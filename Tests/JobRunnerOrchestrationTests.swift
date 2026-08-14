import Foundation
import XCTest
@testable import WordpressMediaUploaderApp

/// Scripted stand-in for CommandRunner: every command SSHTransport would
/// launch is matched against substring rules and answered with a canned
/// result, and each invocation is recorded for ordering assertions.
actor ScriptedCommandExecutor: CommandExecuting {
    struct Response: Sendable {
        /// All substrings must appear in the rendered command to match.
        var commandContains: [String]
        var stdout: [String] = []
        var exitCode: Int32 = 0
    }

    private let responses: [Response]
    private(set) var executedCommands: [String] = []

    init(responses: [Response]) {
        self.responses = responses
    }

    func run(
        _ spec: CommandSpec,
        idleTimeout: Duration,
        onLine: (@MainActor @Sendable (CommandOutputStream, String) -> Void)?
    ) async throws -> CommandResult {
        let rendered = "\(spec.displayName) \(spec.arguments.joined(separator: " "))"
        executedCommands.append(rendered)

        // Unmatched commands succeed silently, so only the commands a test
        // cares about need scripting.
        let response = responses.first { rule in
            rule.commandContains.allSatisfy { rendered.contains($0) }
        } ?? Response(commandContains: [])

        for line in response.stdout {
            await onLine?(.stdout, line)
        }

        return CommandResult(
            exitCode: response.exitCode,
            stdoutLines: response.stdout,
            stderrLines: response.exitCode == 0 ? [] : ["scripted failure"]
        )
    }

    func cancelActiveProcess() {}
}

@MainActor
final class JobRunnerOrchestrationTests: XCTestCase {
    private var tempRoot: URL!

