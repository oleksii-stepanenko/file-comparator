import Foundation

/// A contiguous block in an edit script: either both ranges are equal, or they differ.
public struct DiffHunk: Equatable, Sendable {
    public var a: Range<Int>
    public var b: Range<Int>
    public var isEqual: Bool

    public init(a: Range<Int>, b: Range<Int>, isEqual: Bool) {
        self.a = a
        self.b = b
        self.isEqual = isEqual
    }
}

public enum DiffAlgorithm: String, CaseIterable, Sendable, Codable {
    /// Patience anchoring (unique lines) + Myers for the gaps. Produces human-friendly diffs for code.
    case patience
    /// Classic minimal Myers O(ND).
    case myers
}

/// Sequence diff over integer-interned tokens.
///
/// Uses the linear-space Myers bisection (as in diff-match-patch) with common prefix/suffix
/// trimming, optionally preceded by patience anchoring. A deadline keeps pathological inputs
/// bounded: segments that cannot be resolved in time are reported as a plain change.
public final class SequenceDiff {
    private let a: [Int]
    private let b: [Int]
    private var matchA: [Int] = []
    private var matchB: [Int] = []
    private let deadline: UInt64
    private let algorithm: DiffAlgorithm

    public init(_ a: [Int], _ b: [Int], algorithm: DiffAlgorithm = .patience, timeout: TimeInterval = 3.0) {
        self.a = a
        self.b = b
        self.algorithm = algorithm
        self.deadline = DispatchTime.now().uptimeNanoseconds + UInt64(timeout * 1_000_000_000)
        matchA.reserveCapacity(min(a.count, b.count))
        matchB.reserveCapacity(min(a.count, b.count))
    }

    /// Returns matched index pairs (strictly increasing in both coordinates).
    public func matches() -> (a: [Int], b: [Int]) {
        if matchA.isEmpty && !(a.isEmpty || b.isEmpty) {
            run(0, a.count, 0, b.count)
        }
        return (matchA, matchB)
    }

    public func hunks() -> [DiffHunk] {
        let (ma, mb) = matches()
        return SequenceDiff.hunks(matchA: ma, matchB: mb, countA: a.count, countB: b.count)
    }

    public static func hunks(matchA: [Int], matchB: [Int], countA: Int, countB: Int) -> [DiffHunk] {
        var result: [DiffHunk] = []
        var i = 0, j = 0, k = 0
        while k < matchA.count {
            let mi = matchA[k], mj = matchB[k]
            if mi > i || mj > j {
                result.append(DiffHunk(a: i..<mi, b: j..<mj, isEqual: false))
            }
            // Extend equal run.
            var len = 0
            while k + len < matchA.count && matchA[k + len] == mi + len && matchB[k + len] == mj + len {
                len += 1
            }
            result.append(DiffHunk(a: mi..<(mi + len), b: mj..<(mj + len), isEqual: true))
            i = mi + len
            j = mj + len
            k += len
        }
        if i < countA || j < countB {
            result.append(DiffHunk(a: i..<countA, b: j..<countB, isEqual: false))
        }
        return result
    }

    @inline(__always) private func add(_ i: Int, _ j: Int) {
        matchA.append(i)
        matchB.append(j)
    }

    private func run(_ aLo0: Int, _ aHi0: Int, _ bLo0: Int, _ bHi0: Int) {
        var aLo = aLo0, aHi = aHi0, bLo = bLo0, bHi = bHi0
        while aLo < aHi && bLo < bHi && a[aLo] == b[bLo] {
            add(aLo, bLo); aLo += 1; bLo += 1
        }
        var suffix = 0
        while aLo < aHi && bLo < bHi && a[aHi - 1] == b[bHi - 1] {
            aHi -= 1; bHi -= 1; suffix += 1
        }
        if aLo < aHi && bLo < bHi {
            if !(algorithm == .patience && patience(aLo, aHi, bLo, bHi)) {
                if let (x, y) = bisect(aLo, aHi, bLo, bHi),
                   !(x == aLo && y == bLo), !(x == aHi && y == bHi) {
                    run(aLo, x, bLo, y)
                    run(x, aHi, y, bHi)
                }
            }
        }
        for s in 0..<suffix { add(aHi + s, bHi + s) }
    }

    private struct Occurrence {
        var countA = 0
        var posA = 0
        var countB = 0
        var posB = 0
    }

