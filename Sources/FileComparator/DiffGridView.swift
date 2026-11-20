import AppKit
import CoreText
import DiffCore

/// Hosts the aligned diff grid in a scroll view together with the overview ruler.
final class DiffGridContainer: NSView {
    let scrollView = NSScrollView()
    let grid = DiffGridView()
    let ruler = OverviewRuler()
    weak var model: TextCompareModel? {
        didSet {
            grid.model = model
            ruler.model = model
            model?.grid = self
            reloadData()
        }
    }

    override init(frame: NSRect) {
        super.init(frame: frame)
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.scrollerStyle = .overlay
        scrollView.drawsBackground = true
        scrollView.backgroundColor = Theme.editorBackground
        scrollView.documentView = grid
        scrollView.contentView.postsBoundsChangedNotifications = true
        scrollView.verticalScrollElasticity = .allowed
        scrollView.automaticallyAdjustsContentInsets = false
        scrollView.contentInsets = NSEdgeInsetsZero
        ruler.scrollView = scrollView
        ruler.grid = grid
        addSubview(scrollView)
        addSubview(ruler)
        NotificationCenter.default.addObserver(self, selector: #selector(boundsChanged),
                                               name: NSView.boundsDidChangeNotification, object: scrollView.contentView)
    }

    required init?(coder: NSCoder) { fatalError() }

    override func layout() {
        super.layout()
        let rulerWidth: CGFloat = 16
        scrollView.frame = NSRect(x: 0, y: 0, width: bounds.width - rulerWidth, height: bounds.height)
        ruler.frame = NSRect(x: bounds.width - rulerWidth, y: 0, width: rulerWidth, height: bounds.height)
        grid.updateFrameSize()
    }

    @objc private func boundsChanged() {
        ruler.needsDisplay = true
    }

    func reloadData() {
        grid.reloadData()
        ruler.needsDisplay = true
    }

    func invalidateAll() {
        grid.invalidateCaches()
        ruler.needsDisplay = true
    }

    func setNeedsDisplayAll() {
        grid.needsDisplay = true
        ruler.needsDisplay = true
    }

    /// Result row at the top of the viewport.
    func topVisibleRow() -> Int {
        let display = Int(scrollView.contentView.bounds.minY / grid.rowHeight)
        return model?.layout.nearestResultRow(at: display) ?? display
    }

    func scrollTo(chunk index: Int, animated: Bool = true) {
        guard let model, index < model.result.chunks.count else { return }
        let rows = model.layout.displayRange(of: model.result.chunks[index])
        let top = CGFloat(rows.lowerBound) * grid.rowHeight
        let height = CGFloat(max(1, rows.count)) * grid.rowHeight
        grid.revealChunkHorizontally(index)
        scrollTo(y: top + height / 2, center: true, animated: animated)
    }

    func scrollTo(y: CGFloat, center: Bool, animated: Bool) {
        let clip = scrollView.contentView
        let visible = clip.bounds.height
        var target = center ? y - visible * 0.4 : y
        target = max(0, min(target, grid.frame.height - visible))
        let origin = NSPoint(x: 0, y: target)
        if animated && abs(clip.bounds.minY - target) < visible * 6 {
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.22
                ctx.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                clip.animator().setBoundsOrigin(origin)
            } completionHandler: { [weak self] in
                self?.scrollView.reflectScrolledClipView(clip)
            }
        } else {
            clip.setBoundsOrigin(origin)
            scrollView.reflectScrolledClipView(clip)
        }
    }

    func updateFont() {
        grid.updateFont()
        ruler.needsDisplay = true
    }
}

/// Custom-drawn, virtualized grid: only visible rows are rendered, so files with hundreds of
/// thousands of lines scroll as smoothly as small ones. All panes share one scroll position,
/// which keeps them perfectly aligned.
final class DiffGridView: NSView, NSTextFieldDelegate, NSUserInterfaceValidations {
    weak var model: TextCompareModel?

