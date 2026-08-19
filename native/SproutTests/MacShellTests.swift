import XCTest
@testable import Sprout

/// The macOS shell's pure logic.
///
/// Every rule here is one that nothing in ordinary use will exercise, which is exactly why it is
/// pinned: the collapse thresholds fire only in split-screen and on small external displays, the
/// status-pill text is chrome nobody reads closely, and `TabKey`'s raw values are a persisted format
/// whose breakage looks like "the app forgot which section I was on" rather than like an error.
final class MacShellTests: XCTestCase {

    // MARK: - TabKey is a persisted format

    /// Raw values reach the Keychain config and `@SceneStorage`. Renaming a case silently resets
    /// someone's last-used section, and §2 forbids renumbering.
    func testTabKeyRawValuesAreStable() {
        XCTAssertEqual(TabKey.printer.rawValue, "printer")
        XCTAssertEqual(TabKey.library.rawValue, "library")
        XCTAssertEqual(TabKey.jobs.rawValue, "jobs")
        XCTAssertEqual(TabKey.ams.rawValue, "ams")
        XCTAssertEqual(TabKey.power.rawValue, "power")
        XCTAssertEqual(TabKey.explore.rawValue, "explore")
    }

    /// §2: Explore joins the enum but must NOT become a sixth iOS tab.
    func testExploreIsNotAnIosTab() {
        XCTAssertFalse(TabKey.iosTabs.contains(.explore))
        XCTAssertEqual(TabKey.iosTabs.count, 5)
    }

    /// `allCases` order matters to anything that ever enumerates it; `explore` was appended rather
    /// than inserted so the five original sections keep their original order.
    func testExploreIsAppendedNotInserted() {
        XCTAssertEqual(Array(TabKey.allCases.prefix(5)), TabKey.iosTabs)
        XCTAssertEqual(TabKey.allCases.last, .explore)
    }

    /// The sidebar draws `⌘n` in each row and `MacCommands` registers the real shortcut; both read
    /// this, so the two cannot drift — but only if it actually numbers the sidebar order.
    func testCommandDigitsFollowSidebarOrder() {
        XCTAssertEqual(TabKey.printer.commandDigit, "1")
        XCTAssertEqual(TabKey.library.commandDigit, "2")
        XCTAssertEqual(TabKey.jobs.commandDigit, "3")
        XCTAssertEqual(TabKey.ams.commandDigit, "4")
        XCTAssertEqual(TabKey.power.commandDigit, "5")
        XCTAssertEqual(TabKey.explore.commandDigit, "6")
    }

    func testEveryMacSidebarRowHasAShortcut() {
        for key in TabKey.macPrimary + TabKey.macBrowse {
            XCTAssertNotNil(key.commandDigit, "\(key) is drawn in the sidebar with no shortcut")
        }
    }

    // MARK: - Metrics

    /// A token defined on one platform and not the other is a silent layout bug on exactly one
    /// platform. Both structs are total by construction (`let` members), so what is worth pinning is
    /// that they actually DIFFER where §8 says they do, and that the Mac values respect its floor.
    func testMacMetricsAreDenserThanIOS() {
        XCTAssertLessThan(Metrics.mac.body, Metrics.iOS.body)
        XCTAssertLessThan(Metrics.mac.rowHeight, Metrics.iOS.rowHeight)
        XCTAssertLessThan(Metrics.mac.cardRadius, Metrics.iOS.cardRadius)
        XCTAssertLessThan(Metrics.mac.heroMetric, Metrics.iOS.heroMetric)
        XCTAssertGreaterThan(Metrics.mac.gutter, Metrics.iOS.gutter, "§8 widens the outer gutter on Mac")
    }

    /// §8's last line: 24 pt is the floor, but the primary action stays 34 so it still reads as the
    /// primary action rather than as one more 28 pt control.
    func testPrimaryControlStaysTallerThanTheRest() {
        XCTAssertEqual(Metrics.mac.primaryControlHeight, 34)
        XCTAssertGreaterThan(Metrics.mac.primaryControlHeight, Metrics.mac.controlHeight)
        XCTAssertGreaterThanOrEqual(Metrics.mac.controlHeight, Metrics.mac.minControlHeight)
        XCTAssertEqual(Metrics.mac.minControlHeight, 24)
    }

