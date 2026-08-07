import Foundation
import ObjectiveC

// MARK: - Streaming thresholds

extension TapeEngine {
    /// Payloads at or above this size use streaming I/O (no full in-memory column array).
    static let streamingByteThreshold = 4 * 1024 * 1024 // 4 MiB
    /// Max files walked in a folder encode (safety).
    static let archiveMaxFiles = 50_000
    /// Directory / file basenames skipped when packing folders (and their descendants).
    /// Hidden items (`.build`, `.git`, …) are also skipped via `skipsHiddenFiles`.
    /// **Not** skipped: app bundles and other packages (`.app`, `.framework`, …) —
    /// those are part of the tree and must be fully archived.
    static let archiveSkipNames: Set<String> = [
        ".DS_Store", "Thumbs.db", ".git", ".svn", ".hg",
        "node_modules", ".build", "DerivedData", "__pycache__", ".swiftpm",
    ]
}

// MARK: - Progress

struct TapeProgress: Sendable {
    var phase: String
    var unitsCompleted: Int64
    var unitsTotal: Int64?

    var fraction: Double? {
        guard let total = unitsTotal, total > 0 else { return nil }
        return min(1, Double(unitsCompleted) / Double(total))
    }
}

// MARK: - Stream writer (large files → .Tape on disk)

/// Writes a `.Tape` file incrementally: header once, then payload bytes as columns
/// with `# @block` integrity markers. Does not keep the full column array in RAM.
///
/// Dense stream packing: **v4** block3 … **v7** hex … **v8** base-256 (8 B → 1 col).
/// All stay O(1) memory for multi-GB files.
final class TapeStreamWriter {
    private let handle: FileHandle
    private let blockSize: Int
    private let annotateColumns: Bool
    private var blockBuffer = Data()
    /// Dense column values (ternary/quat fit in low 16 bits; octal 24-bit; hex full UInt32).
    private var denseValues: [UInt32] = []
    /// Base-256 columns (8 channel bytes each).
    private var base256Values: [[UInt8]] = []
    private var blockIndex = 0
    private var columnOffset = 0
    private var totalColumns: Int64 = 0
    private var totalBinaryBytes: Int64 = 0
    private var closed = false
    private let useTernary: Bool
    private let useQuaternary: Bool
    private let useOctal: Bool
    private let useHexadecimal: Bool
    private let useBase256: Bool
    private let packing: TapeEngine.PackingMode
    private let style: TapeEngine.GlyphStyle

    let originalName: String
    let originalSize: Int64?
    let compression: TapeEngine.CompressionKind
    let transfer: TapeEngine.TransferEncoding
    let fileFormat: TapeEngine.TapeFileFormat

    /// Creates the file, writes the header, and prepares for `writePayload` calls.
    /// - Note: Streaming path uses **raw** payload on the strip (compression/Base85
    ///   require the full buffer; pass preferences for header honesty / small-file path).
    init(
        writingTo url: URL,
        originalName: String,
        originalSize: Int64?,
        mode: String = "stream",
        compression: TapeEngine.CompressionKind = .none,
        transfer: TapeEngine.TransferEncoding = .identity,
        blockSize: Int = TapeEngine.defaultBlockSize,
        fileFormat: TapeEngine.TapeFileFormat = .defaultWrite,
        extraHeaderLines: [String] = []
    ) throws {
        if FileManager.default.fileExists(atPath: url.path) {
            try FileManager.default.removeItem(at: url)
        }
        FileManager.default.createFile(atPath: url.path, contents: nil)
        guard let handle = try? FileHandle(forWritingTo: url) else {
            throw TapeEngine.FormatError.io("Could not open \(url.lastPathComponent) for writing")
        }
        self.handle = handle
        self.blockSize = max(1, blockSize)
        self.fileFormat = fileFormat
        self.annotateColumns = fileFormat.includesColumnAnnotations
        self.originalName = originalName
        self.originalSize = originalSize
        // Stream path cannot whole-file compress; record none so restore matches punched bytes.
        self.compression = .none
        self.transfer = .identity
        self.useTernary = fileFormat.usesTernaryPacking
        self.useQuaternary = fileFormat.usesQuaternaryPacking
        self.useOctal = fileFormat.usesOctalPacking
        self.useHexadecimal = fileFormat.usesHexadecimalPacking
        self.useBase256 = fileFormat.usesBase256Packing
        if useBase256 {
            self.packing = .base256
        } else if useHexadecimal {
            self.packing = .hexadecimal
        } else if useOctal {
            self.packing = .octal
        } else if useQuaternary {
            self.packing = .quaternary
        } else if useTernary {
            self.packing = .ternaryBlock3
        } else {
            self.packing = .binary
        }
        self.style = TapeEngine.GlyphStyle.forFormat(fileFormat)

        let glyphStyle = style
        var headerLines = [
            "# PaperTape File v\(fileFormat.rawValue)",
            "# name: \(TapeEngine.sanitizeHeaderValue(originalName))",
            "# size: \(originalSize.map(String.init) ?? "unknown")",
            // Authoritative punched length when known (deserialize / dense unpack need this
            // in the header — trailer-only values are ignored by headered parsers).
            "# punched-size: \(originalSize.map(String.init) ?? "unknown")",
            "# mode: \(mode)",
            "# compression: none",
            "# transfer: identity",
            "# block-size: \(self.blockSize)",
            "# integrity: crc32+xor+sum8",
            "# columns: \(fileFormat.columnsHeaderValue)",
            "# channels: \(TapeEngine.channelCount)",
            "# bit-order: channel-1-lsb",
            "# layout: ch1 ch2 ch3 feed ch4 ch5 ch6 ch7 ch8",
            "# glyphs: \(glyphStyle.headerDescription)",
            "# stream: 1",
        ]
        if useTernary {
            headerLines.append("# packing: \(packing.rawValue)")
            headerLines.append("# packing-base: \(TapeEngine.ternaryBase)")
            headerLines.append("# channel-states: 3")
            headerLines.append("# pack-chunk: 0")
        } else if useQuaternary {
            headerLines.append("# packing: \(packing.rawValue)")
            headerLines.append("# packing-base: \(TapeEngine.quaternaryBase)")
            headerLines.append("# channel-states: 4")
            headerLines.append("# pack-chunk: 0")
        } else if useOctal {
            headerLines.append("# packing: \(packing.rawValue)")
            headerLines.append("# packing-base: \(TapeEngine.octalBase)")
            headerLines.append("# channel-states: 8")
            headerLines.append("# pack-chunk: 0")
        } else if useHexadecimal {
            headerLines.append("# packing: \(packing.rawValue)")
            headerLines.append("# packing-base: \(TapeEngine.hexadecimalBase)")
            headerLines.append("# channel-states: 16")
            headerLines.append("# pack-chunk: 0")
        } else if useBase256 {
            headerLines.append("# packing: \(packing.rawValue)")
            headerLines.append("# packing-base: 18446744073709551616")
            headerLines.append("# channel-states: 256")
            headerLines.append("# pack-chunk: 0")
        }
        for line in extraHeaderLines {
            headerLines.append("# \(line)")
        }
        if compression != .none && compression != .auto {
            headerLines.append("# note: preferred-compress=\(compression.rawValue) (not applied in stream mode)")
        } else if compression == .auto {
            headerLines.append("# note: stream mode uses raw payload (full-file compress skipped for large I/O)")
        }
        if transfer == .ascii85 {
            headerLines.append("# note: preferred-transfer=ascii85 (not applied in stream mode)")
        }
        if useTernary {
            headerLines.append("# note: stream packing=block3 (full base-6561 used for in-memory saves)")
        } else if useQuaternary {
            headerLines.append("# note: stream packing=quat (2 bytes per column)")
        } else if useOctal {
            headerLines.append("# note: stream packing=oct (3 bytes per column)")
        } else if useHexadecimal {
            headerLines.append("# note: stream packing=hex (4 bytes per column)")
        } else if useBase256 {
            headerLines.append("# note: stream packing=b256 (8 bytes per column; hex-pair tokens)")
        }
        headerLines.append("# ---")
        headerLines.append("")
        try handle.write(contentsOf: Data(headerLines.joined(separator: "\n").utf8))
        _ = compression
        _ = transfer
    }

    /// Append raw payload bytes.
    func writePayload(_ data: Data, cancel: TapeEngine.EncodeCancelToken? = nil) throws {
        guard !closed else {
            throw TapeEngine.FormatError.io("TapeStreamWriter is already finished")
        }
        guard !data.isEmpty else { return }
        totalBinaryBytes += Int64(data.count)

        if useTernary {
            // Keep 0–2 leftover bytes so block3 groups stay aligned.
            blockBuffer.append(data)
            while blockBuffer.count >= 3 {
                try cancel?.throwIfCancelled()
                let take = (blockBuffer.count / 3) * 3
                let chunkEnd = min(take, 3 * blockSize)
                let slice = Data(blockBuffer.prefix(chunkEnd))
                blockBuffer.removeFirst(chunkEnd)
                let vals = TapeEngine.packTernaryBlock3(slice).map { UInt32($0) }
                denseValues.append(contentsOf: vals)
                while denseValues.count >= blockSize {
                    try flushDenseBlock(count: blockSize)
                }
            }
            return
        }

        if useQuaternary {
            // 2 bytes → 1 column; keep 0–1 leftover byte.
            blockBuffer.append(data)
            while blockBuffer.count >= 2 {
                try cancel?.throwIfCancelled()
                let take = (blockBuffer.count / 2) * 2
                let chunkEnd = min(take, 2 * blockSize)
                let slice = Data(blockBuffer.prefix(chunkEnd))
                blockBuffer.removeFirst(chunkEnd)
                denseValues.append(contentsOf: TapeEngine.packQuaternary(slice).map { UInt32($0) })
                while denseValues.count >= blockSize {
                    try flushDenseBlock(count: blockSize)
                }
            }
            return
        }

        if useOctal {
            // 3 bytes → 1 column; keep 0–2 leftover bytes.
            blockBuffer.append(data)
            while blockBuffer.count >= 3 {
                try cancel?.throwIfCancelled()
                let take = (blockBuffer.count / 3) * 3
                let chunkEnd = min(take, 3 * blockSize)
                let slice = Data(blockBuffer.prefix(chunkEnd))
                blockBuffer.removeFirst(chunkEnd)
                denseValues.append(contentsOf: TapeEngine.packOctal(slice))
                while denseValues.count >= blockSize {
                    try flushDenseBlock(count: blockSize)
                }
            }
            return
        }

        if useHexadecimal {
            // 4 bytes → 1 column; keep 0–3 leftover bytes.
            blockBuffer.append(data)
            while blockBuffer.count >= 4 {
                try cancel?.throwIfCancelled()
                let take = (blockBuffer.count / 4) * 4
                let chunkEnd = min(take, 4 * blockSize)
                let slice = Data(blockBuffer.prefix(chunkEnd))
                blockBuffer.removeFirst(chunkEnd)
                denseValues.append(contentsOf: TapeEngine.packHexadecimal(slice))
                while denseValues.count >= blockSize {
                    try flushDenseBlock(count: blockSize)
                }
            }
            return
        }

        if useBase256 {
            // 8 bytes → 1 column; keep 0–7 leftover bytes.
            blockBuffer.append(data)
            while blockBuffer.count >= 8 {
                try cancel?.throwIfCancelled()
                let take = (blockBuffer.count / 8) * 8
                let chunkEnd = min(take, 8 * blockSize)
                let slice = Data(blockBuffer.prefix(chunkEnd))
                blockBuffer.removeFirst(chunkEnd)
                base256Values.append(contentsOf: TapeEngine.packBase256(slice))
                while base256Values.count >= blockSize {
                    try flushBase256Block(count: blockSize)
                }
            }
            return
        }

        var idx = data.startIndex
        while idx < data.endIndex {
            try cancel?.throwIfCancelled()
            let space = blockSize - blockBuffer.count
            let end = data.index(idx, offsetBy: min(space, data.distance(from: idx, to: data.endIndex)))
            blockBuffer.append(data[idx..<end])
            idx = end
            if blockBuffer.count >= blockSize {
                try flushBinaryBlock()
            }
        }
    }

    /// Finish last partial block, write punched-size footer notes, close handle.
    @discardableResult
    func finish() throws -> Int64 {
        guard !closed else { return totalColumns }
        if useTernary {
            if !blockBuffer.isEmpty {
                denseValues.append(contentsOf: TapeEngine.packTernaryBlock3(blockBuffer).map { UInt32($0) })
                blockBuffer.removeAll()
            }
            while !denseValues.isEmpty {
                try flushDenseBlock(count: min(blockSize, denseValues.count))
            }
        } else if useQuaternary {
            if !blockBuffer.isEmpty {
                denseValues.append(contentsOf: TapeEngine.packQuaternary(blockBuffer).map { UInt32($0) })
                blockBuffer.removeAll()
            }
            while !denseValues.isEmpty {
                try flushDenseBlock(count: min(blockSize, denseValues.count))
            }
        } else if useOctal {
            if !blockBuffer.isEmpty {
                denseValues.append(contentsOf: TapeEngine.packOctal(blockBuffer))
                blockBuffer.removeAll()
            }
            while !denseValues.isEmpty {
                try flushDenseBlock(count: min(blockSize, denseValues.count))
            }
        } else if useHexadecimal {
            if !blockBuffer.isEmpty {
                denseValues.append(contentsOf: TapeEngine.packHexadecimal(blockBuffer))
                blockBuffer.removeAll()
            }
            while !denseValues.isEmpty {
                try flushDenseBlock(count: min(blockSize, denseValues.count))
            }
        } else if useBase256 {
            if !blockBuffer.isEmpty {
                base256Values.append(contentsOf: TapeEngine.packBase256(blockBuffer))
                blockBuffer.removeAll()
            }
            while !base256Values.isEmpty {
                try flushBase256Block(count: min(blockSize, base256Values.count))
            }
        } else if !blockBuffer.isEmpty {
            try flushBinaryBlock()
        }
        // Append a short trailer (comments only).
        var trailer = """

        # === stream complete ===
        # punched-size: \(totalBinaryBytes)
        # blocks: \(blockIndex)

        """
        if useTernary {
            trailer += "# ternary-columns: \(totalColumns)\n# packing: \(packing.rawValue)\n"
        } else if useQuaternary {
            trailer += "# quaternary-columns: \(totalColumns)\n# packing: \(packing.rawValue)\n"
        } else if useOctal {
            trailer += "# octal-columns: \(totalColumns)\n# packing: \(packing.rawValue)\n"
        } else if useHexadecimal {
            trailer += "# hexadecimal-columns: \(totalColumns)\n# packing: \(packing.rawValue)\n"
        } else if useBase256 {
            trailer += "# base256-columns: \(totalColumns)\n# packing: \(packing.rawValue)\n"
        }
        try handle.write(contentsOf: Data(trailer.utf8))
        try handle.close()
        closed = true
        return totalColumns
    }

    deinit {
        if !closed {
            try? handle.close()
        }
    }

    private func flushBinaryBlock() throws {
        guard !blockBuffer.isEmpty else { return }
        let slice = blockBuffer
        let len = slice.count
        let crc = TapeEngine.crc32(slice)
        let xor = TapeEngine.xorParity(slice)
        let sum = TapeEngine.sum8(slice)
        var text = "# @block \(blockIndex) off=\(columnOffset) len=\(len) crc32=\(String(format: "%08X", crc)) xor=\(String(format: "%02X", xor)) sum8=\(String(format: "%02X", sum))\n"
        for byte in slice {
            let col = TapeEngine.Column(id: 0, byte: byte)
            text += TapeEngine.columnLine(for: col, annotate: annotateColumns, style: style) + "\n"
        }
        try handle.write(contentsOf: Data(text.utf8))
        columnOffset += len
        totalColumns += Int64(len)
        blockIndex += 1
        blockBuffer.removeAll(keepingCapacity: true)
    }

