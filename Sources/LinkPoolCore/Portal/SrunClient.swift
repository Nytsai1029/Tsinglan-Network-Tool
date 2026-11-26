import Foundation

public struct SrunLoginResult: Sendable {
    public let onlineIP: String?
    public let accessToken: String?
    public let message: String
}

public struct SrunOnlineStatus: Sendable {
    public let isOnline: Bool
    /// False when the portal could not be reached at all (transient network
    /// error) as opposed to a definitive "not logged in" answer.
    public let reachable: Bool
    public let userName: String?
    public let onlineIP: String?
    public let productName: String?
    public let balance: String?
    public let errorMessage: String?
}

public enum SrunError: Error, LocalizedError {
    case portalError(String)
    case missingField(String)
    case invalidJSON(String)

    public var errorDescription: String? {
        switch self {
        case .portalError(let m): return m
        case .missingField(let f): return "门户响应缺少字段 \(f)"
        case .invalidJSON(let s): return "无法解析门户响应：\(s)"
        }
    }
}

/// Srun 4.0 portal client.
///
/// Every request can be pinned to an `EgressSource`, which is the mechanism
/// that lets N sessions coexist on one Mac: the TCP connection carrying the
/// login for egress X must leave through X's source address, otherwise the AC
/// attaches the session to the wrong client.
public final class SrunClient {
    private let http: HTTPClient

    public init(http: HTTPClient = HTTPClient(timeout: 6)) {
        self.http = http
    }

    // MARK: - Public API

    public func fetchChallenge(username: String, clientIP: String, base: URL,
                               settings: PortalSettings, source: EgressSource?) throws -> String {
        var components = URLComponents(url: base.appendingPathComponent(settings.challengePath),
                                       resolvingAgainstBaseURL: false)
        components?.queryItems = nil
        let url = try makeURL(base: base, path: settings.challengePath, query: [
            ("callback", "sdu"),
            ("username", username),
            ("ip", clientIP),
            ("_", timestamp())
        ])
        let response = try http.get(url, headers: ["Referer": base.absoluteString], source: source)
        let json = try parseJSONP(response.text)
        if let challenge = json["challenge"] as? String, !challenge.isEmpty {
            return challenge
        }
        throw SrunError.missingField("challenge")
    }

    public func login(account: Account, password: String, clientIP: String,
                      settings: PortalSettings, source: EgressSource?,
                      acidOverride: String? = nil) throws -> SrunLoginResult {
        let base = account.portalURL
        let token = try fetchChallenge(username: account.username, clientIP: clientIP,
                                       base: base, settings: settings, source: source)
        let acid = acidOverride ?? account.acID ?? discoverACID(base: base, settings: settings, source: source) ?? settings.defaultACID

        let hmac = SrunCrypto.hmacMD5Hex(key: token, message: password)
        let hashedPassword = "{MD5}" + hmac
        let infoJSON = infoJSON(username: account.username, password: password,
                                ip: clientIP, acid: acid)
        let info = SrunCrypto.encodeUserInfo(json: infoJSON, token: token)
        let chksum = SrunCrypto.sha1Hex(
            token + account.username +
            token + hmac +
            token + acid +
            token + clientIP +
            token + settings.n +
            token + settings.clientType +
            token + info
        )

        let query: [(String, String)] = [
            ("callback", "sdu"),
            ("action", "login"),
            ("username", account.username),
            ("password", hashedPassword),
            ("ip", clientIP),
            ("ac_id", acid),
            ("n", settings.n),
            ("type", settings.clientType),
            ("os", settings.clientOS),
            ("name", settings.clientName),
            ("double_stack", settings.doubleStack ? "1" : "0"),
            ("info", info),
            ("chksum", chksum),
            ("_", timestamp())
        ]
        let url = try makeURL(base: base, path: settings.loginPath, query: query)
        let response = try http.get(url, headers: [
            "Referer": base.absoluteString,
            "X-Requested-With": "XMLHttpRequest"
        ], source: source)
        let json = try parseJSONP(response.text)

        let error = (json["error"] as? String) ?? ""
        let data = json["data"] as? [String: Any]
        let accessToken = data?["access_token"] as? String
        let onlineIP = data?["online_ip"] as? String
        let succeeded = error == "ok" || (accessToken?.isEmpty == false)
        guard succeeded else {
            let message = (json["error_msg"] as? String)
                ?? (json["suc_msg"] as? String)
                ?? (error.isEmpty ? "门户返回未知错误" : error)
            throw SrunError.portalError(message)
        }
        return SrunLoginResult(onlineIP: onlineIP,
                               accessToken: accessToken,
                               message: (json["suc_msg"] as? String) ?? "登录成功")
    }

