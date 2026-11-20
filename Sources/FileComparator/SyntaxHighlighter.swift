import AppKit

/// A deliberately small, per-line tokenizer. It gives code a familiar, readable texture without
/// the cost of a full parser — every visible line is highlighted independently and cached.
struct SyntaxLanguage {
    var name: String
    var lineComments: [String]
    var blockComment: (String, String)?
    var stringDelimiters: [Character]
    var keywords: Set<String>
    var highlightTypes: Bool
    var attributePrefix: Character?

    static let plain = SyntaxLanguage(name: "Plain Text", lineComments: [], blockComment: nil, stringDelimiters: [],
                                      keywords: [], highlightTypes: false, attributePrefix: nil)

    private static let cFamily: Set<String> = [
        "if", "else", "for", "while", "do", "switch", "case", "default", "break", "continue", "return", "goto",
        "struct", "union", "enum", "typedef", "const", "static", "extern", "volatile", "inline", "sizeof",
        "void", "int", "char", "short", "long", "float", "double", "signed", "unsigned", "bool", "true", "false",
        "class", "public", "private", "protected", "virtual", "override", "template", "typename", "namespace",
        "using", "new", "delete", "this", "nullptr", "NULL", "try", "catch", "throw", "auto", "constexpr",
        "include", "define", "ifdef", "ifndef", "endif", "pragma",
    ]
    private static let swiftKeywords: Set<String> = [
        "import", "func", "var", "let", "if", "else", "guard", "for", "in", "while", "repeat", "switch", "case",
        "default", "break", "continue", "return", "throw", "throws", "rethrows", "try", "catch", "do", "struct",
        "class", "enum", "protocol", "extension", "init", "deinit", "self", "Self", "super", "nil", "true", "false",
        "static", "private", "fileprivate", "internal", "public", "open", "final", "override", "mutating",
        "inout", "some", "any", "async", "await", "actor", "where", "as", "is", "typealias", "associatedtype",
        "defer", "lazy", "weak", "unowned", "subscript", "operator", "convenience", "required", "nonisolated",
        "fallthrough", "get", "set", "willSet", "didSet",
    ]
    private static let jsKeywords: Set<String> = [
        "function", "var", "let", "const", "if", "else", "for", "while", "do", "switch", "case", "default", "break",
        "continue", "return", "throw", "try", "catch", "finally", "new", "delete", "typeof", "instanceof", "in",
        "of", "class", "extends", "super", "this", "null", "undefined", "true", "false", "import", "export", "from",
        "as", "async", "await", "yield", "static", "get", "set", "interface", "type", "enum", "implements",
        "private", "public", "protected", "readonly", "declare", "namespace", "abstract", "void", "never",
        "unknown", "any", "string", "number", "boolean", "keyof", "satisfies",
    ]
    private static let pythonKeywords: Set<String> = [
        "def", "class", "if", "elif", "else", "for", "while", "in", "not", "and", "or", "is", "return", "yield",
        "import", "from", "as", "with", "try", "except", "finally", "raise", "pass", "break", "continue", "lambda",
        "global", "nonlocal", "True", "False", "None", "async", "await", "assert", "del", "self", "match", "case",
    ]
    private static let goKeywords: Set<String> = [
        "package", "import", "func", "var", "const", "type", "struct", "interface", "map", "chan", "if", "else",
        "for", "range", "switch", "case", "default", "break", "continue", "return", "go", "defer", "select",
        "fallthrough", "goto", "nil", "true", "false", "string", "int", "int64", "int32", "uint", "byte", "rune",
        "bool", "error", "float64", "float32", "any",
    ]
    private static let rustKeywords: Set<String> = [
        "fn", "let", "mut", "const", "static", "if", "else", "match", "for", "while", "loop", "in", "break",
        "continue", "return", "struct", "enum", "impl", "trait", "type", "pub", "crate", "mod", "use", "super",
        "self", "Self", "as", "where", "move", "ref", "async", "await", "dyn", "unsafe", "true", "false", "Some",
        "None", "Ok", "Err",
    ]
    private static let javaKeywords: Set<String> = cFamily.union([
        "package", "import", "extends", "implements", "interface", "final", "abstract", "synchronized", "finally",
        "instanceof", "boolean", "byte", "null", "super", "throws", "var", "val", "fun", "object", "when", "is",
        "internal", "data", "sealed", "companion", "lateinit", "suspend", "record", "yield", "string", "foreach",
        "readonly", "async", "await", "get", "set", "out", "ref", "base", "lock", "event", "delegate", "in",
    ])
    private static let shellKeywords: Set<String> = [
        "if", "then", "else", "elif", "fi", "for", "while", "until", "do", "done", "case", "esac", "in", "function",
        "return", "local", "export", "readonly", "echo", "exit", "set", "unset", "source", "alias", "shift",
    ]
    private static let sqlKeywords: Set<String> = [
        "select", "from", "where", "insert", "into", "values", "update", "set", "delete", "create", "table",
        "drop", "alter", "add", "join", "left", "right", "inner", "outer", "on", "group", "by", "order", "having",
        "limit", "offset", "and", "or", "not", "null", "is", "as", "distinct", "union", "all", "primary", "key",
        "foreign", "references", "index", "view", "case", "when", "then", "else", "end", "in", "exists", "like",
        "SELECT", "FROM", "WHERE", "INSERT", "INTO", "VALUES", "UPDATE", "SET", "DELETE", "CREATE", "TABLE",
        "DROP", "ALTER", "JOIN", "LEFT", "RIGHT", "INNER", "ON", "GROUP", "BY", "ORDER", "AND", "OR", "NOT",
        "NULL", "AS", "DISTINCT", "UNION", "PRIMARY", "KEY", "CASE", "WHEN", "THEN", "ELSE", "END", "IN", "LIMIT",
    ]
    private static let rubyKeywords: Set<String> = [
        "def", "end", "class", "module", "if", "elsif", "else", "unless", "while", "until", "for", "in", "do",
        "return", "yield", "begin", "rescue", "ensure", "raise", "self", "nil", "true", "false", "require",
        "attr_accessor", "attr_reader", "private", "public", "protected", "then", "case", "when", "and", "or",
        "not", "lambda", "proc", "super",
    ]
    private static let phpKeywords: Set<String> = jsKeywords.union(["echo", "foreach", "endif", "endforeach", "namespace", "use", "fn", "array", "elseif", "require_once", "include_once"])

