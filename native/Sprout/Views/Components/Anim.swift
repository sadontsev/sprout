import SwiftUI

// Motion primitives, ported 1:1 from `src/components/anim/index.tsx` (Reanimated).
//
// The numbers here are the app's signature feel and were tuned against the Claude Design source —
// treat them as spec, not defaults. Where RN used a named Reanimated easing, the equivalent cubic
// bezier is given so the curve is identical rather than merely similar.

enum Motion {
    /// `Easing.bezier(0.34, 1.56, 0.64, 1)` — overshoots to 1.0978, which is what puts the tiny
    /// bounce in a button release.
    static func spring(_ duration: Double) -> Animation { .timingCurve(0.34, 1.56, 0.64, 1, duration: duration) }
    /// `Easing.bezier(0.3, 1.1, 0.5, 1)` — 0.24 % overshoot past the target digit row.
    static func roll(_ duration: Double) -> Animation { .timingCurve(0.3, 1.1, 0.5, 1, duration: duration) }
    /// `Easing.bezier(0.22, 1, 0.36, 1)` — ease-out-quint-ish: 76 % of the distance in the first
    /// 25 % of the time.
    static func rise(_ duration: Double) -> Animation { .timingCurve(0.22, 1, 0.36, 1, duration: duration) }
    /// Material standard `cubic-bezier(0.4, 0, 0.2, 1)`.
    static func standard(_ duration: Double) -> Animation { .timingCurve(0.4, 0, 0.2, 1, duration: duration) }
    /// `Easing.out(Easing.quad)` = `1-(1-t)²`, as its standard bezier approximation.
    static func outQuad(_ duration: Double) -> Animation { .timingCurve(0.25, 0.46, 0.45, 0.94, duration: duration) }
    /// `Easing.inOut(Easing.quad)` — Reanimated's implicit default easing.
    static func inOutQuad(_ duration: Double) -> Animation { .timingCurve(0.455, 0.03, 0.515, 0.955, duration: duration) }
    /// `Easing.inOut(Easing.ease)` where `Easing.ease` is `bezier(0.42, 0, 1, 1)`.
    static func inOutEase(_ duration: Double) -> Animation { .timingCurve(0.42, 0, 0.58, 1, duration: duration) }
}

// MARK: - Tap

/// Drop-in button style: scales to 0.955 + dims while held (design: `.tap:active`).
///
/// Press in 90 ms out-quad; press out 170 ms on the overshooting SPRING curve, so the release
/// briefly overshoots to ~1.0044 scale. That bounce is the signature — do not flatten it to a plain
/// ease.
struct TapStyle: ButtonStyle {
    var scale: CGFloat = 0.955
    var dim: Double = 0.62

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? scale : 1)
            .opacity(configuration.isPressed ? dim : 1)
            .animation(configuration.isPressed ? Motion.outQuad(0.09) : Motion.spring(0.17), value: configuration.isPressed)
    }
}

/// `Tap` — the RN component's role, as a button. Use for every pressable surface so press feedback
/// is uniform.
struct Tap<Content: View>: View {
    var scale: CGFloat = 0.955
    var dim: Double = 0.62
    var disabled: Bool = false
    var action: () -> Void
    @ViewBuilder var content: () -> Content

    var body: some View {
        Button(action: action, label: content)
            .buttonStyle(TapStyle(scale: scale, dim: dim))
            .disabled(disabled)
    }
}

// MARK: - RollingNumber

/// A number whose digits roll vertically when the value changes (600 ms, ROLL_EASE).
///
/// Digits use tabular figures so the column width never jitters; the separator deliberately does
/// NOT, matching the RN original.
struct RollingNumber: View {
    let value: Int
    var font: Font = .system(size: 34, weight: .bold)
    var color: Color = .primary
    /// Row height — the roll distance per digit.
    var digitHeight: CGFloat = 40

    private var digits: [Character] { Array(String(value)) }

    var body: some View {
        HStack(alignment: .bottom, spacing: 0) {
            ForEach(Array(digits.enumerated()), id: \.offset) { idx, ch in
                if let d = ch.wholeNumberValue {
                    DigitColumn(digit: d, height: digitHeight, font: font, color: color)
                } else {
                    Text(String(ch)).font(font).foregroundStyle(color)
                }
            }
        }
        .frame(height: digitHeight)
        .clipped()
    }

