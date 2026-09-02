#if os(iOS)
// Compiled into TWO targets: the widget extension that ships it, and SproutTests, which renders
// these views to check their layout (a Live Activity never starts in the Simulator, so this is the
// only look available before a build reaches a phone). The extension compiles `Shared/` itself; the
// test target gets those types from the Sprout module instead, hence the conditional import.
#if SPROUT_TESTS
@testable import Sprout
#endif

import ActivityKit
import SwiftUI
import WidgetKit

/// The lock-screen card and Dynamic Island for a print (or an AMS drying cycle).
///
/// Everything here renders from the fixed `LAColors` hexes rather than the app's theme, because a
/// card pushed by the server has no idea what theme the phone is on and must look identical either
/// way.
struct PrintActivityWidget: Widget {
    /// Horizontal breathing room for content that sits near the expanded Dynamic Island's rounded
    /// corners.
    ///
    /// The system does not inset for the corner ARC, only for the bounds, so a glyph in the top or
    /// bottom row gets sliced by the curve while the middle of the same row is fine. Seen in the
    /// field as "Layer 379/590" rendering as "ayer 379/590" and a countdown losing its last digit.
    /// Applied to the text near the corners, never to the whole region — see the bottom region.
    static let cornerInset: CGFloat = 10

    var body: some WidgetConfiguration {
        ActivityConfiguration(for: PrintActivityAttributes.self) { context in
            LockScreenCard(state: context.state, printerId: context.attributes.printerId)
                // The card pins ONE dark background for both appearances, but its text uses adaptive
                // semantic styles (.primary/.secondary/.tertiary). In light appearance those resolve
                // to black — the 19pt finish time, the card's headline, rendered near-black on a
                // near-black card. live-activities.md:203: "If you use a custom background color,
                // choose a color that works well in both modes or a different color for each
                // appearance." The background is already committed to dark, so commit the scheme too
                // rather than auditing every foreground.
                .environment(\.colorScheme, .dark)
                .activityBackgroundTint(Color.black.opacity(0.55))
                .activitySystemActionForegroundColor(.white)
        } dynamicIsland: { context in
            let tint = Color(hexString: context.state.tint)
            return DynamicIsland {
                // `priority:` is the API's own way to settle the three regions' claim on one
                // width — `DynamicIslandExpandedRegion(_:priority:)`, default 0. The sides get 1 so
                // the centre's long file name yields to them instead of squeezing "Printing" into a
                // one-letter column and a countdown into three stacked fragments.
                //
                // NOT `.fixedSize()`, which was the previous attempt: it made the leading HStack
                // demand glyph + full label width, the region clipped the overflow at its leading
                // edge, and the nozzle came out cropped.
                DynamicIslandExpandedRegion(.leading, priority: 1) {
                    // The plate ALONE. The state label used to sit beside it, and at 44 pt there was
                    // no longer room for both — "Printing" came out as "Prin...", which is a worse
                    // reading of the same word. It moved to the centre region, above the file name,
                    // where it has the width to be a word.
                    HStack(spacing: 6) {
                        // ONE mark, not two. The preview and the glyph are rungs of the SAME ladder —
                        // the glyph is what the slot falls back to when there is no plate — so drawing
                        // both put two nozzles side by side on every job without a matched plate,
                        // which is most of them. The preview wins when there is one; otherwise the
                        // tinted mark stands in for it.
                        IslandLeading(state: context.state, tint: tint,
                                      printerId: context.attributes.printerId)
                    }
                }
                DynamicIslandExpandedRegion(.trailing, priority: 1) {
                    CountdownSlot(
                        countdown: context.state.countdown(),
                        font: .system(size: 12, weight: .medium).monospacedDigit(),
                        maxWidth: 64
                    )
                    .foregroundStyle(tint)
                    .padding(.trailing, Self.cornerInset)
                }
                DynamicIslandExpandedRegion(.center) {
                    // State above name, the same stack the lock-screen card uses — Apple asks the two
                    // presentations to share a layout (HIG, Live Activities → Lock Screen).
                    VStack(alignment: .leading, spacing: 1) {
                        Text(context.state.stateLabel)
                            .font(.system(size: 12, weight: .medium))
                            .lineLimit(1)
                            .foregroundStyle(tint)
                        Text(context.state.name)
                            .font(.caption2)
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .foregroundStyle(.secondary)
                    }
                    // NO `.frame(maxWidth: .infinity)`. A greedy child expands to fill whatever it
                    // is offered, which defeats the `priority: 1` the sides carry precisely so the
                    // centre yields to them: the leading tile was starved to a sliver of the glyph
                    // and the trailing countdown to "2.". `truncationMode(.middle)` already lets a
                    // long file name give up width gracefully; it does not need to claim all of it.
                    .frame(alignment: .leading)
                }
                DynamicIslandExpandedRegion(.bottom) {
                    if let rows = context.state.dryUnits, !rows.isEmpty {
                        DryUnitRows(rows: rows, tint: tint)
                            .padding(.horizontal, Self.cornerInset)
                    } else if context.state.dry == true {
                        // The same 10 pt inset the counters get. Without it TEMP/HUMIDITY sit where
                        // the corner arc slices — the "ayer 379/590" failure this file documents.
                        DryReadout(state: context.state, tint: tint)
                            .padding(.horizontal, Self.cornerInset)
                    } else {
                        IslandBottom(state: context.state, tint: tint)
                    }
                }
            } compactLeading: {
                // The BRAND mark, tinted — not `state.symbol`. The design is explicit that the
                // preview is "dropped entirely in the compact island where only a tinted glyph fits",
                // and that the glyph is the nozzle; an SF Symbol here made the app's own island slot
                // look like any other app's. A dry cycle gets the spool, because in minimal and
                // compact the silhouette plus the tint is the entire message and the two must not be
                // confusable.
                IslandProgressMark(state: context.state, tint: tint)
            } compactTrailing: {
                // Drying cards pin progress to 0, so a percentage says nothing about them — they get
                // the countdown instead. Resolved once so the visibility check and the text that
                // follows it read the same clock.
                let countdown = context.state.countdown()
                if context.state.dry == true, countdown != .hidden {
                    // The FINISH TIME, same as the print slot — not the ticking duration it used
                    // to be. A dry cycle runs four to twelve hours, and `12:08:32` wants 59pt of a
                    // 44pt slot: past ten hours it truncated to `12:08:…` even at the minimum
                    // scale, which `LiveActivityRenderTests` measures. A clock is five characters
                    // whatever the duration, stays correct without a push, and answers what a
                    // glance at this slot asks. `DryUnitRows` keeps the duration because it has
                    // the room; this slot does not.
                    CountdownSlot(
                        countdown: countdown,
                        font: .system(size: 13, weight: .semibold).monospacedDigit(),
                        maxWidth: 58,
                        compact: true,
                        style: .finishClock
                    )
                    .foregroundStyle(tint)
                } else if countdown != .hidden {
                    // The finish time, not the percentage. A number that only moves once every few
                    // minutes tells you nothing at a glance; "when will it be done" is the reason
                    // anyone looks at this slot at all. Progress is still on the expanded card.
                    CountdownSlot(
                        countdown: countdown,
                        font: .system(size: 13, weight: .semibold).monospacedDigit(),
                        maxWidth: 58,
                        compact: true,
                        style: .finishClock
                    )
                    .foregroundStyle(tint)
                } else {
                    Text("\(context.state.progress)%")
                        .font(.system(size: 13, weight: .semibold).monospacedDigit())
                        .foregroundStyle(tint)
                }
            } minimal: {
                IslandProgressMark(state: context.state, tint: tint)
            }
            .keylineTint(tint)
            // No contentMargins on the compact slots. live-activities.md:180 is explicit — "Keep
            // content as narrow as possible and ensure it's snug against the TrueDepth camera …
            // don't add padding between content and the TrueDepth camera." Sizing the ring to the
            // slot is the fix; padding it away from the cutout is the thing the guideline forbids.
        }
    }
}

