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

    // MARK: - The guard

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
    }
}
#endif
