import os

/// The camera subsystem's log — the MJPEG parser and stream on both platforms, plus the iOS PiP
/// renderer and the macOS camera window.
///
/// Was `cameraLog` in `CameraPiPLog.swift`, guarded to iOS along with the rest of `CameraPiP*`. That
/// was wrong twice over: it is a plain `Logger` with no platform in it, and its main callers
/// (`MJPEGStream`, `MJPEGParser`) are explicitly reused unchanged on macOS, where there is no PiP
/// for it to be named after.
let cameraLog = Logger(subsystem: "com.mvks5.bambu", category: "camera")
