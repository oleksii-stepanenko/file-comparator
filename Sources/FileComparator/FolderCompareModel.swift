import AppKit
import Observation
import DiffCore

struct FolderRow: Identifiable, Hashable {
    let node: FolderNode
    let depth: Int
    var id: String { node.id }

    static func == (a: FolderRow, b: FolderRow) -> Bool { a.node === b.node && a.depth == b.depth }
    func hash(into h: inout Hasher) { h.combine(node.id) }
}

enum FolderFilter: String, CaseIterable, Identifiable {
    case all, differences, different, missing, identical
    var id: String { rawValue }
    var title: String {
        switch self {
        case .all: return "All"
        case .differences: return "Differences"
        case .different: return "Changed"
        case .missing: return "Unique"
        case .identical: return "Identical"
        }
    }
}

@MainActor
@Observable
final class FolderCompareModel {
    let roots: [URL]
    weak var window: WindowModel?
    private(set) var root: FolderNode?
    var options: FolderCompareOptions
    private(set) var isScanning = false
    private(set) var phase = ""
    private(set) var progress: (done: Int, total: Int) = (0, 0)
    private(set) var rows: [FolderRow] = []
    var expanded: Set<String> = [""]
    var filter: FolderFilter = .all { didSet { rebuildRows() } }
    var search = "" { didSet { rebuildRows() } }
    var selection: Set<String> = []
    private(set) var counts: (identical: Int, different: Int, missing: Int, total: Int) = (0, 0, 0, 0)
    private(set) var elapsed: TimeInterval = 0
    /// Bumped after any status change so row views refresh.
    private(set) var revision = 0

    @ObservationIgnored private var cancelFlag = CancelFlag()

    final class CancelFlag: @unchecked Sendable {
        private let lock = NSLock()
        private var value = false
        var isCancelled: Bool { lock.lock(); defer { lock.unlock() }; return value }
        func cancel() { lock.lock(); value = true; lock.unlock() }
    }

    var sideCount: Int { roots.count }

    init(roots: [URL], window: WindowModel?) {
        self.roots = roots
        self.window = window
        self.options = Preferences.shared.folderOptions
    }

    func start() {
        cancelFlag.cancel()
        let flag = CancelFlag()
        cancelFlag = flag
        isScanning = true
        phase = "Scanning folders…"
        progress = (0, 0)
        let roots = self.roots
        let options = self.options
        let started = Date()
        Task.detached(priority: .userInitiated) { [weak self] in
            let tree = FolderComparator.scan(roots: roots, options: options, isCancelled: { flag.isCancelled })
            FolderComparator.aggregate(tree)
            await MainActor.run {
                guard let self, !flag.isCancelled else { return }
                self.root = tree
                if self.expanded == [""] {
                    // Expand the first level by default.
                    self.expanded = Set([""] + tree.children.filter(\.isDirectory).map(\.id))
                }
                self.phase = "Comparing contents…"
                self.rebuildRows()
            }
            let lastUpdate = LockedDate()
            FolderComparator.compareAll(root: tree, roots: roots, options: options, progress: { done, total in
                guard lastUpdate.shouldFire(interval: 0.08) || done == total else { return }
                Task { @MainActor [weak self] in
                    self?.progress = (done, total)
                }
            }, isCancelled: { flag.isCancelled })
            await MainActor.run {
                guard let self, !flag.isCancelled else { return }
                self.isScanning = false
                self.phase = ""
                self.elapsed = Date().timeIntervalSince(started)
                self.revision += 1
                self.rebuildRows()
            }
        }
    }

    func cancel() {
        cancelFlag.cancel()
        isScanning = false
    }

    func rescan() {
        Preferences.shared.folderOptions = options
        start()
    }

    // MARK: Rows

    private func matchesFilter(_ node: FolderNode) -> Bool {
        if !search.isEmpty && !node.isDirectory && !node.name.localizedCaseInsensitiveContains(search) { return false }
        switch filter {
        case .all: return true
        case .differences: return node.status != .identical
        case .different: return node.isDirectory ? node.differentCount > 0 : (node.status == .different || node.status == .error)
        case .missing: return node.isDirectory ? (node.missingCount > 0 || node.status == .missing) : node.status == .missing
        case .identical: return node.isDirectory ? node.fileCount > node.differentCount + node.missingCount : node.status == .identical
        }
    }

    /// A directory is shown if it, or any descendant, matches.
    private func visible(_ node: FolderNode) -> Bool {
        if !node.isDirectory { return matchesFilter(node) }
        if search.isEmpty { return matchesFilter(node) }
        return node.children.contains { visible($0) }
    }

