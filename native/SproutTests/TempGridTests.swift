import XCTest
@testable import Sprout

/// `TempCard.present` decides both what the temperature grid shows and — through `TempCard.id` —
/// what SwiftUI treats as "the same card" between two status frames. The identity half is the part
/// that regressed: a `UUID` minted per call made every card a new view on every WebSocket frame, so
/// `RollingNumber`, `HeatBar` and `PulseDot` were re-inserted rather than animated. These tests pin
/// the invariant that identity now rests on: labels are unique within a grid, and stable across
/// frames whose values change.
final class TempGridTests: XCTestCase {

    private func dual(nozzleNow: Int = 200, nozzle2Now: Int = 30) -> DashVM {
        var vm = DashVM()
        vm.nozzles = [
            NozzleVM(now: nozzleNow, target: 220, heating: true, active: true, index: 0),
            NozzleVM(now: nozzle2Now, target: 0, heating: false, active: false, index: 1),
        ]
        vm.bedNow = 58
        vm.bedTarget = 60
        vm.bedHeating = true
        return vm
    }

    // MARK: - Shape

    func testSingleNozzleMachineHasNozzleAndBed() {
        var vm = DashVM()
        vm.nozzleNow = 210
        vm.nozzleTarget = 220
        vm.bedNow = 60
        vm.bedTarget = 60
        let cards = TempCard.present(vm, heatingEnabled: true)
        XCTAssertEqual(cards.map(\.label), ["Nozzle", "Bed"])
        XCTAssertEqual(cards[0].now, 210)
        XCTAssertEqual(cards[0].target, 220)
    }

    func testDualNozzleMachineLabelsLeftAndRightInPayloadOrder() {
        let cards = TempCard.present(dual(), heatingEnabled: true)
        XCTAssertEqual(cards.map(\.label), ["Left nozzle", "Right nozzle", "Bed"])
        // `nozzle` is the LEFT head, and the driven one carries the highlight.
        XCTAssertTrue(cards[0].active)
        XCTAssertFalse(cards[1].active)
    }

    func testChamberCardOnlyOnEnclosedMachines() {
        var vm = dual()
        XCTAssertFalse(TempCard.present(vm, heatingEnabled: true).contains { $0.label == "Chamber" })
        vm.hasChamber = true
        vm.chamberNow = 34
        vm.chamberTarget = 40
        let cards = TempCard.present(vm, heatingEnabled: true)
        XCTAssertEqual(cards.map(\.label), ["Left nozzle", "Right nozzle", "Bed", "Chamber"])
        XCTAssertEqual(cards.last?.now, 34)
    }

    // MARK: - Identity

    func testIdIsTheLabel() {
        for card in TempCard.present(dual(), heatingEnabled: true) {
            XCTAssertEqual(card.id, card.label)
        }
    }

    func testEveryShapeProducesUniqueIds() {
        var shapes: [DashVM] = []
        var single = DashVM()
        shapes.append(single)
        single.hasChamber = true
        shapes.append(single)
        shapes.append(dual())
        var dualChamber = dual()
        dualChamber.hasChamber = true
        shapes.append(dualChamber)
        // No machine reports three heads today, but a duplicate id would break `ForEach` silently
        // rather than loudly, so the labelling has to stay unique regardless of the payload.
        var triple = dual()
        triple.nozzles.append(NozzleVM(now: 25, target: 0, heating: false, active: false, index: 2))
        triple.hasChamber = true
        shapes.append(triple)

        for vm in shapes {
            let ids = TempCard.present(vm, heatingEnabled: true).map(\.id)
            XCTAssertEqual(Set(ids).count, ids.count, "duplicate card id in \(ids)")
        }
    }

    func testIdsAreStableWhileTemperaturesChange() {
        // The live case: one status frame later, every value has moved and nothing about identity
        // may have. This is exactly what the per-call `UUID` broke.
        let before = TempCard.present(dual(nozzleNow: 200, nozzle2Now: 30), heatingEnabled: true)
        let after = TempCard.present(dual(nozzleNow: 214, nozzle2Now: 31), heatingEnabled: true)
        XCTAssertEqual(before.map(\.id), after.map(\.id))
        XCTAssertNotEqual(before, after, "the values must still be seen to change")
    }

    func testPresentIsPure() {
        XCTAssertEqual(TempCard.present(dual(), heatingEnabled: true), TempCard.present(dual(), heatingEnabled: true))
    }

    // MARK: - Heating gate

    func testHeatingEnabledFalseSuppressesEveryHeatingFlag() {
        var vm = dual()
        vm.hasChamber = true
        vm.chamberHeating = true
        let cards = TempCard.present(vm, heatingEnabled: false)
        XCTAssertTrue(cards.allSatisfy { !$0.heating })
        // …and the same view model with the gate open does report it, so the assertion above is not
        // passing for the wrong reason.
        XCTAssertTrue(TempCard.present(vm, heatingEnabled: true).contains { $0.heating })
    }

    func testNozzleLabelFallsBackToNumbering() {
        XCTAssertEqual(TempCard.nozzleLabel(index: 0, of: 1), "Nozzle")
        XCTAssertEqual(TempCard.nozzleLabel(index: 0, of: 2), "Left nozzle")
        XCTAssertEqual(TempCard.nozzleLabel(index: 1, of: 2), "Right nozzle")
        XCTAssertEqual(TempCard.nozzleLabel(index: 2, of: 3), "Nozzle 3")
    }
}
