import AppKit
import SwiftUI
import UniformTypeIdentifiers

// MARK: - Notifications

extension Notification.Name {
    /// Posted when a Finder file drag enters/leaves the window drop catcher.
    static let paperTapeFileDragTargeted = Notification.Name("PaperTape.fileDragTargeted")
}

/// Shared drag-and-drop helpers for Finder file drops on macOS.
enum DropSupport {
    static let pasteboardTypes: [NSPasteboard.PasteboardType] = [
        .fileURL,
        NSPasteboard.PasteboardType("public.file-url"),
        NSPasteboard.PasteboardType(rawValue: "NSFilenamesPboardType"),
        .URL,
    ]

    // MARK: Drag session tracking

    /// True while a file drag is likely in progress (Finder → app or within app).
    /// Updated by local/global mouse monitors so `hitTest` does not depend on
    /// `NSApp.currentEvent` being `.leftMouseDragged` (often nil for inter-app drops).
    private static let sessionLock = NSLock()
    private static var _fileDragLikelyActive = false
    private static var monitorsInstalled = false
    private static var localMonitor: Any?
    private static var globalMonitor: Any?

    /// Install once; safe to call repeatedly.
    static func installDragSessionMonitorsIfNeeded() {
        sessionLock.lock()
        defer { sessionLock.unlock() }
        guard !monitorsInstalled else { return }
        monitorsInstalled = true

        // Local: events delivered to this app (including during drop into our windows).
        localMonitor = NSEvent.addLocalMonitorForEvents(
            matching: [.leftMouseDragged, .leftMouseDown, .leftMouseUp, .flagsChanged]
        ) { event in
            updateFileDragState(from: event)
            return event
        }

        // Global: drag may start in Finder; we still see mouse-dragged/up.
        globalMonitor = NSEvent.addGlobalMonitorForEvents(
            matching: [.leftMouseDragged, .leftMouseUp]
        ) { event in
            updateFileDragState(from: event)
        }
    }

    private static func updateFileDragState(from event: NSEvent) {
        switch event.type {
        case .leftMouseUp:
            setFileDragLikelyActive(false)
        case .leftMouseDragged:
            if dragPasteboardHasFiles {
                setFileDragLikelyActive(true)
            }
        case .leftMouseDown:
            // Don't treat a click as a drag; clear stale pasteboard session.
            if !dragPasteboardHasFiles {
                setFileDragLikelyActive(false)
            }
        default:
            break
        }
    }

    private static func setFileDragLikelyActive(_ active: Bool) {
        sessionLock.lock()
        let changed = _fileDragLikelyActive != active
        _fileDragLikelyActive = active
        sessionLock.unlock()
        if changed, !active {
            // Ensure highlight clears if the catcher never got draggingExited.
            NotificationCenter.default.post(
                name: .paperTapeFileDragTargeted,
                object: nil,
                userInfo: ["targeted": false]
            )
        }
    }

    static var fileDragLikelyActive: Bool {
        sessionLock.lock()
        defer { sessionLock.unlock() }
        return _fileDragLikelyActive
    }

    /// Mark an AppKit dragging session as active (catcher entered).
    static func noteDraggingSessionEntered() {
        setFileDragLikelyActive(true)
    }

    static func noteDraggingSessionEnded() {
        setFileDragLikelyActive(false)
    }

    /// True while the system drag pasteboard currently advertises file URLs.
    /// Note: this can remain set briefly after a drag ends — never use alone for hit-testing.
    static var dragPasteboardHasFiles: Bool {
        let pb = NSPasteboard(name: .drag)
        return pb.availableType(from: pasteboardTypes) != nil
    }

    /// Whether AppKit is in an active drag-motion (not a click / mouseDown).
    static var isActiveDragMotion: Bool {
        if let event = NSApp.currentEvent {
            switch event.type {
            case .leftMouseDragged, .rightMouseDragged, .otherMouseDragged:
                return true
            default:
                break
            }
        }
        return fileDragLikelyActive
    }

    /// True when the catcher should claim hit-testing for a file drop.
    static var shouldClaimHitTestForFileDrop: Bool {
        guard dragPasteboardHasFiles else { return false }
        // Prefer explicit session / dragged motion; also accept left button held
        // while the drag pasteboard has files (inter-app Finder drag).
        if fileDragLikelyActive { return true }
        if isActiveDragMotion { return true }
        if NSEvent.pressedMouseButtons != 0 {
            // Exclude pure mouseDown clicks that would otherwise steal UI after a drop.
            if let event = NSApp.currentEvent {
                switch event.type {
                case .leftMouseDown, .leftMouseUp, .rightMouseDown, .rightMouseUp:
                    return false
                default:
                    return true
                }
            }
            // No currentEvent (common for inter-app drag) + button held + file PB.
            return true
        }
        return false
    }

