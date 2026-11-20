import SwiftUI
import AppKit
import DiffCore

struct TextCompareView: View {
    @Bindable var model: TextCompareModel
    var window: WindowModel

    var body: some View {
        VStack(spacing: 0) {
            PaneHeaders(model: model)
            Divider()
            ZStack(alignment: .top) {
                if model.isEditingText {
                    TextEditPanes(model: model)
                } else {
                    DiffGridRepresentable(model: model)
                    if model.result.isIdentical && !model.isComputing && !model.sides.allSatisfy(\.isEmpty) {
                        IdenticalBanner(threeWay: model.isThreeWay, scratch: model.sides.contains(where: \.isUntitled))
                            .padding(.top, 14)
                            .transition(.move(edge: .top).combined(with: .opacity))
                    }
                }
            }
            Divider()
            TextStatusBar(model: model)
        }
        .toolbar { toolbarContent }
        .task { await DebugActions.run(on: model) }
        .alert("Error", isPresented: Binding(get: { model.errorMessage != nil }, set: { if !$0 { model.errorMessage = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(model.errorMessage ?? "")
        }
    }

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItem(placement: .principal) {
            Picker("Mode", selection: $model.isEditingText) {
                Text("Diff").tag(false)
                Text("Edit").tag(true)
            }
            .pickerStyle(.segmented)
            .frame(width: 110)
            .help("Switch between the aligned differences and plain text editors for pasting and typing (⌘E)")
        }
        ToolbarItemGroup(placement: .principal) {
            ControlGroup {
                Button { model.previous() } label: { Label("Previous", systemImage: "chevron.up") }
                    .help("Previous difference (⌥↑)")
                    .disabled(!model.canGoPrevious)
                Button { model.next() } label: { Label("Next", systemImage: "chevron.down") }
                    .help("Next difference (⌥↓)")
                    .disabled(!model.canGoNext)
            } label: {
                Label("Navigate", systemImage: "arrow.up.arrow.down")
            }
            if model.isThreeWay && model.result.conflictCount > 0 {
                Button { model.next(conflictsOnly: true) } label: {
                    Label("Next Conflict", systemImage: "exclamationmark.triangle")
                }
                .help("Next conflict (⌃⌥↓)")
            }
        }
        ToolbarItemGroup(placement: .primaryAction) {
            if model.isThreeWay {
                ControlGroup {
                    Button { model.copyCurrent(from: 0, to: 1) } label: { Label("Take Left", systemImage: "arrow.right.to.line") }
                        .help("Take the left change into the base (⌥→)")
                        .disabled(model.currentChunk == nil)
                    Button { model.copyCurrent(from: 2, to: 1) } label: { Label("Take Right", systemImage: "arrow.left.to.line") }
                        .help("Take the right change into the base (⌥←)")
                        .disabled(model.currentChunk == nil)
                } label: { Label("Merge", systemImage: "arrow.triangle.merge") }
                Button { model.autoMerge() } label: { Label("Auto-merge", systemImage: "wand.and.stars") }
                    .help("Merge all non-conflicting changes into the base (⇧⌘M)")
                    .disabled(model.result.chunks.allSatisfy { $0.kind == .conflict })
            } else {
                ControlGroup {
                    Button { model.copyCurrent(from: 1, to: 0) } label: { Label("Copy to Left", systemImage: "arrow.left.to.line") }
                        .help("Copy the current change to the left (⌥←)")
                        .disabled(model.currentChunk == nil)
                    Button { model.copyCurrent(from: 0, to: 1) } label: { Label("Copy to Right", systemImage: "arrow.right.to.line") }
                        .help("Copy the current change to the right (⌥→)")
                        .disabled(model.currentChunk == nil)
                } label: { Label("Merge", systemImage: "arrow.left.arrow.right") }
            }
            ViewModeMenu(model: model)
            OptionsMenu(model: model)
            Button { model.swapSides() } label: { Label("Swap", systemImage: "arrow.left.arrow.right.circle") }
                .help("Swap sides (⌥⌘X)")
            Button { model.save() } label: { Label("Save", systemImage: "square.and.arrow.down") }
                .help("Save changes (⌘S)")
                .disabled(!model.hasUnsavedChanges)
        }
    }
}

/// What the aligned view shows: everything, changes with N lines of context, or changes only.
struct ViewModeMenu: View {
    @Bindable var model: TextCompareModel

    static let contextChoices = [1, 3, 5, 7, 10, 25]

    var body: some View {
        Menu {
            Picker("Show", selection: $model.viewMode) {
                Label("All Lines", systemImage: "text.alignleft").tag(ViewMode.all)
                Label("Changes Only", systemImage: "line.3.horizontal.decrease").tag(ViewMode.changesOnly)
            }
            .pickerStyle(.inline)
            Picker("Changes with Context", selection: $model.viewMode) {
                ForEach(Self.contextChoices, id: \.self) { n in
                    Text("± \(n) line\(n == 1 ? "" : "s")").tag(ViewMode.context(n))
                }
            }
            .pickerStyle(.inline)
            Button("Collapse All Expanded Sections") { model.collapseAll() }
                .disabled(!model.hasExpandedFolds)
            Divider()
            Picker("Highlight Changes Inside Lines", selection: $model.inlineGranularity) {
                ForEach(InlineGranularity.allCases, id: \.self) { Text($0.title).tag($0) }
            }
            .pickerStyle(.inline)
            Divider()
            Toggle("Show Whitespace", isOn: $model.showWhitespace)
            Toggle("Line Numbers", isOn: $model.showLineNumbers)
            Toggle("Syntax Highlighting", isOn: $model.showSyntax)
        } label: {
            Label("View", systemImage: model.viewMode == .all ? "eye" : "eye.trianglebadge.exclamationmark")
        }
        .help("Show all lines, or only the differences with some surrounding context (⌘1 / ⌘2 / ⌘3)")
    }
}

struct OptionsMenu: View {
    @Bindable var model: TextCompareModel

    var body: some View {
        Menu {
            Picker("Whitespace", selection: $model.options.whitespace) {
                ForEach(WhitespaceMode.allCases, id: \.self) { Text($0.title).tag($0) }
            }
            .pickerStyle(.inline)
            Divider()
            Toggle("Ignore Case", isOn: $model.options.ignoreCase)
            Toggle("Ignore Blank Lines", isOn: $model.options.ignoreBlankLines)
            Toggle("Ignore Numbers", isOn: $model.options.ignoreNumbers)
            Divider()
            Picker("Algorithm", selection: $model.options.algorithm) {
                Text("Patience (readable)").tag(DiffAlgorithm.patience)
                Text("Myers (minimal)").tag(DiffAlgorithm.myers)
            }
        } label: {
            Label("Options", systemImage: "slider.horizontal.3")
        }
        .help("Comparison options")
    }
}

// MARK: - Pane headers

struct PaneHeaders: View {
    var model: TextCompareModel

    var body: some View {
        HStack(spacing: DiffGridView.mergeGutterWidth) {
            ForEach(Array(model.sides.enumerated()), id: \.offset) { index, side in
                PaneHeader(model: model, side: side, index: index, count: model.sideCount)
            }
        }
        .padding(.trailing, 16)
        .background(Color(Theme.gutterBackground))
    }
}

struct PaneHeader: View {
    var model: TextCompareModel
    var side: TextSide
    var index: Int
    var count: Int
    @State private var dropTargeted = false

    private var subtitle: String {
        if let url = side.url { return url.deletingLastPathComponent().path.prettyPath }
        if let s = side.suggestedURL { return "Missing · " + s.path.prettyPath }
        return side.isEmpty ? "Paste text, type, or drop a file" : "Not saved"
    }

    var body: some View {
        let color = SideInfo.color(index, count: count)
        HStack(spacing: 10) {
            if let url = side.url {
                Image(nsImage: NSWorkspace.shared.icon(forFile: url.path))
                    .resizable()
                    .frame(width: 26, height: 26)
            } else {
                Image(systemName: side.suggestedURL != nil ? "doc.badge.ellipsis" : "doc.text")
                    .font(.system(size: 18, weight: .light))
                    .foregroundStyle(.secondary)
                    .frame(width: 26, height: 26)
            }
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(SideInfo.name(index, count: count).uppercased())
                        .font(.system(size: 8.5, weight: .heavy))
                        .tracking(0.5)
                        .foregroundStyle(.white)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1.5)
                        .background(color, in: RoundedRectangle(cornerRadius: 3.5, style: .continuous))
                    Text(side.title)
                        .font(.system(size: 13, weight: .semibold))
                        .lineLimit(1)
                        .truncationMode(.middle)
                    if side.isDirty && !side.isUntitled {
                        Text("EDITED")
                            .font(.system(size: 9, weight: .bold))
                            .tracking(0.4)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1.5)
                            .background(Color.orange.opacity(0.18), in: Capsule())
                            .foregroundStyle(.orange)
                    }
                }
                Text(subtitle)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.head)
            }
            Spacer(minLength: 6)
            HStack(spacing: 6) {
                if side.isUntitled && !side.isEmpty {
                    MetaChip(text: "\(side.lines.count.formatted()) lines")
                }
                if !side.isUntitled {
                    MetaChip(text: side.file.encoding.displayName)
                }
                if !side.isEmpty { MetaChip(text: side.file.lineEnding.rawValue) }
                if side.language.name != "Plain Text" { MetaChip(text: side.language.name) }
            }
            .layoutPriority(-1)
            if side.isEmpty {
                Button {
                    if let t = NSPasteboard.general.string(forType: .string) { model.replaceText(side: index, with: t) }
                } label: {
                    Image(systemName: "doc.on.clipboard")
                }
                .buttonStyle(.borderless)
                .help("Paste the clipboard into this pane")
            }
            // AppKit pop-up menu: a SwiftUI Menu here closed itself immediately on click.
            PaneMenuButton { paneMenuItems() }
                .frame(width: 22, height: 22)
                .help("More actions for this pane")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, minHeight: 50)
        .overlay(alignment: .top) {
            color.frame(height: 2.5)
        }
        .overlay {
            if dropTargeted {
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .strokeBorder(Color.accentColor, style: StrokeStyle(lineWidth: 2, dash: [5, 4]))
                    .background(Color.accentColor.opacity(0.08), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                    .padding(3)
            }
        }
        .contentShape(Rectangle())
        .dropDestination(for: URL.self) { urls, _ in
            guard let url = urls.first(where: { !$0.hasDirectoryPath }) else { return false }
            model.loadFile(url, into: index)
            return true
        } isTargeted: { dropTargeted = $0 }
        .help(side.url?.path ?? "Drop a file here to load it into this pane")
    }
}

