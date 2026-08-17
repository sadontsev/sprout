import XCTest
@testable import Sprout

/// The slice request is a WIRE FORMAT and had no tests at all until this file.
///
/// It lived as local variables inside an iOS-only view. Every assertion here is about a shape the
/// server has already accepted — the point is to notice if that shape ever changes by accident, which
/// is exactly what would happen the first time a second platform assembled its own copy.
final class SliceRequestTests: XCTestCase {

    private func preset(_ id: String, _ name: String, source: String? = nil) -> Preset {
        Preset(id: id, name: name, source: source)
    }

    private func obj(_ v: JSONValue?) -> [String: JSONValue]? {
        if case .object(let o) = v { return o }
        return nil
    }

    // MARK: - Preset references

    func testAPresetRefIsIdAndName() {
        XCTAssertEqual(obj(SliceRequest.presetRef(preset("7", "0.20mm Standard"))),
                       ["id": .string("7"), "name": .string("0.20mm Standard")])
    }

    /// `source` rides along only when the row carried one — an always-present `source: null` is a
    /// different body from the one the server has accepted.
    func testSourceIsPresentOnlyWhenTheRowHadOne() {
        let with = obj(SliceRequest.presetRef(preset("7", "PLA", source: "system")))
        XCTAssertEqual(with?["source"], .string("system"))
        XCTAssertNil(obj(SliceRequest.presetRef(preset("7", "PLA")))?["source"])
    }

    /// A local preset's id is an Int in Swift and a STRING on the wire. Sending the number is a 422
    /// from a server that otherwise looks like it agreed with you.
    func testALocalPresetIdIsSentAsAString() {
        XCTAssertEqual(obj(SliceRequest.localRef(id: 7)),
                       ["source": .string("local"), "id": .string("7")])
    }

    // MARK: - Filament ordering

    /// Positional against the USED slots, not the raw slot numbers. The measured counterexample: a
    /// plate whose only slot is 2, handed [PLA, PETG], printed PLA.
    func testFilamentsAreCompactedToTheUsedSlotsInOrder() {
        let bySlot = [1: preset("a", "PLA"), 2: preset("b", "PETG"), 3: preset("c", "ABS")]
        XCTAssertEqual(SliceRequest.orderedFilaments(mappedSlots: [2], presetBySlot: bySlot).map(\.name),
                       ["PETG"])
        XCTAssertEqual(SliceRequest.orderedFilaments(mappedSlots: [1, 3], presetBySlot: bySlot).map(\.name),
                       ["PLA", "ABS"])
    }

    /// The gap that used to be swallowed in silence, and the predicate that now catches it.
    func testAUsedSlotWithNoPresetIsReportedRatherThanSwallowed() {
        let bySlot = [2: preset("b", "PETG")]
        // What the old code did: two used slots collapse to a ONE-element list…
        XCTAssertEqual(SliceRequest.orderedFilaments(mappedSlots: [1, 2], presetBySlot: bySlot).count, 1)
        // …which is why the caller has to ask this first.
        XCTAssertEqual(SliceRequest.missingPresetSlots(mappedSlots: [1, 2], presetBySlot: bySlot), [1])
        XCTAssertTrue(SliceRequest.missingPresetSlots(mappedSlots: [2], presetBySlot: bySlot).isEmpty)
    }

    // MARK: - The body

    func testTheThreeAlwaysPresentKeys() {
        let b = SliceRequest.body(plate: 3, bedType: "textured_plate",
                                  printer: nil, process: nil, filaments: [])
        XCTAssertEqual(b["plate"], .int(3))
        XCTAssertEqual(b["bed_type"], .string("textured_plate"))
        XCTAssertEqual(b["export_3mf"], .bool(true), "the server returns a 3MF, not raw gcode")
    }

    /// Both preset keys are OPTIONAL and absent rather than null when unknown.
    func testPrinterAndProcessAreOmittedWhenAbsent() {
        let b = SliceRequest.body(plate: 1, bedType: "cool_plate",
                                  printer: nil, process: nil, filaments: [])
        XCTAssertNil(b["printer_preset"])
        XCTAssertNil(b["process_preset"])
        XCTAssertNil(b["filament_preset"])
        XCTAssertNil(b["filament_presets"])
    }

    /// ONE filament takes the singular key and the plural must be absent. This is the common path and
    /// the one proven against the live server.
    func testOneFilamentTakesTheSingularKey() {
        let b = SliceRequest.body(plate: 1, bedType: "cool_plate", printer: nil, process: nil,
                                  filaments: [preset("a", "PLA")])
        XCTAssertEqual(obj(b["filament_preset"])?["name"], .string("PLA"))
        XCTAssertNil(b["filament_presets"], "the plural key must not appear for one filament")
    }

    /// TWO takes the plural, in the given order, and the singular must be absent.
    func testTwoFilamentsTakeThePluralKeyInOrder() {
        let b = SliceRequest.body(plate: 1, bedType: "cool_plate", printer: nil, process: nil,
                                  filaments: [preset("a", "PLA"), preset("b", "PETG")])
        XCTAssertNil(b["filament_preset"])
        guard case .array(let a) = b["filament_presets"] else { return XCTFail("expected an array") }
        XCTAssertEqual(a.compactMap { obj($0)?["name"] }, [.string("PLA"), .string("PETG")])
    }

