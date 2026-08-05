import Foundation

// MARK: - Quaternary column packing (format v5)
//
// Each data channel has four depths (blank / shallow / medium / full) → 4^8 = 65_536
// values per column. log2(65536) = **16 bits/column exactly**.
//
// Highest efficient packing: pair payload bytes big-endian into UInt16 values
// (2 bytes → 1 column). O(n), zero asymptotic waste (1 byte pad only if odd length).

extension TapeEngine {

    /// Glyphs: `.`=0 blank, `+`=1 shallow, `=`=2 medium, `*`=3 full, `o`=feed.
    static let quatBlankGlyph: Character = "."
    static let quatShallowGlyph: Character = "+"
    static let quatMediumGlyph: Character = "="
    static let quatFullGlyph: Character = "*"
    static let quatSprocketGlyph: Character = "o"

    /// 4^8 — values per quaternary column (exactly 2^16).
    static let quaternaryBase = 65_536
    static let quaternaryRadix = 4
    static let quatsPerColumn = 8

    // MARK: Value ↔ quats

    /// Channel levels 0…3 → column value V ∈ [0, 65535], channel 1 = 4^0.
    static func quaternaryValue(fromQuats quats: [UInt8]) -> UInt16 {
        precondition(quats.count == 8)
        var v = 0
        var place = 1
        for q in quats {
            let d = Int(min(q, 3))
            v += d * place
            place *= 4
        }
        return UInt16(v)
    }

    static func quats(fromQuaternaryValue value: UInt16) -> [UInt8] {
        var x = Int(value)
        var out = [UInt8](repeating: 0, count: 8)
        for i in 0..<8 {
            out[i] = UInt8(x % 4)
            x /= 4
        }
        return out
    }

    static func quaternaryIntegrityBytes(_ value: UInt16) -> [UInt8] {
        [UInt8(value & 0xFF), UInt8((value >> 8) & 0xFF)]
    }

    // MARK: Pack / unpack (2 bytes → 1 column)

    /// Pack binary payload: consecutive big-endian pairs → column values (MSB pair first).
    /// Odd trailing byte becomes a column with value `byte << 8` (low byte 0).
    static func packQuaternary(_ data: Data) -> [UInt16] {
        if data.isEmpty { return [] }
        var out: [UInt16] = []
        out.reserveCapacity((data.count + 1) / 2)
        var i = data.startIndex
        while i < data.endIndex {
            let b0 = data[i]
            i = data.index(after: i)
            if i < data.endIndex {
                let b1 = data[i]
                i = data.index(after: i)
                out.append((UInt16(b0) << 8) | UInt16(b1))
            } else {
                out.append(UInt16(b0) << 8)
            }
        }
        return out
    }

    /// Inverse of `packQuaternary`. Emits exactly `byteCount` bytes.
    static func unpackQuaternary(_ values: [UInt16], byteCount: Int) -> Data {
        guard byteCount > 0 else { return Data() }
        var out = Data()
        out.reserveCapacity(byteCount)
        for v in values {
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

    static func quaternaryVisualToken(value: UInt16) -> String {
        let q = quats(fromQuaternaryValue: value)
        func g(_ v: UInt8) -> Character {
            switch v {
            case 0: return quatBlankGlyph
            case 1: return quatShallowGlyph
            case 2: return quatMediumGlyph
            default: return quatFullGlyph
            }
        }
        return "\(g(q[0]))\(g(q[1]))\(g(q[2]))\(quatSprocketGlyph)\(g(q[3]))\(g(q[4]))\(g(q[5]))\(g(q[6]))\(g(q[7]))"
    }

    static func parseQuaternaryToken(_ token: String) -> [UInt8]? {
        let cleaned = token
            .replacingOccurrences(of: " ", with: "")
            .replacingOccurrences(of: "\t", with: "")
        let chars = Array(cleaned)
        if chars.count == 9, isQuatSprocket(chars[3]) {
            var quats: [UInt8] = []
            quats.reserveCapacity(8)
            for (i, ch) in chars.enumerated() {
                if i == 3 { continue }
                guard let q = quatLevel(ch) else { return nil }
                quats.append(q)
            }
            return quats.count == 8 ? quats : nil
        }
        if chars.count == 8 {
            var quats: [UInt8] = []
            for ch in chars {
                guard let q = quatLevel(ch) else { return nil }
                quats.append(q)
            }
            return quats
        }
        var quats: [UInt8] = []
        for ch in chars {
            if isQuatSprocket(ch) { continue }
            if let q = quatLevel(ch) {
                quats.append(q)
            }
            if quats.count == 8 { return quats }
        }
        return quats.count == 8 ? quats : nil
    }

    private static func quatLevel(_ ch: Character) -> UInt8? {
        switch ch {
        case ".", "·", "0", "-", "_": return 0
        case "+", "◦", "1": return 1
        case "=", "│", "|", "2", "m", "M": return 2
        case "*", "●", "3", "X", "x", "#": return 3
        default: return nil
        }
    }

    private static func isQuatSprocket(_ ch: Character) -> Bool {
        switch ch {
        case "o", "O", "○": return true
        default: return false
        }
    }

    /// True when token uses medium `=` (distinctive quaternary glyph).
    static func tokenLooksQuaternary(_ token: String) -> Bool {
        token.contains("=")
    }

    static func quaternaryColumns(fromPunched punched: Data) -> [Column] {
        packQuaternary(punched).enumerated().map { Column(id: $0.offset, quaternaryValue: $0.element) }
    }
}