    private(set) var font = NSFont.monospacedSystemFont(ofSize: 12.5, weight: .regular)
    private var numberFont = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .regular)
    private(set) var rowHeight: CGFloat = 19
    private var charWidth: CGFloat = 7.5
    private var baseline: CGFloat = 14
    private var hOffset: CGFloat = 0
    private var axisLock = 0

    private var lineCache: [[CTLine?]] = []
    private var inlineCache: [Int: [[NSRange]]] = [:]
    private var copyableCache: [Int: [Bool]] = [:]
    private var maxContentWidth: CGFloat = 0
    private var cachedAppearanceName: NSAppearance.Name?
    private var cacheRevision = -1

    private struct ArrowHit: Equatable {
        var chunk: Int
        var from: Int
        var to: Int
    }
    private var hoverArrow: ArrowHit?
    private var hoverRow: Int?

    private var activeLine: Int?
    /// "More changes this way" markers at pane edges for differences scrolled out of view,
    /// keyed by display row (rebuilt for every row drawn).
    private struct EdgeMarker {
        var rect: NSRect
        var side: Int
        var pointsRight: Bool
        /// x offset of the hidden change within the line.
        var offset: CGFloat
        var color: NSColor
        var count: Int
    }
    private var edgeMarkers: [Int: [EdgeMarker]] = [:]
    private var hoverMarker: (row: Int, index: Int)?
    private var editor: NSTextField?
    private var editing: (side: Int, line: Int)?
    private var editCancelled = false

    static let mergeGutterWidth: CGFloat = 38
    private let textPadding: CGFloat = 8

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    override var isOpaque: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override init(frame: NSRect) {
        super.init(frame: frame)
        updateFont()
    }

    required init?(coder: NSCoder) { fatalError() }

    // MARK: Metrics & layout

    func updateFont() {
        let size = Preferences.shared.fontSize
        font = NSFont(name: Preferences.shared.fontName, size: size) ?? NSFont.monospacedSystemFont(ofSize: size, weight: .regular)
        numberFont = NSFont.monospacedDigitSystemFont(ofSize: max(9, size - 1.5), weight: .regular)
        let ascent = CTFontGetAscent(font), descent = CTFontGetDescent(font), leading = CTFontGetLeading(font)
        let natural = ceil(ascent + descent + leading)
        rowHeight = ceil(natural * Preferences.shared.lineSpacing)
        baseline = floor((rowHeight - (ascent + descent)) / 2 + ascent)
        charWidth = ("M" as NSString).size(withAttributes: [.font: font]).width
        invalidateCaches()
        updateFrameSize()
    }

    struct Pane {
        var x: CGFloat
        var width: CGFloat
        var numbersWidth: CGFloat
        var textX: CGFloat { x + numbersWidth + 6 }
        var textArea: NSRect { NSRect(x: x + numbersWidth, y: 0, width: width - numbersWidth, height: 0) }
        var textWidth: CGFloat { width - numbersWidth - 6 }
    }

    func panes() -> [Pane] {
        guard let model else { return [] }
        let n = model.sideCount
        let gutters = CGFloat(n - 1) * Self.mergeGutterWidth
        let paneWidth = floor((bounds.width - gutters) / CGFloat(n))
        let digits = max(3, String(model.result.lineCounts.max() ?? 0).count)
        let digitWidth = ("0" as NSString).size(withAttributes: [.font: numberFont]).width
        let numW = model.showLineNumbers ? ceil(CGFloat(digits) * digitWidth + 22) : 10
        return (0..<n).map { s in
            Pane(x: CGFloat(s) * (paneWidth + Self.mergeGutterWidth), width: paneWidth, numbersWidth: numW)
        }
    }

    func updateFrameSize() {
        guard let scroll = enclosingScrollView else { return }
        let rows = model?.layout.count ?? 0
        let clipHeight = scroll.contentView.bounds.height
        let height = max(clipHeight, CGFloat(rows) * rowHeight + rowHeight * 2)
        let width = scroll.contentView.bounds.width
        if frame.size != NSSize(width: width, height: height) {
            setFrameSize(NSSize(width: width, height: height))
        }
        clampHOffset()
    }

    func reloadData() {
        inlineCache.removeAll()
        copyableCache.removeAll()
        if let model, model.textRevision != cacheRevision {
            invalidateCaches()
        }
        updateFrameSize()
        endEditing(commit: false)
        needsDisplay = true
    }

    func invalidateCaches() {
        guard let model else { return }
        lineCache = model.sides.map { [CTLine?](repeating: nil, count: $0.lines.count) }
        inlineCache.removeAll()
        copyableCache.removeAll()
        cacheRevision = model.textRevision
        maxContentWidth = CGFloat(model.maxLineLength()) * charWidth + 40
        clampHOffset()
        needsDisplay = true
    }

    private func clampHOffset() {
        let maxText = panes().first?.textWidth ?? 0
        hOffset = max(0, min(hOffset, maxContentWidth - maxText))
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        invalidateCaches()
    }

    // MARK: Caches

    private func ctLine(side: Int, line: Int, colors: SyntaxColors, textColor: CGColor) -> CTLine {
        if side < lineCache.count, line < lineCache[side].count, let l = lineCache[side][line] { return l }
        guard let model else { return CTLineCreateWithAttributedString(NSAttributedString(string: "")) }
        let text = model.displayLine(side: side, line: line)
        let attr = NSMutableAttributedString(string: text, attributes: [
            .font: font,
            NSAttributedString.Key(kCTForegroundColorAttributeName as String): textColor,
        ])
        if model.showSyntax && text.utf16.count < 4000 {
            model.sides[side].language.highlight(attr, colors: colors)
        }
        if model.showWhitespace { markWhitespace(attr, raw: model.sides[side].lines[line]) }
        let l = CTLineCreateWithAttributedString(attr)
        if side < lineCache.count, line < lineCache[side].count { lineCache[side][line] = l }
        return l
    }

    /// Replaces spaces with · and the first column of each tab with → (same UTF-16 length, so
    /// inline-diff ranges still line up) and dims them.
    private func markWhitespace(_ attr: NSMutableAttributedString, raw: String) {
        let color = NSColor.tertiaryLabelColor.withAlphaComponent(0.6).cgColor
        let key = NSAttributedString.Key(kCTForegroundColorAttributeName as String)
        var offset = 0, col = 0
        let length = attr.length
        for ch in raw {
            let units = String(ch).utf16.count
            if ch == " " || ch == "\t" {
                guard offset < length else { break }
                attr.replaceCharacters(in: NSRange(location: offset, length: 1), with: ch == " " ? "·" : "→")
                attr.addAttribute(key, value: color, range: NSRange(location: offset, length: 1))
            }
            if ch == "\t" {
                let w = TextCompareModel.tabWidth - (col % TextCompareModel.tabWidth)
                offset += w; col += w
            } else {
                offset += units; col += 1
            }
        }
    }

    private func inlineRanges(row: Int) -> [[NSRange]] {
        if let c = inlineCache[row] { return c }
        guard let model else { return [] }
        let n = model.sideCount
        var out = [[NSRange]](repeating: [], count: n)
        guard row < model.result.rows.count else { return out }
        let r = model.result.rows[row]
        let ci = Int(r.chunk)
        guard ci >= 0, model.inlineGranularity != .off else { inlineCache[row] = out; return out }
        let granularity = model.inlineGranularity
        let kind = model.result.chunks[ci].kind
        let ic = model.options.ignoreCase
        let iw = model.options.whitespace != .compare
        func diff(_ a: Int, _ b: Int) -> InlineDiff? {
            let la = r.line(a), lb = r.line(b)
            guard la >= 0, lb >= 0 else { return nil }
            let d = InlineDiff.compute(model.displayLine(side: a, line: la), model.displayLine(side: b, line: lb),
                                       ignoreCase: ic, ignoreWhitespace: iw, granularity: granularity)
            return d.similarity >= 0.25 ? d : nil
        }
        if n == 2 {
            if kind == .modified, let d = diff(0, 1) { out[0] = d.left; out[1] = d.right }
        } else {
            switch kind {
            case .leftChanged:
                if let d = diff(1, 0) { out[1] = d.left; out[0] = d.right }
            case .rightChanged:
                if let d = diff(1, 2) { out[1] = d.left; out[2] = d.right }
            case .conflict, .bothChanged:
                if let d = diff(1, 0) { out[0] = d.right }
                if let d = diff(1, 2) { out[2] = d.right }
            default: break
            }
        }
        inlineCache[row] = out
        return out
    }

    private func copyable(chunk: Int) -> [Bool] {
        if let c = copyableCache[chunk] { return c }
        guard let model else { return [] }
        let gaps = (0..<(model.sideCount - 1)).map { model.canCopy(chunk: chunk, from: $0, to: $0 + 1) }
        copyableCache[chunk] = gaps
        return gaps
    }

    // MARK: Drawing

    override func draw(_ dirtyRect: NSRect) {
        guard let model, let ctx = NSGraphicsContext.current?.cgContext else { return }
        Theme.editorBackground.setFill()
        dirtyRect.fill()
        let result = model.result
        let panes = self.panes()
        let n = panes.count
        guard n > 0 else { return }

        // Gutters
        for p in panes {
            Theme.gutterBackground.setFill()
            NSRect(x: p.x, y: dirtyRect.minY, width: p.numbersWidth, height: dirtyRect.height).fill()
            Theme.gutterDivider.setFill()
            NSRect(x: p.x + p.numbersWidth - 1, y: dirtyRect.minY, width: 1, height: dirtyRect.height).fill()
        }
        for g in 0..<(n - 1) {
            Theme.mergeGutterBackground.setFill()
            NSRect(x: panes[g].x + panes[g].width, y: dirtyRect.minY, width: Self.mergeGutterWidth, height: dirtyRect.height).fill()
        }

        let rows = result.rows
        let layout = model.layout
        guard layout.count > 0 else {
            drawEmptyState(panes: panes)
            return
        }
        let firstRow = max(0, Int(floor(dirtyRect.minY / rowHeight)))
        let lastRow = min(layout.count - 1, Int(ceil(dirtyRect.maxY / rowHeight)))
        guard firstRow <= lastRow else { return }

        let colors = SyntaxColors.current()
        let textColor = Theme.text.cgColor
        let numberColor = Theme.gutterText.cgColor

        // Pass 1: backgrounds, fillers, line numbers
        var fillerRects: [CGRect] = []
        var folds: [(display: Int, rows: Range<Int>, expanded: Bool)] = []
        for display in firstRow...lastRow {
            guard let row = layout.resultRow(at: display) else {
                switch layout.items[display] {
                case .fold(let range): folds.append((display, range, false))
                case .expanded(let range): folds.append((display, range, true))
                case .row: break
                }
                continue
            }
            let r = rows[row]
            let y = CGFloat(display) * rowHeight
            let ci = Int(r.chunk)
            let kind = ci >= 0 ? result.chunks[ci].kind : nil
            for s in 0..<n {
                let p = panes[s]
                let line = r.line(s)
                let textRect = NSRect(x: p.x + p.numbersWidth, y: y, width: p.width - p.numbersWidth, height: rowHeight)
                let style = kind.flatMap { Theme.style(for: $0, side: s, sideCount: n) }
                if line < 0 {
                    if kind != nil { fillerRects.append(textRect) }
                } else {
                    if let style {
                        style.background.setFill()
                        textRect.fill()
                        style.gutter.setFill()
                        NSRect(x: p.x, y: y, width: p.numbersWidth - 1, height: rowHeight).fill()
                        style.accent.setFill()
                        NSRect(x: p.x + p.numbersWidth - 3, y: y, width: 2, height: rowHeight).fill()
                    } else if hoverRow == display {
                        Theme.hoverRow.setFill()
                        textRect.fill()
                    }
                    if model.showLineNumbers {
                        drawLineNumber(line + 1, in: NSRect(x: p.x, y: y, width: p.numbersWidth - 8, height: rowHeight),
                                       color: style != nil ? textColor.copy(alpha: 0.55)! : numberColor, ctx: ctx)
                    }
                }
            }
        }
        if !fillerRects.isEmpty { drawFillers(fillerRects, ctx: ctx) }

        // Pass 2: inline highlights + text, clipped per pane
        for d in firstRow...lastRow { edgeMarkers[d] = nil }
        var pendingMarkers: [(display: Int, marker: EdgeMarker)] = []
        for s in 0..<n {
            let p = panes[s]
            ctx.saveGState()
            ctx.clip(to: CGRect(x: p.x + p.numbersWidth, y: dirtyRect.minY, width: p.width - p.numbersWidth, height: dirtyRect.height))
            ctx.textMatrix = CGAffineTransform(scaleX: 1, y: -1)
            let x0 = p.textX - hOffset
            for display in firstRow...lastRow {
                guard let row = layout.resultRow(at: display) else { continue }
                let r = rows[row]
                let line = r.line(s)
                guard line >= 0 else { continue }
                let y = CGFloat(display) * rowHeight
                let ctl = ctLine(side: s, line: line, colors: colors, textColor: textColor)
                let ci = Int(r.chunk)
                if ci >= 0, let style = Theme.style(for: result.chunks[ci].kind, side: s, sideCount: n) {
                    let ranges = inlineRanges(row: row)
                    if s < ranges.count && !ranges[s].isEmpty {
                        style.inline.setFill()
                        var hiddenLeft: [CGFloat] = [], hiddenRight: [CGFloat] = []
                        for range in ranges[s] {
                            let a = CTLineGetOffsetForStringIndex(ctl, range.location, nil)
                            let b = CTLineGetOffsetForStringIndex(ctl, NSMaxRange(range), nil)
                            let rect = NSRect(x: x0 + a - 1, y: y + 1.5, width: max(3, b - a + 2), height: rowHeight - 3)
                            NSBezierPath(roundedRect: rect, xRadius: 3, yRadius: 3).fill()
                            if x0 + b < p.textX - 1 { hiddenLeft.append(a) }
                            else if x0 + a > p.x + p.width - 22 { hiddenRight.append(a) }
                        }
                        let markerSize = NSSize(width: 20, height: max(12, rowHeight - 5))
                        if let target = hiddenLeft.last {
                            let r = NSRect(x: p.x + p.numbersWidth + 2, y: y + (rowHeight - markerSize.height) / 2,
                                           width: markerSize.width, height: markerSize.height)
                            pendingMarkers.append((display, EdgeMarker(rect: r, side: s, pointsRight: false, offset: target,
                                                                       color: style.accent, count: hiddenLeft.count)))
                        }
                        if let target = hiddenRight.first {
                            let r = NSRect(x: p.x + p.width - markerSize.width - 3, y: y + (rowHeight - markerSize.height) / 2,
                                           width: markerSize.width, height: markerSize.height)
                            pendingMarkers.append((display, EdgeMarker(rect: r, side: s, pointsRight: true, offset: target,
                                                                       color: style.accent, count: hiddenRight.count)))
                        }
                    }
                }
                ctx.textPosition = CGPoint(x: x0, y: y + baseline)
                CTLineDraw(ctl, ctx)
            }
            ctx.restoreGState()
        }

        // Pass 3: chunk outlines, merge gutter ribbons and arrows
        drawChunkDecorations(firstRow: firstRow, lastRow: lastRow, panes: panes, ctx: ctx)
        for f in folds { drawFold(display: f.display, rows: f.rows, expanded: f.expanded, panes: panes) }
        for (display, m) in pendingMarkers {
            edgeMarkers[display, default: []].append(m)
            let hovered = hoverMarker.map { $0.row == display && $0.index == edgeMarkers[display]!.count - 1 } ?? false
            drawEdgeMarker(m, hovered: hovered)
        }
    }

    private func drawEdgeMarker(_ m: EdgeMarker, hovered: Bool) {
        let path = NSBezierPath(roundedRect: m.rect, xRadius: m.rect.height / 2, yRadius: m.rect.height / 2)
        NSGraphicsContext.saveGraphicsState()
        let shadow = NSShadow()
        shadow.shadowColor = NSColor.black.withAlphaComponent(0.25)
        shadow.shadowBlurRadius = 3
        shadow.shadowOffset = NSSize(width: 0, height: -1)
        shadow.set()
        (hovered ? m.color : m.color.withAlphaComponent(0.92)).setFill()
        path.fill()
        NSGraphicsContext.restoreGraphicsState()
        // Double chevron pointing to the hidden change.
        let glyph = NSBezierPath()
        glyph.lineWidth = 1.6
        glyph.lineCapStyle = .round
        glyph.lineJoinStyle = .round
        let cy = m.rect.midY, h: CGFloat = 3.2, w: CGFloat = 2.6
        for dx in [-2.6, 2.6] as [CGFloat] {
            let cx = m.rect.midX + dx
            if m.pointsRight {
                glyph.move(to: NSPoint(x: cx - w / 2, y: cy - h)); glyph.line(to: NSPoint(x: cx + w / 2, y: cy)); glyph.line(to: NSPoint(x: cx - w / 2, y: cy + h))
            } else {
                glyph.move(to: NSPoint(x: cx + w / 2, y: cy - h)); glyph.line(to: NSPoint(x: cx - w / 2, y: cy)); glyph.line(to: NSPoint(x: cx + w / 2, y: cy + h))
            }
        }
        NSColor.white.setStroke()
        glyph.stroke()
    }

    private func edgeMarker(at point: NSPoint) -> (row: Int, index: Int, marker: EdgeMarker)? {
        let display = Int(point.y / rowHeight)
        guard let list = edgeMarkers[display] else { return nil }
        for (i, m) in list.enumerated() where m.rect.insetBy(dx: -3, dy: -2).contains(point) { return (display, i, m) }
        return nil
    }

    /// Scrolls horizontally so a position inside the lines is comfortably visible.
    private func scrollHorizontally(toLineOffset x: CGFloat) {
        let width = panes().first?.textWidth ?? 0
        hOffset = max(0, x - width * 0.3)
        clampHOffset()
        endEditing(commit: true)
        needsDisplay = true
    }

    /// When jumping to a difference whose changed text is outside the visible columns,
    /// scroll sideways so the first change is in view (WinMerge does the same).
    func revealChunkHorizontally(_ chunkIndex: Int) {
        guard let model, chunkIndex < model.result.chunks.count, model.inlineGranularity != .off else { return }
        let chunk = model.result.chunks[chunkIndex]
        let width = panes().first?.textWidth ?? 0
        guard width > 40 else { return }
        let colors = SyntaxColors.current()
        var offsets: [CGFloat] = []
        for row in chunk.rows.prefix(200) {
            let ranges = inlineRanges(row: row)
            for (s, list) in ranges.enumerated() {
                let line = model.result.rows[row].line(s)
                guard line >= 0, let first = list.first else { continue }
                let ctl = ctLine(side: s, line: line, colors: colors, textColor: Theme.text.cgColor)
                offsets.append(CTLineGetOffsetForStringIndex(ctl, first.location, nil))
            }
        }
        guard let leftmost = offsets.min() else { return } // whole-line change: keep the position
        let visible = offsets.contains { $0 >= hOffset && $0 <= hOffset + width - 30 }
        if !visible { scrollHorizontally(toLineOffset: leftmost) }
    }

    /// "⋯ 120 unchanged lines" band standing in for folded rows; click to expand.
    private func drawFold(display: Int, rows: Range<Int>, expanded: Bool, panes: [Pane]) {
        guard let model, let first = panes.first, let last = panes.last else { return }
        let y = CGFloat(display) * rowHeight
        let band = NSRect(x: first.x, y: y, width: last.x + last.width - first.x, height: rowHeight)
        (hoverRow == display ? Theme.hoverRow : Theme.gutterBackground).setFill()
        band.fill()
        Theme.gutterDivider.setFill()
        NSRect(x: band.minX, y: band.minY, width: band.width, height: 1).fill()
        NSRect(x: band.minX, y: band.maxY - 1, width: band.width, height: 1).fill()
        let isHover = hoverRow == display
        let n = "\(rows.count.formatted()) unchanged line\(rows.count == 1 ? "" : "s")"
        let label = expanded ? "Hide \(n)" + (isHover ? " — click to fold" : "")
                             : n + (isHover ? " — click to show" : "")
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: max(10, font.pointSize - 1.5), weight: .medium),
            .foregroundColor: isHover ? NSColor.controlAccentColor : NSColor.secondaryLabelColor,
        ]
        let icon = NSImage(systemSymbolName: expanded ? "chevron.down.circle" : "arrow.up.and.down.text.horizontal", accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: max(9, font.pointSize - 2.5), weight: .semibold))
        let text = label as NSString
        let size = text.size(withAttributes: attrs)
        for (s, p) in panes.enumerated() {
            // Line-number range hidden in this pane.
            var lo = -1, hi = -1
            for r in [rows.lowerBound, rows.upperBound - 1] {
                let l = model.result.rows[r].line(s)
                if l >= 0 { if lo < 0 { lo = l }; hi = l }
            }
            if lo >= 0 && model.showLineNumbers && !expanded {
                let nums = "\(lo + 1)–\(hi + 1)" as NSString
                var nAttrs: [NSAttributedString.Key: Any] = [.font: numberFont, .foregroundColor: NSColor.tertiaryLabelColor]
                var ns = nums.size(withAttributes: nAttrs)
                if ns.width >= p.numbersWidth - 10 {
                    // Long ranges: shrink to fit rather than disappear.
                    let scale = max(0.55, (p.numbersWidth - 12) / ns.width)
                    nAttrs[.font] = NSFont.monospacedDigitSystemFont(ofSize: numberFont.pointSize * scale, weight: .regular)
                    ns = nums.size(withAttributes: nAttrs)
                }
                if ns.width < p.numbersWidth - 4 {
                    nums.draw(at: NSPoint(x: p.x + p.numbersWidth - 8 - ns.width, y: y + (rowHeight - ns.height) / 2), withAttributes: nAttrs)
                }
            }
            var x = p.textX
            if let icon {
                let tinted = icon.tinted(isHover ? .controlAccentColor : .secondaryLabelColor)
                tinted.draw(in: NSRect(x: x, y: y + (rowHeight - icon.size.height) / 2, width: icon.size.width, height: icon.size.height),
                            from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
                x += icon.size.width + 6
            }
            if s == 0 || model.sideCount > 1 {
                text.draw(at: NSPoint(x: x, y: y + (rowHeight - size.height) / 2), withAttributes: attrs)
            }
        }
    }

    private func drawEmptyState(panes: [Pane]) {
        let title: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 13, weight: .semibold), .foregroundColor: NSColor.secondaryLabelColor]
        let body: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 11.5), .foregroundColor: NSColor.tertiaryLabelColor]
        for p in panes {
            ("Empty" as NSString).draw(at: NSPoint(x: p.textX, y: 14), withAttributes: title)
            ("Paste text with ⌘V, drop a file here, or double-click to type." as NSString)
                .draw(in: NSRect(x: p.textX, y: 34, width: max(80, p.textWidth - 12), height: 40), withAttributes: body)
        }
    }

    private func drawLineNumber(_ number: Int, in rect: NSRect, color: CGColor, ctx: CGContext) {
        let s = NSAttributedString(string: String(number), attributes: [
            .font: numberFont,
            NSAttributedString.Key(kCTForegroundColorAttributeName as String): color,
        ])
        let line = CTLineCreateWithAttributedString(s)
        let w = CTLineGetTypographicBounds(line, nil, nil, nil)
        ctx.saveGState()
        ctx.textMatrix = CGAffineTransform(scaleX: 1, y: -1)
        ctx.textPosition = CGPoint(x: rect.maxX - CGFloat(w), y: rect.minY + baseline - 0.5)
        CTLineDraw(line, ctx)
        ctx.restoreGState()
    }

    private func drawFillers(_ rects: [CGRect], ctx: CGContext) {
        ctx.saveGState()
        Theme.fillerBackground.setFill()
        for r in rects { r.fill() }
        ctx.clip(to: rects)
        let bounds = rects.reduce(rects[0]) { $0.union($1) }
        Theme.fillerStripe.setStroke()
        let path = NSBezierPath()
        path.lineWidth = 1
        let spacing: CGFloat = 7
        var x = floor((bounds.minX - bounds.height) / spacing) * spacing
        // Anchor stripes to absolute coordinates so the pattern is seamless while scrolling.
        let yOffset = bounds.minY.truncatingRemainder(dividingBy: spacing)
        x -= yOffset
        while x < bounds.maxX {
            path.move(to: NSPoint(x: x, y: bounds.maxY))
            path.line(to: NSPoint(x: x + bounds.height, y: bounds.minY))
            x += spacing
        }
        path.stroke()
        ctx.restoreGState()
    }

    /// Vertical extent of a chunk in display coordinates.
    private func chunkRect(_ chunk: DiffChunk) -> (y: CGFloat, h: CGFloat) {
        let rows = model?.layout.displayRange(of: chunk) ?? chunk.rows
        return (CGFloat(rows.lowerBound) * rowHeight, CGFloat(max(rows.count, 0)) * rowHeight)
    }

    private func arrowRects(chunk: DiffChunk, gutter g: Int, panes: [Pane]) -> (toRight: NSRect, toLeft: NSRect) {
        let gx = panes[g].x + panes[g].width
        let (y, h) = chunkRect(chunk)
        let size: CGFloat = 15
        let cy = y + min(h, rowHeight) / 2
        let toRight = NSRect(x: gx + 3, y: cy - size / 2, width: size, height: size)
        let toLeft = NSRect(x: gx + Self.mergeGutterWidth - 3 - size, y: cy - size / 2, width: size, height: size)
        return (toRight, toLeft)
    }

    private func drawChunkDecorations(firstRow: Int, lastRow: Int, panes: [Pane], ctx: CGContext) {
        guard let model else { return }
        let result = model.result
        let n = panes.count
        // Find chunks intersecting the visible rows.
        var chunkIndices: [Int] = []
        var seen = Set<Int>()
        for display in firstRow...lastRow {
            guard let row = model.layout.resultRow(at: display) else { continue }
            let ci = Int(result.rows[row].chunk)
            if ci >= 0 && seen.insert(ci).inserted { chunkIndices.append(ci) }
        }
        // Also include zero-height insertions at the edges: none possible (fillers make every chunk ≥ 1 row).
        for ci in chunkIndices {
            let chunk = result.chunks[ci]
            let (y, h) = chunkRect(chunk)
            let accent = Theme.accent(for: chunk.kind)
            let isCurrent = model.currentChunk == ci

            // Hairlines above and below the chunk in each pane.
            for s in 0..<n {
                let p = panes[s]
                let rect = NSRect(x: p.x + p.numbersWidth, y: y, width: p.width - p.numbersWidth, height: h)
                let style = Theme.style(for: chunk.kind, side: s, sideCount: n)
                let lineColor = (style?.accent ?? accent).withAlphaComponent(isCurrent ? 0.0 : 0.28)
                lineColor.setFill()
                NSRect(x: rect.minX, y: rect.minY, width: rect.width, height: 1).fill()
                NSRect(x: rect.minX, y: rect.maxY - 1, width: rect.width, height: 1).fill()
            }

            // Merge gutters: ribbon + copy arrows.
            let copy = copyable(chunk: ci)
            for g in 0..<(n - 1) {
                let gx = panes[g].x + panes[g].width
                let ribbon = NSRect(x: gx + 2, y: y + 1, width: Self.mergeGutterWidth - 4, height: h - 2)
                accent.withAlphaComponent(isCurrent ? 0.22 : 0.10).setFill()
                NSBezierPath(roundedRect: ribbon, xRadius: 4, yRadius: 4).fill()
                guard g < copy.count, copy[g] else { continue }
                let (toRight, toLeft) = arrowRects(chunk: chunk, gutter: g, panes: panes)
                drawArrow(in: toRight, pointingRight: true, color: accent,
                          hovered: hoverArrow == ArrowHit(chunk: ci, from: g, to: g + 1), emphasized: isCurrent)
                drawArrow(in: toLeft, pointingRight: false, color: accent,
                          hovered: hoverArrow == ArrowHit(chunk: ci, from: g + 1, to: g), emphasized: isCurrent)
            }

            // Current chunk: crisp accent outline around each pane's block.
            if isCurrent {
                for s in 0..<n {
                    let p = panes[s]
                    let rect = NSRect(x: p.x + p.numbersWidth + 1, y: y + 0.5, width: p.width - p.numbersWidth - 2, height: h - 1)
                    let path = NSBezierPath(roundedRect: rect, xRadius: 3, yRadius: 3)
                    path.lineWidth = 1.5
                    NSColor.controlAccentColor.withAlphaComponent(0.85).setStroke()
                    path.stroke()
                }
            }
        }
    }

    private func drawArrow(in rect: NSRect, pointingRight: Bool, color: NSColor, hovered: Bool, emphasized: Bool) {
        let circle = NSBezierPath(ovalIn: rect)
        if hovered {
            color.setFill()
        } else {
            color.withAlphaComponent(emphasized ? 0.32 : 0.18).setFill()
        }
        circle.fill()
        let glyph = NSBezierPath()
        glyph.lineWidth = 1.7
        glyph.lineCapStyle = .round
        glyph.lineJoinStyle = .round
        let cx = rect.midX, cy = rect.midY
        let w: CGFloat = 2.6, hh: CGFloat = 3.6
        if pointingRight {
            glyph.move(to: NSPoint(x: cx - w + 0.5, y: cy - hh))
            glyph.line(to: NSPoint(x: cx + w + 0.5, y: cy))
            glyph.line(to: NSPoint(x: cx - w + 0.5, y: cy + hh))
        } else {
            glyph.move(to: NSPoint(x: cx + w - 0.5, y: cy - hh))
            glyph.line(to: NSPoint(x: cx - w - 0.5, y: cy))
            glyph.line(to: NSPoint(x: cx + w - 0.5, y: cy + hh))
        }
        (hovered ? NSColor.white : color.blended(withFraction: 0.15, of: .black) ?? color).setStroke()
        glyph.stroke()
    }

    // MARK: Hit testing

    private func location(of point: NSPoint) -> (row: Int, side: Int?, gutter: Int?) {
        let row = Int(point.y / rowHeight)
        for (s, p) in panes().enumerated() {
            if point.x >= p.x && point.x < p.x + p.width { return (row, s, nil) }
            if point.x >= p.x + p.width && point.x < p.x + p.width + Self.mergeGutterWidth { return (row, nil, s) }
        }
        return (row, nil, nil)
    }

    /// Result row under a display row (nil for folds and past the end).
    private func resultRow(_ display: Int) -> Int? { model?.layout.resultRow(at: display) }

    private func arrowHit(at point: NSPoint) -> ArrowHit? {
        guard let model else { return nil }
        let loc = location(of: point)
        guard let g = loc.gutter, let rr = resultRow(loc.row), let ci = model.result.chunkIndex(atRow: rr) else { return nil }
        let chunk = model.result.chunks[ci]
        let ps = panes()
        let (toRight, toLeft) = arrowRects(chunk: chunk, gutter: g, panes: ps)
        let copy = copyable(chunk: ci)
        guard g < copy.count, copy[g] else { return nil }
        if toRight.insetBy(dx: -3, dy: -3).contains(point) { return ArrowHit(chunk: ci, from: g, to: g + 1) }
        if toLeft.insetBy(dx: -3, dy: -3).contains(point) { return ArrowHit(chunk: ci, from: g + 1, to: g) }
        return nil
    }

    // MARK: Mouse

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect, .cursorUpdate],
                                       owner: self, userInfo: nil))
    }

    override func mouseMoved(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        let marker = edgeMarker(at: p)
        let markerKey = marker.map { (row: $0.row, index: $0.index) }
        if markerKey?.row != hoverMarker?.row || markerKey?.index != hoverMarker?.index {
            hoverMarker = markerKey
            needsDisplay = true
        }
        if let marker {
            toolTip = marker.marker.pointsRight
                ? "\(marker.marker.count) more change\(marker.marker.count == 1 ? "" : "s") to the right — click to scroll"
                : "\(marker.marker.count) more change\(marker.marker.count == 1 ? "" : "s") to the left — click to scroll"
            NSCursor.pointingHand.set()
            return
        } else if toolTip != nil {
            toolTip = nil
        }
        let hit = arrowHit(at: p)
        let loc = location(of: p)
        let overFold = isFold(loc.row)
        let row = (loc.side != nil || overFold) ? loc.row : nil
        if hit != hoverArrow || row != hoverRow {
            hoverArrow = hit
            hoverRow = row
            needsDisplay = true
        }
        if hit != nil || overFold { NSCursor.pointingHand.set() } else if loc.side != nil { NSCursor.iBeam.set() } else { NSCursor.arrow.set() }
    }

    override func mouseExited(with event: NSEvent) {
        if hoverArrow != nil || hoverRow != nil {
            hoverArrow = nil
            hoverRow = nil
            needsDisplay = true
        }
        NSCursor.arrow.set()
    }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        guard let model else { return }
        let p = convert(event.locationInWindow, from: nil)
        if let m = edgeMarker(at: p) {
            hoverMarker = nil
            scrollHorizontally(toLineOffset: m.marker.offset)
            return
        }
        if let hit = arrowHit(at: p) {
            hoverArrow = nil
            model.copy(chunk: hit.chunk, from: hit.from, to: hit.to)
            return
        }
        let loc = location(of: p)
        if loc.row < model.layout.count {
            switch model.layout.items[loc.row] {
            case .fold(let range): hoverRow = nil; model.reveal(range); return
            case .expanded(let range): hoverRow = nil; model.collapse(range); return
            case .row: break
            }
        }
        if let side = loc.side {
            model.activeSide = side
            activeLine = resultRow(loc.row).map { model.result.rows[$0].line(side) }.flatMap { $0 >= 0 ? $0 : nil }
        }
        let rr = resultRow(loc.row)
        let ci = rr.flatMap { model.result.chunkIndex(atRow: $0) }
        if event.clickCount >= 2, let side = loc.side {
            if let rr {
                let line = model.result.rows[rr].line(side)
                if line >= 0 { beginEditing(side: side, line: line, row: loc.row) }
            } else if model.sides[side].isEmpty {
                model.isEditingText = true
            }
            return
        }
        if ci != model.currentChunk {
            model.select(chunk: ci, scroll: false)
        }
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        guard let model else { return nil }
        let p = convert(event.locationInWindow, from: nil)
        let loc = location(of: p)
        guard let side = loc.side else { return nil }
        let menu = NSMenu()
        guard let rr = resultRow(loc.row) else {
            addPaneItems(to: menu, side: side, line: nil)
            return menu
        }
        let line = model.result.rows[rr].line(side)
        if let ci = model.result.chunkIndex(atRow: rr) {
            model.select(chunk: ci, scroll: false)
            for target in 0..<model.sideCount where target != side && abs(target - side) == 1 || (target != side && model.sideCount == 2) {
                if model.canCopy(chunk: ci, from: side, to: target) {
                    let name = SideInfo.name(target, count: model.sideCount)
                    menu.addItem(MenuAction(title: "Copy This Change to \(name)", symbol: target > side ? "arrow.right" : "arrow.left") {
                        model.copy(chunk: ci, from: side, to: target)
                    })
                }
            }
            menu.addItem(.separator())
        }
        if line >= 0 {
            menu.addItem(MenuAction(title: "Edit Line", symbol: "pencil") { [weak self] in
                self?.beginEditing(side: side, line: line, row: loc.row)
            })
            menu.addItem(MenuAction(title: "Insert Line Below", symbol: "text.insert") {
                model.insertLine(side: side, after: line)
            })
            menu.addItem(MenuAction(title: "Delete Line", symbol: "trash") {
                model.deleteLines(side: side, range: line..<(line + 1))
            })
            menu.addItem(.separator())
            menu.addItem(MenuAction(title: "Copy Line Text", symbol: "doc.on.doc") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(model.sides[side].lines[line], forType: .string)
            })
        }
        if let ci = model.result.chunkIndex(atRow: rr) {
            let range = model.result.chunks[ci].ranges[side]
            if !range.isEmpty {
                menu.addItem(MenuAction(title: "Copy Block Text", symbol: "doc.on.clipboard") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(model.sides[side].lines[range].joined(separator: "\n"), forType: .string)
                })
            }
        }
        addPaneItems(to: menu, side: side, line: line >= 0 ? line : nil)
        return menu
    }

    private func addPaneItems(to menu: NSMenu, side: Int, line: Int?) {
        guard let model else { return }
        if menu.items.last?.isSeparatorItem == false && !menu.items.isEmpty { menu.addItem(.separator()) }
        if NSPasteboard.general.string(forType: .string) != nil {
            menu.addItem(MenuAction(title: line == nil ? "Paste" : "Paste Below This Line", symbol: "doc.on.clipboard") {
                model.paste(NSPasteboard.general.string(forType: .string) ?? "", side: side, afterLine: line)
            })
        }
        menu.addItem(MenuAction(title: "Edit Pane as Text", symbol: "character.cursor.ibeam") {
            model.activeSide = side
            model.isEditingText = true
        })
    }

    private func isFold(_ display: Int) -> Bool {
        guard let model, display >= 0, display < model.layout.count else { return false }
        if case .row = model.layout.items[display] { return false }
        return true
    }

    // MARK: Pasteboard

    @objc func paste(_ sender: Any?) {
        guard let model, let text = NSPasteboard.general.string(forType: .string) else { NSSound.beep(); return }
        model.paste(text, side: min(model.activeSide, model.sideCount - 1), afterLine: activeLine)
    }

    @objc func copy(_ sender: Any?) {
        guard let model, let c = model.currentChunk, c < model.result.chunks.count else { NSSound.beep(); return }
        let side = min(model.activeSide, model.sideCount - 1)
        let range = model.result.chunks[c].ranges[side]
        guard !range.isEmpty, range.upperBound <= model.sides[side].lines.count else { NSSound.beep(); return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(model.sides[side].lines[range].joined(separator: "\n"), forType: .string)
    }

    func validateUserInterfaceItem(_ item: any NSValidatedUserInterfaceItem) -> Bool {
        if item.action == #selector(paste(_:)) { return NSPasteboard.general.string(forType: .string) != nil }
        if item.action == #selector(copy(_:)) { return model?.currentChunk != nil }
        return true
    }

    // MARK: Scrolling

    override func scrollWheel(with event: NSEvent) {
        let dx = event.scrollingDeltaX
        let dy = event.scrollingDeltaY
        if event.phase == .began || (event.phase.isEmpty && event.momentumPhase.isEmpty) {
            axisLock = 0
        }
        if axisLock == 0 && (dx != 0 || dy != 0) {
            axisLock = abs(dx) > abs(dy) ? 1 : 2
        }
        if axisLock == 1 {
            let factor: CGFloat = event.hasPreciseScrollingDeltas ? 1 : charWidth * 3
            let old = hOffset
            hOffset -= dx * factor
            clampHOffset()
            if hOffset != old {
                needsDisplay = true
                endEditing(commit: true)
            }
        } else {
            super.scrollWheel(with: event)
        }
    }

    override func keyDown(with event: NSEvent) {
        guard let scroll = enclosingScrollView else { return super.keyDown(with: event) }
        let clip = scroll.contentView
        var y = clip.bounds.minY
        switch event.specialKey {
        case .upArrow: y -= rowHeight * 3
        case .downArrow: y += rowHeight * 3
        case .pageUp: y -= clip.bounds.height * 0.9
        case .pageDown: y += clip.bounds.height * 0.9
        case .home: y = 0
        case .end: y = frame.height
        case .leftArrow: hOffset -= charWidth * 4; clampHOffset(); needsDisplay = true; return
        case .rightArrow: hOffset += charWidth * 4; clampHOffset(); needsDisplay = true; return
        default:
            if event.charactersIgnoringModifiers == " " { y += clip.bounds.height * 0.9 } else { return super.keyDown(with: event) }
        }
        y = max(0, min(y, frame.height - clip.bounds.height))
        clip.setBoundsOrigin(NSPoint(x: 0, y: y))
        scroll.reflectScrolledClipView(clip)
    }

    // MARK: Inline editing

    func beginEditing(side: Int, line: Int, row: Int) {
        guard let model else { return }
        endEditing(commit: true)
        let p = panes()[side]
        let field = NSTextField(frame: NSRect(x: p.textX - 4, y: CGFloat(row) * rowHeight - 1,
                                              width: p.width - p.numbersWidth - 4, height: rowHeight + 2))
        field.font = font
        field.stringValue = model.sides[side].lines[line]
        field.isBordered = false
        field.focusRingType = .none
        field.drawsBackground = true
        field.backgroundColor = Theme.editorBackground
        field.wantsLayer = true
        field.layer?.cornerRadius = 4
        field.layer?.borderWidth = 1.5
        field.layer?.borderColor = NSColor.controlAccentColor.cgColor
        field.delegate = self
        field.cell?.usesSingleLineMode = true
        field.cell?.isScrollable = true
        addSubview(field)
        editor = field
        editing = (side, line)
        editCancelled = false
        window?.makeFirstResponder(field)
        field.currentEditor()?.selectedRange = NSRange(location: (field.stringValue as NSString).length, length: 0)
    }

    func endEditing(commit: Bool) {
        guard let field = editor, let e = editing else { return }
        editor = nil
        editing = nil
        let text = field.stringValue
        field.delegate = nil
        field.removeFromSuperview()
        window?.makeFirstResponder(self)
        if commit && !editCancelled { model?.editLine(side: e.side, line: e.line, text: text) }
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        if selector == #selector(NSResponder.cancelOperation(_:)) {
            editCancelled = true
            endEditing(commit: false)
            return true
        }
        if selector == #selector(NSResponder.insertNewline(_:)) {
            endEditing(commit: true)
            return true
        }
        return false
    }

    func controlTextDidEndEditing(_ obj: Notification) {
        endEditing(commit: true)
    }
}

