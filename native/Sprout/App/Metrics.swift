import SwiftUI

/// Density tokens — §8 of the Mac handoff.
///
/// The counterpart to `Palette`, and deliberately the *only* thing that differs between the two
/// platforms at token level. **Palette hex values do not change**: dark and light ship as-is on
/// macOS, because a colour that reads correctly on a phone reads correctly on a display. What does
/// not carry over is size. A 44 pt row and 15 pt body text are sized for a thumb at arm's length;
/// on a Mac they read as a phone app that has been stretched, which §Density lists under "not
/// taken".
///
/// Read through `@Environment(\.metrics)` rather than referenced statically, so a SwiftUI preview
/// can render either density and so the value is substitutable in a test.
struct Metrics: Sendable, Equatable {
    /// Running text.
    let body: CGFloat
    /// The screen's own title. On macOS the title lives in the toolbar, which is why it drops so far.
    let screenTitle: CGFloat
    /// A card's heading.
    let cardTitle: CGFloat
    /// The small tracked monospace labels — `UP NEXT`, `NOZZLE`, `BAMBUDDY`.
    let monoLabel: CGFloat
    /// The one big number on a screen: the percentage, the watts.
    let heroMetric: CGFloat

    /// The anchor of the corner-radius scale — cards, panels, sheets, media tiles.
    ///
    /// See `controlRadius`/`chipRadius` below: this is the only radius that is stored, and the
    /// other two are derived from it, so the three can never drift apart.
    let cardRadius: CGFloat
    let cardPadding: CGFloat
    /// A row in a list or table.
    let rowHeight: CGFloat
    /// Distance from the content's edge to the window or screen edge.
    let gutter: CGFloat
    /// Between sibling cards.
    let cardGap: CGFloat

    /// Standard control height. `primaryControlHeight` stays taller on macOS on purpose: at the
    /// same 28 pt as everything else, the one button that commits an action stops looking like the
    /// primary action.
    let controlHeight: CGFloat
    let primaryControlHeight: CGFloat
    /// Nothing tappable/clickable goes below this.
    let minControlHeight: CGFloat

    /// True on the Mac density. Used only where a layout genuinely has no iOS counterpart — never
    /// as a substitute for putting the number in this struct.
    let isMac: Bool

    static let iOS = Metrics(
        body: 15,
        screenTitle: 30,
        cardTitle: 17,
        monoLabel: 11,
        heroMetric: 36,
        cardRadius: 16,
        cardPadding: 16,
        rowHeight: 44,
        gutter: 20,
        cardGap: 12,
        controlHeight: 44,
        primaryControlHeight: 44,
        minControlHeight: 44,
        isMac: false
    )

    static let mac = Metrics(
        body: 13,
        screenTitle: 19,
        cardTitle: 13,
        monoLabel: 9.5,
        heroMetric: 27,
        cardRadius: 12,
        cardPadding: 14,
        rowHeight: 28,
        gutter: 24,
        // §8 gives a 10–14 range. 12 is the middle and matches the prototype's own card grid, which
        // uses 12 between grid cells and 14 between stacked sections; the wider one is `sectionGap`.
        cardGap: 12,
        controlHeight: 28,
        primaryControlHeight: 34,
        minControlHeight: 24,
        isMac: true
    )

    /// Between stacked sections of a screen, as opposed to between cards in a grid.
    var sectionGap: CGFloat { isMac ? 14 : 16 }

    // MARK: - The corner-radius scale
    //
    // THREE steps and no more. A 172 pt card and a 22 pt chip must not share a corner — at one
    // radius the chip looks like a pill that failed and the card looks like a phone widget — but a
    // dozen ad-hoc numbers between them is what the owner called "just ugly", and it is: a survey of
    // `Views/Mac/` before this existed found 2, 3, 4, 5, 6, 7, 8, 9, 10, 11 and 12 all in use, often
    // for the same *kind* of thing in two adjacent files.
    //
    // The relationship is stated rather than tuned: **control is ¾ of a card, chip is ½ of a card.**
    // Both land on integers at both densities (mac 12 → 9 → 6, iOS 16 → 12 → 8), and 9 was already
    // what `MacPrimaryButtonStyle` drew and what `MacExploreSection` had hand-rolled as a local
    // `controlRadius` with a comment asking for exactly this token.
    //
    // Everything that draws one of these uses `style: .continuous`. A `.circular` corner and a
    // `.continuous` corner at the same radius are visibly different shapes, so a mix of the two is
    // itself an inconsistency even when every number agrees — and `RoundedRectangle(cornerRadius:)`
    // defaults to `.circular`, which is how several of them got in.

    /// Buttons, text fields, segmented controls, search bars, pickers, menus — anything the user
    /// clicks that is not a card — **and** fixed-size media wells in the 28–64 pt band, which are
    /// too small to read as cards and too large to read as chips. ¾ of `cardRadius`.
    var controlRadius: CGFloat { cardRadius * 0.75 }

    /// Small tags, badges, outcome pills, type labels, list thumbnails up to about 24 pt — things
    /// roughly one line of text tall. ½ of `cardRadius`.
    ///
    /// Colour swatches are the deliberate exception; they take `swatchRadius` instead, for the
    /// reason given there.
    var chipRadius: CGFloat { cardRadius * 0.5 }

    /// Which step applies is decided by **what the element is**, and only then by how big it is:
    /// card → control → chip, with size breaking the tie for the non-interactive surfaces. Two
    /// shapes escape the scale entirely and both say so at the call site: a chart's data marks
    /// (`MacPowerInspector`'s sparkline bars, which are 2 pt tall at their floor) and anything whose
    /// honest shape is a `Capsule` — a progress track, a text-line skeleton. Reaching for a token
    /// there produces a worse result than naming the shape.

    /// The radius an inner shape needs to stay **concentric** with the outer shape it sits inside.
    ///
    /// Two nested rounded rectangles separated by padding do not look nested when they share a
    /// radius: the inner corner is visibly too round, because its arc has to turn the same amount in
    /// a smaller box. `inner = outer − inset` keeps the two arcs on a common centre. Floored at 0,
    /// which is the right answer for a deeply inset child — a square corner, not a negative one.
    static func concentric(inside outer: CGFloat, inset: CGFloat) -> CGFloat {
        max(0, outer - inset)
    }

    /// A colour swatch's corner, from its own edge length.
    ///
    /// Swatches are the one shape here whose radius cannot come from the three-step scale: they run
    /// from 11 pt in a table cell to 30 pt on a slot card, and a single `chipRadius` would turn the
    /// small one into a circle while leaving the large one looking square. The call sites had in
    /// fact already agreed on one ratio without it being written down anywhere — **every** hand-typed
    /// `Swatch(size:radius:)` pair in the app (11→3, 13→4, 14→4, 15→4, 18→5, 26→7, 30→8) is
    /// `size × 0.27` rounded. This states the rule those numbers were following, so the next swatch
    /// added does not have to be guessed at.
    static func swatchRadius(_ size: CGFloat) -> CGFloat { (size * 0.27).rounded() }

    /// The platform's own density. Views read `@Environment(\.metrics)`; this is what seeds it.
    static var current: Metrics {
        #if os(macOS)
        .mac
        #else
        .iOS
        #endif
    }
}

private struct MetricsKey: EnvironmentKey {
    static let defaultValue = Metrics.current
}

extension EnvironmentValues {
    var metrics: Metrics {
        get { self[MetricsKey.self] }
        set { self[MetricsKey.self] = newValue }
    }
}
