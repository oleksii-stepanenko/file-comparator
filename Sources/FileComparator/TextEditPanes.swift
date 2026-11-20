import SwiftUI
import AppKit
import DiffCore

/// Plain side-by-side text editors used for pasting or freely editing the compared texts.
/// Changed lines are tinted live; switching back to the aligned view shows the full diff.
struct TextEditPanes: View {
    var model: TextCompareModel

    var body: some View {
        HStack(spacing: 0) {
            ForEach(0..<model.sideCount, id: \.self) { side in
                if side > 0 {
                    Rectangle()
                        .fill(Color(Theme.mergeGutterBackground))
                        .frame(width: DiffGridView.mergeGutterWidth)
                        .overlay(Rectangle().fill(Color(Theme.gutterDivider)).frame(width: 1), alignment: .leading)
                        .overlay(Rectangle().fill(Color(Theme.gutterDivider)).frame(width: 1), alignment: .trailing)
                }
                ZStack(alignment: .topLeading) {
                    PaneTextEditor(model: model, side: side, revision: model.textRevision)
                    if model.sides[side].isEmpty {
                        EmptyPaneHint(model: model, side: side)
                            .allowsHitTesting(true)
                    }
                }
            }
        }
        .padding(.trailing, 16) // lines up with the headers (ruler width in the aligned view)
        .background(Color(Theme.editorBackground))
    }
}

/// Placeholder shown over an empty editor.
private struct EmptyPaneHint: View {
    var model: TextCompareModel
    var side: Int

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Paste or type text here")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(.secondary)
            Text("Click to place the cursor, then press ⌘V. You can also drop a file on the header above.")
                .font(.callout)
                .foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 8) {
                Button {
                    if let t = NSPasteboard.general.string(forType: .string) { model.replaceText(side: side, with: t) }
                } label: {
                    Label("Paste from Clipboard", systemImage: "doc.on.clipboard")
                }
                .disabled(NSPasteboard.general.string(forType: .string) == nil)
                Button {
                    PaneFileChooser.choose(into: side, model: model)
                } label: {
                    Label("Open File…", systemImage: "folder")
                }
            }
            .controlSize(.regular)
        }
        .padding(.horizontal, 22)
        .padding(.top, 26)
        .frame(maxWidth: 420, alignment: .leading)
    }
}

enum PaneFileChooser {
    @MainActor static func choose(into side: Int, model: TextCompareModel) {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Open"
        panel.message = "Choose a file for the \(SideInfo.name(side, count: model.sideCount).lowercased()) pane"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        model.loadFile(url, into: side)
    }
}

struct PaneTextEditor: NSViewRepresentable {
    var model: TextCompareModel
    var side: Int
    /// Passed in so SwiftUI calls `updateNSView` whenever any pane's text changes.
    var revision: Int

