import Foundation

// Pure: printer status -> the list of things demanding attention, each carrying ONLY the actions that
// are actually possible right now.
//
// The guiding rule (the owner's): never offer an action the printer/permissions can't currently take.
// A "Resume" button on a printer that isn't paused, or on one that's offline, is worse than no button
// — it teaches you not to trust the screen. So every action is gated on observed state, and anything
// we can't verify is simply not offered.

/// How loudly an alert speaks. The case order IS the severity ladder, so `max()` over a list of
/// levels answers "how bad is the worst one".
enum AlertLevel: String, Sendable, Hashable, Comparable, CaseIterable {
    case info, warning, error

    private var rank: Int {
        switch self {
        case .info: return 0
        case .warning: return 1
        case .error: return 2
        }
    }

    static func < (lhs: AlertLevel, rhs: AlertLevel) -> Bool { lhs.rank < rhs.rank }
}

/// The things an alert can offer to do about itself.
enum AlertActionId: String, Sendable, Hashable {
    /// Continue a paused print (problem fixed / intentional pause).
    case resume
    /// Cancel the job.
    case stop
    /// Dismiss the printer's HMS notices.
    case clearHms
    /// Confirm the bed is clear so the queue can dispatch.
    case plateCleared
    /// Open Bambu's HMS reference for this exact code.
    case lookup
}

/// One button on an alert row.
struct AlertActionVM: Identifiable, Hashable, Sendable {
    var id: AlertActionId
    var label: String
    /// Irreversible or job-ending — the UI confirms these first.
    var destructive: Bool = false
    /// Only on `.lookup`: ordered candidate pages for this code, most likely first. The LAST entry is
    /// Bambu's searchable index and always resolves, so the caller can open the first that works.
    ///
    /// Held as strings rather than `URL`s on purpose: the code is printer-supplied and passes through
    /// `Dash.fmtHmsCode` unchanged when it isn't the expected 16 hex digits, so a `URL(string:)` that
    /// returned nil would silently shorten the fallback chain instead of failing visibly.
    var urls: [String]?
}

/// One thing demanding attention, with the actions that are possible right now.
struct AlertVM: Identifiable, Hashable, Sendable {
    /// Stable across polls so the list doesn't churn while a print runs.
    var id: String
    var level: AlertLevel
    var title: String
    var detail: String
    /// Formatted HMS code, when this alert came from one.
    var code: String?
    var actions: [AlertActionVM]
}

/// Looks up Bambu's own text for a code. Injected so `Alerts.present` stays pure — the catalogue it
/// reads is fetched and cached by `HmsCatalogStore`.
struct AlertDescribe: Sendable {
    /// Takes the dashed display code, e.g. "0501-0400-0003-0002".
    var hms: (@Sendable (String) -> String?)?
    /// Takes the print-error code as text, exactly as it is shown to the user.
    var printError: (@Sendable (String) -> String?)?

    init(hms: (@Sendable (String) -> String?)? = nil, printError: (@Sendable (String) -> String?)? = nil) {
        self.hms = hms
        self.printError = printError
    }

    /// No catalogue yet — every alert falls back to generic copy.
    static let none = AlertDescribe()
}

/// What the app is currently allowed/able to do — actions are filtered through this.
struct AlertCaps: Sendable, Hashable {
    /// The printer is reachable; without this NO control action can succeed.
    var connected: Bool
    /// Control endpoints accept the app's credentials (Bambuddy's scoped key covers print control).
    var canControl: Bool
    /// Machine model ("H2C") — picks the right wiki family for code lookups.
    var model: String?

    init(connected: Bool, canControl: Bool, model: String? = nil) {
        self.connected = connected
        self.canControl = canControl
        self.model = model
    }
}

/// One-line rollup for the dashboard.
struct AlertSummary: Sendable, Hashable {
    var count: Int
    var level: AlertLevel
    var label: String
}

enum Alerts {
    // Bambu's wiki has a page per HMS code, but the path is PER MODEL FAMILY and each family has its
    // own code namespace — verified live: 0C00_0100_0002_0017 is 200 under /h2/ and 404 under /x1/,
    // while 0300_0D00_0001_0003 is the exact reverse. The path also uses UNDERSCORES, not the dashes
    // the code is displayed with (the dashed form 404s everywhere; case is tolerated).
    //
    // So we can't know the right page from the code alone: build ordered candidates from the machine's
    // model, then the other families, and finally the searchable index — which always exists. The
    // caller opens the first that resolves.
    static let families = ["h2", "x1", "p1", "a1"]

