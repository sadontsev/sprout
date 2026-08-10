import Foundation
import AVFoundation
import AVKit
import CoreMedia
import CoreVideo
import ImageIO
import UIKit
import os

// MARK: - 6. Background keep-alive
// ============================================================================

/// PiP by itself does NOT keep an app out of suspension — an ACTIVE audio session does.
/// (Apple DTS, forums thread 793010: "your app will suspend, because it doesn't have an active
/// audio session keeping it awake.") The camera feed has no audio, so we render silence at a
/// trivial cost while PiP is up, with `.mixWithOthers` so the user's music is untouched.
///
/// Info.plist must carry UIBackgroundModes = ["audio"] ("Audio, AirPlay, and Picture in
/// Picture") or PiP will not even start.
///
/// `@unchecked Sendable`: `started`, the engine and the player are main-queue state. `activate()` and
/// `deactivate()` are only ever called from `enablePiP` and the PiP delegate callbacks, all of which
/// are main-thread-only by AVKit contract, and the interruption notification hops onto main below.
final class PiPBackgroundKeepAlive: @unchecked Sendable {

    private let engine = AVAudioEngine()
    private let player = AVAudioPlayerNode()
    private var started = false

    func activate() throws {
        guard !started else { return }
        let s = AVAudioSession.sharedInstance()
        try s.setCategory(.playback, mode: .moviePlayback, options: [.mixWithOthers])
        try s.setActive(true, options: [])

        let fmt = AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 1)!
        guard let silence = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: 44_100) else { return }
        silence.frameLength = silence.frameCapacity
        // NOT pure zeros: a completely silent graph can be optimised away, and an app that is not
        // genuinely rendering audio gets suspended despite the background mode — which freezes the
        // PiP window on its last frame. This is ~-90 dBFS: inaudible, but real output.
        if let ch = silence.floatChannelData?[0] {
            for i in 0..<Int(silence.frameLength) {
                ch[i] = (i % 2 == 0 ? 1.0 : -1.0) * 0.00003
            }
        }
        engine.attach(player)
        engine.connect(player, to: engine.mainMixerNode, format: fmt)
        engine.mainMixerNode.outputVolume = 0.01
        try engine.start()
        player.scheduleBuffer(silence, at: nil, options: [.loops])
        player.play()
        started = true

        NotificationCenter.default.addObserver(
            self, selector: #selector(handleInterruption(_:)),
            name: AVAudioSession.interruptionNotification, object: s)
    }

    func deactivate() {
        guard started else { return }
        started = false
        NotificationCenter.default.removeObserver(self, name: AVAudioSession.interruptionNotification, object: nil)
        player.stop()
        engine.stop()
        try? AVAudioSession.sharedInstance().setActive(false, options: [.notifyOthersOnDeactivation])
    }

    /// A phone call deactivates our session. If we do not reactivate, the app loses its
    /// keep-alive and gets suspended — and the camera dies ~7 s later.
    @objc private func handleInterruption(_ n: Notification) {
        guard let raw = n.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
              let type = AVAudioSession.InterruptionType(rawValue: raw) else { return }
        guard type == .ended else { return }
        // AVFoundation posts this on an unspecified thread. AVAudioEngine is not thread-safe and
        // `started` is a plain Bool, so re-arming here directly could restart the engine while
        // `deactivate()` was stopping it on main — leaving an active audio session (and its
        // background-execution assertion) behind with no PiP window.
        DispatchQueue.main.async { [weak self] in self?.resumeAfterInterruption() }
    }

    /// Main queue only.
    private func resumeAfterInterruption() {
        guard started else { return }
        do {
            try AVAudioSession.sharedInstance().setActive(true, options: [])
            if !engine.isRunning { try engine.start() }
            player.play()
        } catch {
            pipLog.error("could not resume keep-alive audio session: \(error.localizedDescription, privacy: .public)")
        }
    }
}

// ============================================================================
// MARK: - 7. The renderer: layer + PiP controller + reconnect policy
// ============================================================================

/// Why a stream URL could not be produced. Concrete and `Sendable` — a bare `any Error` cannot cross
/// the queue hop from the provider to the main queue under strict concurrency.
struct StreamURLError: Error, Sendable {
    let message: String
}

/// Supplies the stream URL on demand. Asynchronous because the camera token is minted per session
/// and refreshes on a timer, so the URL cannot simply be captured once at start.
typealias StreamURLProvider = @Sendable (@escaping @Sendable (Result<URL, StreamURLError>) -> Void) -> Void

