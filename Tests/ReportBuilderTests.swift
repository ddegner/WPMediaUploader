import XCTest
@testable import WordpressMediaUploaderApp

final class ReportBuilderTests: XCTestCase {
    func testCSVReportEscapesCommasAndQuotes() {
        var file = FileItem(localURL: URL(fileURLWithPath: "/tmp/img,\"quote\".jpg"), filename: "img,\"quote\".jpg", sizeBytes: 1234)
        file.status = .failed
        file.errorMessage = "Bad, \"error\""

        var job = Job(
            profileId: UUID(),
            remoteJobDir: "/tmp/remote-job",
            files: [file],
            logsPath: "/tmp/log.txt"
        )
        job.step = .failed

        let csv = ReportBuilder.csvReport(for: job)
        XCTAssertTrue(csv.contains("\"img,\"\"quote\"\".jpg\""))
        XCTAssertTrue(csv.contains("\"Bad, \"\"error\"\"\""))
    }

    func testJSONReportContainsExpectedCoreFields() throws {
        var file = FileItem(localURL: URL(fileURLWithPath: "/tmp/a.jpg"), filename: "a.jpg", sizeBytes: 10)
        file.status = .regenerated
        file.importAttachmentId = 42

        var job = Job(
            profileId: UUID(),
            remoteJobDir: "/tmp/job",
            files: [file],
            logsPath: "/tmp/log.txt"
        )
        job.step = .finished
        job.importedIds = [42]

        let json = try ReportBuilder.jsonReport(for: job)
        XCTAssertTrue(json.contains("\"status\" : \"finished\""))
        XCTAssertTrue(json.contains("\"importedIds\""))
        XCTAssertTrue(json.contains("\"attachmentId\" : 42"))
    }

    func testJSONReportCreatedAtIsISO8601UTC() throws {
        let job = Job(
            profileId: UUID(),
            remoteJobDir: "/tmp/job",
            files: [],
            logsPath: "/tmp/log.txt"
        )

        let json = try ReportBuilder.jsonReport(for: job)
        // Pin the timestamp shape so report format stays compatible:
        // "createdAt" : "2026-07-07T21:30:00Z"
        XCTAssertNotNil(
            json.firstMatch(of: /"createdAt" : "\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z"/),
            "Unexpected createdAt format in: \(json)"
        )
    }

    func testTextReportContainsFileStatus() {
        var file = FileItem(localURL: URL(fileURLWithPath: "/tmp/a.jpg"), filename: "a.jpg", sizeBytes: 10)
        file.status = .imported

        let job = Job(
            profileId: UUID(),
            remoteJobDir: "/tmp/job",
            files: [file],
            logsPath: "/tmp/log.txt"
        )

        let text = ReportBuilder.textReport(for: job)
        XCTAssertTrue(text.contains("a.jpg: imported"))
    }

    func testReportsIncludeAvifCountForSideloadedFiles() throws {
        var file = FileItem(localURL: URL(fileURLWithPath: "/tmp/a.jpg"), filename: "a.jpg", sizeBytes: 10)
        file.status = .sideloaded
        file.importAttachmentId = 7
        file.avifCount = 9

        var job = Job(
            profileId: UUID(),
            remoteJobDir: "/tmp/job",
            files: [file],
            logsPath: "/tmp/log.txt"
        )
        job.step = .finished
        job.avifSideloadEnabled = true

        let text = ReportBuilder.textReport(for: job)
        XCTAssertTrue(text.contains("a.jpg: sideloaded"))
        XCTAssertTrue(text.contains("avifs: 9"))

        let csv = ReportBuilder.csvReport(for: job)
        XCTAssertTrue(csv.hasPrefix("filename,size_bytes,status,attachment_id,remote_path,error_message,avif_count"))
        XCTAssertTrue(csv.contains("a.jpg,10,sideloaded,7,,,9"))

        let json = try ReportBuilder.jsonReport(for: job)
        XCTAssertTrue(json.contains("\"avifCount\" : 9"))
        XCTAssertTrue(json.contains("\"avifSideloadEnabled\" : true"))
    }
}
