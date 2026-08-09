import Foundation

// Pure G-code -> per-layer toolpath parsing for the layer viewer, plus the scene maths the renderer
// needs to frame what came out. Nothing here touches UIKit, Metal or the network.

/// Axis-aligned extent of the printed geometry, in mm, in plate coordinates (0,0 = front-left).
struct GcodeBounds: Sendable, Equatable {
    var minX: Double
    var minY: Double
    var maxX: Double
    var maxY: Double
    var minZ: Double
    var maxZ: Double
}

/// Per-layer extrusion geometry: everything the layer viewer draws, and nothing it doesn't.
///
/// Geometry is stored FLAT — `[x0, y0, x1, y1, x0, y0, ...]`, four floats (16 bytes) per segment —
/// rather than as an array of segment structs, because the renderer uploads these runs to the GPU
/// verbatim as per-instance attributes. A boxed representation would cost a full extra copy of a
/// print that can reach 1.13M segments (the owner's spike ball), which is exactly the kind of
/// triple-copy that used to make big prints unpreviewable.
struct GcodeParseResult: Sendable {
    /// Model toolpath, one flat run per layer, bottom layer first.
    var layers: [[Float]]
    /// Support toolpath at the SAME layer index: `sup[i]` and `layers[i]` share `zs[i]`. Held apart
    /// so supports can be tinted separately and interleaved per layer in painter's order — a lower
    /// support must never paint over a higher model layer.
    var sup: [[Float]]
    /// Z height in mm of each layer.
    var zs: [Double]
    /// The slicer's own `enable_support` setting, read from the config comment block.
    var supportEnabled: Bool
    /// Whether support geometry was actually emitted (a print may enable supports and need none).
    var hasSupport: Bool
    /// Model segments across all layers — the GPU instance count.
    var segTotal: Int
    /// Support segments across all layers.
    var supTotal: Int
    var bounds: GcodeBounds
}

/// The machine's physical bed footprint, in mm.
struct GcodePlate: Sendable, Equatable {
    var w: Double
    var d: Double

    /// The A1's bed. Also the extent substituted when a file yields no printable geometry at all, so
    /// the viewer still has a ground reference instead of an empty void.
    static let `default` = GcodePlate(w: 256, d: 256)

    /// Grow the drawn plate, in 50 mm steps, to cover a toolpath that somehow exceeds the declared
    /// footprint — the model must never be drawn hanging off the edge of the plate.
    func fitted(to bounds: GcodeBounds) -> GcodePlate {
        GcodePlate(
            w: max(w, (max(bounds.maxX, 1) / 50).rounded(.up) * 50),
            d: max(d, (max(bounds.maxY, 1) / 50).rounded(.up) * 50)
        )
    }
}

/// Framing maths for the orbit camera: everything derivable from the parse result before a single
/// frame is drawn.
struct GcodeScene: Sendable, Equatable {
    /// Bed footprint, already grown to cover the toolpath.
    var plate: GcodePlate
    /// Orbit pivot X — the model footprint's centre.
    var pivotX: Double
    /// Orbit pivot Y — the model footprint's centre.
    var pivotY: Double
    /// Orbit pivot Z, at ~40% of the model's height rather than its middle: rotation then pivots
    /// around the print instead of the plate, and tall prints stay vertically centred instead of
    /// running off the top of the screen.
    var pivotZ: Double
    /// Half the model's bounding-box diagonal. The fit scale DIVIDES by this, so it is never 0.
    var radius: Double
    /// Model height used to normalise the bottom-to-top colour ramp.
    var zSpan: Double
    /// Smallest positive step between consecutive layers — layer heights vary per print, and per
    /// layer within a print (variable-height slicing).
    var minLayerGap: Double
    /// Tolerance for "is this layer the current one" when highlighting. Comfortably under a layer
    /// step so exactly one layer ever lights up.
    var highlightEpsilon: Double

    /// Default camera: a three-quarter view from slightly above, which reads as 3D immediately.
    static let defaultYaw = -0.62
    static let defaultPitch = 1.02
    static let defaultZoom = 1.0
    /// Pitch stays above the horizon. Not just cosmetic: with the camera above the model, layer
    /// order IS depth order, which is what lets the renderer draw bottom-to-top with no depth
    /// buffer (a depth test z-fights same-layer crossings into speckle).
    static let minPitch = 0.12
    static let maxPitch = 1.45
    static let minZoom = 0.15
    static let maxZoom = 14.0