    /// Searchable index of every HMS code — the guaranteed-to-exist last resort.
    static let hmsIndexURL = "https://wiki.bambulab.com/en/hms/error-code"

    /// Wiki segment for a Bambuddy model string ("H2C" -> h2, "X1C" -> x1, "A1 mini" -> a1).
    static func wikiFamily(_ model: String?) -> String {
        // `uppercased()` without a locale on purpose: the model is an ASCII part number, and the
        // Turkish dotless-i mapping would turn a locale-aware fold into a miss.
        let m = (model ?? "").trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        if m.hasPrefix("H2") { return "h2" }
        if m.hasPrefix("X1") { return "x1" }
        if m.hasPrefix("P1") { return "p1" }
        if m.hasPrefix("A1") { return "a1" }
        return "x1" // the largest/legacy set is the least-bad guess for an unknown machine
    }

    /// Ordered candidate pages for a dashed HMS code: this machine's family first, then the others,
    /// then the index.
    static func hmsURLs(_ dashed: String, model: String?) -> [String] {
        let code = dashed.replacingOccurrences(of: "-", with: "_")
        let first = wikiFamily(model)
        let ordered = [first] + families.filter { $0 != first }
        return ordered.map { "https://wiki.bambulab.com/en/\($0)/troubleshooting/hmscode/\(code)" } + [hmsIndexURL]
    }

    /// One rung of Bambu's documented severity ladder.
    private struct Severity: Sendable {
        let level: AlertLevel
        let label: String
    }

    /// Bambu's documented severity ladder. Anything outside it stays a neutral "Notice" rather than
    /// guessing a level we can't justify — some firmwares report values outside 1-4.
    private static let severities: [Int: Severity] = [
        1: Severity(level: .error, label: "Fatal"),
        2: Severity(level: .error, label: "Serious"),
        3: Severity(level: .warning, label: "Common"),
        4: Severity(level: .info, label: "Info"),
    ]

    /// A ladder rung, or nil for anything that isn't one of the four documented integers.
    ///
    /// `Int(exactly:)` rather than `Int(_:)`: severity arrives as a `LooseNumber`, so the printer can
    /// hand us a value no `Int` can hold, and the plain conversion TRAPS on that. A fractional value
    /// is no rung either, which `Int(exactly:)` also rejects.
    private static func severityRung(_ raw: LooseNumber?) -> Severity? {
        guard let v = raw?.double, v.isFinite, let key = Int(exactly: v) else { return nil }
        return severities[key]
    }

