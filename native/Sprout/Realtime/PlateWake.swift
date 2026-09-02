#if os(iOS)
import ActivityKit
import Foundation

/// What the app does with the few seconds a silent push buys it: fetch this print's plate and write
/// it into the App Group, so the card stops drawing a brand glyph.
///
/// **Why this exists at all.** The plate is written by the app, and a print started from Bambu's own
/// app finds Sprout closed. Measured: the card was live and correct for an hour while Bambuddy held
/// the picture the whole time and the phone made no requests at all. Trellis pushes the card into
/// existence; nothing pushes the picture, because a picture cannot travel in a `ContentState`.
///
/// **Why it is self-sufficient rather than reusing `AppModel`.** A background launch never runs
/// `AppModel.load()` or `connect(_:)`, so the client, the camera token and the delegate's callbacks
/// are all nil there. Anything that reached for them would work in the foreground — where it is not
/// needed — and silently do nothing in the background, which is the only place it is.
///
/// **Nothing needs to be told about the file.** `LiveActivityArt.plateURI` derives the path from the
/// activity's `printerId` (a static attribute no push can touch) and the job name, and the widget
/// already calls it. So writing the file is the whole job: the next routine Trellis push re-renders
/// the card and finds it. No ActivityKit update, no new field on the wire.
@MainActor
enum PlateWake {

    /// Resolve the plate for every live print card. Returns whether anything was written.
    ///
    /// The answer is the `UIBackgroundFetchResult` the delegate reports, and iOS budgets future
    /// wakes on it — so a run that found nothing must say so rather than claim new data.
    static func run() async -> Bool {
        guard let config = SecureConfig.load(), config.isComplete else { return false }

        let client = BambuddyClient(
            baseUrl: config.baseUrl,
            apiKey: config.apiKey,
            adminUsername: config.adminUsername,
            adminPassword: config.adminPassword
        )

        // Library thumbnails and the printer's cover are gated by a camera STREAM token, not the API
        // key. The stored one is preferred because minting costs a round trip out of a budget
        // measured in seconds; a mint is the fallback, not the first move.
        var token = config.cameraToken
        if token == nil || token?.isEmpty == true {
            token = try? await client.mintCameraToken()
        }

        let resolver = LiveActivityArtResolver()
        var wrote = false
        for activity in Activity<PrintActivityAttributes>.activities {
            // Print cards only. A drying card shows a spool tile and has no plate to fetch, so
            // asking for one would spend the wake on a request whose answer is never drawn.
            guard activity.attributes.amsId == nil else { continue }
            let job = activity.content.state.name
            guard !job.isEmpty else { continue }
            // `sweep: false` — see `LiveActivityArtResolver.plate`. This resolver knows about one
            // card and would take the others' plates with it.
            // WHICH PLATE. The card's `ContentState` cannot say — it carries no plate, and adding
            // one would be a wire-format change shared with a service that deploys separately — so
            // the wake asks the printer. One request, and without it this path guessed plate 1 and
            // could write the wrong picture for a job the foreground had never resolved.
            //
            // Best-effort like everything else here: a failed status means an unknown plate, not a
            // failed wake.
            let status = try? await client.getStatus(activity.attributes.printerId)
            let uri = await resolver.plate(
                printerId: activity.attributes.printerId,
                jobName: job,
                library: [],
                sdFiles: [],
                client: client,
                token: token,
                plateIndex: PrintArt.plateIndex(
                    gcodeFile: status?.gcodeFile, currentPlateId: status?.currentPlateId?.int),
                sweep: false
            )
            if !uri.isEmpty { wrote = true }
        }
        return wrote
    }
}
#endif
