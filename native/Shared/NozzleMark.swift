import SwiftUI

/// The printhead alone — no bed plate — with a molten bead in the tint.
///
/// **Not `TabNozzle`, and the difference is the bug it fixes.** The tab asset is FIVE shapes in a
/// `48 30 96 142` viewBox, and the fifth is `rect x=58 y=150 w=76 h=15`: the bed plate the head sits
/// above. Riding the progress bar with that asset put the artwork's own plate line directly on top of
/// the bar's line — two horizontal bars a point apart, the glyph reading as sunk into the track.
///
/// The design crops it: `48 30 96 128`, four shapes, plate gone. Which is right, because on the bar
/// the FILL is the bed — the head is depositing onto it, so carrying a second one is both a collision
/// and a lie about what is underneath.
///
/// The bead takes the tint while the body stays grey. That is the whole reason this is a drawn shape
/// and not the App Group PNG: a file URI is one flat image, and a two-tone mark needs two fills.
struct NozzleMark: View {
    /// The head and the cone. Named `shell`, not `body`: a `body` property on a `View` collides with
    /// the protocol requirement — the trap CLAUDE.md names first.
    var shell: Color = Color(red: 0.761, green: 0.780, blue: 0.800)      // #C2C7CC
    /// The collar, a shade down so the cone reads as a separate part at 15 pt.
    var collar: Color = Color(red: 0.529, green: 0.553, blue: 0.580)    // #878D94
    /// The molten bead. The one part that says which state the machine is in.
    var bead: Color

    /// The design's crop. `142` in the tab asset, `128` here — the difference IS the plate.
    private static let viewBox = CGRect(x: 48, y: 30, width: 96, height: 128)

    var body: some View {
        Canvas { ctx, size in
            let scale = min(size.width / Self.viewBox.width, size.height / Self.viewBox.height)
            ctx.scaleBy(x: scale, y: scale)
            ctx.translateBy(x: -Self.viewBox.minX, y: -Self.viewBox.minY)

            ctx.fill(Path(roundedRect: CGRect(x: 60, y: 36, width: 72, height: 50), cornerRadius: 12),
                     with: .color(shell))
            ctx.fill(Path(roundedRect: CGRect(x: 60, y: 80, width: 72, height: 9), cornerRadius: 4.5),
                     with: .color(collar))

            var cone = Path()
            cone.move(to: CGPoint(x: 74, y: 92))
            cone.addLine(to: CGPoint(x: 118, y: 92))
            cone.addLine(to: CGPoint(x: 106, y: 128))
            cone.addLine(to: CGPoint(x: 96, y: 150))
            cone.addLine(to: CGPoint(x: 86, y: 128))
            cone.closeSubpath()
            ctx.fill(cone, with: .color(shell))

            // cy 117, not the tab asset's 120 — the bead sits slightly higher once the plate is gone.
            ctx.fill(Path(ellipseIn: CGRect(x: 85, y: 106, width: 22, height: 22)), with: .color(bead))
        }
        .accessibilityHidden(true)
    }
}

/// The single-colour variant, for slots that tint the whole mark rather than just the bead — the
/// compact and minimal Dynamic Island, where the design says the tint carries the entire message.
struct TintedNozzle: View {
    var tint: Color
    var size: CGFloat

    var body: some View {
        NozzleMark(shell: tint, collar: tint, bead: tint)
            .frame(width: size * (96.0 / 128.0), height: size)
    }
}