    private func flushBase256Block(count: Int) throws {
        guard count > 0, base256Values.count >= count else { return }
        let vals = Array(base256Values.prefix(count))
        base256Values.removeFirst(count)
        let cols = vals.map { TapeEngine.Column(id: 0, base256Bytes: $0) }
        let slice = TapeEngine.integrityData(for: cols)
        let crc = TapeEngine.crc32(slice)
        let xor = TapeEngine.xorParity(slice)
        let sum = TapeEngine.sum8(slice)
        var text = "# @block \(blockIndex) off=\(columnOffset) len=\(count) crc32=\(String(format: "%08X", crc)) xor=\(String(format: "%02X", xor)) sum8=\(String(format: "%02X", sum))\n"
        for col in cols {
            text += TapeEngine.columnLine(for: col, annotate: false, style: style) + "\n"
        }
        try handle.write(contentsOf: Data(text.utf8))
        columnOffset += count
        totalColumns += Int64(count)
        blockIndex += 1
    }

    private func flushDenseBlock(count: Int) throws {
        guard count > 0, denseValues.count >= count else { return }
        let vals = Array(denseValues.prefix(count))
        denseValues.removeFirst(count)
        let cols: [TapeEngine.Column]
        if useHexadecimal {
            cols = vals.map { TapeEngine.Column(id: 0, hexadecimalValue: $0) }
        } else if useOctal {
            cols = vals.map { TapeEngine.Column(id: 0, octalValue: $0) }
        } else if useQuaternary {
            cols = vals.map { TapeEngine.Column(id: 0, quaternaryValue: UInt16(truncatingIfNeeded: $0)) }
        } else {
            cols = vals.map { TapeEngine.Column(id: 0, ternaryValue: UInt16(truncatingIfNeeded: $0)) }
        }
        let slice = TapeEngine.integrityData(for: cols)
        let crc = TapeEngine.crc32(slice)
        let xor = TapeEngine.xorParity(slice)
        let sum = TapeEngine.sum8(slice)
        var text = "# @block \(blockIndex) off=\(columnOffset) len=\(count) crc32=\(String(format: "%08X", crc)) xor=\(String(format: "%02X", xor)) sum8=\(String(format: "%02X", sum))\n"
        for col in cols {
            text += TapeEngine.columnLine(for: col, annotate: false, style: style) + "\n"
        }
        try handle.write(contentsOf: Data(text.utf8))
        columnOffset += count
        totalColumns += Int64(count)
        blockIndex += 1
    }
}

// MARK: - Stream / archive reader (line-oriented)

/// Reads a `.Tape` file line-by-line without loading the whole document into memory.
final class TapeStreamReader {
    private let handle: FileHandle
    private var leftover = Data()
    private var headerDone = false

    private(set) var headerName = "decoded.bin"
    private(set) var headerSize: Int64?
    private(set) var mode = "blob"
    private(set) var blockSize = TapeEngine.defaultBlockSize
    private(set) var compression = TapeEngine.CompressionKind.none
    private(set) var transfer = TapeEngine.TransferEncoding.identity
    private(set) var isStream = false
    private(set) var packing = TapeEngine.PackingMode.binary
    private(set) var packChunk = 0
    private(set) var punchedSize: Int64?

    /// Integrity failures discovered while reading.
    private(set) var failedBlocks: [TapeEngine.IntegrityBlock] = []
    private(set) var blocksChecked = 0

    /// Accumulated dense digits when packing requires whole-payload unpack (full only).
    /// Ternary/quat store UInt16 values in the low half; octal uses full 24-bit values.
    private var ternaryDigits: [UInt32] = []
    private var currentBlockValues: [UInt32] = []
    /// Base-256 columns buffered for stream decode.
    private var base256Digits: [[UInt8]] = []
    private var currentBlockBase256: [[UInt8]] = []
    /// Odd leftover ternary block3 digit carried across integrity blocks.
    private var block3CarryDigit: UInt32?
    /// Binary bytes emitted so far for dense stream unpack (for punched-size truncate).
    private var ternaryBinaryEmitted: Int64 = 0

    init(reading url: URL) throws {
        let accessed = url.startAccessingSecurityScopedResource()
        do {
            handle = try FileHandle(forReadingFrom: url)
        } catch {
            if accessed { url.stopAccessingSecurityScopedResource() }
            throw error
        }
        if accessed {
            // Store as NSURL — deinit must cast the same type (URL cast of NSURL often fails).
            objc_setAssociatedObject(
                handle,
                &TapeStreamReader.assocKey,
                url as NSURL,
                .OBJC_ASSOCIATION_RETAIN
            )
        }
    }

    deinit {
        try? handle.close()
        if let nsurl = objc_getAssociatedObject(handle, &TapeStreamReader.assocKey) as? NSURL {
            (nsurl as URL).stopAccessingSecurityScopedResource()
        }
    }

    private static var assocKey: UInt8 = 0

    /// Parse header lines until `# ---`. Call before `readPayload` / archive members.
    func readHeader() throws {
        guard !headerDone else { return }
        while let line = try readLine() {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed == "# ---" || trimmed == "---" || trimmed.hasPrefix("# ---") {
                headerDone = true
                return
            }
            if trimmed.hasPrefix("# name:") {
                headerName = String(trimmed.dropFirst("# name:".count)).trimmingCharacters(in: .whitespaces)
            } else if trimmed.hasPrefix("# size:") {
                let s = String(trimmed.dropFirst("# size:".count)).trimmingCharacters(in: .whitespaces)
                headerSize = Int64(s)
            } else if trimmed.hasPrefix("# mode:") {
                mode = String(trimmed.dropFirst("# mode:".count)).trimmingCharacters(in: .whitespaces)
            } else if trimmed.hasPrefix("# block-size:") {
                blockSize = Int(String(trimmed.dropFirst("# block-size:".count)).trimmingCharacters(in: .whitespaces))
                    ?? TapeEngine.defaultBlockSize
            } else if trimmed.hasPrefix("# compression:") {
                compression = TapeEngine.CompressionKind.parse(
                    String(trimmed.dropFirst("# compression:".count))
                )
            } else if trimmed.hasPrefix("# transfer:") {
                transfer = TapeEngine.TransferEncoding.parse(
                    String(trimmed.dropFirst("# transfer:".count))
                )
            } else if trimmed.hasPrefix("# stream:") {
                let v = String(trimmed.dropFirst("# stream:".count)).trimmingCharacters(in: .whitespaces)
                isStream = (v == "1" || v.lowercased() == "true")
            } else if trimmed.hasPrefix("# packing:") {
                packing = TapeEngine.PackingMode.parse(
                    String(trimmed.dropFirst("# packing:".count))
                )
            } else if trimmed.hasPrefix("# pack-chunk:") {
                packChunk = Int(String(trimmed.dropFirst("# pack-chunk:".count)).trimmingCharacters(in: .whitespaces)) ?? 0
            } else if trimmed.hasPrefix("# punched-size:") {
                let raw = String(trimmed.dropFirst("# punched-size:".count))
                    .trimmingCharacters(in: .whitespaces)
                if let n = Int64(raw), n >= 0 {
                    punchedSize = n
                }
            } else if trimmed.hasPrefix("# columns:") {
                let c = String(trimmed.dropFirst("# columns:".count)).trimmingCharacters(in: .whitespaces).lowercased()
                if c == "base256" || c == "b256", packing == .binary { packing = .base256 }
                if c == "hexadecimal" || c == "hex", packing == .binary { packing = .hexadecimal }
                if c == "octal", packing == .binary { packing = .octal }
                if c == "quaternary", packing == .binary { packing = .quaternary }
                if c == "ternary", packing == .binary { packing = .ternaryFull }
            } else if trimmed.hasPrefix("# PaperTape File v") {
                let vStr = trimmed.replacingOccurrences(of: "# PaperTape File v", with: "")
                let ver = Int(vStr.trimmingCharacters(in: .whitespaces)) ?? 0
                if packing == .binary {
                    if ver >= 8 { packing = .base256 }
                    else if ver >= 7 { packing = .hexadecimal }
                    else if ver >= 6 { packing = .octal }
                    else if ver >= 5 { packing = .quaternary }
                    else if ver >= 4 { packing = .ternaryFull }
                }
            }
        }
        headerDone = true
    }

    /// Read next payload event from the body.
    enum Event {
        /// Raw punched bytes of a complete integrity block (verified).
        case data(Data)
        /// Start of an archive member.
        case fileBegin(path: String, size: Int64?)
        /// End of current archive member (optional).
        case fileEnd
        case end
    }

    private var currentBlockStored: (crc: UInt32, xor: UInt8, sum: UInt8, len: Int)?
    private var currentBlockBytes = Data()
    private var eof = false

    /// Positive punched/size limits only — `0` means “unknown / do not cap”, not “empty”.
    private var denseByteLimit: Int64? {
        if let p = punchedSize, p > 0 { return p }
        if let s = headerSize, s > 0 { return s }
        return nil
    }

    /// Pull the next event. For simple streams, yields `.data` chunks (per integrity block).
    func nextEvent() throws -> Event {
        try readHeader()
        if eof { return .end }

        while let line = try readLine() {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            // Stream/archive trailers may carry authoritative punched-size after the body.
            if trimmed.hasPrefix("# punched-size:") {
                let raw = String(trimmed.dropFirst("# punched-size:".count))
                    .trimmingCharacters(in: .whitespaces)
                if let n = Int64(raw), n >= 0 {
                    punchedSize = n
                }
                continue
            }
            if trimmed.hasPrefix("# ===") {
                try flushCurrentBlockIfNeeded()
                // If flush produced pending data, return it first (re-hit trailer after).
                if let pending = takePendingData() {
                    pushBack(line)
                    return .data(pending)
                }
                // Drain trailer comments first so punched-size is known before residual unpack.
                var trailerLines: [String] = []
                while let more = try readLine() {
                    trailerLines.append(more)
                    let t = more.trimmingCharacters(in: .whitespaces)
                    if t.hasPrefix("# punched-size:") {
                        let raw = String(t.dropFirst("# punched-size:".count))
                            .trimmingCharacters(in: .whitespaces)
                        if let n = Int64(raw), n >= 0 {
                            punchedSize = n
                        }
                    }
                }
                // Ternary full residual (whole or remaining chunked digits) after size is known.
                if packing == .ternaryFull, !ternaryDigits.isEmpty {
                    let count = Int(denseByteLimit ?? 0)
                    let remain = count > 0
                        ? max(0, count - Int(ternaryBinaryEmitted))
                        : 0
                    // Without a byte limit, refuse digit-count-as-bytes (wrong for full pack).
                    if remain > 0 {
                        let digits16 = ternaryDigits.map { UInt16(truncatingIfNeeded: $0) }
                        let unpacked = TapeEngine.unpackTernary(
                            digits16,
                            mode: packing,
                            byteCount: remain,
                            chunkBytes: packChunk > 0 ? packChunk : 0
                        )
                        ternaryDigits = []
                        ternaryBinaryEmitted += Int64(unpacked.count)
                        if !unpacked.isEmpty {
                            // Re-queue synthetic EOF so next call returns .end after this data.
                            pushBack("# === residual complete ===")
                            return .data(unpacked)
                        }
                    } else {
                        ternaryDigits = []
                    }
                }
                // Odd block3 carry: pair with zero digit under limit (best-effort).
                if packing == .ternaryBlock3, let carry = block3CarryDigit {
                    block3CarryDigit = nil
                    let limit = denseByteLimit
                    if limit == nil || ternaryBinaryEmitted < (limit ?? 0) {
                        let d0 = Int(carry)
                        let v = d0 // d1 = 0
                        var triple = [
                            UInt8((v >> 16) & 0xFF),
                            UInt8((v >> 8) & 0xFF),
                            UInt8(v & 0xFF),
                        ]
                        if let lim = limit {
                            let room = Int(lim - ternaryBinaryEmitted)
                            if room > 0 {
                                if triple.count > room { triple = Array(triple.prefix(room)) }
                                ternaryBinaryEmitted += Int64(triple.count)
                                pushBack("# === residual complete ===")
                                return .data(Data(triple))
                            }
                        } else {
                            ternaryBinaryEmitted += Int64(triple.count)
                            pushBack("# === residual complete ===")
                            return .data(Data(triple))
                        }
                    }
                }
                _ = trailerLines
                eof = true
                return .end
            }
            if trimmed.isEmpty { continue }

            if trimmed.hasPrefix("# @file") {
                try flushCurrentBlockIfNeeded()
                if let pending = takePendingData() {
                    // Re-queue this line conceptually by prepending — simpler: process file after flush
                    // Store the line for re-entry
                    pushBack(line)
                    return .data(pending)
                }
                let meta = Self.parseFileMarker(trimmed)
                return .fileBegin(path: meta.path, size: meta.size)
            }

            if trimmed.hasPrefix("# @block") {
                try flushCurrentBlockIfNeeded()
                if let pending = takePendingData() {
                    pushBack(line)
                    return .data(pending)
                }
                if let meta = TapeEngine.parseBlockMarker(trimmed) {
                    currentBlockStored = (meta.crc, meta.xor, meta.sum, meta.len)
                    currentBlockBytes = Data()
                    currentBlockBytes.reserveCapacity(max(meta.len, blockSize))
                    currentBlockValues = []
                    currentBlockValues.reserveCapacity(max(meta.len, blockSize))
                    currentBlockBase256 = []
                    currentBlockBase256.reserveCapacity(max(meta.len, blockSize))
                }
                continue
            }

            if trimmed.hasPrefix("# @endfile") {
                try flushCurrentBlockIfNeeded()
                if let pending = takePendingData() {
                    pushBack(line)
                    return .data(pending)
                }
                return .fileEnd
            }

            if trimmed.hasPrefix("#") {
                continue
            }

            // Column line
            let tokenPart = trimmed.split(separator: "#", maxSplits: 1)
                .first
                .map(String.init)?
                .trimmingCharacters(in: .whitespaces) ?? trimmed
            if packing.isMultistate {
                let preferQ = packing.isQuaternary
                let preferO = packing.isOctal
                let preferH = packing.isHexadecimal
                let preferB = packing.isBase256
                guard let col = TapeEngine.parseColumnToken(
                    tokenPart,
                    preferTernary: packing.isTernary,
                    preferQuaternary: preferQ,
                    preferOctal: preferO,
                    preferHexadecimal: preferH,
                    preferBase256: preferB
                ) else { continue }
                if preferB {
                    currentBlockBase256.append(col.base256Bytes)
                } else if preferH {
                    currentBlockValues.append(col.hexadecimalValue)
                } else if preferO {
                    currentBlockValues.append(col.octalValue)
                } else if preferQ {
                    currentBlockValues.append(UInt32(col.quaternaryValue))
                } else {
                    currentBlockValues.append(UInt32(col.ternaryValue))
                }
                // Integrity length counts columns
                let blockCount = preferB ? currentBlockBase256.count : currentBlockValues.count
                if let stored = currentBlockStored, stored.len > 0, blockCount >= stored.len {
                    try flushCurrentBlockIfNeeded()
                    if let pending = takePendingData() {
                        return .data(pending)
                    }
                }
            } else {
                guard let holes = TapeEngine.parseVisualToken(tokenPart) else { continue }
                let col = TapeEngine.Column(id: 0, holes: holes)
                currentBlockBytes.append(col.byte)

                if let stored = currentBlockStored, stored.len > 0, currentBlockBytes.count >= stored.len {
                    try flushCurrentBlockIfNeeded()
                    if let pending = takePendingData() {
                        return .data(pending)
                    }
                }
            }
        }

        try flushCurrentBlockIfNeeded()
        // Whole-integer full pack (pack-chunk 0): unpack once we have every digit.
        // Chunked full pack should already have flushed via fixed-width emission.
        if packing == .ternaryFull, !ternaryDigits.isEmpty {
            let count = Int(denseByteLimit ?? 0)
            // Never treat digit count as binary length (same rule as `# ===` residual).
            let remain = count > 0
                ? max(0, count - Int(ternaryBinaryEmitted))
                : 0
            if remain > 0 {
                let digits16 = ternaryDigits.map { UInt16(truncatingIfNeeded: $0) }
                let unpacked = TapeEngine.unpackTernary(
                    digits16,
                    mode: packing,
                    byteCount: remain,
                    chunkBytes: packChunk > 0 ? packChunk : 0
                )
                ternaryDigits = []
                ternaryBinaryEmitted += Int64(unpacked.count)
                return .data(unpacked)
            }
            ternaryDigits = []
        }
        // Octal / quaternary / block3 may have pending bytes; trim to punched-size if known.
        if packing == .base256 || packing == .hexadecimal || packing == .octal
            || packing == .quaternary || packing == .ternaryBlock3,
           let pending = takePendingData() {
            if let lim = denseByteLimit, ternaryBinaryEmitted > lim {
                let over = Int(ternaryBinaryEmitted - lim)
                let keep = max(0, pending.count - over)
                return .data(Data(pending.prefix(keep)))
            }
            return .data(pending)
        }
        if let pending = takePendingData() {
            return .data(pending)
        }
        eof = true
        return .end
    }

