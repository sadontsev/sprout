import SwiftUI

#if os(macOS)
import AppKit
/// The platform's bitmap type. `NSImage` and `UIImage` are both thin wrappers over a `CGImage` here
/// — every use in this app is "decode these bytes, hand them to SwiftUI" — so a typealias plus the
/// two accessors below is the whole abstraction. Nothing needs a protocol.
typealias PlatformImage = NSImage
#else
import UIKit
typealias PlatformImage = UIImage
#endif

extension Image {
    /// One spelling for `Image(uiImage:)` / `Image(nsImage:)`.
    init(platform image: PlatformImage) {
        #if os(macOS)
        self.init(nsImage: image)
        #else
        self.init(uiImage: image)
        #endif
    }
}

extension PlatformImage {
    /// Decode bytes, or nil if they are not an image.
    ///
    /// Named rather than using the initialiser directly because `NSImage(data:)` succeeds for input
    /// `UIImage(data:)` rejects: it accepts PDF, EPS and anything else NSImage can represent, and
    /// for a truncated or HTML-error-page response it can return a valid-but-empty image. A
    /// thumbnail endpoint answering with an error page would then render as a blank tile instead of
    /// falling back to the placeholder, so macOS checks that the result has real pixels.
    static func decoded(from data: Data) -> PlatformImage? {
        #if os(macOS)
        guard let image = NSImage(data: data), image.size.width > 0, image.size.height > 0 else { return nil }
        return image
        #else
        return UIImage(data: data)
        #endif
    }

    /// Approximate decoded size in bytes — what `NSCache` charges an entry against its cost limit,
    /// so that a 60 MB limit means 60 MB rather than "some number of images".
    ///
    /// The two platforms answer this differently and neither answer ports. `UIImage.size` is in
    /// points with a separate `scale` to reach pixels. `NSImage` has no `scale` at all: its `size`
    /// is a drawing size in points, and the real pixel dimensions live on its representations —
    /// of which there can be several, so the largest is the one that will be drawn on a Retina
    /// display and the one worth charging for.
    var decodedByteCost: Int {
        #if os(macOS)
        let widest = representations.map(\.pixelsWide).max() ?? 0
        let tallest = representations.map(\.pixelsHigh).max() ?? 0
        let w = widest > 0 ? widest : Int(size.width)
        let h = tallest > 0 ? tallest : Int(size.height)
        return w * h * 4
        #else
        return Int(size.width * scale * size.height * scale * 4)
        #endif
    }

    /// PNG bytes, for snapshots written to the App Group container.
    func pngRepresentationData() -> Data? {
        #if os(macOS)
        guard let cg = cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }
        return NSBitmapImageRep(cgImage: cg).representation(using: .png, properties: [:])
        #else
        return pngData()
        #endif
    }
}
