import Foundation

public enum WhitespaceMode: String, CaseIterable, Sendable, Codable {
    case compare
    case ignoreTrailing
    case ignoreChanges
    case ignoreAll

    public var title: String {
        switch self {
        case .compare: return "Compare whitespace"
        case .ignoreTrailing: return "Ignore leading & trailing"
        case .ignoreChanges: return "Ignore whitespace changes"
        case .ignoreAll: return "Ignore all whitespace"
        }
    }
}

public struct CompareOptions: Equatable, Sendable, Codable {
    public var whitespace: WhitespaceMode = .compare
    public var ignoreCase: Bool = false
    public var ignoreBlankLines: Bool = false
    public var algorithm: DiffAlgorithm = .patience
    /// Treat lines that differ only in digits as equal (WinMerge "Ignore numbers").
    public var ignoreNumbers: Bool = false

    enum CodingKeys: String, CodingKey { case whitespace, ignoreCase, ignoreBlankLines, algorithm, ignoreNumbers }

    public init(from decoder: Decoder) throws {
        // Tolerant decoding so options saved by older versions keep working.
        let c = try decoder.container(keyedBy: CodingKeys.self)
        whitespace = try c.decodeIfPresent(WhitespaceMode.self, forKey: .whitespace) ?? .compare
        ignoreCase = try c.decodeIfPresent(Bool.self, forKey: .ignoreCase) ?? false
        ignoreBlankLines = try c.decodeIfPresent(Bool.self, forKey: .ignoreBlankLines) ?? false
        algorithm = try c.decodeIfPresent(DiffAlgorithm.self, forKey: .algorithm) ?? .patience
        ignoreNumbers = try c.decodeIfPresent(Bool.self, forKey: .ignoreNumbers) ?? false
    }

    public init(whitespace: WhitespaceMode = .compare, ignoreCase: Bool = false,
                ignoreBlankLines: Bool = false, algorithm: DiffAlgorithm = .patience) {
        self.whitespace = whitespace
        self.ignoreCase = ignoreCase
        self.ignoreBlankLines = ignoreBlankLines
        self.algorithm = algorithm
    }

    public func normalize(_ line: String) -> String {
        var s = line
        switch whitespace {
        case .compare: break
        case .ignoreTrailing:
            s = s.trimmingCharacters(in: .whitespaces)
        case .ignoreChanges:
            var out = ""
            out.reserveCapacity(s.utf8.count)
            var inSpace = false
            for ch in s.trimmingCharacters(in: .whitespaces) {
                if ch == " " || ch == "\t" {
                    if !inSpace { out.append(" ") }
                    inSpace = true
                } else {
                    out.append(ch)
                    inSpace = false
                }
            }
            s = out
        case .ignoreAll:
            s.removeAll { $0 == " " || $0 == "\t" || $0 == "\u{00A0}" }
        }
        if ignoreNumbers { s.removeAll { $0.isASCII && $0.isNumber } }
        if ignoreCase { s = s.lowercased() }
        return s
    }
}

public enum ChunkKind: Sendable, Equatable {
    // Two-way
    case modified       // lines differ on both sides
    case deleted        // present only on the left
    case inserted       // present only on the right
    // Three-way (left, base, right)
    case leftChanged    // only left differs from base
    case rightChanged   // only right differs from base
    case bothChanged    // left and right made the same change
    case conflict       // left and right differ from base and from each other

    public var isConflict: Bool { self == .conflict }
}

/// One row of the aligned view. `lines[side]` is a line index or -1 for a filler (gap).
public struct DiffRow: Sendable, Equatable {
    public var l0: Int32
    public var l1: Int32
    public var l2: Int32
    /// Index into `DiffResult.chunks`, or -1 for an unchanged row.
    public var chunk: Int32

    @inline(__always) public func line(_ side: Int) -> Int {
        switch side {
        case 0: return Int(l0)
        case 1: return Int(l1)
        default: return Int(l2)
        }
    }
}

public struct DiffChunk: Sendable, Equatable {
    public var kind: ChunkKind
    public var rows: Range<Int>
    /// Line ranges per side covered by this chunk (empty ranges mark the insertion point).
    public var ranges: [Range<Int>]
}

public struct DiffResult: Sendable {
    public var sideCount: Int
    public var rows: [DiffRow]
    public var chunks: [DiffChunk]
    public var lineCounts: [Int]

    public var conflictCount: Int { chunks.filter { $0.kind == .conflict }.count }

    /// Number of lines that differ per side.
    public func changedLineCount(side: Int) -> Int {
        chunks.reduce(0) { $0 + $1.ranges[side].count }
    }

    public var isIdentical: Bool { chunks.isEmpty }

