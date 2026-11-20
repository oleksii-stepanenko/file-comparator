import AppKit
import Observation
import DiffCore

/// One pane of a text comparison.
struct TextSide {
    var url: URL?
    var title: String
    var file: TextFile
    var isDirty = false
    var language: SyntaxLanguage
    /// Where "Save" proposes to write an untitled pane (e.g. the missing file in a folder compare).
    var suggestedURL: URL?

    var lines: [String] { file.lines }
    var isUntitled: Bool { url == nil }
    /// True when the pane holds nothing at all.
    var isEmpty: Bool { file.lines.isEmpty || (file.lines.count == 1 && file.lines[0].isEmpty) }
    /// Exact inverse of `TextFile.split` (keeps a trailing newline so empty last lines survive).
    var text: String {
        let body = file.lines.joined(separator: "\n")
        return file.endsWithNewline && !file.lines.isEmpty ? body + "\n" : body
    }

    init(url: URL?, title: String? = nil, file: TextFile, suggestedURL: URL? = nil) {
        self.url = url
        self.title = title ?? url?.lastPathComponent ?? "Untitled"
        self.file = file
        self.suggestedURL = suggestedURL
        self.language = SyntaxLanguage.forExtension((url ?? suggestedURL)?.pathExtension ?? "")
    }
}

@MainActor
@Observable
final class TextCompareModel {
    var sides: [TextSide]
    private(set) var result: DiffResult
    var options: CompareOptions {
        didSet {
            guard options != oldValue else { return }
            Preferences.shared.compareOptions = options
            recompute()
        }
    }
    var currentChunk: Int?
    private(set) var isComputing = false
    var errorMessage: String?
    var showSyntax = true { didSet { grid?.invalidateAll() } }
    /// Word / character / no highlighting of the changed part inside a line.
    var inlineGranularity = Preferences.shared.inlineGranularity {
        didSet { Preferences.shared.inlineGranularity = inlineGranularity; grid?.invalidateAll() }
    }
    /// Draw spaces as · and tabs as →.
    var showWhitespace = Preferences.shared.showWhitespace {
        didSet { Preferences.shared.showWhitespace = showWhitespace; grid?.invalidateAll() }
    }
    var showLineNumbers = Preferences.shared.showLineNumbers {
        didSet { Preferences.shared.showLineNumbers = showLineNumbers; grid?.invalidateAll() }
    }
    /// What the aligned view shows (all rows, changes with context, changes only).
    var viewMode: ViewMode = Preferences.shared.viewMode {
        didSet {
            guard viewMode != oldValue else { return }
            Preferences.shared.viewMode = viewMode
            if case .context(let n) = viewMode { Preferences.shared.contextLines = n }
            revealed = IndexSet()
            rebuildLayout()
            grid?.reloadData()
            if let c = currentChunk { grid?.scrollTo(chunk: c, animated: false) }
        }
    }
    /// Rows of `result` mapped to what is drawn (folds hide distant unchanged lines).
    private(set) var layout: DisplayLayout
    /// Side-by-side plain text editors instead of the aligned grid (used for pasting / free editing).
    var isEditingText = false {
        didSet {
            guard isEditingText != oldValue else { return }
            if isEditingText { pushUndo() } else { flushEditors(); grid?.reloadData() }
        }
    }
    /// Set once anything has been written to disk (lets a folder comparison refresh itself).
    private(set) var didSave = false
    /// Pane that paste / keyboard edits go to in the grid (last clicked).
    var activeSide = 0
    /// Bumped whenever any side's text changes (drives cache invalidation in the grid).
    private(set) var textRevision = 0

