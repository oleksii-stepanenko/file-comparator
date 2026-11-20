import Foundation

public enum LineEnding: String, Sendable, Codable {
    case lf = "LF"
    case crlf = "CRLF"
    case cr = "CR"
    case mixed = "Mixed"

    public var sequence: String {
        switch self {
        case .lf, .mixed: return "\n"
        case .crlf: return "\r\n"
        case .cr: return "\r"
        }
    }
}

public struct TextEncodingInfo: Equatable, Sendable {
    public var encoding: String.Encoding
    public var hasBOM: Bool

    public init(encoding: String.Encoding, hasBOM: Bool) {
        self.encoding = encoding
        self.hasBOM = hasBOM
    }

    public var displayName: String {
        switch encoding {
        case .utf8: return hasBOM ? "UTF-8 BOM" : "UTF-8"
        case .utf16LittleEndian: return "UTF-16 LE"
        case .utf16BigEndian: return "UTF-16 BE"
        case .utf16: return "UTF-16"
        case .isoLatin1: return "ISO Latin 1"
        case .windowsCP1252: return "Windows 1252"
        case .macOSRoman: return "Mac Roman"
        case .ascii: return "ASCII"
        default: return String.localizedName(of: encoding)
        }
    }
}

/// A decoded text file split into lines.
public struct TextFile: Sendable {
    public var lines: [String]
    public var encoding: TextEncodingInfo
    public var lineEnding: LineEnding
    public var endsWithNewline: Bool

    public init(lines: [String], encoding: TextEncodingInfo = .init(encoding: .utf8, hasBOM: false),
                lineEnding: LineEnding = .lf, endsWithNewline: Bool = true) {
        self.lines = lines
        self.encoding = encoding
        self.lineEnding = lineEnding
        self.endsWithNewline = endsWithNewline
    }

    public enum LoadError: Error, LocalizedError {
        case binary
        case unreadable(String)

        public var errorDescription: String? {
            switch self {
            case .binary: return "The file appears to be binary."
            case .unreadable(let s): return s
            }
        }
    }

    /// Heuristic binary detection: NUL bytes in the first 8 KB (ignoring UTF-16 BOM files).
    public static func looksBinary(_ data: Data) -> Bool {
        if data.starts(with: [0xFF, 0xFE]) || data.starts(with: [0xFE, 0xFF]) { return false }
        let probe = data.prefix(8192)
        var controls = 0
        for byte in probe {
            if byte == 0 { return true }
            if byte < 0x09 || (byte > 0x0D && byte < 0x20 && byte != 0x1B) { controls += 1 }
        }
        return probe.count > 0 && controls * 10 > probe.count
    }

    public static func load(url: URL) throws -> TextFile {
        let data: Data
        do {
            data = try Data(contentsOf: url, options: .mappedIfSafe)
        } catch {
            throw LoadError.unreadable(error.localizedDescription)
        }
        if looksBinary(data) { throw LoadError.binary }
        return decode(data)
    }

    public static func decode(_ data: Data) -> TextFile {
        var info = TextEncodingInfo(encoding: .utf8, hasBOM: false)
        var text: String?
        if data.starts(with: [0xEF, 0xBB, 0xBF]) {
            info = .init(encoding: .utf8, hasBOM: true)
            text = String(data: data.dropFirst(3), encoding: .utf8)
        } else if data.starts(with: [0xFF, 0xFE]) {
            info = .init(encoding: .utf16LittleEndian, hasBOM: true)
            text = String(data: data.dropFirst(2), encoding: .utf16LittleEndian)
        } else if data.starts(with: [0xFE, 0xFF]) {
            info = .init(encoding: .utf16BigEndian, hasBOM: true)
            text = String(data: data.dropFirst(2), encoding: .utf16BigEndian)
        } else {
            text = String(data: data, encoding: .utf8)
            if text == nil {
                info = .init(encoding: .windowsCP1252, hasBOM: false)
                text = String(data: data, encoding: .windowsCP1252)
            }
            if text == nil {
                info = .init(encoding: .isoLatin1, hasBOM: false)
                text = String(data: data, encoding: .isoLatin1) ?? ""
            }
        }
        return split(text ?? "", encoding: info)
    }

    public static func split(_ text: String, encoding: TextEncodingInfo = .init(encoding: .utf8, hasBOM: false)) -> TextFile {
        var lines: [String] = []
        var lf = 0, crlf = 0, cr = 0
        let utf8 = Array(text.utf8)
        lines.reserveCapacity(utf8.count / 40 + 1)
        var start = 0
        var i = 0
        let n = utf8.count
        utf8.withUnsafeBufferPointer { p in
            while i < n {
                let c = p[i]
                if c == 0x0A || c == 0x0D {
                    lines.append(String(decoding: UnsafeBufferPointer(rebasing: p[start..<i]), as: UTF8.self))
                    if c == 0x0D && i + 1 < n && p[i + 1] == 0x0A {
                        crlf += 1
                        i += 2
                    } else {
                        if c == 0x0A { lf += 1 } else { cr += 1 }
                        i += 1
                    }
                    start = i
                } else {
                    i += 1
                }
            }
            if start < n {
                lines.append(String(decoding: UnsafeBufferPointer(rebasing: p[start..<n]), as: UTF8.self))
            }
        }
        let endsWithNewline = n > 0 && (utf8[n - 1] == 0x0A || utf8[n - 1] == 0x0D)
        let kinds = [lf, crlf, cr].filter { $0 > 0 }.count
        let ending: LineEnding
        if kinds > 1 { ending = .mixed }
        else if crlf > 0 { ending = .crlf }
        else if cr > 0 { ending = .cr }
        else { ending = .lf }
        return TextFile(lines: lines, encoding: encoding, lineEnding: ending, endsWithNewline: endsWithNewline || n == 0)
    }

    public func serialized() -> Data {
        var text = lines.joined(separator: lineEnding.sequence)
        if endsWithNewline && !lines.isEmpty { text += lineEnding.sequence }
        var data = Data()
        if encoding.hasBOM {
            switch encoding.encoding {
            case .utf8: data.append(contentsOf: [0xEF, 0xBB, 0xBF])
            case .utf16LittleEndian: data.append(contentsOf: [0xFF, 0xFE])
            case .utf16BigEndian: data.append(contentsOf: [0xFE, 0xFF])
            default: break
            }
        }
        data.append(text.data(using: encoding.encoding, allowLossyConversion: true) ?? Data(text.utf8))
        return data
    }

    public func write(to url: URL) throws {
        try serialized().write(to: url, options: .atomic)
    }
}