    public func chunkIndex(atRow row: Int) -> Int? {
        guard row >= 0 && row < rows.count else { return nil }
        let c = Int(rows[row].chunk)
        return c >= 0 ? c : nil
    }

    /// Row where the given line of the given side is displayed.
    public func row(forLine line: Int, side: Int) -> Int? {
        var best: Int?
        for (index, row) in rows.enumerated() {
            let l = row.line(side)
            if l < 0 { continue }
            if l >= line { return l == line ? index : (best ?? index) }
            best = index
        }
        return best
    }
}

public enum DiffEngine {
    /// Interns normalized lines into integer ids shared across all inputs.
    public static func intern(_ texts: [[String]], options: CompareOptions) -> [[Int]] {
        var table: [String: Int] = [:]
        table.reserveCapacity(texts.reduce(0) { $0 + $1.count })
        let trivial = options.whitespace == .compare && !options.ignoreCase && !options.ignoreNumbers
        return texts.map { lines in
            lines.map { line in
                let key = trivial ? line : options.normalize(line)
                if let id = table[key] { return id }
                let id = table.count
                table[key] = id
                return id
            }
        }
    }

    /// Ids of blank lines (after normalization) get unique negative ids when blank lines are ignored,
    /// so we instead strip them: returns mapping from compacted index to original index.
    private static func compactBlank(_ ids: [Int], lines: [String]) -> (ids: [Int], map: [Int]) {
        var out: [Int] = []
        var map: [Int] = []
        for (i, line) in lines.enumerated() where !line.allSatisfy({ $0 == " " || $0 == "\t" }) {
            out.append(ids[i])
            map.append(i)
        }
        return (out, map)
    }

    /// Computes matched line pairs between two id sequences, honouring the blank-line option.
    static func matchPairs(_ a: [Int], _ b: [Int], linesA: [String], linesB: [String],
                           options: CompareOptions) -> (a: [Int], b: [Int]) {
        if options.ignoreBlankLines {
            let ca = compactBlank(a, lines: linesA)
            let cb = compactBlank(b, lines: linesB)
            let (ma, mb) = SequenceDiff(ca.ids, cb.ids, algorithm: options.algorithm).matches()
            var ra: [Int] = [], rb: [Int] = []
            ra.reserveCapacity(ma.count); rb.reserveCapacity(mb.count)
            for k in 0..<ma.count {
                ra.append(ca.map[ma[k]])
                rb.append(cb.map[mb[k]])
            }
            // Blank lines between two consecutive matches pair up as equal where possible.
            return fillBlankMatches(ra, rb, linesA: linesA, linesB: linesB)
        }
        return SequenceDiff(a, b, algorithm: options.algorithm).matches()
    }

    private static func isBlank(_ s: String) -> Bool { s.allSatisfy { $0 == " " || $0 == "\t" } }

    private static func fillBlankMatches(_ ma: [Int], _ mb: [Int], linesA: [String], linesB: [String]) -> (a: [Int], b: [Int]) {
        var ra: [Int] = [], rb: [Int] = []
        var pa = 0, pb = 0
        func fillGap(_ endA: Int, _ endB: Int) {
            // Pair blank lines in the gap in order; non-blank lines remain unmatched.
            let blanksA = (pa..<endA).filter { isBlank(linesA[$0]) }
            let blanksB = (pb..<endB).filter { isBlank(linesB[$0]) }
            // Only treat as equal when the gap consists solely of blank lines on both sides.
            if blanksA.count == endA - pa && blanksB.count == endB - pb {
                for k in 0..<min(blanksA.count, blanksB.count) {
                    ra.append(blanksA[k]); rb.append(blanksB[k])
                }
            }
        }
        for k in 0..<ma.count {
            fillGap(ma[k], mb[k])
            ra.append(ma[k]); rb.append(mb[k])
            pa = ma[k] + 1; pb = mb[k] + 1
        }
        fillGap(linesA.count, linesB.count)
        return (ra, rb)
    }

    public static func compare(_ texts: [[String]], options: CompareOptions = .init()) -> DiffResult {
        precondition(texts.count == 2 || texts.count == 3, "Only 2- or 3-way comparisons are supported")
        let ids = intern(texts, options: options)
        if texts.count == 2 {
            return twoWay(ids, texts: texts, options: options)
        }
        return threeWay(ids, texts: texts, options: options)
    }

    // MARK: Two-way

