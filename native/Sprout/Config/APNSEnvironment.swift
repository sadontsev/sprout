import Foundation

/// Which APNs gateway will accept this install's push tokens.
///
/// The answer comes from the `aps-environment` entitlement in the embedded provisioning profile —
/// **not** from the build configuration. A `-configuration Release` build installed via Xcode or
/// devicectl (this project's everyday device recipe) is development-signed, so its tokens are
/// sandbox tokens while `#if DEBUG` is false. Deriving the environment from the compiler would
/// mislabel exactly that build, and the failure is silent at every layer: APNs answers
/// `400 BadDeviceToken`, the relay drops the binding, the app re-claims with the same wrong value,
/// and the loop never converges.
///
/// That is the shape this codebase keeps rediscovering — a predicate answering a nearby question.
/// "Was this compiled for Debug?" is not "which gateway will accept this token?".
enum APNSEnvironment: String {
    case sandbox
    case production

    /// Derives the environment from a provisioning profile's bytes.
    ///
    /// The profile is a CMS envelope wrapping an XML plist, so the plist is extracted by locating
    /// its bounds rather than by decoding the signature — we are reading our own entitlements, not
    /// verifying them, and Apple has already verified the signature by the time the app runs.
    ///
    /// An absent or unreadable profile means production: App Store builds are the case with no
    /// development entitlement to find, so defaulting the other way would send every real user's
    /// tokens to the sandbox.
    static func from(profile data: Data?) -> APNSEnvironment {
        guard let data, let plist = extractPlist(from: data) else { return .production }
        guard
            let parsed = try? PropertyListSerialization.propertyList(from: plist, format: nil),
            let dict = parsed as? [String: Any],
            let entitlements = dict["Entitlements"] as? [String: Any],
            let value = entitlements["aps-environment"] as? String
        else { return .production }

        return value == "development" ? .sandbox : .production
    }

    /// The running app's environment.
    static var current: APNSEnvironment {
        guard let url = Bundle.main.url(forResource: "embedded", withExtension: "mobileprovision") else {
            return .production
        }
        return from(profile: try? Data(contentsOf: url))
    }

    /// Locates the XML plist inside a CMS-wrapped provisioning profile.
    static func extractPlist(from data: Data) -> Data? {
        guard
            let start = data.range(of: Data("<?xml".utf8)),
            let end = data.range(of: Data("</plist>".utf8), in: start.lowerBound..<data.endIndex)
        else { return nil }
        return data.subdata(in: start.lowerBound..<end.upperBound)
    }
}
