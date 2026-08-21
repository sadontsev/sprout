#if os(iOS)
// Overlays are a fullScreenCover idiom. macOS uses sheets and windows (§7).
// Compiled for iOS only — see docs/native-rewrite/18-mac-port-architecture.md.
import SwiftUI
import UIKit
import WebKit
import os

// The two model viewers are deliberately NOT native renderers. They are the same self-contained
// HTML/JS pages the app has always shipped, hosted in a WKWebView:
//
//  - Parsing a 70 MB G-code file or a 1 M-triangle STL is FASTER in JavaScriptCore than anywhere a
//    Swift port could reach without a week of `UnsafeRawBufferPointer` work, because the page also
//    feeds the parsed floats straight into GPU buffers with no copy in between.
//  - The pages carry zero CDN imports, so they work with no internet at all.
//  - The bytes never cross into Swift: the page fetches its own payload from the server.
//
// The one structural requirement: the document must be loaded ON the Bambuddy origin. Bambuddy
// sends no CORS headers, so a page loaded from `about:blank` or a file URL has its in-page fetch
// blocked outright. `loadHTMLString(_:baseURL:)` with the server origin is what makes it same-origin.


struct ViewerWebView: UIViewRepresentable {
    let html: String
    let baseURL: URL
    let onEvent: (ViewerEvent) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(onEvent: onEvent) }

    func makeUIView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.defaultWebpagePreferences.allowsContentJavaScript = true
        config.userContentController.addUserScript(
            WKUserScript(source: ViewerJS.bridge, injectionTime: .atDocumentStart, forMainFrameOnly: true)
        )
        config.userContentController.add(context.coordinator, name: ViewerJS.bridgeName)

        let web = WKWebView(frame: .zero, configuration: config)
        web.isOpaque = false
        web.backgroundColor = UIColor(Palette.dark.bg)
        web.scrollView.backgroundColor = UIColor(Palette.dark.bg)
        web.scrollView.isScrollEnabled = false
        web.scrollView.bounces = false
        web.scrollView.contentInsetAdjustmentBehavior = .never
        // Both pages implement pinch themselves out of `touchmove` + `preventDefault`, and pinch is
        // fused with two-finger pan in a single branch. Leaving the scroll view's own pinch
        // recognizer enabled lets WKWebView eat the second finger before the DOM ever sees it.
        web.scrollView.pinchGestureRecognizer?.isEnabled = false
        web.allowsBackForwardNavigationGestures = false
        web.loadHTMLString(html, baseURL: baseURL)
        return web
    }

    func updateUIView(_ uiView: WKWebView, context: Context) {
        // Only the callback is refreshed. Re-loading would restart a 70 MB download and, for the
        // STL page, spend a download token that is single-use.
        context.coordinator.onEvent = onEvent
    }

    static func dismantleUIView(_ uiView: WKWebView, coordinator: Coordinator) {
        // Closing mid-download has to actually stop the transfer, and the content controller holds a
        // strong reference to the coordinator until the handler is removed.
        uiView.stopLoading()
        uiView.configuration.userContentController.removeScriptMessageHandler(forName: ViewerJS.bridgeName)
        uiView.configuration.userContentController.removeAllUserScripts()
    }

    @MainActor
    final class Coordinator: NSObject, WKScriptMessageHandler {
        var onEvent: (ViewerEvent) -> Void

        init(onEvent: @escaping (ViewerEvent) -> Void) {
            self.onEvent = onEvent
        }

        func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
            guard
                let json = message.body as? String,
                let data = json.data(using: .utf8),
                let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
            else { return }

            switch obj["type"] as? String {
            case "error":
                onEvent(.failed(
                    (obj["message"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? "render error",
                    status: obj["status"] as? Int ?? 0
                ))
            case "ready":
                onEvent(.ready(hasSupport: obj["hasSupport"] as? Bool ?? false))
            case "loaded":
                onEvent(.loaded(tris: obj["tris"] as? Int ?? 0))
            default:
                break
            }
        }
    }
}

// MARK: - Shared chrome



// MARK: - STL page


/// Where the STL page pulls its mesh from.
enum StlSource: Equatable {
    /// A library file. The page fetches a tokenized download URL where the TOKEN IS THE AUTH, so
    /// the in-page fetch needs no headers. That token is single-use and short-lived.
    case library(fileId: Int, name: String)
    /// An arbitrary same-origin path (e.g. a texturize preview parked on the slicer sidecar), with
    /// optional auth headers for the in-page fetch.
    case direct(origin: String, path: String, name: String, headers: [String: String])
}


// MARK: - Views

/// The STL viewer without chrome, so it can also be embedded inline (the print wizard's step-1
/// preview passes `compact: true`, which hides the page's own control card).
///
/// For a library file this first mints a tokenized download URL, then hands the page a URL it can
/// fetch with no headers at all. The mesh bytes never enter Swift.
struct StlModelView: View {
    let model: AppModel
    let source: StlSource
    var compact = false

