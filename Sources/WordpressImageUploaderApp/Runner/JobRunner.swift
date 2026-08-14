import AppKit
import Foundation
import Observation
import UserNotifications

enum JobRunnerError: LocalizedError {
    case missingFiles
    case unsupportedImages
    case profileIncomplete(String)
    case authSetupFailed(String)
    case invalidStepTransition(from: JobStep, to: JobStep)

    var errorDescription: String? {
        switch self {
        case .missingFiles:
            return "No files selected."
        case .unsupportedImages:
            return "No supported image files were selected."
        case let .profileIncomplete(detail):
            return "Profile is incomplete: \(detail)"
        case let .authSetupFailed(detail):
            return "Failed to configure SSH authentication: \(detail)"
        case let .invalidStepTransition(from, to):
            return "Invalid job step transition: \(from.rawValue) -> \(to.rawValue)"
        }
    }
}

@MainActor
@Observable
final class JobRunner {
    static let playCompletionSoundDefaultsKey = "playCompletionSoundOnCompletion"
    static let showCompletionNotificationDefaultsKey = "showCompletionNotificationOnCompletion"
    
    struct IdentifiedLogLine: Identifiable {
        let id: Int
        let text: String
    }

    private actor ConnectionTestTimeoutState {
        private(set) var triggered = false

        func markTriggered() {
            triggered = true
        }
    }

    private static let connectionTestTimeoutSeconds: UInt64 = 45
    private static let longCommandHeartbeatSeconds: UInt64 = 20

    var currentJob: Job?
    var logLines: [IdentifiedLogLine] = []
    var isRunning = false
    var blockingError: String?
    var inlineStatusMessage: String?

    private let profileStore: ProfileStore
    private let jobStore: JobStore
    private let transport: SSHTransport
    private let logsDirectory: URL

    private var activeRunJobID: UUID?
    private var isCancelling = false
    private var jobTask: Task<Void, Error>?
    private var logLineCounter = 0

    // Weak registry so the app delegate can find a running upload at quit
    // time without plumbing the runner out of the SwiftUI view tree.
    private static let registry = NSHashTable<JobRunner>.weakObjects()

    static var runningInstance: JobRunner? {
        registry.allObjects.first { $0.isRunning }
    }

    static func requestCompletionNotificationAuthorizationIfNeeded() {
        UNUserNotificationCenter.current().getNotificationSettings { settings in
            guard settings.authorizationStatus == .notDetermined else { return }
            UNUserNotificationCenter.current().requestAuthorization(options: [.alert]) { _, _ in
                // No-op: callers handle notification delivery opportunistically.
            }
        }
    }

    init(
        profileStore: ProfileStore,
        jobStore: JobStore,
        transport: SSHTransport? = nil,
        logsDirectory: URL? = nil
    ) {
        self.profileStore = profileStore
        self.jobStore = jobStore
        self.transport = transport ?? SSHTransport(profileStore: profileStore)
        self.logsDirectory = logsDirectory ?? AppPaths.logsDirectory
        // SwiftUI re-runs view initializers, so throwaway JobRunners are
        // constructed while one instance may be mid-run. Recovering then
        // would mark the live job as interrupted/failed in the store.
        if Self.runningInstance == nil {
            recoverInterruptedJobs()
        }
        self.currentJob = nil
        self.logLines = []
        Self.registry.add(self)
    }

    var canRetryFailed: Bool {
        guard !isRunning, let job = currentJob else { return false }

        if job.step == .failed || job.step == .cancelled {
            return job.localFiles.contains { isRetryableStatus($0.status, avifSideloadOn: job.avifSideloadOn) }
        }

        return job.localFiles.contains { $0.status == .failed }
    }

    func start(profile: ServerProfile, fileURLs: [URL]) {
        guard !isRunning else { return }
        do {
            let fileItems = try prepareFileItems(urls: fileURLs)
            start(profile: profile, fileItems: fileItems)
        } catch {
            inlineStatusMessage = nil
            presentBlockingError(error.localizedDescription)
        }
    }

    func start(profile: ServerProfile, fileItems: [FileItem]) {
        guard !isRunning else { return }
        inlineStatusMessage = nil

        do {
            let fileItems = try prepareFileItems(items: fileItems)
            let jobId = UUID()
            let remoteJobDir = "\(ensureNoTrailingSlash(profile.remoteStagingRoot))/\(jobId.uuidString)"
            let logsPath = logsDirectory
                .appendingPathComponent("\(jobId.uuidString).log", isDirectory: false)
                .path

            var job = Job(profileId: profile.id, remoteJobDir: remoteJobDir, files: fileItems, logsPath: logsPath)
            job.id = jobId
            job.avifSideloadEnabled = profile.generateAvifsLocallyEnabled

            currentJob = job
            logLines = []
            presentBlockingError(nil)
            inlineStatusMessage = nil
            jobStore.upsert(job)

            runPipeline(profile: profile, jobID: job.id)
        } catch {
            presentBlockingError(error.localizedDescription)
        }
    }

    func retryFailed(profile: ServerProfile) {
        guard !isRunning else { return }
        guard let selectedJob = currentJob else { return }

        guard selectedJob.profileId == profile.id else {
            presentInlineStatusMessage("The selected profile does not match the job's original profile.")
            return
        }

        do {
            try transitionJobStep(jobID: selectedJob.id, to: .preflight) { job in
                for idx in job.localFiles.indices {
                    guard job.localFiles[idx].status == .failed else { continue }

                    if job.localFiles[idx].importAttachmentId != nil {
                        job.localFiles[idx].status = .imported
                    } else {
                        job.localFiles[idx].status = .queued
                        job.localFiles[idx].remotePath = nil
                    }
                    job.localFiles[idx].errorMessage = nil
                }

                job.errorMessage = nil
                job.activeFileId = nil
            }
        } catch {
            presentInlineStatusMessage(error.localizedDescription)
            return
        }

        recalculateProgress(jobID: selectedJob.id)
        runPipeline(profile: profile, jobID: selectedJob.id)
    }

