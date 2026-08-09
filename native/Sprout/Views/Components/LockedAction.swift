import SwiftUI

/// The two halves of a LAN-gated control — the dim and the guard — kept in one place, so a button
/// can never look enabled while its handler refuses (or the reverse). Every gated control pairs
/// `style(_:)` with `press(_:_:)`: one decision, applied to both the look and the tap.
///
/// A value built in the view body from the live mode, so there is no second copy of `LanMode` to
/// keep in sync. The screen owns the alert flag and attaches the alert once:
///
/// ```swift
/// @State private var lanAlert = false
/// private var locked: LockedActions { LockedActions(mode: lanMode, explaining: $lanAlert) }
///
/// Tap(action: locked.press(.pause) { vm.pause() }) { PauseLabel() }
///     .locked(.pause, by: locked)
/// // …once, on the screen's root:
/// .lockedActionAlert($lanAlert)
/// ```
struct LockedActions {
    var mode: LanMode

    /// Raised when a locked control is tapped. The explanation is identical for every action, so
    /// there is nothing to remember about WHICH one was tapped.
    @Binding var explaining: Bool

    func blocked(_ action: ActionId) -> Bool {
        Lan.isBlocked(action, mode)
    }

    /// The control's opacity, or nil to leave the caller's own opacity alone.
    func style(_ action: ActionId) -> Double? {
        Lan.lockedStyle(blocked(action))
    }

    /// Wraps a control's handler in the gate. Returns a closure rather than running immediately
    /// because that is exactly what `Button`/`Tap` want for `action:`.
    ///
    /// The control stays tappable when locked — the tap is what surfaces the explanation. A
    /// `.disabled` button would swallow it and leave the user with a dead grey square and no reason.
    func press(_ action: ActionId, _ run: @escaping () -> Void) -> () -> Void {
        {
            guard !self.blocked(action) else {
                self.explaining = true
                return
            }
            run()
        }
    }
}

extension View {
    /// Dims this control while `action` is locked. Always pair it with `LockedActions.press` on the
    /// same action.
    func locked(_ action: ActionId, by actions: LockedActions) -> some View {
        opacity(actions.style(action) ?? 1)
    }

    /// The one alert that explains a dead control. Attach once per screen that has gated controls.
    func lockedActionAlert(_ explaining: Binding<Bool>) -> some View {
        alert(Lan.bannerTitle, isPresented: explaining) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(Lan.blockedHint)
        }
    }
}
