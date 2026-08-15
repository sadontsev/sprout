import SwiftUI

/// A self-polling camera stills view that holds the last decoded frame while the next one loads.
///
/// Two things this gets right that the obvious version does not:
///
/// 1. **It owns its own poll loop.** Driving the refresh from outside — a tick counter folded into
///    the URL — restarts the request every interval. A chamber snapshot is a few hundred kilobytes,
///    so a fetch that takes longer than the interval gets cancelled and retried forever and the tile
///    stays black. Here each pass waits for the previous one to finish, so a slow link simply
///    refreshes more slowly.
/// 2. **It keeps the previous frame.** Clearing on each pass produced a visible flicker twice a
///    second. The old frame stays up until a new one actually decodes.
struct SnapshotImage: View {
    /// The snapshot endpoint WITHOUT any cache-buster — this view appends its own.
    let url: URL?
    var interval: Duration = .seconds(2)
    /// Called the first time a frame decodes, so callers can stop claiming the camera is waking.
    var onFirstFrame: () -> Void = {}

    @State private var image: PlatformImage?
    @State private var loadedOnce = false

    var body: some View {
        ZStack {
            if let image {
                Image(platform: image)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    // Deliberately NO .id(image): keying on the frame gives every update a fresh
                    // view identity, so SwiftUI tears the old one down and inserts a new one — which
                    // reads as a blink twice a second. Swapping the content in place is seamless.
            }
        }
        .animation(.easeInOut(duration: 0.12), value: image)
        .task(id: url) {
            image = nil
            loadedOnce = false
            await poll()
        }
    }

    private func poll() async {
        guard let url else { return }
        var pass = 0
        while !Task.isCancelled {
            pass += 1
            // The token is already in the URL; this only defeats caching between passes.
            let busted = URL(string: url.absoluteString + "&_t=\(pass)") ?? url
            await fetch(busted)
            try? await Task.sleep(for: interval)
        }
    }

    private func fetch(_ url: URL) async {
        var request = URLRequest(url: url)
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.timeoutInterval = 20
        guard let (data, response) = try? await URLSession.shared.data(for: request) else { return }
        let ok = (response as? HTTPURLResponse).map { (200..<300).contains($0.statusCode) } ?? true
        // A warming camera answers with a non-image body; keep the last good frame rather than
        // flashing an error into a tile that is about to work.
        guard ok, let decoded = PlatformImage.decoded(from: data) else { return }

        image = decoded
        if !loadedOnce {
            loadedOnce = true
            onFirstFrame()
        }
    }
}