    func cancel() {
        guard isRunning else { return }

        isCancelling = true
        if let activeRunJobID {
            do {
                try transitionJobStep(jobID: activeRunJobID, to: .cancelled) { job in
                    job.errorMessage = "Cancellation requested"
                    job.activeFileId = nil
                }
            } catch JobRunnerError.invalidStepTransition {
                // The run reached a terminal state before cancellation could be applied.
            } catch {
                presentInlineStatusMessage(error.localizedDescription)
            }
        }

        appendLog("Cancellation requested by user.", writer: nil)

        jobTask?.cancel()
        Task {
            await transport.cancelActiveProcess()
        }
    }

    /// Cancels and awaits the transport-level teardown. The quit handshake
    /// must use this instead of cancel(): isRunning flips before the
    /// SIGTERM necessarily reaches the ssh/rsync children, so polling it
    /// alone can let quitting orphan them mid-transfer.
    func cancelAndWaitForTransport() async {
        cancel()
        await transport.cancelActiveProcess()
    }

    func reportText() -> String {
        guard let job = currentJob else {
            return "No job has run yet."
        }

        return ReportBuilder.textReport(for: job)
    }

    func reportPayload(format: ReportExportFormat) -> String? {
        guard let job = currentJob else { return nil }

        switch format {
        case .text:
            return ReportBuilder.textReport(for: job)
        case .json:
            return try? ReportBuilder.jsonReport(for: job)
        case .csv:
            return ReportBuilder.csvReport(for: job)
        }
    }

    func suggestedReportFileName(format: ReportExportFormat) -> String {
        guard let job = currentJob else {
            return "wp-media-job-report.\(format.fileExtension)"
        }
        return "wp-media-job-\(job.id.uuidString).\(format.fileExtension)"
    }

    func loadJob(_ job: Job) {
        if isRunning {
            presentInlineStatusMessage("Cannot switch jobs while a run is active.")
            return
        }

        currentJob = job
        presentBlockingError(nil)
        inlineStatusMessage = nil
        logLines = readLogLines(atPath: job.logsPath)
    }

    /// User-visible notice in the inline status area, for non-job events
    /// the view needs to surface (e.g. a drop that contained no images).
    func presentNotice(_ message: String) {
        presentInlineStatusMessage(message)
    }

    /// Unloads the current job and every piece of state derived from it.
    /// The view must call this instead of nilling currentJob directly —
    /// otherwise the terminal and inline status keep showing the dead job.
    func reset() {
        guard !isRunning else { return }
        currentJob = nil
        logLines = []
        presentBlockingError(nil)
        inlineStatusMessage = nil
    }

    /// Clears stored job history — scoped to one profile when an id is
    /// given, matching what the history list is showing.
    func clearJobHistory(profileId: UUID? = nil) {
        guard !isRunning else { return }
        jobStore.clear(profileId: profileId)

        // Only drop the loaded job when it was part of the cleared set.
        if let current = currentJob, profileId == nil || current.profileId == profileId {
            currentJob = nil
            logLines = []
            presentBlockingError(nil)
            inlineStatusMessage = nil
        }
    }

