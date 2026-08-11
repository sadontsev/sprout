import SwiftUI

/// Onboarding when there is no config, and the settings sheet afterwards. One screen for both,
/// because the fields are the same and the only real difference is what the primary button says.
struct SettingsView: View {
    let model: AppModel
    let isOnboarding: Bool

    @Environment(\.palette) private var c
    @Environment(\.dismiss) private var dismiss

    @State private var baseUrl = ""
    @State private var apiKey = ""
    @State private var adminUsername = ""
    @State private var adminPassword = ""
    @State private var pushUrl = ""

    /// What the field will fall back to if left empty, or nil when nothing can be derived.
    private var derivedFromBase: String? {
        var probe = AppConfig(baseUrl: baseUrl, apiKey: apiKey)
        probe.pushUrl = nil
        return ConfigRules.laPushUrl(probe)
    }

    private var derivedPushHint: String {
        derivedFromBase ?? "https://trellis.example.com"
    }

    /// One sentence saying where registrations will actually go, and what it costs if that is
    /// unreachable — the failure is otherwise a card that simply never updates.
    private var pushResolutionNote: String {
        if !pushUrl.trimmingCharacters(in: .whitespaces).isEmpty {
            return "Cards register here. Trellis runs beside Bambuddy on port \(ConfigRules.trellisPort)."
        }
        if let derived = derivedFromBase {
            return "Leave empty to use \(derived) — derived from the server address."
        }
        return "No Trellis address could be derived from the server address. Enter it to get "
             + "lock-screen updates and MakerWorld collections."
    }
    @State private var serverPush = true
    @State private var texturizeUrl = ""
    @State private var texturize = true
    @State private var showAdvanced = false

    @State private var connecting = false
    @State private var error: String?
    @State private var adminCheck: String?