extension PaneHeader {
    func paneMenuItems() -> [NSMenuItem] {
        var items: [NSMenuItem] = []
        let hasClipboard = NSPasteboard.general.string(forType: .string) != nil
        items.append(MenuAction(title: "Paste Clipboard into Pane", symbol: "doc.on.clipboard", enabled: hasClipboard) { [model, index] in
            if let t = NSPasteboard.general.string(forType: .string) { model.replaceText(side: index, with: t) }
        })
        items.append(MenuAction(title: "Copy Pane Text", symbol: "doc.on.doc", enabled: !side.isEmpty) { [model, index] in
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(model.sides[index].text, forType: .string)
        })
        items.append(MenuAction(title: "Clear Pane", symbol: "xmark.circle", enabled: !side.isEmpty) { [model, index] in
            model.replaceText(side: index, with: "")
        })
        items.append(.separator())
        items.append(MenuAction(title: "Open File into Pane…", symbol: "folder") { [model, index] in
            PaneFileChooser.choose(into: index, model: model)
        })
        items.append(MenuAction(title: side.isUntitled ? "Save…" : "Save As…", symbol: "square.and.arrow.down",
                                enabled: !(side.isEmpty && side.isUntitled)) { [model, index] in
            model.saveAs(side: index)
        })
        if let url = side.url {
            items.append(.separator())
            items.append(MenuAction(title: "Reveal in Finder", symbol: "finder") { NSWorkspace.shared.activateFileViewerSelecting([url]) })
            items.append(MenuAction(title: "Open in Default App", symbol: "arrow.up.forward.app") { NSWorkspace.shared.open(url) })
            items.append(MenuAction(title: "Copy Path", symbol: "link") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(url.path, forType: .string)
            })
        }
        return items
    }
}

