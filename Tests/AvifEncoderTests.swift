import CoreGraphics
import ImageIO
import XCTest
@testable import WordpressMediaUploaderApp

final class AvifEncoderTests: XCTestCase {
    private var workDir: URL!

    override func setUpWithError() throws {
        workDir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("avif-encoder-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: workDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: workDir)
    }

    func testCenterCropRectWideSourceToSquare() {
        let rect = AvifEncoder.centerCropRect(sourceWidth: 400, sourceHeight: 200, targetWidth: 100, targetHeight: 100)
        XCTAssertEqual(rect, CGRect(x: 100, y: 0, width: 200, height: 200))
    }

    func testCenterCropRectTallSourceToSquare() {
        let rect = AvifEncoder.centerCropRect(sourceWidth: 200, sourceHeight: 400, targetWidth: 100, targetHeight: 100)
        XCTAssertEqual(rect, CGRect(x: 0, y: 100, width: 200, height: 200))
    }

    func testCenterCropRectMatchingAspectIsFullFrame() {
        let rect = AvifEncoder.centerCropRect(sourceWidth: 400, sourceHeight: 300, targetWidth: 200, targetHeight: 150)
        XCTAssertEqual(rect, CGRect(x: 0, y: 0, width: 400, height: 300))
    }

    func testEncodeProducesValidAvifsAtExactTargetDimensions() async throws {
        try XCTSkipUnless(AvifEncoder.isAvifEncodingSupported, "ImageIO on this system cannot encode AVIF")

        let sourceURL = workDir.appendingPathComponent("source.jpg")
        try Self.writeTestJPEG(to: sourceURL, width: 640, height: 480)

        let encoder = AvifEncoder(quality: 0.85)
        let outputDir = workDir.appendingPathComponent("out", isDirectory: true)
        let outcome = try await encoder.encode(
            sourceJPEG: sourceURL,
            targets: [
                AvifEncodeTarget(avifFileName: "source.avif", width: 640, height: 480),
                AvifEncodeTarget(avifFileName: "source-150x150.avif", width: 150, height: 150),
                AvifEncodeTarget(avifFileName: "source-300x200.avif", width: 300, height: 200)
            ],
            into: outputDir
        )

        XCTAssertEqual(outcome.encodedFiles.count, 3)
        XCTAssertTrue(outcome.skippedOversizeTargets.isEmpty)

        let expected: [String: (Int, Int)] = [
            "source.avif": (640, 480),
            "source-150x150.avif": (150, 150),
            "source-300x200.avif": (300, 200)
        ]

        for url in outcome.encodedFiles {
            let size = try XCTUnwrap(
                FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int
            )
            XCTAssertGreaterThan(size, AvifEncoder.minValidOutputBytes, url.lastPathComponent)

            let imageSource = try XCTUnwrap(CGImageSourceCreateWithURL(url as CFURL, nil))
            let type = CGImageSourceGetType(imageSource) as String?
            XCTAssertEqual(type, AvifEncoder.avifTypeIdentifier, url.lastPathComponent)

            let properties = try XCTUnwrap(
                CGImageSourceCopyPropertiesAtIndex(imageSource, 0, nil) as? [CFString: Any]
            )
            let (expectedWidth, expectedHeight) = try XCTUnwrap(expected[url.lastPathComponent])
            XCTAssertEqual(properties[kCGImagePropertyPixelWidth] as? Int, expectedWidth, url.lastPathComponent)
            XCTAssertEqual(properties[kCGImagePropertyPixelHeight] as? Int, expectedHeight, url.lastPathComponent)
        }
    }

    func testEncodeSkipsOversizeTargets() async throws {
        try XCTSkipUnless(AvifEncoder.isAvifEncodingSupported, "ImageIO on this system cannot encode AVIF")

        let sourceURL = workDir.appendingPathComponent("source.jpg")
        try Self.writeTestJPEG(to: sourceURL, width: 320, height: 240)

        let encoder = AvifEncoder(quality: 0.85)
        let outcome = try await encoder.encode(
            sourceJPEG: sourceURL,
            targets: [
                AvifEncodeTarget(avifFileName: "huge.avif", width: 20000, height: 10000),
                AvifEncodeTarget(avifFileName: "ok.avif", width: 160, height: 120)
            ],
            into: workDir.appendingPathComponent("out", isDirectory: true)
        )

        XCTAssertEqual(outcome.skippedOversizeTargets, ["huge.avif"])
        XCTAssertEqual(outcome.encodedFiles.map(\.lastPathComponent), ["ok.avif"])
    }

    // Regression: concurrent encodes of a large image intermittently failed in
    // the sandboxed app ("could not create destination"). Mirrors the real
    // 7-derivative target set from a portrait photo upload.
    func testConcurrentEncodeOfLargeImageIsReliable() async throws {
        try XCTSkipUnless(AvifEncoder.isAvifEncodingSupported, "ImageIO on this system cannot encode AVIF")

        let sourceURL = workDir.appendingPathComponent("large.jpg")
        try Self.writeTestJPEG(to: sourceURL, width: 2880, height: 3840)

        let targets = [
            AvifEncodeTarget(avifFileName: "large-scaled.avif", width: 1920, height: 2560),
            AvifEncodeTarget(avifFileName: "large-1536x2048.avif", width: 1536, height: 2048),
            AvifEncodeTarget(avifFileName: "large-1152x1536.avif", width: 1152, height: 1536),
            AvifEncodeTarget(avifFileName: "large-1125x1500.avif", width: 1125, height: 1500),
            AvifEncodeTarget(avifFileName: "large-768x1024.avif", width: 768, height: 1024),
            AvifEncodeTarget(avifFileName: "large-225x300.avif", width: 225, height: 300),
            AvifEncodeTarget(avifFileName: "large-150x150.avif", width: 150, height: 150)
        ]

        let encoder = AvifEncoder(quality: 0.85)
        for round in 1...3 {
            let outputDir = workDir.appendingPathComponent("stress-\(round)", isDirectory: true)
            let outcome = try await encoder.encode(sourceJPEG: sourceURL, targets: targets, into: outputDir)
            XCTAssertEqual(outcome.encodedFiles.count, targets.count, "round \(round)")
        }
    }

    // The quality knob must actually change the output (some encoders ignore
    // kCGImageDestinationLossyCompressionQuality; ImageIO's AVIF honors it).
    func testQualitySettingChangesOutputSize() async throws {
        try XCTSkipUnless(AvifEncoder.isAvifEncodingSupported, "ImageIO on this system cannot encode AVIF")

        let sourceURL = workDir.appendingPathComponent("source.jpg")
        try Self.writeTestJPEG(to: sourceURL, width: 800, height: 600)
        let target = [AvifEncodeTarget(avifFileName: "out.avif", width: 800, height: 600)]

        var sizes: [Int] = []
        for quality in [0.3, 0.85] {
            let outputDir = workDir.appendingPathComponent("q\(Int(quality * 100))", isDirectory: true)
            let outcome = try await AvifEncoder(quality: quality)
                .encode(sourceJPEG: sourceURL, targets: target, into: outputDir)
            let url = try XCTUnwrap(outcome.encodedFiles.first)
            let size = try XCTUnwrap(FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int)
            sizes.append(size)
        }

        XCTAssertLessThan(sizes[0], sizes[1], "higher quality must produce a larger file")
    }

    // Regression: ImageIO fails outright at quality exactly 1.0 (cannot encode
    // lossless AVIF). Quality 100 from the plugin must clamp, not fail.
    func testQualityOneHundredClampsInsteadOfFailing() async throws {
        try XCTSkipUnless(AvifEncoder.isAvifEncodingSupported, "ImageIO on this system cannot encode AVIF")

        let encoder = AvifEncoder(quality: 1.0)
        XCTAssertEqual(encoder.effectiveQuality, AvifEncoder.maxUsableQuality)

        let sourceURL = workDir.appendingPathComponent("source.jpg")
        try Self.writeTestJPEG(to: sourceURL, width: 320, height: 240)

        let outcome = try await encoder.encode(
            sourceJPEG: sourceURL,
            targets: [AvifEncodeTarget(avifFileName: "max.avif", width: 320, height: 240)],
            into: workDir.appendingPathComponent("max-q", isDirectory: true)
        )
        XCTAssertEqual(outcome.encodedFiles.count, 1)
    }

    // MARK: - Embedded avifenc engine

    func testAvifencArgumentsForNormalEncode() {
        let args = AvifEncoder.avifencArguments(
            quality: 85, speed: 4, chroma: "444", bitDepth: 10, lossless: false,
            inputPath: "/tmp/in.png", outputPath: "/tmp/out.avif"
        )
        XCTAssertEqual(args, ["-q", "85", "-y", "444", "-s", "4", "-d", "10", "-j", "3", "/tmp/in.png", "/tmp/out.avif"])
    }

    func testAvifencArgumentsForLosslessForcesFullChroma() {
        let args = AvifEncoder.avifencArguments(
            quality: 100, speed: 2, chroma: "420", bitDepth: 8, lossless: true,
            inputPath: "/tmp/in.png", outputPath: "/tmp/out.avif"
        )
        XCTAssertTrue(args.starts(with: ["--lossless", "-y", "444"]))
        XCTAssertFalse(args.contains("-q"))
    }

    func testAvifencArgumentsClampInvalidValues() {
        let args = AvifEncoder.avifencArguments(
            quality: 150, speed: 99, chroma: "422x", bitDepth: 9, lossless: false,
            inputPath: "in", outputPath: "out"
        )
        // Exact array: quality clamped to 100, chroma falls back to 420,
        // speed clamped to 10, depth falls back to 8.
        XCTAssertEqual(args, ["-q", "100", "-y", "420", "-s", "10", "-d", "8", "-j", "3", "in", "out"])
    }

    private static var vendoredHelperURL: URL? {
        // Hosted in the app (xcodebuild test): use the embedded, signed helper —
        // this exercises the exact sandbox + exec path production uses.
        if let bundled = Bundle.main.url(forAuxiliaryExecutable: "avifenc"),
           FileManager.default.isExecutableFile(atPath: bundled.path)
        {
            return bundled
        }
        // SPM (swift test): fall back to the repo's vendored binary.
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Vendor/avifenc/avifenc", isDirectory: false)
        return FileManager.default.isExecutableFile(atPath: url.path) ? url : nil
    }

    func testEmbeddedEncoderProducesTenBitAvifHonoringSettings() async throws {
        guard let helperURL = Self.vendoredHelperURL else {
            throw XCTSkip("Vendor/avifenc/avifenc missing — run scripts/build-avifenc.sh to exercise the helper engine")
        }

        let sourceURL = workDir.appendingPathComponent("source.jpg")
        try Self.writeTestJPEG(to: sourceURL, width: 640, height: 480)

        var encoder = AvifEncoder(quality: 0.85, helperURL: helperURL)
        encoder.speed = 8
        encoder.chroma = "444"
        encoder.bitDepth = 10

        let outcome = try await encoder.encode(
            sourceJPEG: sourceURL,
            targets: [
                AvifEncodeTarget(avifFileName: "ten.avif", width: 320, height: 240),
                AvifEncodeTarget(avifFileName: "ten-full.avif", width: 640, height: 480)
            ],
            into: workDir.appendingPathComponent("helper-out", isDirectory: true)
        )

        XCTAssertEqual(outcome.encodedFiles.count, 2)
        for url in outcome.encodedFiles {
            let source = try XCTUnwrap(CGImageSourceCreateWithURL(url as CFURL, nil))
            let props = try XCTUnwrap(CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any])
            XCTAssertEqual(props[kCGImagePropertyDepth] as? Int, 10, url.lastPathComponent)
        }
        // PNG intermediates must be cleaned up.
        let leftovers = try FileManager.default.contentsOfDirectory(
            atPath: workDir.appendingPathComponent("helper-out").path
        ).filter { $0.hasSuffix(".png") }
        XCTAssertTrue(leftovers.isEmpty)
    }

