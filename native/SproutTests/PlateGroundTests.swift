import XCTest
@testable import Sprout

/// Which ground goes behind a transparent plate image.
///
/// The bug this encodes: the Bambu Cloud cover is a transparent PNG of the model in its own filament
/// colour, the Dynamic Island's background is black and not ours to set, and a print in near-black
/// PETG therefore arrived as a black model on a black island. Measured on the real job — mean
/// luminance 0.0179, contrast against black 1.36:1.
final class PlateGroundTests: XCTestCase {

    /// A `side`×`side` premultiplied-last RGBA buffer: `coverage` of the pixels carry `colour`, the
    /// rest are fully transparent.
    private func buffer(side: Int = 64, colour: (UInt8, UInt8, UInt8), coverage: Double) -> [UInt8] {
        var px = [UInt8](repeating: 0, count: side * side * 4)
        let opaque = Int(Double(side * side) * coverage)
        for i in 0..<opaque {
            px[i * 4] = colour.0
            px[i * 4 + 1] = colour.1
            px[i * 4 + 2] = colour.2
            px[i * 4 + 3] = 255
        }
        return px
    }

    // MARK: - Which ground

    /// The measured case. `#161616` PETG, 8% of the canvas — exactly the print that reported this.
    func testANearBlackModelGetsThePorcelainGround() {
        let px = buffer(colour: (0x16, 0x16, 0x16), coverage: 0.08)
        XCTAssertEqual(PlateGround.choose(rgba: px, side: 64), .porcelain)
    }

    /// The mirror case, and the reason a fixed light ground would not do: white filament on
    /// porcelain is the same invisibility one step round.
    func testANearWhiteModelGetsTheGraphiteGround() {
        let px = buffer(colour: (0xF2, 0xF3, 0xF5), coverage: 0.08)
        XCTAssertEqual(PlateGround.choose(rgba: px, side: 64), .graphite)
    }

    func testASaturatedModelStillGetsTheBetterOfTheTwo() {
        // Bambu green, luminance ~0.28 — brighter than the tipping point, so graphite wins.
        XCTAssertEqual(PlateGround.choose(rgba: buffer(colour: (0x00, 0xAE, 0x42), coverage: 0.2), side: 64),
                       .graphite)
        // Deep blue, well below it.
        XCTAssertEqual(PlateGround.choose(rgba: buffer(colour: (0x1B, 0x26, 0x3E), coverage: 0.2), side: 64),
                       .porcelain)
    }

    // MARK: - When to leave the image alone

    /// Bambuddy's own renders are opaque and carry their own ground. Compositing behind them would
    /// be a no-op at best, and the question asked here is "is this transparent?", never "did this
    /// come from the cloud?".
    func testAFullyOpaqueImageIsLeftAlone() {
        var px = buffer(colour: (0xE9, 0xEC, 0xF0), coverage: 1.0)
        px[3] = 255
        XCTAssertNil(PlateGround.choose(rgba: px, side: 64))
    }

    /// Too few opaque samples and the mean describes where the point-sampler landed, not the model.
    func testAnAlmostEmptyImageIsLeftAlone() {
        let px = buffer(colour: (0x16, 0x16, 0x16), coverage: 0.001)   // 4 pixels of 4096
        XCTAssertNil(PlateGround.choose(rgba: px, side: 64))
    }

    func testAShortBufferIsLeftAlone() {
        XCTAssertNil(PlateGround.choose(rgba: [0, 0, 0, 255], side: 64))
        XCTAssertNil(PlateGround.choose(rgba: [], side: 0))
    }

    /// A rim of near-zero alpha carries a colour blended with nothing. Counting it would drag the
    /// mean toward whatever the encoder left in the RGB of transparent pixels.
    func testTheAntialiasedRimDoesNotCount() {
        var px = buffer(colour: (0x16, 0x16, 0x16), coverage: 0.08)
        // A band of white at alpha 4 — below the floor, so it must not lighten the verdict.
        for i in 3000..<4096 {
            px[i * 4] = 255; px[i * 4 + 1] = 255; px[i * 4 + 2] = 255; px[i * 4 + 3] = 4
        }
        XCTAssertEqual(PlateGround.choose(rgba: px, side: 64), .porcelain)
    }

    // MARK: - The property that makes two grounds enough

    /// The two ratios cross at a model luminance of 0.203, where both give 3.40:1. So the worst case
    /// this rule can produce still clears the 3:1 a graphical object needs — there is no filament
    /// colour for which choosing between these two does nothing.
    func testTheWorstCaseStillClearsThreeToOne() {
        let crossing = 0.203
        let viaPorcelain = PlateGround.contrast(crossing, PlateGround.Ground.porcelain.luminance)
        let viaGraphite = PlateGround.contrast(crossing, PlateGround.Ground.graphite.luminance)
        XCTAssertEqual(viaPorcelain, viaGraphite, accuracy: 0.05)
        XCTAssertGreaterThan(max(viaPorcelain, viaGraphite), 3.0)
    }

    /// The numbers the report was built on, pinned so the fix cannot be quietly undone: the model
    /// this started with sits at 0.0179, which is 1.36:1 against the island's black and 12.68:1
    /// against porcelain.
    func testTheMeasuredJobsNumbers() {
        let model = 0.0179
        XCTAssertEqual(PlateGround.contrast(model, 0.0), 1.36, accuracy: 0.01)
        XCTAssertEqual(PlateGround.contrast(model, PlateGround.Ground.porcelain.luminance), 12.68, accuracy: 0.02)
        XCTAssertLessThan(PlateGround.contrast(model, PlateGround.Ground.graphite.luminance), 1.2)
    }
}
