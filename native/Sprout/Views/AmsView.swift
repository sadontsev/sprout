import Foundation
import SwiftUI

// MARK: - Screen

/// The **Hardware** tab: filament (every AMS unit and every slot across all of them), the per-unit
/// drying cards, the toolhead nozzles, and the maintenance reminders.
///
/// Topology comes from `AmsTopology` (via `DashVM`) and drying from `Dryer` — nothing here re-derives
/// either. The two things this screen fetches for itself, spool assignments and maintenance, are what
/// pull-to-refresh reloads; trays, temperatures and the drying countdown are live WebSocket state and
/// need no refetch.
@MainActor
struct AmsView: View {
    let model: AppModel

    @Environment(\.palette) private var c

    /// nil while the first assignment fetch is in flight. The client swallows its own errors and
    /// returns `[]`, so an empty array means "no spools mapped", never "the fetch failed" — either
    /// way the slot cards degrade to status-only tray data.
    @State private var assigns: [SlotAssignment]?
    @State private var maint: MaintLoad = .loading
    /// Maintenance item currently being marked done.
    @State private var maintBusy: Int?
    @State private var notice: HwNotice?
    @State private var lanAlert = false

    private var vm: DashVM { model.vm }
    private var status: PrinterStatus? { model.status?.status }
    private var dryers: [DryerVM] { Dryer.present(status) }
    private var amsLabel: String { PrinterProfile.forPrinter(model.printer).amsLabel }
    private var locked: LockedActions { LockedActions(mode: model.lanMode, explaining: $lanAlert) }

    var body: some View {
        HwPage(title: "Hardware") {
            HwSectionHead(
                label: "FILAMENT",
                right: vm.amsUnits.count > 1 ? "\(vm.amsUnits.count) units" : amsLabel,
                first: true
            )
            unitChips
            dryerCards
            slotCards
            NozzlesSection(status: status, dash: vm)
            MaintenanceSection(
                state: maint,
                busyId: maintBusy,
                onRetry: { Task { await reloadMaintenance() } },
                onMarkDone: markDone
            )
        }
        .refreshable { await reload() }
        .task(id: model.printerId) { await reload() }
        .lockedActionAlert($lanAlert)
        .hwNotice($notice)
    }

    // MARK: Filament header

    /// One chip per unit. An AMS 2 Pro and an AMS HT sit at very different humidity and temperature,
    /// so a single machine-wide reading (this used to show `ams[0]`'s) was actively misleading.
    @ViewBuilder private var unitChips: some View {
        FlowLayout(spacing: 8, rowSpacing: 8) {
            Text("\(vm.ams.filter { !$0.empty }.count) of \(vm.ams.isEmpty ? 4 : vm.ams.count) slots loaded")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(c.t3)

            ForEach(vm.amsUnits) { u in
                HwChip {
                    Text(u.label).font(.mono(10, weight: .bold)).foregroundStyle(c.t2)
                    if let h = u.humidity, h > 0 {
                        Image(systemName: "drop").font(.system(size: 10)).foregroundStyle(c.t3)
                        Text("\(Int(h.rounded()))%").font(.mono(10.5)).foregroundStyle(c.t3)
                    }
                    if let t = u.tempC, t > 0 {
                        Image(systemName: "thermometer.medium").font(.system(size: 10)).foregroundStyle(c.t3)
                        Text(String(format: "%.1f°", t)).font(.mono(10.5)).foregroundStyle(c.t3)
                    }
                    // Two AMS 2 Pro units are identical down to the label; the serial tail is the
                    // only thing that tells them apart when you are stood at the machine.
                    if vm.amsUnits.count > 1, !u.serialTail.isEmpty {
                        Text("#\(u.serialTail)").font(.mono(9.5)).foregroundStyle(c.t3)
                    }
                    // Extruder 0 is the RIGHT/main head on the H2 series — this chip shipped
                    // inverted once. With a Filament Track Switch fitted no unit has a fixed
                    // extruder at all, so say "auto" rather than showing a stale binding for some
                    // units and nothing for the others.
                    if vm.amsUnits.count > 1 {
                        if vm.amsRouting == .switch {
                            Text("→ auto").font(.mono(10)).foregroundStyle(c.t3)
                        } else if !AmsTopology.extruderSide(u.extruder).isEmpty {
                            Text("→ \(AmsTopology.extruderSide(u.extruder))")
                                .font(.mono(10))
                                .foregroundStyle(c.t3)
                        }
                    }
                }
            }
        }
        .padding(.horizontal, 20)
    }

    // MARK: Dryers

    /// A RUNNING cycle gets its own card — you need its countdown and Stop. Idle units collapse into
    /// one row: three units meant three identical "Dry damp spools right in the AMS." cards pushing
    /// the actual filament off the screen.
    @ViewBuilder private var dryerCards: some View {
        let active = dryers.filter(\.active)
        ForEach(Array(active.enumerated()), id: \.element.amsId) { pair in
            DryerCard(
                model: model,
                d: pair.element,
                unitLabel: dryerLabel(vm, amsId: pair.element.amsId, index: pair.offset)
            )
        }
        IdleDryers(model: model, vm: vm, dryers: dryers.filter { !$0.active })
    }

    // MARK: Slots

    @ViewBuilder private var slotCards: some View {
        if status == nil {
            ProgressView()
                .tint(c.accent)
                .frame(maxWidth: .infinity)
                .padding(.top, 24)
        } else if vm.ams.isEmpty {
            HwEmptyCard(
                symbol: "shippingbox",
                title: "No filament hub",
                message: "This printer isn’t reporting an AMS. If one is attached, check it’s powered and connected to the printer."
            )
            .padding(.top, 18)
        } else {
            VStack(spacing: 12) {
                ForEach(vm.ams) { slot in
                    SlotCard(
                        model: model,
                        slot: slot,
                        spool: spool(for: slot),
                        // The HT is a single-spool unit whose id IS its tray id; Bambuddy documents
                        // ams/load for tray ids 0-15 only, so its Load button stays hidden.
                        isHt: vm.amsUnits.first { $0.id == slot.unitId }?.kind == .ht,
                        multiUnit: vm.amsUnits.count > 1,
                        locked: locked,
                        notice: $notice
                    )
                }
            }
            .padding(.horizontal, 20)
            .padding(.top, 18)
        }
    }

    /// The inventory spool bound to a slot. Prefer `trayUuid` (RFID); fall back to (unit, LOCAL tray).
    ///
    /// Assignments are stored per (ams_id, LOCAL tray_id), so matching on the tray id alone would
    /// resolve the HT's spool to AMS-0's — both units have a tray 0.
    private func spool(for slot: AmsSlotVM) -> Spool? {
        guard let assigns, !assigns.isEmpty else { return nil }
        let uuid = status?.ams?
            .first { $0.id == slot.unitId }?
            .tray?.first { $0.id == slot.localId }?
            .trayUuid
        if let uuid, !uuid.isEmpty, let hit = assigns.first(where: { $0.spool.trayUuid == uuid }) {
            return hit.spool
        }
        return assigns.first { $0.amsId == slot.unitId && $0.trayId == slot.localId }?.spool
    }

    // MARK: Loading

