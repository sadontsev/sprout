import Foundation

/// What a push may tell the notification extension about the picture to fetch — and, deliberately,
/// how little that is.
///
/// A notification's body and attachment can only be rewritten by a `UNNotificationServiceExtension`,
/// which iOS launches on the app's behalf when a push carries `mutable-content: 1`. That makes the
/// payload a **remote trigger for network work**, so the smallest safe design is the one where a
/// forged or replayed push cannot aim it anywhere.
///
/// So the payload carries a camera stream token and a printer id, and nothing else. The host and the
/// path are compiled in — the host from the Keychain the user typed it into, the path from
/// `snapshotPath` below — and no URL crosses the wire. The worst a forged push can do is make the
/// extension ask the user's own Bambuddy for its own camera frame, which is what the real push does
/// anyway.
///
/// Pure and platform-free so both halves are testable without an extension host: the app never runs
/// this, the extension always does, and an extension is the one place in this project that cannot be
/// exercised in a test.
enum ShotHandoff {

    /// The payload key, top level and beside `aps`.
    ///
    /// APNs hands `aps` to the system and everything else to the app verbatim, so a key nested
    /// inside `aps` never arrives. The symptom would be a banner with no picture and no error at
    /// all — indistinguishable from the camera being off — which is why `token(in:)` is tested
    /// against the nested shape explicitly.
    static let payloadKey = "sprout_shot"

    /// The camera snapshot path. Compiled in rather than sent, so the payload has no field that
    /// selects a URL.
    static func snapshotPath(printerId: Int) -> String {
        "/api/v1/printers/\(printerId)/camera/snapshot"
    }

    /// The stream token carried by a push, if it is one.
    ///
    /// Charset-checked rather than trusted. The token is interpolated into a query string, and a
    /// value containing `&`, `#` or a space would either change the request's shape or fail to
    /// parse — and a token is minted by Bambuddy from a known alphabet, so anything outside it did
    /// not come from Bambuddy.
    static func token(in userInfo: [AnyHashable: Any]) -> String? {
        guard let shot = userInfo[payloadKey] as? [String: Any],
              let token = shot["t"] as? String,
              !token.isEmpty, token.count <= 64,
              token.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-" || $0 == "_") })
        else { return nil }
        return token
    }

    /// Which printer's camera, if the push says.
    static func printerId(in userInfo: [AnyHashable: Any]) -> Int? {
        guard let shot = userInfo[payloadKey] as? [String: Any] else { return nil }
        if let id = shot["p"] as? Int { return id > 0 ? id : nil }
        if let id = shot["p"] as? NSNumber { return id.intValue > 0 ? id.intValue : nil }
        return nil
    }

    /// The snapshot URL, from a base the DEVICE holds and a token the push supplied.
    ///
    /// Returns nil for a base that is not http(s) — a stored value is user-typed, and a `file:` or
    /// scheme-less base would otherwise send the extension somewhere the user did not mean.
    static func url(base: String, printerId: Int, token: String) -> URL? {
        var trimmed = base.trimmingCharacters(in: .whitespacesAndNewlines)
        while trimmed.hasSuffix("/") { trimmed.removeLast() }
        guard let components = URLComponents(string: trimmed),
              let scheme = components.scheme?.lowercased(),
              scheme == "https" || scheme == "http",
              components.host?.isEmpty == false
        else { return nil }
        let escaped = token.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? token
        return URL(string: "\(trimmed)\(snapshotPath(printerId: printerId))?token=\(escaped)")
    }
}