    /// Anchors the diff on lines that are unique in both ranges (longest increasing subsequence).
    /// Returns false when no anchors exist, leaving the range to Myers.
    private func patience(_ aLo: Int, _ aHi: Int, _ bLo: Int, _ bHi: Int) -> Bool {
        // Small ranges: Myers is fine and minimal.
        if (aHi - aLo) < 3 || (bHi - bLo) < 3 { return false }
        var occ: [Int: Occurrence] = [:]
        occ.reserveCapacity(aHi - aLo)
        for i in aLo..<aHi {
            occ[a[i], default: Occurrence()].countA += 1
            occ[a[i]]!.posA = i
        }
        for j in bLo..<bHi {
            if var o = occ[b[j]], o.countA == 1 {
                o.countB += 1
                o.posB = j
                occ[b[j]] = o
            }
        }
        var pairs: [(Int, Int)] = []
        for i in aLo..<aHi {
            if let o = occ[a[i]], o.countA == 1, o.countB == 1 {
                pairs.append((i, o.posB))
            }
        }
        if pairs.isEmpty { return false }

        // LIS on b positions (pairs are already sorted by a position).
        var tails: [Int] = []          // index into pairs
        var prev = [Int](repeating: -1, count: pairs.count)
        for (idx, p) in pairs.enumerated() {
            var lo = 0, hi = tails.count
            while lo < hi {
                let mid = (lo + hi) / 2
                if pairs[tails[mid]].1 < p.1 { lo = mid + 1 } else { hi = mid }
            }
            if lo > 0 { prev[idx] = tails[lo - 1] }
            if lo == tails.count { tails.append(idx) } else { tails[lo] = idx }
        }
        var anchors: [(Int, Int)] = []
        var cur = tails.last ?? -1
        while cur >= 0 {
            anchors.append(pairs[cur])
            cur = prev[cur]
        }
        anchors.reverse()

        var pa = aLo, pb = bLo
        for (i, j) in anchors {
            run(pa, i, pb, j)
            add(i, j)
            pa = i + 1
            pb = j + 1
        }
        run(pa, aHi, pb, bHi)
        return true
    }

    /// Finds the middle snake split point. Returns nil if the deadline expires.
    private func bisect(_ aLo: Int, _ aHi: Int, _ bLo: Int, _ bHi: Int) -> (Int, Int)? {
        let n = aHi - aLo, m = bHi - bLo
        let maxD = (n + m + 1) / 2
        let vOffset = maxD
        let vLength = 2 * maxD + 2
        var v1 = [Int](repeating: -1, count: vLength)
        var v2 = [Int](repeating: -1, count: vLength)
        v1[vOffset + 1] = 0
        v2[vOffset + 1] = 0
        let delta = n - m
        let front = (delta & 1) != 0
        var k1start = 0, k1end = 0, k2start = 0, k2end = 0

        return a.withUnsafeBufferPointer { ap -> (Int, Int)? in
            b.withUnsafeBufferPointer { bp -> (Int, Int)? in
                for d in 0..<maxD {
                    if d & 63 == 0 && DispatchTime.now().uptimeNanoseconds > deadline { return nil }
                    var k1 = -d + k1start
                    while k1 <= d - k1end {
                        let k1Off = vOffset + k1
                        var x1: Int
                        if k1 == -d || (k1 != d && v1[k1Off - 1] < v1[k1Off + 1]) {
                            x1 = v1[k1Off + 1]
                        } else {
                            x1 = v1[k1Off - 1] + 1
                        }
                        var y1 = x1 - k1
                        while x1 < n && y1 < m && ap[aLo + x1] == bp[bLo + y1] {
                            x1 += 1; y1 += 1
                        }
                        v1[k1Off] = x1
                        if x1 > n {
                            k1end += 2
                        } else if y1 > m {
                            k1start += 2
                        } else if front {
                            let k2Off = vOffset + delta - k1
                            if k2Off >= 0 && k2Off < vLength && v2[k2Off] != -1 {
                                let x2 = n - v2[k2Off]
                                if x1 >= x2 { return (aLo + x1, bLo + y1) }
                            }
                        }
                        k1 += 2
                    }
                    var k2 = -d + k2start
                    while k2 <= d - k2end {
                        let k2Off = vOffset + k2
                        var x2: Int
                        if k2 == -d || (k2 != d && v2[k2Off - 1] < v2[k2Off + 1]) {
                            x2 = v2[k2Off + 1]
                        } else {
                            x2 = v2[k2Off - 1] + 1
                        }
                        var y2 = x2 - k2
                        while x2 < n && y2 < m && ap[aHi - 1 - x2] == bp[bHi - 1 - y2] {
                            x2 += 1; y2 += 1
                        }
                        v2[k2Off] = x2
                        if x2 > n {
                            k2end += 2
                        } else if y2 > m {
                            k2start += 2
                        } else if !front {
                            let k1Off = vOffset + delta - k2
                            if k1Off >= 0 && k1Off < vLength && v1[k1Off] != -1 {
                                let x1 = v1[k1Off]
                                let y1 = vOffset + x1 - k1Off
                                if x1 >= n - x2 { return (aLo + x1, bLo + y1) }
                            }
                        }
                        k2 += 2
                    }
                }
                return nil
            }
        }
    }
}