    private func reload() async {
        guard let client = model.client else { return }
        let id = model.printerId
        async let spools = client.listAssignments(printerId: id)
        async let maintenance = fetchMaintenance(client, id)
        let (loadedSpools, loadedMaintenance) = await (spools, maintenance)
        assigns = loadedSpools
        maint = loadedMaintenance
    }

    private func reloadMaintenance() async {
        guard let client = model.client else { return }
        maint = .loading
        maint = await fetchMaintenance(client, model.printerId)
    }

    private func markDone(_ item: MaintenanceItem) {
        guard let client = model.client else { return }
        maintBusy = item.id
        let id = item.id
        Task {
            do {
                try await client.performMaintenance(id)
                await reloadMaintenance()
            } catch {
                notice = HwNotice(title: "Couldn’t update", message: errorDetail(error))
            }
            maintBusy = nil
        }
    }
}

/// Unit name for a dryer card; falls back to a positional label when the unit isn't in the VM. nil on
/// a single-unit machine — there is nothing to disambiguate.
private func dryerLabel(_ vm: DashVM, amsId: Int, index: Int) -> String? {
    guard vm.amsUnits.count > 1 else { return nil }
    return vm.amsUnits.first { $0.id == amsId }?.label ?? "AMS \(index + 1)"
}

// MARK: - Slot card

/// One AMS tray: what is in it, where it is, how much is left, and load/unload.
@MainActor
private struct SlotCard: View {
    let model: AppModel
    let slot: AmsSlotVM
    let spool: Spool?
    let isHt: Bool
    let multiUnit: Bool
    let locked: LockedActions
    @Binding var notice: HwNotice?

    @Environment(\.palette) private var c

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .center, spacing: 14) {
                Swatch(value: swatch, size: 46, radius: 12, empty: slot.empty)

                VStack(alignment: .leading, spacing: 0) {
                    HStack(spacing: 8) {
                        Text(title)
                            .font(.system(size: 16, weight: .bold))
                            .foregroundStyle(c.t1)
                            .lineLimit(1)
                        if slot.active {
                            slotTag("ACTIVE", ink: c.accent, fill: c.accentDim)
                        }
                        // Which nozzle THIS spool feeds. With a Filament Track Switch fitted the
                        // unit no longer has a fixed extruder, so the per-slot answer is the only
                        // true one. Never on an empty slot: there is no filament in it to feed
                        // anything.
                        if !slot.empty, !AmsTopology.extruderSide(slot.extruder).isEmpty {
                            slotTag("→ \(AmsTopology.extruderSide(slot.extruder).uppercased())", ink: c.t2, fill: c.s3)
                        }
                    }
                    Text(slotName)
                        .font(.mono(11, weight: .medium))
                        .foregroundStyle(c.t3)
                        .lineLimit(1)
                        .padding(.top, 5)
                    // Two lines, not one truncated one: the location is what you need when you are
                    // stood at the printer, the spool name is what you need when you are choosing.
                    if !spoolLine.isEmpty {
                        Text(spoolLine)
                            .font(.system(size: 11, weight: .medium))
                            .lineSpacing(4)
                            .foregroundStyle(c.t3)
                            .lineLimit(2)
                            .padding(.top, 2)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                if !slot.empty {
                    VStack(alignment: .trailing, spacing: 2) {
                        if let grams {
                            Text("\(Int(grams.rounded()))g")
                                .font(.mono(17, weight: .bold))
                                .foregroundStyle(c.t1)
                            Text(slot.pct).font(.mono(10)).foregroundStyle(c.t3)
                        } else {
                            Text(slot.pct)
                                .font(.mono(17, weight: .bold))
                                .foregroundStyle(c.t1)
                        }
                    }
                    .fixedSize()
                }
            }

            if !slot.empty {
                HStack {
                    Spacer(minLength: 0)
                    unloadButton
                }
                .padding(.top, 14)
            } else if !isHt {
                loadButton.padding(.top, 14)
            }
        }
        .padding(16)
        .hwCard(18, fill: c.s1, border: slot.active ? c.accent : c.line, width: slot.active ? 1.5 : 1)
        .shadow1()
    }

    // MARK: Composition
    //
    // Every line below encodes a fixed bug: a swatch cannot say "white" (on a white card it is a
    // hole) and the row otherwise read just "PETG", so the colour is named in words too — but a
    // vendor's own name always wins.

    private var swatch: String? {
        spool.flatMap { FilamentColor.norm($0.rgba) } ?? slot.color
    }

    private var title: String {
        if let spool {
            if let named = spool.colorName, !named.isEmpty { return "\(named) \(spool.material)" }
            return join([FilamentColor.name(swatch), spool.material], " ")
        }
        if slot.empty { return "Empty slot" }
        return join([FilamentColor.name(swatch), slot.label], " ")
    }

    private var grams: Double? { spool?.gramsRemaining }

    /// The LOCATION always leads: "Slot 1" is ambiguous once a second unit is fitted.
    private var slotName: String {
        multiUnit ? "\(slot.unitLabel) · Slot \(slot.localId + 1)" : "Slot \(slot.localId + 1)"
    }

    /// Brand + preset, dropping a brand the preset name already repeats ("Bambu Lab · Bambu PETG
    /// Basic") — it cost the width that pushed the actually-useful filament name off the line.
    private var spoolLine: String {
        guard let spool else { return "" }
        let brand = spool.brand ?? ""
        let preset = spool.slicerFilamentName ?? ""
        let firstWord = brand.split(separator: " ").first.map(String.init) ?? ""
        let redundant = !brand.isEmpty && !preset.isEmpty && !firstWord.isEmpty
            && preset.lowercased().hasPrefix(firstWord.lowercased())
        return join([redundant ? nil : brand, preset], " · ")
    }

    private func join(_ parts: [String?], _ separator: String) -> String {
        parts.compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: separator)
    }

    // MARK: Chips & actions

    private func slotTag(_ text: String, ink: Color, fill: Color) -> some View {
        Text(text)
            .font(.mono(8.5))
            .tracking(0.5)
            .foregroundStyle(ink)
            .padding(.horizontal, 7)
            .padding(.vertical, 2)
            .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(fill))
            .fixedSize()
    }

    private var unloadButton: some View {
        Tap(action: locked.press(.amsUnload) { run("Unload failed") { try await $0.amsUnload($1) } }) {
            HStack(spacing: 7) {
                if locked.blocked(.amsUnload) {
                    Image(systemName: "lock").font(.system(size: 12)).foregroundStyle(c.t1)
                }
                Text("Unload").font(.system(size: 12, weight: .semibold)).foregroundStyle(c.t1)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(c.s3))
        }
        .locked(.amsUnload, by: locked)
    }

    private var loadButton: some View {
        // GLOBAL tray id, not the flat index — index 4 is the HT, whose id is 128.
        let trayId = slot.globalId
        return Tap(action: locked.press(.amsLoad) {
            run("Load failed") { try await $0.amsLoad($1, trayId: trayId) }
        }) {
            HStack(spacing: 7) {
                if locked.blocked(.amsLoad) {
                    Image(systemName: "lock").font(.system(size: 13)).foregroundStyle(c.accent)
                }
                Text("Load filament").font(.system(size: 13, weight: .semibold)).foregroundStyle(c.accent)
            }
            .frame(maxWidth: .infinity)
            .frame(height: 44)
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(c.line2, lineWidth: 1))
        }
        .locked(.amsLoad, by: locked)
    }

    private func run(_ failureTitle: String, _ work: @escaping @Sendable (BambuddyClient, Int) async throws -> Void) {
        guard let client = model.client else { return }
        let id = model.printerId
        Task {
            do { try await work(client, id) } catch {
                notice = HwNotice(title: failureTitle, message: errorDetail(error))
            }
        }
    }
}