/// Borderless "⋯" button that pops up an AppKit menu built on demand.
struct PaneMenuButton: NSViewRepresentable {
    var items: () -> [NSMenuItem]

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSButton {
        let image = NSImage(systemSymbolName: "ellipsis.circle", accessibilityDescription: "More")!
            .withSymbolConfiguration(.init(pointSize: 13, weight: .regular))!
        let b = NSButton(image: image, target: context.coordinator, action: #selector(Coordinator.show(_:)))
        b.isBordered = false
        b.imagePosition = .imageOnly
        b.contentTintColor = .secondaryLabelColor
        b.setButtonType(.momentaryChange)
        context.coordinator.items = items
        return b
    }

    func updateNSView(_ nsView: NSButton, context: Context) {
        context.coordinator.items = items
    }

    final class Coordinator: NSObject {
        var items: () -> [NSMenuItem] = { [] }

        @MainActor @objc func show(_ sender: NSButton) {
            let menu = NSMenu()
            menu.autoenablesItems = false
            for item in items() { menu.addItem(item) }
            let y = sender.isFlipped ? sender.bounds.height + 4 : -4
            menu.popUp(positioning: nil, at: NSPoint(x: 0, y: y), in: sender)
        }
    }
}

struct MetaChip: View {
    var text: String
    var body: some View {
        Text(text)
            .font(.system(size: 10, weight: .medium))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(Color.primary.opacity(0.06), in: Capsule())
            .lineLimit(1)
            .fixedSize()
    }
}

struct IdenticalBanner: View {
    var threeWay: Bool
    var scratch = false
    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "checkmark.seal.fill")
                .foregroundStyle(.green)
            Text(scratch ? (threeWay ? "All three texts are identical" : "Texts are identical")
                 : (threeWay ? "All three files are identical" : "Files are identical"))
                .font(.system(size: 13, weight: .semibold))
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 9)
        .background(.regularMaterial, in: Capsule())
        .overlay(Capsule().strokeBorder(.green.opacity(0.35)))
        .shadow(color: .black.opacity(0.12), radius: 10, y: 4)
    }
}