    /// Pure: the printer's state -> the alerts to show, worst first.
    static func present(_ status: PrinterStatus?, caps: AlertCaps, describe: AlertDescribe = .none) -> [AlertVM] {
        guard let status else { return [] }
        var out: [AlertVM] = []
        let state = status.state.uppercased()
        let paused = state == "PAUSE" || state == "PAUSED"
        // Control actions are pointless (and will just error) when the printer isn't reachable.
        let canAct = caps.connected && caps.canControl

        // A zero print_error means "no error" — it must not open an alert. Neither may a value the
        // transport mangled into something non-finite.
        let printError: Double? = {
            guard let v = status.printError?.double, v.isFinite, v != 0 else { return nil }
            return v
        }()
        // The code as text: integral codes print without a decimal point, which is how the printer,
        // Bambu's tables and the user all refer to them.
        let printErrorText: String? = printError.map { v in
            if let i = Int(exactly: v) { return String(i) }
            return String(v)
        }

        // 1. A hard print failure. This is the one that ends a job, so it leads the list.
        if printError != nil || state == "FAILED" || state == "ERROR" {
            let bambuText = printErrorText.flatMap { describe.printError?($0) }
            let fallback = printErrorText.map { "The printer reported error \($0). Check the machine before continuing." }
                ?? "The printer stopped with an error. Check the machine before continuing."
            out.append(AlertVM(
                id: "print-error",
                level: .error,
                title: "Print error",
                detail: bambuText ?? fallback,
                actions: canAct
                    ? [
                        AlertActionVM(id: .resume, label: "Resume"),
                        AlertActionVM(id: .stop, label: "Stop print", destructive: true),
                    ]
                    : []
            ))
        }

        // 2. Paused — the classic "I fixed it, carry on". Only offered when genuinely paused.
        if paused {
            out.append(AlertVM(
                id: "paused",
                level: .warning,
                title: "Print paused",
                detail: "Resume once the problem is fixed, or stop the job entirely.",
                actions: canAct
                    ? [
                        AlertActionVM(id: .resume, label: "Resume print"),
                        AlertActionVM(id: .stop, label: "Stop print", destructive: true),
                    ]
                    : []
            ))
        }

        // 3. Queue blocked on a physical confirmation only the human can give.
        if status.awaitingPlateClear == true {
            out.append(AlertVM(
                id: "plate",
                level: .info,
                title: "Waiting for the plate",
                detail: "The finished print has to come off the bed before the next job can start.",
                actions: canAct ? [AlertActionVM(id: .plateCleared, label: "Plate is clear")] : []
            ))
        }

        // 4. HMS notices. These are NOT failures — the H2C emits benign ones mid-print — so they never
        //    claim the print is broken; they carry the code and a way to look it up.
        let hms = status.hmsErrors ?? []
        for (i, h) in hms.enumerated() {
            let dashed = Dash.fmtHmsCode(h.fullCode ?? h.code)
            let rung = severityRung(h.severity)

            var actions: [AlertActionVM] = []
            if let dashed {
                actions.append(AlertActionVM(id: .lookup, label: "What is this?", urls: hmsURLs(dashed, model: caps.model)))
            }
            // One clear covers every notice, so only offer it on the first row.
            if canAct, i == 0 {
                actions.append(AlertActionVM(id: .clearHms, label: hms.count > 1 ? "Dismiss all (\(hms.count))" : "Dismiss"))
            }

            // Bambu's own words when we have them — "Threaded rods need lubrication now." beats any
            // sentence we could write. Falls back to severity-appropriate generic copy.
            let bambuText = dashed.flatMap { describe.hms?($0) }
            let fallback: String
            if dashed == nil {
                fallback = "The printer raised a health notice with no code attached."
            } else if rung?.level == .error {
                fallback = "The printer flagged a serious condition. Check the machine — look up the code for what it means."
            } else {
                fallback = "A health notice. The printer keeps going unless it also paused."
            }

            out.append(AlertVM(
                id: "hms-\(dashed ?? String(i))",
                level: rung?.level ?? .warning,
                title: rung.map { "\($0.label) notice" } ?? "Printer notice",
                detail: bambuText ?? fallback,
                code: dashed,
                actions: actions
            ))
        }

        return out
    }

    /// One-line rollup for the dashboard: how many, and how bad the worst one is. `nil` = all clear,
    /// so the dashboard renders nothing at all rather than a reassuring-but-noisy "no alerts" row.
    static func summary(_ alerts: [AlertVM]) -> AlertSummary? {
        guard let level = alerts.map(\.level).max() else { return nil }
        let actionable = alerts.filter { $0.actions.contains { $0.id != .lookup } }.count
        let noun = alerts.count == 1 ? "alert" : "alerts"
        // String interpolation of an Int, never a NumberFormatter: the count must read "1234", not a
        // locale's grouped "1,234" / "1 234".
        let label = actionable > 0
            ? "\(alerts.count) \(noun) · \(actionable) actionable"
            : "\(alerts.count) \(noun)"
        return AlertSummary(count: alerts.count, level: level, label: label)
    }

    /// The codes on screen that the catalogue still can't describe, paired with the pages to try.
    ///
    /// Feed the result to `HmsCatalogStore.learn`: every H2-family code is missing from Bambu's public
    /// feed, and the wiki page is the only place its sentence exists.
    static func unknownCodes(in alerts: [AlertVM], catalog: HmsCatalog) -> [HmsLookupTarget] {
        alerts.compactMap { alert in
            guard let code = alert.code, catalog.describeHms(code) == nil else { return nil }
            guard let urls = alert.actions.first(where: { $0.id == .lookup })?.urls, !urls.isEmpty else { return nil }
            return HmsLookupTarget(code: code, urls: urls)
        }
    }
}