/// The expanded island's preview. Same ladder as the card's; absent entirely when there is no
/// image, because an empty tile beside a 16 pt glyph is just clutter.
///
/// **44 pt, up from 30.** Touch-and-hold on the compact or minimal presentation is what produces
/// this view (HIG, Live Activities → Expanded), so it is the one people reach for deliberately —
/// and Apple's own size table gives the expanded presentation 84–160 pt of height against 371 pt of
/// width on a 393×852 phone. The old 30 pt tile spent a fraction of that on the one thing worth
/// enlarging. It stays square and stays in the leading region, which costs the centre 14 pt of the
/// file name's width; the name already truncates in the middle, and a legible model beats two more
/// characters of a name.
/// The expanded island's bottom region for a PRINT: bar, then one line of counters.
///
/// Extracted from the `DynamicIsland` builder so it can be rendered on its own — the island cannot
/// be photographed (a Live Activity does not start in the Simulator at all), so the only way to see
/// this layout before it ships is to render this view directly. `LiveActivityRenderTests` does that
/// at real island widths, which is how the temperatures were caught taking a whole extra line.
private struct IslandBottom: View {
    let state: PrintActivityAttributes.ContentState
    let tint: Color

    var body: some View {
        let temps = TempsRow(state: state, tint: tint)
        return VStack(spacing: 5) {
            ExtrusionBar(
                progress: Double(state.progress) / 100,
                tint: tint,
                riding: ExtrusionRider.rides(tintHex: state.tint, finished: state.finished)
            ) {
                NozzleMark(bead: tint)
            }
            if temps.hasAny {
                // One line when the readings fit, two when they do not — asked of the layout system
                // rather than decided here, because the answer depends on the numbers.
                //
                // The temperatures had a row of their own, which left the space between "Layer
                // 731/952" and "82%" — over half the island — empty while making the card a line
                // taller. Moving them onto that line fixes the ordinary case and breaks the worst
                // one: a dual-nozzle enclosed machine mid-heat wants 291pt of readings against
                // 206pt of free space, and every target truncated to "L 148° →…". Losing all four
                // targets is worse than spending a line, and the targets are the numbers that
                // answer "how long".
                //
                // `ViewThatFits` picks the first child whose IDEAL size fits the width it is
                // offered, so the one-line form is used exactly when it does not have to shrink.
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 8) {
                        counter("Layer \(state.layer)/\(state.totalLayers)")
                        Spacer(minLength: 4)
                        temps
                        Spacer(minLength: 4)
                        counter("\(state.progress)%")
                    }
                    // Stacked, and the temperatures share the LEFT margin with "Layer" rather
                    // than centring themselves under a row that is pinned to both edges.
                    VStack(alignment: .leading, spacing: 3) {
                        HStack {
                            counter("Layer \(state.layer)/\(state.totalLayers)")
                            Spacer()
                            counter("\(state.progress)%")
                        }
                        temps
                    }
                }
                // Only the TEXT is inset, not the bar. The bar is a rectangle whose ends read as
                // deliberate against the curve; a glyph half-eaten by it reads as a bug — "Layer"
                // was arriving as "ayer".
                .padding(.horizontal, PrintActivityWidget.cornerInset)
            } else {
                HStack {
                    counter("Layer \(state.layer)/\(state.totalLayers)")
                    Spacer()
                    counter("\(state.progress)%")
                }
                .padding(.horizontal, PrintActivityWidget.cornerInset)
            }
        }
    }

    /// `LocalizedStringKey`, not `String`, and that is not cosmetic: interpolating an `Int` into a
    /// `LocalizedStringKey` groups it — "Layer 1,731/1,952" — while a plain `String` does not. The
    /// lock-screen card builds this label from a literal and so has always grouped; taking a
    /// `String` here silently dropped the separators on the island alone, and the same print then
    /// read two different ways depending on where you looked at it.
    private func counter(_ text: LocalizedStringKey) -> some View {
        Text(text)
            .font(.caption2.monospacedDigit())
            .foregroundStyle(.secondary)
            .lineLimit(1)
    }
}