    private struct DigitColumn: View {
        let digit: Int
        let height: CGFloat
        let font: Font
        let color: Color

        var body: some View {
            VStack(spacing: 0) {
                ForEach(0...9, id: \.self) { n in
                    Text("\(n)")
                        .font(font)
                        .monospacedDigit()
                        .foregroundStyle(color)
                        .frame(height: height)
                }
            }
            .offset(y: -CGFloat(digit) * height + (height * 4.5))
            .frame(height: height, alignment: .center)
            .clipped()
            .animation(Motion.roll(0.6), value: digit)
        }
    }
}

// MARK: - PulseDot

/// A breathing status dot. Opacity 1 ↔ 0.22, each half `period/2` (default 1200 ms), inOut-quad,
/// forever. The glow shadow breathes with it because the animated opacity multiplies both.
struct PulseDot: View {
    let color: Color
    var size: CGFloat = 8
    var glow: Bool = true
    /// Full cycle in seconds (RN default 2400 ms).
    var period: Double = 2.4

    @State private var dim = false

    var body: some View {
        Circle()
            .fill(color)
            .frame(width: size, height: size)
            .shadow(color: glow ? color.opacity(0.85) : .clear, radius: size * 0.7)
            .opacity(dim ? 0.22 : 1)
            .animation(Motion.inOutQuad(period / 2).repeatForever(autoreverses: true), value: dim)
            .onAppear { dim = true }
    }
}

// MARK: - HeatBar

/// A temperature fill bar. Width eases over 600 ms out-quad; while `heating` the whole bar shimmers
/// 1 → 0.5 → 1 with 700 ms legs.
///
/// The heating→idle transition settles to full opacity over 250 ms rather than waiting for the loop
/// to finish, so the bar never freezes mid-dim.
struct HeatBar: View {
    /// 0...100.
    let pct: Double
    let heating: Bool
    var color: Color
    var track: Color
    var height: CGFloat = 6

    @State private var shimmer = false

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(track)
                Capsule()
                    .fill(color)
                    .frame(width: geo.size.width * min(max(pct / 100, 0), 1))
                    .animation(Motion.outQuad(0.6), value: pct)
            }
        }
        .frame(height: height)
        .opacity(heating && shimmer ? 0.5 : 1)
        .animation(heating ? Motion.inOutQuad(0.7).repeatForever(autoreverses: true) : Motion.inOutQuad(0.25), value: shimmer)
        .animation(Motion.inOutQuad(0.25), value: heating)
        .onChange(of: heating, initial: true) { _, isHeating in
            shimmer = isHeating
        }
    }
}

// MARK: - ProgressRing

/// The hero progress ring. Sweep transitions over 700 ms on the Material standard curve; starts at
/// 12 o'clock, sweeps clockwise, round cap. The glow halo breathes 1200 ms up / 1200 ms down.
struct ProgressRing<Content: View>: View {
    /// 0...1.
    let progress: Double
    var size: CGFloat = 190
    var lineWidth: CGFloat = 10
    var color: Color
    var track: Color
    var glow: Bool = true
    @ViewBuilder var label: () -> Content

    @State private var haloUp = false