    /// Read all remaining payload as concatenated punched bytes (for modest streams).
    func readAllPayloadBytes(progress: ((TapeProgress) -> Void)? = nil) throws -> Data {
        var out = Data()
        var completed: Int64 = 0
        while true {
            switch try nextEvent() {
            case .data(let chunk):
                out.append(chunk)
                completed += Int64(chunk.count)
                progress?(TapeProgress(phase: "Reading", unitsCompleted: completed, unitsTotal: headerSize))
            case .fileBegin, .fileEnd:
                continue
            case .end:
                return out
            }
        }
    }

    // MARK: - Line I/O

    private var pushBackLine: String?

    private func pushBack(_ line: String) {
        pushBackLine = line
    }

    /// Cap a *single* incomplete line (not the whole multi-line read-ahead buffer).
    private static let maxLineBytes = 256 * 1024

    private func readLine() throws -> String? {
        if let pb = pushBackLine {
            pushBackLine = nil
            return pb
        }
        // Prefer complete lines even when leftover is large (partial line + next chunk).
        while true {
            if let range = leftover.firstIndex(of: 0x0A) {
                let lineData = leftover[..<range]
                if lineData.count > Self.maxLineBytes {
                    throw TapeEngine.FormatError.io("Line too long in .Tape body (missing newline?)")
                }
                leftover = leftover[leftover.index(after: range)...]
                let raw = lineData.last == 0x0D ? lineData.dropLast() : lineData
                guard let line = String(data: raw, encoding: .utf8) else {
                    throw TapeEngine.FormatError.io("Invalid UTF-8 in .Tape body")
                }
                return line
            }
            // No newline yet: only the incomplete trailing line may grow.
            if leftover.count > Self.maxLineBytes {
                throw TapeEngine.FormatError.io("Line too long in .Tape body (missing newline?)")
            }
            let chunk = try handle.read(upToCount: 64 * 1024) ?? Data()
            if chunk.isEmpty {
                if leftover.isEmpty { return nil }
                defer { leftover = Data() }
                if leftover.count > Self.maxLineBytes {
                    throw TapeEngine.FormatError.io("Line too long in .Tape body (missing newline?)")
                }
                guard let line = String(data: leftover, encoding: .utf8) else {
                    throw TapeEngine.FormatError.io("Invalid UTF-8 in .Tape body")
                }
                return line
            }
            leftover.append(chunk)
        }
    }

    private var pendingData: Data?

    private func takePendingData() -> Data? {
        defer { pendingData = nil }
        return pendingData
    }

    private func flushCurrentBlockIfNeeded() throws {
        if packing.isMultistate {
            if packing.isBase256 {
                guard !currentBlockBase256.isEmpty || currentBlockStored != nil else { return }
                let vals = currentBlockBase256
                if let stored = currentBlockStored {
                    blocksChecked += 1
                    let cols = vals.map { TapeEngine.Column(id: 0, base256Bytes: $0) }
                    let integ = TapeEngine.integrityData(for: cols)
                    let crc = integ.isEmpty ? 0 : TapeEngine.crc32(integ)
                    let xor = integ.isEmpty ? 0 : TapeEngine.xorParity(integ)
                    let sum = integ.isEmpty ? 0 : TapeEngine.sum8(integ)
                    let lengthMismatch = stored.len > 0 && vals.count != stored.len
                    let checksumMismatch = !integ.isEmpty && (crc != stored.crc || xor != stored.xor || sum != stored.sum)
                    if vals.isEmpty || lengthMismatch || checksumMismatch {
                        failedBlocks.append(
                            TapeEngine.IntegrityBlock(
                                index: blocksChecked - 1,
                                offset: 0,
                                length: vals.count,
                                storedCRC32: stored.crc,
                                storedXOR: stored.xor,
                                storedSum8: stored.sum,
                                computedCRC32: vals.isEmpty || lengthMismatch ? stored.crc &+ 1 : crc,
                                computedXOR: vals.isEmpty || lengthMismatch ? stored.xor &+ 1 : xor,
                                computedSum8: vals.isEmpty || lengthMismatch ? stored.sum &+ 1 : sum
                            )
                        )
                    }
                }
                let limit = denseByteLimit
                var emitted = Data()
                for col in vals {
                    if let lim = limit, ternaryBinaryEmitted >= lim { break }
                    // Emit MSB-first (ch8…ch1)
                    var quad = Array(col.reversed())
                    if let lim = limit {
                        let room = Int(lim - ternaryBinaryEmitted)
                        if room <= 0 { break }
                        if quad.count > room { quad = Array(quad.prefix(room)) }
                    }
                    emitted.append(contentsOf: quad)
                    ternaryBinaryEmitted += Int64(quad.count)
                }
                if !emitted.isEmpty {
                    pendingData = (pendingData ?? Data()) + emitted
                }
                currentBlockBase256 = []
                currentBlockStored = nil
                return
            }
            guard !currentBlockValues.isEmpty || currentBlockStored != nil else { return }
            let vals = currentBlockValues
            if let stored = currentBlockStored {
                blocksChecked += 1
                let cols: [TapeEngine.Column]
                if packing.isHexadecimal {
                    cols = vals.map { TapeEngine.Column(id: 0, hexadecimalValue: $0) }
                } else if packing.isOctal {
                    cols = vals.map { TapeEngine.Column(id: 0, octalValue: $0) }
                } else if packing.isQuaternary {
                    cols = vals.map { TapeEngine.Column(id: 0, quaternaryValue: UInt16(truncatingIfNeeded: $0)) }
                } else {
                    cols = vals.map { TapeEngine.Column(id: 0, ternaryValue: UInt16(truncatingIfNeeded: $0)) }
                }
                let integ = TapeEngine.integrityData(for: cols)
                let crc = integ.isEmpty ? 0 : TapeEngine.crc32(integ)
                let xor = integ.isEmpty ? 0 : TapeEngine.xorParity(integ)
                let sum = integ.isEmpty ? 0 : TapeEngine.sum8(integ)
                let lengthMismatch = stored.len > 0 && vals.count != stored.len
                let checksumMismatch = !integ.isEmpty && (crc != stored.crc || xor != stored.xor || sum != stored.sum)
                if vals.isEmpty || lengthMismatch || checksumMismatch {
                    failedBlocks.append(
                        TapeEngine.IntegrityBlock(
                            index: blocksChecked - 1,
                            offset: 0,
                            length: vals.count,
                            storedCRC32: stored.crc,
                            storedXOR: stored.xor,
                            storedSum8: stored.sum,
                            computedCRC32: vals.isEmpty || lengthMismatch ? stored.crc &+ 1 : crc,
                            computedXOR: vals.isEmpty || lengthMismatch ? stored.xor &+ 1 : xor,
                            computedSum8: vals.isEmpty || lengthMismatch ? stored.sum &+ 1 : sum
                        )
                    )
                }
            }
            if packing == .hexadecimal {
                // Stream-decode: each value → up to 4 bytes. O(1) memory.
                let limit = denseByteLimit
                var emitted = Data()
                for v in vals {
                    if let lim = limit, ternaryBinaryEmitted >= lim { break }
                    var quad = [
                        UInt8((v >> 24) & 0xFF),
                        UInt8((v >> 16) & 0xFF),
                        UInt8((v >> 8) & 0xFF),
                        UInt8(v & 0xFF),
                    ]
                    if let lim = limit {
                        let room = Int(lim - ternaryBinaryEmitted)
                        if room <= 0 { break }
                        if quad.count > room { quad = Array(quad.prefix(room)) }
                    }
                    emitted.append(contentsOf: quad)
                    ternaryBinaryEmitted += Int64(quad.count)
                }
                if !emitted.isEmpty {
                    pendingData = (pendingData ?? Data()) + emitted
                }
            } else if packing == .octal {
                // Stream-decode: each value → up to 3 bytes. O(1) memory.
                let limit = denseByteLimit
                var emitted = Data()
                for v in vals {
                    if let lim = limit, ternaryBinaryEmitted >= lim { break }
                    var triple = [
                        UInt8((v >> 16) & 0xFF),
                        UInt8((v >> 8) & 0xFF),
                        UInt8(v & 0xFF),
                    ]
                    if let lim = limit {
                        let room = Int(lim - ternaryBinaryEmitted)
                        if room <= 0 { break }
                        if triple.count > room { triple = Array(triple.prefix(room)) }
                    }
                    emitted.append(contentsOf: triple)
                    ternaryBinaryEmitted += Int64(triple.count)
                }
                if !emitted.isEmpty {
                    pendingData = (pendingData ?? Data()) + emitted
                }
            } else if packing == .quaternary {
                // Stream-decode: each value → up to 2 bytes. O(1) memory.
                let limit = denseByteLimit
                var emitted = Data()
                for v in vals {
                    if let lim = limit, ternaryBinaryEmitted >= lim { break }
                    var pair = [UInt8((v >> 8) & 0xFF), UInt8(v & 0xFF)]
                    if let lim = limit {
                        let room = Int(lim - ternaryBinaryEmitted)
                        if room <= 0 { break }
                        if pair.count > room { pair = Array(pair.prefix(room)) }
                    }
                    emitted.append(contentsOf: pair)
                    ternaryBinaryEmitted += Int64(pair.count)
                }
                if !emitted.isEmpty {
                    pendingData = (pendingData ?? Data()) + emitted
                }
            } else if packing == .ternaryBlock3 {
                // Stream-decode: every 2 digits → up to 3 bytes. O(1) memory.
                // Carry an odd leftover digit across blocks so odd block lengths stay safe.
                let limit = denseByteLimit
                var digits = vals
                if let carry = block3CarryDigit {
                    digits.insert(carry, at: 0)
                    block3CarryDigit = nil
                }
                var i = 0
                var emitted = Data()
                while i + 1 < digits.count {
                    if let lim = limit, ternaryBinaryEmitted >= lim { break }
                    let d0 = Int(digits[i])
                    let d1 = Int(digits[i + 1])
                    i += 2
                    let v = d0 + d1 * TapeEngine.ternaryBase
                    var triple = [
                        UInt8((v >> 16) & 0xFF),
                        UInt8((v >> 8) & 0xFF),
                        UInt8(v & 0xFF),
                    ]
                    if let lim = limit {
                        let room = Int(lim - ternaryBinaryEmitted)
                        if room <= 0 { break }
                        if triple.count > room {
                            triple = Array(triple.prefix(room))
                        }
                    }
                    emitted.append(contentsOf: triple)
                    ternaryBinaryEmitted += Int64(triple.count)
                }
                if i < digits.count {
                    block3CarryDigit = digits[i]
                }
                if !emitted.isEmpty {
                    pendingData = (pendingData ?? Data()) + emitted
                }
            } else if packing == .ternaryFull, packChunk > 0 {
                // Fixed-width chunked full pack: emit each completed binary chunk without
                // buffering the entire digit stream.
                ternaryDigits.append(contentsOf: vals)
                let limit = denseByteLimit
                while true {
                    if let lim = limit, ternaryBinaryEmitted >= lim { break }
                    let remainingBinary: Int
                    if let lim = limit {
                        remainingBinary = Int(lim - ternaryBinaryEmitted)
                    } else {
                        remainingBinary = packChunk
                    }
                    guard remainingBinary > 0 else { break }
                    let thisChunk = min(packChunk, remainingBinary)
                    let digWidth = TapeEngine.ternaryDigitCapacity(byteCount: thisChunk)
                    guard ternaryDigits.count >= digWidth else { break }
                    let slice = Array(ternaryDigits.prefix(digWidth)).map { UInt16(truncatingIfNeeded: $0) }
                    ternaryDigits.removeFirst(digWidth)
                    let piece = TapeEngine.unpackTernaryFull(slice, byteCount: thisChunk)
                    pendingData = (pendingData ?? Data()) + piece
                    ternaryBinaryEmitted += Int64(piece.count)
                }
            } else {
                // Whole-integer full pack: need all digits before unpack
                ternaryDigits.append(contentsOf: vals)
            }
            currentBlockValues = []
            currentBlockStored = nil
            return
        }

        guard !currentBlockBytes.isEmpty || currentBlockStored != nil else { return }
        let bytes = currentBlockBytes
        if let stored = currentBlockStored {
            blocksChecked += 1
            let crc = bytes.isEmpty ? 0 : TapeEngine.crc32(bytes)
            let xor = bytes.isEmpty ? 0 : TapeEngine.xorParity(bytes)
            let sum = bytes.isEmpty ? 0 : TapeEngine.sum8(bytes)
            let lengthMismatch = stored.len > 0 && bytes.count != stored.len
            let checksumMismatch = !bytes.isEmpty && (crc != stored.crc || xor != stored.xor || sum != stored.sum)
            // Empty body under a marker, or length/checksum mismatch → integrity failure.
            if bytes.isEmpty || lengthMismatch || checksumMismatch {
                failedBlocks.append(
                    TapeEngine.IntegrityBlock(
                        index: blocksChecked - 1,
                        offset: 0,
                        length: bytes.count,
                        storedCRC32: stored.crc,
                        storedXOR: stored.xor,
                        storedSum8: stored.sum,
                        computedCRC32: bytes.isEmpty || lengthMismatch ? stored.crc &+ 1 : crc,
                        computedXOR: bytes.isEmpty || lengthMismatch ? stored.xor &+ 1 : xor,
                        computedSum8: bytes.isEmpty || lengthMismatch ? stored.sum &+ 1 : sum
                    )
                )
            }
        }
        if !bytes.isEmpty {
            pendingData = (pendingData ?? Data()) + bytes
        }
        currentBlockBytes = Data()
        currentBlockStored = nil
    }