// MARK: - Dryers

/// The idle dryers, behind one row.
///
/// Each idle unit used to render its own collapsed card, all with identical copy, so a three-unit
/// machine spent most of the first screen telling you three times that you can dry filament. One unit
/// still renders directly — wrapping a single card in a disclosure is just a wasted tap.
@MainActor
private struct IdleDryers: View {
    let model: AppModel
    let vm: DashVM
    let dryers: [DryerVM]

    @Environment(\.palette) private var c
    @State private var open = false

    var body: some View {
        if dryers.isEmpty {
            EmptyView()
        } else if dryers.count == 1 {
            DryerCard(model: model, d: dryers[0], unitLabel: dryerLabel(vm, amsId: dryers[0].amsId, index: 0))
        } else {
            VStack(spacing: 0) {
                Tap { open.toggle() } content: {
                    HStack(spacing: 12) {
                        Image(systemName: "wind").font(.system(size: 17)).foregroundStyle(c.t2)
                        VStack(alignment: .leading, spacing: 3) {
                            Text("Filament drying")
                                .font(.system(size: 14, weight: .semibold))
                                .foregroundStyle(c.t1)
                            Text("\(dryers.count) units ready · \(names)")
                                .font(.system(size: 11.5, weight: .medium))
                                .foregroundStyle(c.t3)
                                .lineLimit(1)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        Image(systemName: open ? "chevron.up" : "chevron.down")
                            .font(.system(size: 18))
                            .foregroundStyle(c.t3)
                    }
                    .padding(14)
                    .contentShape(.rect)
                }

                if open {
                    // A VStack, not a bare ForEach: a modifier on a ForEach is applied to every
                    // element, and the bottom inset belongs to the group. Without it the last card
                    // would sit flush against the parent's rounded corner.
                    VStack(spacing: 0) {
                        ForEach(Array(dryers.enumerated()), id: \.element.amsId) { pair in
                            DryerCard(
                                model: model,
                                d: pair.element,
                                unitLabel: dryerLabel(vm, amsId: pair.element.amsId, index: pair.offset)
                            )
                        }
                    }
                    .padding(.bottom, 14)
                }
            }
            .hwCard(16, fill: c.s1, border: c.line)
            .padding(.horizontal, 20)
            .padding(.top, 14)
        }
    }

    private var names: String {
        dryers.enumerated()
            .map { pair in
                dryerLabel(vm, amsId: pair.element.amsId, index: pair.offset) ?? "AMS \(pair.offset + 1)"
            }
            .joined(separator: " · ")
    }
}

/// A manual temperature/duration override, tied to the filament type it was made for.
private struct DryTweak: Equatable, Sendable {
    var type: String
    var temp: Int?
    var hours: Int?
}

/// Handy-style drying: pick a loaded filament → its recommended temp/time (from the RFID/preset, with
/// per-type fallbacks), adjust, optional spool rotation; live cycle detail + Stop while running.
@MainActor
private struct DryerCard: View {
    let model: AppModel
    let d: DryerVM
    /// nil on a single-unit machine.
    let unitLabel: String?

    @Environment(\.palette) private var c
    @State private var open = false
    @State private var selType: String?
    /// Manual ± adjustments, KEYED to the filament type they were made for.
    @State private var tweak: DryTweak?
    @State private var rotate = true
    @State private var busy = false
    @State private var confirmStop = false
    @State private var notice: HwNotice?
    @State private var lanAlert = false
    @State private var verify: Task<Void, Never>?

    private var locked: LockedActions { LockedActions(mode: model.lanMode, explaining: $lanAlert) }

    private var opt: DryOption? {
        d.options.first { $0.type == selType } ?? d.options.first
    }

    /// The options list is live (WS tray updates): if the selected spool is pulled mid-configuration
    /// `opt` silently falls back to another filament, and stale absolute numbers must NOT carry over
    /// — a PA temperature applied to PLA deforms the spool.
    private var activeTweak: DryTweak? {
        guard let tweak, let opt, tweak.type == opt.type else { return nil }
        return tweak
    }

    private var effTemp: Int { activeTweak?.temp ?? opt?.temp ?? 55 }
    private var effHours: Int { activeTweak?.hours ?? opt?.hours ?? 8 }

    var body: some View {
        Group {
            if d.active { activeCard } else { idleCard }
        }
        .padding(.horizontal, 20)
        .padding(.top, 14)
        .lockedActionAlert($lanAlert)
        .hwNotice($notice)
        .alert("Stop drying?", isPresented: $confirmStop) {
            Button("Cancel", role: .cancel) {}
            Button("Stop", role: .destructive) { stop() }
        } message: {
            Text("Ends the current drying cycle.")
        }
        .onDisappear { verify?.cancel() }
    }

    // MARK: Active cycle — what's drying, time left, heating vs holding, Stop.

    private var activeCard: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                PulseDot(color: c.heating, size: 9)
                headline
                    .frame(maxWidth: .infinity, alignment: .leading)

                Tap(disabled: busy, action: locked.press(.dryStop) { confirmStop = true }) {
                    Text("Stop")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(c.t1)
                        .padding(.horizontal, 15)
                        .padding(.vertical, 8)
                        .background(RoundedRectangle(cornerRadius: 11, style: .continuous).fill(c.s3))
                }
                .opacity(locked.style(.dryStop) ?? (busy ? 0.5 : 1))
            }

            remaining
                .padding(.top, 12)

