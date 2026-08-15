import os

// Shared plumbing for the two viewer pages.
//
// In `Domain/` because BOTH platforms host the same WKWebView pages — iOS through
// `LayerViewerOverlay`/`StlViewerOverlay`, macOS through the viewer window (1g). This lived in
// `StlViewerOverlay.swift`, which is `#if os(iOS)`, so the Mac host could not name the events its
// own bridge delivers. Same trap as `LibraryBrowse` and `firstResolvingURL`: nothing here is a view
// or a platform, it was simply filed next to one.

/// Both viewers log here. Shared rather than file-private because a failure in either one is the
/// same question — "which URL did the page actually ask for?" — and it should read the same way.
let viewerLog = Logger(subsystem: "com.mvks5.bambu", category: "viewer")

/// What a viewer page reports back over the JS bridge.
enum ViewerEvent: Equatable {
    /// Layer viewer finished parsing and drew its first frame.
    case ready(hasSupport: Bool)
    /// STL viewer finished parsing the mesh.
    case loaded(tris: Int)
    /// Download / parse / WebGL failure. The page renders its own message too.
    ///
    /// `status` is the HTTP status of the in-page fetch when that is what failed, and 0 for a parse
    /// or WebGL failure. It is carried separately from the message because the caller has to ACT on
    /// it: 401/403 on the STL page means the one-shot download token was spent or aged out, which is
    /// recoverable by minting another, while 404 means the URL had the wrong shape and re-minting
    /// would rebuild the same broken URL.
    case failed(String, status: Int)
}


/// Hosts a viewer page and relays its `postMessage` traffic.
///
/// `baseURL` is load-bearing, not cosmetic — see the file header.
