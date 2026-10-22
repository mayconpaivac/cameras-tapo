import AppKit
import SwiftUI

/// Picture in Picture: a small floating window that stays above every app and Space.
/// Shows the same grid as the main window, or a single camera.
@MainActor
final class PiPManager: NSObject, ObservableObject, NSWindowDelegate {
    enum Mode: Equatable {
        case grid
        case single(String) // feed id
    }

    @Published var mode: Mode = .grid
    @Published var page = 0
    @Published private(set) var isOpen = false

    private var panel: NSPanel?
    private weak var mainWindow: NSWindow?

    func showGrid(page: Int, store: CameraStore, location: NetworkLocation, sync: PCSync) {
        self.page = page
        mode = .grid
        open(store: store, location: location, sync: sync)
    }

    func showSingle(_ feed: Feed, store: CameraStore, location: NetworkLocation, sync: PCSync) {
        mode = .single(feed.id)
        open(store: store, location: location, sync: sync)
    }

    func close() {
        panel?.close() // windowWillClose cleans up
    }

    /// Closes PiP and brings the main window back.
    func returnToApp() {
        close()
        NSApp.activate(ignoringOtherApps: true)
        mainWindow?.makeKeyAndOrderFront(nil)
    }

    private func open(store: CameraStore, location: NetworkLocation, sync: PCSync) {
        mainWindow = NSApp.windows.first { $0.isVisible && !($0 is NSPanel) }
        if let panel {
            panel.orderFrontRegardless()
            return
        }
        let size = NSSize(width: 480, height: 270)
        let panel = NSPanel(contentRect: NSRect(origin: .zero, size: size),
                            styleMask: [.titled, .closable, .resizable, .nonactivatingPanel, .fullSizeContentView],
                            backing: .buffered, defer: false)
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        panel.isMovableByWindowBackground = true
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.contentAspectRatio = NSSize(width: 16, height: 9)
        panel.minSize = NSSize(width: 240, height: 135)
        panel.backgroundColor = .black
        for button in [NSWindow.ButtonType.miniaturizeButton, .zoomButton] { panel.standardWindowButton(button)?.isHidden = true }
        panel.delegate = self
        panel.contentView = NSHostingView(rootView: PiPContentView(pip: self)
            .environmentObject(store)
            .environmentObject(location)
            .environmentObject(sync))
        // Bottom-right corner of the screen, like system PiP.
        if let screen = (mainWindow?.screen ?? NSScreen.main)?.visibleFrame {
            panel.setFrameOrigin(NSPoint(x: screen.maxX - size.width - 20, y: screen.minY + 20))
        }
        panel.orderFrontRegardless()
        self.panel = panel
        isOpen = true
    }

    nonisolated func windowWillClose(_ notification: Notification) {
        Task { @MainActor in
            self.panel?.contentView = nil // stops the PiP streams
            self.panel = nil
            self.isOpen = false
        }
    }
}

/// What the PiP window shows. Hovering reveals the controls.
struct PiPContentView: View {
    @ObservedObject var pip: PiPManager
    @EnvironmentObject private var store: CameraStore
    @EnvironmentObject private var location: NetworkLocation
    @AppStorage("gridLayout") private var gridLayout = GridLayout.four.rawValue
    @AppStorage("fiveStyle") private var fiveStyle = FiveStyle.threeTwo.rawValue
    @AppStorage("featuredFeed") private var featuredFeed = ""
    @State private var hovering = false

    private var layout: GridLayout { GridLayout(rawValue: gridLayout) ?? .four }
    private var feeds: [Feed] { store.orderedFeeds(featured: featuredFeed) }
    private var pageCount: Int { max(1, (feeds.count + layout.rawValue - 1) / layout.rawValue) }

    var body: some View {
        ZStack {
            Color.black
            switch pip.mode {
            case .grid: grid
            case .single(let id):
                if let feed = feeds.first(where: { $0.id == id }) {
                    tile(feed).onTapGesture(count: 2) { pip.mode = .grid }
                } else {
                    Text("Câmera removida").foregroundStyle(.secondary)
                }
            }
            if hovering { controls }
        }
        .ignoresSafeArea() // use the area under the (transparent) title bar too
        .onHover { hovering = $0 }
        .onChange(of: pageCount) { if pip.page >= pageCount { pip.page = pageCount - 1 } }
    }

    private var grid: some View {
        GeometryReader { geo in
            let cells = layout.cells(five: FiveStyle(rawValue: fiveStyle) ?? .threeTwo)
            let items = Array(feeds.dropFirst(min(pip.page, pageCount - 1) * layout.rawValue).prefix(layout.rawValue))
            let gap: CGFloat = 2
            let inner = CGSize(width: geo.size.width - gap, height: geo.size.height - gap)
            ZStack(alignment: .topLeading) {
                ForEach(cells.indices, id: \.self) { i in
                    let cell = cells[i]
                    Group {
                        if i < items.count {
                            tile(items[i]).onTapGesture(count: 2) { pip.mode = .single(items[i].id) }
                        } else {
                            Color.white.opacity(0.03)
                        }
                    }
                    .frame(width: max(cell.width * inner.width - gap, 0), height: max(cell.height * inner.height - gap, 0))
                    .offset(x: cell.minX * inner.width + gap, y: cell.minY * inner.height + gap)
                }
            }
        }
    }

    private func tile(_ feed: Feed) -> some View {
        CameraTile(feed: feed, highQuality: true, endpoint: location.endpoint(for: feed.camera),
                   compact: pip.mode == .grid)
            .id("pip-\(feed.id)-\(feed.camera.revision)-\(location.routeKey)")
            .contentShape(Rectangle())
    }

    private var controls: some View {
        VStack {
            HStack(spacing: 6) {
                if case .single = pip.mode {
                    control("square.grid.2x2", "Ver todas as câmeras") { pip.mode = .grid }
                } else if pageCount > 1 {
                    control("chevron.left", "Página anterior") { pip.page = max(pip.page - 1, 0) }
                    Text("\(pip.page + 1)/\(pageCount)").font(.caption.monospacedDigit()).foregroundStyle(.white)
                    control("chevron.right", "Próxima página") { pip.page = min(pip.page + 1, pageCount - 1) }
                }
                Spacer()
                control("arrow.up.left.and.arrow.down.right", "Voltar ao app") { pip.returnToApp() }
                control("xmark", "Fechar") { pip.close() }
            }
            .padding(8)
            .padding(.leading, 60) // keep clear of the window's close button
            Spacer()
            if case .grid = pip.mode {
                Text("Duplo clique numa câmera pra ver só ela")
                    .font(.caption2).foregroundStyle(.white.opacity(0.8))
                    .padding(.horizontal, 8).padding(.vertical, 3)
                    .background(.black.opacity(0.5), in: Capsule())
                    .padding(.bottom, 6)
            }
        }
    }

    private func control(_ symbol: String, _ help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 12, weight: .bold))
                .frame(width: 26, height: 26)
                .background(.black.opacity(0.6), in: Circle())
                .foregroundStyle(.white)
        }
        .buttonStyle(.plain)
        .help(help)
    }
}
