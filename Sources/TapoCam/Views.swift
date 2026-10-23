import AppKit
import CStream
import SwiftUI

// MARK: - Video surface

struct VideoView: NSViewRepresentable {
    let player: StreamPlayer

    func makeNSView(context: Context) -> NSView {
        let view = LayerHostView()
        view.wantsLayer = true
        view.layer?.backgroundColor = .black
        view.videoLayer = player.layer
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        (nsView as? LayerHostView)?.videoLayer = player.layer
    }

    final class LayerHostView: NSView {
        var videoLayer: CALayer? {
            didSet {
                guard oldValue !== videoLayer else { return }
                oldValue?.removeFromSuperlayer()
                if let videoLayer { layer?.addSublayer(videoLayer) }
                needsLayout = true
            }
        }

        /// Only draws: clicks and drags go to the SwiftUI tile around it.
        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        override func layout() {
            super.layout()
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            videoLayer?.frame = bounds
            CATransaction.commit()
        }
    }
}

// MARK: - One video source with its own player

struct CameraTile: View {
    let feed: Feed
    let highQuality: Bool
    var compact = false // small name label (PiP)

    @StateObject private var player: StreamPlayer

    init(feed: Feed, highQuality: Bool, endpoint: Endpoint, compact: Bool = false) {
        self.feed = feed
        self.highQuality = highQuality
        self.compact = compact
        let url = feed.camera.rtspURL(password: Keychain.get(feed.camera.id) ?? "",
                                      lens: feed.lens, highQuality: highQuality, via: endpoint)
        _player = StateObject(wrappedValue: StreamPlayer(url: url, lockKey: feed.camera.host))
    }

    var body: some View {
        ZStack(alignment: .bottomLeading) {
            VideoView(player: player)
            statusOverlay
            HStack(spacing: 6) {
                Text(feed.title)
                if feed.camera.ptz { Image(systemName: "move.3d").imageScale(.small) }
            }
            .font(compact ? .system(size: 9, weight: .semibold) : .callout.weight(.semibold))
            .padding(.horizontal, compact ? 4 : 8).padding(.vertical, compact ? 1 : 4)
            .background(.black.opacity(0.55), in: RoundedRectangle(cornerRadius: compact ? 3 : 6))
            .foregroundStyle(.white)
            .padding(compact ? 3 : 8)
        }
        .background(Color.black)
        .onAppear { player.start() }
        .onDisappear { player.stop() }
    }

