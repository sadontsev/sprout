<!-- Produced by a six-dimension review; every finding was then adversarially verified by a
     separate agent whose default was to reject it. 49 raised, 21 survived. -->
# Code review — native app, 2026-08-10

Reviewed at build 8. Nothing here is fixed yet. Ordered by severity; the file/line is where the
defect lives, and the scenario is what a user would actually see.

> Findings were verified against the running code, not just read. Where a reviewer's claim was
> refuted it was dropped rather than softened — so treat this list as work, not suggestions.

## High (12)

### Widget traps (crashes) whenever the card's ETA has passed — `Date()...eta` with eta < now

`SproutWidget/PrintActivityWidget.swift:100`

`etaDate` is non-nil for any `etaEpochMs > 0`, and three render sites build a `ClosedRange<Date>` as `Date()...eta` without checking ordering: `LockScreenCard` (line 100), `DynamicIslandExpandedRegion(.trailing)` (line 28), and `compactTrailing` for drying cards (line 61). `...` calls `precondition(minimum <= maximum)`, so the widget process traps as soon as the stored ETA is in the past. This is not exotic: the content state is sticky. In LOCAL mode the app is the only updater and stops the moment it is suspended, so the last pushed state — e.g. `etaEpochMs = now + 12 min` — is re-rendered by WidgetKit on every lock-screen wake or Dynamic Island expansion thereafter. Twenty minutes later that range is inverted. Prints also routinely overrun their own estimate while the app is backgrounded. The guard `remainingMin > 0` in `LiveActivityController.content` (line 86) only ensures the ETA is future *at the moment it is computed*; nothing keeps it future at render time. `content()` never clamps and the widget never compares.

**Failure:** A print is running with 10 minutes remaining; the user locks the phone and the app is suspended, so no further updates are pushed. 15 minutes later the user wakes the phone. The widget re-renders `LockScreenCard` with `etaEpochMs` 5 minutes in the past, evaluates `Date()...eta`, and traps with "Can't form Range with upperBound < lowerBound". The Live Activity dies / renders as an unavailable placeholder for the rest of the print.

### SERVER mode produces no Live Activity at all: the app refuses to start a card and never registers a push-to-start token

`Sprout/Realtime/LiveActivityController.swift:233`

`upsert` returns at line 233 (`guard !isServerOwned else { return }`) so the app never calls `Activity.request` when a push URL resolves — correct per the ownership model. But the other half of that model is missing: nothing anywhere in `native/` observes `Activity<PrintActivityAttributes>.pushToStartTokenUpdates` or POSTs to Trellis's `/register-start` (grep for `pushToStart`, `register-start`, `activityStateUpdates` across `native/` returns zero hits). Trellis can only create a card via `_push_start()`, which iterates `_p2s_tokens` — a list populated exclusively by `POST /register-start` (deploy/trellis/app.py:787). With no token registered, the server can never start a card and the app is forbidden from starting one, so neither party ever creates it. SERVER mode is the default whenever `baseUrl` contains `bambuddy.` (`ConfigRules.resolvePushUrl`, line 58) or `serverPush` is left at its default `true` (`SettingsView.swift:17`), i.e. the owner's real configuration. This is not listed among the known gaps in docs/native-rewrite/00-overview.md, and it fails acceptance criteria 30–33 outright. (Compounding it: Trellis's `_envelope()` at app.py:305 still wraps content as `{name, props}` for expo-widgets, which the flat native `ContentState` cannot decode — the coordinated change flagged as the port's highest risk in 07-realtime.md has not been made.)

**Failure:** Owner installs the native build with the usual `https://bambuddy.example.com` base URL. `resolvePushUrl` derives `https://lapush.example.com`, so `isServerOwned == true`. A print starts. `upsert` computes content, finds no matching activity, and returns at line 233. Trellis polls, sees a print, and has no push-to-start token to send to. No card ever appears on the lock screen, for any print or drying cycle, with no error surfaced.

### `register()` posts to an endpoint Trellis does not serve, with the wrong body shape — and is unreachable dead code besides

`Sprout/Realtime/LiveActivityController.swift:272`

Two independent problems. (1) Unreachable: `observePushToken` is only called at line 244 under `if pushUrl != nil`, inside the `Activity.request` branch that line 233 already guarantees is reached only when `pushUrl == nil`. So the condition at line 244 is provably always false and `observePushToken`/`register` never run. `pushType: pushUrl == nil ? nil : .token` (line 240) is dead for the same reason — activities are always requested with `pushType: nil`, so they have no APNs update token even if the server later learned about them. (2) Wrong contract: `register` POSTs to `pushUrl + "/register-activity"` (line 272) with `{token, printer_id, ams_id}`. Trellis exposes `POST /register` (deploy/trellis/app.py:860) and its `Register` model requires `push_token` and `printer_id` plus `printer_name`, `icon_uri`, `kind` ("print"|"dry") and `ams_id`; there is no `/register-activity` route. The response is discarded (`_ = try? await URLSession.shared.data(for: req)`, line 289), so a 404 or a 422 validation error is silently swallowed. Note also that even the card key differs: Trellis keys drying cards `"dry:<pid>:<amsId>"` off the `kind` field the app never sends.

**Failure:** Once the SERVER-mode start path is fixed so a card exists, the app hands its APNs token to `POST /register-activity`, Trellis's FastAPI router returns 404, the app ignores it, and the server never binds a token to the card — so the card is created and then frozen at its initial content, the exact 'card stuck at 0%' symptom this subsystem was rewritten to eliminate.

### connect() replaces the status/cooldown stores without stopping the old ones, leaking a live WebSocket and two poll loops per call

`Sprout/App/AppModel.swift:86`

`connect(_:)` assigns fresh `PrinterStatusStore` (line 103-105), `CooldownStore` (107-109) and `LiveActivityController` (111) over whatever is already there. The four `start*Refresh()` helpers below it do cancel their previous tasks (`fleetTask?.cancel()` etc.), but `status?.stop()` and `cooldown?.stop()` are never called, so the previous two stores are simply dropped — and neither can be collected:

- `PrinterStatusStore.start()` binds `guard let self` and then `await self.runSocketOnce()` (PrinterStatusStore.swift:70-73). That call does not return while the socket is pumping, so the strong binding pins the store for the entire connection. The file comment claims the opposite ("so a dead store is collected instead of being pinned by the loop").
- `CooldownStore.start()` puts `guard let self` *outside* the `while` loop (CooldownCard.swift:35-48), so the `[weak self]` capture is defeated for the loop's whole lifetime.

Worse, `printerId = cfg.printerId ?? 0` on line 100 runs before the new stores exist, so its `didSet` (line 35-43) calls `cooldown?.start(printerId:)` on the *old* store — restarting the loop of the object that is about to be orphaned.

This is reachable from the UI: `SettingsView.connect()` (SettingsView.swift:279) calls `model.connect(saved)` on every tap of "Save" in the settings sheet, not just onboarding.

**Failure:** User opens Settings, changes the API key (or just taps Save twice), and taps Save. `connect()` builds a second `BambuddyClient`/`PrinterStatusStore`/`CooldownStore`. The first store's socket task is still suspended in `runSocketOnce`, holding a strong `self`, so the old store never deallocates: its WebSocket stays open and it keeps decoding frames into a map nobody reads. The old `CooldownStore` keeps calling `sensorHistory` every 60 s with the *old* API key forever. Every subsequent Save adds another socket + another 60 s poller; nothing ever reclaims them.

### MJPEGStreamClient's per-connection state is mutated from the main queue while URLSession delegate callbacks run on its own queue — force-unwrap trap and Data corruption

`Sprout/Camera/MJPEGStream.swift:470`

The class documents its state as "single-threaded by construction" because URLSession delivers callbacks on the serial `delegateQueue` (line 290-296). That invariant is broken by three main-queue entry points:

1. `start(url:)` (328) and `stop()` (341) are called from `CameraPiPRenderer.connect()`'s `DispatchQueue.main.async` block (CameraPiPRenderer.swift:217-227), from `CameraPiPRenderer.stop()` (171) and from the PiP `setPlaying` delegate (323) — all main queue.
2. `resetConnectionState()` (355) writes `parser`, `sawFirstFrame`, `demultiplexed`, `partExpected` and `partBuffer` from that main-queue path.
3. The first-frame watchdog `DispatchWorkItem` is scheduled with `DispatchQueue.main.asyncAfter` (387) and reads `self.sawFirstFrame` then calls `fail()` → `stop()` → mutates `task` and `firstFrameDeadline`, and invokes `delegate?.streamDidFail` on the main thread even though the protocol contract (line 231) says callbacks arrive on the delegate queue.

`task?.cancel()` is asynchronous, so a delegate callback can be in flight or already enqueued when `resetConnectionState()` runs. Two concrete corruptions: `guard parser != nil else { return }` on line 470 followed by `try parser!.consume(data)` on line 472 is a check-then-use across threads; and `partBuffer.append(data)` (459) racing `partBuffer.removeAll(keepingCapacity: true)` (360) mutates one `Data` value's COW buffer from two threads.

