#if os(macOS)
import AppKit
import SwiftUI

/// The no-config state (prototype `1e`).
///
/// Same two fields and the same `bb_` validation as iOS — deliberately, because the validation is
/// `ConfigRules` and forking it would let two platforms disagree about what a valid key is.
///
/// What differs is the window. iOS onboards inside the app's only screen; on Mac this is a
/// fixed-size, **non-resizable** window with no sidebar and no toolbar, and on success it does not
/// open a second window — the same `WindowGroup` re-renders as `MacWindow` because `MacRoot`'s gate
/// flips. Resizing is enabled at the same moment, so a window that cannot yet show three columns
/// cannot be dragged into pretending it can.
struct MacOnboardingView: View {
    let model: AppModel

    @Environment(\.palette) private var c
    @Environment(\.metrics) private var m

    @State private var baseUrl = ""
    @State private var apiKey = ""
    @State private var connecting = false
    @State private var error: String?
    @FocusState private var focus: Field?

    private enum Field { case url, key }

    private var canConnect: Bool {
        !ConfigRules.sanitizeBaseUrl(baseUrl).isEmpty
            && ConfigRules.isValidApiKey(apiKey)
            && !connecting
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            NozzleIcon(color: c.accent, size: 52)
                .padding(.bottom, 18)

            Text("Point Sprout at your server")
                .font(.system(size: 25, weight: .bold))
                .tracking(-0.7)
                .foregroundStyle(c.t1)

            Text("Bambuddy is the server that actually talks to your printer. You run it yourself — "
               + "Sprout never speaks to Bambu Lab’s cloud on its own.")
                .font(.system(size: 13))
                .lineSpacing(3)
                .foregroundStyle(c.t2)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: 420, alignment: .leading)
                .padding(.top, 9)

            VStack(spacing: 9) {
                field("http://bambuddy.local:8080", text: $baseUrl, field: .url)
                    .onSubmit { focus = .key }
                field("bb_ your API key", text: $apiKey, field: .key)
                    .onSubmit { if canConnect { connect() } }
            }
            .padding(.top, 22)

            if let error { errorBox(error).padding(.top, 14) }

            HStack(spacing: 12) {
                Button(connecting ? "Connecting…" : "Connect", action: connect)
                    .buttonStyle(MacPrimaryButtonStyle())
                    .disabled(!canConnect)
                    // ⏎ confirms, per §7's keyboard table.
                    .keyboardShortcut(.defaultAction)

                Button("Try demo mode") { Task { await model.startDemo() } }
                    .buttonStyle(MacSecondaryButtonStyle())

                Spacer(minLength: 0)

                Link("Bambuddy on GitHub ›", destination: URL(string: "https://github.com/JayFoxRox/bambuddy")!)
                    .font(.system(size: 12, weight: .semibold))
                    .tint(c.accent)
            }
            .padding(.top, 18)

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 64)
        .padding(.top, 14)
        .padding(.bottom, 24)
        .frame(width: 660, height: 470)
        .background(c.bg)
        .onAppear {
            baseUrl = model.config?.baseUrl ?? ""
            apiKey = model.config?.apiKey ?? ""
            focus = .url
            lockWindow()
        }
    }

    private func field(_ placeholder: String, text: Binding<String>, field: Field) -> some View {
        TextField("", text: text, prompt: Text(verbatim: placeholder).foregroundStyle(c.t3))
            .textFieldStyle(.plain)
            .font(.mono(12.5, weight: .medium))
            .foregroundStyle(c.t1)
            .focused($focus, equals: field)
            .padding(.horizontal, 12)
            .frame(height: 32)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: m.controlRadius, style: .continuous).fill(c.s2))
            .overlay(
                RoundedRectangle(cornerRadius: m.controlRadius, style: .continuous)
                    .stroke(focus == field ? c.accent : c.line2)
            )
            .disableAutocorrection(true)
    }

    private func errorBox(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 12))
            .foregroundStyle(c.t2)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(11)
            .background(RoundedRectangle(cornerRadius: m.controlRadius, style: .continuous).fill(c.errorDim))
    }

    /// Not resizable until a server answers (§1e). Done through AppKit because
    /// `.windowResizability` is a Scene modifier and this state lives inside one scene, not beside
    /// it — the same window becomes the 1440×900 main window the moment `model.client` exists.
    private func lockWindow() {
        guard let window = NSApp.keyWindow ?? NSApp.windows.first(where: \.isVisible) else { return }
        window.styleMask.remove(.resizable)
        window.setContentSize(NSSize(width: 660, height: 470))
        window.center()
    }

    private func connect() {
        error = nil
        connecting = true
        var cfg = AppConfig(
            baseUrl: ConfigRules.sanitizeBaseUrl(baseUrl),
            apiKey: ConfigRules.sanitizeApiKey(apiKey)
        )
        Task {
            defer { connecting = false }
            let probe = BambuddyClient(baseUrl: cfg.baseUrl, apiKey: cfg.apiKey)
            do {
                let fleet = try await probe.probe()
                // Adopt a real printer from the fleet rather than guessing an id.
                cfg.printerId = fleet.first?.id
                cfg.printerName = fleet.first?.name
                // Restore resizability BEFORE the gate flips, so the main window is not born stuck
                // at 660×470.
                if let window = NSApp.keyWindow ?? NSApp.windows.first(where: \.isVisible) {
                    window.styleMask.insert(.resizable)
                    window.setContentSize(NSSize(width: 1440, height: 900))
                    window.center()
                }
                await model.connect(cfg)
            } catch {
                self.error = classifyConnectError(error).message
            }
        }
    }
}
#endif
