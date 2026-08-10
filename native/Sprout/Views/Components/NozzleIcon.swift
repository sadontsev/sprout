import SwiftUI

/// Monochrome brand nozzle glyph (the app-icon mark, single-colour) for the Printer tab.
///
/// Tints with `color`. Same proportions as the Live Activity glyph — the source viewBox is
/// `48 30 96 142`, which this reproduces by scaling into the frame.
///
/// The Printer TAB does not use this view: a system tab bar renders its items through UIKit and needs
/// a tintable template image, which a `Canvas` cannot be. The same artwork therefore also exists as
/// `Assets.xcassets/TabNozzle.imageset` — same viewBox, same five shapes, same order. Change one and
/// change the other.
struct NozzleIcon: View {
    var color: Color
    var size: CGFloat = 24

    // The artwork's own coordinate space, so the shape coordinates below stay identical to the
    // source SVG rather than being re-derived by hand.
    private static let viewBox = CGRect(x: 48, y: 30, width: 96, height: 142)

    var body: some View {
        Canvas { ctx, canvasSize in
            let scale = min(canvasSize.width / Self.viewBox.width, canvasSize.height / Self.viewBox.height)
            ctx.scaleBy(x: scale, y: scale)
            ctx.translateBy(x: -Self.viewBox.minX, y: -Self.viewBox.minY)

            let shading = GraphicsContext.Shading.color(color)

            ctx.fill(Path(roundedRect: CGRect(x: 60, y: 36, width: 72, height: 50), cornerRadius: 12), with: shading)
            ctx.fill(Path(roundedRect: CGRect(x: 60, y: 80, width: 72, height: 9), cornerRadius: 4.5), with: shading)

            var cone = Path()
            cone.move(to: CGPoint(x: 74, y: 92))
            cone.addLine(to: CGPoint(x: 118, y: 92))
            cone.addLine(to: CGPoint(x: 106, y: 128))
            cone.addLine(to: CGPoint(x: 96, y: 150))
            cone.addLine(to: CGPoint(x: 86, y: 128))
            cone.closeSubpath()
            ctx.fill(cone, with: shading)

            ctx.fill(Path(ellipseIn: CGRect(x: 85, y: 109, width: 22, height: 22)), with: shading)
            ctx.fill(Path(roundedRect: CGRect(x: 58, y: 150, width: 76, height: 15), cornerRadius: 7.5), with: shading)
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}
