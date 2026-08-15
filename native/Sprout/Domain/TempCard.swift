import Foundation

/// One temperature readout, derived from `DashVM`.
///
/// Lives in `Domain/` rather than beside a view because two platforms lay the same cards out
/// differently — iOS stacks them two per row, macOS puts four across (§8) — while the question of
/// WHICH cards exist, what they are called and whether each is heating has exactly one answer.
/// `TempGridTests` pins that answer; the layouts are free to disagree.
///
/// Identity is the LABEL, not a fresh `UUID`. The card list is rebuilt on every body pass —
/// `DashVM` changes on every WebSocket frame, so roughly once a second during a print — and a new
/// id per pass makes SwiftUI tear each card down and re-insert it instead of updating it. That
/// reset `RollingNumber`'s numeric transition, `HeatBar`'s `shimmer` and `PulseDot`'s `dim` every
/// frame, so temperatures snapped and neither loop could complete a single leg. The labels are
/// unique for every printer shape, which is the invariant this identity rests on.
struct TempCard: Identifiable, Equatable, Sendable {
    let label: String
    let now: Int
    let target: Int
    let heating: Bool
    var active: Bool = false

    var id: String { label }

    /// Position-ordered, matching the temperature keys: `nozzle` is the LEFT head, `nozzle2` the
    /// right. The third case cannot happen on any machine Bambuddy talks to, but a duplicate label
    /// would silently break `ForEach` identity, so it is named rather than assumed away.
    static func nozzleLabel(index: Int, of total: Int) -> String {
        guard total > 1 else { return "Nozzle" }
        switch index {
        case 0: return "Left nozzle"
        case 1: return "Right nozzle"
        default: return "Nozzle \(index + 1)"
        }
    }

    /// `heatingEnabled` is false in the print-complete block: a bed still coming down off 60° is not
    /// heating for a job, and should not animate as if it were.
    static func present(_ vm: DashVM, heatingEnabled: Bool) -> [TempCard] {
        var out: [TempCard] = []
        if vm.nozzles.count > 1 {
            for (i, n) in vm.nozzles.enumerated() {
                out.append(TempCard(
                    label: nozzleLabel(index: i, of: vm.nozzles.count),
                    now: n.now, target: n.target,
                    heating: heatingEnabled && n.heating,
                    active: n.active
                ))
            }
        } else {
            out.append(TempCard(label: "Nozzle", now: vm.nozzleNow, target: vm.nozzleTarget, heating: heatingEnabled && vm.nozzleHeating))
        }
        out.append(TempCard(label: "Bed", now: vm.bedNow, target: vm.bedTarget, heating: heatingEnabled && vm.bedHeating))
        if vm.hasChamber {
            out.append(TempCard(label: "Chamber", now: vm.chamberNow, target: vm.chamberTarget, heating: heatingEnabled && vm.chamberHeating))
        }
        return out
    }
}
