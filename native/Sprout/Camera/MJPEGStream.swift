import Foundation
import AVFoundation
import AVKit
import CoreMedia
import CoreVideo
import ImageIO
import os

// MARK: - 3. Frame gate — the backpressure policy
// ============================================================================

/// A one-slot mailbox between the URLSession delegate queue (producer, 10 fps, 200 KB each)
/// and the decode queue (consumer). LATEST WINS: if the consumer is still busy when a new
/// frame lands, the older one is discarded, never queued.
///
/// Why not a queue: a live camera has no value in stale frames. A FIFO would (a) grow without
/// bound if decode ever falls behind, at 2 MB/s, and (b) add latency that never recovers,
/// because the producer rate is fixed by the server, not by us. Bounded memory here is
/// exactly 2 frames (~520 KB).
///
/// `@unchecked Sendable`: every field is read and written under `lock`, which is the whole reason
/// this type exists — it is the one object deliberately touched from both the network queue and the
/// decode queue.
final class LatestFrameGate: @unchecked Sendable {
    private let lock = NSLock()
    private var pending: Data?
    private var draining = false
    private(set) var deliveredCount = 0
    private(set) var droppedCount = 0

    private let queue: DispatchQueue
    private let handler: (Data) -> Void

    init(queue: DispatchQueue, handler: @escaping (Data) -> Void) {
        self.queue = queue
        self.handler = handler
    }

    /// Called from the URLSession delegate queue. Never blocks.
    func offer(_ frame: Data) {
        lock.lock()
        if pending != nil { droppedCount += 1 }
        pending = frame
        let needsKick = !draining
        if needsKick { draining = true }
        lock.unlock()
        guard needsKick else { return }
        queue.async { [weak self] in self?.drain() }
    }

    private func drain() {
        while true {
            lock.lock()
            guard let next = pending else { draining = false; lock.unlock(); return }
            pending = nil
            deliveredCount += 1
            lock.unlock()
            handler(next)
        }
    }

    func reset() {
        lock.lock(); pending = nil; deliveredCount = 0; droppedCount = 0; lock.unlock()
    }
}

// ============================================================================
// MARK: - 4. JPEG -> CMSampleBuffer
// ============================================================================

/// Two strategies, chosen at runtime.
///
/// `.passthrough` wraps the compressed JPEG bytes in a CMSampleBuffer carrying a
/// `kCMVideoCodecType_JPEG` format description and lets AVSampleBufferDisplayLayer's own
/// VideoToolbox decoder do the work — no pixels ever touch our address space. Verified
/// working on macOS 26 (layer reached `.rendering`, no FailedToDecode notification) and
/// `VTIsHardwareDecodeSupported(kCMVideoCodecType_JPEG)` is true on Apple silicon. It is NOT
/// documented for iOS, so it ships behind a self-check that demotes to `.imageIO` on the
/// first decode failure.
///
/// `.imageIO` decodes with ImageIO into an IOSurface-backed pooled CVPixelBuffer, at a
/// subsample factor chosen from the current render size. Measured (M4 Max, 172 KB /
/// 1680x1080): 6.19 ms full res, 2.45 ms at subsample 2, 1.69 ms at subsample 4.
enum DecodeStrategy { case passthrough, imageIO }

/// NOT thread-safe, by design: every method and every field is confined to the renderer's
/// `decodeQueue`. `formatDescription` and `pool` are reference-counted CoreMedia/CoreVideo objects,
/// so releasing one from a second thread while `passthroughBuffer` is between its load and its use is
/// an over-release, not a torn read. `demoteToImageIO` in particular arrives from an
/// AVSampleBufferDisplayLayer notification on an unspecified thread and must be hopped, not locked.
final class JPEGFrameBuilder {

    private(set) var strategy: DecodeStrategy = .passthrough
    /// 1, 2, 4 or 8. Driven by `pictureInPictureController(_:didTransitionToRenderSize:)`,
    /// which Apple's own header tells you to use "in order to avoid unnecessary decoding
    /// overhead".
    var subsampleFactor: Int = 1

    private var formatDescription: CMVideoFormatDescription?
    private var formatDims: (Int, Int) = (0, 0)
    private var pool: CVPixelBufferPool?
    private var poolDims: (Int, Int) = (0, 0)

