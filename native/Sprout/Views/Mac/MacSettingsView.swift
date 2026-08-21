#if os(macOS)
import AppKit
import SwiftUI

/// The `Settings` scene (prototype `1d`), reached with `⌘,`.
///
/// **Not a sidebar item** (§Settings) and not a sheet on the main window. A Mac app's settings live
/// in a Settings scene; putting them in the body would give the app two places to change the server
/// and one of them would be wrong.
///
/// The panes are `SettingsView`'s sections regrouped, not rewritten — the same fields, the same
/// `ConfigRules` validation, the same draft-then-connect flow.
struct MacSettingsView: View {
    let model: AppModel

    @Environment(\.colorScheme) private var scheme

    var body: some View {
        TabView {
            Tab("General", systemImage: "gearshape") { MacSettingsGeneral(model: model) }
            Tab("Server", systemImage: "server.rack") { MacSettingsServer(model: model) }
            Tab("Appearance", systemImage: "paintbrush") { MacSettingsAppearance(model: model) }
            Tab("Notifications", systemImage: "bell") { MacSettingsNotifications(model: model) }
            Tab("Advanced", systemImage: "wrench.and.screwdriver") { MacSettingsAdvanced(model: model) }
        }
        .frame(width: 700, height: 520)
        .macSceneChrome(model, systemScheme: scheme)
        // Deliberately NOT the place the print-alert watcher is attached — `MacRoot` is, because
        // this window may never be opened and the toggles below default to ON. A pane that had to
        // be visited before its own switches meant anything would promise alerts to everyone who
        // never went looking.
    }
}

// MARK: - Shared pane chrome

/// One pane's frame. Every pane is a `Form` in `.grouped` style so the label column aligns across
/// panes — the prototype's right-aligned 96 pt label gutter is what `Form` gives natively on Mac,
/// and hand-rolling it would drift the moment a label got longer.
struct MacSettingsPane<Content: View>: View {
    let content: Content
    init(@ViewBuilder content: () -> Content) { self.content = content() }

    var body: some View {
        Form { content }
            .formStyle(.grouped)
            .scrollContentBackground(.hidden)
    }
}

// MARK: - General

struct MacSettingsGeneral: View {
    let model: AppModel
    @Environment(\.palette) private var c

    var body: some View {
        MacSettingsPane {
            Section {
                LabeledContent("Status") {
                    HStack(spacing: 7) {
                        Circle()
                            .fill(model.client == nil ? c.idle : c.running)
                            .frame(width: 6, height: 6)
                        Text(statusLine)
                    }
                }
                LabeledContent("Printer", value: model.printer?.name ?? "—")
            } header: {
                Text("CONNECTION")
            }

            Section {
                if model.isDemo {
                    Button("Leave demo mode") { Task { await model.exitDemo() } }
                } else {
                    Button("Try demo mode") { Task { await model.startDemo() } }
                    Text("Sample data, no server. Nothing is saved and your real settings are left alone.")
                        .scaledFont(11)
                        .foregroundStyle(c.t3)
                }
            } header: {
                Text("DEMO")
            }

            Section {
                Text(versionLine)
                    .scaledMono(10, weight: .medium)
                    .foregroundStyle(c.t3)
            }
        }
    }

    private var statusLine: String {
        if model.isDemo { return "Demo — no server" }
        guard model.client != nil else { return "Not connected" }
        let n = model.printers.count
        return "Connected · \(n) printer\(n == 1 ? "" : "s")"
    }

    private var versionLine: String {
        let v = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
        let b = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "?"
        return "SPROUT \(v) (\(b)) · NATIVE"
    }
}

// MARK: - Server

struct MacSettingsServer: View {
    let model: AppModel
    @Environment(\.palette) private var c

    @State private var baseUrl = ""
    @State private var apiKey = ""
    @State private var pushUrl = ""
    @State private var testing = false
    @State private var result: String?
    @State private var failed = false
    @State private var confirmDisconnect = false

    private var canSave: Bool {
        !ConfigRules.sanitizeBaseUrl(baseUrl).isEmpty
            && ConfigRules.isValidApiKey(apiKey)
            && !testing
    }

