import SwiftUI
import AppKit
import DiffCore

// MARK: - Images

struct ImageCompareView: View {
    @Bindable var model: ImageCompareModel
    var window: WindowModel
    @State private var zoom: CGFloat = 1

    var body: some View {
        VStack(spacing: 0) {
            infoBar
            Divider()
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Checkerboard().opacity(0.6))
            Divider()
            bottomBar
        }
        .toolbar {
            ToolbarItem(placement: .principal) {
                Picker("Mode", selection: $model.mode) {
                    ForEach(ImageCompareModel.Mode.allCases) { m in
                        Label(m.rawValue, systemImage: m.symbol).tag(m)
                    }
                }
                .pickerStyle(.segmented)
                .help("Comparison mode")
            }
            ToolbarItemGroup(placement: .primaryAction) {
                if model.urls.count == 3 && model.mode != .sideBySide {
                    Picker("Pair", selection: $model.pairIndex) {
                        Text("Left ↔ Base").tag(0)
                        Text("Base ↔ Right").tag(1)
                    }
                    .onChange(of: model.pairIndex) { _, _ in model.compute() }
                }
                Button { window.reopen(model.urls.reversed()) } label: { Label("Swap", systemImage: "arrow.left.arrow.right.circle") }
            }
        }
    }

    private var infoBar: some View {
        HStack(spacing: 10) {
            ForEach(Array(model.urls.enumerated()), id: \.offset) { i, url in
                let color = SideInfo.color(i, count: model.urls.count)
                HStack(spacing: 8) {
                    Circle().fill(color).frame(width: 8, height: 8)
                    Text(url.lastPathComponent).font(.system(size: 12.5, weight: .semibold)).lineLimit(1)
                    Spacer()
                    if let s = model.pixelSize(i) {
                        MetaChip(text: "\(Int(s.width)) × \(Int(s.height))")
                    }
                    MetaChip(text: ByteCountFormatter.string(fromByteCount: model.fileSize(i), countStyle: .file))
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .frame(maxWidth: .infinity)
                .background(Color.primary.opacity(0.03), in: RoundedRectangle(cornerRadius: 9))
            }
        }
        .padding(10)
        .background(Color(Theme.gutterBackground))
    }

    @ViewBuilder
    private var content: some View {
        let (a, b) = model.overlayPair
        switch model.mode {
        case .sideBySide:
            HStack(spacing: 1) {
                ForEach(0..<model.urls.count, id: \.self) { i in
                    imageView(i)
                        .padding(16)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
        case .swipe:
            GeometryReader { geo in
                ZStack {
                    imageView(b)
                    imageView(a)
                        .mask(alignment: .leading) {
                            Rectangle().frame(width: geo.size.width * model.swipe)
                        }
                    Rectangle()
                        .fill(Color.white)
                        .frame(width: 2)
                        .shadow(radius: 3)
                        .overlay(
                            Circle().fill(.white).frame(width: 26, height: 26).shadow(radius: 3)
                                .overlay(Image(systemName: "arrow.left.and.right").font(.system(size: 11, weight: .bold)).foregroundStyle(.black.opacity(0.7)))
                        )
                        .position(x: geo.size.width * model.swipe, y: geo.size.height / 2)
                }
                .contentShape(Rectangle())
                .gesture(DragGesture(minimumDistance: 0).onChanged { v in
                    model.swipe = min(1, max(0, v.location.x / geo.size.width))
                })
            }
            .padding(16)
        case .onion:
            ZStack {
                imageView(a)
                imageView(b).opacity(model.opacity)
            }
            .padding(16)
        case .difference:
            if let img = model.differenceImage {
                Image(nsImage: img)
                    .resizable()
                    .interpolation(.none)
                    .aspectRatio(contentMode: .fit)
                    .padding(16)
            } else {
                ProgressView()
            }
        }
    }

    @ViewBuilder
    private func imageView(_ i: Int) -> some View {
        if let img = model.images[i] {
            Image(nsImage: img)
                .resizable()
                .interpolation(.high)
                .aspectRatio(contentMode: .fit)
                .scaleEffect(zoom)
                .shadow(color: .black.opacity(0.15), radius: 6, y: 2)
        } else {
            Label("Cannot decode image", systemImage: "exclamationmark.triangle")
                .foregroundStyle(.secondary)
        }
    }

    private var bottomBar: some View {
        HStack(spacing: 16) {
            if let same = model.identicalBytes, same {
                Label("Images are identical (byte-for-byte)", systemImage: "checkmark.seal.fill")
                    .foregroundStyle(.green)
            } else if let p = model.differencePercent {
                Label(p < 0.0001 ? "Pixels are identical (files differ in metadata)" : "\(p.formatted(.number.precision(.fractionLength(2))))% of pixels differ",
                      systemImage: p < 0.0001 ? "checkmark.circle" : "circle.lefthalf.filled")
                    .foregroundStyle(p < 0.0001 ? .green : Color(Theme.conflict.accent))
            } else {
                ProgressView().controlSize(.mini)
                Text("Analyzing…").foregroundStyle(.secondary)
            }
            Spacer()
            if model.mode == .swipe {
                Slider(value: $model.swipe, in: 0...1) { Text("Swipe") }.frame(width: 220)
            } else if model.mode == .onion {
                Slider(value: $model.opacity, in: 0...1) { Text("Opacity") }.frame(width: 220)
            }
            Slider(value: $zoom, in: 0.25...4) { Image(systemName: "plus.magnifyingglass") }
                .frame(width: 160)
                .disabled(model.mode == .difference)
        }
        .font(.system(size: 11.5))
        .padding(.horizontal, 12)
        .frame(height: 34)
        .background(Color(Theme.gutterBackground))
    }
}

struct Checkerboard: View {
    var body: some View {
        Canvas { ctx, size in
            let s: CGFloat = 10
            let light = Color(nsColor: .dynamic(0xFFFFFF, 0x26272C))
            let dark = Color(nsColor: .dynamic(0xF0F1F4, 0x1F2024))
            ctx.fill(Path(CGRect(origin: .zero, size: size)), with: .color(light))
            var y: CGFloat = 0
            var row = 0
            while y < size.height {
                var x: CGFloat = row % 2 == 0 ? 0 : s
                while x < size.width {
                    ctx.fill(Path(CGRect(x: x, y: y, width: s, height: s)), with: .color(dark))
                    x += s * 2
                }
                y += s
                row += 1
            }
        }
    }
}

// MARK: - Binary

struct BinaryCompareView: View {
    var model: BinaryCompareModel
    var window: WindowModel

    var body: some View {
        VStack(spacing: 0) {
            summary
            Divider()
            hexView
        }
        .background(Color(Theme.editorBackground))
    }

    private var summary: some View {
        VStack(spacing: 14) {
            HStack(spacing: 12) {
                Image(systemName: model.identical ? "checkmark.seal.fill" : "exclamationmark.circle.fill")
                    .font(.system(size: 30))
                    .foregroundStyle(model.identical ? .green : Color(Theme.conflict.accent))
                VStack(alignment: .leading, spacing: 3) {
                    Text(model.identical ? "Binary files are identical" : "Binary files differ")
                        .font(.title2.weight(.semibold))
                    if let off = model.firstDifference, !model.identical {
                        Text("First difference at offset 0x\(String(off, radix: 16, uppercase: true)) (\(off.formatted()))")
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer()
            }
            HStack(spacing: 10) {
                ForEach(Array(model.urls.enumerated()), id: \.offset) { i, url in
                    let info = model.infos[i]
                    HStack(spacing: 10) {
                        Image(nsImage: NSWorkspace.shared.icon(forFile: url.path)).resizable().frame(width: 30, height: 30)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(url.lastPathComponent).font(.system(size: 13, weight: .semibold)).lineLimit(1)
                            Text("\(ByteCountFormatter.string(fromByteCount: info.size, countStyle: .file)) · \(info.size.formatted()) bytes")
                                .font(.caption).foregroundStyle(.secondary)
                            if let d = info.modified {
                                Text(d.formatted(date: .abbreviated, time: .shortened)).font(.caption).foregroundStyle(.tertiary)
                            }
                        }
                        Spacer()
                        Text(SideInfo.name(i, count: model.urls.count).uppercased())
                            .font(.system(size: 9, weight: .heavy))
                            .foregroundStyle(SideInfo.color(i, count: model.urls.count))
                    }
                    .padding(12)
                    .frame(maxWidth: .infinity)
                    .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                }
            }
        }
        .padding(18)
        .background(Color(Theme.gutterBackground))
    }

    private var hexView: some View {
        let rowsCount = (model.windows.map(\.count).max() ?? 0 + 15) / 16
        return ScrollView([.vertical, .horizontal]) {
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(0..<max(rowsCount, 0), id: \.self) { r in
                    HStack(spacing: 28) {
                        ForEach(0..<model.windows.count, id: \.self) { s in
                            Text(hexLine(row: r, side: s))
                                .font(.system(size: 12, design: .monospaced))
                                .textSelection(.enabled)
                        }
                    }
                    .padding(.vertical, 1.5)
                    .padding(.horizontal, 16)
                    .background(r % 2 == 0 ? Color.clear : Color.primary.opacity(0.025))
                }
            }
            .padding(.vertical, 8)
        }
    }

    private func hexLine(row: Int, side: Int) -> AttributedString {
        let data = model.windows[side]
        let base = row * 16
        let offset = model.windowStart + Int64(base)
        var s = AttributedString(String(format: "%08llX  ", offset))
        s.foregroundColor = Color(Theme.gutterText)
        var ascii = AttributedString("")
        for k in 0..<16 {
            let i = base + k
            if i < data.count {
                let b = data[i]
                let differs = model.windows.contains { i >= $0.count || $0[i] != b }
                var h = AttributedString(String(format: "%02X", b))
                var a = AttributedString((b >= 32 && b < 127) ? String(UnicodeScalar(b)) : "·")
                if differs {
                    let c = Color(SideInfo.color(side, count: model.windows.count))
                    h.backgroundColor = c.opacity(0.25)
                    h.foregroundColor = .primary
                    a.backgroundColor = c.opacity(0.25)
                } else {
                    h.foregroundColor = b == 0 ? .secondary.opacity(0.5) : .primary
                    a.foregroundColor = .secondary
                }
                s += h
                ascii += a
            } else {
                s += AttributedString("  ")
                ascii += AttributedString(" ")
            }
            s += AttributedString(k == 7 ? "  " : " ")
        }
        s += AttributedString(" ")
        s += ascii
        return s
    }
}

// MARK: - Settings

struct SettingsView: View {
    @State private var fontSize = Double(Preferences.shared.fontSize)
    @State private var lineSpacing = Double(Preferences.shared.lineSpacing)
    @State private var options = Preferences.shared.compareOptions
    @State private var folder = Preferences.shared.folderOptions
    @State private var excluded = Preferences.shared.folderOptions.excludedNames.joined(separator: ", ")

    var body: some View {
        TabView {
            Form {
                Section("Editor") {
                    Slider(value: $fontSize, in: 9...22, step: 0.5) { Text("Font size") } minimumValueLabel: { Text("A").font(.caption) } maximumValueLabel: { Text("A").font(.title3) }
                    Slider(value: $lineSpacing, in: 1.0...1.8, step: 0.02) { Text("Line spacing") }
                    Text("Font: \(Int(fontSize)) pt SF Mono").foregroundStyle(.secondary).font(.caption)
                }
                Section("Text comparison defaults") {
                    Picker("Whitespace", selection: $options.whitespace) {
                        ForEach(WhitespaceMode.allCases, id: \.self) { Text($0.title).tag($0) }
                    }
                    Toggle("Ignore case", isOn: $options.ignoreCase)
                    Toggle("Ignore blank lines", isOn: $options.ignoreBlankLines)
                    Picker("Algorithm", selection: $options.algorithm) {
                        Text("Patience (readable)").tag(DiffAlgorithm.patience)
                        Text("Myers (minimal)").tag(DiffAlgorithm.myers)
                    }
                }
            }
            .formStyle(.grouped)
            .tabItem { Label("Text", systemImage: "doc.text") }

            Form {
                Section("Folder comparison") {
                    Toggle("Compare file contents (byte-by-byte)", isOn: $folder.compareContents)
                    Toggle("Include hidden files", isOn: $folder.includeHidden)
                    TextField("Excluded names", text: $excluded, prompt: Text(".git, node_modules, *.tmp"))
                    Text("Comma-separated names or glob patterns that are skipped while scanning.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            .formStyle(.grouped)
            .tabItem { Label("Folders", systemImage: "folder") }

            Form {
                Section("Command line") {
                    Text("Use the bundled `fcompare` script to open comparisons from Terminal or as a git difftool:")
                    Text("fcompare left.txt right.txt\nfcompare left/ base/ right/\ngit difftool --tool=fcompare")
                        .font(.system(.body, design: .monospaced))
                        .textSelection(.enabled)
                }
            }
            .formStyle(.grouped)
            .tabItem { Label("Integration", systemImage: "terminal") }
        }
        .frame(width: 520, height: 400)
        .onChange(of: fontSize) { _, v in Preferences.shared.fontSize = CGFloat(v); NotificationCenter.default.post(name: .fontChanged, object: nil) }
        .onChange(of: lineSpacing) { _, v in Preferences.shared.lineSpacing = CGFloat(v); NotificationCenter.default.post(name: .fontChanged, object: nil) }
        .onChange(of: options) { _, v in Preferences.shared.compareOptions = v }
        .onChange(of: folder) { _, v in Preferences.shared.folderOptions = v }
        .onChange(of: excluded) { _, v in
            folder.excludedNames = v.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        }
    }
}