    /// Derive the framing for a parsed print.
    init(bounds b: GcodeBounds, zs: [Double], plate: GcodePlate = .default) {
        self.plate = plate.fitted(to: b)
        pivotX = (b.minX + b.maxX) / 2
        pivotY = (b.minY + b.maxY) / 2
        pivotZ = (b.minZ + b.maxZ) * 0.4

        // A degenerate extent (one segment, or a single flat layer) must not reach the fit maths as
        // zero: the view scale is derived by dividing by `radius`, and a zero or negative scale
        // crashed the ground-shadow gradient outright when a real file was rendered headlessly.
        let bw = Self.nonZero(b.maxX - b.minX)
        let bh = Self.nonZero(b.maxY - b.minY)
        let bd = Self.nonZero(b.maxZ - b.minZ)
        radius = Self.nonZero(0.5 * (bw * bw + bh * bh + bd * bd).squareRoot())
        zSpan = Self.nonZero(b.maxZ - b.minZ)

        var gap = 0.2 // a plain 0.2 mm layer — the answer when there is nothing to measure
        if zs.count > 1 {
            for i in 1..<zs.count {
                let d = zs[i] - zs[i - 1]
                // 1e-4 discards float noise between two nominally identical Z values.
                if d > 1e-4, d < gap { gap = d }
            }
        }
        minLayerGap = gap
        highlightEpsilon = gap * 0.45
    }

    /// Clamp the orbit pitch to the band that keeps painter's ordering valid.
    static func clampPitch(_ v: Double) -> Double { min(max(v, minPitch), maxPitch) }

    /// Clamp the zoom factor to the usable range.
    static func clampZoom(_ v: Double) -> Double { min(max(v, minZoom), maxZoom) }

    private static func nonZero(_ v: Double) -> Double { (v == 0 || v.isNaN) ? 1 : v }
}

/// G-code -> per-layer toolpath.
enum GcodeLayers {