/// What the renderer reports upward. A typed enum rather than the old `(String, [String: Any])`
/// pair: the payloads cross from the network queue to the main queue, and a dictionary of `Any` is
/// not `Sendable`, so the compiler could not check that hop.
enum CameraEvent: Sendable {
    case live
    /// A new connection attempt has begun, or the stream was torn down — nothing on screen is a live
    /// feed any more. Without this the UI's "live" flag was a write-once latch: after a reconnect or
    /// the 45-minute camera-token rotation the next `.live` was no longer a *change*, so a view
    /// driving its state machine off that change waited for an edge that could never come again and
    /// decayed to "NO SIGNAL" over moving video.
    case connecting
    case error(message: String, retryable: Bool)
    case pipStart
    case pipStop(error: String?)
    /// Emitted every 20 frames. Distinguishes "the stream stalled" from "frames arrive but nothing
    /// renders" — the exact ambiguity behind the earlier static-PiP-frame bug.
    case stats(frames: Int, pipActive: Bool)
    /// Result of arming the near-silent audio session that keeps the app alive behind PiP.
    case audio(ok: Bool, message: String?)
}

/// The reconnect cadence, as pure arithmetic so the ceiling is covered by a test rather than by a
/// comment. It is not a tuning knob: a tight retry loop once piled up six subscribers on the
/// on-demand camera and starved it for every other client on the network, so the calm cadence after
/// a run of frameless attempts is the thing that stops a client-side fault taking the camera down
/// for everything else.
enum CameraReconnectPolicy {
    /// Attempts up to and including this one use the fast exponential cadence.
    static let fastAttempts = 5
    static let firstDelay: TimeInterval = 0.4
    static let growth = 1.6
    static let fastCeiling: TimeInterval = 5.0
    static let calmDelay: TimeInterval = 20.0

    /// `attempt` is 1-based: 1 is the first reconnect after a failure.
    static func delay(forAttempt attempt: Int) -> TimeInterval {
        let n = max(1, attempt)
        // Fast at first, because the camera self-terminates ~7 s after its last viewer and a slow
        // retry guarantees paying the cold warm-up again.
        guard n <= fastAttempts else { return calmDelay }
        return min(firstDelay * pow(growth, Double(n - 1)), fastCeiling)
    }
}

