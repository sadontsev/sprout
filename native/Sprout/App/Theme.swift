import SwiftUI

/// Design tokens from docs/design/Bambu.dc.html (Claude Design) — dark + light variants.
///
/// Ported 1:1 from the RN app's `src/theme.ts`. The RN version mutated a live token object and
/// notified subscribers; SwiftUI resolves the same thing for free through the environment, so
/// `Palette` is a value type and the active one is read via `@Environment(\.palette)`.
struct Palette: Sendable, Equatable {
    let bg: Color
    let s1: Color
    let s2: Color
    let s3: Color
    let s4: Color
    let line: Color
    let line2: Color
    let t1: Color
    let t2: Color
    let t3: Color
    let accent: Color
    let accentInk: Color
    let accentDim: Color
    let running: Color
    let runningDim: Color
    let heating: Color
    let heatingDim: Color
    let paused: Color
    let pausedDim: Color
    let error: Color
    let errorDim: Color
    let idle: Color
    let idleDim: Color
    let sheet: Color
    let tabbar: Color
    /// Neutral well behind thumbnails/camera tiles.
    let thumb: Color
    /// Supports accent (amber) — matches the layer-view support color.
    let supports: Color
    /// Ring drawn around every filament colour swatch. Its job is to separate the swatch from the
    /// CARD it sits on, so it is chosen for contrast against the SURFACES, not against the fill — a
    /// white spool on a white card was invisible. >= 3:1 vs bg/s1/s2/s3/s4/sheet.
    /// `line2` is only ~1.4:1, which is why swatches that already had a hairline still disappeared.
    let swatchRing: Color

    static let dark = Palette(
        bg: Color(hex: 0x0A0B0C),
        s1: Color(hex: 0x131517),
        s2: Color(hex: 0x191C1F),
        s3: Color(hex: 0x23272B),
        s4: Color(hex: 0x2D3237),
        line: Color(white: 1, opacity: 0.07),
        line2: Color(white: 1, opacity: 0.12),
        t1: Color(hex: 0xF3F5F7),
        t2: Color(hex: 0xA4ABB2),
        t3: Color(hex: 0x6B7177),
        accent: Color(hex: 0x2BD4C0),
        accentInk: Color(hex: 0x04201D),
        accentDim: Color(hex: 0x2BD4C0, opacity: 0.15),
        running: Color(hex: 0x30D158),
        runningDim: Color(hex: 0x30D158, opacity: 0.15),
        heating: Color(hex: 0xFF9F0A),
        heatingDim: Color(hex: 0xFF9F0A, opacity: 0.15),
        paused: Color(hex: 0x0A84FF),
        pausedDim: Color(hex: 0x0A84FF, opacity: 0.15),
        error: Color(hex: 0xFF453A),
        errorDim: Color(hex: 0xFF453A, opacity: 0.15),
        idle: Color(hex: 0x8E9398),
        idleDim: Color(hex: 0x8E9398, opacity: 0.14),
        sheet: Color(hex: 0x16181B),
        tabbar: Color(hex: 0x0D0E10, opacity: 0.72),
        thumb: Color(hex: 0x0E1113),
        supports: Color(hex: 0xE8A23D),
        swatchRing: Color(hex: 0x8E9398)
    )

    static let light = Palette(
        bg: Color(hex: 0xEFF1F3),
        s1: Color(hex: 0xFFFFFF),
        s2: Color(hex: 0xF5F6F8),
        s3: Color(hex: 0xEAECEF),
        s4: Color(hex: 0xDEE1E5),
        line: Color(white: 0, opacity: 0.08),
        line2: Color(white: 0, opacity: 0.13),
        t1: Color(hex: 0x0D1012),
        t2: Color(hex: 0x585E64),
        t3: Color(hex: 0x878D94),
        accent: Color(hex: 0x0EAE9C),
        accentInk: Color(hex: 0xFFFFFF),
        accentDim: Color(hex: 0x0EAE9C, opacity: 0.14),
        running: Color(hex: 0x23B24A),
        runningDim: Color(hex: 0x23B24A, opacity: 0.14),
        heating: Color(hex: 0xE0860A),
        heatingDim: Color(hex: 0xE0860A, opacity: 0.14),
        paused: Color(hex: 0x0A84FF),
        pausedDim: Color(hex: 0x0A84FF, opacity: 0.12),
        error: Color(hex: 0xE5392E),
        errorDim: Color(hex: 0xE5392E, opacity: 0.12),
        idle: Color(hex: 0x9AA0A6),
        idleDim: Color(hex: 0x9AA0A6, opacity: 0.14),
        sheet: Color(hex: 0xFFFFFF),
        tabbar: Color(hex: 0xF4F6F8, opacity: 0.8),
        thumb: Color(hex: 0xE4E7EA),
        supports: Color(hex: 0xC77E14),
        swatchRing: Color(hex: 0x6E7378)
    )

    static func forScheme(_ scheme: ColorScheme) -> Palette {
        scheme == .dark ? .dark : .light
    }
}

extension Color {
    init(hex: UInt32, opacity: Double = 1) {
        self.init(
            .sRGB,
            red: Double((hex >> 16) & 0xFF) / 255,
            green: Double((hex >> 8) & 0xFF) / 255,
            blue: Double(hex & 0xFF) / 255,
            opacity: opacity
        )
    }
}

private struct PaletteKey: EnvironmentKey {
    static let defaultValue = Palette.dark
}

extension EnvironmentValues {
    var palette: Palette {
        get { self[PaletteKey.self] }
        set { self[PaletteKey.self] = newValue }
    }
}

/// Monospaced family for the SF-Mono labels in the design. RN used Menlo; SF Mono is the system
/// equivalent and is what `.monospaced()` resolves to.
extension Font {
    static func mono(_ size: CGFloat, weight: Font.Weight = .semibold) -> Font {
        .system(size: size, weight: weight).monospaced()
    }
}

extension View {
    /// The design's card shadow.
    ///
    /// `compositingGroup()` is load-bearing: without it SwiftUI shadows every glyph and stroke in
    /// the subtree individually, so text inside a card picks up its own drop shadow and looks
    /// smudged. Flattening first means the shadow is cast by the card's silhouette, which is what a
    /// card shadow means.
    func shadow1() -> some View {
        compositingGroup()
            .shadow(color: .black.opacity(0.5), radius: 2, x: 0, y: 1)
    }
}
