import Foundation

/// What the aligned view shows.
public enum ViewMode: Equatable, Sendable, Codable, Hashable {
    /// Every row of both files.
    case all
    /// Differences plus `n` unchanged lines above and below each one.
    case context(Int)
    /// Differences only (unchanged runs collapse into a single fold row).
    case changesOnly

    public var contextLines: Int? {
        switch self {
        case .all: return nil
        case .context(let n): return max(0, n)
        case .changesOnly: return 0
        }
    }

    public var title: String {
        switch self {
        case .all: return "All Lines"
        case .context(let n): return "Changes + \(n) Line\(n == 1 ? "" : "s") of Context"
        case .changesOnly: return "Changes Only"
        }
    }

    public var shortTitle: String {
        switch self {
        case .all: return "All lines"
        case .context(let n): return "±\(n) context"
        case .changesOnly: return "Changes only"
        }
    }
}

/// One visual row: either a row of `DiffResult.rows` or a fold standing in for hidden unchanged rows.
public enum DisplayItem: Equatable, Sendable {
    case row(Int)
    /// Collapsed unchanged rows ("⋯ N unchanged lines"); click to expand.
    case fold(Range<Int>)
    /// Header above a fold the user expanded; click to collapse it again. Its rows follow.
    case expanded(Range<Int>)
}

/// Maps the rows of a `DiffResult` onto what is actually drawn, hiding unchanged runs that are
/// far from any difference. Chunk rows are never hidden, so each chunk maps to a contiguous
/// display range.
public struct DisplayLayout: Sendable {
    public let items: [DisplayItem]
    /// Display index of each result row, or -1 when the row is folded away.
    public let displayIndex: [Int32]
    public let isFiltered: Bool

    public var count: Int { items.count }

    public init(result: DiffResult, mode: ViewMode, revealed: IndexSet = IndexSet()) {
        let n = result.rows.count
        guard let context = mode.contextLines else {
            items = (0..<n).map { .row($0) }
            displayIndex = (0..<n).map { Int32($0) }
            isFiltered = false
            return
        }
        var visible = [Bool](repeating: false, count: n)
        for c in result.chunks {
            let lo = max(0, c.rows.lowerBound - context)
            let hi = min(n, c.rows.upperBound + context)
            if lo < hi { for i in lo..<hi { visible[i] = true } }
        }

        var items: [DisplayItem] = []
        items.reserveCapacity(n)
        var index = [Int32](repeating: -1, count: n)
        var i = 0
        while i < n {
            if visible[i] {
                index[i] = Int32(items.count)
                items.append(.row(i))
                i += 1
                continue
            }
            var j = i
            while j < n && !visible[j] { j += 1 }
            if j - i == 1 {
                // A fold would take the same space as the row itself; just show the row.
                index[i] = Int32(items.count)
                items.append(.row(i))
            } else if revealed.contains(integersIn: i..<j) {
                items.append(.expanded(i..<j))
                for k in i..<j {
                    index[k] = Int32(items.count)
                    items.append(.row(k))
                }
            } else {
                items.append(.fold(i..<j))
            }
            i = j
        }
        self.items = items
        self.displayIndex = index
        self.isFiltered = true
    }

    /// The result row drawn at a display index (nil for folds / out of range).
    public func resultRow(at display: Int) -> Int? {
        guard display >= 0 && display < items.count else { return nil }
        if case .row(let r) = items[display] { return r }
        return nil
    }

    /// Display range of a chunk (chunk rows are always visible).
    public func displayRange(of chunk: DiffChunk) -> Range<Int> {
        guard !chunk.rows.isEmpty, chunk.rows.lowerBound < displayIndex.count else { return 0..<0 }
        let start = Int(displayIndex[chunk.rows.lowerBound])
        guard start >= 0 else { return 0..<0 }
        return start..<(start + chunk.rows.count)
    }

    /// Closest result row for a display index (folds resolve to their first hidden row).
    public func nearestResultRow(at display: Int) -> Int {
        guard !items.isEmpty else { return 0 }
        switch items[max(0, min(display, items.count - 1))] {
        case .row(let r): return r
        case .fold(let range), .expanded(let range): return range.lowerBound
        }
    }
}