// MARK: - Status bar

struct TextStatusBar: View {
    var model: TextCompareModel

    private struct Stat: Identifiable {
        var id: String { label }
        var label: String
        var count: Int
        var color: NSColor
    }

    private var stats: [Stat] {
        let chunks = model.result.chunks
        func count(_ k: ChunkKind) -> Int { chunks.filter { $0.kind == k }.count }
        if model.isThreeWay {
            return [
                Stat(label: "left", count: count(.leftChanged), color: Theme.left3.accent),
                Stat(label: "right", count: count(.rightChanged), color: Theme.right3.accent),
                Stat(label: "both", count: count(.bothChanged), color: Theme.both3.accent),
                Stat(label: count(.conflict) == 1 ? "conflict" : "conflicts", count: count(.conflict), color: Theme.conflict.accent),
            ].filter { $0.count > 0 }
        }
        return [
            Stat(label: "changed", count: count(.modified), color: Theme.accent(for: .modified)),
            Stat(label: "removed", count: count(.deleted), color: Theme.removed.accent),
            Stat(label: "added", count: count(.inserted), color: Theme.added.accent),
        ].filter { $0.count > 0 }
    }

    var body: some View {
        HStack(spacing: 14) {
            if model.isComputing {
                ProgressView().controlSize(.mini)
            }
            Text(model.summary)
                .fontWeight(.medium)
            ForEach(stats) { s in
                HStack(spacing: 5) {
                    Circle().fill(Color(s.color)).frame(width: 7, height: 7)
                    Text("\(s.count) \(s.label)")
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
            if let c = model.currentChunk, c < model.result.chunks.count {
                let chunk = model.result.chunks[c]
                HStack(spacing: 5) {
                    RoundedRectangle(cornerRadius: 2).fill(Color(Theme.accent(for: chunk.kind))).frame(width: 8, height: 8)
                    Text("\(Theme.label(for: chunk.kind)) \(c + 1) of \(model.result.chunks.count)")
                }
                .foregroundStyle(.secondary)
            }
            if model.viewMode != .all && !model.isEditingText {
                Button {
                    model.viewMode = .all
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "line.3.horizontal.decrease.circle.fill")
                        Text(model.viewMode.shortTitle)
                    }
                    .foregroundStyle(Color.accentColor)
                }
                .buttonStyle(.plain)
                .help("Showing only differences. Click to show all lines.")
            }
            if model.isEditingText {
                Text("Editing as text · changes highlighted live")
                    .foregroundStyle(.secondary)
            }
            if optionsSummary.isEmpty == false {
                Text(optionsSummary)
                    .foregroundStyle(.tertiary)
            }
            Text(model.sides.map { "\($0.lines.count.formatted())" }.joined(separator: " · ") + " lines")
                .foregroundStyle(.tertiary)
                .monospacedDigit()
        }
        .font(.system(size: 11.5))
        .padding(.horizontal, 12)
        .frame(height: 26)
        .background(Color(Theme.gutterBackground))
    }

    private var optionsSummary: String {
        var parts: [String] = []
        if model.options.whitespace != .compare { parts.append("ignoring whitespace") }
        if model.options.ignoreCase { parts.append("ignoring case") }
        if model.options.ignoreBlankLines { parts.append("ignoring blank lines") }
        if model.options.ignoreNumbers { parts.append("ignoring numbers") }
        return parts.joined(separator: ", ")
    }
}

// MARK: - Grid bridge

