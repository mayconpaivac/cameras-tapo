import AppKit
import Darwin
import Network
import SwiftUI

// MARK: - Network facts (gateway, MAC addresses)

enum NetInfo {
    /// IPv4 address of the default gateway, e.g. "192.168.0.1".
    static func defaultGateway() -> String? {
        let out = run("/sbin/route", ["-n", "get", "default"])
        return out.split(separator: "\n")
            .first { $0.contains("gateway:") }?
            .split(separator: ":").last?
            .trimmingCharacters(in: .whitespaces)
    }

    /// MAC address from the ARP table, normalized to "aa:bb:cc:dd:ee:ff".
    /// Touches the host first (TCP to `port`) so the ARP entry exists.
    static func mac(for ip: String, touchPort: UInt16? = nil) -> String? {
        if let touchPort { touch(ip, port: touchPort) }
        let out = run("/usr/sbin/arp", ["-n", ip])
        guard let range = out.range(of: " at ") else { return nil }
        let raw = out[range.upperBound...].prefix { $0 != " " }
        let parts = raw.split(separator: ":")
        guard parts.count == 6 else { return nil } // "(incomplete)" and similar
        return parts.map { $0.count == 1 ? "0\($0)" : String($0) }.joined(separator: ":").lowercased()
    }

    private static func touch(_ ip: String, port: UInt16) {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { return }
        defer { close(fd) }
        var tv = timeval(tv_sec: 1, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = port.bigEndian
        inet_pton(AF_INET, ip, &addr.sin_addr)
        _ = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
    }

    private static func run(_ path: String, _ args: [String]) -> String {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: path)
        p.arguments = args
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = Pipe()
        do { try p.run() } catch { return "" }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return String(decoding: data, as: UTF8.self)
    }
}

// MARK: - Home or away

/// Decides whether the Mac is on the home network. The office also uses
/// 10.1.1.x, so the check uses the router's MAC address, not the IP range.
@MainActor
final class NetworkLocation: ObservableObject {
    enum Mode: String, CaseIterable, Identifiable {
        case auto, home, away
        var id: String { rawValue }
        var title: String {
            switch self {
            case .auto: "Automático"
            case .home: "Sempre em casa"
            case .away: "Sempre fora (pelo PC)"
            }
        }
    }

    @Published var mode: Mode {
        didSet { defaults.set(mode.rawValue, forKey: "locationMode") }
    }
    /// The home PC's Tailscale address (100.x.y.z or its MagicDNS name).
    @Published var bridgeHost: String {
        didSet { defaults.set(bridgeHost.trimmingCharacters(in: .whitespaces), forKey: "bridgeHost") }
    }
    @Published private(set) var homeRouterMAC: String?
    @Published private(set) var currentRouterMAC: String?
    @Published private(set) var detecting = false
    /// Set by the PC sync when the home PC restreams the cameras (go2rtc).
    @Published private(set) var restreamPort: Int?
    private var restreamPassword: String?

    func setRestream(port: Int?, password: String?) {
        guard port != restreamPort || password != restreamPassword else { return }
        restreamPort = port
        restreamPassword = password
    }

    private let defaults = UserDefaults.standard
    private let monitor = NWPathMonitor()
    private var refreshTask: Task<Void, Never>?

    init() {
        mode = Mode(rawValue: defaults.string(forKey: "locationMode") ?? "") ?? .auto
        bridgeHost = defaults.string(forKey: "bridgeHost") ?? ""
        homeRouterMAC = defaults.string(forKey: "homeRouterMAC")
        monitor.pathUpdateHandler = { [weak self] _ in
            Task { @MainActor in self?.refresh(after: 2) } // let DHCP settle after a network change
        }
        monitor.start(queue: .global(qos: .utility))
        refresh()
    }

    var isHome: Bool {
        switch mode {
        case .home: return true
        case .away: return false
        case .auto:
            guard let home = homeRouterMAC else { return true } // not set up yet: assume home
            return currentRouterMAC == home
        }
    }

    /// Changes whenever streams must reconnect through a different path.
    var routeKey: String {
        (restreamPort != nil ? "restream-" : "") + (isHome ? "home" : "away-\(bridgeHost)")
    }