    override func setUp() {
        super.setUp()
        tempRoot = TestSupport.temporaryDirectory("orchestration")
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: tempRoot)
        tempRoot = nil
        super.tearDown()
    }

    // MARK: - Harness

    /// Key-based auth with no key file: makeAuthContext succeeds without
    /// touching the Keychain or the filesystem.
    private func makeProfile(avifEnabled: Bool = false) -> ServerProfile {
        var profile = ServerProfile.default
        profile.host = "example.com"
        profile.username = "deploy"
        profile.wpRootPath = "/var/www/html"
        profile.remoteStagingRoot = "/var/staging"
        profile.authType = .sshKey
        profile.keyPath = nil
        profile.generateAvifsLocally = avifEnabled
        return profile
    }

    private func makeRunner(executor: ScriptedCommandExecutor) -> JobRunner {
        let profileStore = TestSupport.makeProfileStore()
        return JobRunner(
            profileStore: profileStore,
            jobStore: TestSupport.makeJobStore(),
            transport: SSHTransport(profileStore: profileStore, commandRunner: executor),
            logsDirectory: TestSupport.temporaryDirectory("logs")
        )
    }

    /// Writes a real 4-byte file (rsync's security-scope check requires one)
    /// and returns its queue entry.
    private func makeLocalFile(named name: String) throws -> FileItem {
        let url = tempRoot.appendingPathComponent(name, isDirectory: false)
        try Data([0xde, 0xad, 0xbe, 0xef]).write(to: url)
        return FileItem(localURL: url, filename: name, sizeBytes: 4)
    }

    private func waitUntilRunFinishes(
        _ runner: JobRunner,
        timeout: TimeInterval = 10,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while runner.isRunning {
            if Date() > deadline {
                XCTFail("Timed out waiting for the pipeline run to finish", file: file, line: line)
                return
            }
            try await Task.sleep(for: .milliseconds(10))
        }
    }

    /// Responses every successful run needs: a resolvable remote $HOME and
    /// remote sizes matching the 4-byte local files.
    private static let baselineResponses: [ScriptedCommandExecutor.Response] = [
        .init(commandContains: ["$HOME"], stdout: ["/home/deploy"]),
        .init(commandContains: ["stat -c%s"], stdout: ["4"])
    ]

    // MARK: - Happy path

    func testHappyPathRunsEveryStageInOrderAndFinishesJob() async throws {
        let executor = ScriptedCommandExecutor(responses: Self.baselineResponses + [
            .init(commandContains: ["media import", "a.jpg"], stdout: ["101"]),
            .init(commandContains: ["media import", "b.jpg"], stdout: ["102"])
        ])
        let runner = makeRunner(executor: executor)
        let fileA = try makeLocalFile(named: "a.jpg")
        let fileB = try makeLocalFile(named: "b.jpg")

        runner.start(profile: makeProfile(), fileItems: [fileA, fileB])
        try await waitUntilRunFinishes(runner)

        let job = try XCTUnwrap(runner.currentJob)
        XCTAssertEqual(job.step, .finished)
        XCTAssertEqual(job.localFiles.map(\.status), [.regenerated, .regenerated])
        XCTAssertEqual(job.localFiles.compactMap(\.importAttachmentId), [101, 102])
        XCTAssertEqual(job.importedIds, [101, 102])
        XCTAssertEqual(job.uploadProgress, 1)
        XCTAssertEqual(job.importProgress, 1)
        XCTAssertNil(job.errorMessage)
        XCTAssertNil(job.activeFileId)
        XCTAssertNil(runner.blockingError)

        let commands = await executor.executedCommands
        func firstIndex(
            containing needles: String...,
            file: StaticString = #filePath, line: UInt = #line
        ) throws -> Int {
            try XCTUnwrap(
                commands.firstIndex { command in needles.allSatisfy { command.contains($0) } },
                "No command matching \(needles)",
                file: file, line: line
            )
        }

        // Stages run in pipeline order for the first file…
        let uploadA = try firstIndex(containing: "rsync", "a.jpg")
        let verifyA = try firstIndex(containing: "stat -c%s", "a.jpg")
        let importA = try firstIndex(containing: "media import", "a.jpg")
        let regenerateA = try firstIndex(containing: "media regenerate 101")
        XCTAssertLessThan(uploadA, verifyA)
        XCTAssertLessThan(verifyA, importA)
        XCTAssertLessThan(importA, regenerateA)

        // …and the second file only starts after the first completes.
        let uploadB = try firstIndex(containing: "rsync", "b.jpg")
        XCTAssertLessThan(regenerateA, uploadB)

        // keepRemoteFiles is false, so the staging directory is removed.
        XCTAssertTrue(commands.contains { $0.contains("rm -rf") })
    }

    // MARK: - Stage failures

    func testVerifySizeMismatchFailsFileAndSkipsImport() async throws {
        let executor = ScriptedCommandExecutor(responses: [
            .init(commandContains: ["$HOME"], stdout: ["/home/deploy"]),
            .init(commandContains: ["stat -c%s"], stdout: ["999"])
        ])
        let runner = makeRunner(executor: executor)
        let file = try makeLocalFile(named: "a.jpg")

        runner.start(profile: makeProfile(), fileItems: [file])
        try await waitUntilRunFinishes(runner)

        let job = try XCTUnwrap(runner.currentJob)
        XCTAssertEqual(job.step, .failed)
        XCTAssertEqual(job.localFiles.first?.status, .failed)
        XCTAssertEqual(
            job.localFiles.first?.errorMessage,
            "Size mismatch (local 4 bytes, remote 999 bytes)"
        )
        XCTAssertEqual(job.errorMessage, "1 file(s) failed. Use Retry Failed to rerun only failed steps.")
        XCTAssertEqual(runner.inlineStatusMessage, job.errorMessage)

        let commands = await executor.executedCommands
        XCTAssertFalse(commands.contains { $0.contains("media import") })
    }

    func testImportFailureRecordsTransportErrorAndSkipsRegenerate() async throws {
        let executor = ScriptedCommandExecutor(responses: Self.baselineResponses + [
            .init(commandContains: ["media import"], exitCode: 1)
        ])
        let runner = makeRunner(executor: executor)
        let file = try makeLocalFile(named: "a.jpg")

        runner.start(profile: makeProfile(), fileItems: [file])
        try await waitUntilRunFinishes(runner)

        let job = try XCTUnwrap(runner.currentJob)
        XCTAssertEqual(job.step, .failed)
        XCTAssertEqual(job.localFiles.first?.status, .failed)
        let message = try XCTUnwrap(job.localFiles.first?.errorMessage)
        XCTAssertTrue(message.hasPrefix("Import failed for a.jpg:"), "Unexpected message: \(message)")
        XCTAssertNil(job.localFiles.first?.importAttachmentId)

        let commands = await executor.executedCommands
        XCTAssertFalse(commands.contains { $0.contains("media regenerate") })
    }

    func testUploadFailureForOneFileStillProcessesTheNext() async throws {
        let executor = ScriptedCommandExecutor(responses: Self.baselineResponses + [
            // Exit 1 is not in the transport's transient-retry set.
            .init(commandContains: ["rsync", "a.jpg"], exitCode: 1),
            .init(commandContains: ["media import", "b.jpg"], stdout: ["102"])
        ])
        let runner = makeRunner(executor: executor)
        let fileA = try makeLocalFile(named: "a.jpg")
        let fileB = try makeLocalFile(named: "b.jpg")

        runner.start(profile: makeProfile(), fileItems: [fileA, fileB])
        try await waitUntilRunFinishes(runner)

        let job = try XCTUnwrap(runner.currentJob)
        XCTAssertEqual(job.step, .failed)
        XCTAssertEqual(job.localFiles.map(\.status), [.failed, .regenerated])

        let failed = try XCTUnwrap(job.localFiles.first)
        let message = try XCTUnwrap(failed.errorMessage)
        XCTAssertTrue(message.hasPrefix("Upload failed for a.jpg:"), "Unexpected message: \(message)")
        XCTAssertNil(failed.remotePath)

        let commands = await executor.executedCommands
        XCTAssertFalse(commands.contains { $0.contains("media import") && $0.contains("a.jpg") })
        XCTAssertTrue(commands.contains { $0.contains("media regenerate 102") })
    }

    // MARK: - AVIF sideload orchestration

    func testAvifJobPreparesContextSkipsPluginOnImportAndSideloadsNonJpegAsNoop() async throws {
        let executor = ScriptedCommandExecutor(responses: Self.baselineResponses + [
            .init(commandContains: ["wp_upload_dir"], stdout: ["/var/www/html/wp-content/uploads"]),
            .init(
                commandContains: ["aviflosu_quality"],
                stdout: [#"{"quality":70,"speed":5,"subsampling":"444","bit_depth":"10"}"#]
            ),
            .init(commandContains: ["aviflosu_convert_on_upload"], stdout: ["1"]),
            .init(commandContains: ["media import", "a.png"], stdout: ["101"])
        ])
        let runner = makeRunner(executor: executor)
        let file = try makeLocalFile(named: "a.png")

        runner.start(profile: makeProfile(avifEnabled: true), fileItems: [file])
        try await waitUntilRunFinishes(runner)

        let job = try XCTUnwrap(runner.currentJob)
        XCTAssertEqual(job.step, .finished)
        XCTAssertEqual(job.localFiles.first?.status, .sideloaded)
        XCTAssertEqual(job.localFiles.first?.avifCount, 0)

        let commands = await executor.executedCommands
        let importCommand = try XCTUnwrap(commands.first { $0.contains("media import") })
        XCTAssertTrue(importCommand.contains("--skip-plugins=avif-local-support"))
        let regenerateCommand = try XCTUnwrap(commands.first { $0.contains("media regenerate") })
        XCTAssertTrue(regenerateCommand.contains("--skip-plugins=avif-local-support"))

        let logText = runner.logLines.map(\.text)
        XCTAssertTrue(logText.contains { $0.contains("convert-on-upload is enabled") })
        XCTAssertTrue(logText.contains(
            "AVIF sideloading enabled (system encoder: quality 70; uploads dir /var/www/html/wp-content/uploads)."
        ))
        XCTAssertTrue(logText.contains("Skipped AVIF sideload for a.png (not a JPEG)."))
    }

    func testAvifJobFailsWhenUploadsBaseDirCannotBeResolved() async throws {
        let executor = ScriptedCommandExecutor(responses: Self.baselineResponses + [
            .init(commandContains: ["wp_upload_dir"], stdout: ["PHP Warning: something broke"])
        ])
        let runner = makeRunner(executor: executor)
        let file = try makeLocalFile(named: "a.jpg")

        runner.start(profile: makeProfile(avifEnabled: true), fileItems: [file])
        try await waitUntilRunFinishes(runner)

        let job = try XCTUnwrap(runner.currentJob)
        XCTAssertEqual(job.step, .failed)
        XCTAssertEqual(
            runner.blockingError,
            "Profile is incomplete: Could not resolve the WordPress uploads directory for AVIF sideloading"
        )

        // Preflight failed before any file work started.
        let commands = await executor.executedCommands
        XCTAssertFalse(commands.contains { $0.hasPrefix("rsync") })
    }
}