    var body: some View {
        MacSettingsPane {
            Section {
                TextField("Server URL", text: $baseUrl, prompt: Text(verbatim: "http://bambuddy.local:8080"))
                    .scaledMono(12, weight: .medium)
                HStack {
                    SecureField("API key", text: $apiKey, prompt: Text(verbatim: "bb_…"))
                        .scaledMono(12, weight: .medium)
                    Button("Test", action: test).disabled(!canSave)
                }
                if let result {
                    HStack(spacing: 7) {
                        Circle().fill(failed ? c.error : c.running).frame(width: 6, height: 6)
                        Text(result).scaledFont(11.5).foregroundStyle(c.t2)
                    }
                }
            } header: {
                Text("BAMBUDDY")
            } footer: {
                Text("The server that talks to your printer. Sprout never speaks to Bambu Lab’s cloud on its own.")
            }

            Section {
                TextField("Endpoint", text: $pushUrl, prompt: Text(verbatim: derivedHint))
                    .scaledMono(12, weight: .medium)
            } header: {
                Text("TRELLIS")
            } footer: {
                // Kept honest about BOTH of Trellis's jobs. Describing it as "push" alone is how the
                // Collections tab came to look like a push feature — see laPushUrl vs resolvePushUrl.
                Text("Trellis is a small service you run next to Bambuddy, on your own machine. It "
                   + "delivers lock-screen updates and serves your MakerWorld collections. "
                   + "Collections keep working even with push switched off.")
            }

            Section {
                Button("Save and reconnect", action: save)
                    .disabled(!canSave)
                Button("Disconnect", role: .destructive) { confirmDisconnect = true }
            }
        }
        .onAppear(perform: seed)
        .confirmationDialog("Disconnect from this server?", isPresented: $confirmDisconnect) {
            Button("Disconnect", role: .destructive) { model.signOut() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Sprout will forget the server address and API key on this Mac.")
        }
    }

    private var derivedHint: String {
        var probe = AppConfig(baseUrl: baseUrl, apiKey: apiKey)
        probe.pushUrl = nil
        return ConfigRules.laPushUrl(probe) ?? "optional"
    }

    private func seed() {
        guard let cfg = model.config else { return }
        baseUrl = cfg.baseUrl
        apiKey = cfg.apiKey
        pushUrl = cfg.pushUrl ?? ""
    }

    private func draft() -> AppConfig {
        var cfg = model.config ?? AppConfig()
        cfg.baseUrl = ConfigRules.sanitizeBaseUrl(baseUrl)
        cfg.apiKey = ConfigRules.sanitizeApiKey(apiKey)
        cfg.pushUrl = pushUrl.trimmingCharacters(in: .whitespaces).isEmpty ? nil : pushUrl
        return cfg
    }

    /// Probes WITHOUT saving. "Does this server answer" and "make this my server" are two questions,
    /// and a Test that quietly reconfigured the app would be the second wearing the first's label.
    private func test() {
        testing = true
        result = nil
        let cfg = draft()
        Task {
            defer { testing = false }
            do {
                let fleet = try await BambuddyClient(baseUrl: cfg.baseUrl, apiKey: cfg.apiKey).probe()
                failed = false
                result = "Connected · \(fleet.count) printer\(fleet.count == 1 ? "" : "s")"
            } catch {
                failed = true
                result = classifyConnectError(error).message
            }
        }
    }

    private func save() {
        var cfg = draft()
        testing = true
        Task {
            defer { testing = false }
            do {
                let fleet = try await BambuddyClient(baseUrl: cfg.baseUrl, apiKey: cfg.apiKey).probe()
                if cfg.printerId == nil || !fleet.contains(where: { $0.id == cfg.printerId }) {
                    cfg.printerId = fleet.first?.id
                    cfg.printerName = fleet.first?.name
                }
                await model.connect(cfg)
                failed = false
                result = "Saved."
            } catch {
                failed = true
                result = classifyConnectError(error).message
            }
        }
    }
}

// MARK: - Appearance

struct MacSettingsAppearance: View {
    let model: AppModel
    @Environment(\.palette) private var c

