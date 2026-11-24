import Foundation
import UniformTypeIdentifiers

/// Classic 1-inch 8-channel punched paper tape.
///
/// Physical channel layout across the strip (edge → edge):
/// ```
/// ch1  ch2  ch3  ○feed  ch4  ch5  ch6  ch7  ch8
/// ```
/// Channel 1 = bit 0 (LSB) / trit 3^0, channel 8 = bit 7 (MSB) / trit 3^7.
/// The sprocket (feed) hole is always punched.
///
/// **v1–v3** use binary channels (hole/blank). **v4** ternary (~12.68 b/col),
/// **v5** quaternary (16 b/col), **v6** octal (24 b/col), **v7** hex (32 b/col).
///
/// Optional **payload compression** runs *before* punching: fewer payload
/// bytes → fewer columns on the strip.
enum TapeEngine {

    static let fileExtension = "Tape"
    /// Highest `.Tape` format version this build can read.
    static let formatVersion = 9
    static let channelCount = 8

    /// Suggested `.Tape` filename with version suffix, e.g. `notes-v8.Tape`.
    /// Strips a trailing `-v1`…`-v9` from `stem` so re-saves do not stack suffixes.
    static func suggestedTapeFilename(stem: String, format: TapeFileFormat) -> String {
        var base = stem.trimmingCharacters(in: .whitespacesAndNewlines)
        if base.isEmpty { base = "untitled" }
        // Drop prior version tag: "report-v3" → "report"
        if let r = base.range(of: #"-v[1-9]$"#, options: .regularExpression) {
            base = String(base[..<r.lowerBound])
        }
        if base.isEmpty { base = "untitled" }
        return "\(base)-v\(format.rawValue).\(fileExtension)"
    }

    static var contentType: UTType {
        UTType(exportedAs: "com.papertape.tape", conformingTo: .plainText)
    }

    // MARK: - File format dialect (write preference)

    /// On-disk `.Tape` write dialect. Integrity markers protect the on-strip values;
    /// dialects differ in packing, glyph set, annotations, and preview footer.
    enum TapeFileFormat: Int, CaseIterable, Identifiable, Equatable {
        /// v1: `···○●··●·  # H  0x48` — Unicode glyphs + annotations + terminal preview.
        case v1 = 1
        /// v2: `···○●··●·` — Unicode glyphs only (no annotations, no preview footer).
        case v2 = 2
        /// v3: `...o*..*.` — one-byte ASCII glyphs only (`*` hole, `.` blank, `o` sprocket).
        case v3 = 3
        /// v4: `..+o*+.*+` — ternary ASCII (`.` blank, `+` mid, `*` full, `o` feed) with
        /// base-6561 packing (~12.68 bits/column).
        case v4 = 4
        /// v5: `.=+o*=+.*` — quaternary ASCII (`.` `+` `=` `*` depths, `o` feed);
        /// 2 bytes → 1 column (**16 bits/column**, O(n)).
        case v5 = 5
        /// v6: `.,:o+=x%*` — octal ASCII (8 depths, `o` feed);
        /// 3 bytes → 1 column (**24 bits/column**, O(n)).
        case v6 = 6
        /// v7: 16 calibrated depths (`.…@*`), `o` feed;
        /// 4 bytes → 1 column (**32 bits/column**, O(n)).
        case v7 = 7
        /// v8: base-256 — experimental maximum density; each channel is a full byte
        /// (grayscale 0…255); 8 bytes → 1 column (**64 bits/column**). Tokens: hex pairs + `o`.
        case v8 = 8
        case v9 = 9

        var id: Int { rawValue }

        var displayName: String {
            switch self {
            case .v1: return "v1 annotated"
            case .v2: return "v2 visual"
            case .v3: return "v3 ASCII"
            case .v4: return "v4 ternary"
            case .v5: return "v5 quaternary"
            case .v6: return "v6 octal"
            case .v7: return "v7 hexadecimal"
            case .v9: return "v9 nine-channel binary (Base512)"
            case .v8: return "v8 base-256 — experimental maximum density"
            }
        }

        var shortName: String {
            switch self {
            case .v1: return "v1"
            case .v2: return "v2"
            case .v3: return "v3"
            case .v4: return "v4"
            case .v5: return "v5"
            case .v6: return "v6"
            case .v7: return "v7"
            case .v8: return "v8"
            case .v9: return "v9"
            }
        }

        var help: String {
            switch self {
            case .v1:
                return "Classic: Unicode ●·○ tokens, # char  0xNN notes, and terminal paper preview footer."
            case .v2:
                return "Visual Unicode: ●·○ tokens only — no per-column notes and no terminal paper preview."
            case .v3:
                return "ASCII binary columns: * hole, . blank, o sprocket (e.g. ...o*..*.). No annotations or preview. ~8 bits/column."
            case .v4:
                return "Ternary ASCII: . blank, + mid, * full, o feed. Base-6561 packing (~12.68 bits/column)."
            case .v5:
                return "Quaternary ASCII: . + = * hole depths, o feed. 2 bytes/column (16 bits, linear-time)."
            case .v6:
                return "Octal ASCII: 8 calibrated depths, o feed. 3 bytes/column (24 bits, linear-time)."
            case .v7:
                return "Hexadecimal ASCII: 16 calibrated depths, o feed. 4 bytes/column (32 bits, linear-time). Default write format."
            case .v9:
                return "Nine binary data channels and a separate sprocket. Continuous 9-bit columns (512 patterns)."
            case .v8:
                return "Experimental maximum density: each channel is a full byte (grayscale 0–255). 8 bytes/column (64 bits). Tokens: hex pairs + o feed (e.g. a3f201o00ffc800). Less classic punch-depth look."
            }
        }

        /// Whether serialize writes `# char  0xNN` after each column token.
        var includesColumnAnnotations: Bool { self == .v1 }

        /// Whether serialize appends `# === terminal paper preview ===`.
        var includesTerminalPreview: Bool { self == .v1 }

        /// Whether column glyphs are 1-byte ASCII (v8 uses multi-char hex tokens but still ASCII).
        var usesAsciiGlyphs: Bool {
            self == .v3 || self == .v4 || self == .v5 || self == .v6 || self == .v7 || self == .v8 || self == .v9
        }

        /// Whether this dialect writes ternary (3-state) channels with base-6561 packing.
        var usesTernaryPacking: Bool { self == .v4 }

        /// Whether this dialect writes quaternary (4-state) channels (2 bytes/col).
        var usesQuaternaryPacking: Bool { self == .v5 }

        /// Whether this dialect writes octal (8-state) channels (3 bytes/col).
        var usesOctalPacking: Bool { self == .v6 }

        /// Whether this dialect writes hexadecimal (16-state) channels (4 bytes/col).
        var usesHexadecimalPacking: Bool { self == .v7 }

        /// Whether this dialect writes base-256 (256-state) channels (8 bytes/col).
        var usesBase256Packing: Bool { self == .v8 }

        /// Dense multi-state packing (v4–v8).
        var usesDensePacking: Bool {
            usesTernaryPacking || usesQuaternaryPacking || usesOctalPacking
                || usesHexadecimalPacking || usesBase256Packing
        }

        /// Default packing mode when writing this dialect.
        var defaultPacking: PackingMode {
            switch self {
            case .v4: return .ternaryFull
            case .v5: return .quaternary
            case .v6: return .octal
            case .v7: return .hexadecimal
            case .v8: return .base256
            case .v9: return .base512
            default: return .binary
            }
        }

        /// Value for `# columns:` header.
        var columnsHeaderValue: String {
            switch self {
            case .v1: return "annotated"
            case .v2: return "compact"
            case .v3: return "ascii"
            case .v4: return "ternary"
            case .v5: return "quaternary"
            case .v6: return "octal"
            case .v7: return "hexadecimal"
            case .v8: return "base256"
            case .v9: return "base512"
            }
        }

        /// Choices shown in the UI (version order v1…v9). Default write remains `.defaultWrite` (v7).
        static var uiCases: [TapeFileFormat] { [.v1, .v2, .v3, .v4, .v5, .v6, .v7, .v8, .v9] }

        /// Default when writing new files (v7 hex — practical multilevel density).
        static let defaultWrite: TapeFileFormat = .v7

        static func parse(_ raw: String) -> TapeFileFormat? {
            let key = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            if let n = Int(key), let f = TapeFileFormat(rawValue: n) { return f }
            switch key.lowercased() {
            case "v1", "1", "annotated": return .v1
            case "v2", "2", "compact", "visual": return .v2
            case "v3", "3", "ascii": return .v3
            case "v4", "4", "ternary", "base6561": return .v4
            case "v5", "5", "quaternary", "quat", "base65536": return .v5
            case "v6", "6", "octal", "oct", "base16777216": return .v6
            case "v7", "7", "hex", "hexadecimal", "base4294967296": return .v7
            case "v9", "9", "base512", "base-512", "b512": return .v9
            case "v8", "8", "base256", "b256", "base-256", "byte", "dense": return .v8
            default: return nil
            }
        }
    }

    /// Glyph alphabet for column tokens in a `.Tape` body.
    enum GlyphStyle: Equatable {
        /// ● hole · blank ○ sprocket
        case unicode
        /// * hole . blank o sprocket
        case ascii
        /// * full + mid . blank o sprocket (ternary)
        case ternary
        /// * full = medium + shallow . blank o sprocket (quaternary)
        case quaternary
        /// * full … 8 depths … . blank o sprocket (octal)
        case octal
        /// * full … 16 depths … . blank o sprocket (hexadecimal)
        case hexadecimal
        /// Hex-pair tokens + grayscale channels (base-256)
        case base256

        var hole: Character {
            switch self {
            case .unicode: return TapeEngine.holeGlyph
            case .ascii: return TapeEngine.asciiHoleGlyph
            case .ternary: return TapeEngine.ternaryFullGlyph
            case .quaternary: return TapeEngine.quatFullGlyph
            case .octal: return TapeEngine.octFullGlyph
            case .hexadecimal, .base256: return TapeEngine.hexFullGlyph
            }
        }

        var blank: Character {
            switch self {
            case .unicode: return TapeEngine.blankGlyph
            case .ascii, .ternary, .quaternary, .octal, .hexadecimal, .base256:
                return TapeEngine.asciiBlankGlyph
            }
        }

        var mid: Character? {
            switch self {
            case .ternary: return TapeEngine.ternaryMidGlyph
            case .quaternary: return TapeEngine.quatMediumGlyph
            case .octal: return TapeEngine.octL4Glyph
            case .hexadecimal: return TapeEngine.hexDepthGlyphs[8]
            case .base256: return "8"
            default: return nil
            }
        }

        var sprocket: Character {
            switch self {
            case .unicode: return TapeEngine.sprocketGlyph
            case .ascii, .ternary, .quaternary, .octal, .hexadecimal, .base256:
                return TapeEngine.asciiSprocketGlyph
            }
        }

        var headerDescription: String {
            switch self {
            case .ternary:
                return "*=full +=mid .=blank o=sprocket"
            case .quaternary:
                return "*=full ==med +=shallow .=blank o=sprocket"
            case .octal:
                return "*=7 %=6 x=5 ==4 +=3 :=2 ,=1 .=0 o=sprocket"
            case .hexadecimal:
                return "*=15 @=14 g=13 … .=0 o=sprocket (16 depths)"
            case .base256:
                return "hex-pairs 00-ff per channel, o=sprocket (256 levels=grayscale byte)"
            default:
                return "\(hole)=hole \(blank)=blank \(sprocket)=sprocket"
            }
        }

        static func forFormat(_ format: TapeFileFormat) -> GlyphStyle {
            switch format {
            case .v1, .v2: return .unicode
            case .v3: return .ascii
            case .v4: return .ternary
            case .v5: return .quaternary
            case .v6: return .octal
            case .v7: return .hexadecimal
            case .v8: return .base256
            case .v9: return .ascii
            }
        }
    }

    // MARK: - Compression (payload only — .Tape visual layout unchanged)

    /// Encode preference / stored algorithm.
    ///
    /// - `auto` is an **encode preference only** (never written to `.Tape` headers).
    /// - Files store the concrete winner: `none`, `lzfse`, `zlib`, `lz4`, or `lzma`.
    enum CompressionKind: String, CaseIterable, Identifiable, Equatable {
        case auto = "auto"
        case none = "none"
        case lzfse = "lzfse"
        case zlib = "zlib"
        case lz4 = "lz4"
        case lzma = "lzma"

        var id: String { rawValue }

        /// Choices shown in the UI (auto picks among concrete codecs).
        static var uiCases: [CompressionKind] { [.auto, .none] }

        /// Algorithms that may appear in a `.Tape` `# compression:` header.
        static var storedAlgorithms: [CompressionKind] { [.none, .lzfse, .zlib, .lz4, .lzma] }

        /// Codecs tried when preference is `.auto` (best size wins).
        static var autoCandidates: [CompressionKind] { [.lzfse, .zlib, .lz4, .lzma] }

        var displayName: String {
            switch self {
            case .auto: return "Auto"
            case .none: return "Off"
            case .lzfse: return "LZFSE"
            case .zlib: return "Zlib"
            case .lz4: return "LZ4"
            case .lzma: return "LZMA"
            }
        }

        var help: String {
            switch self {
            case .auto:
                return "Try LZFSE, Zlib, LZ4, and LZMA; use the smallest result. Short messages compress when any codec shrinks the bytes; tiny unique phrases may stay raw."
            case .none:
                return "Always punch raw bytes — one column per original byte."
            case .lzfse:
                return "Force Apple LZFSE (skipped only if it expands the payload)."
            case .zlib:
                return "Force zlib (skipped only if it expands the payload)."
            case .lz4:
                return "Force LZ4 (skipped only if it expands the payload)."
            case .lzma:
                return "Force LZMA (skipped only if it expands the payload)."
            }
        }

        /// True for values that can be stored / used to decompress a payload.
        var isStoredAlgorithm: Bool { self != .auto }

        var nsAlgorithm: NSData.CompressionAlgorithm? {
            switch self {
            case .auto, .none: return nil
            case .lzfse: return .lzfse
            case .zlib: return .zlib
            case .lz4: return .lz4
            case .lzma: return .lzma
            }
        }

        static func parse(_ raw: String) -> CompressionKind {
            let key = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            // Preference / non-payload labels never mean a concrete codec on the strip.
            if key == "auto" || key == "per-file" || key == "mixed" || key.isEmpty {
                return .none
            }
            return CompressionKind(rawValue: key) ?? .none
        }
    }

    /// Below this, codec framing usually *grows* the stream — skip trials.
    static let compressionMinInputBytes = 12
    /// For larger payloads, require at least this many bytes saved.
    static let compressionMinAbsoluteSavings = 16
    /// For larger payloads, require at least this relative savings (5%).
    static let compressionMinRelativeSavings = 0.05
    /// Under this size, treat any strict reduction as worthwhile (message-scale text).
    static let compressionSmallPayloadLimit = 1_024

    // MARK: - Transfer encoding (payload only — visual .Tape / PNG unchanged)

    /// Optional Base85 (Ascii85) step after compression, before punching.
    /// Does not change column glyphs, terminal paper layout, or PNG style — only
    /// which bytes sit on the strip (and thus hole patterns / legend characters).
    enum TransferEncoding: String, CaseIterable, Identifiable, Equatable {
        case identity = "identity"
        case ascii85 = "ascii85"

        var id: String { rawValue }

        var displayName: String {
            switch self {
            case .identity: return "Off"
            case .ascii85: return "Base85"
            }
        }

        var help: String {
            switch self {
            case .identity:
                return "Punch compressed/raw bytes directly."
            case .ascii85:
                return "Adobe Ascii85 after compression: makes the payload printable ASCII on the strip. Expands size (~4 bytes → 5 chars, +25%) — it does not shrink. Use Compress (Auto) to shrink. Same ●·○ file layout and PNG style."
            }
        }

        static func parse(_ raw: String) -> TransferEncoding {
            let key = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            switch key {
            case "ascii85", "base85", "a85", "b85": return .ascii85
            default: return .identity // includes identity, per-file, empty, unknown
            }
        }
    }

    // MARK: - Glyphs used in the digital visual representation

    /// Punched hole (bit = 1) — Unicode (v1/v2).
    static let holeGlyph: Character = "●"
    /// Unpunched paper (bit = 0) — Unicode (v1/v2).
    static let blankGlyph: Character = "·"
    /// Always-present sprocket / feed hole — Unicode (v1/v2).
    static let sprocketGlyph: Character = "○"

    /// Punched hole — ASCII (v3): one byte.
    static let asciiHoleGlyph: Character = "*"
    /// Unpunched paper — ASCII (v3).
    static let asciiBlankGlyph: Character = "."
    /// Sprocket — ASCII (v3).
    static let asciiSprocketGlyph: Character = "o"

    // MARK: - Column model

    /// One vertical column on the tape.
    /// - Binary (v1–v3): one byte as 8 hole/blank channels.
    /// - Ternary (v4): base-6561 digit, levels ∈ {0,1,2}.
    /// - Quaternary (v5): base-65536 digit, levels ∈ {0,1,2,3}.
    /// - Octal (v6): base-16_777_216 digit, levels ∈ {0…7}.
    /// - Hexadecimal (v7): base-2^32 digit, levels ∈ {0…15}.
    /// - Base-256 (v8): each channel is a full byte (0…255); 8 bytes/column.
    struct Column: Equatable, Identifiable {
        var id: Int
        /// Binary punches for channels 1…8 (index 0 = channel 1 / LSB).
        /// For multi-state columns, `true` when level > 0.
        var holes: [Bool]
        /// Multi-state channel levels (length 8). `nil` = pure binary.
        /// For base-256, levels are full channel bytes 0…255.
        var trits: [UInt8]?
        /// Radix for `trits`: 3/4/8/16 = multilevel; **0** = base-256 (byte channels).
        var multistateRadix: UInt8 = 3

        var isBase512: Bool { holes.count == 9 }

        var base512Value: UInt32 {
            holes.enumerated().reduce(0) { value, entry in
                entry.element ? value | (1 << entry.offset) : value
            }
        }

        init(id: Int, base512Value: UInt32) {
            self.id = id
            self.trits = nil
            self.holes = (0..<9).map { (base512Value >> $0) & 1 != 0 }
        }

        var isTernary: Bool { trits != nil && multistateRadix == 3 }
        var isQuaternary: Bool { trits != nil && multistateRadix == 4 }
        var isOctal: Bool { trits != nil && multistateRadix == 8 }
        var isHexadecimal: Bool { trits != nil && multistateRadix == 16 }
        var isBase256: Bool { trits != nil && multistateRadix == 0 }
        var isMultistate: Bool { trits != nil }

        /// Channel bytes for base-256 columns.
        var base256Bytes: [UInt8] {
            if isBase256, let t = trits, t.count == 8 { return t }
            return (0..<8).map { _ in 0 }
        }

        /// Binary byte (v1–v3). Multi-state: low 8 bits of the column value.
        var byte: UInt8 {
            if isBase256 {
                return base256Bytes.first ?? 0
            }
            if isHexadecimal {
                return UInt8(truncatingIfNeeded: hexadecimalValue)
            }
            if isOctal {
                return UInt8(truncatingIfNeeded: octalValue)
            }
            if isQuaternary {
                return UInt8(truncatingIfNeeded: quaternaryValue)
            }
            if trits != nil {
                return UInt8(truncatingIfNeeded: ternaryValue)
            }
            var v: UInt8 = 0
            for (i, punched) in holes.enumerated() where punched {
                v |= (1 << i)
            }
            return v
        }