    static func twoWay(_ ids: [[Int]], texts: [[String]], options: CompareOptions) -> DiffResult {
        let (ma, mb) = matchPairs(ids[0], ids[1], linesA: texts[0], linesB: texts[1], options: options)
        let hunks = SequenceDiff.hunks(matchA: ma, matchB: mb, countA: ids[0].count, countB: ids[1].count)
        var rows: [DiffRow] = []
        rows.reserveCapacity(max(ids[0].count, ids[1].count) + 16)
        var chunks: [DiffChunk] = []
        for h in hunks {
            if h.isEqual {
                for k in 0..<h.a.count {
                    rows.append(DiffRow(l0: Int32(h.a.lowerBound + k), l1: Int32(h.b.lowerBound + k), l2: -1, chunk: -1))
                }
                continue
            }
            if options.ignoreBlankLines && isBlankOnly(h.a, texts[0]) && isBlankOnly(h.b, texts[1]) {
                // Purely blank-line differences are shown as unchanged.
                let n = max(h.a.count, h.b.count)
                for k in 0..<n {
                    rows.append(DiffRow(l0: k < h.a.count ? Int32(h.a.lowerBound + k) : -1,
                                        l1: k < h.b.count ? Int32(h.b.lowerBound + k) : -1, l2: -1, chunk: -1))
                }
                continue
            }
            let kind: ChunkKind = h.a.isEmpty ? .inserted : (h.b.isEmpty ? .deleted : .modified)
            let chunkIndex = Int32(chunks.count)
            let start = rows.count
            let pairs = alignChangedLines(texts[0], h.a, texts[1], h.b)
            for (x, y) in pairs {
                rows.append(DiffRow(l0: Int32(x), l1: Int32(y), l2: -1, chunk: chunkIndex))
            }
            chunks.append(DiffChunk(kind: kind, rows: start..<rows.count, ranges: [h.a, h.b]))
        }
        return DiffResult(sideCount: 2, rows: rows, chunks: chunks, lineCounts: texts.map(\.count))
    }

    private static func isBlankOnly(_ r: Range<Int>, _ lines: [String]) -> Bool {
        r.allSatisfy { isBlank(lines[$0]) }
    }

    /// Aligns lines inside a changed block so that similar lines sit on the same row.
    /// Returns (leftLine or -1, rightLine or -1) pairs in display order.
    static func alignChangedLines(_ la: [String], _ ra: Range<Int>, _ lb: [String], _ rb: Range<Int>) -> [(Int, Int)] {
        let n = ra.count, m = rb.count
        if n == 0 { return rb.map { (-1, $0) } }
        if m == 0 { return ra.map { ($0, -1) } }
        // Large blocks or equal-size blocks: straightforward pairing.
        if n == m || n * m > 40_000 {
            return (0..<max(n, m)).map { k in
                (k < n ? ra.lowerBound + k : -1, k < m ? rb.lowerBound + k : -1)
            }
        }
        // DP alignment maximizing similarity (Needleman–Wunsch style with free gaps).
        let sa = ra.map { Similarity.signature(la[$0]) }
        let sb = rb.map { Similarity.signature(lb[$0]) }
        var score = [[Double]](repeating: [Double](repeating: 0, count: m + 1), count: n + 1)
        for i in 1...n {
            for j in 1...m {
                let s = Similarity.score(sa[i - 1], sb[j - 1])
                let matchScore = s > 0.4 ? score[i - 1][j - 1] + s : -1
                score[i][j] = max(score[i - 1][j], score[i][j - 1], matchScore)
            }
        }
        var pairs: [(Int, Int)] = []
        var i = n, j = m
        while i > 0 || j > 0 {
            if i > 0 && j > 0 {
                let s = Similarity.score(sa[i - 1], sb[j - 1])
                if s > 0.4 && abs(score[i][j] - (score[i - 1][j - 1] + s)) < 1e-9 {
                    pairs.append((ra.lowerBound + i - 1, rb.lowerBound + j - 1)); i -= 1; j -= 1; continue
                }
            }
            if i > 0 && (j == 0 || score[i][j] == score[i - 1][j]) {
                pairs.append((ra.lowerBound + i - 1, -1)); i -= 1
            } else {
                pairs.append((-1, rb.lowerBound + j - 1)); j -= 1
            }
        }
        pairs.reverse()
        // Merge adjacent (x,-1),(-1,y) into a single row to keep blocks compact.
        var merged: [(Int, Int)] = []
        var k = 0
        while k < pairs.count {
            var lefts: [Int] = [], rights: [Int] = []
            while k < pairs.count && (pairs[k].0 < 0 || pairs[k].1 < 0) {
                if pairs[k].0 >= 0 { lefts.append(pairs[k].0) } else { rights.append(pairs[k].1) }
                k += 1
            }
            for t in 0..<max(lefts.count, rights.count) {
                merged.append((t < lefts.count ? lefts[t] : -1, t < rights.count ? rights[t] : -1))
            }
            if k < pairs.count { merged.append(pairs[k]); k += 1 }
        }
        return merged
    }

    // MARK: Three-way