    @ViewBuilder private var statusOverlay: some View {
        switch player.status {
        case .playing:
            EmptyView()
        case .connecting:
            ProgressView().controlSize(.small).tint(.white)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .failed(let message):
            VStack(spacing: 6) {
                Image(systemName: "video.slash").font(.title2)
                Text(message).font(.caption).multilineTextAlignment(.center)
                Text("Tentando de novo…").font(.caption2).opacity(0.7)
            }
            .foregroundStyle(.white.opacity(0.85))
            .padding()
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

// MARK: - PTZ

@MainActor
final class PTZController: ObservableObject {
    @Published var presets: [PTZPreset] = []
    @Published var error: String?
    @Published var moving = false

    private let client: OnvifClient
    private var pending: Task<Void, Never>?

    init(camera: Camera, endpoint: Endpoint) {
        client = OnvifClient(host: endpoint.ptzHost, port: endpoint.onvifPort,
                             username: camera.username, password: Keychain.get(camera.id) ?? "")
    }

    func load() {
        Task {
            do { presets = try await client.presets() } catch { self.error = error.localizedDescription }
        }
    }

    func start(x: Double, y: Double) {
        moving = true
        run { try await $0.move(x: x, y: y) }
    }

    func stop() {
        guard moving else { return }
        moving = false
        run { try await $0.stop() }
    }

    func goTo(_ preset: PTZPreset) {
        run { try await $0.goTo(preset) }
    }

    /// Commands run in order, so a quick press/release never leaves the camera moving.
    private func run(_ op: @escaping (OnvifClient) async throws -> Void) {
        let previous = pending
        pending = Task { [client] in
            await previous?.value
            do {
                try await op(client)
                self.error = nil
            } catch {
                self.error = error.localizedDescription
            }
        }
    }
}

/// The camera selected in the grid, and its PTZ controller (if it has PTZ).
@MainActor
final class PTZSelection: ObservableObject {
    @Published private(set) var feedID: String?
    @Published private(set) var camera: Camera?
    @Published private(set) var controller: PTZController?
    private var key = ""

    func select(_ feed: Feed?, endpoint: Endpoint?) {
        feedID = feed?.id
        camera = feed?.camera
        guard let feed, feed.camera.ptz, let endpoint else {
            controller?.stop()
            controller = nil
            key = ""
            return
        }
        let k = "\(feed.camera.id)-\(feed.camera.revision)-\(endpoint)"
        guard k != key else { return }
        controller?.stop()
        key = k
        let c = PTZController(camera: feed.camera, endpoint: endpoint)
        c.load()
        controller = c
    }

    func clear() { select(nil, endpoint: nil) }
}

struct PTZPad: View {
    @ObservedObject var ptz: PTZController
    private let speed = 0.5

    var body: some View {
        VStack(alignment: .trailing, spacing: 10) {
            if !ptz.presets.isEmpty {
                Menu {
                    ForEach(ptz.presets) { p in Button(p.name) { ptz.goTo(p) } }
                } label: {
                    Label("Posições", systemImage: "mappin.and.ellipse")
                }
                .menuStyle(.button)
                .fixedSize()
            }
            ZStack {
                Circle().fill(.black.opacity(0.45))
                Circle().strokeBorder(.white.opacity(0.25))
                arrow("chevron.up", x: 0, y: speed).offset(y: -38)
                arrow("chevron.down", x: 0, y: -speed).offset(y: 38)
                arrow("chevron.left", x: -speed, y: 0).offset(x: -38)
                arrow("chevron.right", x: speed, y: 0).offset(x: 38)
                Circle().fill(.white.opacity(ptz.moving ? 0.5 : 0.15)).frame(width: 14)
            }
            .frame(width: 124, height: 124)
            if let error = ptz.error {
                Text(error).font(.caption).foregroundStyle(.white)
                    .padding(6).background(.red.opacity(0.7), in: RoundedRectangle(cornerRadius: 6))
            }
        }
        .padding(16)
    }

    /// Hold to move, release to stop.
    private func arrow(_ symbol: String, x: Double, y: Double) -> some View {
        Image(systemName: symbol)
            .font(.system(size: 20, weight: .bold))
            .foregroundStyle(.white)
            .frame(width: 40, height: 40)
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0)
                .onChanged { _ in if !ptz.moving { ptz.start(x: x, y: y) } }
                .onEnded { _ in ptz.stop() })
            .help("Segure pra mover (ou use as setas do teclado)")
    }
}

/// Full-window view of one camera in high quality, with lens switch and PTZ.
struct FocusedCameraView: View {
    let camera: Camera
    let endpoint: Endpoint
    @Binding var lens: Int
    /// Jumps to the previous (-1) or next (1) camera. Nil when there is only one.
    let onStep: ((Int) -> Void)?
    let onClose: () -> Void

    @StateObject private var ptz: PTZController
    @FocusState private var hasFocus: Bool

