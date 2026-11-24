import AppKit
import SwiftUI
import UniformTypeIdentifiers

enum AppTheme {
    /// Warm teleprinter paper / ink accent.
    static let accent = Color(red: 0.55, green: 0.38, blue: 0.16)
    static let accentSoft = Color(red: 0.55, green: 0.38, blue: 0.16).opacity(0.12)
    static let ink = Color(red: 0.18, green: 0.14, blue: 0.10)
    static let paper = Color(red: 0.93, green: 0.88, blue: 0.74)
    static let card = Color(nsColor: .controlBackgroundColor)
    static let marble = Color(nsColor: .windowBackgroundColor)
}

struct ContentView: View {
    @State private var mode: WorkMode = .encode
    @State private var plainText = ""
    @State private var document: TapeEngine.TapeDocument = .empty
    @State private var sourceURL: URL?
    @State private var statusMessage: String?
    @State private var copied = false
    @State private var columnWidth: CGFloat = 18
    @State private var showTerminalPreview = true
    @State private var compression: TapeEngine.CompressionKind = .auto
    @State private var base85: Bool = false
    /// .Tape write dialect: v7 hex (default) … v1 annotated.
    @State private var tapeFileFormat: TapeEngine.TapeFileFormat = .defaultWrite
    @State private var externalOpenURL: URL?
    @State private var externalOpenGeneration = 0
    @State private var recomputeGeneration = 0
    @State private var windowDropHighlight = false
    /// When true, plainText / preference onChange must not overwrite a loaded document.
    @State private var suppressLiveRecompute = false
    /// True while a drop/open encode (file or folder) is showing a panel or writing.
    @State private var dropEncodeInFlight = false
    /// Shared with Files tab so encode jobs cannot run concurrently.
    @State private var filesEncodeBusy = false
    @State private var dropProgressFraction: Double?
    @State private var dropProgressLabel: String = ""
    @State private var dropEncodeCancelToken: TapeEngine.EncodeCancelToken?
    @FocusState private var textFocused: Bool

    /// Soft limit for live typing encode (bytes). Larger pastes still encode, but off the hot path.
    private static let liveEncodeSoftLimit = 256_000

