import XCTest
@testable import DiffCore

final class DiffCoreTests: XCTestCase {
    /// Reconstructs b from a using hunks to validate any edit script.
    private func verify(_ a: [Int], _ b: [Int], algorithm: DiffAlgorithm) {
        let hunks = SequenceDiff(a, b, algorithm: algorithm).hunks()
        var rebuilt: [Int] = []
        var ea = 0, eb = 0
        for h in hunks {
            XCTAssertEqual(h.a.lowerBound, ea)
            XCTAssertEqual(h.b.lowerBound, eb)
            if h.isEqual {
                XCTAssertEqual(Array(a[h.a]), Array(b[h.b]))
            }
            rebuilt += b[h.b]
            ea = h.a.upperBound
            eb = h.b.upperBound
        }
        XCTAssertEqual(ea, a.count)
        XCTAssertEqual(eb, b.count)
        XCTAssertEqual(rebuilt, b)
    }

    func testRandomSequencesProduceValidScripts() {
        var rng = SystemRandomNumberGenerator()
        for _ in 0..<400 {
            let n = Int.random(in: 0..<40, using: &rng)
            let m = Int.random(in: 0..<40, using: &rng)
            let alphabet = Int.random(in: 1..<6, using: &rng)
            let a = (0..<n).map { _ in Int.random(in: 0..<alphabet, using: &rng) }
            let b = (0..<m).map { _ in Int.random(in: 0..<alphabet, using: &rng) }
            verify(a, b, algorithm: .myers)
            verify(a, b, algorithm: .patience)
        }
    }

    func testMyersIsMinimal() {
        // LCS length check against DP for small random inputs.
        for _ in 0..<200 {
            let a = (0..<Int.random(in: 0..<25)).map { _ in Int.random(in: 0..<4) }
            let b = (0..<Int.random(in: 0..<25)).map { _ in Int.random(in: 0..<4) }
            let matches = SequenceDiff(a, b, algorithm: .myers).matches().a.count
            var dp = [[Int]](repeating: [Int](repeating: 0, count: b.count + 1), count: a.count + 1)
            for i in stride(from: a.count - 1, through: 0, by: -1) {
                for j in stride(from: b.count - 1, through: 0, by: -1) {
                    dp[i][j] = a[i] == b[j] ? dp[i + 1][j + 1] + 1 : max(dp[i + 1][j], dp[i][j + 1])
                }
            }
            XCTAssertEqual(matches, dp[0][0])
        }
    }

    func testTwoWayRowsAndChunks() {
        let left = ["a", "b", "c", "d", "e"]
        let right = ["a", "B", "c", "e", "f"]
        let r = DiffEngine.compare([left, right])
        XCTAssertEqual(r.chunks.map(\.kind), [.modified, .deleted, .inserted])
        XCTAssertEqual(r.rows.count, 6)
        XCTAssertEqual(r.rows[3].l0, 3)
        XCTAssertEqual(r.rows[3].l1, -1)
    }

    func testIgnoreWhitespaceAndCase() {
        let left = ["if (x)  {", "Return 1"]
        let right = ["if (x) {", "return 1"]
        XCTAssertFalse(DiffEngine.compare([left, right]).isIdentical)
        let opts = CompareOptions(whitespace: .ignoreChanges, ignoreCase: true)
        XCTAssertTrue(DiffEngine.compare([left, right], options: opts).isIdentical)
    }

    func testIgnoreBlankLines() {
        let left = ["a", "", "b"]
        let right = ["a", "b", ""]
        let opts = CompareOptions(ignoreBlankLines: true)
        XCTAssertTrue(DiffEngine.compare([left, right], options: opts).isIdentical)
    }

    func testThreeWayClassification() {
        let base  = ["1", "2", "3", "4", "5", "6", "7"]
        let left  = ["1", "2L", "3", "4", "5X", "6", "7"]
        let right = ["1", "2", "3", "4R", "5Y", "6", "7", "8"]
        let r = DiffEngine.compare([left, base, right])
        let kinds = r.chunks.map(\.kind)
        // Adjacent edits to base lines 4–5 (right) and 5 (left) overlap → one conflict, as in GNU diff3.
        XCTAssertEqual(kinds, [.leftChanged, .conflict, .rightChanged])
        let merged = DiffEngine.autoMerge(r, texts: [left, base, right])
        XCTAssertEqual(merged.applied, 2)
        XCTAssertEqual(merged.merged, ["1", "2L", "3", "4", "5", "6", "7", "8"])
    }

