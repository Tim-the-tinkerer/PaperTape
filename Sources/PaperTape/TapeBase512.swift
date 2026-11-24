import Foundation

extension TapeEngine {
    /// MSB-first bit reservoir. Only finish pads, so chunk and block boundaries
    /// have no effect on the columns written.
    struct Base512Encoder {
        private var bits: UInt32 = 0
        private var count = 0

        mutating func append(_ data: Data, emit: (UInt32) throws -> Void) rethrows {
            for byte in data {
                bits = (bits << 8) | UInt32(byte)
                count += 8
                if count >= 9 {
                    count -= 9
                    try emit(bits >> count)
                    bits &= (1 << count) - 1
                }
            }
        }

        mutating func finish(emit: (UInt32) throws -> Void) rethrows {
            guard count > 0 else { return }
            try emit(bits << (9 - count))
            count = 0
            bits = 0
        }
    }

    struct Base512Decoder {
        private var bits: UInt32 = 0
        private var count = 0
        private var last: UInt32?
        private var columns: Int64 = 0
        private var bytes: Int64 = 0

        mutating func append(_ value: UInt32, to output: inout Data) {
            // Keep the final symbol until its exact number of payload bits is known.
            if let last { consume(last, width: 9, to: &output) }
            last = value
            columns += 1
        }

        mutating func finish(byteCount: Int64?, to output: inout Data) throws {
            guard let byteCount, byteCount >= 0,
                  columns == byteCount - byteCount / 9 else {
                throw base512Error("missing or incorrect punched size")
            }
            if let last {
                let padding = Int(byteCount % 9)
                guard last & ((1 << padding) - 1) == 0 else {
                    throw base512Error("nonzero padding")
                }
                consume(last >> padding, width: 9 - padding, to: &output)
            }
            guard count == 0, bytes == byteCount else {
                throw base512Error("incorrect decoded length")
            }
        }

        private mutating func consume(_ value: UInt32, width: Int, to output: inout Data) {
            bits = (bits << width) | value
            count += width
            while count >= 8 {
                count -= 8
                output.append(UInt8(bits >> count))
                bits &= (1 << count) - 1
                bytes += 1
            }
        }
    }

    static func base512Error(_ reason: String) -> FormatError {
        .io("Invalid v9 tape: \(reason)")
    }

    static func base512Columns(from data: Data) -> [Column] {
        var encoder = Base512Encoder()
        var columns: [Column] = []
        encoder.append(data) { columns.append(Column(id: columns.count, base512Value: $0)) }
        encoder.finish { columns.append(Column(id: columns.count, base512Value: $0)) }
        return columns
    }

    static func parseBase512Token(_ token: String) -> Column? {
        let glyphs = Array(token.utf8)
        guard glyphs.count == 10, glyphs[3] == 111 else { return nil }
        var value: UInt32 = 0
        var bit = 0
        for (index, glyph) in glyphs.enumerated() where index != 3 {
            guard glyph == 46 || glyph == 42 else { return nil }
            if glyph == 42 { value |= 1 << bit }
            bit += 1
        }
        return Column(id: 0, base512Value: value)
    }

    static func validateBase512Block(
        _ columns: [Column], stored: (crc: UInt32, xor: UInt8, sum: UInt8, len: Int)?
    ) throws {
        let data = integrityData(for: columns)
        guard let stored, stored.len > 0, stored.len == columns.count,
              crc32(data) == stored.crc, xorParity(data) == stored.xor,
              sum8(data) == stored.sum else {
            throw base512Error("missing or damaged integrity block")
        }
    }

    static func base512BlockText(_ columns: [Column], index: Int, offset: Int) -> String {
        let data = integrityData(for: columns)
        return "# @block \(index) off=\(offset) len=\(columns.count) "
            + String(format: "crc32=%08X xor=%02X sum8=%02X\n", crc32(data), xorParity(data), sum8(data))
            + columns.map { visualToken(for: $0, style: .ascii) + "\n" }.joined()
    }
}

/// Writes bounded integrity blocks while retaining the encoder's partial symbol.
final class Base512BlockWriter {
    private let handle: FileHandle
    private let blockSize: Int
    private var encoder = TapeEngine.Base512Encoder()
    private var pending: [TapeEngine.Column] = []
    private(set) var columns = 0
    private(set) var blocks = 0

    init(handle: FileHandle, blockSize: Int) {
        self.handle = handle
        self.blockSize = blockSize
    }

    func append(_ data: Data, cancel: TapeEngine.EncodeCancelToken?) throws {
        try encoder.append(data) { [self] value in
            try enqueue(value, cancel: cancel)
        }
    }

    func finish() throws {
        try encoder.finish { [self] value in try enqueue(value, cancel: nil) }
        try flush()
    }

    private func enqueue(_ value: UInt32, cancel: TapeEngine.EncodeCancelToken?) throws {
        pending.append(TapeEngine.Column(id: 0, base512Value: value))
        if pending.count == blockSize {
            try cancel?.throwIfCancelled()
            try flush()
        }
    }

    private func flush() throws {
        guard !pending.isEmpty else { return }
        let text = TapeEngine.base512BlockText(pending, index: blocks, offset: columns)
        try handle.write(contentsOf: Data(text.utf8))
        columns += pending.count
        blocks += 1
        pending.removeAll(keepingCapacity: true)
    }
}