**Failure:** Camera token rotates (or the user taps Retry) while a frame is arriving. `CameraPiPUIView.setURL` → `renderer.connect()` → `client.start(url:)` runs `resetConnectionState()` on the main thread and sets `parser = nil` in the window between line 470's nil-check and line 472's `parser!` on the delegate thread → `Unexpectedly found nil while unwrapping` trap. The `partBuffer` variant instead corrupts the heap silently or crashes inside `Data.append`.

### AVPictureInPictureController is read from the URLSession delegate (network) queue

`Sprout/Camera/CameraPiPRenderer.swift:258`

`streamDidReceiveFrame` (249) and `streamDidFail` (273) are documented as "called on the network queue" (line 247). Both read `pip?.isPictureInPictureActive` — line 258 and line 281. `pip` is an `AVPictureInPictureController`, which the file itself asserts is main-thread-only (`assert(Thread.isMainThread, "AVPictureInPictureController is main-thread-only")`, line 180), and the stored property is written on the main queue at line 202.

So this is both a main-thread-only AVKit API touched off the main thread and an unsynchronised read of a `var` written on another queue. The `@unchecked Sendable` justification on line 110-112 ("every mutation is funnelled onto the main queue by connect/emit ... The delegate callbacks that arrive on the network queue only append to the frame gate") is not what the code does.

**Failure:** With PiP enabled and the stream running at 10 fps, every 20th frame (line 257) reads `pip?.isPictureInPictureActive` from the network thread while UIKit/AVKit mutates the controller on main during a PiP transition — undefined behaviour under the AVKit threading contract, and it reports a torn `pipActive` value up to `CameraPiPModel` through the `.stats` event. On the `streamDidFail` path (281) the same read decides whether to reconnect, so PiP can be left with a dead stream (frozen floating window) or reconnect when it shouldn't.

### stop() never closes the WebSocket — the task stays suspended in receive() holding a strong self

`Sprout/Realtime/PrinterStatusStore.swift:80`

`stop()` cancels `socketTask`, but the only place that closes the socket is the `defer` inside `runSocketOnce` (106-110), which cannot run while the task is suspended at `try await socket.receive()` (line 113). `URLSessionWebSocketTask.receive()` is the compiler-generated async form of `receiveMessageWithCompletionHandler:` and does not observe Swift task cancellation — there is no `withTaskCancellationHandler` wrapping it and no `socket.cancel()` on the cancellation path. The `while !Task.isCancelled` on 112 is only consulted *between* messages.

Because the outer loop's `guard let self` (line 71) stays in scope across `await self.runSocketOnce()`, the store is also strongly retained for as long as the socket sits there, so it cannot deallocate either.

**Failure:** User taps Disconnect. `signOut()` calls `status?.stop()` and drops the store. The printer is idle so no frame arrives; the task never resumes, `socket.cancel(with:.goingAway,...)` never executes, and the `wss://…/api/v1/ws?token=…` connection stays open for the process lifetime with the store pinned behind it. If the user then reconnects with a different server or key, both sockets are live at once.

### `isLive` is a write-once latch, so any re-arm strands the overlay in "NO SIGNAL" over a live picture

`Sprout/Camera/CameraPiPView.swift:113`

`CameraPiPModel.isLive` (line 72) is only ever set to `true` (line 113); no event path sets it back to `false`. `CameraOverlay` drives its phase machine exclusively from `.onChange(of: pip.isLive)` (CameraOverlay.swift:131) — and `onChange` cannot fire when the value does not change. Meanwhile `CameraOverlay` re-arms `phase = .connecting` on every change of `attempt = Attempt(token:reload:)` (CameraOverlay.swift:119-130), which happens on the manual Retry button (`reloadKey += 1`, line 492) and on the 45-minute camera-token rotation in `AppModel.startCameraTokenRefresh` (AppModel.swift:199-210). After a re-arm, the only thing that could move the phase back to `.live` is a *transition* of `isLive` that can never occur again, so the 40 s `warmUpDeadline` task unconditionally flips `phase = .failed`. The snapshot probe cannot save it either — it only short-circuits to `.failed` on HTTP >= 400, never to `.live`.

**Failure:** Open the fullscreen camera, wait for the LIVE badge. Tap the Retry chip (or just leave it open until the 45-minute token refresh fires). `attempt` changes → `phase = .connecting`, so the "CONNECTING…" card is drawn over the video. The renderer reconnects and delivers frames normally, re-emitting `.live`, but `model.isLive` is already `true`, so `onChange` never fires. 40 s later the overlay renders the "CHAMBER · NO SIGNAL" failure card, with Retry/Diagnose buttons, on top of a perfectly live, moving picture — and every subsequent Retry reproduces it.

### Pausing the PiP window kills the stream permanently — `setPlaying(false)` never sets `stopped`

`Sprout/Camera/CameraPiPRenderer.swift:322`

`pictureInPictureController(_:setPlaying:)` resumes with `if playing { if stopped { start(urlProvider: makeStreamURL) } }` but pauses with a bare `client.stop()`. `stopped` is only written by `CameraPiPRenderer.start()`/`stop()` (lines 165, 170), so after a pause it is still `false` and the resume branch is a no-op. `client.stop()` cancels the URLSessionTask, and `didCompleteWithError` returns early on `URLError.cancelled` (MJPEGStream.swift:530), so no `streamDidFail` fires and no reconnect is scheduled. `pictureInPictureControllerIsPlaybackPaused` (line 332) also returns `stopped` — i.e. `false` — so `invalidatePlaybackState()` re-renders the PiP transport as *playing* over a dead stream, and the next tap sends `setPlaying(false)` again rather than `true`.

**Failure:** Start PiP, then tap the pause button in the floating window. The task is cancelled and no frames arrive. Tap play: `setPlaying(true)` runs, `stopped == false`, nothing restarts. The PiP window is frozen on its last frame forever and the transport control claims it is playing. The only recovery is dismissing and re-presenting the whole camera overlay (which builds a fresh `CameraPiPUIView`/renderer).

### TempGrid gives every temperature card a fresh UUID on every render, destroying its animation state

`native/Sprout/Views/DashboardView.swift:771`

`TempGrid.Card` declares `let id = UUID()` (line 771) and `cards` is a *computed* property (line 779) rebuilt on every body evaluation. `ForEach(row) { card in tempCard(card) }` (line 805) therefore sees brand-new identities each pass, so SwiftUI tears down and recreates every temperature card instead of updating it.

`DashboardView.vm` is `model.vm`, which is `Dash.present(status?.status)` — a computed property over the observed `PrinterStatusStore`. During a live print the DashVM changes on every WebSocket frame, so this churn happens roughly once a second, exactly when the animations matter.

Three pieces of state die with each rebuild:
- `RollingNumber`'s `.contentTransition(.numericText(value:))` + `.animation(Motion.roll(0.6), value: value)` (Anim.swift:85-86) only animate across a value change on a *stable* identity. A newly-inserted view renders at its final value with no transition, so nozzle/bed/chamber temperatures snap instead of rolling. This is acceptance criterion 36 in docs/native-rewrite/00-overview.md ("Temperatures roll rather than jump").
- `HeatBar`'s `@State private var shimmer` (Anim.swift:129) resets to false and re-arms via `.onChange(initial: true)` on every frame, so the 700 ms repeatForever shimmer restarts before it can complete a leg — the heating bar never visibly shimmers.
- `PulseDot`'s `@State private var dim` (Anim.swift:101) resets the same way, so the heating dot in `tempCard` never breathes.

Every other `ForEach` in the file uses a stable id (`vm.ams` keys on `globalId`, `model.printers` on `id`); this is the one that doesn't. Fix: derive `Card.id` from `label` (which is already unique per card: "Left nozzle"/"Right nozzle"/"Nozzle"/"Bed"/"Chamber").

**Failure:** Start a print and watch the dashboard. Every status frame (~1/s) replaces all TempGrid cards: the nozzle reading jumps 214° → 215° with no numeric roll, the heating bar's shimmer restarts from full opacity each second instead of pulsing, and the heating indicator dot stays static rather than breathing.

### Camera overlay's Retry can strand a working live stream on "CONNECTING…" and then "NO SIGNAL"

`native/Sprout/Views/Overlays/CameraOverlay.swift:131`

`phase` only ever reaches `.live` through `.onChange(of: pip.isLive) { _, isLive in if isLive { phase = .live } }` (lines 131-133) — an *edge* trigger. But `CameraPiPModel.isLive` is a one-way latch: `Sprout/Camera/CameraPiPView.swift:114` is the only write (`model.isLive = true`) and nothing ever sets it back to false (grep confirms three references total).

Meanwhile both `.task(id: attempt)` blocks assign `phase = .connecting` (lines 120, 124) whenever `attempt` changes, and `attempt` is `Attempt(token:reload:)` (line 77). `retry()` bumps `reloadKey` unconditionally (line 492), and the retry chip is in `topChrome` at all times (line 278), not just on the failure card.