    /// Parse a G-code file into per-layer extrusion geometry.
    ///
    /// Only extruding XY moves become geometry: travels, retractions and Z-hops produce none. A
    /// layer boundary is a Z change seen on an EXTRUDING move — keying off Z alone would split a
    /// layer in two every time the toolhead hopped over a travel.
    static func parse(_ data: Data) -> GcodeParseResult {
        data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) -> GcodeParseResult in
            parse(bytes: raw.bindMemory(to: UInt8.self))
        }
    }

    /// Convenience for callers that already hold the file as a `String`.
    static func parse(_ text: String) -> GcodeParseResult {
        var text = text
        return text.withUTF8 { parse(bytes: $0) }
    }

    /// Exactly representable powers of ten, for the correctly-rounded numeric fast path below.
    private static let pow10: [Double] = [
        1e0, 1e1, 1e2, 1e3, 1e4, 1e5, 1e6, 1e7, 1e8, 1e9, 1e10, 1e11,
        1e12, 1e13, 1e14, 1e15, 1e16, 1e17, 1e18, 1e19, 1e20, 1e21, 1e22,
    ]

    // MARK: - the scan
    //
    // Why raw UTF-8 bytes rather than String APIs: a sliced file runs to tens of megabytes (~70 MB
    // for the spike ball). `String.Index` advances by grapheme cluster, so index-walking decodes
    // Unicode for every character of a file that is pure ASCII; `split`/`components(separatedBy:)`
    // would allocate one String per line — millions of allocations plus a second whole copy of the
    // file — and `Double(String)` would need a third per number. One pass over an
    // `UnsafeBufferPointer<UInt8>` allocates nothing per line and reads digits straight out of the
    // buffer. Multi-byte UTF-8 can only appear inside comments, where every scan below treats bytes
    // >= 0x80 as opaque non-word characters, so it is passed over harmlessly.
    private static func parse(bytes p: UnsafeBufferPointer<UInt8>) -> GcodeParseResult {
        let total = p.count

        let semicolon = UInt8(ascii: ";")
        let newline = UInt8(ascii: "\n")
        let equals = UInt8(ascii: "=")
        let plus = UInt8(ascii: "+")
        let minus = UInt8(ascii: "-")
        let dot = UInt8(ascii: ".")
        let zeroDigit = UInt8(ascii: "0")
        let oneDigit = UInt8(ascii: "1")
        let nineDigit = UInt8(ascii: "9")
        let letterE = UInt8(ascii: "E")
        let letterX = UInt8(ascii: "X")
        let letterY = UInt8(ascii: "Y")
        let letterZ = UInt8(ascii: "Z")

        // Lower-case needles for the case-insensitive comment scans, and the exact command spellings
        // (the slicer emits upper case; a lower-case `g1` is not a command here).
        let featureKey = Array("feature:".utf8)
        let supportKey = Array("support".utf8)
        let enableKey = Array("enable_support".utf8)
        let infinityKey = Array("Infinity".utf8)
        let cmdG90 = Array("G90".utf8)
        let cmdG91 = Array("G91".utf8)
        let cmdM82 = Array("M82".utf8)
        let cmdM83 = Array("M83".utf8)
        let cmdG92 = Array("G92".utf8)
        let cmdG0 = Array("G0".utf8)
        let cmdG1 = Array("G1".utf8)

        // E must advance by more than float noise for a move to count as extrusion.
        let eps = 1e-6

        var layers: [[Float]] = []
        var sup: [[Float]] = []
        var zs: [Double] = []
        // The buffers are refilled per layer; Array's own amortised growth handles prints whose
        // layers run to hundreds of thousands of segments.
        var seg: [Float] = []
        seg.reserveCapacity(4096)
        var sSeg: [Float] = []
        sSeg.reserveCapacity(1024)

        var x = 0.0, y = 0.0, z = 0.0, e = 0.0
        var absXYZ = true, absE = true
        var layerZ: Double?
        var isSupport = false, supportEnabled = false, hasSupport = false
        var minX = Double.infinity, minY = Double.infinity
        var maxX = -Double.infinity, maxY = -Double.infinity

        var cursor = 0    // token scanner position inside the current line
        var cursorEnd = 0 // end of the current line's code, comment already stripped

        @inline(__always) func isSpace(_ b: UInt8) -> Bool {
            b == 0x20 || (b >= 0x09 && b <= 0x0D) // space, tab, LF, VT, FF, CR
        }
        @inline(__always) func isDigit(_ b: UInt8) -> Bool { b >= zeroDigit && b <= nineDigit }
        @inline(__always) func fold(_ b: UInt8) -> UInt8 { (b >= 0x41 && b <= 0x5A) ? b &+ 0x20 : b }
        /// `\w` in a non-Unicode regex: ASCII letters, digits and underscore.
        @inline(__always) func isWord(_ b: UInt8) -> Bool {
            (b >= 0x41 && b <= 0x5A) || (b >= 0x61 && b <= 0x7A) || isDigit(b) || b == 0x5F
        }

        /// Case-insensitive search for a lower-case `needle` in `p[from..<to]`; returns its start.
        func findFold(_ needle: [UInt8], from: Int, to: Int) -> Int? {
            let n = needle.count
            guard n > 0, to - from >= n else { return nil }
            var i = from
            let last = to - n
            while i <= last {
                var j = 0
                while j < n, fold(p[i + j]) == needle[j] { j += 1 }
                if j == n { return i }
                i += 1
            }
            return nil
        }

        func tokenIs(_ lo: Int, _ hi: Int, _ ascii: [UInt8]) -> Bool {
            guard hi - lo == ascii.count else { return false }
            var k = 0
            while k < ascii.count {
                if p[lo + k] != ascii[k] { return false }
                k += 1
            }
            return true
        }

        /// Scale a digit string to a `Double`.
        ///
        /// Fast path: a mantissa below 2^53 with |exponent| <= 22 makes both operands exactly
        /// representable, so a SINGLE multiply or divide is correctly rounded — bit-identical to
        /// `strtod`. Anything longer (more than 19 significant digits, which G-code never carries)
        /// falls back to `pow`, which may land a ulp away.
        func scaled(_ mantissa: UInt64, _ exponent: Int, truncated: Bool) -> Double {
            let m = Double(mantissa)
            if !truncated, mantissa < 9_007_199_254_740_992 {
                if exponent == 0 { return m }
                if exponent > 0, exponent <= 22 { return m * pow10[exponent] }
                if exponent < 0, exponent >= -22 { return m / pow10[-exponent] }
            }
            return m * pow(10, Double(exponent))
        }

        /// Read the longest valid numeric PREFIX of `p[lo..<hi]`, returning nil where there is none.
        ///
        /// Prefix, not whole-string: a parameter may carry a trailing unit or junk ("10.5mm" reads
        /// 10.5), and `Double(String)` rejects those outright, which would silently drop
        /// coordinates. Tokens are whitespace-delimited by construction, so no leading whitespace
        /// can appear here.
        func parseNumberPrefix(_ lo: Int, _ hi: Int) -> Double? {
            var i = lo
            var negative = false
            if i < hi, p[i] == plus || p[i] == minus {
                negative = p[i] == minus
                i += 1
            }
            // A literal "Infinity" is accepted, and only in that exact casing.
            if hi - i >= infinityKey.count {
                var k = 0
                while k < infinityKey.count, p[i + k] == infinityKey[k] { k += 1 }
                if k == infinityKey.count { return negative ? -.infinity : .infinity }
            }

            var mantissa: UInt64 = 0
            var digits = 0
            var exponent = 0
            var truncated = false
            let mantissaCeiling = (UInt64.max - 9) / 10

            while i < hi, isDigit(p[i]) {
                digits += 1
                if mantissa <= mantissaCeiling {
                    mantissa = mantissa * 10 + UInt64(p[i] - zeroDigit)
                } else {
                    truncated = true
                    exponent += 1
                }
                i += 1
            }
            if i < hi, p[i] == dot {
                i += 1
                while i < hi, isDigit(p[i]) {
                    digits += 1
                    if mantissa <= mantissaCeiling {
                        mantissa = mantissa * 10 + UInt64(p[i] - zeroDigit)
                        exponent -= 1
                    } else {
                        truncated = true
                    }
                    i += 1
                }
            }
            guard digits > 0 else { return nil }

            if i < hi, (p[i] | 0x20) == UInt8(ascii: "e") {
                var j = i + 1
                var expNegative = false
                if j < hi, p[j] == plus || p[j] == minus {
                    expNegative = p[j] == minus
                    j += 1
                }
                var value = 0
                var expDigits = 0
                while j < hi, isDigit(p[j]) {
                    // Saturate: 10^1e6 is already infinity (or zero), so more digits change nothing.
                    value = min(value * 10 + Int(p[j] - zeroDigit), 1_000_000)
                    expDigits += 1
                    j += 1
                }
                // An incomplete exponent ("1e", "1e+") is not part of the number: the mantissa alone
                // is the valid prefix.
                if expDigits > 0 { exponent += expNegative ? -value : value }
            }

            let magnitude = scaled(mantissa, exponent, truncated: truncated)
            return negative ? -magnitude : magnitude
        }

        /// Classify a comment: the feature marker the slicer writes before each toolpath block, or
        /// the `enable_support` line in its config trailer.
        func scanComment(_ lo: Int, _ hi: Int) {
            if let f = findFold(featureKey, from: lo, to: hi) {
                let rest = f + featureKey.count
                // A bare "FEATURE:" with nothing after it names no feature and changes nothing; a
                // real one is either support or it isn't, so this never also carries config.
                if rest < hi {
                    isSupport = findFold(supportKey, from: rest, to: hi) != nil
                    return
                }
            }
            var from = lo
            while let s = findFold(enableKey, from: from, to: hi) {
                from = s + 1
                // Word boundary: `foo_enable_support` is a different setting.
                if s > lo, isWord(p[s - 1]) { continue }
                var i = s + enableKey.count
                while i < hi, isSpace(p[i]) { i += 1 }
                guard i < hi, p[i] == equals else { continue }
                i += 1
                while i < hi, isSpace(p[i]) { i += 1 }
                guard i < hi, p[i] == zeroDigit || p[i] == oneDigit else { continue }
                supportEnabled = p[i] == oneDigit
                return
            }
        }

        func pushLayer() {
            guard !seg.isEmpty || !sSeg.isEmpty else { return }
            layers.append(seg)
            sup.append(sSeg)
            zs.append(layerZ ?? 0)
            seg.removeAll(keepingCapacity: true)
            sSeg.removeAll(keepingCapacity: true)
        }

        func nextToken() -> (Int, Int)? {
            while cursor < cursorEnd, isSpace(p[cursor]) { cursor += 1 }
            guard cursor < cursorEnd else { return nil }
            let start = cursor
            while cursor < cursorEnd, !isSpace(p[cursor]) { cursor += 1 }
            return (start, cursor)
        }

        var pos = 0
        while pos < total {
            var nl = pos
            while nl < total, p[nl] != newline { nl += 1 }
            let lineStart = pos
            var lineEnd = nl
            pos = nl + 1

            var i = lineStart
            while i < lineEnd, p[i] != semicolon { i += 1 }
            if i < lineEnd {
                scanComment(i + 1, lineEnd)
                lineEnd = i
            }

            cursor = lineStart
            cursorEnd = lineEnd
            // No explicit trim is needed: a line of nothing but whitespace (including the CR of a
            // CRLF file) yields no first token and is skipped here.
            guard let (c0, c1) = nextToken() else { continue }

            if tokenIs(c0, c1, cmdG90) { absXYZ = true; absE = true; continue }
            if tokenIs(c0, c1, cmdG91) { absXYZ = false; absE = false; continue }
            if tokenIs(c0, c1, cmdM82) { absE = true; continue }
            if tokenIs(c0, c1, cmdM83) { absE = false; continue }
            if tokenIs(c0, c1, cmdG92) {
                while let (a, b) = nextToken() {
                    if p[a] == letterE, let v = parseNumberPrefix(a + 1, b) { e = v }
                }
                continue
            }
            guard tokenIs(c0, c1, cmdG0) || tokenIs(c0, c1, cmdG1) else { continue }

            var nx = x, ny = y, nz = z, ne = e
            var hasE = false, movedXY = false
            while let (a, b) = nextToken() {
                guard let v = parseNumberPrefix(a + 1, b) else { continue }
                switch p[a] {
                case letterX: nx = absXYZ ? v : x + v; movedXY = true
                case letterY: ny = absXYZ ? v : y + v; movedXY = true
                case letterZ: nz = absXYZ ? v : z + v
                case letterE: ne = absE ? v : e + v; hasE = true
                default: break
                }
            }

            if hasE, ne > e + eps, movedXY, nx != x || ny != y {
                if let lz = layerZ {
                    // 0.001 mm is far below any real layer height (0.04 mm at the finest), so this
                    // only ever fires on a genuine layer change.
                    if abs(nz - lz) > 0.001 {
                        pushLayer()
                        layerZ = nz
                    }
                } else {
                    layerZ = nz
                }
                if isSupport {
                    sSeg.append(Float(x)); sSeg.append(Float(y))
                    sSeg.append(Float(nx)); sSeg.append(Float(ny))
                    hasSupport = true
                } else {
                    seg.append(Float(x)); seg.append(Float(y))
                    seg.append(Float(nx)); seg.append(Float(ny))
                }
                if x < minX { minX = x }
                if x > maxX { maxX = x }
                if y < minY { minY = y }
                if y > maxY { maxY = y }
                if nx < minX { minX = nx }
                if nx > maxX { maxX = nx }
                if ny < minY { minY = ny }
                if ny > maxY { maxY = ny }
            }

            x = nx
            y = ny
            z = nz
            if hasE { e = ne }
        }
        pushLayer()

        // Leading PRIME/PURGE layers: the H2C purges at an ELEVATED Z before the first real layer. A
        // leading layer followed by a >0.5 mm DROP is priming, not model — exclude it from the
        // bounds so the fit and the pivot track the actual print (it still renders).
        var firstReal = 0
        while firstReal < zs.count - 1, zs[firstReal] > zs[firstReal + 1] + 0.5 { firstReal += 1 }
        if firstReal > 0 {
            minX = .infinity; minY = .infinity
            maxX = -.infinity; maxY = -.infinity
            func accumulate(_ run: [Float]) {
                var q = 0
                while q + 1 < run.count {
                    let vx = Double(run[q]), vy = Double(run[q + 1])
                    if vx < minX { minX = vx }
                    if vx > maxX { maxX = vx }
                    if vy < minY { minY = vy }
                    if vy > maxY { maxY = vy }
                    q += 2
                }
            }
            for k in firstReal..<layers.count {
                accumulate(layers[k])
                accumulate(sup[k])
            }
        }
        if !minX.isFinite {
            minX = 0; minY = 0
            maxX = GcodePlate.default.w; maxY = GcodePlate.default.d
        }

        var minZ = Double.infinity, maxZ = -Double.infinity
        for k in firstReal..<zs.count {
            if zs[k] < minZ { minZ = zs[k] }
            if zs[k] > maxZ { maxZ = zs[k] }
        }
        if !minZ.isFinite { minZ = 0; maxZ = 1 }

        var segTotal = 0
        for run in layers { segTotal += run.count / 4 }
        var supTotal = 0
        for run in sup { supTotal += run.count / 4 }

        return GcodeParseResult(
            layers: layers,
            sup: sup,
            zs: zs,
            supportEnabled: supportEnabled,
            hasSupport: hasSupport,
            segTotal: segTotal,
            supTotal: supTotal,
            bounds: GcodeBounds(minX: minX, minY: minY, maxX: maxX, maxY: maxY, minZ: minZ, maxZ: maxZ)
        )
    }
}
