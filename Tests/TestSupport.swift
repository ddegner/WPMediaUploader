import Foundation
@testable import WordpressMediaUploaderApp

/// Shared no-op secret store so tests never touch the real Keychain.
struct NoopSecretStore: SecretStoring {
    func setSecret(_ secret: String, account: String) throws {}
    func getSecret(account: String) throws -> String? { nil }
    func deleteSecret(account: String) throws {}
}

/// Factories for hermetic store/runner instances. `swift test` runs
/// unsandboxed, so a bare ProfileStore()/JobStore() would read and write the
/// developer's real Keychain and Application Support — never do that.
enum TestSupport {
    static func temporaryFileURL(_ name: String) -> URL {
        URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("wp-uploader-tests-\(UUID().uuidString)-\(name)", isDirectory: false)
    }

    static func temporaryDirectory(_ name: String) -> URL {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("wp-uploader-tests-\(UUID().uuidString)-\(name)", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    @MainActor
    static func makeProfileStore() -> ProfileStore {
        ProfileStore(
            secretStore: NoopSecretStore(),
            profilesFileURL: temporaryFileURL("profiles.json")
        )
    }

    @MainActor
    static func makeJobStore() -> JobStore {
        JobStore(jobsFileURL: temporaryFileURL("jobs.json"))
    }

    @MainActor
    static func makeRunner(transport: SSHTransport? = nil) -> JobRunner {
        JobRunner(
            profileStore: makeProfileStore(),
            jobStore: makeJobStore(),
            transport: transport,
            logsDirectory: temporaryDirectory("logs")
        )
    }
}
