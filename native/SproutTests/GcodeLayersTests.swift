import XCTest
import Foundation
@testable import Sprout

// The domain sources are compiled into this bundle (see project.yml), so there is nothing to import.

final class GcodeLayersTests: XCTestCase {

    private func parse(_ lines: [String]) -> GcodeParseResult {
        GcodeLayers.parse(lines.joined(separator: "\n"))
    }

    /// One extruding move whose X parameter is `token`, starting from (100, 100). Returns the layer
    /// it produced, so a test can read back exactly what the number scanner made of `token`.
    private func segment(forX token: String) -> [Float] {
        parse(["G90", "G1 Z0.2", "G1 X100 Y100 E0", "G1 X\(token) Y100 E1"]).layers.first ?? []
    }

    // MARK: - layers and segments

    func testSplitsLayersAtExtrusionZChangesAndRecordsSegments() {
        let p = parse([
            "G90", "G1 Z0.2", "G1 X0 Y0 E0", "G1 X10 Y0 E1", "G1 X10 Y10 E2",
            "G1 Z0.4", "G1 X0 Y0 E2.5", "G1 X10 Y0 E3",
        ])
        XCTAssertEqual(p.layers.count, 2)
        XCTAssertEqual(p.layers[0], [0, 0, 10, 0, 10, 0, 10, 10])
        XCTAssertEqual(p.zs, [0.2, 0.4])
        XCTAssertEqual(p.bounds, GcodeBounds(minX: 0, minY: 0, maxX: 10, maxY: 10, minZ: 0.2, maxZ: 0.4))
    }

    func testIgnoresTravelMoves() {
        let p = parse(["G90", "G1 Z0.2", "G1 X0 Y0", "G0 X5 Y5", "G1 X10 Y10 E1"])
        XCTAssertEqual(p.layers.count, 1)
        XCTAssertEqual(p.layers[0], [5, 5, 10, 10])
    }

    func testDoesNotCreateASpuriousLayerForATravelZHop() {
        let p = parse([
            "G90", "G1 Z0.2", "G1 X0 Y0 E0", "G1 X10 Y0 E1",
            "G1 Z1.0", "G0 X0 Y0", "G1 Z0.2", "G1 X0 Y10 E2",
        ])
        XCTAssertEqual(p.layers.count, 1)
    }

    func testHandlesRelativeExtrusionAndG92Resets() {
        let rel = parse(["G90", "M83", "G1 Z0.2", "G1 X0 Y0 E0", "G1 X10 Y0 E0.5", "G1 X10 Y10 E0.5"])
        XCTAssertEqual(rel.layers[0].count, 8)

        let g92 = parse(["G90", "G1 Z0.2", "G1 X0 Y0 E5", "G92 E0", "G1 X10 Y0 E0.1"])
        XCTAssertEqual(g92.layers[0], [0, 0, 10, 0])
    }

    func testStripsCommentsAndBlankLines() {
        let p = parse(["; header", "G90 ; absolute", "", "G1 Z0.2", "G1 X0 Y0 E0", "G1 X4 Y0 E1 ; wall"])
        XCTAssertEqual(p.layers[0], [0, 0, 4, 0])
    }

    func testHandlesAFinalLineWithNoTrailingNewline() {
        let p = GcodeLayers.parse("G90\nG1 X0 Y0 Z0.2 E0\nG1 X5 Y0 E1")
        XCTAssertEqual(p.layers[0], [0, 0, 5, 0])
    }

    func testReturnsEmptyLayersAndDefaultBoundsForNonPrintInput() {
        let p = GcodeLayers.parse("; just comments\nM104 S200\n")
        XCTAssertTrue(p.layers.isEmpty)
        XCTAssertEqual(p.bounds, GcodeBounds(minX: 0, minY: 0, maxX: 256, maxY: 256, minZ: 0, maxZ: 1))
    }

    func testEmitsFlatFloatRunsAndASegmentCount() {
        let p = parse(["G90", "G1 Z0.2", "G1 X0 Y0 E0", "G1 X10 Y0 E1", "G1 X10 Y10 E2"])
        let run: [Float] = p.layers[0]
        XCTAssertEqual(run.count, 8)
        XCTAssertEqual(p.segTotal, 2)
    }

    func testGrowsPastItsInitialBufferWithoutLosingOrReorderingSegments() {
        // The buffer starts at 4096 floats (1024 segments); 3000 segments forces two doublings.
        var lines = ["G90", "G1 Z0.2", "G1 X0 Y0 E0"]
        for i in 1...3000 { lines.append("G1 X\(i) Y0 E\(i)") }
        let p = parse(lines)
        XCTAssertEqual(p.segTotal, 3000)
        let run = p.layers[0]
        XCTAssertEqual(Array(run.prefix(4)), [0, 0, 1, 0])
        XCTAssertEqual(Array(run.suffix(4)), [2999, 0, 3000, 0])
    }

