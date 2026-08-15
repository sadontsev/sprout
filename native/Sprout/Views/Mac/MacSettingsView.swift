#if os(macOS)
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
        .environment(\.palette, Palette.forScheme(model.theme.colorScheme ?? scheme))
        .environment(\.metrics, .mac)
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
                        .font(.system(size: 11))
                        .foregroundStyle(c.t3)
                }
            } header: {
                Text("DEMO")
            }

            Section {
                Text(versionLine)
                    .font(.mono(10, weight: .medium))
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
                    .font(.mono(12, weight: .medium))
                HStack {
                    SecureField("API key", text: $apiKey, prompt: Text(verbatim: "bb_…"))
                        .font(.mono(12, weight: .medium))
                    Button("Test", action: test).disabled(!canSave)
                }
                if let result {
                    HStack(spacing: 7) {
                        Circle().fill(failed ? c.error : c.running).frame(width: 6, height: 6)
                        Text(result).font(.system(size: 11.5)).foregroundStyle(c.t2)
                    }
                }
            } header: {
                Text("BAMBUDDY")
            } footer: {
                Text("The server that talks to your printer. Sprout never speaks to Bambu Lab’s cloud on its own.")
            }

            Section {
                TextField("Endpoint", text: $pushUrl, prompt: Text(verbatim: derivedHint))
                    .font(.mono(12, weight: .medium))
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

struct MacSettingsNotifications: View {
    let model: AppModel
    @Environment(\.palette) private var c

    @AppStorage("mac.menuBar.showWhenIdle") private var showWhenIdle = false
    @AppStorage("mac.notify.printFinished") private var notifyFinished = true
    @AppStorage("mac.notify.printFailed") private var notifyFailed = true
    @AppStorage("mac.notify.filamentRunout") private var notifyRunout = true

    var body: some View {
        MacSettingsPane {
            Section {
                Toggle("Show the percentage when idle", isOn: $showWhenIdle)
            } header: {
                Text("MENU BAR")
            } footer: {
                Text("While printing the menu bar always shows the percentage. Off, an idle printer "
                   + "shows just the Sprout mark.")
            }

            Section {
                Toggle("Print finished", isOn: $notifyFinished)
                Toggle("Print failed or halted", isOn: $notifyFailed)
                Toggle("Filament ran out", isOn: $notifyRunout)
            } header: {
                Text("NOTIFY ME WHEN")
            } footer: {
                // States the mechanism plainly, because it is genuinely different from iOS and the
                // difference is user-visible: these fire from the app's own live connection, so
                // they arrive only while Sprout is running.
                Text("These are posted by Sprout itself from its live connection to Bambuddy, so "
                   + "they arrive while Sprout is running. There is no Live Activity on Mac — the "
                   + "menu bar is the equivalent.")
            }
        }
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
                Button("Save") {
                    model.update {
                        $0.adminUsername = adminUsername.isEmpty ? nil : adminUsername
                        $0.adminPassword = adminPassword.isEmpty ? nil : adminPassword
                    }
                }
            } header: {
                Text("BAMBUDDY ADMIN")
            } footer: {
                Text("Optional. Settings writes and library file operations are admin-only — a "
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