    @ObservationIgnored weak var grid: DiffGridContainer?
    @ObservationIgnored private var undoStack: [[[String]]] = []
    @ObservationIgnored private var redoStack: [[[String]]] = []
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var watchers: [DispatchSourceFileSystemObject] = []
    @ObservationIgnored private var displayCache: [[String?]] = []
    @ObservationIgnored private var revealed = IndexSet()
    /// Live plain-text editors (edit mode) register here so pending keystrokes can be committed
    /// before anything reads the model, and so tests can type into them.
    struct EditorHook {
        var flush: () -> Void
        var type: (String) -> Void
    }
    @ObservationIgnored var editorHooks: [Int: EditorHook] = [:]

    /// Commits text typed in the editors that has not been pushed to the model yet.
    func flushEditors() {
        for hook in editorHooks.values { hook.flush() }
    }

    var sideCount: Int { sides.count }
    var isThreeWay: Bool { sides.count == 3 }
    var canUndo: Bool { !undoStack.isEmpty }
    var canRedo: Bool { !redoStack.isEmpty }
    /// Pure (read during rendering); call `flushEditors()` first when it matters.
    var hasUnsavedChanges: Bool { sides.contains { $0.isDirty && !($0.isUntitled && $0.isEmpty) } }
    /// Untitled scratch comparison (nothing came from disk).
    var isScratch: Bool { sides.allSatisfy { $0.isUntitled && $0.suggestedURL == nil } }

    init(sides: [TextSide], result: DiffResult, options: CompareOptions) {
        self.sides = sides
        self.result = result
        self.options = options
        self.layout = DisplayLayout(result: result, mode: Preferences.shared.viewMode)
        self.displayCache = sides.map { [String?](repeating: nil, count: $0.lines.count) }
        self.currentChunk = result.chunks.isEmpty ? nil : 0
        startWatching()
    }

    /// Loads files in the background and computes the initial diff.
    static func load(urls: [URL], options: CompareOptions) async throws -> TextCompareModel {
        let (files, result) = try await Task.detached(priority: .userInitiated) { () throws -> ([TextFile], DiffResult) in
            let files = try urls.map { try TextFile.load(url: $0) }
            let result = DiffEngine.compare(files.map(\.lines), options: options)
            return (files, result)
        }.value
        let sides = zip(urls, files).map { TextSide(url: $0, file: $1) }
        return TextCompareModel(sides: sides, result: result, options: options)
    }

    /// Loads a comparison where some panes have no file. `missing` supplies a title and the
    /// path the pane would be saved to (used for files that exist on one side of a folder only).
    static func load(slots: [URL?], missing: [(title: String, suggested: URL?)?], options: CompareOptions) async throws -> TextCompareModel {
        let files = try await Task.detached(priority: .userInitiated) { () throws -> [TextFile?] in
            try slots.map { try $0.map { try TextFile.load(url: $0) } }
        }.value
        let template = files.compactMap { $0 }.first
        let sides: [TextSide] = slots.indices.map { i in
            if let url = slots[i], let file = files[i] { return TextSide(url: url, file: file) }
            var empty = TextFile(lines: [])
            if let template { empty.encoding = template.encoding; empty.lineEnding = template.lineEnding }
            let info = i < missing.count ? missing[i] : nil
            return TextSide(url: nil, title: info?.title ?? "Untitled", file: empty, suggestedURL: info?.suggested)
        }
        let result = DiffEngine.compare(sides.map(\.file.lines), options: options)
        return TextCompareModel(sides: sides, result: result, options: options)
    }

    /// An empty two- or three-pane comparison to paste or type text into.
    static func blank(count: Int) -> TextCompareModel {
        let names = count == 3 ? ["Left", "Base", "Right"] : ["Left", "Right"]
        let sides = names.map { TextSide(url: nil, title: "Untitled \($0)", file: TextFile(lines: [])) }
        let options = Preferences.shared.compareOptions
        let m = TextCompareModel(sides: sides, result: DiffEngine.compare(sides.map(\.file.lines), options: options), options: options)
        m.isEditingText = true
        m.undoStack.removeAll()
        return m
    }

    // MARK: Display helpers

    static let tabWidth = 4