    /// The flat layout is the GPU upload format: four floats per segment, no index buffer, and
    /// `segTotal` is the instance count drawn from it.
    func testFlatLayoutIsFourFloatsPerSegment() {
        let p = parse(["G90", "G1 Z0.2", "G1 X0 Y0 E0", "G1 X10 Y0 E1", "G1 X10 Y10 E2", "G1 X0 Y10 E3"])
        for run in p.layers { XCTAssertEqual(run.count % 4, 0) }
        XCTAssertEqual(p.layers.reduce(0) { $0 + $1.count / 4 }, p.segTotal)
        XCTAssertEqual(p.segTotal, 3)
    }

    /// There is no segment budget and no decimation: every segment in the file comes back.
    func testParsesFarPastAnyBudgetWithoutDecimating() {
        var lines = ["G90", "G1 Z0.2", "G1 X0 Y0 E0"]
        for i in 1...20_000 { lines.append("G1 X\(i) Y0 E\(i)") }
        let p = parse(lines)
        XCTAssertEqual(p.segTotal, 20_000)
        XCTAssertEqual(p.layers.count, 1)
        XCTAssertEqual(Array(p.layers[0].suffix(4)), [19_999, 0, 20_000, 0])
    }

    // MARK: - supports

    func testSeparatesSupportToolpathAndFlagsIt() {
        let p = parse([
            "G90", "; enable_support = 1", "G1 Z0.2", "G1 X0 Y0 E0",
            "; FEATURE: Outer wall", "G1 X10 Y0 E1",
            "; FEATURE: Support", "G1 X0 Y5 E2", "G1 X10 Y5 E3",
            "; FEATURE: Inner wall", "G1 X10 Y10 E4",
        ])
        XCTAssertEqual(p.layers[0], [0, 0, 10, 0, 10, 5, 10, 10])
        XCTAssertEqual(p.sup[0], [10, 0, 0, 5, 0, 5, 10, 5])
        XCTAssertTrue(p.hasSupport)
        XCTAssertTrue(p.supportEnabled)
    }

    func testReportsNoSupportsWhenNoneArePresent() {
        let p = parse(["G90", "; enable_support = 0", "G1 Z0.2", "; FEATURE: Outer wall", "G1 X0 Y0 E0", "G1 X5 Y0 E1"])
        XCTAssertFalse(p.hasSupport)
        XCTAssertFalse(p.supportEnabled)
    }

    /// What the app reports once a file is ready: layer count, support presence, total segments.
    func testReportsLayerCountSupportPresenceAndSegmentTotals() {
        let p = parse([
            "G90", "G1 Z0.2", "G1 X0 Y0 E0", "G1 X10 Y0 E1",
            "; FEATURE: Support", "G1 X10 Y5 E2",
            "; FEATURE: Solid infill", "G1 Z0.4", "G1 X0 Y5 E3",
        ])
        XCTAssertEqual(p.layers.count, 2)
        XCTAssertEqual(p.zs.count, p.layers.count)
        XCTAssertEqual(p.sup.count, p.layers.count)
        XCTAssertTrue(p.hasSupport)
        XCTAssertEqual(p.segTotal, 2)
        XCTAssertEqual(p.supTotal, 1)
    }

    func testFeatureMatchingIsCaseInsensitiveAndMatchesAnySupportFeature() {
        let p = parse([
            "G90", "G1 Z0.2", "G1 X0 Y0 E0",
            "; feature: SUPPORT INTERFACE", "G1 X10 Y0 E1",
            "; FEATURE: Overhang wall", "G1 X10 Y10 E2",
        ])
        XCTAssertEqual(p.sup[0], [0, 0, 10, 0])
        XCTAssertEqual(p.layers[0], [10, 0, 10, 10])
    }

    func testFeatureWithNoNameLeavesTheClassificationUnchanged() {
        let p = parse([
            "G90", "G1 Z0.2", "G1 X0 Y0 E0",
            "; FEATURE: Support", "G1 X10 Y0 E1",
            "; FEATURE:", "G1 X10 Y10 E2",
        ])
        XCTAssertEqual(p.sup[0], [0, 0, 10, 0, 10, 0, 10, 10])
        XCTAssertTrue(p.layers[0].isEmpty)
    }