            FlowLayout(spacing: 8, rowSpacing: 8) {
                if let stage = d.stage, let target = d.targetTemp {
                    HwChip(padV: 4) {
                        Image(systemName: "thermometer.medium").font(.system(size: 11)).foregroundStyle(c.heating)
                        Text(stage == .heating ? "heating to \(fmtTemp(target))°" : "holding \(fmtTemp(target))°")
                            .font(.mono(11.5))
                            .foregroundStyle(c.t2)
                    }
                }
                if let humidity = d.humidityPct {
                    HwChip(padV: 4) {
                        Image(systemName: "drop").font(.system(size: 11)).foregroundStyle(c.t3)
                        Text("\(humidity)%").font(.mono(11.5)).foregroundStyle(c.t2)
                    }
                }
            }
            .padding(.top, 10)
        }
        .padding(16)
        .hwCard(16, fill: c.heatingDim, border: c.heating)
    }

    /// One `Text`, not two views: the unit name is an inline continuation of the title, so it wraps
    /// with it rather than being pushed onto its own line. Each run carries its own attributes, so
    /// the outer `Text` never has to override them.
    private var headline: Text {
        let title = Text("Drying \(d.filament.isEmpty ? "filament" : d.filament)")
            .font(.system(size: 15, weight: .bold))
            .foregroundStyle(c.t1)
        guard let unitLabel else { return title }
        let unit = Text(" · \(unitLabel)")
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(c.t3)
        return Text("\(title)\(unit)")
    }

    private var remaining: Text {
        let left = Text(d.remainingText)
            .font(.mono(26, weight: .bold))
            .foregroundStyle(c.t1)
        let unit = Text("  left")
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(c.t3)
        return Text("\(left)\(unit)")
    }

    // MARK: Idle — collapsed row that expands into the full configuration.

    private var idleCard: some View {
        VStack(spacing: 0) {
            Tap { open.toggle() } content: {
                HStack(spacing: 12) {
                    Image(systemName: "wind").font(.system(size: 17)).foregroundStyle(c.t2)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(unitLabel.map { "Filament drying · \($0)" } ?? "Filament drying")
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(c.t1)
                        Text(open ? "This AMS dries up to \(d.maxTemp)°C." : "Dry damp spools right in the AMS.")
                            .font(.system(size: 11.5, weight: .medium))
                            .foregroundStyle(c.t3)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    Image(systemName: open ? "chevron.up" : "chevron.down")
                        .font(.system(size: 16))
                        .foregroundStyle(c.t3)
                }
                .padding(14)
                .contentShape(.rect)
            }

            if open { configuration }
        }
        .hwCard(16, fill: c.s1, border: c.line)
    }

    private var configuration: some View {
        VStack(alignment: .leading, spacing: 12) {
            FlowLayout(spacing: 8, rowSpacing: 8) {
                ForEach(d.options) { o in
                    let on = o.type == opt?.type
                    Tap {
                        // Selecting a filament re-follows its recommendation; manual tweaks then
                        // apply on top of it.
                        selType = o.type
                        tweak = nil
                    } content: {
                        HStack(spacing: 6) {
                            if let color = o.color, let fill = FilamentColor.swiftUI(color) {
                                Circle().fill(fill).frame(width: 10, height: 10)
                            }
                            Text(o.type)
                                .font(.system(size: 12, weight: .semibold))
                                .foregroundStyle(on ? c.accent : c.t2)
                            Text("\(o.temp)° · \(o.hours)h")
                                .font(.mono(10.5, weight: .medium))
                                .foregroundStyle(c.t3)
                        }
                        .padding(.horizontal, 10)
                        .padding(.vertical, 7)
                        .hwCard(10, fill: on ? c.accentDim : c.s2, border: on ? c.accent : c.line)
                    }
                }
                if d.options.isEmpty {
                    Text("No filament loaded.")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(c.t3)
                }
            }

            HStack(spacing: 10) {
                HwStepper(label: "Temperature", value: "\(effTemp)°",
                          onMinus: { adjustTemp(-5) }, onPlus: { adjustTemp(5) })
                HwStepper(label: "Duration", value: "\(effHours)h",
                          onMinus: { adjustHours(-1) }, onPlus: { adjustHours(1) })
            }

            HStack(spacing: 10) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Rotate spool").font(.system(size: 13, weight: .semibold)).foregroundStyle(c.t1)
                    Text("Turns the spool during drying for even heat.")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(c.t3)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                PillToggle(value: $rotate, onColor: c.accent, offColor: c.s3, knob: c.t1)
            }

            ForEach(d.blockers, id: \.self) { blocker in
                HStack(spacing: 7) {
                    Image(systemName: "exclamationmark.triangle")
                        .font(.system(size: 13))
                        .foregroundStyle(c.heating)
                    Text(blocker)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(c.heating)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }

            startButton
        }
        .padding(.horizontal, 14)
        .padding(.bottom, 14)
    }

    private var startDisabled: Bool { busy || !d.blockers.isEmpty || d.options.isEmpty }

    private var startButton: some View {
        Tap(disabled: startDisabled, action: locked.press(.dryStart, start)) {
            HStack(spacing: 8) {
                if locked.blocked(.dryStart) {
                    Image(systemName: "lock").font(.system(size: 14)).foregroundStyle(c.accentInk)
                }
                Text("Start drying — \(effTemp)° for \(effHours)h")
                    .font(.system(size: 14, weight: .bold))
                    .foregroundStyle(c.accentInk)
            }
            .frame(maxWidth: .infinity)
            .frame(height: 46)
            .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(c.accent))
        }
        .opacity(locked.style(.dryStart) ?? (startDisabled ? 0.45 : 1))
    }

    // MARK: Adjustment

    private func adjustTemp(_ delta: Int) {
        guard let opt else { return }
        tweak = DryTweak(
            type: opt.type,
            temp: min(max(effTemp + delta, Dryer.minTemp), d.maxTemp),
            hours: activeTweak?.hours
        )
    }

    private func adjustHours(_ delta: Int) {
        guard let opt else { return }
        tweak = DryTweak(
            type: opt.type,
            temp: activeTweak?.temp,
            hours: min(max(effHours + delta, 1), Dryer.maxHours)
        )
    }

    /// The active card renders the target as an integer; a fractional target would read "holding 62.5°".
    private func fmtTemp(_ t: Double) -> String { String(Int(t.rounded())) }

    // MARK: Commands

    private func start() {
        guard let client = model.client else { return }
        busy = true
        let printerId = model.printerId
        let amsId = d.amsId
        let temp = effTemp
        let hours = effHours
        let filament = opt?.type
        let rotateTray = rotate
        Task {
            do {
                try await client.dryingStart(
                    printerId, amsId: amsId, temp: temp, hours: hours,
                    filament: filament, rotate: rotateTray
                )
                busy = false
                open = false
                scheduleVerification(client: client, printerId: printerId, amsId: amsId)
            } catch {
                busy = false
                notice = HwNotice(title: "Couldn’t start drying", message: errorDetail(error))
            }
        }
    }

    /// Bambuddy answers 200 as soon as the MQTT command is SENT — the printer can still refuse it
    /// (observed live: `result:'failed', reason:'mqtt message verify failed'` with LAN Developer Mode
    /// off) and nothing would ever surface it. So verify that the AMS actually entered drying.
    ///
    /// If the cycle DID start the unit moves to the active list, this card is replaced and the task is
    /// cancelled — which is exactly right, since there is then nothing to warn about.
    private func scheduleVerification(client: BambuddyClient, printerId: Int, amsId: Int) {
        verify?.cancel()
        verify = Task {
            try? await Task.sleep(for: .seconds(9))
            guard !Task.isCancelled else { return }
            // Status fetch failed — can't verify; stay quiet rather than cry wolf.
            guard let s = try? await client.getStatus(printerId) else { return }
            guard let unit = s.ams?.first(where: { $0.id == amsId }) else { return }
            // dryTime (minutes remaining) > 0 is THE active signal; dryStatus is unreliable.
            guard !((unit.dryTime?.double ?? 0) > 0) else { return }
            notice = HwNotice(
                title: "Drying didn’t start",
                message: "The printer rejected the command (\"mqtt message verify failed\"). Newer Bambu firmware requires LAN Developer Mode for this: on the printer’s screen, enable Settings → Network → Developer Mode, then try again."
            )
        }
    }

    private func stop() {
        guard let client = model.client else { return }
        busy = true
        let printerId = model.printerId
        let amsId = d.amsId
        Task {
            do { try await client.dryingStop(printerId, amsId: amsId) } catch {
                notice = HwNotice(title: "Couldn’t stop drying", message: errorDetail(error))
            }
            busy = false
        }
    }
}

/// The ± control used for drying temperature and duration.
@MainActor
private struct HwStepper: View {
    let label: String
    let value: String
    let onMinus: () -> Void
    let onPlus: () -> Void

