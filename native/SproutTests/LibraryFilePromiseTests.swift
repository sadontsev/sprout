import UniformTypeIdentifiers
import XCTest
@testable import Sprout

/// What a dragged-out library file is vended as (§5.3).
///
/// Both answers fail QUIETLY when wrong. A mistyped drag is accepted by a receiver that then cannot
/// open it; a misnamed one lands on the Desktop as a file macOS will not identify — and which this
/// app's own `CFBundleDocumentTypes` would refuse to take back.
final class LibraryFilePromiseTests: XCTestCase {

    private func file(_ filename: String, type: String? = nil, printName: String? = nil) -> LibraryFile {
        var f = LibraryFile(id: 7, filename: filename)
        f.fileType = type
        f.printName = printName
        return f
    }

    // MARK: - Type identifier

    /// `gcode.3mf` must be tested BEFORE `3mf`, or every sliced file is vended as a plain project
    /// and a slicer offered one re-slices something already sliced.
    func testASlicedThreeMFIsNotVendedAsAPlainOne() {
        XCTAssertEqual(
            LibraryFilePromise.typeIdentifier(for: file("bracket.gcode.3mf")),
            "com.bambulab.gcode-3mf"
        )
        XCTAssertEqual(
            LibraryFilePromise.typeIdentifier(for: file("bracket.3mf")),
            "com.bambulab.3mf"
        )
    }

    func testEachDeclaredTypeIsVendedAsItself() {
        XCTAssertEqual(LibraryFilePromise.typeIdentifier(for: file("a.gcode")), "com.bambulab.gcode")
        XCTAssertEqual(
            LibraryFilePromise.typeIdentifier(for: file("a.stl")),
            "public.standard-tesselated-geometry-format"
        )
    }

    func testTypeIsCaseInsensitive() {
        XCTAssertEqual(LibraryFilePromise.typeIdentifier(for: file("PLATE.3MF")), "com.bambulab.3mf")
        XCTAssertEqual(
            LibraryFilePromise.typeIdentifier(for: file("Bracket.GCODE.3MF")),
            "com.bambulab.gcode-3mf"
        )
    }

    /// An unrecognised name still drags. `public.data` is the honest answer — these ARE real bytes —
    /// and refusing to start the drag would hide a working export behind a dead gesture.
    func testAnUnknownNameStillDragsAsData() {
        XCTAssertEqual(LibraryFilePromise.typeIdentifier(for: file("notes")), UTType.data.identifier)
    }

    /// Only types this bundle actually declares may be vended. Claiming one it does not define is
    /// how a receiver ends up accepting a drop nothing can open.
    func testOnlyDeclaredTypesAreEverVended() {
        let declared: Set<String> = [
            "com.bambulab.3mf", "com.bambulab.gcode-3mf", "com.bambulab.gcode",
            "public.standard-tesselated-geometry-format", UTType.data.identifier,
        ]
        for name in ["a.3mf", "a.gcode.3mf", "a.gcode", "a.stl", "a.zip", ""] {
            XCTAssertTrue(
                declared.contains(LibraryFilePromise.typeIdentifier(for: file(name))),
                "\(name) vended an undeclared type"
            )
        }
    }

    // MARK: - Filename

    func testTheFilenameIsUsedVerbatimWhenItAlreadyNamesAType() {
        XCTAssertEqual(LibraryFilePromise.filename(for: file("bracket.gcode.3mf")), "bracket.gcode.3mf")
    }

    /// The name written to disk comes from `filename`, NOT `displayName`. `displayName` prefers
    /// `printName` — free-form server text, often a MakerWorld title with no extension at all.
    func testThePrintNameDoesNotDecideWhatIsWrittenToDisk() {
        let f = file("bracket-v4.3mf", printName: "Bracket 20/40")
        XCTAssertEqual(LibraryFilePromise.filename(for: f), "bracket-v4.3mf")
    }

    /// A display name is user-derived and may carry path separators. Finder reads those as
    /// directories.
    func testPathSeparatorsNeverReachTheFilename() {
        let f = file("", printName: "Bracket 20/40")
        let name = LibraryFilePromise.filename(for: f)
        XCTAssertFalse(name.contains("/"))
        XCTAssertFalse(name.contains("\\"))
    }

    /// An extensionless name gets one from the server's `fileType`, so what lands on the Desktop is
    /// a file this app would take back.
    func testAnExtensionlessNameGainsOneFromTheServersType() {
        XCTAssertEqual(LibraryFilePromise.filename(for: file("bracket", type: "gcode.3mf")), "bracket.gcode.3mf")
        XCTAssertEqual(LibraryFilePromise.filename(for: file("bracket", type: "stl")), "bracket.stl")
        XCTAssertEqual(LibraryFilePromise.filename(for: file("bracket", type: "3mf")), "bracket.3mf")
    }

