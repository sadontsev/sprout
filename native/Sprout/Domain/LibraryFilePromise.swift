import Foundation
import UniformTypeIdentifiers

/// What a library file should be VENDED as when it is dragged out of the app (§5.3).
///
/// Two questions, and getting either wrong produces a file the receiver mishandles rather than an
/// error anyone sees:
///
///  - **Which type identifier?** The receiver decides what it will accept from this alone. Offering
///    a `.stl` as `com.bambulab.3mf` makes a slicer accept a drop it cannot open.
///  - **What filename?** Finder writes exactly what it is given. A name with no extension, or the
///    wrong one, lands as a file macOS cannot identify — and this app's own `CFBundleDocumentTypes`
///    would then refuse to open the thing it just exported.
///
/// Both are answered from `LibraryFile.filename` rather than from `displayName`. `displayName`
/// prefers `printName`, which is free-form server text — a MakerWorld title like `Bracket 20/40`
/// carrying no extension at all. It is the right thing to SHOW and the wrong thing to write to disk.
enum LibraryFilePromise {

    /// The identifiers this app declares in `UTImportedTypeDeclarations`. Vending anything else
    /// would be claiming a type the bundle does not define.
    ///
    /// Ordered longest-suffix-first: `gcode.3mf` has to be tested before `3mf`, or every sliced file
    /// is vended as a plain project.
    private static let byExtension: [(suffix: String, identifier: String)] = [
        (".gcode.3mf", "com.bambulab.gcode-3mf"),
        (".3mf",       "com.bambulab.3mf"),
        (".gcode",     "com.bambulab.gcode"),
        (".stl",       UTType.data.identifier),
    ]

    /// The type to vend, or `public.data` when the name says nothing useful.
    ///
    /// `public.data` rather than nil: a drag that cannot name its type is still a drag of real
    /// bytes, and refusing to start one would hide a working export behind an unexplained dead
    /// gesture. Every receiver accepts `public.data`; the worst case is that it is filed generically.
    static func typeIdentifier(for file: LibraryFile) -> String {
        let name = file.filename.lowercased()
        for (suffix, identifier) in byExtension where name.hasSuffix(suffix) {
            // `.stl` maps to the system's own identifier, which the table stores as `public.data`
            // only because `UTType` cannot be a static-let literal here; resolve it properly.
            if suffix == ".stl" { return UTType.stl?.identifier ?? "public.standard-tesselated-geometry-format" }
            return identifier
        }
        return UTType.data.identifier
    }

    /// The name the receiver should write.
    ///
    /// Sanitised for path separators — a display name is user-derived and `Bracket 20/40.3mf` would
    /// otherwise be read by the receiver as a directory — and guaranteed to carry an extension, so
    /// a file exported to the Desktop is one this app would take back.
    static func filename(for file: LibraryFile) -> String {
        let raw = file.filename.trimmingCharacters(in: .whitespacesAndNewlines)
        let safe = LibraryBrowse.safeShareName(raw.isEmpty ? LibraryBrowse.displayName(file) : raw)
        return hasKnownExtension(safe) ? safe : safe + inferredExtension(for: file)
    }

    private static func hasKnownExtension(_ name: String) -> Bool {
        let lower = name.lowercased()
        return byExtension.contains { lower.hasSuffix($0.suffix) }
    }

    /// Falls back to the server's `fileType` when the filename carries no extension of its own.
    /// `.3mf` last because it is the only one that is a safe guess for an unknown model file.
    private static func inferredExtension(for file: LibraryFile) -> String {
        switch (file.fileType ?? "").lowercased() {
        case let t where t.contains("gcode.3mf"): ".gcode.3mf"
        case let t where t.contains("gcode"):     ".gcode"
        case "stl":                               ".stl"
        default:                                  ".3mf"
        }
    }
}

private extension UTType {
    /// The system type for a binary STL. Declared as an ALTERNATE handler in this app's
    /// `CFBundleDocumentTypes`, not an imported type, so it is looked up rather than hard-coded.
    static var stl: UTType? { UTType("public.standard-tesselated-geometry-format") }
}