    @Environment(\.palette) private var c

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(label.uppercased())
                .font(.system(size: 10, weight: .semibold))
                .tracking(0.6)
                .foregroundStyle(c.t3)
            HStack {
                button("minus", action: onMinus)
                Spacer(minLength: 4)
                Text(value).font(.mono(16, weight: .bold)).foregroundStyle(c.t1)
                Spacer(minLength: 4)
                button("plus", action: onPlus)
            }
            .padding(.top, 6)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .hwCard(12, fill: c.s2, border: c.line)
    }

    private func button(_ symbol: String, action: @escaping () -> Void) -> some View {
        Tap(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(c.t1)
                .frame(width: 30, height: 30)
                .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(c.s3))
        }
    }
}

// MARK: - Nozzles

/// One nozzle, as the card shows it.
private struct RackNozzleVM: Identifiable, Hashable {
    var id: String
    var diameter: String
    var type: String
    /// "High flow" | "Standard flow" | "" — empty when the code carries no flow information.
    var flow: String
    /// Per-nozzle filament MEMORY (the last filament run through it), not what is loaded now.
    var colorHex: String?
    /// Last 4 of the RFID serial; "" for chipless nozzles.
    var serial: String
    var mounted: Bool
    /// Physically in the toolhead right now.
    var engaged: Bool
}

private struct ToolheadVM: Identifiable, Hashable {
    /// "left" | "right" | "single".
    var side: String
    var label: String
    var active: Bool
    /// Has a nozzle changer, so ENGAGED is meaningful.
    var swappable: Bool
    var nozzles: [RackNozzleVM]
    var id: String { side + label }
}

/// Nozzles grouped by toolhead, following Bambu Studio's own parser (`DevNozzleSystemParser::
/// ParseV2_0`):
///  - rack `id` < 16  ⇒ the nozzle CURRENTLY INSTALLED on extruder `id` (0 = RIGHT/main, 1 = LEFT);
///  - rack `id` >= 16 ⇒ a nozzle DOCKED in the changer ("vortex"). The changer belongs to the MAIN
///    (right, ext 0) extruder — Studio attaches rack nozzles only there.
///  - An engaged nozzle's home dock simply DISAPPEARS from the list.
///  - `filamentColor` is per-nozzle filament memory, so several docked nozzles legitimately carry
///    one; `wear`/`stat` mark neither engagement nor emptiness. Chipless nozzles report serial "N/A"
///    but are REAL — the H2C's left fixed 0.4 is exactly that, so "N/A" must not be filtered out.
private enum NozzlePresenter {
    static func toolheads(_ status: PrinterStatus?, dash: DashVM) -> [ToolheadVM] {
        guard let status else { return [] }
        let rack = status.nozzleRack ?? []
        if !rack.isEmpty { return fromRack(rack, activeExtruder: status.activeExtruder?.int) }
        return fromSpec(status, dash: dash)
    }

    private static func fromRack(_ rack: [NozzleRackSlot], activeExtruder: Int?) -> [ToolheadVM] {
        let installed = rack.filter { $0.id < 16 }   // on-extruder: the id IS the extruder id
        let docked = rack.filter { $0.id >= 16 }.map { vm($0, engaged: false) }

        var exts: [Int] = []
        for r in installed where !exts.contains(r.id) { exts.append(r.id) }
        exts.sort(by: >)                              // descending ⇒ LEFT (1) displayed first
        let dual = exts.count > 1

        return exts.map { ext in
            let engaged = installed.filter { $0.id == ext }.map { vm($0, engaged: true) }
            return ToolheadVM(
                side: dual ? (ext == 0 ? "right" : "left") : "single",
                label: dual ? (ext == 0 ? "Right" : "Left") : "Nozzle",
                active: activeExtruder == ext,
                swappable: ext == 0 && !docked.isEmpty,
                nozzles: ext == 0 ? engaged + docked : engaged
            )
        }
    }

    /// No rack (A1 etc.): one non-swappable toolhead per mounted nozzle, spec from `status.nozzles`.
    ///
    /// `dash.nozzles` is TEMPERATURE-ordered (index 0 = `nozzle` = LEFT) while the `nozzles` spec
    /// array is EXTRUDER-ordered (index 0 = extruder 0 = RIGHT) — hence the `1 - i` cross-map, without
    /// which the diameters swap sides on a dual.
    private static func fromSpec(_ status: PrinterStatus, dash: DashVM) -> [ToolheadVM] {
        let info = status.nozzles ?? []
        let dual = dash.nozzles.count > 1
        return dash.nozzles.enumerated().compactMap { pair -> ToolheadVM? in
            let i = pair.offset
            let n = pair.element
            let spec = dual ? info[safe: 1 - i] : info[safe: i]
            let diameter = dia(Double(spec?.nozzleDiameter ?? ""))
            let type = typeLabel(spec?.nozzleType)
            let flow = flowLabel(spec?.nozzleType)
            guard !diameter.isEmpty || !type.isEmpty else { return nil }
            return ToolheadVM(
                side: dual ? (i == 0 ? "left" : "right") : "single",
                label: dual ? (i == 0 ? "Left" : "Right") : "Nozzle",
                active: n.active,
                swappable: false,
                nozzles: [RackNozzleVM(
                    id: "m\(i)", diameter: diameter, type: type, flow: flow,
                    colorHex: nil, serial: "", mounted: n.active, engaged: n.active
                )]
            )
        }
    }

    private static func vm(_ r: NozzleRackSlot, engaged: Bool) -> RackNozzleVM {
        let color = r.filamentColor ?? ""
        let mounted = !color.isEmpty && color != "00000000"
        let serial = r.serialNumber ?? ""
        let chipless = serial.isEmpty || serial == "N/A"
        return RackNozzleVM(
            id: String(r.id),
            diameter: dia(r.nozzleDiameter?.double),
            type: typeLabel(r.nozzleType),
            flow: flowLabel(r.nozzleType),
            colorHex: mounted ? FilamentColor.norm(color) : nil,
            serial: chipless ? "" : String(serial.suffix(4)),
            mounted: mounted,
            engaged: engaged
        )
    }

    /// H2-series nozzle codes are structured, not opaque: "H" + flow letter + a two-digit MATERIAL id
    /// (HS01 and HH01 are both 0.4 mm / 350 °C and differ only in the middle letter, which pins that
    /// letter as flow). Decoding the halves independently means a nozzle Bambu ships tomorrow still
    /// reports its flow correctly instead of falling back to a raw code.
    private static let material: [String: String] = [
        "00": "Stainless", "01": "Hardened", "05": "Tungsten Carbide",
    ]

    /// Long-form codes some machines (A1) report instead of the H2 short codes.
    private static let longForm: [String: String] = [
        "hardened_steel": "Hardened",
        "stainless_steel": "Stainless",
        "tungsten_carbide": "Tungsten Carbide",
        "hardened_tungsten": "Hardened Tungsten",
    ]

    /// Splits an "H" + flow + two material digits code, or nil when the string isn't one.
    private static func h2Code(_ t: String?) -> (flow: Character, material: String)? {
        guard let t, t.count == 4, t.hasPrefix("H") else { return nil }
        let chars = Array(t)
        guard chars[1] == "S" || chars[1] == "H" else { return nil }
        guard chars[2].isNumber, chars[3].isNumber else { return nil }
        return (chars[1], String(chars[2...3]))
    }

