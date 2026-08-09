import SwiftUI

/// Chrome colours for the fullscreen camera. Deliberately theme-INDEPENDENT: the video behind them
/// is always dark, so a light-mode palette would make the pills unreadable.
private enum Chrome {
    static let bg = Color(hex: 0x060708)
    /// `rgba(22,24,27, …)` — the round chips and the status pill.
    static let chip = Color(hex: 0x16181B, opacity: 0.6)
    static let pill = Color(hex: 0x16181B, opacity: 0.55)
    static let panel = Color(hex: 0x16181B, opacity: 0.97)
    static let dim = Color(hex: 0x3A4046)
    static let faint = Color(hex: 0x4F555B)
    static let muted = Color(hex: 0x6B7177)
    static let label = Color(hex: 0x9AA0A6)
    static let hairline = Color.white.opacity(0.10)
}

/// Fullscreen chamber camera — live MJPEG in an `AVSampleBufferDisplayLayer`, manual landscape,
/// Picture-in-Picture, and a diagnostics panel for when no picture arrives.
///
/// Three phases only: `connecting`, `live`, `failed`. **Warming up is not an error.** The A1's
/// camera is on-demand: it self-terminates ~7 s after the last viewer, and a cold start costs
/// seconds before the first JPEG — during which the socket is open and perfectly healthy. The
/// renderer reconnects on its own with a fast backoff, so this view's job is to look patient until
/// a wall-clock deadline says otherwise, not to cry failure at the first hiccup.
struct CameraOverlay: View {
    let model: AppModel

    @Environment(\.palette) private var c
    @Environment(\.dismiss) private var dismiss

    private enum Phase { case connecting, live, failed }

    /// Identity of one connection attempt. When it changes, the phase, the fast-fail probe and the
    /// warm-up deadline all re-arm together.
    private struct Attempt: Equatable {
        let token: String?
        let reload: Int
    }

    /// No stream URL means no native view mounts, so nothing else would ever report an outcome.
    private static let noTokenDeadline: Duration = .seconds(8)
    /// Wall-clock budget for the first frame. Bounded by time rather than by a retry count, so a
    /// slow warm-up and a fast-erroring dead camera converge on the same deadline.
    private static let warmUpDeadline: Duration = .seconds(40)

    @State private var pip = CameraPiPModel()
    @State private var phase: Phase = .connecting
    @State private var reloadKey = 0
    @State private var landscape = false
    /// Token minted by Retry. Takes precedence over `AppModel`'s shared one, which refreshes only on
    /// its own 45-minute timer — a rejected token is the single failure the renderer will not retry
    /// through, so the manual path has to be able to mint.
    @State private var localToken: String?

    @State private var showDiagnostics = false
    @State private var diagnosing = false
    @State private var diagnosis: CameraDiagnosis?
    @State private var diagnosisError: String?

    // MARK: - Derived

    private var token: String? { localToken ?? model.cameraToken }

    /// The token goes in the QUERY STRING; `X-API-Key` is rejected with 401 on stream and snapshot.
    private var streamUrl: URL? {
        guard let client = model.client, let token else { return nil }
        return client.streamUrl(model.printerId, token: token)
    }

    private var snapshotUrl: URL? {
        guard let client = model.client, let token else { return nil }
        return client.snapshotUrl(model.printerId, token: token)
    }

    private var attempt: Attempt { Attempt(token: token, reload: reloadKey) }

    private var live: Bool { phase == .live }

    /// A known-offline printer will never produce a frame — show the actionable card now rather than
    /// after a full warm-up deadline of spinning.
    private var failedView: Bool { phase == .failed || (!live && model.vm.kind == .offline) }

    private var cameraHint: String { PrinterProfile.forPrinter(model.printer).cameraHint }

    // MARK: - Body