extension TapeEngine {
    static func base512SelfTest() -> [String] {
        var failures: [String] = []
        func check(_ condition: Bool, _ description: String) {
            if !condition { failures.append("v9: \(description)") }
        }
        func reject(_ data: Data, _ description: String) {
            do {
                _ = try deserialize(data).restoredData()
                failures.append("v9 accepted \(description)")
            } catch {
                // Expected rejection.
            }
        }

        do {
            check(TapeFileFormat.defaultWrite == .v7, "default format changed")
            for value in UInt32(0)...511 {
                let column = Column(id: 0, base512Value: value)
                let token = visualToken(for: column, style: .ascii)
                check(parseBase512Token(token) == column, "symbol \(value)")
            }
            check(base512Columns(from: Data([0x80, 0xFF])).map(\.base512Value) == [257, 508],
                  "MSB-first reference vector")
            for count in 0...20 {
                let payload = Data((0..<count).map { UInt8(truncatingIfNeeded: $0 * 31 + 7) })
                for transfer in [TransferEncoding.identity, .ascii85] {
                    let doc = encode(data: payload, originalName: "binary.bin", compression: .none, transferEncoding: transfer)
                    let roundTrip = try deserialize(serialize(doc, fileFormat: .v9))
                    let restored = try roundTrip.restoredData()
                    check(restored == payload, "length \(count), transfer \(transfer)")
                }
            }
            let payload = Data(repeating: 0xA5, count: 8193)
            let doc = encode(data: payload, originalName: "compressed.bin", compression: .lzfse, transferEncoding: .ascii85)
            let roundTrip = try deserialize(serialize(doc, fileFormat: .v9))
            let restored = try roundTrip.restoredData()
            check(restored == payload, "compression and Base85")
            check(terminalPaper(for: roundTrip, maxColumns: 2).contains("ch9"), "terminal ninth row")
            check(TapeImageExporter.renderPNG(document: roundTrip, maxColumns: 2) != nil, "PNG export")

            let oneByte = encode(data: Data([0x80]), originalName: "one.bin", compression: .none)
            let valid = String(decoding: serialize(oneByte, fileFormat: .v9), as: UTF8.self)
            let token = visualToken(for: Column(id: 0, base512Value: 256))
            reject(Data(valid.replacingOccurrences(of: token, with: "....o.....").utf8), "bad sprocket")
            reject(Data(valid.replacingOccurrences(of: token, with: visualToken(for: Column(id: 0, base512Value: 0))).utf8),
                   "changed ninth channel")
            reject(Data(valid.replacingOccurrences(of: "# punched-size: 1", with: "# punched-size: unknown").utf8),
                   "missing exact length")
            reject(Data(valid.replacingOccurrences(of: token + "\n", with: "").utf8), "missing column")
            reject(Data(valid.replacingOccurrences(of: "# size: 1", with: "# size: 0").utf8),
                   "zero original length with nonempty payload")
            let header = valid.components(separatedBy: "# @block")[0]
            let nonzeroPadding = base512BlockText([Column(id: 0, base512Value: 257)], index: 0, offset: 0)
            reject(Data((header + nonzeroPadding).utf8), "nonzero padding with valid checksums")

            let root = FileManager.default.temporaryDirectory
                .appendingPathComponent("PaperTapeV9Tests-\(UUID().uuidString)")
            let source = root.appendingPathComponent("source")
            let tape = root.appendingPathComponent("archive.Tape")
            let output = root.appendingPathComponent("output")
            try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: root) }
            try payload.write(to: source.appendingPathComponent("compressed.bin"))
            try Data().write(to: source.appendingPathComponent("empty.bin"))
            _ = try encodeFolder(root: source, to: tape, compression: .lzfse, transfer: .ascii85, fileFormat: .v9)
            let archive = try Data(contentsOf: tape)
            let archivePreview = try deserialize(archive)
            check(archivePreview.isArchive && archivePreview.columns.allSatisfy(\.isBase512),
                  "archive preview columns")
            let extracted = try extractFolder(from: tape, to: output)
            let restoredMember = try Data(contentsOf: output.appendingPathComponent("compressed.bin"))
            let restoredEmpty = try Data(contentsOf: output.appendingPathComponent("empty.bin"))
            check(extracted.files == 2 && extracted.failedBlocks == 0 &&
                  restoredMember == payload && restoredEmpty.isEmpty, "archive round trip")
            let truncated = String(decoding: archive, as: UTF8.self)
                .components(separatedBy: "# === archive complete ===")[0]
            try Data(truncated.utf8).write(to: tape)
            do {
                _ = try extractFolder(from: tape, to: output)
                failures.append("v9 accepted a truncated archive")
            } catch {
                // Expected rejection.
            }

            let malformedStream = Data((header + nonzeroPadding).utf8)
            try malformedStream.write(to: tape)
            let existing = root.appendingPathComponent("existing.bin")
            try payload.write(to: existing)
            do {
                _ = try decodeFileStreaming(from: tape, to: existing)
                failures.append("v9 streamed nonzero padding with valid checksums")
            } catch {
                let preserved = try Data(contentsOf: existing)
                check(preserved == payload, "failed stream must preserve existing destination")
            }
        } catch {
            failures.append("v9: \(error.localizedDescription)")
        }
        return failures
    }
}