    /// Nothing known at all still produces a usable, extensioned name rather than an empty one.
    func testThereIsAlwaysAName() {
        let name = LibraryFilePromise.filename(for: file(""))
        XCTAssertFalse(name.isEmpty)
        XCTAssertTrue(name.hasSuffix(".3mf"), "the safe default for an unidentified model file")
    }

    /// The name written to disk and the URL path segment are different questions with different
    /// sanitisers, and conflating them is how the download 404s.
    func testTheDiskNameAndTheUrlSegmentAreNotTheSameFunction() {
        let f = file("Bracket 20/40.3mf")
        XCTAssertEqual(LibraryFilePromise.filename(for: f), "Bracket 20-40.3mf")
        XCTAssertEqual(
            LibraryDownloadName.pathSegment(f.filename, fallback: "model-7"),
            "Bracket 20-40.3mf"
        )
    }
}

#if os(macOS)
/// The `NSItemProvider` itself, not just the strings that go into it.
///
/// A promise fails silently in a way the pure tests cannot see: register the wrong identifier and
/// the drag simply is not accepted, with no error anywhere. These assert what the receiver will
/// actually be offered.
final class MacFileDragProviderTests: XCTestCase {

    private func file(_ filename: String) -> LibraryFile {
        LibraryFile(id: 7, filename: filename)
    }

    @MainActor
    func testTheProviderOffersTheFilesOwnType() {
        let model = AppModel()
        let provider = MacFileDrag.provider(for: file("bracket.gcode.3mf"), model: model)
        XCTAssertTrue(
            provider.registeredTypeIdentifiers.contains("com.bambulab.gcode-3mf"),
            "offered \(provider.registeredTypeIdentifiers)"
        )
    }

    /// The receiver takes the written name from here. Without it Finder invents one.
    @MainActor
    func testTheProviderCarriesTheFilename() {
        let model = AppModel()
        let provider = MacFileDrag.provider(for: file("bracket.3mf"), model: model)
        XCTAssertEqual(provider.suggestedName, "bracket.3mf")
    }

    /// Exactly one representation. Registering a file AND a data representation lets a receiver pick
    /// the one that does not download, which is how a drop lands an empty file.
    @MainActor
    func testExactlyOneRepresentationIsOffered() {
        let model = AppModel()
        let provider = MacFileDrag.provider(for: file("a.stl"), model: model)
        XCTAssertEqual(provider.registeredTypeIdentifiers.count, 1)
    }

    /// Constructing the provider must not touch the network — it happens on mouse-down, for a drag
    /// the user may abandon. With no client configured this still returns a provider rather than
    /// throwing or hanging; the failure surfaces at DROP time, where there is a receiver to tell.
    @MainActor
    func testBuildingTheProviderNeedsNoServer() {
        let model = AppModel()
        XCTAssertNil(model.client)
        let provider = MacFileDrag.provider(for: file("a.3mf"), model: model)
        XCTAssertFalse(provider.registeredTypeIdentifiers.isEmpty)
    }
}
#endif

#if os(macOS)
/// A drag released back over Sprout is a CANCELLED drag, not an import.
///
/// The window accepts a drop anywhere (§5.3), and abandoning a drag over the window you dragged
/// from is the most ordinary way to cancel one. Without this the file you just exported is
/// re-uploaded as a duplicate.
final class MacDragRoundTripTests: XCTestCase {

    func testOurOwnStagedExportIsRecognised() {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(MacFileDrag.stagingPrefix + "ABC123", isDirectory: true)
            .appendingPathComponent("bracket.3mf")
        XCTAssertTrue(MacFileDrag.isOwnExport(url))
    }

    /// A real file the user drags in from Finder must still import, including one that merely lives
    /// somewhere with a similar-looking name.
    func testAFileFromElsewhereIsNotMistakenForOurs() {
        for path in ["/Users/x/Desktop/bracket.3mf",
                     "/Users/x/Downloads/drag-something/bracket.3mf",
                     "/tmp/sprout/bracket.3mf"] {
            XCTAssertFalse(MacFileDrag.isOwnExport(URL(fileURLWithPath: path)), path)
        }
    }

    /// The guard is on the STAGING DIRECTORY, not the filename — two different drags of the same
    /// file produce the same last component and only the directory tells them apart.
    func testTheGuardIsOnTheDirectoryNotTheName() {
        let ours = FileManager.default.temporaryDirectory
            .appendingPathComponent(MacFileDrag.stagingPrefix + "one", isDirectory: true)
            .appendingPathComponent("same-name.3mf")
        let theirs = URL(fileURLWithPath: "/Users/x/Desktop/same-name.3mf")
        XCTAssertTrue(MacFileDrag.isOwnExport(ours))
        XCTAssertFalse(MacFileDrag.isOwnExport(theirs))
    }
}
#endif
