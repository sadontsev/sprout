#if os(iOS)
import SwiftUI
import UIKit
import XCTest

@testable import Sprout

/// Renders the Live Activity's own views and measures them.
///
/// **A Live Activity does not start in the Simulator at all**, so the island and the lock-screen
/// card cannot be photographed before they ship — every layout mistake in this file's history was
/// found on a real phone, after a TestFlight build, having already cost one. Rendering the views
/// directly is the only check available before that point, and it catches the whole class of defect
/// that matters here: content that does not fit the width it is given.
///
/// Two things happen per case. The measurement ASSERTS — a row wider than the slot it lives in is a
/// failure, whatever it looks like. The PNG is written only when `SPROUT_SHOT_DIR` is set, because
/// the value of a picture is that a human looks at it, and nothing looks at one written on every
/// run.
final class LiveActivityRenderTests: XCTestCase {

    // MARK: - Slot widths
    //
    // Measured from the shipped screenshots rather than assumed, and deliberately CONSERVATIVE: the
    // expanded island is inset from the screen edge on every Pro model, and the narrowest phone that
    // shows a lock-screen card is smaller than the one this is developed on. A layout that fits
    // these fits the real thing; one that fits only a 402pt phone is a layout that breaks on
    // somebody else's.

    /// Expanded Dynamic Island content width. The island is inset from a 393pt screen's edges.
    static let islandWidth: CGFloat = 371
    /// Lock-screen card on the NARROWEST phone that has one (375pt class, e.g. SE/mini).
    static let lockScreenWidth: CGFloat = 343

    // MARK: - States

    /// The live H2C, as photographed: dual nozzle, one head hot, chamber present.
    private func running() -> PrintActivityAttributes.ContentState {
        var s = PrintActivityAttributes.ContentState()
        s.stateLabel = "Printing"
        s.name = "Perfect Filament Storage"
        s.progress = 82
        s.layer = 731
        s.totalLayers = 952
        s.nozzle = 42
        s.nozzle2 = 220
        s.nozzle2Target = 220
        s.hasNozzle2 = true
        s.activeNozzle = 1
        s.bed = 55
        s.bedTarget = 55
        s.chamber = 30
        s.chamberTarget = 0
        s.etaEpochMs = Date().addingTimeInterval(2 * 3600 + 8 * 60).timeIntervalSince1970 * 1000
        return s
    }

    /// The WIDEST state this card can reach: a dual-nozzle enclosed machine with both heads and the
    /// bed and the chamber all chasing targets at once, and five-digit layer counters. Every reading
    /// carries an arrow, which is what makes it the worst case rather than merely a busy one.
    private func widest() -> PrintActivityAttributes.ContentState {
        var s = running()
        s.layer = 1731
        s.totalLayers = 1952
        s.nozzle = 148
        s.nozzleTarget = 220
        s.nozzle2 = 148
        s.nozzle2Target = 220
        s.bed = 55
        s.bedTarget = 60
        s.chamber = 31
        s.chamberTarget = 50
        return s
    }

    /// An open-frame machine: no chamber, one head.
    private func openFrame() -> PrintActivityAttributes.ContentState {
        var s = running()
        s.hasNozzle2 = false
        s.nozzle = 220
        s.nozzleTarget = 220
        s.activeNozzle = 0
        s.chamber = nil
        s.chamberTarget = nil
        return s
    }

    /// An AMS drying cycle — the compact slot shows the spool instead of the nozzle.
    private func drying() -> PrintActivityAttributes.ContentState {
        var s = PrintActivityAttributes.ContentState()
        s.dry = true
        s.stateLabel = "Drying"
        s.tint = LAColors.drying
        s.amsTemp = 55
        s.amsTarget = 60
        s.humidity = 18
        s.etaEpochMs = Date().addingTimeInterval(3600).timeIntervalSince1970 * 1000
        return s
    }

    // MARK: - Measuring

    /// The width this view WANTS, given no constraint. Larger than the slot means the slot cannot
    /// hold it — SwiftUI will then compress, scale or truncate, none of which this row should ever
    /// have to do.
    @MainActor
    private func idealWidth(_ view: some View) -> CGFloat {
        let host = UIHostingController(rootView: view)
        host.view.backgroundColor = .clear
        return host.sizeThatFits(in: CGSize(width: CGFloat.greatestFiniteMagnitude,
                                            height: CGFloat.greatestFiniteMagnitude)).width
    }

