import XCTest
@testable import Sprout

/// Covers the API boundary types in `Api/Models.swift` + `Api/BambuddyClient.swift`: the shapes the
/// server actually sends, and the coercions that must never trap on a hostile payload.
final class ApiModelsTests: XCTestCase {

    private func decodeJob(_ json: String) throws -> SliceJob {
        try BambuddyClient.decoder.decode(SliceJob.self, from: Data(json.utf8))
    }

    // MARK: - LooseNumber.int

    func testIntTruncatesTowardZeroLikeTheOldConversion() {
        XCTAssertEqual(LooseNumber(3.7).int, 3)
        XCTAssertEqual(LooseNumber(-3.7).int, -3)
        XCTAssertEqual(LooseNumber(0).int, 0)
        XCTAssertEqual(LooseNumber(210).int, 210)
    }

    func testIntIsNilWithoutAFiniteValue() {
        XCTAssertNil(LooseNumber(nil).int)
        XCTAssertNil(LooseNumber(Double.nan).int)
        XCTAssertNil(LooseNumber(Double.infinity).int)
        XCTAssertNil(LooseNumber(-Double.infinity).int)
    }

    /// The whole point of the fix: `Int(1e30)` is a trap, and `1e30.isFinite` is true. A stringified
    /// WS field parses straight into that.
    func testIntSaturatesInsteadOfTrappingOnOutOfRangeMagnitudes() {
        XCTAssertEqual(LooseNumber(1e30).int, Int.max)
        XCTAssertEqual(LooseNumber(-1e30).int, Int.min)
        XCTAssertEqual(LooseNumber(Double(Int.max)).int, Int.max)
        XCTAssertEqual(LooseNumber(Double(Int.min)).int, Int.min)
        XCTAssertEqual(LooseNumber(Double.greatestFiniteMagnitude).int, Int.max)
        XCTAssertEqual(LooseNumber(-Double.greatestFiniteMagnitude).int, Int.min)
    }

