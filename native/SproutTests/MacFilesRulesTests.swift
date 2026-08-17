import XCTest
@testable import Sprout

// The pure rules behind the Mac Files section, and behind the Printer SD half in particular.
//
// **These are the first tests this surface has ever had.** Before this file, a grep of `SproutTests/`
// for `MacFileBrowse` returned nothing at all — 1,450 lines of section logic, including every filter,
// sort and naming rule the two segments share, with zero coverage. The SD parity work needed those
// rules to be trustworthy before it could lean on them, so they are pinned here alongside the new
// ones rather than left for later.

// MARK: - Fixtures

private func sdFile(_ name: String, in folder: String = "/cache", bytes: Double? = 1_000) -> PrinterFile {
    PrinterFile(name: name, isDirectory: false, size: bytes.map(LooseNumber.init),
                path: "\(folder)/\(name)", mtime: nil)
}

private func sdFolder(_ path: String) -> PrinterFile {
    PrinterFile(name: (path as NSString).lastPathComponent, isDirectory: true, size: nil,
                path: path, mtime: nil)
}

// MARK: - SdFileCaps

/// What the printer's own storage will actually serve.
///
/// The panel these gate used to say "Deleting is the only action available here" over a card that
/// serves plate renders, posters, bytes and G-code. That sentence was true of the app and false of
/// the printer — the inverse of CLAUDE.md's recurring bug, and the reason this type exists.
final class SdFileCapsTests: XCTestCase {

    // MARK: Layers

    /// `.gcode.3mf` and nothing else — the same distinction `LibraryFileCaps` keeps between
    /// `isSliced` and `hasGcode`, spelled against a filename because that is all an SD row carries.
    func testOnlyASlicedThreeMfOffersLayers() {
        XCTAssertTrue(SdFileCaps.canViewLayers(sdFile("cube.gcode.3mf")))
        XCTAssertTrue(SdFileCaps.canViewLayers(sdFile("CUBE.GCODE.3MF")))
        XCTAssertFalse(SdFileCaps.canViewLayers(sdFile("cube.3mf")))
        XCTAssertFalse(SdFileCaps.canViewLayers(sdFile("cube.stl")))
        XCTAssertFalse(SdFileCaps.canViewLayers(sdFile("notes.txt")))
    }

    /// A folder is never viewable, whatever it is called. `/prints.gcode.3mf/` as a directory name is
    /// absurd and is exactly the sort of thing a filename-based predicate gets wrong.
    func testAFolderNeverOffersLayers() {
        XCTAssertFalse(SdFileCaps.canViewLayers(sdFolder("/cache/cube.gcode.3mf")))
    }

    // MARK: Play

    /// `.mp4` only. `.avi` is what older firmwares wrote and AVFoundation will not play it, so
    /// offering Play for one would be a dead button.
    func testOnlyMp4Plays() {
        XCTAssertTrue(SdFileCaps.canPlay(sdFile("video_2026-07-05_15-16-02.mp4", in: "/timelapse")))
        XCTAssertTrue(SdFileCaps.canPlay(sdFile("clip.MP4")))
        XCTAssertFalse(SdFileCaps.canPlay(sdFile("clip.avi")))
        XCTAssertFalse(SdFileCaps.canPlay(sdFile("cube.gcode.3mf")))
        XCTAssertFalse(SdFileCaps.canPlay(sdFolder("/timelapse")))
    }

    /// Play and Layers are mutually exclusive in practice, which is what lets the inspector draw one
    /// headline button rather than reserving space for two.
    func testPlayAndLayersAreNeverBothOffered() {
        for name in ["cube.gcode.3mf", "clip.mp4", "notes.txt", "cube.3mf"] {
            let f = sdFile(name)
            XCTAssertFalse(SdFileCaps.canPlay(f) && SdFileCaps.canViewLayers(f), name)
        }
    }

    // MARK: Download and delete

    func testEveryFileDownloadsAndNoFolderDoes() {
        XCTAssertTrue(SdFileCaps.canDownload(sdFile("notes.txt")))
        XCTAssertTrue(SdFileCaps.canDownload(sdFile("cube.gcode.3mf")))
        XCTAssertFalse(SdFileCaps.canDownload(sdFolder("/cache")))
    }