    func testThreeWaySameChange() {
        let base = ["a", "b", "c"]
        let left = ["a", "X", "c"]
        let right = ["a", "X", "c"]
        let r = DiffEngine.compare([left, base, right])
        XCTAssertEqual(r.chunks.map(\.kind), [.bothChanged])
    }

    func testInlineDiff() {
        let d = InlineDiff.compute("let value = foo(1, 2)", "let value = bar(1, 3)")
        XCTAssertEqual(d.left.count, 2)
        XCTAssertEqual(d.right.count, 2)
        XCTAssertGreaterThan(d.similarity, 0.5)
    }

    func testTextSplitAndSerialize() {
        let f = TextFile.split("a\r\nb\r\nc\r\n")
        XCTAssertEqual(f.lines, ["a", "b", "c"])
        XCTAssertEqual(f.lineEnding, .crlf)
        XCTAssertTrue(f.endsWithNewline)
        XCTAssertEqual(String(data: f.serialized(), encoding: .utf8), "a\r\nb\r\nc\r\n")
        let g = TextFile.split("x\ny")
        XCTAssertFalse(g.endsWithNewline)
        XCTAssertEqual(String(data: g.serialized(), encoding: .utf8), "x\ny")
    }

    func testLargeInputPerformance() {
        var a: [String] = []
        for i in 0..<60_000 { a.append("line \(i) some content here \(i % 97)") }
        var b = a
        for k in stride(from: 100, to: 60_000, by: 60) { b[k] = "changed \(k)" }
        for k in stride(from: 500, to: 50_000, by: 997) { b.insert("inserted \(k)", at: k) }
        let start = Date()
        let r = DiffEngine.compare([a, b])
        let elapsed = Date().timeIntervalSince(start)
        XCTAssertGreaterThan(r.chunks.count, 900)
        XCTAssertLessThan(elapsed, 2.0, "diff took \(elapsed)s")
    }

    func testFolderCompare() throws {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let l = tmp.appendingPathComponent("L"), r = tmp.appendingPathComponent("R")
        let fm = FileManager.default
        try fm.createDirectory(at: l.appendingPathComponent("sub"), withIntermediateDirectories: true)
        try fm.createDirectory(at: r.appendingPathComponent("sub"), withIntermediateDirectories: true)
        try "same".write(to: l.appendingPathComponent("same.txt"), atomically: true, encoding: .utf8)
        try "same".write(to: r.appendingPathComponent("same.txt"), atomically: true, encoding: .utf8)
        try "aaaa".write(to: l.appendingPathComponent("sub/diff.txt"), atomically: true, encoding: .utf8)
        try "aaab".write(to: r.appendingPathComponent("sub/diff.txt"), atomically: true, encoding: .utf8)
        try "only".write(to: l.appendingPathComponent("leftonly.txt"), atomically: true, encoding: .utf8)
        defer { try? fm.removeItem(at: tmp) }

        let root = FolderComparator.scan(roots: [l, r], options: .init())
        FolderComparator.compareAll(root: root, roots: [l, r], options: .init(), progress: { _, _ in }, isCancelled: { false })
        let files = FolderComparator.files(in: root)
        let byName = Dictionary(uniqueKeysWithValues: files.map { ($0.relativePath, $0.status) })
        XCTAssertEqual(byName["same.txt"], .identical)
        XCTAssertEqual(byName["sub/diff.txt"], .different)
        XCTAssertEqual(byName["leftonly.txt"], .missing)
        XCTAssertEqual(root.status, .different)
        XCTAssertEqual(root.differentCount, 1)
        XCTAssertEqual(root.missingCount, 1)
    }

    // MARK: View modes

    private func layoutFixture() -> DiffResult {
        var a = (0..<100).map { "line \($0)" }
        var b = a
        b[10] = "changed 10"
        b[11] = "changed 11"
        b[13] = "changed 13" // separated from the first chunk by one unchanged row
        b[60] = "changed 60"
        a.remove(at: 90)      // deletion near the end
        _ = a
        return DiffEngine.compare([a, b])
    }

