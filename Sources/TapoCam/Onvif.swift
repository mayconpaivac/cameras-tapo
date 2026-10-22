import CryptoKit
import Foundation

struct PTZPreset: Identifiable, Hashable {
    let id: String // preset token
    let name: String
}

/// Minimal ONVIF client for Tapo cameras: pan/tilt and saved positions.
/// Tapo serves every ONVIF service at http://<ip>:2020/onvif/service.
actor OnvifClient {
    enum Failure: LocalizedError {
        case http(Int), fault(String), noPTZ
        var errorDescription: String? {
            switch self {
            case .http(let code): return code == 401 ? "Usuário ou senha errados" : "Erro HTTP \(code)"
            case .fault(let msg): return msg
            case .noPTZ: return "Câmera sem PTZ"
            }
        }
    }

    private let host: String
    private let port: Int
    private let username: String
    private let password: String
    private var serviceURL: URL?
    private var profileToken: String?

    init(host: String, port: Int = 2020, username: String, password: String) {
        self.host = host
        self.port = port
        self.username = username
        self.password = password
    }

    // MARK: Public API

    func hasPTZ() async throws -> Bool {
        do { _ = try await ptzProfile(); return true } catch Failure.noPTZ { return false }
    }

    /// Velocity from -1 to 1. Keeps moving until `stop()`.
    func move(x: Double, y: Double) async throws {
        let token = try await ptzProfile()
        _ = try await call("""
            <tptz:ContinuousMove><tptz:ProfileToken>\(token)</tptz:ProfileToken>\
            <tptz:Velocity><tt:PanTilt x="\(x)" y="\(y)"/></tptz:Velocity></tptz:ContinuousMove>
            """)
    }

    func stop() async throws {
        let token = try await ptzProfile()
        _ = try await call("""
            <tptz:Stop><tptz:ProfileToken>\(token)</tptz:ProfileToken>\
            <tptz:PanTilt>true</tptz:PanTilt><tptz:Zoom>false</tptz:Zoom></tptz:Stop>
            """)
    }

    func presets() async throws -> [PTZPreset] {
        let token = try await ptzProfile()
        let xml = try await call("<tptz:GetPresets><tptz:ProfileToken>\(token)</tptz:ProfileToken></tptz:GetPresets>")
        return matches(#"<tptz:Preset token="([^"]+)"[^>]*>\s*<tt:Name>([^<]*)</tt:Name>"#, in: xml).map {
            PTZPreset(id: $0[0], name: $0[1].trimmingCharacters(in: .whitespaces))
        }
    }

    func goTo(_ preset: PTZPreset) async throws {
        let token = try await ptzProfile()
        _ = try await call("""
            <tptz:GotoPreset><tptz:ProfileToken>\(token)</tptz:ProfileToken>\
            <tptz:PresetToken>\(preset.id)</tptz:PresetToken></tptz:GotoPreset>
            """)
    }

    // MARK: Internals

    private func service() async throws -> URL {
        if let serviceURL { return serviceURL }
        let device = URL(string: "http://\(host):\(port)/onvif/device_service")!
        let xml = try await call(
            "<tds:GetCapabilities><tds:Category>All</tds:Category></tds:GetCapabilities>", url: device)
        let ptz = matches(#"<tt:PTZ>\s*<tt:XAddr>([^<]+)"#, in: xml).first?.first
        let media = matches(#"<tt:Media>\s*<tt:XAddr>([^<]+)"#, in: xml).first?.first
        // Use the advertised address only for its path: the host may be unreachable over VPN.
        let path = URL(string: ptz ?? media ?? "")?.path
        let url = URL(string: "http://\(host):\(port)\(path?.isEmpty == false ? path! : "/onvif/service")")!
        serviceURL = url
        return url
    }

    private func ptzProfile() async throws -> String {
        if let profileToken { return profileToken }
        let xml = try await call("<trt:GetProfiles/>")
        // First profile that carries a PTZ configuration.
        let blocks = xml.components(separatedBy: "<trt:Profiles ").dropFirst()
        for block in blocks where block.contains("PTZConfiguration") {
            if let token = matches(#"token="([^"]+)""#, in: block).first?.first {
                profileToken = token
                return token
            }
        }
        throw Failure.noPTZ
    }

    private func call(_ body: String, url: URL? = nil) async throws -> String {
        let target: URL
        if let url { target = url } else { target = try await service() }

        var req = URLRequest(url: target, timeoutInterval: 8)
        req.httpMethod = "POST"
        req.setValue("application/soap+xml; charset=utf-8", forHTTPHeaderField: "Content-Type")
        req.httpBody = Data(envelope(body).utf8)

        let (data, response) = try await URLSession.shared.data(for: req)
        let text = String(decoding: data, as: UTF8.self)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        if status == 401 || text.contains("NotAuthorized") { throw Failure.http(401) }
        if text.contains("Fault>") {
            let reason = matches(#"<(?:\w+:)?Text[^>]*>([^<]+)<"#, in: text).first?.first
            throw Failure.fault(reason ?? "A câmera recusou o comando")
        }
        guard (200..<300).contains(status) else { throw Failure.http(status) }
        return text
    }

    /// SOAP envelope with WS-Security UsernameToken (password digest).
    private func envelope(_ body: String) -> String {
        let nonce = Data((0..<16).map { _ in UInt8.random(in: 0...255) })
        let fmt = ISO8601DateFormatter()
        fmt.formatOptions = [.withInternetDateTime]
        let created = fmt.string(from: Date())
        let digest = Data(Insecure.SHA1.hash(data: nonce + Data(created.utf8) + Data(password.utf8)))
        return """
            <s:Envelope xmlns:s="http://www.w3.org/2003/05/soap-envelope" \
            xmlns:tds="http://www.onvif.org/ver10/device/wsdl" \
            xmlns:trt="http://www.onvif.org/ver10/media/wsdl" \
            xmlns:tptz="http://www.onvif.org/ver20/ptz/wsdl" \
            xmlns:tt="http://www.onvif.org/ver10/schema"><s:Header>\
            <Security s:mustUnderstand="1" xmlns="http://docs.oasis-open.org/wss/2004/01/oasis-200401-wss-wssecurity-secext-1.0.xsd">\
            <UsernameToken><Username>\(xmlEscape(username))</Username>\
            <Password Type="http://docs.oasis-open.org/wss/2004/01/oasis-200401-wss-username-token-profile-1.0#PasswordDigest">\
            \(digest.base64EncodedString())</Password>\
            <Nonce EncodingType="http://docs.oasis-open.org/wss/2004/01/oasis-200401-wss-soap-message-security-1.0#Base64Binary">\
            \(nonce.base64EncodedString())</Nonce>\
            <Created xmlns="http://docs.oasis-open.org/wss/2004/01/oasis-200401-wss-wssecurity-utility-1.0.xsd">\(created)</Created>\
            </UsernameToken></Security></s:Header><s:Body>\(body)</s:Body></s:Envelope>
            """
    }

    private func xmlEscape(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
    }

    private func matches(_ pattern: String, in text: String) -> [[String]] {
        guard let re = try? NSRegularExpression(pattern: pattern) else { return [] }
        let ns = text as NSString
        return re.matches(in: text, range: NSRange(location: 0, length: ns.length)).map { m in
            (1..<m.numberOfRanges).map { ns.substring(with: m.range(at: $0)) }
        }
    }
}
