import SwiftUI
import AppKit

struct RootView: View {
    @State private var model = WindowModel()
    @State private var nsWindow: NSWindow?
    @State private var closeGuard = WindowCloseGuard()
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        ZStack {
            switch model.current {
            case .welcome:
                WelcomeView(window: model)
            case .loading(let name):
                LoadingView(title: "Comparing", detail: name)
            case .text(let m):
                TextCompareView(model: m, window: model)
                    .id(ObjectIdentifier(m))
            case .folder(let m):
                FolderCompareView(model: m, window: model)
                    .id(ObjectIdentifier(m))
            case .image(let m):
                ImageCompareView(model: m, window: model)
                    .id(ObjectIdentifier(m))
            case .binary(let m):
                BinaryCompareView(model: m, window: model)
                    .id(ObjectIdentifier(m))
            }
        }
        .frame(minWidth: 860, minHeight: 540)
        .navigationTitle(model.current.title)
        .toolbar {
            ToolbarItemGroup(placement: .navigation) {
                if model.hasHistory {
                    ControlGroup {
                        Button {
                            model.goBack()
                        } label: {
                            Label("Back", systemImage: "chevron.backward")
                        }
                        .help(model.backTitle.map { "Back to \($0) (⌘[ or mouse back button)" } ?? "Back")
                        .disabled(!model.canGoBack)
                        Button {
                            model.goForward()
                        } label: {
                            Label("Forward", systemImage: "chevron.forward")
                        }
                        .help(model.forwardTitle.map { "Forward to \($0) (⌘] or mouse forward button)" } ?? "Forward")
                        .disabled(!model.canGoForward)
                    } label: {
                        Label("Navigate", systemImage: "chevron.backward.chevron.forward")
                    }
                    .controlGroupStyle(.navigation)
                }
                if !model.isWelcome {
                    Button {
                        model.goHome()
                    } label: {
                        Label("Start", systemImage: "square.grid.2x2")
                    }
                    .help("New comparison (⇧⌘H)")
                }
            }
        }
        .alert("Can’t Compare", isPresented: Binding(get: { model.errorMessage != nil }, set: { if !$0 { model.errorMessage = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(model.errorMessage ?? "")
        }
        .background(WindowAccessor { window in
            nsWindow = window
            model.hostWindow = window
            closeGuard.model = model
            closeGuard.install(on: window)
            window.tabbingMode = .preferred
            window.titlebarSeparatorStyle = .line
            if let size = AppDelegate.debugSize {
                window.setContentSize(size)
                window.center()
            }
            if let path = AppDelegate.debugWindowIDPath {
                try? String(window.windowNumber).write(toFile: path, atomically: true, encoding: .utf8)
            }
        })
        .focusedSceneValue(\.windowModel, model)
        .onChange(of: model.hasUnsavedChanges) { _, dirty in nsWindow?.isDocumentEdited = dirty }
        .onAppear {
            WindowRegistry.shared.register(model)
            if let n = AppDelegate.startBlank {
                AppDelegate.startBlank = nil
                model.openBlank(count: n)
            }
            consumePending(force: true)
        }
        .onReceive(NotificationCenter.default.publisher(for: .openRequest)) { _ in
            consumePending(force: false)
        }
    }

    /// Picks up queued comparisons (from the command line, Finder or the Open panel).
    private func consumePending(force: Bool) {
        guard !AppDelegate.pending.isEmpty else { return }
        if !force {
            // Only the key window (or the sole window) reacts to global open requests.
            let isKey = nsWindow?.isKeyWindow ?? false
            let anyKey = NSApp.windows.contains { $0.isKeyWindow }
            guard isKey || (!anyKey && WindowRegistry.shared.models.first === model) else { return }
        }
        if model.isWelcome || force {
            let urls = AppDelegate.pending.removeFirst()
            if urls.count == 1 {
                model.prefill = urls
            } else {
                model.open(urls)
            }
        } else {
            openWindow(id: "main")
        }
    }
}

struct LoadingView: View {
    var title: String
    var detail: String

    var body: some View {
        VStack(spacing: 14) {
            ProgressView()
                .controlSize(.large)
            Text(title)
                .font(.title3.weight(.semibold))
            Text(detail)
                .font(.callout)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(maxWidth: 480)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(Theme.editorBackground))
    }
}

/// Exposes the hosting NSWindow to SwiftUI.
struct WindowAccessor: NSViewRepresentable {
    var onWindow: (NSWindow) -> Void

    func makeNSView(context: Context) -> NSView {
        let v = NSView()
        DispatchQueue.main.async { [weak v] in
            if let w = v?.window { onWindow(w) }
        }
        return v
    }

    func updateNSView(_ nsView: NSView, context: Context) {}
}

/// Intercepts window close to offer saving unsaved merge edits, forwarding everything else
/// to SwiftUI's own window delegate.
final class WindowCloseGuard: NSObject, NSWindowDelegate {
    weak var model: WindowModel?
    private weak var original: NSWindowDelegate?

    func install(on window: NSWindow) {
        guard window.delegate !== self else { return }
        original = window.delegate
        window.delegate = self
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        let ok = MainActor.assumeIsolated { model?.confirmDiscard() ?? true }
        guard ok else { return false }
        return original?.windowShouldClose?(sender) ?? true
    }

    override func responds(to aSelector: Selector!) -> Bool {
        super.responds(to: aSelector) || (original?.responds(to: aSelector) ?? false)
    }

    override func forwardingTarget(for aSelector: Selector!) -> Any? {
        if let original, original.responds(to: aSelector) { return original }
        return super.forwardingTarget(for: aSelector)
    }
}
