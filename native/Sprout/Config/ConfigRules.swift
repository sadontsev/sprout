import Foundation

/// Pure input sanitisers and URL resolution for the connection form.
enum ConfigRules {
    /// Trim whitespace and any stray trailing slash; keep scheme + host.
    static func sanitizeBaseUrl(_ raw: String) -> String {
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        s.removeAll { $0.isWhitespace }
        while s.hasSuffix("/") { s.removeLast() }
        return s
    }

    /// The characters a Bambuddy key may contain after the `bb_` prefix: base64url.
    private static let keyCharacters = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789_-")

    /// API keys are `bb_` + a base64url token. Pasting often appends a stray trailing character —
    /// whitespace, a newline, or a `%` (zsh's no-newline EOL marker / a URL-encode artifact). Trim
    /// both ends, then strip leading/trailing characters that aren't valid key characters. Interior
    /// characters are never touched.
    ///
    /// NOTE: this charset MUST match `isValidApiKey`'s. An earlier mismatch — the sanitiser kept `_`
    /// but the validator only accepted alphanumerics — left Connect greyed out for any key
    /// containing `_`/`-`, despite the field being filled.
    static func sanitizeApiKey(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        var chars = Array(trimmed.unicodeScalars)
        while let f = chars.first, !keyCharacters.contains(f) { chars.removeFirst() }
        while let l = chars.last, !keyCharacters.contains(l) { chars.removeLast() }
        return String(String.UnicodeScalarView(chars))
    }

    /// Whether a raw API-key input is a plausible Bambuddy key once sanitised — drives the Connect
    /// button's enabled state.
    static func isValidApiKey(_ raw: String) -> Bool {
        let k = sanitizeApiKey(raw)
        guard k.hasPrefix("bb_") else { return false }
        let body = k.dropFirst(3)
        guard body.count >= 6 else { return false }
        return body.unicodeScalars.allSatisfy { keyCharacters.contains($0) }
    }

    /// The effective la-push base URL the app should register with — or nil for LOCAL-ONLY mode.
    ///
    /// Each person self-hosts their OWN la-push next to their OWN Bambuddy (it polls Bambuddy with
    /// their API key and signs with their APNs key), so the app must be pointed at it. Two modes:
    /// - SERVER (a URL): the app registers each card's push token, so lock-screen cards keep
    ///   updating and status banners fire even after iOS suspends the app.
    /// - LOCAL (nil): registration is skipped, so Live Activities only update while the app runs and
    ///   there are no push banners — but no server is needed.
    ///
    /// Resolution: `serverPush == false` forces LOCAL. Otherwise prefer an explicit `pushUrl`; else
    /// derive it from a `bambuddy.*` host by swapping the subdomain to `lapush.`.
    static func resolvePushUrl(_ cfg: AppConfig) -> String? {
        if cfg.serverPush == false { return nil }
        if let explicit = cfg.pushUrl?.trimmingCharacters(in: .whitespaces), !explicit.isEmpty {
            return httpUrl(trimTrailingSlashes(explicit))
        }
        if cfg.baseUrl.contains("bambuddy.") {
            return httpUrl(trimTrailingSlashes(cfg.baseUrl.replacingOccurrences(of: "bambuddy.", with: "lapush.")))
        }
        return nil
    }

    /// Same shape for the stl-texturize sidecar. The shell health-probes the resolved URL before
    /// enabling any texturize UI.
    static func resolveTexturizeUrl(_ cfg: AppConfig) -> String? {
        if cfg.texturize == false { return nil }
        if let explicit = cfg.texturizeUrl?.trimmingCharacters(in: .whitespaces), !explicit.isEmpty {
            return httpUrl(trimTrailingSlashes(explicit))
        }
        if cfg.baseUrl.contains("bambuddy.") {
            return httpUrl(trimTrailingSlashes(cfg.baseUrl.replacingOccurrences(of: "bambuddy.", with: "texturize.")))
        }
        return nil
    }

    private static func trimTrailingSlashes(_ s: String) -> String {
        var t = s.trimmingCharacters(in: .whitespaces)
        while t.hasSuffix("/") { t.removeLast() }
        return t
    }

    /// Only ever hand a push token to a well-formed http(s) URL. The push URL is user-entered config
    /// (never injected from observed content), but this rejects typos and non-http schemes so a
    /// malformed entry silently disables push rather than POSTing the token somewhere unexpected.
    private static func httpUrl(_ s: String) -> String? {
        let lower = s.lowercased()
        guard lower.hasPrefix("http://") || lower.hasPrefix("https://") else { return nil }
        guard !s.contains(where: \.isWhitespace), s.count > 8 else { return nil }
        return s
    }
}
