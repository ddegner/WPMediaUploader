import Foundation

enum AuthenticationType: String, Codable, CaseIterable, Identifiable, Sendable {
    case sshKey
    case password

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .sshKey:
            return "SSH Key"
        case .password:
            return "Password"
        }
    }
}

struct ServerProfile: Identifiable, Codable, Equatable, Sendable {
    var id: UUID
    var name: String
    var host: String
    var port: Int
    var username: String
    var authType: AuthenticationType
    var keyPath: String?
    var keyBookmarkData: Data?
    var keyPassphraseKeychainId: String?
    var passwordKeychainId: String?
    var wpRootPath: String
    var remoteStagingRoot: String
    var keepRemoteFiles: Bool
    var profileColorHex: String?
    // Optional so profiles saved by older app versions still decode.
    var generateAvifsLocally: Bool?

    var generateAvifsLocallyEnabled: Bool {
        generateAvifsLocally ?? false
    }

    static let `default` = ServerProfile(
        id: UUID(),
        name: "New Profile",
        host: "",
        port: 22,
        username: "",
        authType: .password,
        keyPath: nil,
        keyBookmarkData: nil,
        keyPassphraseKeychainId: nil,
        passwordKeychainId: nil,
        wpRootPath: "",
        remoteStagingRoot: "~/wp-media-import",
        keepRemoteFiles: false,
        profileColorHex: nil,
        generateAvifsLocally: nil
    )
}

struct ProfileColor: Identifiable, Equatable, Sendable {
    let id: String
    let name: String
    let hex: String

    static let presets: [ProfileColor] = [
        ProfileColor(id: "blue", name: "Blue", hex: "007AFF"),
        ProfileColor(id: "purple", name: "Purple", hex: "AF52DE"),
        ProfileColor(id: "pink", name: "Pink", hex: "FF2D55"),
        ProfileColor(id: "red", name: "Red", hex: "FF3B30"),
        ProfileColor(id: "orange", name: "Orange", hex: "FF9500"),
        ProfileColor(id: "green", name: "Green", hex: "34C759"),
        ProfileColor(id: "teal", name: "Teal", hex: "5AC8FA"),
        ProfileColor(id: "indigo", name: "Indigo", hex: "5856D6"),
    ]
}

enum FileItemStatus: String, Codable, CaseIterable, Sendable, Comparable {
    case queued
    case uploaded
    case verified
    case imported
    case regenerated
    case sideloaded
    case failed

    private var sortOrder: Int {
        switch self {
        case .queued: return 0
        case .uploaded: return 1
        case .verified: return 2
        case .imported: return 3
        case .regenerated: return 4
        case .sideloaded: return 5
        case .failed: return 6
        }
    }

    static func < (lhs: Self, rhs: Self) -> Bool {
        lhs.sortOrder < rhs.sortOrder
    }
}

struct FileItem: Identifiable, Codable, Equatable, Sendable {
    var id: UUID
    var localURL: URL
    var bookmarkData: Data?
    var filename: String
    var sizeBytes: Int64
    var status: FileItemStatus
    var remotePath: String?
    var importAttachmentId: Int?
    var errorMessage: String?
    // Number of AVIF derivatives sideloaded for this file (0 = stage skipped).
    // Optional so jobs saved by older app versions still decode.
    var avifCount: Int?

    init(localURL: URL, bookmarkData: Data? = nil, filename: String, sizeBytes: Int64) {
        self.id = UUID()
        self.localURL = localURL
        self.bookmarkData = bookmarkData
        self.filename = filename
        self.sizeBytes = sizeBytes
        self.status = .queued
    }
}

enum JobStep: String, Codable, Sendable {
    case preflight
    case uploading
    case verifying
    case importing
    case regenerating
    case sideloading
    case finished
    case failed
    case cancelled
}

extension JobStep {
    static let inFlightSteps: Set<JobStep> = [
        .preflight,
        .uploading,
        .verifying,
        .importing,
        .regenerating,
        .sideloading
    ]

    var isTerminal: Bool {
        switch self {
        case .finished, .failed, .cancelled:
            return true
        default:
            return false
        }
    }

    func canTransition(to next: JobStep) -> Bool {
        if self == next {
            return true
        }

        if Self.inFlightSteps.contains(self) {
            return Self.inFlightSteps.contains(next) || next.isTerminal
        }

        if isTerminal {
            return next == .preflight
        }

        return false
    }
}

struct Job: Identifiable, Codable, Sendable {
    var id: UUID
    var profileId: UUID
    var createdAt: Date
    var remoteJobDir: String
    var localFiles: [FileItem]
    var step: JobStep
    var uploadProgress: Double
    var importProgress: Double
    var activeFileId: UUID?
    var errorMessage: String?
    var logsPath: String

    var importedIds: [Int]

    // Snapshot of the profile's "Generate AVIFs locally" setting at job start.
    // Optional so jobs saved by older app versions still decode.
    var avifSideloadEnabled: Bool?

    var avifSideloadOn: Bool {
        avifSideloadEnabled ?? false
    }

    init(profileId: UUID, remoteJobDir: String, files: [FileItem], logsPath: String) {
        self.id = UUID()
        self.profileId = profileId
        self.createdAt = Date()
        self.remoteJobDir = remoteJobDir
        self.localFiles = files
        self.step = .preflight
        self.uploadProgress = 0
        self.importProgress = 0
        self.activeFileId = nil
        self.errorMessage = nil
        self.logsPath = logsPath
        self.importedIds = []
    }

    var failedCount: Int {
        localFiles.count { $0.status == .failed }
    }
}

extension FileItem {
    static func fromURL(_ url: URL, bookmarkData: Data? = nil) -> FileItem? {
        guard url.isFileURL else { return nil }
        do {
            let values = try url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey, .nameKey])
            guard values.isRegularFile == true else { return nil }
            guard let name = values.name else { return nil }
            let size = Int64(values.fileSize ?? 0)
            return FileItem(localURL: url, bookmarkData: bookmarkData, filename: name, sizeBytes: size)
        } catch {
            return nil
        }
    }
}
