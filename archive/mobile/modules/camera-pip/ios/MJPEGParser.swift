import Foundation
import AVFoundation
import AVKit
import CoreMedia
import CoreVideo
import ImageIO
import UIKit
import os

// ============================================================================
// MARK: - 1. Incremental multipart/x-mixed-replace parser
// ============================================================================

enum MJPEGParseEvent {
    case frame(Data)
    /// A non-image part. Bambuddy emits exactly one `text/plain` part inside an HTTP 200
    /// while the on-demand camera is warming up or has failed. THIS is the warm-up signal.
    case nonImagePart(contentType: String, body: Data)
    case endOfStream
}

enum MJPEGParseError: LocalizedError {
    case bufferOverflow(limit: Int)
    case malformedHeaders
    case badContentLength(String)

    var errorDescription: String? {
        switch self {
        case .bufferOverflow(let l):   return "multipart buffer exceeded \(l) bytes without a boundary"
        case .malformedHeaders:        return "multipart part headers were malformed"
        case .badContentLength(let s): return "unparsable Content-Length: \(s)"
        }
    }
}

/// Incremental parser for `multipart/x-mixed-replace`.
///
/// URLSession delivers ~16–64 KB per `didReceive data:` callback, so a 200 KB JPEG spans
/// 4–15 callbacks and a boundary marker WILL land split across two of them. Rules encoded here:
///
///  * never rescan bytes already scanned, except the tail that could be the prefix of a
///    boundary completed by the next chunk;
///  * honour `Content-Length` when present (one memcpy, zero scanning) and fall back to
///    scanning for the next delimiter when it is absent;
///  * a candidate delimiter only counts if it starts a line AND is followed by CRLF / LF /
///    HT / SP / `--`, so JPEG entropy data containing the bytes `--frame` cannot truncate a
///    frame on the scanning path;
///  * discard the preamble before the first delimiter and re-seek after every body (the
///    inter-part CRLF is framing, not payload);
///  * tolerate bare-LF line endings.
///
/// Pure value type, no I/O — unit-testable without a socket.
struct MultipartMJPEGParser {

    /// Hard cap on the rolling buffer. One 1680x1080 frame is 191–261 KB, so 8 MB is ~30
    /// frames of slack before we declare the stream desynchronised instead of running out of
    /// memory on a server that stopped emitting boundaries.
    static let bufferLimit = 8 * 1024 * 1024

    private enum State {
        case seekingDelimiter
        case atDelimiter
        case bodyKnown(headers: [String: String], length: Int)
        case bodyScan(headers: [String: String])
        case finished
    }

    private let delimiter: [UInt8]        // "--<boundary>"
    private var buf: [UInt8] = []
    private var scanned = 0               // bytes already searched for `delimiter`
    private var state: State = .seekingDelimiter
    private var atStreamStart = true      // only the first delimiter may omit a leading LF

    init(boundary: String) { self.delimiter = Array(("--" + boundary).utf8) }

    /// `multipart/x-mixed-replace; boundary=frame` -> `frame`. Handles quoted/unspaced forms.
    static func boundary(fromContentType ct: String) -> String? {
        for rawParam in ct.split(separator: ";").dropFirst() {
            let p = rawParam.trimmingCharacters(in: .whitespaces)
            guard p.lowercased().hasPrefix("boundary=") else { continue }
            var v = String(p.dropFirst("boundary=".count)).trimmingCharacters(in: .whitespaces)
            if v.hasPrefix("\""), v.hasSuffix("\""), v.count >= 2 { v = String(v.dropFirst().dropLast()) }
            return v.isEmpty ? nil : v
        }
        return nil
    }

    /// Feed one network chunk. Returns every event it completed (usually 0 or 1 frames).
    mutating func consume(_ chunk: Data) throws -> [MJPEGParseEvent] {
        if case .finished = state { return [] }
        buf.append(contentsOf: chunk)
        if buf.count > Self.bufferLimit { throw MJPEGParseError.bufferOverflow(limit: Self.bufferLimit) }
        var out: [MJPEGParseEvent] = []
        while try step(&out) {}
        return out
    }

