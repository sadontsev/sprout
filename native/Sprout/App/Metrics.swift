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