    func testDeleteMatchesDownload() {
        for f in [sdFile("a.txt"), sdFile("b.mp4"), sdFolder("/cache")] {
            XCTAssertEqual(SdFileCaps.canDelete(f), SdFileCaps.canDownload(f), f.path)
        }
    }

    // MARK: The two genuine gaps

    /// Printing from the card is refused for EVERY entry, including a sliced file that would print
    /// perfectly well if it were in the library. There is no path-based print or enqueue endpoint;
    /// the constraint is the API's, not the file's.
    func testNothingOnTheCardCanBePrinted() {
        for name in ["cube.gcode.3mf", "cube.3mf", "cube.stl", "clip.mp4", "notes.txt"] {
            XCTAssertFalse(SdFileCaps.canPrint(sdFile(name)), name)
        }
        XCTAssertFalse(SdFileCaps.canPrint(sdFolder("/cache")))
    }

    /// The 3D view too — and notably for an `.stl`, which is the case that would tempt someone to
    /// "fix" this by reusing `LibraryFileCaps.isStl`. Nothing turns a printer path into a mesh.
    func testNothingOnTheCardOpensInThreeD() {
        for name in ["cube.stl", "cube.gcode.3mf", "cube.3mf"] {
            XCTAssertFalse(SdFileCaps.canView3D(sdFile(name)), name)
        }
    }

    /// The refusals must not be interchangeable strings: printing and the mesh view are refused for
    /// different reasons, and the single sentence that used to bundle them was half false.
    func testTheTwoRefusalsSayDifferentThings() {
        XCTAssertNotEqual(SdFileCaps.noPrintNote, SdFileCaps.noMeshNote)
        // The print note names the remedy, because there genuinely is one.
        XCTAssertTrue(SdFileCaps.noPrintNote.lowercased().contains("library"))
        // Neither may claim layer preview is unavailable — it is the thing that just became available.
        for note in [SdFileCaps.noPrintNote, SdFileCaps.noMeshNote] {
            XCTAssertFalse(note.lowercased().contains("layer preview"), note)
        }
    }

    /// The Mac's "no layers" wording is the library viewer's, verbatim. Two wordings of one refusal is
    /// how a user learns to distrust both.
    func testTheLayersRefusalMatchesTheViewers() {
        #if os(macOS)
        XCTAssertEqual(SdFileCaps.noLayersNote, MacViewerCopy.noLayers)
        #endif
    }

    // MARK: Preview

    func testASlicedFileShowsItsPlate() {
        XCTAssertEqual(SdFileCaps.preview(sdFile("cube.gcode.3mf")), .plate)
    }

    /// A recording's poster is a DIFFERENT file, beside it in a `thumbnail` subfolder — so the case
    /// carries the path rather than implying the entry's own.
    func testARecordingShowsThePrintersPoster() {
        let pf = sdFile("video_2026-07-05_15-16-02.mp4", in: "/timelapse")
        XCTAssertEqual(SdFileCaps.preview(pf),
                       .poster(path: "/timelapse/thumbnail/video_2026-07-05_15-16-02.jpg"))
    }

    /// ipcam basenames contain dots, and only the final extension may be swapped.
    func testAnIpcamPosterKeepsTheDottedBasename() {
        let pf = sdFile("ipcam-record.2026-04-21_22-12-16.0.mp4", in: "/ipcam")
        XCTAssertEqual(SdFileCaps.preview(pf),
                       .poster(path: "/ipcam/thumbnail/ipcam-record.2026-04-21_22-12-16.0.jpg"))
    }

    func testEverythingElseFallsBackToAGlyph() {
        XCTAssertEqual(SdFileCaps.preview(sdFile("notes.txt")), .glyph)
        XCTAssertEqual(SdFileCaps.preview(sdFile("cube.3mf")), .glyph)
    }

    /// A folder is a glyph even inside `/timelapse`: the poster convention names a file beside a
    /// recording, and a directory has no poster to fetch.
    func testAFolderIsAlwaysAGlyph() {
        XCTAssertEqual(SdFileCaps.preview(sdFolder("/timelapse")), .glyph)
        XCTAssertEqual(SdFileCaps.preview(sdFolder("/ipcam")), .glyph)
    }

    // MARK: Naming and symbols

