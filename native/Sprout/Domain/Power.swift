import Foundation

/// One server-side rule that can switch a smart plug with nobody watching.
struct PlugAutomation: Identifiable, Hashable, Sendable {
    /// Which rule this is. Stable across renders, so it doubles as the SwiftUI identity.
    enum Key: String, Sendable, Hashable {
        case autoOn = "auto_on"
        case autoOff = "auto_off"
        case afterDrying = "after_drying"
        case schedule
    }

    let key: Key
    var label: String
    var detail: String
    /// Marks the dangerous direction: this rule can kill power to a running print.
    var cuts: Bool

    var id: Key { key }
}

/// Smart-plug presentation: what a plug will do on its own, and which sockets are worth listing.
enum Power {
    /// A `HH:MM` wall-clock time, or nil when the field is absent or malformed.
    ///
    /// Hand-rolled and ASCII-only on purpose. Swift's regex `\d` matches any Unicode decimal digit,
    /// so `/^([01]\d|2[0-3]):[0-5]\d$/` would happily accept "٠٧:٠٠" and then paste it straight into
    /// the schedule line. Zero-padding is required — "7:00" is rejected rather than guessed at.
    private static func hhmm(_ t: String?) -> String? {
        guard let t else { return nil }
        // Byte count, not Character count: any non-ASCII scalar is more than one UTF-8 byte and so
        // cannot slip through a length check that a multi-byte grapheme would have passed.
        let b = Array(t.utf8)
        guard b.count == 5, b[2] == UInt8(ascii: ":") else { return nil }

        func digit(_ byte: UInt8) -> Int? {
            let zero = UInt8(ascii: "0")
            guard byte >= zero, byte <= UInt8(ascii: "9") else { return nil }
            return Int(byte - zero)
        }
        guard let h10 = digit(b[0]), let h1 = digit(b[1]),
              let m10 = digit(b[3]), let m1 = digit(b[4]) else { return nil }
        guard h10 * 10 + h1 <= 23, m10 * 10 + m1 <= 59 else { return nil }
        return t
    }

    /// A threshold rendered for prose: the payload value when it is usable, otherwise the fallback.
    ///
    /// `fallback` is Bambuddy's own default for that field (5 min, 70 °C, 10 min). The rule fires
    /// on the default whether or not the API echoes a value back, so printing it is more honest
    /// than printing nothing.
    ///
    /// A whole number must print with no ".0" tail; a fractional value keeps its fraction. Non-finite
    /// is treated as absent — these fields arrive as strings over the WebSocket, and `"nan"` parses
    /// to a Double that would otherwise be rendered into the sentence.
    private static func threshold(_ raw: LooseNumber?, fallback: Int) -> String {
        guard let v = raw?.double, v.isFinite else { return String(fallback) }
        if v == v.rounded(), let whole = Int(exactly: v.rounded()) { return String(whole) }
        return String(v)
    }

    /// Every automation currently ARMED on a plug, in the order a user would want to read them.
    ///
    /// Bambuddy runs these itself and the app cannot change them — writes to `/smart-plugs/{id}` are
    /// admin-only and 403 with a scoped API key — so the only honest thing the UI can do is report
    /// them accurately.
    static func plugAutomations(_ plug: SmartPlug?) -> [PlugAutomation] {
        guard let plug else { return [] }
        var out: [PlugAutomation] = []

        if plug.autoOn == true {
            out.append(PlugAutomation(
                key: .autoOn,
                label: "Auto power-on",
                detail: "Switches on when a print starts.",
                cuts: false
            ))
        }

        if plug.autoOff == true {
            // Two shapes of the same rule; the mode decides which threshold actually applies.
            let detail = plug.offDelayMode == "temperature"
                ? "Switches off after a print, once the hotend cools below \(threshold(plug.offTempThreshold, fallback: 70))°C."
                : "Switches off \(threshold(plug.offDelayMinutes, fallback: 5)) min after a print finishes."
            out.append(PlugAutomation(
                key: .autoOff,
                label: "Auto power-off",
                detail: plug.autoOffPersistent == true ? "\(detail) Survives a Bambuddy restart." : detail,
                cuts: true
            ))
        }

        if plug.autoOffAfterDrying == true {
            out.append(PlugAutomation(
                key: .afterDrying,
                label: "Off after drying",
                detail: "Switches off \(threshold(plug.offDelayAfterDryingMinutes, fallback: 10)) min after AMS drying finishes.",
                cuts: true
            ))
        }

        // A schedule counts as armed only if it has a time to act on — an enabled schedule with both
        // fields null does nothing, and reporting it would be a phantom warning.
        if plug.scheduleEnabled == true {
            let on = hhmm(plug.scheduleOnTime)
            let off = hhmm(plug.scheduleOffTime)
            if on != nil || off != nil {
                var parts: [String] = []
                if let on { parts.append("on at \(on)") }
                if let off { parts.append("off at \(off)") }
                out.append(PlugAutomation(
                    key: .schedule,
                    label: "Schedule",
                    detail: "Switches \(parts.joined(separator: ", ")) every day.",
                    cuts: off != nil
                ))
            }
        }

        return out
    }

    /// Plugs to list, stably ordered by id.
    ///
    /// Passing nil for `printerPlugId` keeps EVERY socket, including the printer's own. That is the
    /// normal call: all three sockets live on one physical strip (a P304M), and hiding the printer's
    /// own made the strip look like it was missing a socket even though that socket drives the big
    /// power control above the list.
    ///
    /// Disabled plugs are dropped either way: Bambuddy will not act on them — a deleted Home
    /// Assistant entity can never report — so a dead row would just be noise.
    static func otherPlugs(_ all: [SmartPlug]?, printerPlugId: Int?) -> [SmartPlug] {
        guard let all else { return [] }
        return all
            .filter { plug in
                let isPrinterPlug = printerPlugId != nil && plug.id == printerPlugId
                return !isPrinterPlug && (plug.enabled ?? true)
            }
            .sorted { $0.id < $1.id }
    }

    /// One line for the whole plug: what will happen on its own, if anything.
    static func automationSummary(_ plug: SmartPlug?) -> String {
        let list = plugAutomations(plug)
        guard !list.isEmpty else { return "Nothing switches this plug automatically." }
        return list.map(\.label).joined(separator: " · ")
    }

    /// A display name that is never blank: the plug's own name, else its id, else a generic noun.
    static func plugLabel(_ plug: SmartPlug?) -> String {
        guard let plug else { return "Smart plug" }
        let name = (plug.name ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        return name.isEmpty ? "Plug \(plug.id)" : name
    }
}