    static func forExtension(_ ext: String) -> SyntaxLanguage {
        let e = ext.lowercased()
        let cStyle = SyntaxLanguage(name: "C", lineComments: ["//"], blockComment: ("/*", "*/"),
                                    stringDelimiters: ["\"", "'"], keywords: cFamily, highlightTypes: true, attributePrefix: "#")
        switch e {
        case "swift":
            return SyntaxLanguage(name: "Swift", lineComments: ["//"], blockComment: ("/*", "*/"), stringDelimiters: ["\""],
                                  keywords: swiftKeywords, highlightTypes: true, attributePrefix: "@")
        case "c", "h", "cc", "cpp", "cxx", "hpp", "hh", "m", "mm":
            var l = cStyle; l.name = e == "m" || e == "mm" ? "Objective-C" : "C/C++"; return l
        case "js", "jsx", "mjs", "cjs", "ts", "tsx", "vue", "svelte":
            return SyntaxLanguage(name: e.hasPrefix("t") ? "TypeScript" : "JavaScript", lineComments: ["//"], blockComment: ("/*", "*/"),
                                  stringDelimiters: ["\"", "'", "`"], keywords: jsKeywords, highlightTypes: true, attributePrefix: "@")
        case "java", "kt", "kts", "scala", "groovy", "cs", "dart":
            return SyntaxLanguage(name: ["java": "Java", "kt": "Kotlin", "kts": "Kotlin", "cs": "C#", "dart": "Dart"][e] ?? "JVM",
                                  lineComments: ["//"], blockComment: ("/*", "*/"),
                                  stringDelimiters: ["\"", "'"], keywords: javaKeywords, highlightTypes: true, attributePrefix: "@")
        case "go":
            return SyntaxLanguage(name: "Go", lineComments: ["//"], blockComment: ("/*", "*/"), stringDelimiters: ["\"", "'", "`"],
                                  keywords: goKeywords, highlightTypes: true, attributePrefix: nil)
        case "rs":
            return SyntaxLanguage(name: "Rust", lineComments: ["//"], blockComment: ("/*", "*/"), stringDelimiters: ["\""],
                                  keywords: rustKeywords, highlightTypes: true, attributePrefix: "#")
        case "py", "pyw", "pyi":
            return SyntaxLanguage(name: "Python", lineComments: ["#"], blockComment: nil, stringDelimiters: ["\"", "'"],
                                  keywords: pythonKeywords, highlightTypes: true, attributePrefix: "@")
        case "rb", "rake", "gemspec":
            return SyntaxLanguage(name: "Ruby", lineComments: ["#"], blockComment: nil, stringDelimiters: ["\"", "'"],
                                  keywords: rubyKeywords, highlightTypes: true, attributePrefix: nil)
        case "php":
            return SyntaxLanguage(name: "PHP", lineComments: ["//", "#"], blockComment: ("/*", "*/"), stringDelimiters: ["\"", "'"],
                                  keywords: phpKeywords, highlightTypes: true, attributePrefix: "$")
        case "sh", "bash", "zsh", "fish", "command", "env":
            return SyntaxLanguage(name: "Shell", lineComments: ["#"], blockComment: nil, stringDelimiters: ["\"", "'"],
                                  keywords: shellKeywords, highlightTypes: false, attributePrefix: "$")
        case "sql":
            return SyntaxLanguage(name: "SQL", lineComments: ["--"], blockComment: ("/*", "*/"), stringDelimiters: ["'", "\""],
                                  keywords: sqlKeywords, highlightTypes: false, attributePrefix: nil)
        case "json", "jsonc", "json5":
            return SyntaxLanguage(name: "JSON", lineComments: ["//"], blockComment: ("/*", "*/"), stringDelimiters: ["\""],
                                  keywords: ["true", "false", "null"], highlightTypes: false, attributePrefix: nil)
        case "yaml", "yml", "toml", "ini", "cfg", "conf", "properties":
            return SyntaxLanguage(name: e == "toml" ? "TOML" : (e.hasPrefix("y") ? "YAML" : "Config"), lineComments: ["#", ";"], blockComment: nil,
                                  stringDelimiters: ["\"", "'"], keywords: ["true", "false", "null", "yes", "no", "on", "off"],
                                  highlightTypes: false, attributePrefix: nil)
        case "css", "scss", "less", "sass":
            return SyntaxLanguage(name: "CSS", lineComments: e == "css" ? [] : ["//"], blockComment: ("/*", "*/"),
                                  stringDelimiters: ["\"", "'"], keywords: ["important", "inherit", "initial", "none", "auto"],
                                  highlightTypes: false, attributePrefix: "@")
        case "html", "htm", "xml", "plist", "svg", "xaml", "csproj", "storyboard", "xib":
            return SyntaxLanguage(name: e.hasPrefix("htm") ? "HTML" : "XML", lineComments: [], blockComment: ("<!--", "-->"),
                                  stringDelimiters: ["\"", "'"], keywords: [], highlightTypes: false, attributePrefix: nil)
        case "lua":
            return SyntaxLanguage(name: "Lua", lineComments: ["--"], blockComment: nil, stringDelimiters: ["\"", "'"],
                                  keywords: ["local", "function", "end", "if", "then", "else", "elseif", "for", "in", "do", "while",
                                             "repeat", "until", "return", "nil", "true", "false", "and", "or", "not", "break"],
                                  highlightTypes: false, attributePrefix: nil)
        default:
            return .plain
        }
    }

