import Foundation

/// A transient message, and whether it is good news.
///
/// Constructed through `.failure` / `.success` rather than a memberwise initialiser so the kind is
/// always stated at the call site. Failure is by far the common case — it is what
/// `AppModel.perform` reports for every refused printer command — but "common" is not a default
/// worth inferring: the two successes in the app (a file added to the library, a job re-queued)
/// were exactly the ones being mislabelled.
struct Toast: Equatable, Sendable {
    enum Kind: Equatable, Sendable {
        case failure
        case success
    }

    let text: String
    let kind: Kind

    static func failure(_ text: String) -> Toast { Toast(text: text, kind: .failure) }
    static func success(_ text: String) -> Toast { Toast(text: text, kind: .success) }
}