    /// A recording's filename is a timestamp the printer wrote; everything else keeps its own name.
    func testARecordingIsNamedByItsTimestamp() {
        XCTAssertEqual(SdFileCaps.displayName(sdFile("video_2026-07-05_15-16-02.mp4")), "Jul 5, 15:16")
        XCTAssertEqual(SdFileCaps.displayName(sdFile("cube.gcode.3mf")), "cube.gcode.3mf")
        XCTAssertEqual(SdFileCaps.displayName(sdFolder("/cache/models")), "models")
    }

    /// An `.mp4` with no timestamp in it falls back to the raw name rather than inventing a date.
    func testAnUnstampedRecordingKeepsItsName() {
        XCTAssertEqual(SdFileCaps.displayName(sdFile("holiday.mp4")), "holiday.mp4")
    }

    /// One symbol source for both layouts, so a file cannot be a `shippingbox` in the list and a
    /// `doc` in the grid.
    func testSymbolsDistinguishTheFourKinds() {
        XCTAssertEqual(SdFileCaps.symbol(sdFolder("/timelapse")), "film")
        XCTAssertEqual(SdFileCaps.symbol(sdFolder("/cache")), "folder")
        XCTAssertEqual(SdFileCaps.symbol(sdFile("cube.gcode.3mf")), "shippingbox")
        XCTAssertEqual(SdFileCaps.symbol(sdFile("clip.mp4")), "film")
        XCTAssertEqual(SdFileCaps.symbol(sdFile("notes.txt")), "doc")
    }
}

// MARK: - Name sanitising

/// One rule, three former copies.
///
/// `pathSegment` (URL segment) and `fileName` (cache filename) differ by exactly one character, and
/// the SD share needed the second. Writing a fourth copy is how three copies disagree.
final class LibraryDownloadNameTests: XCTestCase {

    func testSeparatorsBecomeOneDash() {
        XCTAssertEqual(LibraryDownloadName.pathSegment("Bracket 20/40", fallback: "x"), "Bracket 20-40")
        XCTAssertEqual(LibraryDownloadName.pathSegment("a\\b", fallback: "x"), "a-b")
    }

    /// Runs collapse rather than producing a dash per character. This is what the regex-based
    /// `safeShareName` has always done, and it is pinned so adopting the shared rule cannot silently
    /// rename anyone's cached downloads.
    func testRunsOfSeparatorsCollapse() {
        XCTAssertEqual(LibraryDownloadName.pathSegment("a//b", fallback: "x"), "a-b")
        XCTAssertEqual(LibraryDownloadName.fileName("a/\\:b", fallback: "x"), "a-b")
    }

    /// The one character that separates the two questions: legal in a URL path segment, a hazard in a
    /// filename.
    func testOnlyTheFilenameRuleStripsAColon() {
        XCTAssertEqual(LibraryDownloadName.pathSegment("Bracket 20:40", fallback: "x"), "Bracket 20:40")
        XCTAssertEqual(LibraryDownloadName.fileName("Bracket 20:40", fallback: "x"), "Bracket 20-40")
    }

    func testControlCharactersAreDropped() {
        XCTAssertEqual(LibraryDownloadName.fileName("a\u{7}b\u{7F}", fallback: "x"), "ab")
    }

    /// `.` and `..` fold away during URL resolution, and an empty name leaves a trailing slash with
    /// no segment at all. Those are the names that BREAK a URL, and they are the ones that fall back.
    func testTheNamesThatWouldBreakAUrlFallBack() {
        for name in ["", "   ", ".", "..", "\u{7}"] {
            XCTAssertEqual(LibraryDownloadName.fileName(name, fallback: "fallback"), "fallback", name)
            XCTAssertEqual(LibraryDownloadName.pathSegment(name, fallback: "fallback"), "fallback", name)
        }
    }

    /// A name made only of separators becomes `-`, and deliberately does NOT fall back.
    ///
    /// `-` is a legal path segment and a legal filename, so nothing downstream breaks — the fallback
    /// list is for names that would corrupt the URL, not for names that are merely useless. Pinned
    /// because it is the sort of edge a future tidy-up would "fix" into a behaviour change.
    func testANameOfOnlySeparatorsBecomesADash() {
        XCTAssertEqual(LibraryDownloadName.pathSegment("/", fallback: "fallback"), "-")
        XCTAssertEqual(LibraryDownloadName.pathSegment("///", fallback: "fallback"), "-")
        XCTAssertEqual(LibraryDownloadName.fileName(":/:", fallback: "fallback"), "-")
    }
}

