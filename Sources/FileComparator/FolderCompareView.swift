import SwiftUI
import AppKit
import UniformTypeIdentifiers
import DiffCore

struct FolderCompareView: View {
    @Bindable var model: FolderCompareModel
    var window: WindowModel

    private let sideColumnWidth: CGFloat = 200
    private let statusWidth: CGFloat = 118

    var body: some View {
        VStack(spacing: 0) {
            rootHeaders
            Divider()
            filterBar
            Divider()
            columnHeader
            Divider()
            if model.root == nil {
                LoadingView(title: model.phase.isEmpty ? "Scanning" : model.phase, detail: model.roots.map(\.path).joined(separator: "  ↔  "))
            } else if model.rows.isEmpty {
                emptyState
            } else {
                list
            }
            Divider()
            statusBar
        }
        .task { await FolderDebugActions.run(on: model) }
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                Button {
                    if let node = model.selectedNode { model.open(node) }
                } label: {
                    Label("Show Differences", systemImage: "doc.text.magnifyingglass")
                }
                .help("Open the selected file to see what changed inside it (Return or double-click)")
                .disabled(model.selectedNode == nil || model.selectedNode?.presentSides.isEmpty == true)
                Button { model.expandAll() } label: { Label("Expand All", systemImage: "arrow.down.right.and.arrow.up.left") }
                    .help("Expand all folders")
                Button { model.collapseAll() } label: { Label("Collapse All", systemImage: "arrow.up.left.and.arrow.down.right") }
                    .help("Collapse all folders")
                folderOptionsMenu
                Button { model.rescan() } label: { Label("Rescan", systemImage: "arrow.clockwise") }
                    .help("Rescan folders (⌘R)")
            }
        }
    }

    // MARK: Header

    private var rootHeaders: some View {
        HStack(spacing: 10) {
            ForEach(Array(model.roots.enumerated()), id: \.offset) { i, url in
                let color = SideInfo.color(i, count: model.sideCount)
                HStack(spacing: 10) {
                    Image(nsImage: NSWorkspace.shared.icon(forFile: url.path))
                        .resizable()
                        .frame(width: 26, height: 26)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(url.lastPathComponent)
                            .font(.system(size: 13, weight: .semibold))
                            .lineLimit(1)
                        Text(url.deletingLastPathComponent().path.prettyPath)
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.head)
                    }
                    Spacer()
                    Text(SideInfo.name(i, count: model.sideCount).uppercased())
                        .font(.system(size: 9, weight: .heavy))
                        .tracking(0.5)
                        .foregroundStyle(color)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(color.opacity(0.14), in: Capsule())
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .frame(maxWidth: .infinity)
                .background(Color.primary.opacity(0.03), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                .overlay(alignment: .leading) {
                    UnevenRoundedRectangle(topLeadingRadius: 10, bottomLeadingRadius: 10).fill(color).frame(width: 3)
                }
                .help(url.path)
            }
        }
        .padding(10)
        .background(Color(Theme.gutterBackground))
    }

    private var filterBar: some View {
        HStack(spacing: 8) {
            ForEach(FolderFilter.allCases) { f in
                FilterChip(title: f.title, count: count(for: f), color: color(for: f), selected: model.filter == f) {
                    withAnimation(.easeOut(duration: 0.15)) { model.filter = f }
                }
            }
            Spacer()
            if model.isScanning {
                HStack(spacing: 8) {
                    if model.progress.total > 0 {
                        ProgressView(value: Double(model.progress.done), total: Double(max(model.progress.total, 1)))
                            .frame(width: 120)
                        Text("\(model.progress.done.formatted()) / \(model.progress.total.formatted())")
                            .monospacedDigit()
                    } else {
                        ProgressView().controlSize(.small)
                        Text(model.phase)
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            SearchField(text: $model.search)
                .frame(width: 220)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    private var columnHeader: some View {
        HStack(spacing: 0) {
            Text("Name")
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.leading, 34)
            ForEach(0..<model.sideCount, id: \.self) { i in
                HStack(spacing: 5) {
                    Circle().fill(SideInfo.color(i, count: model.sideCount)).frame(width: 6, height: 6)
                    Text(SideInfo.name(i, count: model.sideCount))
                    Spacer()
                    Text("Modified")
                }
                .frame(width: sideColumnWidth - 16)
                .padding(.horizontal, 8)
            }
            Text("Status")
                .frame(width: statusWidth, alignment: .leading)
                .padding(.leading, 6)
        }
        .font(.system(size: 11, weight: .semibold))
        .foregroundStyle(.secondary)
        .padding(.vertical, 5)
        .padding(.trailing, 12)
        .background(Color(Theme.gutterBackground))
    }

    private var list: some View {
        List(selection: $model.selection) {
            ForEach(model.rows) { row in
                FolderRowView(row: row, model: model, sideColumnWidth: sideColumnWidth, statusWidth: statusWidth,
                              expanded: model.expanded.contains(row.node.id), revision: model.revision)
                    .tag(row.id)
                    .listRowInsets(EdgeInsets(top: 0, leading: 4, bottom: 0, trailing: 4))
            }
        }
        .listStyle(.inset(alternatesRowBackgrounds: true))
        .environment(\.defaultMinListRowHeight, 26)
        .contextMenu(forSelectionType: String.self) { ids in
            contextMenu(for: ids)
        } primaryAction: { ids in
            for id in ids {
                if let row = model.rows.first(where: { $0.id == id }) { model.open(row.node) }
            }
        }
        .onKeyPress(.return) {
            if let id = model.selection.first, let row = model.rows.first(where: { $0.id == id }) {
                model.open(row.node)
                return .handled
            }
            return .ignored
        }
        .onKeyPress(.rightArrow) {
            for id in model.selection { if let r = model.rows.first(where: { $0.id == id }), r.node.isDirectory, !model.expanded.contains(id) { model.toggle(r.node) } }
            return .handled
        }
        .onKeyPress(.leftArrow) {
            for id in model.selection { if let r = model.rows.first(where: { $0.id == id }), r.node.isDirectory, model.expanded.contains(id) { model.toggle(r.node) } }
            return .handled
        }
    }

    @ViewBuilder
    private func contextMenu(for ids: Set<String>) -> some View {
        if let id = ids.first, let node = model.rows.first(where: { $0.id == id })?.node {
            Button(node.isDirectory ? "Compare Folders" : "Compare Files") { model.open(node) }
                .disabled(node.presentSides.count < 2)
            Divider()
            ForEach(0..<model.sideCount, id: \.self) { s in
                Button("Reveal \(SideInfo.name(s, count: model.sideCount)) in Finder") { model.reveal(node, side: s) }
                    .disabled(!node.isPresent(s))
            }
            Divider()
            ForEach(0..<model.sideCount, id: \.self) { from in
                ForEach(0..<model.sideCount, id: \.self) { to in
                    if from != to && (model.sideCount == 2 || abs(from - to) == 1) {
                        Button("Copy \(SideInfo.name(from, count: model.sideCount)) → \(SideInfo.name(to, count: model.sideCount))") {
                            model.copy(node, from: from, to: to)
                        }
                        .disabled(!node.isPresent(from))
                    }
                }
            }
            Divider()
            ForEach(0..<model.sideCount, id: \.self) { s in
                Button("Move \(SideInfo.name(s, count: model.sideCount)) Item to Trash", role: .destructive) { model.moveToTrash(node, side: s) }
                    .disabled(!node.isPresent(s))
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 10) {
            Image(systemName: model.filter == .differences ? "checkmark.seal" : "line.3.horizontal.decrease.circle")
                .font(.system(size: 40, weight: .light))
                .foregroundStyle(model.filter == .differences ? .green : .secondary)
            Text(model.filter == .differences && model.search.isEmpty ? "No differences" : "Nothing matches the current filter")
                .font(.title3.weight(.semibold))
            if model.filter == .differences && model.search.isEmpty {
                Text("The folders contain identical files.").foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var statusBar: some View {
        HStack(spacing: 14) {
            let c = model.counts
            Text("\(c.total.formatted()) files").fontWeight(.medium)
            dot(Theme.accent(for: .modified), "\(c.different.formatted()) changed")
            dot(Theme.left3.accent, "\(c.missing.formatted()) unique")
            dot(NSColor.systemGray, "\(c.identical.formatted()) identical")
            Spacer()
            Text("Double-click a file (or press Return) to see its differences")
                .foregroundStyle(.tertiary)
            if !model.isScanning && model.elapsed > 0 {
                Text("Compared in \(model.elapsed.formatted(.number.precision(.fractionLength(2))))s")
                    .foregroundStyle(.tertiary)
            }
            Text(model.options.compareContents ? "Byte-by-byte" : "Size & date")
                .foregroundStyle(.tertiary)
        }
        .font(.system(size: 11.5))
        .padding(.horizontal, 12)
        .frame(height: 26)
        .background(Color(Theme.gutterBackground))
    }

    private func dot(_ color: NSColor, _ text: String) -> some View {
        HStack(spacing: 5) {
            Circle().fill(Color(color)).frame(width: 7, height: 7)
            Text(text).foregroundStyle(.secondary)
        }
    }

    private var folderOptionsMenu: some View {
        Menu {
            Toggle("Compare File Contents", isOn: Binding(get: { model.options.compareContents },
                                                         set: { model.options.compareContents = $0; model.rescan() }))
            Toggle("Include Hidden Files", isOn: Binding(get: { model.options.includeHidden },
                                                        set: { model.options.includeHidden = $0; model.rescan() }))
            Divider()
            Toggle("Exclude Common Build & VCS Folders", isOn: Binding(
                get: { !model.options.excludedNames.isEmpty },
                set: { on in
                    model.options.excludedNames = on ? FolderCompareOptions().excludedNames : []
                    model.rescan()
                }))
        } label: {
            Label("Options", systemImage: "slider.horizontal.3")
        }
    }

    private func count(for f: FolderFilter) -> Int? {
        let c = model.counts
        switch f {
        case .all: return c.total
        case .differences: return c.different + c.missing
        case .different: return c.different
        case .missing: return c.missing
        case .identical: return c.identical
        }
    }

    private func color(for f: FolderFilter) -> Color {
        switch f {
        case .all: return .accentColor
        case .differences: return Color(Theme.conflict.accent)
        case .different: return Color(Theme.accent(for: .modified))
        case .missing: return Color(Theme.left3.accent)
        case .identical: return .gray
        }
    }
}

struct FilterChip: View {
    var title: String
    var count: Int?
    var color: Color
    var selected: Bool
    var action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Text(title)
                if let count {
                    Text(count.formatted())
                        .font(.system(size: 10.5, weight: .bold))
                        .monospacedDigit()
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .background(selected ? Color.white.opacity(0.25) : color.opacity(0.15), in: Capsule())
                        .foregroundStyle(selected ? .white : color)
                }
            }
            .font(.system(size: 12, weight: .medium))
            .padding(.horizontal, 10)
            .padding(.vertical, 4.5)
            .background {
                Capsule().fill(selected ? AnyShapeStyle(color.gradient) : AnyShapeStyle(Color.primary.opacity(hovering ? 0.09 : 0.05)))
            }
            .foregroundStyle(selected ? .white : .primary)
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}

struct SearchField: NSViewRepresentable {
    @Binding var text: String

    func makeNSView(context: Context) -> NSSearchField {
        let f = NSSearchField()
        f.placeholderString = "Filter by name"
        f.delegate = context.coordinator
        f.controlSize = .regular
        return f
    }

    func updateNSView(_ nsView: NSSearchField, context: Context) {
        if nsView.stringValue != text { nsView.stringValue = text }
    }

    func makeCoordinator() -> Coordinator { Coordinator(text: $text) }

    final class Coordinator: NSObject, NSSearchFieldDelegate {
        var text: Binding<String>
        init(text: Binding<String>) { self.text = text }
        func controlTextDidChange(_ obj: Notification) {
            if let f = obj.object as? NSSearchField { text.wrappedValue = f.stringValue }
        }
    }
}

// MARK: - Row

enum IconCache {
    @MainActor private static var cache: [String: NSImage] = [:]

    @MainActor static func icon(for node: FolderNode) -> NSImage {
        let key = node.isDirectory ? "/dir" : (node.name as NSString).pathExtension.lowercased()
        if let i = cache[key] { return i }
        let img: NSImage
        if node.isDirectory {
            img = NSWorkspace.shared.icon(for: .folder)
        } else if let t = UTType(filenameExtension: key) {
            img = NSWorkspace.shared.icon(for: t)
        } else {
            img = NSWorkspace.shared.icon(for: .data)
        }
        cache[key] = img
        return img
    }
}

struct FolderRowView: View {
    var row: FolderRow
    var model: FolderCompareModel
    var sideColumnWidth: CGFloat
    var statusWidth: CGFloat
    var expanded: Bool
    var revision: Int
    @State private var hovering = false

    private static let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .short
        f.timeStyle = .short
        f.doesRelativeDateFormatting = true
        return f
    }()

    var body: some View {
        let node = row.node
        HStack(spacing: 0) {
            HStack(spacing: 5) {
                Color.clear.frame(width: CGFloat(row.depth) * 16, height: 1)
                if node.isDirectory {
                    Button {
                        withAnimation(.easeOut(duration: 0.12)) { model.toggle(node) }
                    } label: {
                        Image(systemName: "chevron.right")
                            .font(.system(size: 9.5, weight: .bold))
                            .rotationEffect(.degrees(expanded ? 90 : 0))
                            .frame(width: 14, height: 14)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                } else {
                    Color.clear.frame(width: 14, height: 14)
                }
                Image(nsImage: IconCache.icon(for: node))
                    .resizable()
                    .frame(width: 17, height: 17)
                    .opacity(node.status == .missing ? 0.7 : 1)
                Text(node.name)
                    .font(.system(size: 12.5, weight: node.status == .different ? .semibold : .regular))
                    .foregroundStyle(nameColor(node))
                    .lineLimit(1)
                    .truncationMode(.middle)
                if node.isDirectory && (node.differentCount + node.missingCount) > 0 {
                    Text("\(node.differentCount + node.missingCount)")
                        .font(.system(size: 9.5, weight: .bold))
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 0.5)
                        .background(Color.primary.opacity(0.07), in: Capsule())
                }
                Spacer(minLength: 4)
                if hovering && !node.isDirectory && !node.presentSides.isEmpty {
                    Button {
                        model.open(node)
                    } label: {
                        HStack(spacing: 3) {
                            Image(systemName: "doc.text.magnifyingglass")
                            Text(node.presentSides.count == model.sideCount ? "Compare" : "View")
                        }
                        .font(.system(size: 10.5, weight: .semibold))
                        .padding(.horizontal, 7)
                        .padding(.vertical, 2)
                        .background(Color.accentColor.opacity(0.14), in: Capsule())
                        .foregroundStyle(Color.accentColor)
                        .contentShape(Capsule())
                    }
                    .buttonStyle(.plain)
                    .help("Show the differences inside this file")
                    .padding(.trailing, 6)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            ForEach(0..<model.sideCount, id: \.self) { s in
                sideCell(node, side: s)
                    .frame(width: sideColumnWidth - 16)
                    .padding(.horizontal, 8)
            }
            StatusBadge(node: node, sideCount: model.sideCount)
                .frame(width: statusWidth, alignment: .leading)
                .padding(.leading, 6)
        }
        .frame(height: 24)
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
    }

    private func nameColor(_ node: FolderNode) -> Color {
        switch node.status {
        case .identical: return .primary.opacity(0.75)
        case .different: return .primary
        case .missing:
            if let s = node.presentSides.first, node.presentSides.count == 1 { return SideInfo.color(s, count: model.sideCount) }
            return .primary
        case .error: return .red
        case .pending: return .secondary
        }
    }

    @ViewBuilder
    private func sideCell(_ node: FolderNode, side: Int) -> some View {
        if let meta = node.metas[side] {
            HStack(spacing: 6) {
                if !node.isDirectory {
                    Text(ByteCountFormatter.string(fromByteCount: meta.size, countStyle: .file))
                        .monospacedDigit()
                        .frame(width: 66, alignment: .trailing)
                }
                Spacer(minLength: 2)
                if let d = meta.modified {
                    Text(Self.dateFormatter.string(from: d))
                        .lineLimit(1)
                }
            }
            .font(.system(size: 11))
            .foregroundStyle(.secondary)
        } else {
            HStack {
                Rectangle()
                    .fill(Color.primary.opacity(0.12))
                    .frame(height: 1)
                    .frame(maxWidth: 40)
                Spacer()
            }
        }
    }
}

struct StatusBadge: View {
    var node: FolderNode
    var sideCount: Int

    var body: some View {
        let (text, symbol, color) = descriptor
        HStack(spacing: 4) {
            if node.status == .pending {
                ProgressView().controlSize(.mini)
            } else {
                Image(systemName: symbol)
                    .font(.system(size: 10, weight: .bold))
            }
            Text(text)
                .font(.system(size: 11, weight: .medium))
                .lineLimit(1)
        }
        .foregroundStyle(color)
        .padding(.horizontal, 7)
        .padding(.vertical, 2.5)
        .background(color.opacity(node.status == .identical ? 0.0 : 0.12), in: Capsule())
    }

    private var descriptor: (String, String, Color) {
        switch node.status {
        case .identical:
            return ("Identical", "equal", .secondary)
        case .different:
            return (node.isDirectory ? "Has changes" : "Changed", "circle.lefthalf.filled", Color(Theme.accent(for: .modified)))
        case .missing:
            let present = node.presentSides
            if present.count == 1 {
                return ("\(SideInfo.name(present[0], count: sideCount)) only", "plus.circle.fill", SideInfo.color(present[0], count: sideCount))
            }
            let missing = (0..<sideCount).filter { !present.contains($0) }
            return ("Not in \(missing.map { SideInfo.name($0, count: sideCount) }.joined(separator: ", "))", "minus.circle.fill", Color(Theme.conflict.accent))
        case .pending:
            return ("Comparing", "clock", .secondary)
        case .error:
            return ("Unreadable", "exclamationmark.triangle.fill", .red)
        }
    }
}

/// Test hook: FC_DEBUG_FOLDER="open sub/file.txt; back" drives the folder model after the scan.
enum FolderDebugActions {
    @MainActor private static var started = false

    @MainActor static func run(on model: FolderCompareModel) async {
        guard let script = ProcessInfo.processInfo.environment["FC_DEBUG_FOLDER"], !started else { return }
        started = true
        // Unstructured task: navigating away cancels the view's .task, but the script must go on.
        Task { @MainActor in await perform(script, on: model) }
    }

    @MainActor private static func perform(_ script: String, on model: FolderCompareModel) async {
        for _ in 0..<50 where model.isScanning || model.root == nil { try? await Task.sleep(for: .milliseconds(100)) }
        try? await Task.sleep(for: .milliseconds(500))
        for command in script.split(separator: ";") {
            let parts = command.trimmingCharacters(in: .whitespaces).split(separator: " ", maxSplits: 1).map(String.init)
            switch parts.first {
            case "open" where parts.count == 2:
                if let n = model.node(atPath: parts[1]) { model.open(n) }
            case "select" where parts.count == 2:
                if let n = model.node(atPath: parts[1]) { model.selection = [n.id] }
            case "back": model.window?.goBack()
            case "forward": model.window?.goForward()
            default: break
            }
            try? await Task.sleep(for: .milliseconds(900))
        }
    }
}
