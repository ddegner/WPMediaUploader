import XCTest
@testable import WordpressMediaUploaderApp

final class AvifTargetPlannerTests: XCTestCase {
    func testPlanWithScaledMainFileAndSizes() throws {
        let json = """
        {
          "file": "2026/08/photo-scaled.jpg",
          "width": 2560,
          "height": 1707,
          "sizes": {
            "thumbnail": { "file": "photo-150x150.jpg", "width": 150, "height": 150, "mime-type": "image/jpeg" },
            "medium": { "file": "photo-300x200.jpg", "width": 300, "height": 200, "mime-type": "image/jpeg" }
          },
          "original_image": "photo.jpg"
        }
        """

        let plan = try AvifTargetPlanner.plan(metadataJSON: Data(json.utf8))

        XCTAssertEqual(plan.remoteSubdirectory, "2026/08")
        XCTAssertEqual(plan.targets.count, 3)
        XCTAssertEqual(plan.targets.first?.avifFileName, "photo-scaled.avif")
        XCTAssertEqual(plan.targets.first?.width, 2560)
        XCTAssertEqual(plan.targets.first?.height, 1707)

        let names = Set(plan.targets.map(\.avifFileName))
        XCTAssertEqual(names, ["photo-scaled.avif", "photo-150x150.avif", "photo-300x200.avif"])
        // original_image is never converted (matches the server plugin).
        XCTAssertFalse(names.contains("photo.avif"))
    }

    func testPlanWithoutScaledVariantUsesOriginalName() throws {
        let json = """
        {
          "file": "2026/08/small.jpg",
          "width": 800,
          "height": 600,
          "sizes": {}
        }
        """

        let plan = try AvifTargetPlanner.plan(metadataJSON: Data(json.utf8))
        XCTAssertEqual(plan.targets.map(\.avifFileName), ["small.avif"])
        XCTAssertEqual(plan.targets.first?.width, 800)
    }

    func testPlanToleratesPhpEmptyArraySizes() throws {
        let json = """
        { "file": "2026/08/lonely.jpeg", "width": 1200, "height": 900, "sizes": [] }
        """

        let plan = try AvifTargetPlanner.plan(metadataJSON: Data(json.utf8))
        XCTAssertEqual(plan.targets.map(\.avifFileName), ["lonely.avif"])
    }

    func testPlanDeduplicatesSizesSharingTheSameFile() throws {
        let json = """
        {
          "file": "2026/08/pic.jpg",
          "width": 1000,
          "height": 800,
          "sizes": {
            "medium": { "file": "pic-300x240.jpg", "width": 300, "height": 240 },
            "custom": { "file": "pic-300x240.jpg", "width": 300, "height": 240 }
          }
        }
        """

        let plan = try AvifTargetPlanner.plan(metadataJSON: Data(json.utf8))
        XCTAssertEqual(plan.targets.count { $0.avifFileName == "pic-300x240.avif" }, 1)
    }

    func testPlanSkipsNonJpegSizeFiles() throws {
        let json = """
        {
          "file": "2026/08/pic.jpg",
          "width": 1000,
          "height": 800,
          "sizes": {
            "webp-copy": { "file": "pic-300x240.webp", "width": 300, "height": 240 }
          }
        }
        """

        let plan = try AvifTargetPlanner.plan(metadataJSON: Data(json.utf8))
        XCTAssertEqual(plan.targets.map(\.avifFileName), ["pic.avif"])
    }

    func testPlanFlatUploadsDirectoryHasEmptySubdirectory() throws {
        let json = """
        { "file": "flat.jpg", "width": 640, "height": 480, "sizes": {} }
        """

        let plan = try AvifTargetPlanner.plan(metadataJSON: Data(json.utf8))
        XCTAssertEqual(plan.remoteSubdirectory, "")
    }

    func testPlanAcceptsStringDimensionsInSizes() throws {
        let json = """
        {
          "file": "2026/08/pic.jpg",
          "width": 1000,
          "height": 800,
          "sizes": {
            "medium": { "file": "pic-300x240.jpg", "width": "300", "height": "240" }
          }
        }
        """

        let plan = try AvifTargetPlanner.plan(metadataJSON: Data(json.utf8))
        let medium = plan.targets.first { $0.avifFileName == "pic-300x240.avif" }
        XCTAssertEqual(medium?.width, 300)
        XCTAssertEqual(medium?.height, 240)
    }

    func testPlanThrowsOnMalformedJSON() {
        XCTAssertThrowsError(try AvifTargetPlanner.plan(metadataJSON: Data("not json".utf8)))
        XCTAssertThrowsError(try AvifTargetPlanner.plan(metadataJSON: Data("{}".utf8)))
    }

    func testAvifFileNameMapping() {
        XCTAssertEqual(AvifTargetPlanner.avifFileName(forJpeg: "a.jpg"), "a.avif")
        XCTAssertEqual(AvifTargetPlanner.avifFileName(forJpeg: "a.JPEG"), "a.avif")
        XCTAssertEqual(AvifTargetPlanner.avifFileName(forJpeg: "a.jpe"), "a.avif")
        XCTAssertEqual(AvifTargetPlanner.avifFileName(forJpeg: "photo.name.jpg"), "photo.name.avif")
        XCTAssertNil(AvifTargetPlanner.avifFileName(forJpeg: "a.png"))
        XCTAssertNil(AvifTargetPlanner.avifFileName(forJpeg: "a.avif"))
    }
}