    static func urls(fromDraggingInfo sender: NSDraggingInfo) -> [URL] {
        urls(from: sender.draggingPasteboard)
    }

    static func urls(from pb: NSPasteboard) -> [URL] {
        var urls: [URL] = []

        if let objects = pb.readObjects(forClasses: [NSURL.self], options: [
            .urlReadingFileURLsOnly: true,
        ]) as? [URL] {
            urls.append(contentsOf: objects.filter(\.isFileURL))
        }

        if urls.isEmpty,
           let paths = pb.propertyList(
            forType: NSPasteboard.PasteboardType(rawValue: "NSFilenamesPboardType")
           ) as? [String] {
            urls.append(contentsOf: paths.map { URL(fileURLWithPath: $0) })
        }

        // Modern file-URL pasteboard type as raw data
        if urls.isEmpty,
           let data = pb.data(forType: .fileURL),
           let str = String(data: data, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines),
           !str.isEmpty {
            if str.hasPrefix("file:"), let u = URL(string: str), u.isFileURL {
                urls.append(u)
            } else if str.hasPrefix("/") {
                urls.append(URL(fileURLWithPath: str))
            }
        }

        if urls.isEmpty,
           let str = pb.string(forType: .string)?.trimmingCharacters(in: .whitespacesAndNewlines),
           !str.isEmpty {
            if str.hasPrefix("file:"), let u = URL(string: str), u.isFileURL {
                urls.append(u)
            } else if str.hasPrefix("/") {
                urls.append(URL(fileURLWithPath: str))
            }
        }

        var seen = Set<String>()
        return urls.filter { url in
            let key = url.standardizedFileURL.path
            if seen.contains(key) { return false }
            seen.insert(key)
            return true
        }
    }

    static func readData(from url: URL) throws -> Data {
        let accessed = url.startAccessingSecurityScopedResource()
        defer {
            if accessed { url.stopAccessingSecurityScopedResource() }
        }
        return try Data(contentsOf: url)
    }

    static let utTypes: [UTType] = [.fileURL, .data, .item, .folder, .directory, .content]

    static func loadFileURL(from provider: NSItemProvider, completion: @escaping (URL?) -> Void) {
        if provider.canLoadObject(ofClass: URL.self) {
            _ = provider.loadObject(ofClass: URL.self) { url, _ in
                if let url {
                    DispatchQueue.main.async { completion(url) }
                    return
                }
                loadFileURLViaTypeIdentifier(from: provider, completion: completion)
            }
            return
        }
        loadFileURLViaTypeIdentifier(from: provider, completion: completion)
    }

    private static func loadFileURLViaTypeIdentifier(
        from provider: NSItemProvider,
        completion: @escaping (URL?) -> Void
    ) {
        let candidates = [
            UTType.fileURL.identifier,
            "public.file-url",
            "public.folder",
            "public.directory",
            "com.apple.pasteboard.promised-file-url",
            NSPasteboard.PasteboardType.fileURL.rawValue,
        ]
        let typeID = candidates.first(where: { provider.hasItemConformingToTypeIdentifier($0) })
            ?? UTType.fileURL.identifier

        provider.loadItem(forTypeIdentifier: typeID, options: nil) { item, _ in
            let url = fileURL(fromDropItem: item)
            DispatchQueue.main.async { completion(url) }
        }
    }

    static func fileURL(fromDropItem item: NSSecureCoding?) -> URL? {
        if let url = item as? URL { return url }
        if let nsurl = item as? NSURL { return nsurl as URL }
        if let data = item as? Data {
            if let url = URL(dataRepresentation: data, relativeTo: nil), url.isFileURL {
                return url
            }
            if let str = String(data: data, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines),
               !str.isEmpty {
                if str.hasPrefix("file:"), let url = URL(string: str) { return url }
                return URL(fileURLWithPath: str)
            }
        }
        if let str = item as? String {
            let trimmed = str.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.hasPrefix("file:"), let url = URL(string: trimmed) { return url }
            return URL(fileURLWithPath: trimmed)
        }
        if let arr = item as? [String], let first = arr.first {
            return URL(fileURLWithPath: first)
        }
        return nil
    }

    @discardableResult
    static func handleProviders(
        _ providers: [NSItemProvider],
        completion: @escaping (URL?) -> Void
    ) -> Bool {
        guard let provider = providers.first(where: { provider in
            provider.canLoadObject(ofClass: URL.self)
                || provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier)
                || provider.hasItemConformingToTypeIdentifier("public.file-url")
                || provider.hasItemConformingToTypeIdentifier("public.folder")
                || provider.hasItemConformingToTypeIdentifier("public.directory")
        }) ?? providers.first else {
            completion(nil)
            return false
        }
        loadFileURL(from: provider, completion: completion)
        return true
    }
}

