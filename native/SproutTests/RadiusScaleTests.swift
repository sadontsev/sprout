import XCTest
@testable import Sprout

/// The corner-radius scale (`Metrics.cardRadius` / `controlRadius` / `chipRadius`).
///
/// This exists because the thing it guards is invisible to every other kind of check. A radius that
/// drifts compiles, runs, renders and passes the whole suite — the only symptom is the owner saying
/// the window looks untidy, which is what happened: a survey of `Views/Mac/` found 2, 3, 4, 5, 6, 7,
/// 8, 9, 10, 11 and 12 all in use, several of them for the same *kind* of element in two adjacent
/// files. Pinning the scale here means the next radius has to be argued for rather than typed.
///
/// Nothing in this file needs a window, so it runs on both destinations.
final class RadiusScaleTests: XCTestCase {

    private let scales: [(name: String, m: Metrics)] = [("iOS", .iOS), ("mac", .mac)]

    // MARK: - The scale itself

    /// Three steps, strictly ordered, on every density. An out-of-order scale would put a *rounder*
    /// corner on a chip than on the card containing it, which is the specific thing that reads as a
    /// mistake rather than as a style.
    func testScaleIsStrictlyDescendingOnBothDensities() {
        for (name, m) in scales {
            XCTAssertGreaterThan(m.cardRadius, m.controlRadius, "\(name): card must be roundest")
            XCTAssertGreaterThan(m.controlRadius, m.chipRadius, "\(name): control must beat chip")
            XCTAssertGreaterThan(m.chipRadius, 0, "\(name): a chip still has a corner")
        }
    }

    /// The relationship is the point — three numbers with no stated ratio between them is just a
    /// shorter list of magic numbers. Control is ¾ of a card, chip is ½.
    func testStepsHoldTheStatedRatios() {
        for (name, m) in scales {
            XCTAssertEqual(m.controlRadius, m.cardRadius * 0.75, accuracy: 0.0001,
                           "\(name): control is three quarters of a card")
            XCTAssertEqual(m.chipRadius, m.cardRadius * 0.5, accuracy: 0.0001,
                           "\(name): chip is half a card")
        }
    }

    /// Both densities were chosen so every step lands on a whole point. A 13.5 pt radius is not
    /// wrong so much as unintended — it means someone changed `cardRadius` without checking what it
    /// dragged with it, and a half-point corner renders soft on a non-Retina display.
    func testEveryStepIsAWholeNumberOfPoints() {
        for (name, m) in scales {
            for (label, value) in [("card", m.cardRadius), ("control", m.controlRadius),
                                   ("chip", m.chipRadius)] {
                XCTAssertEqual(value, value.rounded(), accuracy: 0.0001,
                               "\(name) \(label) radius \(value) is not a whole point")
            }
        }
    }

    /// The two platforms are one scale at two densities, not two scales. Mac is tighter at every
    /// step, exactly as §8 makes it tighter in type and row height.
    func testMacIsTighterThanIOSAtEveryStep() {
        XCTAssertLessThan(Metrics.mac.cardRadius, Metrics.iOS.cardRadius)
        XCTAssertLessThan(Metrics.mac.controlRadius, Metrics.iOS.controlRadius)
        XCTAssertLessThan(Metrics.mac.chipRadius, Metrics.iOS.chipRadius)
    }

    /// The values themselves, pinned. `controlRadius` in particular is load-bearing: it is what
    /// `MacPrimaryButtonStyle` and `MacSecondaryButtonStyle` draw, so every button in the Mac app
    /// changes shape if this moves.
    func testPinnedValues() {
        XCTAssertEqual(Metrics.mac.cardRadius, 12)
        XCTAssertEqual(Metrics.mac.controlRadius, 9)
        XCTAssertEqual(Metrics.mac.chipRadius, 6)
        XCTAssertEqual(Metrics.iOS.cardRadius, 16)
        XCTAssertEqual(Metrics.iOS.controlRadius, 12)
        XCTAssertEqual(Metrics.iOS.chipRadius, 8)
    }

    /// The scale is derived from one stored number, so a density change cannot leave two of the
    /// three behind. Asserted against a hand-built `Metrics` rather than the two shipped ones,
    /// because that is the case a future edit would create.
    func testAThirdDensityWouldStayConsistent() {
        let m = Metrics(
            body: 14, screenTitle: 24, cardTitle: 15, monoLabel: 10, heroMetric: 30,
            cardRadius: 20, cardPadding: 15, rowHeight: 36, gutter: 22, cardGap: 12,
            controlHeight: 36, primaryControlHeight: 40, minControlHeight: 32, isMac: false
        )
        XCTAssertEqual(m.controlRadius, 15)
        XCTAssertEqual(m.chipRadius, 10)
        XCTAssertGreaterThan(m.cardRadius, m.controlRadius)
        XCTAssertGreaterThan(m.controlRadius, m.chipRadius)
    }