private struct IslandLeading: View {
    let state: PrintActivityAttributes.ContentState
    let tint: Color
    let printerId: Int

    var body: some View {
        // The PLATE only. `iconUri` is deliberately not a fallback here: it is the brand nozzle, and
        // showing it in the tile would put the same mark in the tile and beside it.
        //
        // Through `plateURI`, not `state.modelUri`: a Trellis push carries no plate, so reading the
        // pushed value alone made the tile empty on every server-driven update.
        if state.dry != true,
           let image = LockScreenCard.loadImage(
            LiveActivityArt.plateURI(printerId: printerId, jobName: state.name,
                                     carried: state.modelUri)) {
            // FIT into what the region offers, not a hard 44.
            //
            // `.frame(width: 44, height: 44)` is a DEMAND: when the expanded island's leading region
            // is narrower than that — and it is, its width is Apple's to decide and not published —
            // the tile overflows and the region clips it, cutting the model's left and right edges.
            // The same fault at its extreme is what showed a sliver of the fallback glyph.
            //
            // `scaledToFit` + `maxWidth/maxHeight` shrinks to whatever it is given instead, so the
            // whole model is always visible. Fit rather than fill costs nothing on a plate render,
            // which is square (measured: the printer's own cover is 512x512), and a non-square one
            // letterboxes onto the tile's own ground rather than losing its edges.
            Image(uiImage: image)
                .resizable()
                .scaledToFit()
                .frame(maxWidth: 44, maxHeight: 44)
                .modifier(PreviewTile(radius: 10))
        } else {
            IslandMark(state: state, tint: tint, size: 16)
        }
    }
}

