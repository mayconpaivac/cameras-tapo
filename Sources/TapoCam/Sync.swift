import CommonCrypto
import CryptoKit
import Foundation
import Security

/// The camera list published by the home PC's bridge (http://<PC>:20200/cameras).
struct PCCameraList: Decodable {
    struct Item: Decodable {
        let id: String
        let name: String
        let host: String
        let port: Int
        let username: String
        let dualLens: Bool
        let ptz: Bool
        let slot: Int
        let mac: String?
        let secret: String?
    }

    let version: Int
    let restreamPort: Int?
    let kdfSalt: String?
    let kdfIterations: Int?
    let cameras: [Item]
}

/// The PC's go2rtc credentials; the password derives from the pairing code (same as the Windows app).
enum Restream {
    static let user = "cameras"

    static func password(pairingCode: String) -> String {
        let digest = SHA256.hash(data: Data("CamerasTapo.rtsp:\(PairingCrypto.normalize(pairingCode))".utf8))
        return String(digest.map { String(format: "%02x", $0) }.joined().prefix(24))
    }
}

/// Same scheme as the Windows app: PBKDF2-SHA256 → AES-256-GCM, secret = nonce | ciphertext | tag.
enum PairingCrypto {
    static func normalize(_ code: String) -> String {
        String(code.uppercased().filter { $0.isLetter || $0.isNumber })
    }

    static func key(code: String, salt: Data, iterations: Int) -> SymmetricKey? {
        let password = Array(normalize(code).utf8)
        var out = [UInt8](repeating: 0, count: 32)
        let status = salt.withUnsafeBytes { saltPtr in
            CCKeyDerivationPBKDF(CCPBKDFAlgorithm(kCCPBKDF2),
                                 password.map { Int8(bitPattern: $0) }, password.count,
                                 saltPtr.bindMemory(to: UInt8.self).baseAddress, salt.count,
                                 CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA256), UInt32(iterations),
                                 &out, out.count)
        }
        return status == kCCSuccess ? SymmetricKey(data: out) : nil
    }

    static func decrypt(_ secret: String, key: SymmetricKey) -> String? {
        guard let data = Data(base64Encoded: secret),
              let box = try? AES.GCM.SealedBox(combined: data),
              let plain = try? AES.GCM.open(box, using: key) else { return nil }
        return String(data: plain, encoding: .utf8)
    }
}

/// Keeps the Mac's camera list in step with the home PC (the PC is the source of truth).
@MainActor
final class PCSync: ObservableObject {
    @Published private(set) var status = ""
    @Published private(set) var syncing = false
    @Published private(set) var lastSync: Date?
    @Published var pairingCode: String {
        didSet { PairingStore.save(pairingCode) }
    }

    private let store: CameraStore
    private let location: NetworkLocation
    private var timer: Timer?

    init(store: CameraStore, location: NetworkLocation) {
        self.store = store
        self.location = location
        pairingCode = PairingStore.load() ?? ""
        timer = Timer.scheduledTimer(withTimeInterval: 300, repeats: true) { [weak self] _ in
            Task { @MainActor in await self?.sync() }
        }
        Task { await sync() }
    }

    /// Cameras come from the PC as soon as its address is set.
    var isEnabled: Bool { !location.bridgeHost.trimmingCharacters(in: .whitespaces).isEmpty }

    func sync() async {
        let host = location.bridgeHost.trimmingCharacters(in: .whitespaces)
        SyncLog.write("início host=\(host) syncing=\(syncing)")
        guard !host.isEmpty, !syncing, let url = URL(string: "http://\(host):20200/cameras") else { return }
        syncing = true
        defer { syncing = false }
        do {
            var request = URLRequest(url: url, timeoutInterval: 8)
            request.cachePolicy = .reloadIgnoringLocalCacheData
            let (data, response) = try await URLSession.shared.data(for: request)
            guard (response as? HTTPURLResponse)?.statusCode == 200 else {
                status = "O PC respondeu com erro."
                return
            }
            let list = try JSONDecoder().decode(PCCameraList.self, from: data)
            let code = pairingCode
            let passwords = await Task.detached { () -> [String: String] in
                guard !code.isEmpty, let saltText = list.kdfSalt, let salt = Data(base64Encoded: saltText),
                      let key = PairingCrypto.key(code: code, salt: salt, iterations: list.kdfIterations ?? 200_000)
                else { return [:] }
                var out: [String: String] = [:]
                for cam in list.cameras {
                    if let secret = cam.secret, let pw = PairingCrypto.decrypt(secret, key: key) { out[cam.id] = pw }
                }
                return out
            }.value
            SyncLog.write("\(list.cameras.count) câmeras, \(passwords.count) senhas")
            store.replaceWithPCList(list.cameras, passwords: passwords)
            // Watch through the PC's restream when it offers one (needs the pairing code).
            SyncLog.write("retransmissão: porta=\(list.restreamPort.map(String.init) ?? "nenhuma") código=\(code.isEmpty ? "vazio" : "ok")")
            if let port = list.restreamPort, !code.isEmpty {
                location.setRestream(port: port, password: Restream.password(pairingCode: code))
            } else {
                location.setRestream(port: nil, password: nil)
            }
            lastSync = Date()
            let missing = list.cameras.count - passwords.count
            if list.cameras.isEmpty {
                status = "O PC ainda não tem câmeras. Adicione no app do Windows."
            } else if code.isEmpty {
                status = "\(list.cameras.count) câmeras. Digite o código de pareamento pra receber as senhas."
            } else if missing > 0 {
                status = "\(list.cameras.count) câmeras, mas o código de pareamento não confere."
            } else {
                status = "Sincronizado: \(list.cameras.count) câmeras."
            }
        } catch {
            SyncLog.write("erro \(error)")
            location.setRestream(port: nil, password: nil) // PC unreachable: at home, go straight to the cameras
            status = "Não achei o PC (\(error.localizedDescription)). Ele está ligado e o Tailscale conectado?"
        }
    }
}

/// The pairing code lives in the Keychain, like the camera passwords.
enum PairingStore {
    private static let service = "TapoCam.pairing"

    static func load() -> String? {
        let q: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                                kSecAttrAccount as String: "pc", kSecReturnData as String: true]
        var out: AnyObject?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess, let data = out as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func save(_ code: String) {
        let base: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                                   kSecAttrAccount as String: "pc"]
        SecItemDelete(base as CFDictionary)
        guard !code.isEmpty else { return }
        var add = base
        add[kSecValueData as String] = Data(code.utf8)
        SecItemAdd(add as CFDictionary, nil)
    }
}

/// Small log of sync attempts: ~/Library/Application Support/TapoCam/sync.log
enum SyncLog {
    static func write(_ message: String) {
        let url = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("TapoCam/sync.log")
        let line = "\(ISO8601DateFormatter().string(from: Date()))  \(message)\n"
        if let h = try? FileHandle(forWritingTo: url) {
            h.seekToEndOfFile()
            h.write(Data(line.utf8))
            try? h.close()
        } else {
            try? Data(line.utf8).write(to: url)
        }
    }
}
