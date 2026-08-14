import Foundation

struct SSHAuthContext: Sendable {
    var additionalSSHArgs: [String]
    var environment: [String: String]?
    var securityScopedAccesses: [SecurityScopedFileAccess] = []
    var temporaryAskPassAccount: String?

    func cleanup() {
        for access in securityScopedAccesses {
            access.stop()
        }
        if let temporaryAskPassAccount {
            try? KeychainService.deleteSecret(account: temporaryAskPassAccount)
        }
    }
}

struct ProfileTestResult: Sendable {
    var checks: [String]
    var success: Bool
}

@MainActor
final class SSHTransport {
    private let commandRunner: any CommandExecuting
    private let profileStore: ProfileStore
    private var knownHostsPathCache: String?

    init(profileStore: ProfileStore, commandRunner: any CommandExecuting = CommandRunner()) {
        self.profileStore = profileStore
        self.commandRunner = commandRunner
    }

    // MARK: - Auth context

    func makeAuthContext(for profile: ServerProfile) throws -> SSHAuthContext {
        try makeAuthContext(
            for: profile,
            password: profileStore.loadPassword(for: profile),
            keyPassphrase: profileStore.loadKeyPassphrase(for: profile),
            passwordMissingDetail: "Password auth selected, but no password is stored in Keychain"
        )
    }

    func makeAuthContext(for profile: ServerProfile, password: String?, keyPassphrase: String?) throws -> SSHAuthContext {
        try makeAuthContext(
            for: profile,
            password: password,
            keyPassphrase: keyPassphrase,
            passwordMissingDetail: "Password auth selected, but no password provided"
        )
    }

    // MARK: - Auth context (private)

    private func makeAuthContext(
        for profile: ServerProfile,
        password: String?,
        keyPassphrase: String?,
        passwordMissingDetail: String
    ) throws -> SSHAuthContext {
        switch profile.authType {
        case .sshKey:
            var args: [String] = []
            var access: SecurityScopedFileAccess?
            if let keyPath = profile.keyPath,
               !keyPath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            {
                access = try SecurityScopedFileAccess.start(
                    path: keyPath,
                    bookmarkData: profile.keyBookmarkData,
                    purpose: "SSH key file"
                )
                if let access {
                    args += ["-i", access.url.path]
                }
            }

            if let passphrase = keyPassphrase, !passphrase.isEmpty {
                let askPass = try makeAskPassEnv(secret: passphrase)
                args = ["-o", "BatchMode=no"] + args
                return SSHAuthContext(
                    additionalSSHArgs: args,
                    environment: askPass.environment,
                    securityScopedAccesses: [access].compactMap { $0 },
                    temporaryAskPassAccount: askPass.keychainAccount
                )
            }

            args = ["-o", "BatchMode=yes"] + args
            return SSHAuthContext(
                additionalSSHArgs: args,
                environment: nil,
                securityScopedAccesses: [access].compactMap { $0 },
                temporaryAskPassAccount: nil
            )

        case .password:
            guard let password, !password.isEmpty else {
                throw JobRunnerError.profileIncomplete(passwordMissingDetail)
            }
            let askPass = try makeAskPassEnv(secret: password)

            let args = [
                "-o", "BatchMode=no",
                "-o", "PreferredAuthentications=password,keyboard-interactive",
                "-o", "PubkeyAuthentication=no",
                "-o", "NumberOfPasswordPrompts=1"
            ]

            return SSHAuthContext(
                additionalSSHArgs: args,
                environment: askPass.environment,
                temporaryAskPassAccount: askPass.keychainAccount
            )
        }
    }

    // MARK: - SSH execution

    func runSSH(
        profile: ServerProfile,
        auth: SSHAuthContext,
        remoteCommand: String,
        writer: LogWriter?,
        onLine: (@MainActor @Sendable (CommandOutputStream, String) -> Void)? = nil
    ) async throws -> CommandResult {
        // Wrap in a login shell so the server's full PATH (including versioned PHP) is available.
        let loginCommand = "bash -lc \(shellSingleQuote(remoteCommand))"
        let args = sshBaseArgs(profile: profile, auth: auth) + [loginCommand]
        writer?.append("$ /usr/bin/ssh \(args.joined(separator: " "))")

        let spec = CommandSpec(
            executableURL: URL(fileURLWithPath: "/usr/bin/ssh"),
            arguments: args,
            environment: auth.environment,
            currentDirectoryURL: nil,
            displayName: "ssh"
        )

        let result = try await commandRunner.run(spec, onLine: onLine)

        guard result.exitCode == 0 else {
            let tail = result.stderrLines.suffix(3).joined(separator: " | ")
            throw CommandRunnerError.nonZeroExit(code: result.exitCode, stderrTail: tail)
        }

        return result
    }

