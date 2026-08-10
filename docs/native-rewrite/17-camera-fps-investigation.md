# Investigation brief: chamber camera frame rate

Hand this to a fresh session. It is written to be self-contained — you should not need to read the
conversation it came from.

## The report

PiP (picture-in-picture) on the chamber camera activates and shows moving video, but the frame rate
is "fairly low". The question is whether that is the source, the transport, or the app's display
path — and then whether it can be improved.

## Ground truth about the system

- Printer: Bambu Lab **H2C**, China-market, printer id **2** in Bambuddy.
- Camera is **RTSP**, port 322, multiplexed by Bambuddy into an HTTP
  `multipart/x-mixed-replace; boundary=frame` stream at
  `GET /api/v1/printers/{id}/camera/stream?token=<camera-stream-token>&fps=<n>`.
- That endpoint is gated by a **camera stream token** in the query, NOT the API key. Mint one with
  `POST /api/v1/printers/camera/stream-token`. The API key is rejected with 401 there.
- The camera is **on-demand**: it starts when a viewer attaches and self-terminates ~7 s after the
  last one detaches. **Cold warm-up is several seconds** — this matters enormously, see below.
- Bambuddy runs in docker on the home server (`ssh gem`, container `bambuddy`, port 8910). The API
  key is at `<secrets-dir>/bb_apikey` on that host. **Never print it.**
- The app's renderer is `native/Sprout/Camera/` — `MJPEGStream.swift` (parser + URLSession client),
  `CameraPiPRenderer.swift` (decode → `AVSampleBufferDisplayLayer` → PiP). The dashboard tile and
  the fullscreen overlay each drive one; the tile stands down whenever an overlay is up, so they do
  not compete for the camera.

## What is established

1. **The camera is healthy.** `POST /api/v1/printers/2/camera/diagnose` returns
   `overall_status: ok`, `summary_code: live_stream_active_healthy`.
2. **Restarting Bambuddy changes nothing** — measured identically before and after, byte for byte.
   So it is not a wedged capture loop.
3. **The chamber light was on** during the slow measurements, so a low-light long-exposure
   explanation is ruled out.
4. **The `fps` query parameter appeared to have no effect** — 10, 20 and 30 all produced the same
   result. Treat this as *suspected but not proven*, because the measurement it rests on is flawed
   (below).
5. **The app has itself sustained ~10 fps.** Its own frame counter logged
   `camera frames=400 rate=10.0/s` over 40+ seconds, and separately a 20-second server-side capture
   yielded 187 frames (~9.4 fps) with textbook framing. So ~10 fps is achievable on this hardware
   and this path.

## Measurement errors already made — do not repeat them

The previous session reached three confident wrong conclusions about this camera. They are recorded
because the failure mode is the interesting part.

1. **"Cloudflare buffers the stream."** A `curl` through the public host returned 0 bytes while
   `localhost` streamed fine. Apparently decisive — but the test ran while the app was retry-storming
   and had piled up six subscribers, starving the camera for every client. The symptom was measuring
   the bug. Healthy, the public host streams ~27 MB in 12 s however you ask for it. **The proxy was
   never involved.**
2. **"Zero frames reach the renderer."** The app's frame counter appeared to read nothing, which
   pointed at the display layer. It logs at `info` level, and `log show` drops `info` unless you pass
   `--info`. The frames were there all along.
3. **"The source is stuck at 2.0 fps."** Every such reading was `20 frames in 10 s`, suspiciously
   exact. The window was 10 s and the camera's cold warm-up is ~7 s, so ~70 % of each measurement was
   the camera waking up. A follow-up 40-second run then returned **zero** frames while `diagnose`
   reported healthy — at which point the instrument, not the source, is clearly the problem. Repeated
   open-and-abandon connections were reproducing by hand exactly the subscriber churn the app had
   just been fixed for.

**The lesson to carry in: when a diagnostic contradicts a working control case, suspect the
diagnostic.** And check the log level before concluding anything from silence.

## The right instrument

Measure from **inside the app**, not with `curl`. `CameraPiPRenderer.streamDidReceiveFrame`
increments a counter and logs every 100 frames:

```
camera frames=<n> rate=<x>/s
```

That counts frames actually decoded and displayed, over a long window, with no warm-up
contamination. Read it with:

```bash
xcrun simctl spawn <udid> log show --last 5m --info \
  --predicate 'subsystem == "com.mvks5.bambu"' --style compact | grep "camera frames"
```

`--info` is **required** or the lines are silently dropped. On a physical device the same log comes
from Console.app or `idevicesyslog`.

If you do measure server-side, the window must be **≥ 30 s**, you must discount the warm-up, and you
must let the previous connection fully detach (watch
`docker logs bambuddy | grep subscriber` reach 0) before opening the next.

## The question to answer, in order

1. **What rate does the app actually achieve while PiP is up?** Open the fullscreen camera, start
   PiP, background the app, and read the counter over a couple of minutes.
   - **~10/s while PiP looks choppy** → the source is fine and the bottleneck is the PiP display
     path. Investigate: whether the JPEG decode took the hardware `.passthrough` path or demoted to
     `.imageIO` (the renderer logs this); whether `AVSampleBufferDisplayLayer` is dropping frames
     under PiP; and whether `LatestFrameGate` is discarding more than it delivers (it exposes
     `deliveredCount` / `droppedCount` — surface them).
   - **~2/s** → the source genuinely degraded. Then establish whether the `fps` parameter is honoured
     at all, whether the RTSP source rate varies with printer state, and whether frame SIZE moves
     inversely with rate (260 KB/frame was observed at the slow rate vs 174 KB/frame at ~9.4 fps,
     which would suggest a resolution or quality mode change rather than a throughput limit).
2. **Only once (1) is answered**, decide whether there is anything worth optimising app-side.

## Constraints

- Do not change app behaviour to "fix" this until the bottleneck is identified. Two of the three
  wrong conclusions above led to real code changes; one was a genuine bug fix by luck, the other was
  wasted work.
- Do not restart Bambuddy again — it has been tried and made no difference, and it interrupts print
  monitoring.
- Never print, log or embed the API key, the camera token, or the owner's hostnames.
- The app is installed on the simulator (`B0E42F7D-F839-4F87-87C3-8734EDF54067`, iOS 27) and on the
  owner's physical iPhone. **PiP does not work on the simulator** —
  `AVPictureInPictureController.isPictureInPictureSupported()` is false there — so anything about PiP
  specifically must be measured on the device.
