#if os(macOS)
import Foundation
import SwiftUI

/// The **Hardware** inspector (§4, prototype lines 610-630): the triage card, then one readings card
/// per AMS unit, then what `⌘R` actually refetches.
///
/// §4 moves the triage card OUT of the content column on Mac and makes it the inspector's whole job.
/// That is the one place in this section where the inspector writes back to the content column — a
/// triage line sets `HardwareStore.segment`, because "the thing that needs you" and "the pane it
/// lives in" are the same fact. It is not a second navigation surface: there is nothing here that
/// isn't about the hardware currently reporting.
///
/// Everything shown is live socket state or `HardwareStore`'s own load. No fetch is started here —
/// an inspector that polled would double the section's traffic and keep polling with the section
/// switched away. (`MacSectionContent` owns the store's lifetime for both columns.)
@MainActor
struct MacHardwareInspector: View {
    let model: AppModel
    /// Does this instance bring its own `ScrollView`?
    ///
    /// True in the inspector column, which is its own scrolling region. False when the panes fall
    /// back INTO the section (`MacInspectorPlacement`), because the section already scrolls and
    /// nesting one scroll view in another gives an ambiguous height and two scrollbars.
    ///
    /// A parameter rather than a computed `panes` property read from outside, because a SwiftUI
    /// view's `@State` and `@Environment` are only established once it is installed in the
    /// hierarchy — reading `SomeInspector(model:).panes` from another view would evaluate those
    /// wrappers before SwiftUI has set them up.
    var scrolls = true


    @Environment(\.palette) private var c
    @Environment(\.metrics) private var m

    private var hw: HardwareStore { model.hardware }
    private var status: PrinterStatus? { model.status?.status }

