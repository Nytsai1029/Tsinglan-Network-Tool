import Foundation

public struct PortalStatus: Sendable {
    public let isOnline: Bool
    /// False when neither the captive probe nor the portal root answered, so
    /// we cannot tell whether we are online. SessionManager surfaces this as
    /// `.unverified` instead of pretending the egress is offline.
    public let reachable: Bool
    public let userName: String?
    public let onlineIP: String?
    public let productName: String?
    public let balance: String?
    public let errorMessage: String?

    public init(isOnline: Bool, reachable: Bool, userName: String? = nil,
                onlineIP: String? = nil, productName: String? = nil,
                balance: String? = nil, errorMessage: String? = nil) {
        self.isOnline = isOnline
        self.reachable = reachable
        self.userName = userName
        self.onlineIP = onlineIP
        self.productName = productName
        self.balance = balance
        self.errorMessage = errorMessage
    }
}

public struct PortalLoginResult: Sendable {
    public let onlineIP: String?
    public let accessToken: String?
    public let message: String
}

public enum PortalError: Error, LocalizedError {
    case portalError(String)
    case unreachable(String)
    case invalidResponse(String)

    public var errorDescription: String? {
        switch self {
        case .portalError(let m): return m
        case .unreachable(let m): return "门户不可达：\(m)"
        case .invalidResponse(let s): return "无法解析门户响应：\(s)"
        }
    }
}