    func testEmbeddedEncoderLosslessSucceeds() async throws {
        guard let helperURL = Self.vendoredHelperURL else {
            throw XCTSkip("Vendor/avifenc/avifenc missing — run scripts/build-avifenc.sh to exercise the helper engine")
        }

        let sourceURL = workDir.appendingPathComponent("source.jpg")
        try Self.writeTestJPEG(to: sourceURL, width: 200, height: 150)

        var encoder = AvifEncoder(quality: 1.0, helperURL: helperURL)
        encoder.lossless = true

        let outcome = try await encoder.encode(
            sourceJPEG: sourceURL,
            targets: [AvifEncodeTarget(avifFileName: "lossless.avif", width: 200, height: 150)],
            into: workDir.appendingPathComponent("lossless-out", isDirectory: true)
        )
        XCTAssertEqual(outcome.encodedFiles.count, 1)
    }

    func testEncodeThrowsForUnreadableSource() async {
        let encoder = AvifEncoder(quality: 0.85)
        do {
            _ = try await encoder.encode(
                sourceJPEG: workDir.appendingPathComponent("missing.jpg"),
                targets: [AvifEncodeTarget(avifFileName: "x.avif", width: 10, height: 10)],
                into: workDir.appendingPathComponent("out", isDirectory: true)
            )
            XCTFail("Expected an error for a missing source file")
        } catch {
            // expected
        }
    }

    // MARK: - Helpers

    private static func writeTestJPEG(to url: URL, width: Int, height: Int) throws {
        let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!
        guard let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
        ) else {
            throw NSError(domain: "AvifEncoderTests", code: 1)
        }

        // A gradient plus rectangles so the JPEG has real detail to encode.
        for x in stride(from: 0, to: width, by: 8) {
            let hue = CGFloat(x) / CGFloat(width)
            context.setFillColor(CGColor(red: hue, green: 1 - hue, blue: 0.5, alpha: 1))
            context.fill(CGRect(x: x, y: 0, width: 8, height: height))
        }
        context.setFillColor(CGColor(red: 0, green: 0, blue: 0, alpha: 1))
        context.fill(CGRect(x: width / 4, y: height / 4, width: width / 2, height: height / 2))

        guard let image = context.makeImage(),
              let destination = CGImageDestinationCreateWithURL(url as CFURL, "public.jpeg" as CFString, 1, nil)
        else {
            throw NSError(domain: "AvifEncoderTests", code: 2)
        }
        CGImageDestinationAddImage(destination, image, [
            kCGImageDestinationLossyCompressionQuality: 0.9
        ] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else {
            throw NSError(domain: "AvifEncoderTests", code: 3)
        }
    }
}