    /// The MATERIAL only — flow is reported separately so the two facts can be shown independently.
    /// Never returns a bare unknown token: a raw `HS02` next to cards reading "Hardened" reads like a
    /// material name, so an undecodable code becomes "Type HS02".
    static func typeLabel(_ t: String?) -> String {
        guard let t, !t.isEmpty else { return "" }
        if let code = h2Code(t) {
            return material[code.material] ?? "Type \(t)"   // known shape, unknown material
        }
        if let known = longForm[t] { return known }
        if t.contains("_") {
            return t.split(separator: "_")
                .map { $0.prefix(1).uppercased() + $0.dropFirst().lowercased() }
                .joined(separator: " ")
        }
        return "Type \(t)"
    }

    /// "" when the code carries no flow information at all (the A1's long-form names), so callers can
    /// simply omit the chip.
    static func flowLabel(_ t: String?) -> String {
        guard let code = h2Code(t) else { return "" }
        return code.flow == "H" ? "High flow" : "Standard flow"
    }

    /// "0.4 mm". `%g` keeps the printer's own precision without inventing decimals (1 stays "1").
    static func dia(_ d: Double?) -> String {
        guard let d, d.isFinite else { return "" }
        return String(format: "%g mm", d)
    }
}

/// Nozzle inventory grouped by toolhead. No temperatures here — those are on the dashboard, labelled
/// Left/Right — so nothing is shown twice.
@MainActor
private struct NozzlesSection: View {
    let status: PrinterStatus?
    let dash: DashVM

    @Environment(\.palette) private var c

    var body: some View {
        let toolheads = NozzlePresenter.toolheads(status, dash: dash)
        if !toolheads.isEmpty {
            VStack(alignment: .leading, spacing: 0) {
                HwSectionHead(label: "NOZZLES")
                ForEach(toolheads) { th in
                    toolhead(th)
                }
            }
        }
    }

    @ViewBuilder private func toolhead(_ th: ToolheadVM) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            // Sub-header: which side, fixed vs vortex, and whether it's the active extruder.
            HStack(spacing: 8) {
                Text(th.label).font(.system(size: 13, weight: .bold)).foregroundStyle(c.t1)
                if th.side != "single" {
                    Text(th.swappable ? "VORTEX · \(th.nozzles.count)" : "FIXED")
                        .font(.mono(10))
                        .tracking(0.5)
                        .foregroundStyle(c.t3)
                }
                if th.active {
                    Text("ACTIVE")
                        .font(.mono(8))
                        .tracking(0.5)
                        .foregroundStyle(c.accent)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 1.5)
                        .background(RoundedRectangle(cornerRadius: 5, style: .continuous).fill(c.accentDim))
                }
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 10)

            if th.swappable {
                Text("Engaged is in the head now; the rest are docked. Color chips show each nozzle's last filament.")
                    .font(.system(size: 11.5, weight: .medium))
                    .lineSpacing(3.5)
                    .foregroundStyle(c.t3)
                    .padding(.horizontal, 20)
                    .padding(.bottom, 10)
            }

            if th.nozzles.count == 1, let only = th.nozzles.first {
                NozzleCard(n: only, showMounted: th.swappable).padding(.horizontal, 20)
            } else {
                LazyVGrid(
                    columns: [GridItem(.flexible(), spacing: 10), GridItem(.flexible(), spacing: 10)],
                    spacing: 10
                ) {
                    ForEach(th.nozzles) { n in
                        NozzleCard(n: n, showMounted: th.swappable)
                    }
                }
                .padding(.horizontal, 20)
            }
        }
        .padding(.bottom, 4)
    }
}

/// One nozzle: its filament memory, diameter, flow and whether it is the engaged one.
@MainActor
private struct NozzleCard: View {
    let n: RackNozzleVM
    /// Only a toolhead with a changer can meaningfully say ENGAGED.
    let showMounted: Bool

    @Environment(\.palette) private var c

    /// Spotlight the nozzle physically in the head.
    private var highlight: Bool { showMounted && n.engaged }

    var body: some View {
        HStack(spacing: 11) {
            Swatch(value: n.colorHex, size: 30, radius: 8) {
                Image(systemName: "chevron.down")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(FilamentColor.inkOn(n.colorHex))
            }

            VStack(alignment: .leading, spacing: 2) {
                // Wraps: on a half-width card "0.4 mm" + HIGH FLOW + ENGAGED overflows one line, and
                // the last chip was being clipped at the card edge.
                FlowLayout(spacing: 5, rowSpacing: 4) {
                    Text(n.diameter.isEmpty ? "Nozzle" : n.diameter)
                        .font(.system(size: 14, weight: .bold))
                        .foregroundStyle(c.t1)
                    // Flow rate is a first-class spec on the H2 series — a high-flow and a standard
                    // nozzle of the same diameter print very differently — so it gets its own chip
                    // rather than the subtitle, which truncates on a half-width card.
                    if !n.flow.isEmpty {
                        let high = n.flow == "High flow"
                        chip(high ? "HIGH FLOW" : "STANDARD", ink: high ? c.heating : c.t3, fill: high ? c.heatingDim : c.s3)
                    }
                    if showMounted, n.engaged {
                        chip("ENGAGED", ink: c.accent, fill: c.accentDim)
                    }
                }
                Text(subtitle)
                    .font(.mono(10.5, weight: .medium))
                    .foregroundStyle(c.t3)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(13)
        .hwCard(15, fill: c.s1, border: highlight ? c.accent : c.line, width: highlight ? 1.5 : 1)
    }

    private var subtitle: String {
        [n.type, n.serial.isEmpty ? nil : "#\(n.serial)"]
            .compactMap { $0 }
            .filter { !$0.isEmpty }
            .joined(separator: " · ")
    }

    private func chip(_ text: String, ink: Color, fill: Color) -> some View {
        Text(text)
            .font(.mono(7.5))
            .tracking(0.4)
            .foregroundStyle(ink)
            .padding(.horizontal, 5)
            .padding(.vertical, 1.5)
            .background(RoundedRectangle(cornerRadius: 5, style: .continuous).fill(fill))
    }
}

// MARK: - Maintenance

/// Loading / failed / loaded, spelled out. The RN original used a `T | null | undefined` tri-state
/// here and the three branches drive genuinely different UI.
private enum MaintLoad {
    case loading
    case failed
    case loaded(MaintenancePrinter)
}

private func fetchMaintenance(_ client: BambuddyClient, _ printerId: Int) async -> MaintLoad {
    do { return .loaded(try await client.getMaintenance(printerId)) } catch { return .failed }
}

/// Service reminders for this printer, with "mark done".
///
/// Not LAN-gated: marking an item done is Bambuddy-side bookkeeping in its own database and the
/// printer is never asked. It IS admin-gated, which the client handles by routing through the JWT
/// transport.
@MainActor
private struct MaintenanceSection: View {
    let state: MaintLoad
    /// Item id currently being marked done.
    let busyId: Int?
    let onRetry: () -> Void
    let onMarkDone: (MaintenanceItem) -> Void

    @Environment(\.palette) private var c
    @State private var confirm: MaintenanceItem?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HwSectionHead(label: "MAINTENANCE", right: hoursPrinted)

            switch state {
            case .loading:
                ProgressView().tint(c.accent).frame(maxWidth: .infinity).padding(.top, 16)
            case .failed:
                failedCard
            case .loaded:
                if items.isEmpty {
                    HwEmptyCard(
                        symbol: "wrench.and.screwdriver",
                        title: "No reminders set up",
                        message: "Add service intervals in Bambuddy (Settings → Maintenance) and they’ll track here as you print."
                    )
                } else {
                    list
                }
            }
        }
        .alert(
            confirm.map { "Mark \"\($0.maintenanceTypeName)\" as done?" } ?? "",
            isPresented: Binding(get: { confirm != nil }, set: { if !$0 { confirm = nil } }),
            presenting: confirm
        ) { item in
            Button("Cancel", role: .cancel) {}
            Button("Mark done") { onMarkDone(item) }
        } message: { item in
            Text("This resets its counter. Next reminder in \(hours(item.intervalHours)) h of printing.")
        }
    }

