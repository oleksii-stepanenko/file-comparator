import SwiftUI
import AppKit
import UniformTypeIdentifiers

struct WelcomeView: View {
    @Bindable var window: WindowModel
    @State private var slots: [URL?] = [nil, nil, nil]
    @State private var threeWay = false
    @State private var recents: [RecentComparison] = Preferences.shared.recents
    @State private var windowDropTargeted = false

    private var activeSlots: [Int] { threeWay ? [0, 1, 2] : [0, 2] }
    private var ready: Bool { activeSlots.allSatisfy { slots[$0] != nil } }
    /// Some slots are empty but the filled ones are files: compare against blank panes.
    private var partialReady: Bool {
        let filled = activeSlots.compactMap { slots[$0] }
        return !filled.isEmpty && filled.count < activeSlots.count && filled.allSatisfy { !$0.hasDirectoryPath && !isDirectory($0) }
    }

    private func isDirectory(_ url: URL) -> Bool {
        var d: ObjCBool = false
        return FileManager.default.fileExists(atPath: url.path, isDirectory: &d) && d.boolValue
    }

    private func compare() {
        if ready {
            window.open(activeSlots.compactMap { slots[$0] })
        } else if partialReady {
            let s = activeSlots.map { slots[$0] }
            window.open(slots: s, missing: s.enumerated().map { i, u in u == nil ? ("Untitled \(slotTitle(activeSlots[i]))", nil) : nil })
        }
    }

    var body: some View {
        ZStack {
            WelcomeBackground()
            ScrollView {
                VStack(spacing: 30) {
                    header
                    VStack(spacing: 18) {
                        modePicker
                        slotRow
                        actionRow
                    }
                    .padding(22)
                    .background {
                        RoundedRectangle(cornerRadius: 22, style: .continuous)
                            .fill(.regularMaterial)
                            .shadow(color: .black.opacity(0.08), radius: 24, y: 10)
                    }
                    .overlay {
                        RoundedRectangle(cornerRadius: 22, style: .continuous)
                            .strokeBorder(.primary.opacity(0.06))
                    }
                    if !recents.isEmpty { recentList }
                    tips
                }
                .frame(maxWidth: 920)
                .padding(.horizontal, 40)
                .padding(.vertical, 36)
                .frame(maxWidth: .infinity)
            }
        }
        .dropDestination(for: URL.self) { urls, _ in
            fill(with: urls, from: nil)
            return true
        } isTargeted: { windowDropTargeted = $0 }
        .onReceive(NotificationCenter.default.publisher(for: .recentsChanged)) { _ in
            recents = Preferences.shared.recents
        }
        .onChange(of: window.prefill) { _, urls in
            if !urls.isEmpty { fill(with: urls, from: nil); window.prefill = [] }
        }
        .onAppear {
            if !window.prefill.isEmpty { fill(with: window.prefill, from: nil); window.prefill = [] }
        }
    }

    // MARK: Sections

