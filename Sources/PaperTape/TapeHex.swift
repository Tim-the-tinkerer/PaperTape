import Foundation

// MARK: - Hexadecimal column packing (format v7)
//
// Each data channel has sixteen calibrated depths → 16^8 = 4_294_967_296 values
// per column. log2(4_294_967_296) = **32 bits/column exactly**.
//
// Densest packing: consecutive big-endian quads → one column value
// (4 bytes → 1 column). O(n), zero asymptotic waste (pad only for N mod 4 ≠ 0).

extension TapeEngine {

    /// Progressive ASCII depths 0…15 (full = `*`). Feed = `o`.
    /// Note: `#` is reserved for comments — never use it as a hole glyph.
    /// Glyphs: `. , : + = x % a b c d e f g @ *`
    static let hexDepthGlyphs: [Character] = [
        ".", ",", ":", "+", "=", "x", "%", "a",
        "b", "c", "d", "e", "f", "g", "@", "*",
    ]
    static let hexBlankGlyph: Character = "."
    static let hexFullGlyph: Character = "*"
    static let hexSprocketGlyph: Character = "o"

    /// 16^8 — values per hex column (exactly 2^32).
    static let hexadecimalBase: UInt64 = 4_294_967_296
    static let hexadecimalRadix = 16
    static let hexesPerColumn = 8

    // MARK: Value ↔ levels

    /// Channel levels 0…15 → column value V ∈ [0, 2^32−1], channel 1 = 16^0.
    static func hexadecimalValue(fromHexes hexes: [UInt8]) -> UInt32 {
        precondition(hexes.count == 8)
        var v: UInt64 = 0
        var place: UInt64 = 1
        for h in hexes {
            let d = UInt64(min(h, 15))
            v += d * place
            place *= 16
        }
        return UInt32(truncatingIfNeeded: v)
    }

    static func hexes(fromHexadecimalValue value: UInt32) -> [UInt8] {
        var x = UInt64(value)
        var out = [UInt8](repeating: 0, count: 8)
        for i in 0..<8 {
            out[i] = UInt8(x % 16)
            x /= 16
        }
        return out
    }

    /// Integrity over the full 32-bit column value (little-endian 4 bytes).
    static func hexadecimalIntegrityBytes(_ value: UInt32) -> [UInt8] {
        [
            UInt8(value & 0xFF),
            UInt8((value >> 8) & 0xFF),
            UInt8((value >> 16) & 0xFF),
            UInt8((value >> 24) & 0xFF),
        ]
    }

    // MARK: Pack / unpack (4 bytes → 1 column)

    /// Pack binary payload: consecutive big-endian quads → column values.
    /// Short remainder high-aligns remaining bytes (low bytes zero).
    static func packHexadecimal(_ data: Data) -> [UInt32] {
        if data.isEmpty { return [] }
        var out: [UInt32] = []
        out.reserveCapacity((data.count + 3) / 4)
        var i = data.startIndex
        while i < data.endIndex {
            var v: UInt32 = 0
            var shift: UInt32 = 24
            var took = 0
            while took < 4, i < data.endIndex {
                v |= UInt32(data[i]) << shift
                i = data.index(after: i)
                shift = shift &- 8
                took += 1
            }
            out.append(v)
        }
        return out
    }

    /// Inverse of `packHexadecimal`. Emits exactly `byteCount` bytes.
    static func unpackHexadecimal(_ values: [UInt32], byteCount: Int) -> Data {
        guard byteCount > 0 else { return Data() }
        var out = Data()
        out.reserveCapacity(byteCount)
        for v in values {
            if out.count >= byteCount { break }
            out.append(UInt8((v >> 24) & 0xFF))
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

    static func hexadecimalVisualToken(value: UInt32) -> String {
        let h = hexes(fromHexadecimalValue: value)
        func g(_ v: UInt8) -> Character {
            let i = Int(min(v, 15))
            return hexDepthGlyphs[i]
        }
        return "\(g(h[0]))\(g(h[1]))\(g(h[2]))\(hexSprocketGlyph)\(g(h[3]))\(g(h[4]))\(g(h[5]))\(g(h[6]))\(g(h[7]))"
    }

    static func parseHexadecimalToken(_ token: String) -> [UInt8]? {
        let cleaned = token
            .replacingOccurrences(of: " ", with: "")
            .replacingOccurrences(of: "\t", with: "")
        let chars = Array(cleaned)
        if chars.count == 9, isHexSprocket(chars[3]) {
            var hexes: [UInt8] = []
            hexes.reserveCapacity(8)
            for (i, ch) in chars.enumerated() {
                if i == 3 { continue }
                guard let q = hexLevel(ch) else { return nil }
                hexes.append(q)
            }
            return hexes.count == 8 ? hexes : nil
        }
        if chars.count == 8 {
            var hexes: [UInt8] = []
            for ch in chars {
                guard let q = hexLevel(ch) else { return nil }
                hexes.append(q)
            }
            return hexes
        }
        var hexes: [UInt8] = []
        for ch in chars {
            if isHexSprocket(ch) { continue }
            if let q = hexLevel(ch) {
                hexes.append(q)
            }
            if hexes.count == 8 { return hexes }
        }
        return hexes.count == 8 ? hexes : nil
    }

    private static func hexLevel(_ ch: Character) -> UInt8? {
        switch ch {
        case ".", "·", "0", "-", "_": return 0
        case ",", "1": return 1
        case ":", "2": return 2
        case "+", "3": return 3
        case "=", "4", "m", "M": return 4
        case "x", "X", "5": return 5
        case "%", "6", "&": return 6
        case "a", "A", "7": return 7
        case "b", "B", "8": return 8
        case "c", "C", "9": return 9
        case "d", "D": return 10
        case "e", "E": return 11
        case "f", "F": return 12
        case "g", "G": return 13
        case "@", "h", "H": return 14
        case "*", "●": return 15
        default: return nil
        }
    }

    private static func isHexSprocket(_ ch: Character) -> Bool {
        switch ch {
        case "o", "O", "○": return true
        default: return false
        }
    }

    /// Distinctive hex glyphs beyond v6 octal set.
    static func tokenLooksHexadecimal(_ token: String) -> Bool {
        for ch in token {
            switch ch {
            case "a"..."g", "A"..."G", "@": return true
            default: continue
            }
        }
        return false
    }

    static func hexadecimalColumns(fromPunched punched: Data) -> [Column] {
        packHexadecimal(punched).enumerated().map { Column(id: $0.offset, hexadecimalValue: $0.element) }
    }
}
