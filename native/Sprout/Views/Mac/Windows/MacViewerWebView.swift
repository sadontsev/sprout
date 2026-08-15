#if os(macOS)
import AppKit
import SwiftUI
import WebKit
import os

// The AppKit host for the two viewer pages, and nothing else.
//
// The PAGES are shared with iOS byte for byte — `LayerPage.html` and `StlPage.html` build a
// self-contained document that downloads and parses its OWN payload. The long comment at the top of
// `StlViewerOverlay.swift` explains why that is not a native renderer and must not become one; the
// one structural requirement it names is repeated here because it is easy to break by accident:
// **the document has to be loaded on the Bambuddy origin.** Bambuddy sends no CORS headers, so a
// page loaded from `about:blank` or a file URL has its in-page fetch refused outright.
//
// So the only thing that forks per platform is the WKWebView host, and this file is the twin of
// `ViewerWebView` (`StlViewerOverlay.swift:48`). It mirrors that type's behaviour deliberately:
// same configuration, same bridge, same "update refreshes only the callback", same teardown.
//
// Two things are here that the iOS host does not need, both because a Mac has no fingers:
//
//  - `injectedCSS`, which is how the Mac window hides the page's own control card. On iOS the card
//    IS the chrome; on macOS the 236 pt sidebar of `1g` owns the scrubber, so the card would be a
//    second set of the same controls that can drift out of sync with it.
//  - `adaptsMouseToTouch`, because `StlPage` listens for `touchstart`/`touchmove`/`touchend` and
//    for nothing else. `LayerPage` has mouse and wheel handlers ("trackpad use AND headless
//    testing"); the STL page never grew them, so without this the mesh cannot be orbited or zoomed
//    with a mouse at all.

// MARK: - Driving the page from Swift

/// A handle on the hosted page, so the window's sidebar can operate controls that live inside it.
///
/// The alternative — forking the pages so the Mac's controls are native — is the thing the whole
/// design refuses. Clicking the page's own `.chip` elements and dispatching an `input` on its own
/// `<input type=range>` means there is still exactly ONE implementation of "what does Ivory do",
/// and it is the one iOS ships.
@MainActor
final class MacViewerPageHandle {
    /// Weak: the web view is owned by the view hierarchy, and the handle outlives a mode switch.
    fileprivate weak var web: WKWebView?

    /// True once a page has been hosted. `nil` web with `wasAttached == false` means "no page yet",
    /// which is a different situation from "the page went away" — the sidebar disables its controls
    /// for both, but a caller that needs to tell them apart can.
    private(set) var wasAttached = false

    fileprivate func attach(_ web: WKWebView) {
        self.web = web
        wasAttached = true
    }

    fileprivate func detach() {
        web = nil
    }

