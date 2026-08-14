import Foundation

enum FileRowTone: Sendable {
    case secondary
    case progress
    case success
    case failure
}

enum FileRowStatus: Equatable, Sendable {
    case preflight
    case queued
    case uploading
    case uploaded
    case verifying
    case verified
    case importing
    case imported
    case regenerating
    case regenerated
    case sideloading
    case sideloaded
    case failed

    var label: String {
        switch self {
        case .preflight: return "preflight"
        case .queued: return "queued"
        case .uploading: return "uploading"
        case .uploaded: return "uploaded"
        case .verifying: return "verifying"
        case .verified: return "verified"
        case .importing: return "importing"
        case .imported: return "imported"
        case .regenerating: return "regenerating"
        case .regenerated: return "regenerated"
        case .sideloading: return "sideloading"
        case .sideloaded: return "sideloaded"
        case .failed: return "failed"
        }
    }

    var tone: FileRowTone {
        switch self {
        case .failed:
            return .failure
        case .regenerated, .sideloaded:
            return .success
        case .preflight, .uploading, .uploaded, .verifying, .verified, .importing, .imported, .regenerating,
             .sideloading:
            return .progress
        case .queued:
            return .secondary
        }
    }

    static func resolve(
        item: FileItem,
        isQueuedSource: Bool,
        isActiveFile: Bool,
        currentStep: JobStep?
    ) -> FileRowStatus {
        if isQueuedSource {
            return .queued
        }

        if currentStep == .preflight, item.status == .queued {
            return .preflight
        }

        if isActiveFile, let currentStep {
            switch currentStep {
            case .uploading:
                return .uploading
            case .verifying:
                return .verifying
            case .importing:
                return .importing
            case .regenerating:
                return .regenerating
            case .sideloading:
                return .sideloading
            default:
                break
            }
        }

        switch item.status {
        case .queued:
            return .queued
        case .uploaded:
            return .uploaded
        case .verified:
            return .verified
        case .imported:
            return .imported
        case .regenerated:
            return .regenerated
        case .sideloaded:
            return .sideloaded
        case .failed:
            return .failed
        }
    }
}

enum FileRowPresentation {
    static func helpText(for item: FileItem, rowStatus: FileRowStatus, isQueuedSource: Bool) -> String {
        if isQueuedSource {
            return "Queued for next run"
        }

        if rowStatus == .preflight {
            return "Running preflight checks and preparing staging."
        }

        switch item.status {
        case .failed:
            if let error = item.errorMessage, !error.isEmpty {
                return error
            }
            return "Failed"
        case .uploaded:
            if let remotePath = item.remotePath, !remotePath.isEmpty {
                return "Uploaded to \(remotePath)"
            }
            return "Uploaded"
        case .verified:
            if let remotePath = item.remotePath, !remotePath.isEmpty {
                return "Verified upload at \(remotePath)"
            }
            return "Upload verified"
        case .imported:
            if let attachmentId = item.importAttachmentId {
                return "Imported as attachment ID \(attachmentId)"
            }
            return "Imported"
        case .regenerated:
            if let attachmentId = item.importAttachmentId {
                return "Imported as attachment ID \(attachmentId) and regenerated"
            }
            return "Imported and regenerated"
        case .sideloaded:
            let base: String
            if let attachmentId = item.importAttachmentId {
                base = "Imported as attachment ID \(attachmentId)"
            } else {
                base = "Imported"
            }
            if let avifCount = item.avifCount, avifCount > 0 {
                return "\(base), \(avifCount) AVIF file(s) sideloaded"
            }
            return "\(base), AVIF sideload skipped (not a JPEG)"
        case .queued:
            return "Waiting to upload"
        }
    }
}

struct JobRuntimeAnchor: Sendable {
    let startedAt: Date
    let processedBaseline: Int
}

private struct JobRuntimeEstimate: Sendable {
    let filesPerMinute: Double
    let secondsRemaining: TimeInterval
}

struct JobPresentation: Sendable {
    let totalFiles: Int
    let processedFiles: Int
    let successfulFiles: Int
    let failedFiles: Int
    let remainingFiles: Int

    let statusLine: String
    let progressLabel: String
    let etaLine: String
    let rateLine: String
    let overallProgress: Double

    /// The terminal success status for a job: sideload-enabled jobs finish
    /// files at .sideloaded, others at .regenerated.
    static func successStatus(for job: Job) -> FileItemStatus {
        job.avifSideloadOn ? .sideloaded : .regenerated
    }

    static func processedFileCount(in job: Job) -> Int {
        let success = successStatus(for: job)
        return job.localFiles.count { item in
            item.status == success || item.status == .failed
        }
    }

    private static let etaFormatStyle = Duration.UnitsFormatStyle.units(
        allowed: [.hours, .minutes],
        width: .narrow,
        maximumUnitCount: 2
    )

