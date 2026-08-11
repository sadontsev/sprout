import Foundation

/// The frame rates the two camera surfaces ask for, kept in one place because they are **not**
/// independent dials.
///
/// Bambuddy runs ONE ffmpeg per printer and fixes its output rate from whichever viewer starts it —
/// `CameraUpstreamClaim` has the mechanism — so these numbers compete for a single stream. Reading
/// them side by side is what makes it visible when the dashboard tile would hand fullscreen a rate it
/// does not want, and, just as usefully, when it would not.
///
/// A higher rate costs the **phone**, not the printer. `?fps=` is an ffmpeg *output* flag: the printer
/// streams at full rate regardless and Bambuddy simply forwards fewer of those frames (maintainer on
/// maziggy/bambuddy#2806). At roughly 200 KB a frame, 10 fps is ~2 MB/s — nothing on home wifi, and
/// about 120 MB a minute over cellular. That asymmetry, not printer load, is what the split below is
/// for.
enum CameraRate {

    /// Fullscreen and Picture-in-Picture, on any path. You are looking at the video, so pay for it.
    static let fullscreen = 10

    /// The always-on dashboard thumbnail on an unmetered path. Deliberately **equal** to `fullscreen`:
    /// when the two match, opening fullscreen inherits a stream that is already the right rate and can
    /// skip restarting the shared upstream altogether. `testTheUnmeteredTileMatchesFullscreen` pins
    /// that equality, because the skip below silently changes meaning if the two drift apart.
    static let tileUnmetered = 10

    /// ...and on a metered or Low Data path, where an always-on thumbnail is the last thing that
    /// should be spending an allowance while nobody is even looking at it.
    static let tileMetered = 2

    /// `isExpensive` is cellular or a personal hotspot; `isConstrained` is Low Data Mode. Both come
    /// straight from `NWPathMonitor`, which answers the actual question — *do these bytes cost the
    /// user anything?* — rather than a stand-in for it such as "is the interface wifi".
    static func tile(isExpensive: Bool, isConstrained: Bool) -> Int {
        (isExpensive || isConstrained) ? tileMetered : tileUnmetered
    }

    /// Whether opening fullscreen has anything to gain by dropping and restarting the shared upstream.
    ///
    /// Note carefully what this does NOT claim. It cannot tell you the rate the upstream is actually
    /// running at — nothing on the client can, which is the substance of maziggy/bambuddy#2806 and the
    /// reason that issue was worth filing. It answers the narrower question it can answer honestly:
    /// *would this app's own tile have started that upstream slower than fullscreen wants?* When the
    /// two rates match, nothing this app does can create a mismatch, so a restart is pure cost — a
    /// wasted ffmpeg respawn and RTSP reconnect in front of the user. When some THIRD party started a
    /// slower stream we simply share it, which is exactly what we would have done anyway had they
    /// still been attached when we asked.
    static func fullscreenNeedsFreshUpstream(tileFps: Int) -> Bool {
        tileFps < fullscreen
    }
}
