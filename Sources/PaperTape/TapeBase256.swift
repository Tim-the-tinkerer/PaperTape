import Foundation

// MARK: - Base-256 column packing (format v8)
//
// Each data channel stores a full byte (0…255) → 256^8 = 2^64 values per column.
// log2(2^64) = **64 bits/column exactly** → **8 payload bytes per column**.
//
// Visually this is less “multilevel punch depth” and more “eight grayscale values
// across the strip” — each channel intensity is a whole byte. That is intentional:
// at this density the tape is a packed byte grid with the classic feed-hole layout.
//
// On-disk token: two hex digits per channel + feed `o` (17 characters), because a
// single ASCII glyph cannot encode 256 levels.
// Example: `a3f201o00ffc800` → ch1=0xA3, ch2=0xF2, ch3=0x01, feed, ch4=0x00 …

extension TapeEngine {

    static let base256SprocketGlyph: Character = "o"
    /// 256^8 = 2^64 (theoretical states per column).
    static let base256Radix = 256
    static let bytesPerBase256Column = 8

    // MARK: Pack / unpack (8 bytes → 1 column)

    /// Pack binary payload: consecutive big-endian 8-byte groups → channel bytes.
    /// Channel 1 = 256^0 (LSB); first payload byte is high (channel 8).
    /// Short remainder high-aligns (low channels zero).
    static func packBase256(_ data: Data) -> [[UInt8]] {
        if data.isEmpty { return [] }
        var out: [[UInt8]] = []
        out.reserveCapacity((data.count + 7) / 8)
        var i = data.startIndex
        while i < data.endIndex {
            var channels = [UInt8](repeating: 0, count: 8)
            var took = 0
            while took < 8, i < data.endIndex {
                // First payload byte → channel 8 (index 7); later → lower channels.
                channels[7 - took] = data[i]
                i = data.index(after: i)
                took += 1
            }
            out.append(channels)
        }
        return out
    }

    /// Inverse of `packBase256`. Emits exactly `byteCount` bytes (big-endian groups).
    static func unpackBase256(_ columns: [[UInt8]], byteCount: Int) -> Data {
        guard byteCount > 0 else { return Data() }
        var out = Data()
        out.reserveCapacity(byteCount)
        for col in columns {
            precondition(col.count == 8)
            // Emit channel 8 … channel 1 (MSB first).
            for idx in (0..<8).reversed() {
                if out.count >= byteCount { break }
                out.append(col[idx])
            }
        }
        while out.count < byteCount { out.append(0) }
        if out.count > byteCount {
            out = Data(out.prefix(byteCount))
        }
        return out
    }

    static func base256Value(fromBytes bytes: [UInt8]) -> UInt64 {
        precondition(bytes.count == 8)
        var v: UInt64 = 0
        var place: UInt64 = 1
        for b in bytes {
            v &+= UInt64(b) &* place
            place &*= 256
        }
        return v
    }

    static func base256Bytes(fromValue value: UInt64) -> [UInt8] {
        var x = value
        var out = [UInt8](repeating: 0, count: 8)
        for i in 0..<8 {
            out[i] = UInt8(truncatingIfNeeded: x)
            x >>= 8
        }
        return out
    }

    /// Integrity over the 8 channel bytes in ch1…ch8 order.
    static func base256IntegrityBytes(_ bytes: [UInt8]) -> [UInt8] {
        precondition(bytes.count == 8)
        return bytes
    }

    // MARK: Visual tokens (hex pairs + feed)

    /// 17-char token: 16 hex digits with feed `o` after channel 3.
    static func base256VisualToken(bytes: [UInt8]) -> String {
        precondition(bytes.count == 8)
        func hx(_ b: UInt8) -> String { String(format: "%02x", b) }
        return "\(hx(bytes[0]))\(hx(bytes[1]))\(hx(bytes[2]))\(base256SprocketGlyph)\(hx(bytes[3]))\(hx(bytes[4]))\(hx(bytes[5]))\(hx(bytes[6]))\(hx(bytes[7]))"
    }

    static func parseBase256Token(_ token: String) -> [UInt8]? {
        let cleaned = token
            .replacingOccurrences(of: " ", with: "")
            .replacingOccurrences(of: "\t", with: "")
            .lowercased()
        let chars = Array(cleaned)
        // Preferred: 17 chars with feed at index 6
        if chars.count == 17, isBase256Sprocket(chars[6]) {
            let hex = String(chars[0..<6]) + String(chars[7..<17])
            return parseHexByteString(hex)
        }
        // Alternate: 16 hex digits only (no feed)
        if chars.count == 16, chars.allSatisfy({ $0.isHexDigit }) {
            return parseHexByteString(String(chars))
        }
        // Loose: strip sprocket glyphs and take 16 hex digits
        var hexChars: [Character] = []
        for ch in chars {
            if isBase256Sprocket(ch) { continue }
            if ch.isHexDigit { hexChars.append(ch) }
            if hexChars.count == 16 { break }
        }
        guard hexChars.count == 16 else { return nil }
        return parseHexByteString(String(hexChars))
    }

    private static func parseHexByteString(_ hex: String) -> [UInt8]? {
        guard hex.count == 16 else { return nil }
        var out = [UInt8]()
        out.reserveCapacity(8)
        var i = hex.startIndex
        for _ in 0..<8 {
            let j = hex.index(i, offsetBy: 2)
            guard let b = UInt8(hex[i..<j], radix: 16) else { return nil }
            out.append(b)
            i = j
        }
        return out
    }

    private static func isBase256Sprocket(_ ch: Character) -> Bool {
        switch ch {
        case "o", "O", "○": return true
        default: return false
        }
    }

    static func tokenLooksBase256(_ token: String) -> Bool {
        let cleaned = token.replacingOccurrences(of: " ", with: "").lowercased()
        guard cleaned.count >= 16 else { return false }
        var hex = 0
        for ch in cleaned {
            if ch == "o" { continue }
            if ch.isHexDigit { hex += 1 } else { return false }
        }
        return hex >= 16
    }

    static func base256Columns(fromPunched punched: Data) -> [Column] {
        packBase256(punched).enumerated().map { Column(id: $0.offset, base256Bytes: $0.element) }
    }
}

private extension Character {
    var isHexDigit: Bool {
        ("0"..."9").contains(self) || ("a"..."f").contains(self) || ("A"..."F").contains(self)
    }
}