    init(camera: Camera, endpoint: Endpoint, lens: Binding<Int>, onStep: ((Int) -> Void)?, onClose: @escaping () -> Void) {
        self.camera = camera
        self.endpoint = endpoint
        _lens = lens
        self.onStep = onStep
        self.onClose = onClose
        _ptz = StateObject(wrappedValue: PTZController(camera: camera, endpoint: endpoint))
    }

    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            CameraTile(feed: Feed(camera: camera, lens: lens), highQuality: true, endpoint: endpoint)
                .id("hd-\(camera.id)-\(camera.revision)-\(lens)-\(endpoint.host)")
                .onTapGesture(count: 2, perform: onClose)
            if camera.ptz { PTZPad(ptz: ptz) }
            if let onStep {
                HStack {
                    StepArrow(symbol: "chevron.left", help: "Câmera anterior (⌘←)", shortcut: .leftArrow) { onStep(-1) }
                    Spacer()
                    StepArrow(symbol: "chevron.right", help: "Próxima câmera (⌘→)", shortcut: .rightArrow) { onStep(1) }
                }
                .padding(.horizontal, 16)
                .frame(maxHeight: .infinity)
            }
        }
        .focusable()
        .focusEffectDisabled()
        .focused($hasFocus)
        .onAppear {
            hasFocus = true
            if camera.ptz { ptz.load() }
        }
        .onDisappear { ptz.stop() }
        .onKeyPress(keys: [.upArrow, .downArrow, .leftArrow, .rightArrow], phases: [.down, .up]) { press in
            if press.modifiers.contains(.command) && press.phase == .down { return .ignored } // ⌘← → switch cameras
            guard camera.ptz else {
                // No PTZ: ← → switch cameras.
                guard press.phase == .down, let onStep else { return .ignored }
                if press.key == .leftArrow { onStep(-1); return .handled }
                if press.key == .rightArrow { onStep(1); return .handled }
                return .ignored
            }
            if press.phase == .up { ptz.stop(); return .handled }
            guard !ptz.moving else { return .handled }
            switch press.key {
            case .upArrow: ptz.start(x: 0, y: 0.5)
            case .downArrow: ptz.start(x: 0, y: -0.5)
            case .leftArrow: ptz.start(x: -0.5, y: 0)
            default: ptz.start(x: 0.5, y: 0)
            }
            return .handled
        }
    }
}

/// Round ‹ / › button on the side of a single-camera view.
struct StepArrow: View {
    let symbol: String
    let help: String
    var size: CGFloat = 44
    /// Pressed with ⌘.
    var shortcut: KeyEquivalent? = nil
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: size * 0.45, weight: .bold))
                .foregroundStyle(.white)
                .frame(width: size, height: size)
                .background(.black.opacity(0.5), in: Circle())
                .overlay(Circle().strokeBorder(.white.opacity(0.2)))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .help(help)
        .keyboardShortcut(shortcut.map { KeyboardShortcut($0, modifiers: .command) })
    }
}

// MARK: - Main window

struct ContentView: View {
    @EnvironmentObject private var store: CameraStore
    @EnvironmentObject private var location: NetworkLocation
    @EnvironmentObject private var sync: PCSync
    @State private var editing: Camera?
    @State private var remoteSettings = false
    @State private var adding = false
    @State private var focusedID: UUID?
    @State private var focusedLens = 0
    @State private var removing: Camera?
    @State private var scanning = false
    @AppStorage("gridLayout") private var gridLayout = GridLayout.four.rawValue
    @AppStorage("fiveStyle") private var fiveStyle = FiveStyle.threeTwo.rawValue
    @AppStorage("featuredFeed") private var featuredFeed = "" // old setting, read by FeedOrder.parse
    @AppStorage("feedOrder") private var feedOrder = ""
    @StateObject private var ptzSelection = PTZSelection()
    @StateObject private var pip = PiPManager()
    @State private var page = 0

    /// In the order the user arranged; the first one takes the big spot.
    private var orderedFeeds: [Feed] { store.orderedFeeds(order: FeedOrder.parse(feedOrder, legacy: featuredFeed)) }

    private func moveToFront(_ id: String) {
        feedOrder = FeedOrder.insert(orderedFeeds, id: id, index: 0)
        page = 0
    }

    private var layout: GridLayout { GridLayout(rawValue: gridLayout) ?? .four }

    private var focused: Camera? {
        focusedID.flatMap { id in store.cameras.first { $0.id == id } }
    }