/// The island mark with the print's progress drawn around it.
///
/// The slot is ~17 pt and already spends all of it on a glyph that never changes, so the ring is the
/// only way to get progress into it without shrinking the mark to nothing. It replaces no text: the
/// trailing slot still carries the finish time, which answers a different question.
///
/// A drying cycle gets the plain mark. Those pin `progress` to 0 for their whole run, so a ring
/// would sit empty and read as a stalled print — the countdown in the trailing slot is their answer.
private struct IslandProgressMark: View {
    let state: PrintActivityAttributes.ContentState
    let tint: Color

    private var fraction: Double {
        min(max(Double(state.progress) / 100, 0), 1)
    }

    var body: some View {
        if state.dry == true {
            IslandMark(state: state, tint: tint, size: 17)
        } else {
            // 17 TOTAL, the size the plain mark occupied. The ring was added at 22 and the compact
            // slot does not scroll or shrink its content — it clips it, against the sensor cutout.
            // The ring has to fit inside the old footprint, so the glyph gives up the 2pt the stroke
            // needs rather than the slot growing.
            //
            // `.inset(by: 1)` is what actually makes it fit. A stroke is CENTRED on the path, so a
            // 2pt stroke on a circle that fills a 17pt frame paints from 16pt to 18pt across —
            // half of it outside the frame — and the island clipped that outer point off, leaving
            // the leading arc sliced flat on a real phone. The frame measured 17 and was; the
            // paint was 19. Insetting by half the line width puts the whole stroke inside, which
            // `LiveActivityRenderTests` now checks by reading pixels rather than frames.
            IslandMark(state: state, tint: tint, size: 10)
                .frame(width: 17, height: 17)
                .background {
                    ZStack {
                        Circle()
                            .inset(by: 1)
                            .stroke(tint.opacity(0.28), lineWidth: 2)
                        Circle()
                            .inset(by: 1)
                            // A hair of arc at 0 %, so the ring reads as "started" rather than as a
                            // missing element on the first frames of a print.
                            .trim(from: 0, to: max(fraction, 0.02))
                            .stroke(tint, style: StrokeStyle(lineWidth: 2, lineCap: .round))
                            .rotationEffect(.degrees(-90))
                    }
                }
        }
    }
}

/// The tinted brand mark for the island's small slots — nozzle for a print, spool for a dry cycle.
private struct IslandMark: View {
    let state: PrintActivityAttributes.ContentState
    let tint: Color
    let size: CGFloat

    var body: some View {
        if state.dry == true {
            SpoolGlyph(size: size, tint: tint)
        } else {
            TintedNozzle(tint: tint, size: size)
        }
    }
}

/// The one place a countdown is rendered, shared by the lock-screen card, the expanded Dynamic
/// Island and the compact one.
///
/// It exists so no site can reintroduce `Date()...eta`: that range inverts as soon as the ETA passes
/// and `...` traps, taking the widget process — and therefore the whole Live Activity — with it. See
/// `LiveActivityCountdown`.
private struct CountdownSlot: View {
    let countdown: LiveActivityCountdown
    let font: Font
    let maxWidth: CGFloat
    /// The compact island slot is too narrow for the word, so it gets the short label.
    var compact: Bool = false
    /// Duration or wall-clock finish. See `LiveActivityCountdown.Style` for why the small slots
    /// differ from the roomy ones.
    var style: LiveActivityCountdown.Style = .remaining

    var body: some View {
        switch countdown {
        case .ticking(let range):
            switch style {
            case .remaining:
                text(Text(timerInterval: range, countsDown: true))
            case .finishClock:
                // `range.upperBound` IS the ETA — `countdown()` builds `now...eta`. Rendered with
                // `style: .time` so it follows the phone's 12/24-hour setting rather than a format
                // this widget picks, and so it needs no push to stay correct.
                text(Text(range.upperBound, style: .time))
            }
        case .overdue:
            // `0:00` reads as a countdown run out — beside a CLOCK it reads as midnight, so the
            // finish-time slots get a word instead.
            text(Text(
                !compact ? LiveActivityCountdown.overdueLabel
                    : style == .finishClock ? LiveActivityCountdown.overdueLabelClock
                    : LiveActivityCountdown.overdueLabelCompact))
        case .hidden:
            EmptyView()
        }
    }

    private func text(_ label: Text) -> some View {
        label
            .font(font)
            // One line, always. `maxWidth` caps how wide the slot may get, not how narrow it may be
            // squeezed, so in a contested layout a countdown wrapped into stacked fragments — "1:35:45"
            // as three lines. A time that does not fit should shrink, not stack.
            .lineLimit(1)
            .minimumScaleFactor(0.75)
            .multilineTextAlignment(.trailing)
            .frame(maxWidth: maxWidth)
    }
}

