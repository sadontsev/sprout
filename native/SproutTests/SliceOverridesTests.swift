import XCTest
@testable import Sprout

final class SliceOverridesTests: XCTestCase {

    private let base = "0.20mm Standard @BBL H2C"
    private let presetName = "Sprout Custom @BBL H2C"

    /// Unwraps a string-valued preset key, so assertions read as the JSON the slicer will see.
    private func str(_ d: [String: JSONValue], _ key: String) -> String? {
        guard case .string(let v)? = d[key] else { return nil }
        return v
    }

    // MARK: - Nothing to override

    func testNoOverridesProducesNoDeltaAndSoNoPresetChurn() {
        let none = SliceOverrides()
        XCTAssertNil(none.processDelta(inheriting: base, presetName: presetName))
        XCTAssertNil(none.filamentDelta(inheriting: "Bambu PLA Basic @BBL H2C", presetName: presetName))
        XCTAssertFalse(none.hasProcessOverrides)
        // A filament key is not a process override.
        XCTAssertFalse(SliceOverrides(flowRatio: 1).hasProcessOverrides)
        XCTAssertTrue(SliceOverrides(flowRatio: 1).hasFilamentOverrides)
    }

    // MARK: - Process delta

    func testDeltaCarriesOnlyTheChangedKeysOnTopOfTheInheritsEnvelope() {
        let s = SliceOverrides(wallLoops: 4, infillDensity: 15)
            .processDelta(inheriting: base, presetName: presetName)
        let expected: [String: JSONValue] = [
            "type": .string("process"),
            "name": .string(presetName),
            "from": .string("User"),
            "inherits": .string(base),
            "wall_loops": .string("4"),
            "sparse_infill_density": .string("15%"),
        ]
        XCTAssertEqual(s, expected)
    }

    func testBooleansSerializeAsOneOrZeroAndEnumsPassThrough() {
        let o = SliceOverrides(
            infillPattern: "gyroid",
            topPattern: "monotonic",
            primeTower: true,
            support: false,
            supportType: "tree(auto)",
            supportStyle: "snug"
        )
        guard let s = o.processDelta(inheriting: base, presetName: presetName) else {
            return XCTFail("expected a delta")
        }
        XCTAssertEqual(str(s, "enable_prime_tower"), "1")
        XCTAssertEqual(str(s, "enable_support"), "0")
        XCTAssertEqual(str(s, "support_type"), "tree(auto)")
        XCTAssertEqual(str(s, "support_style"), "snug")
        XCTAssertEqual(str(s, "sparse_infill_pattern"), "gyroid")
        XCTAssertEqual(str(s, "top_surface_pattern"), "monotonic")
    }

    func testValuesAreClampedToSlicerLegalRanges() {
        let o = SliceOverrides(
            wallLoops: -2,
            infillDensity: 250,
            primeTowerWidth: 0.5,
            supportAngle: 120
        )
        guard let s = o.processDelta(inheriting: base, presetName: presetName) else {
            return XCTFail("expected a delta")
        }
        XCTAssertEqual(str(s, "wall_loops"), "0")
        XCTAssertEqual(str(s, "sparse_infill_density"), "100%")
        XCTAssertEqual(str(s, "support_threshold_angle"), "90")
        XCTAssertEqual(str(s, "prime_tower_width"), "2")
    }

    func testFractionalInputsAreRoundedForIntegerKeysButNotForMillimetres() {
        let o = SliceOverrides(wallLoops: 3.6, infillDensity: 14.5, primeTowerWidth: 35.5, supportAngle: 44.4)
        guard let s = o.processDelta(inheriting: base, presetName: presetName) else {
            return XCTFail("expected a delta")
        }
        XCTAssertEqual(str(s, "wall_loops"), "4")
        XCTAssertEqual(str(s, "sparse_infill_density"), "15%")
        XCTAssertEqual(str(s, "support_threshold_angle"), "44")
        // A width is a real millimetre value, so it keeps its fraction.
        XCTAssertEqual(str(s, "prime_tower_width"), "35.5")
    }

    func testIntegralValuesNeverSerializeWithATrailingPointZero() {
        // The slicer compares preset values as text: "2.0" is not the same token as "2".
        let s = SliceOverrides(primeTowerWidth: 60).processDelta(inheriting: base, presetName: presetName)
        XCTAssertEqual(str(s ?? [:], "prime_tower_width"), "60")
    }

    func testExtremeNumbersClampInsteadOfTrappingOnIntConversion() {
        // A numeric text field can hand us anything; `Int(_:)` on an out-of-range Double is a crash.
        let o = SliceOverrides(
            wallLoops: 1e30,
            infillDensity: -.infinity,
            primeTowerWidth: -1e30,
            supportAngle: .nan
        )
        guard let s = o.processDelta(inheriting: base, presetName: presetName) else {
            return XCTFail("expected a delta")
        }
        XCTAssertEqual(str(s, "wall_loops"), String(Int.max))
        XCTAssertEqual(str(s, "sparse_infill_density"), "0%")
        XCTAssertEqual(str(s, "prime_tower_width"), "2")
        XCTAssertEqual(str(s, "support_threshold_angle"), "1")
    }

