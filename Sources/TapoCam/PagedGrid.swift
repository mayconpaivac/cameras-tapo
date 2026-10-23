import AppKit
import SwiftUI

/// Arrangement for the 5-camera page.
enum FiveStyle: String, CaseIterable, Identifiable {
    case bigLeft, bigTop, threeTwo

    var id: String { rawValue }

    var title: String {
        switch self {
        case .bigLeft: "1 grande + 4 à direita"
        case .bigTop: "1 grande + 4 embaixo"
        case .threeTwo: "3 em cima + 2 embaixo"
        }
    }

    var symbol: String {
        switch self {
        case .bigLeft: "rectangle.split.2x1"
        case .bigTop: "rectangle.split.1x2"
        case .threeTwo: "rectangle.split.3x1"
        }
    }
}

/// How many cameras fit on one page.
enum GridLayout: Int, CaseIterable, Identifiable {
    case one = 1, two = 2, four = 4, five = 5, six = 6, eight = 8, nine = 9, twelve = 12, sixteen = 16

    var id: Int { rawValue }

    /// Where each camera goes, as fractions of the page (0...1). The first one is the featured spot.
    func cells(five: FiveStyle) -> [CGRect] {
        switch self {
        case .one: return rows([1])
        case .two: return rows([2])
        case .four: return rows([2, 2])
        case .six: return rows([3, 3])
        case .eight: return rows([4, 4])
        case .nine: return rows([3, 3, 3])
        case .twelve: return rows([4, 4, 4])
        case .sixteen: return rows([4, 4, 4, 4])
        case .five:
            switch five {
            case .threeTwo:
                return rows([3, 2])
            case .bigLeft:
                return [CGRect(x: 0, y: 0, width: 0.5, height: 1)]
                    + [(0.5, 0.0), (0.75, 0.0), (0.5, 0.5), (0.75, 0.5)]
                        .map { CGRect(x: $0.0, y: $0.1, width: 0.25, height: 0.5) }
            case .bigTop:
                let top = 0.7
                return [CGRect(x: 0, y: 0, width: 1, height: top)]
                    + (0..<4).map { CGRect(x: Double($0) * 0.25, y: top, width: 0.25, height: 1 - top) }
            }
        }
    }

    /// Equal-height rows; each row splits its width evenly.
    private func rows(_ counts: [Int]) -> [CGRect] {
        let h = 1.0 / Double(counts.count)
        return counts.enumerated().flatMap { r, n in
            (0..<n).map { c in CGRect(x: Double(c) / Double(n), y: Double(r) * h, width: 1.0 / Double(n), height: h) }
        }
    }
}

/// Fixed grid that fills the window, split into pages you can flip sideways.
/// Only the cameras on the visible page stream, which saves bandwidth.
struct PagedGrid: View {
    let feeds: [Feed]
    let layout: GridLayout
    let fiveStyle: FiveStyle
    let endpoint: (Camera) -> Endpoint
    let routeKey: String
    @Binding var page: Int
    var managedByPC = false
    @ObservedObject var selection: PTZSelection
    let onOpen: (Feed) -> Void
    let onEdit: (Camera) -> Void
    let onRemove: (Camera) -> Void
    let onFeature: (Feed) -> Void
    var onPiP: ((Feed) -> Void)? = nil
    /// Drag and drop: (feed id, position in the full list, swap with the one there, or insert).
    var onMove: ((String, Int, Bool) -> Void)? = nil

    @State private var direction: Edge = .trailing
    @State private var scrollMonitor: Any?
    @State private var scrollAccumulated: CGFloat = 0
    @State private var dropTarget: Int?
    @State private var pagerTarget = 0 // -1/1 while a camera is dragged over ‹ / ›
    @FocusState private var hasFocus: Bool

    private let spacing: CGFloat = 4

    private var pageCount: Int { max(1, (feeds.count + layout.rawValue - 1) / layout.rawValue) }

    private var pageFeeds: [Feed] {
        let start = min(page, pageCount - 1) * layout.rawValue
        return Array(feeds.dropFirst(start).prefix(layout.rawValue))
    }

