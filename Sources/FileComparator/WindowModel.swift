import AppKit
import Observation
import UniformTypeIdentifiers
import DiffCore

enum Screen: Identifiable {
    case welcome
    case loading(String)
    case text(TextCompareModel)
    case folder(FolderCompareModel)
    case image(ImageCompareModel)
    case binary(BinaryCompareModel)

    var id: String {
        switch self {
        case .welcome: return "welcome"
        case .loading(let s): return "loading-\(s)"
        case .text(let m): return "text-\(ObjectIdentifier(m).hashValue)"
        case .folder(let m): return "folder-\(ObjectIdentifier(m).hashValue)"
        case .image(let m): return "image-\(ObjectIdentifier(m).hashValue)"
        case .binary(let m): return "binary-\(ObjectIdentifier(m).hashValue)"
        }
    }

    @MainActor var title: String {
        switch self {
        case .welcome: return "FileComparator"
        case .loading: return "Comparing…"
        case .text(let m): return m.sides.map(\.title).joined(separator: " ↔ ")
        case .folder(let m): return m.roots.map(\.lastPathComponent).joined(separator: " ↔ ")
        case .image(let m): return m.urls.map(\.lastPathComponent).joined(separator: " ↔ ")
        case .binary(let m): return m.urls.map(\.lastPathComponent).joined(separator: " ↔ ")
        }
    }
}

/// Per-window navigation history (like a browser): drilling into a file or sub-folder pushes a
/// screen; Back / Forward (toolbar, ⌘[ / ⌘], mouse side buttons, swipe) move through it.
@MainActor
@Observable
final class WindowModel {
    private(set) var history: [Screen] = [.welcome]
    private(set) var index = 0
    var errorMessage: String?
    /// URLs handed to the start page (e.g. a single file dropped on the Dock icon).
    var prefill: [URL] = []
    /// The window showing this model (used to route mouse back/forward buttons).
    @ObservationIgnored weak var hostWindow: NSWindow?

    static let historyLimit = 40

    var current: Screen { history[index] }
    var canGoBack: Bool { index > 0 }
    var canGoForward: Bool { index < history.count - 1 }
    var hasHistory: Bool { history.count > 1 }
    var isWelcome: Bool { if case .welcome = current { return true }; return false }

    var textModel: TextCompareModel? { if case .text(let m) = current { return m }; return nil }
    var folderModel: FolderCompareModel? { if case .folder(let m) = current { return m }; return nil }

    var backTitle: String? { canGoBack ? history[index - 1].title : nil }
    var forwardTitle: String? { canGoForward ? history[index + 1].title : nil }

    func goBack() {
        guard canGoBack, confirmDiscard() else { return }
        let saved = textModel?.didSave == true
        index -= 1
        // Files edited and saved in a drilled-in diff: refresh the folder comparison underneath.
        if saved, case .folder(let f) = current { f.rescan() }
    }

    func goForward() {
        guard canGoForward, confirmDiscard() else { return }
        index += 1
    }

    func goHome() {
        guard !isWelcome, confirmDiscard() else { return }
        show(.welcome, push: true)
    }

    /// Adds a screen after the current one (dropping any forward history), or replaces the current one.
    private func show(_ screen: Screen, push: Bool) {
        if push {
            let dropped = history[(index + 1)...]
            history.removeSubrange((index + 1)...)
            dropped.forEach(Self.release)
            history.append(screen)
            index = history.count - 1
            if history.count > Self.historyLimit {
                let excess = history.count - Self.historyLimit
                history[..<excess].forEach(Self.release)
                history.removeFirst(excess)
                index -= excess
            }
        } else {
            let old = history[index]
            history[index] = screen
            if old.id != screen.id { Self.release(old) }
        }
    }

    /// Swaps a placeholder (loading screen) for its result wherever it sits in the history.
    private func replace(id: String, with screen: Screen?) {
        guard let i = history.firstIndex(where: { $0.id == id }) else { return }
        if let screen {
            history[i] = screen
        } else {
            history.remove(at: i)
            if history.isEmpty { history = [.welcome] }
            if index >= i { index = max(0, index - 1) }
            index = min(index, history.count - 1)
        }
    }

    private static func release(_ s: Screen) {
        if case .text(let m) = s { m.tearDown() }
        if case .folder(let f) = s { f.cancel() }
    }

    var hasUnsavedChanges: Bool { textModel?.hasUnsavedChanges == true }