    var body: some View {
        ZStack {
            Chrome.bg.ignoresSafeArea()

            GeometryReader { geo in
                let ins = geo.safeAreaInsets
                // The reader is laid out INSIDE the safe area, which is exactly why it is used: it
                // still reports the real insets, which the rotated chrome needs. The surface is then
                // sized to the full screen and shifted back over the insets — SwiftUI does not clip
                // a view to its layout bounds, so this paints edge to edge without `ignoresSafeArea`
                // zeroing out the numbers.
                let full = CGSize(
                    width: geo.size.width + ins.leading + ins.trailing,
                    height: geo.size.height + ins.top + ins.bottom
                )
                // Landscape without touching the native orientation: the app is portrait-locked, and
                // a manual toggle also keeps working when the phone's own rotation lock is ON, which
                // auto-rotate would not. The WHOLE overlay rotates — chrome included — so you turn
                // the phone and everything reads the right way up.
                let surface = landscape ? CGSize(width: full.height, height: full.width) : full

                surfaceBody(surface: surface, insets: ins)
                    .frame(width: surface.width, height: surface.height)
                    .clipped()
                    .rotationEffect(.degrees(landscape ? 90 : 0))
                    .position(x: full.width / 2 - ins.leading, y: full.height / 2 - ins.top)
            }
        }
        // Re-arm on a fresh token (re-mint) or a manual retry. Both tasks assign `.connecting`
        // synchronously before their first suspension, so the order they run in cannot matter.
        .task(id: attempt) {
            phase = .connecting
            await probeSnapshot()
        }
        .task(id: attempt) {
            phase = .connecting
            let limit = token == nil ? Self.noTokenDeadline : Self.warmUpDeadline
            try? await Task.sleep(for: limit)
            // A cancelled sleep means the attempt was superseded, not that it timed out.
            guard !Task.isCancelled else { return }
            if phase == .connecting { phase = .failed }
        }
        .onChange(of: pip.isLive) { _, isLive in
            if isLive { phase = .live }
        }
        .onChange(of: model.cameraToken) { _, _ in
            // The shared token just rotated; drop the manual one so both paths do not fight.
            localToken = nil
        }
    }

