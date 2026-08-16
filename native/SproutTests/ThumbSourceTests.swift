import XCTest
@testable import Sprout

/// `ThumbSource` derives, from filenames alone, which library file a sliced file was produced from —
/// so a sliced file's silhouette can borrow the source model's real render.
///
/// It is a heuristic by necessity: the API exposes no parent link. Three fields look like one and are
/// not, and each was checked against the live schema before this rule was written —
/// `sliced_from_library_file_id` does not exist at all, `slicedForModel` is the PRINTER model, and
/// `variant_group_id` is NULL on every row. So the rule must be conservative, and every case below
/// where it returns nil is the rule declining rather than failing.
///
/// The library snapshots here mirror the real one this was measured against.
final class ThumbSourceTests: XCTestCase {
    private func file(_ id: Int, _ name: String, thumb: String? = "t.png") -> LibraryFile {
        var f = LibraryFile(id: id, filename: name)
        f.thumbnailPath = thumb
        return f
    }

    // MARK: - Reading the name

    func testStemOfASlicedName() {
        XCTAssertEqual(ThumbSource.sourceStem(of: "cr.gcode.3mf"), "cr")
        XCTAssertEqual(ThumbSource.sourceStem(of: "3 colour benchy.gcode.3mf"), "3 colour benchy")
    }

    func testAnUnslicedNameHasNoStem() {
        XCTAssertNil(ThumbSource.sourceStem(of: "cr.3mf"))
        XCTAssertNil(ThumbSource.sourceStem(of: "part.stl"))
        XCTAssertNil(ThumbSource.sourceStem(of: "notes.txt"))
    }

    /// `.gcode.3mf` with nothing in front of it is not a slice of anything.
    func testABareSuffixHasNoStem() {
        XCTAssertNil(ThumbSource.sourceStem(of: ".gcode.3mf"))
    }

    /// Real rows arrive URL-encoded from the import path — this exact filename is in the library
    /// this was measured against.
    func testAnEncodedNameIsDecodedBeforeMatching() {
        XCTAssertEqual(ThumbSource.sourceStem(of: "Adapter%20hexagon%20for%20electric%20drill.gcode.3mf"),
                       "Adapter hexagon for electric drill")
    }

    func testTheSuffixMatchIsCaseInsensitive() {
        XCTAssertEqual(ThumbSource.sourceStem(of: "Part.GCODE.3MF"), "Part")
    }

    // MARK: - Finding the source

    /// The measured case: `cr.3mf` (40) with three slices of it (41-43).
    func testASlicedFileFindsTheModelItCameFrom() {
        let library = [file(40, "cr.3mf"), file(41, "cr.gcode.3mf"),
                       file(42, "cr.gcode.3mf"), file(43, "cr.gcode.3mf")]
        for slicedId in [41, 42, 43] {
            let sliced = library.first { $0.id == slicedId }!
            XCTAssertEqual(ThumbSource.sourceCandidate(for: sliced, in: library)?.id, 40,
                           "slice \(slicedId) should borrow from cr.3mf")
        }
    }

    /// The disambiguation that makes "nearest preceding id" the rule rather than "first match".
    /// Two separate imports of the same model, each sliced: 48→49 and 53→54, never crossed.
    func testTwoImportsOfTheSameNameEachKeepTheirOwnSource() {
        let library = [file(48, "3 colour benchy.3mf"), file(49, "3 colour benchy.gcode.3mf"),
                       file(53, "3 colour benchy.3mf"), file(54, "3 colour benchy.gcode.3mf")]
        XCTAssertEqual(ThumbSource.sourceCandidate(for: library[1], in: library)?.id, 48)
        XCTAssertEqual(ThumbSource.sourceCandidate(for: library[3], in: library)?.id, 53)
    }

    /// An encoded slice must find its decoded source.
    func testAnEncodedSliceMatchesItsDecodedSource() {
        let library = [file(30, "Adapter hexagon for electric drill.3mf"),
                       file(38, "Adapter%20hexagon%20for%20electric%20drill.gcode.3mf")]
        XCTAssertEqual(ThumbSource.sourceCandidate(for: library[1], in: library)?.id, 30)
    }

    /// A `.3mf` embeds a real render; a `.stl` only ever gets Bambuddy's own silhouette. Borrowing
    /// from the `.stl` would swap a blob for a blob.
    func testA3mfSourceIsPreferredOverAnStl() {
        let library = [file(10, "part.stl"), file(11, "part.3mf"), file(12, "part.gcode.3mf")]
        XCTAssertEqual(ThumbSource.sourceCandidate(for: library[2], in: library)?.id, 11)
    }

    /// If the only source is an STL it is still offered — the probe downstream is what rejects it if
    /// it turns out to be a silhouette. This rule's job is to nominate, not to judge pixels.
    func testAnStlSourceIsOfferedWhenThereIsNo3mf() {
        let library = [file(10, "part.stl"), file(12, "part.gcode.3mf")]
        XCTAssertEqual(ThumbSource.sourceCandidate(for: library[1], in: library)?.id, 10)
    }

    // MARK: - Declining

    func testNoSourceWhenNothingMatches() {
        let library = [file(1, "other.3mf"), file(2, "cr.gcode.3mf")]
        XCTAssertNil(ThumbSource.sourceCandidate(for: library[1], in: library))
    }

    /// A file that is not itself a slice has no source to look for.
    func testAnUnslicedFileHasNoSource() {
        let library = [file(1, "cr.3mf"), file(2, "cr.gcode.3mf")]
        XCTAssertNil(ThumbSource.sourceCandidate(for: library[0], in: library))
    }

    /// One silhouette must never borrow from another, or a chain of slices all show the same blob.
    func testASliceIsNeverTheSourceForAnotherSlice() {
        let library = [file(41, "cr.gcode.3mf"), file(42, "cr.gcode.3mf")]
        XCTAssertNil(ThumbSource.sourceCandidate(for: library[1], in: library))
    }

    /// A source with no thumbnail has nothing to lend.
    func testASourceWithoutAThumbnailIsNotOffered() {
        let library = [file(40, "cr.3mf", thumb: nil), file(41, "cr.gcode.3mf")]
        XCTAssertNil(ThumbSource.sourceCandidate(for: library[1], in: library))
    }

    func testAFileIsNeverItsOwnSource() {
        let only = file(41, "cr.gcode.3mf")
        XCTAssertNil(ThumbSource.sourceCandidate(for: only, in: [only]))
    }

    func testAnEmptyLibraryYieldsNothing() {
        XCTAssertNil(ThumbSource.sourceCandidate(for: file(41, "cr.gcode.3mf"), in: []))
    }

    /// A source uploaded AFTER the slice is still better than nothing, but only when there is no
    /// preceding one — this is the fallback arm of the ordering rule.
    func testAFollowingSourceIsUsedOnlyWhenNonePrecedes() {
        let library = [file(41, "cr.gcode.3mf"), file(60, "cr.3mf")]
        XCTAssertEqual(ThumbSource.sourceCandidate(for: library[0], in: library)?.id, 60)
    }

    /// Similar names must not collide: `cr2.3mf` is not the source of `cr.gcode.3mf`.
    func testAPrefixMatchIsNotASource() {
        let library = [file(40, "cr2.3mf"), file(41, "cr.gcode.3mf")]
        XCTAssertNil(ThumbSource.sourceCandidate(for: library[1], in: library))
    }
}