// `@unchecked Sendable`, on one rule: THE RENDERER'S CONTROL STATE IS MAIN-QUEUE ONLY.
//
//  * `stopped`, `retryAttempt`, `epoch`, `frameCount`, `pendingReconnect`, `pip` and `makeStreamURL`
//    are read and written on the main queue and nowhere else. Every `MJPEGStreamClientDelegate`
//    callback arrives on the stream client's own queue and hops here before touching any of them —
//    they used to mutate `retryAttempt` and read the main-thread-only `AVPictureInPictureController`
//    in place.
//  * `builder` and every `displayLayer` sample-buffer call belong to `decodeQueue`. The two
//    AVSampleBufferDisplayLayer notifications arrive on an unspecified thread and hop there.
//  * `gate` is the one deliberately shared object, and it is internally locked.
final class CameraPiPRenderer: NSObject, @unchecked Sendable, MJPEGStreamClientDelegate,
                               AVPictureInPictureControllerDelegate,
                               AVPictureInPictureSampleBufferPlaybackDelegate {

    let displayLayer = AVSampleBufferDisplayLayer()
    private let rateWindowStart = Date()

    private let client = MJPEGStreamClient()
    private let builder = JPEGFrameBuilder()
    private let keepAlive = PiPBackgroundKeepAlive()
    private var pip: AVPictureInPictureController?
    private var gate: LatestFrameGate!

    private let decodeQueue = DispatchQueue(label: "bambu.mjpeg.decode", qos: .userInitiated)

    /// Re-supplied by JS at start so native can re-mint on 401 without waking the JS thread —
    /// which is throttled or stopped once the app is backgrounded.
    private var makeStreamURL: StreamURLProvider = { $0(.failure(StreamURLError(message: "no stream URL provider set"))) }

    /// Diagnostic: total frames handed to the display layer. A PiP window frozen on one frame is
    /// ambiguous — either frames stopped arriving (app suspended) or they arrive and are not
    /// rendered. This counter tells the two apart without a device log.
    private var frameCount = 0
    private var epoch: Int64 = 0
    private var retryAttempt = 0
    private var stopped = true
    private var probeDeadline: Date?
    /// Held so a queued reconnect can be cancelled. `epoch` cannot stand in for this: the stale timer
    /// calls `connect()`, which bumps `epoch` itself before capturing it, so it always passes its own
    /// staleness check.
    private var pendingReconnect: DispatchWorkItem?

    /// Outbound events to JS. The renderer otherwise only logs, and a PiP that silently fails to
    /// start is indistinguishable from one the user simply hasn't noticed — so every terminal state
    /// is reported, not just the happy path.
    var onEvent: (@Sendable (CameraEvent) -> Void)?

    override init() {
        super.init()
        displayLayer.videoGravity = .resizeAspect
        // No controlTimebase: every frame carries DisplayImmediately instead.
        gate = LatestFrameGate(queue: decodeQueue) { [weak self] jpeg in self?.decodeAndEnqueue(jpeg) }
        client.setDelegate(self)

        NotificationCenter.default.addObserver(
            self, selector: #selector(layerFailedToDecode(_:)),
            name: .AVSampleBufferDisplayLayerFailedToDecode, object: displayLayer)
        NotificationCenter.default.addObserver(
            self, selector: #selector(layerRequiresFlushChanged(_:)),
            name: .AVSampleBufferDisplayLayerRequiresFlushToResumeDecodingDidChange, object: displayLayer)
    }

    // ---- public API (main queue only) ----

    func start(urlProvider: @escaping StreamURLProvider) {
        makeStreamURL = urlProvider
        stopped = false
        retryAttempt = 0
        connect()
    }

    func stop() { teardown(clearImage: true) }

    /// `clearImage: false` is for a PiP *pause*: the floating window is expected to hold its last
    /// frame there, and `flushAndRemoveImage` would leave it black.
    private func teardown(clearImage: Bool) {
        stopped = true
        cancelPendingReconnect()
        client.stop()
        gate.reset()
        // `emit`, not `deliver`: `stop()` also runs from the hosting view's deinit, and the event sink
        // asserts main-actor isolation.
        emit(.connecting)
        if clearImage {
            // On the decode queue, not main: `flushAndRemoveImage` and `enqueue` are the same
            // serialised API, and flushing from main while a frame was mid-decode left the layer
            // holding the very frame the teardown existed to remove.
            decodeQueue.async { [weak self] in self?.displayLayer.flushAndRemoveImage() }
        }
    }

    deinit {
        // The client's URLSession holds the client as its delegate, so nothing else can ever release
        // it, its ephemeral session or its queue — one leaked set per camera session otherwise.
        client.invalidate()
    }

    /// MUST be called while the app is in the foreground: PiP cannot be started from the
    /// background (Apple DTS, forums thread 793010).
    func enablePiP() throws {
        guard AVPictureInPictureController.isPictureInPictureSupported() else { return }
        assert(Thread.isMainThread, "AVPictureInPictureController is main-thread-only")
        // Idempotent: repeated taps must not build a second controller over the same layer.
        if pip != nil {
            try keepAlive.activate()
            return
        }
        do {
            try keepAlive.activate()                // audio session first, or PiP silently no-ops
            emit(.audio(ok: true, message: nil))
        } catch {
            // Not fatal for STARTING PiP, but without it the app suspends when backgrounded and the
            // window freezes on its last frame.
            pipLog.error("keep-alive audio session failed: \(error.localizedDescription, privacy: .public)")
            emit(.audio(ok: false, message: error.localizedDescription))
        }
        let source = AVPictureInPictureController.ContentSource(
            sampleBufferDisplayLayer: displayLayer, playbackDelegate: self)
        let c = AVPictureInPictureController(contentSource: source)
        c.delegate = self
        // Auto-enter PiP when the user swipes home while the camera is on screen — the whole
        // point of this feature.
        c.canStartPictureInPictureAutomaticallyFromInline = true
        pip = c
    }

    func startPiP() { pip?.startPictureInPicture() }
    func stopPiP()  { pip?.stopPictureInPicture() }

    // ---- connection lifecycle ----

    private func connect() {
        guard !stopped else { return }
        cancelPendingReconnect()
        epoch &+= 1
        let myEpoch = epoch
        // A new attempt means nothing on screen is a live feed any more. Emitted on every attempt so
        // the UI's live flag describes the CURRENT connection instead of latching on the first frame
        // it ever saw. It is ordered before any `.live` this attempt can produce: both cross the same
        // main-queue hop, and this one is submitted first.
        emit(.connecting)
        makeStreamURL { [weak self] result in
            // Re-capture weakly INSIDE the hop: the provider may answer on any queue, so the value
            // that crosses to main has to be one the compiler can prove is safe to send.
            DispatchQueue.main.async { [weak self] in
                guard let self, !self.stopped, self.epoch == myEpoch else { return }
                switch result {
                case .success(let url):
                    self.probeDeadline = Date().addingTimeInterval(1.5)   // passthrough self-check window
                    self.client.start(url: url)
                case .failure(let e):
                    pipLog.error("could not build stream URL: \(e.message, privacy: .public)")
                    self.scheduleReconnect()
                }
            }
        }
    }

    /// The camera self-terminates ~7 s after the last viewer, and cold warm-up is 0.01–1.3 s.
    /// So: reconnect FAST (a 5 s backoff would guarantee the camera has already shut down and
    /// pay the warm-up again), with a short ceiling.
    private func scheduleReconnect() {
        guard !stopped else { return }
        retryAttempt += 1
        // A queued reconnect MUST be cancellable. With the 20 s ceiling, one scheduled just before
        // the user closed the camera would fire long after they had reopened it and tear down the
        // healthy connection that had replaced it — the picture drops and pays the warm-up again for
        // no reason.
        cancelPendingReconnect()
        let item = DispatchWorkItem { [weak self] in self?.connect() }
        pendingReconnect = item
        DispatchQueue.main.asyncAfter(deadline: .now() + CameraReconnectPolicy.delay(forAttempt: retryAttempt),
                                      execute: item)
    }

    private func cancelPendingReconnect() {
        pendingReconnect?.cancel()
        pendingReconnect = nil
    }

    // ---- MJPEGStreamClientDelegate ----
    //
    // All three arrive on the stream client's own serial queue and hop to main before touching any
    // renderer state. `MJPEGStreamError` carries an `any Error`, so it cannot cross the hop itself —
    // its message and retryability are read on the client's queue and only those cross.

    func streamDidReceiveFrame(_ jpeg: Data) {
        gate.offer(jpeg)                  // internally locked: the one thing that stays off main
        DispatchQueue.main.async { [weak self] in self?.noteFrame() }
    }

    /// Main queue only.
    private func noteFrame() {
        frameCount += 1
        // Logged sparsely, but it is the measurement that separates "the stream stopped" from
        // "frames arrive and nothing renders" — the two look identical on screen.
        if frameCount == 1 || frameCount % 100 == 0 {
            let dt = Date().timeIntervalSince(rateWindowStart)
            pipLog.info("camera frames=\(self.frameCount, privacy: .public) rate=\(String(format: "%.1f", Double(self.frameCount) / max(dt, 0.001)), privacy: .public)/s")
        }
        if frameCount % 20 == 0 {
            deliver(.stats(frames: frameCount, pipActive: pip?.isPictureInPictureActive == true))
        }
    }

    func streamDidBecomeLive() {
        pipLog.info("camera stream live")
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.retryAttempt = 0
            self.deliver(.live)
        }
    }

    /// Main queue only.
    private func deliver(_ event: CameraEvent) { onEvent?(event) }

    private func emit(_ event: CameraEvent) {
        DispatchQueue.main.async { [weak self] in self?.deliver(event) }
    }

    func streamDidFail(_ error: MJPEGStreamError) {
        pipLog.error("camera stream failed: \(error.localizedDescription, privacy: .public)")
        // Typed, not just a string: the native client can see what WebKit hid — notably a 401 from
        // an expired token, which the WebView could not distinguish from "still warming up".
        let message = error.localizedDescription
        let retryable = error.isRetryable
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.deliver(.error(message: message, retryable: retryable))
            guard !self.stopped else { return }
            // While PiP is up, ALWAYS reconnect: a dead socket means the camera shuts down 7 s later
            // and the floating window freezes with no way for the user to intervene.
            if retryable || self.pip?.isPictureInPictureActive == true {
                self.scheduleReconnect()
            }
        }
    }

    // ---- decode + enqueue (decode queue) ----

    private func decodeAndEnqueue(_ jpeg: Data) {
        // A layer whose decoder was reclaimed must be flushed before it will accept anything.
        if displayLayer.requiresFlushToResumeDecoding { displayLayer.flush() }
        guard displayLayer.isReadyForMoreMediaData else { return }   // backpressure: drop, never block
        guard let sb = builder.makeSampleBuffer(from: jpeg, pts: CMClockGetTime(CMClockGetHostTimeClock()))
        else { return }
        displayLayer.enqueue(sb)
    }

    // ---- passthrough self-check ----

    @objc private func layerFailedToDecode(_ n: Notification) {
        let err = n.userInfo?[AVSampleBufferDisplayLayerFailedToDecodeNotificationErrorKey] as? NSError
        let reason = err.map { "\($0.domain) \($0.code)" } ?? "unknown"
        // AVFoundation posts this on an unspecified thread. `builder` is decode-queue confined — the
        // same confinement `subsampleFactor` already honours — and the demotion assigns
        // `formatDescription = nil`, which would release the CMVideoFormatDescription the decode
        // queue is holding halfway through `passthroughBuffer`. Hop, don't lock.
        decodeQueue.async { [weak self] in
            guard let self else { return }
            if self.builder.strategy == .passthrough {
                self.builder.demoteToImageIO(reason: reason)
            } else {
                pipLog.error("display layer decode failure: \(reason, privacy: .public)")
            }
            self.displayLayer.flush()
        }
    }

    @objc private func layerRequiresFlushChanged(_ n: Notification) {
        // Same unspecified posting thread, and `flush` has to be serialised against `enqueue`.
        decodeQueue.async { [weak self] in
            guard let self, self.displayLayer.requiresFlushToResumeDecoding else { return }
            // Happens when the system revokes video decoder resources — observed after the
            // device has been locked with PiP up for a while. Flushing resets status from
            // .failed back to .unknown so the next enqueue renders.
            self.displayLayer.flush()
        }
    }

    // ---- AVPictureInPictureSampleBufferPlaybackDelegate ----

    func pictureInPictureController(_ c: AVPictureInPictureController, setPlaying playing: Bool) {
        // `stopped` IS the transport state — `pictureInPictureControllerIsPlaybackPaused` below
        // returns it — so the pause branch has to set it. It used to just cancel the task: `stopped`
        // stayed false, so the resume branch found nothing to restart, the cancelled task produced no
        // `streamDidFail` (URLError.cancelled returns early) and therefore no reconnect, and the
        // window sat frozen on its last frame while the transport control claimed it was playing.
        if playing {
            if stopped { start(urlProvider: makeStreamURL) }
        } else {
            teardown(clearImage: false)
        }
        c.invalidatePlaybackState()
    }

    /// Infinite duration == live content: PiP then shows no scrubber and no skip buttons.
    func pictureInPictureControllerTimeRangeForPlayback(_ c: AVPictureInPictureController) -> CMTimeRange {
        CMTimeRange(start: .negativeInfinity, duration: .positiveInfinity)
    }

    func pictureInPictureControllerIsPlaybackPaused(_ c: AVPictureInPictureController) -> Bool { stopped }

    /// Apple's own header: "Delegate take the new render size ... into account when choosing
    /// media variants in order to avoid unnecessary decoding overhead." The PiP window is a few
    /// hundred points wide; decoding 1680x1080 into it is pure waste on the ImageIO path.
    func pictureInPictureController(_ c: AVPictureInPictureController,
                                    didTransitionToRenderSize newRenderSize: CMVideoDimensions) {
        let target = max(Int(newRenderSize.width), 1)
        let factor: Int
        switch 1680 / max(target, 1) {
        case 0...1:  factor = 1
        case 2...3:  factor = 2
        case 4...7:  factor = 4
        default:     factor = 8
        }
        decodeQueue.async { [weak self] in self?.builder.subsampleFactor = factor }
    }

    func pictureInPictureController(_ c: AVPictureInPictureController,
                                    skipByInterval: CMTime, completion: @escaping () -> Void) {
        completion()    // live stream: nothing to seek. Failing to call this wedges the PiP UI.
    }

    // ---- AVPictureInPictureControllerDelegate ----

    func pictureInPictureControllerDidStartPictureInPicture(_ c: AVPictureInPictureController) {
        pipLog.info("PiP started")
        emit(.pipStart)
    }

    func pictureInPictureController(_ c: AVPictureInPictureController,
                                    failedToStartPictureInPictureWithError error: Error) {
        pipLog.error("PiP failed to start: \(error.localizedDescription, privacy: .public)")
        keepAlive.deactivate()
        emit(.pipStop(error: error.localizedDescription))
    }

    func pictureInPictureControllerDidStopPictureInPicture(_ c: AVPictureInPictureController) {
        // Full resolution again once we are back inline.
        decodeQueue.async { [weak self] in self?.builder.subsampleFactor = 1 }
        keepAlive.deactivate()
        emit(.pipStop(error: nil))
    }
}

// ============================================================================
