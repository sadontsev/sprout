import Foundation

/// Whether the printer will accept COMMANDS at all.
///
/// Bambuddy reaches the printer over LAN MQTT only. With LAN Developer Mode off, the firmware
/// rejects every message published to `device/{serial}/request` with "mqtt message verify failed" —
/// while status reports keep flowing, so the app looks perfectly healthy. Bambuddy does not check
/// either: it returns success the moment publish() returns, so the API answers 200 and the UI
/// renders a successful pause that never happened. That silent lie is what this exists to end.
///
/// TRI-STATE ON PURPOSE. `.unknown` is not `.off`. `PrinterStatus.developerMode` is nil until the
/// printer has reported (and is absent from the WebSocket feed entirely), and a gate that treats
/// absence as "off" greys out the whole UI on every cold start. Only an explicit false disables
/// anything.
enum LanMode: String, Sendable, Hashable, CaseIterable {
    case on
    case off
    case unknown
}

/// Every action the app can invoke that we care about gating.
///
/// The raw values are the action's stable name — keep them in sync with any other surface that
/// refers to an action by string.
enum ActionId: String, Sendable, Hashable, CaseIterable {
    case pause
    case resume
    case stop
    case light
    case speed
    case amsLoad
    case amsUnload
    case dryStart
    case dryStop
    case startPrint
    case plateCleared
    case printAgain
    case plug
    case camera
    case maintenance
    case queueRemove
}

/// LAN Developer Mode gating: which actions the printer refuses, how a refused control looks, and
/// the copy that explains it.
enum Lan {
    /// Reads the tri-state from a status payload. A missing status, or a status that has not
    /// reported the flag yet, is `.unknown` — never `.off`.
    static func mode(from status: PrinterStatus?) -> LanMode {
        guard let developerMode = status?.developerMode else { return .unknown }
        return developerMode ? .on : .off
    }

    /// Actions the printer refuses without Developer Mode. All of them are `print.*` MQTT commands
    /// on the one verified topic — the same rejection applies to every one, which is why this is a
    /// list and not a per-command investigation.
    ///
    /// An ordered array rather than a `Set` because a `Set` has no order, and `blockedActions(_:)`
    /// has to be deterministic for anything that enumerates or renders them.
    static let blocked: [ActionId] = [
        .pause,
        .resume,
        .speed,
        .amsLoad,
        .amsUnload,
        .dryStart,
        .dryStop,
        .startPrint,
        .printAgain,
    ]

    /// Membership lookup for `blocked`, so `isBlocked` is not a linear scan on every control of
    /// every render.
    private static let blockedSet: Set<ActionId> = Set(blocked)

    /// Whether this action is refused right now.
    ///
    /// Deliberately NOT blocked, each for a specific reason:
    ///
    ///  - `.stop` — THE EMERGENCY CONTROL. A dead grey Stop on a print that is spaghettifying is
    ///    actively dangerous. A Stop that might fail is strictly better than one that cannot be
    ///    pressed.
    ///  - `.light` — the only control here that is not a `print` command; it publishes
    ///    system/ledctrl, which the firmware does not verify the same way.
    ///  - `.camera` — RTSPS on its own port; verified streaming with Developer Mode off.
    ///  - `.plug` — a different device entirely, and the real kill switch when commands are refused.
    ///  - `.plateCleared`, `.queueRemove`, `.maintenance` — Bambuddy-side bookkeeping in its own
    ///    database; the printer is never asked.
    static func isBlocked(_ action: ActionId, _ mode: LanMode) -> Bool {
        mode == .off && blockedSet.contains(action)
    }

    /// Actions blocked right now — for tests and for anything that wants to enumerate them.
    static func blockedActions(_ mode: LanMode) -> [ActionId] {
        mode == .off ? blocked : []
    }

    static let bannerTitle = "Printer controls are locked"
    static let bannerBody =
        "This printer won't accept commands until LAN Developer Mode is on. Monitoring, the camera and your library still work."

    /// Why a specific control is dead, shown when one is tapped. Short, and says what to do.
    static let blockedHint =
        "Turn on LAN Developer Mode on the printer (Settings → Network), then re-enter its new access code in this app."

    static let helpTitle = "Turn on LAN Developer Mode"
    static let helpBody = """
        Your printer reports status, streams the camera and accepts files, but rejects every command this app sends — pause, resume, speed, AMS, drying and starting a print. Its firmware requires signed commands unless Developer Mode is on.

        On the printer:
        1. Settings → Network → LAN Only Mode.
        2. Turn on Developer Mode and confirm.
        3. The printer shows a NEW access code.

        Then update the access code in Bambuddy, and this app will be able to control the printer again.
        """

    /// The one visual treatment for a locked control. Dimming (not hiding, not `.disabled`) keeps
    /// the UI stable and discoverable: the button stays where it was, and tapping it explains
    /// itself.
    static let lockedOpacity: Double = 0.4

    /// The opacity a control should take, or nil to leave whatever the caller already had.
    ///
    /// nil rather than 1 so it composes without clobbering: `lockedStyle(locked) ?? (busy ? 0.5 : 1)`
    /// keeps a caller's own dim (e.g. the dryer buttons' busy state) when nothing is locked.
    static func lockedStyle(_ locked: Bool) -> Double? {
        locked ? lockedOpacity : nil
    }
}