So: tap Retry while the stream is live. `attempt` changes → `phase = .connecting`. `retry()` then tries `client.mintCameraToken()`; the comment at line 495-497 explicitly allows that mint to fail ("Keep the old token if the mint fails"). With the token unchanged, `streamUrl` is unchanged, so `CameraPiPView` does not restart (by design, line 145-146), `isLive` stays true, `onChange` never fires again, and `phase` is stuck at `.connecting`. Forty seconds later the deadline task flips it to `.failed` (line 129) and `stateCard` paints "CHAMBER · NO SIGNAL" plus the failure copy over video that is still rendering. `probeSnapshot` cannot rescue it — it only ever sets `.failed`, never `.live` (line 533).

The same trap fires without any user action: `AppModel` re-mints the shared camera token every 45 minutes, which changes `attempt.token`. If the renderer hot-swaps the URL without re-emitting `.live`, the overlay again decays to NO SIGNAL over live video.

Fix: make `phase` a function of the current state rather than an edge — e.g. `if pip.isLive { phase = .live }` inside the `.task(id: attempt)` bodies before re-arming, or reset `pip.isLive` when the renderer restarts.

**Failure:** Open the fullscreen camera, wait for video, then tap the ⟳ chip in the top chrome. If the token mint fails (server hiccup) or returns the same token, the live picture is immediately covered by the "CONNECTING… / Waking the chamber camera" card, and 40 s later by "CHAMBER · NO SIGNAL — Couldn't wake the chamber camera", with frames still decoding behind it. Only closing and reopening the overlay recovers.

### SliceJob flattens the slice-job `result` object, so the newly sliced file id is always nil

`native/Sprout/Api/Models.swift:577`

`GET /api/v1/slice-jobs/{id}` returns the outputs nested under `result` — `docs/phase0-results.md:37` records it as validated live: "`GET /api/v1/slice-jobs/{job_id}` → `result.{library_file_id, print_time_seconds, filament_used_g, filament_used_mm}`", and the RN source it was ported from reads `setResult(j.result ?? {})` (`mobile/src/components/Overlays.tsx:1039`), with the spec repeating it at `docs/native-rewrite/01-api.md:348`.

`SliceJob` (Models.swift:577-586) declares `printTimeSeconds`, `filamentUsedG`, `filamentUsedMm` and `libraryFileId` as TOP-LEVEL properties and has no `result` member at all. With `keyDecodingStrategy = .convertFromSnakeCase` these bind to root-level `print_time_seconds` / `library_file_id`, which do not exist on the response, so every one of them decodes to nil on a successful slice.

The wizard then consumes them at `Sprout/Views/Overlays/WizardView.swift:1177-1182` (`result = SliceResult(printTimeSeconds: job.printTimeSeconds?.double, filamentUsedG: job.filamentUsedG?.double, libraryFileId: job.libraryFileId)`), and the `SliceResult` doc comment at WizardView:1270 says exactly what is lost: "including the NEW library file id, which is what actually gets enqueued".

**Failure:** Print an STL through the wizard. The slice completes; `job.libraryFileId` is nil because the id lives at `result.library_file_id`. Step 5 renders `plateReview(fileId: result?.libraryFileId ?? file.id, ...)` (WizardView:888) against the ORIGINAL STL, which has no plates, so the review shows nothing and no time/filament estimate. Pressing Start computes `let libraryFileId = result?.libraryFileId ?? file.id` (WizardView:1224) and enqueues `"library_file_id": .int(<original unsliced STL id>)` (WizardView:1236) instead of the sliced .gcode.3mf Bambuddy just produced — the queue item points at the wrong (unprintable) file and the print never starts.

## Medium (24)

### The `/sync` reconcile protocol is absent although the class doc claims it, so a swiped card can never be replaced

`Sprout/Realtime/LiveActivityController.swift:10`

The type comment (lines 9-11) states that in SERVER mode the app "registers push tokens and reconciles, reporting the full set of live activities so the server can notice a user-swiped dismissal." No reconcile exists: there is no timer, no enumeration-and-report, and no call to `/sync` anywhere in `native/` (grep for `/sync` returns nothing). Trellis's `/sync` handler (deploy/trellis/app.py:804) documents exactly why it is mandatory: APNs answers 200 for a card the user has swiped away, so the server keeps believing it owns a vanished card and refuses to start a replacement. 07-realtime.md, gotcha 2, says explicitly "do not remove `/sync` naively… until [the `activityStateUpdates` redesign] lands, port `/sync` as-is" — and `activityStateUpdates` is not observed either, so the better native alternative is not implemented in its place. This is also not in the known-gaps table.

**Failure:** In SERVER mode a card is up for a running print and the user swipes it away from the lock screen. Trellis's `_regs` still holds a registration for that printer, `_p2s_pending` blocks a fresh push-to-start, and the app never reports the card's absence. The lock screen stays empty for the remaining hours of the print, and Trellis keeps spending APNs pushes into the void.

### Only the selected printer is reconciled, so a second printer's card freezes and is never ended

`Sprout/App/AppModel.swift:184`

`startDerivedRefresh` calls `sync(printerId: self.printerId, …)` for the currently selected printer only. The RN app passed one `ActivityEntry` per fleet printer built from the accumulated `statuses` map — 10-shell-config.md §8: "Every printer in the fleet gets an entry; the hook starts/updates/ends a card per printer based on its live state, so A1 and H2C show as two separate cards on the lock screen." `PrinterStatusStore.statuses` already carries every printer seen on the socket and its own doc comment says the Live Activity logic reads it, but nothing does. Every path inside `sync` filters on the single `printerId`: `upsert`'s activity lookup (line 221), `end` (line 255) and the drying teardown loop (lines 202-208). A card belonging to a non-selected printer therefore receives no updates and is never ended, since nothing else in the app will ever be called with that printer's id.

**Failure:** The H2C is printing with a card on the lock screen. The user switches the fleet selector to the A1 to check on it. The H2C card stops updating immediately — frozen progress, frozen temperatures, a countdown running toward an ETA that is never corrected — and when the H2C print finishes nothing ends the card; it lingers until ActivityKit's own expiry. Additionally the A1 gets no card at all until it is the selected printer.

### In SERVER mode the app still calls `activity.update()`, violating the single-owner invariant the file exists to enforce

`Sprout/Realtime/LiveActivityController.swift:220`

`upsert` runs its update loop (lines 220-229) before the `guard !isServerOwned` at line 233, so when a push URL resolves the app writes locally-computed content into cards the server also pushes to. The file's own doc (lines 8-11) says SERVER mode means "the server starts, updates and ends every card", and 07-realtime.md gotcha 3 keeps "exactly one owner per card" as the invariant that killed the duplicate/zombie/mismatched-content bugs. Two writers with independent gating do not merely waste budget: the app's throttle state (`lastContent`/`lastUpdate`) knows nothing about the server's pushes, and Trellis polls Bambuddy every 5 s while the app reads a WebSocket, so the two sides hold different snapshots. ActivityKit's per-app update budget is also finite; doubling the push rate makes it the limiting factor (07-realtime.md gotcha 11).

**Failure:** Once server-mode cards work, Trellis pushes progress 41% from its 5 s poll; a second later the app's 4 s sync loop writes its own slightly older snapshot showing 40%, then the server pushes 42%. The card's progress and countdown visibly jitter backwards, and the doubled push rate exhausts the ActivityKit budget so genuine updates start being dropped.

### MJPEGStreamClient's URLSession retains it as its delegate, so deinit (and its invalidateAndCancel) can never run

`Sprout/Camera/MJPEGStream.swift:363`

Line 325 creates `URLSession(configuration:delegate:delegateQueue:)` with `self` as the delegate. URLSession keeps a *strong* reference to its delegate until the session is explicitly invalidated. The client holds `session` (line 272) and the session holds the client — an unbreakable cycle. The only invalidation is `deinit { session?.invalidateAndCancel() }` on line 363, which is exactly the code that cannot execute while the cycle exists.

Contrast with `UploadDelegate.perform` (Api/UploadDelegate.swift:26) and `FileDownloadDelegate.run` (Views/LibraryView.swift:1494), which both `defer { session.finishTasksAndInvalidate() }` and are therefore correct.

Each fullscreen camera open builds a `CameraPiPUIView` → `CameraPiPRenderer` → a new `MJPEGStreamClient` (CameraPiPRenderer.swift:120), so the leak accumulates per open.

**Failure:** Open the camera overlay, close it, repeat. Each cycle permanently leaks one MJPEGStreamClient, one ephemeral URLSession and its `bambu.mjpeg.net` OperationQueue (plus any not-yet-fired first-frame `DispatchWorkItem` on the main queue). Nothing releases them for the life of the process.

### retryAttempt and stopped are mutated from both the network delegate queue and the main queue

`Sprout/Camera/CameraPiPRenderer.swift:237`

`retryAttempt` is written from three places on two different threads: `start()` line 165 (main), `streamDidBecomeLive()` line 264 (network delegate queue), and `scheduleReconnect()` line 237 (`retryAttempt += 1`), which is itself reached both from `connect()`'s failure branch on the main queue (line 226) and from `streamDidFail` on the network queue (line 282). `stopped` is written on main (138/164/170) and read on the network queue at line 278 and in `scheduleReconnect`'s guard at 236. None of it is synchronised, and the `@unchecked Sendable` on line 113 asserts it is.

