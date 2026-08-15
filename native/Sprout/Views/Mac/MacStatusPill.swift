#if os(macOS)
import SwiftUI

/// The toolbar's state readout — `PRINTING · 62 %`, `IDLE`, `OFFLINE` (§3).
///
/// The text is a pure function of `DashVM` and nothing else. That is the whole point: `DashVM` is
/// this app's single source of print-state classification, and a toolbar that re-derived "is it
/// printing?" from `status.state` would be a second answer to a question that already has one —
/// free to disagree with the hero card six inches below it.
enum MacStatusPill {
    /// Percentage is appended only while a print is actually running. On `.complete` the progress
    /// integer is still 100 and on `.error` it is whatever it stopped at; showing either would read
    /// as a live number on a machine that is not moving.
    static func text(_ vm: DashVM) -> String {
        let state = vm.stateLabel.uppercased()
        guard vm.kind == .live else { return state }
        return "\(state) · \(vm.progressInt) %"
    }
}

struct MacStatusPillView: View {
    let vm: DashVM
    @Environment(\.palette) private var c
    @Environment(\.metrics) private var m

    var body: some View {
        Text(MacStatusPill.text(vm))
            .font(.mono(m.monoLabel, weight: .medium))
            .tracking(0.6)
            .foregroundStyle(c.t3)
            // Tabular figures on every ticking number, per §8 — without them the pill's width
            // jitters once a second as the percentage changes.
            .monospacedDigit()
            .lineLimit(1)
            .accessibilityLabel(MacStatusPill.text(vm).lowercased())
    }
}
#endif
