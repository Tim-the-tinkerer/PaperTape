import Foundation

// MARK: - Ternary column packing (format v4)
//
// Each data channel has three states (blank / mid / full) → 3^8 = 6561 values per
// column (feed hole is always present, not part of the value).
//
// Density: log2(6561) ≈ 12.684 bits/column vs 8 bits for binary punch.
//
// Highest packing: interpret the entire punched binary payload as one big-endian
// integer and emit base-6561 digits (LSB-first columns). Streaming uses the same
// full conversion on fixed-size binary chunks (`pack-chunk`).

extension TapeEngine {

    /// How binary payload bytes are mapped onto multi-state columns.
    enum PackingMode: String, Equatable {
        /// Classic 1 byte = 1 binary column (v1–v3).
        case binary = "binary"
        /// Full base-6561 integer conversion (v4).
        case ternaryFull = "full"
        /// Streamable near-optimal ternary: every 3 bytes → 2 columns (v4 stream).
        case ternaryBlock3 = "block3"
        /// Quaternary: every 2 bytes → 1 column (v5; exactly 16 bits/col).
        case quaternary = "quat"
        /// Octal: every 3 bytes → 1 column (v6; exactly 24 bits/col).
        case octal = "oct"
        /// Hexadecimal: every 4 bytes → 1 column (v7; exactly 32 bits/col).
        case hexadecimal = "hex"
        /// Base-256: every 8 bytes → 1 column (v8; exactly 64 bits/col).
        case base256 = "b256"
        case base512 = "b512"

        var isTernary: Bool { self == .ternaryFull || self == .ternaryBlock3 }
        var isQuaternary: Bool { self == .quaternary }
        var isOctal: Bool { self == .octal }
        var isHexadecimal: Bool { self == .hexadecimal }
        var isBase256: Bool { self == .base256 }
        /// Non-binary packing (ternary / quat / oct / hex / base-256).
        var isMultistate: Bool { self != .binary }

        static func parse(_ raw: String) -> PackingMode {
            let key = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            switch key {
            case "b512", "base512": return .base512
            case "full", "ternary", "ternary-full", "base6561", "6561":
                return .ternaryFull
            case "block3", "block-3", "3+2", "stream":
                return .ternaryBlock3
            case "quat", "quaternary", "base65536", "65536", "q2", "4":
                return .quaternary
            case "oct", "octal", "base16777216", "16777216", "o3", "8":
                return .octal
            case "hex", "hexadecimal", "base16", "base4294967296", "4294967296", "h4", "16":
                return .hexadecimal
            case "b256", "base256", "base-256", "byte", "256", "base18446744073709551616":
                return .base256
            case "binary", "none", "identity", "":
                return .binary
            default:
                return .binary
            }
        }
    }

    /// Glyphs for ternary columns: `.`=0 blank, `+`=1 mid, `*`=2 full, `o`=feed.
    static let ternaryBlankGlyph: Character = "."
    static let ternaryMidGlyph: Character = "+"
    static let ternaryFullGlyph: Character = "*"
    static let ternarySprocketGlyph: Character = "o"

    /// 3^8 — values per ternary column.
    static let ternaryBase = 6561

    /// Default binary chunk size for linear-time full-pack (bytes). Larger → denser,
    /// approaching the theoretical ~12.684 bits/col; 0 means whole payload.
    static let defaultTernaryPackChunk = 4_096

    /// Payloads at or below this use one whole-integer full pack (absolute densest).
    /// Larger payloads use fixed-width chunked full-pack (O(n), still ~12.68 bits/col).
    /// Whole-integer conversion is O(n²) and freezes the UI on multi-100KB+ files.
    static let ternaryWholePackMaxBytes = 24_576

    /// Choose pack-chunk for highest density that still finishes promptly.
    static func preferredTernaryPackChunk(byteCount: Int) -> Int {
        byteCount <= ternaryWholePackMaxBytes ? 0 : defaultTernaryPackChunk
    }