    func endpoint(for camera: Camera) -> Endpoint {
        let host = bridgeHost.trimmingCharacters(in: .whitespaces)
        // Video through the PC's restream (one camera connection per lens, however many apps watch).
        // PTZ: straight to the camera at home, through the bridge when away.
        if let port = restreamPort, let pw = restreamPassword, !host.isEmpty {
            return Endpoint(host: host, rtspPort: port,
                            onvifPort: isHome ? Camera.onvifPort : camera.bridgeONVIFPort,
                            onvifHost: isHome ? camera.host : host,
                            restreamPassword: pw)
        }
        guard !isHome, !host.isEmpty else { return camera.localEndpoint }
        return Endpoint(host: host, rtspPort: camera.bridgeRTSPPort, onvifPort: camera.bridgeONVIFPort)
    }

    func markCurrentNetworkAsHome() {
        guard let mac = currentRouterMAC else { return }
        homeRouterMAC = mac
        defaults.set(mac, forKey: "homeRouterMAC")
    }

    func refresh(after delay: Double = 0) {
        refreshTask?.cancel()
        refreshTask = Task {
            if delay > 0 { try? await Task.sleep(for: .seconds(delay)) }
            guard !Task.isCancelled else { return }
            detecting = true
            let mac = await Task.detached { () -> String? in
                guard let gw = NetInfo.defaultGateway() else { return nil }
                return NetInfo.mac(for: gw)
            }.value
            guard !Task.isCancelled else { return }
            currentRouterMAC = mac
            detecting = false
        }
    }
}

// MARK: - Remote access sheet

struct RemoteAccessSheet: View {
    @ObservedObject var store: CameraStore
    @ObservedObject var location: NetworkLocation
    @ObservedObject var sync: PCSync
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Acesso remoto").font(.title2.bold())
            Text("As câmeras vêm do PC Windows de casa: adicione lá e elas aparecem aqui. Fora de casa, o vídeo também passa pelo PC, via Tailscale.")
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            GroupBox("PC de casa") {
                VStack(alignment: .leading, spacing: 10) {
                    TextField("Endereço do PC no Tailscale", text: $location.bridgeHost,
                              prompt: Text("100.x.y.z"))
                    SecureField("Código de pareamento", text: $sync.pairingCode, prompt: Text("XXXX-XXXX"))
                    Text("Os dois aparecem no app do Windows, em Acesso remoto.")
                        .font(.caption).foregroundStyle(.secondary)
                    HStack {
                        Button(sync.syncing ? "Sincronizando…" : "Sincronizar agora") { Task { await sync.sync() } }
                            .disabled(sync.syncing || !sync.isEnabled)
                        if sync.syncing { ProgressView().controlSize(.small) }
                        Text(sync.status).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                    }
                    if !store.cameras.isEmpty && sync.isEnabled {
                        Divider()
                        ForEach(store.cameras) { cam in
                            HStack {
                                Image(systemName: Keychain.get(cam.id) == nil ? "lock.slash" : "checkmark.circle")
                                    .foregroundStyle(Keychain.get(cam.id) == nil ? .orange : .green)
                                Text(cam.name)
                                Spacer()
                                Text(verbatim: "\(cam.host) · vídeo cam\(cam.slot)_* · PTZ \(cam.bridgeONVIFPort)")
                                    .font(.caption.monospaced()).foregroundStyle(.secondary)
                            }
                        }
                    }
                }
                .padding(6)
            }

            GroupBox("Onde estou") {
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Image(systemName: location.isHome ? "house.fill" : "globe")
                        Text(location.isHome ? "Em casa: conexão direta com as câmeras" : "Fora: conexão pelo PC de casa")
                            .bold()
                        if location.detecting { ProgressView().controlSize(.small) }
                    }
                    Picker("Modo", selection: $location.mode) {
                        ForEach(NetworkLocation.Mode.allCases) { Text($0.title).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    HStack {
                        Text(homeDescription).font(.caption).foregroundStyle(.secondary)
                        Spacer()
                        Button("Esta rede é minha casa") { location.markCurrentNetworkAsHome() }
                            .disabled(location.currentRouterMAC == nil
                                      || location.currentRouterMAC == location.homeRouterMAC)
                    }
                }
                .padding(6)
            }

            HStack {
                Spacer()
                Button("Fechar") { dismiss() }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 560)
        .onChange(of: location.bridgeHost) { Task { await sync.sync() } }
        .onChange(of: sync.pairingCode) { Task { await sync.sync() } }
    }

    private var homeDescription: String {
        guard let home = location.homeRouterMAC else { return "Casa ainda não definida (tudo é tratado como casa)." }
        if location.currentRouterMAC == home { return "Roteador desta rede = roteador de casa." }
        return "Roteador desta rede é outro (casa: \(home))."
    }
}