struct DiffGridRepresentable: NSViewRepresentable {
    var model: TextCompareModel

    func makeNSView(context: Context) -> DiffGridContainer {
        let v = DiffGridContainer(frame: .zero)
        v.model = model
        context.coordinator.observe(v)
        DispatchQueue.main.async {
            if let c = model.currentChunk { v.scrollTo(chunk: c, animated: false) }
        }
        return v
    }

    func updateNSView(_ nsView: DiffGridContainer, context: Context) {
        if nsView.model !== model { nsView.model = model }
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator {
        private var token: NSObjectProtocol?
        func observe(_ v: DiffGridContainer) {
            token = NotificationCenter.default.addObserver(forName: .fontChanged, object: nil, queue: .main) { [weak v] _ in
                MainActor.assumeIsolated { v?.updateFont() }
            }
        }
        deinit { if let token { NotificationCenter.default.removeObserver(token) } }
    }
}

/// Test hook: FC_DEBUG_ACTIONS="copy 0 0 1; next; edit 1 3 text; save" drives the model after load.
enum DebugActions {
    @MainActor static func run(on model: TextCompareModel) async {
        guard let script = ProcessInfo.processInfo.environment["FC_DEBUG_ACTIONS"] else { return }
        try? await Task.sleep(for: .milliseconds(600))
        for command in script.split(separator: ";") {
            let parts = command.split(separator: " ").map(String.init)
            guard let op = parts.first else { continue }
            let n = parts.dropFirst().compactMap { Int($0) }
            switch op {
            case "copy" where n.count == 3: model.copy(chunk: n[0], from: n[1], to: n[2])
            case "next": model.next()
            case "prev": model.previous()
            case "edit" where n.count >= 2: model.editLine(side: n[0], line: n[1], text: parts.dropFirst(3).joined(separator: " "))
            case "undo": model.undo()
            case "redo": model.redo()
            case "delete" where n.count == 3: model.deleteLines(side: n[0], range: n[1]..<(n[1] + n[2]))
            case "copyall" where n.count == 2: model.copyAll(from: n[0], to: n[1])
            case "automerge": model.autoMerge()
            case "save": model.save()
            case "font+": Preferences.shared.fontSize += 2; NotificationCenter.default.post(name: .fontChanged, object: nil)
            case "view":
                switch parts.dropFirst().first {
                case "all": model.viewMode = .all
                case "changes": model.viewMode = .changesOnly
                case "context": model.viewMode = .context(n.first ?? 3)
                default: break
                }
            case "reveal" where n.count == 1:
                if n[0] < model.layout.count, case .fold(let r) = model.layout.items[n[0]] { model.reveal(r) }
            case "paste" where n.count >= 1:
                // paste <side> <text…>  ("\\n" becomes a newline)
                let raw = command.drop(while: { $0 == " " }).dropFirst(op.count + 1).drop(while: { $0 != " " }).dropFirst()
                let text = String(raw).replacingOccurrences(of: "\\n", with: "\n")
                model.replaceText(side: n[0], with: text)
            case "edit-mode": model.isEditingText = true
            case "ws": model.showWhitespace.toggle()
            case "numbers": model.showLineNumbers.toggle()
            case "inline":
                model.inlineGranularity = InlineGranularity(rawValue: parts.dropFirst().first ?? "") ?? .word
            case "collapse-all": model.collapseAll()
            case "type" where n.count >= 1:
                // type <side> <text…>: inserts at the cursor of that pane's editor, like real typing
                let raw = command.drop(while: { $0 == " " }).dropFirst(op.count + 1).drop(while: { $0 != " " }).dropFirst()
                model.editorHooks[n[0]]?.type(String(raw).replacingOccurrences(of: "\\n", with: "\n"))
            case "type-save" where n.count >= 1:
                // types and saves immediately (no debounce wait): checks pending text is not lost
                let raw = command.drop(while: { $0 == " " }).dropFirst(op.count + 1).drop(while: { $0 != " " }).dropFirst()
                model.editorHooks[n[0]]?.type(String(raw).replacingOccurrences(of: "\\n", with: "\n"))
                model.save()
            case "timed-type" where n.count >= 1:
                let start = Date()
                model.editorHooks[n[0]]?.type("x")
                model.flushEditors()
                FileHandle.standardError.write("timed-type: \(Int(Date().timeIntervalSince(start) * 1000)) ms\n".data(using: .utf8)!)
            case "diff-mode": model.isEditingText = false
            default: break
            }
            try? await Task.sleep(for: .milliseconds(400))
        }
    }
}