    var body: some View {
        ZStack(alignment: .bottom) {
            GeometryReader { geo in
                pageView(size: geo.size)
                    .id("page-\(page)-\(layout.rawValue)-\(fiveStyle.rawValue)")
                    .transition(.push(from: direction))
            }
            .clipped()

            if pageCount > 1 { pager }

            if let controller = selection.controller, let cam = selection.camera {
                ptzPanel(controller, cam)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
                    .padding(.bottom, pageCount > 1 ? 44 : 0)
            }
        }
        .focusable()
        .focusEffectDisabled()
        .focused($hasFocus)
        .onAppear {
            hasFocus = true
            clampPage()
            installScrollMonitor()
        }
        .onDisappear(perform: removeScrollMonitor)
        .onChange(of: layout) { clampPage(); refreshSelection() }
        .onChange(of: feeds) { clampPage(); refreshSelection() }
        .onChange(of: page) { refreshSelection() }
        .onChange(of: routeKey) { refreshSelection() }
        .onKeyPress(keys: [.upArrow, .downArrow, .leftArrow, .rightArrow, .escape], phases: [.down, .up], action: handleKey)
    }

    private func pageView(size: CGSize) -> some View {
        let cells = layout.cells(five: fiveStyle)
        let items = pageFeeds
        // Outer margin of half a gap; each cell is inset by half a gap on every side.
        let inner = CGSize(width: size.width - spacing, height: size.height - spacing)
        return ZStack(alignment: .topLeading) {
            ForEach(cells.indices, id: \.self) { i in
                let cell = cells[i]
                let w = cell.width * inner.width - spacing
                let h = cell.height * inner.height - spacing
                Group {
                    if i < items.count {
                        tile(items[i], highQuality: true) // always full quality (stream1/stream6)
                    } else {
                        Color.white.opacity(0.03).clipShape(RoundedRectangle(cornerRadius: 6))
                    }
                }
                .overlay {
                    if dropTarget == i {
                        RoundedRectangle(cornerRadius: 6)
                            .fill(Color.accentColor.opacity(0.2))
                            .strokeBorder(Color.accentColor, lineWidth: 3)
                            .allowsHitTesting(false)
                    }
                }
                .frame(width: max(w, 0), height: max(h, 0))
                .dropDestination(for: String.self) { ids, _ in
                    dropTarget = nil
                    guard let id = ids.first, let onMove else { return false }
                    let index = min(page, pageCount - 1) * layout.rawValue + i
                    if i < items.count, items[i].id == id { return false }
                    withAnimation(.easeInOut(duration: 0.2)) { onMove(id, index, true) }
                    return true
                } isTargeted: { over in
                    if over { dropTarget = i } else if dropTarget == i { dropTarget = nil }
                }
                .offset(x: cell.minX * inner.width + spacing, y: cell.minY * inner.height + spacing)
            }
        }
        .frame(width: size.width, height: size.height, alignment: .topLeading)
    }