    fileprivate static func parseFileMarker(_ line: String) -> ArchiveMemberMeta {
        parseFileMarkerPublic(line)
    }

    /// Parsed `# @file path="…" size=… punched=… compression=… transfer=… packing=… pack-chunk=…`
    struct ArchiveMemberMeta: Equatable {
        var path: String
        var size: Int64?
        var punchedSize: Int64?
        var compression: TapeEngine.CompressionKind
        var transfer: TapeEngine.TransferEncoding
        var packing: TapeEngine.PackingMode
        /// Binary chunk size for full packing; nil = derive with preferredTernaryPackChunk.
        var packChunk: Int?
    }

    static func parseFileMarkerPublic(_ line: String) -> ArchiveMemberMeta {
        // # @file path="a/b.txt" size=123 punched=40 compression=lzfse transfer=identity packing=full pack-chunk=0
        var path = "file.bin"
        var size: Int64?
        var punched: Int64?
        var compression = TapeEngine.CompressionKind.none
        var transfer = TapeEngine.TransferEncoding.identity
        var packing = TapeEngine.PackingMode.binary
        var packChunk: Int?

        if let r = line.range(of: "path=\"") {
            let rest = line[r.upperBound...]
            if let end = rest.firstIndex(of: "\"") {
                path = String(rest[..<end])
                    .replacingOccurrences(of: "\\\"", with: "\"")
                    .replacingOccurrences(of: "\\\\", with: "\\")
            }
        } else if let r = line.range(of: "path=") {
            let rest = line[r.upperBound...].split(separator: " ").first.map(String.init) ?? "file.bin"
            path = rest.trimmingCharacters(in: CharacterSet(charactersIn: "\""))
        }
        if let r = line.range(of: "size=") {
            let rest = line[r.upperBound...].split(separator: " ").first.map(String.init) ?? ""
            size = Int64(rest)
        }
        // Accept punched= and punched-size=
        for key in ["punched=", "punched-size="] {
            if let r = line.range(of: key) {
                let rest = line[r.upperBound...].split(separator: " ").first.map(String.init) ?? ""
                punched = Int64(rest)
                break
            }
        }
        if let r = line.range(of: "compression=") {
            let rest = line[r.upperBound...].split(separator: " ").first.map(String.init) ?? "none"
            compression = TapeEngine.CompressionKind.parse(rest)
        }
        if let r = line.range(of: "transfer=") {
            let rest = line[r.upperBound...].split(separator: " ").first.map(String.init) ?? "identity"
            transfer = TapeEngine.TransferEncoding.parse(rest)
        }
        if let r = line.range(of: "packing=") {
            let rest = line[r.upperBound...].split(separator: " ").first.map(String.init) ?? "binary"
            packing = TapeEngine.PackingMode.parse(rest)
        }
        // pack-chunk= and pack_chunk=
        for key in ["pack-chunk=", "pack_chunk="] {
            if let r = line.range(of: key) {
                let rest = line[r.upperBound...].split(separator: " ").first.map(String.init) ?? ""
                packChunk = Int(rest)
                break
            }
        }
        return ArchiveMemberMeta(
            path: path,
            size: size,
            punchedSize: punched,
            compression: compression,
            transfer: transfer,
            packing: packing,
            packChunk: packChunk
        )
    }
}

// MARK: - High-level streaming encode / decode

extension TapeEngine {
    /// Read at most `limit` bytes. `hitLimit` is true when more data remains after the cap
    /// (metadata understated a large file).
    private static func readUpToThreshold(
        from url: URL,
        limit: Int
    ) throws -> (data: Data, hitLimit: Bool) {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var data = Data()
        data.reserveCapacity(min(limit, 1_048_576))
        let chunkSize = 256 * 1024
        while data.count < limit {
            let n = min(chunkSize, limit - data.count)
            let chunk = try handle.read(upToCount: n) ?? Data()
            if chunk.isEmpty { return (data, false) }
            data.append(chunk)
        }
        let peek = try handle.read(upToCount: 1) ?? Data()
        return (data, !peek.isEmpty)
    }

    /// Stream-encode from disk after an understated-size probe (writes prefetched bytes first).
    private static func streamEncodeFromFileHandle(
        source: URL,
        tapeURL: URL,
        name: String,
        compression: CompressionKind,
        transfer: TransferEncoding,
        fileFormat: TapeFileFormat,
        cancel: EncodeCancelToken?,
        progress: ((TapeProgress) -> Void)?,
        prefetched: Data
    ) throws -> (columns: Int64, usedStream: Bool) {
        let writer = try TapeStreamWriter(
            writingTo: tapeURL,
            originalName: name,
            originalSize: nil,
            mode: "stream",
            compression: compression,
            transfer: transfer,
            fileFormat: fileFormat
        )
        do {
            try cancel?.throwIfCancelled()
            if !prefetched.isEmpty {
                try writer.writePayload(prefetched, cancel: cancel)
            }
            let handle = try FileHandle(forReadingFrom: source)
            defer { try? handle.close() }
            // Prefetch already consumed the first `prefetched.count` bytes — skip them.
            try handle.seek(toOffset: UInt64(prefetched.count))
            var completed = Int64(prefetched.count)
            let chunkSize = 256 * 1024
            while true {
                try cancel?.throwIfCancelled()
                let chunk = try handle.read(upToCount: chunkSize) ?? Data()
                if chunk.isEmpty { break }
                try writer.writePayload(chunk, cancel: cancel)
                completed += Int64(chunk.count)
                progress?(TapeProgress(phase: "Streaming", unitsCompleted: completed, unitsTotal: nil))
            }
            let cols = try writer.finish()
            progress?(TapeProgress(phase: "Done", unitsCompleted: completed, unitsTotal: completed))
            return (cols, true)
        } catch {
            try? FileManager.default.removeItem(at: tapeURL)
            throw error
        }
    }

    /// Encode a file to `.Tape` using streaming I/O when large; small files use the in-memory path.
    static func encodeFileStreaming(
        from source: URL,
        to tapeURL: URL,
        compression: CompressionKind = .auto,
        transfer: TransferEncoding = .identity,
        fileFormat: TapeFileFormat = .defaultWrite,
        cancel: EncodeCancelToken? = nil,
        progress: ((TapeProgress) -> Void)? = nil
    ) throws -> (columns: Int64, usedStream: Bool) {
        let accessed = source.startAccessingSecurityScopedResource()
        defer { if accessed { source.stopAccessingSecurityScopedResource() } }

        try cancel?.throwIfCancelled()
        let values = try source.resourceValues(forKeys: [.fileSizeKey, .isDirectoryKey])
        if values.isDirectory == true {
            throw FormatError.io("Use encodeFolder for directories")
        }
        let fileSize = Int64(values.fileSize ?? 0)
        let name = source.lastPathComponent

        // Known small size → full compress / Base85 in memory (cap load if metadata understated).
        if fileSize > 0, fileSize < Int64(streamingByteThreshold) {
            try cancel?.throwIfCancelled()
            let probe = try readUpToThreshold(from: source, limit: streamingByteThreshold)
            if probe.hitLimit {
                // Listing size was wrong — stream the real file from disk (O(1) extra memory).
                return try streamEncodeFromFileHandle(
                    source: source,
                    tapeURL: tapeURL,
                    name: name,
                    compression: compression,
                    transfer: transfer,
                    fileFormat: fileFormat,
                    cancel: cancel,
                    progress: progress,
                    prefetched: probe.data
                )
            }
            let data = probe.data
            try cancel?.throwIfCancelled()
            progress?(TapeProgress(phase: "Encoding", unitsCompleted: 0, unitsTotal: Int64(data.count)))
            let doc = encode(
                data: data,
                originalName: name,
                compression: compression,
                transferEncoding: transfer
            )
            try cancel?.throwIfCancelled()
            progress?(TapeProgress(phase: "Packing columns", unitsCompleted: Int64(data.count / 2), unitsTotal: Int64(data.count)))
            let out = serialize(doc, fileFormat: fileFormat)
            try out.write(to: tapeURL, options: .atomic)
            let writtenCols = columnCountAfterSerialize(
                binaryColumns: doc.columns.count,
                punchedBytes: doc.punchedData.count,
                fileFormat: fileFormat
            )
            progress?(TapeProgress(phase: "Done", unitsCompleted: Int64(data.count), unitsTotal: Int64(data.count)))
            return (writtenCols, false)
        }

        // Unknown size (0): try to load up to the threshold; stream only if truly large.
        if fileSize == 0 {
            let input = try FileHandle(forReadingFrom: source)
            defer { try? input.close() }
            var buffer = Data()
            buffer.reserveCapacity(min(streamingByteThreshold, 1_048_576))
            let chunkSize = 256 * 1024
            var hitThreshold = false
            while buffer.count < streamingByteThreshold {
                try cancel?.throwIfCancelled()
                let chunk = try input.read(upToCount: min(chunkSize, streamingByteThreshold - buffer.count)) ?? Data()
                if chunk.isEmpty { break }
                buffer.append(chunk)
                if buffer.count >= streamingByteThreshold {
                    hitThreshold = true
                    break
                }
            }
            if !hitThreshold {
                // Fits in memory — full compress / Base85 path.
                try cancel?.throwIfCancelled()
                progress?(TapeProgress(phase: "Encoding", unitsCompleted: 0, unitsTotal: Int64(buffer.count)))
                let doc = encode(
                    data: buffer,
                    originalName: name,
                    compression: compression,
                    transferEncoding: transfer
                )
                try cancel?.throwIfCancelled()
                progress?(TapeProgress(phase: "Packing columns", unitsCompleted: Int64(buffer.count / 2), unitsTotal: Int64(buffer.count)))
                let out = serialize(doc, fileFormat: fileFormat)
                try out.write(to: tapeURL, options: .atomic)
                let writtenCols = columnCountAfterSerialize(
                    binaryColumns: doc.columns.count,
                    punchedBytes: doc.punchedData.count,
                    fileFormat: fileFormat
                )
                progress?(TapeProgress(phase: "Done", unitsCompleted: Int64(buffer.count), unitsTotal: Int64(buffer.count)))
                return (writtenCols, false)
            }
            // Large unknown-size file: stream raw, including bytes already buffered.
            let writer = try TapeStreamWriter(
                writingTo: tapeURL,
                originalName: name,
                originalSize: nil,
                mode: "stream",
                compression: compression,
                transfer: transfer,
                fileFormat: fileFormat
            )
            do {
                try writer.writePayload(buffer, cancel: cancel)
                var completed = Int64(buffer.count)
                while true {
                    try cancel?.throwIfCancelled()
                    let chunk = try input.read(upToCount: chunkSize) ?? Data()
                    if chunk.isEmpty { break }
                    try writer.writePayload(chunk, cancel: cancel)
                    completed += Int64(chunk.count)
                    progress?(TapeProgress(phase: "Streaming", unitsCompleted: completed, unitsTotal: nil))
                }
                try cancel?.throwIfCancelled()
                let cols = try writer.finish()
                progress?(TapeProgress(phase: "Done", unitsCompleted: completed, unitsTotal: completed))
                return (cols, true)
            } catch {
                try? FileManager.default.removeItem(at: tapeURL)
                throw error
            }
        }

        // Streaming raw punch (known large size)
        return try streamRawFile(
            from: source,
            to: tapeURL,
            name: name,
            expectedSize: fileSize,
            compression: compression,
            transfer: transfer,
            fileFormat: fileFormat,
            cancel: cancel,
            progress: progress
        )
    }

    /// On-disk column count after serialize (ternary packing may shrink vs binary columns).
    private static func columnCountAfterSerialize(
        binaryColumns: Int,
        punchedBytes: Int,
        fileFormat: TapeFileFormat
    ) -> Int64 {
        if fileFormat.usesBase256Packing, punchedBytes > 0 {
            return Int64((punchedBytes + 7) / 8)
        }
        if fileFormat.usesHexadecimalPacking, punchedBytes > 0 {
            return Int64((punchedBytes + 3) / 4)
        }
        if fileFormat.usesOctalPacking, punchedBytes > 0 {
            return Int64((punchedBytes + 2) / 3)
        }
        if fileFormat.usesQuaternaryPacking, punchedBytes > 0 {
            return Int64((punchedBytes + 1) / 2)
        }
        guard fileFormat.usesTernaryPacking, punchedBytes > 0 else {
            return Int64(binaryColumns)
        }
        let chunk = preferredTernaryPackChunk(byteCount: punchedBytes)
        // Count without re-packing whole payload: capacity formula for chunked, or
        // re-pack only when small enough.
        if chunk <= 0 {
            // Whole pack — digit count is data-dependent; use a quick pack of empty? 
            // For status only: approximate ceil(8n/log2(6561)).
            return Int64(ternaryDigitCapacity(byteCount: punchedBytes))
        }
        var total = 0
        var remaining = punchedBytes
        while remaining > 0 {
            let n = min(chunk, remaining)
            total += ternaryDigitCapacity(byteCount: n)
            remaining -= n
        }
        return Int64(total)
    }

    /// Stream a file as raw punched columns (no whole-file compress / Base85).
    private static func streamRawFile(
        from source: URL,
        to tapeURL: URL,
        name: String,
        expectedSize: Int64?,
        compression: CompressionKind,
        transfer: TransferEncoding,
        fileFormat: TapeFileFormat = .defaultWrite,
        cancel: EncodeCancelToken? = nil,
        progress: ((TapeProgress) -> Void)?
    ) throws -> (columns: Int64, usedStream: Bool) {
        let writer = try TapeStreamWriter(
            writingTo: tapeURL,
            originalName: name,
            originalSize: expectedSize,
            mode: "stream",
            compression: compression,
            transfer: transfer,
            fileFormat: fileFormat
        )
        do {
            let input = try FileHandle(forReadingFrom: source)
            defer { try? input.close() }

            var completed: Int64 = 0
            let chunkSize = 256 * 1024
            while true {
                try cancel?.throwIfCancelled()
                let chunk = try input.read(upToCount: chunkSize) ?? Data()
                if chunk.isEmpty { break }
                try writer.writePayload(chunk, cancel: cancel)
                completed += Int64(chunk.count)
                progress?(TapeProgress(
                    phase: "Streaming",
                    unitsCompleted: completed,
                    unitsTotal: expectedSize
                ))
            }
            try cancel?.throwIfCancelled()
            if let expected = expectedSize, expected > 0, completed != expected {
                try? FileManager.default.removeItem(at: tapeURL)
                throw FormatError.io(
                    "Read \(completed) bytes but expected \(expected) for \(name)"
                )
            }
            let cols = try writer.finish()
            progress?(TapeProgress(phase: "Done", unitsCompleted: completed, unitsTotal: completed))
            return (cols, true)
        } catch {
            try? FileManager.default.removeItem(at: tapeURL)
            throw error
        }
    }