    /// Send a command to the page and discard the result.
    ///
    /// **Every snippet must evaluate to a value.** The async `evaluateJavaScript` overload is typed
    /// `-> Any` and its generated thunk force-unwraps the ObjC completion's result, so a script that
    /// evaluates to `undefined` traps rather than returning nil. Every builder in `MacViewerJS`
    /// therefore ends in an explicit `true` / object / `null`; `null` is fine because it bridges to
    /// `NSNull`, not to nil.
    ///
    /// **Nothing here hands an `Any` back to its caller, and that is not a style choice.** Under
    /// `SWIFT_STRICT_CONCURRENCY: complete` an `Any` cannot cross an isolation boundary at all, and
    /// a SwiftUI `View`'s own methods are not automatically main-actor-isolated — so a returned
    /// `Any?` compiles here and fails at every call site. It is the same lesson CLAUDE.md records
    /// against the camera renderer: decode to a typed `Sendable` value on the side that receives it.
    func run(_ js: String) async {
        guard let web else { return }
        do {
            _ = try await web.evaluateJavaScript(js)
        } catch {
            // Only reached for a script the page rejected — a torn-down web view returns above, so
            // this is never the noise of a mode switch racing a command.
            viewerLog.error("Viewer command failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Everything the layer sidebar needs, decoded here so only the typed value leaves.
    func layerStats() async -> MacLayerStats? {
        guard let web else { return nil }
        return MacLayerStats(try? await web.evaluateJavaScript(MacViewerJS.layerStats))
    }
}

// MARK: - What the page knows

/// The facts the layer sidebar shows that only the parsed page can answer.
///
/// Lives beside `MacViewerJS.layerStats`, which is the one thing that produces it: the JS and the
/// decode are two halves of one wire format and drift the moment they are read apart.
struct MacLayerStats: Equatable, Sendable {
    var total: Int
    /// Z of every layer, bottom first — the source of the "Z 25.60 MM" readout.
    ///
    /// Pulled across whole, once, rather than asked for per step: playback advances up to 24 layers
    /// a second and a round trip per frame would be 24 evaluations a second for a fixed number.
    var zs: [Double]
    /// Z of the topmost layer, i.e. the printed height.
    var topZ: Double
    /// Smallest positive gap between consecutive layers.
    var minGap: Double
    /// Largest. Differs from `minGap` on a variable-height slice, where a single "0.20 mm" would be
    /// a number the file does not contain.
    var maxGap: Double

    init?(_ raw: Any?) {
        guard let d = raw as? [String: Any] else { return nil }
        let zs = (d["zs"] as? [Any])?.compactMap { ($0 as? NSNumber)?.doubleValue } ?? []
        let total = (d["total"] as? NSNumber)?.intValue ?? zs.count
        guard total > 0 else { return nil }
        self.total = total
        self.zs = zs
        topZ = (d["topZ"] as? NSNumber)?.doubleValue ?? 0
        minGap = (d["minGap"] as? NSNumber)?.doubleValue ?? 0
        maxGap = (d["maxGap"] as? NSNumber)?.doubleValue ?? 0
    }

    /// Z of layer `n` (1-based), or nil where the page reported no heights.
    func z(at n: Int) -> Double? {
        guard n >= 1, n <= zs.count else { return nil }
        return zs[n - 1]
    }

    /// "0.20 mm", or the range when the slice is variable-height.
    var layerHeightText: String {
        guard minGap > 0 else { return "—" }
        // 5 µm: below any real difference between two nominally identical layer heights, and well
        // above float noise.
        if maxGap - minGap > 0.005 {
            return String(format: "%.2f–%.2f mm", minGap, maxGap)
        }
        return String(format: "%.2f mm", minGap)
    }
}

// MARK: - The snippets

/// The JavaScript the Mac host injects or evaluates.
///
/// Kept in one place, and kept SMALL, on purpose: everything here is host-side adaptation. The
/// moment one of these grows into rendering or parsing it belongs in the page, where iOS gets it
/// too — see the note at the top of this file.
enum MacViewerJS {

    // MARK: Reading the page

    /// Everything the sidebar needs that only the page knows, in ONE round trip.
    ///
    /// `zs` and `b` are `var`s at the page script's top level, so they are genuinely global by the
    /// time `boot()` has assigned them. The whole `zs` array is pulled across once rather than
    /// asking for `zs[n-1]` per step: playback steps up to 24 layers a second and a round trip per
    /// frame would be 24 evaluations a second for a number that never changes.
    static let layerStats = """
    (function () {
      var s = document.getElementById('s');
      if (!s) return null;
      var zs = (window.zs && window.zs.length) ? Array.prototype.slice.call(window.zs) : [];
      var total = parseInt(s.max, 10) || zs.length;
      var top = zs.length ? zs[zs.length - 1] : 0;
      if (window.b && typeof b.maxZ === 'number' && isFinite(b.maxZ)) top = Math.max(top, b.maxZ);
      var mn = Infinity, mx = 0;
      for (var i = 1; i < zs.length; i++) {
        var d = zs[i] - zs[i - 1];
        // 1e-4 discards float noise between two nominally identical Z values, exactly as
        // GcodeScene's own gap scan does.
        if (d > 1e-4) { if (d < mn) mn = d; if (d > mx) mx = d; }
      }
      return { total: total, topZ: top, minGap: isFinite(mn) ? mn : 0, maxGap: mx, zs: zs };
    })();
    """

    // MARK: Writing to the page

    /// Move the layer viewer to layer `n` (1-based), through the page's own slider.
    ///
    /// The slider is the page's only entry point for this: `cur` is a local inside `boot()`, and the
    /// `input` listener is what recomputes the label and schedules a frame. Setting `.value` alone
    /// changes nothing, which is why the event is dispatched explicitly.
    static func setLayer(_ n: Int) -> String {
        """
        (function () {
          var s = document.getElementById('s');
          if (!s) return false;
          s.value = String(\(n));
          s.dispatchEvent(new Event('input'));
          return true;
        })();
        """
    }

    /// Click one of the page's own shading / background chips by its `data-m` value.
    ///
    /// Matched by attribute in a loop rather than through a `querySelector` with an interpolated
    /// attribute selector, so the value goes through `ViewerJS.literal` and cannot break out of the
    /// selector or the script.
    static func clickChip(_ chip: String) -> String {
        """
        (function () {
          var want = \(ViewerJS.literal(chip));
          var cs = document.querySelectorAll('.chip');
          for (var i = 0; i < cs.length; i++) {
            if (cs[i].getAttribute('data-m') === want) { cs[i].click(); return true; }
          }
          return false;
        })();
        """
    }

    /// Click the page's own reset-view button. It is hidden by `viewerChromeCSS` / `compact: true`,
    /// and `HTMLElement.click()` does not care whether an element is displayed.
    static let resetView = """
    (function () {
      var r = document.getElementById('reset');
      if (!r) return false;
      r.click();
      return true;
    })();
    """

    // MARK: Injected at document start

    /// Hides the page's own floating chrome, and gives the canvas back the space it reserved for it.
    ///
    /// The second rule is the load-bearing one. `LayerPage` keeps `RESERVE = 150` px clear at the
    /// bottom for its control card and centres the model in `(height - RESERVE)`. Hiding the card
    /// does not change that constant — it is baked into `fit()` — so the print would sit 75 px above
    /// the middle of an otherwise empty canvas. Growing both canvases by exactly the reserve puts
    /// the centre back where the viewer can see it; the extra strip hangs below the viewport, which
    /// `body{overflow:hidden}` clips.
    ///
    /// `#c` and `#cg` set `top` and `bottom` together, so an explicit height over-constrains the box
    /// and `bottom` is the edge CSS drops — i.e. it grows downward, which is what this needs.
    ///
    /// TODO(LayerPage): `RESERVE` should be measured off `#bar` rather than assumed, at which point
    /// the second rule here can go.
    static let viewerChromeCSS = """
    #bar, #reset { display: none !important; }
    #c, #cg { height: calc(100% + 150px) !important; }
    """

    /// Wraps a stylesheet in the user script that installs it.
    static func styleInjector(_ css: String) -> String {
        """
        document.addEventListener('DOMContentLoaded', function () {
          var s = document.createElement('style');
          s.textContent = \(ViewerJS.literal(css));
          document.head.appendChild(s);
        });
        true;
        """
    }

    /// Feeds macOS mouse and wheel input into a page that only listens for touches.
    ///
    /// `StlPage` binds `touchstart` / `touchmove` / `touchend` on its canvas and nothing else, so on
    /// a Mac its mesh is a still image. The handlers are duck-typed — they read `e.touches.length`,
    /// `e.touches[i].clientX/clientY` and call `e.preventDefault()` — so a plain object with those
    /// members drives them exactly as a real `TouchEvent` would. That matters, because macOS WebKit
    /// has no constructible `TouchEvent` to synthesise.
    ///
    /// Installed ONLY for the mesh page. `LayerPage` already has mouse and wheel handlers of its
    /// own, and adding these on top would rotate it twice per drag.
    ///
    /// The wheel branch fakes a pinch: one synthetic two-finger touch whose span grows and shrinks
    /// around a midpoint fixed at gesture start. Fixed, because the page's pan rides along with the
    /// pinch — a midpoint that followed the cursor would pan the model every time the user scrolled.
    ///
    /// TODO(StlPage): the real fix is mouse + wheel handlers in the page, the way `LayerPage` has
    /// them; then this goes away and iOS is unaffected either way.
    static let mouseToTouch = """
    (function () {
      var add = EventTarget.prototype.addEventListener;
      EventTarget.prototype.addEventListener = function (type, fn, opts) {
        add.call(this, type, fn, opts);
        if (!(this instanceof HTMLCanvasElement)) return;
        if (type !== 'touchstart' && type !== 'touchmove' && type !== 'touchend') return;
        this['__sprout_' + type] = fn;
        if (this.__sproutWired) return;
        this.__sproutWired = true;

        var el = this, dragging = false;
        var pinchTimer = null, pinchSpan = 0, pinchX = 0, pinchY = 0;
        function noop() {}
        function fire(name, touches) {
          var fn = el['__sprout_' + name];
          if (fn) fn({ touches: touches, preventDefault: noop });
        }
        function one(e) { return [{ clientX: e.clientX, clientY: e.clientY }]; }
        function two() {
          return [
            { clientX: pinchX - pinchSpan / 2, clientY: pinchY },
            { clientX: pinchX + pinchSpan / 2, clientY: pinchY }
          ];
        }

        el.addEventListener('mousedown', function (e) {
          dragging = true;
          fire('touchstart', one(e));
        });
        // On window, not on the canvas: a drag that leaves the canvas must keep orbiting, and must
        // still end when the button is released outside it.
        add.call(window, 'mousemove', function (e) {
          if (dragging) fire('touchmove', one(e));
        }, false);
        add.call(window, 'mouseup', function () {
          if (!dragging) return;
          dragging = false;
          fire('touchend', []);
        }, false);

        el.addEventListener('wheel', function (e) {
          e.preventDefault();
          if (pinchTimer === null) {
            pinchSpan = 200; pinchX = e.clientX; pinchY = e.clientY;
            fire('touchstart', two());
          } else {
            clearTimeout(pinchTimer);
          }
          pinchSpan = Math.max(20, Math.min(4000, pinchSpan * (e.deltaY < 0 ? 1.12 : 1 / 1.12)));
          fire('touchmove', two());
          // The gesture has no end event of its own, so it ends when the wheel goes quiet.
          pinchTimer = setTimeout(function () {
            pinchTimer = null;
            fire('touchend', []);
          }, 220);
        }, { passive: false });
      };
    })();
    true;
    """
}

// MARK: - The host

/// Hosts a viewer page and relays its `postMessage` traffic — the AppKit twin of iOS's
/// `ViewerWebView`.
///
/// `baseURL` is load-bearing, not cosmetic: see the file header.
struct MacViewerWebView: NSViewRepresentable {
    let html: String
    let baseURL: URL
    /// Extra CSS installed before the page's own script runs. Empty means "leave the page alone".
    var injectedCSS = ""
    /// Feed mouse and wheel input to a page that only listens for touches. Mesh page only.
    var adaptsMouseToTouch = false
    /// The window's handle on the page. Reassigned on every rebuild.
    let handle: MacViewerPageHandle
    let onEvent: (ViewerEvent) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(handle: handle, onEvent: onEvent) }

    /// The configuration both hosts share — this view, and the offscreen render `MacQuickLook`
    /// photographs. Factored out because a viewer page that behaves differently depending on which
    /// host loaded it is a fork of the page with nothing to declare it.
    static func makeConfiguration(
        handler: Coordinator,
        injectedCSS: String = "",
        adaptsMouseToTouch: Bool = false
    ) -> WKWebViewConfiguration {
        let config = WKWebViewConfiguration()
        config.defaultWebpagePreferences.allowsContentJavaScript = true

        // Order matters: the bridge shim has to exist before the page's own script calls it, and
        // the style/input scripts have to be registered before the document starts.
        let scripts = [ViewerJS.bridge]
            + (injectedCSS.isEmpty ? [] : [MacViewerJS.styleInjector(injectedCSS)])
            + (adaptsMouseToTouch ? [MacViewerJS.mouseToTouch] : [])
        for source in scripts {
            config.userContentController.addUserScript(
                WKUserScript(source: source, injectionTime: .atDocumentStart, forMainFrameOnly: true)
            )
        }
        config.userContentController.add(handler, name: ViewerJS.bridgeName)
        return config
    }

    func makeNSView(context: Context) -> WKWebView {
        let config = Self.makeConfiguration(
            handler: context.coordinator,
            injectedCSS: injectedCSS,
            adaptsMouseToTouch: adaptsMouseToTouch
        )
        let web = WKWebView(frame: .zero, configuration: config)
        // The pages paint their own opaque background; this is only what shows in the moment before
        // the first paint and behind any rubber-band, and a white flash against a near-black window
        // is the one thing that would read as a bug.
        web.underPageBackgroundColor = NSColor(Palette.dark.bg)
        // Both pages implement zoom themselves — the layer page off `wheel`, the mesh page off the
        // synthetic pinch above. WKWebView's own magnification would scale the rendered BITMAP of a
        // canvas instead, so a zoomed-in toolpath would be a blurry enlargement of the same pixels.
        web.allowsMagnification = false
        web.allowsBackForwardNavigationGestures = false
        web.loadHTMLString(html, baseURL: baseURL)
        context.coordinator.handle.attach(web)
        return web
    }

    func updateNSView(_ nsView: WKWebView, context: Context) {
        // Only the callback is refreshed. Re-loading would restart a 70 MB download and, for the
        // mesh page, spend a download token that is single-use. Everything that legitimately needs a
        // different page is driven by `.id(attempt)` at the call site, which builds a NEW host.
        context.coordinator.onEvent = onEvent
    }

    static func dismantleNSView(_ nsView: WKWebView, coordinator: Coordinator) {
        // Closing mid-download has to actually stop the transfer, and the content controller holds a
        // strong reference to the coordinator until the handler is removed.
        nsView.stopLoading()
        nsView.configuration.userContentController.removeScriptMessageHandler(forName: ViewerJS.bridgeName)
        nsView.configuration.userContentController.removeAllUserScripts()
        coordinator.handle.detach()
    }

    @MainActor
    final class Coordinator: NSObject, WKScriptMessageHandler {
        let handle: MacViewerPageHandle
        var onEvent: (ViewerEvent) -> Void

        init(handle: MacViewerPageHandle, onEvent: @escaping (ViewerEvent) -> Void) {
            self.handle = handle
            self.onEvent = onEvent
        }

        /// Byte-for-byte the same wire contract as the iOS coordinator, because it is the same page
        /// posting it. Divergence here would be a fork of the bridge with nothing to declare it.
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
#endif
