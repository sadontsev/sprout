import XCTest
@testable import Sprout

final class PrinterFilesTests: XCTestCase {

    // MARK: - isSliced3mf

    func testIsSliced3mfMatchesGcode3mfCaseInsensitively() {
        XCTAssertTrue(PrinterFiles.isSliced3mf("Bambu_Cube_XYZ.gcode.3mf"))
        XCTAssertTrue(PrinterFiles.isSliced3mf("MODEL.GCODE.3MF"))
        XCTAssertFalse(PrinterFiles.isSliced3mf("notes.3mf.txt"))
        XCTAssertFalse(PrinterFiles.isSliced3mf("video.mp4"))
    }

    /// A plain project 3MF is NOT sliced. It carries no toolpaths, so `/gcode` answers 404 — which
    /// is exactly what "View layers" did on a `.3mf` the library had listed as sliced.
    func testPlainThreeMfIsNotSliced() {
        XCTAssertFalse(PrinterFiles.isSliced3mf("model.3mf"))
        XCTAssertFalse(PrinterFiles.isSliced3mf("model.3MF"))
        XCTAssertFalse(PrinterFiles.isSliced3mf(".3mf"))
    }

    func testIsSliced3mfNeedsTheDot() {
        XCTAssertTrue(PrinterFiles.isSliced3mf(".gcode.3mf"))
        XCTAssertFalse(PrinterFiles.isSliced3mf("gcode.3mf".replacingOccurrences(of: ".", with: "")))
        XCTAssertFalse(PrinterFiles.isSliced3mf(""))
    }

    // MARK: - isPlayableVideo

    func testIsPlayableVideoMp4OnlyBecauseIOSCannotPlayTheOldAviTimelapses() {
        XCTAssertTrue(PrinterFiles.isPlayableVideo("video_2026-07-05_15-16-02.mp4"))
        XCTAssertTrue(PrinterFiles.isPlayableVideo("video.MP4"))
        XCTAssertFalse(PrinterFiles.isPlayableVideo("old.avi"))
    }

    func testIsPlayableVideoNeedsTheDot() {
        XCTAssertTrue(PrinterFiles.isPlayableVideo(".mp4"))
        XCTAssertFalse(PrinterFiles.isPlayableVideo("mp4"))
        XCTAssertFalse(PrinterFiles.isPlayableVideo(""))
    }

    // MARK: - isMediaFolder

    func testIsMediaFolderMatchesTheTopLevelTimelapseAndIpcamDirsOnly() {
        XCTAssertTrue(PrinterFiles.isMediaFolder("/timelapse"))
        XCTAssertTrue(PrinterFiles.isMediaFolder("/timelapse/"))
        XCTAssertTrue(PrinterFiles.isMediaFolder("/ipcam"))
        XCTAssertTrue(PrinterFiles.isMediaFolder("/ipcam/"))
        XCTAssertFalse(PrinterFiles.isMediaFolder("/timelapse/thumbnail"))
        XCTAssertFalse(PrinterFiles.isMediaFolder("/ipcam/thumbnail"))
        XCTAssertFalse(PrinterFiles.isMediaFolder("/"))
    }

    /// Case folding must be locale-independent — a Turkish-locale lowercase would turn "IPCAM" into
    /// "ıpcam" and the folder would stop matching.
    func testIsMediaFolderIsCaseInsensitiveIncludingTheDottedI() {
        XCTAssertTrue(PrinterFiles.isMediaFolder("/IPCAM"))
        XCTAssertTrue(PrinterFiles.isMediaFolder("/Ipcam/"))
        XCTAssertTrue(PrinterFiles.isMediaFolder("/TimeLapse"))
    }

    func testIsMediaFolderRejectsNearMisses() {
        XCTAssertFalse(PrinterFiles.isMediaFolder("timelapse"))
        XCTAssertFalse(PrinterFiles.isMediaFolder("//timelapse"))
        XCTAssertFalse(PrinterFiles.isMediaFolder("/timelapse//"))
        XCTAssertFalse(PrinterFiles.isMediaFolder("/timelapses"))
        XCTAssertFalse(PrinterFiles.isMediaFolder("/ipcam/thumbnail/"))
        XCTAssertFalse(PrinterFiles.isMediaFolder(""))
    }

    // MARK: - mediaThumbPath

    func testMediaThumbPathMapsToTheSiblingThumbnailJpg() {
        XCTAssertEqual(
            PrinterFiles.mediaThumbPath("/timelapse/video_2026-07-05_15-16-02.mp4"),
            "/timelapse/thumbnail/video_2026-07-05_15-16-02.jpg")
        // ipcam basenames contain DOTS (".<seq>.mp4") — only the final extension is swapped.
        XCTAssertEqual(
            PrinterFiles.mediaThumbPath("/ipcam/ipcam-record.2026-04-21_22-12-16.0.mp4"),
            "/ipcam/thumbnail/ipcam-record.2026-04-21_22-12-16.0.jpg")
        // no extension -> unchanged (never build a broken URL)
        XCTAssertEqual(PrinterFiles.mediaThumbPath("/timelapse/weird"), "/timelapse/weird")
    }

