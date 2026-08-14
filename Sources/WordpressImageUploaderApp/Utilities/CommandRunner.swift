import Foundation

enum CommandOutputStream: Sendable {
    case stdout
    case stderr
}

struct CommandSpec: Sendable {
    var executableURL: URL
    var arguments: [String]
    var environment: [String: String]?
    var currentDirectoryURL: URL?
    var displayName: String
}

struct CommandResult: Sendable {
    var exitCode: Int32
    var stdoutLines: [String]
    var stderrLines: [String]
}

enum CommandRunnerError: Error, LocalizedError {
    case launchFailed(String)
    case nonZeroExit(code: Int32, stderrTail: String)
    case idleTimeout(seconds: Int)

    var errorDescription: String? {
        switch self {
        case let .launchFailed(message):
            return "Failed to launch command: \(message)"
        case let .nonZeroExit(code, stderrTail):
            if stderrTail.isEmpty {
                return "Command failed with exit code \(code)."
            }
            return "Command failed with exit code \(code): \(stderrTail)"
        case let .idleTimeout(seconds):
            return "Command produced no output for \(seconds) seconds and was terminated."
        }
    }
}

/// Tracks output activity for the idle watchdog. An idle timeout (rather
/// than a wall-clock one) lets long transfers run as long as they keep
/// producing progress lines, while still reaping a wedged ssh/rsync/wp-cli.
private actor CommandActivityMonitor {
    private var lastActivity = ContinuousClock.now
    private(set) var timedOut = false

    func touch() { lastActivity = .now }
    func markTimedOut() { timedOut = true }
    func idleDuration() -> Duration { lastActivity.duration(to: .now) }
}

private actor ProcessTermination {
    private var exitCode: Int32?
    private var continuations: [CheckedContinuation<Int32, Never>] = []

    func finish(_ code: Int32) {
        guard exitCode == nil else { return }
        exitCode = code
        let pending = continuations
        continuations.removeAll()
        for continuation in pending {
            continuation.resume(returning: code)
        }
    }

    func wait() async -> Int32 {
        if let exitCode {
            return exitCode
        }
        return await withCheckedContinuation { continuation in
            continuations.append(continuation)
        }
    }
}

/// Seam for tests: SSHTransport talks to its process runner through this
/// protocol so command execution can be stubbed or recorded.
protocol CommandExecuting: Actor {
    func run(
        _ spec: CommandSpec,
        idleTimeout: Duration,
        onLine: (@MainActor @Sendable (CommandOutputStream, String) -> Void)?
    ) async throws -> CommandResult
    func cancelActiveProcess()
}

extension CommandExecuting {
    func run(
        _ spec: CommandSpec,
        onLine: (@MainActor @Sendable (CommandOutputStream, String) -> Void)? = nil
    ) async throws -> CommandResult {
        try await run(spec, idleTimeout: CommandRunner.defaultIdleTimeout, onLine: onLine)
    }
}

actor CommandRunner: CommandExecuting {
    private var activeProcesses: [ObjectIdentifier: Process] = [:]

    /// Default idle timeout: comfortably above the 600 s remote-side
    /// `timeout` wrapper on wp-cli commands, so the local watchdog only
    /// fires when a command is truly wedged (no output at all).
    static let defaultIdleTimeout: Duration = .seconds(900)

    func run(
        _ spec: CommandSpec,
        idleTimeout: Duration = CommandRunner.defaultIdleTimeout,
        onLine: (@MainActor @Sendable (CommandOutputStream, String) -> Void)? = nil
    ) async throws -> CommandResult {
        let process = Process()
        process.executableURL = spec.executableURL
        process.arguments = spec.arguments

        if let environment = spec.environment {
            process.environment = ProcessInfo.processInfo.environment.merging(environment) { _, new in new }
        }

        if let cwd = spec.currentDirectoryURL {
            process.currentDirectoryURL = cwd
        }

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe
        let termination = ProcessTermination()
        process.terminationHandler = { finished in
            Task {
                await termination.finish(finished.terminationStatus)
            }
        }

        let processID = ObjectIdentifier(process)
        activeProcesses[processID] = process
        defer { activeProcesses[processID] = nil }

        do {
            try process.run()
        } catch {
            throw CommandRunnerError.launchFailed(error.localizedDescription)
        }

        let monitor = CommandActivityMonitor()

        return try await withTaskCancellationHandler {
            let watchdog = Task {
                while true {
                    try? await Task.sleep(for: .seconds(10))
                    if Task.isCancelled { return }
                    if await monitor.idleDuration() > idleTimeout {
                        await monitor.markTimedOut()
                        process.terminate()
                        return
                    }
                }
            }
            defer { watchdog.cancel() }

            // Drain both pipes concurrently using structured async I/O.
            // Each sequence reaches EOF after the process exits and closes
            // its write ends, so no blocking calls or readabilityHandler races.
            async let stdoutResult = Self.collectLines(
                from: stdoutPipe.fileHandleForReading, stream: .stdout, monitor: monitor, onLine: onLine
            )
            async let stderrResult = Self.collectLines(
                from: stderrPipe.fileHandleForReading, stream: .stderr, monitor: monitor, onLine: onLine
            )
            async let exitCodeResult = termination.wait()

            let stdoutLines = try await stdoutResult
            let stderrLines = try await stderrResult
            let exitCode = await exitCodeResult

            if await monitor.timedOut {
                throw CommandRunnerError.idleTimeout(seconds: Int(idleTimeout.components.seconds))
            }

            try Task.checkCancellation()
            return CommandResult(
                exitCode: exitCode,
                stdoutLines: stdoutLines,
                stderrLines: stderrLines
            )
        } onCancel: {
            process.terminate()
        }
    }

    func cancelActiveProcess() {
        for process in activeProcesses.values {
            process.terminate()
        }
    }

    /// Reads complete lines from a file handle using async byte sequences.
    /// Returns when the handle reaches EOF (i.e. the process has exited).
    /// Each line is delivered to the main actor before the next is read, so
    /// per-stream ordering survives all the way into the UI and the log.
    private nonisolated static func collectLines(
        from handle: FileHandle,
        stream: CommandOutputStream,
        monitor: CommandActivityMonitor,
        onLine: (@MainActor @Sendable (CommandOutputStream, String) -> Void)?
    ) async throws -> [String] {
        var lines: [String] = []
        for try await line in handle.bytes.lines {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            lines.append(trimmed)
            await monitor.touch()
            if let onLine {
                await onLine(stream, trimmed)
            }
        }
        return lines
    }
}
