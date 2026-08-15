// The Mac Explore inspector's pure decisions: who gets told about a finished import, and whose
// choice the pending import is acting on.
//
// **These cases only run on the macOS test destination.** `MacExploreCopy` lives inside
// `#if os(macOS)` because it is Mac panel support, so the iOS command in CLAUDE.md contributes zero
// cases from this file — a green iOS run is not evidence that any of this passed. Run
// `xcodebuild … -destination 'platform=macOS' test` as well (18-mac-port-architecture.md, Build).
#if os(macOS)
import XCTest
@testable import Sprout

final class MacExploreTests: XCTestCase {

    // MARK: Fixtures

    private func detail(materials: [String] = ["PLA"]) -> MWProfileDetail {
        var d = MWProfileDetail()
        d.seconds = 3600
        d.grams = 20
        d.slots = materials.map { m in var s = MWSlot(); s.type = m; return s }
        return d
    }

    private func row(_ id: Int, title: String = "v", detail: MWProfileDetail? = nil) -> MWProfileRow {
        MWProfileRow(id: id, profileId: id * 10, title: title, coverUrl: nil,
                     detail: detail, summary: nil, pictures: [])
    }

    /// The view's own wiring, so a test exercises the same composition the panel does rather than a
    /// hand-built `ImportPick` the panel could never produce.
    private func plan(rows: [MWProfileRow], defaultInstanceId: Int?) -> String {
        let picked = MakerWorld.preselect(rows, defaultInstanceId: defaultInstanceId)
        return MacExploreCopy.importPlan(
            MacExploreCopy.importPick(
                pickedId: picked?.id,
                pickedTitle: picked?.title,
                pickedPublishesDetail: picked?.detail != nil,
                recommendedId: defaultInstanceId,
                recommendationIsListed: defaultInstanceId.map { want in
                    rows.contains { $0.id == want }
                } ?? false
            )
        )
    }

    // MARK: Announcing a finished import — the guard that was on one twin only

    /// The regression this file exists for. The failure path asked "is this model still selected?"
    /// and the success path did not, so an import that LANDED while the user had moved on reported
    /// nowhere at all — no card (that model is not on screen) and no toast.
    func testAnImportThatFinishesUnderAnotherSelectionIsAnnounced() {
        XCTAssertTrue(MacExploreCopy.announcesInToast(finished: 1400373, selected: 40146),
                      "a background import's outcome must reach the window when its own card cannot")
    }

    func testAnImportThatFinishesOnTheSelectedModelIsNotAnnouncedTwice() {
        XCTAssertFalse(MacExploreCopy.announcesInToast(finished: 40146, selected: 40146),
                       "the receipt card under the button already says it — a toast would repeat it")
    }

    /// Deselecting is not "still watching": with nothing selected the inspector draws its empty
    /// state, so the receipt has no card to appear in.
    func testAnImportThatFinishesWithNothingSelectedIsAnnounced() {
        XCTAssertTrue(MacExploreCopy.announcesInToast(finished: 40146, selected: nil))
    }

    // MARK: What the announcement says

    /// "Reports where the file landed" is the promise. A toast that only said "done" would keep the
    /// half that is easy and drop the half that was promised.
    func testTheLandedToastNamesTheFile() {
        let text = MacExploreCopy.landedToast(filename: "bracket.3mf", libraryFileId: 91,
                                              wasExisting: false)
        XCTAssertTrue(text.contains("bracket.3mf"), text)
        XCTAssertTrue(text.contains("Added to your library"), text)
        XCTAssertFalse(text.contains("91"), "the id is the fallback, not an addition")
    }

    func testTheLandedToastSaysWhenNothingWasDownloadedTwice() {
        let text = MacExploreCopy.landedToast(filename: "bracket.3mf", libraryFileId: 91,
                                              wasExisting: true)
        XCTAssertTrue(text.contains("Already in your library"), text)
        XCTAssertTrue(text.contains("Nothing was downloaded twice."), text)
    }

    /// `filename` is optional in `MakerWorldImportResponse`, and an empty string is the same absence
    /// wearing different clothes. Either way the sentence must still end on something.
    func testTheLandedToastFallsBackToTheLibraryIdWhenTheServerNamesNoFile() {
        for name in [nil, "", "   "] as [String?] {
            let text = MacExploreCopy.landedToast(filename: name, libraryFileId: 91,
                                                  wasExisting: false)
            XCTAssertTrue(text.contains("library file 91"), text)
            XCTAssertFalse(text.hasSuffix("— ."), text)
        }
    }

    // MARK: Whose choice the import is acting on

