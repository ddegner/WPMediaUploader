import XCTest
@testable import WordpressMediaUploaderApp

final class JobRunnerLogicTests: XCTestCase {

    // MARK: - resolvedStagingRoot

    func testResolvedStagingRootTildeOnly() {
        let profile = makeProfile(remoteStagingRoot: "~")
        let result = resolvedStagingRoot(profile: profile, homeDirectory: "/home/deploy")
        XCTAssertEqual(result, "/home/deploy")
    }

    func testResolvedStagingRootTildeSlashPath() {
        let profile = makeProfile(remoteStagingRoot: "~/wp-media-import")
        let result = resolvedStagingRoot(profile: profile, homeDirectory: "/home/deploy")
        XCTAssertEqual(result, "/home/deploy/wp-media-import")
    }

    func testResolvedStagingRootAbsolutePath() {
        let profile = makeProfile(remoteStagingRoot: "/var/staging")
        let result = resolvedStagingRoot(profile: profile, homeDirectory: "/home/deploy")
        XCTAssertEqual(result, "/var/staging")
    }

    func testResolvedStagingRootTildeSlashNestedPath() {
        let profile = makeProfile(remoteStagingRoot: "~/a/b/c")
        let result = resolvedStagingRoot(profile: profile, homeDirectory: "/root")
        XCTAssertEqual(result, "/root/a/b/c")
    }

    // MARK: - shellSingleQuote edge cases

    func testShellSingleQuoteEmptyString() {
        XCTAssertEqual(shellSingleQuote(""), "''")
    }

    func testShellSingleQuoteWithSingleQuote() {
        XCTAssertEqual(shellSingleQuote("it's"), "'it'\\''s'")
    }

    func testShellSingleQuoteSimple() {
        XCTAssertEqual(shellSingleQuote("hello"), "'hello'")
    }

    // MARK: - prepareFileItems

    @MainActor
    func testPrepareFileItemsEmptyThrows() throws {
        let runner = TestSupport.makeRunner()

        XCTAssertThrowsError(try runner.prepareFileItems(urls: [])) { error in
            XCTAssertTrue(error is JobRunnerError)
        }
    }

    @MainActor
    func testPrepareFileItemsUnsupportedThrows() throws {
        let runner = TestSupport.makeRunner()

        let urls = [URL(fileURLWithPath: "/tmp/test.zip")]
        XCTAssertThrowsError(try runner.prepareFileItems(urls: urls)) { error in
            XCTAssertTrue(error is JobRunnerError)
        }
    }

    @MainActor
    func testPrepareFileItemsAllowsDuplicateBasenamesFromDifferentFolders() throws {
        let fm = FileManager.default
        let tempRoot = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("wp-uploader-tests-\(UUID().uuidString)", isDirectory: true)
        let aDir = tempRoot.appendingPathComponent("a", isDirectory: true)
        let bDir = tempRoot.appendingPathComponent("b", isDirectory: true)
        let aFile = aDir.appendingPathComponent("same.jpg", isDirectory: false)
        let bFile = bDir.appendingPathComponent("same.jpg", isDirectory: false)

        try fm.createDirectory(at: aDir, withIntermediateDirectories: true)
        try fm.createDirectory(at: bDir, withIntermediateDirectories: true)
        try Data([0x00, 0x01]).write(to: aFile)
        try Data([0x02, 0x03]).write(to: bFile)

        defer { try? fm.removeItem(at: tempRoot) }

        let runner = TestSupport.makeRunner()

        let items = try runner.prepareFileItems(urls: [aFile, bFile])
        XCTAssertEqual(items.count, 2)
    }

    @MainActor
    func testPrepareFileItemsDeduplicatesSamePath() throws {
        let fm = FileManager.default
        let tempRoot = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("wp-uploader-tests-\(UUID().uuidString)", isDirectory: true)
        let fileURL = tempRoot.appendingPathComponent("one.jpg", isDirectory: false)

        try fm.createDirectory(at: tempRoot, withIntermediateDirectories: true)
        try Data([0x00, 0x01]).write(to: fileURL)
        defer { try? fm.removeItem(at: tempRoot) }

        let runner = TestSupport.makeRunner()

        let items = try runner.prepareFileItems(urls: [fileURL, fileURL])
        XCTAssertEqual(items.count, 1)
        XCTAssertEqual(items.first?.localURL.standardizedFileURL.path, fileURL.standardizedFileURL.path)
    }

    @MainActor
    func testPrepareFileItemsStoresBookmarkDataWhenPossible() throws {
        let fm = FileManager.default
        let tempRoot = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("wp-uploader-tests-\(UUID().uuidString)", isDirectory: true)
        let fileURL = tempRoot.appendingPathComponent("bookmarked.jpg", isDirectory: false)

        try fm.createDirectory(at: tempRoot, withIntermediateDirectories: true)
        try Data([0x00, 0x01]).write(to: fileURL)
        defer { try? fm.removeItem(at: tempRoot) }

        let runner = TestSupport.makeRunner()

        let items = try runner.prepareFileItems(urls: [fileURL])
        XCTAssertEqual(items.count, 1)
        XCTAssertNotNil(items.first?.bookmarkData)
    }