/// Closure-backed menu item.
final class MenuAction: NSMenuItem {
    private let handler: () -> Void

    init(title: String, symbol: String? = nil, enabled: Bool = true, handler: @escaping () -> Void) {
        self.handler = handler
        super.init(title: title, action: #selector(run), keyEquivalent: "")
        target = self
        isEnabled = enabled
        if let symbol { image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil) }
    }

    required init(coder: NSCoder) { fatalError() }

    @objc private func run() { handler() }
}

/// Miniature map of all differences, WinMerge "location pane" style. Click or drag to jump.
final class OverviewRuler: NSView {
    weak var model: TextCompareModel?
    weak var scrollView: NSScrollView?
    weak var grid: DiffGridView?

    override var isFlipped: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        Theme.gutterBackground.setFill()
        bounds.fill()
        Theme.gutterDivider.setFill()
        NSRect(x: 0, y: 0, width: 1, height: bounds.height).fill()
        guard let model, let grid, let scrollView else { return }
        let rows = model.layout.count
        guard rows > 0 else { return }
        let n = model.sideCount
        let inset: CGFloat = 3
        let laneWidth = (bounds.width - inset * 2 - 1) / CGFloat(n)
        // Short documents map 1:1 onto the viewport instead of stretching over the whole ruler.
        let visibleRows = scrollView.contentView.bounds.height / max(grid.rowHeight, 1)
        let scale = (bounds.height - 4) / max(CGFloat(rows), visibleRows, 1)
        for (ci, chunk) in model.result.chunks.enumerated() {
            let d = model.layout.displayRange(of: chunk)
            let y = 2 + CGFloat(d.lowerBound) * scale
            let h = max(2, CGFloat(d.count) * scale)
            for s in 0..<n {
                guard let style = Theme.style(for: chunk.kind, side: s, sideCount: n) else { continue }
                let color = s == 1 && n == 3 ? Theme.accent(for: chunk.kind).withAlphaComponent(0.45) : style.accent
                color.withAlphaComponent(model.currentChunk == ci ? 1 : 0.85).setFill()
                NSRect(x: 1 + inset + CGFloat(s) * laneWidth, y: y, width: laneWidth - 1, height: h).fill()
            }
        }
        // Viewport indicator
        let clip = scrollView.contentView.bounds
        let content = max(CGFloat(rows) * grid.rowHeight, scrollView.contentView.bounds.height, 1)
        let track = bounds.height - 4
        let vy = 2 + min(1, clip.minY / content) * track
        let vh = max(10, min(1, clip.height / content) * track)
        let rect = NSRect(x: 1.5, y: vy, width: bounds.width - 3, height: min(vh, bounds.height - vy))
        let path = NSBezierPath(roundedRect: rect, xRadius: 3, yRadius: 3)
        NSColor.labelColor.withAlphaComponent(0.07).setFill()
        path.fill()
        NSColor.labelColor.withAlphaComponent(0.28).setStroke()
        path.lineWidth = 1
        path.stroke()
    }

    override func mouseDown(with event: NSEvent) { jump(event) }
    override func mouseDragged(with event: NSEvent) { jump(event) }

    private func jump(_ event: NSEvent) {
        guard let model, let grid, let container = superview as? DiffGridContainer else { return }
        let p = convert(event.locationInWindow, from: nil)
        let visibleRows = (superview as? DiffGridContainer)?.scrollView.contentView.bounds.height ?? 0
        let rows = max(CGFloat(model.layout.count), visibleRows / max(grid.rowHeight, 1))
        let row = (p.y - 2) / max(1, bounds.height - 4) * rows
        container.scrollTo(y: row * grid.rowHeight, center: true, animated: false)
    }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .pointingHand)
    }
}

extension NSImage {
    /// Template symbol drawn in a single colour.
    func tinted(_ color: NSColor) -> NSImage {
        let img = NSImage(size: size, flipped: false) { rect in
            self.draw(in: rect)
            color.set()
            rect.fill(using: .sourceAtop)
            return true
        }
        img.isTemplate = false
        return img
    }
}
