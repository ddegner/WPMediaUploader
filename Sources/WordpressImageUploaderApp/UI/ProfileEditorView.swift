import SwiftUI

struct ProfileEditorView: View {
    @Environment(\.dismiss) private var dismiss

    let jobRunner: JobRunner
    let onSave: (ServerProfile, String, String) throws -> Void

    @State private var profile: ServerProfile
    @State private var password: String
    @State private var keyPassphrase: String
    @State private var showKeyImporter = false
    @State private var saveError: String?
    // Recomputed on edits instead of per render pass: validation resolves a
    // security-scoped bookmark for SSH-key profiles, which is too expensive
    // to run twice for every keystroke's body evaluation.
    @State private var validationError: String?

    @State private var isTesting = false
    @State private var testLines: [String] = []
    @State private var testSuccess = false

    init(
        profile: ServerProfile,
        initialPassword: String?,
        initialKeyPassphrase: String?,
        jobRunner: JobRunner,
        onSave: @escaping (ServerProfile, String, String) throws -> Void
    ) {
        self.jobRunner = jobRunner
        self.onSave = onSave
        _profile = State(initialValue: profile)
        _password = State(initialValue: initialPassword ?? "")
        _keyPassphrase = State(initialValue: initialKeyPassphrase ?? "")
        _validationError = State(initialValue: ProfileValidation.firstError(
            for: profile,
            password: initialPassword ?? "",
            context: .editor
        ))
    }

    var body: some View {
        NavigationStack {
            Form {
                connectionSection
                wordpressSection
                defaultsSection
                connectionTestSection
            }
            .formStyle(.grouped)
            .navigationTitle("Profile Editor")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        dismiss()
                    }
                    .keyboardShortcut(.cancelAction)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        saveAndClose()
                    }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                    .disabled(!canSave)
                }
            }
        }
        .fileImporter(
            isPresented: $showKeyImporter,
            allowedContentTypes: [.data],
            allowsMultipleSelection: false
        ) { result in
            switch result {
            case let .success(urls):
                guard let url = urls.first else { return }
                profile.keyPath = url.path
                do {
                    profile.keyBookmarkData = try SecurityScopedFileAccess.bookmarkData(for: url)
                } catch {
                    // Without a bookmark the sandbox will refuse the key at
                    // upload time — say so now, next to the file that failed.
                    profile.keyBookmarkData = nil
                    saveError = "Could not create a sandbox bookmark for the key file: \(error.localizedDescription)"
                }
            case let .failure(error):
                saveError = error.localizedDescription
            }
        }
        .onChange(of: profile) { revalidate() }
        .onChange(of: password) { revalidate() }
        .frame(width: 720, height: 760)
        .alert("Save Error", isPresented: Binding(
            get: { saveError != nil },
            set: { if !$0 { saveError = nil } }
        )) {
            Button("OK") { saveError = nil }
        } message: {
            Text(saveError ?? "")
        }
    }

    // MARK: - Connection

    private var connectionSection: some View {
        Section(header: Text("Connection")) {
            TextField("Profile Name", text: $profile.name, prompt: Text("My WordPress Server"))
            TextField("Host", text: $profile.host, prompt: Text("example.com"))
            TextField("Username", text: $profile.username, prompt: Text("deploy"))

            LabeledContent("Port") {
                TextField("", value: $profile.port, format: .number)
                    .multilineTextAlignment(.trailing)
                    .frame(width: 80)
            }

            Picker("Authentication", selection: $profile.authType) {
                ForEach(AuthenticationType.allCases) { auth in
                    Text(auth.displayName).tag(auth)
                }
            }
            .pickerStyle(.menu)

            if profile.authType == .sshKey {
                HStack {
                    TextField("Optional", text: Binding(
                        get: { profile.keyPath ?? "" },
                        set: {
                            profile.keyPath = $0.trimmed.isEmpty ? nil : $0
                            profile.keyBookmarkData = nil
                        }
                    ))
                    .font(.body.monospaced())

                    Button("Choose…") {
                        showKeyImporter = true
                    }
                }
                SecureField("Key Passphrase (optional)", text: $keyPassphrase)
            } else {
                SecureField("Password", text: $password)
            }
        }
    }

    // MARK: - WordPress

    private var wordpressSection: some View {
        Section(header: Text("WordPress")) {
            TextField("WP Root Path", text: $profile.wpRootPath, prompt: Text("/var/www/html"))
                .font(.body.monospaced())
        }
    }

    // MARK: - Defaults

    private var defaultsSection: some View {
        Section(header: Text("Defaults")) {
            TextField("Staging Root", text: $profile.remoteStagingRoot, prompt: Text("~/wp-media-import"))
                .font(.body.monospaced())

            Toggle("Keep remote files after success", isOn: $profile.keepRemoteFiles)

            Toggle(
                "Generate AVIFs locally",
                isOn: Binding(
                    get: { profile.generateAvifsLocally ?? false },
                    set: { profile.generateAvifsLocally = $0 }
                )
            )
            Text(
                "Encodes AVIF versions of each JPEG on this Mac and uploads them next to the WordPress derivatives. Server-side AVIF conversion is skipped during import; LQIP placeholders are still generated."
            )
            .font(.caption)
            .foregroundStyle(.secondary)
        }
    }

    private var connectionTestSection: some View {
        Section(header: Text("Validation")) {
            HStack {
                Button(isTesting ? "Testing…" : "Test Connection") {
                    runConnectionTest()
                }
                .disabled(isTesting || !canSave || jobRunner.isRunning)

                if isTesting {
                    ProgressView()
                        .controlSize(.small)
                }

                if !testLines.isEmpty {
                    Label(testSuccess ? "Passed" : "Failed", systemImage: testSuccess ? "checkmark.circle.fill" : "xmark.circle.fill")
                        .foregroundStyle(testSuccess ? .green : .red)
                }
                Spacer()
            }

            if !testLines.isEmpty {
                ForEach(Array(testLines.enumerated()), id: \.offset) { _, line in
                    Text(line)
                        .font(.caption.monospaced())
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }

            // The reason Save is disabled, instead of a mute dead button.
            if let validationError {
                Text(validationError)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var canSave: Bool {
        validationError == nil
    }

    private func revalidate() {
        validationError = ProfileValidation.firstError(for: profile, password: password, context: .editor)
    }

    private func saveAndClose() {
        do {
            try onSave(
                profile,
                password,
                keyPassphrase
            )
            dismiss()
        } catch {
            saveError = error.localizedDescription
        }
    }

    private func runConnectionTest() {
        guard !jobRunner.isRunning else {
            testLines = ["Stop the active upload before running Test Connection."]
            testSuccess = false
            return
        }

        isTesting = true
        testLines = []
        testSuccess = false

        Task {
            // This Task inherits the view's main-actor isolation; no hop needed.
            let result = await jobRunner.testConnection(
                profile: profile,
                password: password.isEmpty ? nil : password,
                keyPassphrase: keyPassphrase.isEmpty ? nil : keyPassphrase
            )
            testLines = result.checks
            testSuccess = result.success
            isTesting = false
        }
    }
}