    func testEnableSupportNeedsAWordBoundaryButNotWhitespace() {
        XCTAssertTrue(GcodeLayers.parse("; enable_support=1\n").supportEnabled)
        XCTAssertTrue(GcodeLayers.parse(";   enable_support   =   1\n").supportEnabled)
        // A different setting that merely ends with the same word must not flip it.
        XCTAssertFalse(GcodeLayers.parse("; tree_enable_support = 1\n").supportEnabled)
        // ...nor one that merely starts with it.
        XCTAssertFalse(GcodeLayers.parse("; enable_supports = 1\n").supportEnabled)
    }

    func testMultiByteCommentTextDoesNotBreakScanning() {
        let p = parse(["G90", "G1 Z0.2", "G1 X0 Y0 E0", "; FEATURE: Support ✓", "G1 X10 Y0 E1"])
        XCTAssertEqual(p.sup[0], [0, 0, 10, 0])
        // Bytes >= 0x80 are non-word, so they satisfy the boundary in front of the setting.
        XCTAssertTrue(GcodeLayers.parse("; 日本語enable_support = 1\n").supportEnabled)
    }

    // MARK: - bounds

    func testExcludesTheElevatedPurgeLayerFromBoundsButStillRendersIt() {
        let p = parse([
            "M83",
            "G1 X280 Y0 Z5.8 F3000", "G1 X290 Y0 E5",
            "G1 X10 Y10 Z0.2 F3000", "G1 X20 Y10 E1", "G1 X20 Y20 E1",
            "G1 X10 Y10 Z0.4 F3000", "G1 X20 Y10 E1",
        ])
        XCTAssertEqual(p.layers.count, 3)   // the purge layer is still drawn
        XCTAssertEqual(p.bounds.minZ, 0.2)  // NOT 5.8
        XCTAssertEqual(p.bounds.maxX, 20)   // the purge line does not skew the fit
    }

    // MARK: - scanner edge cases

    func testHandlesCRLFLineEndings() {
        let p = GcodeLayers.parse("G90\r\nG1 Z0.2\r\nG1 X0 Y0 E0\r\nG1 X10 Y0 E1\r\n")
        XCTAssertEqual(p.layers[0], [0, 0, 10, 0])
    }

    func testHandlesEmptyAndWhitespaceOnlyInput() {
        for text in ["", "\n", "   \n\t\r\n", ";\n"] {
            let p = GcodeLayers.parse(text)
            XCTAssertTrue(p.layers.isEmpty, "expected no layers for \(text.debugDescription)")
            XCTAssertTrue(p.zs.isEmpty)
            XCTAssertEqual(p.segTotal, 0)
            XCTAssertEqual(p.bounds, GcodeBounds(minX: 0, minY: 0, maxX: 256, maxY: 256, minZ: 0, maxZ: 1))
        }
        XCTAssertTrue(GcodeLayers.parse(Data()).layers.isEmpty)
    }

    func testReadsTheNumericPrefixOfAParameter() {
        XCTAssertEqual(segment(forX: "10"), [100, 100, 10, 100])
        XCTAssertEqual(segment(forX: "10.5mm"), [100, 100, 10.5, 100])   // trailing junk is ignored
        XCTAssertEqual(segment(forX: "1e1"), [100, 100, 10, 100])
        XCTAssertEqual(segment(forX: ".5"), [100, 100, 0.5, 100])
        XCTAssertEqual(segment(forX: "5."), [100, 100, 5, 100])
        XCTAssertEqual(segment(forX: "1e"), [100, 100, 1, 100])          // incomplete exponent drops
        XCTAssertEqual(segment(forX: "-7"), [100, 100, -7, 100])
        XCTAssertEqual(segment(forX: "+7"), [100, 100, 7, 100])
        XCTAssertEqual(segment(forX: "0x10"), [100, 100, 0, 100])        // stops at 'x', hex is not a number
    }

    /// The scanner reads digits itself, so a comma is junk rather than a decimal separator no matter
    /// what locale the device is set to.
    func testDecimalParsingIsLocaleIndependent() {
        XCTAssertEqual(segment(forX: "1,5"), [100, 100, 1, 100])
        XCTAssertEqual(segment(forX: "1.5"), [100, 100, 1.5, 100])
    }

    func testAParameterWithNoNumberProducesNoGeometry() {
        XCTAssertTrue(segment(forX: "").isEmpty)
        XCTAssertTrue(segment(forX: "abc").isEmpty)
    }