`retryAttempt` is not a diagnostic — it selects the reconnect cadence at lines 242-243, including the deliberate escalation to 20 s that the overview doc says exists to stop the client starving the camera for every other viewer on the network.

**Failure:** A URL-provider failure on main and a stream failure on the network queue both hit `scheduleReconnect()`; the two `retryAttempt += 1` read-modify-writes interleave and the counter stays at or below 5. The 20 s calming cadence at line 243 never engages, and the fast 0.4-5 s retry loop reattaches viewers server-side — the exact pile-up documented in docs/native-rewrite/00-overview.md as having starved the camera for every client on the network.

### JPEGFrameBuilder state is mutated from the FailedToDecode notification thread while the decode queue is reading it

`Sprout/Camera/MJPEGStream.swift:96`

`JPEGFrameBuilder` has no internal synchronisation. Its `strategy`, `formatDescription`, `formatDims`, `pool` and `poolDims` are read and written by `makeSampleBuffer` on `decodeQueue` (CameraPiPRenderer.swift:292). The renderer is careful to hop `subsampleFactor` writes onto that queue (`decodeQueue.async` at lines 347 and 371) — but `layerFailedToDecode` (CameraPiPRenderer.swift:299-309) does not: it reads `builder.strategy` and calls `builder.demoteToImageIO(...)`, which writes `strategy` and `formatDescription = nil` (MJPEGStream.swift:98-99) directly on whatever thread AVFoundation posts `AVSampleBufferDisplayLayerFailedToDecode` on.

**Failure:** The layer rejects a JPEG-passthrough sample buffer (the case the demotion exists for). AVFoundation posts the notification on its own thread while `passthroughBuffer` is between `guard let fd = formatDescription` (line 126) and `CMSampleBufferCreateReady` (143) on the decode queue. The concurrent `formatDescription = nil` releases the CMVideoFormatDescription out from under the in-flight use — an over-release/EXC_BAD_ACCESS, or at best a torn `strategy` where the builder keeps producing passthrough buffers the layer will keep rejecting, leaving the camera tile black.

### The defer in runSocketOnce re-arms REST polling after stop() has already torn it down

`Sprout/Realtime/PrinterStatusStore.swift:106`

`stop()` (80-85) cancels `pollTask` and sets it to nil. But the `defer` block in `runSocketOnce` (106-110) unconditionally calls `restartPolling()` on the way out — it does not check `Task.isCancelled`. `restartPolling` (133) sees `connected == false` and creates a brand-new `Task` that loops on `getStatus` every 3 s and stores it in `pollTask` after `stop()` has already returned. Nothing subsequently cancels it: `stop()` is finished, and a later `start()` would only reach it via `restartPolling` again.

On its own the `[weak self]` capture bounds this to the store's lifetime — but the store outlives `stop()` in exactly the scenario of the `connect()` finding above, where a re-Save orphans a store that is pinned by its own socket task.

**Failure:** The socket drops at the same moment the user signs out or re-saves settings. `runSocketOnce` unwinds, its defer starts a fresh poll task, and `stop()`/`signOut()` have no handle on it. The orphaned store keeps issuing `GET /api/v1/printers/{id}/status` every 3 s against the old base URL and old API key — after the user has explicitly disconnected or changed servers.

### The `retryable` flag on `.error` is discarded, so a non-retryable failure never reaches the failure card

`Sprout/Camera/CameraPiPView.swift:115`

`case .error(let message, _): model.lastError = message` throws away the second associated value. The spec (docs/native-rewrite/11-camera-pip.md §9) states the contract explicitly: "`onLive` → `live`. `onError` with `retryable === false` → `failed`. Retryable errors are ignored by the UI (the renderer reconnects itself)." `CameraPiPModel` has no property carrying retryability at all, so `CameraOverlay` has no way to implement that rule and only ever renders the message in the small `errorLine`. The one error the whole native rewrite was built to distinguish — `.unauthorized` from an expired stream token, which `MJPEGStreamError.isRetryable` reports as `false` (MJPEGStream.swift:263) — is therefore indistinguishable from "still warming up" in the UI, which is precisely the WebView limitation this code exists to remove.

**Failure:** The camera stream token expires or is rejected. The client fails with `.unauthorized`, the renderer emits `.error(message: "camera stream token rejected", retryable: false)` and deliberately does not reconnect (line 281). The overlay keeps showing the "CONNECTING… Waking the chamber camera" card with a spinner for the entire 40 s `warmUpDeadline` before finally declaring failure, instead of showing the actionable Retry card (which mints a fresh token) immediately.

### `JPEGFrameBuilder` is mutated from the notification thread while the decode queue is using it

`Sprout/Camera/CameraPiPRenderer.swift:302`

Every other access to `builder` is deliberately confined to `decodeQueue` — `subsampleFactor` is written via `decodeQueue.async` in both PiP callbacks (lines 347 and 371) precisely to honour the spec's "`subsampleFactor` is only ever mutated on `decodeQueue` — thread confinement, not a lock". `layerFailedToDecode` breaks that invariant: it runs on whatever thread posts `AVSampleBufferDisplayLayerFailedToDecode` (not documented as main), reads `builder.strategy` (line 302) and calls `builder.demoteToImageIO` (line 303), which writes `strategy` and assigns `formatDescription = nil` (MJPEGStream.swift:98-99). Concurrently, `decodeAndEnqueue` on `decodeQueue` is inside `makeSampleBuffer` → `passthroughBuffer`, reading and writing that same `formatDescription`/`formatDims`/`pool` (MJPEGStream.swift:116-126). `JPEGFrameBuilder` is a plain class with no lock, and `formatDescription` is a reference-counted CoreMedia object — releasing it on one thread while another loads and retains it is an unsynchronised ARC race.

**Failure:** On a device where JPEG passthrough is rejected, the first decode failure notification arrives while the decode queue is mid-`passthroughBuffer`. Best case the demotion is lost (the `guard strategy == .passthrough` on the other thread sees a torn value and every subsequent frame keeps going down the passthrough path, so the camera stays black despite the fallback existing). Worst case the `CMVideoFormatDescription` is released on the notification thread between the decode queue's load and retain, producing an over-release crash inside `CMSampleBufferCreateReady`.

### `AVPictureInPictureController.isPictureInPictureActive` is read from the URLSession delegate queue

`Sprout/Camera/CameraPiPRenderer.swift:258`

`streamDidReceiveFrame` (line 258) and `streamDidFail` (line 281) both evaluate `pip?.isPictureInPictureActive == true`. Both are `MJPEGStreamClientDelegate` callbacks, documented in the protocol as "Delivered on the client's delegate queue" (MJPEGStream.swift:231) — that is `bambu.mjpeg.net`, never main. `AVPictureInPictureController` is a main-thread-only AVKit object; the code asserts exactly that for `enablePiP` (line 180, `assert(Thread.isMainThread, "AVPictureInPictureController is main-thread-only")`), then violates it twice per stream. The `pip` property itself is also written on main in `enablePiP` (line 202) and read here off-main with no synchronisation.

**Failure:** With PiP enabled, every 20th frame (~2 s at 10 fps) the network queue reads `pip?.isPictureInPictureActive`. Main Thread Checker traps on the AVKit access in a debug build; in release the read races the main-thread write of `pip` in `enablePiP`, and `streamDidFail`'s "while PiP is up, ALWAYS reconnect" decision can be made from a stale/torn read — so a non-retryable `.unauthorized` either fails to reconnect while the PiP window is genuinely up (frozen window, no way to intervene) or reconnects when it is not.

### The first-frame watchdog fires on the main queue and mutates state owned by the delegate queue

`Sprout/Camera/MJPEGStream.swift:387`

`delegateQueue` is a serial OperationQueue and the comment at line 290 relies on that: "the parser is single-threaded by construction and needs no locking". The watchdog breaks the confinement — `armFirstFrameWatchdog` schedules its `DispatchWorkItem` on `DispatchQueue.main` (line 387), and that block reads `sawFirstFrame` and calls `fail()` → `stop()`, which cancels `task` and nils `firstFrameDeadline` (lines 342-343). Those same fields are written on the delegate queue by `emitFrame` (lines 449-452, `sawFirstFrame = true; firstFrameDeadline?.cancel()`) and by `start()` on main. Nothing serialises the two. `fail()` also calls `delegate?.streamDidFail` from main, while `CameraPiPRenderer` assumes that callback arrives on the network queue and mutates `retryAttempt` from it (line 236) — racing `streamDidBecomeLive`'s `retryAttempt = 0` (line 264) and `start()`'s reset (line 165).

**Failure:** The camera warms up slowly and the first JPEG lands right around the 12 s deadline. The delegate queue runs `emitFrame` → `streamDidBecomeLive` while the main queue is already inside the watchdog block, which read `sawFirstFrame == false` a moment earlier. The healthy task is cancelled by `stop()`, and the renderer receives `streamDidFail(.noFirstFrame)` *after* `streamDidBecomeLive` — so it resets `retryAttempt` to 0 and immediately reconnects, attaching a second viewer to the on-demand camera for a stream that had just started working.