/// The full card on the lock screen.
private struct LockScreenCard: View {
    let state: PrintActivityAttributes.ContentState
    /// From the ACTIVITY'S ATTRIBUTES, which a push cannot replace — see `LiveActivityArt.plateURI`.
    let printerId: Int

    private var tint: Color { Color(hexString: state.tint) }

    var body: some View {
        // THREE COLUMNS, not four stacked rows.
        //
        // The old card was a leading glyph and then everything else in one column: title, name,
        // bar, and a stats row. Every one of those lines pinned something to the left edge and
        // something to the right, so the card read as two ragged margins with a hole down the
        // middle, and the one value worth glancing at — when it finishes — was the same size as
        // the nozzle temperatures.
        //
        // Now the middle column carries the identity and the progress, and the trailing column is
        // a single block for the answer. Nothing is pinned to a corner for want of anywhere else.
        HStack(alignment: .center, spacing: 12) {
            leadingVisual

            VStack(alignment: .leading, spacing: 5) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(state.stateLabel)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(tint)
                    if !state.printerName.isEmpty {
                        Text(state.printerName)
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(.secondary)
                    }
                }

                if !state.name.isEmpty {
                    // The headline, because it is the SUBJECT — what is being printed. It used to be
                    // 12pt regular `.secondary`, i.e. smaller and fainter than the state word above
                    // it, which inverted the hierarchy: the card shouted "Printing" and whispered
                    // what. live-activities.md:94 — "Use large, heavier-weight text — a medium
                    // weight or higher … make sure key information is legible at a glance."
                    Text(state.name)
                        .font(.system(size: 16, weight: .semibold))
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .foregroundStyle(.secondary)
                }

                if let rows = state.dryUnits, !rows.isEmpty {
                    DryUnitRows(rows: rows, tint: tint)
                } else if state.dry == true {
                    DryReadout(state: state, tint: tint)
                } else {
                    ExtrusionBar(
                        progress: Double(state.progress) / 100,
                        tint: tint,
                        riding: ExtrusionRider.rides(tintHex: state.tint, finished: state.finished),
                        // 5 read as a hairline once the card is drawn at Mac size beside the
                        // countdown. live-activities.md:113: "When separating a block of content,
                        // place it in an inset container shape or use a thick line."
                        barHeight: 7,
                        // 11 is the mock's margin, and the glyph is 20 tall, so it overflowed nine
                        // points into the line above and sat against the file name. Reserving the
                        // glyph's own height plus a little keeps the design's look without the
                        // collision.
                        headroom: 16
                    ) { riderGlyph }

                    // Counters and temperatures on ONE line when they fit, stacked when they do
                    // not — and stacked LEFT-ALIGNED, on the same margin as everything else in this
                    // column.
                    //
                    // This column is roughly a third of the card, not the card: the leading visual
                    // and the countdown block take the rest. A single fixed row tuned for the width
                    // of the expanded island clipped every reading here to "L…  R 2…  B…  C 3…",
                    // and squeezing the readings in beside "Layer 731/952" instead left that label
                    // floating against a two-row block on no shared baseline. Given a whole row they
                    // simply line up.
                    ViewThatFits(in: .horizontal) {
                        HStack(spacing: 8) {
                            layerCount
                            temps
                            Spacer(minLength: 0)
                        }
                        VStack(alignment: .leading, spacing: 3) {
                            layerCount
                            temps
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .foregroundStyle(.secondary)

                    if state.queueCount > 0, !state.nextName.isEmpty {
                        Text(verbatim: "Up next · \(state.nextName)")
                            .font(.system(size: 10))
                            .lineLimit(1)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            // The answer, given the weight it earns. Percentage sits under the time as its
            // subtitle rather than competing with the layer counter for the same line.
            // Both kinds get the trailing block. The drying card used to be the ONLY card with no
            // time on it — `DryReadout` replaced the block entirely — even though `etaEpochMs` is
            // populated for a dry cycle and the island already showed it.
            //
            // A DURATION, not a wall clock, and that is the whole distinction: a print has an
            // appointment ("come back at 21:47"), a dry cycle has a length ("another 5h 44m"). Nobody
            // plans their evening around when the filament finishes drying.
            VStack(alignment: .trailing, spacing: 1) {
                CountdownSlot(
                    countdown: state.countdown(),
                    font: .system(size: 19, weight: .semibold).monospacedDigit(),
                    maxWidth: 92,
                    style: state.dry == true ? .remaining : .finishClock
                )
                .foregroundStyle(state.dry == true ? AnyShapeStyle(tint) : AnyShapeStyle(.primary))
                if state.dry == true {
                    Text("left")
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                } else {
                    Text("\(state.progress)%")
                        .font(.system(size: 12, weight: .medium).monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }
            .fixedSize(horizontal: true, vertical: false)
        }
        .padding(14)
    }

    /// 56 pt, up from 44: the slot shows the PRINT, not the app.
    ///
    /// Fallback ladder, first that loads wins — `modelUri` (the plate render), then `iconUri` (the
    /// brand glyph), then the SF Symbol. All three live in the App Group because the widget is a
    /// separate process and cannot reach the app's sandbox; see `LiveActivityArt`, which is what
    /// finally puts them there. Until that landed every card fell to step 3, so the "fallback" was
    /// the only thing anyone ever saw.
    ///
    /// A drying card never has a plate to show, so it gets the spool tile instead of an empty well.
    @ViewBuilder
    private var leadingVisual: some View {
        if state.dry == true {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(tint.opacity(0.14))
                .frame(width: 56, height: 56)
                .overlay { SpoolGlyph(size: 28, tint: tint) }
        } else if let image = Self.loadImage(
            LiveActivityArt.plateURI(printerId: printerId, jobName: state.name,
                                     carried: state.modelUri)) ?? Self.loadImage(state.iconUri) {
            // `scaledToFill` + clip, not `scaledToFit`: a plate render is rarely square and fitting it
            // letterboxed the model into a corner of an empty slot.
            Image(uiImage: image)
                .resizable()
                .scaledToFill()
                .frame(width: 56, height: 56)
                .clipped()
                .modifier(PreviewTile())
        } else {
            Image(systemName: state.symbol)
                .font(.system(size: 26))
                .foregroundStyle(tint)
                .frame(width: 56, height: 56)
                .background(Color(red: 0.075, green: 0.082, blue: 0.090))
                .modifier(PreviewTile())
        }
    }

    /// The nozzle that rides the bar.
    ///
    /// DRAWN, not the App Group PNG. That PNG is the tab asset, which carries the bed plate as its
    /// fifth shape — riding the bar with it stacked the artwork's own plate line on the bar's line.
    /// `NozzleMark` is the design's crop, and being a view rather than a file is also what lets the
    /// bead take the tint while the body stays grey.
    private var riderGlyph: some View { NozzleMark(bead: tint) }

    private var temps: some View { TempsRow(state: state, tint: tint) }

    @ViewBuilder private var layerCount: some View {
        if state.totalLayers > 0 {
            Text("Layer \(state.layer)/\(state.totalLayers)")
                .font(.system(size: 11, weight: .medium).monospacedDigit())
                .lineLimit(1)
        }
    }

    static func loadImage(_ uri: String) -> UIImage? {
        guard !uri.isEmpty, let url = URL(string: uri), let data = try? Data(contentsOf: url) else { return nil }
        return UIImage(data: data)
    }
}

/// `N 148° → 220°  B 55° → 60°`, shared by the lock-screen card and the expanded island.
///
/// One view rather than two, because the island's numbers used to be missing entirely and the fix
/// for that must not become a second copy that drifts from the card's. Apple's own guidance for the
/// Lock Screen presentation is to "use a layout similar to the expanded presentation"
/// (HIG, Live Activities → Lock Screen), so the two surfaces disagreeing about what a print shows
/// was a defect rather than a choice.
private struct TempsRow: View {
    let state: PrintActivityAttributes.ContentState
    let tint: Color
    var size: CGFloat = 10

    /// Nothing to say when every reading is zero — an offline or idle card. Apple asks for the
    /// height to shrink when there is less to show, so this returning empty is load-bearing rather
    /// than tidy: it is what keeps the expanded island short in the states that have no numbers.
    var hasAny: Bool {
        state.nozzle > 0 || state.nozzleTarget > 0 || state.bed > 0 || state.bedTarget > 0
            || state.nozzle2 > 0 || state.nozzle2Target > 0 || state.chamber != nil
    }

    /// The heads, in position order. `nil` chamber is the printer having no chamber, not a chamber
    /// reading 0°, so an open-frame machine renders three pairs and not a fourth one lying about a
    /// chamber it does not have.
    @ViewBuilder private var heads: some View {
        if state.hasNozzle2 {
            pair("L", state.nozzle, state.nozzleTarget, active: state.activeNozzle == 0)
            pair("R", state.nozzle2, state.nozzle2Target, active: state.activeNozzle == 1)
        } else {
            pair("N", state.nozzle, state.nozzleTarget, active: true)
        }
    }

    @ViewBuilder private var vessels: some View {
        pair("B", state.bed, state.bedTarget, active: false)
        if let chamber = state.chamber {
            pair("C", chamber, state.chamberTarget ?? 0, active: false)
        }
    }

    var body: some View {
        // One row where it fits, two where it does not — the row adapts to the width it is GIVEN,
        // which is not the same as the width of the surface it is on. That distinction is what this
        // view got wrong: the expanded island hands the row most of its width, while the lock-screen
        // card's middle column is a third of the card, and a single fixed layout tuned for the
        // island truncated every reading to "L…  R 2…  B…  C 3…" on the card.
        //
        // Truncation is the one outcome that must never happen here: a clipped "L 148° →…" drops
        // the target, and the target is the number that answers "how long". Two rows cost a line;
        // a clipped row costs the information.
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 8) {
                heads
                vessels
            }
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 8) { heads }
                HStack(spacing: 8) { vessels }
            }
        }
        // Each PAIR stays on one line — a reading broken across lines is unreadable. The row as a
        // whole is free to become two, which is what `ViewThatFits` above decides.
        .lineLimit(1)
        .fixedSize(horizontal: false, vertical: true)
    }

    /// `N 148° → 220°` while a target is being chased, `N 220°` once it is reached. The target was
    /// accepted and dropped once, so a heating card said nothing about what it was heating TO —
    /// which on the one card that exists to answer "how long" is the number that answers it.
    private func pair(_ label: String, _ now: Int, _ target: Int, active: Bool) -> some View {
        Text(target > 0 && target != now ? "\(label) \(now)° → \(target)°" : "\(label) \(now)°")
            .font(.system(size: size, weight: active ? .semibold : .regular).monospacedDigit())
            .foregroundStyle(active ? AnyShapeStyle(tint) : AnyShapeStyle(.tertiary))
    }
}

/// Every rung of the leading ladder is a TILE — same corner, same hairline. Without it the fallback
/// steps read as a picture that failed to load rather than as the slot's own state.
private struct PreviewTile: ViewModifier {
    var radius: CGFloat = 10