    private var canConnect: Bool {
        !ConfigRules.sanitizeBaseUrl(baseUrl).isEmpty && ConfigRules.isValidApiKey(apiKey) && !connecting
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    if isOnboarding { intro }
                    connection
                    if let error { errorBox(error) }
                    appearance
                    advanced
                    primaryButton
                    if !isOnboarding { signOutButton }
                    version
                }
                .padding(20)
            }
            .scrollIndicators(.hidden)
            .background(c.bg)
            .navigationTitle(isOnboarding ? "" : "Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                if !isOnboarding {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Done") { dismiss() }.tint(c.accent)
                    }
                }
            }
        }
        .onAppear(perform: seedFromConfig)
    }

    private func seedFromConfig() {
        guard let cfg = model.config else { return }
        baseUrl = cfg.baseUrl
        apiKey = cfg.apiKey
        adminUsername = cfg.adminUsername ?? ""
        adminPassword = cfg.adminPassword ?? ""
        pushUrl = cfg.pushUrl ?? ""
        serverPush = cfg.serverPush ?? true
        texturizeUrl = cfg.texturizeUrl ?? ""
        texturize = cfg.texturize ?? true
    }

    // MARK: - Sections

    private var intro: some View {
        VStack(alignment: .leading, spacing: 10) {
            NozzleIcon(color: c.accent, size: 44)
            Text("Sprout")
                .font(.system(size: 30, weight: .bold))
                .tracking(-0.8)
                .foregroundStyle(c.t1)
            Text("Point the app at your self-hosted Bambuddy server.")
                .font(.system(size: 14))
                .foregroundStyle(c.t2)
        }
        .padding(.bottom, 4)
    }

    private var connection: some View {
        VStack(alignment: .leading, spacing: 14) {
            sectionLabel("CONNECTION")
            field("Server URL", text: $baseUrl, placeholder: "https://bambuddy.example.com", keyboard: .URL)
            field("API key", text: $apiKey, placeholder: "bb_…", secure: true)
            if !apiKey.isEmpty, !ConfigRules.isValidApiKey(apiKey) {
                Text("That doesn't look like a Bambuddy key — they start with bb_ .")
                    .font(.system(size: 11))
                    .foregroundStyle(c.heating)
            }
        }
    }

    private var appearance: some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionLabel("APPEARANCE")
            // A segmented control rather than a toggle: "System" is a real third state, not the
            // absence of a choice, and collapsing it into on/off is what forces people to re-pick
            // every time the device flips at sunset.
            HStack(spacing: 6) {
                ForEach(ThemePreference.allCases) { option in
                    let on = model.theme == option
                    Tap {
                        withAnimation(Motion.standard(0.22)) { model.theme = option }
                    } content: {
                        Text(option.label)
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(on ? c.accentInk : c.t2)
                            .frame(maxWidth: .infinity)
                            .frame(height: 40)
                            .background(
                                RoundedRectangle(cornerRadius: 11, style: .continuous)
                                    .fill(on ? c.accent : c.s1)
                            )
                            .overlay(
                                RoundedRectangle(cornerRadius: 11, style: .continuous)
                                    .stroke(on ? .clear : c.line)
                            )
                    }
                    .accessibilityLabel(option.label)
                    .accessibilityAddTraits(on ? [.isSelected, .isButton] : .isButton)
                }
            }
        }
    }

    private var advanced: some View {
        VStack(alignment: .leading, spacing: 14) {
            Tap { withAnimation(Motion.standard(0.25)) { showAdvanced.toggle() } } content: {
                HStack {
                    sectionLabel("ADVANCED")
                    Spacer()
                    Image(systemName: showAdvanced ? "chevron.up" : "chevron.down")
                        .font(.system(size: 12))
                        .foregroundStyle(c.t3)
                }
                .contentShape(.rect)
            }

            if showAdvanced {
                VStack(alignment: .leading, spacing: 14) {
                    Text("Admin login unlocks the few actions Bambuddy refuses API keys for — marking maintenance done, and saving slicer overrides.")
                        .font(.system(size: 11))
                        .foregroundStyle(c.t3)
                    field("Admin username", text: $adminUsername, placeholder: "optional")
                    field("Admin password", text: $adminPassword, placeholder: "optional", secure: true)
                    if !adminUsername.isEmpty {
                        Tap(action: verifyAdmin) {
                            Text(adminCheck ?? "Check admin login")
                                .font(.system(size: 13, weight: .semibold))
                                .foregroundStyle(c.accent)
                        }
                    }

                    // The hint says only what this build does. It once ended "…and there are no push
                    // banners", which reads as a promise that ON delivers them — the native build
                    // registers Live Activity push tokens but never registers for notifications, so
                    // there are no banners in either position.
                    toggleRow("Live Activity via server", isOn: $serverPush,
                              hint: "On lets your server keep the lock-screen card current in the background. Off keeps it local: it updates only while the app is running.")
                    if serverPush {
                        // Named for what it is. "Push server" read as the service that delivers the
                        // push — which is Canopy, which the app never talks to and which would
                        // reject it. This is Trellis: your own box, beside Bambuddy.
                        field("Trellis URL", text: $pushUrl,
                              placeholder: derivedPushHint, keyboard: .URL)
                        // The resolved value, not a promise that one exists. The placeholder used
                        // to read "derived from the server host" while derivation returned nil for
                        // every address that was not a `bambuddy.` hostname — so push and the
                        // Collections tab were both off, and the field said it had it covered.
                        Text(pushResolutionNote)
                            .font(.system(size: 11))
                            .foregroundStyle(c.t3)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    // The setting is kept so it survives a switch back to the RN build, but this
                    // build has no texturizer yet — a toggle that promises a feature which isn't
                    // there is worse than no toggle.
                    VStack(alignment: .leading, spacing: 5) {
                        HStack {
                            Text("Model texturizer")
                                .font(.system(size: 14, weight: .semibold))
                                .foregroundStyle(c.t3)
                            Spacer()
                            Text("Not in this build")
                                .font(.mono(10))
                                .foregroundStyle(c.t3)
                        }
                        Text("The stl-texturize sidecar isn't wired up natively yet. Your setting is kept.")
                            .font(.system(size: 11))
                            .foregroundStyle(c.t3)
                    }
                }
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
    }

    private var primaryButton: some View {
        Tap(disabled: !canConnect, action: connect) {
            HStack(spacing: 8) {
                if connecting { ProgressView().tint(c.accentInk) }
                Text(connecting ? "Connecting…" : (isOnboarding ? "Connect" : "Save"))
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(c.accentInk)
            }
            .frame(maxWidth: .infinity)
            .frame(height: 52)
            .background(RoundedRectangle(cornerRadius: 15, style: .continuous).fill(canConnect ? c.accent : c.s3))
        }
        .opacity(canConnect ? 1 : 0.6)
    }

    private var signOutButton: some View {
        Tap {
            model.signOut()
            dismiss()
        } content: {
            Text("Disconnect")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(c.error)
                .frame(maxWidth: .infinity)
                .frame(height: 48)
                .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(c.errorDim))
        }
    }

    private var version: some View {
        let v = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
        let b = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "?"
        return Text("Sprout \(v) (\(b)) · native")
            .font(.mono(10, weight: .medium))
            .foregroundStyle(c.t3)
            .frame(maxWidth: .infinity)
            .padding(.top, 6)
    }

    // MARK: - Pieces

    private func sectionLabel(_ s: String) -> some View {
        Text(s).font(.mono(10)).tracking(1).foregroundStyle(c.t3)
    }

    private func field(_ label: String, text: Binding<String>, placeholder: String, secure: Bool = false, keyboard: UIKeyboardType = .default) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(label).font(.system(size: 12, weight: .semibold)).foregroundStyle(c.t2)
            Group {
                if secure {
                    SecureField(placeholder, text: text)
                } else {
                    TextField(placeholder, text: text)
                }
            }
            .font(.system(size: 15))
            .foregroundStyle(c.t1)
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
            .keyboardType(keyboard)
            .padding(.horizontal, 14)
            .frame(height: 48)
            .background(RoundedRectangle(cornerRadius: 13, style: .continuous).fill(c.s1))
            .overlay(RoundedRectangle(cornerRadius: 13, style: .continuous).stroke(c.line))
        }
    }

    private func toggleRow(_ label: String, isOn: Binding<Bool>, hint: String) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack {
                Text(label).font(.system(size: 14, weight: .semibold)).foregroundStyle(c.t1)
                Spacer()
                PillToggle(value: isOn, onColor: c.accent, offColor: c.s3, knob: c.t1)
            }
            Text(hint).font(.system(size: 11)).foregroundStyle(c.t3)
        }
    }

    private func errorBox(_ message: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill").font(.system(size: 14)).foregroundStyle(c.error)
            Text(message).font(.system(size: 13)).foregroundStyle(c.t1)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(c.errorDim))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).stroke(c.error))
    }

    // MARK: - Actions

    private func draftConfig() -> AppConfig {
        var cfg = model.config ?? AppConfig()
        cfg.baseUrl = ConfigRules.sanitizeBaseUrl(baseUrl)
        cfg.apiKey = ConfigRules.sanitizeApiKey(apiKey)
        cfg.adminUsername = adminUsername.isEmpty ? nil : adminUsername
        cfg.adminPassword = adminPassword.isEmpty ? nil : adminPassword
        cfg.pushUrl = pushUrl.isEmpty ? nil : pushUrl
        cfg.serverPush = serverPush
        cfg.texturizeUrl = texturizeUrl.isEmpty ? nil : texturizeUrl
        cfg.texturize = texturize
        return cfg
    }

    /// Probe before saving, so a wrong URL or a rejected key fails HERE with a specific message
    /// instead of becoming a dashboard that says "Connecting" forever.
    private func connect() {
        error = nil
        connecting = true
        let cfg = draftConfig()
        Task {
            defer { connecting = false }
            let probe = BambuddyClient(baseUrl: cfg.baseUrl, apiKey: cfg.apiKey)
            do {
                let fleet = try await probe.probe()
                var saved = cfg
                // Adopt a real printer from the fleet rather than guessing an id.
                if saved.printerId == nil || !fleet.contains(where: { $0.id == saved.printerId }) {
                    saved.printerId = fleet.first?.id
                    saved.printerName = fleet.first?.name
                }
                await model.connect(saved)
                if !isOnboarding { dismiss() }
            } catch {
                self.error = classifyConnectError(error).message
            }
        }
    }

    private func verifyAdmin() {
        adminCheck = "Checking…"
        let cfg = draftConfig()
        Task {
            let probe = BambuddyClient(
                baseUrl: cfg.baseUrl, apiKey: cfg.apiKey,
                adminUsername: cfg.adminUsername, adminPassword: cfg.adminPassword
            )
            do {
                try await probe.verifyAdminLogin()
                adminCheck = "Admin login works"
            } catch {
                adminCheck = error.localizedDescription
            }
        }
    }
}
