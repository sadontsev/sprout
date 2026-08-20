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
    static func rides(tintHex: String, finished: Bool) -> Bool {
        // `finished` is not decoration. The tint alone CANNOT answer this: `LAState.complete.tintHex`
        // is `LAColors.running`, the same green as printing, and Trellis sends that same hex for
        // FINISH/FINISHED/FINISHING. So a tint-only predicate answers "is this a green state?" — and
        // it parked the nozzle at the end of a full bar on a completed print, telling the user the
        // machine was still laying plastic onto a finished plate.
        //
        // The exact nearby-question shape CLAUDE.md's table is made of, written into the comment that
        // claimed to have avoided it: "complete is excluded — the bar is full, nothing is moving".
        // It was not excluded. `finished` is a `ContentState` field both the app and Trellis already
        // populate, and it is the capability rather than a proxy for it.
        guard !finished else { return false }
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
    /// Space reserved ABOVE the bar. The mock's `margin-top: 11px`; the glyph is absolutely
    /// positioned there and is allowed to overflow it slightly, which is why this is a reservation
    /// rather than `glyphSize.height`. Design gives 11 on the lock screen and expanded island, 20 in
    /// StandBy, 10 in the Mac panel.
    var headroom: CGFloat = 11
    @ViewBuilder var rider: () -> Rider

    /// How far the tip sinks into the bar — the mock's `bottom: 1px`.
    private static var tipInset: CGFloat { 1 }

    /// Total height the view claims, bar plus the headroom the glyph needs.
    ///
    /// **Computed, not padded.** This was `.frame(height: barHeight)` followed by
    /// `.padding(.top, glyph - bar)`, which reported one height and drew at another: the counters
    /// underneath were laid out against the bar alone and rendered straight on top of it, and the
    /// track filled the padded box so a 5 pt bar came out about 15 pt tall.
    private var totalHeight: CGFloat {
        riding ? barHeight + headroom : barHeight
    }

    var body: some View {
        GeometryReader { geo in
            let width = geo.size.width
            let fill = width * CGFloat(min(max(progress.isFinite ? progress : 0, 0), 1))
            // Bottom-aligned: the bar sits on the baseline and the glyph rises out of it, so the
            // headroom is above the bar where the design puts it.
            ZStack(alignment: .bottomLeading) {
                Capsule()
                    .fill(Color.white.opacity(0.22))
                    .frame(height: barHeight)
                Capsule()
                    .fill(tint)
                    .frame(width: fill, height: barHeight)
                    // The glow the design asks for. A shadow rather than a blurred duplicate: one
                    // layer, and it tracks the fill's shape for free.
                    .shadow(color: tint.opacity(0.5), radius: 4)

                if riding {
                    rider()
                        .frame(width: glyphSize.width, height: glyphSize.height)
                        .shadow(color: .black.opacity(0.55), radius: 3, x: 0, y: 2)
                        .offset(
                            x: ExtrusionRider.centreX(progress: progress,
                                                      width: width,
                                                      glyphWidth: glyphSize.width) - glyphSize.width / 2,
                            // Tip one point above the bar's BOTTOM, so the cone ends inside the fill
                            // it is laying down rather than floating over it.
                            y: -(barHeight - Self.tipInset)
                        )
                }
            }
            .frame(width: width, height: geo.size.height, alignment: .bottomLeading)
        }
        .frame(height: totalHeight)
    }
}
