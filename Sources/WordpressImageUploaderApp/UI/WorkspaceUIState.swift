import SwiftUI

enum WorkspaceOperationsTab: String, CaseIterable, Identifiable, Sendable {
    case activeJob
    case terminal
    case history

    var id: String { rawValue }

    var title: String {
        switch self {
        case .activeJob: return "Active Job"
        case .terminal: return "Terminal"
        case .history: return "Job History"
        }
    }

    var systemImage: String {
        switch self {
        case .activeJob: return "hourglass"
        case .terminal: return "chevron.left.forwardslash.chevron.right"
        case .history: return "clock"
        }
    }
}

enum WorkspaceLayoutState {
    static let showProfilesDrawerKey = "workspace.showProfilesDrawer"
    static let showOperationsDrawerKey = "workspace.showOperationsDrawer"
    static let operationsTabKey = "workspace.operationsTab"

    static let defaultShowProfilesDrawer = true
    static let defaultShowOperationsDrawer = true
    static let defaultOperationsTab: WorkspaceOperationsTab = .activeJob
    static let defaultWindowSize = CGSize(width: 1180, height: 760)

    static func restoredOperationsTab(from rawValue: String) -> WorkspaceOperationsTab {
        WorkspaceOperationsTab(rawValue: rawValue) ?? defaultOperationsTab
    }

    // Initial state read at view construction so drawers start in their
    // persisted positions instead of flashing open and animating closed.
    static func initialSplitVisibility(defaults: UserDefaults = .standard) -> NavigationSplitViewVisibility {
        let show = defaults.object(forKey: showProfilesDrawerKey) as? Bool ?? defaultShowProfilesDrawer
        return splitVisibility(forProfilesDrawer: show)
    }

    static func initialOperationsPane(defaults: UserDefaults = .standard) -> WorkspaceOperationsTab? {
        guard initialOperationsDrawerVisible(defaults: defaults) else { return nil }
        return initialOperationsTab(defaults: defaults)
    }

    // Visibility and selected tab are separate pieces of state: hiding the
    // inspector must not forget which tab was showing.
    static func initialOperationsDrawerVisible(defaults: UserDefaults = .standard) -> Bool {
        defaults.object(forKey: showOperationsDrawerKey) as? Bool ?? defaultShowOperationsDrawer
    }

    static func initialOperationsTab(defaults: UserDefaults = .standard) -> WorkspaceOperationsTab {
        restoredOperationsTab(from: defaults.string(forKey: operationsTabKey) ?? "")
    }

    // Write-side API: every UserDefaults write for workspace layout goes
    // through here so the persistence contract lives in one place.
    static func persistProfilesDrawer(visible: Bool, defaults: UserDefaults = .standard) {
        defaults.set(visible, forKey: showProfilesDrawerKey)
    }

    static func persistOperationsDrawer(visible: Bool, defaults: UserDefaults = .standard) {
        defaults.set(visible, forKey: showOperationsDrawerKey)
    }

    static func persistOperationsTab(_ tab: WorkspaceOperationsTab, defaults: UserDefaults = .standard) {
        defaults.set(tab.rawValue, forKey: operationsTabKey)
    }

    static func splitVisibility(forProfilesDrawer isVisible: Bool) -> NavigationSplitViewVisibility {
        isVisible ? .all : .detailOnly
    }

    static func profilesDrawerVisible(for visibility: NavigationSplitViewVisibility) -> Bool {
        switch visibility {
        case .detailOnly:
            return false
        default:
            return true
        }
    }
}

enum WorkspaceCommandState {
    static func canStartUpload(isRunning: Bool, hasSelectedProfile: Bool, queuedCount: Int) -> Bool {
        !isRunning && hasSelectedProfile && queuedCount > 0
    }

    static func canStopUpload(isRunning: Bool) -> Bool {
        isRunning
    }

    static func canClearFiles(isRunning: Bool, queuedCount: Int, hasCurrentJob: Bool) -> Bool {
        !isRunning && (queuedCount > 0 || hasCurrentJob)
    }

    static func canDeleteSelectedFiles(isRunning: Bool, selectedCount: Int, hasQueuedSelection: Bool) -> Bool {
        !isRunning && selectedCount > 0 && hasQueuedSelection
    }

    static func canClearJobHistory(isRunning: Bool, jobCount: Int) -> Bool {
        !isRunning && jobCount > 0
    }
}
