import Foundation

// Lifted out of `PrintActivityAttributes.swift`, which is `#if os(iOS)` because `ActivityAttributes`
// does not exist on macOS. The palette is not iOS-only: the Mac menu bar panel draws the same print
// row with the same semantics, and `ExtrusionRider.rides` decides whether the nozzle is drawn by
// comparing against these values on BOTH platforms. Leaving it inside the guard meant the Mac had to
// either re-declare the hexes — two copies of a wire contract — or ask a different question.

/// Fixed palette for Live Activity content — deliberately NOT the app's theme tokens.
///
/// A card lives on the lock screen, which has no relationship to the in-app theme, and Trellis
/// (which owns cards in server mode) has no idea what theme the phone is on: it always sends these
/// values. Reading the themed colour meant a light-mode app produced #23B24A while an identical card
/// pushed from the server produced #30D158 — the same print rendering in two different greens
/// depending on which side created it. **These MUST equal Trellis's COLORS.**
enum LAColors {
    static let running = "#30D158"
    static let heating = "#FF9F0A"
    static let paused = "#0A84FF"
    static let error = "#FF453A"
    static let idle = "#8E9398"
    /// Drying amber — matches Trellis's `dry_state`.
    static let drying = "#FFB86C"
}