    // MARK: Big natural number (little-endian 32-bit limbs)

    /// Unsigned big integer used only for base-256 ↔ base-6561 conversion.
    struct BigNat: Equatable {
        /// Limbs, least-significant first. Empty == 0.
        var limbs: [UInt32]

        static let zero = BigNat(limbs: [])

        init(limbs: [UInt32]) {
            self.limbs = limbs
            trim()
        }

        /// Big-endian byte string → integer.
        init(bigEndian data: Data) {
            if data.isEmpty {
                limbs = []
                return
            }
            // Skip leading zero bytes (value-preserving).
            var start = data.startIndex
            while start < data.endIndex, data[start] == 0 {
                start = data.index(after: start)
            }
            if start == data.endIndex {
                limbs = []
                return
            }
            let bytes = data[start...]
            var limbs: [UInt32] = []
            limbs.reserveCapacity((bytes.count + 3) / 4)
            var i = bytes.endIndex
            while i > bytes.startIndex {
                var limb: UInt32 = 0
                var shift: UInt32 = 0
                var count = 0
                while count < 4, i > bytes.startIndex {
                    i = bytes.index(before: i)
                    limb |= UInt32(bytes[i]) << shift
                    shift += 8
                    count += 1
                }
                limbs.append(limb)
            }
            self.limbs = limbs
            trim()
        }

        var isZero: Bool { limbs.isEmpty }

        mutating func trim() {
            while let last = limbs.last, last == 0 {
                limbs.removeLast()
            }
        }

        /// self = self * m + addend (addend < 2^32).
        mutating func multiplyAdd(m: UInt32, addend: UInt32 = 0) {
            if m == 0 {
                limbs = addend == 0 ? [] : [addend]
                return
            }
            var carry = UInt64(addend)
            for i in 0..<limbs.count {
                let prod = UInt64(limbs[i]) * UInt64(m) + carry
                limbs[i] = UInt32(truncatingIfNeeded: prod)
                carry = prod >> 32
            }
            while carry > 0 {
                limbs.append(UInt32(truncatingIfNeeded: carry))
                carry >>= 32
            }
            trim()
        }

        /// Divide by `d` (d > 0). Returns remainder; self becomes quotient.
        mutating func divide(by d: UInt32) -> UInt32 {
            precondition(d > 0)
            if limbs.isEmpty { return 0 }
            var rem: UInt64 = 0
            for i in (0..<limbs.count).reversed() {
                let cur = (rem << 32) | UInt64(limbs[i])
                limbs[i] = UInt32(cur / UInt64(d))
                rem = cur % UInt64(d)
            }
            trim()
            return UInt32(rem)
        }

        /// Big-endian representation, exactly `count` bytes (leading zeros padded).
        func bigEndianBytes(count: Int) -> Data {
            guard count > 0 else { return Data() }
            var out = Data(count: count)
            if limbs.isEmpty {
                return out
            }
            var idx = count
            for limb in limbs {
                for b in 0..<4 {
                    guard idx > 0 else { return out }
                    idx -= 1
                    out[idx] = UInt8(truncatingIfNeeded: limb >> (b * 8))
                }
            }
            return out
        }
    }

    // MARK: Trit ↔ value

    /// Channel levels 0/1/2 → column value V ∈ [0, 6560], channel 1 = 3^0.
    static func ternaryValue(fromTrits trits: [UInt8]) -> UInt16 {
        precondition(trits.count == 8)
        var v = 0
        var place = 1
        for t in trits {
            let d = Int(min(t, 2))
            v += d * place
            place *= 3
        }
        return UInt16(v)
    }

    /// Column value → 8 trits (channel 1 first).
    static func trits(fromTernaryValue value: UInt16) -> [UInt8] {
        var x = Int(value)
        if x < 0 { x = 0 }
        if x >= ternaryBase { x = ternaryBase - 1 }
        var out = [UInt8](repeating: 0, count: 8)
        for i in 0..<8 {
            out[i] = UInt8(x % 3)
            x /= 3
        }
        return out
    }

