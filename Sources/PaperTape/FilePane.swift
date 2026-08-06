import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// Encode arbitrary files into `.Tape` punched-paper containers, or restore them.
struct FilePane: View {
    /// Shared with the main toolbar so Off / Auto stay consistent across tabs.
    @Binding var compression: TapeEngine.CompressionKind
    @Binding var base85: Bool
    @Binding var tapeFileFormat: TapeEngine.TapeFileFormat
    /// Shared with main-window drop encode so jobs cannot overlap.
    @Binding var externalBusy: Bool
    var externalOpenURL: URL?
    var externalOpenGeneration: Int = 0
    var onExternalOpenHandled: () -> Void
    var onOpenDocument: (TapeEngine.TapeDocument, URL?) -> Void
    var onStatus: (String) -> Void

    @State private var isBusy = false
    @State private var lastEncodedURL: URL?
    @State private var lastDecodedURL: URL?
    @State private var lastInfo: String?
    @State private var dropHighlight = false
    @State private var progressFraction: Double?
    @State private var progressLabel: String = ""

    @State private var encodeDropHighlight = false
    @State private var decodeDropHighlight = false
    @State private var lastHandledExternalGeneration: Int = -1
    @State private var encodeCancelToken: TapeEngine.EncodeCancelToken?

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    intro
                    encodeCard
                    decodeCard
                    formatSpec
                }
                .padding(20)
                .frame(maxWidth: 720)
                .frame(maxWidth: .infinity)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            Divider()
            footer
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .contentShape(Rectangle())
        .onFileDrop(isTargeted: $dropHighlight) { url in
            routeDroppedFile(url)
        }
        // External open: parent sets URL then bumps generation. React to both so we never
        // miss an open when generation changes before the URL binding lands (or vice versa).
        .onChange(of: externalOpenGeneration) { _ in
            acceptExternalOpenIfNeeded()
        }
        .onChange(of: externalOpenURL) { url in
            if url != nil {
                acceptExternalOpenIfNeeded()
            }
        }
        .onAppear {
            acceptExternalOpenIfNeeded()
        }
        .overlay {
            if dropHighlight || encodeDropHighlight || decodeDropHighlight {
                ZStack {
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(AppTheme.accent.opacity(0.08))
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .strokeBorder(AppTheme.accent, style: StrokeStyle(lineWidth: 2, dash: [8, 4]))
                    Text(dropOverlayLabel)
                        .font(.headline)
                        .foregroundStyle(AppTheme.accent)
                        .padding(12)
                        .background(Capsule().fill(Color(nsColor: .windowBackgroundColor).opacity(0.92)))
                }
                .padding(8)
                .allowsHitTesting(false)
            }
        }
    }

    private var dropOverlayLabel: String {
        if decodeDropHighlight {
            return "Drop .Tape to restore original"
        }
        if encodeDropHighlight {
            return "Drop file to punch as .Tape"
        }
        return "Drop to punch · drop .Tape to decode"
    }

    private var intro: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Paper tape files (.\(TapeEngine.fileExtension))", systemImage: "scroll")
                .font(.title3.weight(.semibold))
                .foregroundStyle(AppTheme.accent)

            Text(
                "Files and folders become punched columns (v1–v8 formats). Large files stream to disk; folders pack as multi-file archives. "
                    + "Suggested save names include the format version (e.g. report-v4.Tape)."
            )
            .font(.callout)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var encodeCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("Encode → .Tape")
                    .font(.headline)
                Spacer()
                Text("Drop file or folder")
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(.secondary)
            }

            Text("Compress / Base85 apply to each file under 4 MiB (including every file inside a folder pack). Larger files stream raw. Folders use mode: archive with one @file section per path.")
                .font(.caption)
                .foregroundStyle(.secondary)

            HStack(spacing: 12) {
                Text("Compress")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                Picker("Compress", selection: $compression) {
                    ForEach(TapeEngine.CompressionKind.uiCases) { kind in
                        Text(kind.displayName).tag(kind)
                    }
                }
                .labelsHidden()
                .fixedSize(horizontal: true, vertical: false)
                .help(compression.help)

                Toggle("Base85 (+25%)", isOn: $base85)
                    .toggleStyle(.checkbox)
                    .help(TapeEngine.TransferEncoding.ascii85.help)

                Picker("Format", selection: $tapeFileFormat) {
                    ForEach(TapeEngine.TapeFileFormat.uiCases) { fmt in
                        Text(fmt.displayName).tag(fmt)
                    }
                }
                .labelsHidden()
                .fixedSize(horizontal: true, vertical: false)
                .help(tapeFileFormat.help)
            }

            HStack(spacing: 10) {
                Button {
                    pickAndEncode(filesOnly: true)
                } label: {
                    Label("Choose file…", systemImage: "hammer")
                }
                .disabled(anyBusy)
                .buttonStyle(.borderedProminent)
                .tint(AppTheme.accent)

                Button {
                    pickAndEncode(filesOnly: false)
                } label: {
                    Label("Choose folder…", systemImage: "folder")
                }
                .disabled(anyBusy)

                Button {
                    pickAndOpenTape()
                } label: {
                    Label("Open .Tape…", systemImage: "scroll")
                }
                .disabled(anyBusy)
                .help("Load a .Tape into the Tape tab (strip + integrity banner).")
            }

            dropHint("Drop a file or folder here")
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(cardBackground)
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(encodeDropHighlight ? AppTheme.accent : Color.clear, lineWidth: 2)
        )
        .onFileDrop(isTargeted: $encodeDropHighlight) { url in
            if TapeEngine.isTapeURL(url) {
                openTapeInApp(url)
            } else {
                encodeURL(url, promptSave: true)
            }
        }
    }

    private var decodeCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("Decode .Tape → original")
                    .font(.headline)
                Spacer()
                Text("Drop a .Tape file")
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(.secondary)
            }

            Text("Restores a single file, or extracts a folder archive into a new directory. Large tapes stream to disk.")
                .font(.caption)
                .foregroundStyle(.secondary)

            HStack(spacing: 10) {
                Button {
                    pickAndOpenTape()
                } label: {
                    Label("Open in Tape tab…", systemImage: "scroll")
                }
                .disabled(anyBusy)
                .buttonStyle(.borderedProminent)
                .tint(AppTheme.accent)
                .help("Inspect punched columns and integrity without extracting.")

                Button {
                    pickAndDecode()
                } label: {
                    Label("Restore original…", systemImage: "tray.and.arrow.down")
                }
                .disabled(anyBusy)
            }

            dropHint("Drop a .Tape file here")
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(cardBackground)
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(decodeDropHighlight ? AppTheme.accent : Color.clear, lineWidth: 2)
        )
        .onFileDrop(isTargeted: $decodeDropHighlight) { url in
            if TapeEngine.isTapeURL(url) {
                decodeTape(at: url, promptSave: true)
            } else {
                lastInfo = "Not a .Tape — encoding instead."
                onStatus(lastInfo ?? "")
                encodeURL(url, promptSave: true)
            }
        }
    }

    private func dropHint(_ text: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "arrow.down.doc")
                .foregroundStyle(AppTheme.accent)
            Text(text)
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer()
        }
        .padding(10)
        .frame(maxWidth: .infinity)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(style: StrokeStyle(lineWidth: 1, dash: [5, 4]))
                .foregroundStyle(AppTheme.accent.opacity(0.45))
        )
    }

    private var formatSpec: some View {
        GroupBox("Digital representation") {
            VStack(alignment: .leading, spacing: 6) {
                Text("Layout (edge → edge):  ch1  ch2  ch3  ○feed  ch4  ch5  ch6  ch7  ch8")
                    .font(.system(.caption, design: .monospaced))
                Text("Glyphs:  \(String(TapeEngine.holeGlyph)) = punched hole · \(String(TapeEngine.blankGlyph)) = blank · \(String(TapeEngine.sprocketGlyph)) = sprocket")
                    .font(.system(.caption, design: .monospaced))
                Text("Bit order: channel 1 = bit 0 (LSB), channel 8 = bit 7 (MSB)")
                    .font(.caption)
                Text("File: UTF-8 header + one column token per line (v1 may add a terminal-paper preview footer)")
                    .font(.caption)
                Text("Pipeline: compress → Base85 → punch. Blocks: CRC-32 + XOR + SUM8 every 64 columns.")
                    .font(.caption)
                Text("Damaged text: check # @block lines — failing CRC/XOR/SUM8 names the bad block.")
                    .font(.caption)
            }
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(4)
        }
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: 6) {
            if isBusy {
                HStack(alignment: .center, spacing: 12) {
                    VStack(alignment: .leading, spacing: 4) {
                        if let fraction = progressFraction {
                            ProgressView(value: fraction)
                                .progressViewStyle(.linear)
                            Text(progressLabel)
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        } else {
                            HStack(spacing: 8) {
                                ProgressView()
                                    .controlSize(.small)
                                Text(progressLabel.isEmpty ? "Working…" : progressLabel)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(2)
                            }
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)

                    if encodeCancelToken != nil {
                        Button("Cancel") {
                            encodeCancelToken?.cancel()
                            progressLabel = "Cancelling…"
                            lastInfo = "Cancelling…"
                            onStatus("Cancelling…")
                        }
                        .controlSize(.small)
                        .keyboardShortcut(.cancelAction)
                    }
                }
            }
            HStack {
                if !isBusy {
                    if let lastInfo {
                        Text(lastInfo)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(3)
                    } else {
                        Text("Drop files/folders to punch · drop .Tape to restore.")
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                    }
                }
                Spacer()
                if let url = lastEncodedURL {
                    Button("Show encoded") {
                        NSWorkspace.shared.activateFileViewerSelecting([url])
                    }
                    .font(.caption)
                }
                if let url = lastDecodedURL {
                    Button("Show restored") {
                        NSWorkspace.shared.activateFileViewerSelecting([url])
                    }
                    .font(.caption)
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    private var cardBackground: some View {
        RoundedRectangle(cornerRadius: 12, style: .continuous)
            .fill(AppTheme.card)
            .shadow(color: .black.opacity(0.04), radius: 4, y: 1)
    }

    // MARK: - Actions

    /// Pick up parent-provided externalOpenURL once per generation.
    private func acceptExternalOpenIfNeeded() {
        guard let url = externalOpenURL else { return }
        // Ignore duplicate delivery of the same generation (onAppear + onChange race).
        if lastHandledExternalGeneration == externalOpenGeneration, externalOpenGeneration != 0 {
            return
        }
        lastHandledExternalGeneration = externalOpenGeneration
        // Clear parent URL only after we have a local copy and accepted this generation.
        onExternalOpenHandled()
        routeDroppedFile(url)
    }

    private func routeDroppedFile(_ url: URL) {
        if isBusy || externalBusy {
            OpenFileBridge.enqueueWithoutFlush(url)
            lastInfo = "Busy — queued \(url.lastPathComponent)"
            onStatus(lastInfo ?? "")
            return
        }
        if isDirectory(url) {
            encodeURL(url, promptSave: true)
        } else if TapeEngine.isTapeURL(url) {
            openTapeInApp(url)
        } else {
            encodeURL(url, promptSave: true)
        }
    }

    /// Call after every job finishes so multi-drop / multi-open can proceed serially.
    /// Only call after `beginBusy()` (or equivalent) — never after a cancelled save panel
    /// that never started a job (that would clear another job’s `externalBusy`).
    private func finishJobAndFlushQueue() {
        isBusy = false
        externalBusy = false
        encodeCancelToken = nil
        clearProgress()
        if OpenFileBridge.hasPending() {
            DispatchQueue.main.async {
                OpenFileBridge.requestFlush()
            }
        }
    }

    private func beginBusy() {
        isBusy = true
        externalBusy = true
    }

    /// UI disable for any encode/open in progress (this pane or ContentView drop).
    private var anyBusy: Bool { isBusy || externalBusy }

    private func pickAndEncode(filesOnly: Bool) {
        let panel = NSOpenPanel()
        panel.canChooseFiles = filesOnly
        panel.canChooseDirectories = !filesOnly
        panel.allowsMultipleSelection = false
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            encodeURL(url, promptSave: true)
        }
    }

    private func pickAndDecode() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [TapeEngine.contentType, .plainText, .data]
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            decodeTape(at: url, promptSave: true)
        }
    }

    /// Open a .Tape for inspection on the Tape tab (does not extract the payload).
    private func pickAndOpenTape() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [TapeEngine.contentType, .plainText, .data]
        panel.message = "Choose a .Tape file to open in the Tape tab"
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            openTapeInApp(url)
        }
    }

    private func isDirectory(_ url: URL) -> Bool {
        let accessed = url.startAccessingSecurityScopedResource()
        defer { if accessed { url.stopAccessingSecurityScopedResource() } }
        var isDir: ObjCBool = false
        if FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir) {
            return isDir.boolValue
        }
        return (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
    }

    private func encodeURL(_ url: URL, promptSave: Bool) {
        if isBusy || externalBusy {
            OpenFileBridge.enqueueWithoutFlush(url)
            lastInfo = "Busy — queued \(url.lastPathComponent)"
            onStatus(lastInfo ?? "")
            return
        }
        if isDirectory(url) {
            encodeFolder(at: url, promptSave: promptSave)
        } else {
            encodeFile(at: url, promptSave: promptSave)
        }
    }

    private func reportProgress(_ p: TapeProgress) {
        DispatchQueue.main.async {
            progressLabel = p.phase
            progressFraction = p.fraction
        }
    }

    private func clearProgress() {
        progressFraction = nil
        progressLabel = ""
    }

    private func openTapeInApp(_ url: URL) {
        if isBusy || externalBusy {
            OpenFileBridge.enqueueWithoutFlush(url)
            lastInfo = "Busy — queued \(url.lastPathComponent)"
            onStatus(lastInfo ?? "")
            return
        }
        beginBusy()
        lastInfo = "Opening…"
        clearProgress()
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                var doc = try TapeEngine.loadForDisplay(from: url)
                if doc.integrity == nil, !doc.columns.isEmpty {
                    doc.integrity = TapeEngine.buildIntegrityReport(
                        for: doc.columns,
                        blockSize: doc.blockSize > 0 ? doc.blockSize : TapeEngine.defaultBlockSize,
                        hasMarkers: false
                    )
                }
                DispatchQueue.main.async {
                    finishJobAndFlushQueue()
                    var msg = "Opened \(url.lastPathComponent) · \(doc.columns.count) columns"
                    if doc.isArchive {
                        msg += " · folder archive (use Restore to extract)"
                    } else if doc.isPartialPreview {
                        msg += " · partial preview (integrity not full-file)"
                    } else if let rep = doc.integrity, rep.checked {
                        msg += " · " + (rep.allOK ? "integrity OK" : rep.summary)
                    } else if doc.isEmpty {
                        msg += " · empty"
                    }
                    lastInfo = msg
                    onOpenDocument(doc, url)
                    onStatus(msg)
                }
            } catch {
                DispatchQueue.main.async {
                    finishJobAndFlushQueue()
                    lastInfo = error.localizedDescription
                    onStatus(error.localizedDescription)
                }
            }
        }
    }

    /// Best-effort load after writing a .Tape. Never returns empty when the file has columns.
    private static func loadTapeForUI(from url: URL, expectedColumns: Int64) -> TapeEngine.TapeDocument {
        if let doc = try? TapeEngine.loadForDisplay(from: url), !doc.isEmpty {
            return doc
        }
        if let data = try? Data(contentsOf: url, options: [.mappedIfSafe]),
           let doc = try? TapeEngine.deserialize(data), !doc.isEmpty {
            return doc
        }
        // Last resort: column-token preview (handles ternary v4 without full unpack).
        if expectedColumns > 0,
           let doc = try? TapeEngine.loadForDisplay(from: url, maxColumns: min(Int(expectedColumns), 8_192)),
           !doc.isEmpty {
            return doc
        }
        return .empty
    }

    private func encodeFile(at url: URL, promptSave: Bool) {
        let preferredCompression = compression
        let preferredTransfer: TapeEngine.TransferEncoding = base85 ? .ascii85 : .identity
        let preferredFormat = tapeFileFormat

        let finishWrite: (URL) -> Void = { dest in
            beginBusy()
            let cancelToken = TapeEngine.EncodeCancelToken()
            encodeCancelToken = cancelToken
            lastInfo = "Encoding \(url.lastPathComponent)…"
            onStatus(lastInfo ?? "")
            clearProgress()
            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    let accessed = url.startAccessingSecurityScopedResource()
                    defer { if accessed { url.stopAccessingSecurityScopedResource() } }
                    let result = try TapeEngine.encodeFileStreaming(
                        from: url,
                        to: dest,
                        compression: preferredCompression,
                        transfer: preferredTransfer,
                        fileFormat: preferredFormat,
                        cancel: cancelToken,
                        progress: { [self] p in reportProgress(p) }
                    )
                    try cancelToken.throwIfCancelled()
                    // Always put something on the Tape tab: prefer disk reload, never leave empty
                    // when encode produced columns.
                    let preview = Self.loadTapeForUI(from: dest, expectedColumns: result.columns)
                    DispatchQueue.main.async {
                        finishJobAndFlushQueue()
                        lastEncodedURL = dest
                        onOpenDocument(preview, dest)
                        let mode = result.usedStream ? "streamed" : "encoded"
                        var msg = "Punched \(url.lastPathComponent) → \(dest.lastPathComponent) · \(result.columns) cols (\(mode))"
                        if preview.isPartialPreview {
                            msg += " · partial preview"
                        } else if let rep = preview.integrity, rep.checked {
                            msg += " · " + (rep.allOK ? "integrity OK" : rep.summary)
                        }
                        if preview.isEmpty, result.columns > 0 {
                            msg += " · preview empty — use Open .Tape… on Files"
                        }
                        lastInfo = msg
                        onStatus(msg)
                    }
                } catch {
                    let cancelled = (error as? TapeEngine.FormatError)?.isCancellation == true
                        || cancelToken.isCancelled
                    if cancelled {
                        try? FileManager.default.removeItem(at: dest)
                    }
                    DispatchQueue.main.async {
                        finishJobAndFlushQueue()
                        lastInfo = cancelled
                            ? "Encode cancelled."
                            : "Encode failed: \(error.localizedDescription)"
                        onStatus(lastInfo ?? "")
                    }
                }
            }
        }

        if promptSave {
            // Do not set isBusy before the save panel — a cancelled panel used to leave
            // the UI stuck, and a missing external-open URL left status at "punching…".
            let suggested = TapeEngine.suggestedTapeFilename(
                stem: stem(of: url.lastPathComponent),
                format: preferredFormat
            )
            lastInfo = "Choose where to save \(suggested)…"
            onStatus(lastInfo ?? "")
            let panel = NSSavePanel()
            panel.allowedContentTypes = [TapeEngine.contentType, .plainText, .data]
            panel.nameFieldStringValue = suggested
            panel.canCreateDirectories = true
            panel.message = "Save punched file as a .Tape file"
            let handler: (NSApplication.ModalResponse) -> Void = { response in
                guard response == .OK, let dest = panel.url else {
                    // Panel never called beginBusy — do not clear externalBusy / steal another job.
                    lastInfo = "Save cancelled"
                    onStatus(lastInfo ?? "")
                    return
                }
                finishWrite(dest)
            }
            if let window = NSApp.keyWindow ?? NSApp.mainWindow ?? NSApp.windows.first(where: \.isVisible) {
                panel.beginSheetModal(for: window, completionHandler: handler)
            } else {
                panel.begin(completionHandler: handler)
            }
        } else {
            let dest = FileManager.default.temporaryDirectory
                .appendingPathComponent(
                    TapeEngine.suggestedTapeFilename(
                        stem: stem(of: url.lastPathComponent),
                        format: preferredFormat
                    )
                )
            finishWrite(dest)
        }
    }

    private func encodeFolder(at url: URL, promptSave: Bool) {
        let preferredCompression = compression
        let preferredTransfer: TapeEngine.TransferEncoding = base85 ? .ascii85 : .identity
        let preferredFormat = tapeFileFormat

        let run: (URL) -> Void = { dest in
            beginBusy()
            let cancelToken = TapeEngine.EncodeCancelToken()
            encodeCancelToken = cancelToken
            lastInfo = "Packing folder \(url.lastPathComponent)…"
            onStatus(lastInfo ?? "")
            clearProgress()
            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    let accessed = url.startAccessingSecurityScopedResource()
                    defer { if accessed { url.stopAccessingSecurityScopedResource() } }
                    let result = try TapeEngine.encodeFolder(
                        root: url,
                        to: dest,
                        compression: preferredCompression,
                        transfer: preferredTransfer,
                        fileFormat: preferredFormat,
                        cancel: cancelToken,
                        progress: { [self] p in reportProgress(p) }
                    )
                    try cancelToken.throwIfCancelled()
                    let preview = Self.loadTapeForUI(from: dest, expectedColumns: result.columns)
                    DispatchQueue.main.async {
                        finishJobAndFlushQueue()
                        lastEncodedURL = dest
                        onOpenDocument(preview, dest)
                        let ratio: String
                        if result.originalBytes > 0, result.columns < result.originalBytes {
                            let pct = Int((1.0 - Double(result.columns) / Double(result.originalBytes)) * 100)
                            ratio = " · payload −\(pct)%"
                        } else {
                            ratio = ""
                        }
                        lastInfo =
                            "Packed \(result.files) file(s) from \(url.lastPathComponent) → "
                            + "\(result.columns) cols\(ratio) · \(result.compressionNote) · \(dest.lastPathComponent)"
                        onStatus(lastInfo ?? "")
                    }
                } catch {
                    let cancelled = (error as? TapeEngine.FormatError)?.isCancellation == true
                        || cancelToken.isCancelled
                    if cancelled {
                        try? FileManager.default.removeItem(at: dest)
                    }
                    DispatchQueue.main.async {
                        finishJobAndFlushQueue()
                        lastInfo = cancelled
                            ? "Encode cancelled."
                            : "Folder encode failed: \(error.localizedDescription)"
                        onStatus(lastInfo ?? "")
                    }
                }
            }
        }

        if promptSave {
            let suggested = TapeEngine.suggestedTapeFilename(
                stem: url.lastPathComponent,
                format: preferredFormat
            )
            lastInfo = "Choose where to save \(suggested)…"
            onStatus(lastInfo ?? "")
            let panel = NSSavePanel()
            panel.allowedContentTypes = [TapeEngine.contentType, .plainText, .data]
            panel.nameFieldStringValue = suggested
            panel.canCreateDirectories = true
            panel.message = "Save punched folder archive as a .Tape file"
            let handler: (NSApplication.ModalResponse) -> Void = { response in
                guard response == .OK, let dest = panel.url else {
                    lastInfo = "Save cancelled"
                    onStatus(lastInfo ?? "")
                    finishJobAndFlushQueue()
                    return
                }
                run(dest)
            }
            if let window = NSApp.keyWindow ?? NSApp.mainWindow ?? NSApp.windows.first(where: \.isVisible) {
                panel.beginSheetModal(for: window, completionHandler: handler)
            } else {
                panel.begin(completionHandler: handler)
            }
        } else {
            run(FileManager.default.temporaryDirectory
                .appendingPathComponent(
                    TapeEngine.suggestedTapeFilename(
                        stem: url.lastPathComponent,
                        format: preferredFormat
                    )
                ))
        }
    }

    /// Restore a .Tape: single file, stream, or folder archive.
    private func decodeTape(at url: URL, promptSave: Bool) {
        if isBusy {
            OpenFileBridge.enqueueWithoutFlush(url)
            lastInfo = "Busy — queued \(url.lastPathComponent)"
            onStatus(lastInfo ?? "")
            return
        }
        beginBusy()
        lastInfo = "Reading \(url.lastPathComponent)…"
        clearProgress()

        DispatchQueue.global(qos: .userInitiated).async {
            do {
                let reader = try TapeStreamReader(reading: url)
                try reader.readHeader()

                if reader.mode == "archive" {
                    DispatchQueue.main.async {
                        self.promptExtractArchive(from: url, defaultName: reader.headerName)
                    }
                    return
                }

                let suggested = reader.headerName.isEmpty ? "decoded.bin" : reader.headerName
                DispatchQueue.main.async {
                    if promptSave {
                        let panel = NSSavePanel()
                        panel.nameFieldStringValue = suggested
                        panel.canCreateDirectories = true
                        panel.begin { response in
                            guard response == .OK, let dest = panel.url else {
                                finishJobAndFlushQueue()
                                return
                            }
                            self.performDecodeFile(from: url, to: dest)
                        }
                    } else {
                        let dest = FileManager.default.temporaryDirectory.appendingPathComponent(suggested)
                        self.performDecodeFile(from: url, to: dest)
                    }
                }
            } catch {
                DispatchQueue.main.async {
                    finishJobAndFlushQueue()
                    lastInfo = "Could not read \(url.lastPathComponent): \(error.localizedDescription)"
                    onStatus(lastInfo ?? "")
                }
            }
        }
    }

    private func promptExtractArchive(from tapeURL: URL, defaultName: String) {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = true
        panel.prompt = "Extract Here"
        panel.message = "Choose a folder to extract the archive “\(defaultName)” into."
        panel.begin { response in
            guard response == .OK, let parent = panel.url else {
                finishJobAndFlushQueue()
                return
            }
            let dest = parent.appendingPathComponent(defaultName.isEmpty ? "TapeArchive" : defaultName)
            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    let result = try TapeEngine.extractFolder(
                        from: tapeURL,
                        to: dest,
                        progress: { [self] p in reportProgress(p) }
                    )
                    DispatchQueue.main.async {
                        finishJobAndFlushQueue()
                        lastDecodedURL = dest
                        var msg = "Extracted \(result.files) file(s), \(result.bytes) bytes → \(dest.lastPathComponent)"
                        if result.failedBlocks > 0 {
                            msg += " · \(result.failedBlocks) integrity block(s) failed"
                        }
                        lastInfo = msg
                        onStatus(msg)
                    }
                } catch {
                    DispatchQueue.main.async {
                        finishJobAndFlushQueue()
                        lastInfo = "Extract failed: \(error.localizedDescription)"
                        onStatus(lastInfo ?? "")
                    }
                }
            }
        }
    }

    private func performDecodeFile(from tapeURL: URL, to dest: URL) {
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                let result = try TapeEngine.decodeFileStreaming(
                    from: tapeURL,
                    to: dest,
                    progress: { [self] p in reportProgress(p) }
                )
                // Always try to show the .Tape on the Tape tab after restore.
                let preview = Self.loadTapeForUI(from: tapeURL, expectedColumns: result.bytes)
                DispatchQueue.main.async {
                    finishJobAndFlushQueue()
                    lastDecodedURL = dest
                    if !preview.isEmpty {
                        onOpenDocument(preview, tapeURL)
                    }
                    var msg = "Restored \(result.bytes) byte(s) → \(dest.lastPathComponent)"
                    if !result.integrityOK {
                        msg += " · integrity issues (\(result.failedBlocks) block(s))"
                    }
                    lastInfo = msg
                    onStatus(msg)
                }
            } catch {
                DispatchQueue.main.async {
                    finishJobAndFlushQueue()
                    lastInfo = "Decode failed: \(error.localizedDescription)"
                    onStatus(lastInfo ?? "")
                }
            }
        }
    }

    private func stem(of filename: String) -> String {
        let ns = filename as NSString
        let ext = ns.pathExtension
        if ext.isEmpty { return filename }
        return ns.deletingPathExtension
    }
}
