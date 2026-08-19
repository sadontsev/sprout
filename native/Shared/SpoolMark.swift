import SwiftUI

/// The drying mark: a filament spool with heat rising off it.
///
/// **It replaces a droplet, and the reason is not taste.** `humidity.fill` and every droplet glyph
/// read as *water* — which is the opposite of what a dryer does. A user glancing at an amber droplet
/// on a lock screen has been told the machine is wet. The spool says what is actually being acted on,
/// and the rising strokes say heat is being applied to it.
///
/// Drawn rather than shipped as an asset because it is needed at wildly different sizes and in three
/// rendering contexts — a SwiftUI card, a tinted widget slot, and an AppKit template image for the
/// menu bar. One `Shape` serves all of them, and the stroke weight is a function of the size rather
/// than a fixed value scaled up (see `strokeWidth`).
///
/// Geometry is specified on a 24×24 grid and scaled to whatever size it is asked for, so the
/// proportions hold from 14 pt to 200 pt.
struct SpoolMark: Shape {

    /// The grid the geometry below is written against.
    static let grid: CGFloat = 24

    // The spool body.
    private static let ringCentre = CGPoint(x: 12, y: 15.2)
    private static let ringRadius: CGFloat = 6.3
    private static let hubRadius: CGFloat = 1.9

    /// Heat, rising. Three strokes of different lengths — equal ones read as a barcode.
    private static let heat: [(x: CGFloat, from: CGFloat, to: CGFloat)] = [
        (8.3, 6.1, 3.5),
        (12.0, 5.1, 2.1),
        (15.7, 6.1, 3.5),
    ]

    /// How heavy the line should be at a given rendered size.
    ///
    /// **Heavier as it gets smaller**, which is the opposite of scaling. A 1.8 pt stroke scaled down
    /// with the artwork lands under a point at 14 pt and the ring disappears into the background;
    /// the mark has to survive to 14 pt because that is the Mac menu bar. The steps are the sizes the
    /// design calls out — ≥34 pt on a card, 17–21 pt in a row, ≤14 pt in the bar.
    ///
    /// Returned in GRID units, so the caller scales it with everything else.
    static func strokeWidth(forSize size: CGFloat) -> CGFloat {
        if size >= 34 { return 1.8 }
        if size >= 17 { return 2.1 }
        return 2.3
    }

    func path(in rect: CGRect) -> Path {
        // Uniform scale on the smaller edge, so a non-square rect centres rather than distorts — a
        // stretched spool reads as a different object.
        let side = min(rect.width, rect.height)
        let k = side / Self.grid
        let originX = rect.minX + (rect.width - side) / 2
        let originY = rect.minY + (rect.height - side) / 2
        func p(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
            CGPoint(x: originX + x * k, y: originY + y * k)
        }

        var path = Path()

        // The ring. Stroked by the caller, not filled — `SpoolMark` is a stroke shape.
        path.addEllipse(in: CGRect(
            x: p(Self.ringCentre.x - Self.ringRadius, 0).x,
            y: p(0, Self.ringCentre.y - Self.ringRadius).y,
            width: Self.ringRadius * 2 * k,
            height: Self.ringRadius * 2 * k
        ))

        for stroke in Self.heat {
            path.move(to: p(stroke.x, stroke.from))
            path.addLine(to: p(stroke.x, stroke.to))
        }

        return path
    }
}

/// The hub, which is FILLED while the rest of the mark is stroked.
///
/// A separate shape because one `Path` cannot be both, and faking a filled dot with a very heavy
/// stroked circle blurs at small sizes — at 14 pt it turns into a smudge rather than a centre.
struct SpoolMarkHub: Shape {
    func path(in rect: CGRect) -> Path {
        let side = min(rect.width, rect.height)
        let k = side / SpoolMark.grid
        let originX = rect.minX + (rect.width - side) / 2
        let originY = rect.minY + (rect.height - side) / 2
        let r: CGFloat = 1.9
        return Path(ellipseIn: CGRect(
            x: originX + (12 - r) * k,
            y: originY + (15.2 - r) * k,
            width: r * 2 * k,
            height: r * 2 * k
        ))
    }
}

/// The mark, assembled and ready to place. `size` drives both the frame and the stroke weight, so a
/// caller cannot accidentally scale one without the other.
struct SpoolGlyph: View {
    let size: CGFloat
    var tint: Color = .primary

    var body: some View {
        let weight = SpoolMark.strokeWidth(forSize: size) * (size / SpoolMark.grid)
        ZStack {
            SpoolMark()
                .stroke(tint, style: StrokeStyle(lineWidth: weight, lineCap: .round, lineJoin: .round))
            SpoolMarkHub().fill(tint)
        }
        .frame(width: size, height: size)
        // The mark IS the meaning here — "drying" is not otherwise written on the small surfaces.
        .accessibilityLabel("Drying")
    }
}
