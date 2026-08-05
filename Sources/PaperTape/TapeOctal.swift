import Foundation

// MARK: - Octal column packing (format v6)
//
// Each data channel has eight calibrated depths → 8^8 = 16_777_216 values per
// column. log2(16_777_216) = **24 bits/column exactly**.
//
// Densest packing: consecutive big-endian triples → one column value
// (3 bytes → 1 column). O(n), zero asymptotic waste (pad only for N mod 3 ≠ 0).

extension TapeEngine {

    /// Glyphs: `.`=0 … `*`=7 full, `o`=feed.
    /// Progressive ASCII depths: `. , : + = x % *`
    /// Note: `#` is reserved for comments / integrity markers — never use it as a hole glyph.
    static let octBlankGlyph: Character = "."
    static let octL1Glyph: Character = ","
    static let octL2Glyph: Character = ":"
    static let octL3Glyph: Character = "+"
    static let octL4Glyph: Character = "="
    static let octL5Glyph: Character = "x"
    static let octL6Glyph: Character = "%"
    static let octFullGlyph: Character = "*"
    static let octSprocketGlyph: Character = "o"

    /// 8^8 — values per octal column (exactly 2^24).
    static let octalBase = 16_777_216
    static let octalRadix = 8
    static let octsPerColumn = 8

    // MARK: Value ↔ levels

    /// Channel levels 0…7 → column value V ∈ [0, 16_777_215], channel 1 = 8^0.
    static func octalValue(fromOcts octs: [UInt8]) -> UInt32 {
        precondition(octs.count == 8)
        var v = 0
        var place = 1
        for o in octs {
            let d = Int(min(o, 7))
            v += d * place
            place *= 8
        }
        return UInt32(v)
    }

    static func octs(fromOctalValue value: UInt32) -> [UInt8] {
        var x = Int(value & 0x00FF_FFFF)
        var out = [UInt8](repeating: 0, count: 8)
        for i in 0..<8 {
            out[i] = UInt8(x % 8)
            x /= 8
        }
        return out
    }

    /// Integrity over the 24-bit column value (little-endian 3 bytes).
    static func octalIntegrityBytes(_ value: UInt32) -> [UInt8] {
        let v = value & 0x00FF_FFFF
        return [
            UInt8(v & 0xFF),
            UInt8((v >> 8) & 0xFF),
            UInt8((v >> 16) & 0xFF),
        ]
    }

    // MARK: Pack / unpack (3 bytes → 1 column)

    /// Pack binary payload: consecutive big-endian triples → column values.
    /// Remainder 1 byte → `byte << 16`; remainder 2 → `(b0 << 16) | (b1 << 8)`.
    static func packOctal(_ data: Data) -> [UInt32] {
        if data.isEmpty { return [] }
        var out: [UInt32] = []
        out.reserveCapacity((data.count + 2) / 3)
        var i = data.startIndex
        while i < data.endIndex {
            let b0 = UInt32(data[i])
            i = data.index(after: i)
            if i >= data.endIndex {
                out.append(b0 << 16)
                break
            }
            let b1 = UInt32(data[i])
            i = data.index(after: i)
            if i >= data.endIndex {
                out.append((b0 << 16) | (b1 << 8))
                break
            }
            let b2 = UInt32(data[i])
            i = data.index(after: i)
            out.append((b0 << 16) | (b1 << 8) | b2)
        }
        return out
    }

    /// Inverse of `packOctal`. Emits exactly `byteCount` bytes.
    static func unpackOctal(_ values: [UInt32], byteCount: Int) -> Data {
        guard byteCount > 0 else { return Data() }
        var out = Data()
        out.reserveCapacity(byteCount)
        for v in values {
            if out.count >= byteCount { break }
            out.append(UInt8((v >> 16) & 0xFF))
            if out.count >= byteCount { break }
            out.append(UInt8((v >> 8) & 0xFF))
            if out.count >= byteCount { break }
            out.append(UInt8(v & 0xFF))
        }
        while out.count < byteCount { out.append(0) }
        if out.count > byteCount {
            out = Data(out.prefix(byteCount))
        }
        return out
    }

    // MARK: Visual tokens

    static func octalVisualToken(value: UInt32) -> String {
        let o = octs(fromOctalValue: value)
        func g(_ v: UInt8) -> Character {
            switch v {
            case 0: return octBlankGlyph
            case 1: return octL1Glyph
            case 2: return octL2Glyph
            case 3: return octL3Glyph
            case 4: return octL4Glyph
            case 5: return octL5Glyph
            case 6: return octL6Glyph
            default: return octFullGlyph
            }
        }
        return "\(g(o[0]))\(g(o[1]))\(g(o[2]))\(octSprocketGlyph)\(g(o[3]))\(g(o[4]))\(g(o[5]))\(g(o[6]))\(g(o[7]))"
    }

    static func parseOctalToken(_ token: String) -> [UInt8]? {
        let cleaned = token
            .replacingOccurrences(of: " ", with: "")
            .replacingOccurrences(of: "\t", with: "")
        let chars = Array(cleaned)
        if chars.count == 9, isOctSprocket(chars[3]) {
            var octs: [UInt8] = []
            octs.reserveCapacity(8)
            for (i, ch) in chars.enumerated() {
                if i == 3 { continue }
                guard let q = octLevel(ch) else { return nil }
                octs.append(q)
            }
            return octs.count == 8 ? octs : nil
        }
        if chars.count == 8 {
            var octs: [UInt8] = []
            for ch in chars {
                guard let q = octLevel(ch) else { return nil }
                octs.append(q)
            }
            return octs
        }
        var octs: [UInt8] = []
        for ch in chars {
            if isOctSprocket(ch) { continue }
            if let q = octLevel(ch) {
                octs.append(q)
            }
            if octs.count == 8 { return octs }
        }
        return octs.count == 8 ? octs : nil
    }

    private static func octLevel(_ ch: Character) -> UInt8? {
        switch ch {
        case ".", "·", "0", "-", "_": return 0
        case ",", "1": return 1
        case ":", "2": return 2
        case "+", "◦", "3": return 3
        case "=", "│", "|", "4", "m", "M": return 4
        case "x", "X", "5": return 5
        case "%", "#", "6", "&": return 6  // `#` accepted when reading legacy/mistaken tokens
        case "*", "●", "7": return 7
        default: return nil
        }
    }

    private static func isOctSprocket(_ ch: Character) -> Bool {
        switch ch {
        case "o", "O", "○": return true
        default: return false
        }
    }

    /// Distinctive octal glyphs not used as primary v5 medium-only markers.
    static func tokenLooksOctal(_ token: String) -> Bool {
        token.contains(",") || token.contains(":") || token.contains("x")
            || token.contains("X") || token.contains("%")
    }

    static func octalColumns(fromPunched punched: Data) -> [Column] {
        packOctal(punched).enumerated().map { Column(id: $0.offset, octalValue: $0.element) }
    }
}