    @State private var page: String?
    /// The absolute URL handed to the page, kept so a failure can be logged as the URL that was
    /// actually asked for rather than the one the reader assumes it was.
    @State private var pageUrl: String?
    @State private var failure: String?
    @State private var loaded = false
    @State private var attempt = 0
    /// One automatic re-mint has already been spent on this file.
    @State private var reminted = false

    var body: some View {
        ZStack {
            if let page, failure == nil {
                ViewerWebView(html: page, baseURL: documentBase, onEvent: handle)
                    .id(attempt)
            }
            if let failure {
                ViewerFailure(icon: "cube", message: failure, compact: compact, onRetry: retry)
            } else if !loaded {
                ViewerLoading(label: "LOADING MODEL…", compact: compact)
            }
        }
        .background(Palette.dark.bg)
        .task(id: attempt) { await build() }
    }

    private var documentBase: URL {
        switch source {
        case .library: ViewerJS.documentBase(of: model.client?.baseUrl ?? "")
        case .direct(let origin, _, _, _): ViewerJS.documentBase(of: origin)
        }
    }

    private func build() async {
        guard page == nil, failure == nil else { return }

        switch source {
        case .direct(let origin, let path, let name, let headers):
            // Resolve against the document base HERE rather than leaving a bare path for the page to
            // resolve. Two reasons: the page's own resolution silently depended on the base keeping
            // its path prefix (it did not), and a relative URL cannot be logged when it fails —
            // whatever the page fetched would be a guess.
            guard let resolved = URL(string: path, relativeTo: ViewerJS.documentBase(of: origin))?.absoluteURL else {
                failure = "That preview URL isn’t valid."
                return
            }
            pageUrl = resolved.absoluteString
            page = StlPage.html(url: resolved.absoluteString, name: name, compact: compact, headers: headers)

        case .library(let fileId, let name):
            guard let client = model.client else {
                failure = "Not connected to Bambuddy."
                return
            }
            do {
                // Minted once per attempt: the slicer token is single-use and short-lived, so a
                // second mint on a re-render would hand the page a URL the first one already spent.
                //
                // The name is only a Content-Disposition courtesy to the server, but it lands in a
                // PATH SEGMENT, so it has to be reduced to something that can be one — see
                // `LibraryDownloadName`.
                let safeName = LibraryDownloadName.pathSegment(name, fallback: "model-\(fileId).stl")
                let url = try await client.mintFileDownloadUrl(fileId, filename: safeName)
                guard !Task.isCancelled else { return }
                pageUrl = url.absoluteString
                page = StlPage.html(url: url.absoluteString, name: name, compact: compact, headers: [:])
            } catch let e as BambuddyError {
                failure = e.detail
            } catch {
                failure = error.localizedDescription
            }
        }
    }

    private func handle(_ event: ViewerEvent) {
        switch event {
        case .loaded: loaded = true
        case .ready: break
        case .failed(let message, let status):
            viewerLog.error("STL page failed (HTTP \(status, privacy: .public)) on \(ViewerJS.loggableUrl(self.pageUrl ?? "<no url>"), privacy: .public) — \(message, privacy: .public)")
            // A spent or expired one-shot token answers 401/403. The page CAN be re-run on the same
            // token without the app asking — WebKit reloads it after a content-process recycle — so
            // treating that as terminal strands a perfectly good file behind a dead credential.
            // Mint another and reload, exactly once: 404 is deliberately excluded because it means
            // the URL's shape is wrong and a fresh token would rebuild the same broken URL.
            if !reminted, isTokenRejection(status), case .library = source {
                reminted = true
                viewerLog.notice("STL page: re-minting a download token after HTTP \(status, privacy: .public)")
                rebuild()
                return
            }
            failure = message
        }
    }

    private func isTokenRejection(_ status: Int) -> Bool { status == 401 || status == 403 }

    /// A fresh attempt has to re-mint — the previous token is gone either way.
    private func rebuild() {
        page = nil
        pageUrl = nil
        failure = nil
        loaded = false
        attempt += 1
    }

    /// The manual Retry. Unlike the automatic one it also re-arms the automatic re-mint, because the
    /// user asking again is a new decision, not the same attempt continuing.
    private func retry() {
        reminted = false
        rebuild()
    }
}

/// Full-screen interactive STL preview for a library file: flat-shaded WebGL mesh with orbit, pinch
/// zoom, two-finger pan and double-tap reset, plus Steel / Ivory / Normals / Light-bg chips.
/// Opens on Ivory, matching the near-white the server renders library thumbnails in.
struct StlViewerOverlay: View {
    let model: AppModel
    let file: LibraryFile

    var body: some View {
        ZStack(alignment: .top) {
            Palette.dark.bg.ignoresSafeArea()

            StlModelView(model: model, source: .library(fileId: file.id, name: title))
                .ignoresSafeArea()

            ViewerTopBar(title: title) { model.overlay = nil }
        }
        .preferredColorScheme(.dark)
    }

    /// Library names arrive percent-encoded often enough that the raw string is unreadable; a
    /// malformed escape decodes to nil, in which case the raw name is still better than nothing.
    private var title: String {
        let raw = [file.printName ?? "", file.filename].first { !$0.isEmpty } ?? "file-\(file.id)"
        return raw.removingPercentEncoding ?? raw
    }
}
#endif