    func body(content: Content) -> some View {
        content
            .clipShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .strokeBorder(Color.white.opacity(0.12))
            )
    }
}

/// The aggregate card's body: one line per drying unit.
///
/// Replaces `DryReadout`'s two big numbers, because at three units those numbers belong to three
/// different machines and stacking them says nothing about which. A row per unit, sorted soonest
/// first, is the only layout that answers "which one finishes next".
private struct DryUnitRows: View {
    let rows: [PrintActivityAttributes.DryUnitState]
    let tint: Color

    var body: some View {
        VStack(spacing: 0) {
            ForEach(rows) { row in
                if row.id != rows.first?.id {
                    Divider().overlay(Color.white.opacity(0.08))
                }
                HStack(spacing: 8) {
                    // Fixed column, so the labels line up rather than shifting with filament names.
                    Text(row.label)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(tint)
                        .frame(width: 52, alignment: .leading)
                    Text(row.filament)
                        .font(.system(size: 11))
                        .lineLimit(1)
                        .foregroundStyle(.secondary)
                    Text("\(row.temp)°→\(row.target)°")
                        .font(.system(size: 11).monospacedDigit())
                        .foregroundStyle(.secondary)
                    Text("\(row.humidity)%")
                        .font(.system(size: 11).monospacedDigit())
                        .foregroundStyle(.tertiary)
                    Spacer(minLength: 4)
                    Text(Self.short(row.minutesLeft))
                        .font(.system(size: 11, weight: .medium).monospacedDigit())
                        .foregroundStyle(.secondary)
                        .frame(width: 52, alignment: .trailing)
                }
                .padding(.vertical, 3)
            }
        }
    }