/// Huawei Agile Controller-Campus (`/ac_portal/...`) client.
///
/// Login is a single form POST; the AC binds the session to the TCP source
/// address, which is why every request accepts an `EgressSource`.
public final class HuaweiACClient {
    private let http: HTTPClient
    private let browserUA = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) "
        + "AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Safari/605.1.15"

    public init(timeout: TimeInterval = 8) {
        self.http = HTTPClient(timeout: timeout, maxBodyBytes: 512 * 1024, userAgent: browserUA)
    }

    // MARK: - Status

    private enum Probe {
        case online
        case captive(URL?)
        case unreachable(String)
    }

    public func status(base: URL, settings: PortalSettings, source: EgressSource?) -> PortalStatus {
        let probe = probeCaptive(settings: settings, source: source)
        switch probe {
        case .online:
            return PortalStatus(isOnline: true, reachable: true)
        case .captive(let url):
            return PortalStatus(isOnline: false, reachable: true,
                                errorMessage: url.map { "需要登录（\($0.host ?? "门户")）" } ?? "需要登录")
        case .unreachable(let message):
            // A failed DNS lookup is normal before authentication (the AC
            // blocks resolution), so fall back to asking the portal itself.
            if let verdict = portalRootVerdict(base: base, source: source) {
                return verdict
            }
            return PortalStatus(isOnline: false, reachable: false, errorMessage: message)
        }
    }

    /// 204 from the captive endpoint means the device already has internet.
    private func probeCaptive(settings: PortalSettings, source: EgressSource?) -> Probe {
        guard let url = URL(string: settings.captiveCheckURL), url.scheme == "http" else {
            return .unreachable("探测地址无效")
        }
        do {
            let response = try http.get(url, headers: ["Accept": "*/*"], source: source)
            if response.status == 204 || response.status == 200 {
                let text = response.text.lowercased()
                if text.contains("ac_portal") || text.contains("上网认证") {
                    return .captive(nil)
                }
                return .online
            }
            if (300..<400).contains(response.status) {
                if let location = response.header("location"),
                   let target = URL(string: location, relativeTo: url)?.absoluteURL {
                    if isPortalURL(target) { return .captive(target) }
                    // Redirect to a normal site: the device is online.
                    return .online
                }
                return .captive(nil)
            }
            if response.status == 403 || response.status == 401 {
                return .captive(nil)
            }
            return .unreachable("探测返回 HTTP \(response.status)")
        } catch {
            return .unreachable(error.localizedDescription)
        }
    }

    /// The portal root redirects to `/homepage/index.html` when the client is
    /// already authenticated and to `/ac_portal/...` when it is not.
    private func portalRootVerdict(base: URL, source: EgressSource?) -> PortalStatus? {
        guard let response = try? http.get(base, headers: ["Accept": "text/html"], source: source) else {
            return nil
        }
        let location = response.header("location").flatMap { URL(string: $0, relativeTo: base)?.absoluteURL }
        if let location {
            let path = location.absoluteString.lowercased()
            if path.contains("homepage") { return PortalStatus(isOnline: true, reachable: true) }
            if isPortalURL(location) {
                return PortalStatus(isOnline: false, reachable: true, errorMessage: "需要登录")
            }
        }
        if response.status == 200 {
            let text = response.text.lowercased()
            if text.contains("homepage/index") || text.contains("个人管理") { return PortalStatus(isOnline: true, reachable: true) }
            if text.contains("ac_portal") { return PortalStatus(isOnline: false, reachable: true) }
        }
        return nil
    }

    private func isPortalURL(_ url: URL) -> Bool {
        let text = url.path.lowercased()
        return text.contains("ac_portal") || text.contains("portal")
    }

    // MARK: - Login

    public func login(account: Account, password: String, settings: PortalSettings,
                      source: EgressSource?) throws -> PortalLoginResult {
        let base = account.portalURL
        guard var components = URLComponents(url: base, resolvingAgainstBaseURL: false) else {
            throw PortalError.unreachable("门户地址无效")
        }
        components.path = settings.huaweiLoginPath
        guard let url = components.url else { throw PortalError.unreachable("登录地址无效") }

        // The page uses `+(new Date())`, i.e. milliseconds since epoch.
        let authTag = String(Int64(Date().timeIntervalSince1970 * 1000))
        let plain = password.trimmingCharacters(in: .whitespacesAndNewlines)
        let encrypted = HuaweiPortalCrypto.rc4Hex(plain, key: authTag)

        let form = [
            "opr": "pwdLogin",
            "userName": account.username,
            "pwd": encrypted,
            "auth_tag": authTag,
            "rememberPwd": "1"
        ]
        let headers = [
            "Referer": base.absoluteString + "/",
            "Origin": base.absoluteString,
            "Accept": "application/json, text/javascript, */*; q=0.01",
            "X-Requested-With": "XMLHttpRequest"
        ]

        let response: HTTPResponse
        do {
            response = try http.post(url, form: form, headers: headers, source: source)
        } catch {
            throw PortalError.unreachable(error.localizedDescription)
        }

        guard let object = try? JSONSerialization.jsonObject(with: response.body) as? [String: Any] else {
            let snippet = response.text.trimmingCharacters(in: .whitespacesAndNewlines).prefix(160)
            throw PortalError.invalidResponse(snippet.isEmpty ? "HTTP \(response.status)" : String(snippet))
        }

        let success = (object["success"] as? Bool) == true
            || (object["success"] as? Int) == 1
            || (object["success"] as? String)?.lowercased() == "true"
        let message = (object["msg"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard success else {
            throw PortalError.portalError(message.isEmpty ? "登录被拒绝（HTTP \(response.status)）" : message)
        }

        let userName = object["userName"] as? String
        return PortalLoginResult(onlineIP: nil,
                                 accessToken: object["token"] as? String,
                                 message: message.isEmpty ? (userName.map { "登录成功：\($0)" } ?? "登录成功") : message)
    }

    /// Explicit logout. The AC identifies the session by the TCP source
    /// address, so callers must pass the egress that owns the session.
    @discardableResult
    public func logout(base: URL, settings: PortalSettings, source: EgressSource?) throws -> String {
        guard var components = URLComponents(url: base, resolvingAgainstBaseURL: false) else {
            throw PortalError.unreachable("门户地址无效")
        }
        components.path = settings.huaweiLoginPath
        guard let url = components.url else { throw PortalError.unreachable("注销地址无效") }

        let headers = [
            "Referer": base.absoluteString + "/",
            "Origin": base.absoluteString,
            "Accept": "application/json, text/javascript, */*; q=0.01",
            "X-Requested-With": "XMLHttpRequest"
        ]
        let response: HTTPResponse
        do {
            response = try http.post(url, form: ["opr": "logout"], headers: headers, source: source)
        } catch {
            throw PortalError.unreachable(error.localizedDescription)
        }
        guard let object = try? JSONSerialization.jsonObject(with: response.body) as? [String: Any] else {
            throw PortalError.invalidResponse("HTTP \(response.status)")
        }
        let success = (object["success"] as? Bool) == true
            || (object["success"] as? Int) == 1
            || (object["success"] as? String)?.lowercased() == "true"
        let message = (object["msg"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard success else {
            throw PortalError.portalError(message.isEmpty ? "注销被拒绝（HTTP \(response.status)）" : message)
        }
        return message.isEmpty ? "已注销" : message
    }
}
