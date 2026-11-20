import SwiftUI
import AppKit
import DiffCore

@main
struct FileComparatorApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        WindowGroup(id: "main") {
            RootView()
        }
        .defaultSize(width: 1320, height: 840)
        .windowToolbarStyle(.unified(showsTitle: true))
        .commands { AppCommands() }

        Settings {
            SettingsView()
        }
    }
}

// MARK: - App delegate / command line

final class AppDelegate: NSObject, NSApplicationDelegate {
    /// Comparisons waiting for a window to pick them up.
    @MainActor static var pending: [[URL]] = []
    static var debugWindowIDPath: String?
    static var debugSize: NSSize?
    static var debugDark = false
    static var debugLight = false
    /// `--blank 2|3`: start with an empty comparison to paste into.
    @MainActor static var startBlank: Int?
    private var launchPaths: Set<String> = []
    private var launchDate = Date()

    func applicationWillFinishLaunching(_ notification: Notification) {
        NSWindow.allowsAutomaticWindowTabbing = true
        UserDefaults.standard.register(defaults: ["NSQuitAlwaysKeepsWindows": false])
        let urls = Self.parseArguments(Array(CommandLine.arguments.dropFirst()))
        if !urls.isEmpty {
            launchPaths = Set(urls.map(\.path))
            MainActor.assumeIsolated { Self.pending.append(urls) }
        }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Test launches run as an accessory app so they cannot take keyboard focus.
        NSApp.setActivationPolicy(Self.debugWindowIDPath == nil ? .regular : .accessory)
        if Self.debugDark { NSApp.appearance = NSAppearance(named: .darkAqua) }
        if Self.debugLight { NSApp.appearance = NSAppearance(named: .aqua) }
        // Screenshot/test launches must never steal keyboard focus from whatever the user is doing.
        if Self.debugWindowIDPath == nil { NSApp.activate(ignoringOtherApps: true) }
        installNavigationMonitor()
    }

    /// Mouse side buttons (button 3 = back, 4 = forward) and trackpad swipes navigate the
    /// window under the pointer, like in a browser or Finder.
    private func installNavigationMonitor() {
        NSEvent.addLocalMonitorForEvents(matching: [.otherMouseDown, .otherMouseUp, .swipe]) { event in
            let direction: Int
            switch event.type {
            case .swipe:
                guard event.deltaX != 0 else { return event }
                direction = event.deltaX > 0 ? -1 : 1
            case .otherMouseDown:
                guard event.buttonNumber == 3 || event.buttonNumber == 4 else { return event }
                direction = event.buttonNumber == 3 ? -1 : 1
            default:
                // Swallow the matching mouse-up so nothing else reacts to it.
                return (event.buttonNumber == 3 || event.buttonNumber == 4) ? nil : event
            }
            MainActor.assumeIsolated {
                guard let model = WindowRegistry.shared.model(for: event.window ?? NSApp.keyWindow) else { return }
                if direction < 0 { model.goBack() } else { model.goForward() }
            }
            return nil
        }
    }

    static func parseArguments(_ args: [String]) -> [URL] {
        var urls: [URL] = []
        var i = 0
        let cwd = FileManager.default.currentDirectoryPath
        while i < args.count {
            let a = args[i]
            if a == "--debug-window-id", i + 1 < args.count {
                debugWindowIDPath = args[i + 1]; i += 2; continue
            }
            if a == "--debug-size", i + 1 < args.count {
                let parts = args[i + 1].split(separator: "x").compactMap { Double($0) }
                if parts.count == 2 { debugSize = NSSize(width: parts[0], height: parts[1]) }
                i += 2; continue
            }
            if a == "--debug-dark" { debugDark = true; i += 1; continue }
            if a == "--debug-light" { debugLight = true; i += 1; continue }
            if a == "--blank" || a == "--paste" {
                var count = 2
                if i + 1 < args.count, let n = Int(args[i + 1]), n == 2 || n == 3 { count = n; i += 1 }
                MainActor.assumeIsolated { startBlank = count }
                i += 1; continue
            }
            if a.hasPrefix("-NS") || a.hasPrefix("-Apple") { i += 2; continue }
            if a.hasPrefix("-") { i += 1; continue }
            let path = (a as NSString).expandingTildeInPath
            let url = path.hasPrefix("/") ? URL(fileURLWithPath: path) : URL(fileURLWithPath: cwd).appendingPathComponent(path)
            urls.append(url.standardizedFileURL)
            i += 1
        }
        return urls
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        // AppKit also delivers command-line paths as open events; ignore those duplicates.
        if Date().timeIntervalSince(launchDate) < 3, Set(urls.map(\.path)).isSubset(of: launchPaths) { return }
        MainActor.assumeIsolated {
            Self.pending.append(urls)
            NotificationCenter.default.post(name: .openRequest, object: nil)
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        let dirty = MainActor.assumeIsolated {
            WindowRegistry.shared.models.contains { m in
                m.textModel?.flushEditors()
                return m.textModel?.hasUnsavedChanges == true
            }
        }
        guard dirty else { return .terminateNow }
        let alert = NSAlert()
        alert.messageText = "You have unsaved changes."
        alert.informativeText = "Quit anyway and discard them?"
        alert.addButton(withTitle: "Discard & Quit")
        alert.addButton(withTitle: "Cancel")
        return alert.runModal() == .alertFirstButtonReturn ? .terminateNow : .terminateCancel
    }
}

/// Tracks live window models (weakly) so app-level code can reach them.
@MainActor
final class WindowRegistry {
    static let shared = WindowRegistry()
    private var boxes: [WeakBox] = []