    private var header: some View {
        VStack(spacing: 14) {
            AppGlyph(size: 74)
            Text("FileComparator")
                .font(.system(size: 34, weight: .bold, design: .rounded))
            Text("Compare and merge files, folders and images — side by side or three-way.")
                .font(.title3)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .padding(.top, 8)
    }

    private var modePicker: some View {
        HStack {
            Picker("", selection: $threeWay.animation(.spring(response: 0.35, dampingFraction: 0.85))) {
                Label("Two-way", systemImage: "rectangle.split.2x1").tag(false)
                Label("Three-way merge", systemImage: "rectangle.split.3x1").tag(true)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(width: 330)
            Spacer()
            Button {
                choose(startingAt: 0, multiple: true)
            } label: {
                Label("Choose Files…", systemImage: "folder")
            }
            .buttonStyle(.borderless)
        }
    }

    private var slotRow: some View {
        HStack(spacing: 14) {
            ForEach(activeSlots, id: \.self) { index in
                DropSlot(
                    title: slotTitle(index),
                    color: slotColor(index),
                    url: slots[index],
                    onDrop: { urls in fill(with: urls, from: index) },
                    onChoose: { choose(startingAt: index, multiple: false) },
                    onClear: { slots[index] = nil }
                )
                .transition(.asymmetric(insertion: .scale(scale: 0.9).combined(with: .opacity), removal: .opacity))
                if index != activeSlots.last {
                    Image(systemName: "arrow.left.arrow.right")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.tertiary)
                }
            }
        }
    }

    private var actionRow: some View {
        HStack(spacing: 12) {
            Button {
                swap()
            } label: {
                Label("Swap", systemImage: "arrow.left.arrow.right")
            }
            .disabled(slots.allSatisfy { $0 == nil })
            Button("Clear") { slots = [nil, nil, nil] }
                .disabled(slots.allSatisfy { $0 == nil })
            Spacer()
            Text(hint)
                .font(.callout)
                .foregroundStyle(.secondary)
            Button {
                window.openBlank(count: threeWay ? 3 : 2)
            } label: {
                Label("Paste Text", systemImage: "doc.on.clipboard")
                    .padding(.horizontal, 4)
                    .padding(.vertical, 3)
            }
            .controlSize(.large)
            .help("Start with empty panes and paste or type the texts to compare (⇧⌘N)")
            Button {
                compare()
            } label: {
                Label("Compare", systemImage: "play.fill")
                    .padding(.horizontal, 10)
                    .padding(.vertical, 3)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .keyboardShortcut(.return, modifiers: .command)
            .disabled(!ready && !partialReady)
        }
    }

    private var hint: String {
        let missing = activeSlots.filter { slots[$0] == nil }.count
        if missing == 0 { return "Ready  ⌘↩" }
        if partialReady { return "Empty slots open as blank panes" }
        return "Add files, or paste text"
    }

    private var recentList: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Recent Comparisons")
                    .font(.headline)
                Spacer()
                Button("Clear") { Preferences.shared.clearRecents() }
                    .buttonStyle(.borderless)
                    .font(.callout)
            }
            LazyVGrid(columns: [GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12)], spacing: 10) {
                ForEach(recents.prefix(8)) { item in
                    RecentCard(item: item) {
                        window.open(item.urls)
                    } onRemove: {
                        Preferences.shared.removeRecent(item)
                    }
                }
            }
        }
    }

    private var tips: some View {
        HStack(spacing: 22) {
            TipLabel(symbol: "hand.draw", text: "Drop items anywhere")
            TipLabel(symbol: "keyboard", text: "⌥↑ ⌥↓ jump between changes")
            TipLabel(symbol: "terminal", text: "fcompare a b [c]")
        }
        .font(.callout)
        .foregroundStyle(.secondary)
    }

    // MARK: Helpers

    private func slotTitle(_ i: Int) -> String {
        threeWay ? ["Left", "Base", "Right"][i] : (i == 0 ? "Left" : "Right")
    }

    private func slotColor(_ i: Int) -> Color {
        threeWay ? SideInfo.color(i, count: 3) : SideInfo.color(i == 0 ? 0 : 1, count: 2)
    }

    /// Fills slots from dropped/chosen URLs. `index == nil` means "dropped on the window".
    private func fill(with urls: [URL], from index: Int?) {
        guard !urls.isEmpty else { return }
        if urls.count >= 3 && !threeWay {
            withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) { threeWay = true }
        }
        let order = threeWay ? [0, 1, 2] : [0, 2]
        if urls.count >= 2 {
            for (k, u) in urls.prefix(order.count).enumerated() { slots[order[k]] = u }
            if ready { window.open(activeSlots.compactMap { slots[$0] }) }
        } else if let index {
            slots[index] = urls[0]
        } else {
            let target = order.first { slots[$0] == nil } ?? order.last!
            slots[target] = urls[0]
        }
    }

    private func choose(startingAt index: Int, multiple: Bool) {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = multiple
        panel.prompt = "Choose"
        panel.message = multiple ? "Select two or three files or folders" : "Select a file or folder"
        guard panel.runModal() == .OK else { return }
        if multiple && panel.urls.count >= 2 {
            fill(with: panel.urls, from: nil)
        } else if let u = panel.urls.first {
            slots[index] = u
        }
    }

    private func swap() {
        slots.swapAt(0, 2)
    }
}

