<!-- Generated as the port specification for the native Swift rewrite. -->
# The MJPEG + PiP layer (already Swift — ports nearly verbatim)

## pip

The Picture-in-Picture chamber-camera pipeline. **This module is already 100% Swift** — it is the single largest chunk of the app that ports verbatim. The only throwaway code is the Expo bridging layer (`CameraPiPView.swift`'s base class + `CameraPiPModule.swift` + `src/index.ts` + the podspec/`expo-module.config.json`).

**Why it exists at all** (from `CameraPiPModule.swift`'s doc comment): the printer camera is MJPEG, and *iOS cannot put MJPEG into Picture-in-Picture* — PiP needs a real video track. Rather than stand up an HLS transcode service, this module decodes JPEG frames in-app and feeds an `AVSampleBufferDisplayLayer`, which `AVPictureInPictureController` accepts directly as a `ContentSource`. No transcode hop, no extra service, no cold-start regression.

### File inventory

| File | Lines | Role | Ports as-is? |
|---|---|---|---|
| `modules/camera-pip/ios/CameraPiPLog.swift` | 11 | `let pipLog = Logger(subsystem: "com.mvks5.bambu", category: "camera-pip")` | **Yes** |
| `modules/camera-pip/ios/MJPEGParser.swift` | 273 | Incremental `multipart/x-mixed-replace` parser + JPEG header inspector | **Yes, 100%** |
| `modules/camera-pip/ios/MJPEGStream.swift` | 519 | Frame gate, JPEG→CMSampleBuffer builder, URLSession client | **Yes, 100%** |
| `modules/camera-pip/ios/CameraPiPRenderer.swift` | 335 | Audio keep-alive, display layer, PiP controller, reconnect policy | **Yes** (only the `onEvent` dict shape changes) |
| `modules/camera-pip/ios/CameraPiPView.swift` | 74 | `ExpoView` host for the layer | **No** — rewrite as plain `UIView` + `UIViewRepresentable` |
| `modules/camera-pip/ios/CameraPiPModule.swift` | 52 | Expo `Module` definition | **No** — delete |
| `modules/camera-pip/ios/CameraPiP.podspec` | 19 | Pod packaging | **No** — delete |
| `modules/camera-pip/expo-module.config.json` | 6 | `{"platforms":["apple"],"apple":{"modules":["CameraPiPModule"]}}` | **No** — delete |
| `modules/camera-pip/src/index.ts` | 46 | TS types + `requireNativeView`/`requireNativeModule` | **No** — delete |

Podspec facts worth preserving: `s.platforms = { :ios => '16.4' }`, `s.static_framework = true`, `s.frameworks = 'AVKit', 'AVFoundation', 'CoreMedia', 'CoreVideo', 'ImageIO'`, `s.pod_target_xcconfig = { 'DEFINES_MODULE' => 'YES' }`. In a native app these become plain target membership + framework links; **iOS 16.4 is the real floor** (`AVPictureInPictureController.ContentSource(sampleBufferDisplayLayer:playbackDelegate:)` is iOS 15+, but the app baseline is 16.4).

---

### The endpoints and the token

- Mint: `POST {baseURL}/api/v1/printers/camera/stream-token` with header `X-API-Key: <key>` → JSON `{ "token": "..." }`.
- Stream: `GET {baseURL}/api/v1/printers/{printerId}/camera/stream?token=<urlencoded>&fps=10`
- Snapshot (used as a fast-fail probe): `GET {baseURL}/api/v1/printers/{printerId}/camera/snapshot?token=<urlencoded>`
- Diagnose: `POST {baseURL}/api/v1/printers/{printerId}/camera/diagnose`

`{baseURL}` is `https://<bambuddy-host>` from the Keychain. **The token MUST be in the query string — the `X-API-Key` header is rejected with 401 on `/camera/stream` and `/camera/snapshot`.** Same token also authorizes every library/print-log thumbnail.

Token lifecycle (`src/realtime/useCameraStream.ts`, must be reimplemented natively): backend TTL is **60 minutes**; the app refreshes at **55 min** (`TOKEN_TTL_MS = 55 * 60 * 1000`) via a **60 s** interval timer, and mints on enable / clears on disable. Tokens are session-only, never persisted.

---

### 1. `MJPEGParser.swift` — incremental multipart parser

`MultipartMJPEGParser` is a **pure value type (struct), no I/O**, deliberately unit-testable without a socket.

**Why an incremental parser is required** (verbatim from the header comment): URLSession delivers ~16–64 KB per `didReceive data:` callback, so a 200 KB JPEG spans 4–15 callbacks and **a boundary marker WILL land split across two of them**.

The four rules it encodes:
1. Never rescan bytes already scanned, **except** the tail that could be the prefix of a boundary completed by the next chunk.
2. Honour `Content-Length` when present (one memcpy, zero scanning); fall back to scanning for the next delimiter when absent.
3. A candidate delimiter only counts if it **starts a line** AND is followed by CRLF / LF / HT / SP / `--`. Without this, JPEG entropy-coded data containing the literal bytes `--frame` truncates a frame on the scanning path.
4. Discard the preamble before the first delimiter and re-seek after every body (the inter-part CRLF is framing, not payload). Tolerate bare-LF line endings.

**Buffer cap:** `static let bufferLimit = 8 * 1024 * 1024`. Rationale in-comment: one 1680×1080 frame is **191–261 KB**, so 8 MB is ~30 frames of slack before declaring the stream desynchronised rather than OOMing on a server that stopped emitting boundaries. Exceeding it throws `MJPEGParseError.bufferOverflow(limit:)`.

**Events:**
```swift
enum MJPEGParseEvent {
    case frame(Data)
    /// A non-image part. Bambuddy emits exactly one `text/plain` part inside an HTTP 200
    /// while the on-demand camera is warming up or has failed. THIS is the warm-up signal.
    case nonImagePart(contentType: String, body: Data)
    case endOfStream
}
```

**Errors:** `bufferOverflow(limit:)` → `"multipart buffer exceeded \(l) bytes without a boundary"`; `malformedHeaders` → `"multipart part headers were malformed"`; `badContentLength(String)` → `"unparsable Content-Length: \(s)"`.

#### State machine

```
seekingDelimiter --find valid delimiter, drop preamble--> atDelimiter
atDelimiter --"--" follows--> emit .endOfStream, clear buf --> finished (terminal)
atDelimiter --parse headers--> bodyKnown(headers, length)   [Content-Length present]
                            \-> bodyScan(headers)           [Content-Length absent]
bodyKnown --buf.count >= length--> emit, drop(length) --> seekingDelimiter
bodyScan  --find next delimiter--> trim trailing CRLF/LF, emit, drop(idx) --> atDelimiter
finished --> consume() returns [] forever
```

Instance state: `delimiter: [UInt8]` (= `"--" + boundary` as UTF-8), `buf: [UInt8]`, `scanned: Int`, `state`, `atStreamStart: Bool` (**only the first delimiter may omit a leading LF**).

Note the asymmetry: `bodyKnown` returns to `seekingDelimiter` (the trailing CRLF after the body is framing to be skipped), while `bodyScan` returns to `atDelimiter` because `drop(idx)` deliberately leaves the delimiter at `buf[0]`.

**`atDelimiter` byte walk** (after the delimiter): index `i = delimiter.count`; if `buf[i] == 0x2D && buf[i+1] == 0x2D` → closing marker → `.endOfStream`; otherwise skip SP (`0x20`) / HT (`0x09`), then optional CR (`0x0D`), then require LF (`0x0A`) or throw `.malformedHeaders`.

**Boundary extraction from Content-Type** — handles quoted and unspaced forms:
```swift
static func boundary(fromContentType ct: String) -> String? {
    for rawParam in ct.split(separator: ";").dropFirst() {
        let p = rawParam.trimmingCharacters(in: .whitespaces)
        guard p.lowercased().hasPrefix("boundary=") else { continue }
        var v = String(p.dropFirst("boundary=".count)).trimmingCharacters(in: .whitespaces)
        if v.hasPrefix("\""), v.hasSuffix("\""), v.count >= 2 { v = String(v.dropFirst().dropLast()) }
        return v.isEmpty ? nil : v
    }
    return nil
}
```
(`multipart/x-mixed-replace; boundary=frame` → `frame`.)

**`findDelimiter()` — the non-obvious hot path.** memchr-accelerated, advances `scanned` so bytes are never re-examined, but **always leaves `delimiter.count + 1` bytes unscanned** so a marker split across two chunks is still found on the next feed:
```swift
private mutating func findDelimiter() -> Int? {
    let n = delimiter.count
    let tail = n + 2                                   // delimiter + 2 validation bytes
    guard buf.count >= tail else { return nil }
    let first = delimiter[0]
    let last = buf.count - tail
    let start = min(scanned, last + 1)
    var result: Int?
    var newScanned = max(0, buf.count - (tail - 1))
    let streamStart = atStreamStart

    delimiter.withUnsafeBufferPointer { dp in
        buf.withUnsafeBufferPointer { bp in
            let base = bp.baseAddress!
            var i = max(start, 0)
            while i <= last {
                guard let p = memchr(base + i, Int32(first), bp.count - i) else { return }
                let idx = UnsafeRawPointer(p).assumingMemoryBound(to: UInt8.self) - base
                if idx > last { return }
                if memcmp(base + idx, dp.baseAddress!, n) == 0 {
                    let startsLine = (idx == 0 && streamStart) || (idx > 0 && base[idx - 1] == 0x0A)
                    let f0 = base[idx + n], f1 = base[idx + n + 1]
                    let terminated = f0 == 0x0D || f0 == 0x0A || f0 == 0x20 || f0 == 0x09
                        || (f0 == 0x2D && f1 == 0x2D)
                    if startsLine, terminated { result = idx; newScanned = idx; return }
                }
                i = idx + 1
            }
        }
    }
    scanned = newScanned
    return result
}
```

**Header parsing:** lines split on `0x0A`, optional preceding `0x0D` stripped; blank line ends headers and returns `(headers, i + 1)`; keys are **lowercased and trimmed**, values trimmed. If more than **64 KB** accumulates without a blank line → `.malformedHeaders`.

**`emit()` — two independent gates.** The declared type must be an image **AND** the payload must open with SOI (`FF D8`). Reason in-comment: *a gateway that returns a JSON error under `Content-Type: image/jpeg` would otherwise be handed to the decoder ten times a second.*
```swift
let claimsJPEG = ct.contains("image/jpeg") || ct.contains("image/jpg")
if claimsJPEG, body.count >= 2, body[body.startIndex] == 0xFF, body[body.startIndex + 1] == 0xD8 {
    out.append(.frame(body))
} else {
    out.append(.nonImagePart(contentType: ct.isEmpty ? "(none)" : ct, body: body))
}
```

`drop(k)` does `buf.removeFirst(min(k, buf.count))` and `scanned = max(0, scanned - k)`.

#### `inspectJPEG` — header-only size/progressive detection

```swift
struct JPEGInfo { let width: Int; let height: Int; let isProgressive: Bool }  // SOF2
```
Walks JPEG markers to the first SOFn, reading only a few hundred header bytes, **never the entropy-coded data** — microseconds vs. a full decode. Key logic:
- Require `b[0]==0xFF, b[1]==0xD8`, start at `i = 2`.
- If `b[i] != 0xFF` → `i += 1` (resync over fill bytes).
- marker `0xFF` or `0x00` → `i += 1`.
- marker `0xD8` or `0xD0…0xD9` → `i += 2` (standalone, no length).
- `segLen = Int(b[i+2]) << 8 | Int(b[i+3])`.
- If marker in `0xC0…0xCF` **excluding `0xC4` (DHT), `0xC8`, `0xCC` (DAC)** → this is a SOFn: `h = b[i+5]<<8 | b[i+6]`, `w = b[i+7]<<8 | b[i+8]`, `isProgressive = (marker == 0xC2 || marker == 0xCA)`.
- else `if segLen < 2 { return nil }; i += 2 + segLen`.

`isProgressive` is load-bearing: **hardware JPEG decoders commonly reject progressive JPEGs**, so a progressive frame must never take the passthrough path.

---

### 2. `MJPEGStream.swift` §3 — `LatestFrameGate` (the backpressure policy)

A **one-slot mailbox** between the URLSession delegate queue (producer: 10 fps × ~200 KB) and the decode queue (consumer). **LATEST WINS** — if the consumer is still busy when a new frame lands, the older one is discarded, never queued.

Rationale (verbatim): *a live camera has no value in stale frames. A FIFO would (a) grow without bound if decode ever falls behind, at 2 MB/s, and (b) add latency that never recovers, because the producer rate is fixed by the server, not by us. Bounded memory here is exactly 2 frames (~520 KB).*

```swift
func offer(_ frame: Data) {           // called from the URLSession delegate queue; NEVER blocks
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
        handler(next)                 // handler runs OUTSIDE the lock
    }
}
```
Uses `NSLock`. `reset()` clears `pending` and both counters. `deliveredCount`/`droppedCount` are `private(set)` and currently **read nowhere** — diagnostic-only.

---

### 3. `MJPEGStream.swift` §4 — `JPEGFrameBuilder` (JPEG → `CMSampleBuffer`)

Two strategies chosen at runtime: `enum DecodeStrategy { case passthrough, imageIO }`.

**`.passthrough`** wraps the *compressed* JPEG bytes in a `CMSampleBuffer` carrying a `kCMVideoCodecType_JPEG` format description and lets `AVSampleBufferDisplayLayer`'s own VideoToolbox decoder do the work — **no pixels ever touch our address space**. Documented evidence in-comment: verified working on macOS 26 (layer reached `.rendering`, no FailedToDecode notification), and `VTIsHardwareDecodeSupported(kCMVideoCodecType_JPEG)` is true on Apple silicon. **It is NOT documented for iOS**, so it ships behind a self-check that demotes to `.imageIO` on the first decode failure.

**`.imageIO`** decodes with ImageIO into an IOSurface-backed pooled `CVPixelBuffer` at a subsample factor. **Measured on M4 Max with a 172 KB / 1680×1080 frame: 6.19 ms full res, 2.45 ms at subsample 2, 1.69 ms at subsample 4.**

`subsampleFactor: Int` is 1, 2, 4 or 8, driven by `pictureInPictureController(_:didTransitionToRenderSize:)` — Apple's own header says to use it *"in order to avoid unnecessary decoding overhead"*.

Dispatch:
```swift
func makeSampleBuffer(from jpeg: Data, pts: CMTime) -> CMSampleBuffer? {
    guard let info = inspectJPEG(jpeg) else { return nil }
    // Hardware JPEG decoders reject progressive JPEGs; never hand one to the layer.
    if strategy == .passthrough, !info.isProgressive {
        return passthroughBuffer(jpeg, info: info, pts: pts)
    }
    return decodedBuffer(jpeg, pts: pts)
}
```
Note `inspectJPEG` returning nil is also the last-ditch guard that non-JPEG bytes (a text/plain error body that reached the builder via the de-multiplexed path) are silently dropped instead of crashing the decoder.

**Demotion is one-way and idempotent:**
```swift
func demoteToImageIO(reason: String) {
    guard strategy == .passthrough else { return }
    strategy = .imageIO
    formatDescription = nil
    pipLog.warning("JPEG passthrough rejected by AVSampleBufferDisplayLayer (\(reason, privacy: .public)); falling back to ImageIO decode")
}
```
There is no re-promotion path.

**Passthrough construction gotchas:**
- The `CMVideoFormatDescription` is cached and rebuilt only when `(width, height)` changes (`formatDims`).
- The block buffer takes ownership of a **`malloc`'d copy**; `kCFAllocatorMalloc` as `blockAllocator` frees it. On failure the code must `free(bytes)` manually — it does.
- Timing: `CMSampleTimingInfo(duration: CMTime(value: 1, timescale: 10), presentationTimeStamp: pts, decodeTimeStamp: .invalid)` — i.e. a hardcoded **100 ms** duration matching the 10 fps request.

**ImageIO path gotchas:**
```swift
let opts: [CFString: Any] = [
    kCGImageSourceShouldCacheImmediately: true,   // decode now, on THIS queue
    kCGImageSourceShouldCache: false,
    kCGImageSourceSubsampleFactor: max(1, subsampleFactor),
]
```
- Pixel buffer pool is rebuilt when `(w, h)` changes; pool option `kCVPixelBufferPoolMinimumBufferCountKey: 3`.
- **`kCVPixelBufferIOSurfacePropertiesKey: [:]` is MANDATORY** — `AVSampleBufferDisplayLayer`'s header states CVPixelBuffers handed to it must be IOSurface-backed.
- Format `kCVPixelFormatType_32BGRA`; the CGContext uses `bitsPerComponent: 8`, `CGColorSpaceCreateDeviceRGB()`, `CGImageAlphaInfo.noneSkipFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue`, `bytesPerRow: CVPixelBufferGetBytesPerRow(pb)`.
- `CVPixelBufferLockBaseAddress` / `defer { CVPixelBufferUnlockBaseAddress }`.

**`markDisplayImmediately` — applied to every sample buffer on both paths:**
```swift
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
```

---

### 4. `MJPEGStream.swift` §5 — `MJPEGStreamClient` (the URLSession de-multiplexing fix)

#### THE hard-won bug

```swift
// URLSession DE-MULTIPLEXES multipart/x-mixed-replace by itself: every part arrives as its own
// didReceive-response callback carrying that PART's Content-Type, and the bytes that follow are
// the part body alone — boundary framing never reaches the delegate. So the parser below only
// ever runs on platforms/paths that hand us the raw stream; on the normal path these two fields
// do the work. (Rejecting the second callback as "not multipart" is exactly how this first
// failed: the stream connected, then instantly errored on its own first frame.)
private var partBuffer = Data()
private var partExpected: Int?
private var demultiplexed = false
```

So there are **two mutually exclusive receive paths**, selected at runtime by whether a *second* `didReceive response` callback ever arrives on the same task:

- **De-multiplexed path (what actually happens on iOS).** Response #1 = the `multipart/x-mixed-replace` envelope; a `MultipartMJPEGParser` is built but never used. Response #2… N = one per part, each carrying `image/jpeg` and that part's `Content-Length`. Body bytes go to `partBuffer`.
- **Raw path (kept as a fallback).** All bytes flow to `parser.consume(_:)`.

**Both paths are needed and both must survive the port** — deleting the parser would leave nothing if a future OS/proxy stops de-multiplexing, and deleting the demux path reproduces the original instant-failure bug.

#### Response handling

```swift
func urlSession(_ s: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
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
```

Data handling on the demux path — **`Content-Length` saves a whole frame interval of latency**:
```swift
if demultiplexed {
    partBuffer.append(data)
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
```
Otherwise `parser!.consume(data)` and switch on the events: `.frame` → `emitFrame`; `.nonImagePart` → log `pipLog.warning("camera stream sent \(ct) instead of a frame: \(msg)")` with `msg` = first **512 bytes** decoded UTF-8 and trimmed, and `fail(.backendMessage(...))` **only if `!sawFirstFrame`** (*mid-stream: one bad part is not fatal; the idle timeout will catch a real stall*); `.endOfStream` → log `"camera closed the multipart stream"` then `fail(sawFirstFrame ? .transport(URLError(.networkConnectionLost)) : .backendMessage("camera closed the stream before sending a frame"))`.

#### `URLSessionConfiguration` — every setting is deliberate

```swift
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
```

Delegate queue — **serial by construction so the parser needs no locking**:
```swift
let q = OperationQueue()
q.maxConcurrentOperationCount = 1
q.qualityOfService = .userInitiated
q.name = "bambu.mjpeg.net"
```

`start(url:)` calls `stop()` first, clears `parser`/`sawFirstFrame`, sets `req.setValue("no-store", forHTTPHeaderField: "Cache-Control")`, arms the watchdog, logs `pipLog.info("MJPEG connect \(Self.redact(url))")`, then `resume()`. `deinit` does `session?.invalidateAndCancel()`.

#### Never log the token

```swift
/// Never log the raw URL — it carries the camera stream token.
static func redact(_ url: URL) -> String {
    guard var c = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return "<url>" }
    c.queryItems = c.queryItems?.map { $0.name == "token" ? URLQueryItem(name: "token", value: "***") : $0 }
    return c.string ?? "<url>"
}
```

#### First-frame watchdog (default 12 s)

```
// The failure this exists for: during warm-up the backend answers HTTP 200 with correct
// multipart headers, so the socket looks healthy, and then emits either nothing or a single
// text/plain part. Neither a transport error nor an idle timeout necessarily fires. Without
// this the UI waits forever — the exact bug the WebView viewer had to solve with a stall
// watchdog. Two independent detectors: the text/plain part (immediate, in didReceive) and
// this wall-clock deadline (covers "opened and then silent").
```
Implemented as a `DispatchWorkItem` on `DispatchQueue.main.asyncAfter(deadline: .now() + firstFrameTimeout)`; `init(firstFrameTimeout: TimeInterval = 12)`. Cancelled on first frame (`emitFrame`) and in `didCompleteWithError`.

#### Errors and retryability

```swift
enum MJPEGStreamError: LocalizedError {
    case httpStatus(Int)              // "HTTP \(c)"
    case notMultipart(String)         // "expected multipart/x-mixed-replace, got \(ct)"
    case backendMessage(String)       // the warm-up / camera-unavailable case; message passed through
    case noFirstFrame(after: TimeInterval)  // "no JPEG within \(Int(t))s"
    case parse(Error)                 // "stream parse error: \(e.localizedDescription)"
    case transport(Error)             // e.localizedDescription
    case unauthorized                 // "camera stream token rejected"
}
```
```swift
/// The camera is on-demand: warm-up (0.01–1.3 s measured) and self-termination ~7 s after
/// the last viewer both present as recoverable. A 401 needs a fresh token first.
var isRetryable: Bool { /* everything true EXCEPT .unauthorized */ }
```
`401` **and** `403` both map to `.unauthorized` (non-retryable).

#### Redirect hardening

```swift
/// URLSession follows redirects by default and carries only whatever URL the server put in
/// `Location`. If that drops the query string the token is gone and the next hop 401s; if it
/// points off-host the token leaks to a third party. Refuse anything that is not a same-origin
/// redirect, and re-attach the token if the server stripped it.
```
Compares `scheme`, `host`, `port` of `task.originalRequest?.url` against `request.url`; on mismatch logs `"refusing cross-origin redirect from the camera stream"` and calls `completionHandler(nil)` — *deliver the 3xx body instead of following it*. On a same-origin redirect that lost `token`, it copies the original `token` query item onto the new URL.

#### Completion

```swift
func urlSession(_ s: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
    firstFrameDeadline?.cancel(); firstFrameDeadline = nil
    guard let error else {
        delegate?.streamDidFail(.transport(URLError(.networkConnectionLost)))   // infinite stream: clean EOF IS a failure
        return
    }
    if (error as? URLError)?.code == .cancelled { return }   // our own stop()/fail() — not an error
    delegate?.streamDidFail(.transport(error))
}
```

**Known discrepancy to fix or keep consciously:** `flushPart()`'s doc says *"Called when the next part starts and at completion"*, but `didCompleteWithError` does **not** call it — a trailing part with no `Content-Length` is dropped on disconnect. Harmless (the next reconnect supplies fresh frames) but the comment is wrong.

---

### 5. `CameraPiPRenderer.swift` §6 — `PiPBackgroundKeepAlive` (the audio-session trick)

**This is the single least-obvious piece of the whole app.**

```
/// PiP by itself does NOT keep an app out of suspension — an ACTIVE audio session does.
/// (Apple DTS, forums thread 793010: "your app will suspend, because it doesn't have an active
/// audio session keeping it awake.") The camera feed has no audio, so we render silence at a
/// trivial cost while PiP is up, with `.mixWithOthers` so the user's music is untouched.
///
/// Info.plist must carry UIBackgroundModes = ["audio"] ("Audio, AirPlay, and Picture in
/// Picture") or PiP will not even start.
```

`app.json` → `expo.ios.infoPlist.UIBackgroundModes = ["audio"]`. In a native project this is the target's **Background Modes → Audio, AirPlay, and Picture in Picture** capability. **Without it PiP will not start at all**; with it but without an *active* session, PiP starts and then freezes on the last frame once backgrounded.

```swift
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
```
Exact constants that matter: **44 100 Hz, 1 channel, 1-second buffer (44 100 frames), alternating ±0.00003 (≈ −90 dBFS), looping, mixer output volume 0.01, category `.playback` / mode `.moviePlayback` / option `.mixWithOthers`.**

`deactivate()` removes the observer, stops player + engine, and `try? AVAudioSession.sharedInstance().setActive(false, options: [.notifyOthersOnDeactivation])`.

Interruption recovery — **a phone call otherwise kills the whole feature**:
```swift
/// A phone call deactivates our session. If we do not reactivate, the app loses its
/// keep-alive and gets suspended — and the camera dies ~7 s later.
@objc private func handleInterruption(_ n: Notification) {
    guard let raw = n.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
          let type = AVAudioSession.InterruptionType(rawValue: raw) else { return }
    guard type == .ended, started else { return }
    do {
        try AVAudioSession.sharedInstance().setActive(true, options: [])
        if !engine.isRunning { try engine.start() }
        player.play()
    } catch {
        pipLog.error("could not resume keep-alive audio session: \(error.localizedDescription, privacy: .public)")
    }
}
```

---

### 6. `CameraPiPRenderer.swift` §7 — the renderer

```swift
final class CameraPiPRenderer: NSObject, MJPEGStreamClientDelegate,
                               AVPictureInPictureControllerDelegate,
                               AVPictureInPictureSampleBufferPlaybackDelegate {
    let displayLayer = AVSampleBufferDisplayLayer()          // videoGravity = .resizeAspect
    private let client = MJPEGStreamClient()
    private let builder = JPEGFrameBuilder()
    private let keepAlive = PiPBackgroundKeepAlive()
    private var pip: AVPictureInPictureController?
    private var gate: LatestFrameGate!
    private let decodeQueue = DispatchQueue(label: "bambu.mjpeg.decode", qos: .userInitiated)
```

Two notification observers are registered on `init`, both scoped to `object: displayLayer`:
`.AVSampleBufferDisplayLayerFailedToDecode` and `.AVSampleBufferDisplayLayerRequiresFlushToResumeDecodingDidChange`.

**No `controlTimebase` is ever set** — every frame carries `DisplayImmediately` instead.

#### The URL provider indirection

```swift
/// Re-supplied by JS at start so native can re-mint on 401 without waking the JS thread —
/// which is throttled or stopped once the app is backgrounded.
private var makeStreamURL: (@escaping (Result<URL, Error>) -> Void) -> Void = { $0(.failure(URLError(.badURL))) }
```
**Design intent vs. current reality:** `CameraPiPView.restart()` supplies `{ done in done(.success(url)) }` — a *constant* closure. So today the architecture is ready for background re-minting but the RN layer never wires it up; a 401 while backgrounded is unrecoverable until the app is foregrounded. Fixing this is one of the clearest wins of the native rewrite.

#### Connection state machine

State: `stopped: Bool` (starts `true`), `epoch: Int64`, `retryAttempt: Int`, `frameCount: Int`, `probeDeadline: Date?`.

```swift
private func connect() {
    guard !stopped else { return }
    epoch &+= 1
    let myEpoch = epoch
    makeStreamURL { [weak self] result in
        DispatchQueue.main.async {
            guard let self, !self.stopped, self.epoch == myEpoch else { return }   // stale-callback guard
            switch result {
            case .success(let url):
                self.client.delegate = self
                self.probeDeadline = Date().addingTimeInterval(1.5)   // passthrough self-check window
                self.client.start(url: url)
            case .failure(let e):
                pipLog.error("could not build stream URL: \(e.localizedDescription, privacy: .public)")
                self.scheduleReconnect()
            }
        }
    }
}
```
`probeDeadline` is **written and never read** — dead code; drop it in the port (the passthrough self-check is actually driven by the FailedToDecode notification, not a timer).

**Reconnect backoff — fast on purpose:**
```swift
/// The camera self-terminates ~7 s after the last viewer, and cold warm-up is 0.01–1.3 s.
/// So: reconnect FAST (a 5 s backoff would guarantee the camera has already shut down and
/// pay the warm-up again), with a short ceiling.
let delay = min(0.4 * pow(1.6, Double(retryAttempt - 1)), 5.0)
```
Concretely: **0.4, 0.64, 1.024, 1.638, 2.621, 4.194, 5.0, 5.0 …** seconds. `retryAttempt` is reset to 0 on `streamDidBecomeLive()`.

`stop()` sets `stopped = true`, `client.stop()`, `gate.reset()`, `displayLayer.flushAndRemoveImage()`.

#### Delegate callbacks (network queue)

```swift
func streamDidReceiveFrame(_ jpeg: Data) {
    frameCount += 1
    if frameCount % 20 == 0 {                       // ≈ every 2 s at 10 fps
        emit("stats", ["frames": frameCount, "pip": pip?.isPictureInPictureActive == true])
    }
    gate.offer(jpeg)
}
```
`frameCount` exists for a specific diagnostic reason: *a PiP window frozen on one frame is ambiguous — either frames stopped arriving (app suspended) or they arrive and are not rendered. This counter tells the two apart without a device log.*

```swift
func streamDidFail(_ error: MJPEGStreamError) {
    pipLog.error("camera stream failed: \(error.localizedDescription, privacy: .public)")
    emit("error", ["message": error.localizedDescription, "retryable": error.isRetryable])
    guard !stopped else { return }
    // While PiP is up, ALWAYS reconnect: a dead socket means the camera shuts down 7 s later
    // and the floating window freezes with no way for the user to intervene.
    if error.isRetryable || pip?.isPictureInPictureActive == true {
        scheduleReconnect()
    }
}
```
That `|| pip?.isPictureInPictureActive == true` overrides the non-retryable `.unauthorized` case specifically because there is no UI to intervene from inside a PiP window.

`emit(_:_:)` always hops to `DispatchQueue.main.async` before calling `onEvent`.

#### Decode + enqueue (decode queue)

```swift
private func decodeAndEnqueue(_ jpeg: Data) {
    // A layer whose decoder was reclaimed must be flushed before it will accept anything.
    if displayLayer.requiresFlushToResumeDecoding { displayLayer.flush() }
    guard displayLayer.isReadyForMoreMediaData else { return }   // backpressure: drop, never block
    guard let sb = builder.makeSampleBuffer(from: jpeg, pts: CMClockGetTime(CMClockGetHostTimeClock()))
    else { return }
    displayLayer.enqueue(sb)
}
```
PTS source is the **host time clock**, not a monotonic counter.

#### Passthrough self-check / decoder-reclaim recovery

```swift
@objc private func layerFailedToDecode(_ n: Notification) {
    let err = n.userInfo?[AVSampleBufferDisplayLayerFailedToDecodeNotificationErrorKey] as? NSError
    let reason = err.map { "\($0.domain) \($0.code)" } ?? "unknown"
    if builder.strategy == .passthrough {
        builder.demoteToImageIO(reason: reason)
        displayLayer.flush()
    } else {
        pipLog.error("display layer decode failure: \(reason, privacy: .public)")
        displayLayer.flush()
    }
}

@objc private func layerRequiresFlushChanged(_ n: Notification) {
    if displayLayer.requiresFlushToResumeDecoding {
        // Happens when the system revokes video decoder resources — observed after the
        // device has been locked with PiP up for a while. Flushing resets status from
        // .failed back to .unknown so the next enqueue renders.
        displayLayer.flush()
    }
}
```

#### PiP enable/start/stop

```swift
/// MUST be called while the app is in the foreground: PiP cannot be started from the
/// background (Apple DTS, forums thread 793010).
func enablePiP() throws {
    guard AVPictureInPictureController.isPictureInPictureSupported() else { return }
    assert(Thread.isMainThread, "AVPictureInPictureController is main-thread-only")
    // Idempotent: repeated taps must not build a second controller over the same layer.
    if pip != nil { try keepAlive.activate(); return }
    do {
        try keepAlive.activate()                // audio session first, or PiP silently no-ops
        emit("audio", ["ok": true])
    } catch {
        // Not fatal for STARTING PiP, but without it the app suspends when backgrounded and the
        // window freezes on its last frame.
        pipLog.error("keep-alive audio session failed: \(error.localizedDescription, privacy: .public)")
        emit("audio", ["ok": false, "message": error.localizedDescription])
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
```
Asymmetry worth noting: the early-return branch (`pip != nil`) uses `try` **uncaught**, so a repeat tap can throw where the first tap swallows the error. The native version should catch in both branches.

**Ordering is load-bearing: activate the audio session BEFORE constructing the controller, or PiP silently no-ops.**

#### `AVPictureInPictureSampleBufferPlaybackDelegate` (all four methods are required)

```swift
func pictureInPictureController(_ c: AVPictureInPictureController, setPlaying playing: Bool) {
    if playing { if stopped { start(urlProvider: makeStreamURL) } } else { client.stop() }
    c.invalidatePlaybackState()
}

/// Infinite duration == live content: PiP then shows no scrubber and no skip buttons.
func pictureInPictureControllerTimeRangeForPlayback(_ c: AVPictureInPictureController) -> CMTimeRange {
    CMTimeRange(start: .negativeInfinity, duration: .positiveInfinity)
}

func pictureInPictureControllerIsPlaybackPaused(_ c: AVPictureInPictureController) -> Bool { stopped }

func pictureInPictureController(_ c: AVPictureInPictureController,
                                skipByInterval: CMTime, completion: @escaping () -> Void) {
    completion()    // live stream: nothing to seek. Failing to call this wedges the PiP UI.
}
```

**Render-size → subsample mapping** (`1680` is the camera's native width):
```swift
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
```
`subsampleFactor` is only ever mutated on `decodeQueue` — thread confinement, not a lock.

#### `AVPictureInPictureControllerDelegate`

- `pictureInPictureControllerDidStartPictureInPicture` → log `"PiP started"`, `emit("pipStart", [:])`.
- `pictureInPictureController(_:failedToStartPictureInPictureWithError:)` → log, **`keepAlive.deactivate()`**, `emit("pipStop", ["error": error.localizedDescription])`.
- `pictureInPictureControllerDidStopPictureInPicture` → `decodeQueue.async { builder.subsampleFactor = 1 }` (*full resolution again once we are back inline*), `keepAlive.deactivate()`, `emit("pipStop", [:])`.

The audio session is therefore active **only for the lifetime of a PiP session**, never while merely viewing inline.

---

### 7. `CameraPiPView.swift` — the Expo view host (mostly glue, one real behaviour)

```swift
public final class CameraPiPView: ExpoView {
  let renderer = CameraPiPRenderer()
  private let onLive = EventDispatcher()   // + onError, onPipStart, onPipStop, onStats, onAudio
  private var url: URL?
  private var active = false
```
Real behaviour to preserve:
- `backgroundColor = UIColor(white: 0.02, alpha: 1)` (≈ `#050505`) behind the layer.
- `layer.addSublayer(renderer.displayLayer)`.
- Layout — **no implicit animation, or the layer slides into place on every layout pass:**
```swift
public override func layoutSubviews() {
    super.layoutSubviews()
    CATransaction.begin()
    CATransaction.setDisableActions(true)
    renderer.displayLayer.frame = bounds
    CATransaction.commit()
}
```
- **Hot-swap semantics — the most important rule in the file:**
```swift
/// Hot-swap the URL. Deliberately does NOT rebuild the display layer — the camera token refreshes
/// on a timer, and tearing the layer down would take an active PiP window with it.
func setURL(_ next: URL?) { guard next != url else { return }; url = next; if active { restart() } }
func setActive(_ next: Bool) { guard next != active else { return }; active = next; if next { restart() } else { renderer.stop() } }
private func restart() { guard let url else { renderer.stop(); return }; renderer.start { done in done(.success(url)) } }
deinit { renderer.stop() }
```
Both setters are **idempotent-guarded**; a redundant prop write must not restart the stream.

---

### 8. `CameraPiPModule.swift` — pure Expo glue (delete on port), but one comment must survive

```swift
Name("CameraPiP")
Function("isSupported") { AVPictureInPictureController.isPictureInPictureSupported() }
View(CameraPiPView.self) {
  Events("onLive", "onError", "onPipStart", "onPipStop", "onStats", "onAudio")
  Prop("url")    { (view: CameraPiPView, url: URL?) in view.setURL(url) }
  Prop("active") { (view: CameraPiPView, active: Bool) in view.setActive(active) }

  // .runOnQueue(.main) is NOT optional here. Expo runs AsyncFunction bodies on a background
  // queue by default, and every call below is main-thread-only UIKit/AVKit —
  // AVPictureInPictureController construction, the CALayer it wraps, and
  // startPictureInPicture() itself. Off-main this traps, which is what tapping the button did.
  AsyncFunction("startPiP") { (view: CameraPiPView) in
    try view.renderer.enablePiP(); view.renderer.startPiP()
  }.runOnQueue(.main)
  AsyncFunction("stopPiP") { (view: CameraPiPView) in view.renderer.stopPiP() }.runOnQueue(.main)
}
```
The Expo mechanism disappears, but the **hard requirement survives verbatim: every PiP call is main-thread-only and traps off-main** (this was the "PiP crashed because AVKit ran off the main thread" bug, commit `e6239ea`).

`isSupported` gates the toolbar button — *"a button that silently does nothing is worse than no button"*.

---

### 9. The consuming UI (`src/components/Overlays.tsx` → `CameraOverlay`) — must be rebuilt in SwiftUI

Signature: `CameraOverlay({ streamUrl, snapshotUrl, status, cameraHint, onClose, onRefresh, onPipChange })`.

**Phase state machine:** `'connecting' | 'live' | 'failed'`
- Re-armed to `connecting` whenever `streamUrl` changes (token re-mint) or the manual retry counter bumps.
- `onLive` → `live`. `onError` with `retryable === false` → `failed`. Retryable errors are ignored by the UI (the renderer reconnects itself).
- **8000 ms safety net**: if no `streamUrl` ever arrives (token mint hanging/rejecting) no native view exists to report a failure, so a timer forces `failed`.
- **Snapshot fast-fail probe** (comment is the whole rationale): *a disabled H2C camera rejects the SNAPSHOT endpoint deterministically (HTTP 503 in ~60 ms) while its `/stream` returns HTTP 200 whose only multipart part is a text/plain error — the `<img>` never decodes a frame, so without this the overlay sits on "waking…" for the full 40 s watchdog deadline.* **Only a clean HTTP error short-circuits; a probe NETWORK failure proves nothing about the stream path and is ignored.**
- `failedView = phase === 'failed' || (!live && vm.kind === 'offline')` — a known-offline printer shows the actionable card immediately.

**The view is deliberately NOT keyed on `streamUrl`** — remounting would destroy the display layer and take any active PiP window with it. Props passed: `url={streamUrl}`, `active` (always true while mounted), `style={{ flex: 1, backgroundColor: '#060708' }}`.

**Exact chrome** (worth matching in SwiftUI): overlay background `#060708`, `zIndex: 70`. Top bar: 40×40 circular buttons, `borderRadius: 20`, `backgroundColor: 'rgba(22,24,27,0.6)'`, `gap: 11`, `paddingTop: insets.top + 10` (portrait) or `12` (landscape), `paddingBottom: 16`, horizontal 16. Status pill: `rgba(22,24,27,0.55)`, radius 13, padding 13/10, a 7×7 dot in `vm.stateColor`, label `vm.stateLabel` 13pt/600, right-aligned `${vm.progressInt}% · L${vm.layer}` 12pt/600 mono. Buttons in order: landscape toggle (Feather `monitor`/`smartphone`, 17), close (Feather `chevron-down`, 22), status pill, **PiP (MaterialIcons `picture-in-picture-alt`, 17 — Feather has no PiP glyph and "minimize" read as a generic square)**, retry (Feather `refresh-cw`, 18).

Failure card: Feather `video-off` 30 in `#3a4046`; `CHAMBER · NO SIGNAL` mono 11pt letterSpacing 2 in `#3a4046`; body 13pt/19 in `#6b7177`; Retry button 42 tall, radius 12, `rgba(255,255,255,0.08)`. Offline copy: *"Printer is offline. The chamber camera needs the printer powered on and connected to Wi-Fi, then tap Retry."* Otherwise: *"Couldn't wake the chamber camera. {cameraHint ?? 'Give it a moment and tap Retry.'} Make sure the printer is powered on."*

Connecting card: `ActivityIndicator` `#6b7177`; `CONNECTING…` mono 11pt letterSpacing 2; sub-copy 12.5pt/18 in `#4f555b`: *"Waking the chamber camera — the first frame can take a few seconds."*

Live badge (bottom-left, `bottom: insets.bottom + 24`, `paddingHorizontal: 18`): pill `rgba(22,24,27,0.55)` radius 9, 6×6 dot in `c.running`, `LIVE` 10pt/600 letterSpacing 0.5.

**Manual landscape** — the app is portrait-locked in Info.plist and `expo-screen-orientation` isn't installed, so the overlay fakes rotation by transforming itself:
```js
const landscapeStyle = landscape
  ? { width: winH, height: winW, left: (winW - winH) / 2, top: (winH - winW) / 2, transform: [{ rotate: '90deg' }] }
  : { inset: 0 };
```
plus `paddingLeft: (landscape ? insets.top : 0) + 16` because *rotated, the notch/Dynamic Island runs down what is now the left edge*. A manual toggle also keeps working when the phone's own rotation lock is ON.

`onStats` and `onAudio` are still emitted natively but **not rendered** — kept because re-surfacing them for the unresolved frozen-PiP question was a one-line OTA change.

---

### Port notes

| Piece | Native Swift/SwiftUI equivalent | Effort |
|---|---|---|
| `MJPEGParser.swift` | **Copy verbatim.** Zero Expo dependencies. Keep the unit tests. | trivial |
| `MJPEGStream.swift` (`LatestFrameGate`, `JPEGFrameBuilder`, `MJPEGStreamClient`) | **Copy verbatim.** Zero Expo dependencies. | trivial |
| `CameraPiPLog.swift` | Copy; keep `subsystem: "com.mvks5.bambu"`, `category: "camera-pip"`. | trivial |
| `CameraPiPRenderer.swift` | Copy. Replace `var onEvent: ((String, [String: Any]) -> Void)?` with a typed `enum CameraPiPEvent { case live, error(message: String, retryable: Bool), pipStart, pipStop(error: String?), stats(frames: Int, pip: Bool), audio(ok: Bool, message: String?) }` published via `@Published` / `AsyncStream` / a delegate. Everything else — reconnect math, notification observers, PiP delegates, keep-alive — is unchanged. | small |
| `CameraPiPView.swift` | Rewrite as a plain `final class CameraPiPUIView: UIView` (same `layoutSubviews` `CATransaction` trick, same `UIColor(white: 0.02, alpha: 1)`), wrapped in a `UIViewRepresentable`. `EventDispatcher` → the typed event stream. `setURL`/`setActive` become methods on an observable `CameraPiPController`. | small |
| `CameraPiPModule.swift` | **Delete.** `isSupported()` → call `AVPictureInPictureController.isPictureInPictureSupported()` directly. `startPiP`/`stopPiP` → methods on the controller, annotated `@MainActor` (this *replaces* `.runOnQueue(.main)` and is strictly better — the compiler enforces it). | delete |
| `CameraPiP.podspec`, `expo-module.config.json`, `src/index.ts` | **Delete.** Add `AVKit`, `AVFoundation`, `CoreMedia`, `CoreVideo`, `ImageIO` to the app target's linked frameworks. | delete |
| `UIBackgroundModes: ["audio"]` (from `app.json`) | Target → Signing & Capabilities → **Background Modes → Audio, AirPlay, and Picture in Picture**. No config plugin needed anymore. | trivial |
| `useCameraStream.ts` | An `actor`/`@MainActor` `CameraTokenStore`: mint via `POST /api/v1/printers/camera/stream-token`, cache with a 55-minute refresh-ahead against a 60-minute TTL, `Task` with `Timer`/`AsyncTimerSequence` at 60 s. | small |
| `CameraOverlay` in `Overlays.tsx` | A SwiftUI `fullScreenCover` / `ZStack` overlay hosting the `UIViewRepresentable`, with `@State private var phase: Phase`. Reuse the same phase transitions, 8 s no-URL timer, and snapshot probe. | medium |

**Genuinely hard / different natively:**

1. **View identity and PiP survival.** In RN, "don't key the view on `streamUrl`" was the safeguard. In SwiftUI, `UIViewRepresentable` instances get recreated freely, and `makeUIView` can be called again on identity change. **The `CameraPiPRenderer` (and its `AVSampleBufferDisplayLayer` and `AVPictureInPictureController`) must be owned by a long-lived object outside the view tree** — a `@StateObject`/singleton `CameraPiPController` retained at app scope — otherwise dismissing the camera sheet destroys the layer and kills the PiP window. Do **not** put the renderer in `makeUIView`'s local scope. Add `.id()` sparingly and never derive it from the URL.

2. **Native re-mint while backgrounded — fix the gap.** The `makeStreamURL` provider exists exactly so a 401 can be recovered without waking JS, but the RN layer passes a constant closure. Natively, wire it to the real token store: `renderer.start { done in Task { done(await tokenStore.freshURL(printerId:fps:)) } }`. That makes `.unauthorized` recoverable and lets a long PiP session outlive the 60-minute token — the one behaviour the current build cannot do.

3. **Auto-rotation instead of the fake landscape transform.** The RN overlay rotates itself 90° because the app is portrait-locked and `expo-screen-orientation` isn't installed. Natively, either allow landscape for the camera screen (`UISupportedInterfaceOrientations` + per-scene `requestGeometryUpdate`) or keep the manual toggle — but keep the manual toggle *as an option* because it still works when the user's own rotation lock is ON, which auto-rotate does not. Preserve the `paddingLeft: insets.top` correction if the transform approach is kept.

4. **`enablePiP()` must run on the main actor and in the foreground.** Mark it `@MainActor` and, ideally, guard on `UIApplication.shared.applicationState == .active` — PiP cannot be started from the background (Apple DTS forums thread 793010). Keep the `assert(Thread.isMainThread)` as a belt-and-braces `dispatchPrecondition(condition: .onQueue(.main))`.

5. **The layer must be in a *visible* view hierarchy** for `canStartPictureInPictureAutomaticallyFromInline = true` to fire on swipe-home. If SwiftUI ever collapses the representable to zero size (e.g. inside a `.hidden()` or an off-screen tab), auto-PiP silently stops working. Give the hosting view a real non-zero frame whenever `active`.

6. **Swift 6 strict concurrency.** `MJPEGStreamClient` mutates `partBuffer`/`parser`/`sawFirstFrame` from the URLSession `OperationQueue` while the first-frame watchdog fires on `DispatchQueue.main` and touches `sawFirstFrame` + `task`. Under `-strict-concurrency=complete` this needs an explicit `@unchecked Sendable` with a documented queue-confinement invariant, or (cleaner) move the watchdog onto the same `delegateQueue`'s underlying serial queue. Same for `CameraPiPRenderer.frameCount` (incremented on the network queue, read in `emit`). This is the one place where a verbatim copy will fight the compiler.

7. **Don't "simplify" away the dual receive path.** The de-multiplexed path is the one that runs; the `MultipartMJPEGParser` looks dead on a device and is very tempting to delete. It is the fallback for any environment that hands over raw bytes, and it carries all the boundary-splitting correctness. Keep both, keep the tests.

8. **Dead code to drop deliberately:** `CameraPiPRenderer.probeDeadline` (written, never read) and `LatestFrameGate.deliveredCount`/`droppedCount` (unless you surface them in a debug HUD, which the `onStats` comment suggests would be useful).

9. **Fix on the way through:** `flushPart()` is documented as running "at completion" but `didCompleteWithError` never calls it; and `enablePiP()`'s `pip != nil` fast path lets `keepAlive.activate()` throw while the slow path catches. Both are one-liners.
