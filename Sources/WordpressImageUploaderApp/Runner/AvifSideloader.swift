import Foundation

/// Job-level inputs for AVIF sideloading, resolved once during preflight.
struct AvifSideloadContext: Sendable {
    /// Absolute uploads basedir on the server (wp_upload_dir()["basedir"]).
    var uploadsBaseDir: String
    /// The plugin's aviflosu_quality option (0...100; >=100 means lossless).
    var quality: Int
    /// The plugin's aviflosu_speed option (0...10).
    var speed: Int = 6
    /// The plugin's aviflosu_subsampling option ("420"/"422"/"444").
    var chroma: String = "420"
    /// The plugin's aviflosu_bit_depth option (8/10/12).
    var bitDepth: Int = 8
    /// Embedded avifenc binary when bundled; nil falls back to ImageIO.
    var helperURL: URL? = nil

    /// Plugin semantics: quality 100 switches to lossless encoding.
    var lossless: Bool { quality >= 100 }
}

extension AvifSideloadContext {
    init(uploadsBaseDir: String, settings: AvifPluginSettings, helperURL: URL?) {
        self.init(
            uploadsBaseDir: uploadsBaseDir,
            quality: settings.quality,
            speed: settings.speed,
            chroma: settings.chroma,
            bitDepth: settings.bitDepth,
            helperURL: helperURL
        )
    }
}

/// The avif-local-support plugin's encoder settings as stored in wp_options.
/// Defaults mirror the plugin's own fallbacks; `parse` rejects out-of-range
/// values so a hand-edited option cannot produce an invalid encode.
struct AvifPluginSettings: Equatable, Sendable {
    /// aviflosu_quality (0...100; >=100 means lossless).
    var quality = 85
    /// aviflosu_speed (0...10).
    var speed = 6
    /// aviflosu_subsampling ("420"/"422"/"444").
    var chroma = "420"
    /// aviflosu_bit_depth (8/10/12).
    var bitDepth = 8

    /// One wp-cli eval expression fetching every encoder option in a single
    /// round trip, JSON-encoded so `parse` can strip PHP notices around it.
    static let optionFetchExpression = "echo json_encode(array("
        + "\"quality\"=>(int)get_option(\"aviflosu_quality\",85),"
        + "\"speed\"=>(int)get_option(\"aviflosu_speed\",6),"
        + "\"subsampling\"=>(string)get_option(\"aviflosu_subsampling\",\"420\"),"
        + "\"bit_depth\"=>(string)get_option(\"aviflosu_bit_depth\",\"8\")));"

    /// Parses the eval output, tolerating shell/PHP noise around the JSON.
    /// Any field that is missing, mistyped, or out of range keeps its default.
    static func parse(from rawOutput: String) -> AvifPluginSettings {
        var settings = AvifPluginSettings()
        guard let jsonData = extractJSONObject(from: rawOutput),
              let parsed = try? JSONSerialization.jsonObject(with: jsonData) as? [String: Any]
        else {
            return settings
        }

        if let value = parsed["quality"] as? Int, (0...100).contains(value) {
            settings.quality = value
        }
        if let value = parsed["speed"] as? Int, (0...10).contains(value) {
            settings.speed = value
        }
        if let value = parsed["subsampling"] as? String, ["420", "422", "444"].contains(value) {
            settings.chroma = value
        }
        if let value = parsed["bit_depth"] as? String, let depth = Int(value), [8, 10, 12].contains(depth) {
            settings.bitDepth = depth
        }
        return settings
    }

    /// The job-log line describing the encoder this job will actually use.
    func encoderSummary(usingEmbeddedEncoder: Bool, uploadsBaseDir: String) -> String {
        guard usingEmbeddedEncoder else {
            return "AVIF sideloading enabled (system encoder: quality \(quality); uploads dir \(uploadsBaseDir))."
        }
        let losslessNote = lossless ? ", lossless" : ""
        return "AVIF sideloading enabled (embedded aom encoder: quality \(quality), speed \(speed), "
            + "chroma \(chroma), \(bitDepth)-bit\(losslessNote); uploads dir \(uploadsBaseDir))."
    }