// MARK: - Components

struct DropSlot: View {
    var title: String
    var color: Color
    var url: URL?
    var onDrop: ([URL]) -> Void
    var onChoose: () -> Void
    var onClear: () -> Void
    @State private var targeted = false
    @State private var hovering = false

    var body: some View {
        VStack(spacing: 10) {
            if let url {
                Image(nsImage: NSWorkspace.shared.icon(forFile: url.path))
                    .resizable()
                    .interpolation(.high)
                    .frame(width: 56, height: 56)
                    .shadow(color: .black.opacity(0.12), radius: 4, y: 2)
                Text(url.lastPathComponent)
                    .font(.headline)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(url.deletingLastPathComponent().path.prettyPath)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.head)
            } else {
                ZStack {
                    Circle().fill(color.opacity(0.12)).frame(width: 56, height: 56)
                    Image(systemName: targeted ? "arrow.down.circle.fill" : "plus")
                        .font(.system(size: 22, weight: .semibold))
                        .foregroundStyle(color)
                }
                Text("Drop a file or folder")
                    .font(.headline)
                    .foregroundStyle(.primary.opacity(0.8))
                Button("Choose…", action: onChoose)
                    .buttonStyle(.link)
                    .font(.callout)
            }
        }
        .padding(.horizontal, 14)
        .padding(.top, 26)
        .padding(.bottom, 16)
        .frame(maxWidth: .infinity, minHeight: 186)
        .background {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(targeted ? color.opacity(0.10) : Color(nsColor: .textBackgroundColor).opacity(url == nil ? 0.45 : 0.9))
        }
        .overlay {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(targeted ? color : (url == nil ? Color.secondary.opacity(0.35) : color.opacity(0.45)),
                              style: StrokeStyle(lineWidth: targeted ? 2 : 1.3, dash: url == nil && !targeted ? [6, 5] : []))
        }
        .overlay(alignment: .topLeading) {
            Text(title.uppercased())
                .font(.system(size: 10, weight: .bold))
                .tracking(0.6)
                .foregroundStyle(color)
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(color.opacity(0.14), in: Capsule())
                .padding(10)
        }
        .overlay(alignment: .topTrailing) {
            if url != nil && hovering {
                HStack(spacing: 4) {
                    Button(action: onChoose) { Image(systemName: "folder") }
                        .help("Choose another item")
                    Button(action: onClear) { Image(systemName: "xmark") }
                        .help("Clear")
                }
                .buttonStyle(.borderless)
                .font(.system(size: 11, weight: .semibold))
                .padding(10)
            }
        }
        .scaleEffect(targeted ? 1.02 : 1)
        .animation(.spring(response: 0.3, dampingFraction: 0.7), value: targeted)
        .onHover { hovering = $0 }
        .onTapGesture(count: 2) { onChoose() }
        .dropDestination(for: URL.self) { urls, _ in
            onDrop(urls)
            return true
        } isTargeted: { targeted = $0 }
        .contentShape(Rectangle())
    }
}

struct RecentCard: View {
    var item: RecentComparison
    var onOpen: () -> Void
    var onRemove: () -> Void
    @State private var hovering = false

    private var symbol: String {
        switch item.kind {
        case "folder": return "folder.fill"
        case "image": return "photo.fill"
        case "binary": return "cpu"
        default: return item.paths.count == 3 ? "rectangle.split.3x1.fill" : "doc.text.fill"
        }
    }

    private var tint: Color {
        switch item.kind {
        case "folder": return .blue
        case "image": return .pink
        case "binary": return .gray
        default: return item.paths.count == 3 ? .purple : .orange
        }
    }

