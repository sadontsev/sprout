import XCTest
@testable import Sprout

/// The multipart parser behind the chamber camera.
///
/// This code has a bad history: the stream client once rejected its own first frame because
/// URLSession de-multiplexes `multipart/x-mixed-replace` itself and the boundary framing never
/// reaches the delegate. These tests exercise the parser directly with synthetic bytes so that
/// class of bug fails here rather than as a black tile on the dashboard.
final class MJPEGParserTests: XCTestCase {

    /// The smallest thing `inspectJPEG` and the SOI check will accept: SOI + a marker + EOI.
    private func jpeg(_ payload: [UInt8] = [0x00, 0x10, 0x01, 0x02]) -> Data {
        Data([0xFF, 0xD8] + payload + [0xFF, 0xD9])
    }

    private func part(boundary: String, contentType: String = "image/jpeg", body: Data, leadingCRLF: Bool = true) -> Data {
        var d = Data()
        if leadingCRLF { d.append(Data("\r\n".utf8)) }
        d.append(Data("--\(boundary)\r\n".utf8))
        d.append(Data("Content-Type: \(contentType)\r\n".utf8))
        d.append(Data("Content-Length: \(body.count)\r\n\r\n".utf8))
        d.append(body)
        return d
    }

    // MARK: - Boundary extraction

    func testBoundaryFromContentType() {
        XCTAssertEqual(MultipartMJPEGParser.boundary(fromContentType: "multipart/x-mixed-replace; boundary=frame"), "frame")
        XCTAssertEqual(MultipartMJPEGParser.boundary(fromContentType: "multipart/x-mixed-replace;boundary=--myBoundary"), "--myBoundary")
    }

    func testQuotedBoundaryIsUnwrapped() {
        XCTAssertEqual(MultipartMJPEGParser.boundary(fromContentType: #"multipart/x-mixed-replace; boundary="frame""#), "frame")
    }

    func testNoBoundaryYieldsNil() {
        XCTAssertNil(MultipartMJPEGParser.boundary(fromContentType: "image/jpeg"))
        XCTAssertNil(MultipartMJPEGParser.boundary(fromContentType: ""))
    }

    // MARK: - Framing

    func testSingleFrame() throws {
        var parser = MultipartMJPEGParser(boundary: "frame")
        let events = try parser.consume(part(boundary: "frame", body: jpeg(), leadingCRLF: false))
        let frames = events.compactMap { if case .frame(let d) = $0 { return d } else { return nil } }
        XCTAssertEqual(frames.count, 1)
        XCTAssertEqual(frames[0], jpeg())
    }

    func testTwoFramesInOneChunk() throws {
        var parser = MultipartMJPEGParser(boundary: "frame")
        var data = part(boundary: "frame", body: jpeg([0x01]), leadingCRLF: false)
        data.append(part(boundary: "frame", body: jpeg([0x02])))
        data.append(Data("\r\n--frame\r\n".utf8))   // start of the next part, so the second can close

        let frames = try parser.consume(data).compactMap { if case .frame(let d) = $0 { return d } else { return nil } }
        XCTAssertEqual(frames.count, 2)
        XCTAssertEqual(frames[0], jpeg([0x01]))
        XCTAssertEqual(frames[1], jpeg([0x02]))
    }

    /// The real transport delivers arbitrary slices, not whole parts. Splitting mid-header and
    /// mid-body must not lose or corrupt a frame.
    func testFrameSplitAcrossManyChunks() throws {
        var parser = MultipartMJPEGParser(boundary: "frame")
        var whole = part(boundary: "frame", body: jpeg([0x0A, 0x0B, 0x0C, 0x0D]), leadingCRLF: false)
        whole.append(Data("\r\n--frame\r\n".utf8))

        var frames: [Data] = []
        for byte in whole {
            let events = try parser.consume(Data([byte]))
            frames += events.compactMap { if case .frame(let d) = $0 { return d } else { return nil } }
        }
        XCTAssertEqual(frames.count, 1)
        XCTAssertEqual(frames[0], jpeg([0x0A, 0x0B, 0x0C, 0x0D]))
    }

    /// Bytes that merely look like the boundary must not split a frame.
    func testBoundaryLikeBytesInsideTheBodyAreNotADelimiter() throws {
        var parser = MultipartMJPEGParser(boundary: "frame")
        let payload = Data([0xFF, 0xD8]) + Data("--fram".utf8) + Data([0x00, 0xFF, 0xD9])
        var data = part(boundary: "frame", body: payload, leadingCRLF: false)
        data.append(Data("\r\n--frame\r\n".utf8))

        let frames = try parser.consume(data).compactMap { if case .frame(let d) = $0 { return d } else { return nil } }
        XCTAssertEqual(frames.count, 1)
        XCTAssertEqual(frames[0], payload)
    }

    /// A gateway can answer with JSON under `Content-Type: image/jpeg`. Without the SOI check that
    /// reaches the decoder as a frame and renders nothing, with no error to explain why.
    func testNonJpegBodyIsNotEmittedAsAFrame() throws {
        var parser = MultipartMJPEGParser(boundary: "frame")
        var data = part(boundary: "frame", body: Data(#"{"detail":"camera offline"}"#.utf8), leadingCRLF: false)
        data.append(Data("\r\n--frame\r\n".utf8))

        let frames = try parser.consume(data).compactMap { if case .frame(let d) = $0 { return d } else { return nil } }
        XCTAssertTrue(frames.isEmpty, "a body that does not start with SOI is not a JPEG")
    }

    func testEmptyChunkIsHarmless() throws {
        var parser = MultipartMJPEGParser(boundary: "frame")
        XCTAssertNoThrow(try parser.consume(Data()))
    }

    // MARK: - JPEG inspection

    func testInspectRejectsNonJpeg() {
        XCTAssertNil(inspectJPEG(Data([0x00, 0x01, 0x02, 0x03, 0x04])))
        XCTAssertNil(inspectJPEG(Data()))
    }

    func testInspectAcceptsSoi() {
        // A minimal SOF0: 8-bit, 16x32, 3 components.
        let sof: [UInt8] = [0xFF, 0xC0, 0x00, 0x11, 0x08, 0x00, 0x20, 0x00, 0x10, 0x03]
        let d = Data([0xFF, 0xD8] + sof + [0xFF, 0xD9])
        let info = inspectJPEG(d)
        XCTAssertNotNil(info, "a well-formed SOI/SOF0/EOI must inspect")
    }
}
