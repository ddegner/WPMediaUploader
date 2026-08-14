import Foundation
import XCTest
@testable import WordpressMediaUploaderApp

// MARK: - AskPass helper protocol

final class AskPassTests: XCTestCase {
    func testReturnsSecretForValidInvocation() {
        let secret = AskPass.response(
            environment: ["WP_ASKPASS_MODE": "1", "WP_ASKPASS_KEYCHAIN_ACCOUNT": "askpass-abc"],
            secretLookup: { account in
                XCTAssertEqual(account, "askpass-abc")
                return "s3cret"
            }
        )
        XCTAssertEqual(secret, "s3cret")
    }

    func testReturnsNilWhenModeFlagAbsent() {
        let secret = AskPass.response(
            environment: ["WP_ASKPASS_KEYCHAIN_ACCOUNT": "askpass-abc"],
            secretLookup: { _ in "s3cret" }
        )
        XCTAssertNil(secret)
    }

    func testReturnsNilWhenAccountMissingOrEmpty() {
        XCTAssertNil(AskPass.response(
            environment: ["WP_ASKPASS_MODE": "1"],
            secretLookup: { _ in "s3cret" }
        ))
        XCTAssertNil(AskPass.response(
            environment: ["WP_ASKPASS_MODE": "1", "WP_ASKPASS_KEYCHAIN_ACCOUNT": ""],
            secretLookup: { _ in "s3cret" }
        ))
    }

    func testReturnsNilWhenLookupFailsOrFindsNothing() {
        struct Boom: Error {}
        XCTAssertNil(AskPass.response(
            environment: ["WP_ASKPASS_MODE": "1", "WP_ASKPASS_KEYCHAIN_ACCOUNT": "askpass-x"],
            secretLookup: { _ in throw Boom() }
        ))
        XCTAssertNil(AskPass.response(
            environment: ["WP_ASKPASS_MODE": "1", "WP_ASKPASS_KEYCHAIN_ACCOUNT": "askpass-x"],
            secretLookup: { _ in nil }
        ))
    }
}

// MARK: - JobStore pruning, scoped clear, log deletion

final class JobStoreTests: XCTestCase {
    @MainActor
    private func makeJob(profileId: UUID, logPath: String, createdAt: Date = .now) -> Job {
        var job = Job(
            profileId: profileId,
            remoteJobDir: "/tmp/job",
            files: [FileItem(localURL: URL(fileURLWithPath: "/tmp/a.jpg"), filename: "a.jpg", sizeBytes: 1)],
            logsPath: logPath
        )
        job.createdAt = createdAt
        return job
    }

    @MainActor
    func testClearScopedToProfileRemovesOnlyThatProfilesJobsAndLogs() throws {
        let store = TestSupport.makeJobStore()
        let profileA = UUID()
        let profileB = UUID()

        let logA = TestSupport.temporaryFileURL("a.log")
        let logB = TestSupport.temporaryFileURL("b.log")
        try Data("a".utf8).write(to: logA)
        try Data("b".utf8).write(to: logB)

        store.upsert(makeJob(profileId: profileA, logPath: logA.path))
        store.upsert(makeJob(profileId: profileB, logPath: logB.path))

        store.clear(profileId: profileA)

        XCTAssertEqual(store.jobs.map(\.profileId), [profileB])
        XCTAssertFalse(FileManager.default.fileExists(atPath: logA.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: logB.path))
    }

    @MainActor
    func testClearAllRemovesEverything() throws {
        let store = TestSupport.makeJobStore()
        let log = TestSupport.temporaryFileURL("all.log")
        try Data("x".utf8).write(to: log)
        store.upsert(makeJob(profileId: UUID(), logPath: log.path))

        store.clear()

        XCTAssertTrue(store.jobs.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: log.path))
    }

    @MainActor
    func testUpsertPrunesToMaxAndDeletesPrunedLogs() throws {
        let store = TestSupport.makeJobStore()
        let profile = UUID()

        let oldestLog = TestSupport.temporaryFileURL("oldest.log")
        try Data("old".utf8).write(to: oldestLog)
        store.upsert(makeJob(profileId: profile, logPath: oldestLog.path, createdAt: .distantPast))

        for index in 0..<100 {
            store.upsert(makeJob(
                profileId: profile,
                logPath: TestSupport.temporaryFileURL("job-\(index).log").path,
                createdAt: Date(timeIntervalSinceNow: Double(index))
            ))
        }

        XCTAssertEqual(store.jobs.count, 100)
        XCTAssertFalse(store.jobs.contains { $0.logsPath == oldestLog.path })
        XCTAssertFalse(FileManager.default.fileExists(atPath: oldestLog.path))
    }
}