    // MARK: - Rsync execution

    func runRsyncFile(
        profile: ServerProfile,
        auth: SSHAuthContext,
        localFileURL: URL,
        localFileBookmarkData: Data? = nil,
        remoteTargetPath: String,
        transferMode: RsyncTransferMode,
        writer: LogWriter?,
        onLine: (@MainActor @Sendable (CommandOutputStream, String) -> Void)? = nil
    ) async throws {
        let fileAccess = try SecurityScopedFileAccess.start(
            url: localFileURL,
            bookmarkData: localFileBookmarkData,
            purpose: "Selected upload file"
        )
        defer { fileAccess.stop() }

        try await runRsyncWithRetry(
            profile: profile,
            auth: auth,
            localPaths: [fileAccess.url.path],
            remoteTargetPath: remoteTargetPath,
            transferMode: transferMode,
            writer: writer,
            onLine: onLine
        )
    }

    /// Uploads several local files to one remote directory in a single rsync
    /// invocation. Sources must be app-container files (no security scope).
    func runRsyncFiles(
        profile: ServerProfile,
        auth: SSHAuthContext,
        localFileURLs: [URL],
        remoteTargetPath: String,
        transferMode: RsyncTransferMode,
        writer: LogWriter?,
        onLine: (@MainActor @Sendable (CommandOutputStream, String) -> Void)? = nil
    ) async throws {
        guard !localFileURLs.isEmpty else { return }

        try await runRsyncWithRetry(
            profile: profile,
            auth: auth,
            localPaths: localFileURLs.map(\.path),
            remoteTargetPath: remoteTargetPath,
            transferMode: transferMode,
            writer: writer,
            onLine: onLine
        )
    }

    private func runRsyncWithRetry(
        profile: ServerProfile,
        auth: SSHAuthContext,
        localPaths: [String],
        remoteTargetPath: String,
        transferMode: RsyncTransferMode,
        writer: LogWriter?,
        onLine: (@MainActor @Sendable (CommandOutputStream, String) -> Void)? = nil
    ) async throws {
        do {
            try await attemptRsync(
                profile: profile, auth: auth,
                localPaths: localPaths, remoteTargetPath: remoteTargetPath,
                transferMode: transferMode,
                writer: writer, onLine: onLine
            )
        } catch let error as CommandRunnerError {
            guard case .nonZeroExit(let code, _) = error,
                  isTransientRsyncExitCode(code)
            else {
                throw error
            }

            writer?.append("Transient rsync error (exit \(code)), retrying in 2 seconds…")
            try await Task.sleep(for: .seconds(2))

            try await attemptRsync(
                profile: profile, auth: auth,
                localPaths: localPaths, remoteTargetPath: remoteTargetPath,
                transferMode: transferMode,
                writer: writer, onLine: onLine
            )
        }
    }

    private func attemptRsync(
        profile: ServerProfile,
        auth: SSHAuthContext,
        localPaths: [String],
        remoteTargetPath: String,
        transferMode: RsyncTransferMode,
        writer: LogWriter?,
        onLine: (@MainActor @Sendable (CommandOutputStream, String) -> Void)? = nil
    ) async throws {
        let arguments = makeRsyncArguments(
            profile: profile,
            auth: auth,
            localPaths: localPaths,
            remoteTargetPath: remoteTargetPath,
            transferMode: transferMode
        )

        let result = try await runRsync(
            arguments: arguments,
            environment: auth.environment,
            writer: writer,
            onLine: onLine
        )

        guard result.exitCode == 0 else {
            let stderrTail = result.stderrLines.suffix(3).joined(separator: " | ")
            throw CommandRunnerError.nonZeroExit(code: result.exitCode, stderrTail: stderrTail)
        }
    }

    private func isTransientRsyncExitCode(_ code: Int32) -> Bool {
        // 12: Error in rsync protocol data stream
        // 23: Partial transfer due to error
        // 30: Timeout in data send/receive
        // 255: SSH connection error
        [12, 23, 30, 255].contains(code)
    }

    // MARK: - Remote helpers

    func fetchRemoteHomeDirectory(
        profile: ServerProfile,
        auth: SSHAuthContext,
        writer: LogWriter?,
        onLine: (@MainActor @Sendable (CommandOutputStream, String) -> Void)? = nil
    ) async throws -> String {
        let result = try await runSSH(
            profile: profile,
            auth: auth,
            remoteCommand: "printf '%s' \"$HOME\"",
            writer: writer,
            onLine: onLine
        )
        let home = result.stdoutLines.last?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if home.isEmpty {
            throw JobRunnerError.profileIncomplete("Could not resolve remote $HOME path")
        }
        return home
    }

