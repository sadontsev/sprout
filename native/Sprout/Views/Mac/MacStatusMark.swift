#if os(macOS)
import AppKit
import SwiftUI

/// One menu bar mark per printer state.
///
/// The status item used to have exactly two appearances: a percentage while printing, and the plain
/// nozzle for absolutely everything else. So "idle", "paused", "error", "complete" and "offline" —
/// five different situations, one of which is a failed print — were a single identical glyph. The
/// menu bar's whole job is to be readable without opening anything, and it was answering "is a print
/// running?" when the question is "what is the machine doing?".
///
/// Each mark is the same nozzle artboard with a badge drawn INTO it, so the item's width never
/// changes as state does. That matters more than it sounds: a status item that resizes shoves every
/// item to its left, and the user's muscle memory for "the wifi menu is here" breaks every time a
/// print starts.
enum MacStatusMark: String, CaseIterable, Sendable {
    case idle, heating, printing, paused, error, complete, drying, offline

    /// Which mark a state gets.
    ///
    /// A straight relabelling of `LAState`, which is the single ordered ladder the Live Activity tint
    /// also reads. Deliberately NOT a second `switch` over `DashKind` and `isPaused`: `DashKind` has
    /// no `paused` case at all — pause is `vm.isPaused` — so a hand-rolled version here would have
    /// silently reported every paused print as `printing`, which is the one state a menu bar exists
    /// to make obvious.
    static func mark(_ state: LAState) -> MacStatusMark {
        switch state {
        case .idle: return .idle
        case .heating: return .heating
        case .printing: return .printing
        case .paused: return .paused
        case .error: return .error
        case .complete: return .complete
        case .drying: return .drying
        case .offline: return .offline
        }
    }

    /// Whether the label shows this mark at all, or a number instead.
    ///
    /// Printing is the one state with something better to say than a picture, and mixing an image
    /// with text makes the item's width jump — so a percentage REPLACES the glyph rather than joining
    /// it. That decision predates this type and is deliberately preserved.
    var showsGlyph: Bool { self != .printing }

    /// Ink opacity for the nozzle body. Everything is a template image, so this is the only way to
    /// say "present but not doing anything" without introducing a colour.
    var inkOpacity: CGFloat {
        switch self {
        case .idle: return 0.55
        case .offline: return 0.38
        default: return 1.0
        }
    }

    /// The one sanctioned colour exception in the whole menu bar.
    ///
    /// A template image is tinted by the system and cannot carry colour, which is correct for every
    /// state but one: a failed print is the thing that must not be missed, and a monochrome exclam
    /// among monochrome neighbours is exactly what gets missed. The pip is drawn as a coloured
    /// overlay on a non-template composite for this state only.
    var pip: NSColor? { self == .error ? NSColor(hexString: LAColors.error) : nil }
}

/// Builds and caches the marks.
///
/// Built once per state and held for the process: `MacMenuBarLabel` reads this on every status
/// update, and rendering an `NSImage` per frame would be visible as a stutter in the bar.
@MainActor
enum MacStatusMarkArt {
    private static var cache: [MacStatusMark: NSImage] = [:]

    /// The nozzle artboard's aspect, so a badge lands in the same place at any height.
    private static let artboard = CGSize(width: 17.577, height: 26)

    static func image(_ mark: MacStatusMark, height: CGFloat = MacMenuBarLabel.glyphHeight) -> NSImage? {
        if let hit = cache[mark] { return hit }
        guard let built = build(mark, height: height) else { return nil }
        cache[mark] = built
        return built
    }

    private static func build(_ mark: MacStatusMark, height: CGFloat) -> NSImage? {
        guard let base = NSImage(named: "TabNozzle") else { return nil }
        let scale = height / artboard.height
        // Badges hang off the artboard's bottom-right, so the canvas is wider than the nozzle.
        let badge: CGFloat = mark == .printing || mark == .idle ? 0 : 10 * scale
        let size = NSSize(width: artboard.width * scale + badge * 0.45,
                          height: height)

        let image = NSImage(size: size, flipped: false) { _ in
            let nozzleRect = NSRect(x: 0, y: 0, width: artboard.width * scale, height: height)
            base.draw(in: nozzleRect, from: .zero, operation: .sourceOver,
                      fraction: mark.inkOpacity)

            let ctx = NSGraphicsContext.current?.cgContext
            ctx?.setLineCap(.round)
            ctx?.setLineJoin(.round)
            NSColor.black.setStroke()
            NSColor.black.setFill()

            switch mark {
            case .offline:
                // A 38° slash across the whole mark — the universal "not connected", and it reads at
                // 14 pt where a small badge would not.
                let path = NSBezierPath()
                path.lineWidth = 1.6 * scale
                path.lineCapStyle = .round
                path.move(to: NSPoint(x: nozzleRect.minX + 1 * scale, y: nozzleRect.minY + 3 * scale))
                path.line(to: NSPoint(x: nozzleRect.maxX - 1 * scale, y: nozzleRect.maxY - 3 * scale))
                path.stroke()
            case .heating, .paused, .error, .complete, .drying:
                drawBadge(mark, in: NSRect(x: size.width - badge, y: 0, width: badge, height: badge),
                          scale: scale)
            case .idle, .printing:
                break
            }
            return true
        }

        // Template EXCEPT for error: the system tints a template image and would flatten the red pip
        // to the same monochrome as everything else, which is precisely the state where that must not
        // happen.
        image.isTemplate = mark.pip == nil
        guard let pip = mark.pip else { return image }

        let composite = NSImage(size: size, flipped: false) { _ in
            // The nozzle stays monochrome and follows the bar, approximated as the label colour —
            // a non-template image cannot follow the appearance, so this picks the one that is right
            // in dark mode where the bar almost always is.
            NSColor.labelColor.set()
            image.draw(in: NSRect(origin: .zero, size: size))
            pip.setFill()
            let r = 3.0 * (height / artboard.height)
            NSBezierPath(ovalIn: NSRect(x: size.width - r * 2, y: 0, width: r * 2, height: r * 2)).fill()
            return true
        }
        return composite
    }

