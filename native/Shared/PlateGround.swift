import Foundation

/// Which ground a plate image needs behind it so the model can actually be seen.
///
/// The Bambu Cloud cover is a **transparent** PNG of the model in its own filament colour, and the
/// Dynamic Island's background is black and not ours to change — HIG, Live Activities → Choosing
/// colors: *"You can't customize background colors for compact, minimal, and expanded
/// presentations."* So a print in near-black PETG arrived as a black model on a black island.
/// Measured on the running job: mean luminance `0.0179`, contrast against black **1.36:1**. That is
/// invisible, not merely poor.
///
/// A fixed light ground is not the fix, because it fails the other way round the moment someone
/// prints in white. The ground has to be chosen from the image.
///
/// Bambuddy's own renders are opaque and already carry a ground, so they must be left untouched —
/// which `choose` answers with nil rather than by inspecting where the image came from. "Is this
/// transparent?" is the question; "is this a cloud cover?" is the nearby one that would be wrong the
/// day another source starts sending alpha.
enum PlateGround {

    /// The two candidates, and deliberately only two: they are the pair the library renders already
    /// use (`MODEL_COLOR` on `BACKGROUND_COLOR`), so a cloud cover and a server render read as the
    /// same product rather than as two apps.
    enum Ground: Equatable, Sendable {
        case porcelain
        case graphite

        /// 0...1 sRGB components.
        var rgb: (r: Double, g: Double, b: Double) {
            switch self {
            case .porcelain: (233.0 / 255, 236.0 / 255, 240.0 / 255)   // #E9ECF0
            case .graphite: (42.0 / 255, 39.0 / 255, 36.0 / 255)       // #2A2724
            }
        }

        /// WCAG relative luminance, precomputed — these are constants, not measurements.
        var luminance: Double {
            switch self {
            case .porcelain: 0.8113
            case .graphite: 0.0243
            }
        }
    }

    /// Below this many opaque samples the mean says more about which pixels the point-sampler
    /// happened to land on than about the model. A thin part sampled at 64×64 can legitimately fall
    /// here, and leaving such an image alone is better than grounding it against a guess.
    static let minimumOpaqueSamples = 24

    /// Alpha at or below this counts as transparent. Not zero: a PNG's antialiased rim carries a few
    /// units of alpha whose colour is a blend with nothing, and averaging those drags the mean
    /// toward whatever the encoder left in the RGB channels of fully transparent pixels.
    static let opaqueAlphaFloor: UInt8 = 8

    /// The ground to composite behind this image, or nil to leave it as it is.
    ///
    /// - Parameters:
    ///   - rgba: premultiplied-last RGBA, 4 bytes per pixel, row-major — what `rgbaProbe` returns.
    ///   - side: the square's edge in pixels.
    /// - Returns: the ground that gives the model the most contrast, or nil when the image is fully
    ///   opaque (it has a ground already), when the buffer is too small to judge, or when too few
    ///   pixels are opaque to mean anything.
    static func choose(rgba: [UInt8], side: Int) -> Ground? {
        guard side > 0, rgba.count >= side * side * 4 else { return nil }

        var sum = 0.0
        var opaque = 0
        var transparent = 0
        for pixel in stride(from: 0, to: side * side * 4, by: 4) {
            let alpha = rgba[pixel + 3]
            guard alpha > opaqueAlphaFloor else {
                transparent += 1
                continue
            }
            // Premultiplied, so undo it before reading the colour — otherwise a half-transparent
            // edge reads as a darker version of itself and drags the mean down.
            let a = Double(alpha) / 255
            let r = min(Double(rgba[pixel]) / 255 / a, 1)
            let g = min(Double(rgba[pixel + 1]) / 255 / a, 1)
            let b = min(Double(rgba[pixel + 2]) / 255 / a, 1)
            sum += 0.2126 * linear(r) + 0.7152 * linear(g) + 0.0722 * linear(b)
            opaque += 1
        }

        // Nothing to composite onto: the image brought its own ground.
        guard transparent > 0 else { return nil }
        guard opaque >= minimumOpaqueSamples else { return nil }

        let mean = sum / Double(opaque)
        return contrast(mean, Ground.porcelain.luminance) >= contrast(mean, Ground.graphite.luminance)
            ? .porcelain
            : .graphite
    }

    /// WCAG contrast ratio between two relative luminances.
    ///
    /// Picking the better of exactly two grounds has a floor worth knowing: the two ratios are equal
    /// at a model luminance of `0.203`, where both give **3.40:1**. So the worst case this rule can
    /// produce still clears the 3:1 that a graphical object needs — there is no model colour for
    /// which it does nothing useful.
    static func contrast(_ a: Double, _ b: Double) -> Double {
        (max(a, b) + 0.05) / (min(a, b) + 0.05)
    }

    /// sRGB component to linear light.
    private static func linear(_ value: Double) -> Double {
        value <= 0.03928 ? value / 12.92 : pow((value + 0.055) / 1.055, 2.4)
    }
}