    // MARK: - Concentric nesting

    /// `inner = outer − inset`. Two nested rounded rectangles that share a radius do not look
    /// nested: the inner corner has to turn the same amount inside a smaller box, so it reads as
    /// too round. This is the rule the Files grid tile and all three segmented controls apply.
    func testConcentricSubtractsTheInset() {
        XCTAssertEqual(Metrics.concentric(inside: 12, inset: 9), 3)
        XCTAssertEqual(Metrics.concentric(inside: 9, inset: 2), 7)
        XCTAssertEqual(Metrics.concentric(inside: 16, inset: 4), 12)
    }

    /// A child flush with its parent shares the parent's corner — there is no gap to correct for.
    func testConcentricWithNoInsetIsTheOuterRadius() {
        XCTAssertEqual(Metrics.concentric(inside: 12, inset: 0), 12)
    }

    /// A child inset further than the parent's radius gets a SQUARE corner, not a negative one.
    /// `RoundedRectangle` clamps a negative radius silently, so without the floor this would be a
    /// number that means nothing being passed to something that quietly ignores it.
    func testConcentricFloorsAtSquare() {
        XCTAssertEqual(Metrics.concentric(inside: 12, inset: 14), 0)
        XCTAssertEqual(Metrics.concentric(inside: 12, inset: 999), 0)
    }

    /// The real cases, so a `cardRadius`/`controlRadius` change cannot quietly square off a corner
    /// that is meant to be rounded.
    func testTheConcentricCasesInUseStayRounded() {
        let m = Metrics.mac
        // Files grid: a thumbnail inset 9 pt inside a 12 pt card.
        XCTAssertGreaterThan(Metrics.concentric(inside: m.cardRadius, inset: 9), 0)
        // Segmented controls: a thumb inset 2 pt inside a `controlRadius` track.
        let thumb = Metrics.concentric(inside: m.controlRadius, inset: 2)
        XCTAssertGreaterThan(thumb, 0)
        XCTAssertLessThan(thumb, m.controlRadius)
    }

    // MARK: - Swatches

    /// Colour swatches cannot take a fixed step of the scale: they run 11–30 pt, and one radius
    /// would make the smallest a circle and the largest look square. They scale with their own edge
    /// instead.
    ///
    /// **Every pair below is a value that was hand-typed at a call site before this function
    /// existed**, which is the evidence that the rule was already being followed by eye — and the
    /// proof that hoisting it changed no pixels.
    func testSwatchRadiusReproducesEveryHandTypedValue() {
        let measured: [(CGFloat, CGFloat)] = [
            (11, 3),   // MacJobsSection, the FILE column's table cell
            (12, 3),   // MacViewerWindow, the layer legend's keys
            (13, 4),   // MacPrintSheet, a tray picker row
            (14, 4),   // MacFilesInspector / MacHardwareSection nozzle rows
            (15, 4),   // MacQuickLook's filament strip
            (18, 5),   // MacPrintSheet, a mapping row
            (26, 7),   // MacPrinterSection's AMS strip
            (30, 8),   // MacHardwareSection's slot card
        ]
        for (size, expected) in measured {
            XCTAssertEqual(Metrics.swatchRadius(size), expected, "swatch at \(size) pt")
        }
    }

    /// A bigger swatch never gets a tighter corner. Cheap, and it is the property a future tweak to
    /// the ratio would be most likely to break.
    func testSwatchRadiusNeverDecreasesWithSize() {
        var previous = Metrics.swatchRadius(4)
        for size in stride(from: CGFloat(5), through: 64, by: 1) {
            let r = Metrics.swatchRadius(size)
            XCTAssertGreaterThanOrEqual(r, previous, "swatch radius went backwards at \(size) pt")
            previous = r
        }
    }

    /// A swatch is a rounded square, never a circle: its radius stays under half its edge. At
    /// exactly half it IS a circle, and a circular filament swatch is a different component.
    func testSwatchRadiusStaysUnderACircle() {
        for size in stride(from: CGFloat(8), through: 64, by: 1) {
            XCTAssertLessThan(Metrics.swatchRadius(size), size / 2, "swatch at \(size) pt is a circle")
        }
    }
}