    /// `5h 44m`, or `44m` under the hour. A duration, never a clock — a dry cycle has no appointment.
    static func short(_ minutes: Int) -> String {
        let m = max(0, minutes)
        return m >= 60 ? "\(m / 60)h \(m % 60)m" : "\(m)m"
    }
}

/// Drying cards trade progress for the two numbers that actually tell the story: interior
/// temperature climbing and humidity falling. The countdown ticks client-side.
private struct DryReadout: View {
    let state: PrintActivityAttributes.ContentState
    let tint: Color

    var body: some View {
        HStack(spacing: 14) {
            reading("TEMP", value: "\(state.amsTemp ?? 0)°", target: (state.amsTarget ?? 0) > 0 ? "→ \(state.amsTarget ?? 0)°" : nil)
            reading("HUMIDITY", value: "\(state.humidity ?? 0)%", target: nil)
            Spacer()
        }
    }

    private func reading(_ label: String, value: String, target: String?) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label)
                .font(.system(size: 8, weight: .semibold))
                .tracking(0.8)
                .foregroundStyle(.tertiary)
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text(value)
                    .font(.system(size: 13, weight: .semibold).monospacedDigit())
                    .foregroundStyle(tint)
                if let target {
                    Text(target)
                        .font(.system(size: 10).monospacedDigit())
                        .foregroundStyle(.tertiary)
                }
            }
        }
    }
}

