#if os(macOS)
import AppKit
import SwiftUI

/// The chamber camera in its own window (prototype `1c`).
///
/// Reuses `MJPEGStream` + `CameraRenderer` unchanged (§5.2); only the chrome differs from iOS. The
/// PiP path is not involved at all — this window IS the Mac's answer to PiP (§6).
struct MacCameraWindow: View {
    let model: AppModel
    let printerId: Int

    @Environment(\.palette) private var c
    @Environment(\.metrics) private var m
    @Environment(\.colorScheme) private var scheme

    @State private var cam = CameraStreamModel()
    @State private var paused = false
    @State private var floating = false
    @State private var showOverlayStats = true
    @State private var saveError: String?

    private var printer: Printer? { model.printers.first { $0.id == printerId } }

    /// Always the full rate. The dashboard tile deliberately asks for a low rate on a metered path
    /// (`CameraRate.tileMetered`); a window the user opened on purpose is the case that wants
    /// frames, and a Mac is not on a phone plan.
    private var streamURL: URL? {
        guard let client = model.client, let token = model.cameraToken else { return nil }
        return client.streamUrl(printerId, token: token, fps: CameraRate.fullscreen)
    }

    var body: some View {
        VStack(spacing: 0) {
            stream
            controls
        }
        .background(c.bg)
        .environment(\.palette, Palette.forScheme(model.theme.colorScheme ?? scheme))
        .environment(\.metrics, .mac)
        .navigationTitle("Chamber camera — \(printer?.name ?? "Printer")")
        .onAppear { model.cameraOwnership.windowOpened(printerId: printerId) }
        .onDisappear {
            model.cameraOwnership.windowClosed(printerId: printerId)
            // Explicit rather than relying on `dismantleNSView`: the claim must be handed back the
            // moment the window goes, or the inspector tile sits on its last frame forever.
            paused = true
        }
        .alert("Couldn’t save the frame", isPresented: Binding(
            get: { saveError != nil }, set: { if !$0 { saveError = nil } }
        )) {
            Button("OK", role: .cancel) { saveError = nil }
        } message: {
            Text(verbatim: saveError ?? "")
        }
    }

    private var stream: some View {
        CameraStreamView(url: paused ? nil : streamURL, active: !paused, model: cam)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(c.thumb)
            .overlay(alignment: .topLeading) { if showOverlayStats { liveBadge } }
            .overlay(alignment: .topTrailing) { if showOverlayStats { layerBadge } }
            .overlay { if streamURL == nil { noTokenNote } }
    }

    private var liveBadge: some View {
        HStack(spacing: 7) {
            PulseDot(color: c.error, size: 6)
            Text(cam.isLive ? "LIVE · MJPEG" : (paused ? "PAUSED" : "CONNECTING…"))
                .font(.mono(10, weight: .semibold))
                .foregroundStyle(c.t1)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(c.bg.opacity(0.7)))
        .padding(14)
    }

    private var layerBadge: some View {
        let vm = model.vm
        return Text(vm.kind == .live ? "LAYER \(vm.layer) · \(vm.progressInt) %" : vm.stateLabel.uppercased())
            .font(.mono(10, weight: .medium))
            .monospacedDigit()
            .foregroundStyle(c.t2)
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(c.bg.opacity(0.7)))
            .padding(14)
    }

    /// The camera is gated by a stream TOKEN, not by the API key — a missing token is a specific,
    /// recoverable state and saying "no signal" for it would send someone to look at the printer.
    private var noTokenNote: some View {
        Text("Waiting for a camera token from Bambuddy.")
            .font(.system(size: m.body))
            .foregroundStyle(c.t2)
    }

    private var controls: some View {
        HStack(spacing: 9) {
            Button {
                paused.toggle()
            } label: {
                Image(systemName: paused ? "play.fill" : "pause.fill")
                    .frame(width: 34, height: 34)
            }
            .buttonStyle(.borderless)
            .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(c.s3))
            .help(paused ? "Resume the stream" : "Pause the stream")

            Button("Snapshot", action: copyFrameToPasteboard)
                .buttonStyle(MacSecondaryButtonStyle())
                .disabled(!cam.isLive)

            Button("Save frame…", action: saveFrame)
                .buttonStyle(MacSecondaryButtonStyle())
                .disabled(!cam.isLive)

            Spacer(minLength: 0)

            Toggle("Float on top", isOn: $floating)
                .toggleStyle(.switch)
                .onChange(of: floating) { _, on in setFloating(on) }

            Toggle("Overlay stats", isOn: $showOverlayStats)
                .toggleStyle(.switch)
        }
        .padding(.horizontal, 16)
        .frame(height: 76)
        .background(c.s1)
        .overlay(alignment: .top) { Rectangle().fill(c.line).frame(height: 1) }
    }

    /// `NSWindow.level = .floating`. Reached through the view's own window rather than
    /// `NSApp.keyWindow`, so toggling it in one camera window cannot float a different one.
    private func setFloating(_ on: Bool) {
        guard let window = NSApp.windows.first(where: { $0.isKeyWindow })
            ?? NSApp.windows.first(where: { $0.title.hasPrefix("Chamber camera") })
        else { return }
        window.level = on ? .floating : .normal
    }

    private func copyFrameToPasteboard() {
        guard let image = currentFrame() else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.writeObjects([image])
    }

    /// A save PANEL, not a silent write to Photos. The Mac has no photo library by default, and the
    /// app is sandboxed — `files.user-selected.read-write` is what the panel grants, so this is both
    /// the idiomatic and the only permitted path.
    private func saveFrame() {
        guard let image = currentFrame(), let png = image.pngRepresentationData() else {
            saveError = "There is no frame to save yet."
            return
        }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.png]
        panel.nameFieldStringValue = "\(printer?.name ?? "printer")-frame.png"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try png.write(to: url)
        } catch {
            saveError = error.localizedDescription
        }
    }

    /// The most recent frame, decoded on demand from the renderer's stash.
    private func currentFrame() -> PlatformImage? {
        guard let jpeg = cam.renderer?.frameStash.latest() else { return nil }
        return PlatformImage.decoded(from: jpeg)
    }
}
#endif