// MARK: - Full-window AppKit drop catcher (clicks must pass through)

/// Transparent overlay that accepts Finder file drops.
///
/// **Critical:** `hitTest` must not claim the view for ordinary clicks.
/// We claim only while a file-drag session is active (tracked by event monitors
/// + drag pasteboard), never on bare mouseDown after a drop.
final class FileDropCatcherView: NSView {
    var onURLs: (([URL]) -> Void)?

    private var dragDepth = 0

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = false
        autoresizingMask = [.width, .height]
        registerForDraggedTypes(DropSupport.pasteboardTypes)
        DropSupport.installDragSessionMonitorsIfNeeded()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var isOpaque: Bool { false }

    override func hitTest(_ point: NSPoint) -> NSView? {
        let local = convert(point, from: superview)
        guard bounds.contains(local) else { return nil }

        // Already inside an AppKit dragging session for this view.
        if dragDepth > 0 {
            return self
        }

        // Claim only while a file drag is in progress — not for normal clicks.
        guard DropSupport.shouldClaimHitTestForFileDrop else {
            return nil
        }
        return self
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        DropSupport.noteDraggingSessionEntered()
        let urls = DropSupport.urls(fromDraggingInfo: sender)
        // Accept even if URL parse is empty at enter (promised files); prepare will recheck.
        dragDepth += 1
        if dragDepth == 1 {
            postTargeted(true)
        }
        if urls.isEmpty, !DropSupport.dragPasteboardHasFiles {
            return []
        }
        return .copy
    }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        DropSupport.noteDraggingSessionEntered()
        if !DropSupport.urls(fromDraggingInfo: sender).isEmpty || DropSupport.dragPasteboardHasFiles {
            return .copy
        }
        return []
    }

    override func draggingExited(_ sender: NSDraggingInfo?) {
        dragDepth = max(0, dragDepth - 1)
        if dragDepth == 0 {
            endDragSession()
        }
    }

    override func prepareForDragOperation(_ sender: NSDraggingInfo) -> Bool {
        // Promised files may only resolve at perform time — allow if pasteboard looks like files.
        !DropSupport.urls(fromDraggingInfo: sender).isEmpty || DropSupport.dragPasteboardHasFiles
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        var urls = DropSupport.urls(fromDraggingInfo: sender)
        // Last-chance: read filenames property list again (some apps only fill at drop).
        if urls.isEmpty {
            urls = DropSupport.urls(from: sender.draggingPasteboard)
        }
        endDragSession()
        guard !urls.isEmpty else { return false }
        deliver(urls)
        return true
    }

    override func concludeDragOperation(_ sender: NSDraggingInfo?) {
        endDragSession()
    }

    /// If we ever become first mouse target by mistake, do not swallow the click.
    override func mouseDown(with event: NSEvent) {
        if let superview {
            let point = superview.convert(event.locationInWindow, from: nil)
            for sibling in superview.subviews.reversed() where sibling !== self {
                let local = sibling.convert(point, from: superview)
                if let hit = sibling.hitTest(local) {
                    hit.mouseDown(with: event)
                    return
                }
            }
        }
        super.mouseDown(with: event)
    }

    private func deliver(_ urls: [URL]) {
        if Thread.isMainThread {
            onURLs?(urls)
        } else {
            DispatchQueue.main.async { [weak self] in
                self?.onURLs?(urls)
            }
        }
    }

    private func endDragSession() {
        dragDepth = 0
        DropSupport.noteDraggingSessionEnded()
        postTargeted(false)
    }

    private func postTargeted(_ targeted: Bool) {
        NotificationCenter.default.post(
            name: .paperTapeFileDragTargeted,
            object: nil,
            userInfo: ["targeted": targeted]
        )
    }
}

// MARK: - SwiftUI onDrop fallback (card-level + root ContentView)

private struct FileDropModifier: ViewModifier {
    @Binding var isTargeted: Bool
    var onURL: (URL) -> Void

    func body(content: Content) -> some View {
        content
            .contentShape(Rectangle())
            .onDrop(of: DropSupport.utTypes, isTargeted: $isTargeted) { providers in
                DropSupport.handleProviders(providers) { url in
                    guard let url else { return }
                    onURL(url)
                }
            }
    }
}

extension View {
    func onFileDrop(isTargeted: Binding<Bool>, perform: @escaping (URL) -> Void) -> some View {
        modifier(FileDropModifier(isTargeted: isTargeted, onURL: perform))
    }
}