    /// Tab-expanded line used for drawing and inline diffs.
    func displayLine(side: Int, line: Int) -> String {
        guard side < sides.count, line >= 0, line < sides[side].file.lines.count, line < displayCache[side].count else { return "" }
        if let s = displayCache[side][line] { return s }
        let raw = sides[side].file.lines[line]
        let s: String
        if raw.contains("\t") {
            var out = ""
            out.reserveCapacity(raw.count + 8)
            var col = 0
            for ch in raw {
                if ch == "\t" {
                    let spaces = Self.tabWidth - (col % Self.tabWidth)
                    out.append(String(repeating: " ", count: spaces))
                    col += spaces
                } else {
                    out.append(ch)
                    col += 1
                }
            }
            s = out
        } else {
            s = raw
        }
        displayCache[side][line] = s
        return s
    }

    /// Longest display line in characters (approximation used for horizontal scrolling).
    func maxLineLength() -> Int {
        var m = 0
        for side in sides {
            for l in side.file.lines where l.utf16.count > m { m = l.utf16.count }
        }
        return m + m / 6
    }

    // MARK: Diff computation

    func recompute(keepPosition: Bool = true) {
        generation += 1
        let gen = generation
        let texts = sides.map(\.file.lines)
        let opts = options
        isComputing = true
        Task.detached(priority: .userInitiated) {
            let r = DiffEngine.compare(texts, options: opts)
            await MainActor.run { [weak self] in
                guard let self, gen == self.generation else { return }
                self.apply(result: r)
            }
        }
    }

    private func apply(result r: DiffResult) {
        result = r
        isComputing = false
        revealed = IndexSet()
        rebuildLayout()
        if r.chunks.isEmpty {
            currentChunk = nil
        } else if let c = currentChunk {
            currentChunk = min(c, r.chunks.count - 1)
        }
        grid?.reloadData()
    }

    private func rebuildLayout() {
        layout = DisplayLayout(result: result, mode: viewMode, revealed: revealed)
    }

    /// Expands a fold so the unchanged lines it hides become visible.
    func reveal(_ rows: Range<Int>) {
        revealed.insert(integersIn: rows)
        rebuildLayout()
        grid?.reloadData()
    }

    /// Folds an expanded region back up.
    func collapse(_ rows: Range<Int>) {
        revealed.remove(integersIn: rows)
        rebuildLayout()
        grid?.reloadData()
    }

    /// Folds every expanded region back up.
    func collapseAll() {
        guard !revealed.isEmpty else { return }
        revealed = IndexSet()
        rebuildLayout()
        grid?.reloadData()
    }

    var hasExpandedFolds: Bool { !revealed.isEmpty }

    /// Called after any line mutation. The diff is recomputed synchronously so that `result`
    /// never refers to line indices that no longer exist (the grid may redraw at any moment).
    private func textChanged() {
        generation += 1 // discard any in-flight async diff
        textRevision += 1
        displayCache = sides.map { [String?](repeating: nil, count: $0.lines.count) }
        let r = DiffEngine.compare(sides.map(\.file.lines), options: options)
        grid?.invalidateAll()
        apply(result: r)
    }

    // MARK: Undo

    private func pushUndo() {
        undoStack.append(sides.map(\.file.lines))
        if undoStack.count > 200 { undoStack.removeFirst() }
        redoStack.removeAll()
    }

    func undo() {
        flushEditors()
        guard let snapshot = undoStack.popLast() else { return }
        redoStack.append(sides.map(\.file.lines))
        restore(snapshot)
    }

    func redo() {
        guard let snapshot = redoStack.popLast() else { return }
        undoStack.append(sides.map(\.file.lines))
        restore(snapshot)
    }

    private func restore(_ snapshot: [[String]]) {
        for i in sides.indices where sides[i].file.lines != snapshot[i] {
            sides[i].file.lines = snapshot[i]
            sides[i].isDirty = true
        }
        textChanged()
    }

    // MARK: Merging