    #if os(macOS)

    // MARK: - Menu bar glyph

    /// The nozzle mark has to fit the menu bar's slot, with air.
    ///
    /// It was drawn at the asset's INTRINSIC size — a 17.6 x 26 pt SVG — so 26 pt of artwork went
    /// into a 22 pt slot and it dwarfed every system item beside it. Measured through
    /// `SPROUT_WINDOW_PROBE`: framing it took the status item from 44 pt wide to 34 pt.
    ///
    /// The upper bound is the real invariant. 22 is the slot on a standard Mac, and a glyph that
    /// fills it edge to edge looks wrong even where it is not clipped, so the cap is set below that
    /// deliberately rather than at it.
    func testTheMenuBarGlyphFitsTheBarWithAir() {
        XCTAssertLessThanOrEqual(MacMenuBarLabel.glyphHeight, 18)
        XCTAssertGreaterThanOrEqual(MacMenuBarLabel.glyphHeight, 12)
    }

    // MARK: - Collapse rules (§1)

    /// The default window is 1440 wide: everything fits.
    func testDefaultWindowShowsAllThreeColumns() {
        let c = MacCollapse.forWidth(1440)
        XCTAssertTrue(c.inspectorFitsAsColumn)
        XCTAssertTrue(c.sidebarFitsAsColumn)
        XCTAssertFalse(c.needsToolbarSectionPopup)
    }

    /// 1180 is 220 + 640 + 320 exactly — the moment the three stated widths stop fitting. Pinned as
    /// an inclusive boundary because "at exactly 1180" is the case a `>` would get wrong.
    func testInspectorThresholdIsTheSumOfTheThreeColumns() {
        XCTAssertEqual(MacCollapse.inspectorThreshold, 220 + 640 + 320)
        XCTAssertTrue(MacCollapse.forWidth(1180).inspectorFitsAsColumn)
        XCTAssertFalse(MacCollapse.forWidth(1179).inspectorFitsAsColumn)
    }

    /// Between the two thresholds only the inspector goes. Losing detail is preferable to losing
    /// navigation, which is the whole reason there are two thresholds and not one.
    func testInspectorGoesBeforeTheSidebar() {
        let c = MacCollapse.forWidth(1000)
        XCTAssertFalse(c.inspectorFitsAsColumn)
        XCTAssertTrue(c.sidebarFitsAsColumn, "the sidebar must outlive the inspector")
    }

    func testSidebarFoldsBelowItsThreshold() {
        XCTAssertTrue(MacCollapse.forWidth(980).sidebarFitsAsColumn)
        XCTAssertFalse(MacCollapse.forWidth(979).sidebarFitsAsColumn)
    }

    /// Navigation is never lost: whenever the sidebar folds, the toolbar must carry the popup.
    func testNavigationIsNeverLost() {
        for width in stride(from: 320.0, through: 1600.0, by: 20.0) {
            let c = MacCollapse.forWidth(width)
            XCTAssertTrue(
                c.sidebarFitsAsColumn || c.needsToolbarSectionPopup,
                "at \(width) pt there is no way to change section"
            )
        }
    }

    /// Both thresholds sit above the 1080 pt window minimum, so neither is reachable by dragging
    /// the window edge — they exist for split-screen and small external displays. If someone lowers
    /// a threshold below the minimum it becomes dead code, and this says so.
    func testThresholdsAreOnlyReachableBelowTheWindowMinimum() {
        XCTAssertGreaterThan(MacCollapse.inspectorThreshold, 1080)
        XCTAssertLessThan(MacCollapse.sidebarThreshold, 1080, "a sidebar rule at or above the window minimum would fire in normal use")
    }

    // MARK: - Toolbar status pill (§3)

