import XCTest
@testable import Sprout

/// The pure pieces behind the Files tab and the two WebView viewers: the download-name sanitiser,
/// the viewer document base, and the log redaction.
///
/// These exist because of a "download failed (HTTP 404)" that could not be reproduced by hand: the
/// `/dl/{token}/{filename}` endpoint answers 403 for every bad credential and 200 for every invented
/// filename, so a 404 can only mean the PATH had the wrong number of segments. Both ways that
/// happens are covered here.
final class LibraryViewerTests: XCTestCase {

    // MARK: - LibraryDownloadName

    func testKeepsAnOrdinaryFilenameUntouched() {
        XCTAssertEqual(LibraryDownloadName.pathSegment("Adapter hexagon.stl", fallback: "fb"), "Adapter hexagon.stl")
    }

    /// The 404. A separator survives percent-encoding as `%2F`, the server decodes the path before it
    /// routes, and `/dl/{token}/{filename}` is suddenly a four-segment path that matches no route.
    func testFoldsPathSeparatorsSoTheNameStaysOneSegment() {
        XCTAssertEqual(LibraryDownloadName.pathSegment("Bracket 20/40", fallback: "fb"), "Bracket 20-40")
        XCTAssertEqual(LibraryDownloadName.pathSegment("a\\b", fallback: "fb"), "a-b")
        XCTAssertEqual(LibraryDownloadName.pathSegment("/leading", fallback: "fb"), "-leading")
    }

    /// The other 404: nothing left to be a segment at all, so the URL ends at `/dl/{token}/`.
    func testFallsBackWhenNothingUsableIsLeft() {
        XCTAssertEqual(LibraryDownloadName.pathSegment("", fallback: "model-7.stl"), "model-7.stl")
        XCTAssertEqual(LibraryDownloadName.pathSegment("   \n", fallback: "model-7.stl"), "model-7.stl")
    }

    /// `.` and `..` are resolved away by the URL parser, which removes a segment — the same failure
    /// as an empty name, reached by a different route.
    func testFallsBackForRelativePathSegments() {
        XCTAssertEqual(LibraryDownloadName.pathSegment(".", fallback: "fb"), "fb")
        XCTAssertEqual(LibraryDownloadName.pathSegment("..", fallback: "fb"), "fb")
        // Only a segment that IS a dot run is dangerous; a name that merely contains one is fine.
        XCTAssertEqual(LibraryDownloadName.pathSegment("v1.2.stl", fallback: "fb"), "v1.2.stl")
    }

    func testDropsControlCharactersRatherThanPercentEscapingThem() {
        XCTAssertEqual(LibraryDownloadName.pathSegment("x\u{0007}y\u{007F}z", fallback: "fb"), "xyz")
        XCTAssertEqual(LibraryDownloadName.pathSegment("a\nb", fallback: "fb"), "ab")
    }

    func testAcceptsNonAsciiVerbatim() {
        // Percent-encoding happens later, in the client's URL builder; this stage only removes what
        // cannot be a path segment at all.
        XCTAssertEqual(LibraryDownloadName.pathSegment("Männchen.stl", fallback: "fb"), "Männchen.stl")
    }

    // MARK: - ViewerJS.documentBase

    func testDocumentBaseIsAlwaysDirectoryLike() {
        XCTAssertEqual(ViewerJS.documentBase(of: "https://b.example.com").absoluteString, "https://b.example.com/")
        XCTAssertEqual(ViewerJS.documentBase(of: "https://b.example.com/").absoluteString, "https://b.example.com/")
        XCTAssertEqual(ViewerJS.documentBase(of: "  https://b.example.com  ").absoluteString, "https://b.example.com/")
    }

    func testDocumentBaseKeepsThePortAndThePathPrefix() {
        XCTAssertEqual(
            ViewerJS.documentBase(of: "https://b.example.com:8910/bambuddy").absoluteString,
            "https://b.example.com:8910/bambuddy/"
        )
        XCTAssertEqual(
            ViewerJS.documentBase(of: "https://b.example.com:8910/bambuddy//").absoluteString,
            "https://b.example.com:8910/bambuddy/"
        )
    }