    func makeCoordinator() -> Coordinator { Coordinator(model: model, side: side) }

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSTextView.scrollableTextView()
        scroll.hasHorizontalScroller = true
        scroll.autohidesScrollers = true
        scroll.drawsBackground = true
        scroll.backgroundColor = Theme.editorBackground
        guard let tv = scroll.documentView as? NSTextView else { return scroll }
        tv.isRichText = false
        tv.importsGraphics = false
        tv.allowsUndo = true
        tv.usesFindBar = true
        tv.isIncrementalSearchingEnabled = true
        tv.isAutomaticQuoteSubstitutionEnabled = false
        tv.isAutomaticDashSubstitutionEnabled = false
        tv.isAutomaticTextReplacementEnabled = false
        tv.isAutomaticSpellingCorrectionEnabled = false
        tv.isContinuousSpellCheckingEnabled = false
        tv.isGrammarCheckingEnabled = false
        tv.smartInsertDeleteEnabled = false
        tv.drawsBackground = true
        tv.backgroundColor = Theme.editorBackground
        tv.textColor = Theme.text
        tv.insertionPointColor = .controlAccentColor
        tv.textContainerInset = NSSize(width: 8, height: 8)
        tv.font = context.coordinator.font
        tv.typingAttributes = [.font: context.coordinator.font, .foregroundColor: Theme.text]
        // No soft wrapping: lines stay lines, like in the aligned view.
        tv.isHorizontallyResizable = true
        tv.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        tv.textContainer?.widthTracksTextView = false
        tv.textContainer?.containerSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        tv.string = model.sides[side].text
        tv.delegate = context.coordinator
        context.coordinator.textView = tv
        context.coordinator.knownRevision = model.textRevision
        context.coordinator.register()
        context.coordinator.applyHighlights()
        if side == min(model.activeSide, model.sideCount - 1), AppDelegate.debugWindowIDPath == nil {
            DispatchQueue.main.async { tv.window?.makeFirstResponder(tv) }
        }
        return scroll
    }

    func updateNSView(_ nsView: NSScrollView, context: Context) {
        context.coordinator.model = model
        context.coordinator.syncFromModel()
    }

    static func dismantleNSView(_ nsView: NSScrollView, coordinator: Coordinator) {
        coordinator.flush()
        coordinator.unregister()
    }

    @MainActor
    final class Coordinator: NSObject, NSTextViewDelegate {
        var model: TextCompareModel
        let side: Int
        weak var textView: NSTextView?
        var knownRevision = -1
        private var pending: DispatchWorkItem?
        let font: NSFont

        init(model: TextCompareModel, side: Int) {
            self.model = model
            self.side = side
            let size = Preferences.shared.fontSize
            font = NSFont(name: Preferences.shared.fontName, size: size) ?? .monospacedSystemFont(ofSize: size, weight: .regular)
        }

        func register() {
            model.editorHooks[side] = TextCompareModel.EditorHook(
                flush: { [weak self] in self?.flushIfPending() },
                type: { [weak self] text in
                    guard let tv = self?.textView else { return }
                    tv.insertText(text, replacementRange: tv.selectedRange())
                })
        }

        func unregister() {
            model.editorHooks[side] = nil
        }

        private func flushIfPending() {
            if pending != nil { flush() }
        }

        func textDidChange(_ notification: Notification) {
            pending?.cancel()
            let work = DispatchWorkItem { [weak self] in
                MainActor.assumeIsolated { self?.flush() }
            }
            pending = work
            // Big files re-diff less eagerly so typing stays smooth.
            let lines = model.sides.map(\.lines.count).max() ?? 0
            let delay = lines > 20_000 ? 0.7 : (lines > 5_000 ? 0.4 : 0.25)
            DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
        }

        func textViewDidChangeSelection(_ notification: Notification) {
            if model.activeSide != side { model.activeSide = side }
        }

        /// Pushes the editor's text into the model (diff recomputes synchronously).
        func flush() {
            pending?.cancel()
            pending = nil
            guard let tv = textView else { return }
            model.setText(side: side, text: tv.string)
            knownRevision = model.textRevision
            applyHighlights()
        }

        /// Pulls text changed elsewhere (undo, Paste button, loading a file) into the editor.
        func syncFromModel() {
            guard let tv = textView, model.textRevision != knownRevision, pending == nil else { return }
            knownRevision = model.textRevision
            if side < model.sides.count {
                // Compare lines, not raw strings, so CRLF / trailing newlines never cause a needless reset.
                if TextFile.split(tv.string).lines != model.sides[side].file.lines {
                    let text = model.sides[side].text
                    let sel = tv.selectedRange()
                    tv.string = text
                    tv.setSelectedRange(NSRange(location: min(sel.location, (text as NSString).length), length: 0))
                }
            }
            applyHighlights()
        }

        /// Tints the lines of this pane that belong to a difference.
        func applyHighlights() {
            guard let tv = textView, let lm = tv.layoutManager, side < model.sides.count else { return }
            let ns = tv.string as NSString
            let full = NSRange(location: 0, length: ns.length)
            lm.removeTemporaryAttribute(.backgroundColor, forCharacterRange: full)
            let n = model.sideCount
            let result = model.result
            guard !result.chunks.isEmpty else { return }
            // Start offset of every line (\n, \r\n and \r all end a line, matching TextFile.split).
            var starts: [Int] = [0]
            starts.reserveCapacity(model.sides[side].lines.count + 1)
            var i = 0
            let len = ns.length
            while i < len {
                let c = ns.character(at: i)
                if c == 10 { starts.append(i + 1) }
                else if c == 13 {
                    if i + 1 < len && ns.character(at: i + 1) == 10 { i += 1 }
                    starts.append(i + 1)
                }
                i += 1
            }
            for chunk in result.chunks {
                let r = chunk.ranges[side]
                guard !r.isEmpty, r.lowerBound < starts.count,
                      let style = Theme.style(for: chunk.kind, side: side, sideCount: n) else { continue }
                let a = starts[r.lowerBound]
                let b = r.upperBound < starts.count ? starts[r.upperBound] : len
                guard b >= a else { continue }
                lm.addTemporaryAttribute(.backgroundColor, value: style.background, forCharacterRange: NSRange(location: a, length: b - a))
            }
        }
    }
}
