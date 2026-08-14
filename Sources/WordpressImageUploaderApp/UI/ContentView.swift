import AppKit
import QuickLook
import QuickLookThumbnailing
import SwiftUI
import UniformTypeIdentifiers

@MainActor
private final class ThumbnailProvider {
    static let shared = ThumbnailProvider()

    private let cache = NSCache<NSString, NSImage>()
    private var inFlight: [String: [CheckedContinuation<NSImage?, Never>]] = [:]

    private init() {
        cache.countLimit = 500
    }

    func thumbnail(for url: URL, size: CGSize, scale: CGFloat) async -> NSImage? {
        let key = cacheKey(for: url, size: size, scale: scale)
        if let cached = cache.object(forKey: key as NSString) {
            return cached
        }

        return await withCheckedContinuation { continuation in
            if inFlight[key] != nil {
                inFlight[key, default: []].append(continuation)
                return
            }
            inFlight[key] = [continuation]

            let request = QLThumbnailGenerator.Request(
                fileAt: url,
                size: size,
                scale: scale,
                representationTypes: .thumbnail
            )

            QLThumbnailGenerator.shared.generateBestRepresentation(for: request) { [key] representation, _ in
                let image = representation?.nsImage
                Task { @MainActor in
                    if let image {
                        self.cache.setObject(image, forKey: key as NSString)
                    }
                    let continuations = self.inFlight[key] ?? []
                    self.inFlight[key] = nil
                    for continuation in continuations {
                        continuation.resume(returning: image)
                    }
                }
            }
        }
    }

    private func cacheKey(for url: URL, size: CGSize, scale: CGFloat) -> String {
        let pxWidth = Int((size.width * scale).rounded())
        let pxHeight = Int((size.height * scale).rounded())
        return "\(url.standardizedFileURL.path)|\(pxWidth)x\(pxHeight)"
    }
}

private struct FileThumbnailIcon: View {
    @Environment(\.displayScale) private var displayScale

    let url: URL
    var size: CGFloat = 20

    @State private var image: NSImage?

    var body: some View {
        Group {
            if let image {
                Image(nsImage: image)
                    .resizable()
                    .scaledToFill()
                    .frame(width: size, height: size)
                    .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
                    .overlay {
                        RoundedRectangle(cornerRadius: 4, style: .continuous)
                            .strokeBorder(.primary.opacity(0.08))
                    }
            } else {
                Image(nsImage: NSWorkspace.shared.icon(forFile: url.path))
                    .resizable()
                    .frame(width: size, height: size)
            }
        }
        .task(id: url) { @MainActor in
            image = await ThumbnailProvider.shared.thumbnail(
                for: url,
                size: CGSize(width: size, height: size),
                scale: displayScale
            )
        }
    }
}

// Queue storage lives in a class so queue edits can register with
// NSUndoManager (which needs an object target that outlives the view value).
@MainActor
@Observable
private final class FileQueue {
    var items: [FileItem] = []

    // Snapshot-based undo: registrations made while undoing become redo
    // (NSUndoManager's redo-during-undo rule), so one recursive helper
    // covers both directions.
    func setItems(_ newItems: [FileItem], actionName: String, undoManager: UndoManager?) {
        let oldItems = items
        guard newItems != oldItems else { return }
        items = newItems

        guard let undoManager else { return }
        undoManager.registerUndo(withTarget: self) { queue in
            MainActor.assumeIsolated {
                queue.setItems(oldItems, actionName: actionName, undoManager: undoManager)
            }
        }
        undoManager.setActionName(actionName)
    }
}

struct ContentView: View {
    private static let profilesDrawerMinWidth: CGFloat = 200
    private static let profilesDrawerWidth: CGFloat = 260
    private static let profilesDrawerMaxWidth: CGFloat = 340
    private static let workbenchMinWidth: CGFloat = 180
    private static let visibleLogLineLimit = 300

    private struct ProfileEditorDraft: Identifiable {
        let id: UUID
        var profile: ServerProfile
        var initialPassword: String?
        var initialKeyPassphrase: String?

        init(profile: ServerProfile, initialPassword: String?, initialKeyPassphrase: String?) {
            id = profile.id
            self.profile = profile
            self.initialPassword = initialPassword
            self.initialKeyPassphrase = initialKeyPassphrase
        }
    }

    private struct DisplayFile: Identifiable {
        private static let currentJobRowPrefix = "job-"
        private static let queuedRowPrefix = "queued-"

        enum Source {
            case currentJob
            case queued
        }

        let source: Source
        let item: FileItem

        static func currentJobRowID(for id: UUID) -> String {
            "\(currentJobRowPrefix)\(id.uuidString)"
        }

        static func queuedRowID(for id: UUID) -> String {
            "\(queuedRowPrefix)\(id.uuidString)"
        }

        static func isQueuedRowID(_ rowID: String) -> Bool {
            rowID.hasPrefix(queuedRowPrefix)
        }

        var id: String {
            switch source {
            case .currentJob:
                return Self.currentJobRowID(for: item.id)
            case .queued:
                return Self.queuedRowID(for: item.id)
            }
        }
    }

    @Bindable var profileStore: ProfileStore
    @Bindable var jobStore: JobStore
    @Bindable var jobRunner: JobRunner
    @Bindable var externalFileIntake: ExternalFileIntake

    @Environment(\.appearsActive) private var appearsActive
    @Environment(\.undoManager) private var undoManager

    @State private var fileQueue = FileQueue()
    @State private var isDropTargeted = false
    @State private var selectedFileRowIDs: Set<String> = []
    @State private var profileEditorDraft: ProfileEditorDraft?
    @State private var selectedProfileId: UUID?
    @State private var runtimeAnchors: [UUID: JobRuntimeAnchor] = [:]
    @State private var splitViewVisibility = WorkspaceLayoutState.initialSplitVisibility()
    @State private var isOperationsPaneVisible = WorkspaceLayoutState.initialOperationsDrawerVisible()
    @State private var operationsTab = WorkspaceLayoutState.initialOperationsTab()
    @State private var profilePendingDeletion: ServerProfile?
    @State private var showResetConfirmation = false
    @State private var showClearHistoryConfirmation = false
    @State private var quickLookURL: URL?
    @State private var quickLookURLs: [URL] = []
    @State private var quickLookAccessTokens: [SecurityScopedFileAccess] = []


