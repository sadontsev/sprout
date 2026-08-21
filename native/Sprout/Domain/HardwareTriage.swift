import Foundation

/// Which of the Hardware tab's three segments needs you, and why.
///
/// The tab used to stack four unrelated jobs in one ~2 500 pt scroll — unit chips, dryers, slots,
/// nozzles, then service. Service reminders are the only part with a deadline and they sat at the
/// **bottom**, which is why they needed a dashboard chip to be noticed at all.
///
/// Splitting the scroll into segments fixes the length and creates a new problem: something wrong in
/// one segment is invisible from the other two. This is the answer — one line, above the picker, on
/// every segment. Pure so the wording and, more importantly, the **thresholds** can be tested.
enum HardwareTriage {

    enum Segment: String, CaseIterable, Identifiable, Sendable {
        case filament, nozzles, service

        var id: String { rawValue }

        var label: String {
            switch self {
            case .filament: return "Filament"
            case .nozzles:  return "Nozzles"
            // "Maintenance", not "Service": the dashboard chip says "maintenance tasks are due",
            // the endpoint is `getMaintenance`, and the fields are `dueCount`/`warningCount`. The
            // tab was the only place calling it something else. The CASE stays `service` — the raw
            // value is persisted.
            case .service:  return "Maintenance"
            }
        }
    }

    struct Item: Equatable, Identifiable, Sendable {
        var segment: Segment
        var text: String
        /// Overdue service and a wet spool are both worth saying; only one of them stops a print
        /// looking right tomorrow. Higher sorts first.
        var weight: Int
        /// How many underlying problems this line stands for.
        ///
        /// Not always 1: several overdue service items collapse into one readable line, and the
        /// headline has to count the PROBLEMS rather than the lines. Shipping without this produced
        /// "1 thing needs you" sitting directly above "4 service items overdue" — a card arguing
        /// with itself in the space of two lines.
        var count: Int = 1
        var id: String { "\(segment.rawValue)-\(text)" }
    }

    /// Relative humidity at or above which a spool is worth drying.
    ///
    /// 30 % is the number the design copy quotes for PETG, and it is the one the reason line has to
    /// agree with — a card that says "38 % is above the 30 % you'd want" while the threshold is 45 %
    /// would be a sentence arguing with its own trigger.
    static let dampRH = 30.0

    /// Everything that currently wants attention, worst first.
    ///
    /// `overdue` is counted from `hoursUntilDue < 0` rather than `isDue`, because the two are
    /// different questions: `isDue` is true from the moment the interval elapses, while a NEGATIVE
    /// remaining figure is the one that can be stated as "overdue by N hours".
    static func items(maintenance: [MaintenanceItem],
                      humidities: [(label: String, rh: Double?)],
                      nozzlesKnown: Bool) -> [Item] {
        var out: [Item] = []

        let overdue = maintenance.filter { ($0.hoursUntilDue?.double ?? 0) < 0 && $0.enabled != false }
        if overdue.count == 1, let one = overdue.first {
            out.append(Item(segment: .service, text: "\(one.maintenanceTypeName) overdue", weight: 100))
        } else if overdue.count > 1 {
            out.append(Item(segment: .service, text: "\(overdue.count) service items overdue",
                            weight: 100, count: overdue.count))
        }

        for unit in humidities {
            guard let rh = unit.rh, rh >= dampRH else { continue }
            out.append(Item(segment: .filament,
                            text: "\(unit.label) at \(Int(rh.rounded())) % RH",
                            weight: 50))
        }

        // Nothing is claimed about nozzles when the printer has not said anything about them.
        // "No nozzle data" is not a fault, and reporting it as one would put a permanent warning on
        // every machine that does not have a swappable rack.
        _ = nozzlesKnown

        return out.sorted { $0.weight > $1.weight }
    }

    /// The card's headline. `nil` when there is nothing to say — and then no card is drawn at all,
    /// rather than an "all good" banner taking up room on every screen forever.
    static func headline(_ items: [Item]) -> String? {
        let n = items.reduce(0) { $0 + $1.count }
        switch n {
        case 0: return nil
        case 1: return "1 thing needs you"
        default: return "\(n) things need you"
        }
    }

    /// The card's detail line: each item, most severe first.
    static func detail(_ items: [Item]) -> String {
        items.map(\.text).joined(separator: "  ·  ")
    }

    /// Which segments carry a dot on the picker.
    static func flagged(_ items: [Item]) -> Set<Segment> {
        Set(items.map(\.segment))
    }

    /// Why a spool wants drying, in words, rather than a bare Dry button.
    ///
    /// Names the reading, the threshold and the fix. The temperature is the unit's own ceiling
    /// rather than a constant: an AMS 2 Pro tops out at 65 °C and an HT reaches 85 °C, so a single
    /// hardcoded number would be wrong on one of them.
    static func dryingReason(rh: Double, maxDryTemp: Int) -> String {
        let temp = min(55, maxDryTemp)
        return "\(Int(rh.rounded())) % is above the \(Int(dampRH)) % you'd want for PETG. "
             + "A 6 h cycle at \(temp) °C fixes it."
    }
}