    private var lossless: Bool { quality >= 100 }
}

/// wp-cli eval output may carry login-shell noise ahead of the echoed value;
/// the basedir is the last non-empty line and must be an absolute path.
func parseUploadsBaseDir(fromStdoutLines lines: [String]) -> String? {
    guard let baseDir = lines.last?.trimmingCharacters(in: .whitespacesAndNewlines),
          baseDir.hasPrefix("/")
    else {
        return nil
    }
    return baseDir
}

enum AvifSideloadError: LocalizedError {
    case metadataUnavailable(String)
    case noEncodedOutput(String)
    case uploadVerificationFailed(String)
    case unsafeRemotePath(String)

    var errorDescription: String? {
        switch self {
        case let .metadataUnavailable(detail):
            return "Could not fetch attachment metadata: \(detail)"
        case let .noEncodedOutput(detail):
            return "No AVIF files were produced: \(detail)"
        case let .uploadVerificationFailed(detail):
            return "AVIF upload verification failed: \(detail)"
        case let .unsafeRemotePath(detail):
            return "Refused unsafe remote upload path: \(detail)"
        }
    }
}

/// Runs the per-file sideload stage: fetch attachment metadata, encode AVIF
/// derivatives locally from the original JPEG, rsync them next to the JPEGs
/// in the uploads directory, then trigger LQIP generation on the server.
@MainActor
struct AvifSideloader {
    struct Outcome: Sendable {
        var avifCount: Int
    }

    let transport: SSHTransport