        /// Base-6561 digit (0…6560).
        var ternaryValue: UInt16 {
            if let t = trits, multistateRadix == 3 {
                return TapeEngine.ternaryValue(fromTrits: t)
            }
            var v = 0
            var place = 1
            for punched in holes {
                if punched { v += place }
                place *= 3
            }
            return UInt16(v)
        }

        /// Base-65536 digit (0…65535).
        var quaternaryValue: UInt16 {
            if let t = trits, multistateRadix == 4 {
                return TapeEngine.quaternaryValue(fromQuats: t)
            }
            if let t = trits, multistateRadix != 8, multistateRadix != 16 {
                return TapeEngine.quaternaryValue(fromQuats: t.map { min($0, 3) })
            }
            var v: UInt16 = 0
            for (i, punched) in holes.enumerated() where punched {
                v |= UInt16(1 << i)
            }
            return v
        }

        /// Base-16_777_216 digit (0…16_777_215).
        var octalValue: UInt32 {
            if let t = trits, multistateRadix == 8 {
                return TapeEngine.octalValue(fromOcts: t)
            }
            if let t = trits, multistateRadix != 16 {
                return TapeEngine.octalValue(fromOcts: t.map { min($0, 7) })
            }
            var v: UInt32 = 0
            for (i, punched) in holes.enumerated() where punched {
                v |= UInt32(1 << i)
            }
            return v
        }

        /// Full 32-bit hex column value (0…2^32−1).
        var hexadecimalValue: UInt32 {
            if let t = trits, multistateRadix == 16 {
                return TapeEngine.hexadecimalValue(fromHexes: t)
            }
            if let t = trits, multistateRadix != 0 {
                return TapeEngine.hexadecimalValue(fromHexes: t.map { min($0, 15) })
            }
            var v: UInt32 = 0
            for (i, punched) in holes.enumerated() where punched {
                v |= UInt32(1 << i)
            }
            return v
        }

        /// Channel level for display.
        /// Base-256 returns the raw byte (0…255) for grayscale drawing.
        /// Other formats map onto a 0…7 intensity scale.
        func channelLevel(_ index: Int) -> UInt8 {
            if let t = trits, index < t.count {
                if multistateRadix == 0 {
                    return t[index] // full byte intensity
                }
                let maxL = multistateRadix > 1 ? multistateRadix - 1 : 7
                let raw = min(t[index], maxL)
                if multistateRadix == 16 {
                    return UInt8((Int(raw) * 7) / 15)
                }
                if multistateRadix == 8 {
                    return raw
                }
                if multistateRadix == 4 {
                    switch raw {
                    case 0: return 0
                    case 1: return 2
                    case 2: return 4
                    default: return 7
                    }
                }
                if multistateRadix == 3 {
                    switch raw {
                    case 0: return 0
                    case 1: return 3
                    default: return 7
                    }
                }
                return raw
            }
            if index < holes.count { return holes[index] ? 7 : 0 }
            return 0
        }

        /// Bytes contributing to integrity CRC/XOR/SUM8 for this column.
        var integrityBytes: [UInt8] {
            if isBase512 {
                let value = base512Value
                return [UInt8(truncatingIfNeeded: value), UInt8(value >> 8)]
            }
            if isBase256 {
                return TapeEngine.base256IntegrityBytes(base256Bytes)
            }
            if isHexadecimal {
                return TapeEngine.hexadecimalIntegrityBytes(hexadecimalValue)
            }
            if isOctal {
                return TapeEngine.octalIntegrityBytes(octalValue)
            }
            if isQuaternary {
                return TapeEngine.quaternaryIntegrityBytes(quaternaryValue)
            }
            if isTernary {
                return TapeEngine.ternaryIntegrityBytes(ternaryValue)
            }
            return [byte]
        }

        init(id: Int, byte: UInt8) {
            self.id = id
            self.trits = nil
            self.multistateRadix = 3
            self.holes = (0..<8).map { bit in
                ((byte >> bit) & 1) == 1
            }
        }

        init(id: Int, holes: [Bool]) {
            precondition(holes.count == 8)
            self.id = id
            self.holes = holes
            self.trits = nil
            self.multistateRadix = 3
        }

        init(id: Int, ternaryValue: UInt16) {
            self.id = id
            let t = TapeEngine.trits(fromTernaryValue: ternaryValue)
            self.trits = t
            self.multistateRadix = 3
            self.holes = t.map { $0 != 0 }
        }

        init(id: Int, trits: [UInt8]) {
            precondition(trits.count == 8)
            self.id = id
            let clamped = trits.map { min($0, 2) }
            self.trits = clamped
            self.multistateRadix = 3
            self.holes = clamped.map { $0 != 0 }
        }

        init(id: Int, quaternaryValue: UInt16) {
            self.id = id
            let q = TapeEngine.quats(fromQuaternaryValue: quaternaryValue)
            self.trits = q
            self.multistateRadix = 4
            self.holes = q.map { $0 != 0 }
        }

        init(id: Int, quats: [UInt8]) {
            precondition(quats.count == 8)
            self.id = id
            let clamped = quats.map { min($0, 3) }
            self.trits = clamped
            self.multistateRadix = 4
            self.holes = clamped.map { $0 != 0 }
        }

        init(id: Int, octalValue: UInt32) {
            self.id = id
            let o = TapeEngine.octs(fromOctalValue: octalValue)
            self.trits = o
            self.multistateRadix = 8
            self.holes = o.map { $0 != 0 }
        }

        init(id: Int, octs: [UInt8]) {
            precondition(octs.count == 8)
            self.id = id
            let clamped = octs.map { min($0, 7) }
            self.trits = clamped
            self.multistateRadix = 8
            self.holes = clamped.map { $0 != 0 }
        }

        init(id: Int, hexadecimalValue: UInt32) {
            self.id = id
            let h = TapeEngine.hexes(fromHexadecimalValue: hexadecimalValue)
            self.trits = h
            self.multistateRadix = 16
            self.holes = h.map { $0 != 0 }
        }

        init(id: Int, hexes: [UInt8]) {
            precondition(hexes.count == 8)
            self.id = id
            let clamped = hexes.map { min($0, 15) }
            self.trits = clamped
            self.multistateRadix = 16
            self.holes = clamped.map { $0 != 0 }
        }

        init(id: Int, base256Bytes: [UInt8]) {
            precondition(base256Bytes.count == 8)
            self.id = id
            self.trits = base256Bytes
            self.multistateRadix = 0 // special: full-byte channels
            self.holes = base256Bytes.map { $0 != 0 }
        }

        /// ASCII / Latin-1 printable glyph for the legend strip, if any (binary only).
        var printableChar: Character? {
            guard !isMultistate else { return nil }
            let b = byte
            if b >= 32 && b < 127 {
                return Character(UnicodeScalar(b))
            }
            return nil
        }
    }

    /// Default columns per integrity block (localizes damage in text transmission).
    static let defaultBlockSize = 64

    // MARK: - Block integrity (checksums + parity)

    /// One verified chunk of punched columns.
    struct IntegrityBlock: Equatable, Identifiable {
        var id: Int { index }
        /// Block index from the start of the punched stream.
        var index: Int
        /// Column offset into the full tape.
        var offset: Int
        /// Number of data columns in this block.
        var length: Int
        /// Stored CRC-32 (IEEE) over the block bytes.
        var storedCRC32: UInt32
        /// Stored XOR of every byte in the block (detects odd-bit flips per bit lane).
        var storedXOR: UInt8
        /// Stored sum of bytes mod 256 (different failure mode than XOR).
        var storedSum8: UInt8

        var computedCRC32: UInt32 = 0
        var computedXOR: UInt8 = 0
        var computedSum8: UInt8 = 0

        var crcOK: Bool { storedCRC32 == computedCRC32 }
        var xorOK: Bool { storedXOR == computedXOR }
        var sumOK: Bool { storedSum8 == computedSum8 }
        var ok: Bool { crcOK && xorOK && sumOK }

        var failureSummary: String {
            var parts: [String] = []
            if !crcOK { parts.append("CRC") }
            if !xorOK { parts.append("XOR") }
            if !sumOK { parts.append("SUM8") }
            return parts.isEmpty ? "ok" : parts.joined(separator: "+")
        }
    }

    /// Result of reading/verifying integrity markers in a `.Tape` file.
    struct IntegrityReport: Equatable {
        var blockSize: Int
        var blocks: [IntegrityBlock]
        /// True when the file contained `@block` markers (vs. legacy / synthetic).
        var hasMarkers: Bool

        var failedBlocks: [IntegrityBlock] { blocks.filter { !$0.ok } }
        var allOK: Bool { !blocks.isEmpty && failedBlocks.isEmpty }
        var checked: Bool { !blocks.isEmpty }

        var summary: String {
            guard checked else { return "No integrity blocks" }
            if allOK {
                return "Integrity OK · \(blocks.count) block(s) · \(blockSize) cols/block"
            }
            let bad = failedBlocks
            let n = bad.count
            if n == 1, let b = bad.first {
                return "Integrity FAIL · block \(b.index) @col \(b.offset) (\(b.failureSummary)) · 1/\(blocks.count)"
            }
            if n <= 4 {
                let list = bad.map { "\($0.index)" }.joined(separator: ", ")
                return "Integrity FAIL · blocks \(list) · \(n)/\(blocks.count)"
            }
            // Compact: avoid multi-hundred ID dumps in the UI
            guard let first = bad.first, let last = bad.last else {
                return "Integrity FAIL · \(n)/\(blocks.count) blocks"
            }
            return "Integrity FAIL · \(n)/\(blocks.count) blocks (first \(first.index) @col \(first.offset), last \(last.index) @col \(last.offset))"
        }

        /// Short detail line for the banner (first few failures only).
        var detailLine: String {
            let bad = failedBlocks
            guard !bad.isEmpty else {
                return "CRC-32 + XOR + SUM8 over \(blockSize)-column blocks"
            }
            let shown = bad.prefix(5).map { b in
                "block \(b.index) @col \(b.offset) (\(b.failureSummary))"
            }
            var line = shown.joined(separator: " · ")
            if bad.count > 5 {
                line += " · … +\(bad.count - 5) more"
            }
            return line
        }
    }

    struct TapeDocument: Equatable {
        var columns: [Column]
        var originalName: String
        /// Uncompressed original payload size in bytes.
        var originalSize: Int
        /// Compression applied to original bytes before optional Base85 / punching.
        var compression: CompressionKind
        /// Transfer encoding applied after compression, before punching.
        var transferEncoding: TransferEncoding
        var note: String
        /// Block size used when writing integrity markers (columns per block).
        var blockSize: Int
        /// Present after deserialize (and after serialize preparation).
        var integrity: IntegrityReport?
        /// Container mode from header: `blob`, `stream`, or `archive`.
        var containerMode: String = "blob"
        /// True when columns are a truncated preview of a larger tape (not full-file integrity).
        var isPartialPreview: Bool = false
        /// How payload bytes map onto columns (binary vs ternary packing).
        var packing: PackingMode = .binary
        /// Binary payload byte count that was packed into ternary columns.
        /// For binary tapes equals `columns.count`. For ternary, used by unpack.
        var packedByteCount: Int = 0
        /// Pack-chunk size in binary bytes (0 = whole payload as one integer).
        var packChunk: Int = 0

        /// Bytes as they appear after compress/Base85 and *before* multi-state packing.
        /// For binary tapes this is one byte per column.
        var punchedData: Data {
            if packing == .base512 {
                var decoder = Base512Decoder()
                var output = Data()
                for column in columns { decoder.append(column.base512Value, to: &output) }
                if isPartialPreview { return output }
                do {
                    try decoder.finish(byteCount: Int64(packedByteCount), to: &output)
                    return output
                } catch {
                    return Data()
                }
            }
            if packing.isBase256 {
                let cols = columns.map(\.base256Bytes)
                let count = Self.densePackedByteCount(
                    packedByteCount: packedByteCount,
                    originalSize: originalSize,
                    compression: compression,
                    transfer: transferEncoding,
                    packing: packing,
                    columnCount: cols.count
                )
                if isPartialPreview {
                    let maxFromCols = cols.count * 8
                    let n = min(count > 0 ? count : maxFromCols, maxFromCols)
                    return TapeEngine.unpackBase256(cols, byteCount: n)
                }
                return TapeEngine.unpackBase256(cols, byteCount: count)
            }
            if packing.isHexadecimal {
                let vals = columns.map(\.hexadecimalValue)
                let count = Self.densePackedByteCount(
                    packedByteCount: packedByteCount,
                    originalSize: originalSize,
                    compression: compression,
                    transfer: transferEncoding,
                    packing: packing,
                    columnCount: vals.count
                )
                if isPartialPreview {
                    let maxFromCols = vals.count * 4
                    let n = min(count > 0 ? count : maxFromCols, maxFromCols)
                    return TapeEngine.unpackHexadecimal(vals, byteCount: n)
                }
                return TapeEngine.unpackHexadecimal(vals, byteCount: count)
            }
            if packing.isOctal {
                let vals = columns.map(\.octalValue)
                let count = Self.densePackedByteCount(
                    packedByteCount: packedByteCount,
                    originalSize: originalSize,
                    compression: compression,
                    transfer: transferEncoding,
                    packing: packing,
                    columnCount: vals.count
                )
                if isPartialPreview {
                    let maxFromCols = vals.count * 3
                    let n = min(count > 0 ? count : maxFromCols, maxFromCols)
                    return TapeEngine.unpackOctal(vals, byteCount: n)
                }
                return TapeEngine.unpackOctal(vals, byteCount: count)
            }
            if packing.isQuaternary {
                let vals = columns.map(\.quaternaryValue)
                let count = Self.densePackedByteCount(
                    packedByteCount: packedByteCount,
                    originalSize: originalSize,
                    compression: compression,
                    transfer: transferEncoding,
                    packing: packing,
                    columnCount: vals.count
                )
                if isPartialPreview {
                    // Complete pairs only from loaded columns.
                    let maxFromCols = vals.count * 2
                    let n = min(count > 0 ? count : maxFromCols, maxFromCols)
                    return TapeEngine.unpackQuaternary(vals, byteCount: n)
                }
                return TapeEngine.unpackQuaternary(vals, byteCount: count)
            }
            if packing.isTernary {
                let digits = columns.map(\.ternaryValue)
                let count: Int
                if isPartialPreview {
                    let maxB = packedByteCount > 0
                        ? packedByteCount
                        : (originalSize > 0 ? originalSize : digits.count * 3)
                    count = Self.ternaryPartialByteCapacity(
                        digitCount: digits.count,
                        packing: packing,
                        packChunk: packChunk,
                        maxBytes: maxB
                    )
                } else {
                    count = Self.densePackedByteCount(
                        packedByteCount: packedByteCount,
                        originalSize: originalSize,
                        compression: compression,
                        transfer: transferEncoding,
                        packing: packing,
                        columnCount: digits.count
                    )
                }
                return TapeEngine.unpackTernary(
                    digits,
                    mode: packing,
                    byteCount: count,
                    chunkBytes: packChunk
                )
            }
            return Data(columns.map(\.byte))
        }

        /// Resolve how many binary bytes multi-state columns represent (full document).
        static func densePackedByteCount(
            packedByteCount: Int,
            originalSize: Int,
            compression: CompressionKind,
            transfer: TransferEncoding,
            packing: PackingMode,
            columnCount: Int
        ) -> Int {
            if packedByteCount > 0 { return packedByteCount }
            // Raw identity streams: # size: equals punched binary length.
            if originalSize > 0,
               (compression == .none || !compression.isStoredAlgorithm),
               transfer == .identity
            {
                return originalSize
            }
            // Last resort estimates (prefer punched-size / size in headers).
            switch packing {
            case .ternaryBlock3:
                return (columnCount / 2) * 3
            case .quaternary:
                return columnCount * 2
            case .octal:
                return columnCount * 3
            case .hexadecimal:
                return columnCount * 4
            case .base512:
                return columnCount + columnCount / 8
            case .base256:
                return columnCount * 8
            case .ternaryFull, .binary:
                return columnCount
            }
        }

        /// Max faithful binary bytes decodable from a partial digit prefix.
        static func ternaryPartialByteCapacity(
            digitCount: Int,
            packing: PackingMode,
            packChunk: Int,
            maxBytes: Int
        ) -> Int {
            guard digitCount > 0, maxBytes > 0 else { return 0 }
            switch packing {
            case .ternaryBlock3:
                let pairs = digitCount / 2
                return min(maxBytes, pairs * 3)
            case .ternaryFull:
                if packChunk > 0 {
                    let width = TapeEngine.ternaryDigitCapacity(byteCount: packChunk)
                    guard width > 0 else { return 0 }
                    let fullChunks = digitCount / width
                    return min(maxBytes, fullChunks * packChunk)
                }
                // Whole-integer pack cannot decode a digit prefix.
                return 0
            case .quaternary:
                return min(maxBytes, digitCount * 2)
            case .octal:
                return min(maxBytes, digitCount * 3)
            case .hexadecimal:
                return min(maxBytes, digitCount * 4)
            case .base512:
                return min(maxBytes, digitCount + digitCount / 8)
            case .base256:
                return min(maxBytes, digitCount * 8)
            case .binary:
                return min(maxBytes, digitCount)
            }
        }

        /// Restored original payload when possible; never silently returns punched bytes as original.
        var data: Data {
            (try? restoredData()) ?? Data()
        }

        var textUTF8: String? {
            guard let restored = try? restoredData() else { return nil }
            return String(data: restored, encoding: .utf8)
        }

        var isEmpty: Bool { columns.isEmpty }

        var isArchive: Bool { containerMode == "archive" }

        var isCompressed: Bool {
            compression.isStoredAlgorithm && compression != .none
        }

        var usesBase85: Bool {
            transferEncoding == .ascii85
        }

        /// Ratio of punched columns to original size (1.0 = no savings; lower is better).
        var compressionRatio: Double? {
            guard originalSize > 0, columns.count != originalSize else { return nil }
            return Double(columns.count) / Double(originalSize)
        }

        var isTernary: Bool { packing.isTernary }
        var isQuaternary: Bool { packing.isQuaternary }
        var isOctal: Bool { packing.isOctal }
        var isHexadecimal: Bool { packing.isHexadecimal }
        var isBase256: Bool { packing.isBase256 }
        var isMultistate: Bool { packing.isMultistate }

        /// Restore original payload from punched columns.
        /// - Parameter allowPartial: When true, allow export of a partial large-tape preview
        ///   (best-effort). Archives still require extractFolder.
        func restoredData(allowPartial: Bool = false) throws -> Data {
            if isArchive {
                throw FormatError.io("This .Tape is a folder archive — use Export / Files → Restore to extract members.")
            }
            if isPartialPreview, !allowPartial {
                throw FormatError.io("This is a partial preview of a large .Tape — export with allowPartial or Restore the full file.")
            }
            // Ternary whole-integer packs cannot recover a faithful prefix from partial columns.
            if isPartialPreview, allowPartial, packing == .ternaryFull, packChunk <= 0 {
                throw FormatError.io(
                    "Partial ternary (full pack) preview cannot export payload — use Files → Restore on the full .Tape."
                )
            }
            var stage: Data
            if packing == .base512, !isPartialPreview {
                guard integrity?.allOK == true || columns.isEmpty else {
                    throw TapeEngine.base512Error("damaged integrity blocks")
                }
                var decoder = Base512Decoder()
                stage = Data()
                for column in columns { decoder.append(column.base512Value, to: &stage) }
                try decoder.finish(byteCount: Int64(packedByteCount), to: &stage)
            } else if isPartialPreview, packing.isMultistate {
                stage = punchedData // already limited for partial multi-state
                if stage.isEmpty {
                    throw FormatError.io(
                        "Partial multi-state preview has no complete pack groups to export — use Files → Restore."
                    )
                }
            } else {
                stage = punchedData
            }
            // Inverse pipeline: punched → [Base85 decode] → [decompress] → original
            if transferEncoding == .ascii85 {
                stage = try TapeEngine.ascii85Decode(stage)
            }
            if isCompressed {
                // Partial previews may not include the full compressed stream — try decompress,
                // and fall back to punched bytes only when allowPartial.
                do {
                    stage = try TapeEngine.decompress(stage, kind: compression, expectedSize: allowPartial ? 0 : originalSize)
                } catch {
                    if allowPartial {
                        // Best-effort: return what we have after optional Base85 (already applied).
                        return stage
                    }
                    throw error
                }
            }
            if packing == .base512, !isPartialPreview, stage.count != originalSize {
                throw TapeEngine.base512Error("incorrect original size")
            }
            if originalSize > 0, stage.count > originalSize, !isCompressed, transferEncoding == .identity {
                stage = Data(stage.prefix(originalSize))
            }
            return stage
        }

