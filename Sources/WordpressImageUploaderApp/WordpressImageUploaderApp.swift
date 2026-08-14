import AppKit
import SwiftUI

struct WordpressMediaUploaderApp: App {
    private static let repositoryURL = URL(string: "https://github.com/ddegner/wp-media-uploader")!

    private enum AppearanceMode: String, CaseIterable, Identifiable {
        case auto
        case light
        case dark

        var id: String { rawValue }

        var displayName: String {
            switch self {
            case .auto: return "Auto"
            case .light: return "Light"
            case .dark: return "Dark"
            }
        }

        var preferredColorScheme: ColorScheme? {
            switch self {
            case .auto: return nil
            case .light: return .light
            case .dark: return .dark
            }
        }

        var nsAppearance: NSAppearance? {
            switch self {
            case .auto: return nil
            case .light: return NSAppearance(named: .aqua)
            case .dark: return NSAppearance(named: .darkAqua)
            }
        }
    }

    @State private var profileStore: ProfileStore
    @State private var jobStore: JobStore
    @State private var externalFileIntake: ExternalFileIntake
    @AppStorage("appearanceMode") private var appearanceModeRaw = AppearanceMode.auto.rawValue
    @AppStorage(JobRunner.playCompletionSoundDefaultsKey) private var playCompletionSoundOnCompletion = false
    @AppStorage(JobRunner.showCompletionNotificationDefaultsKey) private var showCompletionNotificationOnCompletion = false
    @FocusedBinding(\.showProfilesDrawerBinding) private var focusedShowProfilesDrawer: Bool?
    @FocusedBinding(\.showOperationsDrawerBinding) private var focusedShowOperationsDrawer: Bool?
    @FocusedValue(\.windowCommandActions) private var focusedWindowCommandActions
    @NSApplicationDelegateAdaptor(DockFileOpenDelegate.self) private var dockFileOpenDelegate

    init() {
        let profiles = ProfileStore()
        let jobs = JobStore()
        let fileIntake = ExternalFileIntake.shared

        _profileStore = State(initialValue: profiles)
        _jobStore = State(initialValue: jobs)
        _externalFileIntake = State(initialValue: fileIntake)
    }

    private var appearanceMode: AppearanceMode {
        get { AppearanceMode(rawValue: appearanceModeRaw) ?? .auto }
        set { appearanceModeRaw = newValue.rawValue }
    }