    func demoteToImageIO(reason: String) {
        guard strategy == .passthrough else { return }
        strategy = .imageIO
        formatDescription = nil
        cameraLog.warning("JPEG passthrough rejected by AVSampleBufferDisplayLayer (\(reason, privacy: .public)); falling back to ImageIO decode")
    }

    /// Called on the decode queue. Returns a buffer ready to enqueue, or nil.
    func makeSampleBuffer(from jpeg: Data, pts: CMTime) -> CMSampleBuffer? {
        guard let info = inspectJPEG(jpeg) else { return nil }
        // Hardware JPEG decoders reject progressive JPEGs; never hand one to the layer.
        if strategy == .passthrough, !info.isProgressive {
            return passthroughBuffer(jpeg, info: info, pts: pts)
        }
        return decodedBuffer(jpeg, pts: pts)
    }

    // ---- strategy A: zero-copy compressed passthrough ----

    private func passthroughBuffer(_ jpeg: Data, info: JPEGInfo, pts: CMTime) -> CMSampleBuffer? {
        if formatDescription == nil || formatDims != (info.width, info.height) {
            var fd: CMVideoFormatDescription?
            guard CMVideoFormatDescriptionCreate(allocator: kCFAllocatorDefault,
                                                 codecType: kCMVideoCodecType_JPEG,
                                                 width: Int32(info.width), height: Int32(info.height),
                                                 extensions: nil, formatDescriptionOut: &fd) == noErr,
                  let fd else { return nil }
            formatDescription = fd
            formatDims = (info.width, info.height)
        }
        guard let fd = formatDescription else { return nil }

        // CMBlockBuffer takes ownership of a malloc'd copy (kCFAllocatorMalloc frees it).
        guard let bytes = malloc(jpeg.count) else { return nil }
        jpeg.withUnsafeBytes { bytes.copyMemory(from: $0.baseAddress!, byteCount: jpeg.count) }
        var block: CMBlockBuffer?
        guard CMBlockBufferCreateWithMemoryBlock(allocator: kCFAllocatorDefault, memoryBlock: bytes,
                                                 blockLength: jpeg.count, blockAllocator: kCFAllocatorMalloc,
                                                 customBlockSource: nil, offsetToData: 0,
                                                 dataLength: jpeg.count, flags: 0,
                                                 blockBufferOut: &block) == noErr,
              let block else { free(bytes); return nil }

        var sb: CMSampleBuffer?
        var size = jpeg.count
        var timing = CMSampleTimingInfo(duration: CMTime(value: 1, timescale: 10),
                                        presentationTimeStamp: pts, decodeTimeStamp: .invalid)
        guard CMSampleBufferCreateReady(allocator: kCFAllocatorDefault, dataBuffer: block,
                                        formatDescription: fd, sampleCount: 1,
                                        sampleTimingEntryCount: 1, sampleTimingArray: &timing,
                                        sampleSizeEntryCount: 1, sampleSizeArray: &size,
                                        sampleBufferOut: &sb) == noErr, let sb else { return nil }
        Self.markDisplayImmediately(sb)
        return sb
    }

    // ---- strategy B: ImageIO decode into a pooled IOSurface-backed pixel buffer ----

    private func decodedBuffer(_ jpeg: Data, pts: CMTime) -> CMSampleBuffer? {
        let opts: [CFString: Any] = [
            kCGImageSourceShouldCacheImmediately: true,   // decode now, on THIS queue
            kCGImageSourceShouldCache: false,
            kCGImageSourceSubsampleFactor: max(1, subsampleFactor),
        ]
        guard let src = CGImageSourceCreateWithData(jpeg as CFData, nil),
              let cg = CGImageSourceCreateImageAtIndex(src, 0, opts as CFDictionary)
        else { return nil }

        let w = cg.width, h = cg.height
        if pool == nil || poolDims != (w, h) {
            // kCVPixelBufferIOSurfacePropertiesKey is MANDATORY: AVSampleBufferDisplayLayer's
            // header states CVPixelBuffers it is handed must be IOSurface-backed.
            let attrs: [CFString: Any] = [
                kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_32BGRA,
                kCVPixelBufferWidthKey: w,
                kCVPixelBufferHeightKey: h,
                kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary,
            ]
            var p: CVPixelBufferPool?
            guard CVPixelBufferPoolCreate(kCFAllocatorDefault,
                                          [kCVPixelBufferPoolMinimumBufferCountKey: 3] as CFDictionary,
                                          attrs as CFDictionary, &p) == kCVReturnSuccess else { return nil }
            pool = p
            poolDims = (w, h)
        }
        guard let pool else { return nil }
        var pbOut: CVPixelBuffer?
        guard CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, pool, &pbOut) == kCVReturnSuccess,
              let pb = pbOut else { return nil }

