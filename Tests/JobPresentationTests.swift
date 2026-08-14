import Foundation
import XCTest
@testable import WordpressMediaUploaderApp

final class JobPresentationTests: XCTestCase {
    func testFailedUploadCountsAsAttemptedDuringNextActiveUploadProgress() {
        var failedFile = FileItem(
            localURL: URL(fileURLWithPath: "/tmp/failed.jpg"),
            filename: "failed.jpg",
            sizeBytes: 10
        )
        failedFile.status = .failed

        let activeFile = FileItem(
            localURL: URL(fileURLWithPath: "/tmp/active.jpg"),
            filename: "active.jpg",
            sizeBytes: 10
        )

        var job = Job(
            profileId: UUID(),
            remoteJobDir: "/tmp/job",
            files: [failedFile, activeFile],
            logsPath: "/tmp/job.log"
        )
        job.step = .uploading
        job.activeFileId = activeFile.id
        job.uploadProgress = 0.75

        let presentation = JobPresentation.make(
            for: job,
            activeFileStatus: .uploading,
            now: Date(),
            anchor: nil
        )

        XCTAssertEqual(presentation.overallProgress, 0.5625, accuracy: 0.0001)
    }

    func testSideloadEnabledJobUsesFiveStepsAndSideloadedAsSuccess() {
        var sideloadedFile = FileItem(
            localURL: URL(fileURLWithPath: "/tmp/done.jpg"),
            filename: "done.jpg",
            sizeBytes: 10
        )
        sideloadedFile.status = .sideloaded
        sideloadedFile.avifCount = 9

        var regeneratedFile = FileItem(
            localURL: URL(fileURLWithPath: "/tmp/pending.jpg"),
            filename: "pending.jpg",
            sizeBytes: 10
        )
        regeneratedFile.status = .regenerated

        var job = Job(
            profileId: UUID(),
            remoteJobDir: "/tmp/job",
            files: [sideloadedFile, regeneratedFile],
            logsPath: "/tmp/job.log"
        )
        job.avifSideloadEnabled = true
        job.step = .sideloading

        let presentation = JobPresentation.make(
            for: job,
            activeFileStatus: .sideloading,
            now: Date(),
            anchor: nil
        )

        // A .regenerated file is NOT terminal in a sideload-enabled job.
        XCTAssertEqual(presentation.processedFiles, 1)
        XCTAssertEqual(presentation.successfulFiles, 1)
        XCTAssertEqual(presentation.remainingFiles, 1)
        // (5 + 4) of 10 weighted steps.
        XCTAssertEqual(presentation.overallProgress, 0.9, accuracy: 0.0001)
    }

    func testSideloadDisabledJobStillTreatsRegeneratedAsSuccess() {
        var file = FileItem(
            localURL: URL(fileURLWithPath: "/tmp/a.jpg"),
            filename: "a.jpg",
            sizeBytes: 10
        )
        file.status = .regenerated

        var job = Job(
            profileId: UUID(),
            remoteJobDir: "/tmp/job",
            files: [file],
            logsPath: "/tmp/job.log"
        )
        job.step = .finished

        let presentation = JobPresentation.make(for: job, activeFileStatus: nil, now: Date(), anchor: nil)

        XCTAssertEqual(presentation.processedFiles, 1)
        XCTAssertEqual(presentation.successfulFiles, 1)
        XCTAssertEqual(presentation.overallProgress, 1.0, accuracy: 0.0001)
    }

    func testSideloadEnabledJobCountsSkippedNonJpegAsSuccess() {
        var skippedPNG = FileItem(
            localURL: URL(fileURLWithPath: "/tmp/pic.png"),
            filename: "pic.png",
            sizeBytes: 10
        )
        skippedPNG.status = .sideloaded
        skippedPNG.avifCount = 0

        var failedFile = FileItem(
            localURL: URL(fileURLWithPath: "/tmp/bad.jpg"),
            filename: "bad.jpg",
            sizeBytes: 10
        )
        failedFile.status = .failed

        var job = Job(
            profileId: UUID(),
            remoteJobDir: "/tmp/job",
            files: [skippedPNG, failedFile],
            logsPath: "/tmp/job.log"
        )
        job.avifSideloadEnabled = true
        job.step = .failed

        let presentation = JobPresentation.make(for: job, activeFileStatus: nil, now: Date(), anchor: nil)

        XCTAssertEqual(presentation.processedFiles, 2)
        XCTAssertEqual(presentation.successfulFiles, 1)
        XCTAssertEqual(presentation.failedFiles, 1)
        // Failed files weigh a full stepsPerFile so the bar can reach 100%.
        XCTAssertEqual(presentation.overallProgress, 1.0, accuracy: 0.0001)
    }
}