    /// Asks before leaving unsaved merge work. Returns true if it is OK to proceed.
    /// "Don't Save" reverts the edits so the screen stays clean in the history.
    func confirmDiscard() -> Bool {
        textModel?.flushEditors()
        guard let m = textModel, m.hasUnsavedChanges else { return true }
        let alert = NSAlert()
        alert.messageText = "Save changes to \(m.sides.filter(\.isDirty).map(\.title).joined(separator: ", "))?"
        alert.informativeText = "Your merge edits will be lost if you don’t save them."
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Cancel")
        alert.addButton(withTitle: "Don’t Save")
        switch alert.runModal() {
        case .alertFirstButtonReturn:
            return m.save() && !m.hasUnsavedChanges
        case .alertThirdButtonReturn:
            m.revertUnsaved()
            return true
        default:
            return false
        }
    }

    /// Opens a comparison. When `push` is true it is layered over the current screen (drill-down).
    func open(_ urls: [URL], push: Bool = true, recordRecent: Bool = true) {
        if push { guard confirmDiscard() else { return } }
        let urls = urls.map { $0.standardizedFileURL }
        guard urls.count >= 2 && urls.count <= 3 else {
            errorMessage = "Choose two or three files or folders to compare."
            return
        }
        let fm = FileManager.default
        var dirs: [Bool] = []
        for u in urls {
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: u.path, isDirectory: &isDir) else {
                errorMessage = "“\(u.lastPathComponent)” could not be found."
                return
            }
            dirs.append(isDir.boolValue)
        }
        if Set(dirs).count > 1 {
            errorMessage = "Cannot compare a folder with a file. Choose only files or only folders."
            return
        }
        func show(_ s: Screen) { self.show(s, push: push) }

        if dirs[0] {
            let m = FolderCompareModel(roots: urls, window: self)
            show(.folder(m))
            m.start()
            if recordRecent { Preferences.shared.addRecent(urls: urls, kind: "folder") }
            return
        }

        if urls.allSatisfy({ Self.isImage($0) }) {
            show(.image(ImageCompareModel(urls: urls)))
            if recordRecent { Preferences.shared.addRecent(urls: urls, kind: "image") }
            return
        }

        let loadingScreen = Screen.loading(urls.map(\.lastPathComponent).joined(separator: ", "))
        show(loadingScreen)
        let loadingID = loadingScreen.id
        let options = Preferences.shared.compareOptions
        Task {
            let screen: Screen
            do {
                let model = try await TextCompareModel.load(urls: urls, options: options)
                screen = .text(model)
                if recordRecent { Preferences.shared.addRecent(urls: urls, kind: "text") }
            } catch TextFile.LoadError.binary {
                let model = await BinaryCompareModel.load(urls: urls)
                screen = .binary(model)
                if recordRecent { Preferences.shared.addRecent(urls: urls, kind: "binary") }
            } catch {
                self.errorMessage = error.localizedDescription
                self.replace(id: loadingID, with: nil)
                return
            }
            self.replace(id: loadingID, with: screen)
        }
    }

    /// Starts an empty comparison to paste or type text into.
    func openBlank(count: Int) {
        guard confirmDiscard() else { return }
        show(.text(TextCompareModel.blank(count: count)), push: true)
    }

    /// Opens a text comparison where some panes have no file (blank, or missing on that side).
    func open(slots: [URL?], missing: [(title: String, suggested: URL?)?]) {
        let present = slots.compactMap { $0 }
        if present.isEmpty { openBlank(count: slots.count); return }
        guard confirmDiscard() else { return }
        let loadingScreen = Screen.loading(present.map(\.lastPathComponent).joined(separator: ", "))
        show(loadingScreen, push: true)
        let loadingID = loadingScreen.id
        let options = Preferences.shared.compareOptions
        Task {
            do {
                let model = try await TextCompareModel.load(slots: slots, missing: missing, options: options)
                self.replace(id: loadingID, with: .text(model))
            } catch {
                self.errorMessage = (error as? TextFile.LoadError).map { _ in "Only text files can be compared with an empty pane." } ?? error.localizedDescription
                self.replace(id: loadingID, with: nil)
                if present.count == 1, slots.count > 1, (error as? TextFile.LoadError) != nil {
                    // A binary/image file that exists on one side only: just open it, as before.
                    self.errorMessage = nil
                    NSWorkspace.shared.open(present[0])
                }
            }
        }
    }

    static func isImage(_ url: URL) -> Bool {
        guard let type = UTType(filenameExtension: url.pathExtension) else { return false }
        return type.conforms(to: .image) && !type.conforms(to: .svg) && !type.conforms(to: .pdf)
    }

    /// Re-runs the comparison with the given order (used by "swap sides" on non-text screens).
    func reopen(_ urls: [URL]) { open(urls, push: false, recordRecent: false) }
}