    func fetchRemoteFileSize(
        profile: ServerProfile,
        auth: SSHAuthContext,
        remotePath: String,
        writer: LogWriter?,
        onLine: (@MainActor @Sendable (CommandOutputStream, String) -> Void)? = nil
    ) async throws -> Int64 {
        let command = "(stat -c%s \(shellSingleQuote(remotePath)) 2>/dev/null || stat -f%z \(shellSingleQuote(remotePath)) 2>/dev/null)"
        let result = try await runSSH(
            profile: profile,
            auth: auth,
            remoteCommand: command,
            writer: writer,
            onLine: onLine
        )

        guard let line = result.stdoutLines
            .map({ $0.trimmingCharacters(in: .whitespacesAndNewlines) })
            .last,
              let value = Int64(line)
        else {
            throw JobRunnerError.profileIncomplete("Could not parse remote file size for \(remotePath)")
        }

        return value
    }

    /// Fetches the sizes of several remote files in one ssh round trip.
    /// Returns one entry per requested path, in order; nil means the file
    /// is missing or its size could not be read.
    func fetchRemoteFileSizes(
        profile: ServerProfile,
        auth: SSHAuthContext,
        remotePaths: [String],
        writer: LogWriter?,
        onLine: (@MainActor @Sendable (CommandOutputStream, String) -> Void)? = nil
    ) async throws -> [Int64?] {
        guard !remotePaths.isEmpty else { return [] }

        // One line of output per path; "missing" keeps the line count stable
        // when a file is absent so positions still align with remotePaths.
        let command = remotePaths
            .map { path in
                let quoted = shellSingleQuote(path)
                return "(stat -c%s \(quoted) 2>/dev/null || stat -f%z \(quoted) 2>/dev/null || echo missing)"
            }
            .joined(separator: "; ")

        let result = try await runSSH(
            profile: profile,
            auth: auth,
            remoteCommand: command,
            writer: writer,
            onLine: onLine
        )

        // Login-shell noise (motd, profile output) can precede the stat lines.
        let lines = result.stdoutLines
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .suffix(remotePaths.count)

        guard lines.count == remotePaths.count else {
            throw JobRunnerError.profileIncomplete(
                "Could not read remote file sizes (expected \(remotePaths.count) results, got \(lines.count))"
            )
        }

        return lines.map { Int64($0) }
    }

    // MARK: - Shared preflight checks (S6)

    func runPreflightChecks(
        profile: ServerProfile,
        auth: SSHAuthContext,
        writer: LogWriter?,
        onLine: (@MainActor @Sendable (CommandOutputStream, String) -> Void)? = nil
    ) async throws {
        _ = try await runSSH(
            profile: profile,
            auth: auth,
            remoteCommand: "uname -a",
            writer: writer,
            onLine: onLine
        )
        _ = try await runSSH(
            profile: profile,
            auth: auth,
            remoteCommand: "command -v wp",
            writer: writer,
            onLine: onLine
        )
        _ = try await runSSH(
            profile: profile,
            auth: auth,
            remoteCommand: "command -v rsync",
            writer: writer,
            onLine: onLine
        )
        _ = try await runSSH(
            profile: profile,
            auth: auth,
            remoteCommand: wpCommand("wp --path=\(shellSingleQuote(profile.wpRootPath)) core is-installed"),
            writer: writer,
            onLine: onLine
        )
    }

    func cancelActiveProcess() async {
        await commandRunner.cancelActiveProcess()
    }

    // MARK: - Private helpers

    /// One builder for the connection options shared by ssh and rsync's -e
    /// transport — an option added to one path but not the other would mean
    /// the two connect with different security settings.
    private func sharedSSHOptions(profile: ServerProfile, auth: SSHAuthContext) -> [String] {
        var args = [
            "-p", "\(profile.port)",
            "-o", "StrictHostKeyChecking=accept-new",
            "-o", "ConnectTimeout=10",
            "-o", "ConnectionAttempts=1"
        ]
        if let knownHostsPath = knownHostsPath() {
            args += ["-o", "UserKnownHostsFile=\(knownHostsPath)"]
        }
        args += auth.additionalSSHArgs
        return args
    }

