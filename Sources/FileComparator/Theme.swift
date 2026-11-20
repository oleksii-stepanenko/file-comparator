import AppKit
import SwiftUI
import DiffCore

extension NSColor {
    convenience init(hex: UInt32, alpha: CGFloat = 1) {
        self.init(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
                  green: CGFloat((hex >> 8) & 0xFF) / 255,
                  blue: CGFloat(hex & 0xFF) / 255,
                  alpha: alpha)
    }

    static func dynamic(_ light: NSColor, _ dark: NSColor) -> NSColor {
        NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light
        }
    }

    static func dynamic(_ light: UInt32, _ dark: UInt32, alpha: CGFloat = 1) -> NSColor {
        dynamic(NSColor(hex: light, alpha: alpha), NSColor(hex: dark, alpha: alpha))
    }
}

/// Visual identity of a change type: row background, inline (word) highlight and an accent
/// used for borders, the overview ruler and badges.
struct ChangeStyle {
    let background: NSColor
    let inline: NSColor
    let accent: NSColor
    let gutter: NSColor
}

enum Theme {
    // Editor chrome
    static let editorBackground = NSColor.dynamic(0xFFFFFF, 0x1C1D21)
    static let gutterBackground = NSColor.dynamic(0xF7F8FA, 0x202126)
    static let gutterText = NSColor.dynamic(0xA2A7B0, 0x5C616B)
    static let gutterDivider = NSColor.dynamic(0xE8EAEE, 0x2B2D33)
    static let mergeGutterBackground = NSColor.dynamic(0xF0F2F5, 0x18191D)
    static let text = NSColor.dynamic(0x1F2328, 0xD4D7DD)
    static let fillerStripe = NSColor.dynamic(NSColor(hex: 0x8A93A3, alpha: 0.13), NSColor(hex: 0x9AA3B5, alpha: 0.09))
    static let fillerBackground = NSColor.dynamic(NSColor(hex: 0xF4F5F7), NSColor(hex: 0x1F2024))
    static let selectionOutline = NSColor.controlAccentColor
    static let hoverRow = NSColor.dynamic(NSColor(hex: 0x000000, alpha: 0.025), NSColor(hex: 0xFFFFFF, alpha: 0.03))

    // Change palettes
    static let removed = ChangeStyle(
        background: .dynamic(0xFFEEF0, 0x3A2327),
        inline: .dynamic(0xFFC5CB, 0x7A2F38),
        accent: NSColor(hex: 0xF2555A),
        gutter: .dynamic(0xFFDCE0, 0x4A272D))
    static let added = ChangeStyle(
        background: .dynamic(0xE9FBEF, 0x1C3326),
        inline: .dynamic(0xADEFC0, 0x25603A),
        accent: NSColor(hex: 0x2EB860),
        gutter: .dynamic(0xD2F6DE, 0x1F3D2B))
    static let left3 = ChangeStyle(
        background: .dynamic(0xEAF2FF, 0x1C2A40),
        inline: .dynamic(0xBCD5FF, 0x2B4E86),
        accent: NSColor(hex: 0x3D82F6),
        gutter: .dynamic(0xD9E7FF, 0x203454))
    static let right3 = added
    static let both3 = ChangeStyle(
        background: .dynamic(0xF4EEFF, 0x2A2342),
        inline: .dynamic(0xDCCBFF, 0x4C3B80),
        accent: NSColor(hex: 0x9B6CF2),
        gutter: .dynamic(0xE8DDFF, 0x342A52))
    static let conflict = ChangeStyle(
        background: .dynamic(0xFFF2E6, 0x3A2817),
        inline: .dynamic(0xFFCF9E, 0x81501E),
        accent: NSColor(hex: 0xF08A24),
        gutter: .dynamic(0xFFE3C7, 0x4A321C))
    static let baseMuted = ChangeStyle(
        background: .dynamic(0xF5F6F8, 0x24252B),
        inline: .dynamic(0xE3E6EB, 0x353843),
        accent: NSColor(hex: 0x8C93A0),
        gutter: .dynamic(0xECEEF2, 0x2A2C33))

