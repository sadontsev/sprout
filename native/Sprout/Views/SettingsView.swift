#if os(iOS)
// iOS sheet. macOS uses a Settings scene (1d).
// Compiled for iOS only — see docs/native-rewrite/18-mac-port-architecture.md.
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
            return "Leave empty to use \(derived) – derived from the server address."
        }
        return "No Trellis address could be derived from the server address. Enter it to get "
             + "lock-screen updates and MakerWorld collections."
    }
    @State private var serverPush = true
    @State private var texturizeUrl = ""
    @State private var texturize = true
    @State private var showAdvanced = false
    @State private var showTrellisInfo = false
    @State private var showBambuddyInfo = false

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
                    trellisSection
                    adminSection
                    if let error { errorBox(error) }
                    primaryButton
                    if !isOnboarding { signOutButton }
                    demoButton
                    appearance
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

    /// The Bambuddy server itself: the one thing the app genuinely cannot work without.
    ///
    /// Labelled for the software rather than "CONNECTION", so the three sections read as the three
    /// things being configured, and given the same (i) as Trellis. Someone arriving with no idea
    /// what Bambuddy is gets an answer and a link instead of two empty fields.
    private var connection: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 6) {
                sectionLabel("BAMBUDDY")
                Tap { withAnimation(Motion.standard(0.25)) { showBambuddyInfo.toggle() } } content: {
                    Image(systemName: showBambuddyInfo ? "info.circle.fill" : "info.circle")
                        .font(.system(size: 13))
                        .foregroundStyle(c.accent)
                        .contentShape(.rect)
                }
                .accessibilityLabel("What is Bambuddy?")
                Spacer()
            }

            if showBambuddyInfo {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Bambuddy is the server that actually talks to your printer. You run it "
                         + "yourself, on a NAS, a Pi or any spare box that runs Docker. Sprout is a "
                         + "client for it and does nothing on its own.")
                        .font(.system(size: 12))
                        .foregroundStyle(c.t2)
                        .fixedSize(horizontal: false, vertical: true)
                    bullet("Server URL – where Bambuddy is reachable, from this phone.")
                    bullet("API key – made in Bambuddy under Settings, and starts with bb_ .")
                    Text("No server yet? The demo below runs the whole app on sample data.")
                        .font(.system(size: 12))
                        .foregroundStyle(c.t3)
                        .fixedSize(horizontal: false, vertical: true)
                    Link(destination: URL(string: "https://github.com/maziggy/bambuddy")!) {
                        HStack(spacing: 5) {
                            Text("Bambuddy on GitHub")
                                .font(.system(size: 12.5, weight: .semibold))
                            Image(systemName: "arrow.up.right")
                                .font(.system(size: 10, weight: .bold))
                        }
                        .foregroundStyle(c.accent)
                    }
                }
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(c.s2))
                .transition(.opacity.combined(with: .move(edge: .top)))
            }

            field("Server URL", text: $baseUrl, placeholder: "https://bambuddy.example.com", keyboard: .URL)
            field("API key", text: $apiKey, placeholder: "bb_…", secure: true)
            if !apiKey.isEmpty, !ConfigRules.isValidApiKey(apiKey) {
                Text("That doesn't look like a Bambuddy key – they start with bb_ .")
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

    /// Trellis: the box the owner runs beside Bambuddy.
    ///
    /// Named, explained and linked, because "push server" told nobody anything. The (i) unfolds
    /// rather than always showing: someone who already runs one does not need the paragraph, and
    /// someone who does not needs more than a field label.
    private var trellisSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 6) {
                sectionLabel("TRELLIS")
                Tap { withAnimation(Motion.standard(0.25)) { showTrellisInfo.toggle() } } content: {
                    Image(systemName: showTrellisInfo ? "info.circle.fill" : "info.circle")
                        .font(.system(size: 13))
                        .foregroundStyle(c.accent)
                        .contentShape(.rect)
                }
                .accessibilityLabel("What is Trellis?")
                Spacer()
            }

            // A claim that cannot be built is otherwise INVISIBLE: the relay accepts the
            // registration and then never pushes to it, so nothing errors and the only symptom is a
            // lock-screen card that never moves. Shown here rather than logged, per this repo's
            // rule that an absent capability says so instead of being discovered by hitting it.
            if let claimIssue = model.liveActivity?.claimHealth.message {
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 12))
                        .foregroundStyle(c.paused)
                    Text(claimIssue)
                        .font(.system(size: 12))
                        .foregroundStyle(c.t2)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(c.s2))
            }

            if showTrellisInfo {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Trellis is a small service you run next to Bambuddy, on your own machine. "
                         + "It does what this app cannot do alone:")
                        .font(.system(size: 12))
                        .foregroundStyle(c.t2)
                    // Push is BOTH kinds, and the app really does both now: PushRegistrar asks for
                    // alert/sound/badge and registers for remote notifications, and Trellis sends
                    // apns-push-type "alert" for finished and failed prints as well as the
                    // liveactivity updates. The old copy promised only the card because, when it was
                    // written, banners genuinely did not arrive.
                    bullet("Push – notifications when a print finishes or fails, and the lock-screen "
                           + "Live Activity kept current while the app is closed.")
                    bullet("MakerWorld collections (optional) – read with the Bambu account your "
                           + "server is already signed in to, so your phone never holds that token.")
                    bullet("MakerWorld import (optional) – the download runs on your server, not here.")
                    Text("The MakerWorld parts are extras: push and the Live Activity work without "
                         + "them. Everything else in the app works without Trellis at all.")
                        .font(.system(size: 12))
                        .foregroundStyle(c.t3)
                        .fixedSize(horizontal: false, vertical: true)
                    Link(destination: URL(string: "https://github.com/sadontsev/sprout/tree/main/deploy/trellis")!) {
                        HStack(spacing: 5) {
                            Text("Set it up on GitHub")
                                .font(.system(size: 12.5, weight: .semibold))
                            Image(systemName: "arrow.up.right")
                                .font(.system(size: 10, weight: .bold))
                        }
                        .foregroundStyle(c.accent)
                    }
                }
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(c.s2))
                .transition(.opacity.combined(with: .move(edge: .top)))
            }

            toggleRow("Push via server", isOn: $serverPush,
                      hint: "On lets Trellis send print notifications and keep the lock-screen Live "
                          + "Activity current while the app is closed. Off keeps the card local: it "
                          + "updates only while the app is running, and no notifications arrive.")
            if serverPush {
                field("Trellis URL", text: $pushUrl, placeholder: derivedPushHint, keyboard: .URL)
                // The resolved value, not a promise that one exists.
                Text(pushResolutionNote)
                    .font(.system(size: 11))
                    .foregroundStyle(c.t3)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    /// Bambuddy admin — now for exactly one thing.
    ///
    /// The copy used to say admin unlocked "marking maintenance done, and saving slicer overrides".
    /// Measured against a current Bambuddy: `POST /maintenance/items/{id}/perform` answers with the
    /// plain API key (404 for a missing item, not 403), so maintenance no longer needs this at all.
    /// `PUT /local-presets/{id}` still answers 403. Listing one thing it genuinely unlocks beats
    /// listing two when one of them stopped being true.
    private var adminSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            Tap { withAnimation(Motion.standard(0.25)) { showAdvanced.toggle() } } content: {
                HStack {
                    sectionLabel("BAMBUDDY ADMIN")
                    Text("optional")
                        .font(.mono(10))
                        .foregroundStyle(c.t3)
                    Spacer()
                    Image(systemName: showAdvanced ? "chevron.up" : "chevron.down")
                        .font(.system(size: 12))
                        .foregroundStyle(c.t3)
                }
                .contentShape(.rect)
            }

            if showAdvanced {
                VStack(alignment: .leading, spacing: 14) {
                    Text("Only needed to save a custom print profile. Bambuddy stores a slicer "
                         + "override as a local preset, and it refuses to create one for an API key.")
                        .font(.system(size: 12))
                        .foregroundStyle(c.t2)
                        .fixedSize(horizontal: false, vertical: true)
                    Text("You need a custom profile when a stock Bambu preset does not describe what "
                         + "you are actually printing – a filament Bambu doesn’t sell, a temperature "
                         + "or layer height you have tuned for one model, or a nozzle the stock "
                         + "profile doesn’t cover. Without admin you can still slice and print with "
                         + "every stock preset; you just cannot save a tweak for next time.")
                        .font(.system(size: 11.5))
                        .foregroundStyle(c.t3)
                        .fixedSize(horizontal: false, vertical: true)

                    field("Admin username", text: $adminUsername, placeholder: "optional")
                    field("Admin password", text: $adminPassword, placeholder: "optional", secure: true)
                    if !adminUsername.isEmpty {
                        Tap(action: verifyAdmin) {
                            Text(adminCheck ?? "Check admin login")
                                .font(.system(size: 13, weight: .semibold))
                                .foregroundStyle(c.accent)
                        }
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

    private func bullet(_ text: String) -> some View {
        HStack(alignment: .top, spacing: 7) {
            Text(verbatim: "·").font(.system(size: 12, weight: .bold)).foregroundStyle(c.accent)
            Text(text)
                .font(.system(size: 12))
                .foregroundStyle(c.t2)
                .fixedSize(horizontal: false, vertical: true)
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

    /// The way in for someone who has no server — which includes every App Store reviewer.
    ///
    /// Without this the app's first screen asks for a base URL and an API key that a reviewer
    /// cannot possibly have, so there is nothing for them to evaluate. It sits below the real
    /// connect button rather than beside it: the demo is the fallback, not the recommendation.
    private var demoButton: some View {
        VStack(spacing: 8) {
            Tap {
                Task { await model.startDemo() }
            } content: {
                HStack(spacing: 8) {
                    Image(systemName: "play.rectangle")
                        .font(.system(size: 14, weight: .semibold))
                    Text(isOnboarding ? "Explore the demo" : "Open the demo")
                        .font(.system(size: 15, weight: .semibold))
                }
                .foregroundStyle(c.accent)
                .frame(maxWidth: .infinity)
                .frame(height: 48)
                .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(c.accentDim))
                .contentShape(.rect)
            }
            Text(isOnboarding
                 ? "Sample data, no server and no printer. Nothing leaves your device, and nothing "
                 + "can be controlled – every screen is real, the machine behind it is not."
                 // Safe from a configured app: leaving the demo restores this session rather than
                 // clearing it, which is why the banner says "Exit demo" and not "Sign out".
                 : "Sample data, for showing the app to someone. Your connection is kept and comes "
                 + "back when you leave.")
                .font(.system(size: 11.5))
                .foregroundStyle(c.t3)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
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
#endif