    private var droppedFileItems: [FileItem] {
        fileQueue.items
    }

    private var selectedProfile: ServerProfile? {
        guard let selectedProfileId else { return nil }
        return profileStore.profiles.first { $0.id == selectedProfileId }
    }

    private var isProfilesDrawerVisible: Bool {
        WorkspaceLayoutState.profilesDrawerVisible(for: splitViewVisibility)
    }

    private var isOperationsDrawerVisible: Bool {
        isOperationsPaneVisible
    }

    private var activeOperationsTab: WorkspaceOperationsTab {
        operationsTab
    }

    private var profilesDrawerSceneBinding: Binding<Bool> {
        Binding(
            get: { isProfilesDrawerVisible },
            set: { setProfilesDrawerVisible($0) }
        )
    }

    private var operationsDrawerSceneBinding: Binding<Bool> {
        Binding(
            get: { isOperationsDrawerVisible },
            set: { setOperationsDrawerVisible($0) }
        )
    }

    private var operationsTabBinding: Binding<WorkspaceOperationsTab> {
        Binding(
            get: { activeOperationsTab },
            set: { selectOperationsPane($0) }
        )
    }

    private var minimumWindowWidth: CGFloat {
        (isProfilesDrawerVisible ? Self.profilesDrawerMinWidth : 0) + Self.workbenchMinWidth
    }

    var body: some View {
        workspaceAlertLayer
            .sheet(item: $profileEditorDraft) { draft in
                ProfileEditorView(
                    profile: draft.profile,
                    initialPassword: draft.initialPassword,
                    initialKeyPassphrase: draft.initialKeyPassphrase,
                    jobRunner: jobRunner
                ) { updated, password, keyPassphrase in
                    let isNewProfile = !profileStore.profiles.contains(where: { $0.id == updated.id })
                    let storedProfile = try profileStore.upsertProfile(
                        updated,
                        password: password,
                        keyPassphrase: keyPassphrase
                    )

                    if isNewProfile {
                        selectedProfileId = storedProfile.id
                    }
                }
            }
    }

    // Derived bindings instead of shadow @State Bools: the alert presence
    // follows the store's error directly, so errors set before this view
    // subscribes (e.g. a corrupt profiles file at launch) still surface.
    private func errorAlertBinding(
        get value: @escaping () -> String?,
        clear: @escaping () -> Void
    ) -> Binding<Bool> {
        Binding(
            get: { value() != nil },
            set: { if !$0 { clear() } }
        )
    }

    private var workspaceAlertLayer: some View {
        workspaceConfirmationLayer
            .alert(
                "Error",
                isPresented: errorAlertBinding(
                    get: { jobRunner.blockingError },
                    clear: { jobRunner.blockingError = nil }
                ),
                presenting: jobRunner.blockingError
            ) { _ in
                Button("OK") { jobRunner.blockingError = nil }
            } message: { error in
                Text(error)
            }
            .alert(
                "Profile Storage Error",
                isPresented: errorAlertBinding(
                    get: { profileStore.lastError },
                    clear: { profileStore.lastError = nil }
                ),
                presenting: profileStore.lastError
            ) { _ in
                Button("OK") { profileStore.lastError = nil }
            } message: { error in
                Text(error)
            }
            .alert(
                "Job History Error",
                isPresented: errorAlertBinding(
                    get: { jobStore.lastError },
                    clear: { jobStore.lastError = nil }
                ),
                presenting: jobStore.lastError
            ) { _ in
                Button("OK") { jobStore.lastError = nil }
            } message: { error in
                Text(error)
            }
    }

    private var workspaceConfirmationLayer: some View {
        workspacePresentationLayer
            .confirmationDialog(
                "Delete Profile",
                isPresented: Binding(
                    get: { profilePendingDeletion != nil },
                    set: { if !$0 { profilePendingDeletion = nil } }
                ),
                presenting: profilePendingDeletion
            ) { profile in
                Button("Delete \"\(profile.name)\"", role: .destructive) {
                    profileStore.deleteProfile(id: profile.id)
                    profilePendingDeletion = nil
                }
            } message: { _ in
                Text("This will permanently remove the profile and its stored credentials.")
            }
            .confirmationDialog("Reset Queue", isPresented: $showResetConfirmation) {
                Button("Reset", role: .destructive) {
                    clearAllFiles()
                }
            } message: {
                Text("This will clear all queued files and the current job.")
            }
            .confirmationDialog("Clear Job History", isPresented: $showClearHistoryConfirmation) {
                Button("Clear History", role: .destructive) {
                    jobRunner.clearJobHistory(profileId: selectedProfileId)
                }
            } message: {
                Text(
                    selectedProfileId == nil
                        ? "This will remove all completed job records."
                        : "This will remove the selected profile's completed job records."
                )
            }
    }

    private var workspacePresentationLayer: some View {
        workspaceLifecycleLayer
            .frame(minWidth: minimumWindowWidth, minHeight: 600)
            .focusedSceneValue(\.showProfilesDrawerBinding, profilesDrawerSceneBinding)
            .focusedSceneValue(\.showOperationsDrawerBinding, operationsDrawerSceneBinding)
            .focusedSceneValue(\.windowCommandActions, windowCommandActions)
    }