    private final class WeakBox { weak var value: WindowModel?; init(_ v: WindowModel) { value = v } }

    func register(_ m: WindowModel) {
        boxes.removeAll { $0.value == nil }
        if !boxes.contains(where: { $0.value === m }) { boxes.append(WeakBox(m)) }
    }

    var models: [WindowModel] { boxes.compactMap(\.value) }

    func model(for window: NSWindow?) -> WindowModel? {
        guard let window else { return nil }
        // Sheets/alerts belong to their parent window.
        let host = window.sheetParent ?? window
        return models.first { $0.hostWindow === host }
    }
}

// MARK: - Focused values

struct WindowModelKey: FocusedValueKey {
    typealias Value = WindowModel
}

extension FocusedValues {
    var windowModel: WindowModel? {
        get { self[WindowModelKey.self] }
        set { self[WindowModelKey.self] = newValue }
    }
}

// MARK: - Menu commands

struct AppCommands: Commands {
    @FocusedValue(\.windowModel) private var window
    @Environment(\.openWindow) private var openWindow

    private var text: TextCompareModel? { window?.textModel }

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button("New Comparison Window") { openWindow(id: "main") }
                .keyboardShortcut("n")
            Button("Open Files or Folders…") { openPanel() }
                .keyboardShortcut("o")
            Button("New Blank Comparison") { window?.openBlank(count: 2) }
                .keyboardShortcut("n", modifiers: [.command, .shift])
                .disabled(window == nil)
            Button("New Blank Three-Way Comparison") { window?.openBlank(count: 3) }
                .keyboardShortcut("n", modifiers: [.command, .shift, .option])
                .disabled(window == nil)
            Divider()
            Button("Back") { window?.goBack() }
                .keyboardShortcut("[", modifiers: .command)
                .disabled(!(window?.canGoBack ?? false))
            Button("Forward") { window?.goForward() }
                .keyboardShortcut("]", modifiers: .command)
                .disabled(!(window?.canGoForward ?? false))
            Button("Start Page") { window?.goHome() }
                .keyboardShortcut("h", modifiers: [.command, .shift])
        }
        CommandGroup(replacing: .saveItem) {
            Button("Save") { text?.save() }
                .keyboardShortcut("s")
                .disabled(!(text?.sides.contains(where: \.isDirty) ?? false))
            Button("Reload from Disk") { reload() }
                .keyboardShortcut("r")
                .disabled(window == nil || window?.isWelcome == true)
        }
        CommandGroup(replacing: .undoRedo) {
            Button("Undo") {
                if !sendToTextField(#selector(UndoManager.undo)) { text?.undo() }
            }
            .keyboardShortcut("z")
            .disabled(!(text?.canUndo ?? false) && text?.isEditingText != true)
            Button("Redo") {
                if !sendToTextField(#selector(UndoManager.redo)) { text?.redo() }
            }
            .keyboardShortcut("z", modifiers: [.command, .shift])
            .disabled(!(text?.canRedo ?? false) && text?.isEditingText != true)
        }
        CommandMenu("Compare") {
            Button("Next Difference") { text?.next() }
                .keyboardShortcut(.downArrow, modifiers: .option)
                .disabled(text == nil)
            Button("Previous Difference") { text?.previous() }
                .keyboardShortcut(.upArrow, modifiers: .option)
                .disabled(text == nil)
            Button("First Difference") { text?.first() }
                .keyboardShortcut(.upArrow, modifiers: [.option, .command])
                .disabled(text == nil)
            Button("Last Difference") { text?.last() }
                .keyboardShortcut(.downArrow, modifiers: [.option, .command])
                .disabled(text == nil)
            if text?.isThreeWay == true {
                Button("Next Conflict") { text?.next(conflictsOnly: true) }
                    .keyboardShortcut(.downArrow, modifiers: [.option, .control])
                Button("Previous Conflict") { text?.previous(conflictsOnly: true) }
                    .keyboardShortcut(.upArrow, modifiers: [.option, .control])
            }
            Divider()
            if text?.isThreeWay == true {
                Button("Take Left Change into Base") { text?.copyCurrent(from: 0, to: 1) }
                    .keyboardShortcut(.rightArrow, modifiers: .option)
                Button("Take Right Change into Base") { text?.copyCurrent(from: 2, to: 1) }
                    .keyboardShortcut(.leftArrow, modifiers: .option)
                Button("Merge All Non-Conflicting Changes") { text?.autoMerge() }
                    .keyboardShortcut("m", modifiers: [.command, .shift])
            } else {
                Button("Copy Change to Right") { text?.copyCurrent(from: 0, to: 1) }
                    .keyboardShortcut(.rightArrow, modifiers: .option)
                    .disabled(text?.currentChunk == nil)
                Button("Copy Change to Left") { text?.copyCurrent(from: 1, to: 0) }
                    .keyboardShortcut(.leftArrow, modifiers: .option)
                    .disabled(text?.currentChunk == nil)
                Button("Copy All Changes to Right") { text?.copyAll(from: 0, to: 1) }
                    .disabled(text == nil)
                Button("Copy All Changes to Left") { text?.copyAll(from: 1, to: 0) }
                    .disabled(text == nil)
            }
            Divider()
            Button("Swap Sides") { text?.swapSides() }
                .keyboardShortcut("x", modifiers: [.command, .option])
                .disabled(text == nil)
        }
        CommandGroup(after: .toolbar) {
            Button(text?.isEditingText == true ? "Show Differences" : "Edit as Text") { text?.isEditingText.toggle() }
                .keyboardShortcut("e")
                .disabled(text == nil)
            Divider()
            Button("Show All Lines") { text?.viewMode = .all }
                .keyboardShortcut("1")
                .disabled(text == nil)
            Button("Show Changes with Context") { text?.viewMode = .context(Preferences.shared.contextLines) }
                .keyboardShortcut("2")
                .disabled(text == nil)
            Button("Show Changes Only") { text?.viewMode = .changesOnly }
                .keyboardShortcut("3")
                .disabled(text == nil)
            Button("Collapse All Expanded Sections") { text?.collapseAll() }
                .keyboardShortcut("0", modifiers: [.command, .option])
                .disabled(!(text?.hasExpandedFolds ?? false))
            Button(text?.showWhitespace == true ? "Hide Whitespace" : "Show Whitespace") { text?.showWhitespace.toggle() }
                .keyboardShortcut("w", modifiers: [.command, .option])
                .disabled(text == nil)
            Divider()
            Button("Increase Font Size") { changeFont(+1) }
                .keyboardShortcut("+")
            Button("Decrease Font Size") { changeFont(-1) }
                .keyboardShortcut("-")
            Button("Actual Size") { Preferences.shared.fontSize = 12.5; NotificationCenter.default.post(name: .fontChanged, object: nil) }
                .keyboardShortcut("0")
            Divider()
        }
    }

    /// Undo/redo inside a text field or the plain-text editors goes to that text view.
    private func sendToTextField(_ selector: Selector) -> Bool {
        guard let responder = NSApp.keyWindow?.firstResponder as? NSTextView,
              responder.isFieldEditor || responder.allowsUndo else { return false }
        if selector == #selector(UndoManager.undo) { responder.undoManager?.undo() } else { responder.undoManager?.redo() }
        return true
    }

    private func reload() {
        guard let window else { return }
        switch window.current {
        case .text(let m): m.reload()
        case .folder(let m): m.rescan()
        case .image(let m): window.reopen(m.urls)
        case .binary(let m): window.reopen(m.urls)
        default: break
        }
    }

    private func changeFont(_ delta: CGFloat) {
        Preferences.shared.fontSize += delta
        NotificationCenter.default.post(name: .fontChanged, object: nil)
    }

    @MainActor
    private func openPanel() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = true
        panel.message = "Select two or three files or folders to compare"
        panel.prompt = "Compare"
        guard panel.runModal() == .OK else { return }
        AppDelegate.pending.append(panel.urls)
        NotificationCenter.default.post(name: .openRequest, object: nil)
    }
}