    var body: some View {
        Group {
            if let focused {
                FocusedCameraView(camera: focused, endpoint: location.endpoint(for: focused),
                                  lens: $focusedLens,
                                  onStep: orderedFeeds.count > 1 ? step : nil) { focusedID = nil }
                    .id("focus-\(focused.id)-\(focused.revision)-\(location.routeKey)")
            } else if store.cameras.isEmpty {
                emptyState
            } else {
                grid
            }
        }
        .frame(minWidth: 640, minHeight: 400)
        .background(Color.black)
        .onAppear(perform: showScreenshotScene)
        .toolbar { toolbar }
        .navigationTitle(focused.map { Feed(camera: $0, lens: focusedLens).title } ?? "Câmeras")
        .sheet(isPresented: $adding) {
            CameraForm(camera: nil) { cam, pass in store.save(cam, password: pass) }
        }
        .sheet(isPresented: $scanning) {
            ScanSheet(store: store)
        }
        .sheet(isPresented: $remoteSettings) {
            RemoteAccessSheet(store: store, location: location, sync: sync)
        }
        .sheet(item: $editing) { cam in
            CameraForm(camera: cam) { cam, pass in store.save(cam, password: pass) }
        }
        .confirmationDialog("Remover \(removing?.name ?? "")?",
                            isPresented: Binding(get: { removing != nil }, set: { if !$0 { removing = nil } })) {
            Button("Remover", role: .destructive) {
                if let removing { store.remove(removing) }
                removing = nil
            }
        }
    }