    private mutating func step(_ out: inout [MJPEGParseEvent]) throws -> Bool {
        switch state {
        case .finished:
            return false

        case .seekingDelimiter:
            guard let idx = findDelimiter() else { return false }
            drop(idx)
            atStreamStart = false
            state = .atDelimiter
            return true

        case .atDelimiter:
            guard buf.count >= delimiter.count + 2 else { return false }
            var i = delimiter.count
            if buf[i] == 0x2D, buf[i + 1] == 0x2D {                     // closing "--boundary--"
                out.append(.endOfStream)
                buf.removeAll(keepingCapacity: false)
                scanned = 0
                state = .finished
                return false
            }
            while i < buf.count, buf[i] == 0x20 || buf[i] == 0x09 { i += 1 }
            guard i < buf.count else { return false }
            if buf[i] == 0x0D { i += 1 }
            guard i < buf.count else { return false }
            guard buf[i] == 0x0A else { throw MJPEGParseError.malformedHeaders }
            i += 1
            guard let (headers, bodyStart) = try parseHeaders(from: i) else { return false }
            drop(bodyStart)
            if let lenStr = headers["content-length"] {
                guard let n = Int(lenStr.trimmingCharacters(in: .whitespaces)), n >= 0 else {
                    throw MJPEGParseError.badContentLength(lenStr)
                }
                state = .bodyKnown(headers: headers, length: n)
            } else {
                state = .bodyScan(headers: headers)
            }
            return true

        case .bodyKnown(let headers, let length):
            guard buf.count >= length else { return false }
            let body = Data(buf[0..<length])
            drop(length)
            state = .seekingDelimiter                                   // trailing CRLF is framing
            emit(headers: headers, body: body, into: &out)
            return true

        case .bodyScan(let headers):
            guard let idx = findDelimiter() else { return false }
            var end = idx
            if end > 0, buf[end - 1] == 0x0A { end -= 1; if end > 0, buf[end - 1] == 0x0D { end -= 1 } }
            let body = Data(buf[0..<end])
            drop(idx)                                                   // leave delimiter at buf[0]
            state = .atDelimiter
            emit(headers: headers, body: body, into: &out)
            return true
        }
    }

    private func emit(headers: [String: String], body: Data, into out: inout [MJPEGParseEvent]) {
        let ct = headers["content-type"]?.lowercased() ?? ""
        // Two independent gates: the declared type must be an image AND the payload must open
        // with SOI. A gateway that returns a JSON error under `Content-Type: image/jpeg` would
        // otherwise be handed to the decoder ten times a second.
        let claimsJPEG = ct.contains("image/jpeg") || ct.contains("image/jpg")
        if claimsJPEG, body.count >= 2, body[body.startIndex] == 0xFF, body[body.startIndex + 1] == 0xD8 {
            out.append(.frame(body))
        } else {
            out.append(.nonImagePart(contentType: ct.isEmpty ? "(none)" : ct, body: body))
        }
    }

    private func parseHeaders(from start: Int) throws -> ([String: String], Int)? {
        var headers: [String: String] = [:]
        var i = start, lineStart = start
        while i < buf.count {
            guard buf[i] == 0x0A else { i += 1; continue }
            var lineEnd = i
            if lineEnd > lineStart, buf[lineEnd - 1] == 0x0D { lineEnd -= 1 }
            if lineEnd == lineStart { return (headers, i + 1) }          // blank line -> done
            let line = String(decoding: buf[lineStart..<lineEnd], as: UTF8.self)
            if let c = line.firstIndex(of: ":") {
                headers[line[line.startIndex..<c].trimmingCharacters(in: .whitespaces).lowercased()] =
                    String(line[line.index(after: c)...]).trimmingCharacters(in: .whitespaces)
            }
            i += 1
            lineStart = i
        }
        if buf.count - start > 64 * 1024 { throw MJPEGParseError.malformedHeaders }
        return nil
    }