    private enum WorkMode: String, CaseIterable, Identifiable {
        case encode = "Encode"
        case tape = "Tape"
        case files = "Files"
        case about = "About"
        var id: String { rawValue }
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            mainPane
            Divider()
            footer
        }
        .frame(minWidth: 820, minHeight: 560)
        .background(AppTheme.marble)
        // SwiftUI fallback when the AppKit catcher does not receive the drop.
        .onFileDrop(isTargeted: $windowDropHighlight) { url in
            // Go straight to loadURL (also used by the AppKit catcher via OpenFileBridge).
            // Avoid double-queue when both paths fire: if a job is already in flight, queue.
            if dropEncodeInFlight {
                OpenFileBridge.enqueueWithoutFlush(url)
                statusMessage = "Busy — queued \(url.lastPathComponent)"
            } else {
                statusMessage = "Dropped \(url.lastPathComponent)…"
                loadURL(url)
            }
        }
        .overlay {
            if windowDropHighlight {
                ZStack {
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(AppTheme.accent.opacity(0.10))
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .strokeBorder(AppTheme.accent, style: StrokeStyle(lineWidth: 2, dash: [8, 4]))
                    Text("Drop a file to punch · drop .Tape to open")
                        .font(.headline)
                        .foregroundStyle(AppTheme.accent)
                        .padding(12)
                        .background(Capsule().fill(Color(nsColor: .windowBackgroundColor).opacity(0.92)))
                }
                .padding(12)
                .allowsHitTesting(false)
            }
        }
        .onAppear {
            DropSupport.installDragSessionMonitorsIfNeeded()
            textFocused = true
            recomputeFromText()
            consumePendingOpens()
        }
        .onReceive(NotificationCenter.default.publisher(for: OpenFileBridge.flushNotification)) { _ in
            consumePendingOpens()
        }
        .onReceive(NotificationCenter.default.publisher(for: .paperTapeFileDragTargeted)) { note in
            windowDropHighlight = (note.userInfo?["targeted"] as? Bool) ?? false
        }
        .onChange(of: plainText) { _ in
            guard !suppressLiveRecompute else { return }
            if mode == .encode {
                scheduleRecompute()
            }
        }
        .onChange(of: compression) { _ in
            guard !suppressLiveRecompute else { return }
            // Apply immediately so Off cannot race with a deferred auto recompute.
            if mode == .encode {
                // Text editor is source of truth when non-empty; otherwise re-punch binary payload.
                if !plainText.isEmpty {
                    recomputeFromText()
                } else if !document.isEmpty {
                    reapplyPayloadPreferences()
                }
            } else if !document.isEmpty {
                reapplyPayloadPreferences()
            }
        }
        .onChange(of: base85) { _ in
            guard !suppressLiveRecompute else { return }
            if mode == .encode {
                if !plainText.isEmpty {
                    recomputeFromText()
                } else if !document.isEmpty {
                    reapplyPayloadPreferences()
                }
            } else if !document.isEmpty {
                reapplyPayloadPreferences()
            }
        }
        .onChange(of: mode) { newMode in
            // Switching to Tape with typed text but empty document → punch now.
            if newMode == .tape, document.isEmpty, !plainText.isEmpty, !suppressLiveRecompute {
                recomputeFromText()
            }
        }
    }

    private var transferPreference: TapeEngine.TransferEncoding {
        base85 ? .ascii85 : .identity
    }

    // MARK: - Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                Text("●○")
                    .font(.system(size: 16, weight: .bold, design: .monospaced))
                    .foregroundStyle(AppTheme.paper)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .fill(AppTheme.accent)
                    )
                VStack(alignment: .leading, spacing: 2) {
                    Text("PaperTape")
                        .font(.headline)
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
                Picker("Mode", selection: $mode) {
                    ForEach(WorkMode.allCases) { m in
                        Text(m.rawValue).tag(m)
                    }
                }
                .pickerStyle(.segmented)
                .frame(maxWidth: 360)
                .labelsHidden()
            }

            if mode == .encode || mode == .tape {
                optionsBar
            } else if mode == .files {
                Text("Drop any file to punch a .Tape, or a .Tape file to restore the original.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    private var subtitle: String {
        switch mode {
        case .encode: return "Type text → punch columns on the strip"
        case .tape: return "Inspect the visual punched-tape representation"
        case .files: return "Encode or restore files (.Tape container)"
        case .about: return "Classic 8-channel paper tape, digitized"
        }
    }

    private var optionsBar: some View {
        HStack(spacing: 12) {
            Text("Zoom")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            Slider(value: $columnWidth, in: 10...28, step: 1)
                .frame(maxWidth: 120)

            Toggle("Terminal preview", isOn: $showTerminalPreview)
                .toggleStyle(.checkbox)
                .help("Show the ASCII terminal-paper art below the strip.")

            HStack(spacing: 4) {
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
            }

            Toggle("Base85 (+25%)", isOn: $base85)
                .toggleStyle(.checkbox)
                .help(TapeEngine.TransferEncoding.ascii85.help)

            HStack(spacing: 4) {
                Text("Format")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                Picker("Format", selection: $tapeFileFormat) {
                    ForEach(TapeEngine.TapeFileFormat.uiCases) { fmt in
                        Text(fmt.shortName).tag(fmt)
                    }
                }
                .labelsHidden()
                .fixedSize(horizontal: true, vertical: false)
                .help(tapeFileFormat.help)
            }

            Spacer(minLength: 0)

            if !document.isEmpty {
                let n = document.columns.count
                Label("\(n) cols", systemImage: "square.grid.3x3")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if document.isCompressed || document.usesBase85 {
                    Label(columnStatsLabel(document, columns: n), systemImage: "arrow.down.circle")
                        .font(.caption)
                        .foregroundStyle(AppTheme.accent)
                } else {
                    Label("\(document.originalSize) bytes · raw", systemImage: "number")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Button("Clear") {
                recomputeGeneration += 1
                plainText = ""
                document = .empty
                sourceURL = nil
                statusMessage = nil
            }
            .disabled(plainText.isEmpty && document.isEmpty)
        }
    }

    // MARK: - Main

    @ViewBuilder
    private var mainPane: some View {
        switch mode {
        case .encode:
            encodePane
        case .tape:
            tapePane
        case .files:
            FilePane(
                compression: $compression,
                base85: $base85,
                tapeFileFormat: $tapeFileFormat,
                externalBusy: $filesEncodeBusy,
                externalOpenURL: externalOpenURL,
                externalOpenGeneration: externalOpenGeneration,
                onExternalOpenHandled: { externalOpenURL = nil },
                onOpenDocument: { doc, url in
                    applyLoadedDocument(doc, url: url)
                },
                onStatus: { statusMessage = $0 }
            )
            // Do not remount FilePane on every external open — that drops in-flight progress.
        case .about:
            aboutPane
        }
    }

    private var encodePane: some View {
        // Prefer fixed proportions over VSplitView + flex frames (avoids layout recursion).
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 6) {
                Text("Plain text (UTF-8)")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 12)
                    .padding(.top, 10)

                ZStack(alignment: .topLeading) {
                    if plainText.isEmpty {
                        Text("Type or paste text to encode as punched tape…\nEach UTF-8 byte becomes one column.")
                            .font(.body)
                            .foregroundStyle(.tertiary)
                            .padding(.horizontal, 16)
                            .padding(.vertical, 10)
                            .allowsHitTesting(false)
                    }
                    TextEditor(text: $plainText)
                        .font(.system(size: 14))
                        .scrollContentBackground(.hidden)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .focused($textFocused)
                }
                .background(AppTheme.card)
            }
            // Shrink text area when terminal preview is open so the preview stays on-screen.
            .frame(
                minHeight: 100,
                idealHeight: showTerminalPreview ? 140 : 200,
                maxHeight: showTerminalPreview ? 180 : 280
            )

            Divider()

            tapeSection(showBanner: true)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private var tapePane: some View {
        VStack(spacing: 0) {
            // Always reserve the integrity strip at the top of the Tape tab so it
            // cannot disappear into a scroll area or be gated only by Encode.
            if !document.isEmpty || document.isArchive {
                integrityBannerSlot
                    .padding(.top, 8)
            }

            if document.isEmpty, !document.isArchive {
                emptyTapePlaceholder
            } else if document.isEmpty, document.isArchive {
                emptyArchivePlaceholder
            } else {
                tapeSection(showBanner: false)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)

                if shouldShowDecodedPreview, let preview = decodedPreviewText {
                    Divider()
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Decoded payload (UTF-8)")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 12)
                            .padding(.top, 8)
                        ScrollView {
                            Text(preview)
                                .font(.system(size: 13, design: .monospaced))
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .topLeading)
                                .padding(.horizontal, 12)
                                .padding(.bottom, 10)
                        }
                        .frame(maxHeight: showTerminalPreview ? 100 : 140)
                    }
                    .background(AppTheme.card)
                }
            }
        }
    }

    private var emptyArchivePlaceholder: some View {
        VStack(spacing: 16) {
            Image(systemName: "folder")
                .font(.system(size: 40))
                .foregroundStyle(AppTheme.accent.opacity(0.7))
            Text("Folder archive")
                .font(.title3.weight(.semibold))
            Text("This .Tape packs multiple files. Use Files → Restore to extract them to a folder.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 360)
            Button("Go to Files") { mode = .files }
                .buttonStyle(.bordered)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(24)
    }

    private var emptyTapePlaceholder: some View {
        VStack(spacing: 16) {
            Image(systemName: "scroll")
                .font(.system(size: 40))
                .foregroundStyle(AppTheme.accent.opacity(0.7))
            Text("No tape loaded")
                .font(.title3.weight(.semibold))
            Text("Encode text on the Encode tab, open a .Tape from Files, or drop a .Tape file onto the window.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 360)
            HStack(spacing: 12) {
                Button("Go to Encode") { mode = .encode }
                Button("Go to Files") { mode = .files }
            }
            .buttonStyle(.bordered)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(24)
    }

    @ViewBuilder
    private var integrityBannerSlot: some View {
        // Context banners (archive / partial) stack *above* the integrity report.
        // Previously archive/partial short-circuited and hid CRC/XOR/SUM8 entirely.
        VStack(alignment: .leading, spacing: 4) {
            if document.isArchive {
                contextBanner(
                    systemImage: "folder.fill",
                    title: "Folder archive",
                    detail: document.note.isEmpty
                        ? "Use Files → Restore to extract members. Integrity below covers the punched columns shown on the strip."
                        : document.note,
                    accent: true
                )
            } else if document.isPartialPreview {
                contextBanner(
                    systemImage: "eye",
                    title: "Partial preview",
                    detail: document.note.isEmpty
                        ? "First columns only — integrity is for this preview window, not necessarily the full file."
                        : document.note,
                    accent: false
                )
            }

            if let report = document.integrity, report.checked {
                integrityBanner(report)
            } else if !document.isEmpty {
                HStack(spacing: 10) {
                    Image(systemName: "shield.slash")
                        .foregroundStyle(.secondary)
                    Text(
                        document.isArchive
                            ? "No integrity blocks in the preview columns (empty or unreadable markers)"
                            : "No integrity markers in this .Tape (legacy or incomplete file)"
                    )
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.secondary.opacity(0.10))
                .padding(.horizontal, 10)
                .padding(.bottom, 6)
            }
        }
    }

    private func contextBanner(
        systemImage: String,
        title: String,
        detail: String,
        accent: Bool
    ) -> some View {
        HStack(spacing: 10) {
            Image(systemName: systemImage)
                .foregroundStyle(accent ? AppTheme.accent : Color.secondary)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.caption.weight(.semibold))
                Text(detail)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(accent ? AppTheme.accent.opacity(0.12) : Color.secondary.opacity(0.12))
        )
        .padding(.horizontal, 10)
        .padding(.bottom, 2)
    }

    private func integrityBanner(_ report: TapeEngine.IntegrityReport) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: report.allOK ? "checkmark.shield.fill" : "exclamationmark.triangle.fill")
                .font(.title3)
                .foregroundStyle(report.allOK ? Color.green : Color.orange)
            VStack(alignment: .leading, spacing: 2) {
                Text(report.summary)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(2)
                Text(report.detailLine)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(report.allOK ? Color.green.opacity(0.18) : Color.orange.opacity(0.22))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(report.allOK ? Color.green.opacity(0.5) : Color.orange.opacity(0.55), lineWidth: 1)
        )
        .padding(.horizontal, 10)
        .padding(.bottom, 6)
    }

    /// Apply a loaded document to the main UI and switch to the Tape tab.
    private func applyLoadedDocument(_ doc: TapeEngine.TapeDocument, url: URL?) {
        // Cancel any pending live encode so it cannot wipe this document 50ms later.
        suppressLiveRecompute = true
        recomputeGeneration += 1

        // Never replace a good strip with a failed empty open.
        if doc.isEmpty, !document.isEmpty {
            if let url {
                statusMessage = "Opened \(url.lastPathComponent) but no columns to display — keeping current tape"
            } else {
                statusMessage = "Load produced an empty tape — keeping current tape"
            }
            mode = .tape
            DispatchQueue.main.async { suppressLiveRecompute = false }
            return
        }

        var loaded = doc
        let bs = loaded.blockSize > 0 ? loaded.blockSize : TapeEngine.defaultBlockSize
        // Always ensure a non-empty integrity report for any punched columns so the
        // Tape tab banner can show OK/FAIL (archives and previews included).
        if !loaded.columns.isEmpty {
            if loaded.integrity == nil || loaded.integrity?.blocks.isEmpty == true {
                // Prefer re-verify from markers when the file had them; else synthetic OK.
                let hadMarkers = loaded.integrity?.hasMarkers == true
                loaded.integrity = TapeEngine.buildIntegrityReport(
                    for: loaded.columns,
                    blockSize: bs,
                    hasMarkers: hadMarkers
                )
            }
        }

        // Mode first so plainText onChange (if any) sees .tape and skips recompute.
        mode = .tape
        document = loaded
        sourceURL = url

        if loaded.isEmpty {
            // Keep existing plainText; empty open should not clear the editor.
        } else if loaded.isArchive || loaded.isPartialPreview {
            // Don't pull archive / partial punched bytes into the Encode editor as "text".
            plainText = ""
        } else if let text = loaded.textUTF8, text.count < 200_000 {
            plainText = text
        } else {
            // Binary / huge payload
            plainText = ""
        }

        if loaded.isArchive {
            statusMessage = "\(url?.lastPathComponent ?? loaded.originalName) · folder archive · use Files → Restore"
        } else if loaded.isPartialPreview {
            statusMessage = "\(url?.lastPathComponent ?? loaded.originalName) · partial preview · \(loaded.columns.count) cols"
        } else if let rep = loaded.integrity, rep.checked {
            statusMessage = rep.allOK
                ? "\(url?.lastPathComponent ?? loaded.originalName) · \(loaded.columns.count) cols · integrity OK"
                : rep.summary
        } else if !loaded.isEmpty {
            statusMessage = "\(url?.lastPathComponent ?? loaded.originalName) · \(loaded.columns.count) cols"
        } else if let url {
            statusMessage = "Opened \(url.lastPathComponent) (no punched columns to display)"
        }

        // Re-enable live encode after SwiftUI has consumed the plainText change.
        DispatchQueue.main.async {
            suppressLiveRecompute = false
        }
    }

    /// Avoid building a giant UTF-8 string for binary / huge tapes on every body pass.
    private var shouldShowDecodedPreview: Bool {
        !document.isEmpty && !document.isArchive && document.columns.count <= 32_000
    }

    private var decodedPreviewText: String? {
        guard shouldShowDecodedPreview else { return nil }
        // Prefer restored UTF-8 (works for binary and ternary after unpack).
        if let text = document.textUTF8, !text.isEmpty, text.count < 50_000 {
            return text
        }
        return nil
    }

    @ViewBuilder
    private func tapeSection(showBanner: Bool) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Punched tape")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                if let name = sourceURL?.lastPathComponent ?? (document.originalName != "untitled" ? document.originalName : nil) {
                    Text("· \(name)")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
                if !document.isEmpty {
                    Text("· \(visualColumnCount) cols")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
                Spacer()
                Text("ch1=LSB · ○ = feed")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 12)
            .padding(.top, 10)
            .padding(.bottom, 6)

            // Banner on Encode; Tape tab draws it once above this section.
            if showBanner {
                integrityBannerSlot
            }

            // Visual strip — may shrink; terminal preview keeps reserved height below.
            HStack(alignment: .top, spacing: 8) {
                TapeChannelLegend(nineChannels: visualDocument.packing == .base512)
                    .padding(.leading, 8)
                TapeStripView(
                    document: visualDocument,
                    columnWidth: columnWidth,
                    showLegend: true,
                    maxDisplayColumns: 1_024
                )
                .frame(maxWidth: .infinity, minHeight: 120)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .padding(.bottom, 8)
            .background(Color(nsColor: .underPageBackgroundColor).opacity(0.35))
            .layoutPriority(0)

            if showTerminalPreview {
                Divider()
                terminalPreviewPane
                    .layoutPriority(1)
            }
            // Decoded payload lives only on the Tape tab (below tapeSection), not here —
            // otherwise ternary tapes show it twice. Terminal art already includes `text: …`.
        }
    }

    /// ASCII terminal-paper art. Fixed height so it is never collapsed by the strip above.
    private var terminalPreviewPane: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Terminal paper")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                if visualDocument.packing == .base512 {
                    Text("v9 nine-channel binary (Base512)")
                } else if document.packing.isBase256 {
                    Text("v8 base-256 — experimental maximum density")
                } else if document.packing.isHexadecimal {
                    Text("v7 hexadecimal")
                } else if document.packing.isOctal {
                    Text("v6 octal")
                } else if document.packing.isQuaternary {
                    Text("v5 quaternary")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                } else if document.packing.isTernary {
                    Text("v4 ternary")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
                if visualColumnCount > 64 {
                    Text("(first 64 of \(visualColumnCount) columns)")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
                Spacer()
                Button {
                    copyTerminalArt()
                } label: {
                    Label("Copy", systemImage: "doc.on.doc")
                        .font(.caption)
                }
                .buttonStyle(.borderless)
                .disabled(document.isEmpty)
            }
            .padding(.horizontal, 12)
            .padding(.top, 8)
            .padding(.bottom, 4)

            // NSTextView is more reliable for long monospaced art than SwiftUI ScrollView+Text.
            TerminalPaperTextView(text: terminalPreviewText)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding(.horizontal, 8)
                .padding(.bottom, 8)
        }
        .frame(minHeight: 150, idealHeight: 180, maxHeight: 240)
        .background(AppTheme.paper.opacity(0.65))
        .zIndex(5)
    }

    private var previewsNewBase512Tape: Bool {
        tapeFileFormat == .v9 && document.packing == .binary && !document.isPartialPreview
            && !document.isArchive && (mode == .encode || sourceURL == nil)
    }

    private var visualColumnCount: Int {
        let count = document.columns.count
        return previewsNewBase512Tape ? count - count / 9 : count
    }

    private var visualDocument: TapeEngine.TapeDocument {
        guard previewsNewBase512Tape else {
            return document
        }
        var preview = document
        let byteLimit = 1_152 // Exactly 1,024 complete nine-bit columns.
        let prefix = Data(document.columns.prefix(byteLimit).map(\.byte))
        preview.columns = TapeEngine.base512Columns(from: prefix)
        preview.packing = .base512
        preview.isPartialPreview = document.columns.count > byteLimit
        preview.packedByteCount = prefix.count
        return preview
    }

    private var terminalPreviewText: String {
        if document.isEmpty {
            return "(empty tape — type or open data to generate terminal paper art)"
        }
        return TapeEngine.terminalPaper(for: visualDocument, maxColumns: 64)
    }

    private var aboutPane: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                Text("Paper tape, digitized")
                    .font(.title2.weight(.semibold))
                    .foregroundStyle(AppTheme.accent)

                Text(
                    "Mid-century computers and teletypes stored data on long strips of paper. "
                        + "Each column held one character or byte as a pattern of punched holes, "
                        + "with a smaller sprocket hole for the feed mechanism."
                )
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

                GroupBox("Channel map") {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Physical layout (across the strip):")
                            .font(.caption.weight(.semibold))
                        Text("  ch1  ch2  ch3  ○feed  ch4  ch5  ch6  ch7  ch8")
                            .font(.system(.body, design: .monospaced))
                        Text("Channel 1 = least significant bit (bit 0). Channel 8 = bit 7.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Text("Glyphs: v1–v7 multilevel punches; v8 base-256 — experimental maximum density (grayscale bytes, hex-pair tokens)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(4)
                }

                GroupBox("File format") {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Extension: .\(TapeEngine.fileExtension)  ·  App \(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?")")
                        Text("Type: UTF-8 text with a PaperTape header and one visual column token per line.")
                        Text("Round-trips any binary payload losslessly through the punched pattern.")
                        Text("Pipeline: original → [compress] → [Base85] → [pack according to format] → columns. Format picks packing and glyphs (v1–v9).")
                        Text("Auto compression trials LZFSE/Zlib/LZ4/LZMA. Short messages: any smaller result; large: ≥5% and ≥16 bytes.")
                        Text("Base85 (Ascii85) is optional after compression — printable payload on the strip. It expands (~+25%); use Compress to shrink.")
                        Text("Header: # columns: …|ternary|quaternary|octal|hexadecimal|base256|base512 · # packing: full|block3|quat|oct|hex|b256|b512")
                        Text("v1…v3 binary · v4 (~12.68) · v5 (16) · v6 (24) · v7 hex (32, default) · v8 base-256 — experimental maximum density (64) · v9 nine-channel binary (9).")
                        Text("Suggested save names include the version: notes-v7.Tape, Project-v3.Tape, …")
                        Text("Each block: # @block N … crc32/xor/sum8. Folders: # @file path=\"…\" size=… compression=… packing=… per member.")
                        Text("Large files (≥4 MiB) stream raw; folder members under 4 MiB use Compress/Base85 per file.")
                        Text("Double-click a .Tape file in Finder to open it in this app.")
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(4)
                }

                HStack {
                    Button {
                        statusMessage = TapeEngine.runSelfTest()
                    } label: {
                        Label("Run self-test", systemImage: "checkmark.shield")
                    }
                    Button {
                        plainText = sampleText
                        mode = .encode
                        recomputeFromText()
                    } label: {
                        Label("Load sample", systemImage: "text.quote")
                    }
                    Spacer()
                }
            }
            .padding(24)
            .frame(maxWidth: 720)
            .frame(maxWidth: .infinity)
        }
    }

    // MARK: - Footer

    private var footer: some View {
        VStack(alignment: .leading, spacing: 6) {
            // Global progress for drop / open encode (folder pack can take a while).
            if dropEncodeInFlight {
                HStack(alignment: .center, spacing: 12) {
                    VStack(alignment: .leading, spacing: 4) {
                        if let fraction = dropProgressFraction {
                            ProgressView(value: fraction)
                                .progressViewStyle(.linear)
                            Text(dropProgressLabel.isEmpty ? (statusMessage ?? "Working…") : dropProgressLabel)
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        } else {
                            HStack(spacing: 8) {
                                ProgressView()
                                    .controlSize(.small)
                                Text(dropProgressLabel.isEmpty ? (statusMessage ?? "Working…") : dropProgressLabel)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                            }
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)

                    Button("Cancel") {
                        dropEncodeCancelToken?.cancel()
                        statusMessage = "Cancelling…"
                        dropProgressLabel = "Cancelling…"
                    }
                    .controlSize(.small)
                    .keyboardShortcut(.cancelAction)
                }
            }

            HStack(spacing: 12) {
            if document.isEmpty {
                Text("Ready to punch")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            } else {
                Text(document.originalName)
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer(minLength: 0)

            if let statusMessage {
                Text(statusMessage)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }

            if mode != .about && mode != .files {
                Button {
                    copyTerminalArt()
                } label: {
                    Label(copied ? "Copied" : "Copy terminal art", systemImage: copied ? "checkmark" : "doc.on.doc")
                }
                .disabled(document.isEmpty)
                .keyboardShortcut("c", modifiers: [.command, .shift])

                Button {
                    saveTape()
                } label: {
                    Label("Save .Tape…", systemImage: "square.and.arrow.down")
                }
                .disabled(document.isEmpty || document.isArchive)
                .keyboardShortcut("s", modifiers: [.command])

                Button {
                    exportPNG()
                } label: {
                    Label("Export PNG…", systemImage: "photo")
                }
                .disabled(document.isEmpty)

                Button {
                    exportPayload()
                } label: {
                    Label(
                        document.isArchive ? "Extract archive…" : "Export data…",
                        systemImage: document.isArchive ? "folder.badge.plus" : "shippingbox"
                    )
                }
                .disabled(document.isEmpty)
                .help(
                    document.isArchive
                        ? "Extract all files from this folder archive to a chosen directory."
                        : "Restore the original payload from the punched tape."
                )
            }
            } // HStack
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        // Keep footer above any residual overlay hit-testing quirks.
        .background(AppTheme.marble)
        .zIndex(10)
    }

    // MARK: - Actions

    private func scheduleRecompute() {
        guard !suppressLiveRecompute else { return }
        recomputeGeneration += 1
        let generation = recomputeGeneration
        let text = plainText
        let name = sourceURL?.lastPathComponent ?? "message.txt"
        let comp = compression
        let xfer = transferPreference
        let utf8Count = text.utf8.count

        // Small edits: debounce briefly on main so typing stays smooth.
        // Large pastes: encode off the main thread.
        if utf8Count <= 8_192 {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                guard generation == recomputeGeneration, !suppressLiveRecompute else { return }
                document = TapeEngine.encodeText(
                    text,
                    originalName: name,
                    compression: comp,
                    transferEncoding: xfer
                )
            }
            return
        }

        if utf8Count > Self.liveEncodeSoftLimit {
            statusMessage = "Large input (\(utf8Count.formatted()) bytes) — encoding…"
        }

        DispatchQueue.global(qos: .userInitiated).async {
            let doc = TapeEngine.encodeText(
                text,
                originalName: name,
                compression: comp,
                transferEncoding: xfer
            )
            DispatchQueue.main.async {
                guard generation == recomputeGeneration, !suppressLiveRecompute else { return }
                document = doc
                if utf8Count > Self.liveEncodeSoftLimit {
                    statusMessage = encodeStatus(for: doc)
                }
            }
        }
    }

    private func recomputeFromText() {
        guard !suppressLiveRecompute else { return }
        recomputeGeneration += 1
        let generation = recomputeGeneration
        let text = plainText
        let name = sourceURL?.lastPathComponent ?? "message.txt"
        let comp = compression
        let xfer = transferPreference
        if text.utf8.count <= 8_192 {
            document = TapeEngine.encodeText(
                text,
                originalName: name,
                compression: comp,
                transferEncoding: xfer
            )
            if mode == .encode || mode == .tape {
                statusMessage = encodeStatus(for: document)
            }
        } else {
            DispatchQueue.global(qos: .userInitiated).async {
                let doc = TapeEngine.encodeText(
                    text,
                    originalName: name,
                    compression: comp,
                    transferEncoding: xfer
                )
                DispatchQueue.main.async {
                    guard generation == recomputeGeneration, !suppressLiveRecompute else { return }
                    document = doc
                    statusMessage = encodeStatus(for: doc)
                }
            }
        }
    }

    /// Re-punch whatever payload is currently loaded using Compress + Base85 preferences.
    private func reapplyPayloadPreferences() {
        // Prefer editor text when present (even if the open document was a partial/archive).
        if !plainText.isEmpty {
            recomputeFromText()
            return
        }
        if document.isArchive {
            statusMessage = "Folder archives cannot be re-punched here — use Files → Restore, or re-pack the folder."
            return
        }
        if document.isPartialPreview {
            statusMessage = "Partial preview cannot be re-punched — open a smaller .Tape or Restore the full file."
            return
        }
        recomputeGeneration += 1
        let generation = recomputeGeneration
        let name = sourceURL?.lastPathComponent ?? document.originalName
        let comp = compression
        let xfer = transferPreference
        let payload: Data
        do {
            payload = try document.restoredData()
        } catch {
            statusMessage = "Could not re-encode: \(error.localizedDescription)"
            return
        }
        if payload.isEmpty, plainText.isEmpty {
            // Don't clear a non-empty document when restore yields empty unexpectedly.
            if document.isEmpty {
                document = .empty
            }
            return
        }
        if !plainText.isEmpty {
            recomputeFromText()
            return
        }
        DispatchQueue.global(qos: .userInitiated).async {
            let doc = TapeEngine.encode(
                data: payload,
                originalName: name,
                compression: comp,
                transferEncoding: xfer
            )
            DispatchQueue.main.async {
                guard generation == recomputeGeneration else { return }
                document = doc
                statusMessage = encodeStatus(for: doc)
            }
        }
    }

    private func columnStatsLabel(_ doc: TapeEngine.TapeDocument, columns n: Int) -> String {
        var parts = ["\(doc.originalSize)→\(n)"]
        if doc.isCompressed {
            parts.append(doc.compression.displayName)
        }
        if doc.usesBase85 {
            parts.append("B85")
        }
        return parts.joined(separator: " · ")
    }

    private func encodeStatus(for doc: TapeEngine.TapeDocument) -> String {
        var parts: [String] = ["\(doc.columns.count.formatted()) cols"]
        if doc.isCompressed, let ratio = doc.compressionRatio {
            let pct = Int((1.0 - ratio) * 100)
            let via = compression == .auto ? "auto→\(doc.compression.displayName)" : doc.compression.displayName
            parts.append("\(via) −\(pct)%")
        } else if compression == .auto && doc.originalSize > 0 && !doc.usesBase85 {
            parts.append("Auto kept raw")
        }
        if doc.usesBase85 {
            parts.append("Base85")
        }
        return "Encoded " + parts.joined(separator: " · ") + "."
    }

    private func copyTerminalArt() {
        let art = TapeEngine.terminalPaper(for: visualDocument, maxColumns: 256)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(art, forType: .string)
        copied = true
        statusMessage = visualColumnCount > 256
            ? "Copied terminal art (first 256 columns)."
            : "Copied terminal paper art."
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
            copied = false
        }
    }

    private func saveTape() {
        // Always save using the current Compress / Format preferences.
        let preferred = compression
        let xfer = transferPreference
        let preferredFormat = tapeFileFormat
        let name = sourceURL?.lastPathComponent ?? document.originalName
        let textSnapshot = plainText
        let existing = document

        if existing.isArchive {
            statusMessage = "Folder archives cannot be re-saved as a single blob — re-pack from Files."
            return
        }
        if existing.isPartialPreview, textSnapshot.isEmpty {
            statusMessage = "Partial preview cannot be saved as a full .Tape — type new text on Encode, or Restore the original."
            return
        }

        let panel = NSSavePanel()
        panel.allowedContentTypes = [TapeEngine.contentType]
        let base = stem(of: name)
        panel.nameFieldStringValue = TapeEngine.suggestedTapeFilename(
            stem: base,
            format: preferredFormat
        )
        panel.canCreateDirectories = true
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            statusMessage = "Saving…"
            DispatchQueue.global(qos: .userInitiated).async {
                let docToSave: TapeEngine.TapeDocument
                // Text editor is source of truth whenever it has content (including after
                // a partial large-tape open — user may be re-encoding typed text).
                if !textSnapshot.isEmpty, !existing.isArchive {
                    docToSave = TapeEngine.encodeText(
                        textSnapshot,
                        originalName: name.hasSuffix(".\(TapeEngine.fileExtension)")
                            ? stem(of: name) + ".txt"
                            : name,
                        compression: preferred,
                        transferEncoding: xfer
                    )
                } else if !existing.isEmpty {
                    let payload: Data
                    do {
                        payload = try existing.restoredData()
                    } catch {
                        DispatchQueue.main.async {
                            statusMessage = "Save failed: \(error.localizedDescription)"
                        }
                        return
                    }
                    docToSave = TapeEngine.encode(
                        data: payload,
                        originalName: existing.originalName,
                        compression: preferred,
                        transferEncoding: xfer
                    )
                } else {
                    DispatchQueue.main.async {
                        statusMessage = "Nothing to save — type text or open a file first."
                    }
                    return
                }
                let data = TapeEngine.serialize(docToSave, fileFormat: preferredFormat)
                do {
                    try data.write(to: url, options: .atomic)
                    // Prefer disk reload (real @block verification); fall back to in-memory doc.
                    var reloaded = docToSave
                    if let fromDisk = try? TapeEngine.loadForDisplay(from: url), !fromDisk.isEmpty {
                        reloaded = fromDisk
                    } else if reloaded.integrity == nil, !reloaded.columns.isEmpty {
                        reloaded.integrity = TapeEngine.buildIntegrityReport(
                            for: reloaded.columns,
                            blockSize: reloaded.blockSize,
                            hasMarkers: false
                        )
                    }
                    DispatchQueue.main.async {
                        applyLoadedDocument(reloaded, url: url)
                        statusMessage = "Saved \(url.lastPathComponent) · \(encodeStatus(for: reloaded))"
                    }
                } catch {
                    DispatchQueue.main.async {
                        statusMessage = "Save failed: \(error.localizedDescription)"
                    }
                }
            }
        }
    }

    private func exportPNG() {
        guard let png = TapeImageExporter.renderPNG(document: visualDocument) else {
            statusMessage = "PNG export failed."
            return
        }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.png]
        panel.nameFieldStringValue = "\(stem(of: document.originalName))-tape.png"
        panel.canCreateDirectories = true
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            do {
                try png.write(to: url, options: .atomic)
                statusMessage = "Exported \(url.lastPathComponent)."
            } catch {
                statusMessage = "Export failed: \(error.localizedDescription)"
            }
        }
    }

    private func exportPayload() {
        let doc = document
        if doc.isEmpty {
            statusMessage = "Nothing to export — open or encode a tape first."
            return
        }
        // Folder archives: extract members (same as Files → Restore for archives).
        if doc.isArchive {
            extractArchiveFromCurrentDocument()
            return
        }

        let panel = NSSavePanel()
        panel.nameFieldStringValue = doc.originalName.isEmpty ? "payload.bin" : doc.originalName
        panel.canCreateDirectories = true
        if doc.isPartialPreview {
            if doc.packing.isTernary && (doc.packing == .ternaryFull && doc.packChunk <= 0) {
                statusMessage = "Partial ternary preview cannot export payload — use Files → Restore on the full .Tape."
                return
            }
            panel.message = "This is a partial preview — exported data may be incomplete (complete pack groups only)."
        }
        let present: (NSApplication.ModalResponse) -> Void = { response in
            guard response == .OK, let url = panel.url else { return }
            do {
                let payload = try doc.restoredData(allowPartial: doc.isPartialPreview)
                try payload.write(to: url, options: .atomic)
                if doc.isPartialPreview {
                    statusMessage = "Exported partial preview → \(url.lastPathComponent) (\(payload.count) bytes)."
                } else {
                    statusMessage = "Exported payload \(url.lastPathComponent) (\(payload.count) bytes)."
                }
            } catch {
                statusMessage = "Export failed: \(error.localizedDescription)"
            }
        }
        if let window = NSApp.keyWindow ?? NSApp.mainWindow ?? NSApp.windows.first(where: \.isVisible) {
            panel.beginSheetModal(for: window, completionHandler: present)
        } else {
            panel.begin(completionHandler: present)
        }
    }

    /// Extract a loaded folder-archive .Tape to a user-chosen directory.
    private func extractArchiveFromCurrentDocument() {
        guard let tapeURL = sourceURL else {
            statusMessage = "Save the .Tape first, then Extract archive… (need the file on disk)."
            return
        }
        let defaultName = document.originalName.isEmpty
            ? stem(of: tapeURL.lastPathComponent)
            : document.originalName

        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = true
        panel.prompt = "Extract Here"
        panel.message = "Choose a folder to extract “\(defaultName)” into."

        let present: (NSApplication.ModalResponse) -> Void = { response in
            guard response == .OK, let parent = panel.url else {
                statusMessage = "Extract cancelled"
                return
            }
            let dest = parent.appendingPathComponent(defaultName.isEmpty ? "TapeArchive" : defaultName)
            statusMessage = "Extracting archive…"
            dropEncodeInFlight = true
            filesEncodeBusy = true
            dropProgressFraction = nil
            dropProgressLabel = "Extracting…"
            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    let result = try TapeEngine.extractFolder(
                        from: tapeURL,
                        to: dest,
                        progress: { p in
                            DispatchQueue.main.async {
                                dropProgressLabel = p.phase
                                dropProgressFraction = p.fraction
                                if let f = p.fraction {
                                    statusMessage = "\(p.phase) · \(Int(f * 100))%"
                                } else {
                                    statusMessage = p.phase
                                }
                            }
                        }
                    )
                    DispatchQueue.main.async {
                        dropEncodeInFlight = false
                        filesEncodeBusy = false
                        dropProgressFraction = nil
                        dropProgressLabel = ""
                        var msg = "Extracted \(result.files) file(s), \(result.bytes) bytes → \(dest.lastPathComponent)"
                        if result.failedBlocks > 0 {
                            msg += " · \(result.failedBlocks) integrity block(s) failed"
                        }
                        statusMessage = msg
                        NSWorkspace.shared.activateFileViewerSelecting([dest])
                    }
                } catch {
                    DispatchQueue.main.async {
                        dropEncodeInFlight = false
                        filesEncodeBusy = false
                        dropProgressFraction = nil
                        dropProgressLabel = ""
                        statusMessage = "Extract failed: \(error.localizedDescription)"
                    }
                }
            }
        }
        if let window = NSApp.keyWindow ?? NSApp.mainWindow ?? NSApp.windows.first(where: \.isVisible) {
            panel.beginSheetModal(for: window, completionHandler: present)
        } else {
            panel.begin(completionHandler: present)
        }
    }

    private func consumePendingOpens() {
        if dropEncodeInFlight {
            // Finish current encode/panel first; queue stays until we flush.
            return
        }
        let urls = OpenFileBridge.drain()
        guard let first = urls.first else { return }
        // Leave remaining URLs queued without an immediate flush.
        if urls.count > 1 {
            for extra in urls.dropFirst() {
                OpenFileBridge.enqueueWithoutFlush(extra)
            }
            if urls.count > 2 {
                statusMessage = "Opening \(first.lastPathComponent)… (\(urls.count - 1) more queued)"
            }
        }
        loadURL(first)
    }

    private func loadURL(_ url: URL) {
        // .Tape → inspect on Tape tab. Anything else → save panel + encode (file or folder).
        // Encode runs here directly so we do not depend on FilePane onChange/onAppear races.
        if TapeEngine.isTapeURL(url) {
            statusMessage = "Opening \(url.lastPathComponent)…"
            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    let doc = try TapeEngine.loadForDisplay(from: url)
                    DispatchQueue.main.async {
                        applyLoadedDocument(doc, url: url)
                        if OpenFileBridge.hasPending() {
                            OpenFileBridge.requestFlush()
                        }
                    }
                } catch {
                    DispatchQueue.main.async {
                        mode = .files
                        statusMessage = "Could not open \(url.lastPathComponent): \(error.localizedDescription)"
                        // Fall back to Files tab open picker flow.
                        externalOpenURL = url
                        externalOpenGeneration += 1
                        if OpenFileBridge.hasPending() {
                            OpenFileBridge.requestFlush()
                        }
                    }
                }
            }
            return
        }

        mode = .files
        promptEncodeDroppedSource(url)
    }

    /// Drop / open of a normal file or folder: show save panel, then punch to .Tape.
    private func promptEncodeDroppedSource(_ source: URL) {
        if dropEncodeInFlight || filesEncodeBusy {
            OpenFileBridge.enqueueWithoutFlush(source)
            statusMessage = "Busy — queued \(source.lastPathComponent)"
            return
        }
        dropEncodeInFlight = true
        filesEncodeBusy = true
        let cancelToken = TapeEngine.EncodeCancelToken()
        dropEncodeCancelToken = cancelToken

        let accessed = source.startAccessingSecurityScopedResource()
        let isDir = Self.pathIsDirectory(source)
        let preferredCompression = compression
        let preferredTransfer: TapeEngine.TransferEncoding = base85 ? .ascii85 : .identity
        let preferredFormat = tapeFileFormat

        let panel = NSSavePanel()
        panel.allowedContentTypes = [TapeEngine.contentType, .plainText, .data]
        panel.canCreateDirectories = true
        if isDir {
            let suggested = TapeEngine.suggestedTapeFilename(
                stem: source.lastPathComponent,
                format: preferredFormat
            )
            panel.nameFieldStringValue = suggested
            panel.message = "Save punched folder archive as a .Tape file"
            statusMessage = "Choose where to save \(suggested)…"
        } else {
            let suggested = TapeEngine.suggestedTapeFilename(
                stem: stem(of: source.lastPathComponent),
                format: preferredFormat
            )
            panel.nameFieldStringValue = suggested
            panel.message = "Save punched file as a .Tape file"
            statusMessage = "Choose where to save \(suggested)…"
        }

        let finishAccess = {
            if accessed { source.stopAccessingSecurityScopedResource() }
        }

        let reportDropProgress: (TapeProgress) -> Void = { p in
            DispatchQueue.main.async {
                guard !cancelToken.isCancelled else { return }
                dropProgressLabel = p.phase
                dropProgressFraction = p.fraction
                if let f = p.fraction {
                    let pct = Int(f * 100)
                    statusMessage = "\(p.phase) · \(pct)%"
                } else {
                    statusMessage = p.phase
                }
            }
        }

        let clearDropProgress = {
            dropProgressFraction = nil
            dropProgressLabel = ""
            dropEncodeCancelToken = nil
        }

        let runEncode: (URL) -> Void = { dest in
            dropProgressFraction = nil
            dropProgressLabel = isDir ? "Packing…" : "Encoding…"
            statusMessage = isDir
                ? "Packing folder \(source.lastPathComponent)…"
                : "Encoding \(source.lastPathComponent)…"
            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    let preview: TapeEngine.TapeDocument
                    let status: String
                    if isDir {
                        let result = try TapeEngine.encodeFolder(
                            root: source,
                            to: dest,
                            compression: preferredCompression,
                            transfer: preferredTransfer,
                            fileFormat: preferredFormat,
                            cancel: cancelToken,
                            progress: reportDropProgress
                        )
                        try cancelToken.throwIfCancelled()
                        preview = (try? TapeEngine.loadForDisplay(from: dest)) ?? .empty
                        var ratio = ""
                        if result.originalBytes > 0, result.columns < result.originalBytes {
                            let pct = Int((1.0 - Double(result.columns) / Double(result.originalBytes)) * 100)
                            ratio = " · payload −\(pct)%"
                        }
                        status =
                            "Packed \(result.files) file(s) → \(result.columns) cols\(ratio) · "
                            + "\(result.compressionNote) · \(preferredFormat.shortName) · \(dest.lastPathComponent)"
                    } else {
                        let result = try TapeEngine.encodeFileStreaming(
                            from: source,
                            to: dest,
                            compression: preferredCompression,
                            transfer: preferredTransfer,
                            fileFormat: preferredFormat,
                            cancel: cancelToken,
                            progress: reportDropProgress
                        )
                        try cancelToken.throwIfCancelled()
                        preview = (try? TapeEngine.loadForDisplay(from: dest)) ?? .empty
                        let mode = result.usedStream ? "streamed" : "encoded"
                        status =
                            "Punched \(source.lastPathComponent) → \(dest.lastPathComponent) · "
                            + "\(result.columns) cols (\(mode))"
                    }
                    DispatchQueue.main.async {
                        finishAccess()
                        dropEncodeInFlight = false
                        filesEncodeBusy = false
                        clearDropProgress()
                        if !preview.isEmpty {
                            applyLoadedDocument(preview, url: dest)
                        } else {
                            mode = .files
                        }
                        statusMessage = status
                        if OpenFileBridge.hasPending() {
                            OpenFileBridge.requestFlush()
                        }
                    }
                } catch {
                    let cancelled = (error as? TapeEngine.FormatError)?.isCancellation == true
                        || cancelToken.isCancelled
                    if cancelled {
                        try? FileManager.default.removeItem(at: dest)
                    }
                    DispatchQueue.main.async {
                        finishAccess()
                        dropEncodeInFlight = false
                        filesEncodeBusy = false
                        clearDropProgress()
                        statusMessage = cancelled
                            ? "Encode cancelled."
                            : "Encode failed: \(error.localizedDescription)"
                        if OpenFileBridge.hasPending() {
                            OpenFileBridge.requestFlush()
                        }
                    }
                }
            }
        }

        // Prefer a sheet on the key window so the panel is never hidden behind the app.
        let present: (NSApplication.ModalResponse) -> Void = { response in
            guard response == .OK, let dest = panel.url else {
                finishAccess()
                dropEncodeInFlight = false
                filesEncodeBusy = false
                clearDropProgress()
                statusMessage = "Save cancelled"
                if OpenFileBridge.hasPending() {
                    OpenFileBridge.requestFlush()
                }
                return
            }
            runEncode(dest)
        }

        if let window = NSApp.keyWindow ?? NSApp.mainWindow ?? NSApp.windows.first(where: \.isVisible) {
            panel.beginSheetModal(for: window, completionHandler: present)
        } else {
            panel.begin(completionHandler: present)
        }
    }

    private static func pathIsDirectory(_ url: URL) -> Bool {
        let accessed = url.startAccessingSecurityScopedResource()
        defer { if accessed { url.stopAccessingSecurityScopedResource() } }
        var isDir: ObjCBool = false
        if FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir) {
            return isDir.boolValue
        }
        return (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
    }

    private func stem(of filename: String) -> String {
        let ns = filename as NSString
        let ext = ns.pathExtension
        if ext.isEmpty { return filename }
        return ns.deletingPathExtension
    }

    private var sampleText: String {
        """
        HELLO, PAPER TAPE.
        Knowledge is power — punch it once, feed it forever.
        """
    }
}
