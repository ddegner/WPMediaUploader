import SwiftUI

// Single source for status → color/icon mappings, shared by file rows,
// status dots, and the job header so they can never disagree.

extension FileRowTone {
    var color: Color {
        switch self {
        case .failure: .red
        case .success: .green
        case .progress: .blue
        case .secondary: .secondary
        }
    }
}

extension FileItemStatus {
    var displayTone: FileRowTone {
        switch self {
        case .failed: .failure
        case .regenerated, .sideloaded: .success
        case .imported, .verified, .uploaded: .progress
        case .queued: .secondary
        }
    }

    var displayColor: Color { displayTone.color }
}

extension JobStep {
    var displayColor: Color {
        switch self {
        case .finished: .green
        case .failed, .cancelled: .red
        default: .accentColor
        }
    }

    var displayIcon: String {
        switch self {
        case .preflight: "network"
        case .uploading: "arrow.up.circle"
        case .verifying: "checkmark.shield"
        case .importing: "square.and.arrow.down"
        case .regenerating: "arrow.triangle.2.circlepath"
        case .sideloading: "photo.stack"
        case .finished: "checkmark.circle.fill"
        case .failed: "exclamationmark.triangle.fill"
        case .cancelled: "xmark.circle"
        }
    }

    var displayTitle: String { rawValue.capitalized }
}
