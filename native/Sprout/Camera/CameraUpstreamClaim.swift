import Foundation

/// What one `/camera/stop` call means to a viewer that wants the shared upstream running at ITS
/// frame rate.
enum CameraUpstreamClaimStep: Equatable {
    /// No shared upstream is running any more — or none ever was. Connecting now creates a fresh one
    /// at whatever `fps` this viewer asks for.
    case proceed
    /// The backend refused to tear the upstream down because another viewer is still attached. Wait
    /// and ask again: the dashboard tile's own disconnect is noticed asynchronously, so the first
    /// call after the overlay opens routinely lands while the tile is still counted as a subscriber.
    case retry
}

/// Why a client has to tear the camera down before it can watch it properly.
///
/// Bambuddy runs ONE ffmpeg per printer and fans it out to every viewer. That upstream's output rate
/// is `-r <fps>`, taken from whichever viewer *created* the broadcaster; every later viewer's `?fps=`
/// is accepted and then ignored — "the upstream's fps is fixed by the first viewer who creates the
/// broadcaster" (`backend/app/api/routes/camera.py`). The dashboard tile deliberately asks for
/// `DashboardView.tileFps` because it is a thumbnail, and the broadcaster lingers for a 5 s grace
/// window after its last viewer leaves. So opening the fullscreen camera or PiP from the dashboard
/// landed inside that window, inherited the tile's 2 fps, and had no way to ask for more — which is
/// exactly the "fairly low frame rate in PiP" report. Dropping the upstream first is the only lever
/// a client has.
///
/// Deliberately best-effort. `/camera/stop` refuses while ANY subscriber is still attached, and that
/// refusal is the property that makes this safe: if somebody else is watching, we never interrupt
/// them — we share their rate instead. Every failure path here ends the same way, connecting to
/// whatever is already running, because a slow picture beats no picture.
enum CameraUpstreamClaim {

    /// The tile's HTTP disconnect is observed asynchronously, so the first attempt often lands while
    /// the backend still counts it.
    static let pollIntervalMilliseconds = 250

    /// Total time worth spending before giving up. Spent BEFORE the first frame can arrive, on top of
    /// the camera's own ~1.3 s cold warm-up, so it is kept short: this buys frame rate, and paying
    /// for it with a visibly slower open would be a bad trade.
    static let budgetMilliseconds = 2_000

    /// Derived rather than written down twice — the two constants above are the tuning knobs, and a
    /// hand-maintained attempt count is the kind of thing that silently stops matching them.
    static var maxAttempts: Int { budgetMilliseconds / pollIntervalMilliseconds }

    static var pollInterval: Duration { .milliseconds(pollIntervalMilliseconds) }

    static func step(stopped: Int, skipped: Bool) -> CameraUpstreamClaimStep {
        skipped ? .retry : .proceed
    }
}
