import XCTest
@testable import Sprout

/// Covers `Domain/MakerWorld.swift`: the hits↔records join behind the profile picker, the
/// three-way cloud gate, and the licence/availability text.
///
/// The two fixtures are **trimmed captures of real `POST /api/v1/makerworld/resolve` responses**
/// (models 40146 and 1400373, taken 2026-08-10), not hand-written JSON, because every bug this file
/// guards against came from assuming a shape the API does not have. What was trimmed: rows not under
/// test, long `otherCompatibility` tails, and cover URLs. What was not: the key structure, including
/// model 40146's empty-string `licenseDescriptionInfo` and the fact that its pre-selected profile has
/// no record at all.
final class MakerWorldTests: XCTestCase {

    // MARK: - Fixtures

    /// #3DBenchy by Bambu Lab. **The R-1 case**: the profile MakerWorld itself pre-selects
    /// (instance 42179) has no entry in `design.instances`, so it can only be described as
    /// undescribed. Licence `BY-ND`, a Thingiverse remix credit, empty licence prose.
    private static let benchy = #"""
    {"model_id":40146,"instances":[{"id":42179,"profileId":22111064,"title":"1 Colour, 0.25mm layer, 2 walls, 10% infill","cover":"https://makerworld.bblmw.com/c/42179.png"},{"id":40704,"profileId":35118578,"title":"12min42s, Bambu PLA Basic, A1 mini","cover":"https://makerworld.bblmw.com/c/40704.png"},{"id":109644,"profileId":35438952,"title":"14min44s, Bambu PLA Basic, A1","cover":"https://makerworld.bblmw.com/c/109644.png"}],"design":{"id":40146,"title":"Benchy Bambu Pla Basic","coverUrl":"https://makerworld.bblmw.com/cover.png","downloadCount":385253,"designCreator":{"name":"Bambu Lab"},"defaultInstanceId":42179,"license":"BY-ND","licenseDescriptionInfo":{"title":"","content":""},"originals":[{"title":"#3DBenchy - The jolly 3D printing torture-test by CreativeTools.se","author":"CreativeTools","link":"https://www.thingiverse.com/thing:763622"}],"paidSetting":{"isPaid":false,"crowdfunding":0},"isPointRedeemable":false,"isExclusive":false,"instances":[{"id":109644,"profileId":35438952,"title":"14min44s, Bambu PLA Basic, A1","prediction":1895,"weight":12,"needAms":false,"materialCnt":1,"materialColorCnt":1,"isDefault":false,"appCanPrint":true,"instanceFilaments":[{"type":"PLA","color":"#FFFFFF","usedG":"12"}],"extention":{"modelInfo":{"compatibility":{"devModelName":"N2S","devProductName":"A1","nozzleDiameter":0.4},"otherCompatibility":[{"devModelName":"O1C2","devProductName":"H2C","nozzleDiameter":0.4},{"devModelName":"C12","devProductName":"P1S","nozzleDiameter":0.4},{"devModelName":"C11","devProductName":"P1P","nozzleDiameter":0.4}],"projectSettings":{"layerHeight":"0.25","wallLoops":"2","sparseInfillDensity":"10%"},"plates":[{"index":1,"prediction":1895,"weight":12,"thumbnail":{"url":"https://makerworld.bblmw.com/p/1.png"}}]}}},{"id":40704,"profileId":35118578,"title":"12min42s, Bambu PLA Basic, A1 mini","prediction":1661,"weight":13,"needAms":false,"materialCnt":1,"materialColorCnt":1,"isDefault":false,"appCanPrint":true,"instanceFilaments":[{"type":"PLA","color":"#FFFFFF","usedG":"13"}],"extention":{"modelInfo":{"compatibility":{"devModelName":"N1","devProductName":"A1 mini","nozzleDiameter":0.4},"otherCompatibility":[{"devModelName":"O1C2","devProductName":"H2C","nozzleDiameter":0.4},{"devModelName":"C12","devProductName":"P1S","nozzleDiameter":0.4},{"devModelName":"C11","devProductName":"P1P","nozzleDiameter":0.4}],"projectSettings":{"layerHeight":"0.25","wallLoops":"2","sparseInfillDensity":"10%"},"plates":[{"index":1,"prediction":1661,"weight":13,"thumbnail":{"url":"https://makerworld.bblmw.com/p/1.png"}}]}}}]}}
    """#

    /// A 3-filament, 4-plate model under the Standard Digital File License, flagged exclusive.
    /// Sliced for an X1 Carbon and *also* marked H2C — like 36 of 37 profiles on the Benchy, which is
    /// why that marking is not a badge.
    private static let seedTray = #"""
    {"model_id":1400373,"instances":[{"id":1452154,"profileId":298919107,"title":"Seed Starter Tray – 9 Cells","cover":"https://makerworld.bblmw.com/c/1452154.png"},{"id":1452158,"profileId":298919564,"title":"Seed Starter Tray – 6 Cells","cover":"https://makerworld.bblmw.com/c/1452158.png"}],"design":{"id":1400373,"title":"Self Watering Seed Starter with Modular Grow Kit","coverUrl":"https://makerworld.bblmw.com/cover.png","downloadCount":16127,"designCreator":{"name":"Meyui"},"defaultInstanceId":1452154,"license":"Standard Digital File License","licenseDescriptionInfo":{"title":"This user content is licensed under a Standard Digital File License.","content":"You shall not share, sub-license, sell, rent, host, transfer, or distribute in any way the digital or 3D printed versions of this object."},"paidSetting":{"isPaid":false,"crowdfunding":0},"isPointRedeemable":false,"isExclusive":true,"instances":[{"id":1452154,"profileId":298919107,"title":"Seed Starter Tray – 9 Cells","prediction":40048,"weight":322,"needAms":false,"materialCnt":3,"materialColorCnt":3,"isDefault":false,"appCanPrint":true,"instanceFilaments":[{"type":"PLA","color":"#646941","usedG":"230"},{"type":"PLA","color":"#C0C0C0","usedG":"35"},{"type":"PETG","color":"#FFFFFF","usedG":"57"}],"extention":{"modelInfo":{"compatibility":{"devModelName":"BL-P001","devProductName":"X1 Carbon","nozzleDiameter":0.4},"otherCompatibility":[{"devModelName":"O1C2","devProductName":"H2C","nozzleDiameter":0.4},{"devModelName":"N2S","devProductName":"A1","nozzleDiameter":0.4}],"projectSettings":{"layerHeight":"0.2","wallLoops":"2","sparseInfillDensity":"15%"},"plates":[{"index":1,"prediction":15324,"weight":107,"thumbnail":{"url":"https://makerworld.bblmw.com/p/1.png"}},{"index":2,"prediction":3491,"weight":35},{"index":3,"prediction":12055,"weight":123},{"index":4,"prediction":9178,"weight":57}]}}},{"id":1452158,"profileId":298919564,"title":"Seed Starter Tray – 6 Cells","prediction":29499,"weight":226,"needAms":false,"materialCnt":3,"materialColorCnt":3,"isDefault":false,"appCanPrint":true,"instanceFilaments":[{"type":"PLA","color":"#A57E60","usedG":"164"},{"type":"PLA","color":"#C0C0C0","usedG":"25"},{"type":"PETG","color":"#FFFFFF","usedG":"37"}],"extention":{"modelInfo":{"compatibility":{"devModelName":"BL-P001","devProductName":"X1 Carbon","nozzleDiameter":0.4},"otherCompatibility":[{"devModelName":"O1C2","devProductName":"H2C","nozzleDiameter":0.4}],"projectSettings":{"layerHeight":"0.2","wallLoops":"2","sparseInfillDensity":"15%"},"plates":[{"index":1,"prediction":12591,"weight":82},{"index":2,"prediction":2596,"weight":25},{"index":3,"prediction":8162,"weight":82},{"index":4,"prediction":6150,"weight":37}]}}}]}}
    """#

    private func decode(_ json: String) throws -> MakerWorldResolved {
        try BambuddyClient.decoder.decode(MakerWorldResolved.self, from: Data(json.utf8))
    }

    private func benchyResolved() throws -> MakerWorldResolved { try decode(Self.benchy) }
    private func seedResolved() throws -> MakerWorldResolved { try decode(Self.seedTray) }

    // MARK: - Decoding

    /// MakerWorld's own payload is camelCase inside a snake_case envelope. `.convertFromSnakeCase`
    /// leaves underscore-free keys alone, so both survive one decoder — worth pinning, because the
    /// whole join reads fields that would silently be nil if it did not.
    func testResolveDecodesBothTheEnvelopeAndTheCamelCaseDesign() throws {
        let r = try benchyResolved()
        XCTAssertEqual(r.modelId, 40146)                       // model_id → modelId
        XCTAssertEqual(r.alreadyImportedLibraryIds ?? [], [])
        XCTAssertEqual(r.design.defaultInstanceId, 42179)      // camelCase, untouched
        XCTAssertEqual(r.design.designCreator?.name, "Bambu Lab")
        XCTAssertEqual(r.design.instances?.count, 2)
        XCTAssertEqual(r.design.instances?.first?.instanceFilaments?.first?.type, "PLA")
        XCTAssertEqual(r.design.instances?.first?.extention?.modelInfo?.projectSettings?.layerHeight, "0.25")
    }

    /// The measured shape that made every row render blank: the hits carry none of the numbers.
    func testHitsCarryNoneOfTheNumbersTheRowNeeds() throws {
        let r = try benchyResolved()
        for hit in r.instances {
            XCTAssertNil(hit.prediction, "hit \(hit.id) unexpectedly carries prediction")
            XCTAssertNil(hit.weight)
            XCTAssertNil(hit.needAms)
            XCTAssertNil(hit.instanceFilaments)
            XCTAssertNil(hit.extention)
        }
    }

    // MARK: - rows(): the join direction

    /// The row set is the HITS. Building from `design.instances` would have shown 2 of 3 here and
    /// 37 of 88 on the real model — hiding real, importable profiles.
    func testRowsComeFromTheHitsNotTheRecords() throws {
        let r = try benchyResolved()
        let rows = MakerWorld.rows(r)
        XCTAssertEqual(rows.count, r.instances.count)
        XCTAssertEqual(rows.map(\.id), [42179, 40704, 109644])
        XCTAssertEqual(rows.map(\.profileId), [22111064, 35118578, 35438952])
    }

    /// A hit with no matching record is described as undescribed — never as "—".
    func testAHitWithNoRecordGetsNoDetailAndKeepsItsTitleAndCover() throws {
        let rows = MakerWorld.rows(try benchyResolved())
        let orphan = try XCTUnwrap(rows.first { $0.id == 42179 })
        XCTAssertNil(orphan.detail)
        XCTAssertEqual(orphan.title, "1 Colour, 0.25mm layer, 2 walls, 10% infill")
        XCTAssertEqual(orphan.coverUrl, "https://makerworld.bblmw.com/c/42179.png")
        XCTAssertEqual(orphan.profileId, 22111064, "an undescribed profile is still importable")
    }

    func testAHitWithARecordIsEnrichedFromIt() throws {
        let rows = MakerWorld.rows(try benchyResolved())
        let row = try XCTUnwrap(rows.first { $0.id == 109644 })
        let d = try XCTUnwrap(row.detail)
        XCTAssertEqual(d.seconds, 1895)
        XCTAssertEqual(d.grams, 12)
        XCTAssertFalse(d.needAms)
        XCTAssertEqual(d.slots.count, 1)
        XCTAssertEqual(d.slots.first?.type, "PLA")
        XCTAssertEqual(d.slots.first?.grams, 12)
        XCTAssertEqual(d.layerHeight, "0.25")
        XCTAssertEqual(d.slicedFor, "A1")
        XCTAssertEqual(d.plateCount, 1)
        XCTAssertEqual(d.materialCount, 1)
    }

    func testMultiFilamentAndMultiPlateSurviveTheJoin() throws {
        let rows = MakerWorld.rows(try seedResolved())
        let d = try XCTUnwrap(rows.first { $0.id == 1452154 }?.detail)
        XCTAssertEqual(d.slots.count, 3)
        XCTAssertEqual(d.slotCount, 3)
        XCTAssertEqual(d.slots.map(\.type), ["PLA", "PLA", "PETG"])
        XCTAssertEqual(d.slots.map(\.grams), [230, 35, 57])
        XCTAssertEqual(d.plateCount, 4)
        XCTAssertEqual(d.colorCount, 3)
        XCTAssertEqual(d.seconds, 40048)
    }

    /// `usedG` is a STRING on the wire. A row that silently dropped it would under-report the spool.
    func testSlotGramsParseFromTheStringTheApiSends() throws {
        let rows = MakerWorld.rows(try seedResolved())
        let d = try XCTUnwrap(rows.first?.detail)
        XCTAssertEqual(d.slots.map(\.grams), [230, 35, 57])
    }

    func testARecordWithNoMatchingHitIsStillListed() throws {
        var r = try benchyResolved()
        var extra = try XCTUnwrap(r.design.instances?.first)
        extra = MWInstance(id: 999_001, profileId: 999_002, title: "Record-only", prediction: 600,
                           weight: 5, instanceFilaments: extra.instanceFilaments)
        r.design.instances?.append(extra)
        let rows = MakerWorld.rows(r)
        XCTAssertEqual(rows.count, 4)
        XCTAssertEqual(rows.last?.id, 999_001)
        XCTAssertEqual(rows.last?.detail?.seconds, 600)
    }

    func testADuplicateRecordProfileIdTakesTheFirst() throws {
        var r = try benchyResolved()
        let dupe = MWInstance(id: 777, profileId: 35438952, title: "Dupe", prediction: 99_999, weight: 9)
        r.design.instances?.append(dupe)
        let rows = MakerWorld.rows(r)
        XCTAssertEqual(rows.count, 3, "a duplicate profileId is upstream noise, not a fourth profile")
        XCTAssertEqual(rows.first { $0.id == 109644 }?.detail?.seconds, 1895)
    }

    func testAHitWithoutAProfileIdIsListedButCannotBeEnriched() throws {
        var r = try benchyResolved()
        r.instances = [MWInstance(id: 4242, profileId: nil, title: "No profile id")]
        r.design.instances = []
        let rows = MakerWorld.rows(r)
        XCTAssertEqual(rows.count, 1)
        XCTAssertNil(rows[0].detail)
        XCTAssertNil(rows[0].profileId)
    }

    /// The proprietary licence name contains the letters "ND". Treating clause codes as substrings
    /// labelled it no-derivatives and printed the wrong obligation under the import button.
    func testAProprietaryLicenceNameIsNotParsedAsCreativeCommonsClauses() {
        let sdfl = MWLicence(code: "Standard Digital File License")
        XCTAssertEqual(sdfl.label, "Standard Digital File License")
        XCTAssertEqual(sdfl.obligation, "Personal prints only — the file may not be redistributed.")
    }

    func testAnEmptyResolveProducesNoRows() throws {
        var r = try benchyResolved()
        r.instances = []
        r.design.instances = []
        XCTAssertTrue(MakerWorld.rows(r).isEmpty)
    }

    func testAnUntitledProfileFallsBackRatherThanRenderingBlank() throws {
        var r = try benchyResolved()
        r.instances = [MWInstance(id: 1, profileId: nil, title: "   ")]
        XCTAssertEqual(MakerWorld.rows(r).first?.title, "Default profile")
    }

    // MARK: - preselect()

    /// `defaultInstanceId` matches an instance `id`, so the lookup has to run against the hits.
    func testPreselectHonoursMakerWorldsOwnChoiceWhenThatProfileIsDescribed() throws {
        let rows = MakerWorld.rows(try benchyResolved())
        XCTAssertEqual(MakerWorld.preselect(rows, defaultInstanceId: 109644)?.id, 109644,
                       "not the first row — MakerWorld's pick wins when it is usable")
    }

    /// Model 40146's own default profile publishes no details, and `POST /makerworld/import` answers
    /// `400` for it. Pre-selecting it would make the default action a guaranteed failure.
    func testPreselectSkipsAnUndescribedDefaultBecauseItsImportIsRefused() throws {
        let r = try benchyResolved()
        let rows = MakerWorld.rows(r)
        let picked = MakerWorld.preselect(rows, defaultInstanceId: r.design.defaultInstanceId)
        XCTAssertEqual(r.design.defaultInstanceId, 42179)
        XCTAssertEqual(picked?.id, 40704)
        XCTAssertNotNil(picked?.detail)
    }

    /// …but it is still LISTED. One undescribed profile out of six did import, so hiding them would
    /// hide a real capability; only the default pick moves.
    func testUndescribedProfilesRemainSelectableEvenThoughTheyAreNotPreferred() throws {
        let rows = MakerWorld.rows(try benchyResolved())
        XCTAssertTrue(rows.contains { $0.id == 42179 && $0.detail == nil })
    }

    func testPreselectFallsBackToTheFirstSingleFilamentDescribedRow() throws {
        let rows = MakerWorld.rows(try benchyResolved())
        // 42179 is first in the list and undescribed, so passing here means the described-row rule
        // fired rather than the `rows.first` fallback underneath it.
        XCTAssertNil(rows.first?.detail)
        XCTAssertEqual(MakerWorld.preselect(rows, defaultInstanceId: nil)?.id, 40704)
    }

    /// The multi-slot branch: when nothing is single-filament, the second described-row rule has to
    /// fire rather than dropping through to `rows.first`.
    func testPreselectPrefersADescribedRowEvenWhenEveryOneIsMultiFilament() throws {
        var r = try seedResolved()
        r.instances.insert(MWInstance(id: 9_001, profileId: 9_002, title: "Undescribed, and first"),
                           at: 0)
        let rows = MakerWorld.rows(r)
        XCTAssertNil(rows.first?.detail)
        let picked = MakerWorld.preselect(rows, defaultInstanceId: nil)
        XCTAssertEqual(picked?.id, 1452154)
        XCTAssertEqual(picked?.detail?.slotCount, 3)
    }

    func testPreselectStillUsesTheirPickWhenNothingIsDescribed() throws {
        var r = try benchyResolved()
        r.design.instances = []
        let rows = MakerWorld.rows(r)
        XCTAssertEqual(MakerWorld.preselect(rows, defaultInstanceId: 109644)?.id, 109644)
    }

    func testPreselectFallsBackToADescribedRowWhenEveryOneIsMultiFilament() throws {
        let rows = MakerWorld.rows(try seedResolved())
        XCTAssertEqual(MakerWorld.preselect(rows, defaultInstanceId: 0)?.id, 1452154)
    }

    func testPreselectFallsBackToTheFirstRowWhenNothingIsDescribed() throws {
        var r = try benchyResolved()
        r.design.instances = []
        let rows = MakerWorld.rows(r)
        XCTAssertEqual(MakerWorld.preselect(rows, defaultInstanceId: nil)?.id, 42179)
    }

    func testPreselectIsNilWithoutRows() {
        XCTAssertNil(MakerWorld.preselect([], defaultInstanceId: 42179))
    }

    /// `isDefault` was false on every record of every model probed. Nothing may depend on it.
    func testIsDefaultIsNeverUsedAsAFallback() throws {
        var r = try benchyResolved()
        r.design.instances?[0].isDefault = true      // record for hit 109644, the LAST row
        let rows = MakerWorld.rows(r)
        XCTAssertEqual(MakerWorld.preselect(rows, defaultInstanceId: nil)?.id, 40704)
    }

    // MARK: - Row text

    func testMetaLineSaysSoWhenMakerWorldPublishesNothing() throws {
        let rows = MakerWorld.rows(try benchyResolved())
        let line = MakerWorld.metaLine(rows.first { $0.id == 42179 }?.detail)
        XCTAssertEqual(line, "MakerWorld publishes no details for this profile")
        XCTAssertFalse(line.contains("—"), "the em dash is what made this look like a bug")
    }

    func testMetaLineRendersTimeAndWeight() throws {
        let rows = MakerWorld.rows(try benchyResolved())
        XCTAssertEqual(MakerWorld.metaLine(rows.first { $0.id == 109644 }?.detail), "32m  ·  12 g")
    }

    func testMetaLineCallsOutMultiplePlatesBecauseThatIsNotOnePrint() throws {
        let rows = MakerWorld.rows(try seedResolved())
        let line = MakerWorld.metaLine(rows.first?.detail)
        XCTAssertEqual(line, "11h 07m  ·  322 g  ·  4 plates")
    }

    func testMetaLineAddsAmsWhenTheProfileNeedsIt() {
        let d = MWProfileDetail(seconds: 3600, grams: 20, needAms: true, slots: [], plateCount: 1,
                                alsoMarkedFor: [])
        XCTAssertEqual(MakerWorld.metaLine(d), "1h 00m  ·  20 g  ·  AMS")
    }

    /// A described profile with no numbers is not an undescribed one — saying "no details" there
    /// would be a second, smaller lie.
    func testADescribedProfileWithNoNumbersSaysSoDifferently() {
        let d = MWProfileDetail(seconds: nil, grams: nil, needAms: false, slots: [], plateCount: 1,
                                alsoMarkedFor: [])
        XCTAssertEqual(MakerWorld.metaLine(d), "No print estimate published")
    }

    func testMaterialsLineGroupsRepeatedMaterials() throws {
        let rows = MakerWorld.rows(try seedResolved())
        XCTAssertEqual(MakerWorld.materialsLine(rows.first?.detail), "0.2 mm  ·  PLA ×2 + PETG  ·  3 colours")
    }

    func testMaterialsLineOmitsTheColourCountForASingleColour() throws {
        let rows = MakerWorld.rows(try benchyResolved())
        XCTAssertEqual(MakerWorld.materialsLine(rows.first { $0.id == 109644 }?.detail), "0.25 mm  ·  PLA")
    }

    func testMaterialsLineIsEmptyWithoutDetail() {
        XCTAssertEqual(MakerWorld.materialsLine(nil), "")
    }

    func testMaterialsLineToleratesAnUntypedSlot() {
        let d = MWProfileDetail(seconds: nil, grams: nil, needAms: false,
                                slots: [MWSlot(type: nil, color: "#fff", grams: 3)],
                                plateCount: 1, alsoMarkedFor: [])
        XCTAssertEqual(MakerWorld.materialsLine(d), "?")
    }

    // MARK: - Compatibility

    /// True for essentially every profile, which is exactly why it is not shown as a badge — see the
    /// doc comment on `marked(for:)`.
    func testMarkedForIsTrueViaOtherCompatibilityAndIsCaseInsensitive() throws {
        let rows = MakerWorld.rows(try benchyResolved())
        let d = try XCTUnwrap(rows.first { $0.id == 109644 }?.detail)
        XCTAssertEqual(d.slicedFor, "A1")
        XCTAssertTrue(d.marked(for: "H2C"))
        XCTAssertTrue(d.marked(for: "h2c"))
        XCTAssertTrue(d.marked(for: "A1"), "the machine it was sliced for counts too")
        XCTAssertFalse(d.marked(for: "K2 Pro"))
    }

    func testMarkedForIsFalseWhenNothingIsPublished() {
        let d = MWProfileDetail(seconds: nil, grams: nil, needAms: false, slots: [], plateCount: 1,
                                alsoMarkedFor: [])
        XCTAssertFalse(d.marked(for: "H2C"))
    }

    // MARK: - Licence

    func testLicenceReadsTheCodeAndTreatsEmptyProseAsAbsent() throws {
        let r = try benchyResolved()
        let l = try XCTUnwrap(MakerWorld.licence(r.design))
        XCTAssertEqual(l.code, "BY-ND")
        XCTAssertEqual(l.label, "CC BY-ND")
        XCTAssertNil(l.title, "MakerWorld sends empty strings here, not nulls")
        XCTAssertNil(l.body)
        XCTAssertTrue(l.obligation.contains("no modified versions"))
    }

    func testLicenceRendersMakerWorldsOwnProseVerbatimWhenItShipsIt() throws {
        let r = try seedResolved()
        let l = try XCTUnwrap(MakerWorld.licence(r.design))
        XCTAssertEqual(l.code, "Standard Digital File License")
        XCTAssertEqual(l.label, "Standard Digital File License", "not a CC code — shown as sent")
        XCTAssertEqual(l.title, "This user content is licensed under a Standard Digital File License.")
        XCTAssertTrue(try XCTUnwrap(l.body).hasPrefix("You shall not share"))
        XCTAssertTrue(l.obligation.contains("may not be redistributed"))
    }

    func testLicenceIsNilWhenTheDesignCarriesNone() throws {
        var r = try benchyResolved()
        r.design.license = nil
        XCTAssertNil(MakerWorld.licence(r.design))
        r.design.license = "   "
        XCTAssertNil(MakerWorld.licence(r.design))
    }

    func testCreativeCommonsObligationsDifferByClause() {
        XCTAssertTrue(MWLicence(code: "BY").obligation.contains("Credit the creator"))
        XCTAssertTrue(MWLicence(code: "BY-NC").obligation.contains("non-commercial"))
        XCTAssertTrue(MWLicence(code: "BY-NC-ND").obligation.contains("no modified versions"))
        XCTAssertEqual(MWLicence(code: "BY-SA").label, "CC BY-SA")
    }

    func testRemixAttributionSurvivesTheDecode() throws {
        let r = try benchyResolved()
        let original = try XCTUnwrap(r.design.originals?.first)
        XCTAssertEqual(original.author, "CreativeTools")
        XCTAssertEqual(original.link, "https://www.thingiverse.com/thing:763622")
    }

    // MARK: - Availability hints

    func testAvailabilityIsSilentForAFreeModel() throws {
        XCTAssertNil(MakerWorld.availability(try benchyResolved().design).caution)
    }

    func testAnExclusiveModelWarnsBeforeTheDownloadRatherThanAfter() throws {
        let a = MakerWorld.availability(try seedResolved().design)
        XCTAssertTrue(a.isExclusive)
        XCTAssertFalse(a.isPaid)
        XCTAssertEqual(a.caution, "This model is marked exclusive. The import may be refused.")
    }

    func testPaidOutranksTheOtherHints() {
        let a = MWAvailability(isPaid: true, isPointRedeemable: true, isExclusive: true)
        XCTAssertTrue(try XCTUnwrap(a.caution).contains("paid model"))
    }

    func testPointsRedeemableIsItsOwnMessage() {
        XCTAssertTrue(try XCTUnwrap(MWAvailability(isPointRedeemable: true).caution).contains("points"))
    }

    // MARK: - Access gating

    /// The capability answer needs no diagnosis, whatever the diagnostic says.
    func testCanDownloadTrueIsReadyRegardlessOfTheCloudProbe() {
        for probe: MakerWorldCloudProbe in [.forbidden, .readable(authenticated: false), .failed] {
            XCTAssertEqual(MakerWorld.access(cloud: probe, canDownload: true), .ready)
        }
    }

    /// The regression this whole split exists for: the server IS signed in, and the fix is a scope on
    /// the API key — a different app, a different page, a different action.
    func testAKeyWithoutCloudScopeIsNotReportedAsNotSignedIn() {
        let a = MakerWorld.access(cloud: .forbidden, canDownload: false)
        XCTAssertEqual(a, .keyLacksCloudScope)
        let msg = try! XCTUnwrap(a.message)
        XCTAssertTrue(msg.contains("API Keys"))
        XCTAssertFalse(msg.lowercased().contains("sign in"), "signing in again would change nothing")
    }

    func testNotSignedInIsReportedWhenTheKeyCanSeeTheAccount() {
        XCTAssertEqual(MakerWorld.access(cloud: .readable(authenticated: false), canDownload: false),
                       .serverNotSignedIn)
    }

    /// `/makerworld/status` is the endpoint the import actually depends on, so its `false` wins over
    /// a stale-looking `authenticated: true`.
    func testTheMoreSpecificEndpointWinsWhenTheTwoDisagree() {
        XCTAssertEqual(MakerWorld.access(cloud: .readable(authenticated: true), canDownload: false),
                       .serverNotSignedIn)
    }

    /// `/cloud/status` checks expiry, so an authenticated 200 is itself a usable-token answer.
    func testAnAuthenticatedCloudStatusIsEnoughWhenTheOtherProbeNeverAnswered() {
        XCTAssertEqual(MakerWorld.access(cloud: .readable(authenticated: true), canDownload: nil), .ready)
    }

    func testNeitherProbeAnsweringIsSaidPlainlyRatherThanGuessed() {
        XCTAssertEqual(MakerWorld.access(cloud: .failed, canDownload: nil), .unreachable)
    }

    /// `.unreachable` is a snapshot of one instant and the only blocking state that can clear itself
    /// with no user action. Locking the button for the life of the panel — while the panel goes on to
    /// resolve a model and prove the server is back — hides a capability the backend would allow.
    func testOnlyTheTransientStateAdvertisesItselfAsWorthRetrying() {
        XCTAssertTrue(MakerWorldAccess.unreachable.worthRetrying)
        for a: MakerWorldAccess in [.ready, .checking, .keyLacksCloudScope, .serverNotSignedIn] {
            XCTAssertFalse(a.worthRetrying, "\(a) needs a remedy applied elsewhere; re-probing changes nothing")
        }
        XCTAssertTrue(try XCTUnwrap(MakerWorldAccess.unreachable.message).contains("try again"))
    }

    func testEveryBlockingStateExplainsItselfAndReadyDoesNot() {
        XCTAssertNil(MakerWorldAccess.ready.message)
        XCTAssertNil(MakerWorldAccess.checking.message)
        XCTAssertFalse(MakerWorldAccess.ready.blocksImport)
        for a: MakerWorldAccess in [.checking, .keyLacksCloudScope, .serverNotSignedIn, .unreachable] {
            XCTAssertTrue(a.blocksImport, "\(a) must not offer an import that will be refused")
        }
        for a: MakerWorldAccess in [.keyLacksCloudScope, .serverNotSignedIn, .unreachable] {
            XCTAssertNotNil(a.message, "\(a) blocks the button, so it owes the user a reason")
        }
    }

    /// Bambuddy's own window is 30 days; the "~90 days" the design doc asserted came from nowhere and
    /// would have made a day-31 re-login prompt look like a bug.
    func testTheSignInRemedyQuotesBambuddysOwnThirtyDayWindow() {
        let msg = try! XCTUnwrap(MakerWorldAccess.serverNotSignedIn.message)
        XCTAssertTrue(msg.contains("30 days"))
        XCTAssertFalse(msg.contains("90"))
    }

    // MARK: - Failure copy

    /// A refusal MakerWorld explained is worth more than anything written here.
    func testAContentGatedRefusalIsForwardedVerbatim() {
        let f = MakerWorld.failure(step: .importing, status: 403,
                                   detail: "This model requires 30 points to redeem.")
        XCTAssertEqual(f.message, "This model requires 30 points to redeem.")
        XCTAssertTrue(f.offerWebLink)
    }

    func testAContentGatedRefusalWithNoTextStillSaysWhoRefused() {
        let f = MakerWorld.failure(step: .importing, status: 403, detail: nil)
        XCTAssertTrue(f.message.contains("MakerWorld"))
        XCTAssertFalse(f.message.lowercased().contains("import failed"))
        XCTAssertTrue(f.offerWebLink)
    }

    func testABadLinkBlamesTheLinkAndOffersNoWebEscape() {
        let f = MakerWorld.failure(step: .resolve, status: 400, detail: nil)
        XCTAssertTrue(f.message.contains("makerworld.com/models/"))
        XCTAssertFalse(f.offerWebLink, "there is no page to open — the link was never valid")
    }

    /// The same status means different things on either side of an import: at resolve a `400` is a
    /// malformed link, at import it is MakerWorld declining to release that profile's file.
    func testA400AtImportIsNotReportedAsABadLink() {
        let f = MakerWorld.failure(step: .importing, status: 400, detail: nil)
        XCTAssertFalse(f.message.contains("makerworld.com/models/"))
        XCTAssertTrue(f.message.contains("Try another one"))
        XCTAssertTrue(f.offerWebLink)
    }

    func testAMissingModelIsNotReportedAsAServerProblem() {
        let f = MakerWorld.failure(step: .resolve, status: 404, detail: nil)
        XCTAssertEqual(f.message, "MakerWorld has no model at that link.")
        XCTAssertFalse(f.offerWebLink)
    }

    /// A CAPTCHA is unsolvable server-side by design, so the copy has to say that rather than imply
    /// a retry will help.
    func testACaptchaIsNamedAndTheWebLinkIsOffered() {
        let f = MakerWorld.failure(step: .importing, status: 502,
                                   detail: "Upstream returned: please confirm you are not a robot")
        XCTAssertTrue(f.message.contains("CAPTCHA"))
        XCTAssertTrue(f.message.contains("clears in a few hours"))
        XCTAssertTrue(f.offerWebLink)
    }

    func testTheSizeCapIsQuotedRatherThanCalledAFailure() {
        let f = MakerWorld.failure(step: .importing, status: 502,
                                   detail: "file exceeds 200 MB cap")
        XCTAssertTrue(f.message.contains("200 MB"))
    }

    func testARejectedCloudTokenPointsAtTheServersSignInNotTheKey() {
        let f = MakerWorld.failure(step: .importing, status: 401, detail: nil)
        XCTAssertTrue(f.message.contains("Cloud Profiles"))
        XCTAssertFalse(f.message.contains("API Keys"), "that is a different condition entirely")
    }

    /// Resolving is anonymous upstream, so a 401 there cannot be about a Bambu Cloud token — it is
    /// Bambuddy rejecting this app's own key. Sending the user to re-do a cloud sign-in would have
    /// them fix something the call never used.
    func testA401AtResolveBlamesThisAppsKeyNotTheServersCloudSignIn() {
        let f = MakerWorld.failure(step: .resolve, status: 401, detail: nil)
        XCTAssertTrue(f.message.contains("API key"))
        XCTAssertFalse(f.message.contains("Cloud Profiles"))
    }

    /// The server's own sentence beats anything written here, at either step.
    func testA401ForwardsTheServersOwnDetailWhenItSendsOne() {
        for step: MakerWorld.Step in [.resolve, .importing] {
            XCTAssertEqual(MakerWorld.failure(step: step, status: 401, detail: "Key revoked on 2026-08-01.")
                .message, "Key revoked on 2026-08-01.")
        }
    }

    /// The live 400 always carries a `detail`; the fixed copy has to win over it, because MakerWorld's
    /// raw text here ("Bambu Lab API unexpected status 400 for profile 21931235") explains nothing.
    func testA400AtImportKeepsItsOwnCopyOverAnUnhelpfulUpstreamDetail() {
        let f = MakerWorld.failure(step: .importing, status: 400,
                                   detail: "Bambu Lab API unexpected status 400 for profile 21931235")
        XCTAssertTrue(f.message.contains("Try another one"))
        XCTAssertFalse(f.message.contains("unexpected status"))
    }

    func testRateLimitingAsksForPatienceRatherThanRetryingInALoop() {
        XCTAssertTrue(MakerWorld.failure(step: .resolve, status: 429, detail: nil)
            .message.contains("rate-limiting"))
    }

    /// The two hops fail independently and must not be confused.
    func testNoHttpStatusBlamesTheServerHopNotMakerWorld() {
        let f = MakerWorld.failure(step: .resolve, status: 0, detail: nil)
        XCTAssertEqual(f.message, "Couldn’t reach your Bambuddy server.")
        XCTAssertFalse(f.offerWebLink)
    }

    func testAGenericUpstreamFailureNamesTheStepItFailedAt() {
        XCTAssertTrue(MakerWorld.failure(step: .resolve, status: 502, detail: nil).message.contains("look up"))
        XCTAssertTrue(MakerWorld.failure(step: .importing, status: 502, detail: nil).message.contains("download"))
    }

    // MARK: - Filament requirements (the wizard's multi-material gate)

    private func requirements(_ json: String) throws -> FilamentRequirements {
        try BambuddyClient.decoder.decode(FilamentRequirements.self, from: Data(json.utf8))
    }

    /// Live shape, `GET /library/files/47/filament-requirements?plate_id=2` on a Sprout-sliced
    /// MakerWorld import.
    func testASingleMaterialPlateReportsOneSlot() throws {
        let r = try requirements(#"""
        {"file_id":47,"plate_id":2,"filaments":[{"slot_id":1,"type":"PLA","color":"#646941",
        "used_grams":33.0,"used_meters":10.89,"tray_info_idx":"GFA00","used_in_plate":true,"nozzle_id":1}]}
        """#)
        XCTAssertEqual(r.usedSlotCount, 1)
        XCTAssertEqual(r.filaments?.first?.nozzleId, 1, "the extruder the slicer chose — only present after a slice")
        XCTAssertEqual(r.filaments?.first?.trayInfoIdx, "GFA00")
    }

    /// The case the gate exists for. `ams_mapping` is sent as a one-element array, so slots 2 and 3
    /// would reach the printer unmapped.
    func testAMultiMaterialPlateReportsEverySlotItUses() throws {
        let r = try requirements(#"""
        {"file_id":46,"plate_id":1,"filaments":[
          {"slot_id":1,"type":"PLA","used_in_plate":true},
          {"slot_id":2,"type":"PLA","used_in_plate":true},
          {"slot_id":3,"type":"PETG","used_in_plate":true}]}
        """#)
        XCTAssertEqual(r.usedSlotCount, 3)
    }

    /// A four-plate file lists filaments no single plate needs. Counting the whole file would block a
    /// single-material plate — measured: this exact file reports 6 slots unfiltered and 1 per plate.
    ///
    /// Note the used slot here is **2**, not 1. That is the real plate 2 of file 46, and it is why
    /// the count alone cannot decide the mapping — see `soleUsedSlot`.
    func testSlotsTheChosenPlateDoesNotUseAreNotCounted() throws {
        let r = try requirements(#"""
        {"file_id":46,"plate_id":2,"filaments":[
          {"slot_id":1,"type":"PLA","used_in_plate":false},
          {"slot_id":2,"type":"PLA","used_in_plate":true},
          {"slot_id":3,"type":"PETG","used_in_plate":false},
          {"slot_id":4,"type":"PETG","used_in_plate":false}]}
        """#)
        XCTAssertEqual(r.usedSlotCount, 1)
        XCTAssertEqual(r.soleUsedSlot, 2, "the count says 'one filament'; the mapping needs to know WHICH")
    }

    // MARK: soleUsedSlot — which slot, not how many

    /// `ams_mapping` index 0 addresses filament slot 1. A one-element array for a plate whose lone
    /// filament is slot 3 binds the chosen tray to a filament the plate never asks for.
    func testSoleUsedSlotIsTheSlotIdNotThePositionInTheList() throws {
        let r = try requirements(#"""
        {"plate_id":4,"filaments":[
          {"slot_id":1,"type":"PLA","used_in_plate":false},
          {"slot_id":3,"type":"PETG","used_in_plate":true}]}
        """#)
        XCTAssertEqual(r.usedSlotCount, 1)
        XCTAssertEqual(r.soleUsedSlot, 3)
    }

    func testSoleUsedSlotIsNilWhenThePlateNeedsMoreThanOne() throws {
        let r = try requirements(#"""
        {"filaments":[{"slot_id":1,"used_in_plate":true},{"slot_id":2,"used_in_plate":true}]}
        """#)
        XCTAssertNil(r.soleUsedSlot)
    }

    func testSoleUsedSlotIsNilWhenNothingIsKnown() throws {
        XCTAssertNil(try requirements(#"{"filaments":[]}"#).soleUsedSlot)
        XCTAssertNil(try requirements(#"{"file_id":9}"#).soleUsedSlot)
    }

    /// A slot id the API omits or reports as 0 must not produce a negative array index.
    func testSoleUsedSlotFloorsAtOne() throws {
        XCTAssertEqual(try requirements(#"{"filaments":[{"type":"PLA"}]}"#).soleUsedSlot, 1)
        XCTAssertEqual(try requirements(#"{"filaments":[{"slot_id":0,"type":"PLA"}]}"#).soleUsedSlot, 1)
    }

    /// The output of Sprout's own slice renumbers to slot 1 — measured on file 47 `?plate_id=2` — so
    /// the common path keeps sending the single-element mapping that shipped before.
    func testASlicedOutputReportsSlotOneSoTheMappingIsUnchanged() throws {
        let r = try requirements(#"""
        {"file_id":47,"plate_id":2,"filaments":[{"slot_id":1,"type":"PLA","used_grams":33.0,
        "tray_info_idx":"GFA00","used_in_plate":true,"nozzle_id":1}]}
        """#)
        XCTAssertEqual(r.soleUsedSlot, 1)
    }

    /// A missing flag means "no per-plate information", not "unused" — dropping those would report
    /// one slot for a print that needs several, which is the failure the gate must not have.
    func testAMissingUsedInPlateFlagCountsAsUsed() throws {
        let r = try requirements(#"""
        {"filaments":[{"slot_id":1,"type":"PLA"},{"slot_id":2,"type":"PETG"}]}
        """#)
        XCTAssertEqual(r.usedSlotCount, 2)
    }

    func testAnEmptyOrAbsentRequirementListNeverReportsZeroSlots() throws {
        XCTAssertEqual(try requirements(#"{"filaments":[]}"#).usedSlotCount, 1)
        XCTAssertEqual(try requirements(#"{"file_id":9}"#).usedSlotCount, 1)
    }

    // MARK: - Misc

    func testWebUrlIsTheCanonicalModelPage() {
        XCTAssertEqual(MakerWorld.webUrl(modelId: 40146)?.absoluteString,
                       "https://makerworld.com/models/40146")
    }
}
