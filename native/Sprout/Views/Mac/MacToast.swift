#if os(macOS)
import SwiftUI

/// Transient failure message, the Mac counterpart to `Shell`'s `ToastBanner`.
///
/// This is not decoration. `AppModel.perform` is how every printer command reports failure — Pause,
/// Resume, Stop, Light, speed, Print again — and it reports by writing `model.toast`. `ToastBanner`
/// lives in `Shell.swift`, which is iOS-only, so until this existed the Mac build **swallowed every
/// one of them**: the button clicked, the server refused, and nothing whatsoever appeared. A control
/// that looks live and silently does nothing is the exact failure CLAUDE.md's recurring-bug section
/// is about, and it would have been in the app's most consequential controls.
///
/// `MacFileImport` and the Explore import path write here too.
struct MacToast: View {
    let toast: Toast
    let onDismiss: () -> Void

    private var text: String { toast.text }

    /// The glyph and its colour come from the toast's OWN kind, never from reading the copy.
    ///
    /// Every message used to get `exclamationmark.triangle.fill` in `c.heating`, which put a warning
    /// over "planter.3mf added to your library" and over "Queued — the job is back in the queue".
    /// Both are successes, and both went through here.
    private var symbol: String {
        switch toast.kind {
        case .failure: "exclamationmark.triangle.fill"
        case .success: "checkmark.circle.fill"
        }
    }

    @Environment(\.palette) private var c
    @Environment(\.metrics) private var m

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: symbol)
                .scaledFont(13)
                .foregroundStyle(toast.kind == .success ? c.running : c.heating)
            Text(text)
                .font(.system(size: m.body, weight: .medium))
                .foregroundStyle(c.t1)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 8)
            Button {
                onDismiss()
            } label: {
                Image(systemName: "xmark")
                    .scaledFont(10, weight: .bold)
                    .foregroundStyle(c.t3)
            }
            .buttonStyle(.plain)
            // An explicit dismiss control, unlike iOS where tapping the banner clears it. A click
            // that lands anywhere on a floating panel is not discoverable on a pointer platform,
            // and the banner sits over content the user may well want to click instead.
            .accessibilityLabel("Dismiss")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
        .frame(maxWidth: 460, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: m.cardRadius, style: .continuous).fill(c.s3))
        .overlay(RoundedRectangle(cornerRadius: m.cardRadius, style: .continuous).stroke(c.line2))
        .shadow(color: .black.opacity(0.35), radius: 12, y: 4)
        .padding(.bottom, 22)
        .transition(.move(edge: .bottom).combined(with: .opacity))
        // Keyed on the message, exactly as the iOS banner is: replacing `model.toast` with a
        // different string keeps this view at the same structural position, so an un-keyed `.task`
        // would not restart and the new message would run out whatever was left of the previous
        // one's five seconds.
        .task(id: text) {
            try? await Task.sleep(for: .seconds(5))
            guard !Task.isCancelled else { return }
            onDismiss()
        }
    }
}
#endif