    var body: some View {
        ZStack {
            if glow {
                Circle()
                    .fill(color)
                    .frame(width: size * 0.7, height: size * 0.7)
                    .blur(radius: 9)
                    .opacity(haloUp ? 0.6 : 0)
                    .animation(Motion.inOutQuad(1.2).repeatForever(autoreverses: true), value: haloUp)
                    .onAppear { haloUp = true }
            }
            Circle()
                .stroke(track, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
            Circle()
                .trim(from: 0, to: min(max(progress, 0), 1))
                .stroke(color, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                .rotationEffect(.degrees(-90))
                .animation(Motion.standard(0.7), value: progress)
            label()
        }
        .frame(width: size, height: size)
    }
}

// MARK: - FadeRise

/// Enter transition: opacity 0 → 1 while translating `dy` → 0, on RISE_EASE.
///
/// Used for the tab-change transition (dy 8 / 300 ms), the wizard step transition (dy 10 / 300 ms)
/// and popovers — including a NEGATIVE dy, which drops the content down into place.
struct FadeRise<Content: View>: View {
    var delay: Double = 0
    var dy: CGFloat = 11
    var duration: Double = 0.34
    @ViewBuilder var content: () -> Content

    @State private var shown = false

    var body: some View {
        content()
            .opacity(shown ? 1 : 0)
            .offset(y: shown ? 0 : dy)
            .onAppear {
                withAnimation(Motion.rise(duration).delay(delay)) { shown = true }
            }
    }
}

// MARK: - Shimmer (skeleton placeholder)

/// Loading skeleton: a 150 pt highlight sweeps from x = −160 to the view's width over 1400 ms,
/// inOut-ease, looping with no reverse (it snaps back off-screen, so the jump is invisible).
struct Shimmer: View {
    var base: Color
    var cornerRadius: CGFloat = 8

    @State private var phase: CGFloat = -160

    var body: some View {
        GeometryReader { geo in
            base.overlay(alignment: .leading) {
                Rectangle()
                    .fill(Color.white.opacity(0.06))
                    .frame(width: 150)
                    .offset(x: phase)
            }
            .onAppear {
                phase = -160
                withAnimation(Motion.inOutEase(1.4).repeatForever(autoreverses: false)) {
                    phase = geo.size.width
                }
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
    }
}

// MARK: - Toggle

/// The design's pill switch. 240 ms on the SPRING curve; the whole control presses to 0.92 (the one
/// place in the app that overrides `Tap`'s default scale).
struct PillToggle: View {
    @Binding var value: Bool
    var disabled: Bool = false
    var onColor: Color
    var offColor: Color
    var knob: Color

    var body: some View {
        Tap(scale: 0.92, disabled: disabled) {
            value.toggle()
        } content: {
            Capsule()
                .fill(value ? onColor : offColor)
                .frame(width: 46, height: 28)
                .overlay(alignment: value ? .trailing : .leading) {
                    Circle()
                        .fill(knob)
                        .frame(width: 22, height: 22)
                        .padding(.horizontal, 3)
                }
                .animation(Motion.spring(0.24), value: value)
        }
        .opacity(disabled ? 0.4 : 1)
    }
}

// MARK: - Confetti

/// One-shot celebration burst for a finished print.
///
/// Per piece: duration 1100 ms + fall (240–370) → 1340–1470 ms, delay 0–180 ms, horizontal drift
/// ±65 pt, total rotation ±280°, width 6–11 pt, height 0.62 × width, corner radius 2.
struct Confetti: View {
    var colors: [Color]
    var count: Int = 26

    private struct Piece: Identifiable {
        let id: Int
        let x: CGFloat
        let drift: CGFloat
        let fall: Double
        let delay: Double
        let rotation: Double
        let width: CGFloat
        let color: Color
    }

    @State private var pieces: [Piece] = []
    @State private var fired = false

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .top) {
                ForEach(pieces) { p in
                    RoundedRectangle(cornerRadius: 2)
                        .fill(p.color)
                        .frame(width: p.width, height: p.width * 0.62)
                        .offset(
                            x: p.x + (fired ? p.drift : 0),
                            y: fired ? geo.size.height + 40 : -20
                        )
                        .rotationEffect(.degrees(fired ? p.rotation : 0))
                        .opacity(fired ? 0 : 1)
                        .animation(
                            .timingCurve(0.2, 0.6, 0.4, 1, duration: 1.1 + p.fall).delay(p.delay),
                            value: fired
                        )
                }
            }
            .onAppear {
                guard pieces.isEmpty else { return }
                var rng = SystemRandomNumberGenerator()
                pieces = (0..<count).map { i in
                    Piece(
                        id: i,
                        x: CGFloat.random(in: 0...max(geo.size.width, 1), using: &rng),
                        drift: CGFloat.random(in: -65...65, using: &rng),
                        fall: Double.random(in: 0.240...0.370, using: &rng),
                        delay: Double.random(in: 0...0.180, using: &rng),
                        rotation: Double.random(in: -280...280, using: &rng),
                        width: CGFloat.random(in: 6...11, using: &rng),
                        color: colors.randomElement(using: &rng) ?? .white
                    )
                }
                fired = true
            }
        }
        .allowsHitTesting(false)
    }
}
