import XCTest
@testable import WordpressMediaUploaderApp

final class FileRowStatusTests: XCTestCase {
    func testResolveShowsPreflightForCurrentJobQueuedItemDuringPreflight() {
        let item = FileItem(
            localURL: URL(fileURLWithPath: "/tmp/a.jpg"),
            filename: "a.jpg",
            sizeBytes: 1
        )

        let status = FileRowStatus.resolve(
            item: item,
            isQueuedSource: false,
            isActiveFile: false,
            currentStep: .preflight
        )

        XCTAssertEqual(status, .preflight)
        XCTAssertEqual(status.label, "preflight")
    }

    func testResolveKeepsQueuedForQueuedSourceDuringPreflight() {
        let item = FileItem(
            localURL: URL(fileURLWithPath: "/tmp/a.jpg"),
            filename: "a.jpg",
            sizeBytes: 1
        )

        let status = FileRowStatus.resolve(
            item: item,
            isQueuedSource: true,
            isActiveFile: false,
            currentStep: .preflight
        )

        XCTAssertEqual(status, .queued)
    }

    func testHelpTextUsesPreflightMessageWhenRowStatusIsPreflight() {
        let item = FileItem(
            localURL: URL(fileURLWithPath: "/tmp/a.jpg"),
            filename: "a.jpg",
            sizeBytes: 1
        )

        let text = FileRowPresentation.helpText(
            for: item,
            rowStatus: .preflight,
            isQueuedSource: false
        )

        XCTAssertEqual(text, "Running preflight checks and preparing staging.")
    }

    func testResolveShowsSideloadingForActiveFileDuringSideloadStep() {
        var item = FileItem(
            localURL: URL(fileURLWithPath: "/tmp/a.jpg"),
            filename: "a.jpg",
            sizeBytes: 1
        )
        item.status = .regenerated

        let status = FileRowStatus.resolve(
            item: item,
            isQueuedSource: false,
            isActiveFile: true,
            currentStep: .sideloading
        )

        XCTAssertEqual(status, .sideloading)
        XCTAssertEqual(status.tone, .progress)
    }

    func testResolveMapsSideloadedStatusWithSuccessTone() {
        var item = FileItem(
            localURL: URL(fileURLWithPath: "/tmp/a.jpg"),
            filename: "a.jpg",
            sizeBytes: 1
        )
        item.status = .sideloaded

        let status = FileRowStatus.resolve(
            item: item,
            isQueuedSource: false,
            isActiveFile: false,
            currentStep: .finished
        )

        XCTAssertEqual(status, .sideloaded)
        XCTAssertEqual(status.tone, .success)
    }

    func testHelpTextForSideloadedFileIncludesAvifCount() {
        var item = FileItem(
            localURL: URL(fileURLWithPath: "/tmp/a.jpg"),
            filename: "a.jpg",
            sizeBytes: 1
        )
        item.status = .sideloaded
        item.importAttachmentId = 42
        item.avifCount = 9

        let text = FileRowPresentation.helpText(for: item, rowStatus: .sideloaded, isQueuedSource: false)
        XCTAssertEqual(text, "Imported as attachment ID 42, 9 AVIF file(s) sideloaded")
    }

    func testHelpTextForSideloadedNonJpegSaysSkipped() {
        var item = FileItem(
            localURL: URL(fileURLWithPath: "/tmp/a.png"),
            filename: "a.png",
            sizeBytes: 1
        )
        item.status = .sideloaded
        item.importAttachmentId = 43
        item.avifCount = 0

        let text = FileRowPresentation.helpText(for: item, rowStatus: .sideloaded, isQueuedSource: false)
        XCTAssertEqual(text, "Imported as attachment ID 43, AVIF sideload skipped (not a JPEG)")
    }
}