    func highlight(_ s: NSMutableAttributedString, colors: SyntaxColors) {
        if keywords.isEmpty && lineComments.isEmpty && blockComment == nil && stringDelimiters.isEmpty { return }
        let str = s.string as NSString
        let u = Array(s.string.utf16)
        let n = u.count
        var i = 0
        func starts(_ token: String, at p: Int) -> Bool {
            let t = Array(token.utf16)
            if p + t.count > n { return false }
            for k in 0..<t.count where u[p + k] != t[k] { return false }
            return true
        }
        func color(_ r: NSRange, _ c: CGColor) {
            s.addAttribute(NSAttributedString.Key(kCTForegroundColorAttributeName as String), value: c, range: r)
        }
        @inline(__always) func isIdentStart(_ c: UInt16) -> Bool {
            (c >= 65 && c <= 90) || (c >= 97 && c <= 122) || c == 95
        }
        @inline(__always) func isIdent(_ c: UInt16) -> Bool { isIdentStart(c) || (c >= 48 && c <= 57) || c == 36 }
        let delims = Set(stringDelimiters.compactMap { $0.utf16.first })
        let attr = attributePrefix?.utf16.first
        let isMarkup = name == "HTML" || name == "XML"
        while i < n {
            let c = u[i]
            if let lc = lineComments.first(where: { starts($0, at: i) }) {
                _ = lc
                color(NSRange(location: i, length: n - i), colors.comment)
                return
            }
            if let (open, close) = blockComment, starts(open, at: i) {
                var j = i + open.utf16.count
                while j < n && !starts(close, at: j) { j += 1 }
                j = min(n, j + close.utf16.count)
                color(NSRange(location: i, length: j - i), colors.comment)
                i = j
                continue
            }
            if delims.contains(c) {
                var j = i + 1
                while j < n && u[j] != c {
                    if u[j] == 92 { j += 1 } // backslash escape
                    j += 1
                }
                j = min(n, j + 1)
                color(NSRange(location: i, length: j - i), colors.string)
                i = j
                continue
            }
            if isMarkup && c == 60 { // '<' tag name
                var j = i + 1
                if j < n && (u[j] == 47 || u[j] == 63 || u[j] == 33) { j += 1 }
                let s0 = j
                while j < n && (isIdent(u[j]) || u[j] == 45 || u[j] == 58) { j += 1 }
                if j > s0 { color(NSRange(location: s0, length: j - s0), colors.keyword) }
                i = j
                continue
            }
            if let attr, c == attr, i + 1 < n, isIdentStart(u[i + 1]) {
                var j = i + 1
                while j < n && isIdent(u[j]) { j += 1 }
                color(NSRange(location: i, length: j - i), colors.attribute)
                i = j
                continue
            }
            if c >= 48 && c <= 57 {
                var j = i + 1
                while j < n && (isIdent(u[j]) || u[j] == 46) { j += 1 }
                color(NSRange(location: i, length: j - i), colors.number)
                i = j
                continue
            }
            if isIdentStart(c) {
                var j = i + 1
                while j < n && isIdent(u[j]) { j += 1 }
                let r = NSRange(location: i, length: j - i)
                let word = str.substring(with: r)
                if keywords.contains(word) {
                    color(r, colors.keyword)
                } else if highlightTypes && c >= 65 && c <= 90 && j - i > 1 {
                    color(r, colors.type)
                } else if isMarkup || name == "CSS" {
                    // attribute names / properties
                    if j < n && (u[j] == 61 || u[j] == 58) { color(r, colors.attribute) }
                }
                i = j
                continue
            }
            i += 1
        }
    }
}

struct SyntaxColors {
    var keyword: CGColor
    var string: CGColor
    var comment: CGColor
    var number: CGColor
    var type: CGColor
    var attribute: CGColor

    /// Resolves the dynamic theme colors for the current drawing appearance.
    static func current() -> SyntaxColors {
        SyntaxColors(keyword: Theme.synKeyword.cgColor, string: Theme.synString.cgColor,
                     comment: Theme.synComment.cgColor, number: Theme.synNumber.cgColor,
                     type: Theme.synType.cgColor, attribute: Theme.synAttribute.cgColor)
    }
}
