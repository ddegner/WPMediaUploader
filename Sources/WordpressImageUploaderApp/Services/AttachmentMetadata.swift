import Foundation

/// Decoded shape of WordPress `_wp_attachment_metadata` (as emitted by
/// `wp post meta get <id> _wp_attachment_metadata --format=json`).
struct WPAttachmentMetadata: Decodable, Sendable {
    struct Size: Decodable, Sendable {
        let file: String
        let width: Int
        let height: Int

        private enum CodingKeys: String, CodingKey {
            case file
            case width
            case height
        }

        init(file: String, width: Int, height: Int) {
            self.file = file
            self.width = width
            self.height = height
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            file = try container.decode(String.self, forKey: .file)
            width = flexibleInt(container, key: .width) ?? 0
            height = flexibleInt(container, key: .height) ?? 0
        }
    }

    let file: String
    let width: Int?
    let height: Int?
    let sizes: [String: Size]

    private enum CodingKeys: String, CodingKey {
        case file
        case width
        case height
        case sizes
    }

    init(file: String, width: Int?, height: Int?, sizes: [String: Size]) {
        self.file = file
        self.width = width
        self.height = height
        self.sizes = sizes
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        file = try container.decode(String.self, forKey: .file)
        // String-typed dimensions here would otherwise silently become nil,
        // making the main file encode at source size instead of -scaled size.
        width = flexibleInt(container, key: .width)
        height = flexibleInt(container, key: .height)
        // PHP serializes an empty sizes map as [] rather than {}.
        sizes = (try? container.decodeIfPresent([String: Size].self, forKey: .sizes)) ?? [:]
    }
}

// Some WP setups serialize dimensions as strings; accept both.
private func flexibleInt<K: CodingKey>(_ container: KeyedDecodingContainer<K>, key: K) -> Int? {
    if let value = try? container.decodeIfPresent(Int.self, forKey: key) {
        return value
    }
    if let value = try? container.decodeIfPresent(String.self, forKey: key) {
        return Int(value)
    }
    return nil
}

/// One AVIF file to produce. nil dimensions mean "encode at source size".
struct AvifEncodeTarget: Equatable, Sendable {
    let avifFileName: String
    let width: Int?
    let height: Int?
}

struct AvifSideloadPlan: Equatable, Sendable {
    /// Directory of the derivatives relative to the uploads basedir ("" when flat).
    let remoteSubdirectory: String
    let targets: [AvifEncodeTarget]
}

enum AvifTargetPlannerError: LocalizedError {
    case malformedMetadata(String)

    var errorDescription: String? {
        switch self {
        case let .malformedMetadata(detail):
            return "Attachment metadata could not be parsed: \(detail)"
        }
    }
}

enum AvifTargetPlanner {
    /// Builds the sideload plan from raw `_wp_attachment_metadata` JSON.
    ///
    /// Targets are the attachment's main file (the `-scaled` copy when WordPress
    /// created one) plus every generated size. `original_image` is intentionally
    /// excluded — the server plugin never converts it either.
    static func plan(metadataJSON: Data) throws -> AvifSideloadPlan {
        let metadata: WPAttachmentMetadata
        do {
            metadata = try JSONDecoder().decode(WPAttachmentMetadata.self, from: metadataJSON)
        } catch {
            throw AvifTargetPlannerError.malformedMetadata(error.localizedDescription)
        }
        return plan(metadata: metadata)
    }

    static func plan(metadata: WPAttachmentMetadata) -> AvifSideloadPlan {
        let mainFile = metadata.file as NSString
        let subdirectory = mainFile.deletingLastPathComponent

        var targets: [AvifEncodeTarget] = []
        var seenNames = Set<String>()

        if let avifName = avifFileName(forJpeg: mainFile.lastPathComponent) {
            seenNames.insert(avifName)
            targets.append(AvifEncodeTarget(
                avifFileName: avifName,
                width: (metadata.width ?? 0) > 0 ? metadata.width : nil,
                height: (metadata.height ?? 0) > 0 ? metadata.height : nil
            ))
        }

        // Sort for a deterministic encode order (sizes is a dictionary).
        for (_, size) in metadata.sizes.sorted(by: { $0.key < $1.key }) {
            guard size.width > 0, size.height > 0 else { continue }
            guard let avifName = avifFileName(forJpeg: size.file) else { continue }
            guard seenNames.insert(avifName).inserted else { continue }
            targets.append(AvifEncodeTarget(
                avifFileName: avifName,
                width: size.width,
                height: size.height
            ))
        }

        return AvifSideloadPlan(remoteSubdirectory: subdirectory, targets: targets)
    }

    /// `foo.jpg` → `foo.avif`; nil for anything that is not a JPEG filename.
    static func avifFileName(forJpeg fileName: String) -> String? {
        let lowercased = fileName.lowercased()
        for ext in ["jpg", "jpeg", "jpe"] where lowercased.hasSuffix(".\(ext)") {
            return String(fileName.dropLast(ext.count)) + "avif"
        }
        return nil
    }
}