    // Syntax colors
    static let synKeyword = NSColor.dynamic(0x9B2393, 0xFF7AB2)
    static let synString = NSColor.dynamic(0xC41A16, 0xFF8170)
    static let synComment = NSColor.dynamic(0x6C7986, 0x7F8C98)
    static let synNumber = NSColor.dynamic(0x1C00CF, 0xD9C97C)
    static let synType = NSColor.dynamic(0x0B4F79, 0x5DD8FF)
    static let synAttribute = NSColor.dynamic(0x815F03, 0xFD8F3F)

    /// Style for a cell on `side` inside a chunk of `kind`; nil means "not highlighted".
    static func style(for kind: ChunkKind, side: Int, sideCount: Int) -> ChangeStyle? {
        if sideCount == 2 {
            switch kind {
            case .modified: return side == 0 ? removed : added
            case .deleted: return side == 0 ? removed : nil
            case .inserted: return side == 1 ? added : nil
            default: return nil
            }
        }
        switch kind {
        case .leftChanged: return side == 0 ? left3 : (side == 1 ? baseMuted : nil)
        case .rightChanged: return side == 2 ? right3 : (side == 1 ? baseMuted : nil)
        case .bothChanged: return side == 1 ? baseMuted : both3
        case .conflict: return side == 1 ? baseMuted : conflict
        default: return nil
        }
    }

    /// Accent for overview ruler / badges.
    static func accent(for kind: ChunkKind) -> NSColor {
        switch kind {
        case .modified: return NSColor(hex: 0xE2A400)
        case .deleted: return removed.accent
        case .inserted: return added.accent
        case .leftChanged: return left3.accent
        case .rightChanged: return right3.accent
        case .bothChanged: return both3.accent
        case .conflict: return conflict.accent
        }
    }

    static func label(for kind: ChunkKind) -> String {
        switch kind {
        case .modified: return "Changed"
        case .deleted: return "Only in left"
        case .inserted: return "Only in right"
        case .leftChanged: return "Left change"
        case .rightChanged: return "Right change"
        case .bothChanged: return "Same change"
        case .conflict: return "Conflict"
        }
    }
}

extension Color {
    init(_ ns: NSColor) { self.init(nsColor: ns) }
    static let sideLeft = Color(nsColor: Theme.removed.accent)
    static let sideRight = Color(nsColor: Theme.added.accent)
    static let sideBase = Color(nsColor: Theme.left3.accent)
}

/// Side naming & tint used by headers and badges.
enum SideInfo {
    static func name(_ side: Int, count: Int) -> String {
        if count == 3 { return ["Left", "Base", "Right"][side] }
        return ["Left", "Right"][side]
    }

    static func color(_ side: Int, count: Int) -> Color {
        if count == 3 { return [Color(Theme.left3.accent), Color(Theme.baseMuted.accent), Color(Theme.right3.accent)][side] }
        return [Color(Theme.removed.accent), Color(Theme.added.accent)][side]
    }
}

extension String {
    /// Path for display: home folder as "~". `FC_DEBUG_PATH_ALIAS="/real/prefix=~/Shown"` swaps a
    /// prefix (used only when taking documentation screenshots).
    var prettyPath: String {
        var s = self
        if let alias = ProcessInfo.processInfo.environment["FC_DEBUG_PATH_ALIAS"],
           let eq = alias.firstIndex(of: "=") {
            let from = String(alias[..<eq]), to = String(alias[alias.index(after: eq)...])
            if s.hasPrefix(from) { return to + s.dropFirst(from.count) }
        }
        let home = NSHomeDirectory()
        if s.hasPrefix(home) { s = "~" + s.dropFirst(home.count) }
        return s
    }
}
