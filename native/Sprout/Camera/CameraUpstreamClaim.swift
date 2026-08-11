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
/// `CameraRate.tileMetered` on a metered path, and the broadcaster lingers for a 5 s grace
/// window after its last viewer leaves. So opening the fullscreen camera or PiP from the dashboard
/// landed inside that window, inherited the tile's 2 fps, and had no way to ask for more — which is
/// exactly the "fairly low frame rate in PiP" report. Dropping the upstream first is the only lever
/// a client has.
///
/// Deliberately best-effort. `/camera/stop` refuses while ANY subscriber is still attached, and that
/// refusal is the property that makes this safe: if somebody else is watching, we never interrupt
/// them — we share their rate instead. Every failure path here ends the same way, connecting to
/// whatever is already running, because a slow picture beats no picture.
///
/// **Upstream's position (maziggy/bambuddy#2806, closed `wontfix` but documented).** Two corrections
/// worth carrying, because they change what a "better" fix would look like:
///
///  * `?fps=` never reaches the printer. On the RTSP path `-r` is an ffmpeg **output** flag — ffmpeg
///    pulls the full stream regardless and drops frames on the way out — so printer-side load is the
///    same at 2 fps and at 30. The only thing a higher rate costs is frames delivered to the client.
///    So this dance buys frame rate at no cost to the printer, and the reason to keep the dashboard
///    tile low is the phone's bandwidth, not the camera's health.
///  * "Highest requested rate wins" was rejected as the wrong SHAPE of fix: it would restart the
///    shared upstream *while viewers are attached*, which is the fan-out churn behind the A1/P1 black
///    screen in #2521. The fix they'd want is per-subscriber throttling in the broadcaster, which
///    they are not willing to attempt without hardware coverage for every model.
///
/// That objection does **not** apply to what this type does, and the distinction is the whole reason
/// it is safe: the server-side `>= 1 subscriber` guard means we can only ever restart an upstream that
/// nobody is watching. Closing every viewer and reopening is also precisely the procedure the wiki now
/// documents for changing the rate ("Shared streams and FPS"), so this is the sanctioned path rather
/// than a workaround around the maintainer's wishes.
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