    public func status(clientIP: String, base: URL, settings: PortalSettings,
                       source: EgressSource?) -> SrunOnlineStatus {
        do {
            let url = try makeURL(base: base, path: settings.infoPath, query: [
                ("callback", "jsonp"),
                ("ip", clientIP),
                ("_", timestamp())
            ])
            let response = try http.get(url, source: source)
            if response.status == 404 {
                return SrunOnlineStatus(isOnline: false, reachable: false, userName: nil, onlineIP: nil,
                                        productName: nil, balance: nil,
                                        errorMessage: "门户没有标准 Srun 接口（\(settings.infoPath) 返回 404）")
            }
            let json = try parseJSONP(response.text)
            let error = (json["error"] as? String) ?? ""
            guard error == "ok" else {
                return SrunOnlineStatus(isOnline: false, reachable: true, userName: nil, onlineIP: nil,
                                        productName: nil, balance: nil,
                                        errorMessage: (json["error_msg"] as? String) ?? error)
            }
            let user = (json["user_name"] as? String) ?? (json["userName"] as? String)
            return SrunOnlineStatus(isOnline: !(user?.isEmpty ?? true), reachable: true,
                                    userName: user,
                                    onlineIP: json["online_ip"] as? String,
                                    productName: json["products_name"] as? String,
                                    balance: (json["online_balance"] as? String).map { $0 },
                                    errorMessage: nil)
        } catch {
            return SrunOnlineStatus(isOnline: false, reachable: false, userName: nil, onlineIP: nil,
                                    productName: nil, balance: nil,
                                    errorMessage: error.localizedDescription)
        }
    }

    /// Discovers the real `acid` from the portal page. Only reachable for
    /// clients the AC still considers unauthenticated; returns nil otherwise.
    public func discoverACID(base: URL, settings: PortalSettings, source: EgressSource?) -> String? {
        guard let url = try? makeURL(base: base, path: "/srun_portal_pc",
                                     query: [("ac_id", settings.entryACID), ("theme", "proyx")]) else {
            return nil
        }
        guard let response = try? http.getFollowingRedirects(url, source: source),
              response.status == 200 else { return nil }
        let pattern = #"acid\s*:\s*"(\d+)""#
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: response.text, range: NSRange(response.text.startIndex..., in: response.text)),
              let range = Range(match.range(at: 1), in: response.text) else { return nil }
        return String(response.text[range])
    }

    /// Explicit logout. Never called automatically by the session manager:
    /// logging out the machine's primary session would cut the network.
    public func logout(username: String, clientIP: String, base: URL,
                       settings: PortalSettings, source: EgressSource?) throws {
        let time = String(Int(Date().timeIntervalSince1970))
        let sign = SrunCrypto.sha1Hex(time + username + clientIP + "1" + time)
        let url = try makeURL(base: base, path: settings.logoutPath, query: [
            ("callback", "sdu"),
            ("ip", clientIP),
            ("username", username),
            ("time", time),
            ("unbind", "1"),
            ("sign", sign),
            ("_", timestamp())
        ])
        let response = try http.get(url, source: source)
        let json = try parseJSONP(response.text)
        let error = (json["error"] as? String) ?? ""
        guard error == "ok" else { throw SrunError.portalError(error.isEmpty ? "注销失败" : error) }
    }

    // MARK: - Helpers

    private func infoJSON(username: String, password: String, ip: String, acid: String) -> String {
        // Key order is part of the protocol: the server re-serialises and
        // compares. Do not sort.
        "{\"username\":\"\(escape(username))\",\"password\":\"\(escape(password))\"," +
        "\"ip\":\"\(escape(ip))\",\"acid\":\"\(escape(acid))\",\"enc_ver\":\"srun_bx1\"}"
    }

    private func escape(_ string: String) -> String {
        var out = ""
        for scalar in string.unicodeScalars {
            switch scalar {
            case "\"": out += "\\\""
            case "\\": out += "\\\\"
            case "\n": out += "\\n"
            case "\r": out += "\\r"
            case "\t": out += "\\t"
            default:
                if scalar.value < 0x20 {
                    out += String(format: "\\u%04x", scalar.value)
                } else {
                    out.unicodeScalars.append(scalar)
                }
            }
        }
        return out
    }

    private func timestamp() -> String {
        String(Int(Date().timeIntervalSince1970 * 1000))
    }

    private func makeURL(base: URL, path: String, query: [(String, String)]) throws -> URL {
        var string = base.absoluteString
        while string.hasSuffix("/") { string.removeLast() }
        string += path
        var pairs: [String] = []
        for (key, value) in query {
            pairs.append("\(percentEncode(key))=\(percentEncode(value))")
        }
        if !pairs.isEmpty { string += "?" + pairs.joined(separator: "&") }
        guard let url = URL(string: string) else { throw HTTPError.invalidURL(string) }
        return url
    }

    private func percentEncode(_ string: String) -> String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        return string.addingPercentEncoding(withAllowedCharacters: allowed) ?? string
    }

    private func parseJSONP(_ text: String) throws -> [String: Any] {
        var body = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if let open = body.firstIndex(of: "("), let close = body.lastIndex(of: ")"), open < close {
            body = String(body[body.index(after: open)..<close])
        }
        guard let data = body.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw SrunError.invalidJSON(String(text.prefix(200)))
        }
        return object
    }
}