    func testMediaThumbPathHandlesRootLevelFiles() {
        XCTAssertEqual(PrinterFiles.mediaThumbPath("/video.mp4"), "/thumbnail/video.jpg")
    }

    /// The split is the LAST slash and then the LAST dot, so an extension-looking directory name
    /// never gets mistaken for the file's own extension.
    func testMediaThumbPathSplitsOnTheFinalSegmentOnly() {
        XCTAssertEqual(PrinterFiles.mediaThumbPath("/a.mp4/b"), "/a.mp4/b")
        XCTAssertEqual(PrinterFiles.mediaThumbPath("/a/b.mp4/c.txt"), "/a/b.mp4/thumbnail/c.jpg")
    }

    func testMediaThumbPathLeavesMalformedPathsAlone() {
        XCTAssertEqual(PrinterFiles.mediaThumbPath("video.mp4"), "video.mp4")   // no directory
        XCTAssertEqual(PrinterFiles.mediaThumbPath("/timelapse/file."), "/timelapse/file.")  // empty extension
        XCTAssertEqual(PrinterFiles.mediaThumbPath("/timelapse/.mp4"), "/timelapse/.mp4")    // empty basename
        XCTAssertEqual(PrinterFiles.mediaThumbPath("/timelapse/"), "/timelapse/")            // a directory
        XCTAssertEqual(PrinterFiles.mediaThumbPath(""), "")
    }

    // MARK: - mediaLabel

    func testMediaLabelFormatsTheEmbeddedDateAndFallsBackToTheRawName() {
        XCTAssertEqual(PrinterFiles.mediaLabel("video_2026-07-05_15-16-02.mp4"), "Jul 5, 15:16")
        XCTAssertEqual(PrinterFiles.mediaLabel("ipcam-record.2026-04-21_22-12-16.0.mp4"), "Apr 21, 22:12")
        XCTAssertEqual(PrinterFiles.mediaLabel("video_2026-12-31_09-05-59.mp4"), "Dec 31, 09:05")
        XCTAssertEqual(PrinterFiles.mediaLabel("custom_name.mp4"), "custom_name.mp4")
        // bogus month
        XCTAssertEqual(
            PrinterFiles.mediaLabel("video_2026-99-05_15-16-02.mp4"),
            "video_2026-99-05_15-16-02.mp4")
    }

    /// Month 00 would index before the start of the month table; it must fall back, not trap.
    func testMediaLabelRejectsMonthZero() {
        XCTAssertEqual(
            PrinterFiles.mediaLabel("video_2026-00-05_15-16-02.mp4"),
            "video_2026-00-05_15-16-02.mp4")
    }

    func testMediaLabelHandlesBothMonthBoundaries() {
        XCTAssertEqual(PrinterFiles.mediaLabel("video_2026-01-01_00-00-00.mp4"), "Jan 1, 00:00")
        XCTAssertEqual(PrinterFiles.mediaLabel("video_2026-12-01_23-59-59.mp4"), "Dec 1, 23:59")
    }

    func testMediaLabelFindsTheStampAtAnyOffset() {
        XCTAssertEqual(PrinterFiles.mediaLabel("2026-01-02_03-04.mp4"), "Jan 2, 03:04")
        // A five-digit run still yields a stamp starting one character in.
        XCTAssertEqual(PrinterFiles.mediaLabel("12026-07-05_15-16"), "Jul 5, 15:16")
    }

    /// The first structurally valid stamp decides the answer; a bogus month is not retried against a
    /// later stamp.
    func testMediaLabelDoesNotScanPastTheFirstStamp() {
        let name = "video_2026-99-05_15-16-02_2026-07-05_15-16-02.mp4"
        XCTAssertEqual(PrinterFiles.mediaLabel(name), name)
    }

    func testMediaLabelIgnoresNamesTooShortToHoldAStamp() {
        XCTAssertEqual(PrinterFiles.mediaLabel(""), "")
        XCTAssertEqual(PrinterFiles.mediaLabel("2026-07-05_15-1"), "2026-07-05_15-1")
    }

    /// Only ASCII digits count — Arabic-Indic numerals are not something the printer writes, and
    /// accepting them would produce a label from a name that has no timestamp in it.
    func testMediaLabelIgnoresNonAsciiDigits() {
        let name = "video_٢٠٢٦-٠٧-٠٥_١٥-١٦-٠٢.mp4"
        XCTAssertEqual(PrinterFiles.mediaLabel(name), name)
    }
}