#if os(macOS)

// MARK: - MacFileBrowse

/// The filter/sort/naming rules the Files section runs on every keystroke — untested until now.
final class MacFileBrowseTests: XCTestCase {

    private func lib(_ id: Int, _ filename: String, printName: String? = nil,
                     type: String? = nil, size: Double? = nil) -> LibraryFile {
        var f = LibraryFile(id: id, filename: filename)
        f.printName = printName
        f.fileType = type
        f.fileSize = size.map(LooseNumber.init)
        return f
    }

    // MARK: Display names

    /// Upload names arrive percent-encoded, and a decoded name is what the user typed.
    func testDisplayNamesArePercentDecoded() {
        XCTAssertEqual(MacFileBrowse.displayName(lib(1, "Adapter%20hexagon.stl")), "Adapter hexagon.stl")
    }

    /// `printName` wins when it is there and non-empty; an empty one must not beat a real filename.
    func testPrintNameWinsUnlessItIsEmpty() {
        XCTAssertEqual(MacFileBrowse.displayName(lib(1, "raw.stl", printName: "Nice Name")), "Nice Name")
        XCTAssertEqual(MacFileBrowse.displayName(lib(1, "raw.stl", printName: "")), "raw.stl")
    }

    /// A file with no usable name at all still gets one, because a blank card is unclickable.
    func testANamelessFileFallsBackToItsId() {
        XCTAssertEqual(MacFileBrowse.displayName(lib(42, "", printName: "")), "file-42")
    }

    /// A malformed escape decodes to nil, and the raw name beats nothing.
    func testAMalformedEscapeKeepsTheRawName() {
        XCTAssertEqual(MacFileBrowse.displayName(lib(1, "100%.stl")), "100%.stl")
    }

    // MARK: Filtering

    /// The query matches the decoded name AND the raw filename, so "hexagon" finds
    /// `Adapter%20hexagon.stl` whichever form the user has in mind.
    func testTheFilterMatchesBothFormsOfTheName() {
        let files = [lib(1, "Adapter%20hexagon.stl"), lib(2, "cube.3mf")]
        XCTAssertEqual(MacFileBrowse.filter(files, query: "hexagon").map(\.id), [1])
        XCTAssertEqual(MacFileBrowse.filter(files, query: "%20").map(\.id), [1])
        XCTAssertEqual(MacFileBrowse.filter(files, query: "CUBE").map(\.id), [2])
    }

    /// An empty or whitespace query is not a filter. Returning nothing for a stray space would read
    /// as an empty library.
    func testAnEmptyQueryFiltersNothing() {
        let files = [lib(1, "a"), lib(2, "b")]
        XCTAssertEqual(MacFileBrowse.filter(files, query: "").count, 2)
        XCTAssertEqual(MacFileBrowse.filter(files, query: "   ").count, 2)
    }

    /// The SD filter existing at all was a defect fix: the search field sat live over the Printer SD
    /// segment and filtered nothing.
    func testThePrinterFilterMatchesNamesAndFolders() {
        let rows = [sdFile("cube.gcode.3mf"), sdFolder("/cache/models"), sdFile("notes.txt")]
        XCTAssertEqual(MacFileBrowse.filterPrinterFiles(rows, query: "cube").map(\.name), ["cube.gcode.3mf"])
        // A folder is a thing you are looking for.
        XCTAssertEqual(MacFileBrowse.filterPrinterFiles(rows, query: "models").map(\.name), ["models"])
        XCTAssertEqual(MacFileBrowse.filterPrinterFiles(rows, query: "  ").count, 3)
    }

    // MARK: Sorting

    /// `.server` is the ABSENCE of an order, not an order — the whole reason the case exists.
    func testServerOrderIsReturnedUntouched() {
        let files = [lib(3, "c"), lib(1, "a"), lib(2, "b")]
        XCTAssertEqual(MacFileBrowse.sort(files, by: .server).map(\.id), [3, 1, 2])
    }