    var body: some View {
        MacSettingsPane {
            Section {
                // A segmented control rather than a toggle: "System" is a real third state, not the
                // absence of a choice, and collapsing it into on/off is what forces people to
                // re-pick every time the machine flips at sunset.
                Picker("Theme", selection: Binding(
                    get: { model.theme },
                    set: { model.theme = $0 }
                )) {
                    ForEach(ThemePreference.allCases) { Text($0.label).tag($0) }
                }
                .pickerStyle(.segmented)
            } header: {
                Text("APPEARANCE")
            } footer: {
                Text("Not redundant on Mac: Sprout's palette is its own, so this chooses which of "
                   + "its two palettes to use rather than following the system blindly.")
            }
        }
    }
}

// MARK: - Notifications (Mac-only)

/// Spec 1d's Mac-only pane: what the menu bar extra shows, and which events post a
/// `UNUserNotification`. It replaces the iOS Live Activity pane, because macOS has neither
/// ActivityKit nor — see `MacNotificationController` — a way to receive the remote banners Trellis
/// pushes to the iPhone.
///
/// Three of the toggles that used to be here were wired to nothing, and one of them ("Filament ran
/// out") was gated on a state the printer does not report at all. Every switch below now names the
/// observation it is driven by, and `MacNotifyKind` owns both halves so a toggle cannot exist
/// without an event or an event without a toggle.
struct MacSettingsNotifications: View {
    let model: AppModel
    @Environment(\.palette) private var c

    @AppStorage("mac.menuBar.showWhenIdle") private var showWhenIdle = false
    // One `@AppStorage` per kind rather than a loop: `@AppStorage` is a property wrapper and needs
    // a stored binding, and the keys come from `MacNotifyKind.Key` so the pane and
    // `MacNotifyPrefs.load` cannot drift onto different strings.
    @AppStorage(MacNotifyKind.Key.finished) private var notifyFinished = true
    @AppStorage(MacNotifyKind.Key.stopped) private var notifyStopped = true
    @AppStorage(MacNotifyKind.Key.problem) private var notifyProblem = true
    @AppStorage(MacNotifyKind.Key.plateCool) private var notifyPlateCool = true
    @AppStorage(MacNotifyKind.Key.dryingDone) private var notifyDryingDone = true

    private var notifications: MacNotificationController { .shared }
    private var advice: MacNotifyAuthorization.Advice {
        MacNotifyAuthorization.advice(notifications.authorization)
    }

    var body: some View {
        MacSettingsPane {
            permission
            menuBar
            events
            delivery
        }
        // The pane is the only place that asks for permission, and it re-reads it on every
        // appearance because it can be changed in System Settings behind the app's back.
        .task { await notifications.refreshAuthorization() }
    }

    // MARK: Permission

    private var permission: some View {
        Section {
            LabeledContent("macOS permission") {
                HStack(spacing: 7) {
                    Circle()
                        .fill(advice.willBeSeen ? c.running : c.error)
                        .frame(width: 6, height: 6)
                    Text(advice.label)
                }
            }
            if advice.canAsk {
                Button("Allow notifications…") {
                    Task { await notifications.requestAuthorization() }
                }
            } else if advice.canOpenSettings {
                Button("Open Notification settings") { openSystemNotificationSettings() }
            }
        } header: {
            Text("PERMISSION")
        } footer: {
            // Says the unhappy thing out loud. A pane that showed only switches would let someone
            // believe alerts were on while macOS was dropping every one of them.
            Text(advice.detail)
        }
    }

    // MARK: Menu bar

    private var menuBar: some View {
        Section {
            Toggle("Show the percentage when idle", isOn: $showWhenIdle)
        } header: {
            Text("MENU BAR")
        } footer: {
            Text("While printing the menu bar always shows the percentage. Off, an idle printer "
               + "shows just the Sprout mark.")
        }
    }

    // MARK: Events

    private var events: some View {
        Section {
            toggle(.finished, $notifyFinished)
            toggle(.stopped, $notifyStopped)
            toggle(.problem, $notifyProblem)
            toggle(.plateCool, $notifyPlateCool)
            toggle(.dryingDone, $notifyDryingDone)
        } header: {
            Text("NOTIFY ME WHEN")
        } footer: {
            Text("Every switch names what Sprout actually watches. There is no separate "
               + "“filament ran out” alert because the printer has no such state — a runout stops "
               + "the print and reports it as a pause, which is what “Print paused, halted or "
               + "failed” is watching for.")
        }
    }

    /// One switch, with the evidence behind it underneath.
    private func toggle(_ kind: MacNotifyKind, _ isOn: Binding<Bool>) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Toggle(kind.label, isOn: isOn)
            Text(kind.gatedOn)
                .scaledFont(11)
                .foregroundStyle(c.t3)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: Delivery