    static func make(
        for job: Job,
        activeFileStatus: FileRowStatus?,
        now: Date,
        anchor: JobRuntimeAnchor?
    ) -> JobPresentation {
        let totalFiles = job.localFiles.count
        let processedFiles = processedFileCount(in: job)
        let successStatus = successStatus(for: job)
        let successfulFiles = job.localFiles.count { $0.status == successStatus }
        let failedFiles = job.failedCount
        let remainingFiles = max(totalFiles - processedFiles, 0)

        let runtimeEstimate = estimateRuntime(
            for: job,
            processedFiles: processedFiles,
            now: now,
            anchor: anchor
        )

        let etaLine: String = if job.step.isTerminal {
            "Complete"
        } else if let runtimeEstimate {
            if runtimeEstimate.secondsRemaining < 60 {
                "<1 min"
            } else {
                Duration.seconds(runtimeEstimate.secondsRemaining).formatted(etaFormatStyle)
            }
        } else {
            "Estimating..."
        }

        let rateLine: String = if let runtimeEstimate {
            String(format: "%.1f files/min", runtimeEstimate.filesPerMinute)
        } else {
            job.step.isTerminal ? "n/a" : "Estimating..."
        }

        return JobPresentation(
            totalFiles: totalFiles,
            processedFiles: processedFiles,
            successfulFiles: successfulFiles,
            failedFiles: failedFiles,
            remainingFiles: remainingFiles,
            statusLine: statusLine(for: job, processedFiles: processedFiles, activeFileStatus: activeFileStatus),
            progressLabel: totalFiles > 0 ? "\(processedFiles)/\(totalFiles) processed" : "0/0 processed",
            etaLine: etaLine,
            rateLine: rateLine,
            overallProgress: progress(for: job, processedFiles: processedFiles)
        )
    }

    private static func progress(for job: Job, processedFiles: Int) -> Double {
        let total = job.localFiles.count
        guard total > 0 else { return 0 }

        // Weight each file's contribution by how far through the pipeline it
        // has progressed (upload → verify → import → regenerate [→ sideload]).
        // This produces a smoothly advancing bar instead of one that only
        // jumps when a file fully completes.
        let stepsPerFile = job.avifSideloadOn ? 5.0 : 4.0
        let totalSteps = Double(total) * stepsPerFile

        var completedSteps = 0.0
        for file in job.localFiles {
            completedSteps += stepWeight(for: file.status, stepsPerFile: stepsPerFile)
        }

        // During an active rsync upload, blend in the per-file transfer
        // progress so the bar moves even within a single large upload.
        if job.step == .uploading,
           let activeFileId = job.activeFileId,
           let activeFile = job.localFiles.first(where: { $0.id == activeFileId }),
           activeFile.status == .queued
        {
            let alreadyUploaded = Double(job.localFiles.count {
                [.uploaded, .verified, .imported, .regenerated, .sideloaded, .failed].contains($0.status)
            })
            let rsyncFraction = max(0, min(1, job.uploadProgress * Double(total) - alreadyUploaded))
            completedSteps += rsyncFraction
        }

        return min(completedSteps / totalSteps, 1.0)
    }

    private static func stepWeight(for status: FileItemStatus, stepsPerFile: Double) -> Double {
        switch status {
        case .queued:       return 0
        case .uploaded:     return 1
        case .verified:     return 2
        case .imported:     return 3
        case .regenerated:  return 4
        case .sideloaded:   return 5
        case .failed:       return stepsPerFile
        }
    }

    private static func statusLine(for job: Job, processedFiles: Int, activeFileStatus: FileRowStatus?) -> String {
        let total = job.localFiles.count
        guard total > 0 else { return "No files queued." }

        if job.step == .preflight {
            return "Running preflight checks and preparing staging."
        }

        if let activeFileId = job.activeFileId,
           let index = job.localFiles.firstIndex(where: { $0.id == activeFileId })
        {
            let activeFile = job.localFiles[index]
            let statusLabel = (activeFileStatus?.label ?? "working").capitalized
            return "File \(index + 1) of \(total): \(activeFile.filename) • \(statusLabel)"
        }

        if job.step.isTerminal {
            return "\(processedFiles)/\(total) files processed."
        }

        if let nextIndex = job.localFiles.firstIndex(where: { file in
            file.status == .queued || file.status == .uploaded || file.status == .verified
                || file.status == .imported
                || (job.avifSideloadOn && file.status == .regenerated)
        }) {
            return "Next file \(nextIndex + 1) of \(total): \(job.localFiles[nextIndex].filename)"
        }

        return "\(processedFiles)/\(total) files processed."
    }

    private static func estimateRuntime(
        for job: Job,
        processedFiles: Int,
        now: Date,
        anchor: JobRuntimeAnchor?
    ) -> JobRuntimeEstimate? {
        guard let anchor else { return nil }

        let elapsed = now.timeIntervalSince(anchor.startedAt)
        guard elapsed > 5 else { return nil }

        let completedSinceStart = processedFiles - anchor.processedBaseline
        guard completedSinceStart > 0 else { return nil }

        let filesPerSecond = Double(completedSinceStart) / elapsed
        guard filesPerSecond > 0 else { return nil }

        let remainingFiles = max(job.localFiles.count - processedFiles, 0)
        let secondsRemaining = Double(remainingFiles) / filesPerSecond
        return JobRuntimeEstimate(
            filesPerMinute: filesPerSecond * 60,
            secondsRemaining: max(secondsRemaining, 0)
        )
    }
}