        CVPixelBufferLockBaseAddress(pb, [])
        defer { CVPixelBufferUnlockBaseAddress(pb, []) }
        guard let ctx = CGContext(data: CVPixelBufferGetBaseAddress(pb), width: w, height: h,
                                  bitsPerComponent: 8, bytesPerRow: CVPixelBufferGetBytesPerRow(pb),
                                  space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.noneSkipFirst.rawValue
                                            | CGBitmapInfo.byteOrder32Little.rawValue)
        else { return nil }
        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))

        var fd: CMVideoFormatDescription?
        guard CMVideoFormatDescriptionCreateForImageBuffer(allocator: kCFAllocatorDefault,
                                                           imageBuffer: pb,
                                                           formatDescriptionOut: &fd) == noErr,
              let fd else { return nil }
        var sb: CMSampleBuffer?
        var timing = CMSampleTimingInfo(duration: CMTime(value: 1, timescale: 10),
                                        presentationTimeStamp: pts, decodeTimeStamp: .invalid)
        guard CMSampleBufferCreateReadyWithImageBuffer(allocator: kCFAllocatorDefault, imageBuffer: pb,
                                                       formatDescription: fd, sampleTiming: &timing,
                                                       sampleBufferOut: &sb) == noErr, let sb else { return nil }
        Self.markDisplayImmediately(sb)
        return sb
    }

    /// With no controlTimebase set on the layer, DisplayImmediately renders each frame the
    /// moment it is decoded and drops anything still queued — exactly right for a live feed
    /// with jittery arrival. (AVSampleBufferDisplayLayer.h only warns against combining this
    /// with a controlTimebase or an AVSampleBufferRenderSynchronizer; we set neither.)
    private static func markDisplayImmediately(_ sb: CMSampleBuffer) {
        guard let atts = CMSampleBufferGetSampleAttachmentsArray(sb, createIfNecessary: true),
              CFArrayGetCount(atts) > 0 else { return }
        let dict = unsafeBitCast(CFArrayGetValueAtIndex(atts, 0), to: CFMutableDictionary.self)
        CFDictionarySetValue(dict,
                             Unmanaged.passUnretained(kCMSampleAttachmentKey_DisplayImmediately).toOpaque(),
                             Unmanaged.passUnretained(kCFBooleanTrue).toOpaque())
    }
}

// ============================================================================
// MARK: - 5. The network client
// ============================================================================

protocol MJPEGStreamClientDelegate: AnyObject, Sendable {
    /// Delivered on the client's state queue — the same serial queue URLSession uses for its delegate
    /// callbacks, and the only queue that ever touches the client. Do not block.
    func streamDidReceiveFrame(_ jpeg: Data)
    func streamDidBecomeLive()
    func streamDidFail(_ error: MJPEGStreamError)
}

enum MJPEGStreamError: LocalizedError {
    case httpStatus(Int)
    case notMultipart(String)
    case backendMessage(String)        // <- the warm-up / camera-unavailable case
    case noFirstFrame(after: TimeInterval)
    case parse(Error)
    case transport(Error)
    case unauthorized                  // 401: the ?token= expired

    var errorDescription: String? {
        switch self {
        case .httpStatus(let c):        return "HTTP \(c)"
        case .notMultipart(let ct):     return "expected multipart/x-mixed-replace, got \(ct)"
        case .backendMessage(let m):    return m
        case .noFirstFrame(let t):      return "no JPEG within \(Int(t))s"
        case .parse(let e):             return "stream parse error: \(e.localizedDescription)"
        case .transport(let e):         return e.localizedDescription
        case .unauthorized:             return "camera stream token rejected"
        }
    }