    func canCopy(chunk index: Int, from: Int, to: Int) -> Bool {
        guard index >= 0 && index < result.chunks.count, abs(from - to) >= 1 else { return false }
        let c = result.chunks[index]
        guard c.ranges[from].upperBound <= sides[from].lines.count, c.ranges[to].upperBound <= sides[to].lines.count else { return false }
        if sideCount == 2 { return true }
        // In three-way mode, only offer copies between sides that actually differ in this chunk.
        let a = Array(sides[from].file.lines[c.ranges[from]])
        let b = Array(sides[to].file.lines[c.ranges[to]])
        return a != b
    }

    func copy(chunk index: Int, from: Int, to: Int) {
        flushEditors()
        guard index >= 0 && index < result.chunks.count else { return }
        let c = result.chunks[index]
        guard c.ranges[from].upperBound <= sides[from].lines.count, c.ranges[to].upperBound <= sides[to].lines.count else { return }
        pushUndo()
        sides[to].file.lines = DiffEngine.applyChunk(c, from: from, to: to,
                                                    sourceLines: sides[from].file.lines,
                                                    targetLines: sides[to].file.lines)
        sides[to].isDirty = true
        currentChunk = index
        textChanged()
    }

    func copyCurrent(from: Int, to: Int) {
        guard let c = currentChunk else { return }
        copy(chunk: c, from: from, to: to)
    }

    /// Copies every difference from one side to another.
    func copyAll(from: Int, to: Int) {
        flushEditors()
        guard !result.chunks.isEmpty else { return }
        pushUndo()
        var target = sides[to].file.lines
        for c in result.chunks.reversed() {
            target.replaceSubrange(c.ranges[to], with: sides[from].file.lines[c.ranges[from]])
        }
        sides[to].file.lines = target
        sides[to].isDirty = true
        textChanged()
    }

    /// Three-way: merge all non-conflicting changes into the base (middle) pane.
    @discardableResult
    func autoMerge() -> Int {
        flushEditors()
        guard isThreeWay else { return 0 }
        let merged = DiffEngine.autoMerge(result, texts: sides.map(\.file.lines))
        guard merged.applied > 0 else { return 0 }
        pushUndo()
        sides[1].file.lines = merged.merged
        sides[1].isDirty = true
        currentChunk = 0
        textChanged()
        return merged.applied
    }

    func editLine(side: Int, line: Int, text: String) {
        guard line >= 0 && line < sides[side].file.lines.count, sides[side].file.lines[line] != text else { return }
        pushUndo()
        // A pasted multi-line string expands into several lines.
        let parts = TextFile.split(text).lines
        sides[side].file.lines.replaceSubrange(line...line, with: parts.isEmpty ? [""] : parts)
        sides[side].isDirty = true
        textChanged()
    }

    func insertLine(side: Int, after line: Int) {
        pushUndo()
        let at = min(max(line + 1, 0), sides[side].file.lines.count)
        sides[side].file.lines.insert("", at: at)
        sides[side].isDirty = true
        textChanged()
    }

    func deleteLines(side: Int, range: Range<Int>) {
        guard !range.isEmpty, range.upperBound <= sides[side].file.lines.count else { return }
        pushUndo()
        sides[side].file.lines.removeSubrange(range)
        sides[side].isDirty = true
        textChanged()
    }

    /// Replaces a whole pane (Paste / Clear / open a file into a pane).
    func replaceText(side: Int, with text: String) {
        guard side < sides.count else { return }
        let split = TextFile.split(text)
        guard split.lines != sides[side].file.lines else { return }
        pushUndo()
        setLines(side: side, split)
    }

    /// Live write-back from the text editors (undo is snapshotted once when editing starts).
    func setText(side: Int, text: String) {
        guard side < sides.count else { return }
        let split = TextFile.split(text)
        guard split.lines != sides[side].file.lines else { return }
        setLines(side: side, split)
    }