    func testASingleProcessKeyIsEnoughToProduceADelta() {
        for o in [
            SliceOverrides(wallLoops: 2),
            SliceOverrides(infillPattern: "grid"),
            SliceOverrides(topPattern: "concentric"),
            SliceOverrides(primeTower: false),
            SliceOverrides(primeTowerWidth: 40),
            SliceOverrides(support: true),
            SliceOverrides(supportType: "normal(auto)"),
            SliceOverrides(supportStyle: "tree_organic"),
            SliceOverrides(supportAngle: 30),
            SliceOverrides(infillDensity: 20),
        ] {
            XCTAssertTrue(o.hasProcessOverrides)
            XCTAssertNotNil(o.processDelta(inheriting: base, presetName: presetName))
        }
    }

    // MARK: - Filament delta

    func testFilamentDeltaReplicatesFlowAcrossTheVariantArrayAndClamps() {
        let f = SliceOverrides(flowRatio: 0.95)
            .filamentDelta(inheriting: "Bambu PLA Basic @BBL H2C", presetName: presetName, variants: 3)
        XCTAssertEqual(
            f?["filament_flow_ratio"],
            JSONValue.array([.string("0.95"), .string("0.95"), .string("0.95")])
        )
        XCTAssertEqual(str(f ?? [:], "inherits"), "Bambu PLA Basic @BBL H2C")
        XCTAssertEqual(str(f ?? [:], "type"), "filament")
        XCTAssertEqual(str(f ?? [:], "from"), "User")

        let hi = SliceOverrides(flowRatio: 9).filamentDelta(inheriting: "x", presetName: presetName, variants: 1)
        XCTAssertEqual(hi?["filament_flow_ratio"], JSONValue.array([.string("2")]))

        let lo = SliceOverrides(flowRatio: 0).filamentDelta(inheriting: "x", presetName: presetName, variants: 1)
        XCTAssertEqual(lo?["filament_flow_ratio"], JSONValue.array([.string("0.5")]))
    }

    func testFilamentDeltaAlwaysEmitsAtLeastOneVariantSlot() {
        // A machine that reports 0 (or a nonsense negative) extruder variants must still get a
        // usable array, not an empty one the slicer would reject.
        let f = SliceOverrides(flowRatio: 1.02)
            .filamentDelta(inheriting: "x", presetName: presetName, variants: 0)
        XCTAssertEqual(f?["filament_flow_ratio"], JSONValue.array([.string("1.02")]))
    }

    func testFilamentDeltaDefaultsToTheThreeVariantH2SeriesShape() {
        let f = SliceOverrides(flowRatio: 1).filamentDelta(inheriting: "x", presetName: presetName)
        XCTAssertEqual(f?["filament_flow_ratio"], JSONValue.array([.string("1"), .string("1"), .string("1")]))
    }

    // MARK: - Badge count

    func testOverrideCountDrivesTheBadge() {
        XCTAssertEqual(SliceOverrides().overrideCount, 0)
        XCTAssertEqual(SliceOverrides(wallLoops: 3, flowRatio: 1.02).overrideCount, 2)
        XCTAssertEqual(
            SliceOverrides(
                wallLoops: 3, infillDensity: 20, infillPattern: "grid", topPattern: "monotonic",
                primeTower: true, primeTowerWidth: 40, support: true, supportType: "tree(auto)",
                supportStyle: "snug", supportAngle: 30, flowRatio: 1
            ).overrideCount,
            11
        )
    }

    // MARK: - Serialization

    func testDeltaKeysSurviveTheProjectsSnakeCaseEncoder() throws {
        // The shared encoder converts camelCase keys to snake_case; these keys are already
        // snake_case and must pass through untouched.
        guard let s = SliceOverrides(wallLoops: 4, infillDensity: 15, supportAngle: 30)
            .processDelta(inheriting: base, presetName: presetName) else {
            return XCTFail("expected a delta")
        }
        let encoder = JSONEncoder()
        encoder.keyEncodingStrategy = .convertToSnakeCase
        let data = try encoder.encode(s)
        let round = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        XCTAssertEqual(round?["wall_loops"] as? String, "4")
        XCTAssertEqual(round?["sparse_infill_density"] as? String, "15%")
        XCTAssertEqual(round?["support_threshold_angle"] as? String, "30")
        XCTAssertEqual(round?["inherits"] as? String, base)
    }

    // MARK: - Pickable values

    func testPickableValueListsMatchTheSlicerVocabulary() {
        XCTAssertEqual(SliceOverrides.infillPatterns, [
            "grid", "gyroid", "cubic", "triangles", "honeycomb", "lightning", "adaptivecubic", "crosshatch",
        ])
        XCTAssertEqual(SliceOverrides.topPatterns, ["monotonic", "monotonicline", "concentric", "alignedrectilinear"])
        XCTAssertEqual(SliceOverrides.supportTypes, ["tree(auto)", "normal(auto)"])
        XCTAssertEqual(SliceOverrides.supportStyles, [
            "default", "snug", "tree_slim", "tree_strong", "tree_hybrid", "tree_organic",
        ])
    }
}
