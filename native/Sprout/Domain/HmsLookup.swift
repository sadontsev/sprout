import Foundation

// Resolving Bambu's wiki page for an HMS code.
//
// In `Domain/` rather than beside the alerts overlay because both platforms need it and the overlay
// is iOS-only. It was a `private` free function inside `AlertsOverlay.swift`, which put the whole
// "Look it up" action out of reach of the Mac build — the same way `LibraryBrowse` being private in
// an iOS-guarded file led to it being copied. There is nothing view-shaped in it.

/// The first of `urls` that answers 2xx to a HEAD, or the last entry as the guaranteed fallback.
///
/// A thrown request (offline, DNS blocked, captive portal) stops the walk immediately rather than
/// burning one timeout per family — the index page is the right answer in that state anyway.
func firstResolvingURL(_ urls: [String]) async -> URL? {
    for candidate in urls.dropLast() {
        guard let url = URL(string: candidate) else { continue }
        var request = URLRequest(url: url, timeoutInterval: 6)
        request.httpMethod = "HEAD"
        do {
            let (_, response) = try await URLSession.shared.data(for: request)
            if let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) { return url }
        } catch {
            break
        }
    }
    return urls.last.flatMap { URL(string: $0) }
}