// MARK: - Path canonicalization

final class PathHelperTests: XCTestCase {
    func testEnsureNoTrailingSlashStripsAllTrailingSlashes() {
        XCTAssertEqual(ensureNoTrailingSlash("a//"), "a")
        XCTAssertEqual(ensureNoTrailingSlash("/var/www///"), "/var/www")
        XCTAssertEqual(ensureNoTrailingSlash("/"), "/")
        XCTAssertEqual(ensureNoTrailingSlash("a"), "a")
    }
}

// MARK: - CSV formula injection

final class CSVInjectionTests: XCTestCase {
    @MainActor
    func testLeadingFormulaCharactersAreDefused() {
        var file = FileItem(
            localURL: URL(fileURLWithPath: "/tmp/=SUM(A1:A9).jpg"),
            filename: "=SUM(A1:A9).jpg",
            sizeBytes: 10
        )
        file.status = .failed
        file.errorMessage = "@remote said no"

        let job = Job(profileId: UUID(), remoteJobDir: "/tmp/job", files: [file], logsPath: "/tmp/job.log")
        let csv = ReportBuilder.csvReport(for: job)
        let dataRow = csv.split(separator: "\n")[1]

        XCTAssertTrue(dataRow.hasPrefix("'=SUM"), "leading = must be defused, got: \(dataRow)")
        XCTAssertTrue(dataRow.contains("'@remote said no"), "leading @ must be defused, got: \(dataRow)")
    }
}

// MARK: - ProfileValidation, directly

final class ProfileValidationTests: XCTestCase {
    private func makeProfile() -> ServerProfile {
        var profile = ServerProfile.default
        profile.name = "Prod"
        profile.host = "example.com"
        profile.username = "deploy"
        profile.port = 22
        profile.wpRootPath = "/var/www/html"
        profile.remoteStagingRoot = "~/wp-media-import"
        profile.authType = .password
        return profile
    }

    func testValidPasswordProfilePasses() {
        XCTAssertNil(ProfileValidation.firstError(for: makeProfile(), password: "pw", context: .editor))
        XCTAssertNil(ProfileValidation.firstError(for: makeProfile(), password: "pw", context: .execution))
    }

    func testEditorRequiresName() {
        var profile = makeProfile()
        profile.name = "   "
        XCTAssertEqual(
            ProfileValidation.firstError(for: profile, password: "pw", context: .editor),
            "Profile name is required"
        )
        // Execution context intentionally skips the name check.
        XCTAssertNil(ProfileValidation.firstError(for: profile, password: "pw", context: .execution))
    }

    func testEmptyStagingRootFails() {
        var profile = makeProfile()
        profile.remoteStagingRoot = ""
        XCTAssertEqual(
            ProfileValidation.firstError(for: profile, password: "pw", context: .editor),
            "Remote staging root is required"
        )
    }

    func testMissingPasswordMessageDependsOnContext() {
        let profile = makeProfile()
        XCTAssertEqual(
            ProfileValidation.firstError(for: profile, password: " ", context: .editor),
            "Password is required"
        )
        XCTAssertEqual(
            ProfileValidation.firstError(for: profile, password: nil, context: .execution),
            "Password auth selected, but no password is stored in Keychain"
        )
    }

    func testSSHKeyPathMustExist() {
        var profile = makeProfile()
        profile.authType = .sshKey
        profile.keyPath = "/nonexistent/key-\(UUID().uuidString)"
        profile.keyBookmarkData = nil
        let error = ProfileValidation.firstError(for: profile, password: "", context: .editor)
        XCTAssertEqual(error, "SSH key file not found at \(profile.keyPath!)")
    }

    func testCanSaveMirrorsEditorValidation() {
        XCTAssertTrue(ProfileValidation.canSave(profile: makeProfile(), password: "pw"))
        var broken = makeProfile()
        broken.host = ""
        XCTAssertFalse(ProfileValidation.canSave(profile: broken, password: "pw"))
    }
}
