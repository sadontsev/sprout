import Foundation

/// What a printer is doing, in the vocabulary the status surfaces speak.
///
/// **One ladder, two consumers, and they must not drift.** The iOS Live Activity picks a tint from
/// the dashboard view model; the Mac menu bar picks a glyph from the same view model. Those were
/// about to be two `switch`es over the same inputs written a month apart — and the moment they
/// disagree, the phone says a print is paused while the Mac says it is running, about the same
/// machine, at the same second.
///
/// The ladder is ORDERED and the order is the content: error beats paused beats not-running beats
/// heating. Reading it as a set of independent conditions is how a paused-with-an-error state ends up
/// reported as merely paused.
///
/// Lives in `Domain/` rather than `Shared/` because it takes a `DashVM`, which the widget target does
/// not compile — the widget renders from the wire's `tint` string and never needs to derive one.
enum LAState: String, CaseIterable, Sendable {
    case idle, heating, printing, paused, error, complete, drying, offline

    /// The state of a machine, given its dashboard view model and whether any AMS unit is drying.
    ///
    /// `drying` is a separate argument because it is not a `DashKind`: a dry cycle runs alongside
    /// whatever the printer is doing, so it can only ever be the answer when nothing else is
    /// happening. A print outranks it — the print is the thing with a deadline.
    static func of(vm: DashVM, drying: Bool = false) -> LAState {
        if vm.kind == .error { return .error }
        if vm.isPaused { return .paused }
        if vm.kind == .complete { return .complete }
        if vm.kind == .offline || vm.kind == .connecting { return .offline }
        if vm.kind == .idle { return drying ? .drying : .idle }
        return vm.stateColor == .heating ? .heating : .printing
    }

    /// The wire colour for this state — one of `LAColors`, which Trellis must agree with.
    ///
    /// `complete` is deliberately `running` green rather than a colour of its own: a finished print
    /// is a good outcome, and the card stays up until the plate is cleared. That is existing shipped
    /// behaviour, preserved here rather than re-decided.
    var tintHex: String {
        switch self {
        case .error: return LAColors.error
        case .paused: return LAColors.paused
        case .idle, .offline: return LAColors.idle
        case .heating: return LAColors.heating
        case .drying: return LAColors.drying
        case .printing, .complete: return LAColors.running
        }
    }
}