        static let empty = TapeDocument(
            columns: [],
            originalName: "untitled",
            originalSize: 0,
            compression: .none,
            transferEncoding: .identity,
            note: "",
            blockSize: TapeEngine.defaultBlockSize,
            integrity: nil,
            containerMode: "blob",
            isPartialPreview: false,
            packing: .binary,
            packedByteCount: 0,
            packChunk: 0
        )
    }

    // MARK: - Encode / decode bytes

    static func columns(from data: Data) -> [Column] {
        data.enumerated().map { Column(id: $0.offset, byte: $0.element) }
    }

    static func data(from columns: [Column]) -> Data {
        Data(columns.map(\.byte))
    }

    /// Encode raw bytes onto the tape.
    /// Pipeline: original → [compress] → [Base85] → punch columns.
    /// Visual `.Tape` layout and PNG style are unchanged regardless of options.
    static func encode(
        data: Data,
        originalName: String = "untitled",
        note: String = "",
        compression: CompressionKind = .auto,
        transferEncoding: TransferEncoding = .identity
    ) -> TapeDocument {
        let (afterCompress, appliedCompression) = applyCompression(data, preferred: compression)
        let punchedBytes: Data
        let appliedTransfer: TransferEncoding
        if transferEncoding == .ascii85, !afterCompress.isEmpty {
            punchedBytes = ascii85Encode(afterCompress)
            appliedTransfer = .ascii85
        } else {
            punchedBytes = afterCompress
            appliedTransfer = .identity
        }
        var doc = TapeDocument(
            columns: columns(from: punchedBytes),
            originalName: sanitizeName(originalName),
            originalSize: data.count,
            compression: appliedCompression,
            transferEncoding: appliedTransfer,
            note: note,
            blockSize: defaultBlockSize,
            integrity: nil
        )
        // Synthetic report (stored == computed). hasMarkers:true would force false FAILs
        // because it treats missing stored markers as corruption — only for deserialize.
        doc.integrity = buildIntegrityReport(
            for: doc.columns,
            blockSize: defaultBlockSize,
            hasMarkers: false
        )
        return doc
    }

    // MARK: - Checksums & parity

    /// IEEE CRC-32 (polynomial 0xEDB88320), same family as ZIP/PNG.
    static func crc32(_ data: Data) -> UInt32 {
        var crc: UInt32 = 0xFFFF_FFFF
        for byte in data {
            let idx = Int((crc ^ UInt32(byte)) & 0xFF)
            crc = (crc >> 8) ^ crc32Table[idx]
        }
        return crc ^ 0xFFFF_FFFF
    }

    private static let crc32Table: [UInt32] = {
        (0..<256).map { i -> UInt32 in
            var c = UInt32(i)
            for _ in 0..<8 {
                c = (c & 1) != 0 ? (0xEDB88320 ^ (c >> 1)) : (c >> 1)
            }
            return c
        }
    }()

    /// Byte-wise XOR parity over a block.
    static func xorParity(_ data: Data) -> UInt8 {
        data.reduce(0 as UInt8) { $0 ^ $1 }
    }

    /// Additive checksum: sum of bytes mod 256.
    static func sum8(_ data: Data) -> UInt8 {
        var s: UInt32 = 0
        for b in data { s = (s + UInt32(b)) & 0xFF }
        return UInt8(s)
    }

    /// Flatten column integrity payload (1–8 B per column depending on packing).
    static func integrityData(for columns: ArraySlice<Column>) -> Data {
        var data = Data()
        // Reserve for densest integrity unit (base-256 = 8 bytes/col).
        data.reserveCapacity(columns.count * 8)
        for col in columns {
            data.append(contentsOf: col.integrityBytes)
        }
        return data
    }

    static func integrityData(for columns: [Column]) -> Data {
        integrityData(for: columns[...])
    }

    static func buildIntegrityReport(
        for columns: [Column],
        blockSize: Int,
        hasMarkers: Bool,
        stored: [(crc: UInt32, xor: UInt8, sum: UInt8)]? = nil
    ) -> IntegrityReport {
        let bs = max(1, blockSize)
        var blocks: [IntegrityBlock] = []
        var offset = 0
        var index = 0
        while offset < columns.count {
            let len = min(bs, columns.count - offset)
            let slice = integrityData(for: columns[offset..<(offset + len)])
            let computedCRC = crc32(slice)
            let computedXOR = xorParity(slice)
            let computedSum = sum8(slice)

            let storedCRC: UInt32
            let storedXOR: UInt8
            let storedSum: UInt8
            if let stored, index < stored.count {
                storedCRC = stored[index].crc
                storedXOR = stored[index].xor
                storedSum = stored[index].sum
            } else if hasMarkers {
                // Marker missing for this block — force a detectable failure.
                storedCRC = computedCRC &+ 1
                storedXOR = computedXOR &+ 1
                storedSum = computedSum &+ 1
            } else {
                // Fresh report / write path: stored == computed.
                storedCRC = computedCRC
                storedXOR = computedXOR
                storedSum = computedSum
            }

            blocks.append(IntegrityBlock(
                index: index,
                offset: offset,
                length: len,
                storedCRC32: storedCRC,
                storedXOR: storedXOR,
                storedSum8: storedSum,
                computedCRC32: computedCRC,
                computedXOR: computedXOR,
                computedSum8: computedSum
            ))
            offset += len
            index += 1
        }
        return IntegrityReport(blockSize: bs, blocks: blocks, hasMarkers: hasMarkers)
    }

    static func encodeText(
        _ text: String,
        originalName: String = "message.txt",
        note: String = "",
        compression: CompressionKind = .auto,
        transferEncoding: TransferEncoding = .identity
    ) -> TapeDocument {
        let data = Data(text.utf8)
        return encode(
            data: data,
            originalName: originalName,
            note: note,
            compression: compression,
            transferEncoding: transferEncoding
        )
    }

    // MARK: - Ascii85 (Adobe / Base85, no <~ ~> delimiters)

    /// Encode binary as Adobe Ascii85 (4 bytes → 5 printable ASCII chars; `z` for four zero bytes).
    static func ascii85Encode(_ data: Data) -> Data {
        if data.isEmpty { return Data() }
        var out = [UInt8]()
        out.reserveCapacity((data.count + 3) / 4 * 5)

        var i = data.startIndex
        while i < data.endIndex {
            let remaining = data.distance(from: i, to: data.endIndex)
            let take = min(4, remaining)
            var tuple: UInt64 = 0
            for j in 0..<4 {
                tuple <<= 8
                if j < take {
                    tuple |= UInt64(data[data.index(i, offsetBy: j)])
                }
            }
            if take == 4 && tuple == 0 {
                out.append(UInt8(ascii: "z"))
            } else {
                var chars = [UInt8](repeating: 33, count: 5)
                var value = tuple
                for k in (0..<5).reversed() {
                    chars[k] = UInt8(value % 85) + 33
                    value /= 85
                }
                // Partial block: only emit take+1 characters
                out.append(contentsOf: chars.prefix(take + 1))
            }
            i = data.index(i, offsetBy: take)
        }
        return Data(out)
    }

    /// Decode Adobe Ascii85 (ignores whitespace; rejects invalid characters).
    static func ascii85Decode(_ data: Data) throws -> Data {
        var out = [UInt8]()
        out.reserveCapacity(data.count * 4 / 5 + 4)

        var group = [UInt8]()
        group.reserveCapacity(5)

        func flushGroup(_ g: [UInt8], final: Bool) throws {
            guard !g.isEmpty else { return }
            if g.count == 1 {
                throw FormatError.base85Failed("Incomplete Ascii85 group")
            }
            // Pad incomplete groups with 'u' (84) per Adobe Ascii85.
            var padded = g
            while padded.count < 5 { padded.append(UInt8(ascii: "u")) }
            // UInt64: 85^5 can exceed UInt32 during intermediate math.
            var value: UInt64 = 0
            for ch in padded {
                let d = Int(ch) - 33
                guard d >= 0, d < 85 else {
                    throw FormatError.base85Failed("Invalid Ascii85 character")
                }
                value = value * 85 + UInt64(d)
            }
            if value > UInt64(UInt32.max) {
                throw FormatError.base85Failed("Ascii85 value overflow")
            }
            let bytesToWrite = final ? g.count - 1 : 4
            guard bytesToWrite >= 1, bytesToWrite <= 4 else {
                throw FormatError.base85Failed("Bad Ascii85 block length")
            }
            for shift in [24, 16, 8, 0].prefix(bytesToWrite) {
                out.append(UInt8((value >> shift) & 0xFF))
            }
        }

        // Note: '<' (60) and '>' (62) are *valid* Ascii85 digits — only the
        // Adobe delimiter pairs <~ and ~> should be skipped, not lone < or >.
        var i = data.startIndex
        while i < data.endIndex {
            let byte = data[i]
            // Whitespace
            if byte == 32 || byte == 9 || byte == 10 || byte == 13 || byte == 0 {
                i = data.index(after: i)
                continue
            }
            // Delimiter pairs
            if byte == UInt8(ascii: "<"),
               data.index(after: i) < data.endIndex,
               data[data.index(after: i)] == UInt8(ascii: "~") {
                i = data.index(i, offsetBy: 2)
                continue
            }
            if byte == UInt8(ascii: "~"),
               data.index(after: i) < data.endIndex,
               data[data.index(after: i)] == UInt8(ascii: ">") {
                i = data.index(i, offsetBy: 2)
                continue
            }
            if byte == UInt8(ascii: "z") {
                if !group.isEmpty {
                    throw FormatError.base85Failed("'z' inside Ascii85 group")
                }
                out.append(contentsOf: [0, 0, 0, 0])
                i = data.index(after: i)
                continue
            }
            guard byte >= 33, byte <= 117 else {
                throw FormatError.base85Failed("Invalid Ascii85 byte \(byte)")
            }
            group.append(byte)
            if group.count == 5 {
                try flushGroup(group, final: false)
                group.removeAll(keepingCapacity: true)
            }
            i = data.index(after: i)
        }
        if !group.isEmpty {
            try flushGroup(group, final: true)
        }
        return Data(out)
    }

    /// Choose compressed bytes when they beat raw; otherwise raw + `.none`.
    ///
    /// - `.auto` — trial LZFSE / Zlib / LZ4 / LZMA and keep the smallest winner
    /// - concrete codec — try only that codec
    /// - `.none` — always raw
    ///
    /// Message-scale text (under ~1 KB) accepts **any** strict size reduction so short
    /// repeated phrases still compress. Larger payloads keep a 5% / 16-byte floor.
    static func applyCompression(
        _ data: Data,
        preferred: CompressionKind
    ) -> (Data, CompressionKind) {
        guard !data.isEmpty, preferred != .none else {
            return (data, .none)
        }

        // Extremely small inputs: framing almost always expands the stream.
        if data.count < compressionMinInputBytes {
            return (data, .none)
        }

        let candidates: [CompressionKind]
        switch preferred {
        case .auto:
            candidates = CompressionKind.autoCandidates
        case .none:
            return (data, .none)
        default:
            candidates = [preferred]
        }

        var bestData = data
        var bestKind = CompressionKind.none
        var bestSize = data.count

        for kind in candidates {
            guard let algo = kind.nsAlgorithm else { continue }
            guard let compressed = try? (data as NSData).compressed(using: algo) as Data else {
                continue
            }
            // Prefer strictly smaller streams; then apply size-tiered “worthwhile” filter.
            guard compressed.count < bestSize,
                  isWorthwhileCompression(original: data.count, compressed: compressed.count)
            else { continue }
            bestSize = compressed.count
            bestData = compressed
            bestKind = kind
        }

        return (bestData, bestKind)
    }

    /// Whether a compressed result is worth punching instead of raw.
    ///
    /// - Small / message payloads: any reduction of 1+ bytes.
    /// - Larger payloads: ≥16 bytes and ≥5% smaller (avoids noisy micro-gains).
    static func isWorthwhileCompression(original: Int, compressed: Int) -> Bool {
        guard original > 0, compressed > 0, compressed < original else { return false }
        let saved = original - compressed
        if original < compressionSmallPayloadLimit {
            return saved >= 1
        }
        let relative = Double(saved) / Double(original)
        return saved >= compressionMinAbsoluteSavings
            && relative >= compressionMinRelativeSavings
    }

    static func decompress(
        _ data: Data,
        kind: CompressionKind,
        expectedSize: Int = 0
    ) throws -> Data {
        guard kind != .none, kind != .auto else { return data }
        guard let algo = kind.nsAlgorithm else {
            throw FormatError.unsupportedCompression(kind.rawValue)
        }
        do {
            let out = try (data as NSData).decompressed(using: algo) as Data
            if expectedSize > 0, out.count != expectedSize {
                throw FormatError.decompressionFailed(
                    "size mismatch: decompressed \(out.count) bytes, expected \(expectedSize)"
                )
            }
            return out
        } catch let err as FormatError {
            throw err
        } catch {
            throw FormatError.decompressionFailed(error.localizedDescription)
        }
    }

    // MARK: - Visual digital representation (terminal / paper form)

    /// One column as a compact visual token used inside `.Tape` files.
    /// Layout: `c1 c2 c3 feed c4 c5 c6 c7 c8` (9 characters).
    /// - Unicode (v1/v2): `●` / `·` / `○`
    /// - ASCII (v3): `*` / `.` / `o`  e.g. `...o*..*.`
    /// - Ternary (v4): `*` full / `+` mid / `.` blank / `o` feed
    static func visualToken(for column: Column, style: GlyphStyle = .unicode) -> String {
        if column.isBase512 {
            var glyphs = column.holes.map { $0 ? "*" : "." }
            glyphs.insert("o", at: 3)
            return glyphs.joined()
        }
        if style == .base256 || column.isBase256 {
            return base256VisualToken(bytes: column.base256Bytes)
        }
        if style == .hexadecimal || column.isHexadecimal {
            return hexadecimalVisualToken(value: column.hexadecimalValue)
        }
        if style == .octal || column.isOctal {
            return octalVisualToken(value: column.octalValue)
        }
        if style == .quaternary || column.isQuaternary {
            return quaternaryVisualToken(value: column.quaternaryValue)
        }
        if style == .ternary || column.isTernary {
            if let t = column.trits {
                return ternaryVisualToken(trits: t)
            }
            return ternaryVisualToken(value: column.ternaryValue)
        }
        let hole = style.hole
        let blank = style.blank
        let feed = style.sprocket
        let g = column.holes.map { $0 ? hole : blank }
        // ch1 ch2 ch3 · sprocket · ch4 ch5 ch6 ch7 ch8
        return "\(g[0])\(g[1])\(g[2])\(feed)\(g[3])\(g[4])\(g[5])\(g[6])\(g[7])"
    }

    /// Parse a visual token back into 8 hole flags (binary). Returns nil if invalid.
    /// For ternary tokens (containing `+`), maps any punch (mid/full) to `true`.
    static func parseVisualToken(_ token: String) -> [Bool]? {
        let cleaned = token
            .replacingOccurrences(of: " ", with: "")
            .replacingOccurrences(of: "\t", with: "")
        if tokenLooksTernary(cleaned), let trits = parseTernaryToken(cleaned) {
            return trits.map { $0 != 0 }
        }
        // Accept ●/·/○ and ASCII fallbacks (*, ., o, 1, 0, …).
        return parseVisualTokenStrict(cleaned)
    }

    /// Parse a column token into a Column (binary, ternary, quaternary, octal, or hex).
    /// When a prefer flag is set, that packing is tried first (and alone among dense
    /// auto-detects) so e.g. a v5 token containing `x` is not stolen by denser looks.
    static func parseColumnToken(
        _ token: String,
        preferTernary: Bool = false,
        preferQuaternary: Bool = false,
        preferOctal: Bool = false,
        preferHexadecimal: Bool = false,
        preferBase256: Bool = false
    ) -> Column? {
        let cleaned = token
            .replacingOccurrences(of: " ", with: "")
            .replacingOccurrences(of: "\t", with: "")
        let hasPrefer = preferBase256 || preferHexadecimal || preferOctal || preferQuaternary || preferTernary
        if preferBase256, let bytes = parseBase256Token(cleaned) {
            return Column(id: 0, base256Bytes: bytes)
        }
        if preferHexadecimal, let hexes = parseHexadecimalToken(cleaned) {
            return Column(id: 0, hexes: hexes)
        }
        if preferOctal, let octs = parseOctalToken(cleaned) {
            return Column(id: 0, octs: octs)
        }
        if preferQuaternary, let quats = parseQuaternaryToken(cleaned) {
            return Column(id: 0, quats: quats)
        }
        if preferTernary, let trits = parseTernaryToken(cleaned) {
            return Column(id: 0, trits: trits)
        }
        // Auto-detect only when no packing preference was given (headerless / loose tokens).
        if !hasPrefer {
            if tokenLooksBase256(cleaned), let bytes = parseBase256Token(cleaned) {
                return Column(id: 0, base256Bytes: bytes)
            }
            if tokenLooksHexadecimal(cleaned), let hexes = parseHexadecimalToken(cleaned) {
                return Column(id: 0, hexes: hexes)
            }
            if tokenLooksOctal(cleaned), let octs = parseOctalToken(cleaned) {
                return Column(id: 0, octs: octs)
            }
            if tokenLooksQuaternary(cleaned), let quats = parseQuaternaryToken(cleaned) {
                return Column(id: 0, quats: quats)
            }
            if tokenLooksTernary(cleaned), let trits = parseTernaryToken(cleaned) {
                return Column(id: 0, trits: trits)
            }
        }
        if let holes = parseVisualTokenStrict(cleaned) {
            return Column(id: 0, holes: holes)
        }
        // Last resort: preferred dense parsers may accept tokens without distinctive glyphs.
        if preferBase256, let bytes = parseBase256Token(cleaned) {
            return Column(id: 0, base256Bytes: bytes)
        }
        if preferHexadecimal, let hexes = parseHexadecimalToken(cleaned) {
            return Column(id: 0, hexes: hexes)
        }
        if preferOctal, let octs = parseOctalToken(cleaned) {
            return Column(id: 0, octs: octs)
        }
        if preferQuaternary, let quats = parseQuaternaryToken(cleaned) {
            return Column(id: 0, quats: quats)
        }
        if preferTernary, let trits = parseTernaryToken(cleaned) {
            return Column(id: 0, trits: trits)
        }
        return nil
    }

