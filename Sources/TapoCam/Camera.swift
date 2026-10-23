import Foundation
import Security

/// Where to reach a camera: directly at home, or through the home PC when away.
/// `restreamPassword` set = video comes from the home PC's go2rtc (rtsp://host:port/cam<slot>_<lens>).
struct Endpoint: Hashable {
    var host: String
    var rtspPort: Int
    var onvifPort: Int
    var onvifHost: String? = nil
    var restreamPassword: String? = nil

    var ptzHost: String { onvifHost ?? host }
}

struct Camera: Codable, Identifiable, Hashable {
    var id = UUID()
    var name: String
    var host: String
    var port: Int = 554
    var username: String
    /// Two video sources (e.g. C245D): lens 0 = stream1/2, lens 1 = stream6/7.
    var dualLens = false
    /// Pan/tilt through ONVIF (C206, C245D, C200…).
    var ptz = false
    /// Bumped on every edit so open players reconnect with new settings.
    var revision = 0
    /// Hardware address, used by the Windows bridge to find the camera when its IP changes.
    var mac: String?
    /// Fixed number for this camera's ports on the Windows bridge (RTSP 5540+slot, ONVIF 20200+slot).
    var slot = 0

    static let onvifPort = 2020

    var lenses: [Int] { dualLens ? [0, 1] : [0] }

    var localEndpoint: Endpoint { Endpoint(host: host, rtspPort: port, onvifPort: Camera.onvifPort) }
    var bridgeRTSPPort: Int { 5540 + slot }
    var bridgeONVIFPort: Int { 20200 + slot }

    func lensName(_ lens: Int) -> String? {
        guard dualLens else { return nil }
        return lens == 0 ? "Grande-angular" : "Zoom"
    }

    /// High quality = stream1/stream6, light = stream2/stream7 (used in the grid).
    func rtspURL(password: String, lens: Int = 0, highQuality: Bool, via endpoint: Endpoint? = nil) -> String {
        let target = endpoint ?? localEndpoint
        if let rp = target.restreamPassword { // restreamed by the home PC: always full quality
            let pw = rp.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? rp
            return "rtsp://\(Restream.user):\(pw)@\(target.host):\(target.rtspPort)/cam\(slot)_\(lens)"
        }
        let allowed = CharacterSet.urlUserAllowed.subtracting(CharacterSet(charactersIn: ":@/?#"))
        let user = username.addingPercentEncoding(withAllowedCharacters: allowed) ?? username
        let pass = password.addingPercentEncoding(withAllowedCharacters: allowed) ?? password
        let path = lens == 0 ? (highQuality ? "stream1" : "stream2")
                             : (highQuality ? "stream6" : "stream7")
        return "rtsp://\(user):\(pass)@\(target.host):\(target.rtspPort)/\(path)"
    }
}

extension Camera {
    private enum CodingKeys: String, CodingKey {
        case id, name, host, port, username, dualLens, ptz, revision, mac, slot
    }

    // Tolerates files saved by older versions (missing keys get defaults).
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        host = try c.decode(String.self, forKey: .host)
        port = try c.decodeIfPresent(Int.self, forKey: .port) ?? 554
        username = try c.decode(String.self, forKey: .username)
        dualLens = try c.decodeIfPresent(Bool.self, forKey: .dualLens) ?? false
        ptz = try c.decodeIfPresent(Bool.self, forKey: .ptz) ?? false
        revision = try c.decodeIfPresent(Int.self, forKey: .revision) ?? 0
        mac = try c.decodeIfPresent(String.self, forKey: .mac)
        slot = try c.decodeIfPresent(Int.self, forKey: .slot) ?? 0
    }
}

/// Grid order, saved as comma-separated feed ids (`feedOrder` in UserDefaults).
enum FeedOrder {
    /// `legacy` is the old single "featured" feed, used until the user rearranges.
    static func parse(_ stored: String, legacy: String) -> [String] {
        if stored.isEmpty { return legacy.isEmpty ? [] : [legacy] }
        return stored.split(separator: ",").map(String.init)
    }

    /// Swaps the feed with whatever sits at `index` (or sends it last when that spot is empty).
    static func swap(_ current: [Feed], id: String, index: Int) -> String {
        var ids = current.map(\.id)
        guard let from = ids.firstIndex(of: id) else { return ids.joined(separator: ",") }
        if index < ids.count { ids.swapAt(from, index) } else { ids.append(ids.remove(at: from)) }
        return ids.joined(separator: ",")
    }

    /// Moves the feed to `index`, shifting the others.
    static func insert(_ current: [Feed], id: String, index: Int) -> String {
        var ids = current.map(\.id)
        guard let from = ids.firstIndex(of: id) else { return ids.joined(separator: ",") }
        ids.remove(at: from)
        ids.insert(id, at: min(max(index, 0), ids.count))
        return ids.joined(separator: ",")
    }
}

/// One video source shown on screen: a camera plus which lens.
struct Feed: Identifiable, Hashable {
    let camera: Camera
    let lens: Int
    var id: String { "\(camera.id)-\(lens)" }
    var title: String {
        camera.lensName(lens).map { "\(camera.name) · \($0)" } ?? camera.name
    }
}

@MainActor
final class CameraStore: ObservableObject {
    @Published private(set) var cameras: [Camera] = []

