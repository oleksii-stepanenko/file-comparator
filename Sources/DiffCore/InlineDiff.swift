import Foundation

/// Word/character level differences between two lines, expressed as UTF-16 ranges
/// (so they map directly onto NSString / CoreText offsets).
public enum InlineGranularity: String, Sendable, Codable, CaseIterable {
    case word, character, off

    public var title: String {
        switch self {
        case .word: return "Word Level"
        case .character: return "Character Level"
        case .off: return "Off"
        }
    }
}

public struct InlineDiff: Sendable, Equatable {
    public var left: [NSRange]
    public var right: [NSRange]
    /// 0...1 – how much of the two lines is shared.
    public var similarity: Double

    public static let none = InlineDiff(left: [], right: [], similarity: 1)

    private struct Token {
        var range: NSRange
        var hash: Int
    }

    private static func tokenize(_ s: String, ignoreCase: Bool, characters: Bool = false) -> [Token] {
        let u = Array(s.utf16)
        if characters {
            // One token per character (surrogate pairs stay together).
            var tokens: [Token] = []
            tokens.reserveCapacity(u.count)
            var i = 0
            while i < u.count {
                var len = 1
                if u[i] >= 0xD800 && u[i] < 0xDC00 && i + 1 < u.count { len = 2 }
                var ch = u[i]
                if ignoreCase && ch >= 65 && ch <= 90 { ch += 32 }
                tokens.append(Token(range: NSRange(location: i, length: len), hash: Int(ch) &* 31 &+ (len == 2 ? Int(u[i + 1]) : 0)))
                i += len
            }
            return tokens
        }
        var tokens: [Token] = []
        tokens.reserveCapacity(u.count / 3 + 1)
        var i = 0
        @inline(__always) func isWord(_ c: UInt16) -> Bool {
            (c >= 48 && c <= 57) || (c >= 65 && c <= 90) || (c >= 97 && c <= 122) || c == 95 || c >= 0x80
        }
        @inline(__always) func isSpace(_ c: UInt16) -> Bool { c == 32 || c == 9 }
        while i < u.count {
            let start = i
            let c = u[i]
            if isWord(c) {
                while i < u.count && isWord(u[i]) { i += 1 }
            } else if isSpace(c) {
                while i < u.count && isSpace(u[i]) { i += 1 }
            } else {
                i += 1
            }
            var h = Hasher()
            for k in start..<i {
                var ch = u[k]
                if ignoreCase && ch >= 65 && ch <= 90 { ch += 32 }
                h.combine(ch)
            }
            tokens.append(Token(range: NSRange(location: start, length: i - start), hash: h.finalize()))
        }
        return tokens
    }

    public static func compute(_ a: String, _ b: String, ignoreCase: Bool = false, ignoreWhitespace: Bool = false,
                               granularity: InlineGranularity = .word) -> InlineDiff {
        if a == b { return .none }
        let chars = granularity == .character
        let ta = tokenize(a, ignoreCase: ignoreCase, characters: chars)
        let tb = tokenize(b, ignoreCase: ignoreCase, characters: chars)
        // Intern token hashes to small ints for SequenceDiff.
        var table: [Int: Int] = [:]
        func ids(_ t: [Token]) -> [Int] { t.map { tok in
            if let v = table[tok.hash] { return v }
            let v = table.count; table[tok.hash] = v; return v
        } }
        let ia = ids(ta), ib = ids(tb)
        let hunks = SequenceDiff(ia, ib, algorithm: .myers, timeout: 0.05).hunks()
        var left: [NSRange] = [], right: [NSRange] = []
        var commonChars = 0
        let totalChars = max(1, a.utf16.count + b.utf16.count)
        func span(_ toks: [Token], _ r: Range<Int>) -> NSRange? {
            guard !r.isEmpty else { return nil }
            let s = toks[r.lowerBound].range.location
            let e = NSMaxRange(toks[r.upperBound - 1].range)
            return NSRange(location: s, length: e - s)
        }
        func isWhitespaceOnly(_ toks: [Token], _ r: Range<Int>, _ str: [UInt16]) -> Bool {
            for k in r {
                let rg = toks[k].range
                for p in rg.location..<NSMaxRange(rg) where str[p] != 32 && str[p] != 9 { return false }
            }
            return true
        }
        let ua = Array(a.utf16), ub = Array(b.utf16)
        for h in hunks {
            if h.isEqual {
                for k in h.a { commonChars += ta[k].range.length * 2 }
                continue
            }
            if ignoreWhitespace && isWhitespaceOnly(ta, h.a, ua) && isWhitespaceOnly(tb, h.b, ub) { continue }
            if let r = span(ta, h.a) { left.append(r) }
            if let r = span(tb, h.b) { right.append(r) }
        }
        return InlineDiff(left: merge(left), right: merge(right), similarity: Double(commonChars) / Double(totalChars))
    }

    /// Merges ranges separated by tiny gaps for calmer highlighting.
    private static func merge(_ ranges: [NSRange]) -> [NSRange] {
        var out: [NSRange] = []
        for r in ranges {
            if var last = out.last, r.location - NSMaxRange(last) <= 1 {
                last.length = NSMaxRange(r) - last.location
                out[out.count - 1] = last
            } else {
                out.append(r)
            }
        }
        return out
    }
}