    private static func parseVisualTokenStrict(_ cleaned: String) -> [Bool]? {
        // Preferred form length 9: dddSddddd
        let chars = Array(cleaned.filter { isHoleChar($0) || isSprocketChar($0) || isBlankChar($0) })
        if chars.count == 9, isSprocketChar(chars[3]) {
            return [
                isHoleChar(chars[0]),
                isHoleChar(chars[1]),
                isHoleChar(chars[2]),
                isHoleChar(chars[4]),
                isHoleChar(chars[5]),
                isHoleChar(chars[6]),
                isHoleChar(chars[7]),
                isHoleChar(chars[8]),
            ]
        }
        // 8 data bits only (no sprocket)
        if chars.count == 8, chars.allSatisfy({ isHoleChar($0) || isBlankChar($0) }) {
            return chars.map { isHoleChar($0) }
        }
        // Longer line: extract first 8 data glyphs, skip sprocket-like
        var holes: [Bool] = []
        for ch in chars {
            if isSprocketChar(ch) { continue }
            if isHoleChar(ch) {
                holes.append(true)
            } else if isBlankChar(ch) {
                holes.append(false)
            }
            if holes.count == 8 { return holes }
        }
        return holes.count == 8 ? holes : nil
    }

    private static func isHoleChar(_ ch: Character) -> Bool {
        switch ch {
        case "●", "*", "1", "X", "x", "#": return true
        default: return false
        }
    }

    private static func isBlankChar(_ ch: Character) -> Bool {
        switch ch {
        case "·", ".", "0", "-", "_": return true
        default: return false
        }
    }

    private static func isSprocketChar(_ ch: Character) -> Bool {
        switch ch {
        case "○", "o", "O": return true
        default: return false
        }
    }

    /// Multi-row terminal “paper” art for display / copy.
    /// Rows top→bottom: ch8 … ch1 with feed row between ch4 and ch3 (visual top is ch8).
    ///
    /// Binary columns: legend is one printable char per column (when ASCII).
    /// Ternary (v4): channels use blank/mid/full glyphs; the UTF-8 message is printed
    /// under the tape (columns are packed digits, not 1:1 with payload bytes).
    static func terminalPaper(for document: TapeDocument, maxColumns: Int? = nil) -> String {
        let cols = maxColumns.map { Array(document.columns.prefix($0)) } ?? document.columns
        guard !cols.isEmpty else {
            return "(empty tape)"
        }

        let nineChannels = document.packing == .base512
        let multistate = (document.packing.isMultistate && !nineChannels)
            || cols.contains(where: \.isMultistate)
        let quaternary = document.packing.isQuaternary
            || cols.contains(where: \.isQuaternary)
        let octal = document.packing.isOctal
            || cols.contains(where: \.isOctal)
        let hexadecimal = document.packing.isHexadecimal
            || cols.contains(where: \.isHexadecimal)
        let base256 = document.packing.isBase256
            || cols.contains(where: \.isBase256)
        let width = cols.count
        let edge = String(repeating: "─", count: width * 2 + 3)

        func row(_ label: String, values: [Character]) -> String {
            let body = values.map { "\($0)" }.joined(separator: " ")
            return "│ \(body) │ \(label)"
        }

        /// Channel glyph: binary, ternary, quaternary, octal, or hex.
        /// Uses raw multi-state levels (not the 0…7 display stretch used by the strip).
        func channelGlyph(_ col: Column, channelIndex: Int) -> Character {
            if multistate {
                let level: UInt8
                if let t = col.trits, channelIndex < t.count {
                    if col.multistateRadix == 0 {
                        level = t[channelIndex] // base-256: full byte
                    } else {
                        let maxL = col.multistateRadix > 1 ? col.multistateRadix - 1 : 7
                        level = min(t[channelIndex], maxL)
                    }
                } else {
                    level = col.channelLevel(channelIndex)
                }
                if base256 {
                    // Grayscale hint in terminal art: light → dark by high nibble.
                    let nibble = level >> 4
                    switch nibble {
                    case 0: return blankGlyph
                    case 1: return "·"
                    case 2: return "∘"
                    case 3: return "◦"
                    case 4: return "○"
                    case 5: return "◐"
                    case 6: return "◕"
                    default: return holeGlyph
                    }
                }
                if hexadecimal {
                    // Map 0…15 onto progressive Unicode hole intensities.
                    let mapped = UInt8((Int(level) * 7) / 15)
                    switch mapped {
                    case 0: return blankGlyph
                    case 1: return "·"
                    case 2: return "∘"
                    case 3: return "◦"
                    case 4: return "○"
                    case 5: return "◐"
                    case 6: return "◕"
                    default: return holeGlyph
                    }
                }
                if octal {
                    switch level {
                    case 0: return blankGlyph
                    case 1: return "·"
                    case 2: return "∘"
                    case 3: return "◦"
                    case 4: return "○"
                    case 5: return "◐"
                    case 6: return "◕"
                    default: return holeGlyph
                    }
                }
                if quaternary {
                    switch level {
                    case 0: return blankGlyph
                    case 1: return "◦"
                    case 2: return "◐"
                    default: return holeGlyph
                    }
                }
                switch level {
                case 0: return blankGlyph
                case 1: return "◦"
                default: return holeGlyph
                }
            }
            return col.channelLevel(channelIndex) > 0 ? holeGlyph : blankGlyph
        }

        // Visual order top→bottom: channel 8 … channel 4, feed, channel 3 … channel 1
        var lines: [String] = []
        lines.append("┌\(edge)┐")

        for ch in (4...(nineChannels ? 9 : 8)).reversed() {
            let glyphs: [Character] = cols.map { channelGlyph($0, channelIndex: ch - 1) }
            lines.append(row("ch\(ch)", values: glyphs))
        }

        let feed: [Character] = cols.map { _ in sprocketGlyph }
        lines.append(row("feed", values: feed))

        for ch in (1...3).reversed() {
            let glyphs: [Character] = cols.map { channelGlyph($0, channelIndex: ch - 1) }
            lines.append(row("ch\(ch)", values: glyphs))
        }

        lines.append("└\(edge)┘")

        if multistate {
            // Packed digits ≠ bytes: show restored text (or a short note) under the strip.
            if let text = document.textUTF8, !text.isEmpty {
                let single = text
                    .replacingOccurrences(of: "\r\n", with: " ")
                    .replacingOccurrences(of: "\n", with: " ")
                    .replacingOccurrences(of: "\r", with: " ")
                let shown = single.count > 120 ? String(single.prefix(117)) + "…" : single
                lines.append("  \(shown)")
            } else if let note = ternaryLegendNote(for: document) {
                lines.append("  \(note)")
            } else {
                let kind: String
                if base256 { kind = "base-256" }
                else if hexadecimal { kind = "hexadecimal" }
                else if octal { kind = "octal" }
                else if quaternary { kind = "quaternary" }
                else { kind = "ternary" }
                lines.append("  (\(kind) pack — \(cols.count) col\(cols.count == 1 ? "" : "s"))")
            }
        } else if !nineChannels {
            // Legend of printable characters under the tape (1 column = 1 byte)
            let legend = cols.map { col -> String in
                if let c = col.printableChar {
                    return String(c)
                }
                return "·"
            }.joined(separator: " ")
            lines.append("  \(legend)")
        }

        return lines.joined(separator: "\n")
    }

    /// Extra one-line note under multi-state terminal art when UTF-8 text is unavailable.
    private static func ternaryLegendNote(for document: TapeDocument) -> String? {
        let kind: String
        if document.packing.isBase256 { kind = "base-256" }
        else if document.packing.isHexadecimal { kind = "hexadecimal" }
        else if document.packing.isOctal { kind = "octal" }
        else if document.packing.isQuaternary { kind = "quaternary" }
        else { kind = "ternary" }
        if document.isPartialPreview {
            return "(\(kind) · partial preview — restore full .Tape for payload text)"
        }
        if document.isArchive {
            return "(\(kind) · folder archive)"
        }
        if document.isCompressed || document.usesBase85 {
            let n = (try? document.restoredData())?.count ?? 0
            if n > 0 {
                return "payload: \(n) byte\(n == 1 ? "" : "s") (binary / non-UTF-8)"
            }
        }
        return nil
    }

    /// One payload line for a column.
    /// - v1: Unicode token + `# char  0xNN`
    /// - v2: Unicode token only
    /// - v3: ASCII token only (`* . o`)
    /// - v4: Ternary ASCII token only (`. + * o`)
    static func columnLine(
        for column: Column,
        annotate: Bool,
        style: GlyphStyle = .unicode
    ) -> String {
        let token = visualToken(for: column, style: style)
        // Multi-state columns are packed digits, not 1:1 payload bytes — never annotate.
        guard annotate,
              style != .ternary, style != .quaternary, style != .octal,
              style != .hexadecimal, style != .base256
        else { return token }
        if let ch = column.printableChar, ch != " " {
            return "\(token)  # \(ch)  0x\(String(format: "%02X", column.byte))"
        }
        return "\(token)  # 0x\(String(format: "%02X", column.byte))"
    }

    /// Compact single-line-per-column form used as the payload of a `.Tape` file.
    static func columnListing(
        for document: TapeDocument,
        fileFormat: TapeFileFormat = .defaultWrite
    ) -> String {
        columnListingWithIntegrity(
            for: document.columns,
            blockSize: document.blockSize,
            fileFormat: fileFormat
        )
    }

    /// Column listing with `# @block` integrity markers between blocks.
    static func columnListingWithIntegrity(
        for columns: [Column],
        blockSize: Int,
        fileFormat: TapeFileFormat = .defaultWrite
    ) -> String {
        guard !columns.isEmpty else { return "" }
        let bs = max(1, blockSize)
        let annotate = fileFormat.includesColumnAnnotations
        let style = GlyphStyle.forFormat(fileFormat)
        var lines: [String] = []
        lines.reserveCapacity(columns.count + (columns.count / bs) + 2)

        var offset = 0
        var index = 0
        while offset < columns.count {
            let len = min(bs, columns.count - offset)
            let sliceCols = Array(columns[offset..<(offset + len)])
            let slice = integrityData(for: sliceCols[...])
            let crc = crc32(slice)
            let xor = xorParity(slice)
            let sum = sum8(slice)
            lines.append(
                "# @block \(index) off=\(offset) len=\(len) crc32=\(String(format: "%08X", crc)) xor=\(String(format: "%02X", xor)) sum8=\(String(format: "%02X", sum))"
            )
            for col in sliceCols {
                lines.append(columnLine(for: col, annotate: annotate, style: style))
            }
            offset += len
            index += 1
        }
        return lines.joined(separator: "\n")
    }

    /// Build ternary columns from binary punched payload using highest-density packing.
    static func ternaryColumns(
        fromPunched punched: Data,
        mode: PackingMode = .ternaryFull,
        chunkBytes: Int = 0
    ) -> [Column] {
        let digits = packTernary(punched, mode: mode, chunkBytes: chunkBytes)
        return digits.enumerated().map { Column(id: $0.offset, ternaryValue: $0.element) }
    }

    // MARK: - .Tape file format

    enum FormatError: LocalizedError {
        case emptyPayload
        case invalidHeader
        case unsupportedVersion(Int)
        case missingPayload
        case badColumn(Int)
        case unsupportedCompression(String)
        case decompressionFailed(String)
        case base85Failed(String)
        case io(String)
        case cancelled

        var errorDescription: String? {
            switch self {
            case .emptyPayload: return "No punched columns found."
            case .invalidHeader: return "Not a valid PaperTape (.Tape) file."
            case .unsupportedVersion(let v): return "Unsupported .Tape format version \(v)."
            case .missingPayload: return "Header present but tape body is empty."
            case .badColumn(let n): return "Could not parse punched column \(n)."
            case .unsupportedCompression(let k): return "Unsupported compression “\(k)”."
            case .decompressionFailed(let m): return "Decompression failed: \(m)"
            case .base85Failed(let m): return "Base85 error: \(m)"
            case .io(let msg): return msg
            case .cancelled: return "Encode cancelled."
            }
        }

        var isCancellation: Bool {
            if case .cancelled = self { return true }
            return false
        }
    }

    /// Cooperative cancel flag for long encode/pack jobs.
    final class EncodeCancelToken: @unchecked Sendable {
        private let lock = NSLock()
        private var _cancelled = false

        var isCancelled: Bool {
            lock.lock()
            defer { lock.unlock() }
            return _cancelled
        }

        func cancel() {
            lock.lock()
            _cancelled = true
            lock.unlock()
        }

        func throwIfCancelled() throws {
            if isCancelled { throw FormatError.cancelled }
        }
    }

    /// Build a UTF-8 `.Tape` document: metadata header + visual punched columns.
    /// - Parameter fileFormat:
    ///   - **v1** — Unicode tokens + per-column annotations + terminal-paper preview footer
    ///   - **v2** — Unicode tokens only
    ///   - **v3** — ASCII tokens (`* . o`) only
    ///   - **v4** — Ternary ASCII (`. + * o`) with full base-6561 packing
    /// Integrity: `# @block` markers carry CRC32 + XOR + SUM8 per block (comment lines only).
    static func serialize(
        _ document: TapeDocument,
        fileFormat: TapeFileFormat = .defaultWrite
    ) -> Data {
        let blockSize = max(1, document.blockSize > 0 ? document.blockSize : defaultBlockSize)
        let version = fileFormat.rawValue
        let glyphStyle = GlyphStyle.forFormat(fileFormat)

        // For v4: pack binary punched payload → ternary columns.
        // If the document is already ternary, re-pack from unpacked punched bytes so
        // re-saving always uses full packing.
        let writeColumns: [Column]
        let punchedByteCount: Int
        let packing: PackingMode
        let packChunk: Int
        if fileFormat == .v9 {
            let payload = document.punchedData
            packing = .base512
            packChunk = 0
            punchedByteCount = payload.count
            writeColumns = base512Columns(from: payload)
        } else if fileFormat.usesBase256Packing {
            let binaryPayload: Data
            if document.packing.isMultistate {
                binaryPayload = document.punchedData
            } else {
                binaryPayload = Data(document.columns.map(\.byte))
            }
            packing = .base256
            packChunk = 0
            punchedByteCount = binaryPayload.count
            writeColumns = base256Columns(fromPunched: binaryPayload)
        } else if fileFormat.usesHexadecimalPacking {
            let binaryPayload: Data
            if document.packing.isMultistate {
                binaryPayload = document.punchedData
            } else {
                binaryPayload = Data(document.columns.map(\.byte))
            }
            packing = .hexadecimal
            packChunk = 0
            punchedByteCount = binaryPayload.count
            writeColumns = hexadecimalColumns(fromPunched: binaryPayload)
        } else if fileFormat.usesOctalPacking {
            let binaryPayload: Data
            if document.packing.isMultistate {
                binaryPayload = document.punchedData
            } else {
                binaryPayload = Data(document.columns.map(\.byte))
            }
            packing = .octal
            packChunk = 0
            punchedByteCount = binaryPayload.count
            writeColumns = octalColumns(fromPunched: binaryPayload)
        } else if fileFormat.usesQuaternaryPacking {
            let binaryPayload: Data
            if document.packing.isMultistate {
                binaryPayload = document.punchedData
            } else {
                binaryPayload = Data(document.columns.map(\.byte))
            }
            packing = .quaternary
            packChunk = 0
            punchedByteCount = binaryPayload.count
            writeColumns = quaternaryColumns(fromPunched: binaryPayload)
        } else if fileFormat.usesTernaryPacking {
            let binaryPayload: Data
            if document.packing.isMultistate {
                binaryPayload = document.punchedData
            } else {
                binaryPayload = Data(document.columns.map(\.byte))
            }
            packing = .ternaryFull
            // Whole-integer pack only for modest sizes (O(n²)); larger → fixed chunks (O(n),
            // still ~12.68 bits/col). Avoids multi-second freezes when encoding real files.
            packChunk = preferredTernaryPackChunk(byteCount: binaryPayload.count)
            punchedByteCount = binaryPayload.count
            writeColumns = ternaryColumns(
                fromPunched: binaryPayload,
                mode: packing,
                chunkBytes: packChunk
            )
        } else {
            packing = .binary
            packChunk = 0
            // If source was multi-state, expand to binary columns for v1–v3 write.
            if document.packing.isMultistate {
                let bytes = document.punchedData
                writeColumns = columns(from: bytes)
                punchedByteCount = bytes.count
            } else {
                writeColumns = document.columns
                punchedByteCount = document.columns.count
            }
        }

        // Explicit newlines — avoids multiline-string indent surprises.
        var headerLines = [
            "# PaperTape File v\(version)",
            "# name: \(sanitizeName(document.originalName))",
            "# size: \(document.originalSize)",
            "# punched-size: \(punchedByteCount)",
            "# compression: \(document.compression.rawValue)",
            "# transfer: \(document.transferEncoding.rawValue)",
            "# block-size: \(blockSize)",
            "# integrity: crc32+xor+sum8",
            "# columns: \(fileFormat.columnsHeaderValue)",
            "# channels: \(fileFormat == .v9 ? 9 : channelCount)",
            "# bit-order: channel-1-lsb",
            "# layout: ch1 ch2 ch3 feed ch4 ch5 ch6 ch7 ch8\(fileFormat == .v9 ? " ch9" : "")",
            "# glyphs: \(glyphStyle.headerDescription)",
        ]
        if packing == .base512 {
            headerLines += ["# packing: b512", "# packing-base: 512", "# channel-states: 2"]
        } else if packing.isTernary {
            headerLines.append("# packing: \(packing.rawValue)")
            headerLines.append("# packing-base: \(ternaryBase)")
            headerLines.append("# channel-states: 3")
            headerLines.append("# ternary-columns: \(writeColumns.count)")
            headerLines.append("# pack-chunk: \(packChunk)")
        } else if packing.isQuaternary {
            headerLines.append("# packing: \(packing.rawValue)")
            headerLines.append("# packing-base: \(quaternaryBase)")
            headerLines.append("# channel-states: 4")
            headerLines.append("# quaternary-columns: \(writeColumns.count)")
            headerLines.append("# pack-chunk: 0")
        } else if packing.isOctal {
            headerLines.append("# packing: \(packing.rawValue)")
            headerLines.append("# packing-base: \(octalBase)")
            headerLines.append("# channel-states: 8")
            headerLines.append("# octal-columns: \(writeColumns.count)")
            headerLines.append("# pack-chunk: 0")
        } else if packing.isHexadecimal {
            headerLines.append("# packing: \(packing.rawValue)")
            headerLines.append("# packing-base: \(hexadecimalBase)")
            headerLines.append("# channel-states: 16")
            headerLines.append("# hexadecimal-columns: \(writeColumns.count)")
            headerLines.append("# pack-chunk: 0")
        } else if packing.isBase256 {
            headerLines.append("# packing: \(packing.rawValue)")
            headerLines.append("# packing-base: 18446744073709551616")
            headerLines.append("# channel-states: 256")
            headerLines.append("# base256-columns: \(writeColumns.count)")
            headerLines.append("# pack-chunk: 0")
            headerLines.append("# note: base-256 — each channel is a grayscale byte (0–255); 8 bytes/column")
        }
        if !document.note.isEmpty {
            headerLines.append("# note: \(sanitizeHeaderValue(document.note))")
        }
        headerLines.append("# ---")
        headerLines.append("")

        let body: String
        if writeColumns.isEmpty {
            body = "# (empty tape)\n"
        } else {
            body = columnListingWithIntegrity(
                for: writeColumns,
                blockSize: blockSize,
                fileFormat: fileFormat
            ) + "\n"
        }

        // v1 only: terminal paper preview (comments only; never parsed as columns).
        // v2/v3/v4 omit this section for a smaller, payload-focused file.
        var footer = ""
        if fileFormat.includesTerminalPreview {
            let previewDoc = TapeDocument(
                columns: writeColumns,
                originalName: document.originalName,
                originalSize: document.originalSize,
                compression: document.compression,
                transferEncoding: document.transferEncoding,
                note: document.note,
                blockSize: blockSize,
                integrity: nil,
                packing: packing,
                packedByteCount: punchedByteCount,
                packChunk: packChunk
            )
            let previewLimit = 96
            let preview = terminalPaper(for: previewDoc, maxColumns: previewLimit)
            var footerLines = [""]
            let label = writeColumns.count > previewLimit
                ? "# === terminal paper preview (first \(previewLimit) columns) ==="
                : "# === terminal paper preview ==="
            footerLines.append(label)
            for row in preview.split(separator: "\n", omittingEmptySubsequences: false) {
                footerLines.append("# \(row)")
            }
            footerLines.append("")
            footer = footerLines.joined(separator: "\n")
        }

        let text = headerLines.joined(separator: "\n") + body + footer
        return Data(text.utf8)
    }