    func rebuildRows() {
        guard let root else { rows = []; return }
        var out: [FolderRow] = []
        let searching = !search.isEmpty
        func walk(_ n: FolderNode, depth: Int) {
            for c in n.children where visible(c) {
                out.append(FolderRow(node: c, depth: depth))
                if c.isDirectory && (expanded.contains(c.id) || searching) {
                    walk(c, depth: depth + 1)
                }
            }
        }
        walk(root, depth: 0)
        rows = out
        let files = FolderComparator.files(in: root)
        var identical = 0, different = 0, missing = 0
        for f in files {
            switch f.status {
            case .identical: identical += 1
            case .different, .error: different += 1
            case .missing: missing += 1
            case .pending: break
            }
        }
        counts = (identical, different, missing, files.count)
    }

    func toggle(_ node: FolderNode) {
        guard node.isDirectory else { return }
        if expanded.contains(node.id) { expanded.remove(node.id) } else { expanded.insert(node.id) }
        rebuildRows()
    }

    func expandAll() {
        guard let root else { return }
        var ids: Set<String> = [""]
        func walk(_ n: FolderNode) { for c in n.children where c.isDirectory { ids.insert(c.id); walk(c) } }
        walk(root)
        expanded = ids
        rebuildRows()
    }

    func collapseAll() {
        expanded = [""]
        rebuildRows()
    }

    // MARK: Actions

    func open(_ node: FolderNode) {
        if node.isDirectory {
            if node.presentSides.count == sideCount {
                window?.open(roots.indices.map { node.url(side: $0, roots: roots) }, recordRecent: false)
            } else {
                toggle(node)
            }
            return
        }
        let present = node.presentSides
        if present.count == sideCount {
            window?.open(roots.indices.map { node.url(side: $0, roots: roots) }, recordRecent: false)
        } else if !present.isEmpty {
            // Missing on some side: show it against an empty pane (saving that pane creates the file).
            let slots: [URL?] = roots.indices.map { node.isPresent($0) ? node.url(side: $0, roots: roots) : nil }
            let missing: [(title: String, suggested: URL?)?] = roots.indices.map {
                node.isPresent($0) ? nil : ("Not in \(SideInfo.name($0, count: sideCount))", node.url(side: $0, roots: roots))
            }
            window?.open(slots: slots, missing: missing)
        }
    }

    /// The single selected row, if any.
    var selectedNode: FolderNode? {
        guard selection.count == 1, let id = selection.first else { return nil }
        return rows.first { $0.id == id }?.node
    }

    /// Finds a node by relative path (used by the debug hook).
    func node(atPath path: String) -> FolderNode? {
        guard let root else { return nil }
        func find(_ n: FolderNode) -> FolderNode? {
            for c in n.children {
                if c.path == path { return c }
                if c.isDirectory, let f = find(c) { return f }
            }
            return nil
        }
        return find(root)
    }

    func reveal(_ node: FolderNode, side: Int) {
        guard node.isPresent(side) else { return }
        NSWorkspace.shared.activateFileViewerSelecting([node.url(side: side, roots: roots)])
    }

    /// Copies a file or folder from one side to the other (WinMerge "Copy to Right/Left").
    func copy(_ node: FolderNode, from: Int, to: Int) {
        guard node.isPresent(from) else { return }
        let src = node.url(side: from, roots: roots)
        let dst = node.url(side: to, roots: roots)
        let alert = NSAlert()
        alert.messageText = "Copy “\(node.name)” to \(SideInfo.name(to, count: sideCount))?"
        alert.informativeText = node.isPresent(to)
            ? "The existing item at \(dst.path) will be moved to the Trash and replaced."
            : "The item will be created at \(dst.path)."
        alert.addButton(withTitle: "Copy")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        do {
            let fm = FileManager.default
            if fm.fileExists(atPath: dst.path) {
                try fm.trashItem(at: dst, resultingItemURL: nil)
            }
            try fm.createDirectory(at: dst.deletingLastPathComponent(), withIntermediateDirectories: true)
            try fm.copyItem(at: src, to: dst)
            start()
        } catch {
            window?.errorMessage = error.localizedDescription
        }
    }

    func moveToTrash(_ node: FolderNode, side: Int) {
        guard node.isPresent(side) else { return }
        let url = node.url(side: side, roots: roots)
        let alert = NSAlert()
        alert.messageText = "Move “\(node.name)” to the Trash?"
        alert.informativeText = url.path
        alert.addButton(withTitle: "Move to Trash")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        do {
            try FileManager.default.trashItem(at: url, resultingItemURL: nil)
            start()
        } catch {
            window?.errorMessage = error.localizedDescription
        }
    }
}

/// Thread-safe throttle helper for progress reporting.
final class LockedDate: @unchecked Sendable {
    private let lock = NSLock()
    private var last = Date.distantPast

    func shouldFire(interval: TimeInterval) -> Bool {
        lock.lock(); defer { lock.unlock() }
        let now = Date()
        if now.timeIntervalSince(last) >= interval { last = now; return true }
        return false
    }
}
