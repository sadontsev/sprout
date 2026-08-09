import Foundation
import SwiftUI

/// Filament-colour helpers. Ported from `src/dashboard/present.ts`.
enum FilamentColor {
    /// Bambu tray colors are RGBA hex like "565656FF". Returns `#RRGGBB`, or nil when there is no
    /// colour.
    ///
    /// Alpha EXACTLY "00" is Bambu's "unset" sentinel, NOT a real colour: "00000000" used to come
    /// back as "#000000", so a slot whose colour the printer does not know rendered as black
    /// filament — and in the print wizard that black even beat the inventory spool's real colour.
    /// Any other alpha is a genuine colour and keeps its RGB (the AMS reports e.g. "C9A38180").
    ///
    /// Non-hex input returns nil rather than a malformed string: one caller feeds raw MakerWorld
    /// values straight into a background colour, where "#TRANSP" is invalid.
    static func norm(_ hex: String?) -> String? {
        guard let hex else { return nil }
        let h = hex.replacingOccurrences(of: "#", with: "").trimmingCharacters(in: .whitespaces)
        let isHex = (h.count == 6 || h.count == 8) && h.allSatisfy(\.isHexDigit)
        guard isHex else { return nil }
        if h.count == 8, h.suffix(2) == "00" { return nil }
        return "#" + h.prefix(6).uppercased()
    }

    private static func rgb(_ hex: String) -> (Int, Int, Int) {
        let h = Array(hex.dropFirst())
        func byte(_ i: Int) -> Int { Int(String(h[i...(i + 1)]), radix: 16) ?? 0 }
        return (byte(0), byte(2), byte(4))
    }

    /// WCAG relative luminance of a `#RRGGBB` colour.
    static func relLuminance(_ hex: String) -> Double {
        let (r, g, b) = rgb(hex)
        func lin(_ ch: Int) -> Double {
            let v = Double(ch) / 255
            return v <= 0.03928 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * lin(r) + 0.7152 * lin(g) + 0.0722 * lin(b)
    }

    /// WCAG contrast ratio between two `#RRGGBB` colours, 1...21.
    static func contrastRatio(_ a: String, _ b: String) -> Double {
        let la = relLuminance(a), lb = relLuminance(b)
        return (max(la, lb) + 0.05) / (min(la, lb) + 0.05)
    }

    /// Ink that stays readable ON a given fill. 0.179 is the exact luminance where black and white
    /// ink tie: solve (L+0.05)/0.05 = 1.05/(L+0.05). Replaces a hard-coded white glyph that vanished
    /// on a white swatch.
    static func inkOn(_ hex: String?) -> Color {
        if let hex, relLuminance(hex) > 0.179 { return Color(hex: 0x0D1012) }
        return Color(hex: 0xFFFFFF)
    }

    /// A human name for a filament colour — "White", "Titan grey", "Pale beige".
    ///
    /// The point is that a swatch alone cannot say "white": on a white card it is a hole, and a user
    /// reading the row sees only "PETG". Derived from HSL rather than luminance because naming is
    /// about hue and saturation, not perceived brightness. Used only as a FALLBACK — an inventory
    /// spool's own `colorName` always wins, since a vendor name ("Titan Gray") beats anything
    /// computed.
    static func name(_ hex: String?) -> String? {
        guard let hex, hex.count == 7, hex.hasPrefix("#"), hex.dropFirst().allSatisfy(\.isHexDigit) else { return nil }
        let (r, g, b) = rgb(hex)
        let mx = max(r, g, b), mn = min(r, g, b)
        let chroma = Double(mx - mn) / 255
        let L = Double(mx + mn) / 2 / 255

        if chroma < 0.06 {
            if L >= 0.97 { return "White" }
            if L >= 0.86 { return "Off-white" }
            if L >= 0.65 { return "Light grey" }
            if L >= 0.42 { return "Grey" }
            if L >= 0.15 { return "Dark grey" }
            return "Black"
        }

        let d = Double(mx - mn)
        var hue: Double
        if mx == r { hue = 60 * (Double(g - b) / d).truncatingRemainder(dividingBy: 6) }
        else if mx == g { hue = 60 * (Double(b - r) / d + 2) }
        else { hue = 60 * (Double(r - g) / d + 4) }
        if hue < 0 { hue += 360 }

        var base: String
        switch hue {
        case ..<15, 345...: base = "red"
        case ..<45: base = "orange"
        case ..<70: base = "yellow"
        case ..<160: base = "green"
        case ..<200: base = "teal"
        case ..<250: base = "blue"
        case ..<290: base = "purple"
        default: base = "pink"
        }
        // Warm but washed-out reads as beige/brown, not "pale orange".
        if hue >= 15, hue < 55, chroma < 0.3 { base = L >= 0.65 ? "beige" : "brown" }
        let qual = L >= 0.75 ? "Pale " : (L <= 0.25 ? "Dark " : "")
        return (qual + base).prefix(1).uppercased() + (qual + base).dropFirst()
    }

    /// SwiftUI colour from a `#RRGGBB` string.
    static func swiftUI(_ hex: String?) -> Color? {
        guard let hex, let v = UInt32(hex.dropFirst(), radix: 16) else { return nil }
        return Color(hex: v)
    }
}
