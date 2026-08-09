import SwiftUI

/// A filament colour swatch that stays visible whatever the colour is.
///
/// Every site used to paint the raw hex straight into a background, and most dropped the border as
/// soon as a colour was present. So a white spool on a white card was a hole in the layout — the
/// reported bug — and a black spool on a dark card was the same bug in the other theme. The sites
/// that DID keep a hairline were no better: `line2` is ~1.4:1 against its own surface.
///
/// The ring exists to separate the swatch from the CARD, so it is a fixed per-theme colour chosen
/// for contrast against the surfaces (>= 3:1 on every one), not something computed from the fill.
/// That is a proof rather than a sampled result: it holds for colours nobody has tested.
///
/// Three distinct states, deliberately not collapsed into two:
/// - `empty`   — no spool in the slot: transparent fill, DASHED ring
/// - `unknown` — a spool whose colour we do not know: dashed ring + a "?" glyph, never black
/// - `colour`  — the fill, with a solid ring
struct Swatch<Ink: View>: View {
    /// `#RRGGBB`, or nil when the colour is unknown. Pass through `FilamentColor.norm` first.
    var value: String?
    var size: CGFloat
    var radius: CGFloat
    /// True when the slot holds nothing at all — distinct from "colour unknown".
    var empty: Bool = false
    /// Optional glyph drawn on top of the fill (the nozzle chip's chevron).
    @ViewBuilder var ink: () -> Ink

    @Environment(\.palette) private var c

    private var known: Bool { !empty && value != nil }

    var body: some View {
        RoundedRectangle(cornerRadius: radius, style: .continuous)
            .fill(known ? (FilamentColor.swiftUI(value) ?? .clear) : .clear)
            .overlay {
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    // Dashed reads as "nothing here" for both empty and unknown; solid means "this
                    // is the colour".
                    .strokeBorder(
                        c.swatchRing,
                        style: StrokeStyle(lineWidth: 1, dash: known ? [] : [3, 2.5])
                    )
            }
            .overlay {
                if known {
                    ink()
                } else if !empty, size >= 16 {
                    Image(systemName: "questionmark.circle")
                        .font(.system(size: (size * 0.5).rounded()))
                        .foregroundStyle(c.t3)
                }
            }
            .frame(width: size, height: size)
    }
}

extension Swatch where Ink == EmptyView {
    init(value: String?, size: CGFloat, radius: CGFloat, empty: Bool = false) {
        self.init(value: value, size: size, radius: radius, empty: empty) { EmptyView() }
    }
}