    func sideload(
        profile: ServerProfile,
        auth: SSHAuthContext,
        context: AvifSideloadContext,
        file: FileItem,
        attachmentId: Int,
        jobID: UUID,
        writer: LogWriter?,
        onLine: (@MainActor @Sendable (CommandOutputStream, String) -> Void)? = nil
    ) async throws -> Outcome {
        // 1. Fetch the attachment metadata WordPress just wrote — it names
        //    every derivative (exact filenames and pixel dimensions).
        let wpPath = shellSingleQuote(profile.wpRootPath)
        let metadataCommand = wpCommand(
            "wp --path=\(wpPath) post meta get \(attachmentId) _wp_attachment_metadata --format=json"
        )
        let metadataResult = try await transport.runSSH(
            profile: profile,
            auth: auth,
            remoteCommand: metadataCommand,
            writer: writer,
            onLine: nil
        )

        let rawOutput = metadataResult.stdoutLines.joined(separator: "\n")
        guard let metadataData = extractJSONObject(from: rawOutput) else {
            throw AvifSideloadError.metadataUnavailable("no JSON in response for attachment \(attachmentId)")
        }

        let plan = try AvifTargetPlanner.plan(metadataJSON: metadataData)
        guard !plan.targets.isEmpty else {
            writer?.append("No AVIF targets in metadata for attachment \(attachmentId); skipping.")
            return Outcome(avifCount: 0)
        }

        // 2. Encode locally from the original (read-only sandbox: open the
        //    source via its security-scoped bookmark, write to app temp).
        let fileAccess = try SecurityScopedFileAccess.start(
            url: file.localURL,
            bookmarkData: file.bookmarkData,
            purpose: "AVIF encode source"
        )
        defer { fileAccess.stop() }

        let workDirectory = AppPaths.avifWorkDirectory(jobID: jobID, fileID: file.id)
        defer { try? FileManager.default.removeItem(at: workDirectory) }

        let encoder = AvifEncoder(
            quality: Double(context.quality) / 100.0,
            speed: context.speed,
            chroma: context.chroma,
            bitDepth: context.bitDepth,
            lossless: context.lossless,
            helperURL: context.helperURL
        )
        let sourceURL = fileAccess.url
        let outcome = try await encoder.encode(
            sourceJPEG: sourceURL,
            targets: plan.targets,
            into: workDirectory,
            onEvent: { message in
                // Encoder events originate on concurrent encode tasks and
                // carry no meaningful ordering; a plain hop is fine here.
                Task { @MainActor in
                    onLine?(.stdout, message)
                }
            }
        )

        guard !outcome.encodedFiles.isEmpty else {
            // Every target exceeding the AVIF pixel limit is a legitimate
            // skip (the plugin does the same), not a failure.
            if !outcome.skippedOversizeTargets.isEmpty {
                writer?.append(
                    "All AVIF targets for \(file.filename) exceed the AVIF pixel limit; nothing to sideload."
                )
                return Outcome(avifCount: 0)
            }
            throw AvifSideloadError.noEncodedOutput(file.filename)
        }

        // 3. One rsync carrying every AVIF into the uploads month directory
        //    (it already exists — the JPEG derivatives live there).
        //    rsync -a preserves local modes, so make the files world-readable
        //    before pushing — the webserver must be able to serve them.
        for encodedFile in outcome.encodedFiles {
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o644],
                ofItemAtPath: encodedFile.path
            )
        }

        var remoteDir = ensureNoTrailingSlash(context.uploadsBaseDir)
        if !plan.remoteSubdirectory.isEmpty {
            // The subdirectory comes from server-supplied metadata; make sure
            // it cannot escape the uploads tree before we write into it.
            guard !plan.remoteSubdirectory.hasPrefix("/"),
                  !plan.remoteSubdirectory.split(separator: "/").contains("..")
            else {
                throw AvifSideloadError.unsafeRemotePath(
                    "'\(plan.remoteSubdirectory)' for attachment \(attachmentId)"
                )
            }
            remoteDir += "/\(plan.remoteSubdirectory)"
        }
        try await transport.runRsyncFiles(
            profile: profile,
            auth: auth,
            localFileURLs: outcome.encodedFiles,
            remoteTargetPath: remoteDir + "/",
            transferMode: .overwrite,
            writer: writer,
            onLine: onLine
        )

        // 3b. These files were written straight into the live site, so confirm
        //     each one landed with the exact size we encoded locally.
        try await verifyUploadedSizes(
            profile: profile,
            auth: auth,
            encodedFiles: outcome.encodedFiles,
            remoteDir: remoteDir,
            writer: writer
        )

        // 4. Generate the LQIP/ThumbHash placeholder now (the plugin's
        //    on-upload hook was skipped). Tolerated failure: LQIP may be
        //    disabled in plugin settings, and the daily scan backfills.
        let lqipCommand = wpCommand("wp --path=\(wpPath) lqip generate \(attachmentId)")
        do {
            _ = try await transport.runSSH(
                profile: profile,
                auth: auth,
                remoteCommand: lqipCommand,
                writer: writer,
                onLine: onLine
            )
        } catch {
            if Task.isCancelled { throw CancellationError() }
            writer?.append("LQIP generation skipped for attachment \(attachmentId): \(error.localizedDescription)")
        }

        return Outcome(avifCount: outcome.encodedFiles.count)
    }

    private func verifyUploadedSizes(
        profile: ServerProfile,
        auth: SSHAuthContext,
        encodedFiles: [URL],
        remoteDir: String,
        writer: LogWriter?
    ) async throws {
        let localSizes = try encodedFiles.map { url -> Int64 in
            let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
            return (attributes[.size] as? Int64) ?? -1
        }
        let remotePaths = encodedFiles.map { "\(remoteDir)/\($0.lastPathComponent)" }

        let remoteSizes = try await transport.fetchRemoteFileSizes(
            profile: profile,
            auth: auth,
            remotePaths: remotePaths,
            writer: writer
        )

        for (index, remoteSize) in remoteSizes.enumerated() {
            let filename = encodedFiles[index].lastPathComponent
            guard let remoteSize else {
                throw AvifSideloadError.uploadVerificationFailed("\(filename) is missing on the server")
            }
            guard remoteSize == localSizes[index] else {
                throw AvifSideloadError.uploadVerificationFailed(
                    "\(filename) size mismatch (local \(localSizes[index]) bytes, remote \(remoteSize) bytes)"
                )
            }
        }
    }
}
