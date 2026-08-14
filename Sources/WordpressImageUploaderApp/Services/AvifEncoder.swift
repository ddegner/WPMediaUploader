import CoreGraphics
import Foundation
import ImageIO

enum AvifEncoderError: LocalizedError {
    case cannotReadSource(String)
    case encodeFailed(String)
    case outputTooSmall(String)

    var errorDescription: String? {
        switch self {
        case let .cannotReadSource(detail):
            return "Could not read source image: \(detail)"
        case let .encodeFailed(detail):
            return "AVIF encode failed: \(detail)"
        case let .outputTooSmall(detail):
            return "AVIF encode produced an invalid file: \(detail)"
        }
    }
}

struct AvifEncodeOutcome: Sendable {
    var encodedFiles: [URL] = []
    var skippedOversizeTargets: [String] = []
}

/// Immutable decoded-image payload shared across concurrent encode tasks.
/// CGImage and the CF property dictionaries are read-only after creation.
private final class DecodedSource: @unchecked Sendable {
    let image: CGImage
    let exifProperties: NSDictionary?

    init(image: CGImage, exifProperties: NSDictionary?) {
        self.image = image
        self.exifProperties = exifProperties
    }
}

/// Encodes AVIF derivatives from a JPEG original.
///
/// Mirrors the server plugin's ImagickEncoder semantics: every derivative is
/// produced from the original in one pass (center-crop to the target aspect,
/// high-quality resize, single lossy encode), the source ICC profile is
/// preserved, and outputs at or under 512 bytes are rejected as invalid.
///
/// Two engines:
/// - `helperURL` set → the embedded `avifenc` (libavif + aom, same encoder
///   family the server plugin uses via ImageMagick). Honors speed, chroma
///   subsampling, bit depth, and lossless.
/// - `helperURL` nil → system ImageIO. Quality only; always 4:2:0 / 8-bit,
///   and quality 1.0 is clamped (ImageIO cannot encode lossless AVIF).
struct AvifEncoder: Sendable {
    /// Lossy quality in 0...1 (WordPress option 85 → 0.85).
    var quality: Double
    /// aom speed 0 (slowest/best) ... 10 (fastest). Ignored by ImageIO.
    var speed: Int = 6
    /// "420", "422", or "444". Ignored by ImageIO (always 420).
    var chroma: String = "420"
    /// 8, 10, or 12. Ignored by ImageIO (always 8).
    var bitDepth: Int = 8
    /// Plugin semantics: quality >= 100 means lossless. avifenc only.
    var lossless: Bool = false
    /// Embedded avifenc binary; nil selects the ImageIO engine.
    var helperURL: URL? = nil
    var maxConcurrentEncodes: Int = 4

    /// ImageIO's AVIF encoder hard-fails at exactly 1.0 (it cannot encode
    /// lossless AVIF), verified empirically; 0.99 is the usable maximum.
    static let maxUsableQuality = 0.99

    var effectiveQuality: Double {
        min(max(quality, 0), Self.maxUsableQuality)
    }

    /// AVIF Advanced Profile pixel limit (16384×8704), same rule as the plugin.
    static let maxOutputPixels = 35_651_584

    /// Encoded output must exceed this to count as valid (plugin's serve rule).
    static let minValidOutputBytes = 512

    static let avifTypeIdentifier = "public.avif"

    static var isAvifEncodingSupported: Bool {
        let identifiers = CGImageDestinationCopyTypeIdentifiers() as? [String] ?? []
        return identifiers.contains(avifTypeIdentifier)
    }

    func encode(
        sourceJPEG: URL,
        targets: [AvifEncodeTarget],
        into outputDirectory: URL,
        onEvent: (@Sendable (String) -> Void)? = nil
    ) async throws -> AvifEncodeOutcome {
        guard !targets.isEmpty else { return AvifEncodeOutcome() }

        try FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)

        let source = try Self.decodeOriented(sourceJPEG: sourceJPEG)

        var outcome = AvifEncodeOutcome()
        var plannedTargets: [AvifEncodeTarget] = []
        for target in targets {
            if let width = target.width, let height = target.height,
               width * height > Self.maxOutputPixels
            {
                onEvent?("Skipping \(target.avifFileName): \(width)x\(height) exceeds the AVIF pixel limit.")
                outcome.skippedOversizeTargets.append(target.avifFileName)
                continue
            }
            plannedTargets.append(target)
        }