    // MARK: - connection test isolation

    @MainActor
    func testConnectionWhileRunIsActiveReturnsEarlyFailure() async {
        let runner = TestSupport.makeRunner()
        runner.isRunning = true

        let result = await runner.testConnection(
            profile: .default,
            password: nil,
            keyPassphrase: nil
        )

        XCTAssertFalse(result.success)
        XCTAssertEqual(result.checks, ["Stop the active upload before running Test Connection."])
    }

    // MARK: - validateProfile

    @MainActor
    func testValidateProfileMissingHostThrows() {
        let runner = TestSupport.makeRunner()

        var profile = ServerProfile.default
        profile.host = ""
        profile.username = "user"
        profile.wpRootPath = "/var/www"
        profile.remoteStagingRoot = "~/staging"

        XCTAssertThrowsError(try runner.validateProfile(profile)) { error in
            let desc = error.localizedDescription
            XCTAssertTrue(desc.contains("Host"), "Expected host error, got: \(desc)")
        }
    }

    @MainActor
    func testValidateProfileMissingUsernameThrows() {
        let runner = TestSupport.makeRunner()

        var profile = ServerProfile.default
        profile.host = "example.com"
        profile.username = ""
        profile.wpRootPath = "/var/www"
        profile.remoteStagingRoot = "~/staging"

        XCTAssertThrowsError(try runner.validateProfile(profile)) { error in
            let desc = error.localizedDescription
            XCTAssertTrue(desc.contains("Username"), "Expected username error, got: \(desc)")
        }
    }

    @MainActor
    func testValidateProfileMissingWpPathThrows() {
        let runner = TestSupport.makeRunner()

        var profile = ServerProfile.default
        profile.host = "example.com"
        profile.username = "user"
        profile.wpRootPath = ""
        profile.remoteStagingRoot = "~/staging"

        XCTAssertThrowsError(try runner.validateProfile(profile)) { error in
            let desc = error.localizedDescription
            XCTAssertTrue(desc.contains("WordPress"), "Expected WP path error, got: \(desc)")
        }
    }

    @MainActor
    func testValidateProfileInvalidPortThrows() {
        let runner = TestSupport.makeRunner()

        var profile = ServerProfile.default
        profile.host = "example.com"
        profile.username = "user"
        profile.wpRootPath = "/var/www"
        profile.remoteStagingRoot = "~/staging"
        profile.port = 0

        XCTAssertThrowsError(try runner.validateProfile(profile, password: "secret")) { error in
            let desc = error.localizedDescription
            XCTAssertTrue(desc.contains("Port"), "Expected port error, got: \(desc)")
        }
    }

    @MainActor
    func testValidateProfileValidSSHKeyProfile() {
        let runner = TestSupport.makeRunner()

        var profile = ServerProfile.default
        profile.host = "example.com"
        profile.username = "user"
        profile.wpRootPath = "/var/www/html"
        profile.remoteStagingRoot = "~/staging"
        profile.authType = .sshKey
        profile.keyPath = nil

        XCTAssertNoThrow(try runner.validateProfile(profile))
    }

    @MainActor
    func testValidateProfilePasswordAuthIgnoresMissingSSHKeyPath() {
        let runner = TestSupport.makeRunner()

        var profile = ServerProfile.default
        profile.host = "example.com"
        profile.username = "user"
        profile.wpRootPath = "/var/www/html"
        profile.remoteStagingRoot = "~/staging"
        profile.authType = .password
        profile.keyPath = "/path/that/does/not/exist/id_ed25519"

        XCTAssertNoThrow(try runner.validateProfile(profile, password: "secret"))
    }

    // MARK: - runner message routing

    @MainActor
    func testCanRetryFailedIsTrueForCancelledJobWithUnfinishedFiles() {
        let runner = TestSupport.makeRunner()

        var file = FileItem(localURL: URL(fileURLWithPath: "/tmp/a.jpg"), filename: "a.jpg", sizeBytes: 10)
        file.status = .verified

        var job = Job(
            profileId: UUID(),
            remoteJobDir: "/tmp/job",
            files: [file],
            logsPath: "/tmp/log.txt"
        )
        job.step = .cancelled
        runner.currentJob = job

        XCTAssertTrue(runner.canRetryFailed)
    }