    /// The badge: a 10 pt disc bottom-right with a shape knocked into it.
    private static func drawBadge(_ mark: MacStatusMark, in rect: NSRect, scale: CGFloat) {
        // The disc is a hole punched in the nozzle so the badge reads at 14 pt — a filled disc over a
        // filled nozzle is a blob, and an outlined one loses its outline.
        NSGraphicsContext.current?.cgContext.setBlendMode(.clear)
        NSBezierPath(ovalIn: rect.insetBy(dx: -1 * scale, dy: -1 * scale)).fill()
        NSGraphicsContext.current?.cgContext.setBlendMode(.normal)
        NSColor.black.setFill()
        NSBezierPath(ovalIn: rect).fill()

        NSGraphicsContext.current?.cgContext.setBlendMode(.clear)
        let inner = rect.insetBy(dx: rect.width * 0.28, dy: rect.height * 0.28)
        let stroke = NSBezierPath()
        stroke.lineWidth = max(1.4 * scale, 1)
        stroke.lineCapStyle = .round

        switch mark {
        case .paused:
            let w = inner.width * 0.3
            NSBezierPath(rect: NSRect(x: inner.minX, y: inner.minY, width: w, height: inner.height)).fill()
            NSBezierPath(rect: NSRect(x: inner.maxX - w, y: inner.minY, width: w, height: inner.height)).fill()
        case .complete:
            stroke.move(to: NSPoint(x: inner.minX, y: inner.midY))
            stroke.line(to: NSPoint(x: inner.midX - inner.width * 0.05, y: inner.minY))
            stroke.line(to: NSPoint(x: inner.maxX, y: inner.maxY))
            stroke.stroke()
        case .error:
            stroke.move(to: NSPoint(x: inner.midX, y: inner.maxY))
            stroke.line(to: NSPoint(x: inner.midX, y: inner.minY + inner.height * 0.32))
            stroke.stroke()
            NSBezierPath(ovalIn: NSRect(x: inner.midX - stroke.lineWidth / 2, y: inner.minY,
                                        width: stroke.lineWidth, height: stroke.lineWidth)).fill()
        case .heating:
            // One rising stroke — the same vocabulary as the spool's heat, so the two amber-ish
            // states read as related.
            stroke.move(to: NSPoint(x: inner.midX, y: inner.minY))
            stroke.line(to: NSPoint(x: inner.midX, y: inner.maxY))
            stroke.stroke()
        case .drying:
            // The spool, shrunk into the badge. Ring plus hub only — the heat strokes do not survive
            // a 10 pt disc, and the amber tint is not available on a template image.
            let ring = inner.insetBy(dx: inner.width * 0.08, dy: inner.height * 0.08)
            stroke.appendOval(in: ring)
            stroke.stroke()
            NSBezierPath(ovalIn: NSRect(x: ring.midX - stroke.lineWidth,
                                        y: ring.midY - stroke.lineWidth,
                                        width: stroke.lineWidth * 2,
                                        height: stroke.lineWidth * 2)).fill()
        case .idle, .printing, .offline:
            break
        }
        NSGraphicsContext.current?.cgContext.setBlendMode(.normal)
    }
}

extension NSColor {
    /// The `#RRGGBB` strings `LAColors` carries. Falls back to grey rather than trapping — these are
    /// wire values.
    convenience init(hexString: String) {
        let hex = hexString.hasPrefix("#") ? String(hexString.dropFirst()) : hexString
        guard hex.count == 6, let v = UInt32(hex, radix: 16) else {
            self.init(white: 0.5, alpha: 1)
            return
        }
        self.init(srgbRed: CGFloat((v >> 16) & 0xFF) / 255,
                  green: CGFloat((v >> 8) & 0xFF) / 255,
                  blue: CGFloat(v & 0xFF) / 255,
                  alpha: 1)
    }
}
#endif