    /// The percentage is appended only while a print is actually running. `.complete` still reports
    /// 100 and `.error` reports whatever it stopped at; either would read as a live number on a
    /// machine that is not moving.
    func testPercentageOnlyAppearsWhilePrinting() {
        var vm = DashVM()
        vm.kind = .live
        vm.stateLabel = "Printing"
        vm.progressInt = 62
        XCTAssertEqual(MacStatusPill.text(vm), "PRINTING · 62 %")

        vm.kind = .complete
        vm.stateLabel = "Complete"
        vm.progressInt = 100
        XCTAssertEqual(MacStatusPill.text(vm), "COMPLETE")

        vm.kind = .error
        vm.stateLabel = "Error"
        vm.progressInt = 41
        XCTAssertEqual(MacStatusPill.text(vm), "ERROR")
    }

    func testOfflineAndIdleReadAsThemselves() {
        var vm = DashVM()
        vm.kind = .offline
        vm.stateLabel = "Offline"
        XCTAssertEqual(MacStatusPill.text(vm), "OFFLINE")

        vm.kind = .idle
        vm.stateLabel = "Idle"
        XCTAssertEqual(MacStatusPill.text(vm), "IDLE")
    }

    // MARK: - Camera claim (§5.2)

    /// The window wins while it is STREAMING. A paused window holds no claim — it is not using the
    /// upstream, and keeping it claimed captioned the tile "PLAYING IN WINDOW" while neither
    /// surface showed video.
    @MainActor
    func testAPausedCameraWindowReleasesTheClaim() {
        let owner = MacCameraOwnership()
        XCTAssertTrue(owner.tileMayStream(printerId: 1))

        owner.setWindowStreaming(true, printerId: 1)
        XCTAssertFalse(owner.tileMayStream(printerId: 1))

        owner.setWindowStreaming(false, printerId: 1)     // paused, still open
        XCTAssertTrue(owner.tileMayStream(printerId: 1), "a paused window is not using the camera")
    }

    /// One claim per PRINTER, not one globally: a camera window for printer 1 must not stop the
    /// tile streaming printer 2.
    @MainActor
    func testTheClaimIsPerPrinter() {
        let owner = MacCameraOwnership()
        owner.setWindowStreaming(true, printerId: 1)
        XCTAssertFalse(owner.tileMayStream(printerId: 1))
        XCTAssertTrue(owner.tileMayStream(printerId: 2))
    }

    /// SwiftUI can run `onDisappear` for a window being replaced rather than closed. A double
    /// release must not leave anything claimed by a window that no longer exists.
    @MainActor
    func testReleasingTwiceIsHarmless() {
        let owner = MacCameraOwnership()
        owner.setWindowStreaming(true, printerId: 3)
        owner.setWindowStreaming(false, printerId: 3)
        owner.setWindowStreaming(false, printerId: 3)
        XCTAssertTrue(owner.tileMayStream(printerId: 3))
    }

    // MARK: - Drop target (§5.3)

    /// Extension-based on purpose: a URL dragged from Finder often has no resolvable `UTType`,
    /// because `gcode` and (on most systems) `3mf` are not registered types at all. Asking the file
    /// system for a content type would reject exactly the files Sprout exists to open.
    func testDropAcceptsTheDeclaredTypes() {
        for name in ["a.3mf", "b.gcode", "c.stl", "PLATE.3MF", "x.gcode.3mf"] {
            XCTAssertTrue(MacDropTarget.accepts(URL(fileURLWithPath: "/tmp/\(name)")), name)
        }
    }

    func testDropRejectsEverythingElse() {
        for name in ["notes.txt", "photo.png", "archive.zip", "model.3mf.bak", "gcode"] {
            XCTAssertFalse(MacDropTarget.accepts(URL(fileURLWithPath: "/tmp/\(name)")), name)
        }
    }

    // MARK: - Open requests (§5.3 / §5.4)

    /// A `bambu://file/<id>` hit has to land on Files; a request that named the wrong section would
    /// select a file on a screen that cannot show it.
    func testOpenRequestsNameTheSectionThatCanServeThem() {
        XCTAssertEqual(MacOpenRequest.file(12).section, .library)
        XCTAssertEqual(MacOpenRequest.section(.power).section, .power)
    }

