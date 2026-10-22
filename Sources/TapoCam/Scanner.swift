import Darwin
import Foundation
import SwiftUI

struct ScanResult: Identifiable, Hashable {
    var id: String { ip }
    let ip: String
    let hasOnvif: Bool
    let isTapo: Bool
    let hostname: String?
}

/// Finds devices that accept RTSP connections on a /24 network.
enum NetScanner {
    /// "10.1.1" style prefixes for this Mac's IPv4 networks (Wi-Fi, Ethernet).
    static func localPrefixes() -> [String] {
        var result: [String] = []
        var addrs: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&addrs) == 0, let first = addrs else { return [] }
        defer { freeifaddrs(addrs) }
        for ptr in sequence(first: first, next: { $0.pointee.ifa_next }) {
            let ifa = ptr.pointee
            guard let sa = ifa.ifa_addr, sa.pointee.sa_family == UInt8(AF_INET),
                  ifa.ifa_flags & UInt32(IFF_LOOPBACK) == 0,
                  ifa.ifa_flags & UInt32(IFF_UP) != 0 else { continue }
            let name = String(cString: ifa.ifa_name)
            guard name.hasPrefix("en") else { continue } // skip VPN/virtual interfaces
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            getnameinfo(sa, socklen_t(sa.pointee.sa_len), &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST)
            let parts = String(cString: host).split(separator: ".")
            guard parts.count == 4 else { continue }
            let prefix = parts.prefix(3).joined(separator: ".")
            if !result.contains(prefix) { result.append(prefix) }
        }
        return result
    }

    static func isValidPrefix(_ prefix: String) -> Bool {
        let parts = prefix.split(separator: ".", omittingEmptySubsequences: false)
        return parts.count == 3 && parts.allSatisfy { UInt8($0) != nil }
    }

    /// Scans prefix.1 ... prefix.254. Blocking; call off the main thread.
    static func scan(prefix: String, progress: @escaping (Double) -> Void) -> [ScanResult] {
        let ips = (1...254).map { "\(prefix).\($0)" }
        let rtsp = openHosts(ips, port: 554, timeoutMs: 1200) { progress($0 * 0.8) }
        let found = ips.filter(rtsp.contains)
        let onvif = openHosts(found, port: 2020, timeoutMs: 1200) { _ in }
        progress(0.9)
        let results = found.map { ip in
            ScanResult(ip: ip, hasOnvif: onvif.contains(ip), isTapo: rtspRealm(ip)?.contains("TP-Link") == true,
                       hostname: reverseName(ip))
        }
        progress(1)
        return results
    }

    /// Non-blocking connects in batches; returns the hosts that accepted.
    private static func openHosts(_ ips: [String], port: UInt16, timeoutMs: Int,
                                  progress: (Double) -> Void) -> Set<String> {
        var open = Set<String>()
        let batchSize = 64 // stay well under the default open-file limit
        var done = 0
        for start in stride(from: 0, to: ips.count, by: batchSize) {
            let batch = Array(ips[start..<min(start + batchSize, ips.count)])
            var pending: [(fd: Int32, ip: String)] = []

            for ip in batch {
                let fd = socket(AF_INET, SOCK_STREAM, 0)
                guard fd >= 0 else { continue }
                var one: Int32 = 1
                setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
                _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)
                var addr = sockaddr_in()
                addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
                addr.sin_family = sa_family_t(AF_INET)
                addr.sin_port = port.bigEndian
                inet_pton(AF_INET, ip, &addr.sin_addr)
                let r = withUnsafePointer(to: &addr) {
                    $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                        connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
                    }
                }
                if r == 0 {
                    open.insert(ip); close(fd)
                } else if errno == EINPROGRESS {
                    pending.append((fd, ip))
                } else {
                    close(fd)
                }
            }

            let deadline = Date().addingTimeInterval(Double(timeoutMs) / 1000)
            while !pending.isEmpty, Date() < deadline {
                var fds = pending.map { pollfd(fd: $0.fd, events: Int16(POLLOUT), revents: 0) }
                let wait = Int32(max(1, deadline.timeIntervalSinceNow * 1000))
                guard poll(&fds, nfds_t(fds.count), wait) > 0 else { break }
                var still: [(fd: Int32, ip: String)] = []
                for (i, p) in pending.enumerated() {
                    if fds[i].revents == 0 { still.append(p); continue }
                    var err: Int32 = 0
                    var len = socklen_t(MemoryLayout<Int32>.size)
                    getsockopt(p.fd, SOL_SOCKET, SO_ERROR, &err, &len)
                    if err == 0 { open.insert(p.ip) }
                    close(p.fd)
                }
                pending = still
            }
            pending.forEach { close($0.fd) }
            done += batch.count
            progress(Double(done) / Double(max(ips.count, 1)))
        }
        return open
    }

    /// Asks the RTSP server who it is. TP-Link cameras answer with realm "TP-Link IP-Camera".
    private static func rtspRealm(_ ip: String) -> String? {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { return nil }
        defer { close(fd) }
        var one: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
        var tv = timeval(tv_sec: 2, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = UInt16(554).bigEndian
        inet_pton(AF_INET, ip, &addr.sin_addr)
        let r = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard r == 0 else { return nil }
        let req = "DESCRIBE rtsp://\(ip):554/stream1 RTSP/1.0\r\nCSeq: 1\r\n\r\n"
        guard req.withCString({ send(fd, $0, strlen($0), 0) }) > 0 else { return nil }
        var buf = [UInt8](repeating: 0, count: 2048)
        let n = recv(fd, &buf, buf.count, 0)
        guard n > 0 else { return nil }
        let text = String(decoding: buf[0..<n], as: UTF8.self)
        guard let range = text.range(of: "realm=\"") else { return nil }
        return String(text[range.upperBound...].prefix { $0 != "\"" })
    }

    private static func reverseName(_ ip: String) -> String? {
        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        inet_pton(AF_INET, ip, &addr.sin_addr)
        var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
        let r = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                getnameinfo($0, socklen_t(MemoryLayout<sockaddr_in>.size), &host, socklen_t(host.count), nil, 0, NI_NAMEREQD)
            }
        }
        guard r == 0 else { return nil }
        let name = String(cString: host)
        return name == ip ? nil : name
    }
}

