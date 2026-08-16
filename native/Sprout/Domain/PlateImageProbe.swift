import Foundation

/// Answers one question about a thumbnail: **is this a picture of the model, or a flat silhouette?**
///
/// Bambuddy renders library thumbnails itself, because the slicer never does. Its own docstring is
/// explicit that this is by design and not a failure: *"Both CLIs skip the plate-thumbnail render
/// when invoked with `--slice --export-3mf` headlessly — that render is a GUI-side action that only
/// fires in the desktop Studio."* So `backend/app/services/plate_thumbnail.py` and its sibling
/// `stl_thumbnail.py` fill the gap with trimesh + matplotlib:
///
/// ```python
/// Poly3DCollection(triangles, facecolors="#00AE42", ...)   # _BAMBU_GREEN, on "#1a1a1a"
/// ```
///
/// There is no `shade=` argument and no light source, and `Poly3DCollection` defaults to
/// `shade=False` — so every triangle receives the identical green and the result is a solid
/// silhouette. Measured against this server: a MakerWorld-imported `cr.3mf` returns a detailed
/// shaded render, and the `cr.gcode.3mf` sliced from it returns a flat green ellipse.
///
/// **Why classify the pixels instead of the file.** Every cheaper predicate answers a nearby
/// question and gets it wrong somewhere:
///
/// - *"was it sliced?"* — imported `.3mf`s look fine, but a raw `.stl` upload blobs too, and it is
///   not sliced.
/// - *"is the image 512×512?"* — that is the injected size, but plates in one file can differ, and
///   desktop Studio also writes 512×512.
/// - *"is it Bambu green?"* — the colour is one constant in someone else's repo. The property that
///   actually matters is `shade=False`.
///
/// This asks the only question whose answer cannot drift: does the bitmap contain shading. It also
/// self-heals — if upstream Bambuddy ever passes `shade=True`, these images start classifying as
/// `.shaded` and every fallback in front of them switches itself off with no code change here.
///
/// Deliberately pure and platform-free so it is testable without a renderer: the caller supplies
/// RGBA bytes (see `PlatformImage.rgbaProbe`).
enum PlateImageProbe {
    enum Verdict: Sendable, Equatable {
        /// A real render: many distinct tones.
        case shaded
        /// A solid fill on a background — a silhouette, not a picture of the model.
        case flatSilhouette
        /// Effectively one colour. A blank tile, or a snapshot taken before anything drew.
        case uniform
        /// Not enough pixels to judge.
        case unreadable

        /// Whether this image is worth showing as a depiction of the model.
        var depictsModel: Bool { self == .shaded }
    }

    /// Buckets holding less than this share of the image are treated as antialiasing along the
    /// silhouette's edge rather than as tones of their own. A 512×512 matplotlib fill carries a thin
    /// blended rim which would otherwise read as shading.
    private static let noiseFloor = 0.005

    /// Above this combined share, two buckets *are* the image — a fill and its ground.
    private static let twoToneShare = 0.90

    /// Above this, one bucket is the whole image.
    private static let uniformShare = 0.98

    /// Classify a square RGBA buffer (4 bytes per pixel, row-major).
    ///
    /// Quantises to 5 bits per channel before counting. At 8 bits, JPEG ringing and PNG dither would
    /// scatter a flat fill across dozens of near-identical values and every silhouette would read as
    /// shaded.
    static func classify(rgba: [UInt8], side: Int) -> Verdict {
        guard side > 0, rgba.count >= side * side * 4 else { return .unreadable }

        var histogram: [UInt16: Int] = [:]
        var counted = 0
        for pixel in stride(from: 0, to: side * side * 4, by: 4) {
            // Skip transparent pixels: a PNG with an alpha ground would otherwise contribute a
            // bucket whose colour is undefined.
            guard rgba[pixel + 3] > 8 else { continue }
            let r = UInt16(rgba[pixel] >> 3)
            let g = UInt16(rgba[pixel + 1] >> 3)
            let b = UInt16(rgba[pixel + 2] >> 3)
            histogram[(r << 10) | (g << 5) | b, default: 0] += 1
            counted += 1
        }
        guard counted > 0 else { return .unreadable }

        let total = Double(counted)
        let shares = histogram.values
            .map { Double($0) / total }
            .filter { $0 >= noiseFloor }
            .sorted(by: >)

        // Every bucket fell below the noise floor, which means no tone dominates anywhere — the most
        // varied image possible, not an unreadable one. Returning `.unreadable` here read a detailed
        // render as a failure and sent the caller off to borrow a picture it did not need.
        guard let first = shares.first else { return .shaded }
        if first >= uniformShare { return .uniform }

        let topTwo = first + (shares.count > 1 ? shares[1] : 0)
        // Two tones that between them ARE the image: a fill and its ground, with nothing in between.
        // A genuine render spreads across many buckets, so its top two never reach this.
        if shares.count <= 2 || topTwo >= twoToneShare { return .flatSilhouette }

        return .shaded
    }
}