        let windowSize = max(1, maxConcurrentEncodes)

        let encodedURLs = try await withThrowingTaskGroup(of: URL.self) { group in
            var urls: [URL] = []
            var nextIndex = 0

            func addTask(_ target: AvifEncodeTarget) {
                let outputURL = outputDirectory.appendingPathComponent(target.avifFileName, isDirectory: false)
                group.addTask {
                    try Task.checkCancellation()
                    do {
                        try await self.encodeSingle(source: source, target: target, to: outputURL)
                    } catch is CancellationError {
                        throw CancellationError()
                    } catch {
                        // One retry clears transient encoder failures.
                        onEvent?("Retrying \(target.avifFileName): \(error.localizedDescription)")
                        try await Task.sleep(for: .milliseconds(200))
                        try Task.checkCancellation()
                        try await self.encodeSingle(source: source, target: target, to: outputURL)
                    }
                    onEvent?("Encoded \(target.avifFileName)")
                    return outputURL
                }
            }

            while nextIndex < plannedTargets.count, nextIndex < windowSize {
                addTask(plannedTargets[nextIndex])
                nextIndex += 1
            }

            while let finished = try await group.next() {
                urls.append(finished)
                if nextIndex < plannedTargets.count {
                    addTask(plannedTargets[nextIndex])
                    nextIndex += 1
                }
            }

            return urls
        }