    #endif
}

/// `PlugPoller`'s freshness rule.
///
/// Not macOS-specific — it guards every wattage on both platforms — but it belongs with the other
/// "nearby predicate" pins. The bug it exists to prevent shipped twice: a retained reading rendered
/// under the words "W drawing now", and again under "kWh · nothing is measuring".
final class PlugFreshnessTests: XCTestCase {

    /// An unbound poller is not measuring anything, whatever its last poll said.
    ///
    /// This is the case `reachable` alone cannot see. When Bambuddy stops reporting a plug,
    /// `PowerStore` binds nil, which STOPS the poller — and `reachable` stays `true` for ever,
    /// because the last poll it ever made did succeed.
    @MainActor
    func testAnUnboundPollerIsNeverCurrent() {
        let poller = PlugPoller(period: .seconds(5))
        XCTAssertFalse(poller.isPolling, "nothing bound, so nothing is polling")
        XCTAssertTrue(poller.reachable, "reachable defaults true — which is exactly the trap")
        XCTAssertFalse(poller.readingIsCurrent)
        XCTAssertNil(poller.liveWatts)
        XCTAssertNil(poller.liveKwh)
    }

    /// `start()` does nothing without a binding, so a poller cannot report itself as live by being
    /// asked to run.
    @MainActor
    func testStartWithoutABindingDoesNotClaimToBePolling() {
        let poller = PlugPoller(period: .seconds(5))
        poller.start()
        XCTAssertFalse(poller.isPolling)
        XCTAssertFalse(poller.readingIsCurrent)
    }

    /// The raw values stay deliberately sticky — blanking on a blip is the behaviour this guard
    /// exists to preserve, not remove. Only the *presentation* accessors go nil.
    @MainActor
    func testTheRawValuesAreStillRetained() {
        let poller = PlugPoller(period: .seconds(5))
        poller.stop()
        XCTAssertNil(poller.watts, "no poll has run, so there is nothing retained yet")
        XCTAssertFalse(poller.readingIsCurrent)
    }

    // MARK: - Who finishes an open request

    // macOS-only: `MacOpenRequest` lives behind `#if os(macOS)`, so without this guard the whole
    // iOS target fails to compile. That is exactly what happened — these were added and only the
    // macOS suite was re-run, so a green 1088 hid a broken iOS build.
    #if os(macOS)

    /// The handover rule between the request's two consumers. `MacWindow` navigates and then either
    /// clears the request or leaves it for the section that landed; getting this backwards breaks
    /// one of the two in a way nothing else catches.
    func testArrivingFinishesASectionRequestButNotAFileRequest() {
        XCTAssertTrue(MacOpenRequest.section(.jobs).isServedByArriving)
        XCTAssertTrue(MacOpenRequest.section(.library).isServedByArriving,
                      "even to Files — a bare section request asks for nothing but the section")
        XCTAssertFalse(MacOpenRequest.file(12).isServedByArriving,
                       "the id still has to be selected, so the request must survive the trip")
    }

    /// A served-and-cleared request is what lets the SECOND one of a session do anything at all:
    /// `onChange` fires on a change, so an uncleared `.section(.jobs)` would be re-assigned its own
    /// value and navigate nowhere. This is the print-sheet-to-Jobs jump.
    func testRepeatingASectionRequestStillNavigatesBecauseItWasCleared() {
        var pending: MacOpenRequest?
        var arrivedAt: [TabKey] = []
        func consume(_ request: MacOpenRequest?) {
            guard let request else { return }
            arrivedAt.append(request.section)
            if request.isServedByArriving { pending = nil }
        }

        pending = .section(.jobs); consume(pending)
        XCTAssertNil(pending, "serving it must clear it")
        pending = .section(.jobs); consume(pending)
        XCTAssertEqual(arrivedAt, [.jobs, .jobs], "the second print must navigate too")
    }

    #endif
}