### A pending reconnect timer survives stop()/start() and tears down the healthy connection it finds

`Sprout/Camera/CameraPiPRenderer.swift:244`

`scheduleReconnect` posts `DispatchQueue.main.asyncAfter` with no handle and no cancellation (line 244); the only guard is `connect()`'s `guard !stopped`. `stopped` is `true` only between `stop()` and the next `start()`, and the ceiling makes the pending delay as long as 20 s (line 243). The `epoch` mechanism does not help here: the stale timer calls `connect()`, which bumps `epoch` itself (line 212) before capturing `myEpoch`, so it always passes its own staleness check. `client.start(url:)` then calls `stop()` on the live task (MJPEGStream.swift:329) and opens a new one.

**Failure:** A failing stream reaches `retryAttempt > 5`, so a reconnect is queued 20 s out. The user closes the camera overlay (`dismantleUIView` → `setActive(false)` → `renderer.stop()`, `stopped = true`) and reopens it 5 s later — a new `CameraPiPUIView` is built, but the old renderer's timer is still pending on the main queue only if the old renderer is still alive (it is, until the old view deallocs) and, in the more common in-place case (`setURL` on token rotation calls `restart()` → `start()` on the *same* renderer), `stopped` goes back to `false`. The stale timer then fires, cancels the freshly established live stream and pays the camera warm-up again — the picture drops and re-connects for no reason.

### URLSession delegate retain cycle makes `deinit { session?.invalidateAndCancel() }` unreachable — the client, session and delegate queue leak per camera session

`Sprout/Camera/MJPEGStream.swift:363`

`session = URLSession(configuration: cfg, delegate: self, delegateQueue: delegateQueue)` (line 325). `URLSession` holds a **strong** reference to its delegate until the session is explicitly invalidated. `MJPEGStreamClient` holds `session` strongly (line 272), so client ↔ session is a retain cycle, and the only `invalidateAndCancel()` call site is `deinit` (line 363) — which the cycle guarantees never runs. Nothing else in the app calls `invalidate`/`finishTasksAndInvalidate` on it (grep confirms `invalidateAndCancel` appears exactly once in `native/Sprout`). A fresh `MJPEGStreamClient` is built for every `CameraPiPRenderer`, which is built for every `CameraPiPUIView` in `makeUIView`.

**Failure:** Open the camera overlay and close it N times (or open it, let SwiftUI recreate the representable). Each cycle permanently leaks one `MJPEGStreamClient`, its `URLSession` (with its ephemeral cache/credential storage), and the `bambu.mjpeg.net` OperationQueue. Memory and per-session URLLoading resources grow monotonically for the lifetime of the process; the cleanup the author wrote is dead code.

### The reconnect ceiling is defeated by a camera that delivers one frame and drops

`Sprout/Camera/CameraPiPRenderer.swift:264`

The 20 s calming cadence added after the subscriber pile-up only engages once `retryAttempt > 5` (line 243). But `retryAttempt` is reset to 0 by `streamDidBecomeLive` (line 264), which fires on the **first frame of every connection** (`emitFrame`, MJPEGStream.swift:449-453) — not after any sustained period of streaming. So the counter measures "consecutive attempts that produced zero frames", and any attempt that produces a single JPEG before dying resets it. The comment at line 240 states the intended invariant as "once a run of attempts has failed without a single frame", which is exactly the case this misses.

**Failure:** The on-demand camera is contended (another client attached, or it is mid-restart): each connection hands over one JPEG and then closes. `streamDidBecomeLive` → `retryAttempt = 0`; `streamDidFail(.transport)` → `retryAttempt = 1` → 0.4 s delay → repeat. The client reconnects roughly twice a second indefinitely, attaching a fresh viewer server-side every time — reproducing the exact camera-starvation failure documented in 00-overview.md, with the ceiling in place but never reached.

### The URL provider is a constant closure, so a 401 during PiP retries the same dead token forever

`Sprout/Camera/CameraPiPView.swift:59`

`CameraPiPUIView.restart()` passes `{ done in done(.success(url)) }` — the URL captured at the moment of restart, including its `?token=`. `CameraPiPRenderer.makeStreamURL` exists specifically so the URL can be re-derived per attempt (its own doc comment, line 129-130: "so native can re-mint on 401 without waking the JS thread"), and the spec calls wiring it to the token store the single behaviour the RN build could not do (11-camera-pip.md, port note 2). It is still not wired. Compounding it, `streamDidFail` reconnects unconditionally while PiP is active — `if error.isRetryable || pip?.isPictureInPictureActive == true` (line 281) — so the non-retryable `.unauthorized` case does retry, using the same expired credential each time.

**Failure:** Start PiP and leave it up past the camera token's 60-minute TTL (the app stays alive behind the keep-alive audio session, and SwiftUI will not run `updateUIView`/`setURL` while backgrounded, so the 45-minute refresh never reaches the view). The stream 401s. `enablePiP` keeps the window up, `streamDidFail` schedules a reconnect because PiP is active, `connect()` calls the constant provider, gets the same expired URL, and 401s again — an unbounded loop at the 20 s cadence with a frozen floating window and no in-PiP way to intervene.

### `flushPart()` is never called at completion, so the final part of a connection is silently dropped

`Sprout/Camera/MJPEGStream.swift:440`

`flushPart`'s own doc comment says "Called when the next part starts and at completion" (line 439), but `didCompleteWithError` (line 524-532) never calls it — the only call site is the next part's `didReceive response` (line 412). On the de-multiplexed path (which the spec says is the path that actually runs on device, port note 7), a part is otherwise only emitted early when `partExpected` is known from `expectedContentLength` (line 462); when the server omits `Content-Length`, `expectedContentLength` is -1, `partExpected` stays nil, and the accumulated bytes are only ever flushed by the *next* part's headers. The spec lists this as a one-line fix to make on the way through (port note 9).