    private var delivery: some View {
        Section {
            LabeledContent("Alerts arrive", value: watchingLine)
            LabeledContent("Remote push", value: remotePushLine)
        } header: {
            Text("DELIVERY")
        } footer: {
            // The whole honest story, because the alternative is someone quitting Sprout before bed
            // and wondering why the phone was told and the Mac was not. Three `Text`s rather than
            // one string with blank lines in it: a `Text` literal is a `LocalizedStringKey`, which
            // SwiftUI parses as Markdown, and Markdown does not keep the paragraph breaks.
            VStack(alignment: .leading, spacing: 8) {
                Text("Sprout watches your printer over the connection it already has and posts "
                   + "these itself, so they arrive only while it is running — quitting it stops "
                   + "them. Closing the window does not: the menu bar item keeps the app alive.")
                Text("Your iPhone gets the same alerts remotely, pushed by Trellis. This Mac "
                   + "cannot: the relay that holds the push keys only sends to a token a device "
                   + "has claimed with App Attest, and macOS has no App Attest. Registering this "
                   + "Mac's token anyway would leave Trellis pushing at something that can never "
                   + "receive it, so Sprout does not register it.")
                Text("There is no Live Activity on Mac — the menu bar item is the equivalent.")
            }
        }
    }

    /// Says what the watcher is actually doing, not merely that it exists. "The loop is running"
    /// and "there is a printer to watch" are different facts, and reporting only the first would be
    /// reassuring in exactly the case where nothing can fire.
    private var watchingLine: String {
        guard notifications.isWatching else { return "Not yet — Sprout is not watching" }
        let n = notifications.watchedPrinters
        guard n > 0 else { return "While Sprout is running · no printer status yet" }
        return "While Sprout is running · \(n) printer\(n == 1 ? "" : "s")"
    }

    private var remotePushLine: String {
        // Reports the token as what it IS — present, and not deliverable — rather than hiding it.
        // Dropping it silently is the defect this pane was built to close.
        notifications.deviceToken == nil
            ? "Not registered with Apple yet"
            : "Registered with Apple · not deliverable on macOS"
    }

    /// macOS shows its own permission prompt exactly once, so a denied app can only send someone
    /// here. Opened through LaunchServices, which the sandbox permits.
    private func openSystemNotificationSettings() {
        guard let url = URL(
            string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension"
        ) else { return }
        NSWorkspace.shared.open(url)
    }
}

// MARK: - Advanced

struct MacSettingsAdvanced: View {
    let model: AppModel
    @Environment(\.palette) private var c

    @State private var adminUsername = ""
    @State private var adminPassword = ""

    var body: some View {
        MacSettingsPane {
            Section {
                TextField("Username", text: $adminUsername)
                SecureField("Password", text: $adminPassword)
                // `connect`, not `update`. `BambuddyClient` captures the admin credentials as
                // `let`s at init and is only ever constructed by `AppModel.connect`, so `update`
                // answered the nearby question — "persist this" — instead of the real one, "make
                // this the live session's credentials". The visible cost: Hardware kept printing
                // "add the admin username and password in Settings" directly under credentials that
                // had just been added, and library rename/delete/move kept 403ing, until relaunch.
                // iOS routes the same two fields through `connect` for exactly this reason.
                // Disabled in demo, and it says so below. The demo has no Bambuddy to hold
                // credentials, and `connect` now refuses to persist the sentinel config anyway — but
                // a button that runs and changes nothing is the failure this codebase keeps
                // rediscovering, so the reason is on screen rather than discovered by clicking.
                Button("Save") {
                    guard var cfg = model.config, !model.isDemo else { return }
                    cfg.adminUsername = adminUsername.isEmpty ? nil : adminUsername
                    cfg.adminPassword = adminPassword.isEmpty ? nil : adminPassword
                    Task { await model.connect(cfg) }
                }
                .disabled(model.isDemo)
            } header: {
                Text("BAMBUDDY ADMIN")
            } footer: {
                Text(model.isDemo
                     ? "Not available in the demo — there is no server to sign in to. Connect to "
                     + "your Bambuddy first."
                     : "Optional. Settings writes and library file operations are admin-only — a "
                     + "scoped API key gets 403 for those, and reads work without this.")
            }

            Section {
                LabeledContent("LAN developer mode", value: lanLine)
            } header: {
                Text("PRINTER")
            } footer: {
                Text("Read from the printer, not set here. With LAN mode off, some controls are "
                   + "unavailable and Sprout says so on the control itself rather than failing "
                   + "when you use it.")
            }
        }
        .onAppear {
            adminUsername = model.config?.adminUsername ?? ""
            adminPassword = model.config?.adminPassword ?? ""
        }
    }

    private var lanLine: String {
        switch model.lanMode {
        case .on: "On"
        case .off: "Off"
        case .unknown: "Unknown"
        }
    }
}
#endif
