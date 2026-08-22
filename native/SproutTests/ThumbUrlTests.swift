import XCTest
@testable import Sprout

/// The `v=` on a thumbnail URL, and the two nil answers around it.
///
/// Why this file exists: `/library/files/{id}/thumbnail` is a STABLE address over MUTABLE content.
/// `ThumbCache` keys on the URL and runs `.returnCacheDataElseLoad`, which never revalidates, so a
/// re-rendered thumbnail was invisible to any install that had already seen the old one — from disk,
/// across relaunches. It took repainting every preview server-side to notice, because until then
/// nothing had ever changed under one of these addresses.
///
/// `thumbnail_path` is the server's own content-addressed filename, so the URL can carry the
/// identity it was missing. These tests hold that it does, and that adding it did not disturb the
/// two nil cases the callers depend on.
final class ThumbUrlTests: XCTestCase {

    private func client() -> BambuddyClient {
        BambuddyClient(baseUrl: "https://bambuddy.example.com", apiKey: "bb_test")
    }

    // MARK: - The version marker

    func testTheUrlCarriesTheThumbnailsOwnFilename() {
        let url = client().fileThumbUrl(
            39, token: "tok", thumbnailPath: .some("archive/library/thumbnails/a272932a.png"))
        XCTAssertEqual(
            url?.absoluteString,
            "https://bambuddy.example.com/api/v1/library/files/39/thumbnail?token=tok&v=a272932a.png")
    }

    /// The whole point: two renders of the same file are two URLs, so the cache cannot serve the
    /// first when the server is holding the second.
    func testARerenderProducesADifferentUrl() {
        let c = client()
        let before = c.fileThumbUrl(39, token: "tok", thumbnailPath: .some("t/35a70400.png"))
        let after = c.fileThumbUrl(39, token: "tok", thumbnailPath: .some("t/a272932a.png"))
        XCTAssertNotNil(before)
        XCTAssertNotEqual(before, after)
    }

    /// A path with no directory part is still a name.
    func testABareFilenameIsUsedAsIs() {
        let url = client().fileThumbUrl(7, token: "tok", thumbnailPath: .some("abc.png"))
        XCTAssertEqual(url?.query, "token=tok&v=abc.png")
    }

    /// The server has told us nothing about the path, so there is nothing to version by — but the
    /// request is still worth making. Losing this case would blank every thumbnail on a listing that
    /// omits the key.
    func testAnUnknownPathStillProducesAUrl() {
        let url = client().fileThumbUrl(7, token: "tok", thumbnailPath: .none)
        XCTAssertEqual(url?.absoluteString,
                       "https://bambuddy.example.com/api/v1/library/files/7/thumbnail?token=tok")
    }

    /// An explicit null means the server HAS no thumbnail. Different question, different answer.
    func testAnExplicitlyNullPathIsNoUrlAtAll() {
        XCTAssertNil(client().fileThumbUrl(7, token: "tok", thumbnailPath: .some(nil)))
    }

    func testNoTokenIsNoUrl() {
        XCTAssertNil(client().fileThumbUrl(7, token: nil, thumbnailPath: .some("t/abc.png")))
    }

    /// A trailing slash cannot name a file, so there is no version to add — and the URL must still
    /// be built rather than lost.
    func testATrailingSlashLeavesTheUrlUnversioned() {
        let url = client().fileThumbUrl(7, token: "tok", thumbnailPath: .some("thumbnails/"))
        XCTAssertEqual(url?.query, "token=tok")
    }

    /// Both halves of the query go through the same escaping. A name with a space would otherwise
    /// produce a URL that does not parse at all.
    func testTheVersionIsPercentEscaped() {
        let url = client().fileThumbUrl(7, token: "a b", thumbnailPath: .some("t/x y.png"))
        XCTAssertEqual(url?.absoluteString,
                       "https://bambuddy.example.com/api/v1/library/files/7/thumbnail?token=a%20b&v=x%20y.png")
    }

    // MARK: - The print log takes the same treatment

    func testPrintLogThumbnailsAreVersionedToo() {
        let url = client().printLogThumbUrl(12, token: "tok", thumbnailPath: .some("a/b/c.png"))
        XCTAssertEqual(url?.absoluteString,
                       "https://bambuddy.example.com/api/v1/print-log/12/thumbnail?token=tok&v=c.png")
    }

    func testPrintLogKeepsItsTwoNilCases() {
        XCTAssertNil(client().printLogThumbUrl(12, token: nil, thumbnailPath: .some("a.png")))
        XCTAssertNil(client().printLogThumbUrl(12, token: "tok", thumbnailPath: .some(nil)))
        XCTAssertNotNil(client().printLogThumbUrl(12, token: "tok", thumbnailPath: .none))
    }

    // MARK: - The plate render is the one that cannot be versioned

    /// Not an oversight: a plate render has no `thumbnail_path` and nothing else identifies which
    /// render it is. Its callers pass `revalidates: true` instead. Asserted so that a later change
    /// adding a `v=` here has to come with the data to put in it.
    func testThePlateRenderUrlCarriesNoVersion() {
        let url = client().plateThumbUrl(39, plateIndex: 1, token: "tok")
        XCTAssertEqual(url?.query, "token=tok")
    }

    // MARK: - The printer's own cover

    /// The rung for a job with no file name in it at all. Measured on the live machine: a plate sent
    /// straight from the slicer reported `subtask_name` = "PETG 0.2mm layer, 2 walls, 15% infill" —
    /// the process preset — so no library row, card entry or archive could ever match it.
    func testTheCoverUrlIsBuiltFromThePrinterAndTheStreamToken() {
        XCTAssertEqual(client().printerCoverUrl(2, token: "tok")?.absoluteString,
                       "https://bambuddy.example.com/api/v1/printers/2/cover?token=tok")
    }

    /// Token-gated like every other thumbnail here — the `X-API-Key` header answers 401.
    func testNoTokenIsNoCover() {
        XCTAssertNil(client().printerCoverUrl(2, token: nil))
    }

    func testTheCoverTokenIsEscaped() {
        XCTAssertEqual(client().printerCoverUrl(2, token: "a b")?.query, "token=a%20b")
    }
}
