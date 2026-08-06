import AppKit
import SwiftUI

@main
struct MainEntry {
    static func main() {
        if CommandLine.arguments.contains("--self-test") {
            let result = TapeEngine.runSelfTest()
            print(result)
            exit(result.hasPrefix("Self-test passed") ? 0 : 1)
        }

        
        // CLI: --pack-folder <dir> <dest.Tape> [--format v7]
        if let idx = CommandLine.arguments.firstIndex(of: "--pack-folder"),
           CommandLine.arguments.count > idx + 2 {
            let root = URL(fileURLWithPath: CommandLine.arguments[idx + 1], isDirectory: true)
            let dest = URL(fileURLWithPath: CommandLine.arguments[idx + 2])
            var format = TapeEngine.TapeFileFormat.defaultWrite
            if let fidx = CommandLine.arguments.firstIndex(of: "--format"),
               CommandLine.arguments.count > fidx + 1,
               let f = TapeEngine.TapeFileFormat.parse(CommandLine.arguments[fidx + 1]) {
                format = f
            }
            do {
                let r = try TapeEngine.encodeFolder(root: root, to: dest, compression: .auto, transfer: .identity, fileFormat: format)
                print("packed files=\(r.files) columns=\(r.columns) format=\(format.shortName)")
                exit(0)
            } catch {
                print("PACK FAILED: \(error)")
                exit(1)
            }
        }
        // CLI: --extract-folder <tape> <dir>
        if let idx = CommandLine.arguments.firstIndex(of: "--extract-folder"),
           CommandLine.arguments.count > idx + 2 {
            let tape = URL(fileURLWithPath: CommandLine.arguments[idx + 1])
            let dest = URL(fileURLWithPath: CommandLine.arguments[idx + 2], isDirectory: true)
            do {
                let r = try TapeEngine.extractFolder(from: tape, to: dest)
                print("extracted files=\(r.files) bytes=\(r.bytes) failedBlocks=\(r.failedBlocks)")
                exit(0)
            } catch {
                print("EXTRACT FAILED: \(error)")
                exit(1)
            }
        }

// CLI: --encode-file <src> <dest> [--format v3|v4|v5|v6|v7]
        if let idx = CommandLine.arguments.firstIndex(of: "--encode-file"),
           CommandLine.arguments.count > idx + 2 {
            let src = URL(fileURLWithPath: CommandLine.arguments[idx + 1])
            let dest = URL(fileURLWithPath: CommandLine.arguments[idx + 2])
            var format = TapeEngine.TapeFileFormat.defaultWrite
            if let fidx = CommandLine.arguments.firstIndex(of: "--format"),
               CommandLine.arguments.count > fidx + 1,
               let f = TapeEngine.TapeFileFormat.parse(CommandLine.arguments[fidx + 1]) {
                format = f
            }
            do {
                let result = try TapeEngine.encodeFileStreaming(
                    from: src,
                    to: dest,
                    compression: .none,
                    transfer: .identity,
                    fileFormat: format
                )
                let reloaded = try TapeEngine.deserialize(try Data(contentsOf: dest, options: [.mappedIfSafe]))
                let payload = try reloaded.restoredData()
                let original = try Data(contentsOf: src)
                print("encoded columns=\(result.columns) stream=\(result.usedStream)")
                print("reloaded columns=\(reloaded.columns.count) packing=\(reloaded.packing) packedBytes=\(reloaded.packedByteCount)")
                print("original=\(original.count) restored=\(payload.count) match=\(payload == original)")
                print("integrity=\(reloaded.integrity?.summary ?? "nil")")
                exit(payload == original ? 0 : 2)
            } catch {
                print("ENCODE FAILED: \(error)")
                exit(1)
            }
        }

        let app = NSApplication.shared
        let delegate = AppDelegate.shared
        app.delegate = delegate
        app.setActivationPolicy(.regular)
        app.run()
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    static let shared = AppDelegate()

    private var window: NSWindow?

    private let minSize = NSSize(width: 820, height: 560)
    private let defaultSize = NSSize(width: 1020, height: 720)

    private override init() {
        super.init()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Track Finder file drags so the drop catcher hitTest works for inter-app drops.
        DropSupport.installDragSessionMonitorsIfNeeded()
        buildMainMenu()
        showMainWindow()
        DispatchQueue.main.async { [weak self] in
            self?.deliverPendingOpens()
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in
            self?.deliverPendingOpens()
        }
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        deliverPendingOpens()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag {
            showMainWindow()
        } else {
            window?.makeKeyAndOrderFront(nil)
        }
        return true
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        for url in urls {
            OpenFileBridge.enqueue(url)
        }
        showMainWindow()
        DispatchQueue.main.async { [weak self] in
            self?.deliverPendingOpens()
        }
    }

    func application(_ sender: NSApplication, openFile filename: String) -> Bool {
        OpenFileBridge.enqueue(URL(fileURLWithPath: filename))
        showMainWindow()
        DispatchQueue.main.async { [weak self] in
            self?.deliverPendingOpens()
        }
        return true
    }

    func application(_ sender: NSApplication, openFiles filenames: [String]) {
        for name in filenames {
            OpenFileBridge.enqueue(URL(fileURLWithPath: name))
        }
        showMainWindow()
        DispatchQueue.main.async { [weak self] in
            self?.deliverPendingOpens()
        }
        sender.reply(toOpenOrPrint: .success)
    }

    func applicationShouldOpenUntitledFile(_ sender: NSApplication) -> Bool {
        true
    }

    private func deliverPendingOpens() {
        guard OpenFileBridge.hasPending() else { return }
        showMainWindow()
        OpenFileBridge.requestFlush()
    }

    private func showMainWindow() {
        if let window {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let rootView = ContentView()
            .frame(minWidth: minSize.width, minHeight: minSize.height)

        let hosting = NSHostingView(rootView: rootView)
        hosting.frame = NSRect(origin: .zero, size: defaultSize)

        // Root container so we can pin a full-window drop catcher above SwiftUI.
        // TextEditor and other SwiftUI views steal Finder drops otherwise.
        let container = NSView(frame: NSRect(origin: .zero, size: defaultSize))
        container.autoresizingMask = [.width, .height]
        hosting.autoresizingMask = [.width, .height]
        hosting.frame = container.bounds
        container.addSubview(hosting)

        // Full-window AppKit drop target above SwiftUI (TextEditor steals SwiftUI onDrop).
        let catcher = FileDropCatcherView(frame: container.bounds)
        catcher.autoresizingMask = [.width, .height]
        catcher.onURLs = { urls in
            for url in urls {
                OpenFileBridge.enqueue(url)
            }
        }
        container.addSubview(catcher)
        // Also register the container so AppKit has a registered destination even if
        // hit-testing is flaky for a frame; the catcher still owns performDragOperation.
        container.registerForDraggedTypes(DropSupport.pasteboardTypes)

        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: defaultSize),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "PaperTape"
        window.contentView = container
        window.setContentSize(defaultSize)
        window.contentMinSize = minSize
        window.isRestorable = true
        window.setFrameAutosaveName("PaperTapeMain")
        window.center()
        window.isReleasedWhenClosed = false
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        self.window = window
    }

    @objc private func showAbout(_ sender: Any?) {
        let info = Bundle.main.infoDictionary
        let short = info?["CFBundleShortVersionString"] as? String
        let build = info?["CFBundleVersion"] as? String
        let versionLine: String
        switch (short, build) {
        case let (s?, b?): versionLine = "Version \(s) (\(b))"
        case let (s?, nil): versionLine = "Version \(s)"
        default: versionLine = "Version unavailable"
        }
        let options: [NSApplication.AboutPanelOptionKey: Any] = [
            .applicationName: "PaperTape",
            .version: build ?? "",
            .applicationVersion: versionLine,
            .credits: NSAttributedString(
                string: """
                Encode data as classic 8-channel punched paper tape.

                Binary dialects (v1–v3): one byte per column (ch1 = LSB).
                Default write: v7 hexadecimal (32 bits/col). v8 base-256 — experimental maximum density (64 bits/col, grayscale).
                .Tape files round-trip losslessly; only v1 embeds a terminal-paper preview footer.
                Suggested save names: name-v1.Tape … name-v8.Tape.

                Double-click a .Tape file to open it.
                """,
                attributes: [
                    .font: NSFont.systemFont(ofSize: NSFont.smallSystemFontSize),
                    .foregroundColor: NSColor.secondaryLabelColor,
                ]
            ),
        ]
        NSApp.orderFrontStandardAboutPanel(options: options)
    }

    private func buildMainMenu() {
        let mainMenu = NSMenu()

        let appMenuItem = NSMenuItem()
        mainMenu.addItem(appMenuItem)
        let appMenu = NSMenu()
        appMenuItem.submenu = appMenu
        appMenu.addItem(
            withTitle: "About PaperTape",
            action: #selector(showAbout(_:)),
            keyEquivalent: ""
        )
        appMenu.addItem(NSMenuItem.separator())
        appMenu.addItem(
            withTitle: "Hide PaperTape",
            action: #selector(NSApplication.hide(_:)),
            keyEquivalent: "h"
        )
        let hideOthers = appMenu.addItem(
            withTitle: "Hide Others",
            action: #selector(NSApplication.hideOtherApplications(_:)),
            keyEquivalent: "h"
        )
        hideOthers.keyEquivalentModifierMask = [.command, .option]
        appMenu.addItem(
            withTitle: "Show All",
            action: #selector(NSApplication.unhideAllApplications(_:)),
            keyEquivalent: ""
        )
        appMenu.addItem(NSMenuItem.separator())
        appMenu.addItem(
            withTitle: "Quit PaperTape",
            action: #selector(NSApplication.terminate(_:)),
            keyEquivalent: "q"
        )

        let fileMenuItem = NSMenuItem()
        mainMenu.addItem(fileMenuItem)
        let fileMenu = NSMenu(title: "File")
        fileMenuItem.submenu = fileMenu
        fileMenu.addItem(
            withTitle: "Close",
            action: #selector(NSWindow.performClose(_:)),
            keyEquivalent: "w"
        )

        let editMenuItem = NSMenuItem()
        mainMenu.addItem(editMenuItem)
        let editMenu = NSMenu(title: "Edit")
        editMenuItem.submenu = editMenu
        editMenu.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        editMenu.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "Z")
        editMenu.addItem(NSMenuItem.separator())
        editMenu.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        editMenu.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        editMenu.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")

        let windowMenuItem = NSMenuItem()
        mainMenu.addItem(windowMenuItem)
        let windowMenu = NSMenu(title: "Window")
        windowMenuItem.submenu = windowMenu
        windowMenu.addItem(
            withTitle: "Minimize",
            action: #selector(NSWindow.performMiniaturize(_:)),
            keyEquivalent: "m"
        )
        windowMenu.addItem(
            withTitle: "Zoom",
            action: #selector(NSWindow.performZoom(_:)),
            keyEquivalent: ""
        )
        windowMenu.addItem(NSMenuItem.separator())
        windowMenu.addItem(
            withTitle: "Bring All to Front",
            action: #selector(NSApplication.arrangeInFront(_:)),
            keyEquivalent: ""
        )
        NSApp.windowsMenu = windowMenu

        NSApp.mainMenu = mainMenu
    }
}