    private var hoursPrinted: String? {
        guard case .loaded(let data) = state else { return nil }
        return String(format: "%.1f h printed", data.totalPrintHours?.double ?? 0)
    }

    /// Due first, then warnings, then by how soon each falls due.
    private var items: [MaintenanceItem] {
        guard case .loaded(let data) = state else { return [] }
        return data.maintenanceItems
            .filter { $0.enabled ?? false }
            .sorted { a, b in
                if (a.isDue ?? false) != (b.isDue ?? false) { return a.isDue ?? false }
                if (a.isWarning ?? false) != (b.isWarning ?? false) { return a.isWarning ?? false }
                return (a.hoursUntilDue?.double ?? 0) < (b.hoursUntilDue?.double ?? 0)
            }
    }

    private var failedCard: some View {
        HStack(spacing: 12) {
            Text("Couldn’t load maintenance.")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(c.t3)
                .frame(maxWidth: .infinity, alignment: .leading)
            Tap(action: onRetry) {
                Text("Retry")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(c.t1)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                    .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(c.s3))
            }
        }
        .padding(16)
        .hwCard(18, fill: c.s1, border: c.line)
        .padding(.horizontal, 20)
    }

    private var list: some View {
        VStack(spacing: 11) {
            ForEach(items) { item in
                row(item)
            }
        }
        .padding(.horizontal, 20)
        // After "Mark done" the list re-sorts (the done item sinks below the due ones) — the spring
        // makes the card visibly glide to its new slot instead of teleporting.
        .animation(.spring(response: 0.47, dampingFraction: 0.67), value: items.map(\.id))
    }

    private func row(_ item: MaintenanceItem) -> some View {
        let st = MaintStatus.of(item, c)
        let busy = busyId == item.id
        return VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 13) {
                Image(systemName: maintSymbol(item.maintenanceTypeIcon))
                    .font(.system(size: 20))
                    .foregroundStyle(st.urgent ? st.color : c.t2)
                    .frame(width: 42, height: 42)
                    .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(st.urgent ? c.s3 : c.s2))

                VStack(alignment: .leading, spacing: 4) {
                    Text(item.maintenanceTypeName)
                        .font(.system(size: 15, weight: .bold))
                        .foregroundStyle(c.t1)
                    Text(fmtLastPerformed(item.lastPerformedAt))
                        .font(.mono(11, weight: .medium))
                        .foregroundStyle(c.t3)
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                VStack(alignment: .trailing, spacing: 3) {
                    if st.urgent {
                        Text(st.text.uppercased())
                            .font(.mono(10.5, weight: .bold))
                            .tracking(0.4)
                            .foregroundStyle(st.color)
                            .padding(.horizontal, 9)
                            .padding(.vertical, 4)
                            .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(st.dim))
                    } else {
                        Text(st.text).font(.mono(12)).foregroundStyle(c.t2)
                    }
                    Text("every \(hours(item.intervalHours)) h")
                        .font(.mono(10, weight: .medium))
                        .foregroundStyle(c.t3)
                }
                .fixedSize()
            }

            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 2, style: .continuous).fill(c.s3)
                    RoundedRectangle(cornerRadius: 2, style: .continuous)
                        .fill(st.urgent ? st.color : c.accent)
                        .frame(width: geo.size.width * progress(item) / 100)
                }
            }
            .frame(height: 4)
            .padding(.top, 13)

            HStack {
                Spacer(minLength: 0)
                Tap(disabled: busy) { confirm = item } content: {
                    HStack(spacing: 7) {
                        if busy {
                            ProgressView()
                                .controlSize(.small)
                                .tint(st.urgent ? c.accentInk : c.t1)
                        } else {
                            Image(systemName: "checkmark")
                                .font(.system(size: 14, weight: .medium))
                                .foregroundStyle(st.urgent ? c.accentInk : c.t1)
                        }
                        Text("Mark done")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(st.urgent ? c.accentInk : c.t1)
                    }
                    .padding(.horizontal, 15)
                    .padding(.vertical, 9)
                    .background(RoundedRectangle(cornerRadius: 11, style: .continuous).fill(st.urgent ? c.accent : c.s3))
                }
                .opacity(busy ? 0.5 : 1)
            }
            .padding(.top, 13)
        }
        .padding(16)
        .hwCard(18, fill: c.s1, border: st.urgent ? st.color : c.line, width: st.urgent ? 1.5 : 1)
        .shadow1()
    }

    private func progress(_ item: MaintenanceItem) -> Double {
        let interval = item.intervalHours?.double ?? 0
        guard interval > 0 else { return 0 }
        return min(max((item.hoursSinceMaintenance?.double ?? 0) / interval * 100, 0), 100)
    }

    private func hours(_ n: LooseNumber?) -> Int {
        let v = n?.double ?? 0
        return v.isFinite ? Int(v.rounded()) : 0
    }
}

/// Due / soon / not yet, with the colour and the chip fill that go with it.
private struct MaintStatus {
    var text: String
    var color: Color
    var dim: Color
    var urgent: Bool

    static func of(_ item: MaintenanceItem, _ c: Palette) -> MaintStatus {
        if item.isDue ?? false {
            return MaintStatus(text: "Due now", color: c.error, dim: c.errorDim, urgent: true)
        }
        if item.isWarning ?? false {
            return MaintStatus(text: "Soon", color: c.heating, dim: c.heatingDim, urgent: true)
        }
        let h = item.hoursUntilDue?.double ?? 0
        let text = h >= 1
            ? "in \(Int(h.rounded())) h"
            : "in \(max(0, Int((h * 60).rounded()))) min"
        return MaintStatus(text: text, color: c.t3, dim: c.s3, urgent: false)
    }
}

/// The API sends Lucide icon names; map each to the nearest SF Symbol.
private let maintSymbols: [String: String] = [
    "Droplet": "drop",
    "Sparkles": "sparkles",
    "Flame": "flame",
    "Ruler": "ruler",
    "Square": "square",
    "Cable": "cable.connector",
    "Wrench": "wrench.and.screwdriver",
    "Tool": "wrench.and.screwdriver",
]

private func maintSymbol(_ name: String?) -> String {
    name.flatMap { maintSymbols[$0] } ?? "wrench.and.screwdriver"
}

private func fmtLastPerformed(_ iso: String?, now: Date = Date()) -> String {
    guard let iso, !iso.isEmpty else { return "Never performed" }
    guard let date = NaiveDate.parse(iso) else { return "Performed" }
    let days = Int((now.timeIntervalSince(date) / 86400).rounded(.down))
    if days <= 0 { return "Done today" }
    if days == 1 { return "Done yesterday" }
    if days < 30 { return "Done \(days) days ago" }
    return "Done \(date.formatted(date: .numeric, time: .omitted))"
}