    private func tile(_ feed: Feed, highQuality: Bool) -> some View {
        CameraTile(feed: feed, highQuality: highQuality, endpoint: endpoint(feed.camera))
            .id("tile-\(feed.id)-\(feed.camera.revision)-\(highQuality)-\(routeKey)")
            .clipShape(RoundedRectangle(cornerRadius: 6))
            .overlay(RoundedRectangle(cornerRadius: 6)
                .strokeBorder(Color.accentColor, lineWidth: 3)
                .opacity(selection.feedID == feed.id ? 1 : 0))
            .contentShape(Rectangle())
            .onTapGesture(count: 2) { onOpen(feed) }
            .onTapGesture {
                hasFocus = true
                if selection.feedID == feed.id { selection.clear() }
                else { selection.select(feed, endpoint: endpoint(feed.camera)) }
            }
            .draggable(feed.id) {
                Label(feed.title, systemImage: "video.fill")
                    .font(.callout.weight(.semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 12).padding(.vertical, 6)
                    .background(Color.accentColor, in: Capsule())
            }
            .contextMenu {
                Button(feed.camera.ptz ? "Abrir e controlar" : "Ver em alta qualidade") { onOpen(feed) }
                Button("Colocar em destaque") { onFeature(feed) }
                if let onPiP { Button("Picture in Picture") { onPiP(feed) } }
                if !managedByPC {
                    Button("Editar…") { onEdit(feed.camera) }
                    Divider()
                    Button("Remover…", role: .destructive) { onRemove(feed.camera) }
                }
            }
    }

    /// PTZ for the selected camera, over the grid.
    private func ptzPanel(_ controller: PTZController, _ cam: Camera) -> some View {
        VStack(alignment: .trailing, spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "move.3d")
                Text(cam.name).font(.callout.weight(.semibold))
                Button { selection.clear() } label: { Image(systemName: "xmark.circle.fill") }
                    .buttonStyle(.plain)
                    .help("Tirar a seleção (Esc)")
            }
            .foregroundStyle(.white)
            .padding(.horizontal, 10).padding(.vertical, 5)
            .background(.black.opacity(0.6), in: Capsule())
            .padding(.trailing, 16)
            PTZPad(ptz: controller)
        }
    }

    /// Arrows move the selected PTZ camera; without one, ← → flip pages. Esc clears the selection.
    private func handleKey(_ press: KeyPress) -> KeyPress.Result {
        if press.key == .escape {
            guard press.phase == .down, selection.feedID != nil else { return .ignored }
            selection.clear()
            return .handled
        }
        if let c = selection.controller {
            if press.phase == .up { c.stop(); return .handled }
            guard !c.moving else { return .handled }
            switch press.key {
            case .upArrow: c.start(x: 0, y: 0.5)
            case .downArrow: c.start(x: 0, y: -0.5)
            case .leftArrow: c.start(x: -0.5, y: 0)
            default: c.start(x: 0.5, y: 0)
            }
            return .handled
        }
        guard press.phase == .down else { return .ignored }
        if press.key == .leftArrow { go(-1); return .handled }
        if press.key == .rightArrow { go(1); return .handled }
        return .ignored
    }

    /// Keeps the selection valid: still on this page, with current settings.
    private func refreshSelection() {
        guard let id = selection.feedID else { return }
        if let feed = pageFeeds.first(where: { $0.id == id }) {
            selection.select(feed, endpoint: endpoint(feed.camera))
        } else {
            selection.clear()
        }
    }

    private var pager: some View {
        HStack(spacing: 12) {
            Button { go(-1) } label: { Image(systemName: "chevron.left") }
                .disabled(page == 0)
                .scaleEffect(pagerTarget == -1 ? 1.6 : 1)
                .dropDestination(for: String.self) { ids, _ in dropOnPager(ids, -1) }
                    isTargeted: { pagerTarget = $0 ? -1 : (pagerTarget == -1 ? 0 : pagerTarget) }
                .help("Página anterior (solte uma câmera aqui pra mandar ela pra lá)")
            HStack(spacing: 6) {
                ForEach(0..<pageCount, id: \.self) { i in
                    Circle()
                        .fill(.white.opacity(i == page ? 0.95 : 0.35))
                        .frame(width: 7, height: 7)
                        .onTapGesture { jump(to: i) }
                }
            }
            Text("\(page + 1)/\(pageCount)").font(.caption.monospacedDigit())
            Button { go(1) } label: { Image(systemName: "chevron.right") }
                .disabled(page >= pageCount - 1)
                .scaleEffect(pagerTarget == 1 ? 1.6 : 1)
                .dropDestination(for: String.self) { ids, _ in dropOnPager(ids, 1) }
                    isTargeted: { pagerTarget = $0 ? 1 : (pagerTarget == 1 ? 0 : pagerTarget) }
                .help("Próxima página (solte uma câmera aqui pra mandar ela pra lá)")
        }
        .buttonStyle(.plain)
        .foregroundStyle(.white)
        .padding(.horizontal, 14).padding(.vertical, 7)
        .background(.black.opacity(0.6), in: Capsule())
        .padding(.bottom, 12)
    }

    /// Sends the dropped camera to the last spot of the previous page, or the first of the next one.
    private func dropOnPager(_ ids: [String], _ dir: Int) -> Bool {
        pagerTarget = 0
        let target = page + dir
        guard let id = ids.first, let onMove, target >= 0, target < pageCount,
              feeds.contains(where: { $0.id == id }) else { return false }
        onMove(id, dir < 0 ? page * layout.rawValue - 1 : (page + 1) * layout.rawValue, false)
        jump(to: target)
        return true
    }

    private func go(_ delta: Int) {
        jump(to: page + delta)
    }

    private func jump(to target: Int) {
        let t = min(max(target, 0), pageCount - 1)
        guard t != page else { return }
        direction = t > page ? .trailing : .leading
        withAnimation(.easeInOut(duration: 0.3)) { page = t }
    }

    private func clampPage() {
        if page > pageCount - 1 { page = pageCount - 1 }
    }

    /// Two-finger horizontal swipe on the trackpad flips pages.
    private func installScrollMonitor() {
        guard scrollMonitor == nil else { return }
        scrollMonitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { event in
            guard event.hasPreciseScrollingDeltas,
                  abs(event.scrollingDeltaX) > abs(event.scrollingDeltaY) || event.phase == .ended
            else { return event }
            if event.phase == .began { scrollAccumulated = 0 }
            scrollAccumulated += event.scrollingDeltaX
            if event.phase == .ended || event.phase == .cancelled {
                if scrollAccumulated < -60 { go(1) } else if scrollAccumulated > 60 { go(-1) }
                scrollAccumulated = 0
            }
            return event
        }
    }

    private func removeScrollMonitor() {
        if let scrollMonitor { NSEvent.removeMonitor(scrollMonitor) }
        scrollMonitor = nil
    }
}