    private func setLines(side: Int, _ split: TextFile) {
        sides[side].file.lines = split.lines
        if sides[side].isUntitled && split.lineEnding != .mixed && !split.lines.isEmpty {
            // Pasted text keeps its own line endings when saved.
            sides[side].file.lineEnding = split.lineEnding
        }
        sides[side].isDirty = true
        textChanged()
    }

    /// Inserts clipboard text below `line` (or fills an empty pane).
    func paste(_ text: String, side: Int, afterLine line: Int?) {
        guard side < sides.count, !text.isEmpty else { return }
        var parts = TextFile.split(text).lines
        if parts.isEmpty { parts = [""] }
        if sides[side].isEmpty {
            replaceText(side: side, with: text)
            return
        }
        pushUndo()
        let at = min(max((line ?? (sides[side].file.lines.count - 1)) + 1, 0), sides[side].file.lines.count)
        sides[side].file.lines.insert(contentsOf: parts, at: at)
        sides[side].isDirty = true
        textChanged()
        // Show what was pasted (it may be off-screen when appended at the end).
        if let ci = result.chunks.firstIndex(where: { $0.ranges[side].contains(at) }) { select(chunk: ci) }
    }

    /// Loads a file from disk into one pane (keeps the other panes as they are).
    func loadFile(_ url: URL, into side: Int) {
        guard side < sides.count else { return }
        do {
            let file = try TextFile.load(url: url)
            if sides[side].isDirty && !sides[side].isEmpty { pushUndo() }
            sides[side] = TextSide(url: url, file: file)
            textChanged()
            startWatching()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func swapSides() {
        flushEditors()
        if isThreeWay { sides.swapAt(0, 2) } else { sides.swapAt(0, 1) }
        undoStack.removeAll(); redoStack.removeAll()
        textChanged()
    }

    // MARK: Navigation

    func select(chunk: Int?, scroll: Bool = true) {
        currentChunk = chunk
        if scroll, let c = chunk { grid?.scrollTo(chunk: c) }
        grid?.setNeedsDisplayAll()
    }

    private func anchorRow() -> Int {
        if let c = currentChunk, c < result.chunks.count { return result.chunks[c].rows.lowerBound }
        return grid?.topVisibleRow() ?? 0
    }

    func next(conflictsOnly: Bool = false) {
        let chunks = result.chunks
        guard !chunks.isEmpty else { return }
        let start = currentChunk.map { $0 + 1 } ?? chunks.firstIndex { $0.rows.lowerBound >= anchorRow() } ?? 0
        for i in start..<max(start, chunks.count) where !conflictsOnly || chunks[i].kind == .conflict {
            select(chunk: i); return
        }
        NSSound.beep()
    }

    func previous(conflictsOnly: Bool = false) {
        let chunks = result.chunks
        guard !chunks.isEmpty else { return }
        let start = (currentChunk ?? chunks.count) - 1
        guard start >= 0 else { NSSound.beep(); return }
        for i in stride(from: start, through: 0, by: -1) where !conflictsOnly || chunks[i].kind == .conflict {
            select(chunk: i); return
        }
        NSSound.beep()
    }

    func first() { if !result.chunks.isEmpty { select(chunk: 0) } }
    func last() { if !result.chunks.isEmpty { select(chunk: result.chunks.count - 1) } }

    var canGoNext: Bool { !result.chunks.isEmpty && (currentChunk ?? -1) < result.chunks.count - 1 }
    var canGoPrevious: Bool { !result.chunks.isEmpty && (currentChunk ?? 0) > 0 }

    // MARK: Files

    /// Saves every edited pane. Untitled panes ask for a location; returns false if the user cancelled.
    @discardableResult
    func save() -> Bool {
        flushEditors()
        for i in sides.indices where sides[i].isDirty {
            if sides[i].isUntitled {
                if sides[i].isEmpty { continue }
                guard saveAs(side: i) else { return false }
                continue
            }
            write(side: i, to: sides[i].url!)
        }
        return true
    }

    @discardableResult
    func saveAs(side i: Int) -> Bool {
        flushEditors()
        guard i < sides.count else { return false }
        let panel = NSSavePanel()
        panel.title = "Save \(sides[i].title)"
        panel.canCreateDirectories = true
        let proposed = sides[i].url ?? sides[i].suggestedURL
        if let proposed {
            panel.directoryURL = proposed.deletingLastPathComponent()
            panel.nameFieldStringValue = proposed.lastPathComponent
        } else {
            panel.nameFieldStringValue = sides[i].title.replacingOccurrences(of: " ", with: "-").lowercased() + ".txt"
        }
        guard panel.runModal() == .OK, let url = panel.url else { return false }
        guard write(side: i, to: url) else { return false }
        sides[i].url = url
        sides[i].title = url.lastPathComponent
        sides[i].suggestedURL = nil
        sides[i].language = SyntaxLanguage.forExtension(url.pathExtension)
        grid?.invalidateAll()
        startWatching()
        return true
    }

    @discardableResult
    private func write(side i: Int, to url: URL) -> Bool {
        do {
            stopWatching()
            try sides[i].file.write(to: url)
            sides[i].isDirty = false
            didSave = true
            startWatching()
            return true
        } catch {
            startWatching()
            errorMessage = "Could not save \(url.lastPathComponent): \(error.localizedDescription)"
            return false
        }
    }

    /// Throws away unsaved edits: panes backed by a file reload from disk; untitled panes keep
    /// their text but stop counting as unsaved.
    func revertUnsaved() {
        for i in sides.indices where sides[i].isDirty {
            if let url = sides[i].url, let file = try? TextFile.load(url: url) { sides[i].file = file }
            sides[i].isDirty = false
        }
        undoStack.removeAll(); redoStack.removeAll()
        textChanged()
    }

    func reload() {
        let urls = sides.compactMap(\.url)
        guard urls.count == sides.count else { return }
        do {
            for (i, url) in urls.enumerated() {
                let file = try TextFile.load(url: url)
                sides[i].file = file
                sides[i].isDirty = false
            }
            undoStack.removeAll(); redoStack.removeAll()
            textChanged()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    // MARK: File watching (auto reload untouched files changed on disk)

    private func startWatching() {
        stopWatching()
        for (i, side) in sides.enumerated() {
            guard let url = side.url else { continue }
            let fd = open(url.path, O_EVTONLY)
            guard fd >= 0 else { continue }
            let src = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: [.write, .rename, .delete], queue: .main)
            src.setEventHandler { [weak self] in
                MainActor.assumeIsolated {
                    self?.externalChange(side: i)
                }
            }
            src.setCancelHandler { close(fd) }
            src.resume()
            watchers.append(src)
        }
    }

    private func stopWatching() {
        watchers.forEach { $0.cancel() }
        watchers.removeAll()
    }

    private func externalChange(side: Int) {
        guard side < sides.count, !sides[side].isDirty, let url = sides[side].url else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in
            MainActor.assumeIsolated {
                guard let self, let file = try? TextFile.load(url: url), file.lines != self.sides[side].file.lines else { return }
                self.sides[side].file = file
                self.textChanged()
                self.startWatching() // re-arm after atomic replace
            }
        }
    }

    func tearDown() { stopWatching() }

    // MARK: Statistics

    var summary: String {
        let n = result.chunks.count
        if n == 0 {
            if isComputing { return "Comparing…" }
            if sides.allSatisfy(\.isEmpty) { return "Empty — paste or type text" }
            return sides.contains(where: \.isUntitled) ? "Identical" : "Files are identical"
        }
        var parts = ["\(n) difference\(n == 1 ? "" : "s")"]
        if isThreeWay {
            let c = result.conflictCount
            if c > 0 { parts.append("\(c) conflict\(c == 1 ? "" : "s")") }
        }
        return parts.joined(separator: " · ")
    }
}