    func testNameSizeAndTypeOrders() {
        let files = [
            lib(1, "banana", type: "stl", size: 100),
            lib(2, "apple", type: "3mf", size: 300),
            lib(3, "cherry", type: "gcode.3mf", size: 200),
        ]
        XCTAssertEqual(MacFileBrowse.sort(files, by: .name).map(\.id), [2, 1, 3])
        // Size is DESCENDING — the biggest file is the one you came looking for.
        XCTAssertEqual(MacFileBrowse.sort(files, by: .size).map(\.id), [2, 3, 1])
        XCTAssertEqual(MacFileBrowse.sort(files, by: .type).map(\.id), [2, 3, 1])
    }

    /// Every comparator falls back to the name, so two equal files cannot swap places between
    /// renders — `sorted(by:)` is not stable, and a grid that reshuffles on every keystroke looks
    /// broken even when the order is technically valid.
    func testEqualKeysFallBackToTheNameSoTheOrderIsStable() {
        let files = [lib(1, "zebra", type: "stl", size: 100), lib(2, "apple", type: "stl", size: 100)]
        XCTAssertEqual(MacFileBrowse.sort(files, by: .size).map(\.id), [2, 1])
        XCTAssertEqual(MacFileBrowse.sort(files, by: .type).map(\.id), [2, 1])
    }

    /// A missing size sorts as zero rather than trapping or floating to the top.
    func testAMissingSizeSortsLast() {
        let files = [lib(1, "a", size: nil), lib(2, "b", size: 50)]
        XCTAssertEqual(MacFileBrowse.sort(files, by: .size).map(\.id), [2, 1])
    }

    /// Directories come first whatever the sort: a folder is not a file, and ordering the two
    /// together by size says nothing about either.
    func testFoldersLeadEverySdOrder() {
        let rows = [sdFile("z.txt", bytes: 900), sdFolder("/a/mmm"), sdFile("a.txt", bytes: 100), sdFolder("/a/aaa")]
        for order: MacFileSort in [.server, .name, .size, .type] {
            let sorted = MacFileBrowse.sortPrinterFiles(rows, by: order)
            XCTAssertEqual(sorted.prefix(2).map(\.isDirectory), [true, true], "\(order)")
        }
    }

    /// `.server` partitions rather than sorts, so the printer's own order survives inside each group.
    func testServerOrderKeepsThePrintersSequenceWithinEachGroup() {
        let rows = [sdFile("z.txt"), sdFolder("/a/mmm"), sdFile("a.txt"), sdFolder("/a/aaa")]
        XCTAssertEqual(MacFileBrowse.sortPrinterFiles(rows, by: .server).map(\.name),
                       ["mmm", "aaa", "z.txt", "a.txt"])
    }

    /// The SD listing has no type field, so the extension IS the type.
    func testTheSdTypeOrderUsesTheExtension() {
        let rows = [sdFile("b.txt"), sdFile("a.stl"), sdFile("c.mp4")]
        XCTAssertEqual(MacFileBrowse.sortPrinterFiles(rows, by: .type).map(\.name),
                       ["c.mp4", "a.stl", "b.txt"])
    }

    // MARK: Bytes and crumbs

    /// Zero and nil both render as nothing — an unknown size should take up no space rather than
    /// claim "0 B".
    func testUnknownSizesRenderAsNothing() {
        XCTAssertEqual(MacFileBrowse.bytes(nil), "")
        XCTAssertEqual(MacFileBrowse.bytes(0), "")
        XCTAssertEqual(MacFileBrowse.bytes(.nan), "")
        XCTAssertEqual(MacFileBrowse.bytes(.infinity), "")
    }

    func testDecimalUnitsMatchTheServersAccounting() {
        XCTAssertEqual(MacFileBrowse.bytes(500), "500 B")
        XCTAssertEqual(MacFileBrowse.bytes(2_000), "2 KB")
        XCTAssertEqual(MacFileBrowse.bytes(2_000_000), "2.0 MB")
    }

    /// Each crumb carries the path clicking it navigates to, which is what makes the breadcrumb a
    /// control and not a caption.
    func testCrumbsCarryTheirOwnPaths() {
        let crumbs = MacFileBrowse.crumbs("/cache/models")
        XCTAssertEqual(crumbs.map(\.name), ["printer:", "cache", "models"])
        XCTAssertEqual(crumbs.map(\.path), ["/", "/cache", "/cache/models"])
    }

    func testTheRootIsASingleCrumb() {
        XCTAssertEqual(MacFileBrowse.crumbs("/").map(\.name), ["printer:"])
    }

