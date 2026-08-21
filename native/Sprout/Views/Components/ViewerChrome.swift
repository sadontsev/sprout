import SwiftUI

// Chrome shared by the two viewer pages, on both platforms.
//
// Plain SwiftUI with no platform API in it, so it belongs beside the other shared components rather
// than inside `StlViewerOverlay.swift`, which is `#if os(iOS)`. The macOS viewer window (1g) shows
// the same loading and failure states over the same pages; only the window around them differs.
//
// `Palette.dark` statically rather than `@Environment(\.palette)` on purpose: both viewer pages are
// always dark, whatever the app's theme, because they render a plate against a dark ground.

/// Dark chrome for both viewers.
///
/// These are dark-palette literals on purpose: the page underneath is a fixed dark surface that the
/// app's light theme cannot reach, so light-mode chrome would be invisible on top of it.
enum ViewerChrome {
    static let pill = Palette.dark.sheet
    static let ink = Color.white
    static let dim = Palette.dark.t3
    // 0x3A4046 measured 1.88:1 on the viewer background — effectively invisible, and it
    // is the only feedback during a multi-second G-code parse.
    static let glyph = Color(hex: 0x747A80)
    static let offDot = Color(hex: 0x4F555B)
    static let offInk = Color(hex: 0x9AA0A6)
}

/// Close pill + title pill + an optional trailing pill, floated over a viewer page.
struct ViewerTopBar<Trailing: View>: View {
    let title: String
    let onClose: () -> Void
    private let trailing: () -> Trailing

    init(title: String, onClose: @escaping () -> Void, @ViewBuilder trailing: @escaping () -> Trailing) {
        self.title = title
        self.onClose = onClose
        self.trailing = trailing
    }

    var body: some View {
        HStack(spacing: 11) {
            Tap(action: onClose) {
                // `xmark`, not `chevron.down` — this DISMISSES a fullscreen viewer, which is what
                // Photos puts an x on. A chevron says "collapse downwards", a different promise.
                // The translucent circle around it is drawn below, so the glyph is bare rather
                // than `xmark.circle.fill`.
                Image(systemName: "xmark")
                    .scaledFont(17, weight: .semibold)
                    .foregroundStyle(ViewerChrome.ink)
                    .frame(width: 40, height: 40)
                    .background(Circle().fill(ViewerChrome.pill.opacity(0.6)))
            }

            Text(title)
                .scaledFont(13, weight: .semibold)
                .foregroundStyle(ViewerChrome.ink)
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 13)
                .padding(.vertical, 10)
                .background(RoundedRectangle(cornerRadius: 13, style: .continuous).fill(ViewerChrome.pill.opacity(0.55)))

            trailing()
        }
        .padding(.horizontal, 16)
        .padding(.top, 10)
    }
}

extension ViewerTopBar where Trailing == EmptyView {
    init(title: String, onClose: @escaping () -> Void) {
        self.init(title: title, onClose: onClose, trailing: { EmptyView() })
    }
}

/// Opaque full-bleed placeholder shown while a page downloads and parses.
///
/// Opaque because both pages carry their own in-page "Loading…" text; a translucent cover would
/// show two loading labels at once.
struct ViewerLoading: View {
    let label: String
    var compact = false

    var body: some View {
        VStack(spacing: compact ? 10 : 14) {
            ProgressView().tint(Palette.dark.accent)
            Text(label)
                .font(.mono(compact ? 10 : 11, weight: .semibold))
                .tracking(2)
                .foregroundStyle(ViewerChrome.glyph)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Palette.dark.bg)
    }
}

/// Terminal failure: the page is torn down (freeing whatever it had parsed) and its message shown.
struct ViewerFailure: View {
    let icon: String
    let message: String
    var compact = false
    var onRetry: (() -> Void)?

    var body: some View {
        VStack(spacing: 0) {
            Image(systemName: icon)
                .font(.system(size: compact ? 22 : 30, weight: .regular))
                .foregroundStyle(ViewerChrome.glyph)
            Text(message)
                .font(.system(size: compact ? 12 : 14, weight: .regular))
                .foregroundStyle(ViewerChrome.dim)
                .multilineTextAlignment(.center)
                .lineSpacing(compact ? 4 : 6)
                .padding(.top, compact ? 10 : 14)

            if let onRetry {
                Tap(action: onRetry) {
                    Text("Retry")
                        .scaledFont(13, weight: .semibold)
                        .foregroundStyle(Palette.dark.accent)
                        .padding(.horizontal, 18)
                        .padding(.vertical, 10)
                        .background(Capsule().fill(Palette.dark.accentDim))
                }
                .padding(.top, 18)
            }
        }
        .padding(.horizontal, compact ? 24 : 36)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Palette.dark.bg)
    }
}