    private func surfaceBody(surface: CGSize, insets: EdgeInsets) -> some View {
        ZStack {
            Chrome.bg

            // Native sample-buffer view, never a WebView: an `<img>` can never enter PiP. It is NOT
            // re-created when the token rotates — the view hot-swaps the URL internally, because
            // rebuilding the display layer would take any active PiP window down with it.
            CameraPiPView(url: streamUrl, active: true, model: pip)

            if !live {
                stateCard
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .padding(.horizontal, 36)
                    // Connecting is informational; only the failed card owns touches.
                    .allowsHitTesting(failedView)
            }

            topChrome(insets: insets)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)

            if live {
                liveBadge(insets: insets)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
            }

            if showDiagnostics {
                diagnosticsPanel
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .transition(.opacity)
            }
        }
    }

    // MARK: - Non-live card

    @ViewBuilder
    private var stateCard: some View {
        VStack(spacing: 0) {
            if failedView {
                Image(systemName: "video.slash")
                    .font(.system(size: 30))
                    .foregroundStyle(Chrome.dim)
                Text("CHAMBER · NO SIGNAL")
                    .font(.mono(11, weight: .regular))
                    .tracking(2)
                    .foregroundStyle(Chrome.dim)
                    .padding(.top, 14)
                Text(failureCopy)
                    .font(.system(size: 13))
                    .lineSpacing(3.5)
                    .foregroundStyle(Chrome.muted)
                    .multilineTextAlignment(.center)
                    .padding(.top, 12)
                errorLine(prefix: "REPORTED", color: Chrome.faint)
                HStack(spacing: 10) {
                    Tap(action: retry) {
                        Text("Retry")
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 18)
                            .frame(height: 42)
                            .background(
                                RoundedRectangle(cornerRadius: 12, style: .continuous)
                                    .fill(Color.white.opacity(0.08))
                            )
                    }
                    Tap(action: runDiagnostics) {
                        Text("Diagnose")
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(Chrome.label)
                            .padding(.horizontal, 18)
                            .frame(height: 42)
                            .background(
                                RoundedRectangle(cornerRadius: 12, style: .continuous)
                                    .stroke(Chrome.hairline)
                            )
                    }
                }
                .padding(.top, 18)
            } else {
                ProgressView()
                    .progressViewStyle(.circular)
                    .tint(Chrome.muted)
                Text("CONNECTING…")
                    .font(.mono(11, weight: .regular))
                    .tracking(2)
                    .foregroundStyle(Chrome.muted)
                    .padding(.top, 14)
                Text("Waking the chamber camera — the first frame can take a few seconds.")
                    .font(.system(size: 12.5))
                    .lineSpacing(3)
                    .foregroundStyle(Chrome.faint)
                    .multilineTextAlignment(.center)
                    .padding(.top, 10)
                errorLine(prefix: "RETRYING", color: Chrome.faint)
            }
        }
    }

    private var failureCopy: String {
        model.vm.kind == .offline
            ? "Printer is offline. The chamber camera needs the printer powered on and connected to Wi-Fi, then tap Retry."
            : "Couldn’t wake the chamber camera. \(cameraHint) Make sure the printer is powered on."
    }

    /// The renderer's typed error, verbatim. It is the one place a 401 (expired token) is
    /// distinguishable from "still warming up" — a distinction the old WebView could not make.
    @ViewBuilder
    private func errorLine(prefix: String, color: Color) -> some View {
        if let message = pip.lastError {
            Text("\(prefix) · \(message)")
                .font(.mono(10.5, weight: .regular))
                .foregroundStyle(color)
                .multilineTextAlignment(.center)
                .lineLimit(3)
                .padding(.top, 10)
        }
    }

    // MARK: - Top chrome

    private func topChrome(insets: EdgeInsets) -> some View {
        HStack(spacing: 11) {
            chip(landscape ? "iphone" : "display", size: 17) {
                withAnimation(Motion.standard(0.3)) { landscape.toggle() }
            }
            chip("chevron.down", size: 22, action: close)

            statusPill

            if pip.isPictureInPictureSupported {
                // The real PiP glyph. A generic "minimize" square gave no hint what it did.
                chip(pip.pipActive ? "pip.exit" : "pip.enter", size: 17) {
                    if pip.pipActive { pip.stopPiP() } else { pip.startPiP() }
                }
            }
            chip("arrow.clockwise", size: 18, action: retry)
        }
        .padding(.top, landscape ? 12 : insets.top + 10)
        .padding(.bottom, 16)
        // Rotated, the notch / Dynamic Island runs down what is now the left edge.
        .padding(.leading, (landscape ? insets.top : 0) + 16)
        .padding(.trailing, 16)
    }

    private var statusPill: some View {
        let vm = model.vm
        return HStack(spacing: 8) {
            RoundedRectangle(cornerRadius: 4, style: .continuous)
                .fill(vm.stateColor.resolve(c))
                .frame(width: 7, height: 7)
            Text(vm.stateLabel)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.white)
                .lineLimit(1)
            Spacer(minLength: 8)
            Text("\(vm.progressInt)% · L\(vm.layer)")
                .font(.mono(12))
                .foregroundStyle(Color.white.opacity(0.5))
                .lineLimit(1)
        }
        .padding(.horizontal, 13)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity)
        .background(
            RoundedRectangle(cornerRadius: 13, style: .continuous).fill(Chrome.pill)
        )
    }

    private func chip(_ symbol: String, size: CGFloat, action: @escaping () -> Void) -> some View {
        Tap(action: action) {
            Image(systemName: symbol)
                .font(.system(size: size, weight: .medium))
                .foregroundStyle(.white)
                .frame(width: 40, height: 40)
                .background(Circle().fill(Chrome.chip))
                .contentShape(Circle())
        }
    }

    // MARK: - Live badge

    private func liveBadge(insets: EdgeInsets) -> some View {
        HStack(spacing: 6) {
            Circle()
                .fill(c.running)
                .frame(width: 6, height: 6)
            Text("LIVE")
                .font(.system(size: 10, weight: .semibold))
                .tracking(0.5)
                .foregroundStyle(.white)
        }
        .padding(.horizontal, 11)
        .padding(.vertical, 7)
        .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(Chrome.pill))
        .padding(.horizontal, 18)
        .padding(.bottom, insets.bottom + 24)
    }

    // MARK: - Diagnostics

    /// Drawn INSIDE the rotated surface rather than presented as a sheet, so it turns with the
    /// video in landscape instead of appearing sideways.
    private var diagnosticsPanel: some View {
        ZStack {
            Color.black.opacity(0.55)
                .contentShape(Rectangle())
                .onTapGesture { showDiagnostics = false }

            VStack(alignment: .leading, spacing: 0) {
                Text("Camera diagnostics")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(.white)

                ScrollView {
                    VStack(alignment: .leading, spacing: 10) {
                        diagRow("Frames decoded", "\(pip.frameCount)")
                        Text("Zero frames means nothing ever arrived over the wire. A rising count on a black screen means the transport is fine and the decode or display path is not — the two look identical from the outside.")
                            .font(.system(size: 11))
                            .lineSpacing(2)
                            .foregroundStyle(Chrome.muted)
                        diagRow("Stream", phaseLabel)
                        diagRow("Last error", pip.lastError ?? "none")
                        diagRow("Picture in Picture", pipLabel)
                        diagRow("Keep-alive audio", pip.audioKeepAliveOK ? "armed" : "not armed — PiP will freeze when backgrounded")

                        Rectangle().fill(Chrome.hairline).frame(height: 1).padding(.vertical, 2)

                        Text("SERVER PROBE")
                            .font(.mono(10, weight: .regular))
                            .tracking(1.5)
                            .foregroundStyle(Chrome.faint)

                        if diagnosing {
                            HStack(spacing: 8) {
                                ProgressView().progressViewStyle(.circular).tint(Chrome.muted)
                                Text("Probing…").font(.system(size: 12)).foregroundStyle(Chrome.muted)
                            }
                        }
                        if let diagnosisError {
                            Text(diagnosisError)
                                .font(.system(size: 12))
                                .foregroundStyle(c.error)
                        }
                        if let d = diagnosis {
                            diagRow("Protocol", d.proto ?? "—")
                            diagRow("Port", d.port.map(String.init) ?? "—")
                            diagRow("Overall", d.overallStatus ?? "—")
                            diagRow("Summary", d.summaryCode ?? "—")
                            ForEach(Array((d.stages ?? []).enumerated()), id: \.offset) { _, stage in
                                diagRow(stage.name, [stage.status, stage.code].compactMap { $0 }.joined(separator: " · "))
                            }
                        }

                        // Hard-won: this probe pokes port 6000 and reports the A1's camera
                        // unreachable while the live stream is working fine. Believe the frame
                        // counter above it, not this verdict.
                        Text("The port-6000 probe is a known false negative on the A1 — it can call the camera unreachable while frames are flowing.")
                            .font(.system(size: 11))
                            .lineSpacing(2)
                            .foregroundStyle(Chrome.faint)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: 300)
                .padding(.top, 14)

                HStack(spacing: 10) {
                    Tap(action: retry) {
                        Text("Retry stream")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 16)
                            .frame(height: 38)
                            .background(
                                RoundedRectangle(cornerRadius: 11, style: .continuous)
                                    .fill(Color.white.opacity(0.08))
                            )
                    }
                    Spacer(minLength: 0)
                    Tap { showDiagnostics = false } content: {
                        Text("Close")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(Chrome.label)
                            .padding(.horizontal, 16)
                            .frame(height: 38)
                            .contentShape(Rectangle())
                    }
                }
                .padding(.top, 14)
            }
            .padding(18)
            .frame(maxWidth: 420)
            .background(
                RoundedRectangle(cornerRadius: 18, style: .continuous).fill(Chrome.panel)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 18, style: .continuous).stroke(Chrome.hairline)
            )
            .padding(20)
        }
    }

    private func diagRow(_ label: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text(label)
                .font(.system(size: 12))
                .foregroundStyle(Chrome.muted)
                .frame(width: 118, alignment: .leading)
            Text(value)
                .font(.mono(12, weight: .regular))
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var phaseLabel: String {
        switch phase {
        case .connecting: "warming up"
        case .live: "live"
        case .failed: "failed"
        }
    }

    private var pipLabel: String {
        guard pip.isPictureInPictureSupported else { return "unsupported on this device" }
        return pip.pipActive ? "active" : "supported"
    }

    // MARK: - Actions

    private func close() {
        // Dismissing tears down the hosting view, and with it the display layer that the floating
        // window renders from. Shut PiP down deliberately rather than leaving a frozen window behind.
        if pip.pipActive { pip.stopPiP() }
        dismiss()
    }

    /// Bumping `reloadKey` re-arms the probe and the deadline immediately, so a retry that yields the
    /// same token still gives visible feedback. It is deliberately NOT part of the video view's
    /// identity — only a genuinely new URL restarts the stream, so one retry costs one warm-up.
    private func retry() {
        pip.lastError = nil
        reloadKey += 1
        guard let client = model.client else { return }
        let id = model.printerId
        Task {
            if let fresh = try? await client.mintCameraToken() { localToken = fresh }
            _ = id
        }
    }

    private func runDiagnostics() {
        guard let client = model.client, !diagnosing else { return }
        showDiagnostics = true
        diagnosing = true
        diagnosisError = nil
        let id = model.printerId
        Task {
            do {
                diagnosis = try await client.diagnoseCamera(id)
            } catch let e as BambuddyError {
                diagnosisError = e.detail
            } catch {
                diagnosisError = error.localizedDescription
            }
            diagnosing = false
        }
    }

    /// Fast-fail probe. A camera whose liveview is switched off rejects the SNAPSHOT endpoint
    /// deterministically (HTTP 503 in ~60 ms) while its `/stream` answers 200 with a multipart body
    /// whose only part is a text/plain error — no frame ever decodes, so without this the overlay
    /// would sit on "waking…" for the entire warm-up deadline.
    ///
    /// Only a clean HTTP error short-circuits: a probe NETWORK failure proves nothing about the
    /// stream path and is ignored.
    private func probeSnapshot() async {
        guard let url = snapshotUrl else { return }
        do {
            // Headers are all this needs; dropping the byte stream cancels the transfer before the
            // JPEG body is pulled down.
            let (_, response) = try await URLSession.shared.bytes(for: URLRequest(url: url))
            guard !Task.isCancelled, let http = response as? HTTPURLResponse else { return }
            if http.statusCode >= 400, phase != .live { phase = .failed }
        } catch {
            // Intentionally ignored — see the doc comment.
        }
    }
}