    /// Writes a PNG when `SPROUT_SHOT_DIR` is set, and returns the rendered size.
    @discardableResult
    @MainActor
    private func shoot(_ view: some View, width: CGFloat, named name: String) -> CGSize {
        let renderer = ImageRenderer(content: view.frame(width: width).background(Color.black))
        renderer.scale = 3
        renderer.proposedSize = ProposedViewSize(width: width, height: nil)
        let size = renderer.uiImage?.size ?? .zero
        if let dir = ProcessInfo.processInfo.environment["SPROUT_SHOT_DIR"],
            let png = renderer.uiImage?.pngData()
        {
            try? FileManager.default.createDirectory(
                atPath: dir, withIntermediateDirectories: true)
            try? png.write(to: URL(fileURLWithPath: dir).appendingPathComponent("\(name).png"))
        }
        return size
    }

    /// Pixels a view paints OUTSIDE a square frame of `frame` points.
    ///
    /// The view is placed in that frame, surrounded by `pad` points of black, and rendered; any
    /// non-black pixel in the surround was drawn past the frame. SwiftUI does not clip a view to
    /// its frame, so a stroke centred on a shape's edge paints half its width outside — which the
    /// island then clips against its own boundary. A frame-size measurement cannot see that; only
    /// the pixels can.
    @MainActor
    private func pixelsOutsideFrame(_ view: some View, frame: CGFloat, pad: CGFloat = 3,
                                    scale: CGFloat = 4) -> Int {
        let content = view.frame(width: frame, height: frame).padding(pad).background(Color.black)
        let renderer = ImageRenderer(content: content)
        renderer.scale = scale
        guard let cg = renderer.cgImage else { return -1 }
        let w = cg.width
        let h = cg.height
        var buf = [UInt8](repeating: 0, count: w * h * 4)
        guard let ctx = CGContext(
            data: &buf, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return -1 }
        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))
        let inset = Int(pad * scale)
        var count = 0
        for y in 0..<h {
            for x in 0..<w {
                if x >= inset && x < w - inset && y >= inset && y < h - inset { continue }
                let i = (y * w + x) * 4
                if Int(buf[i]) + Int(buf[i + 1]) + Int(buf[i + 2]) > 45 { count += 1 }
            }
        }
        return count
    }

    // MARK: - The guard

    /// The compact ring must paint NOTHING outside its 17pt frame.
    ///
    /// Observed on a phone: the ring's leading arc sliced flat against the island's edge. The
    /// frame was 17pt, and the measurement said so — but `Circle().stroke(lineWidth: 2)` centres
    /// the stroke on the path, so the ring painted 19pt and the island clipped the outer point.
    /// This test reads pixels, not frames, because that is the only place the difference shows.
    @MainActor
    func testTheCompactRingStaysInsideItsFrame() {
        for (label, state) in [("running", running()), ("open", openFrame()), ("dry", drying())] {
            let outside = pixelsOutsideFrame(LiveActivityShots.compactMark(state), frame: 17)
            XCTAssertEqual(outside, 0, "\(label): \(outside) px painted outside the 17pt frame")
        }
    }


    /// The free space beside the counters on one line, at a given slot width.
    @MainActor
    private func budgetBesideCounters(_ state: PrintActivityAttributes.ContentState, width: CGFloat)
        -> CGFloat
    {
        let counters = idealWidth(
            Text("Layer \(state.layer)/\(state.totalLayers)  \(state.progress)%")
                .font(.caption2.monospacedDigit()))
        return width - counters - 2 * 10 - 16
    }

    /// The ORDINARY states must fit on the counters' line.
    ///
    /// This is the point of moving them there: a settled print shows four short readings, and the
    /// space between "Layer 731/952" and "82%" is over half the island. If these stop fitting, the
    /// card silently grows a row again and the middle goes back to being empty.
    @MainActor
    func testTheOrdinaryStatesShareTheCountersLine() {
        for (label, state) in [("running", running()), ("open", openFrame())] {
            let temps = idealWidth(LiveActivityShots.temps(state))
            let budget = budgetBesideCounters(state, width: Self.islandWidth)
            XCTAssertLessThanOrEqual(
                temps, budget,
                "\(label): temperatures want \(Int(temps))pt, only \(Int(budget))pt free beside the counters")
        }
    }

    /// The WIDEST state is allowed to take a second line — and must not truncate when it does.
    ///
    /// A dual-nozzle enclosed machine mid-heat carries an arrow on every reading and does not fit
    /// beside the counters. `ViewThatFits` drops it to its own row for that case; what must never
    /// happen is the row being kept on one line and clipped, which cost all four targets — the
    /// numbers that answer "how long" — to save a line.
    @MainActor
    func testTheWidestStateTakesASecondLineRatherThanTruncating() {
        let state = widest()
        XCTAssertGreaterThan(
            idealWidth(LiveActivityShots.temps(state)),
            budgetBesideCounters(state, width: Self.islandWidth),
            "if this now fits on one line, the two-line fallback is untested — pick a wider case")
        XCTAssertLessThanOrEqual(
            idealWidth(LiveActivityShots.temps(state)), Self.islandWidth - 2 * 10,
            "the widest readout must fit a full row without truncating")
    }

    /// The lock-screen card is NARROWER than the island on a small phone, and shows the same row.
    @MainActor
    func testTheTemperatureRowFitsTheNarrowestLockScreen() {
        XCTAssertLessThanOrEqual(
            idealWidth(LiveActivityShots.temps(widest())), Self.lockScreenWidth - 2 * 10,
            "the widest readout does not fit the narrowest lock-screen card")
    }

    /// An open-frame machine shows three pairs, an enclosed one four — the row must actually be
    /// narrower without a chamber, or the capability gate is not doing anything.
    @MainActor
    func testDroppingTheChamberNarrowsTheRow() {
        XCTAssertLessThan(
            idealWidth(LiveActivityShots.temps(openFrame())),
            idealWidth(LiveActivityShots.temps(running())))
    }

    // MARK: - Countdown slots

    /// One countdown slot on the island, with the font and cap its region actually uses.
    ///
    /// A struct, not a tuple: an array literal of tuples carrying `Font` expressions sent the type
    /// checker exponential and the build never finished — twice. Explicit types keep it linear.
    private struct CountdownSlotSpec {
        let label: String
        let font: Font
        let maxWidth: CGFloat
        let compact: Bool
        let style: LiveActivityCountdown.Style
    }

    private static let mono12: Font = .system(size: 12, weight: .medium).monospacedDigit()
    private static let mono13: Font = .system(size: 13, weight: .semibold).monospacedDigit()

    private var countdownSlots: [CountdownSlotSpec] {
        [
            CountdownSlotSpec(label: "expanded-trailing", font: Self.mono12, maxWidth: 64, compact: false, style: .remaining),
            CountdownSlotSpec(label: "compact-dry", font: Self.mono13, maxWidth: 58, compact: true, style: .finishClock),
            CountdownSlotSpec(label: "compact-print", font: Self.mono13, maxWidth: 58, compact: true, style: .finishClock),
        ]
    }

    /// The strings a slot must hold. Measured as STATIC text in the slot's monospaced-digit font,
    /// which is the same width the live `Text(timerInterval:)` draws, and — unlike the live timer —
    /// can be measured in a hosting controller without the clock involved. A print over ten hours
    /// is routine on this machine, so the eight-character form is the one that matters.
    private func sample(_ style: LiveActivityCountdown.Style) -> [(label: String, text: String)] {
        switch style {
        case .remaining: return [("59m", "59:59"), ("2h08m", "2:08:32"), ("12h08m", "12:08:32")]
        case .finishClock: return [("24h", "21:09"), ("12h", "12:09 PM")]
        }
    }

    /// `CountdownSlot`'s `minimumScaleFactor`. Below this the text truncates instead of shrinking.
    private static let countdownMinScale: CGFloat = 0.75

    /// No countdown may TRUNCATE in its slot — `12:08:…` is the failure, and it is what the
    /// drying compact slot did past ten hours.
    ///
    /// `CountdownSlot` caps itself with `.frame(maxWidth:)`, so measuring the slot reports the cap
    /// and hides the problem; this measures what the text WANTS. Shrinking to the minimum scale is
    /// the slot's documented behaviour ("a time that does not fit should shrink, not stack"), so
    /// the hard line is the width at that scale. Cases that fit only by shrinking are reported,
    /// not failed — a 12-hour-locale `12:09 PM` at 75 % is legible; a clipped one is not.
    @MainActor
    func testNoCountdownTruncatesInItsSlot() {
        for slot in countdownSlots {
            for d in sample(slot.style) {
                let want = idealWidth(Text(verbatim: d.text).font(slot.font))
                XCTAssertLessThanOrEqual(
                    want * Self.countdownMinScale, slot.maxWidth,
                    "\(slot.label), \(d.label): text wants \(Int(want))pt; even at \(Self.countdownMinScale)x it will not fit \(Int(slot.maxWidth))pt and will TRUNCATE")
                if want > slot.maxWidth {
                    print("  [render] \(slot.label), \(d.label): \(Int(want))pt shrinks to fit \(Int(slot.maxWidth))pt")
                }
            }
        }
    }

    // MARK: - Drying layouts

    private func dryRows() -> [PrintActivityAttributes.DryUnitState] {
        [
            PrintActivityAttributes.DryUnitState(amsId: 0, label: "AMS 1", filament: "PLA", temp: 55, target: 60, humidity: 18, minutesLeft: 344),
            PrintActivityAttributes.DryUnitState(amsId: 128, label: "AMS HT", filament: "PA-CF", temp: 78, target: 80, humidity: 9, minutesLeft: 44),
        ]
    }

    /// The single-unit readout must fit the island's bottom region and the card's middle column.
    @MainActor
    func testTheDryReadoutFits() {
        let w = idealWidth(LiveActivityShots.dryReadout(drying()))
        XCTAssertLessThanOrEqual(w, Self.islandWidth - 2 * 10, "island bottom")
    }

    /// Aggregate rows must fit the narrowest lock-screen card without any column truncating.
    @MainActor
    func testTheDryRowsFitTheNarrowestCard() {
        let w = idealWidth(LiveActivityShots.dryUnitRows(dryRows()))
        XCTAssertLessThanOrEqual(w, Self.lockScreenWidth - 2 * 10, "rows want \(Int(w))pt")
    }

    // MARK: - The plate tile must not crop

    /// A square image with a 3pt border of a known colour on all four sides.
    @MainActor
    private func borderedSquare(side: CGFloat = 512, border: CGFloat = 24) -> UIImage {
        UIGraphicsImageRenderer(size: CGSize(width: side, height: side)).image { ctx in
            UIColor.white.setFill()
            ctx.fill(CGRect(x: 0, y: 0, width: side, height: side))
            UIColor.red.setFill()
            ctx.fill(CGRect(x: 0, y: 0, width: side, height: border))
            ctx.fill(CGRect(x: 0, y: side - border, width: side, height: border))
            ctx.fill(CGRect(x: 0, y: 0, width: border, height: side))
            ctx.fill(CGRect(x: side - border, y: 0, width: border, height: side))
        }
    }

    /// Whether a rendered tile still shows red along each of its four edges.
    @MainActor
    private func edgesPresent(_ view: some View, offered: CGFloat) -> (top: Bool, bottom: Bool,
                                                                      left: Bool, right: Bool) {
        let r = ImageRenderer(content: view.frame(width: offered, height: offered))
        r.scale = 4
        guard let cg = r.cgImage else { return (false, false, false, false) }
        let w = cg.width
        let h = cg.height
        var buf = [UInt8](repeating: 0, count: w * h * 4)
        guard let ctx = CGContext(
            data: &buf, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return (false, false, false, false) }
        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))
        func isRed(_ x: Int, _ y: Int) -> Bool {
            let i = (y * w + x) * 4
            return buf[i] > 120 && buf[i + 1] < 90 && buf[i + 2] < 90
        }
        // Scanned a couple of pixels in from each edge, so the tile's own rounded corners are not
        // mistaken for a crop. A whole row or column having no red means that edge was lost.
        func rowHasRed(_ y: Int) -> Bool { (0..<w).contains { isRed($0, y) } }
        func colHasRed(_ x: Int) -> Bool { (0..<h).contains { isRed(x, $0) } }
        return (top: rowHasRed(2), bottom: rowHasRed(h - 3),
                left: colHasRed(2), right: colHasRed(w - 3))
    }

    /// The tile must show the WHOLE plate, at every width the region might offer.
    ///
    /// The expanded island's leading region width is Apple's to decide and is not published. The
    /// tile demanded a fixed 44pt, so where the region offered less it overflowed and was clipped —
    /// the model's edges cut off, and at the extreme only a sliver of the fallback glyph. Reported
    /// twice from a phone before it was measured here.
    @MainActor
    func testThePlateTileNeverCropsTheModel() {
        let image = borderedSquare()
        for offered in [44, 40, 36, 30] as [CGFloat] {
            let e = edgesPresent(LiveActivityShots.plateTile(image), offered: offered)
            XCTAssertTrue(
                e.top && e.bottom && e.left && e.right,
                "offered \(Int(offered))pt: edges lost — top:\(e.top) bottom:\(e.bottom) left:\(e.left) right:\(e.right)")
        }
    }

    // MARK: - The pictures

    @MainActor
    func testRenderTheCards() {
        for (label, state) in [("running", running()), ("widest", widest()), ("open", openFrame())] {
            let island = shoot(
                LiveActivityShots.islandBottom(state), width: Self.islandWidth,
                named: "island-\(label)")
            let card = shoot(
                LiveActivityShots.lockScreen(state), width: Self.lockScreenWidth,
                named: "card-\(label)")
            XCTAssertGreaterThan(island.height, 0, "\(label): island rendered nothing")
            XCTAssertGreaterThan(card.height, 0, "\(label): card rendered nothing")
        }
        // Every countdown slot at its cap, with the cap outlined, so truncation is visible. The
        // live slot is used here (ImageRenderer copes with timer text; the hosting controller in
        // `idealWidth` does not), with a twelve-hour range so the widest string is on screen.
        let long = Date()...Date().addingTimeInterval(12 * 3600 + 8 * 60 + 32)
        for slot in countdownSlots {
            let v = LiveActivityShots.countdown(
                .ticking(long), font: slot.font, maxWidth: slot.maxWidth,
                compact: slot.compact, style: slot.style)
                .overlay(Rectangle().strokeBorder(Color.white.opacity(0.35), lineWidth: 0.25))
                .padding(4)
            let r = ImageRenderer(content: v.background(Color.black))
            r.scale = 6
            if let dir = ProcessInfo.processInfo.environment["SPROUT_SHOT_DIR"],
                let png = r.uiImage?.pngData()
            {
                try? png.write(to: URL(fileURLWithPath: dir).appendingPathComponent("countdown-\(slot.label).png"))
            }
        }
        shoot(LiveActivityShots.islandLeading(running()), width: 44, named: "island-leading")
        for offered in [44, 36, 30] as [CGFloat] {
            let v = LiveActivityShots.plateTile(borderedSquare())
                .frame(width: offered, height: offered)
                .padding(3)
            let r = ImageRenderer(content: v.background(Color.black))
            r.scale = 8
            if let dir = ProcessInfo.processInfo.environment["SPROUT_SHOT_DIR"],
                let png = r.uiImage?.pngData()
            {
                try? png.write(to: URL(fileURLWithPath: dir).appendingPathComponent("tile-\(Int(offered)).png"))
            }
        }
        shoot(LiveActivityShots.dryReadout(drying()), width: Self.islandWidth - 20, named: "dry-readout")
        shoot(LiveActivityShots.dryUnitRows(dryRows()), width: Self.lockScreenWidth - 20, named: "dry-rows")
        // The compact mark at 12x, with its 17pt frame outlined, so a stroke past the frame is
        // visible to a human as well as to `pixelsOutsideFrame`.
        for (label, state) in [("running", running()), ("dry", drying())] {
            let framed = LiveActivityShots.compactMark(state)
                .frame(width: 17, height: 17)
                .overlay(Rectangle().strokeBorder(Color.white.opacity(0.35), lineWidth: 0.25))
                .padding(4)
            let r = ImageRenderer(content: framed.background(Color.black))
            r.scale = 12
            if let dir = ProcessInfo.processInfo.environment["SPROUT_SHOT_DIR"],
                let png = r.uiImage?.pngData()
            {
                try? png.write(to: URL(fileURLWithPath: dir).appendingPathComponent("compact-\(label).png"))
            }
        }
    }
}
#endif