    @MainActor
    func testCanRetryFailedIsTrueForFailedJobWithQueuedFiles() {
        let runner = TestSupport.makeRunner()

        var file = FileItem(localURL: URL(fileURLWithPath: "/tmp/a.jpg"), filename: "a.jpg", sizeBytes: 10)
        file.status = .queued

        var job = Job(
            profileId: UUID(),
            remoteJobDir: "/tmp/job",
            files: [file],
            logsPath: "/tmp/log.txt"
        )
        job.step = .failed
        runner.currentJob = job

        XCTAssertTrue(runner.canRetryFailed)
    }

    @MainActor
    func testCanRetryFailedIsFalseForCancelledJobWithAllFilesCompleted() {
        let runner = TestSupport.makeRunner()

        var file = FileItem(localURL: URL(fileURLWithPath: "/tmp/a.jpg"), filename: "a.jpg", sizeBytes: 10)
        file.status = .regenerated

        var job = Job(
            profileId: UUID(),
            remoteJobDir: "/tmp/job",
            files: [file],
            logsPath: "/tmp/log.txt"
        )
        job.step = .cancelled
        runner.currentJob = job

        XCTAssertFalse(runner.canRetryFailed)
    }

    @MainActor
    func testStartWithInvalidInputClearsInlineStatusAndSetsBlockingError() {
        let runner = TestSupport.makeRunner()

        runner.inlineStatusMessage = "Old inline message"
        runner.start(profile: ServerProfile.default, fileURLs: [])

        XCTAssertNil(runner.inlineStatusMessage)
        XCTAssertEqual(runner.blockingError, JobRunnerError.missingFiles.localizedDescription)
    }

    @MainActor
    func testLoadJobWhileRunningKeepsCurrentJobAndSetsInlineMessage() {
        let runner = TestSupport.makeRunner()

        let current = Job(
            profileId: UUID(),
            remoteJobDir: "/tmp/current",
            files: [],
            logsPath: "/tmp/current.log"
        )
        let target = Job(
            profileId: UUID(),
            remoteJobDir: "/tmp/target",
            files: [],
            logsPath: "/tmp/target.log"
        )

        runner.currentJob = current
        runner.isRunning = true

        runner.loadJob(target)

        XCTAssertEqual(runner.currentJob?.id, current.id)
        XCTAssertEqual(runner.inlineStatusMessage, "Cannot switch jobs while a run is active.")
    }

    // MARK: - JobStep lifecycle

    func testJobStepInFlightStepsMatchesExpectedPipelineStages() {
        XCTAssertEqual(
            JobStep.inFlightSteps,
            Set([.preflight, .uploading, .verifying, .importing, .regenerating, .sideloading])
        )
    }

    func testJobStepIsTerminalForTerminalStatesOnly() {
        XCTAssertTrue(JobStep.finished.isTerminal)
        XCTAssertTrue(JobStep.failed.isTerminal)
        XCTAssertTrue(JobStep.cancelled.isTerminal)
        XCTAssertFalse(JobStep.preflight.isTerminal)
        XCTAssertFalse(JobStep.uploading.isTerminal)
        XCTAssertFalse(JobStep.verifying.isTerminal)
        XCTAssertFalse(JobStep.importing.isTerminal)
        XCTAssertFalse(JobStep.regenerating.isTerminal)
    }

    func testJobStepInFlightCanTransitionToInFlightAndTerminal() {
        XCTAssertTrue(JobStep.preflight.canTransition(to: .uploading))
        XCTAssertTrue(JobStep.uploading.canTransition(to: .verifying))
        XCTAssertTrue(JobStep.verifying.canTransition(to: .importing))
        XCTAssertTrue(JobStep.importing.canTransition(to: .regenerating))
        XCTAssertTrue(JobStep.regenerating.canTransition(to: .uploading))
        XCTAssertTrue(JobStep.uploading.canTransition(to: .failed))
        XCTAssertTrue(JobStep.importing.canTransition(to: .cancelled))
        XCTAssertTrue(JobStep.regenerating.canTransition(to: .finished))
    }

    func testJobStepTerminalCanOnlyTransitionBackToPreflightOrStaySame() {
        XCTAssertTrue(JobStep.finished.canTransition(to: .preflight))
        XCTAssertTrue(JobStep.failed.canTransition(to: .preflight))
        XCTAssertTrue(JobStep.cancelled.canTransition(to: .preflight))

        XCTAssertTrue(JobStep.finished.canTransition(to: .finished))
        XCTAssertTrue(JobStep.failed.canTransition(to: .failed))
        XCTAssertTrue(JobStep.cancelled.canTransition(to: .cancelled))

        XCTAssertFalse(JobStep.finished.canTransition(to: .uploading))
        XCTAssertFalse(JobStep.failed.canTransition(to: .verifying))
        XCTAssertFalse(JobStep.cancelled.canTransition(to: .importing))
    }

    // MARK: - Helpers

    private func makeProfile(remoteStagingRoot: String) -> ServerProfile {
        var profile = ServerProfile.default
        profile.remoteStagingRoot = remoteStagingRoot
        return profile
    }
}