    /// The share name delegates to the shared rule and must not have changed behaviour.
    func testShareNamesStillCollapseSeparatorsAndFallBack() {
        XCTAssertEqual(MacFileBrowse.safeShareName("Bracket 20/40"), "Bracket 20-40")
        XCTAssertEqual(MacFileBrowse.safeShareName("a//b"), "a-b")
        XCTAssertEqual(MacFileBrowse.safeShareName("x:y"), "x-y")
        XCTAssertEqual(MacFileBrowse.safeShareName("   "), "file")
    }
}

// MARK: - Layout

/// The grid/list switch, which now governs BOTH segments.
final class MacFilesLayoutTests: XCTestCase {

    /// A persisted format: the raw values are written to `@SceneStorage`, so renaming one silently
    /// resets the user's layout instead of failing.
    func testTheRawValuesArePersistedAndMustNotDrift() {
        XCTAssertEqual(MacFilesLayout.grid.rawValue, "grid")
        XCTAssertEqual(MacFilesLayout.list.rawValue, "list")
        XCTAssertEqual(MacFileSort.server.rawValue, "server")
        XCTAssertEqual(Set(MacFileSort.allCases.map(\.rawValue)), ["server", "name", "size", "type"])
    }

    /// `.server` is never described as "sorted by" anything, on either segment — and it is named for
    /// whose order it actually is, which differs between them.
    func testServerOrderIsNamedForWhoseOrderItIs() {
        XCTAssertEqual(MacFileSort.server.label(in: .library), "Library order")
        XCTAssertEqual(MacFileSort.server.label(in: .printer), "Printer’s order")
        XCTAssertFalse(MacFileSort.server.summary(in: .printer).lowercased().contains("sorted by"))
        XCTAssertEqual(MacFileSort.name.summary(in: .printer), "Sorted by name")
    }
}

// MARK: - Detail layout

/// Which way the SD detail panel lays itself out.
///
/// The panel has two homes with opposite proportions, and the wrong choice is not cosmetic: stacked
/// inside a 320 pt drawer, the preview pushed the entire action row below the fold.
final class MacDetailLayoutTests: XCTestCase {

    /// The inspector column is 236–320 pt. It must ALWAYS stack — the threshold sits well clear of
    /// the widest column so a column can never trip it.
    func testEveryColumnWidthStacks() {
        for width in [200.0, 236.0, 280.0, 320.0, 400.0, 519.0] {
            XCTAssertFalse(MacInspectorPlacement.detailIsHorizontal(width: width), "\(width)")
        }
    }

    /// A drawer is as wide as the window, so it always goes side by side.
    func testDrawerWidthsGoSideBySide() {
        for width in [520.0, 900.0, 1400.0, 2400.0] {
            XCTAssertTrue(MacInspectorPlacement.detailIsHorizontal(width: width), "\(width)")
        }
    }

    /// A zero or negative width — the value before the first geometry read — must not flip the
    /// layout, or the panel would rearrange itself on its first frame.
    func testAnUnmeasuredWidthStacks() {
        XCTAssertFalse(MacInspectorPlacement.detailIsHorizontal(width: 0))
        XCTAssertFalse(MacInspectorPlacement.detailIsHorizontal(width: -1))
    }

    /// The two placements must never disagree about which they are: the widest column is strictly
    /// narrower than the threshold, and the drawer is strictly wider.
    func testTheThresholdSeparatesTheTwoPlacements() {
        let widestColumn = 320.0
        XCTAssertFalse(MacInspectorPlacement.detailIsHorizontal(width: widestColumn))
        // A drawer only exists below the column threshold, where the window is still at least the
        // §1 content minimum of 640 pt — comfortably horizontal.
        XCTAssertTrue(MacInspectorPlacement.detailIsHorizontal(width: 640))
    }
}

// MARK: - Viewer identity

/// Which window a viewer request addresses.
///
/// The target used to be a bare `fileId: Int`, and that single field is the entire reason the Mac
/// refused "View layers" for a file on the printer's card — while the endpoint existed and iOS had
/// been using it all along.
final class MacViewerTargetTests: XCTestCase {

    private func request(_ target: MacViewerRequest.Target,
                         name: String = "n",
                         mode: MacViewerRequest.Mode = .layers) -> MacViewerRequest {
        MacViewerRequest(target: target, name: name, mode: mode)
    }