    /// Stream-decode a `.Tape` into a single output file (blob / stream modes).
    static func decodeFileStreaming(
        from tapeURL: URL,
        to outputURL: URL,
        progress: ((TapeProgress) -> Void)? = nil
    ) throws -> (bytes: Int64, integrityOK: Bool, failedBlocks: Int) {
        let reader = try TapeStreamReader(reading: tapeURL)
        try reader.readHeader()

        if reader.mode == "archive" {
            throw FormatError.io("This .Tape is a folder archive — use extractFolder")
        }

        // Compressed / Base85 payloads need full deserialize regardless of stream flag.
        if reader.compression != .none || reader.transfer != .identity {
            let data = try Data(contentsOf: tapeURL, options: [.mappedIfSafe])
            let doc = try deserialize(data)
            let payload = try doc.restoredData()
            try payload.write(to: outputURL, options: .atomic)
            let ok = doc.integrity?.allOK ?? true
            let failed = doc.integrity?.failedBlocks.count ?? 0
            progress?(TapeProgress(phase: "Done", unitsCompleted: Int64(payload.count), unitsTotal: Int64(payload.count)))
            return (Int64(payload.count), ok, failed)
        }

        if FileManager.default.fileExists(atPath: outputURL.path) {
            try FileManager.default.removeItem(at: outputURL)
        }
        FileManager.default.createFile(atPath: outputURL.path, contents: nil)
        do {
            let out = try FileHandle(forWritingTo: outputURL)
            defer { try? out.close() }

            var completed: Int64 = 0
            while true {
                switch try reader.nextEvent() {
                case .data(let chunk):
                    try out.write(contentsOf: chunk)
                    completed += Int64(chunk.count)
                    progress?(TapeProgress(
                        phase: "Writing",
                        unitsCompleted: completed,
                        unitsTotal: reader.headerSize
                    ))
                case .fileBegin, .fileEnd:
                    continue
                case .end:
                    // Trailer may set punched-size after body emit; trim dense remainder pad.
                    if let lim = reader.punchedSize, lim > 0, completed > lim {
                        try out.truncate(atOffset: UInt64(lim))
                        completed = lim
                    } else if let lim = reader.headerSize, lim > 0, completed > lim,
                              reader.punchedSize == nil || (reader.punchedSize ?? 0) <= 0 {
                        try out.truncate(atOffset: UInt64(lim))
                        completed = lim
                    }
                    let ok = reader.failedBlocks.isEmpty
                    return (completed, ok, reader.failedBlocks.count)
                }
            }
        } catch {
            // Do not leave a half-written restore target (matches encode cleanup).
            try? FileManager.default.removeItem(at: outputURL)
            throw error
        }
    }
}

// MARK: - Folder archive

extension TapeEngine {
    struct ArchiveFileEntry: Equatable {
        var relativePath: String
        var byteSize: Int64
    }

    /// Enumerate regular files under `root` with relative POSIX paths.
    ///
    /// Includes package contents (`.app`, `.framework`, …). Skips hidden items
    /// (`.build`, `.git`, …) and known junk names in `archiveSkipNames`.
    /// Symlinks are not followed. Empty directories are not stored (files only).
    static func listFolderFiles(root: URL) throws -> [ArchiveFileEntry] {
        let fm = FileManager.default
        let accessed = root.startAccessingSecurityScopedResource()
        defer { if accessed { root.stopAccessingSecurityScopedResource() } }

        // Do **not** use `.skipsPackageDescendants` — that silently dropped entire
        // app bundles (e.g. Cableform.app) while still packing the source tree.
        guard let enumerator = fm.enumerator(
            at: root,
            includingPropertiesForKeys: [
                .isRegularFileKey, .fileSizeKey, .isDirectoryKey, .isSymbolicLinkKey,
                .isPackageKey,
            ],
            options: [.skipsHiddenFiles]
        ) else {
            throw FormatError.io("Could not read folder \(root.lastPathComponent)")
        }

        var entries: [ArchiveFileEntry] = []
        let rootPath = root.standardizedFileURL.path
        let rootPrefix = rootPath.hasSuffix("/") ? rootPath : rootPath + "/"

        for case let fileURL as URL in enumerator {
            let name = fileURL.lastPathComponent
            if archiveSkipNames.contains(name) {
                // Skip this item and do not walk into it (dirs / packages / junk files).
                enumerator.skipDescendants()
                continue
            }
            let values = try fileURL.resourceValues(
                forKeys: [
                    .isRegularFileKey, .fileSizeKey, .isSymbolicLinkKey,
                    .isDirectoryKey, .isPackageKey,
                ]
            )
            // Do not follow / pack symlink targets outside the chosen tree.
            if values.isSymbolicLink == true {
                enumerator.skipDescendants()
                continue
            }
            // Packages are directories on disk; keep enumerating into them so
            // e.g. MyApp.app/Contents/MacOS/MyApp is archived as normal files.
            if values.isDirectory == true {
                continue
            }
            guard values.isRegularFile == true else { continue }

            let full = fileURL.standardizedFileURL.path
            var rel: String
            if full == rootPath {
                continue
            } else if full.hasPrefix(rootPrefix) {
                rel = String(full.dropFirst(rootPrefix.count))
            } else if full.hasPrefix(rootPath) {
                // Fallback (should be rare with standardized paths)
                rel = String(full.dropFirst(rootPath.count))
                if rel.hasPrefix("/") { rel = String(rel.dropFirst()) }
            } else {
                continue
            }
            rel = rel.replacingOccurrences(of: "\\", with: "/")
            // Reject path components that break the line-oriented archive format.
            guard !rel.isEmpty,
                  !rel.contains("\n"),
                  !rel.contains("\r"),
                  !rel.contains("\0")
            else { continue }

            let size = Int64(values.fileSize ?? 0)
            entries.append(ArchiveFileEntry(relativePath: rel, byteSize: size))
            if entries.count > archiveMaxFiles {
                throw FormatError.io("Folder has more than \(archiveMaxFiles) files")
            }
        }

        entries.sort { $0.relativePath < $1.relativePath }
        return entries
    }

    /// Result of packing a folder into a multi-file `.Tape` archive.
    struct FolderEncodeResult: Equatable {
        var files: Int
        var columns: Int64
        /// Members that used a real compression codec (not raw).
        var compressedFiles: Int
        /// Original total payload bytes (sum of member sizes).
        var originalBytes: Int64
        /// Dominant / preferred compression note for status UI.
        var compressionNote: String
    }

    /// Encode a folder into a multi-file `.Tape` archive.
    ///
    /// Files under the streaming threshold are loaded fully so **Compress** / **Base85**
    /// can run per member (text folders shrink a lot). Larger members stream raw.
    /// Each `# @file` records its own `compression=` / `transfer=` / `punched=`.
    static func encodeFolder(
        root: URL,
        to tapeURL: URL,
        compression: CompressionKind = .auto,
        transfer: TransferEncoding = .identity,
        fileFormat: TapeFileFormat = .defaultWrite,
        cancel: EncodeCancelToken? = nil,
        progress: ((TapeProgress) -> Void)? = nil
    ) throws -> FolderEncodeResult {
        do {
            return try encodeFolderBody(
                root: root,
                to: tapeURL,
                compression: compression,
                transfer: transfer,
                fileFormat: fileFormat,
                cancel: cancel,
                progress: progress
            )
        } catch {
            // Never leave a partial/corrupt archive on disk.
            try? FileManager.default.removeItem(at: tapeURL)
            throw error
        }
    }