    /// The camera is on-demand: warm-up (0.01–1.3 s measured) and self-termination ~7 s after
    /// the last viewer both present as recoverable. A 401 needs a fresh token first.
    var isRetryable: Bool {
        switch self {
        case .backendMessage, .noFirstFrame, .transport, .parse, .httpStatus: return true
        case .notMultipart: return true
        case .unauthorized: return false
        }
    }
}

/// `@unchecked Sendable`: every stored property below is confined to `stateQueue`, including the ones
/// URLSession writes through its delegate callbacks — there is exactly one queue that may touch this
/// object's state, and the public API hops onto it rather than reaching in from the caller's queue.
final class MJPEGStreamClient: NSObject, @unchecked Sendable, URLSessionDataDelegate {

    /// THE queue. It is the delegate queue's `underlyingQueue`, so URLSession runs every callback on
    /// it; `setDelegate`/`start`/`stop`/`invalidate` hop onto it; the first-frame watchdog fires on it.
    ///
    /// Serialising only the delegate queue was not enough, and the gap was not theoretical: `start()`
    /// ran `resetConnectionState()` from the MAIN queue, so `parser` could be set to nil between the
    /// delegate thread's `parser != nil` check and its `parser!` use — an "unexpectedly found nil"
    /// trap — and `partBuffer.append` could run against the same copy-on-write storage another thread
    /// was calling `removeAll` on.
    private let stateQueue = DispatchQueue(label: "bambu.mjpeg.state", qos: .userInitiated)

    private var session: URLSession!
    private weak var delegateRef: MJPEGStreamClientDelegate?
    private var task: URLSessionDataTask?
    private var parser: MultipartMJPEGParser?
    private var sawFirstFrame = false
    private var invalidated = false
    // URLSession DE-MULTIPLEXES multipart/x-mixed-replace by itself: every part arrives as its own
    // didReceive-response callback carrying that PART's Content-Type, and the bytes that follow are
    // the part body alone — boundary framing never reaches the delegate. So the parser below only
    // ever runs on platforms/paths that hand us the raw stream; on the normal path these two fields
    // do the work. (Rejecting the second callback as "not multipart" is exactly how this first
    // failed: the stream connected, then instantly errored on its own first frame.)
    private var partBuffer = Data()
    private var partExpected: Int?
    private var demultiplexed = false
    private var firstFrameDeadline: DispatchWorkItem?
    private let firstFrameTimeout: TimeInterval

    init(firstFrameTimeout: TimeInterval = 12) {
        self.firstFrameTimeout = firstFrameTimeout
        super.init()

        // Serial AND backed by `stateQueue`: URLSession runs the callbacks as operations on the
        // underlying queue, so a delegate callback can never overlap a start/stop/watchdog hop.
        let delegateQueue = OperationQueue()
        delegateQueue.maxConcurrentOperationCount = 1
        delegateQueue.qualityOfService = .userInitiated
        delegateQueue.name = "bambu.mjpeg.net"
        delegateQueue.underlyingQueue = stateQueue

        // EPHEMERAL, deliberately. Three reasons, in order of importance:
        //  1. The stream token lives in the QUERY STRING. A `.default` session persists response
        //     metadata keyed by the full URL into an on-disk Cache.db — writing a live credential
        //     to disk in the clear. `.ephemeral` keeps cache/cookies/credentials in memory only.
        //  2. No cookie or credential jar to leak between printers/tokens.
        //  3. Cache semantics can never interpose on an infinite response.
        let cfg = URLSessionConfiguration.ephemeral
        cfg.urlCache = nil
        cfg.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        cfg.httpShouldSetCookies = false
        cfg.httpCookieAcceptPolicy = .never
        // timeoutIntervalForRequest is an IDLE timeout — it resets on every byte received, so on
        // a streaming response it doubles as the stall watchdog. 15 s comfortably clears the
        // measured 1.3 s warm-up but trips well before a user notices a frozen picture.
        cfg.timeoutIntervalForRequest = 15
        // Default is 7 days; a PiP session lasting that long would be silently killed. Be explicit.
        cfg.timeoutIntervalForResource = .greatestFiniteMagnitude
        cfg.waitsForConnectivity = false          // we run our own reconnect policy
        cfg.networkServiceType = .video
        cfg.allowsExpensiveNetworkAccess = true
        cfg.allowsConstrainedNetworkAccess = true
        cfg.httpAdditionalHeaders = ["Accept": "multipart/x-mixed-replace, image/jpeg"]

        session = URLSession(configuration: cfg, delegate: self, delegateQueue: delegateQueue)
    }

