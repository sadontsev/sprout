#if os(macOS)
import SwiftUI

/// The two button shapes the Mac design uses, at §8's heights.
///
/// These exist rather than `.borderedProminent` because the palette is the app's, not the system's:
/// `accent`/`accentInk` are a specific teal pair chosen for contrast against `s1`–`s4`, and the
/// system's prominent style paints the *user's* macOS accent colour instead — which turns the one
/// button that commits an action a different colour on every machine.
///
/// The height difference is deliberate and is §8's last line: 28 pt is the standard control, but
/// **the primary action in any view stays 34** so it still reads as the primary action. Anything
/// below 24 pt is out of bounds.
struct MacPrimaryButtonStyle: ButtonStyle {
    @Environment(\.palette) private var c
    @Environment(\.metrics) private var m
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(c.accentInk)
            .padding(.horizontal, 20)
            .frame(height: m.primaryControlHeight)
            .background(
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .fill(c.accent)
            )
            .opacity(isEnabled ? (configuration.isPressed ? 0.82 : 1) : 0.4)
            .contentShape(.rect)
            .animation(Motion.standard(0.12), value: configuration.isPressed)
    }
}

struct MacSecondaryButtonStyle: ButtonStyle {
    @Environment(\.palette) private var c
    @Environment(\.metrics) private var m
    @Environment(\.isEnabled) private var isEnabled

    /// Destructive secondaries keep the same shape and recolour the LABEL, as the prototype does —
    /// a filled red button next to a filled teal one reads as two primary actions.
    var role: MacButtonRole = .normal

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(role == .destructive ? c.error : c.t1)
            .padding(.horizontal, 18)
            .frame(height: m.primaryControlHeight)
            .background(
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .fill(c.s3)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .stroke(c.line2)
            )
            .opacity(isEnabled ? (configuration.isPressed ? 0.82 : 1) : 0.4)
            .contentShape(.rect)
            .animation(Motion.standard(0.12), value: configuration.isPressed)
    }
}

enum MacButtonRole { case normal, destructive }
#endif