    /// Integrity bytes for one ternary column: V as little-endian UInt16.
    static func ternaryIntegrityBytes(_ value: UInt16) -> [UInt8] {
        [UInt8(value & 0xFF), UInt8((value >> 8) & 0xFF)]
    }

    // MARK: Full base-6561 pack / unpack

    /// Pack binary payload as one big-endian integer → base-6561 digits (LSB first).
    /// O(n²) in payload size — only call on modest buffers (see `preferredTernaryPackChunk`).
    static func packTernaryFull(_ data: Data) -> [UInt16] {
        if data.isEmpty { return [] }
        var n = BigNat(bigEndian: data)
        if n.isZero {
            // Non-empty all-zero bytes: emit a single 0 digit so the .Tape body has
            // columns (ternary-columns ≥ 1). unpackTernaryFull pads to byteCount.
            return [0]
        }
        var digits: [UInt16] = []
        digits.reserveCapacity(max(1, (data.count * 8 + 11) / 12))
        let base = UInt32(ternaryBase)
        while !n.isZero {
            let r = n.divide(by: base)
            digits.append(UInt16(r))
        }
        return digits
    }

    /// Inverse of `packTernaryFull`. Pads/truncates to exactly `byteCount` big-endian bytes.
    static func unpackTernaryFull(_ digits: [UInt16], byteCount: Int) -> Data {
        guard byteCount > 0 else { return Data() }
        var n = BigNat.zero
        let base = UInt32(ternaryBase)
        for d in digits.reversed() {
            let v = UInt32(min(Int(d), ternaryBase - 1))
            n.multiplyAdd(m: base, addend: v)
        }
        return n.bigEndianBytes(count: byteCount)
    }

    /// Unpack fixed-width chunked full packing (matches `packTernaryFullFixed`).
    static func unpackTernaryFullChunked(
        _ digits: [UInt16],
        byteCount: Int,
        chunkBytes: Int
    ) -> Data {
        guard byteCount > 0 else { return Data() }
        if chunkBytes <= 0 || chunkBytes >= byteCount {
            return unpackTernaryFull(digits, byteCount: byteCount)
        }
        var out = Data()
        out.reserveCapacity(byteCount)
        var digIdx = 0
        var remaining = byteCount
        while remaining > 0 {
            let thisChunk = min(chunkBytes, remaining)
            let digCount = ternaryDigitCapacity(byteCount: thisChunk)
            let slice: ArraySlice<UInt16>
            if digIdx + digCount <= digits.count {
                slice = digits[digIdx..<(digIdx + digCount)]
            } else if digIdx < digits.count {
                slice = digits[digIdx...]
            } else {
                slice = []
            }
            digIdx += digCount
            // Strip trailing zero pad digits before unpack (optional; zeros are fine).
            out.append(unpackTernaryFull(Array(slice), byteCount: thisChunk))
            remaining -= thisChunk
        }
        return out
    }

    /// Fixed digit width for `byteCount` bytes.
    /// `ceil(8n / log2(6561)) + 1` so max values (all 0xFF) always fit; one spare
    /// digit per chunk is negligible vs ~12.68 bits/col density.
    static func ternaryDigitCapacity(byteCount: Int) -> Int {
        guard byteCount > 0 else { return 0 }
        // log2(6561) ≈ 12.6847 → ceil(8n/12.6847) = (80000n + 126846) / 126847
        return max(1, (byteCount * 80_000 + 126_846) / 126_847 + 1)
    }