    /// README screenshots only: launch with `-screenshotScene ptz|focus|remote|scan`.
    private func showScreenshotScene() {
        guard let scene = UserDefaults.standard.string(forKey: "screenshotScene") else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
            let ptzFeed = orderedFeeds.first { $0.camera.ptz }
            switch scene {
            case "ptz": if let f = ptzFeed { ptzSelection.select(f, endpoint: location.endpoint(for: f.camera)) }
            case "focus": if let f = ptzFeed { open(f) }
            case "remote": remoteSettings = true
            case "pip": pip.showGrid(page: page, store: store, location: location, sync: sync)
            case "pipsingle": if let f = orderedFeeds.first { startPiP(f) }
            case "scan": scanning = true
            default: break
            }
        }
    }

    private func startPiP(_ feed: Feed) {
        pip.showSingle(feed, store: store, location: location, sync: sync)
    }

    private func open(_ feed: Feed) {
        ptzSelection.clear()
        focusedLens = feed.lens
        focusedID = feed.camera.id
    }

    /// Full-window view: goes to the previous/next camera in grid order, wrapping around.
    private func step(_ delta: Int) {
        guard let focused else { return }
        let feeds = orderedFeeds
        guard feeds.count > 1 else { return }
        let current = Feed(camera: focused, lens: focusedLens).id
        let i = feeds.firstIndex { $0.id == current } ?? 0
        let next = feeds[(i + delta + feeds.count) % feeds.count]
        focusedLens = next.lens
        focusedID = next.camera.id
    }

    private var grid: some View {
        PagedGrid(feeds: orderedFeeds, layout: layout,
                  fiveStyle: FiveStyle(rawValue: fiveStyle) ?? .threeTwo,
                  endpoint: location.endpoint(for:), routeKey: location.routeKey, page: $page,
                  managedByPC: sync.isEnabled,
                  selection: ptzSelection,
                  onOpen: open, onEdit: { editing = $0 }, onRemove: { removing = $0 },
                  onFeature: { moveToFront($0.id) },
                  onPiP: { startPiP($0) },
                  onMove: { id, index, swap in
                      feedOrder = swap ? FeedOrder.swap(orderedFeeds, id: id, index: index)
                                       : FeedOrder.insert(orderedFeeds, id: id, index: index)
                  })
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "video.badge.plus").font(.system(size: 44))
            Text("Nenhuma câmera ainda").font(.title2)
            if sync.isEnabled {
                Text("As câmeras vêm do PC de casa. Adicione no app do Windows.\n\(sync.status)")
                    .multilineTextAlignment(.center).foregroundStyle(.secondary)
                Button("Acesso remoto…") { remoteSettings = true }.buttonStyle(.borderedProminent)
            } else {
                Text("Adicione as câmeras no app do Windows (PC de casa) e conecte em Acesso remoto,\nou adicione aqui o IP e a conta da câmera criada no app Tapo.")
                    .multilineTextAlignment(.center).foregroundStyle(.secondary)
                HStack {
                    Button("Conectar ao PC de casa") { remoteSettings = true }.buttonStyle(.borderedProminent)
                    Button("Escanear rede") { scanning = true }
                    Button("Adicionar manualmente") { adding = true }
                }
            }
        }
        .foregroundStyle(.white)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    @ToolbarContentBuilder private var toolbar: some ToolbarContent {
        ToolbarItemGroup {
            if let focused {
                Button { startPiP(Feed(camera: focused, lens: focusedLens)) } label: {
                    Label("Picture in Picture", systemImage: "pip.enter")
                }
                .help("Abrir esta câmera numa janelinha flutuante, por cima de tudo")
                Button { focusedID = nil } label: { Label("Voltar", systemImage: "square.grid.2x2") }
                    .keyboardShortcut(.escape, modifiers: [])
                    .help("Voltar pra grade (Esc)")
                if focused.dualLens {
                    Picker("Lente", selection: $focusedLens) {
                        Text("Grande-angular").tag(0)
                        Text("Zoom").tag(1)
                    }
                    .pickerStyle(.segmented)
                    .help("Trocar de lente")
                }
            }
            if focused == nil && !store.cameras.isEmpty {
                Picker("Grade", selection: $gridLayout) {
                    ForEach(GridLayout.allCases) { l in
                        Text("\(l.rawValue)").tag(l.rawValue)
                    }
                }
                .pickerStyle(.segmented)
                .help("Câmeras por tela. Troque de página com ← →, deslizando no trackpad ou nos botões embaixo.")
                Menu {
                    Picker("Destaque", selection: Binding(
                        get: { orderedFeeds.first?.id ?? "" },
                        set: { moveToFront($0) })) {
                        ForEach(store.feeds) { feed in Text(feed.title).tag(feed.id) }
                    }
                    .pickerStyle(.inline)
                } label: {
                    Label(orderedFeeds.first.map { "Destaque: \($0.title)" } ?? "Destaque", systemImage: "star")
                        .labelStyle(.titleAndIcon)
                }
                .fixedSize()
                .help("Câmera que fica na primeira posição (a grande, nos arranjos com destaque)")
                if layout == .five {
                    Picker("Arranjo", selection: $fiveStyle) {
                        ForEach(FiveStyle.allCases) { style in
                            Label(style.title, systemImage: style.symbol).tag(style.rawValue)
                        }
                    }
                    .pickerStyle(.menu)
                    .fixedSize()
                    .help("Arranjo do modo 5. A câmera grande é a primeira — use \"Colocar em destaque\" no clique direito.")
                }
            }
            if focused == nil && !store.cameras.isEmpty {
                Button { pip.showGrid(page: page, store: store, location: location, sync: sync) } label: {
                    Label("Picture in Picture", systemImage: "pip.enter")
                }
                .help("Abrir a grade numa janelinha flutuante, por cima de tudo (duplo clique numa câmera mostra só ela)")
            }
            Button { remoteSettings = true } label: {
                Label(location.isHome ? "Em casa" : "Fora", systemImage: location.isHome ? "house" : "globe")
                    .labelStyle(.titleAndIcon)
            }
            .help(location.isHome ? "Conectando direto nas câmeras. Clique pra configurar o acesso de fora."
                                  : "Conectando pelo PC de casa (Tailscale). Clique pra configurar.")
            if sync.isEnabled {
                Button { Task { await sync.sync() } } label: {
                    Label("Sincronizar", systemImage: "arrow.triangle.2.circlepath")
                }
                .disabled(sync.syncing)
                .help("Câmeras gerenciadas pelo PC de casa. \(sync.status)")
            } else {
                Button { scanning = true } label: { Label("Escanear", systemImage: "dot.radiowaves.left.and.right") }
                    .help("Procurar câmeras na rede")
                Button { adding = true } label: { Label("Adicionar", systemImage: "plus") }
                    .help("Adicionar câmera")
            }
        }
    }
}

// MARK: - Add / edit form

