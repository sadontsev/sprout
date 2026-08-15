import Foundation
import UniformTypeIdentifiers

// The surviving pieces of the old UploadSheet.
//
// The sheet itself is gone: Explore became a page and `+` became a native Menu, which left the
// "Add a file" modal with nothing to present and `MakerWorldPanel` with nothing to present it.
// These outlived it because they were never about the sheet — they are about files and about
// reporting a failed request, and both jobs still exist.
//
// They live in Domain/ rather than beside a view because nothing here is a view or a platform:
// `LibraryUploader` calls `stageUploadCopy` from the shared layer, and `UploadFileKind.all` is also
// the exact UTI list the macOS drop target and file promises are declared against (§5.3).

enum UploadFileKind {
    /// What a file picker — or a drop target — will accept.
    ///
    /// Built with `UTType(tag:tagClass:conformingTo:)` rather than `UTType(filenameExtension:)`
    /// because `gcode` (and, on most systems, `3mf`) is not a registered type: the extension
    /// initialiser returns nil for those and the browser would end up filtering them out. The tag
    /// initialiser mints a dynamic type instead, which still matches by extension.
    static let all: [UTType] = ["3mf", "gcode", "stl"].compactMap {
        UTType(tag: $0, tagClass: .filenameExtension, conformingTo: .data)
    }
}

/// Copy a picked document into our own temp directory and return the copy.
///
/// Two reasons this is not optional. The picker hands back a security-scoped URL that is only
/// readable between `start`/`stopAccessingSecurityScopedResource`, and the upload outlives that
/// window; and the server takes the library's display name from the multipart `filename`, so the
/// copy has to keep the original basename — hence the per-upload subdirectory instead of a unique
/// filename.
///
/// The security scope matters more on macOS, not less: the app is sandboxed there too, and a URL
/// arriving from a drop or from `application(_:open:)` is scoped exactly like a picked one.
///
/// Free function, not a method, so it can run off the main actor: copying tens of megabytes is not
/// something to do while the UI is trying to animate.
func stageUploadCopy(_ picked: URL) throws -> URL {
    let scoped = picked.startAccessingSecurityScopedResource()
    defer { if scoped { picked.stopAccessingSecurityScopedResource() } }

    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent("upload-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let dest = dir.appendingPathComponent(picked.lastPathComponent)
    try FileManager.default.copyItem(at: picked, to: dest)
    return dest
}

/// The API's own `{"detail": …}` sentence, or nil.
///
/// Deliberately narrower than `BambuddyError.detail`, which falls back to the raw body: a proxy's
/// HTML error page is not something to put in front of a person, so callers keep their own wording
/// when there is no structured detail.
func uploadApiDetail(_ error: Error) -> String? {
    guard let e = error as? BambuddyError,
          let data = e.body.data(using: .utf8),
          let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
          let d = obj["detail"] as? String,
          !d.isEmpty
    else { return nil }
    return d
}