    func testIntSaturatesForAStringifiedOutOfRangeNumber() throws {
        struct Row: Decodable { let n: LooseNumber }
        let row = try BambuddyClient.decoder.decode(Row.self, from: Data(#"{"n":"1e30"}"#.utf8))
        XCTAssertEqual(row.n.double, 1e30)
        XCTAssertEqual(row.n.int, Int.max)
    }

    // MARK: - SliceJob: the nested `result` shape

    func testCompletedJobReadsOutputsFromTheNestedResult() throws {
        let job = try decodeJob("""
        {"id":7,"status":"completed","progress":100,
         "result":{"status":"completed","library_file_id":42,"print_time_seconds":738,
                   "filament_used_g":3.75,"filament_used_mm":1240}}
        """)
        XCTAssertEqual(job.status, "completed")
        XCTAssertEqual(job.libraryFileId, 42)
        XCTAssertEqual(job.printTimeSeconds?.double, 738)
        XCTAssertEqual(job.filamentUsedG?.double, 3.75)
        XCTAssertEqual(job.filamentUsedMm?.double, 1240)
        XCTAssertNil(job.errorMessage)
    }

    /// The fallback half of the defensive model: a flattened job must still decode.
    func testCompletedJobStillReadsOutputsFromTheRootWhenThereIsNoResultObject() throws {
        let job = try decodeJob("""
        {"id":7,"status":"completed","library_file_id":42,"print_time_seconds":738,
         "filament_used_g":3.75,"filament_used_mm":1240}
        """)
        XCTAssertEqual(job.libraryFileId, 42)
        XCTAssertEqual(job.printTimeSeconds?.double, 738)
        XCTAssertEqual(job.filamentUsedG?.double, 3.75)
        XCTAssertEqual(job.filamentUsedMm?.double, 1240)
    }

    func testNestedResultWinsOverARootLevelTwin() throws {
        let job = try decodeJob("""
        {"status":"completed","library_file_id":11,"print_time_seconds":1,
         "result":{"library_file_id":42,"print_time_seconds":738}}
        """)
        XCTAssertEqual(job.libraryFileId, 42)
        XCTAssertEqual(job.printTimeSeconds?.double, 738)
    }

    func testStringifiedResultNumbersDecodeRatherThanFailingTheWholeJob() throws {
        let job = try decodeJob("""
        {"status":"completed","result":{"library_file_id":"42","print_time_seconds":"738.5"}}
        """)
        XCTAssertEqual(job.libraryFileId, 42)
        XCTAssertEqual(job.printTimeSeconds?.double, 738.5)
    }

    func testPendingJobHasNoOutputsAndNoError() throws {
        let job = try decodeJob(#"{"id":7,"status":"running","progress":40}"#)
        XCTAssertEqual(job.status, "running")
        XCTAssertEqual(job.progress?.double, 40)
        XCTAssertNil(job.libraryFileId)
        XCTAssertNil(job.printTimeSeconds)
        XCTAssertNil(job.errorMessage)
    }

    func testSliceJobRoundTripsThroughTheAppsCoders() throws {
        let original = try decodeJob("""
        {"id":7,"status":"failed","error":"boom","result":{"library_file_id":42}}
        """)
        let data = try BambuddyClient.encoder.encode(original)
        let again = try BambuddyClient.decoder.decode(SliceJob.self, from: data)
        XCTAssertEqual(again.errorMessage, "boom")
        XCTAssertEqual(again.libraryFileId, 42)
        XCTAssertEqual(again, original)
    }

    // MARK: - SliceJob: the failure reason

    func testFailureReasonComesFromTheServersErrorField() throws {
        let job = try decodeJob("""
        {"status":"failed","error":"filament PETG-CF requires a hardened nozzle"}
        """)
        XCTAssertEqual(job.errorMessage, "filament PETG-CF requires a hardened nozzle")
    }

    func testFailureReasonFallsBackToErrorMessageAndToTheResultObject() throws {
        let legacy = try decodeJob(#"{"status":"failed","error_message":"legacy shape"}"#)
        XCTAssertEqual(legacy.errorMessage, "legacy shape")

        let nested = try decodeJob(#"{"status":"error","result":{"error":"nested reason"}}"#)
        XCTAssertEqual(nested.errorMessage, "nested reason")
    }

    /// A blank `error` must read as absent so the call site's own "Slice failed" default wins over an
    /// empty alert body.
    func testBlankErrorIsTreatedAsAbsent() throws {
        let blank = try decodeJob(#"{"status":"failed","error":"   "}"#)
        XCTAssertNil(blank.errorMessage)

        let blankThenReal = try decodeJob(#"{"status":"failed","error":" ","error_message":"real reason"}"#)
        XCTAssertEqual(blankThenReal.errorMessage, "real reason")
    }

    // MARK: - Multipart filename escaping

    func testFilenameEscapingNeutralisesQuotesAndNewlines() {
        XCTAssertEqual(BambuddyClient.escapeFormDataFilename(#"Bracket "V2".3mf"#),
                       "Bracket %22V2%22.3mf")
        XCTAssertEqual(BambuddyClient.escapeFormDataFilename("a\r\nX-Injected: 1\r\n\r\n.3mf"),
                       "a%0D%0AX-Injected: 1%0D%0A%0D%0A.3mf")
    }

    func testFilenameEscapingLeavesOrdinaryNamesAloneAndNeverEmitsAnEmptyName() {
        XCTAssertEqual(BambuddyClient.escapeFormDataFilename("cube20.gcode.3mf"), "cube20.gcode.3mf")
        XCTAssertEqual(BambuddyClient.escapeFormDataFilename("Bräcket – v2.3mf"), "Bräcket – v2.3mf")
        XCTAssertEqual(BambuddyClient.escapeFormDataFilename(""), "upload.bin")
    }

    /// The invariant the header depends on, stated directly: nothing that could close the
    /// quoted-string or start a new MIME header survives.
    func testEscapedFilenameCanNeverBreakOutOfTheHeader() {
        for raw in [#"a"b"#, "a\rb", "a\nb", "\"\r\n", "plain.3mf"] {
            let escaped = BambuddyClient.escapeFormDataFilename(raw)
            XCTAssertFalse(escaped.contains("\""), "quote survived in \(escaped)")
            XCTAssertFalse(escaped.contains("\r"), "CR survived in \(escaped)")
            XCTAssertFalse(escaped.contains("\n"), "LF survived in \(escaped)")
        }
    }

    // MARK: - Malformed base URL

    func testMalformedBaseUrlThrowsInsteadOfTrapping() async {
        // Precondition: a string Foundation genuinely refuses to parse (a stray `]` in the authority).
        // `.invalid` is reserved and never resolves, so a toolchain that starts parsing this fails the
        // assertion below rather than quietly making a network request.
        let base = "https://printer.invalid:8910]"
        XCTAssertNil(URL(string: base + "/api/v1/printers/"))

        let client = BambuddyClient(baseUrl: base, apiKey: "test-key")
        do {
            _ = try await client.probe(timeout: 1)
            XCTFail("expected a thrown error for a malformed base URL")
        } catch {
            // Whatever else happens, it must be a surfaceable message, not a trap.
            let classified = classifyConnectError(error)
            XCTAssertFalse(classified.message.isEmpty)
        }
    }
}