    private var appDisplayName: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String
            ?? Bundle.main.object(forInfoDictionaryKey: "CFBundleName") as? String
            ?? "WP Media Uploader"
    }

    private var focusedShowProfilesDrawerToggleBinding: Binding<Bool> {
        Binding(
            get: { focusedShowProfilesDrawer ?? true },
            set: { focusedShowProfilesDrawer = $0 }
        )
    }

    private var focusedShowOperationsDrawerToggleBinding: Binding<Bool> {
        Binding(
            get: { focusedShowOperationsDrawer ?? true },
            set: { focusedShowOperationsDrawer = $0 }
        )
    }

    private func applyAppearance() {
        NSApp.appearance = appearanceMode.nsAppearance
    }

    private func showAboutWindow() {
        NSApp.orderFrontStandardAboutPanel(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func openGitHubRepository() {
        NSWorkspace.shared.open(Self.repositoryURL)
    }

    private struct AppSettingsView: View {
        @Binding var appearanceModeRaw: String
        @Binding var playCompletionSoundOnCompletion: Bool
        @Binding var showCompletionNotificationOnCompletion: Bool

        var body: some View {
            Form {
                Picker("Appearance", selection: $appearanceModeRaw) {
                    ForEach(AppearanceMode.allCases) { mode in
                        Text(mode.displayName).tag(mode.rawValue)
                    }
                }
                .pickerStyle(.menu)

                Toggle("Play sound when uploads complete", isOn: $playCompletionSoundOnCompletion)
                Toggle("Show macOS notification when uploads complete", isOn: $showCompletionNotificationOnCompletion)
            }
            .formStyle(.grouped)
            .padding(20)
            .frame(width: 420)
        }
    }

    var body: some Scene {
        Window("WP Media Uploader", id: "main") {
            AppWindowRootView(
                profileStore: profileStore,
                jobStore: jobStore,
                externalFileIntake: externalFileIntake
            )
            .preferredColorScheme(appearanceMode.preferredColorScheme)
            .onAppear {
                applyAppearance()
                if showCompletionNotificationOnCompletion {
                    JobRunner.requestCompletionNotificationAuthorizationIfNeeded()
                }
            }
            .onChange(of: appearanceModeRaw) { _, _ in
                applyAppearance()
            }
            .onChange(of: showCompletionNotificationOnCompletion) { _, isEnabled in
                guard isEnabled else { return }
                JobRunner.requestCompletionNotificationAuthorizationIfNeeded()
            }
        }
        .windowResizability(.contentMinSize)
        .defaultSize(width: WorkspaceLayoutState.defaultWindowSize.width, height: WorkspaceLayoutState.defaultWindowSize.height)
        .commands {
            CommandGroup(replacing: .appInfo) {
                Button("About \(appDisplayName)") {
                    showAboutWindow()
                }
            }

            // File menu
            CommandGroup(replacing: .newItem) {
                Button("New Profile…") {
                    focusedWindowCommandActions?.createProfile()
                }
                .keyboardShortcut("n", modifiers: [.command])
                .disabled(focusedWindowCommandActions == nil)
            }

            CommandGroup(after: .newItem) {
                Button("Edit Selected Profile…") {
                    focusedWindowCommandActions?.editSelectedProfile()
                }
                .keyboardShortcut("e", modifiers: [.command])
                .disabled(!(focusedWindowCommandActions?.canEditSelectedProfile ?? false))

                Button("Delete Selected Profile") {
                    focusedWindowCommandActions?.deleteSelectedProfile()
                }
                .keyboardShortcut(.delete, modifiers: [.command, .option])
                .disabled(!(focusedWindowCommandActions?.canDeleteSelectedProfile ?? false))
            }

            CommandGroup(after: .saveItem) {
                Divider()
                Button("Start Upload") {
                    focusedWindowCommandActions?.startUpload()
                }
                .keyboardShortcut(.return, modifiers: [.command])
                .disabled(!(focusedWindowCommandActions?.canStartUpload ?? false))

                Button("Stop Upload") {
                    focusedWindowCommandActions?.stopUpload()
                }
                .keyboardShortcut(".", modifiers: [.command])
                .disabled(!(focusedWindowCommandActions?.canStopUpload ?? false))

                Button("Retry Failed Files") {
                    focusedWindowCommandActions?.retryFailedFiles()
                }
                .keyboardShortcut("r", modifiers: [.command])
                .disabled(!(focusedWindowCommandActions?.canRetryFailedFiles ?? false))

                Divider()
                Button("Reset Queue and Current Job") {
                    focusedWindowCommandActions?.resetQueueAndCurrentJob()
                }
                .keyboardShortcut("r", modifiers: [.command, .shift])
                .disabled(!(focusedWindowCommandActions?.canResetQueueAndCurrentJob ?? false))

                Button("Clear Job History") {
                    focusedWindowCommandActions?.clearJobHistory()
                }
                .keyboardShortcut("k", modifiers: [.command, .shift])
                .disabled(!(focusedWindowCommandActions?.canClearJobHistory ?? false))
            }

            CommandGroup(replacing: .importExport) {
                Button("Add Files…") {
                    focusedWindowCommandActions?.addFiles()
                }
                .keyboardShortcut("o", modifiers: [.command])
                .disabled(focusedWindowCommandActions == nil)

                Button("Delete Selected Files") {
                    focusedWindowCommandActions?.deleteSelectedFiles()
                }
                // ⌘⌫, not bare Delete: a menu key equivalent is consulted
                // before first-responder key handling, so bare Delete would
                // steal Backspace from every text field. The file list
                // itself already handles plain Delete via .onDeleteCommand.
                .keyboardShortcut(.delete, modifiers: [.command])
                .disabled(!(focusedWindowCommandActions?.canDeleteSelectedFiles ?? false))

                Divider()
                Menu("Reports") {
                    Button("Open Current Job Log") {
                        focusedWindowCommandActions?.openLog()
                    }
                    .keyboardShortcut("l", modifiers: [.command, .option])
                    .disabled(!(focusedWindowCommandActions?.canOpenLog ?? false))

                    Button("Copy Terminal") {
                        focusedWindowCommandActions?.copyVisibleLog()
                    }
                    .keyboardShortcut("c", modifiers: [.command, .option, .shift])
                    .disabled(!(focusedWindowCommandActions?.canCopyVisibleLog ?? false))

                    Button("Copy Current Job Report") {
                        focusedWindowCommandActions?.copyReport()
                    }
                    .keyboardShortcut("c", modifiers: [.command, .option])
                    .disabled(!(focusedWindowCommandActions?.canCopyReport ?? false))

                    Divider()
                    Button("Export JSON Report…") {
                        focusedWindowCommandActions?.exportJSONReport()
                    }
                    .keyboardShortcut("j", modifiers: [.command, .option])
                    .disabled(!(focusedWindowCommandActions?.canExportJSONReport ?? false))

                    Button("Export CSV Report…") {
                        focusedWindowCommandActions?.exportCSVReport()
                    }
                    .keyboardShortcut("v", modifiers: [.command, .option])
                    .disabled(!(focusedWindowCommandActions?.canExportCSVReport ?? false))
                }
            }

            // View menu
            CommandGroup(after: .toolbar) {
                Divider()
                Toggle("Show Sidebar", isOn: focusedShowProfilesDrawerToggleBinding)
                    .disabled(focusedShowProfilesDrawer == nil)
                    .keyboardShortcut("s", modifiers: [.command, .control])

                Toggle("Show Inspector", isOn: focusedShowOperationsDrawerToggleBinding)
                    .disabled(focusedShowOperationsDrawer == nil)
                    .keyboardShortcut("i", modifiers: [.command, .option])

                Divider()
                Button("Show Active Job") {
                    focusedWindowCommandActions?.showActiveJobTab()
                }
                .keyboardShortcut("1", modifiers: [.command])
                .disabled(focusedWindowCommandActions == nil)

                Button("Show Terminal") {
                    focusedWindowCommandActions?.showTerminalTab()
                }
                .keyboardShortcut("2", modifiers: [.command])
                .disabled(focusedWindowCommandActions == nil)

                Button("Show Job History") {
                    focusedWindowCommandActions?.showJobHistoryTab()
                }
                .keyboardShortcut("3", modifiers: [.command])
                .disabled(focusedWindowCommandActions == nil)
            }

            CommandGroup(replacing: .help) {
                Button("Project on GitHub") {
                    openGitHubRepository()
                }
            }

        }

        Settings {
            AppSettingsView(
                appearanceModeRaw: $appearanceModeRaw,
                playCompletionSoundOnCompletion: $playCompletionSoundOnCompletion,
                showCompletionNotificationOnCompletion: $showCompletionNotificationOnCompletion
            )
        }
    }
}

private struct AppWindowRootView: View {
    @Bindable var profileStore: ProfileStore
    @Bindable var jobStore: JobStore
    @Bindable var externalFileIntake: ExternalFileIntake
    @State private var jobRunner: JobRunner

    init(profileStore: ProfileStore, jobStore: JobStore, externalFileIntake: ExternalFileIntake) {
        self.profileStore = profileStore
        self.jobStore = jobStore
        self.externalFileIntake = externalFileIntake
        _jobRunner = State(initialValue: JobRunner(profileStore: profileStore, jobStore: jobStore))
    }

    var body: some View {
        ContentView(
            profileStore: profileStore,
            jobStore: jobStore,
            jobRunner: jobRunner,
            externalFileIntake: externalFileIntake
        )
    }
}
