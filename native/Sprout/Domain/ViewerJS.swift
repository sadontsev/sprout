import Foundation

// Extracted from StlViewerOverlay. These are the literals and the bridge shim injected into the
// viewer page; the page is the same on both platforms, so the macOS viewer window (1g) injects
// exactly these. Only the WKWebView HOST differs between platforms, and that stays in the view.

/// Builders for the literals injected into a viewer page, plus the bridge shim.
enum ViewerJS {
    /// Name of the `WKScriptMessageHandler` the shim posts to.
    static let bridgeName = "sprout"

    /// Injected at document start, before the page's own script runs.
    ///
    /// The pages call `window.ReactNativeWebView.postMessage(...)`; shimming that one symbol keeps
    /// the page source byte-identical to the version that has been rendering real prints for
    /// months, instead of forking it for a different host.
    static let bridge = #"""
    window.ReactNativeWebView={postMessage:function(s){window.webkit.messageHandlers.sprout.postMessage(String(s));}};
    // The layer viewer's axis gizmo reads window.safeTop every frame and falls back to a hard-coded
    // 44pt, which is wrong on a Dynamic Island phone. Measure the real inset off an env() probe.
    document.addEventListener('DOMContentLoaded',function(){
      var p=document.createElement('div');
      p.style.cssText='position:fixed;top:0;left:0;width:0;height:env(safe-area-inset-top);pointer-events:none';
      document.body.appendChild(p);
      window.safeTop=p.getBoundingClientRect().height;
      p.remove();
    });
    """#

    /// A JS string literal. `<` becomes `<` so a filename containing `</script>` cannot close
    /// the block it is embedded in.
    static func literal(_ s: String) -> String {
        var out = "\""
        for u in s.unicodeScalars {
            switch u {
            case "\"": out += "\\\""
            case "\\": out += "\\\\"
            case "\n": out += "\\n"
            case "\r": out += "\\r"
            case "\t": out += "\\t"
            case "<": out += "\\u003c"
            default:
                // U+2028/U+2029 are literal line terminators in JS source.
                if u.value < 0x20 || u.value == 0x2028 || u.value == 0x2029 {
                    out += String(format: "\\u%04x", u.value)
                } else {
                    out.unicodeScalars.append(u)
                }
            }
        }
        return out + "\""
    }

    /// A JS object literal of header name → value.
    static func object(_ dict: [String: String]) -> String {
        let body = dict.keys.sorted()
            .map { "\(literal($0)):\(literal(dict[$0] ?? ""))" }
            .joined(separator: ",")
        return "{\(body)}"
    }

    /// The document URL to load a viewer page on: the server's own base URL, always directory-like.
    ///
    /// It is not merely the origin. Bambuddy (or a texturize sidecar) can be mounted under a PATH
    /// prefix, and a page loaded at the bare origin resolves every relative in-page URL one or more
    /// directories too high — which reaches a route that does not exist and answers **404**, the one
    /// status the download endpoint itself never returns. The RN build passed `${baseUrl}/` here for
    /// exactly this reason; dropping the path was a port regression.
    ///
    /// Query and fragment are discarded (a base URL has no business carrying either) and the path is
    /// forced to end in a single `/` so RFC 3986 resolution treats it as a directory rather than
    /// replacing its last segment.
    ///
    /// Falls back to a dummy https origin so a malformed base URL fails inside the page — with a
    /// message the user can read — rather than trapping here.
    static func documentBase(of urlString: String) -> URL {
        let trimmed = urlString.trimmingCharacters(in: .whitespacesAndNewlines)
        if let u = URL(string: trimmed), let scheme = u.scheme, let host = u.host() {
            var s = "\(scheme)://\(host)"
            if let port = u.port { s += ":\(port)" }
            var path = u.path()
            while path.hasSuffix("/") { path.removeLast() }
            s += path + "/"
            if let base = URL(string: s) { return base }
        }
        return URL(string: "https://localhost/")!
    }

    /// A viewer URL reduced to what is safe to print AND to the only thing that matters when one
    /// fails: its **shape**.
    ///
    /// - scheme + authority collapse to `{base}` — the user's host is not log material;
    /// - the single-use download token after `/dl/` and any `token=` query value collapse to `…`.
    ///
    /// Everything else is verbatim, deliberately. A 404 from `/dl/{token}/{filename}` means the path
    /// gained or lost a segment — an unescaped `/` inside the filename, an empty filename — and only
    /// the literal path shows that. A credential the server dislikes is a 403, never a 404, so
    /// hiding the token costs the diagnosis nothing.
    static func loggableUrl(_ urlString: String) -> String {
        var rest = urlString
        // Split by hand rather than through URL: a base URL too malformed to parse is one of the
        // things this log exists to reveal, and it must still produce a readable line.
        if let schemeEnd = rest.range(of: "://") {
            let afterAuthority = rest[schemeEnd.upperBound...]
            let cut = afterAuthority.firstIndex { $0 == "/" || $0 == "?" || $0 == "#" }
            rest = "{base}" + (cut.map { String(afterAuthority[$0...]) } ?? "")
        }

        let parts = rest.split(separator: "?", maxSplits: 1, omittingEmptySubsequences: false)
        var path = String(parts.first ?? "")
        if let marker = path.range(of: "/dl/") {
            let token = path[marker.upperBound...]
            let tail = token.firstIndex(of: "/").map { String(token[$0...]) } ?? ""
            path = String(path[..<marker.upperBound]) + "…" + tail
        }
        guard parts.count > 1 else { return path }
        let query = String(parts[1]).replacingOccurrences(
            of: "(^|[&])token=[^&]*",
            with: "$1token=…",
            options: .regularExpression
        )
        return path + "?" + query
    }

    /// Number formatting for injected literals — no trailing `.0`, no locale decimal comma.
    static func number(_ v: Double) -> String {
        v == v.rounded() && abs(v) < 1e15 ? String(Int(v)) : String(v)
    }
}