    /// Identity is the file and ONLY the file: "View in 3D" then "View layers" must reuse one window.
    func testModeAndNameAreNotPartOfIdentity() {
        let a = request(.library(fileId: 7), name: "a.stl", mode: .layers)
        let b = request(.library(fileId: 7), name: "renamed.stl", mode: .model)
        XCTAssertEqual(a, b)
        XCTAssertEqual(a.hashValue, b.hashValue)
        XCTAssertEqual(a.id, b.id)
    }

    func testDifferentFilesAreDifferentWindows() {
        XCTAssertNotEqual(request(.library(fileId: 7)), request(.library(fileId: 8)))
        XCTAssertNotEqual(request(.printer(printerId: 1, path: "/a.gcode.3mf")),
                          request(.printer(printerId: 1, path: "/b.gcode.3mf")))
    }

    /// The two kinds share one keyspace, so the prefix is what stops a library id and a printer path
    /// from ever colliding.
    func testALibraryIdAndAPrinterPathCannotCollide() {
        XCTAssertNotEqual(MacViewerRequest.Target.library(fileId: 7).key,
                          MacViewerRequest.Target.printer(printerId: 7, path: "/7").key)
        XCTAssertTrue(MacViewerRequest.Target.library(fileId: 7).key.hasPrefix("library:"))
        XCTAssertTrue(MacViewerRequest.Target.printer(printerId: 1, path: "/x").key.hasPrefix("printer:"))
    }

    /// The same path on two different printers is two different files.
    func testThePrinterIdIsPartOfThePrinterKey() {
        XCTAssertNotEqual(MacViewerRequest.Target.printer(printerId: 1, path: "/x").key,
                          MacViewerRequest.Target.printer(printerId: 2, path: "/x").key)
    }

    /// The library id must be `nil` — never a sentinel — for an SD entry, because the listing lookup
    /// and the mesh page both key on it and `0` is a real id shape.
    func testAPrinterTargetHasNoLibraryId() {
        XCTAssertNil(MacViewerRequest.Target.printer(printerId: 1, path: "/x").libraryFileId)
        XCTAssertEqual(MacViewerRequest.Target.library(fileId: 7).libraryFileId, 7)
    }

    /// The request round-trips through `Codable`, because `WindowGroup(for:)` persists it across
    /// launches and a restored window has to reopen the same file.
    func testTheRequestSurvivesARoundTrip() throws {
        for target: MacViewerRequest.Target in [.library(fileId: 7), .printer(printerId: 2, path: "/timelapse/a.gcode.3mf")] {
            let original = request(target, name: "n", mode: .model)
            let decoded = try JSONDecoder().decode(MacViewerRequest.self,
                                                   from: JSONEncoder().encode(original))
            XCTAssertEqual(decoded.target, original.target)
            XCTAssertEqual(decoded.mode, original.mode)
            XCTAssertEqual(decoded.name, original.name)
        }
    }
}

// MARK: - Video window identity

final class MacVideoRequestTests: XCTestCase {

    /// Re-opening a recording raises its window rather than starting a second download of the same
    /// video — the name is display text and takes no part in that.
    func testIdentityIsThePrinterAndPath() {
        let a = MacVideoRequest(printerId: 1, path: "/timelapse/v.mp4", name: "Jul 5, 15:16")
        let b = MacVideoRequest(printerId: 1, path: "/timelapse/v.mp4", name: "something else")
        XCTAssertEqual(a, b)
        XCTAssertEqual(a.hashValue, b.hashValue)
        XCTAssertNotEqual(a, MacVideoRequest(printerId: 2, path: "/timelapse/v.mp4", name: "x"))
        XCTAssertNotEqual(a, MacVideoRequest(printerId: 1, path: "/ipcam/v.mp4", name: "x"))
    }

    func testTheRequestSurvivesARoundTrip() throws {
        let original = MacVideoRequest(printerId: 3, path: "/ipcam/a.mp4", name: "Apr 21, 22:12")
        let decoded = try JSONDecoder().decode(MacVideoRequest.self,
                                               from: JSONEncoder().encode(original))
        XCTAssertEqual(decoded, original)
        XCTAssertEqual(decoded.name, original.name)
    }
}

#endif