    static func isTapeFile(_ data: Data) -> Bool {
        guard let head = String(data: data.prefix(80), encoding: .utf8) else { return false }
        return head.hasPrefix("# PaperTape File")
    }

    static func isTapeURL(_ url: URL) -> Bool {
        let ext = url.pathExtension
        if ext == "Tape" || ext.lowercased() == "tape" { return true }
        let accessed = url.startAccessingSecurityScopedResource()
        defer { if accessed { url.stopAccessingSecurityScopedResource() } }
        // Sniff only the header — never map an entire multi-GB file just to detect type.
        guard let handle = try? FileHandle(forReadingFrom: url) else { return false }
        defer { try? handle.close() }
        let head = (try? handle.read(upToCount: 256)) ?? Data()
        return isTapeFile(head)
    }

    static func deserialize(_ data: Data) throws -> TapeDocument {
        guard let text = String(data: data, encoding: .utf8) else {
            throw FormatError.invalidHeader
        }

        if text.hasPrefix("# PaperTape File") {
            return try deserializeHeadered(text)
        }

        // Loose visual stream: any lines that look like column tokens.
        let columns = try parseLooseColumns(text)
        guard !columns.isEmpty else { throw FormatError.emptyPayload }
        let cols = columns
        return TapeDocument(
            columns: cols,
            originalName: "decoded.bin",
            originalSize: cols.count,
            compression: .none,
            transferEncoding: .identity,
            note: "",
            blockSize: defaultBlockSize,
            integrity: buildIntegrityReport(for: cols, blockSize: defaultBlockSize, hasMarkers: false)
        )
    }

    /// Load a `.Tape` for the UI. Full document when the file is modest; for very
    /// large tapes, returns the first `maxColumns` columns so the strip/banner work.
    static func loadForDisplay(
        from url: URL,
        maxColumns: Int = 8_192
    ) throws -> TapeDocument {
        let accessed = url.startAccessingSecurityScopedResource()
        defer { if accessed { url.stopAccessingSecurityScopedResource() } }

        let fileSize = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        let fullLoadLimit = 12 * 1024 * 1024

        // Full load for known-modest sizes. Unknown size (0): probe up to the limit.
        if fileSize > 0, fileSize < fullLoadLimit {
            let data = try Data(contentsOf: url, options: [.mappedIfSafe])
            return finalizeDisplayDocument(try deserialize(data))
        }

        if fileSize == 0 {
            let handle = try FileHandle(forReadingFrom: url)
            defer { try? handle.close() }
            var buffer = Data()
            buffer.reserveCapacity(min(fullLoadLimit, 1_048_576))
            var hitLimit = false
            while buffer.count < fullLoadLimit {
                let chunk = try handle.read(upToCount: min(256 * 1024, fullLoadLimit - buffer.count)) ?? Data()
                if chunk.isEmpty { break }
                buffer.append(chunk)
                if buffer.count >= fullLoadLimit {
                    hitLimit = true
                    break
                }
            }
            if !hitLimit {
                return finalizeDisplayDocument(try deserialize(buffer))
            }
            // Too large with unknown size — fall through to stream preview.
        }

        // Large (or unknown-and-huge): line-scan first N column tokens for strip preview.
        // (Do not use TapeStreamReader payload unpack here — ternary full-pack only
        // yields bytes at EOF after reading the entire file.)
        return try loadColumnPreview(from: url, maxColumns: maxColumns)
    }

    /// Stream-parse a large `.Tape` for UI: header + first `maxColumns` column tokens.
    private static func loadColumnPreview(from url: URL, maxColumns: Int) throws -> TapeDocument {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }

        var leftover = Data()
        // Cap a single incomplete line — not the whole multi-line read-ahead buffer.
        let maxLineBytes = 256 * 1024
        func readLine() throws -> String? {
            while true {
                if let range = leftover.firstIndex(of: 0x0A) {
                    let lineData = leftover[..<range]
                    if lineData.count > maxLineBytes {
                        throw FormatError.io("Line too long in .Tape body (missing newline?)")
                    }
                    leftover = leftover[leftover.index(after: range)...]
                    let raw = lineData.last == 0x0D ? lineData.dropLast() : lineData
                    guard let line = String(data: raw, encoding: .utf8) else {
                        throw FormatError.io("Invalid UTF-8 in .Tape body")
                    }
                    return line
                }
                if leftover.count > maxLineBytes {
                    throw FormatError.io("Line too long in .Tape body (missing newline?)")
                }
                let chunk = try handle.read(upToCount: 256 * 1024) ?? Data()
                if chunk.isEmpty {
                    if leftover.isEmpty { return nil }
                    defer { leftover = Data() }
                    if leftover.count > maxLineBytes {
                        throw FormatError.io("Line too long in .Tape body (missing newline?)")
                    }
                    guard let line = String(data: leftover, encoding: .utf8) else {
                        throw FormatError.io("Invalid UTF-8 in .Tape body")
                    }
                    return line
                }
                leftover.append(chunk)
            }
        }

        var name = url.lastPathComponent
        var size = 0
        var punchedSize = 0
        var compression = CompressionKind.none
        var transfer = TransferEncoding.identity
        var blockSize = defaultBlockSize
        var containerMode = "blob"
        var packing = PackingMode.binary
        var packChunk = 0
        var inPayload = false

        while let line = try readLine() {
            let t = line.trimmingCharacters(in: .whitespaces)
            if t == "# ---" || t.hasPrefix("# ---") {
                inPayload = true
                break
            }
            if t.hasPrefix("# PaperTape File v") {
                let vStr = t.replacingOccurrences(of: "# PaperTape File v", with: "")
                let ver = Int(vStr.trimmingCharacters(in: .whitespaces)) ?? 0
                if ver == 9 {
                    packing = .base512
                } else if ver >= 8 {
                    packing = .base256
                } else if ver >= 7 {
                    packing = .hexadecimal
                } else if ver >= 6 {
                    packing = .octal
                } else if ver >= 5 {
                    packing = .quaternary
                } else if ver >= 4 {
                    packing = .ternaryFull
                }
            } else if t.hasPrefix("# name:") {
                name = String(t.dropFirst("# name:".count)).trimmingCharacters(in: .whitespaces)
            } else if t.hasPrefix("# size:") {
                size = Int(String(t.dropFirst("# size:".count)).trimmingCharacters(in: .whitespaces)) ?? 0
            } else if t.hasPrefix("# punched-size:") {
                punchedSize = Int(String(t.dropFirst("# punched-size:".count)).trimmingCharacters(in: .whitespaces)) ?? 0
            } else if t.hasPrefix("# mode:") {
                containerMode = String(t.dropFirst("# mode:".count)).trimmingCharacters(in: .whitespaces).lowercased()
            } else if t.hasPrefix("# compression:") {
                compression = CompressionKind.parse(String(t.dropFirst("# compression:".count)))
            } else if t.hasPrefix("# transfer:") {
                transfer = TransferEncoding.parse(String(t.dropFirst("# transfer:".count)))
            } else if t.hasPrefix("# block-size:") {
                blockSize = Int(String(t.dropFirst("# block-size:".count)).trimmingCharacters(in: .whitespaces)) ?? defaultBlockSize
            } else if t.hasPrefix("# packing:") {
                packing = PackingMode.parse(String(t.dropFirst("# packing:".count)))
            } else if t.hasPrefix("# pack-chunk:") {
                packChunk = Int(String(t.dropFirst("# pack-chunk:".count)).trimmingCharacters(in: .whitespaces)) ?? 0
            } else if t.hasPrefix("# columns:") {
                let c = String(t.dropFirst("# columns:".count)).trimmingCharacters(in: .whitespaces).lowercased()
                if c == "base256" || c == "b256", packing == .binary { packing = .base256 }
                if c == "hexadecimal" || c == "hex", packing == .binary { packing = .hexadecimal }
                if c == "octal", packing == .binary { packing = .octal }
                if c == "quaternary", packing == .binary { packing = .quaternary }
                if c == "ternary", packing == .binary { packing = .ternaryFull }
            }
        }
        guard inPayload else { throw FormatError.missingPayload }

        let preferTernary = packing.isTernary
        let preferQuaternary = packing.isQuaternary
        let preferOctal = packing.isOctal
        let preferHex = packing.isHexadecimal
        let preferB256 = packing.isBase256
        var cols: [Column] = []
        cols.reserveCapacity(min(maxColumns, 8_192))
        var more = false
        while let line = try readLine() {
            let t = line.trimmingCharacters(in: .whitespaces)
            if t.hasPrefix("# ===") { break }
            if t.isEmpty || t.hasPrefix("#") { continue }
            let tokenPart = t.split(separator: "#", maxSplits: 1)
                .first.map(String.init)?
                .trimmingCharacters(in: .whitespaces) ?? t
            guard let col = packing == .base512 ? parseBase512Token(tokenPart) : parseColumnToken(
                tokenPart,
                preferTernary: preferTernary,
                preferQuaternary: preferQuaternary,
                preferOctal: preferOctal,
                preferHexadecimal: preferHex,
                preferBase256: preferB256
            ) else { continue }
            if cols.count >= maxColumns {
                more = true
                break
            }
            if packing == .base512 {
                cols.append(Column(id: cols.count, base512Value: col.base512Value))
            } else if preferB256 {
                cols.append(Column(id: cols.count, base256Bytes: col.base256Bytes))
            } else if preferHex {
                cols.append(Column(id: cols.count, hexadecimalValue: col.hexadecimalValue))
            } else if preferOctal {
                cols.append(Column(id: cols.count, octalValue: col.octalValue))
            } else if preferQuaternary {
                cols.append(Column(id: cols.count, quaternaryValue: col.quaternaryValue))
            } else if preferTernary {
                cols.append(Column(id: cols.count, ternaryValue: col.ternaryValue))
            } else {
                cols.append(Column(id: cols.count, byte: col.byte))
            }
        }