    func testConnection(profile: ServerProfile, password: String?, keyPassphrase: String?) async -> ProfileTestResult {
        guard !isRunning else {
            return ProfileTestResult(
                checks: ["Stop the active upload before running Test Connection."],
                success: false
            )
        }

        var checks: [String] = []
        var authContext: SSHAuthContext?
        let timeoutState = ConnectionTestTimeoutState()
        let timeoutTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: Self.connectionTestTimeoutSeconds * 1_000_000_000)
            guard !Task.isCancelled else { return }
            await timeoutState.markTriggered()
            await transport.cancelActiveProcess()
        }
        defer {
            timeoutTask.cancel()
            authContext?.cleanup()
        }

        do {
            try validateProfile(profile, password: password)
            let auth = try transport.makeAuthContext(for: profile, password: password, keyPassphrase: keyPassphrase)
            authContext = auth

            let home = try await transport.fetchRemoteHomeDirectory(profile: profile, auth: auth, writer: nil)

            _ = try await transport.runSSH(profile: profile, auth: auth, remoteCommand: "uname -a", writer: nil)
            checks.append("SSH OK")

            try await transport.runPreflightChecks(profile: profile, auth: auth, writer: nil)
            checks.append("WP-CLI OK")
            checks.append("WP detected")

            let stagingRoot = resolvedStagingRoot(profile: profile, homeDirectory: home)
            let writableCmd = "mkdir -p \(shellSingleQuote(stagingRoot)) && test -w \(shellSingleQuote(stagingRoot))"
            _ = try await transport.runSSH(profile: profile, auth: auth, remoteCommand: writableCmd, writer: nil)
            checks.append("Writable staging OK")

            return ProfileTestResult(checks: checks, success: true)
        } catch {
            if await timeoutState.triggered {
                checks.append("Connection test timed out after \(Self.connectionTestTimeoutSeconds) seconds.")
                return ProfileTestResult(checks: checks, success: false)
            }
            checks.append(error.localizedDescription)
            return ProfileTestResult(checks: checks, success: false)
        }
    }

    // MARK: - Pipeline

    private func runPipeline(profile: ServerProfile, jobID: UUID) {
        activeRunJobID = jobID
        isRunning = true
        isCancelling = false
        presentBlockingError(nil)
        inlineStatusMessage = nil

        jobTask = Task { @MainActor in
            defer {
                self.isRunning = false
                self.isCancelling = false
                self.jobTask = nil
                self.activeRunJobID = nil
            }

            do {
                try await executeJobPipeline(profile: profile, jobID: jobID)
            } catch is CancellationError {
                markJobCancelled(jobID: jobID, writer: nil)
            } catch {
                handleJobError(error, jobID: jobID)
            }
        }
    }

    private func executeJobPipeline(profile: ServerProfile, jobID: UUID) async throws {
        guard let job = jobSnapshot(id: jobID) else {
            presentBlockingError("The selected job no longer exists.")
            return
        }

        let logURL = URL(fileURLWithPath: job.logsPath)
        let writer = LogWriter(fileURL: logURL)
        defer { writer.flush() }
        appendLog("Job started: \(job.id.uuidString)", writer: writer)

        let logger = lineLogger(writer: writer)
        let authContext: SSHAuthContext

        // Setup and validation
        try validateProfile(profile)
        authContext = try transport.makeAuthContext(for: profile)
        defer { authContext.cleanup() }

        // Execute pipeline steps sequentially (keeping original logic but with better structure)
        try Task.checkCancellation()
        let home = try await transport.fetchRemoteHomeDirectory(
            profile: profile,
            auth: authContext,
            writer: writer,
            onLine: logger
        )

        let resolvedRoot = resolvedStagingRoot(profile: profile, homeDirectory: home)
        mutateJob(id: jobID) { mutable in
            mutable.remoteJobDir = "\(ensureNoTrailingSlash(resolvedRoot))/\(mutable.id.uuidString)"
        }

        try Task.checkCancellation()
        let avifContext = try await preflight(profile: profile, auth: authContext, writer: writer, jobID: jobID)

        try Task.checkCancellation()
        try await ensureRemoteJobDirectories(profile: profile, auth: authContext, writer: writer, jobID: jobID)

        try Task.checkCancellation()
        try await processFilesSequentially(
            profile: profile,
            auth: authContext,
            writer: writer,
            jobID: jobID,
            avifContext: avifContext
        )

        try Task.checkCancellation()
        if !profile.keepRemoteFiles {
            try await cleanupRemoteFiles(profile: profile, auth: authContext, writer: writer, jobID: jobID)
        }

        try? FileManager.default.removeItem(
            at: AppPaths.avifWorkRootDirectory.appendingPathComponent(jobID.uuidString, isDirectory: true)
        )

        try finishJob(jobID: jobID)
    }

    private func handleJobError(_ error: Error, jobID: UUID) {
        if isCancelling {
            markJobCancelled(jobID: jobID, writer: nil)
        } else {
            appendLog("Job failed: \(error.localizedDescription)", writer: nil)
            do {
                try transitionJobStep(jobID: jobID, to: .failed, writer: nil) { mutable in
                    mutable.errorMessage = error.localizedDescription
                    mutable.activeFileId = nil
                }
            } catch {
                appendLog(error.localizedDescription, writer: nil)
            }
            presentBlockingError(error.localizedDescription)
            notifyCompletionIfEnabled(success: false, jobID: jobID)
        }
    }

    private func finishJob(jobID: UUID) throws {
        guard let job = jobSnapshot(id: jobID) else { return }

        if job.localFiles.contains(where: { $0.status == .failed }) {
            try transitionJobStep(jobID: jobID, to: .failed) { mutable in
                mutable.errorMessage =
                    "\(mutable.failedCount) file(s) failed. Use Retry Failed to rerun only failed steps."
                mutable.activeFileId = nil
            }
            presentInlineStatusMessage(jobSnapshot(id: jobID)?.errorMessage)
            notifyCompletionIfEnabled(success: false, jobID: jobID)
        } else {
            try transitionJobStep(jobID: jobID, to: .finished) { mutable in
                mutable.errorMessage = nil
                mutable.uploadProgress = 1
                mutable.importProgress = 1
                mutable.activeFileId = nil
            }
            presentInlineStatusMessage(nil)
            notifyCompletionIfEnabled(success: true, jobID: jobID)
        }
    }

    private func markJobCancelled(jobID: UUID, writer: LogWriter?) {
        appendLog("Job cancelled.", writer: writer)
        var markedCancelled = false
        do {
            try transitionJobStep(jobID: jobID, to: .cancelled, writer: writer) { mutable in
                mutable.errorMessage = "Cancelled by user"
                mutable.activeFileId = nil
            }
            markedCancelled = true
        } catch JobRunnerError.invalidStepTransition {
            // Ignore races where the job already reached a terminal state.
        } catch {
            appendLog(error.localizedDescription, writer: writer)
        }
        if markedCancelled {
            presentInlineStatusMessage("Job cancelled. Use Retry Failed to continue unfinished files.")
        }
    }

    // MARK: - Pipeline steps

    private func preflight(
        profile: ServerProfile,
        auth: SSHAuthContext,
        writer: LogWriter,
        jobID: UUID
    ) async throws -> AvifSideloadContext? {
        try transitionJobStep(jobID: jobID, to: .preflight, writer: writer) {
            $0.activeFileId = nil
        }

        let logger = lineLogger(writer: writer)

        try await transport.runPreflightChecks(
            profile: profile,
            auth: auth,
            writer: writer,
            onLine: logger
        )

        _ = try await transport.runSSH(
            profile: profile,
            auth: auth,
            remoteCommand: wpCommand("wp --path=\(shellSingleQuote(profile.wpRootPath)) core version"),
            writer: writer,
            onLine: logger
        )

        guard jobSnapshot(id: jobID)?.avifSideloadOn == true else {
            return nil
        }
        return try await prepareAvifSideloadContext(profile: profile, auth: auth, writer: writer)
    }

    private func prepareAvifSideloadContext(
        profile: ServerProfile,
        auth: SSHAuthContext,
        writer: LogWriter
    ) async throws -> AvifSideloadContext {
        let baseDir = try await fetchUploadsBaseDir(profile: profile, auth: auth, writer: writer)
        let settings = try await fetchAvifPluginSettings(profile: profile, auth: auth, writer: writer)
        try await noteConvertOnUploadIfEnabled(profile: profile, auth: auth, writer: writer)

        let helperURL = Self.bundledAvifencHelperURL()
        appendLog(
            settings.encoderSummary(usingEmbeddedEncoder: helperURL != nil, uploadsBaseDir: baseDir),
            writer: writer
        )

        return AvifSideloadContext(uploadsBaseDir: baseDir, settings: settings, helperURL: helperURL)
    }

    private func fetchUploadsBaseDir(
        profile: ServerProfile,
        auth: SSHAuthContext,
        writer: LogWriter
    ) async throws -> String {
        let wpPath = shellSingleQuote(profile.wpRootPath)
        let result = try await transport.runSSH(
            profile: profile,
            auth: auth,
            remoteCommand: wpCommand("wp --path=\(wpPath) eval 'echo wp_upload_dir()[\"basedir\"];'"),
            writer: writer,
            onLine: nil
        )
        guard let baseDir = parseUploadsBaseDir(fromStdoutLines: result.stdoutLines) else {
            throw JobRunnerError.profileIncomplete(
                "Could not resolve the WordPress uploads directory for AVIF sideloading"
            )
        }
        return baseDir
    }

    /// One batched read of the plugin's encoder settings. A failed read is
    /// not fatal — the job proceeds on the plugin's own defaults.
    private func fetchAvifPluginSettings(
        profile: ServerProfile,
        auth: SSHAuthContext,
        writer: LogWriter
    ) async throws -> AvifPluginSettings {
        do {
            let wpPath = shellSingleQuote(profile.wpRootPath)
            let php = shellSingleQuote(AvifPluginSettings.optionFetchExpression)
            let result = try await transport.runSSH(
                profile: profile,
                auth: auth,
                remoteCommand: wpCommand("wp --path=\(wpPath) eval \(php)"),
                writer: writer,
                onLine: nil
            )
            return AvifPluginSettings.parse(from: result.stdoutLines.joined(separator: "\n"))
        } catch {
            if Task.isCancelled { throw CancellationError() }
            appendLog("AVIF plugin settings not readable; using defaults (quality 85).", writer: writer)
            return AvifPluginSettings()
        }
    }

    private func noteConvertOnUploadIfEnabled(
        profile: ServerProfile,
        auth: SSHAuthContext,
        writer: LogWriter
    ) async throws {
        do {
            let wpPath = shellSingleQuote(profile.wpRootPath)
            let result = try await transport.runSSH(
                profile: profile,
                auth: auth,
                remoteCommand: wpCommand("wp --path=\(wpPath) option get aviflosu_convert_on_upload"),
                writer: writer,
                onLine: nil
            )
            let value = result.stdoutLines.last?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if value == "1" {
                appendLog(
                    "Note: the server plugin's convert-on-upload is enabled; imports run with --skip-plugins so it stays inactive during this job.",
                    writer: writer
                )
            }
        } catch {
            if Task.isCancelled { throw CancellationError() }
            // Option missing or plugin not installed — nothing to report.
        }
    }

    /// The embedded aom encoder honors every plugin setting; without it,
    /// ImageIO covers quality only (4:2:0 / 8-bit).
    private static func bundledAvifencHelperURL() -> URL? {
        guard let bundled = Bundle.main.url(forAuxiliaryExecutable: "avifenc"),
              FileManager.default.isExecutableFile(atPath: bundled.path)
        else {
            return nil
        }
        return bundled
    }

    private func ensureRemoteJobDirectories(
        profile: ServerProfile,
        auth: SSHAuthContext,
        writer: LogWriter,
        jobID: UUID
    ) async throws {
        guard let job = jobSnapshot(id: jobID) else { return }

        let incoming = incomingDirectory(for: job)
        let command = "mkdir -p \(shellSingleQuote(incoming))"
        _ = try await transport.runSSH(
            profile: profile,
            auth: auth,
            remoteCommand: command,
            writer: writer,
            onLine: lineLogger(writer: writer)
        )
    }

    private func processFilesSequentially(
        profile: ServerProfile,
        auth: SSHAuthContext,
        writer: LogWriter,
        jobID: UUID,
        avifContext: AvifSideloadContext?
    ) async throws {
        try Task.checkCancellation()
        guard let job = jobSnapshot(id: jobID) else { return }

        let context = StageContext(profile: profile, auth: auth, writer: writer, jobID: jobID)
        let incomingDir = incomingDirectory(for: job)
        let avifSideloadOn = avifContext != nil

        recalculateProgress(jobID: jobID)

        for fileID in job.localFiles.map(\.id) {
            try Task.checkCancellation()
            guard let current = fileSnapshot(jobID: jobID, fileID: fileID) else { continue }
            guard shouldProcessSequentially(current, avifSideloadOn: avifSideloadOn) else { continue }

            mutateJob(id: jobID) { mutable in
                mutable.activeFileId = current.id
            }

            try await processFile(fileID, context: context, incomingDir: incomingDir, avifContext: avifContext)
        }

        mutateJob(id: jobID) { mutable in
            mutable.activeFileId = nil
        }
    }

    /// Walks one file through every stage it still needs. A stage failure
    /// marks the file failed, which makes the remaining stages skip it.
    private func processFile(
        _ fileID: UUID,
        context: StageContext,
        incomingDir: String,
        avifContext: AvifSideloadContext?
    ) async throws {
        let avifSideloadOn = avifContext != nil

        try await runStage(
            fileID, context: context, from: .queued, to: .uploading,
            failure: { file, error in
                StageFailure(
                    message: "Upload failed for \(file.filename): \(error.localizedDescription)",
                    mutate: { $0.remotePath = nil }
                )
            },
            body: { file in
                try await uploadFile(file, context: context, incomingDir: incomingDir)
            }
        )

        try await runStage(
            fileID, context: context, from: .uploaded, to: .verifying,
            // The transport already echoed the failing command; keep the
            // job log free of a duplicate failure line.
            failure: { _, error in
                StageFailure(message: error.localizedDescription, logged: false)
            },
            body: { file in
                try await verifyFile(file, context: context)
            }
        )

        try await runStage(
            fileID, context: context, from: .verified, to: .importing,
            failure: { file, error in
                StageFailure(message: timeoutAwareMessage(
                    for: error,
                    fallback: "Import failed for \(file.filename): \(error.localizedDescription)"
                ))
            },
            body: { file in
                try await importFile(file, context: context, skipAvifPlugin: avifSideloadOn)
            }
        )

        try await runStage(
            fileID, context: context, from: .imported, to: .regenerating,
            failure: { file, error in
                StageFailure(message: timeoutAwareMessage(
                    for: error,
                    fallback: "Thumbnail regeneration failed for \(file.filename): \(error.localizedDescription)"
                ))
            },
            body: { file in
                try await regenerateFile(file, context: context, skipAvifPlugin: avifSideloadOn)
            }
        )

        if let avifContext {
            try await runStage(
                fileID, context: context, from: .regenerated, to: .sideloading,
                failure: { file, error in
                    StageFailure(
                        message: "AVIF sideload failed for \(file.filename): \(error.localizedDescription)"
                    )
                },
                body: { file in
                    try await sideloadFile(file, context: context, avifContext: avifContext)
                }
            )
        }
    }

    /// Connection and logging context shared by every stage of one run.
    private struct StageContext {
        let profile: ServerProfile
        let auth: SSHAuthContext
        let writer: LogWriter
        let jobID: UUID
    }

    /// How a stage records a thrown error on the file it was processing.
    private struct StageFailure {
        var message: String
        /// When false the message lands only on the file, not in the job log.
        var logged = true
        /// Extra cleanup applied together with the failed status.
        var mutate: ((inout FileItem) -> Void)?
    }

    /// Message-only error for stage bodies whose failure is detected locally
    /// (e.g. a verification mismatch) rather than thrown by the transport.
    private struct StageError: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    /// Shared shell for one per-file pipeline stage: skips the file unless it
    /// currently holds `entryStatus`, records the matching job step, turns a
    /// thrown error into a failed file (rethrowing cancellation untouched),
    /// and refreshes job progress. The body does the stage's work and records
    /// its own success state.
    private func runStage(
        _ fileID: UUID,
        context: StageContext,
        from entryStatus: FileItemStatus,
        to step: JobStep,
        failure: (FileItem, Error) -> StageFailure,
        body: (FileItem) async throws -> Void
    ) async throws {
        guard let file = fileSnapshot(jobID: context.jobID, fileID: fileID), file.status == entryStatus else {
            return
        }

        try transitionJobStep(jobID: context.jobID, to: step, writer: context.writer)

        do {
            try await body(file)
        } catch {
            if Task.isCancelled {
                throw CancellationError()
            }
            let failure = failure(file, error)
            if failure.logged {
                appendLog(failure.message, writer: context.writer)
            }
            updateFile(jobID: context.jobID, id: file.id) {
                $0.status = .failed
                $0.errorMessage = failure.message
                failure.mutate?(&$0)
            }
        }

        recalculateProgress(jobID: context.jobID)
    }

    // MARK: - Per-file stage work

    private func uploadFile(_ file: FileItem, context: StageContext, incomingDir: String) async throws {
        let jobID = context.jobID
        let writer = context.writer
        let totalFiles = max(totalFileCount(jobID: jobID), 1)
        let uploadedBefore = uploadedCompletedCount(jobID: jobID, excluding: file.id)

        let remoteDir = remoteUploadDirectory(incomingDir: incomingDir, file: file)
        _ = try await transport.runSSH(
            profile: context.profile,
            auth: context.auth,
            remoteCommand: "mkdir -p \(shellSingleQuote(remoteDir))",
            writer: writer,
            onLine: lineLogger(writer: writer)
        )

        let remotePath = remoteUploadPath(incomingDir: incomingDir, file: file)
        try await transport.runRsyncFile(
            profile: context.profile,
            auth: context.auth,
            localFileURL: file.localURL,
            localFileBookmarkData: file.bookmarkData,
            remoteTargetPath: remoteDir + "/",
            transferMode: .resume,
            writer: writer
        ) { [weak self] stream, line in
            guard let self else { return }
            self.appendLog("[\(stream == .stdout ? "out" : "err")] \(line)", writer: writer)
            guard stream == .stdout, let fileProgress = parseRsyncProgress(line) else { return }
            let combined = (Double(uploadedBefore) + fileProgress) / Double(totalFiles)
            self.mutateJob(id: jobID) { mutable in
                mutable.uploadProgress = min(max(combined, 0), 1)
            }
        }

        updateFile(jobID: jobID, id: file.id) {
            $0.remotePath = remotePath
            $0.status = .uploaded
            $0.errorMessage = nil
        }
    }

    private func verifyFile(_ file: FileItem, context: StageContext) async throws {
        guard let remotePath = file.remotePath else {
            throw JobRunnerError.profileIncomplete("Missing remote path for \(file.filename)")
        }

        let remoteSize = try await transport.fetchRemoteFileSize(
            profile: context.profile,
            auth: context.auth,
            remotePath: remotePath,
            writer: context.writer,
            onLine: lineLogger(writer: context.writer)
        )

        guard remoteSize == file.sizeBytes else {
            throw StageError(
                message: "Size mismatch (local \(file.sizeBytes) bytes, remote \(remoteSize) bytes)"
            )
        }

        updateFile(jobID: context.jobID, id: file.id) {
            $0.status = .verified
            $0.errorMessage = nil
        }
    }

    private func importFile(_ file: FileItem, context: StageContext, skipAvifPlugin: Bool) async throws {
        guard let remotePath = file.remotePath else {
            throw JobRunnerError.profileIncomplete("Missing remote path for \(file.filename)")
        }

        let writer = context.writer
        appendLog("Importing \(file.filename).", writer: writer)

        let wpPath = shellSingleQuote(context.profile.wpRootPath)
        let remoteSQ = shellSingleQuote(remotePath)
        // With local AVIF sideloading, keep the server plugin out of
        // the import so it cannot synchronously encode AVIFs.
        let skipPlugins = skipAvifPlugin ? " --skip-plugins=avif-local-support" : ""
        let baseCommand = "wp --path=\(wpPath)\(skipPlugins) media import \(remoteSQ) --porcelain"
        let command = wpCommand(wrapWithOptionalTimeout(command: baseCommand, seconds: 600))
        let heartbeat = startLongCommandHeartbeat(
            activity: "Importing \(file.filename)",
            writer: writer
        )
        defer { heartbeat.cancel() }

        let result = try await transport.runSSH(
            profile: context.profile,
            auth: context.auth,
            remoteCommand: command,
            writer: writer,
            onLine: lineLogger(writer: writer)
        )

        let idLine = result.stdoutLines
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .first { Int($0) != nil }

        guard let idLine, let attachmentId = Int(idLine) else {
            throw JobRunnerError.profileIncomplete(
                "Import did not return attachment ID for \(file.filename)"
            )
        }

        appendLog("Imported \(file.filename) as attachment ID \(attachmentId).", writer: writer)
        mutateJob(id: context.jobID) { mutable in
            if let idx = mutable.localFiles.firstIndex(where: { $0.id == file.id }) {
                mutable.localFiles[idx].status = .imported
                mutable.localFiles[idx].importAttachmentId = attachmentId
                mutable.localFiles[idx].errorMessage = nil
            }

            if !mutable.importedIds.contains(attachmentId) {
                mutable.importedIds.append(attachmentId)
            }
        }
    }

    private func regenerateFile(_ file: FileItem, context: StageContext, skipAvifPlugin: Bool) async throws {
        guard let attachmentId = file.importAttachmentId else {
            throw JobRunnerError.profileIncomplete("Missing attachment ID for \(file.filename)")
        }

        let writer = context.writer
        appendLog("Regenerating thumbnails for \(file.filename) (attachment \(attachmentId)).", writer: writer)

        let wpPath = shellSingleQuote(context.profile.wpRootPath)
        let skipPlugins = skipAvifPlugin ? " --skip-plugins=avif-local-support" : ""
        let baseCommand =
            "wp --path=\(wpPath)\(skipPlugins) media regenerate \(attachmentId) --only-missing --yes"
        let command = wpCommand(wrapWithOptionalTimeout(command: baseCommand, seconds: 600))
        let heartbeat = startLongCommandHeartbeat(
            activity: "Regenerating thumbnails for \(file.filename)",
            writer: writer
        )
        defer { heartbeat.cancel() }

        _ = try await transport.runSSH(
            profile: context.profile,
            auth: context.auth,
            remoteCommand: command,
            writer: writer,
            onLine: lineLogger(writer: writer)
        )

        updateFile(jobID: context.jobID, id: file.id) {
            $0.status = .regenerated
            $0.errorMessage = nil
        }
    }

    private func sideloadFile(
        _ file: FileItem,
        context: StageContext,
        avifContext: AvifSideloadContext
    ) async throws {
        let writer = context.writer

        guard isJpegSourceExtension(file.localURL) else {
            appendLog("Skipped AVIF sideload for \(file.filename) (not a JPEG).", writer: writer)
            updateFile(jobID: context.jobID, id: file.id) {
                $0.status = .sideloaded
                $0.avifCount = 0
                $0.errorMessage = nil
            }
            return
        }

        guard let attachmentId = file.importAttachmentId else {
            throw JobRunnerError.profileIncomplete("Missing attachment ID for \(file.filename)")
        }

        appendLog("Sideloading AVIFs for \(file.filename).", writer: writer)
        let heartbeat = startLongCommandHeartbeat(
            activity: "Sideloading AVIFs for \(file.filename)",
            writer: writer
        )
        defer { heartbeat.cancel() }

        let sideloader = AvifSideloader(transport: transport)
        let outcome = try await sideloader.sideload(
            profile: context.profile,
            auth: context.auth,
            context: avifContext,
            file: file,
            attachmentId: attachmentId,
            jobID: context.jobID,
            writer: writer,
            onLine: lineLogger(writer: writer)
        )

        appendLog(
            "Sideloaded \(outcome.avifCount) AVIF file(s) for \(file.filename).",
            writer: writer
        )
        updateFile(jobID: context.jobID, id: file.id) {
            $0.status = .sideloaded
            $0.avifCount = outcome.avifCount
            $0.errorMessage = nil
        }
    }

    private func cleanupRemoteFiles(
        profile: ServerProfile,
        auth: SSHAuthContext,
        writer: LogWriter,
        jobID: UUID
    ) async throws {
        try Task.checkCancellation()
        guard let job = jobSnapshot(id: jobID) else { return }

        // This is a remote rm -rf on a profile-derived path. Only the exact
        // shape executeJobPipeline builds is acceptable: an absolute path
        // whose final component is this job's UUID. Anything else (an
        // unresolved "~", a traversal, a bare root) is refused.
        let remoteJobDir = ensureNoTrailingSlash(job.remoteJobDir)
        guard remoteJobDir.hasPrefix("/"),
              remoteJobDir.hasSuffix("/\(job.id.uuidString)"),
              !remoteJobDir.split(separator: "/").contains("..")
        else {
            appendLog(
                "Remote cleanup skipped: unexpected job directory '\(job.remoteJobDir)'.",
                writer: writer
            )
            return
        }

        let command = "rm -rf \(shellSingleQuote(remoteJobDir))"
        do {
            _ = try await transport.runSSH(
                profile: profile,
                auth: auth,
                remoteCommand: command,
                writer: writer,
                onLine: lineLogger(writer: writer)
            )
        } catch {
            if Task.isCancelled {
                throw CancellationError()
            }
            appendLog("Remote cleanup skipped: \(error.localizedDescription)", writer: writer)
        }
    }

    // MARK: - File preparation & validation

    func prepareFileItems(urls: [URL]) throws -> [FileItem] {
        let items = urls.compactMap { url -> FileItem? in
            let bookmarkData = try? SecurityScopedFileAccess.bookmarkData(for: url)
            return FileItem.fromURL(url, bookmarkData: bookmarkData)
        }
        return try prepareFileItems(items: items)
    }

    private func prepareFileItems(items: [FileItem]) throws -> [FileItem] {
        guard !items.isEmpty else {
            throw JobRunnerError.missingFiles
        }

        var seenPaths = Set<String>()
        let deduplicated = items.filter { item in
            seenPaths.insert(item.localURL.standardizedFileURL.path).inserted
        }

        let supported = deduplicated.filter { isSupportedImageExtension($0.localURL) }
        guard !supported.isEmpty else {
            throw JobRunnerError.unsupportedImages
        }

        return supported
    }

    func validateProfile(_ profile: ServerProfile, password: String? = nil) throws {
        let effectivePassword: String?
        if profile.authType == .password {
            effectivePassword = try password ?? profileStore.loadPassword(for: profile)
        } else {
            effectivePassword = nil
        }

        if let errorDetail = ProfileValidation.firstError(
            for: profile,
            password: effectivePassword,
            context: .execution
        ) {
            throw JobRunnerError.profileIncomplete(errorDetail)
        }
    }

    // MARK: - Helpers

    private func incomingDirectory(for job: Job) -> String {
        "\(ensureNoTrailingSlash(job.remoteJobDir))/incoming"
    }

    private func remoteUploadDirectory(incomingDir: String, file: FileItem) -> String {
        "\(incomingDir)/\(file.id.uuidString)"
    }

    private func remoteUploadPath(incomingDir: String, file: FileItem) -> String {
        "\(remoteUploadDirectory(incomingDir: incomingDir, file: file))/\(file.filename)"
    }

    private func shouldProcessSequentially(_ file: FileItem, avifSideloadOn: Bool) -> Bool {
        switch file.status {
        case .queued, .uploaded, .verified, .imported:
            return true
        case .regenerated:
            // In sideload-enabled jobs a file resting at .regenerated still
            // needs its AVIF stage (e.g. resumed after cancellation).
            return avifSideloadOn
        case .sideloaded, .failed:
            return false
        }
    }

    private func isRetryableStatus(_ status: FileItemStatus, avifSideloadOn: Bool) -> Bool {
        switch status {
        case .queued, .uploaded, .verified, .imported, .failed:
            return true
        case .regenerated:
            return avifSideloadOn
        case .sideloaded:
            return false
        }
    }

    private func fileSnapshot(jobID: UUID, fileID: UUID) -> FileItem? {
        guard let job = jobSnapshot(id: jobID) else { return nil }
        return job.localFiles.first(where: { $0.id == fileID })
    }

    private func totalFileCount(jobID: UUID) -> Int {
        jobSnapshot(id: jobID)?.localFiles.count ?? 0
    }

    private func uploadedCompletedCount(jobID: UUID, excluding fileID: UUID? = nil) -> Int {
        guard let job = jobSnapshot(id: jobID) else { return 0 }
        return job.localFiles.filter { file in
            if let fileID, file.id == fileID {
                return false
            }
            return [.uploaded, .verified, .imported, .regenerated, .sideloaded, .failed].contains(file.status)
        }.count
    }

    private func recalculateProgress(jobID: UUID) {
        guard let job = jobSnapshot(id: jobID) else { return }

        let total = Double(job.localFiles.count)
        guard total > 0 else {
            mutateJob(id: jobID) { mutable in
                mutable.uploadProgress = 0
                mutable.importProgress = 0
            }
            return
        }

        // Count failed files as complete so progress reaches 100%
        // when all files have been attempted.
        let uploaded = Double(job.localFiles.filter {
            [.uploaded, .verified, .imported, .regenerated, .sideloaded, .failed].contains($0.status)
        }.count)
        let imported = Double(job.localFiles.filter {
            [.imported, .regenerated, .sideloaded, .failed].contains($0.status)
        }.count)

        mutateJob(id: jobID) { mutable in
            mutable.uploadProgress = uploaded / total
            mutable.importProgress = imported / total
        }
    }

    private func updateFile(jobID: UUID, id: UUID, _ transform: (inout FileItem) -> Void) {
        mutateJob(id: jobID) { mutable in
            guard let idx = mutable.localFiles.firstIndex(where: { $0.id == id }) else { return }
            transform(&mutable.localFiles[idx])
        }
    }

    private func jobSnapshot(id: UUID) -> Job? {
        if let currentJob, currentJob.id == id {
            return currentJob
        }
        return jobStore.job(id: id)
    }

    private func mutateJob(id: UUID, _ transform: (inout Job) -> Void) {
        guard var mutable = jobSnapshot(id: id) else { return }
        transform(&mutable)
        jobStore.upsert(mutable)

        if currentJob?.id == id || activeRunJobID == id {
            currentJob = mutable
        }
    }

    private func transitionJobStep(
        jobID: UUID,
        to nextStep: JobStep,
        writer: LogWriter? = nil,
        updates: ((inout Job) -> Void)? = nil
    ) throws {
        guard let currentStep = jobSnapshot(id: jobID)?.step else {
            // Callers treat a plain return as success; leave a trace so a
            // vanished job is diagnosable instead of silently absorbed.
            appendLog(
                "Step transition to \(nextStep.rawValue) skipped: job \(jobID.uuidString) no longer exists.",
                writer: writer
            )
            return
        }
        guard currentStep.canTransition(to: nextStep) else {
            let error = JobRunnerError.invalidStepTransition(from: currentStep, to: nextStep)
            appendLog(error.localizedDescription, writer: writer)
            throw error
        }

        mutateJob(id: jobID) { mutable in
            mutable.step = nextStep
            updates?(&mutable)
        }
    }

    private func lineLogger(writer: LogWriter?) -> (@MainActor @Sendable (CommandOutputStream, String) -> Void) {
        { [weak self] stream, line in
            self?.appendLog("[\(stream == .stdout ? "out" : "err")] \(line)", writer: writer)
        }
    }

    private func appendLog(_ message: String, writer: LogWriter?) {
        let line = message.trimmed
        guard !line.isEmpty else { return }

        logLineCounter += 1
        logLines.append(IdentifiedLogLine(id: logLineCounter, text: line))
        // Amortized trim: dropping a batch every 200 lines instead of one
        // per line avoids an O(n) reallocation on every log append.
        if logLines.count > 1200 {
            logLines.removeFirst(logLines.count - 1000)
        }

        writer?.append(line)
    }

    private func startLongCommandHeartbeat(activity: String, writer: LogWriter?) -> Task<Void, Never> {
        Task { @MainActor [weak self] in
            let startedAt = Date()
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: Self.longCommandHeartbeatSeconds * 1_000_000_000)
                guard !Task.isCancelled, let self else { return }

                let elapsed = Date().timeIntervalSince(startedAt)
                let elapsedLabel = Self.elapsedDurationFormatter.string(from: elapsed) ?? "\(Int(elapsed))s"
                self.appendLog("\(activity) still running (\(elapsedLabel) elapsed).", writer: writer)
            }
        }
    }

    private func wrapWithOptionalTimeout(command: String, seconds: Int) -> String {
        "if command -v timeout >/dev/null 2>&1; then timeout \(seconds) \(command); else \(command); fi"
    }

    private func timeoutAwareMessage(for error: Error, fallback: String) -> String {
        let description = error.localizedDescription
        if description.contains("exit code 124") {
            return "Command timed out after 10 minutes. \(fallback)"
        }
        return fallback
    }

    private static let elapsedDurationFormatter: DateComponentsFormatter = {
        let formatter = DateComponentsFormatter()
        formatter.allowedUnits = [.hour, .minute, .second]
        formatter.unitsStyle = .abbreviated
        formatter.maximumUnitCount = 2
        formatter.zeroFormattingBehavior = .dropLeading
        return formatter
    }()

    private func notifyCompletionIfEnabled(success: Bool, jobID: UUID) {
        playCompletionSoundIfEnabled(success: success)
        showCompletionNotificationIfEnabled(success: success, jobID: jobID)
    }

    private func playCompletionSoundIfEnabled(success: Bool) {
        guard UserDefaults.standard.bool(forKey: Self.playCompletionSoundDefaultsKey) else { return }

        let soundName: NSSound.Name = success ? .init("Glass") : .init("Basso")
        if NSSound(named: soundName)?.play() != true {
            NSSound.beep()
        }
    }

    private func showCompletionNotificationIfEnabled(success: Bool, jobID: UUID) {
        guard UserDefaults.standard.bool(forKey: Self.showCompletionNotificationDefaultsKey) else { return }

        UNUserNotificationCenter.current().getNotificationSettings { settings in
            if settings.authorizationStatus == .authorized {
                Self.enqueueCompletionNotification(success: success, jobID: jobID)
                return
            }

            guard settings.authorizationStatus == .notDetermined else { return }
            UNUserNotificationCenter.current().requestAuthorization(options: [.alert]) { granted, _ in
                guard granted else { return }
                Self.enqueueCompletionNotification(success: success, jobID: jobID)
            }
        }
    }

    nonisolated private static func enqueueCompletionNotification(success: Bool, jobID: UUID) {
        let content = UNMutableNotificationContent()
        content.title = success ? "Upload complete" : "Upload finished with errors"
        content.body = success
            ? "All queued files finished processing."
            : "One or more files failed. Open the app for details."

        let request = UNNotificationRequest(
            identifier: "job-completion-\(jobID.uuidString)-\(UUID().uuidString)",
            content: content,
            trigger: nil
        )
        UNUserNotificationCenter.current().add(request)
    }

    private func recoverInterruptedJobs() {
        for existing in jobStore.jobs {
            guard JobStep.inFlightSteps.contains(existing.step) else { continue }

            var recovered = existing
            var hasRetryableFailure = false

            for idx in recovered.localFiles.indices {
                switch recovered.localFiles[idx].status {
                case .sideloaded, .failed:
                    continue
                case .regenerated:
                    guard recovered.avifSideloadOn else { continue }
                    recovered.localFiles[idx].status = .failed
                    recovered.localFiles[idx].errorMessage =
                        "Previous run was interrupted before AVIF sideload completed."
                    hasRetryableFailure = true
                case .queued, .uploaded, .verified, .imported:
                    recovered.localFiles[idx].status = .failed
                    recovered.localFiles[idx].errorMessage = "Previous run was interrupted before completion."
                    hasRetryableFailure = true
                }
            }

            // Always fail an in-flight job even if no specific files were failed (e.g. all files done but job step not updated)
            recovered.step = .failed
            recovered.errorMessage = hasRetryableFailure
                ? "Previous run was interrupted. Use Retry Failed."
                : "Previous run was interrupted before final status update."
            jobStore.upsert(recovered)
        }
    }

    private func presentBlockingError(_ message: String?) {
        blockingError = message
        if message != nil {
            inlineStatusMessage = nil
        }
    }

    private func presentInlineStatusMessage(_ message: String?) {
        inlineStatusMessage = message
    }

    private func readLogLines(atPath path: String) -> [IdentifiedLogLine] {
        guard let contents = try? String(contentsOfFile: path, encoding: .utf8) else {
            return []
        }

        let lines = contents
            .split(separator: "\n", omittingEmptySubsequences: true)
            .map { $0.replacingOccurrences(of: "\r", with: "") }
            .filter { !$0.isEmpty }
            .suffix(1000)
            
        return lines.enumerated().map { index, text in
            IdentifiedLogLine(id: index, text: String(text))
        }
    }
}
