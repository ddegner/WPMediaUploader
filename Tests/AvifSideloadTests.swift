import Foundation
import XCTest
@testable import WordpressMediaUploaderApp

final class AvifSideloadTests: XCTestCase {
    // MARK: - Codable migration safety

    func testDecodingLegacyProfileWithoutAvifToggleStillSucceeds() throws {
        let id = UUID()
        let json = """
        {
          "id": "\(id.uuidString)",
          "name": "Production",
          "host": "example.com",
          "port": 22,
          "username": "deploy",
          "authType": "password",
          "wpRootPath": "/var/www/html",
          "remoteStagingRoot": "~/wp-media-import",
          "keepRemoteFiles": false
        }
        """

        let decoded = try JSONDecoder().decode(ServerProfile.self, from: Data(json.utf8))
        XCTAssertNil(decoded.generateAvifsLocally)
        XCTAssertFalse(decoded.generateAvifsLocallyEnabled)
    }

    func testDecodingLegacyJobWithoutAvifFieldsStillSucceeds() throws {
        let jobId = UUID()
        let fileId = UUID()
        let json = """
        {
          "id": "\(jobId.uuidString)",
          "profileId": "\(UUID().uuidString)",
          "createdAt": 0,
          "remoteJobDir": "/tmp/job",
          "localFiles": [
            {
              "id": "\(fileId.uuidString)",
              "localURL": "file:///tmp/a.jpg",
              "filename": "a.jpg",
              "sizeBytes": 10,
              "status": "regenerated"
            }
          ],
          "step": "finished",
          "uploadProgress": 1,
          "importProgress": 1,
          "logsPath": "/tmp/job.log",
          "importedIds": [12]
        }
        """

        let decoded = try JSONDecoder().decode(Job.self, from: Data(json.utf8))
        XCTAssertNil(decoded.avifSideloadEnabled)
        XCTAssertFalse(decoded.avifSideloadOn)
        XCTAssertNil(decoded.localFiles.first?.avifCount)
    }

    func testJobAndFileAvifFieldsRoundTrip() throws {
        var file = FileItem(
            localURL: URL(fileURLWithPath: "/tmp/a.jpg"),
            filename: "a.jpg",
            sizeBytes: 10
        )
        file.status = .sideloaded
        file.avifCount = 9

        var job = Job(profileId: UUID(), remoteJobDir: "/tmp/job", files: [file], logsPath: "/tmp/job.log")
        job.avifSideloadEnabled = true

        let data = try JSONEncoder().encode(job)
        let decoded = try JSONDecoder().decode(Job.self, from: data)

        XCTAssertTrue(decoded.avifSideloadOn)
        XCTAssertEqual(decoded.localFiles.first?.status, .sideloaded)
        XCTAssertEqual(decoded.localFiles.first?.avifCount, 9)
    }

    // MARK: - JPEG source gate

    func testIsJpegSourceExtension() {
        XCTAssertTrue(isJpegSourceExtension(URL(fileURLWithPath: "/tmp/a.jpg")))
        XCTAssertTrue(isJpegSourceExtension(URL(fileURLWithPath: "/tmp/a.JPEG")))
        XCTAssertTrue(isJpegSourceExtension(URL(fileURLWithPath: "/tmp/a.jpe")))
        XCTAssertFalse(isJpegSourceExtension(URL(fileURLWithPath: "/tmp/a.png")))
        XCTAssertFalse(isJpegSourceExtension(URL(fileURLWithPath: "/tmp/a.avif")))
        XCTAssertFalse(isJpegSourceExtension(URL(fileURLWithPath: "/tmp/a.pdf")))
    }

    // MARK: - Multi-source rsync arguments

    @MainActor
    func testMakeRsyncArgumentsKeepsSourceOrderAndRemoteTargetLast() {
        let transport = makeTransport()

        var profile = ServerProfile.default
        profile.host = "example.com"
        profile.username = "deploy"

        let auth = SSHAuthContext(additionalSSHArgs: [], environment: nil)
        let arguments = transport.makeRsyncArguments(
            profile: profile,
            auth: auth,
            localPaths: ["/tmp/a.avif", "/tmp/b.avif", "/tmp/c.avif"],
            remoteTargetPath: "/var/www/uploads/2026/08/",
            transferMode: .overwrite
        )

        let sourceIndices = ["/tmp/a.avif", "/tmp/b.avif", "/tmp/c.avif"].compactMap { arguments.firstIndex(of: $0) }
        XCTAssertEqual(sourceIndices.count, 3)
        XCTAssertEqual(sourceIndices, sourceIndices.sorted())
        XCTAssertEqual(arguments.last, "deploy@example.com:'/var/www/uploads/2026/08/'")
    }

    /// Overwrite mode pushes into live directories: it must never append to
    /// or keep partial versions of files that are already being served.
    @MainActor
    func testMakeRsyncArgumentsOverwriteModeNeverAppends() {
        let transport = makeTransport()
        let arguments = transport.makeRsyncArguments(
            profile: .default,
            auth: SSHAuthContext(additionalSSHArgs: [], environment: nil),
            localPaths: ["/tmp/a.avif"],
            remoteTargetPath: "/var/www/uploads/2026/08/",
            transferMode: .overwrite
        )

        XCTAssertFalse(arguments.contains("--append"))
        XCTAssertFalse(arguments.contains("--append-verify"))
        XCTAssertFalse(arguments.contains("--partial"))
        XCTAssertTrue(arguments.contains("--progress"))
    }

    /// Resume mode keeps partials for staging retries but must still rely on
    /// delta transfer (not --append) so a bad prefix gets repaired.
    @MainActor
    func testMakeRsyncArgumentsResumeModeKeepsPartialsWithoutAppend() {
        let transport = makeTransport()
        let arguments = transport.makeRsyncArguments(
            profile: .default,
            auth: SSHAuthContext(additionalSSHArgs: [], environment: nil),
            localPaths: ["/tmp/a.jpg"],
            remoteTargetPath: "/home/deploy/wp-media-import/job/incoming/",
            transferMode: .resume
        )

        XCTAssertTrue(arguments.contains("--partial"))
        XCTAssertFalse(arguments.contains("--append"))
        XCTAssertFalse(arguments.contains("--append-verify"))
    }

    @MainActor
    private func makeTransport() -> SSHTransport {
        SSHTransport(profileStore: TestSupport.makeProfileStore())
    }
}