    var body: some View {
        Button(action: onOpen) {
            HStack(spacing: 12) {
                Image(systemName: symbol)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 34, height: 34)
                    .background(tint.gradient, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                VStack(alignment: .leading, spacing: 2) {
                    Text(item.title)
                        .font(.system(size: 13, weight: .semibold))
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Text(commonParent)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.head)
                }
                Spacer(minLength: 4)
                Text(item.date, format: .relative(presentation: .named))
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
            .padding(10)
            .background {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(hovering ? Color.primary.opacity(0.07) : Color.primary.opacity(0.035))
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .contextMenu {
            Button("Open Comparison", action: onOpen)
            Button("Reveal in Finder") {
                NSWorkspace.shared.activateFileViewerSelecting(item.urls)
            }
            Divider()
            Button("Remove from Recents", role: .destructive, action: onRemove)
        }
        .help(item.paths.joined(separator: "\n"))
    }

    private var commonParent: String {
        let parents = item.paths.map { ($0 as NSString).deletingLastPathComponent }
        let home = NSHomeDirectory()
        if Set(parents).count == 1 { return parents[0].replacingOccurrences(of: home, with: "~") }
        return parents.map { ($0 as NSString).lastPathComponent }.joined(separator: " · ")
    }
}

struct TipLabel: View {
    var symbol: String
    var text: String
    var body: some View {
        Label(text, systemImage: symbol)
            .labelStyle(.titleAndIcon)
    }
}

/// The app's glyph: three offset "pages" with diff stripes.
struct AppGlyph: View {
    var size: CGFloat

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: size * 0.24, style: .continuous)
                .fill(LinearGradient(colors: [Color(red: 0.29, green: 0.42, blue: 0.98), Color(red: 0.55, green: 0.33, blue: 0.95)],
                                     startPoint: .topLeading, endPoint: .bottomTrailing))
                .shadow(color: Color(red: 0.4, green: 0.35, blue: 0.95).opacity(0.35), radius: size * 0.16, y: size * 0.08)
            HStack(spacing: size * 0.07) {
                page(stripes: [(0.9, Color.white.opacity(0.85)), (0.6, Color(red: 1, green: 0.45, blue: 0.5)), (0.75, Color.white.opacity(0.85)), (0.5, Color.white.opacity(0.85))])
                page(stripes: [(0.9, Color.white.opacity(0.85)), (0.7, Color(red: 0.35, green: 0.9, blue: 0.55)), (0.75, Color.white.opacity(0.85)), (0.85, Color(red: 0.35, green: 0.9, blue: 0.55))])
            }
            .padding(size * 0.18)
        }
        .frame(width: size, height: size)
    }

    private func page(stripes: [(CGFloat, Color)]) -> some View {
        VStack(alignment: .leading, spacing: size * 0.06) {
            ForEach(Array(stripes.enumerated()), id: \.offset) { _, s in
                Capsule()
                    .fill(s.1)
                    .frame(width: size * 0.26 * s.0, height: size * 0.055)
            }
        }
        .padding(size * 0.05)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Color.white.opacity(0.16), in: RoundedRectangle(cornerRadius: size * 0.07, style: .continuous))
    }
}

struct WelcomeBackground: View {
    var body: some View {
        ZStack {
            Color(nsColor: .windowBackgroundColor)
            RadialGradient(colors: [Color(red: 0.36, green: 0.45, blue: 1).opacity(0.16), .clear],
                           center: .init(x: 0.15, y: 0.0), startRadius: 0, endRadius: 600)
            RadialGradient(colors: [Color(red: 0.7, green: 0.35, blue: 0.95).opacity(0.12), .clear],
                           center: .init(x: 0.95, y: 0.15), startRadius: 0, endRadius: 520)
            RadialGradient(colors: [Color(red: 0.2, green: 0.8, blue: 0.6).opacity(0.08), .clear],
                           center: .init(x: 0.5, y: 1.05), startRadius: 0, endRadius: 600)
        }
        .ignoresSafeArea()
    }
}