    func testLongDigitRunsDoNotOverflow() {
        let big = segment(forX: "1" + String(repeating: "0", count: 24))
        XCTAssertEqual(Double(big[2]), 1e24, accuracy: 1e19)

        // Beyond Float's range this saturates to infinity rather than trapping.
        let huge = segment(forX: String(repeating: "9", count: 40))
        XCTAssertTrue(huge[2].isInfinite)
    }

    func testCoordinatesAreStoredAtFloat32Precision() {
        let run = segment(forX: "0.1")
        XCTAssertEqual(run[2], Float(0.1))
    }

    func testCommandMatchingIsCaseSensitive() {
        // Lower-case commands are not what any slicer emits; treating them as commands would let a
        // stray word in a stripped comment move the toolhead.
        XCTAssertTrue(parse(["g90", "g1 Z0.2", "g1 X0 Y0 E0", "g1 X10 Y0 E1"]).layers.isEmpty)
    }

    func testDataAndStringEntryPointsAgree() {
        let text = ["G90", "G1 Z0.2", "G1 X0 Y0 E0", "G1 X10 Y0 E1", "G1 Z0.4", "G1 X10 Y10 E2"].joined(separator: "\n")
        let fromString = GcodeLayers.parse(text)
        let fromData = GcodeLayers.parse(Data(text.utf8))
        XCTAssertEqual(fromString.layers, fromData.layers)
        XCTAssertEqual(fromString.zs, fromData.zs)
        XCTAssertEqual(fromString.bounds, fromData.bounds)
    }

    // MARK: - plate and scene

    func testPlateDefaultsTo256x256AndCarriesACustomFootprint() {
        XCTAssertEqual(GcodePlate.default, GcodePlate(w: 256, d: 256))
        let custom = GcodePlate(w: 350, d: 320)
        let scene = GcodeScene(bounds: GcodeBounds(minX: 0, minY: 0, maxX: 10, maxY: 10, minZ: 0, maxZ: 5), zs: [0.2], plate: custom)
        XCTAssertEqual(scene.plate, custom)
    }

    func testPlateGrowsInFiftyMillimetreStepsToCoverStrayToolpaths() {
        let bounds = GcodeBounds(minX: 0, minY: 0, maxX: 310, maxY: 12, minZ: 0, maxZ: 5)
        XCTAssertEqual(GcodePlate.default.fitted(to: bounds), GcodePlate(w: 350, d: 256))
    }

    func testPivotSitsAtTheFootprintCentreAndFortyPercentOfTheHeight() {
        let scene = GcodeScene(bounds: GcodeBounds(minX: 10, minY: 20, maxX: 30, maxY: 60, minZ: 0, maxZ: 100), zs: [0.2, 0.4])
        XCTAssertEqual(scene.pivotX, 20)
        XCTAssertEqual(scene.pivotY, 40)
        XCTAssertEqual(scene.pivotZ, 40)
    }

    func testDegenerateModelKeepsANonZeroRadiusAndSpan() {
        let flat = GcodeBounds(minX: 5, minY: 5, maxX: 5, maxY: 5, minZ: 0.2, maxZ: 0.2)
        let scene = GcodeScene(bounds: flat, zs: [0.2])
        XCTAssertEqual(scene.zSpan, 1)
        XCTAssertGreaterThan(scene.radius, 0)
    }

    func testHighlightToleranceTracksTheSmallestLayerStep() {
        let bounds = GcodeBounds(minX: 0, minY: 0, maxX: 10, maxY: 10, minZ: 0.2, maxZ: 0.48)
        let scene = GcodeScene(bounds: bounds, zs: [0.2, 0.4, 0.48])
        XCTAssertEqual(scene.minLayerGap, 0.08, accuracy: 1e-9)
        XCTAssertEqual(scene.highlightEpsilon, 0.036, accuracy: 1e-9)

        // A single layer (or none) has nothing to measure, so a plain 0.2 mm layer is assumed.
        XCTAssertEqual(GcodeScene(bounds: bounds, zs: [0.2]).minLayerGap, 0.2)
        XCTAssertEqual(GcodeScene(bounds: bounds, zs: []).minLayerGap, 0.2)
    }

    func testOrbitStaysAboveTheHorizonAndZoomStaysInRange() {
        XCTAssertEqual(GcodeScene.clampPitch(-3), GcodeScene.minPitch)
        XCTAssertEqual(GcodeScene.clampPitch(9), GcodeScene.maxPitch)
        XCTAssertEqual(GcodeScene.clampPitch(GcodeScene.defaultPitch), GcodeScene.defaultPitch)
        XCTAssertEqual(GcodeScene.clampZoom(0), GcodeScene.minZoom)
        XCTAssertEqual(GcodeScene.clampZoom(100), GcodeScene.maxZoom)
    }
}