    private static func encodeFolderBody(
        root: URL,
        to tapeURL: URL,
        compression: CompressionKind,
        transfer: TransferEncoding,
        fileFormat: TapeFileFormat,
        cancel: EncodeCancelToken?,
        progress: ((TapeProgress) -> Void)?
    ) throws -> FolderEncodeResult {
        let entries = try listFolderFiles(root: root)
        guard !entries.isEmpty else {
            throw FormatError.io("Folder is empty")
        }

        let totalBytes = entries.reduce(Int64(0)) { $0 + $1.byteSize }
        let folderName = root.lastPathComponent

        if FileManager.default.fileExists(atPath: tapeURL.path) {
            try FileManager.default.removeItem(at: tapeURL)
        }
        FileManager.default.createFile(atPath: tapeURL.path, contents: nil)
        let handle = try FileHandle(forWritingTo: tapeURL)
        defer { try? handle.close() }

        // Archive-level header: payload encoding is per-member (see each @file).
        let glyphStyle = GlyphStyle.forFormat(fileFormat)
        var headerLines = [
            "# PaperTape File v\(fileFormat.rawValue)",
            "# name: \(sanitizeHeaderValue(folderName))",
            "# size: \(totalBytes)",
            "# mode: archive",
            "# members: \(entries.count)",
            "# compression: per-file",
            "# transfer: per-file",
            "# preferred-compression: \(compression.rawValue)",
            "# preferred-transfer: \(transfer.rawValue)",
            "# block-size: \(defaultBlockSize)",
            "# integrity: crc32+xor+sum8",
            "# columns: \(fileFormat.columnsHeaderValue)",
            "# channels: \(channelCount)",
            "# bit-order: channel-1-lsb",
            "# layout: ch1 ch2 ch3 feed ch4 ch5 ch6 ch7 ch8",
            "# glyphs: \(glyphStyle.headerDescription)",
            "# stream: 1",
        ]
        if fileFormat.usesTernaryPacking {
            // Whole-file members use full pack; streamed members use block3.
            headerLines.append("# packing: full")
            headerLines.append("# packing-base: \(ternaryBase)")
            headerLines.append("# channel-states: 3")
            headerLines.append("# pack-chunk: 0")
            headerLines.append("# note: ternary archive — whole-file members packing=full; streamed members packing=block3")
        } else if fileFormat.usesQuaternaryPacking {
            headerLines.append("# packing: quat")
            headerLines.append("# packing-base: \(quaternaryBase)")
            headerLines.append("# channel-states: 4")
            headerLines.append("# pack-chunk: 0")
            headerLines.append("# note: quaternary archive — 2 bytes per column")
        } else if fileFormat.usesOctalPacking {
            headerLines.append("# packing: oct")
            headerLines.append("# packing-base: \(octalBase)")
            headerLines.append("# channel-states: 8")
            headerLines.append("# pack-chunk: 0")
            headerLines.append("# note: octal archive — 3 bytes per column")
        } else if fileFormat.usesHexadecimalPacking {
            headerLines.append("# packing: hex")
            headerLines.append("# packing-base: \(hexadecimalBase)")
            headerLines.append("# channel-states: 16")
            headerLines.append("# pack-chunk: 0")
            headerLines.append("# note: hexadecimal archive — 4 bytes per column")
        } else if fileFormat.usesBase256Packing {
            headerLines.append("# packing: b256")
            headerLines.append("# packing-base: 18446744073709551616")
            headerLines.append("# channel-states: 256")
            headerLines.append("# pack-chunk: 0")
            headerLines.append("# note: base-256 archive — 8 bytes per column (grayscale channels; hex-pair tokens)")
        }
        headerLines.append("# note: each @file may compress independently; files ≥\(streamingByteThreshold / (1024 * 1024))MiB stream raw")
        headerLines.append("# note: packages (.app) included; hidden (.build/.git) and node_modules skipped")
        headerLines.append("# ---")
        headerLines.append("")
        try handle.write(contentsOf: Data(headerLines.joined(separator: "\n").utf8))

        var globalColumns: Int64 = 0
        var globalBinaryPunched: Int64 = 0
        var bytesDone: Int64 = 0
        var compressedFiles = 0
        var codecCounts: [String: Int] = [:]
        let rootAccess = root.startAccessingSecurityScopedResource()
        defer { if rootAccess { root.stopAccessingSecurityScopedResource() } }

        for (fileIndex, entry) in entries.enumerated() {
            try cancel?.throwIfCancelled()
            let fileURL = root.appendingPathComponent(entry.relativePath)
            let escaped = entry.relativePath
                .replacingOccurrences(of: "\\", with: "\\\\")
                .replacingOccurrences(of: "\"", with: "\\\"")

            progress?(TapeProgress(
                phase: "Packing \(entry.relativePath)",
                unitsCompleted: bytesDone,
                unitsTotal: totalBytes
            ))

            // Only whole-file compress when size is known and under the threshold.
            // Unknown/zero size: stream raw (matches encodeFileStreaming safety).
            let canWholeFile =
                entry.byteSize > 0
                && entry.byteSize < Int64(streamingByteThreshold)

            let punchedBytes: Data
            let appliedCompression: CompressionKind
            let appliedTransfer: TransferEncoding
            let originalSize: Int64

            var useWholeFile = canWholeFile
            if canWholeFile {
                try cancel?.throwIfCancelled()
                // Cap the whole-file load: never pull multi-GB into RAM if listing size was understated.
                let probe = try readUpToThreshold(from: fileURL, limit: streamingByteThreshold)
                if probe.hitLimit {
                    // Oversized — pure disk stream (probe was only a size check; re-read from start).
                    useWholeFile = false
                    punchedBytes = Data()
                    appliedCompression = .none
                    appliedTransfer = .identity
                    // Unknown true size until stream completes; listing size is not trustworthy.
                    originalSize = 0
                } else {
                    let data = probe.data
                    originalSize = Int64(data.count)
                    try cancel?.throwIfCancelled()
                    let (afterCompress, comp) = applyCompression(data, preferred: compression)
                    if transfer == .ascii85, !afterCompress.isEmpty {
                        punchedBytes = ascii85Encode(afterCompress)
                        appliedCompression = comp
                        appliedTransfer = .ascii85
                    } else {
                        punchedBytes = afterCompress
                        appliedCompression = comp
                        appliedTransfer = .identity
                    }
                    if appliedCompression != .none {
                        compressedFiles += 1
                        codecCounts[appliedCompression.rawValue, default: 0] += 1
                    }
                    bytesDone += originalSize
                }
            } else {
                // Huge or unknown-size member: stream raw.
                punchedBytes = Data()
                appliedCompression = .none
                appliedTransfer = .identity
                originalSize = entry.byteSize
            }

            let memberHeader: String
            let wroteFromBuffer: Bool
            if useWholeFile {
                let packMode: String
                let packChunk: Int
                if fileFormat.usesTernaryPacking {
                    packMode = "full"
                    packChunk = preferredTernaryPackChunk(byteCount: punchedBytes.count)
                } else if fileFormat.usesQuaternaryPacking {
                    packMode = "quat"
                    packChunk = 0
                } else if fileFormat.usesOctalPacking {
                    packMode = "oct"
                    packChunk = 0
                } else if fileFormat.usesHexadecimalPacking {
                    packMode = "hex"
                    packChunk = 0
                } else if fileFormat.usesBase256Packing {
                    packMode = "b256"
                    packChunk = 0
                } else {
                    packMode = "binary"
                    packChunk = 0
                }
                memberHeader =
                    "# @file path=\"\(escaped)\" size=\(originalSize) punched=\(punchedBytes.count) "
                    + "compression=\(appliedCompression.rawValue) transfer=\(appliedTransfer.rawValue) "
                    + "packing=\(packMode) pack-chunk=\(packChunk) index=\(fileIndex)\n"
                try handle.write(contentsOf: Data(memberHeader.utf8))
                let cols = try writePunchedBlocks(
                    punchedBytes,
                    to: handle,
                    blockSize: defaultBlockSize,
                    fileFormat: fileFormat,
                    cancel: cancel
                )
                globalColumns += Int64(cols)
                globalBinaryPunched += Int64(punchedBytes.count)
                wroteFromBuffer = true
            } else if !punchedBytes.isEmpty {
                // Oversized after load — stream-style dense packing (block3 for v4, not full).
                // Full ternary would force multi-MiB digit buffers on extract and fail the cap.
                let packMode: String
                if fileFormat.usesTernaryPacking {
                    packMode = "block3"
                } else if fileFormat.usesQuaternaryPacking {
                    packMode = "quat"
                } else if fileFormat.usesOctalPacking {
                    packMode = "oct"
                } else if fileFormat.usesHexadecimalPacking {
                    packMode = "hex"
                } else if fileFormat.usesBase256Packing {
                    packMode = "b256"
                } else {
                    packMode = "binary"
                }
                memberHeader =
                    "# @file path=\"\(escaped)\" size=\(originalSize) punched=\(punchedBytes.count) "
                    + "compression=none transfer=identity packing=\(packMode) pack-chunk=0 "
                    + "index=\(fileIndex) stream=1\n"
                try handle.write(contentsOf: Data(memberHeader.utf8))
                let cols = try writeStreamDenseFromBuffer(
                    punchedBytes,
                    to: handle,
                    blockSize: defaultBlockSize,
                    fileFormat: fileFormat,
                    cancel: cancel
                )
                globalColumns += Int64(cols)
                globalBinaryPunched += Int64(punchedBytes.count)
                wroteFromBuffer = true
            } else {
                let streamPack: String
                if fileFormat.usesTernaryPacking {
                    streamPack = "block3"
                } else if fileFormat.usesQuaternaryPacking {
                    streamPack = "quat"
                } else if fileFormat.usesOctalPacking {
                    streamPack = "oct"
                } else if fileFormat.usesHexadecimalPacking {
                    streamPack = "hex"
                } else if fileFormat.usesBase256Packing {
                    streamPack = "b256"
                } else {
                    streamPack = "binary"
                }
                memberHeader =
                    "# @file path=\"\(escaped)\" size=\(originalSize) "
                    + "compression=none transfer=identity packing=\(streamPack) pack-chunk=0 "
                    + "index=\(fileIndex) stream=1\n"
                try handle.write(contentsOf: Data(memberHeader.utf8))
                wroteFromBuffer = false
            }

            if !wroteFromBuffer {
                // Stream raw columns from disk.
                let input = try FileHandle(forReadingFrom: fileURL)
                defer { try? input.close() }
                var blockBuffer = Data()
                var densePending: [UInt32] = []
                var blockIndex = 0
                var columnOffset = 0
                var memberBytes: Int64 = 0
                let bs = defaultBlockSize
                let ternary = fileFormat.usesTernaryPacking
                let quaternary = fileFormat.usesQuaternaryPacking
                let octal = fileFormat.usesOctalPacking
                let hexadecimal = fileFormat.usesHexadecimalPacking
                let base256 = fileFormat.usesBase256Packing
                var base256Pending: [[UInt8]] = []
                let style = GlyphStyle.forFormat(fileFormat)

                func flushBase256Columns(_ count: Int) throws {
                    guard count > 0, base256Pending.count >= count else { return }
                    try cancel?.throwIfCancelled()
                    let vals = Array(base256Pending.prefix(count))
                    base256Pending.removeFirst(count)
                    let cols = vals.map { Column(id: 0, base256Bytes: $0) }
                    let integ = integrityData(for: cols)
                    let crc = crc32(integ)
                    let xor = xorParity(integ)
                    let sum = sum8(integ)
                    let len = cols.count
                    var text =
                        "# @block \(blockIndex) off=\(columnOffset) len=\(len) "
                        + "crc32=\(String(format: "%08X", crc)) "
                        + "xor=\(String(format: "%02X", xor)) "
                        + "sum8=\(String(format: "%02X", sum))\n"
                    for col in cols {
                        text += columnLine(for: col, annotate: false, style: style) + "\n"
                    }
                    try handle.write(contentsOf: Data(text.utf8))
                    columnOffset += len
                    globalColumns += Int64(len)
                    blockIndex += 1
                }

                func flushDenseColumns(_ count: Int) throws {
                    guard count > 0, densePending.count >= count else { return }
                    try cancel?.throwIfCancelled()
                    let vals = Array(densePending.prefix(count))
                    densePending.removeFirst(count)
                    let cols: [Column]
                    if hexadecimal {
                        cols = vals.map { Column(id: 0, hexadecimalValue: $0) }
                    } else if octal {
                        cols = vals.map { Column(id: 0, octalValue: $0) }
                    } else if quaternary {
                        cols = vals.map { Column(id: 0, quaternaryValue: UInt16(truncatingIfNeeded: $0)) }
                    } else {
                        cols = vals.map { Column(id: 0, ternaryValue: UInt16(truncatingIfNeeded: $0)) }
                    }
                    let integ = integrityData(for: cols)
                    let crc = crc32(integ)
                    let xor = xorParity(integ)
                    let sum = sum8(integ)
                    var text =
                        "# @block \(blockIndex) off=\(columnOffset) len=\(count) "
                        + "crc32=\(String(format: "%08X", crc)) "
                        + "xor=\(String(format: "%02X", xor)) "
                        + "sum8=\(String(format: "%02X", sum))\n"
                    for col in cols {
                        text += columnLine(for: col, annotate: false, style: style) + "\n"
                    }
                    try handle.write(contentsOf: Data(text.utf8))
                    columnOffset += count
                    globalColumns += Int64(count)
                    blockIndex += 1
                }

                func flushBinaryBlock() throws {
                    guard !blockBuffer.isEmpty else { return }
                    try cancel?.throwIfCancelled()
                    let n = try writeOneBlock(
                        blockBuffer,
                        index: blockIndex,
                        offset: columnOffset,
                        to: handle,
                        fileFormat: fileFormat
                    )
                    columnOffset += n
                    globalColumns += Int64(n)
                    blockIndex += 1
                    blockBuffer.removeAll(keepingCapacity: true)
                }

                while true {
                    try cancel?.throwIfCancelled()
                    let chunk = try input.read(upToCount: 256 * 1024) ?? Data()
                    if chunk.isEmpty { break }
                    if ternary {
                        blockBuffer.append(chunk)
                        while blockBuffer.count >= 3 {
                            let take = min((blockBuffer.count / 3) * 3, 3 * bs)
                            let piece = Data(blockBuffer.prefix(take))
                            blockBuffer.removeFirst(take)
                            densePending.append(contentsOf: packTernaryBlock3(piece).map { UInt32($0) })
                            while densePending.count >= bs {
                                try flushDenseColumns(bs)
                            }
                        }
                    } else if quaternary {
                        blockBuffer.append(chunk)
                        while blockBuffer.count >= 2 {
                            let take = min((blockBuffer.count / 2) * 2, 2 * bs)
                            let piece = Data(blockBuffer.prefix(take))
                            blockBuffer.removeFirst(take)
                            densePending.append(contentsOf: packQuaternary(piece).map { UInt32($0) })
                            while densePending.count >= bs {
                                try flushDenseColumns(bs)
                            }
                        }
                    } else if octal {
                        blockBuffer.append(chunk)
                        while blockBuffer.count >= 3 {
                            let take = min((blockBuffer.count / 3) * 3, 3 * bs)
                            let piece = Data(blockBuffer.prefix(take))
                            blockBuffer.removeFirst(take)
                            densePending.append(contentsOf: packOctal(piece))
                            while densePending.count >= bs {
                                try flushDenseColumns(bs)
                            }
                        }
                    } else if hexadecimal {
                        blockBuffer.append(chunk)
                        while blockBuffer.count >= 4 {
                            let take = min((blockBuffer.count / 4) * 4, 4 * bs)
                            let piece = Data(blockBuffer.prefix(take))
                            blockBuffer.removeFirst(take)
                            densePending.append(contentsOf: packHexadecimal(piece))
                            while densePending.count >= bs {
                                try flushDenseColumns(bs)
                            }
                        }
                    } else if base256 {
                        blockBuffer.append(chunk)
                        while blockBuffer.count >= 8 {
                            let take = min((blockBuffer.count / 8) * 8, 8 * bs)
                            let piece = Data(blockBuffer.prefix(take))
                            blockBuffer.removeFirst(take)
                            base256Pending.append(contentsOf: packBase256(piece))
                            while base256Pending.count >= bs {
                                try flushBase256Columns(bs)
                            }
                        }
                    } else {
                        var i = chunk.startIndex
                        while i < chunk.endIndex {
                            let space = bs - blockBuffer.count
                            let end = chunk.index(i, offsetBy: min(space, chunk.distance(from: i, to: chunk.endIndex)))
                            blockBuffer.append(chunk[i..<end])
                            i = end
                            if blockBuffer.count >= bs {
                                try flushBinaryBlock()
                            }
                        }
                    }
                    memberBytes += Int64(chunk.count)
                    bytesDone += Int64(chunk.count)
                    progress?(TapeProgress(
                        phase: "Streaming \(entry.relativePath)",
                        unitsCompleted: bytesDone,
                        unitsTotal: totalBytes
                    ))
                }
                if ternary {
                    if !blockBuffer.isEmpty {
                        densePending.append(contentsOf: packTernaryBlock3(blockBuffer).map { UInt32($0) })
                        blockBuffer.removeAll()
                    }
                    while !densePending.isEmpty {
                        try flushDenseColumns(min(bs, densePending.count))
                    }
                } else if quaternary {
                    if !blockBuffer.isEmpty {
                        densePending.append(contentsOf: packQuaternary(blockBuffer).map { UInt32($0) })
                        blockBuffer.removeAll()
                    }
                    while !densePending.isEmpty {
                        try flushDenseColumns(min(bs, densePending.count))
                    }
                } else if octal {
                    if !blockBuffer.isEmpty {
                        densePending.append(contentsOf: packOctal(blockBuffer))
                        blockBuffer.removeAll()
                    }
                    while !densePending.isEmpty {
                        try flushDenseColumns(min(bs, densePending.count))
                    }
                } else if hexadecimal {
                    if !blockBuffer.isEmpty {
                        densePending.append(contentsOf: packHexadecimal(blockBuffer))
                        blockBuffer.removeAll()
                    }
                    while !densePending.isEmpty {
                        try flushDenseColumns(min(bs, densePending.count))
                    }
                } else if base256 {
                    if !blockBuffer.isEmpty {
                        base256Pending.append(contentsOf: packBase256(blockBuffer))
                        blockBuffer.removeAll()
                    }
                    while !base256Pending.isEmpty {
                        try flushBase256Columns(min(bs, base256Pending.count))
                    }
                } else {
                    try flushBinaryBlock()
                }
                globalBinaryPunched += memberBytes
                if originalSize > 0, memberBytes != originalSize {
                    throw FormatError.io(
                        "Read \(memberBytes) bytes but listing size was \(originalSize) for \(entry.relativePath)"
                    )
                }
                // Authoritative punched length for dense pad trim on extract (size may be 0/stale).
                try handle.write(contentsOf: Data("# @endfile punched=\(memberBytes) size=\(memberBytes)\n".utf8))
            }

            if wroteFromBuffer {
                try handle.write(contentsOf: Data("# @endfile\n".utf8))
            }
        }

        let codecSummary: String
        if compressedFiles == 0 {
            codecSummary = compression == .none
                ? "raw (Compress Off)"
                : "raw (no worthwhile savings)"
        } else {
            let parts = codecCounts.keys.sorted().map { "\($0)×\(codecCounts[$0]!)" }
            codecSummary = "compressed \(compressedFiles)/\(entries.count) (\(parts.joined(separator: ", ")))"
        }

        // punched-size = binary bytes on the strip (matches blob header semantics).
        // ternary-columns = on-disk column count when packing is ternary.
        let trailer =
            "\n# === archive complete ===\n"
            + "# members: \(entries.count)\n"
            + "# punched-size: \(globalBinaryPunched)\n"
            + (fileFormat.usesTernaryPacking
                ? "# ternary-columns: \(globalColumns)\n"
                : fileFormat.usesQuaternaryPacking
                    ? "# quaternary-columns: \(globalColumns)\n"
                    : fileFormat.usesOctalPacking
                        ? "# octal-columns: \(globalColumns)\n"
                        : fileFormat.usesHexadecimalPacking
                            ? "# hexadecimal-columns: \(globalColumns)\n"
                            : fileFormat.usesBase256Packing
                                ? "# base256-columns: \(globalColumns)\n"
                                : "")
            + "# compressed-members: \(compressedFiles)\n"
        try handle.write(contentsOf: Data(trailer.utf8))
        progress?(TapeProgress(phase: "Done", unitsCompleted: bytesDone, unitsTotal: totalBytes))
        return FolderEncodeResult(
            files: entries.count,
            columns: globalColumns,
            compressedFiles: compressedFiles,
            originalBytes: totalBytes,
            compressionNote: codecSummary
        )
    }

    /// Stream-style dense pack from an in-memory buffer (block3 / quat / oct).
    /// Used when listing size understated a large file — matches disk-stream extract path.
    @discardableResult
    private static func writeStreamDenseFromBuffer(
        _ data: Data,
        to handle: FileHandle,
        blockSize: Int,
        fileFormat: TapeFileFormat,
        cancel: EncodeCancelToken? = nil
    ) throws -> Int {
        guard !data.isEmpty else { return 0 }
        if fileFormat.usesTernaryPacking {
            let digits = packTernaryBlock3(data)
            let style = GlyphStyle.forFormat(fileFormat)
            let bs = max(1, blockSize)
            var colOffset = 0
            var index = 0
            var total = 0
            while colOffset < digits.count {
                try cancel?.throwIfCancelled()
                let end = min(colOffset + bs, digits.count)
                let sliceVals = Array(digits[colOffset..<end])
                let cols = sliceVals.map { Column(id: 0, ternaryValue: $0) }
                let integ = integrityData(for: cols)
                let crc = crc32(integ)
                let xor = xorParity(integ)
                let sum = sum8(integ)
                let len = cols.count
                var text =
                    "# @block \(index) off=\(colOffset) len=\(len) "
                    + "crc32=\(String(format: "%08X", crc)) "
                    + "xor=\(String(format: "%02X", xor)) "
                    + "sum8=\(String(format: "%02X", sum))\n"
                for col in cols {
                    text += columnLine(for: col, annotate: false, style: style) + "\n"
                }
                try handle.write(contentsOf: Data(text.utf8))
                total += len
                colOffset = end
                index += 1
            }
            return total
        }
        // Quat / oct / binary share writePunchedBlocks (O(n), stream-decodable).
        return try writePunchedBlocks(
            data,
            to: handle,
            blockSize: blockSize,
            fileFormat: fileFormat,
            cancel: cancel
        )
    }