    /// The delegate is stored on `stateQueue` like everything else, so it is set through a method
    /// rather than a property. Safe to call from any queue; callbacks arrive on `stateQueue`.
    func setDelegate(_ next: MJPEGStreamClientDelegate?) {
        stateQueue.async { [weak self] in self?.delegateRef = next }
    }

    /// Safe to call from any queue — the work runs on `stateQueue`, ordered against every in-flight
    /// delegate callback.
    func start(url: URL) {
        stateQueue.async { [weak self] in self?.performStart(url: url) }
    }

    /// Safe to call from any queue — the work runs on `stateQueue`.
    func stop() {
        stateQueue.async { [weak self] in self?.performStop() }
    }

    /// URLSession keeps a STRONG reference to its delegate — this object — until the session is
    /// explicitly invalidated. That made client and session a retain cycle, so `deinit` could never
    /// run and every camera session permanently leaked one client, one ephemeral URLSession and its
    /// operation queue. The owner must call this exactly once when it is done with the client; there
    /// is no other way for these to be released.
    func invalidate() {
        stateQueue.async { [weak self] in
            // `weak` still resolves here: the session itself is holding us until the line below.
            guard let self, !self.invalidated else { return }
            self.invalidated = true
            self.performStop()
            self.delegateRef = nil
            self.session.invalidateAndCancel()
        }
    }

    // ---- everything below runs on `stateQueue` ----

    private func performStart(url: URL) {
        guard !invalidated else { return }
        performStop()
        resetConnectionState()
        var req = URLRequest(url: url)
        req.httpMethod = "GET"
        req.setValue("no-store", forHTTPHeaderField: "Cache-Control")
        let t = session.dataTask(with: req)
        task = t
        armFirstFrameWatchdog()
        cameraLog.info("MJPEG connect \(Self.redact(url), privacy: .public)")
        t.resume()
    }

    private func performStop() {
        firstFrameDeadline?.cancel(); firstFrameDeadline = nil
        // `cancel()` is asynchronous, so callbacks for this task can still be queued behind us.
        // Clearing `task` is what makes them identifiable as stale — see the identity guards below.
        task?.cancel(); task = nil
    }

    /// Clear EVERY per-connection field before reconnecting.
    ///
    /// `demultiplexed` used to survive a restart, and that one omission was enough to break the
    /// camera permanently after the first disconnect: the flag says "responses on this task are
    /// parts, not headers", so on the next connection the opening
    /// `multipart/x-mixed-replace; boundary=frame` response was judged as a part, found not to be
    /// `image/*`, and rejected as "camera unavailable" before a single byte of video arrived. The
    /// retry then failed the same way forever, and because each attempt attaches a viewer
    /// server-side, the pile-up starved the camera for every other client too.
    private func resetConnectionState() {
        parser = nil
        sawFirstFrame = false
        demultiplexed = false
        partExpected = nil
        partBuffer.removeAll(keepingCapacity: true)
    }