    /// memchr-accelerated search for a *valid* delimiter. Advances `scanned` so bytes are never
    /// re-examined, but always leaves `delimiter.count + 1` bytes unscanned so a marker split
    /// across two chunks is still found on the next feed.
    private mutating func findDelimiter() -> Int? {
        let n = delimiter.count
        let tail = n + 2                                   // delimiter + 2 validation bytes
        guard buf.count >= tail else { return nil }
        let first = delimiter[0]
        let last = buf.count - tail
        let start = min(scanned, last + 1)
        var result: Int?
        var newScanned = max(0, buf.count - (tail - 1))
        let streamStart = atStreamStart

        delimiter.withUnsafeBufferPointer { dp in
            buf.withUnsafeBufferPointer { bp in
                let base = bp.baseAddress!
                var i = max(start, 0)
                while i <= last {
                    guard let p = memchr(base + i, Int32(first), bp.count - i) else { return }
                    let idx = UnsafeRawPointer(p).assumingMemoryBound(to: UInt8.self) - base
                    if idx > last { return }
                    if memcmp(base + idx, dp.baseAddress!, n) == 0 {
                        let startsLine = (idx == 0 && streamStart) || (idx > 0 && base[idx - 1] == 0x0A)
                        let f0 = base[idx + n], f1 = base[idx + n + 1]
                        let terminated = f0 == 0x0D || f0 == 0x0A || f0 == 0x20 || f0 == 0x09
                            || (f0 == 0x2D && f1 == 0x2D)
                        if startsLine, terminated { result = idx; newScanned = idx; return }
                    }
                    i = idx + 1
                }
            }
        }
        scanned = newScanned
        return result
    }

    private mutating func drop(_ k: Int) {
        guard k > 0 else { return }
        buf.removeFirst(min(k, buf.count))
        scanned = max(0, scanned - k)
    }
}

// ============================================================================
// MARK: - 2. JPEG header inspection (no decode)
// ============================================================================

struct JPEGInfo {
    let width: Int
    let height: Int
    let isProgressive: Bool     // SOF2. Hardware JPEG decoders commonly reject these.
}

/// Walk JPEG markers to the first SOFn. Reads only the header (a few hundred bytes),
/// never the entropy-coded data — costs microseconds, unlike a full decode.
func inspectJPEG(_ d: Data) -> JPEGInfo? {
    return d.withUnsafeBytes { (raw: UnsafeRawBufferPointer) -> JPEGInfo? in
        let b = raw.bindMemory(to: UInt8.self)
        guard b.count > 4, b[0] == 0xFF, b[1] == 0xD8 else { return nil }
        var i = 2
        while i + 3 < b.count {
            guard b[i] == 0xFF else { i += 1; continue }                 // resync over fill bytes
            let marker = b[i + 1]
            if marker == 0xFF || marker == 0x00 { i += 1; continue }
            if marker == 0xD8 || (marker >= 0xD0 && marker <= 0xD9) { i += 2; continue }
            guard i + 3 < b.count else { return nil }
            let segLen = Int(b[i + 2]) << 8 | Int(b[i + 3])
            // SOF0/1 baseline+extended, SOF2 progressive, SOF9/10 arithmetic. Skip DHT(C4)/DAC(CC).
            if (marker >= 0xC0 && marker <= 0xCF), marker != 0xC4, marker != 0xC8, marker != 0xCC {
                guard i + 9 < b.count else { return nil }
                let h = Int(b[i + 5]) << 8 | Int(b[i + 6])
                let w = Int(b[i + 7]) << 8 | Int(b[i + 8])
                return JPEGInfo(width: w, height: h, isProgressive: marker == 0xC2 || marker == 0xCA)
            }
            if segLen < 2 { return nil }
            i += 2 + segLen
        }
        return nil
    }
}

// ============================================================================
