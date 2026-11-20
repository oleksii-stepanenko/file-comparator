import Foundation

public struct FileMeta: Sendable, Equatable {
    public var size: Int64
    public var modified: Date?
    public var isDirectory: Bool
}

public enum EntryStatus: Int, Sendable, Comparable {
    case identical
    case different
    case missing      // not present on every side
    case pending
    case error

    public static func < (lhs: EntryStatus, rhs: EntryStatus) -> Bool { lhs.rawValue < rhs.rawValue }
}

public final class FolderNode: Identifiable, @unchecked Sendable {
    public let id: String          // unique key
    public let path: String        // relative path
    public let name: String
    public let isDirectory: Bool
    public var metas: [FileMeta?]
    public var status: EntryStatus = .pending
    public var children: [FolderNode] = []
    public weak var parent: FolderNode?
    /// Aggregated counts for directories (files only).
    public var differentCount = 0
    public var missingCount = 0
    public var fileCount = 0

    public init(id: String, path: String? = nil, name: String, isDirectory: Bool, metas: [FileMeta?]) {
        self.id = id
        self.path = path ?? id
        self.name = name
        self.isDirectory = isDirectory
        self.metas = metas
    }

    public var relativePath: String { path }

    public func isPresent(_ side: Int) -> Bool { metas[side] != nil }

    public var presentSides: [Int] { metas.indices.filter { metas[$0] != nil } }

    public func url(side: Int, roots: [URL]) -> URL {
        path.isEmpty ? roots[side] : roots[side].appendingPathComponent(path)
    }
}

public struct FolderCompareOptions: Equatable, Sendable, Codable {
    public var includeHidden = false
    public var compareContents = true
    public var excludedNames: [String] = [".DS_Store", ".git", "node_modules", ".build", "DerivedData", ".svn", ".hg", "__pycache__"]

    public init() {}
}

public enum FolderComparator {
    private static let keys: [URLResourceKey] = [.isDirectoryKey, .fileSizeKey, .contentModificationDateKey, .isSymbolicLinkKey]

    private static func matchesExclusion(_ name: String, _ patterns: [String]) -> Bool {
        for p in patterns where !p.isEmpty {
            if p.contains("*") || p.contains("?") {
                if fnmatch(p, name, 0) == 0 { return true }
            } else if p == name {
                return true
            }
        }
        return false
    }

    /// Builds the merged tree of all sides (no content comparison yet).
    public static func scan(roots: [URL], options: FolderCompareOptions, isCancelled: () -> Bool = { false }) -> FolderNode {
        let fm = FileManager.default
        let rootMetas: [FileMeta?] = roots.map { _ in FileMeta(size: 0, modified: nil, isDirectory: true) }
        let root = FolderNode(id: "", name: roots.first?.lastPathComponent ?? "", isDirectory: true, metas: rootMetas)

        func list(_ dir: URL) -> [String: FileMeta] {
            var out: [String: FileMeta] = [:]
            let opts: FileManager.DirectoryEnumerationOptions = options.includeHidden ? [] : [.skipsHiddenFiles]
            guard let items = try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: keys, options: opts) else { return out }
            for item in items {
                let name = item.lastPathComponent
                if matchesExclusion(name, options.excludedNames) { continue }
                let v = try? item.resourceValues(forKeys: Set(keys))
                var isDir = v?.isDirectory ?? false
                if v?.isSymbolicLink == true {
                    // Follow symlinks for type, but never recurse into linked directories.
                    isDir = false
                }
                out[name] = FileMeta(size: Int64(v?.fileSize ?? 0), modified: v?.contentModificationDate, isDirectory: isDir)
            }
            return out
        }

        func build(_ node: FolderNode, depth: Int) {
            if isCancelled() || depth > 64 { return }
            var listings: [[String: FileMeta]?] = []
            for (side, rootURL) in roots.enumerated() {
                if node.metas[side]?.isDirectory == true {
                    let url = node.path.isEmpty ? rootURL : rootURL.appendingPathComponent(node.path)
                    listings.append(list(url))
                } else {
                    listings.append(nil)
                }
            }
            var names = Set<String>()
            for l in listings { if let l { names.formUnion(l.keys) } }
            var dirs: [FolderNode] = []
            var files: [FolderNode] = []
            for name in names {
                let metas = listings.map { $0?[name] }
                let anyDir = metas.contains { $0?.isDirectory == true }
                let path = node.path.isEmpty ? name : node.path + "/" + name
                if anyDir {
                    // A file on one side and a directory on another: keep only directory sides.
                    let dirMetas = metas.map { $0?.isDirectory == true ? $0 : nil }
                    let child = FolderNode(id: path, name: name, isDirectory: true, metas: dirMetas)
                    child.parent = node
                    dirs.append(child)
                    if metas.contains(where: { $0 != nil && $0?.isDirectory == false }) {
                        let fileMetas = metas.map { $0?.isDirectory == false ? $0 : nil }
                        let f = FolderNode(id: path + "\u{0}file", path: path, name: name, isDirectory: false, metas: fileMetas)
                        f.parent = node
                        files.append(f)
                    }
                } else {
                    let child = FolderNode(id: path, name: name, isDirectory: false, metas: metas)
                    child.parent = node
                    files.append(child)
                }
            }
            let order: (FolderNode, FolderNode) -> Bool = { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
            dirs.sort(by: order)
            files.sort(by: order)
            node.children = dirs + files
            for d in dirs { build(d, depth: depth + 1) }
        }
        build(root, depth: 0)
        return root
    }