    /// The measured shape of model 40146: MakerWorld pre-selects a profile that publishes no
    /// details — the kind that answers `400` — so `preselect` substitutes a described one. The
    /// caption must not hand MakerWorld the credit for the app's own substitution.
    func testASubstitutedVersionIsNotCreditedToMakerWorld() {
        let rows = [row(1, title: "Their pick"),                          // no detail — theirs
                    row(2, title: "0.20 mm standard", detail: detail())]
        let text = plan(rows: rows, defaultInstanceId: 1)

        XCTAssertTrue(text.contains("0.20 mm standard"), text)
        XCTAssertFalse(text.contains("Import uses MakerWorld’s recommended version"),
                       "MakerWorld recommended row 1; Import is taking row 2. \(text)")
        XCTAssertTrue(text.contains("publishes no print details"), text)
        XCTAssertTrue(text.contains("instead"), text)
    }

    /// The other half of the same honesty: when their pick IS what Import takes, say so.
    func testMakerWorldsPickIsCreditedWhenItIsTheOneImportTakes() {
        let rows = [row(1, title: "Their pick", detail: detail()),
                    row(2, title: "Another", detail: detail())]
        XCTAssertEqual(plan(rows: rows, defaultInstanceId: 1),
                       "Import uses MakerWorld’s recommended version, Their pick.")
    }

    /// Their pick stands only because nothing else published anything either — `preselect` has no
    /// described row to prefer. Saying "recommended" and stopping would omit the one fact that
    /// predicts the refusal.
    func testTheirUndescribedPickCarriesTheRefusalWarningWhenNothingElseIsDescribed() {
        let rows = [row(1, title: "Their pick"), row(2, title: "Another")]
        let text = plan(rows: rows, defaultInstanceId: 1)

        XCTAssertTrue(text.contains("Their pick"), text)
        XCTAssertTrue(text.contains("recommended version"), text)
        XCTAssertTrue(text.contains("refuses to release"),
                      "an undescribed profile is the kind MakerWorld refuses — say so before the "
                      + "502 arrives. \(text)")
    }

    /// A `defaultInstanceId` naming an instance that is not among the listed rows is a different
    /// story from one we rejected, and gets a different sentence — "we substituted" would be untrue.
    func testARecommendationThatWasNeverListedSaysSo() {
        let rows = [row(2, title: "0.20 mm standard", detail: detail())]
        let text = plan(rows: rows, defaultInstanceId: 999)

        XCTAssertTrue(text.contains("isn’t among the ones it listed"), text)
        XCTAssertTrue(text.contains("0.20 mm standard"), text)
    }

    func testNoRecommendationSaysMakerWorldNamedNone() {
        let rows = [row(2, title: "0.20 mm standard", detail: detail())]
        XCTAssertEqual(plan(rows: rows, defaultInstanceId: nil),
                       "MakerWorld names no recommended version, so Import uses 0.20 mm standard.")
    }

    /// With no rows there is nothing to attribute to anyone: the import falls back to the resolve's
    /// own profile id, and the sentence says that rather than naming a version that does not exist.
    func testNoRowsFallsBackToTheResolvesOwnProfile() {
        XCTAssertEqual(MacExploreCopy.importPick(pickedId: nil, pickedTitle: nil,
                                                 pickedPublishesDetail: false,
                                                 recommendedId: 1, recommendationIsListed: false),
                       .resolveProfile)
        XCTAssertEqual(plan(rows: [], defaultInstanceId: 1),
                       "Import takes the one profile the resolve published.")
    }

    /// Every branch has to name a version, or the caption stops answering the question it exists for
    /// ("what will Import actually do?").
    func testEveryPlanNamesTheVersionImportWillUse() {
        let named: [MacExploreCopy.ImportPick] = [
            .recommended("A"), .recommendedUndescribed("A"), .substituted("A"),
            .recommendedMissing("A"), .unrecommended("A")
        ]
        for pick in named {
            XCTAssertTrue(MacExploreCopy.importPlan(pick).contains("A"), "\(pick)")
        }
    }

    // MARK: The counts the summary states

    /// The tray-count-aware placement, read the way the inspector reads it. One PLA spool cannot
    /// serve a version that asks for three PLA slots, and "N fit your filament" is the sentence that
    /// would otherwise claim it can.
    func testAMultiSlotVersionNeedsAsManyTraysAsItHasSlots() {
        let rows = [row(1, title: "3-colour", detail: detail(materials: ["PLA", "PLA", "PLA"]))]
        let oneSpool = [VersionGrouping.Tray(unit: 0, slot: 0, type: "PLA")]

        let placed = VersionGrouping.place(rows, defaultInstanceId: nil, trays: oneSpool)
        XCTAssertEqual(placed.first?.group, .needsFilament,
                       "one spool, three slots — the row does not fit")
    }

    /// The other side of `knowsFilament`: with no AMS reading nothing is marked missing, which is
    /// why the inspector withholds the "fit your filament" clause entirely rather than counting
    /// rows that merely happen to be labelled.
    func testNoAmsReadingGreysNothingOut() {
        let rows = [row(1, detail: detail(materials: ["PETG"]))]
        let placed = VersionGrouping.place(rows, defaultInstanceId: nil, trays: [])
        XCTAssertNotEqual(placed.first?.group, .needsFilament,
                          "an empty status is 'we don't know', not 'you have nothing'")
    }
}
#endif