    /// Write payload bytes as visual column lines with `# @block` markers. Returns column count.
    /// For v4, uses **full base-6561** packing of the entire buffer.
    @discardableResult
    private static func writePunchedBlocks(
        _ data: Data,
        to handle: FileHandle,
        blockSize: Int,
        fileFormat: TapeFileFormat,
        cancel: EncodeCancelToken? = nil
    ) throws -> Int {
        guard !data.isEmpty else { return 0 }
        let bs = max(1, blockSize)

        if fileFormat.usesBase256Packing {
            let values = packBase256(data)
            let style = GlyphStyle.forFormat(fileFormat)
            var colOffset = 0
            var index = 0
            var total = 0
            while colOffset < values.count {
                try cancel?.throwIfCancelled()
                let end = min(colOffset + bs, values.count)
                let sliceVals = Array(values[colOffset..<end])
                let cols = sliceVals.map { Column(id: 0, base256Bytes: $0) }
                let integ = integrityData(for: cols)
                let crc = crc32(integ)
                let xor = xorParity(integ)
                let sum = sum8(integ)
                let len = cols.count
                var text =
                    "# @block \(index) off=\(colOffset) len=\(len) "
                    + "crc32=\(String(format: "%08X", crc)) "
                    + "xor=\(String(format: "%02X", xor)) "
                    + "sum8=\(String(format: "%02X", sum))\n"
                for col in cols {
                    text += columnLine(for: col, annotate: false, style: style) + "\n"
                }
                try handle.write(contentsOf: Data(text.utf8))
                total += len
                colOffset = end
                index += 1
            }
            return total
        }

        if fileFormat.usesHexadecimalPacking {
            let values = packHexadecimal(data)
            let style = GlyphStyle.forFormat(fileFormat)
            var colOffset = 0
            var index = 0
            var total = 0
            while colOffset < values.count {
                try cancel?.throwIfCancelled()
                let end = min(colOffset + bs, values.count)
                let sliceVals = Array(values[colOffset..<end])
                let cols = sliceVals.map { Column(id: 0, hexadecimalValue: $0) }
                let integ = integrityData(for: cols)
                let crc = crc32(integ)
                let xor = xorParity(integ)
                let sum = sum8(integ)
                let len = cols.count
                var text =
                    "# @block \(index) off=\(colOffset) len=\(len) "
                    + "crc32=\(String(format: "%08X", crc)) "
                    + "xor=\(String(format: "%02X", xor)) "
                    + "sum8=\(String(format: "%02X", sum))\n"
                for col in cols {
                    text += columnLine(for: col, annotate: false, style: style) + "\n"
                }
                try handle.write(contentsOf: Data(text.utf8))
                total += len
                colOffset = end
                index += 1
            }
            return total
        }

        if fileFormat.usesOctalPacking {
            let values = packOctal(data)
            let style = GlyphStyle.forFormat(fileFormat)
            var colOffset = 0
            var index = 0
            var total = 0
            while colOffset < values.count {
                try cancel?.throwIfCancelled()
                let end = min(colOffset + bs, values.count)
                let sliceVals = Array(values[colOffset..<end])
                let cols = sliceVals.map { Column(id: 0, octalValue: $0) }
                let integ = integrityData(for: cols)
                let crc = crc32(integ)
                let xor = xorParity(integ)
                let sum = sum8(integ)
                let len = cols.count
                var text =
                    "# @block \(index) off=\(colOffset) len=\(len) "
                    + "crc32=\(String(format: "%08X", crc)) "
                    + "xor=\(String(format: "%02X", xor)) "
                    + "sum8=\(String(format: "%02X", sum))\n"
                for col in cols {
                    text += columnLine(for: col, annotate: false, style: style) + "\n"
                }
                try handle.write(contentsOf: Data(text.utf8))
                total += len
                colOffset = end
                index += 1
            }
            return total
        }

        if fileFormat.usesQuaternaryPacking {
            let values = packQuaternary(data)
            let style = GlyphStyle.forFormat(fileFormat)
            var colOffset = 0
            var index = 0
            var total = 0
            while colOffset < values.count {
                try cancel?.throwIfCancelled()
                let end = min(colOffset + bs, values.count)
                let sliceVals = Array(values[colOffset..<end])
                let cols = sliceVals.map { Column(id: 0, quaternaryValue: $0) }
                let integ = integrityData(for: cols)
                let crc = crc32(integ)
                let xor = xorParity(integ)
                let sum = sum8(integ)
                let len = cols.count
                var text =
                    "# @block \(index) off=\(colOffset) len=\(len) "
                    + "crc32=\(String(format: "%08X", crc)) "
                    + "xor=\(String(format: "%02X", xor)) "
                    + "sum8=\(String(format: "%02X", sum))\n"
                for col in cols {
                    text += columnLine(for: col, annotate: false, style: style) + "\n"
                }
                try handle.write(contentsOf: Data(text.utf8))
                total += len
                colOffset = end
                index += 1
            }
            return total
        }

        if fileFormat.usesTernaryPacking {
            // Adaptive full pack: whole-integer for small, chunked O(n) for large.
            let chunk = preferredTernaryPackChunk(byteCount: data.count)
            let digits = packTernary(data, mode: .ternaryFull, chunkBytes: chunk)
            let style = GlyphStyle.forFormat(fileFormat)
            var colOffset = 0
            var index = 0
            var total = 0
            while colOffset < digits.count {
                try cancel?.throwIfCancelled()
                let end = min(colOffset + bs, digits.count)
                let sliceVals = Array(digits[colOffset..<end])
                let cols = sliceVals.map { Column(id: 0, ternaryValue: $0) }
                let integ = integrityData(for: cols)
                let crc = crc32(integ)
                let xor = xorParity(integ)
                let sum = sum8(integ)
                let len = cols.count
                var text =
                    "# @block \(index) off=\(colOffset) len=\(len) "
                    + "crc32=\(String(format: "%08X", crc)) "
                    + "xor=\(String(format: "%02X", xor)) "
                    + "sum8=\(String(format: "%02X", sum))\n"
                for col in cols {
                    text += columnLine(for: col, annotate: false, style: style) + "\n"
                }
                try handle.write(contentsOf: Data(text.utf8))
                total += len
                colOffset = end
                index += 1
            }
            return total
        }

        var offset = 0
        var index = 0
        var total = 0
        while offset < data.count {
            try cancel?.throwIfCancelled()
            let end = min(offset + bs, data.count)
            let slice = data[offset..<end]
            total += try writeOneBlock(
                Data(slice),
                index: index,
                offset: offset,
                to: handle,
                fileFormat: fileFormat
            )
            offset = end
            index += 1
        }
        return total
    }

    @discardableResult
    private static func writeOneBlock(
        _ slice: Data,
        index: Int,
        offset: Int,
        to handle: FileHandle,
        fileFormat: TapeFileFormat
    ) throws -> Int {
        guard !slice.isEmpty else { return 0 }
        let style = GlyphStyle.forFormat(fileFormat)

        // Stream path for dense formats.
        if fileFormat.usesTernaryPacking {
            let digits = packTernaryBlock3(slice)
            let cols = digits.map { Column(id: 0, ternaryValue: $0) }
            let integ = integrityData(for: cols)
            let crc = crc32(integ)
            let xor = xorParity(integ)
            let sum = sum8(integ)
            let len = cols.count
            var text =
                "# @block \(index) off=\(offset) len=\(len) "
                + "crc32=\(String(format: "%08X", crc)) "
                + "xor=\(String(format: "%02X", xor)) "
                + "sum8=\(String(format: "%02X", sum))\n"
            for col in cols {
                text += columnLine(for: col, annotate: false, style: style) + "\n"
            }
            try handle.write(contentsOf: Data(text.utf8))
            return len
        }
        if fileFormat.usesQuaternaryPacking {
            let values = packQuaternary(slice)
            let cols = values.map { Column(id: 0, quaternaryValue: $0) }
            let integ = integrityData(for: cols)
            let crc = crc32(integ)
            let xor = xorParity(integ)
            let sum = sum8(integ)
            let len = cols.count
            var text =
                "# @block \(index) off=\(offset) len=\(len) "
                + "crc32=\(String(format: "%08X", crc)) "
                + "xor=\(String(format: "%02X", xor)) "
                + "sum8=\(String(format: "%02X", sum))\n"
            for col in cols {
                text += columnLine(for: col, annotate: false, style: style) + "\n"
            }
            try handle.write(contentsOf: Data(text.utf8))
            return len
        }
        if fileFormat.usesOctalPacking {
            let values = packOctal(slice)
            let cols = values.map { Column(id: 0, octalValue: $0) }
            let integ = integrityData(for: cols)
            let crc = crc32(integ)
            let xor = xorParity(integ)
            let sum = sum8(integ)
            let len = cols.count
            var text =
                "# @block \(index) off=\(offset) len=\(len) "
                + "crc32=\(String(format: "%08X", crc)) "
                + "xor=\(String(format: "%02X", xor)) "
                + "sum8=\(String(format: "%02X", sum))\n"
            for col in cols {
                text += columnLine(for: col, annotate: false, style: style) + "\n"
            }
            try handle.write(contentsOf: Data(text.utf8))
            return len
        }
        if fileFormat.usesHexadecimalPacking {
            let values = packHexadecimal(slice)
            let cols = values.map { Column(id: 0, hexadecimalValue: $0) }
            let integ = integrityData(for: cols)
            let crc = crc32(integ)
            let xor = xorParity(integ)
            let sum = sum8(integ)
            let len = cols.count
            var text =
                "# @block \(index) off=\(offset) len=\(len) "
                + "crc32=\(String(format: "%08X", crc)) "
                + "xor=\(String(format: "%02X", xor)) "
                + "sum8=\(String(format: "%02X", sum))\n"
            for col in cols {
                text += columnLine(for: col, annotate: false, style: style) + "\n"
            }
            try handle.write(contentsOf: Data(text.utf8))
            return len
        }

        let len = slice.count
        let crc = crc32(slice)
        let xor = xorParity(slice)
        let sum = sum8(slice)
        var text =
            "# @block \(index) off=\(offset) len=\(len) "
            + "crc32=\(String(format: "%08X", crc)) "
            + "xor=\(String(format: "%02X", xor)) "
            + "sum8=\(String(format: "%02X", sum))\n"
        for byte in slice {
            let col = Column(id: 0, byte: byte)
            text += columnLine(
                for: col,
                annotate: fileFormat.includesColumnAnnotations,
                style: style
            ) + "\n"
        }
        try handle.write(contentsOf: Data(text.utf8))
        return len
    }

