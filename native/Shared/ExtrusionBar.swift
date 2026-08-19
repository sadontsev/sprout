import SwiftUI

/// Where the nozzle sits on the progress bar, and whether it should be there at all.
///
/// Pure, because both halves are rules that are easy to get subtly wrong and impossible to notice
/// afterwards: the card renders on a lock screen, out of process, and nobody is looking at it during
/// the two seconds it is wrong.
enum ExtrusionRider {

    /// Centre of the nozzle glyph, in points from the bar's leading edge.
    ///
    /// **Clamped to half a glyph in from each end.** Unclamped, a 3 % print puts the glyph's centre
    /// 3 % along and most of the nozzle hangs off the rounded cap into nothing — which is exactly
    /// what the design file's 3 % heating card shows. At 100 % it does the same on the right.
    ///
    /// Progress outside 0…1 is clamped rather than trusted: it comes off the wire from Trellis.
    static func centreX(progress: Double, width: CGFloat, glyphWidth: CGFloat) -> CGFloat {
        guard width > 0 else { return 0 }
        let p = min(max(progress.isFinite ? progress : 0, 0), 1)
        let raw = width * CGFloat(p)
        // A glyph wider than the bar cannot satisfy both bounds; centre it rather than let the
        // lower bound win and pin it left.
        guard glyphWidth < width else { return width / 2 }
        return min(max(raw, glyphWidth / 2), width - glyphWidth / 2)
    }

    /// Whether the nozzle rides this bar at all.
    ///
    /// **Only while something is actually being extruded.** A parked nozzle drawn mid-bar on a paused
    /// or failed print says the machine is still laying plastic, which is a lie told by a decoration
    /// — and the states where it would lie are exactly the states someone is anxiously checking.
    /// `complete` is excluded for the same reason: the bar is full, nothing is moving.
    ///
    /// Keyed on the tint rather than on `stateLabel`, because the label is free-form server text
    /// (Trellis writes it, and it is localised for humans) while the tint is a fixed enumeration both
    /// sides agree on. A predicate on prose would drift the first time the server reworded a state.
    static func rides(tintHex: String) -> Bool {
        let hex = tintHex.uppercased()
        return hex == LAColors.running.uppercased() || hex == LAColors.heating.uppercased()
    }
}

/// A progress bar with the nozzle riding its leading edge.
///
/// Carried over from the Expo prototype, where it was the one piece of the print card people
/// recognised at a glance: the bar says how far, and the nozzle says *the machine is doing this right
/// now*, which a static bar cannot.
///
/// The caller supplies the glyph, because the widget loads it from the App Group as a `UIImage` while
/// the Mac draws it from the asset catalog — one view, two image sources, no `#if` inside the layout.
struct ExtrusionBar<Rider: View>: View {
    let progress: Double
    let tint: Color
    /// Whether the nozzle is drawn. See `ExtrusionRider.rides`.
    var riding: Bool = true
    var barHeight: CGFloat = 5
    var glyphSize: CGSize = CGSize(width: 15, height: 20)
    @ViewBuilder var rider: () -> Rider

    var body: some View {
        GeometryReader { geo in
            let width = geo.size.width
            let fill = width * CGFloat(min(max(progress.isFinite ? progress : 0, 0), 1))
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(Color.white.opacity(0.22))
                Capsule()
                    .fill(tint)
                    .frame(width: fill)
                    // The glow the design asks for. A shadow rather than a blurred duplicate: one
                    // layer, and it tracks the fill's shape for free.
                    .shadow(color: tint.opacity(0.5), radius: 4)

                if riding {
                    rider()
                        .frame(width: glyphSize.width, height: glyphSize.height)
                        .shadow(color: .black.opacity(0.55), radius: 3, x: 0, y: 2)
                        // Tip touching the bar's TOP, so the glyph reads as depositing onto the fill
                        // rather than floating above it or being impaled by it.
                        .offset(
                            x: ExtrusionRider.centreX(progress: progress,
                                                      width: width,
                                                      glyphWidth: glyphSize.width) - glyphSize.width / 2,
                            y: -glyphSize.height / 2 - barHeight / 2 + 1
                        )
                }
            }
        }
        .frame(height: barHeight)
        // The glyph is drawn ABOVE the bar and a `GeometryReader` clips to its own bounds, so the
        // headroom has to be reserved by the caller's layout — the design specifies it per surface
        // (11 pt on the lock card, 20 in StandBy, 10 in the Mac panel). Stated here because a missing
        // pad shows up as a decapitated nozzle, which reads as a rendering bug rather than a spacing
        // one.
        .padding(.top, riding ? glyphSize.height - barHeight : 0)
    }
}

extension ExtrusionBar where Rider == EmptyView {
    /// The plain bar, for the states that do not extrude.
    init(progress: Double, tint: Color, barHeight: CGFloat = 5) {
        self.init(progress: progress, tint: tint, riding: false, barHeight: barHeight) { EmptyView() }
    }
}