**Failure:** The camera answers with a chunked multipart part carrying no `Content-Length`, sends one complete JPEG, then closes the connection (the on-demand camera's self-termination path). The bytes sit in `partBuffer`; `didCompleteWithError` fires and discards them, so `emitFrame` never runs, `sawFirstFrame` stays `false`, and `streamDidBecomeLive` is never delivered. The renderer reports only `.transport(networkConnectionLost)` and the overlay shows "CONNECTING…" for a stream that did in fact deliver a decodable frame.

### The de-multiplexed receive path has no buffer cap, unlike the parser path's 8 MB limit

`Sprout/Camera/MJPEGStream.swift:459`

`MultipartMJPEGParser` enforces `bufferLimit = 8 * 1024 * 1024` on every `consume` and throws `.bufferOverflow` when the stream desynchronises (MJPEGParser.swift:58, 92) — the comment explains it exists so a server that stops emitting boundaries cannot exhaust memory. The de-multiplexed branch of `didReceive data:` (lines 458-468) has no equivalent: it appends unconditionally to `partBuffer` and only truncates when `partExpected` is non-nil and reached. When `expectedContentLength` is -1 the buffer's only bound is the arrival of the next part's headers. Per the spec (port note 7), this is the branch that actually executes on device, so the protection sits on the path that does not run.

**Failure:** A proxy or a camera firmware that switches to a single unbounded `image/jpeg` body after the first part (or simply never emits a second boundary) keeps the connection fed, so the 15 s idle `timeoutIntervalForRequest` never trips. `partBuffer` grows at the stream's ~2 MB/s with no ceiling and no error, ending in a memory-pressure jetsam kill of the app rather than the `.bufferOverflow` failure the parser path would have raised in four seconds.

### Confetti never animates (and is never rendered), so the print-complete celebration is silently absent

`native/Sprout/Views/Components/Anim.swift:317`

`Confetti.onAppear` (lines 317-333) assigns `pieces` and then `fired = true` in the same closure. SwiftUI coalesces both writes into one update, so the 26 `Piece` views are *inserted* with `fired` already true. `.animation(_:value: fired)` (line 311) animates a change on an existing identity; a newly-inserted view has no prior value to animate from, so each piece renders straight at its terminal state — `offset(y: geo.size.height + 40)` and `.opacity(0)`. Nothing is ever visible.

The `Shimmer` view three declarations down gets this right by contrast: `phase` is already `-160` from its `@State` initialiser before `onAppear` animates it to `geo.size.width` (lines 223, 233-238).

Separately, `Confetti` has no call site anywhere in the app — `grep -rn "Confetti(" native/Sprout` returns only the declaration. `DashboardView.completeBlock` (line 667) renders the checkmark circle, the plate-cleared button and "Print again", but no burst. docs/native-rewrite/04-animation.md:316 records the RN contract: "Only call site: `<Confetti count={22} />` in the print-complete state (DashboardView.tsx:418)". This is not listed in the known-gaps table in 00-overview.md.

Fix: seed the animation across two ticks (set `pieces` first, then `fired` in a `Task { @MainActor in }` or inside `withAnimation` on a subsequent runloop turn), and wire it into `completeBlock`.

**Failure:** Wire `Confetti(colors: [...], count: 22)` into `completeBlock` as the spec requires and finish a print: the ZStack lays out 26 rectangles already at `y = height + 40` with opacity 0, so nothing is drawn at any point. Today the defect is latent because the component is dead code — the user simply never sees the celebration the RN build shows.

### Camera tile badge claims "LIVE · 1 fps" over a blank tile after switching printers

`native/Sprout/Views/DashboardView.swift:321`

`camLoaded` is only ever cleared by `.onChange(of: snapshotURL == nil) { _, gone in if gone { camLoaded = false } }` (line 321) — it watches the *nil-ness* of the URL, not the URL itself.

Switching machines from the fleet switcher (`model.printerId = p.id`, line 154) changes `snapshotURL` (line 269 interpolates `model.printerId`) but never makes it nil, since `model.client` and `model.cameraToken` are unchanged. So `camLoaded` stays `true`.

`SnapshotImage` meanwhile does the right thing: its `.task(id: url)` sets `image = nil` and `loadedOnce = false` (SnapshotImage.swift:36-40). The tile therefore goes blank (`c.thumb`) for the several seconds the new printer's on-demand camera takes to wake, while the overlaid badge shows the running-green `PulseDot` and the text "LIVE · 1 fps" (lines 287-297) — exactly the claim the comment on line 319-320 says must not be made over a blank tile.

Fix: key the reset on the URL itself — `.onChange(of: snapshotURL) { camLoaded = false }`.

**Failure:** On a multi-printer fleet, tap the header to open the switcher and pick the other machine. The camera tile clears to the placeholder colour for the ~7 s cold-start, but the badge keeps pulsing green and reading "LIVE · 1 fps" the whole time.

### Pre-sliced files never populate `result`, so the wizard's final summary always shows "Est. time —"

`native/Sprout/Views/Overlays/WizardView.swift:1112`

`runSliceStep()` contains an `if alreadySliced` branch (lines 1112-1124) that builds a `SliceResult` from `file.printTimeSeconds` / `file.filamentUsedGrams` and advances to step 5. That branch is unreachable.

The function guards `step == 4` (line 1110), and for a pre-sliced file `steps` is `[1, 2, 6, 7]` (line 75). `next()` walks that array (`steps[min(idx + 1, steps.count - 1)]`, line 122), so step 2 goes straight to step 6; step 4 and step 5 are never entered. `back()`'s `if step == 5, !alreadySliced` special case (line 128) is likewise dead for this path.

Consequence: `result` stays nil for the entire pre-sliced flow. `estimatedTime` (line 985-990) reads `result?.printTimeSeconds`, gets nil, and returns "—", so the step-7 "READY TO PRINT" summary reports an unknown print time for a file whose `printTimeSeconds` the library record already carries (Models.swift:227) and which the step-1 plate review displayed a moment earlier.

(`start()` is unaffected — its `result?.libraryFileId ?? file.id` correctly falls back to the original id, line 1224.)

Fix: seed `result` from `file` when `alreadySliced`, e.g. in the initialiser or a `.task`, rather than inside the unreachable step-4 branch.

**Failure:** Long-press a `.gcode.3mf` in the Files tab → Print… → Continue → Continue → pick a tray → Continue. The final "READY TO PRINT" card reads `Est. time  —`, even though the Selected File step one screen back showed "PRINT TIME 2h 14m" for the same plate.

### AmsTopology.present converts payload Doubles to Int with no finite/range guard — traps

`native/Sprout/Domain/AmsUnits.swift:196`

Two conversions in `AmsTopology.present` go straight from a `LooseNumber` payload value to `Int`:

- line 196: `dryingMinLeft: max(0, Int((unit.dryTime?.double ?? 0).rounded()))`
- line 208: `pct: empty ? "—" : "\(Int((tray.remain?.double ?? 0).rounded()))%"`

`Int(Double)` is a runtime trap (fatalError), not a silent 0, for NaN, ±infinity, and any finite value outside Int's range. `LooseNumber` does not filter non-finite values — its decoder does `Double(s)` for the stringified form, and I verified that `Double("nan")` → NaN, `Double("inf")`/`Double("Infinity")` → infinity, `Double("1e30")` → 1e30. Bambuddy's WebSocket serializer stringifies numerics (08-domain.md §0 names `dry_time` specifically as one of the fields that arrives as a string over WS), so this is the exact path that carries a bad value in.

Every sibling Domain module already treats this as a real hazard and guards it with a documented helper: `Dryer.safeRound` (Dryer.swift:232, comment: "Int(Double) is a runtime error for non-finite values and for anything outside Int's range"), `Cooling.rounded` (Cooling.swift:140, "a garbage sensor reading is not worth a crash"), `PlateReview.whole` (PlateReview.swift:142, "The range check is load-bearing"), `SliceOverrides.clampedInt` (SliceOverrides.swift:159). `PowerTests.swift:206` states outright: "`Double(\"nan\")` parses, so a stringified numeric can carry NaN this far." AmsUnits.swift is the one module that skipped the guard, and it reads the same `dry_time` field `Dryer.present` guards.

Both lines are on the primary render path (`Dash.present` → `AmsTopology.present`, Dashboard.swift:186), so the failure is a hard crash of the dashboard, not a cosmetic glitch.

**Failure:** A WebSocket status frame carries `ams[0].dry_time: "nan"` (Bambuddy stringifying a Python `float('nan')`) or `ams[0].tray[0].remain: "1e30"`. Decoding succeeds — `LooseNumber.double` returns NaN / 1e30. The next dashboard render calls `Dash.present` → `AmsTopology.present`, which evaluates `Int(Double.nan.rounded())` at line 196 (or `Int((1e30).rounded())` at line 208) and traps: the app crashes on launch-to-dashboard and re-crashes on every reconnect, with no way for the user past it. `AmsTopologyTests.swift` only ever supplies finite `remain`/`dryTime` values (its `tray()` helper defaults `remain: 80`), so the 488-test suite stays green.

### A WebSocket frame that fails to decode is dropped silently AND the REST fallback stays disabled, freezing the dashboard

`native/Sprout/Realtime/PrinterStatusStore.swift:135`

`WsFrame.parse` swallows every decoding error (`guard let env = try? BambuddyClient.decoder.decode(Envelope.self, from: data)`, PrinterStatusStore.swift:18) and `restartPolling()` refuses to poll whenever the socket is open (`guard !connected else { pollTask = nil; return }`, line 135). So a payload the decoder rejects produces no log, no error state, no status update, and no REST recovery — the last good status stays on screen indefinitely.

That matters because `PrinterStatus` is not uniformly lenient. `docs/native-rewrite/01-api.md` warns for `nozzle_rack`: "Numeric fields may arrive as strings over the WS", and port note 5 spells out the consequence: "Swift's Codable will hard-fail the whole payload on a type mismatch — one bad field loses the entire status frame." Every sibling numeric got `LooseNumber` (`NozzleRackSlot.wear`, `.maxTemp`, `.nozzleDiameter`), but `NozzleRackSlot.id` is a strict `let id: Int` (Models.swift:131), as are `AmsUnitRaw.id` (line 90), `AmsTray.id` (line 79) and `FilaSwitch.inSlots`/`outExtruders` (`[Int]?`, lines 118-119).

Separately, `PrinterStatus.connected: Bool = false` and `state: String = ""` (Models.swift:145-147) look like safe defaults but are not: Swift's synthesized `Decodable` ignores property default values, so a payload missing either key throws `keyNotFound` and takes the whole frame with it (verified with a standalone Swift snippet).

**Failure:** The H2C's firmware stringifies `nozzle_rack[].id` (or the server omits `state`) on the WebSocket feed. `Envelope` decoding throws, `try?` yields nil, the frame is discarded. Because `connected` is still true, `restartPolling()` keeps `pollTask` nil, so no REST poll ever runs. The dashboard keeps rendering whichever status was current when the socket came up — progress, temperatures and layer count frozen — until the socket happens to drop 12+ seconds later, with nothing in the UI or logs indicating why.

### The socket connecting cancels the in-flight first REST status fetch, so the first paint waits for a WebSocket push

`native/Sprout/Realtime/PrinterStatusStore.swift:104`

`start()` kicks off `socketTask` and then `restartPolling()`, whose doc comment states its purpose: "plus one immediate fetch so the first paint doesn't wait for a socket frame" (line 131-132). But `runSocketOnce()` sets `connected = true` and calls `restartPolling()` the instant `socket.resume()` returns (lines 103-104), and `restartPolling()` begins with `pollTask?.cancel()` (line 134) then bails out because `connected` is now true (line 135).

`URLSession.data(for:)` is cancellation-aware, so the in-flight `client.getStatus(id)` inside `pollTask` is aborted mid-request and its `try?` yields nil — the fetch that exists specifically to seed the first paint is thrown away. The two tasks race (`mintWsToken` POST vs `getStatus` GET, comparable latency), so this happens roughly whenever the token mint returns first. Note `connected = true` is set on `resume()`, before the WebSocket handshake is known to have succeeded, so this fires even for a socket that is about to fail.

**Failure:** Cold launch on a healthy server. `mintWsToken` returns in 40 ms, `getStatus` is still in flight at 45 ms. `connected = true` → `restartPolling()` cancels the status request and starts no replacement. The dashboard sits on the `connecting` DashKind until Bambuddy pushes its first `printer_status` frame, defeating acceptance criterion 6 ("Dashboard shows the printer's real state within 3 s of launch (REST fallback), without waiting for a socket frame").

### Slice failures read `error_message`, but the server field is `error`, so the reason is always swallowed

`native/Sprout/Api/Models.swift:581`

`SliceJob.errorMessage` (Models.swift:581) binds, via `convertFromSnakeCase`, to a JSON key `error_message`. Both the RN source and the spec read a different field: `mobile/src/components/Overlays.tsx:1044` is `throw new Error(j.error || 'Slice failed')`, `docs/native-rewrite/01-api.md:348` says "`'failed'` or `'error'` → `throw new Error(j.error || 'Slice failed')`", and `docs/native-rewrite/09-library-logic.md:533` repeats "`'failed'|'error'` → throw `j.error`".

The Swift call site is `throw SproutError(job.errorMessage ?? "Slice failed")` (WizardView.swift:1187), which then becomes the body of the "Slicing failed" alert. Since `error_message` never appears on the response, `errorMessage` is permanently nil and the server's diagnosis is discarded.

**Failure:** A slice fails because the chosen filament preset is incompatible with the mounted nozzle. Bambuddy returns `{"status":"failed","error":"filament PETG-CF requires a hardened nozzle"}`. The wizard decodes `errorMessage` as nil and shows the alert "Slicing failed — Slice failed", dropping the sentence that would tell the user what to change.

## Low (13)

### `signOut()` cancels the sync loop without ending live cards, stranding them on the lock screen

`Sprout/App/AppModel.swift:120`

`signOut()` stops the status store and cooldown, cancels `derivedTask`, and clears `client`/`config`, but never calls `liveActivity?.end(printerId:amsId:)` for the cards it started, and leaves the `liveActivity` property itself set. With `derivedTask` cancelled nothing will ever reconcile those activities again, and with `config` cleared the app cannot rebuild the controller state to end them on the next launch either — `sync` requires a status, which requires a client. In LOCAL mode (the only mode that currently creates cards at all) the cards therefore outlive the session.

**Failure:** A print is running with a card on the lock screen. The user signs out to re-enter a corrected base URL. The card stays on the lock screen frozen at whatever progress it last showed, with a countdown ticking toward a stale ETA, until ActivityKit expires it hours later.

### A card the user dismisses is silently recreated on the next meaningful change

`Sprout/Realtime/LiveActivityController.swift:220`

Dedup is derived entirely from `Activity<PrintActivityAttributes>.activities`. A user-dismissed activity leaves that collection, so `updated` stays false and `upsert` falls through to `Activity.request` (line 237), starting a fresh card. The RN implementation held the instance in an `instances` map keyed by printer id and gated the start on `isLive(vm) && !inst` (07-realtime.md §3.8), so a dismissed card stayed dismissed for the rest of the print. Nothing here records the dismissal — `activityStateUpdates` is not observed anywhere in `native/`.

**Failure:** Mid-print the user swipes the Live Activity away because they do not want it on the lock screen. Within a few seconds the nozzle temperature moves 2°C, `meaningfulChange` returns true, and a brand-new card appears. The user cannot dismiss the card at all short of turning Live Activities off for the app.

### `meaningfulChange` omits `totalLayers`, so the layer row stays hidden after the layer count arrives

`Sprout/Realtime/LiveActivityController.swift:148`

The comparison covers `layer` but not `totalLayers` (nor `finished`, `tint`, `symbol`, `hasNozzle2`, though those track `stateLabel` in practice). The widget gates the layer readout on `state.totalLayers > 0` (PrintActivityWidget.swift:122), so a state that goes from `layer 0 / total 0` to `layer 0 / total 210` is a user-visible change that the gate classifies as no change and never pushes. Bambuddy commonly reports the total before the first layer completes.

**Failure:** A print starts and the card is created while `total_layers` is still 0. The next frame carries `total_layers = 210` with `layer_num` still 0 and identical temperatures; `meaningfulChange` returns false, no update is pushed, and the lock-screen card shows no layer row until the first layer finishes — several minutes on a large first layer.

### PiPBackgroundKeepAlive's interruption handler touches AVAudioEngine concurrently with deactivate()

`Sprout/Camera/CameraPiPRenderer.swift:67`

`handleInterruption` (67-78) is an NSNotification selector for `AVAudioSession.interruptionNotification`, which AVFoundation delivers on an unspecified thread, not guaranteed the main thread. It reads `started` and calls `AVAudioSession.setActive(true)`, `engine.start()` and `player.play()`. `activate()` (26) and `deactivate()` (56) run on the main thread (from `enablePiP`, which asserts main, and from the PiP delegate callbacks at 365/372) and mutate the same `started` flag plus `player.stop()` / `engine.stop()`. AVAudioEngine is not thread-safe, and `started` is an unsynchronised `Bool` read-modify-written from both.

**Failure:** A phone call ends just as the user closes PiP. `deactivate()` on main sets `started = false` and stops the engine while the interruption thread has already passed its `guard type == .ended, started` check and calls `engine.start()` / `setActive(true)`. The audio session is left active with no PiP window — the app holds the silent keep-alive session (and its background-execution assertion) indefinitely, or the racing engine calls trap inside AVAudioEngine.

### `enablePiP()`'s idempotent fast path lets `keepAlive.activate()` throw, so a second PiP tap can silently do nothing

`Sprout/Camera/CameraPiPRenderer.swift:182`

The slow path wraps `keepAlive.activate()` in do/catch and treats an audio-session failure as non-fatal, emitting `.audio(ok: false, …)` and continuing to build the controller (lines 186-194). The `pip != nil` fast path (lines 182-184) uses a bare `try` that propagates out of `enablePiP()`. `CameraPiPModel.startPiP()` calls `try view.renderer.enablePiP()` followed by `view.renderer.startPiP()` (CameraPiPView.swift:91-92), so a throw skips `startPiP()` entirely. The spec flags this exact asymmetry twice and says the native version should catch in both branches (11-camera-pip.md, "Asymmetry worth noting" and port note 9).

**Failure:** The user starts PiP, returns inline (`didStopPictureInPicture` → `keepAlive.deactivate()`, so `started` is false again, while `pip` stays non-nil), then taps PiP again during a phone call or another exclusive-audio interruption. `AVAudioSession.setActive(true)` throws, `enablePiP` rethrows from the fast path, `startPictureInPicture()` is never called, and `model.lastError` is set to an audio-session message. The PiP button appears dead with no window and a confusing error.

### `AVSampleBufferDisplayLayer` flush/enqueue calls are not serialised across three threads

`Sprout/Camera/CameraPiPRenderer.swift:173`

The layer is driven from three different execution contexts with no serialisation: `decodeAndEnqueue` calls `requiresFlushToResumeDecoding`, `flush()` and `enqueue()` on `decodeQueue` (lines 290-294); `layerFailedToDecode` and `layerRequiresFlushChanged` call `flush()` on the notification-posting thread (lines 304, 308, 316); and `stop()` calls `flushAndRemoveImage()` on the main queue (line 173). `gate.reset()` immediately before it (line 172) only clears the pending slot — a frame already dispatched to the gate's handler is mid-flight on `decodeQueue` and will call `enqueue` after the main-thread flush has run.

**Failure:** Close the camera overlay while a frame is being decoded. `stop()` runs `flushAndRemoveImage()` on main, then the in-flight `decodeAndEnqueue` completes on `decodeQueue` and enqueues its sample buffer into the just-flushed layer — so the layer is left holding a frame the teardown intended to remove, and the concurrent flush/enqueue pair is an unsynchronised use of an API that requires serialised access.

### A second toast inherits the first toast's dismissal timer and can vanish almost immediately

`native/Sprout/App/Shell.swift:109`

`ToastBanner` self-dismisses from `.task { try? await Task.sleep(for: .seconds(5)); onDismiss() }` (lines 109-112). The task has no `id:`, and the banner has no `.id(text)`, so it runs once per *appearance* of the view at that structural position.

Because the overlay is `if let toast = model.toast { ToastBanner(text: toast) ... }` (Shell.swift:30-32), replacing `model.toast` with a different string keeps the same view identity — only `text` changes. The `.task` does not restart, so the new message runs out the *old* banner's remaining budget.

This is reachable through the normal failure paths: `DashboardView.setSpeed` ("Speed failed — …"), `PowerView.apply` / `PlugRow.apply` ("Plug command failed — …") and `AppModel.perform` all write `model.toast` directly, and a user retrying a failing control produces back-to-back toasts.

Separately, the `.transition(.move(edge: .bottom).combined(with: .opacity))` on line 107 never plays: nothing wraps the `model.toast` write in `withAnimation` and the overlay carries no `.animation(...)`, so the banner cuts in and out.

Fix: `.id(toast)` on the banner, or `.task(id: text)`.

**Failure:** Tap a plug toggle that the server rejects, then tap it again 4.5 s later. The second "Plug command failed — …" toast appears and is dismissed ~0.5 s later by the first banner's timer, before it can be read.

### Library list rows are identified by array index, so the list churns on any content change

`native/Sprout/Views/LibraryView.swift:583`

The list layout uses `ForEach(rows.indices, id: \.self) { index in let f = rows[index] ... }` (line 583), where `rows = shown` is the filtered/searched result. Identity is positional, so a row's identity survives while its *contents* change.

The grid layout directly above uses the correct form — `ForEach(shown) { f in ... }` (line 503) keyed on `LibraryFile.id` — so the two layouts of the same data behave differently.

Concretely, everything below a mutation point is treated as "the same row with different data" rather than "rows moved": after `deleteLibrary`/`bulkDelete` calls `load()` (lines 941, 967), or on each keystroke in the search field (`query` feeds `LibraryBrowse.filter`, line 157), every row from the change point down gets a new `LibraryFile` in an existing view. The `AsyncImage` in `libraryThumb` (line 653) restarts at its `.empty` phase for each of those rows, which `libraryThumb` renders as `Color.clear`, so the thumbnail column blanks and refetches wholesale instead of the deleted row simply being removed.

Fix: `ForEach(rows) { f in ... }` and derive the separator from `f.id != rows.last?.id`.

**Failure:** Switch the Files tab to list layout with ~20 files, then delete the third file via its context menu. Instead of one row disappearing, every thumbnail below it blanks to the placeholder and re-downloads; typing in the search box produces the same full-column thumbnail flash on each keystroke.

### Dash.round and Dash.fmtDuration check isFinite but not Int's range before Int(_:)

`native/Sprout/Domain/Dashboard.swift:110`

`Dash.round` (lines 108–111) guards `n.isFinite` and then does `Int(n.rounded())`; `Dash.fmtDuration` (lines 83–88) guards `minutes.isFinite, minutes > 0` and then does `Int(minutes / 60)`. `isFinite` rules out NaN and infinity but not magnitude: `Int(Double)` also traps for any finite value beyond ~9.22e18. `Cooling.rounded` (Cooling.swift:140–145) and `Dryer.safeRound` (Dryer.swift:232–237) both add the magnitude clamp on top of the finite check for precisely this reason.

The inputs are unvalidated network values: `Dash.present` feeds `status.progress` into `round` (line 194) and `status.remainingTime` into `fmtDuration` (line 197), both `LooseNumber`, which parses `"1e30"` from a stringified WebSocket field without complaint.

This is also a deviation from the spec. 02-dashboard-model.md §2 defines the reference implementation as `const round = (n) => Math.round(Number(n ?? 0)) || 0` — a value the RN app renders as a large number, the port crashes on. `AlertsTests.swift:258` already exercises `LooseNumber(1e30)` against `Alerts.present`, so the project treats magnitudes of this size as in-scope input; `DashboardTests.swift` has no equivalent case.

**Failure:** `status.progress` arrives as the string `"1e30"` (or `remaining_time` does). `LooseNumber.double` yields 1e30, `isFinite` passes, and `Int((1e30).rounded())` at Dashboard.swift:110 — or `Int(1e30 / 60)` at line 85 — traps, killing the app on the dashboard. The same value in the RN app renders as text.

### LooseNumber.int guards isFinite but not range, trapping for the Domain callers that use it

`native/Sprout/Api/Models.swift:36`

`var int: Int? { value.flatMap { $0.isFinite ? Int($0) : nil } }` — the `isFinite` check handles NaN/infinity but `Int(_:)` still traps for finite values outside Int's range (e.g. 1e30, which `Double("1e30")` produces from a stringified WebSocket field). `Int(exactly:)` would return nil and cost nothing; `Alerts.severityRung` (Alerts.swift:163–166) already uses `Int(exactly:)` and its comment explains exactly this — "the printer can hand us a value no `Int` can hold, and the plain conversion TRAPS on that" — but the shared accessor that most of the Domain layer reads through was not given the same treatment.

Domain call sites that would take the trap: `Dash.present` at Dashboard.swift:161 (`status.activeExtruder?.int`), 187 (`speedLevel`), 195–196 (`layerNum`, `totalLayers`), `AmsTopology.present` at AmsUnits.swift:172 (`trayNow`), and `Dryer.present` at Dryer.swift:159 (`code.int` over `drySfReason`).

I am flagging this at low severity because it needs an absurd magnitude to fire, but it is the shared coercion the whole Domain layer leans on and the fix is one token.

**Failure:** A status frame carries `layer_num: "1e30"` or `speed_level: "1e30"` (a stringified numeric, which is how the WS feed sends numbers). `LooseNumber.double` is 1e30 and finite, so `.int` evaluates `Int(1e30)` and traps — the app crashes rather than the field degrading to nil the way every other `LooseNumber` read path does.

### Multipart upload interpolates the filename into the Content-Disposition header with no quoting or escaping

`native/Sprout/Api/BambuddyClient.swift:630`

`uploadFile` builds the part header by raw string interpolation:

```swift
head += "Content-Disposition: form-data; name=\"file\"; filename=\"\(name)\"\r\n"
```

`name` comes straight from the document picker — `staged.lastPathComponent` at `Sprout/Views/Overlays/UploadSheet.swift:292`, i.e. the user's own filename. `"`, CR and LF are all legal in APFS filenames and none of them are escaped, so the filename can terminate the quoted-string early or inject additional MIME headers into the part. The RN version never had this exposure: it delegated header construction to `expo-file-system`'s native `File.upload` (`docs/native-rewrite/01-api.md:440`).

**Failure:** Upload a file named `Bracket "V2".3mf`. The emitted header is `Content-Disposition: form-data; name="file"; filename="Bracket "V2".3mf"`. FastAPI's multipart parser ends the quoted string at the second quote, so the library entry is stored as `Bracket ` (or the request is rejected as malformed), and the file the user just uploaded is unfindable under the name they gave it.

### `URL(string: baseUrl + path)!` force-unwraps unvalidated user config, crashing the app on a malformed base URL

`native/Sprout/Api/BambuddyClient.swift:145`

Every request builder force-unwraps: `request(_:)` at line 145, `adminLogin` at line 193, `adminSend`'s `attempt` at line 240, and `uploadFile` at line 642.

Nothing validates the base URL into a parseable form first. `ConfigRules.sanitizeBaseUrl` (`Sprout/Config/ConfigRules.swift:6-11`) only trims whitespace and trailing slashes, and the Connect button's gate is `!ConfigRules.sanitizeBaseUrl(baseUrl).isEmpty && ConfigRules.isValidApiKey(apiKey)` (`Sprout/Views/SettingsView.swift:27`) — no scheme or host check. The first thing Connect does is `probe.probe()` (SettingsView:272), which goes straight through `request(_:)`.

iOS 17+ `URL(string:)` percent-encodes many invalid characters rather than failing, but I confirmed it still returns nil for a stray `]`, `<`/`>`, or a bare `%` in the authority (tested against this toolchain's Foundation: `"https://<your-server>:8910]/x"` → nil, `"https://hos<t>.local/x"` → nil).

**Failure:** The user pastes a base URL with a trailing bracket from a copied config snippet — `https://bambuddy.example.com:8910]`. `sanitizeBaseUrl` leaves it untouched (no whitespace, no trailing slash), `canConnect` is satisfied, and tapping Connect calls `probe()` → `URL(string: "https://bambuddy.example.com:8910]/api/v1/printers/")` → nil → force-unwrap trap. The app terminates instead of showing the tuned "Can't reach that URL" message that `classifyConnectError` exists to produce.

### `LooseNumber.int` converts Double→Int guarded only by isFinite, so an out-of-range value traps

`native/Sprout/Api/Models.swift:36`

```swift
var int: Int? { value.flatMap { $0.isFinite ? Int($0) : nil } }
```

`isFinite` rejects NaN and ±infinity but not magnitude: `Int(1e30)` is a runtime trap ("Double value cannot be converted to Int because it is outside the representable range"), and `1e30.isFinite` is true — I verified both. `LooseNumber` exists specifically so "the rest of the app only ever sees `Double?` and can't crash on a string" (Models.swift:6-7), so this is a hole in that guarantee.

The accessor is read on decoded network data throughout: `Sprout/Domain/Dashboard.swift:186,195,196`, `Sprout/Domain/AmsUnits.swift:169`, `Sprout/Realtime/LiveActivityController.swift:84-85`, `Sprout/Views/Overlays/WizardView.swift:62,1095`. The same unguarded pattern appears at `Sprout/Views/LibraryView.swift:1357` (`Int64(listedSize)` after only an `isFinite` check).

**Failure:** A firmware or Bambuddy bug reports `total_layers` (or `layer_num`) as `1e30` — plausible from an uninitialised field or a unit-conversion overflow, and exactly the class of malformed numeric this type was written to absorb. `Dash.present` calls `status.totalLayers?.int` at Dashboard.swift:196 and the app traps on the main actor, crashing on every subsequent status frame rather than rendering a wrong number.