    var body: some View {
        // Each of these was being recomputed several times per render, and none of them is cheap:
        // `model.vm` is a computed property that re-runs the whole dashboard presenter (`AmsTopology`
        // included) on every read, and `triage` used to run it AND a full nozzle-rack parse — three
        // times over, plus one more presentation per unit card. Read once, passed down.
        let dash = model.vm
        let units = dash.amsUnits
        let items = MacHardwareTriage.items(model, dash: dash)
        let dryers = Dryer.present(status)

        // WHY a unit has no dryer, asked once for the machine. It is a machine-level fact — the
        // printer either reports drying support or it does not — and `Dryer.present`'s empty answer
        // means something different in each case. See `MacDryingCopy.noDryerCause`.
        let noDryerCause = MacDryingCopy.noDryerCause(supportsDrying: status?.supportsDrying)

        return MacInspectorScroll(scrolls: scrolls) {
            VStack(alignment: .leading, spacing: m.cardGap) {
                triageCard(items, units: units)
                ForEach(units) { unit in
                    unitCard(unit,
                             dryer: dryers.first { $0.amsId == unit.id },
                             noDryerCause: noDryerCause,
                             multiUnit: units.count > 1)
                }
                if units.isEmpty { noUnitsCard }
                refreshNote
            }
            .padding(m.gutter)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(c.bg)
    }

    // MARK: - Triage

    /// The prototype's red card, plus the case the prototype never draws: nothing wrong.
    ///
    /// `HardwareTriage.headline` returns nil when there is nothing to say, and on iOS that means no
    /// card at all — correct there, where the card is stealing room from the filament list. Here the
    /// card IS the column's reason to exist, so an empty inspector would read as broken rather than
    /// as good news. Same data, opposite right answer.
    @ViewBuilder
    private func triageCard(_ items: [HardwareTriage.Item], units: [AmsUnitVM]) -> some View {
        if let headline = HardwareTriage.headline(items), let worst = MacHardwareSeverity.worst(items) {
            HwCard(fill: worst.color(c).opacity(0.1), stroke: worst.color(c).opacity(0.4)) {
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 8) {
                        Circle().fill(worst.color(c)).frame(width: 7, height: 7)
                        Text(headline)
                            .scaledFont(12.5, weight: .semibold)
                            .foregroundStyle(c.t1)
                    }
                    ForEach(items) { item in triageRow(item) }
                }
            }
        } else {
            HwCard {
                HStack(spacing: 8) {
                    Circle().fill(c.running).frame(width: 7, height: 7)
                    Text(clearLine(units))
                        .scaledFont(12.5, weight: .medium)
                        .foregroundStyle(c.t2)
                }
            }
        }
    }

    /// "Nothing needs you" is a claim, and it is only true of the things that have LOADED.
    /// `HardwareStore.maintenanceItems` is `[]` both while the maintenance fetch is in flight and
    /// after it failed — reading either as "no reminders are due" is the same silent lie as a
    /// 200-with-an-empty-list. So the card says which it is.
    private func clearLine(_ units: [AmsUnitVM]) -> String {
        switch hw.maint {
        case .loading: "Checking service reminders…"
        case .failed: "Nothing wrong here, but service reminders didn’t load"
        case .loaded: units.isEmpty ? "No hardware reporting yet" : "Nothing needs you"
        }
    }

    /// One line per problem, each jumping to the pane that fixes it.
    ///
    /// A `Button`, not a tappable row: on Mac a thing you click has to look like a control, and the
    /// keyboard has to reach it.
    ///
    /// The pane it lands on is now able to account for every item this can raise — including the
    /// overdue reminder whose `enabled` Bambuddy never reported, which the Service pane's own list
    /// still drops (`HardwareStore.serviceItems` filters `enabled ?? false` while `HardwareTriage`
    /// counts `enabled != false`). Until those two predicates agree the pane says out loud what it
    /// is not listing rather than showing an empty screen under a red dot. **Root fix reported.**
    private func triageRow(_ item: HardwareTriage.Item) -> some View {
        Button {
            hw.segment = item.segment
        } label: {
            HStack(spacing: 8) {
                Circle()
                    .fill(MacHardwareSeverity.of(item).color(c))
                    .frame(width: 6, height: 6)
                Text(item.text)
                    .scaledFont(11.5, weight: .medium)
                    .foregroundStyle(c.t2)
                    .monospacedDigit()
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 6)
                Text("\(item.segment.label) ›")
                    .scaledFont(11, weight: .semibold)
                    .foregroundStyle(c.accent)
                    .fixedSize()
            }
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .help("Show this in the \(item.segment.label) pane")
        .accessibilityLabel("\(item.text). Show in \(item.segment.label).")
    }

    // MARK: - Unit readings

    /// One card per AMS unit — humidity, temperature, dryer, slots loaded.
    ///
    /// Per unit rather than one machine-wide reading: an AMS 2 Pro and an AMS HT sit at very
    /// different humidity and temperature, and the RN app's single `ams[0]` figure was actively
    /// misleading on a three-unit machine.
    private func unitCard(_ unit: AmsUnitVM, dryer: DryerVM?,
                          noDryerCause: MacDryingCopy.NoDryerCause, multiUnit: Bool) -> some View {
        HwCard {
            VStack(alignment: .leading, spacing: 0) {
                Text(unitHeading(unit, multiUnit: multiUnit))
                    .font(.mono(m.monoLabel, weight: .bold))
                    .tracking(1.1)
                    .foregroundStyle(c.t3)

                VStack(spacing: 9) {
                    reading("Humidity", humidityText(unit), ink: humidityInk(unit))
                    reading("Temperature", tempText(unit))
                    reading("Dryer", MacDryingCopy.dryerLine(dryer, cause: noDryerCause), mono: false)
                        // A four-word reading cannot carry the distinction on its own, and this one
                        // is the difference between "buy nothing, the printer just isn't saying" and
                        // "this unit will never dry a spool".
                        .help(MacDryingCopy.dryerNote(dryer, cause: noDryerCause))
                    reading("Slots loaded", "\(unit.loaded) of \(unit.capacity)")
                }
                .padding(.top, 11)
            }
        }
    }

    /// "AMS 2 PRO · #4C1E" — the serial tail only when there is more than one unit to tell apart. Two
    /// AMS 2 Pro units are identical down to the label, and it is the only thing that distinguishes
    /// them when you are stood at the machine.
    private func unitHeading(_ unit: AmsUnitVM, multiUnit: Bool) -> String {
        let tail = (multiUnit && !unit.serialTail.isEmpty) ? " · #\(unit.serialTail)" : ""
        return unit.label.uppercased() + tail
    }

    private func reading(_ label: String, _ value: String, ink: Color? = nil, mono: Bool = true) -> some View {
        HStack(spacing: 8) {
            Text(label)
                .scaledFont(11.5, weight: .medium)
                .foregroundStyle(c.t3)
                .frame(maxWidth: .infinity, alignment: .leading)
            Text(value)
                .font(mono ? Font.mono(11.5, weight: .medium) : Font.system(size: 11.5, weight: .medium))
                .monospacedDigit()
                .foregroundStyle(ink ?? c.t1)
                .fixedSize()
        }
    }

    private func humidityText(_ unit: AmsUnitVM) -> String {
        guard let h = unit.humidity, h.isFinite, h > 0 else { return "—" }
        return "\(SafeInt.rounded(h)) %"
    }

    /// Amber at exactly the threshold the drying copy quotes, so the reading and the reason agree.
    private func humidityInk(_ unit: AmsUnitVM) -> Color? {
        guard let h = unit.humidity, h.isFinite, h >= HardwareTriage.dampRH else { return nil }
        return c.heating
    }

    private func tempText(_ unit: AmsUnitVM) -> String {
        guard let t = unit.tempC, t.isFinite, t > 0 else { return "—" }
        return String(format: "%.1f °C", t)
    }

    private var noUnitsCard: some View {
        HwCard {
            VStack(alignment: .leading, spacing: 6) {
                Text("NO FILAMENT HUB")
                    .font(.mono(m.monoLabel, weight: .bold))
                    .tracking(1.1)
                    .foregroundStyle(c.t3)
                Text("This printer isn’t reporting an AMS. Nozzles and service reminders still work.")
                    .scaledFont(11.5)
                    .foregroundStyle(c.t2)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    // MARK: - Footer

    /// What `⌘R` does here, said out loud.
    ///
    /// Nozzles is the case worth writing down: it is live socket state, so there is genuinely
    /// nothing to refetch — `HardwareStore.refresh(.nozzles)` is a deliberate no-op. Without this
    /// line, pressing `⌘R` on the Nozzles pane looks like a refresh that failed.
    private var refreshNote: some View {
        HwCard {
            Text("Filament and Service refetch on ⌘R. Nozzles is live socket state and needs no refresh.")
                .scaledFont(11.5)
                .foregroundStyle(c.t3)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

// MARK: - Card shell

/// Every card in this column: one radius, one padding, one border, all from the metrics tokens.
///
/// Written once because it was written five times — each with a hard-coded `cornerRadius: 11` (the
/// token is 12) and a hand-typed `.padding(.horizontal, 14)` (the token is `m.cardPadding`, 14).
/// Ten literals for two numbers, in the one column that sits directly beside a section using the
/// tokens throughout, is exactly how a 1 pt drift survives a redesign.
///
/// `MacPrinterCard` in `Views/Mac/Sections/MacPrinterSection.swift` is the same shell and is the
/// right long-term home; collapsing into it means editing a file this pass does not own.
/// **Reported.**
private struct HwCard<Content: View>: View {
    var fill: Color?
    var stroke: Color?
    private let content: Content

    @Environment(\.palette) private var c
    @Environment(\.metrics) private var m

    init(fill: Color? = nil, stroke: Color? = nil, @ViewBuilder content: () -> Content) {
        self.fill = fill
        self.stroke = stroke
        self.content = content()
    }

    var body: some View {
        content
            .padding(m.cardPadding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: m.cardRadius, style: .continuous).fill(fill ?? c.s1)
            )
            .overlay(
                RoundedRectangle(cornerRadius: m.cardRadius, style: .continuous).stroke(stroke ?? c.line)
            )
    }
}
#endif
