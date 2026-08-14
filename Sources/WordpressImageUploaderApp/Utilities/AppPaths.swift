import Foundation

enum AppPaths {
    static let appFolderName = "WPMediaUploader"
    private static let legacyAppFolderName = "WordpressMediaUploader"

    private static let _appSupportDirectory: URL = {
        let fm = FileManager.default
        let base =
            fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? fm.homeDirectoryForCurrentUser
                .appendingPathComponent("Library", isDirectory: true)
                .appendingPathComponent("Application Support", isDirectory: true)
        let preferredDir = base.appendingPathComponent(appFolderName, isDirectory: true)
        let legacyDir = base.appendingPathComponent(legacyAppFolderName, isDirectory: true)

        if fm.fileExists(atPath: preferredDir.path) {
            ensureDirectory(preferredDir)
            return preferredDir
        }

        if fm.fileExists(atPath: legacyDir.path) {
            do {
                try fm.moveItem(at: legacyDir, to: preferredDir)
                ensureDirectory(preferredDir)
                return preferredDir
            } catch {
                ensureDirectory(legacyDir)
                return legacyDir
            }
        }

        ensureDirectory(preferredDir)
        return preferredDir
    }()
    
    static var appSupportDirectory: URL { _appSupportDirectory }

    static var profilesFile: URL {
        appSupportDirectory.appendingPathComponent("profiles.json", isDirectory: false)
    }

    static var jobsFile: URL {
        appSupportDirectory.appendingPathComponent("jobs.json", isDirectory: false)
    }

    static var logsDirectory: URL {
        let dir = appSupportDirectory.appendingPathComponent("logs", isDirectory: true)
        ensureDirectory(dir)
        return dir
    }

    /// Root scratch directory for locally encoded AVIF derivatives.
    /// Swept at app launch; per-file subdirectories are removed after upload.
    static var avifWorkRootDirectory: URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent(appFolderName, isDirectory: true)
            .appendingPathComponent("avif", isDirectory: true)
    }

    static func avifWorkDirectory(jobID: UUID, fileID: UUID) -> URL {
        let dir = avifWorkRootDirectory
            .appendingPathComponent(jobID.uuidString, isDirectory: true)
            .appendingPathComponent(fileID.uuidString, isDirectory: true)
        ensureDirectory(dir)
        return dir
    }

    @discardableResult
    static func ensureDirectory(_ url: URL) -> URL {
        if !FileManager.default.fileExists(atPath: url.path) {
            try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        }
        return url
    }
}
