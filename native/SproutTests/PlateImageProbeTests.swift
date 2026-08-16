import XCTest
@testable import Sprout

/// `PlateImageProbe` decides whether a thumbnail depicts the model or is a flat silhouette, which is
/// what makes every fallback in `LibraryThumb` fire or not fire. Tested on synthetic buffers rather
/// than fixtures: the rule is about tone distribution, so a buffer built in the test states the case
/// far more clearly than a checked-in PNG, and it cannot rot.
final class PlateImageProbeTests: XCTestCase {
    private let side = 32

    /// Build a `side x side` RGBA buffer. `shade` returns nil outside the shape.
    private func buffer(background: (UInt8, UInt8, UInt8) = (0x1a, 0x1a, 0x1a),
                        shade: (Int, Int) -> (UInt8, UInt8, UInt8)?) -> [UInt8] {
        var out = [UInt8](repeating: 0, count: side * side * 4)
        for y in 0..<side {
            for x in 0..<side {
                let px = (y * side + x) * 4
                let (r, g, b) = shade(x, y) ?? background
                out[px] = r; out[px + 1] = g; out[px + 2] = b; out[px + 3] = 255
            }
        }
        return out
    }

    /// True inside a centred disc, the shape both of Bambuddy's renders measured here.
    private func inDisc(_ x: Int, _ y: Int, radius: Double = 12) -> Bool {
        let dx = Double(x) - Double(side) / 2, dy = Double(y) - Double(side) / 2
        return (dx * dx + dy * dy).squareRoot() <= radius
    }

    // MARK: - The blob

    /// The exact case in the field: `#00AE42` fill on `#1a1a1a`, no shading. Bambuddy's
    /// `Poly3DCollection(facecolors=_BAMBU_GREEN)` with `shade=False`.
    func testBambuddysFlatGreenRenderIsASilhouette() {
        let rgba = buffer { x, y in inDisc(x, y) ? (0x00, 0xAE, 0x42) : nil }
        XCTAssertEqual(PlateImageProbe.classify(rgba: rgba, side: side), .flatSilhouette)
    }

    /// The colour is one constant in someone else's repository. `shade=False` is the property that
    /// matters, so the same flat fill in any hue must classify the same way.
    func testASilhouetteIsRecognisedRegardlessOfColour() {
        for fill in [(UInt8(0xFF), UInt8(0x8C), UInt8(0x00)), (0x80, 0x80, 0x80), (0x20, 0x40, 0xFF)] {
            let rgba = buffer { x, y in inDisc(x, y) ? fill : nil }
            XCTAssertEqual(PlateImageProbe.classify(rgba: rgba, side: side), .flatSilhouette,
                           "flat fill \(fill) must read as a silhouette")
        }
    }

    /// A light background, as desktop Studio writes, is still two tones.
    func testASilhouetteOnAWhiteGroundIsStillASilhouette() {
        let rgba = buffer(background: (0xFF, 0xFF, 0xFF)) { x, y in
            inDisc(x, y) ? (0x00, 0xAE, 0x42) : nil
        }
        XCTAssertEqual(PlateImageProbe.classify(rgba: rgba, side: side), .flatSilhouette)
    }

    // MARK: - A real render

    /// The same disc with a Lambert-ish gradient — what a shaded render looks like. This is the case
    /// that must NOT be replaced by a borrowed image.
    func testAShadedRenderIsRecognised() {
        let rgba = buffer { x, y in
            guard inDisc(x, y) else { return nil }
            let t = Double(y) / Double(side)
            let v = UInt8(60 + t * 180)
            return (v / 3, v, v / 2)
        }
        XCTAssertEqual(PlateImageProbe.classify(rgba: rgba, side: side), .shaded)
    }

    /// A near-monochrome render still has many tones. The verdict must come from variance, not hue —
    /// the real `cr.3mf` thumbnail measured here is a white/grey spiky ball.
    func testANearMonochromeRenderIsShaded() {
        let rgba = buffer(background: (0xFF, 0xFF, 0xFF)) { x, y in
            guard inDisc(x, y) else { return nil }
            let v = UInt8(90 + ((x * 7 + y * 11) % 140))
            return (v, v, v)
        }
        XCTAssertEqual(PlateImageProbe.classify(rgba: rgba, side: side), .shaded)
    }