    func testDisplayLayoutAllShowsEveryRow() {
        let r = layoutFixture()
        let l = DisplayLayout(result: r, mode: .all)
        XCTAssertEqual(l.count, r.rows.count)
        XCTAssertFalse(l.isFiltered)
        for c in r.chunks { XCTAssertEqual(l.displayRange(of: c), c.rows) }
    }

    func testDisplayLayoutContextKeepsChunksContiguous() {
        let r = layoutFixture()
        XCTAssertGreaterThanOrEqual(r.chunks.count, 3)
        for mode in [ViewMode.changesOnly, .context(1), .context(3), .context(10)] {
            let l = DisplayLayout(result: r, mode: mode)
            XCTAssertLessThan(l.count, r.rows.count, "\(mode)")
            // Every chunk row is visible exactly once and in order.
            var seen = Set<Int>()
            for item in l.items { if case .row(let x) = item { XCTAssertTrue(seen.insert(x).inserted) } }
            for c in r.chunks {
                let d = l.displayRange(of: c)
                XCTAssertEqual(d.count, c.rows.count)
                for (k, row) in c.rows.enumerated() {
                    XCTAssertEqual(l.resultRow(at: d.lowerBound + k), row)
                }
            }
            // Folds + rows cover all result rows.
            var covered = 0
            for item in l.items {
                switch item {
                case .row: covered += 1
                case .fold(let range): covered += range.count; XCTAssertGreaterThanOrEqual(range.count, 2)
                case .expanded: break
                }
            }
            XCTAssertEqual(covered, r.rows.count)
            // No two folds are adjacent.
            for k in 1..<l.items.count {
                if case .fold = l.items[k], case .fold = l.items[k - 1] { XCTFail("adjacent folds") }
            }
        }
    }

    func testDisplayLayoutChangesOnlySeparatesChunks() {
        let a = (0..<20).map { "x\($0)" }
        var b = a
        b[5] = "y"; b[9] = "z"
        let r = DiffEngine.compare([a, b])
        XCTAssertEqual(r.chunks.count, 2)
        let l = DisplayLayout(result: r, mode: .changesOnly)
        // fold(0..<5), row 5, fold(6..<9), row 9, fold(10..<20)
        XCTAssertEqual(l.items, [.fold(0..<5), .row(5), .fold(6..<9), .row(9), .fold(10..<20)])
        let revealed = DisplayLayout(result: r, mode: .changesOnly, revealed: IndexSet(integersIn: 6..<9))
        XCTAssertEqual(revealed.items, [.fold(0..<5), .row(5), .expanded(6..<9), .row(6), .row(7), .row(8), .row(9), .fold(10..<20)])
        XCTAssertEqual(revealed.resultRow(at: 3), 6)
        XCTAssertNil(revealed.resultRow(at: 2))
        XCTAssertEqual(l.nearestResultRow(at: 2), 6)
    }

    func testDisplayLayoutIdenticalFilesFoldEverything() {
        let a = (0..<50).map { "same \($0)" }
        let r = DiffEngine.compare([a, a])
        XCTAssertEqual(DisplayLayout(result: r, mode: .context(3)).items, [.fold(0..<50)])
        XCTAssertEqual(DisplayLayout(result: DiffEngine.compare([[], []]), mode: .changesOnly).count, 0)
    }

    func testIgnoreNumbersAndCharacterInline() {
        var o = CompareOptions()
        o.ignoreNumbers = true
        XCTAssertTrue(DiffEngine.compare([["port = 8080", "x"], ["port = 9090", "x"]], options: o).isIdentical)
        XCTAssertFalse(DiffEngine.compare([["port = 8080"], ["port = 9090"]]).isIdentical)
        let w = InlineDiff.compute("color = red", "colour = red", granularity: .word)
        XCTAssertEqual(w.left, [NSRange(location: 0, length: 5)])
        let c = InlineDiff.compute("color = red", "colour = red", granularity: .character)
        XCTAssertEqual(c.left, [])
        XCTAssertEqual(c.right, [NSRange(location: 4, length: 1)])
        // Old saved options (without ignoreNumbers) still decode.
        let old = #"{"whitespace":"compare","ignoreCase":true,"ignoreBlankLines":false,"algorithm":"patience"}"#
        let decoded = try? JSONDecoder().decode(CompareOptions.self, from: Data(old.utf8))
        XCTAssertEqual(decoded?.ignoreCase, true)
        XCTAssertEqual(decoded?.ignoreNumbers, false)
    }
}