    static func threeWay(_ ids: [[Int]], texts: [[String]], options: CompareOptions) -> DiffResult {
        let L = ids[0], B = ids[1], R = ids[2]
        var mL = [Int](repeating: -1, count: B.count)
        var mR = [Int](repeating: -1, count: B.count)
        let pl = matchPairs(B, L, linesA: texts[1], linesB: texts[0], options: options)
        for k in 0..<pl.a.count { mL[pl.a[k]] = pl.b[k] }
        let pr = matchPairs(B, R, linesA: texts[1], linesB: texts[2], options: options)
        for k in 0..<pr.a.count { mR[pr.a[k]] = pr.b[k] }

        var rows: [DiffRow] = []
        rows.reserveCapacity(B.count + 16)
        var chunks: [DiffChunk] = []
        var i = 0, l = 0, r = 0
        while i < B.count || l < L.count || r < R.count {
            if i < B.count && mL[i] == l && mR[i] == r {
                rows.append(DiffRow(l0: Int32(l), l1: Int32(i), l2: Int32(r), chunk: -1))
                i += 1; l += 1; r += 1
                continue
            }
            var i2 = i
            while i2 < B.count && !(mL[i2] >= 0 && mR[i2] >= 0) { i2 += 1 }
            let l2 = i2 < B.count ? mL[i2] : L.count
            let r2 = i2 < B.count ? mR[i2] : R.count
            let segL = Array(L[l..<l2]), segB = Array(B[i..<i2]), segR = Array(R[r..<r2])
            let kind: ChunkKind?
            if segL == segB && segR == segB {
                kind = nil
            } else if segL == segB {
                kind = .rightChanged
            } else if segR == segB {
                kind = .leftChanged
            } else if segL == segR {
                kind = .bothChanged
            } else {
                kind = .conflict
            }
            let start = rows.count
            let count = max(segL.count, segB.count, segR.count)
            let chunkIndex: Int32 = kind == nil ? -1 : Int32(chunks.count)
            for k in 0..<count {
                rows.append(DiffRow(l0: k < segL.count ? Int32(l + k) : -1,
                                    l1: k < segB.count ? Int32(i + k) : -1,
                                    l2: k < segR.count ? Int32(r + k) : -1,
                                    chunk: chunkIndex))
            }
            if let kind {
                chunks.append(DiffChunk(kind: kind, rows: start..<rows.count, ranges: [l..<l2, i..<i2, r..<r2]))
            }
            i = i2; l = l2; r = r2
        }
        return DiffResult(sideCount: 3, rows: rows, chunks: chunks, lineCounts: texts.map(\.count))
    }

    // MARK: Merging helpers

    /// Returns `target` with the given chunk's lines replaced by the source side's lines.
    public static func applyChunk(_ chunk: DiffChunk, from source: Int, to target: Int,
                                  sourceLines: [String], targetLines: [String]) -> [String] {
        var out = targetLines
        out.replaceSubrange(chunk.ranges[target], with: sourceLines[chunk.ranges[source]])
        return out
    }

    /// Applies all non-conflicting changes into the base (side 1) of a three-way result.
    public static func autoMerge(_ result: DiffResult, texts: [[String]]) -> (merged: [String], applied: Int) {
        precondition(result.sideCount == 3)
        var base = texts[1]
        var applied = 0
        for chunk in result.chunks.reversed() {
            let source: Int
            switch chunk.kind {
            case .leftChanged, .bothChanged: source = 0
            case .rightChanged: source = 2
            default: continue
            }
            base.replaceSubrange(chunk.ranges[1], with: texts[source][chunk.ranges[source]])
            applied += 1
        }
        return (base, applied)
    }
}

/// Cheap line similarity based on character bigram multisets.
enum Similarity {
    struct Signature {
        var bigrams: [Int: Int]
        var total: Int
    }

    static func signature(_ s: String) -> Signature {
        let scalars = Array(s.unicodeScalars.filter { $0 != " " && $0 != "\t" })
        var dict: [Int: Int] = [:]
        if scalars.count < 2 {
            if let c = scalars.first { dict[Int(c.value)] = 1 }
            return Signature(bigrams: dict, total: dict.count)
        }
        for k in 0..<(scalars.count - 1) {
            let key = Int(scalars[k].value) &* 1_000_003 &+ Int(scalars[k + 1].value)
            dict[key, default: 0] += 1
        }
        return Signature(bigrams: dict, total: scalars.count - 1)
    }

    static func score(_ a: Signature, _ b: Signature) -> Double {
        if a.total == 0 && b.total == 0 { return 1 }
        if a.total == 0 || b.total == 0 { return 0 }
        var common = 0
        let (small, large) = a.bigrams.count < b.bigrams.count ? (a, b) : (b, a)
        for (k, v) in small.bigrams {
            if let w = large.bigrams[k] { common += min(v, w) }
        }
        return 2.0 * Double(common) / Double(a.total + b.total)
    }
}