    var feeds: [Feed] {
        cameras.flatMap { cam in cam.lenses.map { Feed(camera: cam, lens: $0) } }
    }

    /// Feeds in the order the user arranged them (drag and drop). New ones go last.
    /// The first one takes the big spot in featured layouts.
    func orderedFeeds(order: [String]) -> [Feed] {
        var rank: [String: Int] = [:]
        for (i, id) in order.enumerated() where rank[id] == nil { rank[id] = i }
        return feeds.enumerated()
            .sorted { a, b in
                let ra = rank[a.element.id] ?? .max, rb = rank[b.element.id] ?? .max
                return ra != rb ? ra < rb : a.offset < b.offset
            }
            .map(\.element)
    }

    private let fileURL: URL = {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("TapoCam", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("cameras.json")
    }()

    init() {
        if let data = try? Data(contentsOf: fileURL),
           let list = try? JSONDecoder().decode([Camera].self, from: data) {
            cameras = list
        }
        assignMissingSlots()
        Keychain.adoptExisting(cameras.map(\.id))
    }

    func save(_ camera: Camera, password: String?) {
        var camera = camera
        camera.revision += 1
        if camera.slot == 0 { camera.slot = nextSlot() }
        if let i = cameras.firstIndex(where: { $0.id == camera.id }) {
            cameras[i] = camera
        } else {
            cameras.append(camera)
        }
        if let password { Keychain.set(password, for: camera.id) }
        persist()
    }

    func remove(_ camera: Camera) {
        cameras.removeAll { $0.id == camera.id }
        Keychain.delete(camera.id)
        persist()
    }

    func setMAC(_ mac: String, for id: UUID) {
        guard let i = cameras.firstIndex(where: { $0.id == id }), cameras[i].mac != mac else { return }
        cameras[i].mac = mac // no revision bump: the stream doesn't need to restart
        persist()
    }

    /// Replaces the list with the home PC's (the PC is the source of truth).
    /// Unchanged cameras keep their revision, so their streams don't restart.
    func replaceWithPCList(_ items: [PCCameraList.Item], passwords: [String: String]) {
        // An empty PC (not set up yet) must not wipe the cameras already on this Mac.
        guard !items.isEmpty || cameras.isEmpty else { return }
        var next: [Camera] = []
        for item in items {
            guard let id = UUID(uuidString: item.id) else { continue }
            let old = cameras.first { $0.id == id }
            var cam = old ?? Camera(id: id, name: item.name, host: item.host, username: item.username)
            cam.name = item.name
            cam.host = item.host
            cam.port = item.port
            cam.username = item.username
            cam.dualLens = item.dualLens
            cam.ptz = item.ptz
            cam.slot = item.slot
            cam.mac = item.mac
            var changed = old == nil || old != cam
            if let pw = passwords[item.id], Keychain.get(id) != pw {
                Keychain.set(pw, for: id)
                changed = true
            }
            if changed { cam.revision = (old?.revision ?? 0) + 1 }
            next.append(cam)
        }
        for gone in cameras where !next.contains(where: { $0.id == gone.id }) { Keychain.delete(gone.id) }
        guard next != cameras else { return }
        cameras = next
        persist()
    }

    /// Slots never change once given, so the Windows bridge ports stay valid.
    private func nextSlot() -> Int { (cameras.map(\.slot).max() ?? 0) + 1 }

    private func assignMissingSlots() {
        guard cameras.contains(where: { $0.slot == 0 }) else { return }
        for i in cameras.indices where cameras[i].slot == 0 { cameras[i].slot = nextSlot() }
        persist()
    }

    private func persist() {
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted]
        try? enc.encode(cameras).write(to: fileURL, options: .atomic)
    }
}

/// Camera passwords live in the macOS Keychain, never in the JSON file.
/// Each one is read once per launch and kept in memory, so macOS asks at most once.
enum Keychain {
    private static let service = "TapoCam.camera"
    private static var cache: [UUID: String] = [:]
    private static let lock = NSLock()
    private static let adoptedKey = "keychainAdoptedBySignedApp"

    static func get(_ id: UUID) -> String? {
        lock.lock(); defer { lock.unlock() }
        if let cached = cache[id] { return cached }
        let value = read(id)
        cache[id] = value
        return value
    }

    /// Items saved by an older build belong to that build, so macOS keeps asking.
    /// Re-saving them once makes this (stable-signed) app their owner.
    static func adoptExisting(_ ids: [UUID]) {
        guard !UserDefaults.standard.bool(forKey: adoptedKey) else { return }
        for id in ids {
            if let value = get(id) { set(value, for: id) }
        }
        UserDefaults.standard.set(true, forKey: adoptedKey)
    }

    private static func read(_ id: UUID) -> String? {
        let q: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: id.uuidString,
            kSecReturnData as String: true,
        ]
        var out: AnyObject?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess,
              let data = out as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func set(_ value: String, for id: UUID) {
        delete(id)
        lock.lock(); cache[id] = value; lock.unlock()
        let q: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: id.uuidString,
            kSecValueData as String: Data(value.utf8),
        ]
        SecItemAdd(q as CFDictionary, nil)
    }

    static func delete(_ id: UUID) {
        lock.lock(); cache[id] = nil; lock.unlock()
        let q: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: id.uuidString,
        ]
        SecItemDelete(q as CFDictionary)
    }
}