    /// Extract a `mode: archive` `.Tape` into `destinationFolder` (created if needed).
    static func extractFolder(
        from tapeURL: URL,
        to destinationFolder: URL,
        progress: ((TapeProgress) -> Void)? = nil
    ) throws -> (files: Int, bytes: Int64, failedBlocks: Int) {
        let accessed = tapeURL.startAccessingSecurityScopedResource()
        defer { if accessed { tapeURL.stopAccessingSecurityScopedResource() } }

        // Line-oriented extract (reliable for multi-file archives).
        let handle = try FileHandle(forReadingFrom: tapeURL)
        defer { try? handle.close() }

        var leftover = Data()
        // Cap a *single* incomplete line (not the whole read-ahead buffer).
        let maxLineBytes = 256 * 1024
        func readLine() throws -> String? {
            while true {
                // Prefer complete lines even when the buffer is large.
                if let range = leftover.firstIndex(of: 0x0A) {
                    let lineData = leftover[..<range]
                    if lineData.count > maxLineBytes {
                        throw FormatError.io("Line too long in archive .Tape body (missing newline?)")
                    }
                    leftover = leftover[leftover.index(after: range)...]
                    let raw = lineData.last == 0x0D ? lineData.dropLast() : lineData
                    guard let line = String(data: raw, encoding: .utf8) else {
                        throw FormatError.io("Invalid UTF-8 in archive .Tape body")
                    }
                    return line
                }
                // No newline yet: only the incomplete trailing line may grow.
                if leftover.count > maxLineBytes {
                    throw FormatError.io("Line too long in archive .Tape body (missing newline?)")
                }
                let chunk = try handle.read(upToCount: 256 * 1024) ?? Data()
                if chunk.isEmpty {
                    if leftover.isEmpty { return nil }
                    defer { leftover = Data() }
                    if leftover.count > maxLineBytes {
                        throw FormatError.io("Line too long in archive .Tape body (missing newline?)")
                    }
                    guard let line = String(data: leftover, encoding: .utf8) else {
                        throw FormatError.io("Invalid UTF-8 in archive .Tape body")
                    }
                    return line
                }
                leftover.append(chunk)
            }
        }

        var mode = "blob"
        var totalHint: Int64?
        var headerPacking = PackingMode.binary
        var inBody = false
        while let line = try readLine() {
            let t = line.trimmingCharacters(in: .whitespaces)
            if t.hasPrefix("# mode:") {
                mode = String(t.dropFirst("# mode:".count)).trimmingCharacters(in: .whitespaces)
            } else if t.hasPrefix("# size:") {
                totalHint = Int64(String(t.dropFirst("# size:".count)).trimmingCharacters(in: .whitespaces))
            } else if t.hasPrefix("# packing:") {
                headerPacking = PackingMode.parse(String(t.dropFirst("# packing:".count)))
            } else if t.hasPrefix("# columns:") {
                let c = String(t.dropFirst("# columns:".count)).trimmingCharacters(in: .whitespaces).lowercased()
                if c == "base256" || c == "b256", headerPacking == .binary {
                    headerPacking = .base256
                } else if c == "hexadecimal" || c == "hex", headerPacking == .binary {
                    headerPacking = .hexadecimal
                } else if c == "octal", headerPacking == .binary {
                    headerPacking = .octal
                } else if c == "quaternary", headerPacking == .binary {
                    headerPacking = .quaternary
                } else if c == "ternary", headerPacking == .binary {
                    headerPacking = .ternaryFull
                }
            } else if t.hasPrefix("# PaperTape File v") {
                let vStr = t.replacingOccurrences(of: "# PaperTape File v", with: "")
                let ver = Int(vStr.trimmingCharacters(in: .whitespaces)) ?? 0
                if headerPacking == .binary {
                    if ver >= 8 { headerPacking = .base256 }
                    else if ver >= 7 { headerPacking = .hexadecimal }
                    else if ver >= 6 { headerPacking = .octal }
                    else if ver >= 5 { headerPacking = .quaternary }
                    else if ver >= 4 { headerPacking = .ternaryFull }
                }
            } else if t == "# ---" || t == "---" || t.hasPrefix("# ---") {
                inBody = true
                break
            }
        }
        guard mode == "archive" else {
            throw FormatError.io("Not a folder archive (.Tape mode is “\(mode)”)")
        }
        guard inBody else {
            throw FormatError.io("Archive .Tape has no payload section")
        }

        let fm = FileManager.default
        try fm.createDirectory(at: destinationFolder, withIntermediateDirectories: true)
        // Stage into a private subfolder so a failed extract never leaves a partial tree
        // mixed into the user-chosen destination.
        let staging = destinationFolder.appendingPathComponent(
            ".papertape-staging-\(UUID().uuidString)",
            isDirectory: true
        )
        try fm.createDirectory(at: staging, withIntermediateDirectories: true)
        defer {
            // Always drop staging: either empty after promote, or partial after failure.
            try? fm.removeItem(at: staging)
        }

        var fileCount = 0
        var bytes: Int64 = 0
        var failedBlocks = 0

        // Current member state. Compressed / Base85 / ternary members buffer then
        // restore once at @endfile. Raw binary identity members may stream to disk.
        var currentPath: String?
        var currentDest: URL?
        var currentWriter: FileHandle?
        var currentCompression = CompressionKind.none
        var currentTransfer = TransferEncoding.identity
        var currentOriginalSize: Int?
        var currentPacking = PackingMode.binary
        var currentPunchedSize: Int?
        var currentPackChunk: Int?
        var punchedBuffer = Data()
        var ternaryDigits: [UInt32] = []
        var base256Digits: [[UInt8]] = []
        var needsBuffer = false
        /// Raw dense stream (block3 / quat / oct / hex / b256) → stream decode to `currentWriter`.
        var streamBlock3 = false
        var block3Emitted: Int64 = 0
        var blockCols: [Column] = []
        var blockStored: (crc: UInt32, xor: UInt8, sum: UInt8, len: Int)?

        func closeCurrentWriter() throws {
            try currentWriter?.close()
            currentWriter = nil
        }

        func positiveLimit(_ a: Int?, _ b: Int?) -> Int64? {
            if let p = a, p > 0 { return Int64(p) }
            if let s = b, s > 0 { return Int64(s) }
            return nil
        }

        /// Odd block3 digit carried across integrity blocks (matches stream reader).
        var archiveBlock3Carry: UInt32?

        func emitDenseStreamValues(_ vals: [UInt32], to writer: FileHandle) throws {
            // Only cap when size/punched is a positive length; 0 means unknown, not empty.
            let limit = positiveLimit(currentPunchedSize, currentOriginalSize)
            var out = Data()
            if currentPacking == .base256 {
                // vals holds packed UInt32 pairs? — archive uses Column path; this branch unused for b256.
                // Handled via emitBase256 below.
            } else if currentPacking == .hexadecimal {
                for v in vals {
                    if let lim = limit, block3Emitted >= lim { break }
                    var quad = [
                        UInt8((v >> 24) & 0xFF),
                        UInt8((v >> 16) & 0xFF),
                        UInt8((v >> 8) & 0xFF),
                        UInt8(v & 0xFF),
                    ]
                    if let lim = limit {
                        let room = Int(lim - block3Emitted)
                        if room <= 0 { break }
                        if quad.count > room { quad = Array(quad.prefix(room)) }
                    }
                    out.append(contentsOf: quad)
                    block3Emitted += Int64(quad.count)
                }
            } else if currentPacking == .octal {
                for v in vals {
                    if let lim = limit, block3Emitted >= lim { break }
                    var triple = [
                        UInt8((v >> 16) & 0xFF),
                        UInt8((v >> 8) & 0xFF),
                        UInt8(v & 0xFF),
                    ]
                    if let lim = limit {
                        let room = Int(lim - block3Emitted)
                        if room <= 0 { break }
                        if triple.count > room { triple = Array(triple.prefix(room)) }
                    }
                    out.append(contentsOf: triple)
                    block3Emitted += Int64(triple.count)
                }
            } else if currentPacking == .quaternary {
                for v in vals {
                    if let lim = limit, block3Emitted >= lim { break }
                    var pair = [UInt8((v >> 8) & 0xFF), UInt8(v & 0xFF)]
                    if let lim = limit {
                        let room = Int(lim - block3Emitted)
                        if room <= 0 { break }
                        if pair.count > room { pair = Array(pair.prefix(room)) }
                    }
                    out.append(contentsOf: pair)
                    block3Emitted += Int64(pair.count)
                }
            } else {
                var digits = vals
                if let carry = archiveBlock3Carry {
                    digits.insert(carry, at: 0)
                    archiveBlock3Carry = nil
                }
                var i = 0
                while i + 1 < digits.count {
                    if let lim = limit, block3Emitted >= lim { break }
                    let d0 = Int(digits[i])
                    let d1 = Int(digits[i + 1])
                    i += 2
                    let v = d0 + d1 * ternaryBase
                    var triple = [
                        UInt8((v >> 16) & 0xFF),
                        UInt8((v >> 8) & 0xFF),
                        UInt8(v & 0xFF),
                    ]
                    if let lim = limit {
                        let room = Int(lim - block3Emitted)
                        if room <= 0 { break }
                        if triple.count > room { triple = Array(triple.prefix(room)) }
                    }
                    out.append(contentsOf: triple)
                    block3Emitted += Int64(triple.count)
                }
                if i < digits.count {
                    archiveBlock3Carry = digits[i]
                }
            }
            if !out.isEmpty {
                try writer.write(contentsOf: out)
                bytes += Int64(out.count)
            }
        }

        func emitBase256Columns(_ cols: [[UInt8]], to writer: FileHandle) throws {
            let limit = positiveLimit(currentPunchedSize, currentOriginalSize)
            var out = Data()
            for col in cols {
                if let lim = limit, block3Emitted >= lim { break }
                var bytes8 = Array(col.reversed()) // MSB first
                if let lim = limit {
                    let room = Int(lim - block3Emitted)
                    if room <= 0 { break }
                    if bytes8.count > room { bytes8 = Array(bytes8.prefix(room)) }
                }
                out.append(contentsOf: bytes8)
                block3Emitted += Int64(bytes8.count)
            }
            if !out.isEmpty {
                try writer.write(contentsOf: out)
                bytes += Int64(out.count)
            }
        }

        func finishMember() throws {
            try flushBlockIntoMember()
            // Flush odd block3 carry if any (pair with zero digit).
            if streamBlock3, currentPacking == .ternaryBlock3, let carry = archiveBlock3Carry,
               let w = currentWriter {
                archiveBlock3Carry = nil
                try emitDenseStreamValues([carry, 0], to: w)
            }
            // Truncate dense stream output to authoritative punched length (drops remainder pad).
            if streamBlock3, let w = currentWriter {
                let lim = positiveLimit(currentPunchedSize, currentOriginalSize)
                if let lim, lim >= 0, block3Emitted > lim {
                    let over = block3Emitted - lim
                    try w.truncate(atOffset: UInt64(lim))
                    bytes = max(0, bytes - over)
                    block3Emitted = lim
                }
            }
            if needsBuffer {
                var stage: Data
                if currentPacking.isMultistate {
                    let byteCount = currentPunchedSize
                        ?? currentOriginalSize
                        ?? 0
                    // For raw dense without punched=, estimate from column count.
                    let count = byteCount > 0
                        ? byteCount
                        : (currentPacking == .ternaryBlock3
                            ? (ternaryDigits.count / 2) * 3
                            : currentPacking == .quaternary
                                ? ternaryDigits.count * 2
                                : currentPacking == .octal
                                    ? ternaryDigits.count * 3
                                    : currentPacking == .hexadecimal
                                        ? ternaryDigits.count * 4
                                        : currentPacking == .base256
                                            ? base256Digits.count * 8
                                            : ternaryDigits.count)
                    if currentPacking == .base256 {
                        stage = unpackBase256(base256Digits, byteCount: count)
                    } else if currentPacking == .hexadecimal {
                        stage = unpackHexadecimal(ternaryDigits, byteCount: count)
                    } else if currentPacking == .octal {
                        stage = unpackOctal(ternaryDigits, byteCount: count)
                    } else if currentPacking == .quaternary {
                        let digits16 = ternaryDigits.map { UInt16(truncatingIfNeeded: $0) }
                        stage = unpackQuaternary(digits16, byteCount: count)
                    } else {
                        let chunk: Int
                        if currentPacking == .ternaryFull {
                            chunk = currentPackChunk
                                ?? preferredTernaryPackChunk(byteCount: count)
                        } else {
                            chunk = 0
                        }
                        let digits16 = ternaryDigits.map { UInt16(truncatingIfNeeded: $0) }
                        stage = unpackTernary(
                            digits16,
                            mode: currentPacking,
                            byteCount: count,
                            chunkBytes: chunk
                        )
                    }
                } else {
                    stage = punchedBuffer
                }
                if currentTransfer == .ascii85 {
                    stage = try ascii85Decode(stage)
                }
                if currentCompression != .none, currentCompression != .auto {
                    stage = try decompress(
                        stage,
                        kind: currentCompression,
                        expectedSize: currentOriginalSize ?? 0
                    )
                }
                if let dest = currentDest {
                    try stage.write(to: dest, options: .atomic)
                    bytes += Int64(stage.count)
                }
            }
            try closeCurrentWriter()
            currentPath = nil
            currentDest = nil
            currentCompression = .none
            currentTransfer = .identity
            currentOriginalSize = nil
            currentPacking = .binary
            currentPunchedSize = nil
            currentPackChunk = nil
            punchedBuffer = Data()
            ternaryDigits = []
            base256Digits = []
            needsBuffer = false
            streamBlock3 = false
            block3Emitted = 0
            archiveBlock3Carry = nil
        }

        func flushBlockIntoMember() throws {
            guard !blockCols.isEmpty || blockStored != nil else { return }
            if let st = blockStored, !blockCols.isEmpty {
                let integ = integrityData(for: blockCols[...])
                let crc = crc32(integ)
                let xor = xorParity(integ)
                let sum = sum8(integ)
                let lengthMismatch = st.len > 0 && st.len != blockCols.count
                let checksumMismatch = crc != st.crc || xor != st.xor || sum != st.sum
                if lengthMismatch || checksumMismatch {
                    failedBlocks += 1
                }
            }
            if !blockCols.isEmpty {
                if streamBlock3, let w = currentWriter {
                    if currentPacking.isBase256 {
                        try emitBase256Columns(blockCols.map(\.base256Bytes), to: w)
                    } else {
                        let vals: [UInt32]
                        if currentPacking.isHexadecimal {
                            vals = blockCols.map(\.hexadecimalValue)
                        } else if currentPacking.isOctal {
                            vals = blockCols.map(\.octalValue)
                        } else if currentPacking.isQuaternary {
                            vals = blockCols.map { UInt32($0.quaternaryValue) }
                        } else {
                            vals = blockCols.map { UInt32($0.ternaryValue) }
                        }
                        try emitDenseStreamValues(vals, to: w)
                    }
                } else if currentPacking.isMultistate {
                    for col in blockCols {
                        if currentPacking.isBase256 {
                            base256Digits.append(col.base256Bytes)
                        } else if currentPacking.isHexadecimal {
                            ternaryDigits.append(col.hexadecimalValue)
                        } else if currentPacking.isOctal {
                            ternaryDigits.append(col.octalValue)
                        } else if currentPacking.isQuaternary {
                            ternaryDigits.append(UInt32(col.quaternaryValue))
                        } else {
                            ternaryDigits.append(UInt32(col.ternaryValue))
                        }
                    }
                } else if needsBuffer {
                    let bin = Data(blockCols.map(\.byte))
                    let limit = streamingByteThreshold * 2
                    if punchedBuffer.count + bin.count > limit {
                        throw FormatError.io(
                            "Archive member “\(currentPath ?? "?")” exceeds safe buffer limit while restoring"
                        )
                    }
                    punchedBuffer.append(bin)
                } else if let w = currentWriter {
                    let bin = Data(blockCols.map(\.byte))
                    try w.write(contentsOf: bin)
                    bytes += Int64(bin.count)
                }
            }
            blockCols.removeAll(keepingCapacity: true)
            blockStored = nil
        }

        while let line = try readLine() {
            let t = line.trimmingCharacters(in: .whitespaces)
            if t.hasPrefix("# ===") { break }

            if t.hasPrefix("# @file") {
                try finishMember()
                let meta = TapeStreamReader.parseFileMarkerPublic(t)
                let safe = sanitizeArchivePath(meta.path)
                guard !safe.isEmpty else { continue }
                let dest = staging.appendingPathComponent(safe)
                try fm.createDirectory(at: dest.deletingLastPathComponent(), withIntermediateDirectories: true)
                if fm.fileExists(atPath: dest.path) { try fm.removeItem(at: dest) }

                currentPath = safe
                currentDest = dest
                currentCompression = meta.compression
                currentTransfer = meta.transfer
                currentOriginalSize = meta.size.map { Int($0) }
                currentPunchedSize = meta.punchedSize.map { Int($0) }
                currentPackChunk = meta.packChunk
                // Per-file packing wins; else archive header default.
                currentPacking = meta.packing != .binary ? meta.packing : headerPacking
                // Buffer when decompress/Base85 needed, or full ternary pack (needs all digits).
                // Raw block3 can stream-decode to disk.
                streamBlock3 =
                    (currentPacking == .ternaryBlock3
                        || currentPacking == .quaternary
                        || currentPacking == .octal
                        || currentPacking == .hexadecimal
                        || currentPacking == .base256)
                    && meta.compression == .none
                    && meta.transfer == .identity
                needsBuffer =
                    meta.compression != .none
                    || meta.transfer == .ascii85
                    || (currentPacking.isMultistate && !streamBlock3)
                punchedBuffer = Data()
                ternaryDigits = []
                base256Digits = []
                block3Emitted = 0
                if let punched = meta.punchedSize, punched > 0, needsBuffer {
                    // Refuse pathological members that would force multi-GB buffers.
                    if punched > Int64(streamingByteThreshold) * 2 {
                        throw FormatError.io(
                            "Archive member “\(safe)” punched size (\(punched)) exceeds safe buffer limit — file may be corrupt"
                        )
                    }
                    if currentPacking.isMultistate {
                        ternaryDigits.reserveCapacity(Int(min(punched, Int64(streamingByteThreshold))))
                    } else {
                        punchedBuffer.reserveCapacity(Int(min(punched, Int64(streamingByteThreshold))))
                    }
                }

                if !needsBuffer {
                    fm.createFile(atPath: dest.path, contents: nil)
                    currentWriter = try FileHandle(forWritingTo: dest)
                } else {
                    currentWriter = nil
                }

                fileCount += 1
                progress?(TapeProgress(
                    phase: "Extracting \(safe)",
                    unitsCompleted: bytes,
                    unitsTotal: totalHint
                ))
                continue
            }

            if t.hasPrefix("# @endfile") {
                // Optional: `# @endfile punched=N size=N` from stream archive members.
                let rest = String(t.dropFirst("# @endfile".count))
                for part in rest.split(separator: " ") {
                    let p = part.split(separator: "=", maxSplits: 1)
                    guard p.count == 2 else { continue }
                    let key = p[0].lowercased()
                    let val = String(p[1])
                    if key == "punched", let n = Int(val), n >= 0 {
                        currentPunchedSize = n
                    } else if key == "size", let n = Int(val), n >= 0 {
                        if currentOriginalSize == nil || (currentOriginalSize ?? 0) <= 0 {
                            currentOriginalSize = n
                        }
                    }
                }
                try finishMember()
                continue
            }

            if t.hasPrefix("# @block") {
                try flushBlockIntoMember()
                if let m = parseBlockMarker(t) {
                    blockStored = (m.crc, m.xor, m.sum, m.len)
                    blockCols = []
                    blockCols.reserveCapacity(max(m.len, defaultBlockSize))
                }
                continue
            }

            if t.hasPrefix("#") || t.isEmpty { continue }

            let tokenPart = t.split(separator: "#", maxSplits: 1)
                .first
                .map(String.init)?
                .trimmingCharacters(in: .whitespaces) ?? t
            let preferTernary = currentPacking.isTernary || headerPacking.isTernary
            let preferQuat = currentPacking.isQuaternary || headerPacking.isQuaternary
            let preferOct = currentPacking.isOctal || headerPacking.isOctal
            let preferHex = currentPacking.isHexadecimal || headerPacking.isHexadecimal
            let preferB256 = currentPacking.isBase256 || headerPacking.isBase256
            guard let col = parseColumnToken(
                tokenPart,
                preferTernary: preferTernary,
                preferQuaternary: preferQuat,
                preferOctal: preferOct,
                preferHexadecimal: preferHex,
                preferBase256: preferB256
            ) else { continue }
            blockCols.append(col)
            if let st = blockStored, st.len > 0, blockCols.count >= st.len {
                try flushBlockIntoMember()
            }
            progress?(TapeProgress(
                phase: currentPath.map { "Extracting \($0)" } ?? "Extracting",
                unitsCompleted: bytes,
                unitsTotal: totalHint
            ))
        }
        try finishMember()
        // Promote staged members into the destination only after a full successful extract.
        let staged = try fm.contentsOfDirectory(
            at: staging,
            includingPropertiesForKeys: nil,
            options: []
        )
        for item in staged {
            let target = destinationFolder.appendingPathComponent(item.lastPathComponent)
            if fm.fileExists(atPath: target.path) {
                try fm.removeItem(at: target)
            }
            try fm.moveItem(at: item, to: target)
        }
        progress?(TapeProgress(phase: "Done", unitsCompleted: bytes, unitsTotal: totalHint ?? bytes))
        return (fileCount, bytes, failedBlocks)
    }

    private static func sanitizeArchivePath(_ path: String) -> String {
        var p = path.replacingOccurrences(of: "\\", with: "/")
        while p.hasPrefix("/") { p = String(p.dropFirst()) }
        let parts = p.split(separator: "/").filter { $0 != ".." && $0 != "." && !$0.isEmpty }
        return parts.map(String.init).joined(separator: "/")
    }
}