extension Color {
    /// Parses the `#RRGGBB` strings the content state carries. These come off the wire from Trellis,
    /// so an unparseable value falls back to grey rather than crashing the widget.
    init(hexString: String) {
        let hex = hexString.hasPrefix("#") ? String(hexString.dropFirst()) : hexString
        guard hex.count == 6, let v = UInt32(hex, radix: 16) else {
            self = .gray
            return
        }
        self.init(
            .sRGB,
            red: Double((v >> 16) & 0xFF) / 255,
            green: Double((v >> 8) & 0xFF) / 255,
            blue: Double(v & 0xFF) / 255
        )
    }
}
#if DEBUG
/// Renderable handles on the card's private views, for `LiveActivityRenderTests`.
///
/// These views are `private` and must stay that way — they are the widget's internals, not API. The
/// harness lives in this file for that reason alone. It exists because **a Live Activity cannot be
/// photographed before it ships**: the Simulator does not start one at all, so the island and the
/// lock-screen card could only ever be checked on a real device, after a TestFlight build. Rendering
/// the same views directly is the only way to see a layout mistake before a user does — which is how
/// the chamber reading was found taking a whole extra row.
enum LiveActivityShots {
    /// The expanded Dynamic Island's bottom region — bar and counters.
    static func islandBottom(_ state: PrintActivityAttributes.ContentState) -> some View {
        IslandBottom(state: state, tint: Color(hexString: state.tint))
            .environment(\.colorScheme, .dark)
    }

    /// The lock-screen card, whole.
    static func lockScreen(_ state: PrintActivityAttributes.ContentState, printerId: Int = 2) -> some View {
        LockScreenCard(state: state, printerId: printerId)
            .environment(\.colorScheme, .dark)
    }

    /// Just the temperature row, for measuring it against a width on its own.
    static func temps(_ state: PrintActivityAttributes.ContentState) -> some View {
        TempsRow(state: state, tint: Color(hexString: state.tint))
            .environment(\.colorScheme, .dark)
    }

    /// The compact-leading / minimal mark: the tinted glyph in its progress ring.
    static func compactMark(_ state: PrintActivityAttributes.ContentState) -> some View {
        IslandProgressMark(state: state, tint: Color(hexString: state.tint))
            .environment(\.colorScheme, .dark)
    }

    /// A countdown slot, exactly as one of the island regions configures it.
    static func countdown(_ countdown: LiveActivityCountdown, font: Font, maxWidth: CGFloat,
                          compact: Bool = false, style: LiveActivityCountdown.Style = .remaining,
                          tint: String = LAColors.running) -> some View {
        CountdownSlot(countdown: countdown, font: font, maxWidth: maxWidth, compact: compact, style: style)
            .foregroundStyle(Color(hexString: tint))
            .environment(\.colorScheme, .dark)
    }

    /// The expanded island's leading tile (plate preview, or the glyph it falls back to).
    static func islandLeading(_ state: PrintActivityAttributes.ContentState, printerId: Int = 2) -> some View {
        IslandLeading(state: state, tint: Color(hexString: state.tint), printerId: printerId)
            .environment(\.colorScheme, .dark)
    }

    /// The plate tile's exact modifier chain, over an image supplied directly.
    ///
    /// `IslandLeading` loads its image from the App Group, which a test has no way to populate — so
    /// the chain is exposed on its own. This is the thing that was cropping.
    static func plateTile(_ image: UIImage) -> some View {
        Image(uiImage: image)
            .resizable()
            .scaledToFit()
            .frame(maxWidth: 44, maxHeight: 44)
            .modifier(PreviewTile(radius: 10))
    }

    /// A single-unit drying card's readout.
    static func dryReadout(_ state: PrintActivityAttributes.ContentState) -> some View {
        DryReadout(state: state, tint: Color(hexString: state.tint))
            .environment(\.colorScheme, .dark)
    }

    /// The aggregate drying card's rows.
    static func dryUnitRows(_ rows: [PrintActivityAttributes.DryUnitState],
                            tint: String = LAColors.drying) -> some View {
        DryUnitRows(rows: rows, tint: Color(hexString: tint))
            .environment(\.colorScheme, .dark)
    }

    /// True when this state has temperatures to show at all — mirrors `TempsRow.hasAny`.
    static func hasTemps(_ state: PrintActivityAttributes.ContentState) -> Bool {
        TempsRow(state: state, tint: .green).hasAny
    }
}
#endif

#endif