    /// An override replaces the single filament's own ref.
    func testAnOverrideReplacesTheSingleFilamentRef() {
        let b = SliceRequest.body(plate: 1, bedType: "cool_plate", printer: nil, process: nil,
                                  filaments: [preset("a", "PLA")],
                                  filamentOverride: SliceRequest.localRef(id: 12))
        XCTAssertEqual(obj(b["filament_preset"])?["id"], .string("12"))
        XCTAssertEqual(obj(b["filament_preset"])?["source"], .string("local"))
    }

    /// …but with two filaments the plural wins and the override is DROPPED. That is today's shipped
    /// behaviour, documented here rather than silently changed: the override is only ever built for a
    /// single filament, so this combination should not arise — and if it ever does, it must not
    /// quietly send one material for a two-material plate.
    func testWithTwoFilamentsThePluralWinsAndTheOverrideIsDropped() {
        let b = SliceRequest.body(plate: 1, bedType: "cool_plate", printer: nil, process: nil,
                                  filaments: [preset("a", "PLA"), preset("b", "PETG")],
                                  filamentOverride: SliceRequest.localRef(id: 12))
        XCTAssertNil(b["filament_preset"])
        XCTAssertNotNil(b["filament_presets"])
    }

    /// A process ref is passed THROUGH, not re-wrapped — the caller may hand us a local-preset ref
    /// instead of a stock one, and re-wrapping would lose the `source: local`.
    func testTheProcessRefIsPassedThroughUntouched() {
        let local = SliceRequest.localRef(id: 99)
        let b = SliceRequest.body(plate: 1, bedType: "cool_plate", printer: nil,
                                  process: local, filaments: [])
        XCTAssertEqual(b["process_preset"], local)
    }

    /// The whole body must survive the client's own encoder with its keys intact. `BambuddyClient`
    /// snake-cases top-level keys of an `AnyEncodable` body, so authoring them already snake-cased is
    /// the safe spelling under either behaviour — this pins whichever is true.
    func testTheBodySurvivesTheEncoderWithSnakeCaseKeys() throws {
        let b = SliceRequest.body(plate: 2, bedType: "textured_plate",
                                  printer: preset("p", "H2C 0.4 nozzle"),
                                  process: SliceRequest.presetRef(preset("q", "0.20mm Standard")),
                                  filaments: [preset("a", "PLA")])
        let data = try JSONEncoder().encode(b)
        let back = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        XCTAssertNotNil(back?["bed_type"], "bed_type must not be camel-cased away")
        XCTAssertNotNil(back?["export_3mf"])
        XCTAssertNotNil(back?["printer_preset"])
        XCTAssertNotNil(back?["process_preset"])
        XCTAssertNotNil(back?["filament_preset"])
    }
}

/// "Can this be sliced" — and the three nearby questions that must not be asked instead.
final class SliceCapabilityTests: XCTestCase {

    private func file(_ type: String?, slicedForModel: String? = nil) -> LibraryFile {
        var f = LibraryFile(id: 1, filename: "x")
        f.fileType = type
        f.slicedForModel = slicedForModel
        return f
    }

    func testAProjectThreeMFCanBeSliced() {
        XCTAssertTrue(SliceCapability.canSlice(file("3mf")))
        XCTAssertTrue(SliceCapability.canSlice(file("3MF")), "type comparison is case-insensitive")
    }

    /// Already has toolpaths — there is nothing to slice.
    func testASlicedThreeMFIsNotOfferedForSlicing() {
        XCTAssertFalse(SliceCapability.canSlice(file("gcode.3mf")))
    }

    /// Unmeasured, so refused. See the doc comment: nothing in this repo records whether `/slice`
    /// takes a bare mesh, and offering it on a guess is the recurring bug.
    func testAnStlIsRefusedUntilSomebodyMeasuresIt() {
        XCTAssertFalse(SliceCapability.canSlice(file("stl")))
    }

    /// The predicate is POSITIVE, so an unknown type is refused rather than offered.
    func testAnUnknownOrMissingTypeIsRefused() {
        XCTAssertFalse(SliceCapability.canSlice(file("zip")))
        XCTAssertFalse(SliceCapability.canSlice(file(nil)))
    }

    /// The counterexample that kills `!isSliced` as the gate: this file is `isSliced == true` because
    /// it names a machine, AND sliceable, at the same time.
    func testAPlainThreeMFNamingAMachineIsBothLabelledSlicedAndSliceable() {
        let f = file("3mf", slicedForModel: "Creality K2 Pro")
        XCTAssertTrue(LibraryFileCaps.isSliced(f), "the label says yes…")
        XCTAssertFalse(LibraryFileCaps.hasGcode(f), "…but there are no toolpaths…")
        XCTAssertTrue(SliceCapability.canSlice(f), "…so it is exactly what slicing is for")
    }
}