struct CameraForm: View {
    let camera: Camera?
    var prefillHost: String? = nil
    let onSave: (Camera, String?) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var host = ""
    @State private var port = "554"
    @State private var username = ""
    @State private var password = ""
    @State private var dualLens = false
    @State private var ptz = false
    @State private var detecting = false
    @State private var detectResult: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(camera == nil ? "Nova câmera" : "Editar câmera").font(.title2.bold())
            Form {
                TextField("Nome", text: $name, prompt: Text("Sala"))
                TextField("IP", text: $host, prompt: Text("192.168.0.50"))
                TextField("Porta", text: $port)
                TextField("Usuário", text: $username, prompt: Text("Conta da câmera"))
                SecureField("Senha", text: $password,
                            prompt: Text(camera == nil ? "" : "Deixe vazio pra manter"))
                Toggle("Duas lentes (C245D, C240D…)", isOn: $dualLens)
                Toggle("Movimento PTZ (C206, C245D, C200…)", isOn: $ptz)
            }
            HStack {
                Button(detecting ? "Detectando…" : "Detectar automaticamente", action: detect)
                    .disabled(detecting || !canDetect)
                if detecting { ProgressView().controlSize(.small) }
                if let detectResult { Text(detectResult).font(.caption).foregroundStyle(.secondary) }
            }
            Text("Use a conta criada no app Tapo em Configurações avançadas → Conta da câmera. Não é sua conta TP-Link.")
                .font(.caption).foregroundStyle(.secondary)
            HStack {
                Spacer()
                Button("Cancelar") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Salvar") { save() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!valid)
            }
        }
        .padding(20)
        .frame(width: 440)
        .onAppear {
            if let prefillHost, camera == nil { host = prefillHost }
            guard let camera else { return }
            name = camera.name
            host = camera.host
            port = String(camera.port)
            username = camera.username
            dualLens = camera.dualLens
            ptz = camera.ptz
        }
    }

    private var trimmedHost: String { host.trimmingCharacters(in: .whitespaces) }

    private var effectivePassword: String {
        if !password.isEmpty { return password }
        return camera.flatMap { Keychain.get($0.id) } ?? ""
    }

    private var canDetect: Bool {
        !trimmedHost.isEmpty && !username.isEmpty && !effectivePassword.isEmpty
    }

    private var valid: Bool {
        !name.trimmingCharacters(in: .whitespaces).isEmpty && !trimmedHost.isEmpty
            && !username.isEmpty && Int(port) != nil && (camera != nil || !password.isEmpty)
    }

    /// PTZ: asks ONVIF for a PTZ profile. Second lens: tries to open stream6.
    private func detect() {
        detecting = true
        detectResult = nil
        var probe = Camera(name: "", host: trimmedHost, port: Int(port) ?? 554, username: username)
        probe.dualLens = true
        let pass = effectivePassword
        let url = probe.rtspURL(password: pass, lens: 1, highQuality: false)
        Task {
            let client = OnvifClient(host: probe.host, port: Camera.onvifPort, username: probe.username, password: pass)
            var problem: String?
            let hasPTZ: Bool
            do { hasPTZ = try await client.hasPTZ() } catch {
                hasPTZ = false
                problem = error.localizedDescription
            }
            let hasSecond = await Task.detached { () -> Bool in
                var err = [CChar](repeating: 0, count: 128)
                guard let s = tc_open(url, 6, nil, &err, Int32(err.count)) else { return false }
                tc_close(s)
                return true
            }.value
            ptz = hasPTZ
            dualLens = hasSecond
            var found: [String] = []
            if hasSecond { found.append("duas lentes") }
            if hasPTZ { found.append("PTZ") }
            detectResult = problem.map { "Erro: \($0)" }
                ?? (found.isEmpty ? "Lente única, sem PTZ" : "Encontrado: " + found.joined(separator: " + "))
            detecting = false
        }
    }

    private func save() {
        var cam = camera ?? Camera(name: "", host: "", username: "")
        cam.name = name.trimmingCharacters(in: .whitespaces)
        cam.host = trimmedHost
        cam.port = Int(port) ?? 554
        cam.username = username
        cam.dualLens = dualLens
        cam.ptz = ptz
        onSave(cam, password.isEmpty ? nil : password)
        dismiss()
    }
}