        outcome.encodedFiles = encodedURLs.sorted { $0.lastPathComponent < $1.lastPathComponent }
        return outcome
    }

    // MARK: - Decoding

    /// Decodes the source JPEG once with EXIF orientation baked into the pixels,
    /// keeping the source colorspace so the ICC profile survives re-encoding.
    private static func decodeOriented(sourceJPEG: URL) throws -> DecodedSource {
        let sourceOptions = [kCGImageSourceShouldCache: false] as CFDictionary
        guard let imageSource = CGImageSourceCreateWithURL(sourceJPEG as CFURL, sourceOptions) else {
            throw AvifEncoderError.cannotReadSource(sourceJPEG.lastPathComponent)
        }

        let properties = CGImageSourceCopyPropertiesAtIndex(imageSource, 0, nil) as? [CFString: Any]
        let pixelWidth = properties?[kCGImagePropertyPixelWidth] as? Int ?? 0
        let pixelHeight = properties?[kCGImagePropertyPixelHeight] as? Int ?? 0
        guard pixelWidth > 0, pixelHeight > 0 else {
            throw AvifEncoderError.cannotReadSource("\(sourceJPEG.lastPathComponent) has no pixel dimensions")
        }

        // The thumbnail API with the transform option decodes at full size with
        // orientation applied — one decode, correctly rotated pixels.
        let decodeOptions: [CFString: Any] = [
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceThumbnailMaxPixelSize: max(pixelWidth, pixelHeight),
            kCGImageSourceShouldCacheImmediately: true
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(imageSource, 0, decodeOptions as CFDictionary) else {
            throw AvifEncoderError.cannotReadSource(sourceJPEG.lastPathComponent)
        }

        let exif = properties?[kCGImagePropertyExifDictionary] as? NSDictionary
        return DecodedSource(image: image, exifProperties: exif)
    }

    // MARK: - Single-target encode

    private func encodeSingle(
        source: DecodedSource,
        target: AvifEncodeTarget,
        to outputURL: URL
    ) async throws {
        let image: CGImage
        if let width = target.width, let height = target.height,
           width > 0, height > 0,
           width != source.image.width || height != source.image.height
        {
            image = try Self.cropAndResize(source.image, targetWidth: width, targetHeight: height)
        } else {
            image = source.image
        }

        if let helperURL {
            try await encodeWithHelper(
                helperURL,
                image: image,
                exif: source.exifProperties,
                target: target,
                to: outputURL
            )
        } else {
            try encodeWithImageIO(image: image, exif: source.exifProperties, target: target, to: outputURL)
        }

        let size = (try? FileManager.default.attributesOfItem(atPath: outputURL.path)[.size] as? Int) ?? 0
        guard size > Self.minValidOutputBytes else {
            try? FileManager.default.removeItem(at: outputURL)
            throw AvifEncoderError.outputTooSmall("\(target.avifFileName) is \(size) bytes")
        }
    }

    // MARK: - ImageIO engine

    private func encodeWithImageIO(
        image: CGImage,
        exif: NSDictionary?,
        target: AvifEncodeTarget,
        to outputURL: URL
    ) throws {
        // Encode in memory and write the bytes ourselves for a clear error
        // when anything goes wrong with the output location.
        let encodedData = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            encodedData as CFMutableData,
            Self.avifTypeIdentifier as CFString,
            1,
            nil
        ) else {
            throw AvifEncoderError.encodeFailed(
                Self.isAvifEncodingSupported
                    ? "could not create destination for \(target.avifFileName)"
                    : "this system's ImageIO cannot encode AVIF"
            )
        }

        var destinationProperties: [CFString: Any] = [
            kCGImageDestinationLossyCompressionQuality: effectiveQuality,
            kCGImagePropertyOrientation: 1
        ]
        if let exif {
            destinationProperties[kCGImagePropertyExifDictionary] = exif
        }

        CGImageDestinationAddImage(destination, image, destinationProperties as CFDictionary)
        guard CGImageDestinationFinalize(destination) else {
            throw AvifEncoderError.encodeFailed(target.avifFileName)
        }

        guard encodedData.length > Self.minValidOutputBytes else {
            throw AvifEncoderError.outputTooSmall("\(target.avifFileName) is \(encodedData.length) bytes")
        }

        try (encodedData as Data).write(to: outputURL, options: .atomic)
    }

    // MARK: - Embedded avifenc engine

    private func encodeWithHelper(
        _ helperURL: URL,
        image: CGImage,
        exif: NSDictionary?,
        target: AvifEncodeTarget,
        to outputURL: URL
    ) async throws {
        // Lossless PNG intermediate carries pixels, ICC profile, and EXIF.
        let pngURL = outputURL.deletingPathExtension().appendingPathExtension("png")
        try Self.writePNG(image, exif: exif, to: pngURL)
        defer { try? FileManager.default.removeItem(at: pngURL) }

        let arguments = Self.avifencArguments(
            quality: Int((quality * 100).rounded()),
            speed: speed,
            chroma: chroma,
            bitDepth: bitDepth,
            lossless: lossless,
            inputPath: pngURL.path,
            outputPath: outputURL.path
        )
        try await Self.runHelper(at: helperURL, arguments: arguments)
    }

    /// Pure argument builder (unit-tested).
    static func avifencArguments(
        quality: Int,
        speed: Int,
        chroma: String,
        bitDepth: Int,
        lossless: Bool,
        inputPath: String,
        outputPath: String
    ) -> [String] {
        let validChroma = ["420", "422", "444"].contains(chroma) ? chroma : "420"
        let validDepth = [8, 10, 12].contains(bitDepth) ? bitDepth : 8

        var arguments: [String] = []
        if lossless {
            // Mirrors the plugin: lossless forces 4:4:4.
            arguments += ["--lossless", "-y", "444"]
        } else {
            arguments += ["-q", String(max(0, min(100, quality))), "-y", validChroma]
        }
        arguments += [
            "-s", String(max(0, min(10, speed))),
            "-d", String(validDepth),
            "-j", "3",
            inputPath,
            outputPath
        ]
        return arguments
    }

    private static func writePNG(_ image: CGImage, exif: NSDictionary?, to url: URL) throws {
        guard let destination = CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil) else {
            throw AvifEncoderError.encodeFailed("could not create PNG intermediate")
        }
        var properties: [CFString: Any] = [kCGImagePropertyOrientation: 1]
        if let exif {
            properties[kCGImagePropertyExifDictionary] = exif
        }
        CGImageDestinationAddImage(destination, image, properties as CFDictionary)
        guard CGImageDestinationFinalize(destination) else {
            throw AvifEncoderError.encodeFailed("could not write PNG intermediate")
        }
    }

    private static func runHelper(at helperURL: URL, arguments: [String]) async throws {
        let process = Process()
        process.executableURL = helperURL
        process.arguments = arguments
        // Progress chatter is unused, and the null device can never fill up
        // and block the encoder the way an undrained pipe buffer does.
        process.standardOutput = FileHandle.nullDevice
        let stderrPipe = Pipe()
        process.standardError = stderrPipe

        // Drain stderr while the helper runs — reading only after exit
        // deadlocks once the helper writes more than one pipe buffer.
        let stderrHandle = stderrPipe.fileHandleForReading
        let stderrTask = Task.detached {
            (try? stderrHandle.readToEnd()) ?? Data()
        }

        let status: Int32 = try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Int32, Error>) in
                process.terminationHandler = { finished in
                    continuation.resume(returning: finished.terminationStatus)
                }
                do {
                    try process.run()
                    // A cancellation that raced the launch saw pid 0 in
                    // onCancel and killed nothing; honor it now.
                    if Task.isCancelled {
                        kill(process.processIdentifier, SIGTERM)
                    }
                } catch {
                    process.terminationHandler = nil
                    continuation.resume(throwing: error)
                }
            }
        } onCancel: {
            // kill(2) is exception-free even if the process never started.
            let pid = process.processIdentifier
            if pid > 0 {
                kill(pid, SIGTERM)
            }
        }

        let stderrData = await stderrTask.value
        guard status == 0 else {
            let tail = String(decoding: stderrData, as: UTF8.self)
                .split(separator: "\n")
                .suffix(2)
                .joined(separator: " | ")
            throw AvifEncoderError.encodeFailed("avifenc exit \(status): \(tail)")
        }
    }

    // MARK: - Shared pixel pipeline

    private static func cropAndResize(_ image: CGImage, targetWidth: Int, targetHeight: Int) throws -> CGImage {
        let cropRect = centerCropRect(
            sourceWidth: image.width,
            sourceHeight: image.height,
            targetWidth: targetWidth,
            targetHeight: targetHeight
        )

        guard let cropped = image.cropping(to: cropRect) else {
            throw AvifEncoderError.encodeFailed("crop to \(targetWidth)x\(targetHeight) failed")
        }

        let colorSpace = usableColorSpace(for: image)
        guard let context = CGContext(
            data: nil,
            width: targetWidth,
            height: targetHeight,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
        ) else {
            throw AvifEncoderError.encodeFailed("could not create drawing context")
        }

        context.interpolationQuality = .high
        context.draw(cropped, in: CGRect(x: 0, y: 0, width: targetWidth, height: targetHeight))

        guard let resized = context.makeImage() else {
            throw AvifEncoderError.encodeFailed("resize to \(targetWidth)x\(targetHeight) failed")
        }
        return resized
    }

    private static func usableColorSpace(for image: CGImage) -> CGColorSpace {
        if let space = image.colorSpace, space.model == .rgb {
            return space
        }
        return CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
    }

    /// Same center-crop math as the plugin's ImagickEncoder::resizeAndCrop:
    /// crop the source to the target aspect ratio (centered), then resize.
    static func centerCropRect(
        sourceWidth: Int,
        sourceHeight: Int,
        targetWidth: Int,
        targetHeight: Int
    ) -> CGRect {
        let srcW = max(1, sourceWidth)
        let srcH = max(1, sourceHeight)
        let tW = max(1, targetWidth)
        let tH = max(1, targetHeight)

        let sourceAspect = Double(srcW) / Double(srcH)
        let targetAspect = Double(tW) / Double(tH)

        let cropWidth: Int
        let cropHeight: Int
        let cropX: Int
        let cropY: Int

        if sourceAspect > targetAspect {
            cropHeight = srcH
            cropWidth = Int(Double(srcH) * targetAspect)
            cropX = (srcW - cropWidth) / 2
            cropY = 0
        } else {
            cropWidth = srcW
            cropHeight = Int(Double(srcW) / targetAspect)
            cropX = 0
            cropY = (srcH - cropHeight) / 2
        }

        return CGRect(x: cropX, y: cropY, width: max(1, cropWidth), height: max(1, cropHeight))
    }
}