/// Bambuddy timestamps are NAIVE — "2026-06-28T15:07:35.681213", no zone — and have to be read as
/// LOCAL time, the way `new Date()` did. `ISO8601DateFormatter` refuses six-digit fractions outright,
/// and reading them as UTC would shift every "3 days ago" by the offset.
private enum NaiveDate {
    // Shared instances: `DateFormatter` is thread-safe once configured, and these are never mutated
    // after construction — so no formatter is rebuilt per row.
    private static let second = fixed("yyyy-MM-dd'T'HH:mm:ss")
    private static let day = fixed("yyyy-MM-dd")

    private static func fixed(_ format: String) -> DateFormatter {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")   // never the user's calendar for a wire format
        f.timeZone = .current
        f.dateFormat = format
        return f
    }

    static func parse(_ iso: String) -> Date? {
        // Sub-second precision is never displayed, so drop it rather than trying to parse 6 digits.
        let base = iso.split(separator: ".", maxSplits: 1).first.map(String.init) ?? iso
        return second.date(from: base)
            ?? day.date(from: base)
            ?? ISO8601DateFormatter().date(from: iso)   // a value that DOES carry an offset
    }
}

// MARK: - Scaffolding

/// The tab's scroll container: the design's header lives inside the scroll content, not in a
/// navigation bar.
@MainActor
private struct HwPage<Content: View>: View {
    let title: String
    @ViewBuilder var content: () -> Content

    @Environment(\.palette) private var c

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                Text(title)
                    .font(.system(size: 30, weight: .bold))
                    .kerning(-0.8)
                    .foregroundStyle(c.t1)
                    .padding(.horizontal, 20)
                content()
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.top, 8)
            .padding(.bottom, 120)   // clearance for the tab bar
        }
        .scrollIndicators(.hidden)
        .background(c.bg)
    }
}

/// FILAMENT / NOZZLES / MAINTENANCE.
@MainActor
private struct HwSectionHead: View {
    let label: String
    var right: String? = nil
    var first = false

    @Environment(\.palette) private var c

    var body: some View {
        HStack {
            Text(label).font(.mono(11)).tracking(1.2).foregroundStyle(c.t3)
            Spacer(minLength: 8)
            if let right, !right.isEmpty {
                Text(right).font(.mono(11)).foregroundStyle(c.t3)
            }
        }
        .padding(.horizontal, 20)
        .padding(.top, first ? 8 : 26)
        .padding(.bottom, 12)
    }
}

/// The small pill used for AMS readings and drying stats.
@MainActor
private struct HwChip<Content: View>: View {
    var padV: CGFloat = 3
    @ViewBuilder var content: () -> Content

    @Environment(\.palette) private var c

    var body: some View {
        HStack(spacing: 5) { content() }
            .padding(.horizontal, 9)
            .padding(.vertical, padV)
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(c.s2))
    }
}

/// "There is genuinely nothing here" — distinct from a failed fetch, which keeps its own card.
@MainActor
private struct HwEmptyCard: View {
    let symbol: String
    let title: String
    // Not `body`: that name is the View requirement itself.
    let message: String

    @Environment(\.palette) private var c

    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: symbol).font(.system(size: 22)).foregroundStyle(c.t3)
            Text(title).font(.system(size: 14, weight: .semibold)).foregroundStyle(c.t1)
            Text(message)
                .font(.system(size: 12, weight: .medium))
                .lineSpacing(5)
                .multilineTextAlignment(.center)
                .foregroundStyle(c.t3)
                .frame(maxWidth: 250)
        }
        .frame(maxWidth: .infinity)
        .padding(18)
        .hwCard(18, fill: c.s1, border: c.line)
        .padding(.horizontal, 20)
    }
}

/// A one-button alert for a command that failed. Identifiable so a second failure replaces the first
/// instead of being swallowed.
private struct HwNotice: Identifiable, Sendable {
    let id = UUID()
    var title: String
    var message: String
}

/// Bambuddy's own message ("AMS is busy" from a 409), not the transport noise around it.
private func errorDetail(_ error: Error) -> String {
    (error as? BambuddyError)?.detail ?? error.localizedDescription
}

private extension View {
    /// RN's `borderWidth` draws INSIDE the box, which is what `strokeBorder` does.
    func hwCard(_ radius: CGFloat, fill: Color, border: Color, width: CGFloat = 1) -> some View {
        background(RoundedRectangle(cornerRadius: radius, style: .continuous).fill(fill))
            .overlay(
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .strokeBorder(border, lineWidth: width)
            )
    }

    func hwNotice(_ notice: Binding<HwNotice?>) -> some View {
        alert(
            notice.wrappedValue?.title ?? "",
            isPresented: Binding(
                get: { notice.wrappedValue != nil },
                set: { if !$0 { notice.wrappedValue = nil } }
            ),
            presenting: notice.wrappedValue
        ) { _ in
            Button("OK", role: .cancel) {}
        } message: { n in
            Text(n.message)
        }
    }
}

/// A wrapping row — RN's `flexWrap: 'wrap'` with a gap, which no SwiftUI stack does.
///
/// Used wherever a chip row can outgrow its width: the AMS unit readings, the drying stats, the
/// filament picker, and the nozzle card's spec chips (on a half-width card "0.4 mm" + HIGH FLOW +
/// ENGAGED overflowed one line and the last chip was clipped).
private struct FlowLayout: Layout {
    var spacing: CGFloat = 8
    var rowSpacing: CGFloat = 8

    private struct Row {
        var indices: [Int] = []
        var width: CGFloat = 0
        var height: CGFloat = 0
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maxWidth = proposal.width ?? .infinity
        let rows = rows(maxWidth: maxWidth, subviews: subviews)
        let height = rows.reduce(0) { $0 + $1.height } + rowSpacing * CGFloat(max(0, rows.count - 1))
        let widest = rows.map(\.width).max() ?? 0
        return CGSize(width: maxWidth.isFinite ? maxWidth : widest, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let rows = rows(maxWidth: proposal.width ?? bounds.width, subviews: subviews)
        var y = bounds.minY
        for row in rows {
            var x = bounds.minX
            for i in row.indices {
                let size = subviews[i].sizeThatFits(.unspecified)
                subviews[i].place(
                    at: CGPoint(x: x, y: y + (row.height - size.height) / 2),
                    anchor: .topLeading,
                    proposal: ProposedViewSize(size)
                )
                x += size.width + spacing
            }
            y += row.height + rowSpacing
        }
    }

    private func rows(maxWidth: CGFloat, subviews: Subviews) -> [Row] {
        var rows: [Row] = []
        var current = Row()
        for i in subviews.indices {
            let size = subviews[i].sizeThatFits(.unspecified)
            let extended = current.indices.isEmpty ? size.width : current.width + spacing + size.width
            if !current.indices.isEmpty, extended > maxWidth {
                rows.append(current)
                current = Row(indices: [i], width: size.width, height: size.height)
            } else {
                current.indices.append(i)
                current.width = extended
                current.height = max(current.height, size.height)
            }
        }
        if !current.indices.isEmpty { rows.append(current) }
        return rows
    }
}