    /// Pack with fixed-width digits per chunk (stream-safe, near-max density).
    static func packTernaryFullFixed(_ data: Data, chunkBytes: Int) -> [UInt16] {
        if data.isEmpty { return [] }
        let chunk = chunkBytes <= 0 ? data.count : max(1, chunkBytes)
        var out: [UInt16] = []
        out.reserveCapacity(ternaryDigitCapacity(byteCount: data.count) + chunk)
        var offset = 0
        while offset < data.count {
            let end = min(offset + chunk, data.count)
            let slice = Data(data[offset..<end])
            var digs = packTernaryFull(slice)
            let width = ternaryDigitCapacity(byteCount: end - offset)
            if digs.count > width {
                // Extremely defensive: keep all digits (should not happen with +1).
                out.append(contentsOf: digs)
            } else {
                if digs.count < width {
                    digs.append(contentsOf: repeatElement(UInt16(0), count: width - digs.count))
                }
                out.append(contentsOf: digs)
            }
            offset = end
        }
        return out
    }

    // MARK: Block3 (3 bytes → 2 columns)

    /// Near-optimal streamable packing: 24 bits → 2 columns (12 bits/col).
    static func packTernaryBlock3(_ data: Data) -> [UInt16] {
        if data.isEmpty { return [] }
        var out: [UInt16] = []
        out.reserveCapacity(((data.count + 2) / 3) * 2)
        var i = data.startIndex
        while i < data.endIndex {
            let rem = data.distance(from: i, to: data.endIndex)
            var v = 0
            // Big-endian 3-byte groups (pad missing low bytes with 0).
            v |= Int(data[i]) << 16
            if rem >= 2 {
                v |= Int(data[data.index(i, offsetBy: 1)]) << 8
            }
            if rem >= 3 {
                v |= Int(data[data.index(i, offsetBy: 2)])
            }
            let d0 = v % ternaryBase
            let d1 = v / ternaryBase
            out.append(UInt16(d0))
            out.append(UInt16(d1))
            i = data.index(i, offsetBy: min(3, rem))
        }
        return out
    }

    static func unpackTernaryBlock3(_ digits: [UInt16], byteCount: Int) -> Data {
        guard byteCount > 0 else { return Data() }
        var out = Data()
        out.reserveCapacity(byteCount)
        var di = 0
        while out.count < byteCount {
            let d0 = di < digits.count ? Int(digits[di]) : 0
            let d1 = di + 1 < digits.count ? Int(digits[di + 1]) : 0
            di += 2
            let v = d0 + d1 * ternaryBase
            let b0 = UInt8((v >> 16) & 0xFF)
            let b1 = UInt8((v >> 8) & 0xFF)
            let b2 = UInt8(v & 0xFF)
            let need = byteCount - out.count
            if need >= 1 { out.append(b0) }
            if need >= 2 { out.append(b1) }
            if need >= 3 { out.append(b2) }
        }
        if out.count > byteCount {
            out = Data(out.prefix(byteCount))
        }
        return out
    }

    // MARK: Unified pack / unpack

    /// Pack with explicit chunk size. Pass `chunkBytes: preferredTernaryPackChunk(byteCount:)`
    /// for highest density that still runs in linear time on large buffers.
    static func packTernary(
        _ data: Data,
        mode: PackingMode,
        chunkBytes: Int = 0
    ) -> [UInt16] {
        switch mode {
        case .binary:
            return data.map { UInt16($0) }
        case .ternaryFull:
            // chunkBytes <= 0 → one whole-integer conversion (densest, O(n²)).
            // chunkBytes > 0 → fixed-width full pack per chunk (near densest, O(n)).
            if chunkBytes > 0 {
                return packTernaryFullFixed(data, chunkBytes: chunkBytes)
            }
            return packTernaryFull(data)
        case .ternaryBlock3:
            return packTernaryBlock3(data)
        case .quaternary:
            return packQuaternary(data)
        case .octal:
            preconditionFailure("packTernary does not support .octal; call packOctal")
        case .hexadecimal:
            preconditionFailure("packTernary does not support .hexadecimal; call packHexadecimal")
        case .base512:
            preconditionFailure("packTernary does not support .base512")
        case .base256:
            preconditionFailure("packTernary does not support .base256; call packBase256")
        }
    }