    /// Collects every file node in the tree.
    public static func files(in root: FolderNode) -> [FolderNode] {
        var out: [FolderNode] = []
        func walk(_ n: FolderNode) {
            for c in n.children {
                if c.isDirectory { walk(c) } else { out.append(c) }
            }
        }
        walk(root)
        return out
    }

    /// Sets a file node's status by comparing sizes then bytes.
    public static func compareFile(_ node: FolderNode, roots: [URL], compareContents: Bool) {
        let present = node.presentSides
        if present.count < node.metas.count {
            node.status = .missing
            return
        }
        let sizes = present.map { node.metas[$0]!.size }
        if Set(sizes).count > 1 {
            node.status = .different
            return
        }
        if !compareContents {
            let dates = present.compactMap { node.metas[$0]?.modified }
            node.status = Set(dates).count > 1 ? .different : .identical
            return
        }
        var status = EntryStatus.identical
        let first = node.url(side: present[0], roots: roots)
        for side in present.dropFirst() {
            switch bytesEqual(first, node.url(side: side, roots: roots)) {
            case .some(true): continue
            case .some(false): status = .different
            case .none: status = .error
            }
            if status != .identical { break }
        }
        node.status = status
    }

    /// Byte-for-byte comparison. Returns nil on read errors.
    public static func bytesEqual(_ a: URL, _ b: URL) -> Bool? {
        guard let ha = try? FileHandle(forReadingFrom: a), let hb = try? FileHandle(forReadingFrom: b) else { return nil }
        defer { try? ha.close(); try? hb.close() }
        let chunk = 1 << 18
        while true {
            let da: Data, db: Data
            do {
                da = try ha.read(upToCount: chunk) ?? Data()
                db = try hb.read(upToCount: chunk) ?? Data()
            } catch {
                return nil
            }
            if da != db { return false }
            if da.isEmpty { return true }
        }
    }

    /// Compares all files concurrently, then aggregates directory statuses.
    public static func compareAll(root: FolderNode, roots: [URL], options: FolderCompareOptions,
                                  progress: @escaping (Int, Int) -> Void, isCancelled: @escaping () -> Bool) {
        let all = files(in: root)
        let total = all.count
        let lock = NSLock()
        var done = 0
        DispatchQueue.concurrentPerform(iterations: max(1, min(total, ProcessInfo.processInfo.activeProcessorCount * 2))) { worker in
            let workers = max(1, min(total, ProcessInfo.processInfo.activeProcessorCount * 2))
            var idx = worker
            while idx < total {
                if isCancelled() { return }
                compareFile(all[idx], roots: roots, compareContents: options.compareContents)
                lock.lock()
                done += 1
                let d = done
                lock.unlock()
                if d % 64 == 0 || d == total { progress(d, total) }
                idx += workers
            }
        }
        aggregate(root)
    }

    /// Computes directory statuses and counts bottom-up.
    public static func aggregate(_ node: FolderNode) {
        guard node.isDirectory else { return }
        var different = 0, missing = 0, files = 0
        var anyNonIdentical = false
        var anyPending = false
        for c in node.children {
            if c.isDirectory {
                aggregate(c)
                different += c.differentCount
                missing += c.missingCount
                files += c.fileCount
            } else {
                files += 1
                if c.status == .different || c.status == .error { different += 1 }
                if c.status == .missing { missing += 1 }
            }
            if c.status == .pending { anyPending = true }
            if c.status != .identical { anyNonIdentical = true }
        }
        node.differentCount = different
        node.missingCount = missing
        node.fileCount = files
        if node.presentSides.count < node.metas.count {
            node.status = .missing
        } else if anyPending {
            node.status = .pending
        } else {
            node.status = anyNonIdentical ? .different : .identical
        }
    }
}