        if containerMode == "archive" {
            compression = .none
            transfer = .identity
        }
        let partial = more || containerMode == "archive"
        let previewNote: String
        if containerMode == "archive" {
            previewNote = "Folder archive preview — use Files → Restore to extract"
        } else if partial {
            previewNote = "Partial preview (first \(cols.count) columns) — integrity not full-file"
        } else {
            previewNote = "Preview of large .Tape"
        }
        let report = buildIntegrityReport(for: cols, blockSize: blockSize, hasMarkers: false)
        return TapeDocument(
            columns: cols,
            originalName: name,
            originalSize: size,
            compression: containerMode == "archive" ? .none : compression,
            transferEncoding: containerMode == "archive" ? .identity : transfer,
            note: previewNote,
            blockSize: blockSize,
            integrity: report,
            containerMode: containerMode.isEmpty ? "blob" : containerMode,
            isPartialPreview: partial,
            packing: packing,
            packedByteCount: punchedSize,
            packChunk: packChunk
        )
    }

    private static func finalizeDisplayDocument(_ doc: TapeDocument) -> TapeDocument {
        var doc = doc
        if doc.integrity == nil, !doc.columns.isEmpty {
            doc.integrity = buildIntegrityReport(
                for: doc.columns,
                blockSize: doc.blockSize,
                hasMarkers: false
            )
        }
        return doc
    }

    private static func deserializeHeadered(_ text: String) throws -> TapeDocument {
        var exactPunchedSize: Int?
        var contradictoryPunchedSize = false
        // 0 until `# PaperTape File vN` is seen — do not default to latest formatVersion
        // or missing-version files would be forced into octal packing.
        var version = 0
        var name = "decoded.bin"
        var size = 0
        var declaredSize: Int?
        var punchedSize = 0
        var compression = CompressionKind.none
        var transfer = TransferEncoding.identity
        var blockSize = defaultBlockSize
        var note = ""
        var containerMode = "blob"
        var packing = PackingMode.binary
        var packChunk = 0
        var denseColumnHint = 0
        var columnsHeader = ""
        var payloadLines: [String] = []
        var inPayload = false

        // Pre-scan entire file for punched-size (header *or* stream trailer after # ===).
        // Last numeric value wins so the trailer can correct "unknown" streams.
        for line in text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("# punched-size:") {
                let raw = String(trimmed.dropFirst("# punched-size:".count))
                    .trimmingCharacters(in: .whitespaces)
                if let n = Int(raw), n >= 0 {
                    if let previous = exactPunchedSize, previous != n { contradictoryPunchedSize = true }
                    exactPunchedSize = n
                    punchedSize = n
                }
            }
        }

        for line in text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            if !inPayload {
                if trimmed == "# ---" || trimmed == "---" || trimmed.hasPrefix("# ---") {
                    inPayload = true
                    continue
                }
                if trimmed.hasPrefix("# PaperTape File v") {
                    let vStr = trimmed.replacingOccurrences(of: "# PaperTape File v", with: "")
                    version = Int(vStr.trimmingCharacters(in: .whitespaces)) ?? version
                    continue
                }
                if trimmed.hasPrefix("# name:") {
                    name = String(trimmed.dropFirst("# name:".count)).trimmingCharacters(in: .whitespaces)
                    continue
                }
                if trimmed.hasPrefix("# size:") {
                    declaredSize = Int(trimmed.dropFirst("# size:".count).trimmingCharacters(in: .whitespaces))
                    size = declaredSize ?? 0
                    continue
                }
                if trimmed.hasPrefix("# punched-size:") {
                    // Prefer pre-scan (includes trailer); still accept header mid-pass.
                    let raw = String(trimmed.dropFirst("# punched-size:".count))
                        .trimmingCharacters(in: .whitespaces)
                    if let n = Int(raw), n >= 0 { punchedSize = n }
                    continue
                }
                if trimmed.hasPrefix("# mode:") {
                    containerMode = String(trimmed.dropFirst("# mode:".count))
                        .trimmingCharacters(in: .whitespaces)
                        .lowercased()
                    if containerMode.isEmpty { containerMode = "blob" }
                    continue
                }
                if trimmed.hasPrefix("# compression:") {
                    compression = CompressionKind.parse(
                        String(trimmed.dropFirst("# compression:".count))
                    )
                    continue
                }
                if trimmed.hasPrefix("# transfer:") {
                    transfer = TransferEncoding.parse(
                        String(trimmed.dropFirst("# transfer:".count))
                    )
                    continue
                }
                if trimmed.hasPrefix("# block-size:") {
                    blockSize = Int(String(trimmed.dropFirst("# block-size:".count)).trimmingCharacters(in: .whitespaces))
                        ?? defaultBlockSize
                    continue
                }
                if trimmed.hasPrefix("# packing:") {
                    packing = PackingMode.parse(
                        String(trimmed.dropFirst("# packing:".count))
                    )
                    continue
                }
                if trimmed.hasPrefix("# pack-chunk:") {
                    packChunk = Int(String(trimmed.dropFirst("# pack-chunk:".count)).trimmingCharacters(in: .whitespaces)) ?? 0
                    continue
                }
                if trimmed.hasPrefix("# ternary-columns:") {
                    denseColumnHint = Int(String(trimmed.dropFirst("# ternary-columns:".count)).trimmingCharacters(in: .whitespaces)) ?? 0
                    continue
                }
                if trimmed.hasPrefix("# quaternary-columns:") {
                    denseColumnHint = Int(String(trimmed.dropFirst("# quaternary-columns:".count)).trimmingCharacters(in: .whitespaces)) ?? 0
                    continue
                }
                if trimmed.hasPrefix("# octal-columns:") {
                    denseColumnHint = Int(String(trimmed.dropFirst("# octal-columns:".count)).trimmingCharacters(in: .whitespaces)) ?? 0
                    continue
                }
                if trimmed.hasPrefix("# hexadecimal-columns:") {
                    denseColumnHint = Int(String(trimmed.dropFirst("# hexadecimal-columns:".count)).trimmingCharacters(in: .whitespaces)) ?? 0
                    continue
                }
                if trimmed.hasPrefix("# base256-columns:") {
                    denseColumnHint = Int(String(trimmed.dropFirst("# base256-columns:".count)).trimmingCharacters(in: .whitespaces)) ?? 0
                    continue
                }
                if trimmed.hasPrefix("# columns:") {
                    columnsHeader = String(trimmed.dropFirst("# columns:".count))
                        .trimmingCharacters(in: .whitespaces)
                        .lowercased()
                    continue
                }
                // Accept older alias
                if trimmed.hasPrefix("# base85:") {
                    let v = String(trimmed.dropFirst("# base85:".count))
                        .trimmingCharacters(in: .whitespaces)
                        .lowercased()
                    if v == "1" || v == "true" || v == "yes" || v == "ascii85" {
                        transfer = .ascii85
                    }
                    continue
                }
                if trimmed.hasPrefix("# note:") {
                    note = String(trimmed.dropFirst("# note:".count)).trimmingCharacters(in: .whitespaces)
                    continue
                }
                continue
            }

            // Payload region — stop at terminal preview section
            if trimmed.hasPrefix("# ===") { break }
            if trimmed.isEmpty { continue }
            // Keep @block marker lines and column lines; skip other comments.
            // For archives, also skip @file/@endfile (columns are still shown for the strip).
            if trimmed.hasPrefix("#") {
                if trimmed.hasPrefix("# @block") {
                    payloadLines.append(trimmed)
                }
                continue
            }
            payloadLines.append(trimmed)
        }

        if version > formatVersion {
            throw FormatError.unsupportedVersion(version)
        }

        // Infer dense packing from version / columns header when packing field omitted.
        if version == 9 {
            packing = .base512
        } else if packing == .binary {
            if version >= 8 || columnsHeader == "base256" || columnsHeader == "b256" {
                packing = .base256
            } else if version >= 7 || columnsHeader == "hexadecimal" || columnsHeader == "hex" {
                packing = .hexadecimal
            } else if version >= 6 || columnsHeader == "octal" {
                packing = .octal
            } else if version >= 5 || columnsHeader == "quaternary" {
                packing = .quaternary
            } else if version >= 4 || columnsHeader == "ternary" {
                packing = .ternaryFull
            }
        }
        let preferTernary = packing.isTernary
        let preferQuaternary = packing.isQuaternary
        let preferOctal = packing.isOctal
        let preferHex = packing.isHexadecimal
        let preferB256 = packing.isBase256
        let preferDense = packing.isMultistate

        // Folder archives are multi-member; never treat as a single blob for restore.
        // Still parse columns so the Tape tab can show a strip preview.
        if containerMode == "archive" {
            compression = .none
            transfer = .identity
            if note.isEmpty {
                note = "Folder archive — use Files → Restore to extract members"
            }
        }

        if compression != .none, compression.nsAlgorithm == nil {
            throw FormatError.unsupportedCompression(compression.rawValue)
        }

        // Sequential parse: each `# @block` opens a section; following column lines
        // belong to that section until the next marker. This matches serialize order
        // and avoids false cascade failures from re-slicing with a uniform block size.
        struct PendingSection {
            var marker: (index: Int, off: Int, len: Int, crc: UInt32, xor: UInt8, sum: UInt8)?
            var columns: [Column] = []
        }

        var sections: [PendingSection] = []
        var current = PendingSection()
        var hasMarkers = false

        func pushCurrent() {
            if current.marker != nil || !current.columns.isEmpty {
                sections.append(current)
            }
            current = PendingSection()
        }

        for line in payloadLines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("# @block") || trimmed.hasPrefix("@block") {
                pushCurrent()
                hasMarkers = true
                current.marker = parseBlockMarker(trimmed)
                continue
            }
            if trimmed.isEmpty || trimmed.hasPrefix("#") { continue }

            let tokenPart = trimmed.split(separator: "#", maxSplits: 1, omittingEmptySubsequences: false)
                .first
                .map(String.init)?
                .trimmingCharacters(in: .whitespaces) ?? trimmed
            guard let col = packing == .base512 ? parseBase512Token(tokenPart) : parseColumnToken(
                tokenPart,
                preferTernary: preferTernary,
                preferQuaternary: preferQuaternary,
                preferOctal: preferOctal,
                preferHexadecimal: preferHex,
                preferBase256: preferB256
            ) else {
                if packing == .base512 { throw base512Error("invalid column token") }
                continue
            }
            current.columns.append(col)
        }
        pushCurrent()

        // Legacy files: no markers, one flat column stream
        if !hasMarkers && sections.count == 1, sections[0].marker == nil {
            // keep as-is
        } else if !hasMarkers && sections.isEmpty {
            // no data
        }

        if packing == .base512 {
            var expectedOffset = 0
            for (index, section) in sections.enumerated() {
                guard section.columns.count <= blockSize else { throw base512Error("oversized block") }
                let m = section.marker
                // Archive offsets and indices restart at each member.
                if containerMode != "archive",
                   m?.off != expectedOffset || m?.index != index {
                    throw base512Error("invalid block offset")
                }
                try validateBase512Block(section.columns, stored: m.map { ($0.crc, $0.xor, $0.sum, $0.len) })
                expectedOffset += section.columns.count
            }
            if containerMode != "archive" {
                guard !contradictoryPunchedSize, let exactPunchedSize else {
                    throw base512Error("missing or contradictory punched size")
                }
                var decoder = Base512Decoder()
                var output = Data()
                for section in sections {
                    for column in section.columns { decoder.append(column.base512Value, to: &output) }
                }
                try decoder.finish(byteCount: Int64(exactPunchedSize), to: &output)
                if compression == .none, transfer == .identity, let declaredSize, declaredSize != exactPunchedSize {
                    throw base512Error("original and punched sizes differ")
                }
            }
        }

        var columns: [Column] = []
        var integrityBlocks: [IntegrityBlock] = []
        var offset = 0
        columns.reserveCapacity(sections.reduce(0) { $0 + $1.columns.count })

        for (seq, section) in sections.enumerated() {
            let data = integrityData(for: section.columns[...])
            let computedCRC = crc32(data)
            let computedXOR = xorParity(data)
            let computedSum = sum8(data)

            let index = section.marker?.index ?? seq
            var storedCRC: UInt32
            let storedXOR: UInt8
            let storedSum: UInt8
            if let m = section.marker {
                storedCRC = m.crc
                storedXOR = m.xor
                storedSum = m.sum
                // Length mismatch against marker is an integrity failure even if CRC collides.
                if m.len > 0, m.len != section.columns.count {
                    storedCRC = computedCRC &+ 1
                }
            } else if hasMarkers {
                // Columns appeared without a marker while other markers exist
                storedCRC = computedCRC &+ 1
                storedXOR = computedXOR &+ 1
                storedSum = computedSum &+ 1
            } else {
                storedCRC = computedCRC
                storedXOR = computedXOR
                storedSum = computedSum
            }

            integrityBlocks.append(IntegrityBlock(
                index: index,
                offset: offset,
                length: section.columns.count,
                storedCRC32: storedCRC,
                storedXOR: storedXOR,
                storedSum8: storedSum,
                computedCRC32: computedCRC,
                computedXOR: computedXOR,
                computedSum8: computedSum
            ))

            for col in section.columns {
                if packing == .base512 {
                    columns.append(Column(id: columns.count, base512Value: col.base512Value))
                } else if preferB256 {
                    columns.append(Column(id: columns.count, base256Bytes: col.base256Bytes))
                } else if preferHex {
                    columns.append(Column(id: columns.count, hexadecimalValue: col.hexadecimalValue))
                } else if preferOctal {
                    columns.append(Column(id: columns.count, octalValue: col.octalValue))
                } else if preferQuaternary {
                    columns.append(Column(id: columns.count, quaternaryValue: col.quaternaryValue))
                } else if preferTernary {
                    columns.append(Column(id: columns.count, ternaryValue: col.ternaryValue))
                } else {
                    columns.append(Column(id: columns.count, byte: col.byte))
                }
            }
            offset += section.columns.count
        }

        guard !columns.isEmpty else {
            // Empty body is valid when:
            // - original size is 0 / archive shell
            // - dense payload with punched-size (e.g. legacy all-zero pack with no digits)
            if size == 0 || containerMode == "archive" {
                return TapeDocument(
                    columns: [],
                    originalName: name,
                    originalSize: size,
                    compression: .none,
                    transferEncoding: .identity,
                    note: containerMode == "archive"
                        ? (note.isEmpty ? "Folder archive — use Files → Restore" : note)
                        : note,
                    blockSize: blockSize,
                    integrity: nil,
                    containerMode: containerMode,
                    isPartialPreview: false,
                    packing: packing,
                    packedByteCount: 0,
                    packChunk: packChunk
                )
            }
            if preferDense, punchedSize > 0 {
                // Restore N zero bytes from punched-size with a single zero column.
                let zeroCol: [Column]
                if preferB256 {
                    zeroCol = [Column(id: 0, base256Bytes: [UInt8](repeating: 0, count: 8))]
                } else if preferHex {
                    zeroCol = [Column(id: 0, hexadecimalValue: 0)]
                } else if preferOctal {
                    zeroCol = [Column(id: 0, octalValue: 0)]
                } else if preferQuaternary {
                    zeroCol = [Column(id: 0, quaternaryValue: 0)]
                } else {
                    zeroCol = [Column(id: 0, ternaryValue: 0)]
                }
                return TapeDocument(
                    columns: zeroCol,
                    originalName: name.isEmpty ? "decoded.bin" : name,
                    originalSize: size > 0 ? size : punchedSize,
                    compression: compression,
                    transferEncoding: transfer,
                    note: note,
                    blockSize: blockSize,
                    integrity: buildIntegrityReport(
                        for: zeroCol,
                        blockSize: blockSize,
                        hasMarkers: false
                    ),
                    containerMode: containerMode,
                    isPartialPreview: false,
                    packing: packing,
                    packedByteCount: punchedSize,
                    packChunk: packChunk
                )
            }
            throw FormatError.missingPayload
        }

        var reindexed = columns
        let transformed = compression != .none || transfer != .identity
        // Binary legacy trim only (dense packing uses punched-size as packed byte count).
        if !preferDense {
            if !transformed, !hasMarkers, size > 0, size < reindexed.count {
                reindexed = Array(reindexed.prefix(size))
                    .enumerated()
                    .map { Column(id: $0.offset, holes: $0.element.holes) }
            } else if !hasMarkers, punchedSize > 0, punchedSize < reindexed.count {
                reindexed = Array(reindexed.prefix(punchedSize))
                    .enumerated()
                    .map { Column(id: $0.offset, holes: $0.element.holes) }
            }
        } else if denseColumnHint > 0, denseColumnHint < reindexed.count, !hasMarkers {
            reindexed = Array(reindexed.prefix(denseColumnHint))
                .enumerated()
                .map {
                    if packing == .base512 {
                        return Column(id: $0.offset, base512Value: $0.element.base512Value)
                    }
                    if preferB256 {
                        return Column(id: $0.offset, base256Bytes: $0.element.base256Bytes)
                    }
                    if preferHex {
                        return Column(id: $0.offset, hexadecimalValue: $0.element.hexadecimalValue)
                    }
                    if preferOctal {
                        return Column(id: $0.offset, octalValue: $0.element.octalValue)
                    }
                    if preferQuaternary {
                        return Column(id: $0.offset, quaternaryValue: $0.element.quaternaryValue)
                    }
                    return Column(id: $0.offset, ternaryValue: $0.element.ternaryValue)
                }
        }

        let packedBytes: Int
        if preferDense {
            if punchedSize > 0 {
                packedBytes = punchedSize
            } else if size > 0, !transformed {
                // Stream header may only have # size: (raw punched length).
                packedBytes = size
            } else {
                packedBytes = 0
            }
        } else {
            packedBytes = reindexed.count
        }

        let originalSize: Int
        if size > 0 {
            originalSize = size
        } else if !transformed {
            originalSize = preferDense ? (packedBytes > 0 ? packedBytes : reindexed.count) : reindexed.count
        } else {
            originalSize = 0
        }

        // If we trimmed without markers, rebuild integrity for the kept columns
        let report: IntegrityReport
        if hasMarkers {
            report = IntegrityReport(
                blockSize: blockSize,
                blocks: integrityBlocks,
                hasMarkers: true
            )
        } else {
            report = buildIntegrityReport(
                for: reindexed,
                blockSize: blockSize,
                hasMarkers: false,
                stored: nil
            )
        }

        let doc = TapeDocument(
            columns: reindexed,
            originalName: name.isEmpty ? "decoded.bin" : name,
            originalSize: containerMode == "archive" ? size : originalSize,
            compression: compression,
            transferEncoding: transfer,
            note: note,
            blockSize: blockSize,
            integrity: report,
            containerMode: containerMode,
            isPartialPreview: false,
            packing: packing,
            packedByteCount: packedBytes,
            packChunk: packChunk
        )

        // Restore check for compressed/Base85 only when integrity allows a sensible payload.
        // Never fail open solely because of integrity (user may still export best-effort data).
        if containerMode != "archive", compression != .none || transfer != .identity {
            _ = try? doc.restoredData()
        }

        return doc
    }

    /// Parse `# @block 0 off=0 len=64 crc32=AABBCCDD xor=5A sum8=3C`
    static func parseBlockMarker(_ line: String) -> (index: Int, off: Int, len: Int, crc: UInt32, xor: UInt8, sum: UInt8)? {
        var rest = line.trimmingCharacters(in: .whitespaces)
        // Accept "# @block …", "## @block …", or bare "@block …"
        while rest.hasPrefix("#") {
            rest = String(rest.dropFirst()).trimmingCharacters(in: .whitespaces)
        }
        guard rest.hasPrefix("@block") else { return nil }
        rest = String(rest.dropFirst("@block".count)).trimmingCharacters(in: .whitespaces)

        var index = 0
        var off = 0
        var len = 0
        var crc: UInt32 = 0
        var xor: UInt8 = 0
        var sum: UInt8 = 0
        var sawCRC = false

        let parts = rest.split(whereSeparator: { $0 == " " || $0 == "\t" })
        if let first = parts.first, let idx = Int(first) {
            index = idx
        }
        for part in parts.dropFirst() {
            let kv = part.split(separator: "=", maxSplits: 1)
            guard kv.count == 2 else { continue }
            let key = String(kv[0]).lowercased()
            let val = String(kv[1]).trimmingCharacters(in: .whitespaces)
            switch key {
            case "off": off = Int(val) ?? off
            case "len": len = Int(val) ?? len
            case "crc32":
                if let v = UInt32(val, radix: 16) {
                    crc = v
                    sawCRC = true
                }
            case "xor":
                xor = UInt8(val, radix: 16) ?? xor
            case "sum8":
                sum = UInt8(val, radix: 16) ?? sum
            default: break
            }
        }
        // Require at least a crc field so we don't invent empty markers
        guard sawCRC || len > 0 || parts.count >= 1 else { return nil }
        return (index, off, len, crc, xor, sum)
    }

    private static func parseLooseColumns(_ text: String) throws -> [Column] {
        var columns: [Column] = []
        for line in text.split(separator: "\n").map(String.init) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty || trimmed.hasPrefix("#") { continue }
            let tokenPart = trimmed.split(separator: "#", maxSplits: 1)
                .first
                .map(String.init)?
                .trimmingCharacters(in: .whitespaces) ?? trimmed
            if let holes = parseVisualToken(tokenPart) {
                columns.append(Column(id: columns.count, holes: holes))
            }
        }
        return columns
    }

    // MARK: - Self-test

    static func runSelfTest() -> String {
        var failures: [String] = []

        let samples: [(String, String)] = [
            ("Hello", "hello.txt"),
            ("PaperTape ★", "unicode.txt"),
            ("", "empty.txt"),
            (String(repeating: "A", count: 64), "block.txt"),
        ]

        for (text, name) in samples {
            let doc = encodeText(text, originalName: name)
            let file = serialize(doc)
            do {
                let round = try deserialize(file)
                if round.data != Data(text.utf8) {
                    failures.append("round-trip data mismatch for \(name)")
                }
                if round.originalName != name {
                    failures.append("name mismatch for \(name): \(round.originalName)")
                }
                // Token parse
                for col in doc.columns {
                    let token = visualToken(for: col)
                    guard let holes = parseVisualToken(token) else {
                        failures.append("token parse failed: \(token)")
                        continue
                    }
                    if holes != col.holes {
                        failures.append("token holes mismatch: \(token)")
                    }
                }
            } catch {
                failures.append("\(name): \(error.localizedDescription)")
            }
        }

        // Binary blob with all bit patterns
        var blob = Data()
        for i in 0...255 {
            blob.append(UInt8(i))
        }
        let binDoc = encode(data: blob, originalName: "all-bytes.bin")
        do {
            let round = try deserialize(serialize(binDoc))
            if round.data != blob {
                failures.append("all-bytes.bin round-trip mismatch")
            }
        } catch {
            failures.append("all-bytes: \(error.localizedDescription)")
        }

        // Forced codec round-trips (highly compressible payload)
        let compressible = Data(repeating: 0x41, count: 4_096) // "A" * 4096
        for kind in [CompressionKind.lzfse, CompressionKind.zlib, CompressionKind.lz4, CompressionKind.lzma] {
            let doc = encode(data: compressible, originalName: "aaaa.bin", compression: kind)
            if doc.compression != kind {
                failures.append("\(kind.rawValue): expected compression to apply, got \(doc.compression.rawValue)")
            }
            if doc.columns.count >= compressible.count {
                failures.append("\(kind.rawValue): compressed columns not smaller (\(doc.columns.count) vs \(compressible.count))")
            }
            let file = serialize(doc)
            if !String(data: file, encoding: .utf8)!.contains("# compression: \(kind.rawValue)") {
                failures.append("\(kind.rawValue): header missing compression field")
            }
            do {
                let round = try deserialize(file)
                if round.compression != kind {
                    failures.append("\(kind.rawValue): compression not restored from header")
                }
                if round.data != compressible {
                    failures.append("\(kind.rawValue): decompressed payload mismatch")
                }
            } catch {
                failures.append("\(kind.rawValue): \(error.localizedDescription)")
            }
        }

        // Auto: pick a winner, never store "auto"
        let autoDoc = encode(data: compressible, originalName: "auto.bin", compression: .auto)
        if autoDoc.compression == .auto {
            failures.append("auto: must not store preference auto in document")
        }
        if !autoDoc.isCompressed {
            failures.append("auto: expected a concrete codec for highly compressible data")
        } else {
            // Winner should be at least as small as every individual candidate trial
            var bestForced = compressible.count
            for kind in CompressionKind.autoCandidates {
                let d = encode(data: compressible, originalName: "t.bin", compression: kind)
                bestForced = min(bestForced, d.columns.count)
            }
            if autoDoc.columns.count > bestForced {
                failures.append("auto: winner larger than best forced codec (\(autoDoc.columns.count) > \(bestForced))")
            }
            do {
                let round = try deserialize(serialize(autoDoc))
                if round.data != compressible {
                    failures.append("auto: round-trip payload mismatch")
                }
                if round.compression == .auto {
                    failures.append("auto: header should store concrete algorithm")
                }
            } catch {
                failures.append("auto: \(error.localizedDescription)")
            }
        }

        // Tiny unique bytes: auto should leave raw (below min input / expands)
        let tiny = Data([0x01, 0x02, 0x03])
        let tinyDoc = encode(data: tiny, originalName: "tiny.bin", compression: .auto)
        if tinyDoc.compression != .none || tinyDoc.punchedData != tiny {
            failures.append("tiny auto should punch raw bytes")
        }

        // Message-scale repeated text should compress under Auto
        let message = String(repeating: "Hello tape. ", count: 20) // 240 bytes
        let msgDoc = encodeText(message, originalName: "msg.txt", compression: .auto)
        if !msgDoc.isCompressed {
            failures.append("message auto: expected compression for repeated phrase (\(message.utf8.count) bytes)")
        } else if msgDoc.data != Data(message.utf8) {
            failures.append("message auto: round-trip data mismatch")
        }

        // Incompressible-ish random data often fails the savings floor
        var random = Data()
        random.reserveCapacity(512)
        var state: UInt64 = 0xC0FFEE
        for _ in 0..<512 {
            state = state &* 6364136223846793005 &+ 1
            random.append(UInt8(truncatingIfNeeded: state >> 33))
        }
        let randDoc = encode(data: random, originalName: "rand.bin", compression: .auto)
        // If it did compress, it must still round-trip and meet the worthwhile bar.
        if randDoc.isCompressed {
            if !isWorthwhileCompression(original: random.count, compressed: randDoc.columns.count) {
                failures.append("random: compressed without meeting savings floor")
            }
            do {
                if try deserialize(serialize(randDoc)).data != random {
                    failures.append("random: compressed round-trip mismatch")
                }
            } catch {
                failures.append("random: \(error.localizedDescription)")
            }
        } else if randDoc.punchedData != random {
            failures.append("random: raw fallback should preserve bytes")
        }

        // Base85 round-trip (with and without compression)
        let b85Payload = Data("Man is distinguished, not only by his reason, but...".utf8)
        do {
            let enc = ascii85Encode(b85Payload)
            let dec = try ascii85Decode(enc)
            if dec != b85Payload {
                failures.append("ascii85 pure round-trip mismatch")
            }
            // All Ascii85 output should be printable-ish for strip legend
            if enc.contains(where: { $0 < 33 || ($0 > 117 && $0 != UInt8(ascii: "z")) }) {
                failures.append("ascii85 produced out-of-range bytes")
            }
        } catch {
            failures.append("ascii85: \(error.localizedDescription)")
        }

        let b85Doc = encode(
            data: b85Payload,
            originalName: "b85.txt",
            compression: .none,
            transferEncoding: .ascii85
        )
        if b85Doc.transferEncoding != .ascii85 {
            failures.append("base85: transfer not recorded")
        }
        do {
            let round = try deserialize(serialize(b85Doc))
            if round.transferEncoding != .ascii85 {
                failures.append("base85: transfer not restored from header")
            }
            if round.data != b85Payload {
                failures.append("base85: document round-trip mismatch")
            }
            // Visual column tokens present (Unicode or ASCII dialect)
            let fileText = String(data: serialize(b85Doc, fileFormat: .v2), encoding: .utf8) ?? ""
            let fileAscii = String(data: serialize(b85Doc, fileFormat: .v3), encoding: .utf8) ?? ""
            if !b85Doc.columns.isEmpty {
                if !fileText.contains(String(holeGlyph)) {
                    failures.append("base85: Unicode visual hole glyphs missing from v2 .Tape")
                }
                if !fileAscii.contains(String(asciiHoleGlyph)) {
                    failures.append("base85: ASCII visual hole glyphs missing from v3 .Tape")
                }
            }
        } catch {
            failures.append("base85 file: \(error.localizedDescription)")
        }

        let b85Comp = encode(
            data: Data(repeating: 0x41, count: 500),
            originalName: "both.bin",
            compression: .auto,
            transferEncoding: .ascii85
        )
        do {
            let round = try deserialize(serialize(b85Comp))
            if round.data != Data(repeating: 0x41, count: 500) {
                failures.append("base85+compress round-trip mismatch")
            }
        } catch {
            failures.append("base85+compress: \(error.localizedDescription)")
        }

        // Format v1 vs v2: both round-trip; v2 has no per-column annotations.
        do {
            let text = "Hello v2 compact"
            let doc = encodeText(text, originalName: "fmt.txt", compression: .none)
            let v1 = String(data: serialize(doc, fileFormat: .v1), encoding: .utf8)!
            let v2 = String(data: serialize(doc, fileFormat: .v2), encoding: .utf8)!
            if !v1.hasPrefix("# PaperTape File v1") {
                failures.append("format: v1 header missing")
            }
            if !v2.hasPrefix("# PaperTape File v2") {
                failures.append("format: v2 header missing")
            }
            if !v1.contains("0x48"), !v1.contains("# H") {
                // 'H' of Hello is 0x48 — annotated form should include hex or char notes
                if !v1.contains("  # ") {
                    failures.append("format: v1 should annotate columns")
                }
            }
            // v2 body column lines must not include trailing annotations
            let v2Body = v2.components(separatedBy: "# ---\n").last ?? v2
            for line in v2Body.split(separator: "\n", omittingEmptySubsequences: false) {
                let t = line.trimmingCharacters(in: .whitespaces)
                if t.isEmpty || t.hasPrefix("#") { continue }
                if t.contains("  # ") || t.contains("0x") {
                    failures.append("format: v2 column line should not be annotated: \(t)")
                    break
                }
            }
            if v2.contains("# === terminal paper preview") {
                failures.append("format: v2 must omit terminal paper preview section")
            }
            if !v1.contains("# === terminal paper preview") {
                failures.append("format: v1 must include terminal paper preview section")
            }
            let v3 = String(data: serialize(doc, fileFormat: .v3), encoding: .utf8)!
            if !v3.hasPrefix("# PaperTape File v3") {
                failures.append("format: v3 header missing")
            }
            if v3.contains("●") || v3.contains("·") || v3.contains("○") {
                failures.append("format: v3 body must not use Unicode hole/blank/sprocket glyphs")
            }
            if !v3.contains("*") || !v3.contains(".") || !v3.contains("o") {
                failures.append("format: v3 should use ASCII * . o glyphs")
            }
            if v3.contains("# === terminal paper preview") {
                failures.append("format: v3 must omit terminal paper preview section")
            }
            // First column of "Hello v2 compact" is 'H' = 0x48 → bits for visual token
            let r1 = try deserialize(Data(v1.utf8))
            let r2 = try deserialize(Data(v2.utf8))
            let r3 = try deserialize(Data(v3.utf8))
            if r1.data != Data(text.utf8) || r2.data != Data(text.utf8) || r3.data != Data(text.utf8) {
                failures.append("format: v1/v2/v3 payload round-trip mismatch")
            }
            if r1.integrity?.allOK != true || r2.integrity?.allOK != true || r3.integrity?.allOK != true {
                failures.append("format: v1/v2/v3 integrity should verify OK")
            }

            // v4 ternary full pack
            let v4 = String(data: serialize(doc, fileFormat: .v4), encoding: .utf8)!
            if !v4.hasPrefix("# PaperTape File v4") {
                failures.append("format: v4 header missing")
            }
            if !v4.contains("# packing: full") || !v4.contains("# columns: ternary") {
                failures.append("format: v4 packing/columns headers missing")
            }
            if !v4.contains("+") && !v4.contains("*") && !v4.contains(".") {
                failures.append("format: v4 should use ternary . + * glyphs")
            }
            if v4.contains("●") || v4.contains("·") || v4.contains("○") {
                failures.append("format: v4 body must not use Unicode binary glyphs")
            }
            if v4.contains("# === terminal paper preview") {
                failures.append("format: v4 must omit terminal paper preview section")
            }
            let r4 = try deserialize(Data(v4.utf8))
            if r4.data != Data(text.utf8) {
                failures.append("format: v4 payload round-trip mismatch")
            }
            if r4.packing != .ternaryFull {
                failures.append("format: v4 packing not restored")
            }
            if r4.integrity?.allOK != true {
                failures.append("format: v4 integrity should verify OK")
            }
            // Density: ternary columns should be ≤ binary columns for same payload
            if r4.columns.count > doc.columns.count {
                failures.append(
                    "format: v4 columns (\(r4.columns.count)) should not exceed binary (\(doc.columns.count))"
                )
            }
        } catch {
            failures.append("format: \(error.localizedDescription)")
        }

        // Ternary pack/unpack unit tests (highest density full base-6561)
        do {
            let payloads: [Data] = [
                Data(),
                Data([0x00]),
                Data([0xFF]),
                Data([0x00, 0x01, 0x02]),
                Data((0..<256).map { UInt8($0) }),
                Data(repeating: 0x00, count: 64),
                Data(repeating: 0xA5, count: 1_000),
            ]
            for (i, p) in payloads.enumerated() {
                let digs = packTernaryFull(p)
                let back = unpackTernaryFull(digs, byteCount: p.count)
                if back != p {
                    failures.append("ternary full pack round-trip fail #\(i) (len \(p.count))")
                }
                let b3 = packTernaryBlock3(p)
                let back3 = unpackTernaryBlock3(b3, byteCount: p.count)
                if back3 != p {
                    failures.append("ternary block3 pack round-trip fail #\(i) (len \(p.count))")
                }
            }
            // Full pack denser than binary; block3 near full for large payloads
            let big = Data((0..<10_000).map { UInt8(truncatingIfNeeded: $0) })
            let fullCols = packTernaryFull(big).count
            let block3Cols = packTernaryBlock3(big).count
            if fullCols >= big.count {
                failures.append("ternary full: expected fewer columns than bytes (\(fullCols) vs \(big.count))")
            }
            if fullCols > block3Cols {
                failures.append("ternary full should be ≤ block3 columns (\(fullCols) > \(block3Cols))")
            }
            // Theoretical: ~0.631 columns/byte → ~6309 for 10k; allow slack
            if fullCols > 6_400 {
                failures.append("ternary full density worse than expected (\(fullCols) cols for 10k bytes)")
            }
            // Chunked full pack (large-file path) round-trip
            let large = Data((0..<80_000).map { UInt8(truncatingIfNeeded: $0 &* 3 &+ 1) })
            let chunk = preferredTernaryPackChunk(byteCount: large.count)
            if chunk <= 0 {
                failures.append("ternary: 80KB should use chunked pack-chunk > 0")
            } else {
                let digs = packTernary(large, mode: .ternaryFull, chunkBytes: chunk)
                let back = unpackTernary(digs, mode: .ternaryFull, byteCount: large.count, chunkBytes: chunk)
                if back != large {
                    failures.append("ternary chunked full pack round-trip fail (80KB)")
                }
                if digs.count >= large.count {
                    failures.append("ternary chunked should still beat binary columns")
                }
            }
            // File encode path: serialize v4 of large-ish payload must finish and round-trip
            do {
                let mid = Data(repeating: 0x5A, count: 100_000)
                let doc = encode(data: mid, originalName: "mid.bin", compression: .none)
                let t0 = Date()
                let file = serialize(doc, fileFormat: .v4)
                let elapsed = Date().timeIntervalSince(t0)
                if elapsed > 2.0 {
                    failures.append("ternary serialize 100KB took \(String(format: "%.2f", elapsed))s (should be <<1s with chunking)")
                }
                let round = try deserialize(file)
                if round.data != mid {
                    failures.append("ternary serialize/deserialize 100KB mismatch")
                }
            } catch {
                failures.append("ternary large serialize: \(error.localizedDescription)")
            }
            // Trit value bounds
            for v: UInt16 in [0, 1, 2, 100, 6560] {
                let t = trits(fromTernaryValue: v)
                if ternaryValue(fromTrits: t) != v {
                    failures.append("trit value round-trip fail for \(v)")
                }
            }
            let tok = ternaryVisualToken(value: 100)
            if parseTernaryToken(tok) == nil {
                failures.append("ternary token parse failed: \(tok)")
            }
            // All-zero payloads (whole pack + chunked) must survive full file round-trip
            for n in [1, 2, 8, 64, 1_000, 30_000] {
                let zeros = Data(repeating: 0x00, count: n)
                let zDoc = encode(data: zeros, originalName: "zeros.bin", compression: .none)
                do {
                    let zFile = serialize(zDoc, fileFormat: .v4)
                    let zText = String(data: zFile, encoding: .utf8) ?? ""
                    if zText.contains("# (empty tape)"), n > 0 {
                        failures.append("ternary zeros n=\(n): must not write empty body")
                    }
                    let zRound = try deserialize(zFile)
                    if zRound.data != zeros {
                        failures.append("ternary zeros n=\(n): payload mismatch (got \(zRound.data.count) bytes)")
                    }
                    if zRound.packedByteCount != n {
                        failures.append("ternary zeros n=\(n): packedByteCount \(zRound.packedByteCount)")
                    }
                } catch {
                    failures.append("ternary zeros n=\(n): \(error.localizedDescription)")
                }
            }
            // Suggested filenames
            if suggestedTapeFilename(stem: "notes", format: .v4) != "notes-v4.Tape" {
                failures.append("filename: notes-v4.Tape")
            }
            if suggestedTapeFilename(stem: "notes-v3", format: .v4) != "notes-v4.Tape" {
                failures.append("filename: should replace prior -vN suffix")
            }
            if suggestedTapeFilename(stem: "notes-v4", format: .v1) != "notes-v1.Tape" {
                failures.append("filename: v1 suffix")
            }
            // Cross-format: v4 → reopen → v3
            do {
                let payload = Data("cross-format check".utf8)
                let d = encode(data: payload, originalName: "x.bin", compression: .none)
                let v4data = serialize(d, fileFormat: .v4)
                let fromV4 = try deserialize(v4data)
                let v3data = serialize(fromV4, fileFormat: .v3)
                let fromV3 = try deserialize(v3data)
                if fromV3.data != payload {
                    failures.append("cross-format v4→v3 payload mismatch")
                }
            } catch {
                failures.append("cross-format: \(error.localizedDescription)")
            }
            // Terminal art for dense formats must include restored UTF-8 text
            do {
                let msg = "The Matrix has you!"
                let d = encodeText(msg, originalName: "neo.txt", compression: .none)
                let v4doc = try deserialize(serialize(d, fileFormat: .v4))
                let art = terminalPaper(for: v4doc)
                if !art.contains(msg) || art.contains("text: ") {
                    failures.append("terminal art v4: missing message line (got: \(art.suffix(80)))")
                }
                if v4doc.textUTF8 != msg {
                    failures.append("terminal art v4: textUTF8 mismatch")
                }
                let v5doc = try deserialize(serialize(d, fileFormat: .v5))
                let art5 = terminalPaper(for: v5doc)
                if !art5.contains(msg) {
                    failures.append("terminal art v5: missing message (got: \(art5.suffix(80)))")
                }
                if v5doc.packing != .quaternary {
                    failures.append("v5 packing not restored")
                }
                // Binary art still has per-column legend
                let v3doc = try deserialize(serialize(d, fileFormat: .v3))
                let art3 = terminalPaper(for: v3doc)
                if !art3.contains("M") || art3.contains("text: ") {
                    failures.append("terminal art v3: expected per-column legend, not text: line")
                }
            } catch {
                failures.append("terminal art: \(error.localizedDescription)")
            }
            // Quaternary pack: 2 bytes/col, exact round-trip
            do {
                for n in [0, 1, 2, 3, 19, 64, 1000, 10_001] {
                    let p = Data((0..<n).map { UInt8(truncatingIfNeeded: $0 &* 3) })
                    let vals = packQuaternary(p)
                    let back = unpackQuaternary(vals, byteCount: n)
                    if back != p {
                        failures.append("quat pack round-trip fail n=\(n)")
                    }
                    let expectedCols = n == 0 ? 0 : (n + 1) / 2
                    if vals.count != expectedCols {
                        failures.append("quat cols n=\(n): \(vals.count) vs \(expectedCols)")
                    }
                }
                let msg = Data("Hello quaternary v5!".utf8)
                let doc = encode(data: msg, originalName: "q.txt", compression: .none)
                let file = serialize(doc, fileFormat: .v5)
                let text = String(data: file, encoding: .utf8) ?? ""
                if !text.hasPrefix("# PaperTape File v5") {
                    failures.append("v5 header missing")
                }
                if !text.contains("# packing: quat") || !text.contains("# columns: quaternary") {
                    failures.append("v5 packing/columns headers")
                }
                if text.contains("●") || text.contains("·") {
                    failures.append("v5 body must be ASCII glyphs")
                }
                let round = try deserialize(file)
                if round.data != msg {
                    failures.append("v5 document round-trip mismatch")
                }
                if round.integrity?.allOK != true {
                    failures.append("v5 integrity fail")
                }
                // Denser than binary
                if round.columns.count > msg.count {
                    failures.append("v5 should have ≤ binary columns")
                }
                // Denser or equal to ternary for this short string
                let t4 = try deserialize(serialize(doc, fileFormat: .v4))
                if round.columns.count > t4.columns.count + 2 {
                    // allow small variance; 2B/col vs ~0.63 cols/byte
                    failures.append("v5 denser expected vs v4? v5=\(round.columns.count) v4=\(t4.columns.count)")
                }
            } catch {
                failures.append("quat: \(error.localizedDescription)")
            }
            if suggestedTapeFilename(stem: "a", format: .v5) != "a-v5.Tape" {
                failures.append("filename v5")
            }
            // Octal pack: 3 bytes/col, exact round-trip (v6 densest)
            do {
                for n in [0, 1, 2, 3, 4, 5, 19, 64, 999, 10_002] {
                    let p = Data((0..<n).map { UInt8(truncatingIfNeeded: $0 &* 7 &+ 1) })
                    let vals = packOctal(p)
                    let back = unpackOctal(vals, byteCount: n)
                    if back != p {
                        failures.append("oct pack round-trip fail n=\(n)")
                    }
                    let expectedCols = n == 0 ? 0 : (n + 2) / 3
                    if vals.count != expectedCols {
                        failures.append("oct cols n=\(n): \(vals.count) vs \(expectedCols)")
                    }
                }
                let msg = Data("Hello octal v6 packing!".utf8)
                let doc = encode(data: msg, originalName: "o.txt", compression: .none)
                let file = serialize(doc, fileFormat: .v6)
                let text = String(data: file, encoding: .utf8) ?? ""
                if !text.hasPrefix("# PaperTape File v6") {
                    failures.append("v6 header missing")
                }
                if !text.contains("# packing: oct") || !text.contains("# columns: octal") {
                    failures.append("v6 packing/columns headers")
                }
                if text.contains("●") || text.contains("·") {
                    failures.append("v6 body must be ASCII glyphs")
                }
                let round = try deserialize(file)
                if round.data != msg {
                    failures.append("v6 document round-trip mismatch")
                }
                if round.packing != .octal {
                    failures.append("v6 packing not restored")
                }
                if round.integrity?.allOK != true {
                    failures.append("v6 integrity fail")
                }
                if round.columns.count > (msg.count + 2) / 3 + 1 {
                    failures.append("v6 column count too high: \(round.columns.count) for \(msg.count) B")
                }
                let v5 = try deserialize(serialize(doc, fileFormat: .v5))
                if round.columns.count > v5.columns.count {
                    failures.append("v6 denser expected vs v5? v6=\(round.columns.count) v5=\(v5.columns.count)")
                }
                let art6 = terminalPaper(for: round)
                if !art6.contains("Hello octal") {
                    failures.append("terminal art v6: missing message")
                }
            } catch {
                failures.append("oct: \(error.localizedDescription)")
            }
            if suggestedTapeFilename(stem: "a", format: .v6) != "a-v6.Tape" {
                failures.append("filename v6")
            }
            // Hexadecimal pack: 4 bytes/col, exact round-trip (v7 densest)
            do {
                for n in [0, 1, 2, 3, 4, 5, 7, 19, 64, 999, 10_003] {
                    let p = Data((0..<n).map { UInt8(truncatingIfNeeded: $0 &* 11 &+ 3) })
                    let vals = packHexadecimal(p)
                    let back = unpackHexadecimal(vals, byteCount: n)
                    if back != p {
                        failures.append("hex pack round-trip fail n=\(n)")
                    }
                    let expectedCols = n == 0 ? 0 : (n + 3) / 4
                    if vals.count != expectedCols {
                        failures.append("hex cols n=\(n): \(vals.count) vs \(expectedCols)")
                    }
                }
                let msg = Data("Hello hexadecimal v7 packing!".utf8)
                let doc = encode(data: msg, originalName: "h.txt", compression: .none)
                let file = serialize(doc, fileFormat: .v7)
                let text = String(data: file, encoding: .utf8) ?? ""
                if !text.hasPrefix("# PaperTape File v7") {
                    failures.append("v7 header missing")
                }
                if !text.contains("# packing: hex") || !text.contains("# columns: hexadecimal") {
                    failures.append("v7 packing/columns headers")
                }
                if text.contains("●") || text.contains("·") {
                    failures.append("v7 body must be ASCII glyphs")
                }
                let round = try deserialize(file)
                if round.data != msg {
                    failures.append("v7 document round-trip mismatch")
                }
                if round.packing != .hexadecimal {
                    failures.append("v7 packing not restored")
                }
                if round.integrity?.allOK != true {
                    failures.append("v7 integrity fail")
                }
                let v6 = try deserialize(serialize(doc, fileFormat: .v6))
                if round.columns.count > v6.columns.count {
                    failures.append("v7 denser expected vs v6? v7=\(round.columns.count) v6=\(v6.columns.count)")
                }
                let art7 = terminalPaper(for: round)
                if !art7.contains("Hello hexadecimal") {
                    failures.append("terminal art v7: missing message")
                }
            } catch {
                failures.append("hex: \(error.localizedDescription)")
            }
            if suggestedTapeFilename(stem: "a", format: .v7) != "a-v7.Tape" {
                failures.append("filename v7")
            }
            // Base-256 pack: 8 bytes/col, exact round-trip (v8 densest)
            do {
                for n in [0, 1, 2, 7, 8, 9, 19, 64, 999, 10_007] {
                    let p = Data((0..<n).map { UInt8(truncatingIfNeeded: $0 &* 13 &+ 5) })
                    let cols = packBase256(p)
                    let back = unpackBase256(cols, byteCount: n)
                    if back != p {
                        failures.append("b256 pack round-trip fail n=\(n)")
                    }
                    let expectedCols = n == 0 ? 0 : (n + 7) / 8
                    if cols.count != expectedCols {
                        failures.append("b256 cols n=\(n): \(cols.count) vs \(expectedCols)")
                    }
                }
                let msg = Data("Hello base-256 v8 packing!!".utf8)
                let doc = encode(data: msg, originalName: "b.txt", compression: .none)
                let file = serialize(doc, fileFormat: .v8)
                let text = String(data: file, encoding: .utf8) ?? ""
                if !text.hasPrefix("# PaperTape File v8") {
                    failures.append("v8 header missing")
                }
                if !text.contains("# packing: b256") || !text.contains("# columns: base256") {
                    failures.append("v8 packing/columns headers")
                }
                // Tokens should be hex pairs + o, not single-char multilevel
                if !text.contains("o") {
                    failures.append("v8 body missing feed glyph")
                }
                let round = try deserialize(file)
                if round.data != msg {
                    failures.append("v8 document round-trip mismatch")
                }
                if round.packing != .base256 {
                    failures.append("v8 packing not restored")
                }
                if round.integrity?.allOK != true {
                    failures.append("v8 integrity fail")
                }
                let v7 = try deserialize(serialize(doc, fileFormat: .v7))
                if round.columns.count > v7.columns.count {
                    failures.append("v8 denser expected vs v7? v8=\(round.columns.count) v7=\(v7.columns.count)")
                }
                let tok = base256VisualToken(bytes: [0xA3, 0xF2, 0x01, 0x00, 0xFF, 0xC8, 0x00, 0x11])
                if tok != "a3f201o00ffc80011" {
                    // a3 f2 01 o 00 ff c8 00 11
                    failures.append("b256 token format: \(tok)")
                }
            } catch {
                failures.append("b256: \(error.localizedDescription)")
            }
            if suggestedTapeFilename(stem: "a", format: .v8) != "a-v8.Tape" {
                failures.append("filename v8")
            }
            if TapeFileFormat.defaultWrite != .v7 {
                failures.append("default write should be v7")
            }
        }

        // Integrity: clean round-trip + single-block corruption (no cascade false positives).
        do {
            let payload = Data((0..<200).map { UInt8($0 & 0xFF) })
            let doc = encode(data: payload, originalName: "int.bin", compression: .none)
            var file = String(data: serialize(doc, fileFormat: .v1), encoding: .utf8)!
            guard file.contains("# @block"), file.contains("crc32=") else {
                failures.append("integrity: missing @block markers in serialize")
                throw FormatError.missingPayload
            }
            let good = try deserialize(Data(file.utf8))
            if good.integrity?.allOK != true {
                failures.append("integrity: clean file should verify OK (\(good.integrity?.summary ?? "?"))")
            }
            if (good.integrity?.blocks.count ?? 0) < 2 {
                failures.append("integrity: expected multiple blocks for 200-byte payload")
            }
            // Corrupt one data column after the first @block section only.
            guard let sep = file.range(of: "# ---\n") else {
                failures.append("integrity: missing payload separator")
                throw FormatError.invalidHeader
            }
            let body = String(file[sep.upperBound...])
            var corrupted = false
            var bodyLines = body.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
            var dataLinesSeen = 0
            for i in bodyLines.indices {
                let line = bodyLines[i]
                if line.hasPrefix("#") { continue }
                dataLinesSeen += 1
                // Flip a hole in the second block (~column 70)
                if dataLinesSeen > 70, let r = line.range(of: String(holeGlyph)) {
                    bodyLines[i] = line.replacingCharacters(in: r, with: String(blankGlyph))
                    corrupted = true
                    break
                }
            }
            if !corrupted {
                failures.append("integrity: could not find a data hole to flip")
            } else {
                let head = String(file[..<sep.upperBound])
                file = head + bodyLines.joined(separator: "\n")
                let bad = try deserialize(Data(file.utf8))
                let failed = bad.integrity?.failedBlocks ?? []
                if failed.isEmpty {
                    failures.append("integrity: corrupted file should fail a block (\(bad.integrity?.summary ?? ""))")
                } else if failed.count > 3 {
                    // Cascade false-positive guard: one flipped hole should not fail most blocks
                    failures.append("integrity: cascade? \(failed.count) blocks failed (expected ~1)")
                }
            }
        } catch {
            failures.append("integrity: \(error.localizedDescription)")
        }

        // Large-ish raw text integrity (catches sequential marker bugs)
        do {
            let big = String(repeating: "The quick brown fox jumps over the lazy dog. ", count: 100)
            let doc = encodeText(big, originalName: "fox.txt", compression: .none)
            let round = try deserialize(serialize(doc))
            if round.integrity?.allOK != true {
                failures.append("integrity large text: \(round.integrity?.summary ?? "nil")")
            }
            if round.data != Data(big.utf8) {
                failures.append("integrity large text: payload mismatch")
            }
        } catch {
            failures.append("integrity large text: \(error.localizedDescription)")
        }

        // Channel bit mapping: byte 0x01 → only channel 1 punched
        let c1 = Column(id: 0, byte: 0x01)
        if c1.holes != [true, false, false, false, false, false, false, false] {
            failures.append("LSB mapping wrong")
        }
        let c8 = Column(id: 0, byte: 0x80)
        if c8.holes != [false, false, false, false, false, false, false, true] {
            failures.append("MSB mapping wrong")
        }

        // Folder archive + per-file compression round-trip
        do {
            let tmpRoot = FileManager.default.temporaryDirectory
                .appendingPathComponent("PaperTapeSelfTest-\(UUID().uuidString)", isDirectory: true)
            let extractRoot = FileManager.default.temporaryDirectory
                .appendingPathComponent("PaperTapeSelfTestOut-\(UUID().uuidString)", isDirectory: true)
            defer {
                try? FileManager.default.removeItem(at: tmpRoot)
                try? FileManager.default.removeItem(at: extractRoot)
            }
            try FileManager.default.createDirectory(at: tmpRoot, withIntermediateDirectories: true)
            let a = String(repeating: "Hello paper tape folder. ", count: 80) // ~2KB compressible
            let b = String(repeating: "Another file with repeated text. ", count: 60)
            try Data(a.utf8).write(to: tmpRoot.appendingPathComponent("a.txt"))
            try FileManager.default.createDirectory(
                at: tmpRoot.appendingPathComponent("sub", isDirectory: true),
                withIntermediateDirectories: true
            )
            try Data(b.utf8).write(to: tmpRoot.appendingPathComponent("sub/b.txt"))

            let tapeURL = FileManager.default.temporaryDirectory
                .appendingPathComponent("PaperTapeSelfTest-\(UUID().uuidString).Tape")
            defer { try? FileManager.default.removeItem(at: tapeURL) }

            // Fake .app package — must be included (previously skipped via skipsPackageDescendants).
            let appMacOS = tmpRoot
                .appendingPathComponent("Demo.app/Contents/MacOS", isDirectory: true)
            try FileManager.default.createDirectory(at: appMacOS, withIntermediateDirectories: true)
            try Data("#!/bin/sh\necho demo\n".utf8)
                .write(to: appMacOS.appendingPathComponent("Demo"))
            try Data("stub".utf8)
                .write(to: tmpRoot.appendingPathComponent("Demo.app/Contents/Info.plist"))
            // Hidden build tree must still be skipped.
            let buildDir = tmpRoot.appendingPathComponent(".build", isDirectory: true)
            try FileManager.default.createDirectory(at: buildDir, withIntermediateDirectories: true)
            try Data("junk".utf8).write(to: buildDir.appendingPathComponent("artifact.o"))

            let packed = try encodeFolder(
                root: tmpRoot,
                to: tapeURL,
                compression: .auto,
                transfer: .identity
            )
            // a.txt, sub/b.txt, Demo.app/Contents/MacOS/Demo, Demo.app/Contents/Info.plist
            if packed.files != 4 {
                failures.append("archive: expected 4 files (incl. .app), got \(packed.files)")
            }
            let listed = try listFolderFiles(root: tmpRoot).map(\.relativePath)
            if !listed.contains(where: { $0.contains("Demo.app/") }) {
                failures.append("archive: .app package contents missing from listing")
            }
            if listed.contains(where: { $0.contains(".build") }) {
                failures.append("archive: .build should be skipped")
            }
            if packed.compressedFiles < 1 {
                failures.append("archive: expected at least one compressed member (got \(packed.compressedFiles))")
            }
            if packed.columns >= packed.originalBytes {
                failures.append(
                    "archive: columns (\(packed.columns)) should be < original (\(packed.originalBytes)) with Auto"
                )
            }
            let tapeText = String(data: try Data(contentsOf: tapeURL, options: [.mappedIfSafe]), encoding: .utf8) ?? ""
            if !tapeText.contains("compression=lzfse")
                && !tapeText.contains("compression=zlib")
                && !tapeText.contains("compression=lz4")
                && !tapeText.contains("compression=lzma") {
                failures.append("archive: @file lines missing a concrete compression= codec")
            }
            if !tapeText.contains("# compression: per-file") {
                failures.append("archive: expected per-file compression header")
            }

            // Opening an archive for display must not pretend to be a single blob payload.
            let display = try loadForDisplay(from: tapeURL)
            if !display.isArchive {
                failures.append("archive display: expected containerMode archive")
            }
            if (try? display.restoredData()) != nil {
                failures.append("archive display: restoredData() must throw (not a single blob)")
            }

            let extracted = try extractFolder(from: tapeURL, to: extractRoot)
            if extracted.files != 4 {
                failures.append("archive extract: expected 4 files, got \(extracted.files)")
            }
            let aOut = try String(contentsOf: extractRoot.appendingPathComponent("a.txt"), encoding: .utf8)
            let bOut = try String(contentsOf: extractRoot.appendingPathComponent("sub/b.txt"), encoding: .utf8)
            if aOut != a { failures.append("archive extract: a.txt mismatch") }
            if bOut != b { failures.append("archive extract: sub/b.txt mismatch") }
            let appBin = extractRoot.appendingPathComponent("Demo.app/Contents/MacOS/Demo")
            if !FileManager.default.fileExists(atPath: appBin.path) {
                failures.append("archive extract: Demo.app binary missing")
            }
            if FileManager.default.fileExists(atPath: extractRoot.appendingPathComponent(".build/artifact.o").path) {
                failures.append("archive extract: .build should not have been packed")
            }
            // v4 archives should record pack-chunk on @file lines for durable unpack.
            if tapeText.contains("# columns: ternary") || tapeText.contains("# packing: full") {
                if !tapeText.contains("pack-chunk=") {
                    failures.append("archive: v4 @file lines should include pack-chunk=")
                }
            }
        } catch {
            failures.append("archive: \(error.localizedDescription)")
        }

        // Stream writer block3 ternary: encode via TapeStreamWriter, restore via decodeFileStreaming
        do {
            let tmp = FileManager.default.temporaryDirectory
                .appendingPathComponent("PaperTapeStream-\(UUID().uuidString).Tape")
            let outURL = FileManager.default.temporaryDirectory
                .appendingPathComponent("PaperTapeStreamOut-\(UUID().uuidString).bin")
            defer {
                try? FileManager.default.removeItem(at: tmp)
                try? FileManager.default.removeItem(at: outURL)
            }
            // Non-multiple of 3 to exercise partial last group
            let payload = Data((0..<10_001).map { UInt8(truncatingIfNeeded: $0) })
            let writer = try TapeStreamWriter(
                writingTo: tmp,
                originalName: "stream.bin",
                originalSize: Int64(payload.count),
                mode: "stream",
                fileFormat: .v4
            )
            // Write in uneven deterministic chunks (exercise leftover 0–2 bytes)
            let chunkSizes = [1, 2, 3, 7, 64, 1000, 4096]
            var offset = 0
            var step = 0
            while offset < payload.count {
                let n = min(chunkSizes[step % chunkSizes.count], payload.count - offset)
                try writer.writePayload(payload.subdata(in: offset..<(offset + n)))
                offset += n
                step += 1
            }
            let cols = try writer.finish()
            if cols <= 0 {
                failures.append("stream v4: expected ternary columns")
            }
            let head = String(data: try Data(contentsOf: tmp).prefix(400), encoding: .utf8) ?? ""
            if !head.contains("# packing: block3") {
                failures.append("stream v4: expected packing block3 in header")
            }
            let decoded = try decodeFileStreaming(from: tmp, to: outURL)
            let restored = try Data(contentsOf: outURL)
            if restored != payload {
                failures.append(
                    "stream v4 block3 round-trip mismatch (got \(restored.count), want \(payload.count))"
                )
            }
            if decoded.bytes != Int64(payload.count) {
                failures.append("stream v4: decode byte count \(decoded.bytes)")
            }
            // Full deserialize path must also restore (header punched-size)
            let fullDoc = try deserialize(try Data(contentsOf: tmp))
            if fullDoc.data != payload {
                failures.append(
                    "stream v4 full deserialize mismatch (\(fullDoc.data.count) vs \(payload.count), packed=\(fullDoc.packedByteCount))"
                )
            }
        } catch {
            failures.append("stream v4: \(error.localizedDescription)")
        }

        // Stream writer dense formats: non-multiple lengths and trailer punched-size.
        for fmt in [TapeFileFormat.v5, .v6, .v7, .v8, .v9] {
            do {
                let tmp = FileManager.default.temporaryDirectory
                    .appendingPathComponent("PaperTapeStream\(fmt.shortName)-\(UUID().uuidString).Tape")
                let outURL = FileManager.default.temporaryDirectory
                    .appendingPathComponent("PaperTapeStream\(fmt.shortName)Out-\(UUID().uuidString).bin")
                defer {
                    try? FileManager.default.removeItem(at: tmp)
                    try? FileManager.default.removeItem(at: outURL)
                }
                // 10001: odd for quat; 10001 % 3 == 2 for octal remainder
                let payload = Data((0..<10_001).map { UInt8(truncatingIfNeeded: $0 &* 3) })
                let writer = try TapeStreamWriter(
                    writingTo: tmp,
                    originalName: "stream-\(fmt.shortName).bin",
                    originalSize: Int64(payload.count),
                    mode: "stream",
                    fileFormat: fmt
                )
                var offset = 0
                var step = 0
                let chunkSizes = [1, 2, 3, 5, 17, 100, 2048]
                while offset < payload.count {
                    let n = min(chunkSizes[step % chunkSizes.count], payload.count - offset)
                    try writer.writePayload(payload.subdata(in: offset..<(offset + n)))
                    offset += n
                    step += 1
                }
                _ = try writer.finish()
                let head = String(data: try Data(contentsOf: tmp).prefix(500), encoding: .utf8) ?? ""
                let expectPack: String
                switch fmt {
                case .v5: expectPack = "quat"
                case .v6: expectPack = "oct"
                case .v7: expectPack = "hex"
                case .v8: expectPack = "b256"
                case .v9: expectPack = "b512"
                default: expectPack = "?"
                }
                if !head.contains("# packing: \(expectPack)") {
                    failures.append("stream \(fmt.shortName): expected packing \(expectPack)")
                }
                let decoded = try decodeFileStreaming(from: tmp, to: outURL)
                let restored = try Data(contentsOf: outURL)
                if restored != payload {
                    failures.append(
                        "stream \(fmt.shortName) round-trip mismatch (got \(restored.count), want \(payload.count))"
                    )
                }
                if decoded.bytes != Int64(payload.count) {
                    failures.append("stream \(fmt.shortName): decode bytes \(decoded.bytes)")
                }
                let fullDoc = try deserialize(try Data(contentsOf: tmp))
                if fullDoc.data != payload {
                    failures.append("stream \(fmt.shortName) full deserialize mismatch")
                }
            } catch {
                failures.append("stream \(fmt.shortName): \(error.localizedDescription)")
            }
        }

        // Unknown-size stream: header punched-size unknown; trailer only — must trim pad.
        for fmt in [TapeFileFormat.v4, .v5, .v6, .v7, .v8, .v9] {
            do {
                let tmp = FileManager.default.temporaryDirectory
                    .appendingPathComponent("PaperTapeUnk\(fmt.shortName)-\(UUID().uuidString).Tape")
                let outURL = FileManager.default.temporaryDirectory
                    .appendingPathComponent("PaperTapeUnk\(fmt.shortName)Out-\(UUID().uuidString).bin")
                defer {
                    try? FileManager.default.removeItem(at: tmp)
                    try? FileManager.default.removeItem(at: outURL)
                }
                // Force remainder pad for each dense width.
                let n: Int
                switch fmt {
                case .v8: n = 1_007 // %8 = 7
                case .v7: n = 1_005 // %4 = 1
                case .v6: n = 1_004 // %3 = 2
                case .v5: n = 1_003 // odd
                default: n = 1_001 // block3 remainder
                }
                let payload = Data((0..<n).map { UInt8(truncatingIfNeeded: $0 &* 5) })
                let writer = try TapeStreamWriter(
                    writingTo: tmp,
                    originalName: "unk.bin",
                    originalSize: nil, // forces size/punched-size: unknown in header
                    mode: "stream",
                    fileFormat: fmt
                )
                try writer.writePayload(payload)
                _ = try writer.finish()
                let text = String(data: try Data(contentsOf: tmp), encoding: .utf8) ?? ""
                if !text.contains("# punched-size: unknown") {
                    failures.append("stream unk \(fmt.shortName): expected unknown header size")
                }
                if !text.contains("# punched-size: \(n)") {
                    failures.append("stream unk \(fmt.shortName): expected trailer punched-size \(n)")
                }
                let decoded = try decodeFileStreaming(from: tmp, to: outURL)
                let restored = try Data(contentsOf: outURL)
                if restored != payload {
                    failures.append(
                        "stream unk \(fmt.shortName) pad-trim fail (got \(restored.count), want \(n))"
                    )
                }
                if decoded.bytes != Int64(n) {
                    failures.append("stream unk \(fmt.shortName): bytes \(decoded.bytes)")
                }
            } catch {
                failures.append("stream unk \(fmt.shortName): \(error.localizedDescription)")
            }
        }

        // Chunked full pack + stream decode (pack-chunk > 0)
        do {
            let tmp = FileManager.default.temporaryDirectory
                .appendingPathComponent("PaperTapeChunk-\(UUID().uuidString).Tape")
            let outURL = FileManager.default.temporaryDirectory
                .appendingPathComponent("PaperTapeChunkOut-\(UUID().uuidString).bin")
            defer {
                try? FileManager.default.removeItem(at: tmp)
                try? FileManager.default.removeItem(at: outURL)
            }
            let payload = Data((0..<50_000).map { UInt8(truncatingIfNeeded: $0 &* 7) })
            let doc = encode(data: payload, originalName: "chunked.bin", compression: .none)
            try serialize(doc, fileFormat: .v4).write(to: tmp, options: .atomic)
            let text = String(data: try Data(contentsOf: tmp).prefix(500), encoding: .utf8) ?? ""
            if !text.contains("# pack-chunk: 4096") {
                failures.append("chunked full: expected pack-chunk 4096 header")
            }
            // Stream-oriented restore (does not map whole file into TapeDocument columns)
            let decoded = try decodeFileStreaming(from: tmp, to: outURL)
            let restored = try Data(contentsOf: outURL)
            if restored != payload {
                failures.append("chunked full stream-decode mismatch (\(restored.count) vs \(payload.count))")
            }
            if decoded.bytes != Int64(payload.count) {
                failures.append("chunked full: byte count \(decoded.bytes)")
            }
        } catch {
            failures.append("chunked full stream: \(error.localizedDescription)")
        }

        // decompress size mismatch must not silently truncate
        do {
            let payload = Data(repeating: 0x41, count: 2_000)
            let doc = encode(data: payload, originalName: "sz.bin", compression: .lzfse)
            guard doc.isCompressed else {
                failures.append("size-check: expected LZFSE to compress 2KB of A's")
                throw FormatError.io("skip")
            }
            // Force wrong expected size through decompress API
            do {
                _ = try decompress(doc.punchedData, kind: doc.compression, expectedSize: 100)
                failures.append("size-check: decompress should throw on size mismatch")
            } catch {
                // expected
            }
        } catch {
            if "\(error)".contains("skip") == false {
                failures.append("size-check: \(error.localizedDescription)")
            }
        }

        failures.append(contentsOf: base512SelfTest())
        if failures.isEmpty {
            return "Self-test passed (text, unicode, empty, compression, Base85, integrity, v4–v9 packing, stream, folder archive)."
        }
        return "Self-test FAILED:\n" + failures.joined(separator: "\n")
    }

    // MARK: - Helpers

    private static func sanitizeName(_ name: String) -> String {
        sanitizeHeaderValue(name).isEmpty ? "untitled" : sanitizeHeaderValue(name)
    }

    static func sanitizeHeaderValue(_ value: String) -> String {
        value
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\r", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
