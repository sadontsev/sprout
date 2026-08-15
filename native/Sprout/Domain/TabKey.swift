import Foundation

/// The app's top-level sections.
///
/// One enum for both platforms, as §2 requires — iOS renders five of these as a `TabView`, macOS
/// renders all six as sidebar rows. A second enum would let the two drift, and the selection is
/// persisted, so they would drift into a stored value the other platform cannot read.
///
/// **The raw values are a persisted format.** They are written to the Keychain config and to
/// `@SceneStorage`. Renaming a case silently resets someone's last-used section; `TabKeyTests` pins
/// every string.
///
/// `explore` is last on purpose. `allCases` is not what drives the iOS tab bar (`MainTabs`
/// enumerates its five explicitly), but appending rather than inserting means any future consumer
/// of `allCases` gets the five original sections in their original order.
enum TabKey: String, CaseIterable, Hashable, Sendable {
    case printer, library, jobs, ams, power
    /// macOS only. On iOS, Explore is reached by pushing from the Files `+` menu, not by a tab —
    /// there is no sixth tab, and `iosTabs` is what guarantees that.
    case explore

    var label: String {
        switch self {
        case .printer: "Printer"
        case .library: "Files"
        case .jobs: "Jobs"        // queue + history merged into one print timeline
        case .ams: "Hardware"
        case .power: "Power"
        case .explore: "Explore"
        }
    }

    /// The SF Symbol for the section. `printer` is the exception: its mark is the brand nozzle
    /// glyph, an asset-catalog template image, so it has no symbol name.
    var systemImage: String? {
        switch self {
        case .printer: nil
        case .library: "folder"
        case .jobs: "list.bullet"
        case .ams: "shippingbox"
        case .power: "power"
        case .explore: "square.grid.2x2"
        }
    }

    /// The five sections the iOS tab bar shows. Explore is deliberately absent.
    static let iosTabs: [TabKey] = [.printer, .library, .jobs, .ams, .power]

    /// The five that sit above the `BROWSE` header in the macOS sidebar (§2).
    static let macPrimary: [TabKey] = [.printer, .library, .jobs, .ams, .power]

    /// The `BROWSE` group. A group rather than a sixth peer row because Explore browses someone
    /// else's catalogue, not this printer — §2 keeps that distinction visible.
    static let macBrowse: [TabKey] = [.explore]

    /// `⌘1`–`⌘6`, in sidebar order.
    var commandDigit: Character? {
        guard let index = (Self.macPrimary + Self.macBrowse).firstIndex(of: self) else { return nil }
        return Character("\(index + 1)")
    }
}