    func sshBaseArgs(profile: ServerProfile, auth: SSHAuthContext) -> [String] {
        sharedSSHOptions(profile: profile, auth: auth) + ["\(profile.username)@\(profile.host)"]
    }

    private func rsyncSSHTransport(profile: ServerProfile, auth: SSHAuthContext) -> String {
        // Note: this string is split by rsync's own tokenizer, not a shell.
        // openrsync handles plain quotes but not escaped ones, so paths
        // containing an apostrophe cannot be represented reliably here.
        (["ssh"] + sharedSSHOptions(profile: profile, auth: auth))
            .map(shellSingleQuote)
            .joined(separator: " ")
    }

    enum RsyncTransferMode: Sendable {
        /// Staging uploads into a fresh per-job directory: keep a partial file
        /// from an interrupted attempt so the retry resumes via delta transfer.
        /// Never uses --append — a mismatched prefix must be repaired, and the
        /// delta algorithm's checksums do that where append would corrupt.
        case resume
        /// Pushes into live directories (e.g. the WordPress uploads tree):
        /// whole-file replace through rsync's temp-file-and-rename default,
        /// leaving no partial files behind on failure.
        case overwrite
    }

    // Internal for tests (source ordering / remote-target-last invariants).
    func makeRsyncArguments(
        profile: ServerProfile,
        auth: SSHAuthContext,
        localPaths: [String],
        remoteTargetPath: String,
        transferMode: RsyncTransferMode
    ) -> [String] {
        var arguments = ["-az"]

        switch transferMode {
        case .resume:
            arguments.append("--partial")
        case .overwrite:
            break
        }
        arguments.append("--progress")

        arguments += ["-e", rsyncSSHTransport(profile: profile, auth: auth)]
        arguments += localPaths
        arguments.append("\(profile.username)@\(profile.host):\(shellSingleQuote(remoteTargetPath))")
        return arguments
    }

    private func runRsync(
        arguments: [String],
        environment: [String: String]?,
        writer: LogWriter?,
        onLine: (@MainActor @Sendable (CommandOutputStream, String) -> Void)?
    ) async throws -> CommandResult {
        writer?.append("$ /usr/bin/rsync \(arguments.joined(separator: " "))")

        let spec = CommandSpec(
            executableURL: URL(fileURLWithPath: "/usr/bin/rsync"),
            arguments: arguments,
            environment: environment,
            currentDirectoryURL: nil,
            displayName: "rsync"
        )
        return try await commandRunner.run(spec, onLine: onLine)
    }

    // Use the app binary itself as SSH_ASKPASS. The sandbox blocks exec of dynamically-
    // created shell scripts but always allows exec of signed binaries in the app bundle.
    // main.swift detects WP_ASKPASS_MODE=1 and reads a temporary Keychain secret before SwiftUI starts.
    private func makeAskPassEnv(secret: String) throws -> (environment: [String: String], keychainAccount: String) {
        guard let executablePath = Bundle.main.executablePath else {
            throw JobRunnerError.authSetupFailed("Could not locate app binary for SSH authentication")
        }
        let account = "askpass-\(UUID().uuidString)"
        try KeychainService.setSecret(secret, account: account)
        return ([
            "SSH_ASKPASS": executablePath,
            "SSH_ASKPASS_REQUIRE": "force",
            "DISPLAY": "1",
            "WP_ASKPASS_MODE": "1",
            "WP_ASKPASS_KEYCHAIN_ACCOUNT": account
        ], account)
    }

    private func knownHostsPath() -> String? {
        if let knownHostsPathCache {
            return knownHostsPathCache
        }

        let knownHostsFileURL = AppPaths.appSupportDirectory
            .appendingPathComponent("known_hosts", isDirectory: false)
        let fileManager = FileManager.default
        let parent = knownHostsFileURL.deletingLastPathComponent()
        AppPaths.ensureDirectory(parent)

        if !fileManager.fileExists(atPath: knownHostsFileURL.path) {
            fileManager.createFile(atPath: knownHostsFileURL.path, contents: Data())
        }

        try? fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: knownHostsFileURL.path)
        knownHostsPathCache = knownHostsFileURL.path
        return knownHostsPathCache
    }
}

// MARK: - Shared utilities used by JobRunner

func resolvedStagingRoot(profile: ServerProfile, homeDirectory: String) -> String {
    if profile.remoteStagingRoot == "~" {
        return homeDirectory
    }

    if profile.remoteStagingRoot.hasPrefix("~/") {
        let suffix = String(profile.remoteStagingRoot.dropFirst(2))
        return "\(homeDirectory)/\(suffix)"
    }

    return profile.remoteStagingRoot
}
