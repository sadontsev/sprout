import SwiftUI

/// Decoded MakerWorld thumbnails, kept so scrolling does not re-fetch them.
///
/// **The stutter inside the grid.** Every tile and every one of a model's up-to-88 version rows was
/// a bare `AsyncImage`, which keeps no decoded-image cache of its own. Scrolling back up re-fetched
/// each cover through the Bambuddy proxy and re-decoded the JPEG, so the grid got slower the more of
/// it you had seen.
///
/// Two layers, because they answer different questions. `NSCache` holds decoded `UIImage`s so a
/// re-appearing tile costs nothing at all; `URLCache` holds the bytes so a cold decode still avoids
/// the network. `NSCache` also evicts itself under memory pressure, which a plain dictionary would
/// not — this is a grid of photographs, and holding every one of them is how a browse session ends
/// in a jetsam.
///
/// Keyed by the full URL. Bambuddy's thumbnail endpoint passes the CDN URL through as a query
/// parameter and the CDN URL is content-addressed, so the key is stable and a hit is always the
/// right image.
actor ThumbCache {
    static let shared = ThumbCache()

    private let memory: NSCache<NSURL, UIImage> = {
        let c = NSCache<NSURL, UIImage>()
        c.totalCostLimit = 60 * 1024 * 1024
        return c
    }()

    private let session: URLSession = {
        let cfg = URLSessionConfiguration.default
        cfg.urlCache = URLCache(memoryCapacity: 8 * 1024 * 1024,
                                diskCapacity: 200 * 1024 * 1024,
                                directory: nil)
        // Use the disk copy when there is one; these images never change under their URL.
        cfg.requestCachePolicy = .returnCacheDataElseLoad
        cfg.timeoutIntervalForRequest = 20
        return URLSession(configuration: cfg)
    }()

    /// In-flight loads, so twenty tiles appearing at once make one request per URL rather than
    /// twenty. Without this, a fast scroll issues the same fetch repeatedly before any completes.
    private var inFlight: [URL: Task<UIImage?, Never>] = [:]

    func image(for url: URL, headers: [String: String] = [:]) async -> UIImage? {
        if let hit = memory.object(forKey: url as NSURL) { return hit }
        if let running = inFlight[url] { return await running.value }

        let task = Task<UIImage?, Never> { [session] in
            var req = URLRequest(url: url)
            for (k, v) in headers { req.setValue(v, forHTTPHeaderField: k) }
            guard let (data, response) = try? await session.data(for: req) else { return nil }
            let status = (response as? HTTPURLResponse)?.statusCode ?? 200
            // A 401 here means the camera stream token has expired — the thumbnail endpoint is
            // token-gated, not X-API-Key-gated. Caching that body would pin an error image in place
            // for the rest of the session.
            guard (200..<300).contains(status), let image = UIImage(data: data) else { return nil }
            return image
        }
        inFlight[url] = task
        let image = await task.value
        inFlight[url] = nil
        if let image {
            // Cost in bytes, so the limit means what it says rather than counting images.
            let cost = Int(image.size.width * image.size.height * image.scale * image.scale * 4)
            memory.setObject(image, forKey: url as NSURL, cost: cost)
        }
        return image
    }

    /// Warm the cache for covers about to scroll into view. Fire-and-forget: a prefetch that loses a
    /// race with the real request costs nothing, because `inFlight` collapses them.
    func prefetch(_ urls: [URL], headers: [String: String] = [:]) {
        for url in urls where memory.object(forKey: url as NSURL) == nil {
            Task { _ = await image(for: url, headers: headers) }
        }
    }
}

/// A thumbnail that reads `ThumbCache`, so re-appearing tiles do not re-download.
///
/// Sized two ways because the call sites genuinely differ: `aspect` for covers that should keep a
/// ratio and take the width they are given, `size` for fixed thumbnails in rows.
struct CachedThumb: View {
    let url: URL?
    var aspect: CGFloat?
    var size: CGSize?
    var contentMode: ContentMode = .fill

    @Environment(\.palette) private var c
    @State private var image: UIImage?
    @State private var failed = false

    var body: some View {
        Rectangle()
            .fill(c.thumb)
            .aspectRatio(aspect, contentMode: .fit)
            .frame(width: size?.width, height: size?.height)
            .overlay {
                if let image {
                    Image(uiImage: image)
                        .resizable()
                        .aspectRatio(contentMode: contentMode)
                        // A `.fill` image is flexible, so it must be clipped by the composite rather
                        // than inside the overlay — an overlay does not clip to its base.
                        .transition(.opacity)
                } else if failed || url == nil {
                    Image(systemName: "photo")
                        .font(.system(size: 16, weight: .light))
                        .foregroundStyle(c.t3)
                }
            }
            .clipped()
            .animation(Motion.standard(0.18), value: image != nil)
            .task(id: url) {
                // Reset when the row is recycled onto a different model, or the previous model's
                // photo lingers under the new one's title.
                image = nil
                failed = false
                guard let url else { return }
                let loaded = await ThumbCache.shared.image(for: url)
                guard !Task.isCancelled else { return }
                image = loaded
                failed = loaded == nil
            }
    }
}