    /// A photographic field is obviously shaded; this guards the noise floor from swallowing detail.
    func testANoisyImageIsShaded() {
        var seed = 12345
        let rgba = buffer { _, _ in
            seed = (seed &* 1103515245 &+ 12345) & 0x7FFFFFFF
            let v = UInt8(seed % 256)
            return (v, UInt8((seed >> 8) % 256), UInt8((seed >> 16) % 256))
        }
        XCTAssertEqual(PlateImageProbe.classify(rgba: rgba, side: side), .shaded)
    }

    // MARK: - Degenerate input

    /// A blank tile, or a snapshot taken before anything drew.
    func testASingleColourIsUniform() {
        let rgba = buffer { _, _ in (0x1a, 0x1a, 0x1a) }
        XCTAssertEqual(PlateImageProbe.classify(rgba: rgba, side: side), .uniform)
    }

    func testAnEmptyBufferIsUnreadable() {
        XCTAssertEqual(PlateImageProbe.classify(rgba: [], side: side), .unreadable)
    }

    func testAShortBufferIsUnreadable() {
        XCTAssertEqual(PlateImageProbe.classify(rgba: [UInt8](repeating: 0, count: 16), side: side),
                       .unreadable)
    }

    func testAZeroSideIsUnreadable() {
        XCTAssertEqual(PlateImageProbe.classify(rgba: [0, 0, 0, 255], side: 0), .unreadable)
    }

    /// Fully transparent pixels carry no colour to count. An all-alpha-zero image must not be read as
    /// a confident silhouette of nothing.
    func testAFullyTransparentImageIsUnreadable() {
        let rgba = [UInt8](repeating: 0, count: side * side * 4)
        XCTAssertEqual(PlateImageProbe.classify(rgba: rgba, side: side), .unreadable)
    }

    /// A PNG with an alpha ground: only the drawn pixels count, and a flat fill on transparency is
    /// one opaque tone — uniform, not shaded. It must never read as a render.
    func testAFlatFillOnTransparencyIsNotShaded() {
        var rgba = [UInt8](repeating: 0, count: side * side * 4)
        for y in 0..<side where true {
            for x in 0..<side where inDisc(x, y) {
                let px = (y * side + x) * 4
                rgba[px] = 0x00; rgba[px + 1] = 0xAE; rgba[px + 2] = 0x42; rgba[px + 3] = 255
            }
        }
        XCTAssertNotEqual(PlateImageProbe.classify(rgba: rgba, side: side), .shaded)
    }

    // MARK: - The boundary

    /// Antialiasing along a silhouette's edge introduces blended tones. They must stay below the
    /// noise floor, or every silhouette reads as a render and the fallback never fires.
    func testAnAntialiasedSilhouetteIsStillASilhouette() {
        let rgba = buffer { x, y in
            let dx = Double(x) - 16, dy = Double(y) - 16
            let d = (dx * dx + dy * dy).squareRoot()
            if d <= 11.5 { return (0x00, 0xAE, 0x42) }
            // A one-pixel blended rim.
            if d <= 12.5 { return (0x0D, 0x64, 0x30) }
            return nil
        }
        XCTAssertEqual(PlateImageProbe.classify(rgba: rgba, side: side), .flatSilhouette)
    }

    /// Three substantial tones is a render, not a silhouette — the smallest case that must come back
    /// `.shaded`, and the other side of the boundary above.
    func testThreeSubstantialTonesIsShaded() {
        let rgba = buffer { x, y in
            guard inDisc(x, y) else { return nil }
            if y < 12 { return (0x00, 0xAE, 0x42) }
            if y < 20 { return (0x00, 0x70, 0x2C) }
            return (0x00, 0x40, 0x18)
        }
        XCTAssertEqual(PlateImageProbe.classify(rgba: rgba, side: side), .shaded)
    }

    /// `depictsModel` is what the view branches on; only a real render qualifies.
    func testOnlyShadedDepictsTheModel() {
        XCTAssertTrue(PlateImageProbe.Verdict.shaded.depictsModel)
        XCTAssertFalse(PlateImageProbe.Verdict.flatSilhouette.depictsModel)
        XCTAssertFalse(PlateImageProbe.Verdict.uniform.depictsModel)
        XCTAssertFalse(PlateImageProbe.Verdict.unreadable.depictsModel)
    }
}