    /// The regression this fixes: with the path dropped, a relative in-page URL resolved at the bare
    /// origin — a route that does not exist, i.e. a 404 that never came from the endpoint the URL
    /// was aimed at.
    func testRelativePathsResolveUnderThePrefix() {
        let base = ViewerJS.documentBase(of: "https://b.example.com:8910/bambuddy")
        XCTAssertEqual(
            URL(string: "texturize-jobs/j9/result.stl", relativeTo: base)?.absoluteURL.absoluteString,
            "https://b.example.com:8910/bambuddy/texturize-jobs/j9/result.stl"
        )
        // A ROOT-relative path still resolves at the origin — that is RFC 3986, and it is what the
        // RN build did too.
        XCTAssertEqual(
            URL(string: "/texturize-jobs/j9/result.stl", relativeTo: base)?.absoluteURL.absoluteString,
            "https://b.example.com:8910/texturize-jobs/j9/result.stl"
        )
    }

    func testDocumentBaseDropsQueryAndFragment() {
        XCTAssertEqual(ViewerJS.documentBase(of: "https://b.example.com/x?q=1#f").absoluteString, "https://b.example.com/x/")
    }

    func testDocumentBaseFallsBackInsteadOfTrappingOnAnUnusableBaseUrl() {
        // A base URL with no scheme, or one Foundation refuses outright, must still produce a
        // document so the page can render its own error.
        XCTAssertEqual(ViewerJS.documentBase(of: "homeserver.local:8910").absoluteString, "https://localhost/")
        XCTAssertEqual(ViewerJS.documentBase(of: "").absoluteString, "https://localhost/")
        XCTAssertEqual(ViewerJS.documentBase(of: "not a url ][").absoluteString, "https://localhost/")
    }

    // MARK: - ViewerJS.loggableUrl

    func testLoggableUrlHidesTheDownloadTokenAndTheHostButKeepsTheShape() {
        XCTAssertEqual(
            ViewerJS.loggableUrl("https://b.example.com/api/v1/library/files/22/dl/s3cr3t/model.stl"),
            "{base}/api/v1/library/files/22/dl/…/model.stl"
        )
    }

    /// The whole point of keeping the path verbatim: these two are the 404s, and they are visible at
    /// a glance in the log line.
    func testLoggableUrlShowsAMalformedFilenameSegment() {
        XCTAssertEqual(
            ViewerJS.loggableUrl("https://b.example.com/api/v1/library/files/22/dl/s3cr3t/plate%2F1.stl"),
            "{base}/api/v1/library/files/22/dl/…/plate%2F1.stl"
        )
        XCTAssertEqual(
            ViewerJS.loggableUrl("https://b.example.com/api/v1/library/files/22/dl/s3cr3t/"),
            "{base}/api/v1/library/files/22/dl/…/"
        )
    }

    func testLoggableUrlHidesATokenQueryValueAndKeepsEveryOtherParameter() {
        XCTAssertEqual(
            ViewerJS.loggableUrl("https://b.example.com/api/v1/library/files/22/thumbnail?token=s3cr3t&x=1"),
            "{base}/api/v1/library/files/22/thumbnail?token=…&x=1"
        )
        XCTAssertEqual(
            ViewerJS.loggableUrl("https://b.example.com/api/v1/printers/1/camera/snapshot?fps=1&token=s3cr3t"),
            "{base}/api/v1/printers/1/camera/snapshot?fps=1&token=…"
        )
    }

    func testLoggableUrlLeavesAnUnrelatedQueryAlone() {
        XCTAssertEqual(
            ViewerJS.loggableUrl("https://b.example.com/api/v1/printers/1/files/gcode?path=%2Fx.3mf"),
            "{base}/api/v1/printers/1/files/gcode?path=%2Fx.3mf"
        )
    }

    /// A URL that never became absolute is exactly the kind of thing this log exists to expose, so it
    /// must survive redaction rather than be swallowed.
    func testLoggableUrlPassesThroughAUrlWithNoAuthority() {
        XCTAssertEqual(ViewerJS.loggableUrl("/api/v1/library/files/22/gcode"), "/api/v1/library/files/22/gcode")
        XCTAssertEqual(ViewerJS.loggableUrl(""), "")
    }
}
