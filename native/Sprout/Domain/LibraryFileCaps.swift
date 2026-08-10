import Foundation

/// What a library file can actually be asked for.
///
/// These are CAPABILITY predicates, not descriptions, and they live here — outside any one view —
/// because the same questions are asked from the Files tab, its long-press menu and the print
/// wizard, and the answers drifted apart the first time they were asked in two places.
///
/// The distinction this type exists to keep is between `isSliced` and `hasGcode`. They sound like
/// synonyms and are not:
///
///  - `isSliced` answers *"was this prepared by a slicer?"* — a label. `slicedForModel` names the
///    machine a file was prepared for, which a plain project `.3mf` carries too (the live library
///    holds one that says "Creality K2 Pro" and contains no toolpaths at all).
///  - `hasGcode` answers *"will `GET /library/files/{id}/gcode` answer?"* — the capability the layer
///    viewer needs. Only a `gcode.3mf` has toolpaths; that plain `.3mf` answers **404**.
///
/// Gating "View layers" on the first shipped a menu item whose request 404'd. Anything that needs
/// toolpaths must ask `hasGcode`.
enum LibraryFileCaps {

    /// Whether the file was produced by a slicer. Drives the "sliced" BADGE and the type filter, and
    /// must NOT gate anything that needs toolpaths — see `hasGcode`.
    static func isSliced(_ f: LibraryFile) -> Bool {
        (f.fileType ?? "").contains("gcode") || !(f.slicedForModel ?? "").isEmpty
    }

    /// Whether the file actually contains toolpaths, i.e. whether `/gcode` will answer.
    ///
    /// The one predicate the layer viewer — and the wizard's "already sliced, nothing to re-slice"
    /// fast path — may be gated on.
    static func hasGcode(_ f: LibraryFile) -> Bool {
        (f.fileType ?? "").lowercased().contains("gcode")
    }

    /// Whether the 3D mesh viewer can render this file. It is an STL parser: a `.3mf` is a zip
    /// container it cannot open, so the exact type is the capability.
    static func isStl(_ f: LibraryFile) -> Bool {
        (f.fileType ?? "").lowercased() == "stl"
    }
}