    /// Never log the raw URL — it carries the camera stream token.
    static func redact(_ url: URL) -> String {
        guard var c = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return "<url>" }
        c.queryItems = c.queryItems?.map { $0.name == "token" ? URLQueryItem(name: "token", value: "***") : $0 }
        return c.string ?? "<url>"
    }

    // ---- warm-up watchdog ----
    //
    // The failure this exists for: during warm-up the backend answers HTTP 200 with correct
    // multipart headers, so the socket looks healthy, and then emits either nothing or a single
    // text/plain part. Neither a transport error nor an idle timeout necessarily fires. Without
    // this the UI waits forever — the exact bug the WebView viewer had to solve with a stall
    // watchdog. Two independent detectors: the text/plain part (immediate, in didReceive) and
    // this wall-clock deadline (covers "opened and then silent").
    private func armFirstFrameWatchdog() {
        firstFrameDeadline?.cancel()
        let item = DispatchWorkItem { [weak self] in
            guard let self, !self.sawFirstFrame else { return }
            self.fail(.noFirstFrame(after: self.firstFrameTimeout))
        }
        firstFrameDeadline = item
        // On `stateQueue`, NOT main. It reads `sawFirstFrame` and then tears the task down; running
        // that on main against fields the delegate queue was writing meant a first frame landing on
        // the deadline could be delivered while the watchdog was already committed to killing the
        // connection — the healthy stream was cancelled and `streamDidFail` was handed to a delegate
        // that had just been told the stream was live, on a queue the protocol says it never uses.
        stateQueue.asyncAfter(deadline: .now() + firstFrameTimeout, execute: item)
    }

    private func fail(_ e: MJPEGStreamError) {
        performStop()
        delegateRef?.streamDidFail(e)
    }

    // ---- URLSessionDataDelegate ----

    func urlSession(_ s: URLSession, dataTask: URLSessionDataTask,
                    didReceive response: URLResponse,
                    completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        // A cancelled task keeps delivering until URLSession notices. Anything not from the task we
        // currently own is from a connection that has already been replaced or torn down.
        guard dataTask === task else { completionHandler(.cancel); return }
        guard let http = response as? HTTPURLResponse else {
            completionHandler(.cancel); fail(.notMultipart("non-HTTP response")); return
        }
        guard http.statusCode == 200 else {
            completionHandler(.cancel)
            fail(http.statusCode == 401 || http.statusCode == 403 ? .unauthorized : .httpStatus(http.statusCode))
            return
        }
        let ct = (http.value(forHTTPHeaderField: "Content-Type") ?? "").lowercased()

        // Subsequent callbacks on the SAME task are parts, not a new response.
        if parser != nil || demultiplexed {
            flushPart()
            demultiplexed = true
            if ct.hasPrefix("image/") {
                partExpected = http.expectedContentLength > 0 ? Int(http.expectedContentLength) : nil
                partBuffer.removeAll(keepingCapacity: true)
            } else {
                // THE WARM-UP CHECK: HTTP 200, correct multipart headers, but the only part is a
                // text/plain error. Without this the UI waits forever on a healthy-looking socket.
                partExpected = nil
                if !sawFirstFrame {
                    completionHandler(.cancel)
                    fail(.backendMessage("camera unavailable (\(ct.isEmpty ? "no content-type" : ct))"))
                    return
                }
            }
            completionHandler(.allow)
            return
        }

        guard ct.contains("multipart/x-mixed-replace"),
              let b = MultipartMJPEGParser.boundary(fromContentType: ct) else {
            completionHandler(.cancel); fail(.notMultipart(ct.isEmpty ? "(no Content-Type)" : ct)); return
        }
        parser = MultipartMJPEGParser(boundary: b)
        completionHandler(.allow)
    }

    /// Emit whatever part body has accumulated. Called when the NEXT part's headers arrive, which is
    /// what proves the body is complete on a part that carried no Content-Length.
    private func flushPart() {
        guard !partBuffer.isEmpty else { return }
        let jpeg = partBuffer
        partBuffer.removeAll(keepingCapacity: true)
        partExpected = nil
        emitFrame(jpeg)
    }

    /// The same flush at end-of-connection. A part with no Content-Length is otherwise only completed
    /// by the next part's headers, and the on-demand camera self-terminates instead of sending them —
    /// so a stream that handed over one whole JPEG and closed used to discard it, leave `sawFirstFrame`
    /// false, and report "no JPEG within 12s" for a frame it had actually received.
    ///
    /// Nothing here proves completeness, so ask the JPEG itself — see `isCompleteJPEG`.
    private func flushFinalPart() {
        defer { partBuffer.removeAll(keepingCapacity: true); partExpected = nil }
        guard Self.isCompleteJPEG(partBuffer) else { return }
        emitFrame(partBuffer)
    }

    /// A whole JPEG opens with SOI (FF D8) and ends with EOI (FF D9). At end-of-connection there is
    /// no following part to prove the buffered body was complete, and without this check a connection
    /// dropped mid-frame would hand the decoder a truncation and report the stream as having gone
    /// live off the back of it.
    static func isCompleteJPEG(_ d: Data) -> Bool {
        d.count >= 4 && d.prefix(2).elementsEqual([0xFF, 0xD8]) && d.suffix(2).elementsEqual([0xFF, 0xD9])
    }

    private func emitFrame(_ jpeg: Data) {
        if !sawFirstFrame {
            sawFirstFrame = true
            firstFrameDeadline?.cancel(); firstFrameDeadline = nil
            delegateRef?.streamDidBecomeLive()
        }
        delegateRef?.streamDidReceiveFrame(jpeg)
    }

    func urlSession(_ s: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        guard dataTask === task else { return }
        if demultiplexed {
            partBuffer.append(data)
            // The parser path has enforced an 8 MB ceiling since it was written, precisely so a server
            // that stops emitting boundaries cannot exhaust memory. This branch — the one that
            // actually runs on device, because URLSession de-multiplexes multipart itself — had no
            // ceiling at all: with no Content-Length the buffer's only bound was the next part's
            // headers, so a stream that never sent them grew at ~2 MB/s until jetsam.
            if partBuffer.count > MultipartMJPEGParser.bufferLimit {
                fail(.parse(MJPEGParseError.bufferOverflow(limit: MultipartMJPEGParser.bufferLimit)))
                return
            }
            // Content-Length lets a frame be emitted the moment it is complete rather than waiting
            // for the next part's headers — a whole frame-interval of latency at 10 fps.
            if let n = partExpected, partBuffer.count >= n {
                let jpeg = partBuffer.prefix(n)
                partBuffer.removeAll(keepingCapacity: true)
                partExpected = nil
                emitFrame(Data(jpeg))
            }
            return
        }
        // Take the parser out of the property for the duration of the call: it is a struct holding a
        // rolling byte buffer, and being its sole owner is what lets `consume` append in place instead
        // of copying the whole buffer per chunk.
        guard var p = parser else { return }
        parser = nil
        let events: [MJPEGParseEvent]
        do { events = try p.consume(data) } catch { fail(.parse(error)); return }
        parser = p

        for e in events {
            switch e {
            case .frame(let jpeg):
                emitFrame(jpeg)

            case .nonImagePart(let ct, let body):
                // THE WARM-UP CHECK. HTTP 200, well-formed multipart, one text/plain part.
                let msg = String(decoding: body.prefix(512), as: UTF8.self)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                cameraLog.warning("camera stream sent \(ct, privacy: .public) instead of a frame: \(msg, privacy: .public)")
                if !sawFirstFrame {
                    fail(.backendMessage(msg.isEmpty ? "camera unavailable (\(ct))" : msg))
                    return
                }
                // Mid-stream: one bad part is not fatal; the idle timeout will catch a real stall.

            case .endOfStream:
                cameraLog.info("camera closed the multipart stream")
                fail(sawFirstFrame ? .transport(URLError(.networkConnectionLost)) : .backendMessage("camera closed the stream before sending a frame"))
                return
            }
        }
    }

    /// URLSession follows redirects by default and carries only whatever URL the server put in
    /// `Location`. If that drops the query string the token is gone and the next hop 401s; if it
    /// points off-host the token leaks to a third party. Refuse anything that is not a same-origin
    /// redirect, and re-attach the token if the server stripped it.
    func urlSession(_ s: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest,
                    completionHandler: @escaping (URLRequest?) -> Void) {
        guard let old = task.originalRequest?.url, let new = request.url,
              old.scheme == new.scheme, old.host == new.host, old.port == new.port else {
            cameraLog.error("refusing cross-origin redirect from the camera stream")
            completionHandler(nil)          // deliver the 3xx body instead of following it
            return
        }
        var out = request
        if URLComponents(url: new, resolvingAgainstBaseURL: false)?
            .queryItems?.contains(where: { $0.name == "token" }) != true,
           var c = URLComponents(url: new, resolvingAgainstBaseURL: false),
           let tok = URLComponents(url: old, resolvingAgainstBaseURL: false)?
            .queryItems?.first(where: { $0.name == "token" }) {
            c.queryItems = (c.queryItems ?? []) + [tok]
            if let fixed = c.url { out = URLRequest(url: fixed) }
        }
        completionHandler(out)
    }

    func urlSession(_ s: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard task === self.task else { return }
        self.task = nil
        firstFrameDeadline?.cancel(); firstFrameDeadline = nil
        // Our own cancellation, from stop()/start(). Nothing to report and nothing worth flushing.
        if (error as? URLError)?.code == .cancelled { return }
        flushFinalPart()
        if let error {
            delegateRef?.streamDidFail(.transport(error))
        } else {
            delegateRef?.streamDidFail(.transport(URLError(.networkConnectionLost)))
        }
    }
}

// ============================================================================