// MARK: - Scan sheet

struct ScanSheet: View {
    @ObservedObject var store: CameraStore
    @Environment(\.dismiss) private var dismiss

    @AppStorage("scanPrefix") private var prefix = ""
    @State private var scanning = false
    @State private var progress = 0.0
    @State private var results: [ScanResult]?
    @State private var addingIP: ScanResult?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Escanear rede").font(.title2.bold())
            Text("Procura aparelhos com vídeo RTSP (porta 554). As câmeras precisam ter a **Conta da câmera** criada no app Tapo pra aparecerem.")
                .font(.callout).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            HStack {
                Text("Rede")
                TextField("10.1.1", text: $prefix)
                    .frame(width: 110)
                    .onSubmit(scan)
                Text(".1 – .254").foregroundStyle(.secondary)
                Spacer()
                Button(scanning ? "Escaneando…" : "Escanear", action: scan)
                    .keyboardShortcut(.defaultAction)
                    .disabled(scanning || !NetScanner.isValidPrefix(prefix))
            }
            if scanning { ProgressView(value: progress) }

            resultList.frame(minHeight: 200)

            HStack {
                Text("De fora de casa, digite a rede de casa (precisa do Tailscale ligado).")
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Fechar") { dismiss() }.keyboardShortcut(.cancelAction)
            }
        }
        .padding(20)
        .frame(width: 520)
        .onAppear {
            if prefix.isEmpty { prefix = NetScanner.localPrefixes().first ?? "192.168.0" }
            if results == nil { scan() }
        }
        .sheet(item: $addingIP) { r in
            CameraForm(camera: nil, prefillHost: r.ip) { cam, pass in store.save(cam, password: pass) }
        }
    }

    @ViewBuilder private var resultList: some View {
        if let results {
            if results.isEmpty && !scanning {
                VStack(spacing: 8) {
                    Image(systemName: "questionmark.video").font(.largeTitle)
                    Text("Nada encontrado nessa rede.")
                    Text("Confira se a Conta da câmera foi criada e se o Mac está na mesma rede.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(results) { r in row(r) }
                    .listStyle(.bordered)
            }
        } else {
            Color.clear
        }
    }

    private func row(_ r: ScanResult) -> some View {
        let added = store.cameras.first { $0.host == r.ip }
        return HStack {
            Image(systemName: r.isTapo || r.hasOnvif ? "video.fill" : "network")
                .foregroundStyle(r.isTapo ? Color.accentColor : .secondary)
                .frame(width: 22)
            VStack(alignment: .leading, spacing: 2) {
                Text(r.ip).font(.body.monospacedDigit())
                Text(detail(r)).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            if let added {
                Label(added.name, systemImage: "checkmark").foregroundStyle(.secondary)
            } else {
                Button("Adicionar") { addingIP = r }
            }
        }
        .padding(.vertical, 2)
    }

    private func detail(_ r: ScanResult) -> String {
        var parts: [String] = [r.isTapo ? "Câmera Tapo / TP-Link" : r.hasOnvif ? "Provável câmera (RTSP + ONVIF)" : "Aparelho com RTSP"]
        if let h = r.hostname { parts.append(h) }
        return parts.joined(separator: " · ")
    }

    private func rank(_ r: ScanResult) -> Int { r.isTapo ? 0 : r.hasOnvif ? 1 : 2 }

    private func scan() {
        let p = prefix.trimmingCharacters(in: .whitespaces)
        guard !scanning, NetScanner.isValidPrefix(p) else { return }
        scanning = true
        progress = 0
        results = []
        Task.detached(priority: .userInitiated) {
            let found = NetScanner.scan(prefix: p) { value in
                Task { @MainActor in progress = value }
            }
            await MainActor.run {
                results = found.sorted { (rank($0), $0.ip.count, $0.ip) < (rank($1), $1.ip.count, $1.ip) }
                scanning = false
            }
        }
    }
}