    private var workspaceLifecycleLayer: some View {
        workspaceContainer
            .onAppear {
                // Drawer state is seeded from persisted defaults at @State
                // initialization; re-applying it here would revert live drawer
                // changes whenever the system reparents the content and
                // onAppear fires again.
                ingestExternalFilesIfPreferredWindow()
                seedRuntimeAnchorForActiveJob(force: true)
                if selectedProfileId == nil {
                    selectedProfileId = profileStore.profiles.first?.id
                }
                if profileStore.isEmpty, profileEditorDraft == nil {
                    presentNewProfileEditor()
                }
            }
            .onChange(of: splitViewVisibility) { _, newValue in
                // The window toolbar's native sidebar toggle writes the
                // binding directly, so persist here to cover every path.
                WorkspaceLayoutState.persistProfilesDrawer(
                    visible: WorkspaceLayoutState.profilesDrawerVisible(for: newValue)
                )
            }
            .onChange(of: externalFileIntake.sequence) { _, _ in
                ingestExternalFilesIfPreferredWindow()
            }
            .onChange(of: appearsActive) { _, isActive in
                guard isActive else { return }
                ingestExternalFiles()
            }
            .onChange(of: jobRunner.isRunning) { _, running in
                if running {
                    seedRuntimeAnchorForActiveJob(force: true)
                }
            }
            .onChange(of: jobRunner.currentJob?.id) { _, _ in
                seedRuntimeAnchorForActiveJob(force: true)
            }
            .onChange(of: jobRunner.currentJob?.step) { _, step in
                guard step == .preflight else { return }
                seedRuntimeAnchorForActiveJob(force: true)
            }
            .onChange(of: profileStore.profiles.map(\.id)) { _, ids in
                if let selectedProfileId, !ids.contains(selectedProfileId) {
                    self.selectedProfileId = ids.first
                } else if self.selectedProfileId == nil {
                    self.selectedProfileId = ids.first
                }
            }
            .onOpenURL { url in
                externalFileIntake.enqueue([url])
                ingestExternalFilesIfPreferredWindow()
            }
    }

    private var workspaceContainer: some View {
        NavigationSplitView(columnVisibility: $splitViewVisibility) {
            sidebar
                .navigationSplitViewColumnWidth(
                    min: Self.profilesDrawerMinWidth,
                    ideal: Self.profilesDrawerWidth,
                    max: Self.profilesDrawerMaxWidth
                )
        } detail: {
            middleWorkbench
                .frame(minWidth: Self.workbenchMinWidth, maxWidth: .infinity)
                .toolbar {
                    middleToolbarItems()
                }
        }
        .toolbarRole(.editor)
        .navigationSplitViewStyle(.balanced)
        .inspector(isPresented: operationsDrawerSceneBinding) {
            operationsDrawer
                .inspectorColumnWidth(min: 280, ideal: 340, max: 400)
        }
    }

    // MARK: - Sidebar