    static func unpackTernary(
        _ digits: [UInt16],
        mode: PackingMode,
        byteCount: Int,
        chunkBytes: Int = 0
    ) -> Data {
        switch mode {
        case .binary:
            var out = Data()
            out.reserveCapacity(min(byteCount, digits.count))
            for d in digits.prefix(byteCount) {
                out.append(UInt8(truncatingIfNeeded: d))
            }
            while out.count < byteCount { out.append(0) }
            return out
        case .ternaryFull:
            if chunkBytes > 0 {
                return unpackTernaryFullChunked(digits, byteCount: byteCount, chunkBytes: chunkBytes)
            }
            return unpackTernaryFull(digits, byteCount: byteCount)
        case .ternaryBlock3:
            return unpackTernaryBlock3(digits, byteCount: byteCount)
        case .quaternary:
            return unpackQuaternary(digits, byteCount: byteCount)
        case .octal:
            preconditionFailure("unpackTernary does not support .octal; call unpackOctal")
        case .hexadecimal:
            preconditionFailure("unpackTernary does not support .hexadecimal; call unpackHexadecimal")
        case .base512:
            preconditionFailure("unpackTernary does not support .base512")
        case .base256:
            preconditionFailure("unpackTernary does not support .base256; call unpackBase256")
        }
    }

    // MARK: Visual tokens (ternary)

    /// Column token: `c1 c2 c3 feed c4 c5 c6 c7 c8` with `.+*` and `o`.
    static func ternaryVisualToken(value: UInt16) -> String {
        let t = trits(fromTernaryValue: value)
        func g(_ v: UInt8) -> Character {
            switch v {
            case 0: return ternaryBlankGlyph
            case 1: return ternaryMidGlyph
            default: return ternaryFullGlyph
            }
        }
        return "\(g(t[0]))\(g(t[1]))\(g(t[2]))\(ternarySprocketGlyph)\(g(t[3]))\(g(t[4]))\(g(t[5]))\(g(t[6]))\(g(t[7]))"
    }

    static func ternaryVisualToken(trits t: [UInt8]) -> String {
        ternaryVisualToken(value: ternaryValue(fromTrits: t))
    }

    /// Parse a ternary column token into 8 trits. Returns nil if invalid.
    static func parseTernaryToken(_ token: String) -> [UInt8]? {
        let cleaned = token
            .replacingOccurrences(of: " ", with: "")
            .replacingOccurrences(of: "\t", with: "")
        let chars = Array(cleaned)
        // Prefer length-9 with sprocket at index 3.
        if chars.count == 9, isTernarySprocketChar(chars[3]) {
            var trits: [UInt8] = []
            trits.reserveCapacity(8)
            for (i, ch) in chars.enumerated() {
                if i == 3 { continue }
                guard let t = ternaryTrit(ch) else { return nil }
                trits.append(t)
            }
            return trits.count == 8 ? trits : nil
        }
        // 8 data trits only
        if chars.count == 8 {
            var trits: [UInt8] = []
            for ch in chars {
                guard let t = ternaryTrit(ch) else { return nil }
                trits.append(t)
            }
            return trits
        }
        // Longer: extract first 8 data glyphs, skip sprocket
        var trits: [UInt8] = []
        for ch in chars {
            if isTernarySprocketChar(ch) { continue }
            if let t = ternaryTrit(ch) {
                trits.append(t)
            }
            if trits.count == 8 { return trits }
        }
        return trits.count == 8 ? trits : nil
    }

    private static func ternaryTrit(_ ch: Character) -> UInt8? {
        switch ch {
        case ".", "·", "0", "-", "_": return 0
        case "+", "│", "|", "m", "M": return 1
        case "*", "●", "1", "X", "x", "#", "2": return 2
        default: return nil
        }
    }

    private static func isTernarySprocketChar(_ ch: Character) -> Bool {
        switch ch {
        case "o", "O", "○": return true
        default: return false
        }
    }

    /// True when a token looks ternary (has mid glyph or only ternary alphabet).
    static func tokenLooksTernary(_ token: String) -> Bool {
        token.contains("+")
    }
}