    private var sidebar: some View {
        List(selection: $selectedProfileId) {
            ForEach(profileStore.profiles) { profile in
                profileSidebarRow(profile)
                    .tag(profile.id)
            }
        }
        .listStyle(.sidebar)
        .contextMenu(forSelectionType: UUID.self) { ids in
            if let profile = profile(forSelection: ids) {
                Button("Edit Profile…") {
                    presentProfileEditor(for: profile)
                }

                Menu("Color") {
                    Button {
                        setProfileColor(nil, for: profile)
                    } label: {
                        Label("None", systemImage: profile.profileColorHex == nil ? "checkmark" : "circle.slash")
                    }

                    Divider()

                    ForEach(ProfileColor.presets) { preset in
                        Button {
                            setProfileColor(preset.hex, for: profile)
                        } label: {
                            Label(preset.name, systemImage: profile.profileColorHex == preset.hex ? "checkmark.circle.fill" : "circle.fill")
                        }
                        .tint(Color(hexString: preset.hex))
                    }
                }

                Divider()

                Button("Delete Profile", role: .destructive) {
                    deleteProfile(profile)
                }
                .disabled(jobRunner.isRunning)
            }
        } primaryAction: { ids in
            if let profile = profile(forSelection: ids) {
                presentProfileEditor(for: profile)
            }
        }
        .environment(\.defaultMinListRowHeight, 30)
        .safeAreaInset(edge: .bottom, spacing: 0) {
            HStack {
                ControlGroup {
                    Button {
                        presentNewProfileEditor()
                    } label: {
                        Image(systemName: "plus")
                    }
                    .help("New profile")
                    .accessibilityLabel("New profile")

                    Button {
                        if let selectedProfile {
                            deleteProfile(selectedProfile)
                        }
                    } label: {
                        Image(systemName: "minus")
                    }
                    .help("Delete selected profile")
                    .accessibilityLabel("Delete selected profile")
                    .disabled(!canDeleteProfile)
                }
                .controlSize(.small)
                .frame(width: 52)
                Spacer()
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
        }
    }

    private func profileSidebarRow(_ profile: ServerProfile) -> some View {
        Label {
            VStack(alignment: .leading, spacing: 2) {
                Text(profile.name)
                    .font(.callout)
                Text("\(profile.username)@\(profile.host)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .lineLimit(1)
        } icon: {
            Image(systemName: "server.rack")
                .foregroundStyle(
                    profile.profileColorHex.map { Color(hexString: $0) } ?? .secondary
                )
        }
    }

    // MARK: - Middle Workbench

    private var middleWorkbench: some View {
        VStack(spacing: 0) {
            if selectedProfile != nil {
                filesArea
            } else if profileStore.isEmpty {
                ContentUnavailableView {
                    Label("No Profiles", systemImage: "server.rack")
                } description: {
                    Text("Create a profile to start uploading.")
                } actions: {
                    Button("Create Profile") {
                        presentNewProfileEditor()
                    }
                    if !isProfilesDrawerVisible {
                        Button("Open Profiles Drawer") {
                            setProfilesDrawerVisible(true)
                        }
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ContentUnavailableView {
                    Label("No Profile Selected", systemImage: "server.rack")
                } description: {
                    Text("Select a profile to get started.")
                } actions: {
                    if !isProfilesDrawerVisible {
                        Button("Open Profiles Drawer") {
                            setProfilesDrawerVisible(true)
                        }
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }

    @ToolbarContentBuilder
    private func middleToolbarItems() -> some ToolbarContent {
        ToolbarItem(placement: .navigation) {
            toolbarProfileLabel
        }

        ToolbarItemGroup(placement: .automatic) {
            Button {
                choosePhotos()
            } label: {
                Label("Add Files...", systemImage: "plus")
            }
            .help("Choose files to queue for upload")
            .accessibilityLabel("Add files")

            Button(role: .destructive) {
                showResetConfirmation = true
            } label: {
                Label("Reset", systemImage: "trash")
            }
            .labelStyle(.iconOnly)
            .disabled(!canResetAction)
            .help("Reset queued files and clear the current job")
            .accessibilityLabel("Reset queued files and clear the current job")
        }

        ToolbarSpacer(.fixed)

        ToolbarItemGroup(placement: .automatic) {
            Button {
                guard let profile = retryProfile else { return }
                jobRunner.retryFailed(profile: profile)
            } label: {
                Label("Retry Failed", systemImage: "arrow.counterclockwise")
            }
            .labelStyle(.iconOnly)
            .disabled(!(jobRunner.canRetryFailed && retryProfile != nil))
            .help("Retry failed or unfinished files; successful files are skipped")
            .accessibilityLabel("Retry failed or unfinished files; successful files are skipped")

            Button {
                jobRunner.cancel()
            } label: {
                Label("Stop", systemImage: "stop.fill")
            }
            .labelStyle(.iconOnly)
            .disabled(!canStopAction)
            .help("Stop all active transfers in this window")
            .accessibilityLabel("Stop all active transfers in this window")

            Button {
                startQueuedUpload()
            } label: {
                Label("Start Upload", systemImage: "play.fill")
            }
            .labelStyle(.iconOnly)
            .disabled(!canStartAction)
            .help("Upload selected photos and import to WordPress")
            .accessibilityLabel("Upload selected photos and import to WordPress")
            // No bare-Return default action: in a non-modal window, Return
            // with the file list focused must not kick off a network upload.
            // ⌘↩ in the File menu remains the shortcut.
        }

        ToolbarItemGroup(placement: .primaryAction) {
            Spacer()

            Button {
                setOperationsDrawerVisible(!isOperationsDrawerVisible)
            } label: {
                Label("Toggle Inspector", systemImage: "sidebar.right")
            }
            .help(isOperationsDrawerVisible ? "Hide operations drawer" : "Show operations drawer")
        }
    }

    private var toolbarProfileLabel: some View {
        Group {
            if let selectedProfile {
                HStack(spacing: 8) {
                    Image(systemName: "server.rack")
                        .foregroundStyle(
                            selectedProfile.profileColorHex.map { Color(hexString: $0) } ?? .secondary
                        )
                    VStack(alignment: .leading, spacing: 1) {
                        Text(selectedProfile.name)
                            .font(.headline)
                            .lineLimit(1)
                        Text("\(selectedProfile.username)@\(selectedProfile.host)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
                .help("\(selectedProfile.username)@\(selectedProfile.host)")
            } else if profileStore.isEmpty {
                Text("No Profiles")
                    .font(.headline)
                    .foregroundStyle(.secondary)
            } else {
                Text("No Profile Selected")
                    .font(.headline)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 2)
        .frame(maxWidth: 340, alignment: .leading)
    }

    // MARK: - Operations Drawer

    private var operationsDrawer: some View {
        VStack(spacing: 0) {
            Picker("Operations", selection: operationsTabBinding) {
                ForEach(WorkspaceOperationsTab.allCases) { tab in
                    Label(tab.title, systemImage: tab.systemImage)
                        .tag(tab)
                }
            }
            .labelsHidden()
            .pickerStyle(.segmented)
            .controlSize(.regular)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)

            Group {
                switch activeOperationsTab {
                case .activeJob:
                    operationsProgressPanel
                case .terminal:
                    logViewer
                case .history:
                    jobHistoryView
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private var operationsProgressPanel: some View {
        Group {
            if let job = jobRunner.currentJob {
                jobStatusForm(job: job)
            } else {
                operationsEmptyState("No job selected")
            }
        }
    }

    private func operationsEmptyState(_ message: String) -> some View {
        ContentUnavailableView(message, systemImage: "tray")
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var terminalContent: some View {
        Group {
            if jobRunner.logLines.isEmpty {
                operationsEmptyState("No job selected")
            } else {
                // One Text for the whole visible log so selection works
                // continuously across lines.
                ScrollView {
                    Text(visibleLogText)
                        .font(.system(size: 10, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 4)
                }
                .defaultScrollAnchor(.bottom)
            }
        }
        .frame(minHeight: 80)
    }

    private var visibleLogText: String {
        jobRunner.logLines
            .suffix(Self.visibleLogLineLimit)
            .map(\.text)
            .joined(separator: "\n")
    }

    private var operationsInlineMessage: String? {
        if let message = jobRunner.inlineStatusMessage?.trimmingCharacters(in: .whitespacesAndNewlines),
           !message.isEmpty
        {
            return message
        }

        guard let currentJob = jobRunner.currentJob else { return nil }
        guard currentJob.step == .failed || currentJob.step == .cancelled else { return nil }
        return currentJob.errorMessage
    }

    private func inlineMessageRow(message: String) -> some View {
        HStack(alignment: .top, spacing: 6) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
                .font(.caption)
            Text(message)
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(Color.orange.opacity(0.08))
        )
    }

    private var selectedProfileJobs: [Job] {
        guard let selectedId = selectedProfileId else {
            return jobStore.jobs
        }
        return jobStore.jobs.filter { $0.profileId == selectedId }
    }

    private var jobHistoryView: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Recent Jobs")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Clear", systemImage: "trash") {
                    showClearHistoryConfirmation = true
                }
                .buttonStyle(.borderless)
                .controlSize(.small)
                .disabled(!canClearJobHistory)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)

            if selectedProfileJobs.isEmpty {
                operationsEmptyState("No jobs yet")
            } else {
                List(selectedProfileJobs.prefix(50)) { job in
                    Button {
                        jobRunner.loadJob(job)
                    } label: {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(job.createdAt.formatted(date: .abbreviated, time: .shortened))
                                .font(.callout)
                            HStack(spacing: 4) {
                                statusDot(for: job.step)
                                Text(job.step.displayTitle)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                Text("• \(job.localFiles.count) files")
                                    .font(.caption)
                                    .foregroundStyle(.tertiary)
                            }
                        }
                    }
                    .buttonStyle(.plain)
                    .disabled(jobRunner.isRunning)
                }
                .listStyle(.inset)
                .scrollContentBackground(.hidden)
            }
        }
    }

    // MARK: - Image Queue

    private var filesArea: some View {
        let job = jobRunner.currentJob
        let currentJobFiles = job?.localFiles.map { DisplayFile(source: .currentJob, item: $0) } ?? []
        return VStack(spacing: 0) {
            ZStack {
                fileList(currentJobFiles: currentJobFiles, job: job)
                    .overlay {
                        if isDropTargeted {
                            RoundedRectangle(cornerRadius: 6, style: .continuous)
                                .strokeBorder(Color.accentColor.opacity(0.65), style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
                                .padding(8)
                        }
                    }
                    .dropDestination(for: URL.self) { droppedURLs, _ in
                        addFiles(droppedURLs)
                        return true
                    } isTargeted: {
                        isDropTargeted = $0
                    }
                    .onDeleteCommand {
                        deleteSelectedFileRows()
                    }
            }
        }
        .onChange(of: droppedFileItems) { _, _ in
            pruneFileSelection()
        }
        .onChange(of: job?.id) { _, _ in
            pruneFileSelection()
        }
    }

    private func fileList(currentJobFiles: [DisplayFile], job: Job?) -> some View {
        let isEmpty = currentJobFiles.isEmpty && droppedFileItems.isEmpty
        return List(selection: $selectedFileRowIDs) {
            ForEach(currentJobFiles) { file in
                fileRow(for: file, job: job)
                    .tag(file.id)
            }

            ForEach(droppedFileItems) { item in
                let file = DisplayFile(source: .queued, item: item)
                fileRow(for: file, job: job)
                    .tag(file.id)
            }
            .onMove { source, destination in
                guard !jobRunner.isRunning else { return }
                moveQueuedFiles(from: source, to: destination)
            }
        }
        .listStyle(.inset)
        .dragContainer(for: URL.self, itemID: \.self) { draggedItemIDs in
            draggedItemIDs
        }
        .dragContainerSelection(urls(forRowIDs: selectedFileRowIDs))
        .copyable(urls(forRowIDs: selectedFileRowIDs))
        .pasteDestination(for: URL.self) { addFiles($0) }
        .contextMenu(forSelectionType: String.self) { rowIDs in
            if rowIDs.isEmpty {
                Button("Add Files…") {
                    choosePhotos()
                }
            } else {
                Button("Show in Finder") {
                    NSWorkspace.shared.activateFileViewerSelecting(urls(forRowIDs: rowIDs))
                }
                Button("Quick Look") {
                    presentQuickLook(forRowIDs: rowIDs)
                }
                Divider()
                Button("Delete", role: .destructive) {
                    deleteQueuedFiles(forRowIDs: rowIDs)
                }
                .disabled(jobRunner.isRunning || !rowIDs.contains(where: DisplayFile.isQueuedRowID))
            }
        }
        .quickLookPreview($quickLookURL, in: quickLookURLs)
        .onKeyPress(.space) {
            guard !selectedFileRowIDs.isEmpty else { return .ignored }
            presentQuickLook(forRowIDs: selectedFileRowIDs)
            return .handled
        }
        .onChange(of: quickLookURL) { _, newValue in
            guard newValue == nil else { return }
            for token in quickLookAccessTokens {
                token.stop()
            }
            quickLookAccessTokens = []
            quickLookURLs = []
        }
        .overlay {
            if isEmpty {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .strokeBorder(Color.secondary.opacity(0.25), style: StrokeStyle(lineWidth: 1, dash: [6, 4]))
                    .padding(10)
                    .overlay {
                        VStack(spacing: 8) {
                            Image(systemName: "photo.stack")
                                .font(.system(size: 32, weight: .light))
                                .foregroundStyle(.secondary.opacity(0.5))
                            Text("Drop images here")
                                .font(.callout)
                                .foregroundStyle(.secondary.opacity(0.5))
                        }
                    }
                    .allowsHitTesting(false)
            }
        }
    }

    private var canClearFiles: Bool {
        WorkspaceCommandState.canClearFiles(
            isRunning: jobRunner.isRunning,
            queuedCount: droppedFileItems.count,
            hasCurrentJob: jobRunner.currentJob != nil
        )
    }

    private var canStartAction: Bool {
        WorkspaceCommandState.canStartUpload(
            isRunning: jobRunner.isRunning,
            hasSelectedProfile: selectedProfile != nil,
            queuedCount: droppedFileItems.count
        )
    }

    private var canStopAction: Bool {
        WorkspaceCommandState.canStopUpload(isRunning: jobRunner.isRunning)
    }

    private var canResetAction: Bool {
        canClearFiles
    }

    private var canDeleteSelectedFilesAction: Bool {
        let hasQueuedSelection = selectedFileRowIDs.contains(where: DisplayFile.isQueuedRowID)
        return WorkspaceCommandState.canDeleteSelectedFiles(
            isRunning: jobRunner.isRunning,
            selectedCount: selectedFileRowIDs.count,
            hasQueuedSelection: hasQueuedSelection
        )
    }

    private var canUseCurrentJobAction: Bool {
        jobRunner.currentJob != nil
    }

    private var canCopyVisibleLogAction: Bool {
        !jobRunner.logLines.isEmpty
    }

    private var windowCommandActions: WindowCommandActions {
        WindowCommandActions(
            createProfile: presentNewProfileEditor,
            editSelectedProfile: {
                guard let selectedProfile else { return }
                presentProfileEditor(for: selectedProfile)
            },
            deleteSelectedProfile: {
                guard let selectedProfile else { return }
                deleteProfile(selectedProfile)
            },
            addFiles: choosePhotos,
            deleteSelectedFiles: deleteSelectedFileRows,
            resetQueueAndCurrentJob: { showResetConfirmation = true },
            retryFailedFiles: {
                guard let profile = retryProfile else { return }
                jobRunner.retryFailed(profile: profile)
            },
            stopUpload: {
                jobRunner.cancel()
            },
            startUpload: startQueuedUpload,
            clearJobHistory: { showClearHistoryConfirmation = true },
            openLog: openLogs,
            copyVisibleLog: copyVisibleLog,
            copyReport: copyReport,
            exportJSONReport: {
                exportReport(as: .json)
            },
            exportCSVReport: {
                exportReport(as: .csv)
            },
            showActiveJobTab: {
                selectOperationsPane(.activeJob)
            },
            showTerminalTab: {
                selectOperationsPane(.terminal)
            },
            showJobHistoryTab: {
                selectOperationsPane(.history)
            },
            canEditSelectedProfile: selectedProfile != nil,
            canDeleteSelectedProfile: canDeleteProfile,
            canDeleteSelectedFiles: canDeleteSelectedFilesAction,
            canResetQueueAndCurrentJob: canResetAction,
            canRetryFailedFiles: jobRunner.canRetryFailed && retryProfile != nil,
            canStopUpload: canStopAction,
            canStartUpload: canStartAction,
            canClearJobHistory: canClearJobHistory,
            canOpenLog: canUseCurrentJobAction,
            canCopyVisibleLog: canCopyVisibleLogAction,
            canCopyReport: canUseCurrentJobAction,
            canExportJSONReport: canUseCurrentJobAction,
            canExportCSVReport: canUseCurrentJobAction
        )
    }

    private func fileRow(for file: DisplayFile, job: Job?) -> some View {
        let item = file.item
        let rowStatus = fileRowStatus(for: file, in: job)

        return HStack(spacing: 8) {
            FileThumbnailIcon(url: item.localURL, size: 20)
            Text(item.filename)
                .font(.system(size: 12))
                .lineLimit(1)
            Spacer()
            Text(item.sizeBytes.formatted(.byteCount(style: .file, allowedUnits: [.kb, .mb])))
                .font(.caption2.monospacedDigit())
                .foregroundStyle(.secondary)
            perItemIndicator(for: file, rowStatus: rowStatus, in: job)
            Text(rowStatus.label.uppercased())
                .font(.caption2.monospaced())
                .foregroundStyle(rowStatus.tone.color)
                .frame(width: 108, alignment: .trailing)
                .accessibilityLabel("Status: \(rowStatus.label)")
        }
        .padding(.vertical, 2)
        .help(
            FileRowPresentation.helpText(
                for: item,
                rowStatus: rowStatus,
                isQueuedSource: file.source == .queued
            )
        )
        .contentShape(Rectangle())
        .draggable(URL.self, id: \.self, item: item.localURL)
    }

    private func perItemIndicator(for file: DisplayFile, rowStatus: FileRowStatus, in job: Job?) -> some View {
        Group {
            switch rowStatus {
            case .failed:
                Image(systemName: "xmark.circle.fill").foregroundStyle(.red)
            case .regenerated, .sideloaded:
                Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
            case .preflight:
                ProgressView().controlSize(.small)
            case .uploading, .verifying, .importing, .regenerating, .sideloading:
                if isActivelyRunning(file, in: job) {
                    ProgressView().controlSize(.small)
                } else {
                    Image(systemName: "clock").foregroundStyle(.secondary)
                }
            case .uploaded, .verified, .imported:
                statusDot(for: file.item.status)
            case .queued:
                statusDot(for: .queued)
            }
        }
    }

    private func isActivelyRunning(_ file: DisplayFile, in job: Job?) -> Bool {
        guard file.source == .currentJob else { return false }
        guard let job, jobRunner.isRunning else { return false }
        return job.activeFileId == file.item.id
    }

    private func fileRowStatus(for file: DisplayFile, in job: Job?) -> FileRowStatus {
        FileRowStatus.resolve(
            item: file.item,
            isQueuedSource: file.source == .queued,
            isActiveFile: isActivelyRunning(file, in: job),
            currentStep: job?.step
        )
    }

    private func activeFileStatus(for job: Job) -> FileRowStatus? {
        guard let activeFileId = job.activeFileId else { return nil }
        guard let activeFile = job.localFiles.first(where: { $0.id == activeFileId }) else { return nil }
        return FileRowStatus.resolve(
            item: activeFile,
            isQueuedSource: false,
            isActiveFile: true,
            currentStep: job.step
        )
    }

    private func jobStatusForm(job: Job) -> some View {
        // TimelineView drives the clock so ETA/rate keep advancing during a
        // long single-file upload instead of freezing until unrelated state
        // happens to invalidate the view.
        TimelineView(.periodic(from: .now, by: 1)) { context in
            jobStatusFormContent(job: job, now: context.date)
        }
    }

    private func jobStatusFormContent(job: Job, now: Date) -> some View {
        let presentation = JobPresentation.make(
            for: job,
            activeFileStatus: activeFileStatus(for: job),
            now: now,
            anchor: runtimeAnchors[job.id]
        )

        return Form {
            Section {
                HStack {
                    Label(job.step.displayTitle, systemImage: job.step.displayIcon)
                        .foregroundStyle(job.step.displayColor)
                    Spacer()
                    if jobRunner.isRunning {
                        ProgressView()
                            .controlSize(.small)
                    }
                }

                ProgressView(value: presentation.overallProgress) {
                    Text(presentation.progressLabel)
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }

                LabeledContent("ETA", value: presentation.etaLine)
                LabeledContent("Rate", value: presentation.rateLine)

                if let message = operationsInlineMessage {
                    inlineMessageRow(message: message)
                }
            }

            Section {
                LabeledContent("Succeeded") {
                    Text("\(presentation.successfulFiles)")
                        .foregroundStyle(.green)
                }
                if presentation.failedFiles > 0 {
                    LabeledContent("Failed") {
                        Text("\(presentation.failedFiles)")
                            .foregroundStyle(.red)
                    }
                }
                LabeledContent("Remaining", value: "\(presentation.remainingFiles)")
            }
        }
        .formStyle(.grouped)
    }

    private var logViewer: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Terminal")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                Spacer()
                ControlGroup {
                    Button("View Log", systemImage: "eye", action: openLogs)
                        .disabled(jobRunner.currentJob == nil)
                    Button("Copy Terminal", systemImage: "doc.on.doc", action: copyVisibleLog)
                        .disabled(!canCopyVisibleLogAction)
                    Button("Copy Report", systemImage: "doc.text", action: copyReport)
                        .disabled(jobRunner.currentJob == nil)
                    Menu("Export", systemImage: "square.and.arrow.up") {
                        Button("Export JSON…") { exportReport(as: .json) }
                        Button("Export CSV…") { exportReport(as: .csv) }
                    }
                    .disabled(jobRunner.currentJob == nil)
                }
                .controlGroupStyle(.automatic)
                .controlSize(.small)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)

            terminalContent
        }
    }


    // MARK: - Helpers

    private func setProfilesDrawerVisible(_ isVisible: Bool) {
        let target = WorkspaceLayoutState.splitVisibility(forProfilesDrawer: isVisible)
        guard splitViewVisibility != target else { return }
        splitViewVisibility = target
        WorkspaceLayoutState.persistProfilesDrawer(visible: isVisible)
    }

    private func setOperationsDrawerVisible(_ isVisible: Bool) {
        guard isOperationsPaneVisible != isVisible else { return }
        isOperationsPaneVisible = isVisible
        WorkspaceLayoutState.persistOperationsDrawer(visible: isVisible)
    }

    private func selectOperationsPane(_ tab: WorkspaceOperationsTab) {
        operationsTab = tab
        isOperationsPaneVisible = true
        WorkspaceLayoutState.persistOperationsTab(tab)
        WorkspaceLayoutState.persistOperationsDrawer(visible: true)
    }


    private var retryProfile: ServerProfile? {
        guard let job = jobRunner.currentJob else { return nil }
        return profileStore.profiles.first(where: { $0.id == job.profileId })
    }

    private var canDeleteProfile: Bool {
        selectedProfile != nil && !jobRunner.isRunning
    }

    private var canClearJobHistory: Bool {
        WorkspaceCommandState.canClearJobHistory(
            isRunning: jobRunner.isRunning,
            jobCount: selectedProfileJobs.count
        )
    }

    private func presentNewProfileEditor() {
        var newProfile = ServerProfile.default
        newProfile.id = UUID()
        newProfile.name = "New Profile"
        profileEditorDraft = ProfileEditorDraft(
            profile: newProfile,
            initialPassword: nil,
            initialKeyPassphrase: nil
        )
    }

    private func deleteProfile(_ profile: ServerProfile) {
        guard !jobRunner.isRunning else { return }
        profilePendingDeletion = profile
    }

    private func setProfileColor(_ hex: String?, for profile: ServerProfile) {
        var updated = profile
        updated.profileColorHex = hex
        profileStore.update(updated)
    }

    private func profile(forSelection ids: Set<UUID>) -> ServerProfile? {
        guard let id = ids.first else { return nil }
        return profileStore.profiles.first { $0.id == id }
    }

    private func presentProfileEditor(for profile: ServerProfile) {
        // A failed Keychain read must not open the editor with empty secret
        // fields — saving those would delete the stored credentials.
        guard let secrets = profileStore.loadSecretsForEditing(profile: profile) else { return }
        profileEditorDraft = ProfileEditorDraft(
            profile: profile,
            initialPassword: secrets.password,
            initialKeyPassphrase: secrets.keyPassphrase
        )
    }

    @MainActor
    private func choosePhotos() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = true
        panel.canChooseFiles = true
        panel.allowedContentTypes = {
            // Derived from the same list JobRunner filters with, so the
            // picker and the pipeline can never drift apart.
            var seen = Set<String>()
            var types: [UTType] = []
            for ext in supportedImageExtensions.sorted() {
                guard let type = UTType(filenameExtension: ext) else { continue }
                if seen.insert(type.identifier).inserted {
                    types.append(type)
                }
            }
            return types
        }()

        if panel.runModal() == .OK {
            addFiles(panel.urls)
        }
    }

    private func addFiles(_ urls: [URL]) {
        let imageFiles = resolveImageFileURLs(from: urls)
        guard !imageFiles.isEmpty else {
            // A drop that yields nothing must not look like a broken drop
            // target — say why nothing happened.
            if !urls.isEmpty {
                jobRunner.presentNotice("No supported image files were found in the added items.")
            }
            return
        }

        var items = fileQueue.items
        var existing = Set(items.map { $0.localURL.standardizedFileURL.path })
        for url in imageFiles {
            let key = url.standardizedFileURL.path
            guard existing.insert(key).inserted else { continue }
            let bookmarkData = try? SecurityScopedFileAccess.bookmarkData(for: url)
            guard let item = FileItem.fromURL(url, bookmarkData: bookmarkData) else { continue }
            items.append(item)
        }
        fileQueue.setItems(items, actionName: "Add Files", undoManager: undoManager)
        pruneFileSelection()
    }

    private func ingestExternalFiles() {
        addFiles(externalFileIntake.drain())
    }

    private func ingestExternalFilesIfPreferredWindow() {
        guard appearsActive else { return }
        ingestExternalFiles()
    }

    private func clearAllFiles() {
        guard !jobRunner.isRunning else { return }
        fileQueue.setItems([], actionName: "Reset Queue", undoManager: undoManager)
        selectedFileRowIDs.removeAll()
        jobRunner.reset()
    }

    private func startQueuedUpload() {
        guard let profile = selectedProfile else { return }
        let queued = droppedFileItems
        guard !queued.isEmpty else { return }

        jobRunner.start(profile: profile, fileItems: queued)
        if jobRunner.isRunning {
            // The queued files now belong to the job; clearing the queue is
            // not undoable, and stale queue undos would re-add duplicates.
            fileQueue.items = []
            undoManager?.removeAllActions(withTarget: fileQueue)
            selectedFileRowIDs.removeAll()
            if isOperationsDrawerVisible {
                selectOperationsPane(.activeJob)
            }
        }
    }

    private func deleteSelectedFileRows() {
        guard !jobRunner.isRunning else { return }
        guard !selectedFileRowIDs.isEmpty else { return }
        deleteQueuedFiles(forRowIDs: selectedFileRowIDs)
    }

    private func fileItems(forRowIDs rowIDs: Set<String>) -> [FileItem] {
        var items: [FileItem] = []
        if let job = jobRunner.currentJob {
            items.append(contentsOf: job.localFiles.filter { item in
                rowIDs.contains(DisplayFile.currentJobRowID(for: item.id))
            })
        }
        items.append(contentsOf: droppedFileItems.filter { item in
            rowIDs.contains(DisplayFile.queuedRowID(for: item.id))
        })
        return items
    }

    private func urls(forRowIDs rowIDs: Set<String>) -> [URL] {
        fileItems(forRowIDs: rowIDs).map(\.localURL)
    }

    private func presentQuickLook(forRowIDs rowIDs: Set<String>) {
        let items = fileItems(forRowIDs: rowIDs)
        guard !items.isEmpty else { return }

        // Files restored from job history need their security-scoped access
        // re-established from bookmarks before Quick Look can read them.
        var tokens: [SecurityScopedFileAccess] = []
        var previewURLs: [URL] = []
        for item in items {
            guard let access = try? SecurityScopedFileAccess.start(
                url: item.localURL,
                bookmarkData: item.bookmarkData,
                purpose: "Quick Look preview"
            ) else { continue }
            tokens.append(access)
            previewURLs.append(access.url)
        }
        guard !previewURLs.isEmpty else { return }

        quickLookAccessTokens = tokens
        quickLookURLs = previewURLs
        quickLookURL = previewURLs.first
    }

    private func moveQueuedFiles(from source: IndexSet, to destination: Int) {
        var items = fileQueue.items
        items.move(fromOffsets: source, toOffset: destination)
        fileQueue.setItems(items, actionName: "Move Files", undoManager: undoManager)
    }

    private func deleteQueuedFiles(forRowIDs rowIDs: Set<String>) {
        guard !rowIDs.isEmpty else { return }

        let queuedRowIDs = Set(rowIDs.filter(DisplayFile.isQueuedRowID))
        guard !queuedRowIDs.isEmpty else { return }

        let queuedItemIDs = Set(
            droppedFileItems
                .map(\.id)
                .filter { queuedRowIDs.contains(DisplayFile.queuedRowID(for: $0)) }
        )
        guard !queuedItemIDs.isEmpty else { return }

        var items = fileQueue.items
        items.removeAll { queuedItemIDs.contains($0.id) }
        fileQueue.setItems(items, actionName: "Delete Files", undoManager: undoManager)
        selectedFileRowIDs.subtract(queuedRowIDs)
        pruneFileSelection()
    }

    private func pruneFileSelection() {
        var validRowIDs = Set<String>()
        if let job = jobRunner.currentJob {
            validRowIDs.formUnion(job.localFiles.map { DisplayFile.currentJobRowID(for: $0.id) })
        }
        validRowIDs.formUnion(droppedFileItems.map { DisplayFile.queuedRowID(for: $0.id) })
        selectedFileRowIDs.formIntersection(validRowIDs)
    }

    private func copyReport() {
        let text = jobRunner.reportText()
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
    }

    private func copyVisibleLog() {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(visibleLogText, forType: .string)
    }

    @MainActor
    private func exportReport(as format: ReportExportFormat) {
        guard let payload = jobRunner.reportPayload(format: format) else { return }

        let panel = NSSavePanel()
        panel.canCreateDirectories = true
        panel.nameFieldStringValue = jobRunner.suggestedReportFileName(format: format)
        panel.allowedContentTypes = [contentType(for: format)]

        guard panel.runModal() == .OK, let destination = panel.url else { return }

        do {
            try payload.write(to: destination, atomically: true, encoding: String.Encoding.utf8)
        } catch {
            jobRunner.blockingError = "Failed to export: \(error.localizedDescription)"
        }
    }

    private func openLogs() {
        guard let path = jobRunner.currentJob?.logsPath else { return }
        NSWorkspace.shared.open(URL(fileURLWithPath: path))
    }

    private func contentType(for format: ReportExportFormat) -> UTType {
        switch format {
        case .text: return .plainText
        case .json: return .json
        case .csv: return .commaSeparatedText
        }
    }

    private func statusDot(for status: FileItemStatus) -> some View {
        Circle()
            .fill(status.displayColor)
            .frame(width: 8, height: 8)
    }

    private func statusDot(for step: JobStep) -> some View {
        Circle()
            .fill(step.displayColor)
            .frame(width: 8, height: 8)
    }

    private func seedRuntimeAnchorForActiveJob(force: Bool = false) {
        guard let job = jobRunner.currentJob else { return }
        guard !job.step.isTerminal else { return }
        if !force, runtimeAnchors[job.id] != nil { return }
        runtimeAnchors[job.id] = JobRuntimeAnchor(
            startedAt: Date(),
            processedBaseline: JobPresentation.processedFileCount(in: job)
        )
    }


}
