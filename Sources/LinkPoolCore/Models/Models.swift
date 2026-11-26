import Foundation

// MARK: - Account

/// A campus-network account. Secrets never live in this struct: the password is
/// stored in the Keychain under `Account.secretKey`.
public struct Account: Codable, Identifiable, Hashable, Sendable {
    public var id: UUID
    /// Friendly label shown in the UI ("主账号", "测试号 2" ...).
    public var name: String
    public var username: String
    /// Portal base URL, e.g. `http://4.3.2.1`.
    public var portalURL: URL
    /// Real auth acid. `nil` means "discover from the portal page, fall back to
    /// `PortalSettings.defaultACID`".
    public var acID: String?
    public var isEnabled: Bool
    public var note: String
    public var createdAt: Date
    public var updatedAt: Date

    public init(
        id: UUID = UUID(),
        name: String,
        username: String,
        portalURL: URL = URL(string: "http://4.3.2.1")!,
        acID: String? = nil,
        isEnabled: Bool = true,
        note: String = "",
        createdAt: Date = Date(),
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.name = name
        self.username = username
        self.portalURL = portalURL
        self.acID = acID
        self.isEnabled = isEnabled
        self.note = note
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    public var secretKey: String { "account.\(id.uuidString)" }
}

// MARK: - Egress

public enum EgressKind: String, Codable, CaseIterable, Sendable {
    /// The address the interface already has (DHCP).
    case physical
    /// An extra IPv4 alias added to a physical interface (multi-dial).
    case alias
    /// Reserved for future tunnels / external links.
    case virtual

    public var displayName: String {
        switch self {
        case .physical: return "物理链路"
        case .alias: return "虚拟 IP"
        case .virtual: return "虚拟链路"
        }
    }
}

/// One authenticated exit: a source IP on an interface that carries at most one
/// campus session.
public struct Egress: Codable, Identifiable, Hashable, Sendable {
    public var id: UUID
    public var name: String
    public var interfaceName: String
    public var localAddress: String
    public var kind: EgressKind
    public var accountID: UUID?
    public var weight: Int
    public var isEnabled: Bool
    /// When true the session manager may log this egress in automatically.
    /// Defaults to false so that a freshly detected live session is never
    /// disturbed.
    public var autoLogin: Bool
    public var createdAt: Date

    public init(
        id: UUID = UUID(),
        name: String,
        interfaceName: String,
        localAddress: String,
        kind: EgressKind = .physical,
        accountID: UUID? = nil,
        weight: Int = 1,
        isEnabled: Bool = true,
        autoLogin: Bool = false,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.name = name
        self.interfaceName = interfaceName
        self.localAddress = localAddress
        self.kind = kind
        self.accountID = accountID
        self.weight = max(1, weight)
        self.isEnabled = isEnabled
        self.autoLogin = autoLogin
        self.createdAt = createdAt
    }
}

// MARK: - Settings

public enum ProxyStrategy: String, Codable, CaseIterable, Sendable {
    case roundRobin
    case leastConnections
    case weighted

    public var displayName: String {
        switch self {
        case .roundRobin: return "轮询"
        case .leastConnections: return "最少连接"
        case .weighted: return "加权"
        }
    }
}

public struct ProxySettings: Codable, Sendable, Equatable {
    public var host: String = "127.0.0.1"
    public var port: Int = 7890
    public var strategy: ProxyStrategy = .roundRobin
    /// Seconds a destination host stays pinned to one egress. 0 disables
    /// stickiness (best for bandwidth aggregation).
    public var stickySeconds: Int = 0
    public var allowLAN: Bool = false
    public var maxConnections: Int = 512
    /// When the portal API cannot be reached (unknown deployment), allow
    /// routing through links whose state could not be verified. Intended for
    /// single-link debugging; off by default.
    public var allowUnverifiedEgress: Bool = false

    public init() {}

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        host = try c.decodeIfPresent(String.self, forKey: .host) ?? "127.0.0.1"
        port = try c.decodeIfPresent(Int.self, forKey: .port) ?? 7890
        strategy = try c.decodeIfPresent(ProxyStrategy.self, forKey: .strategy) ?? .roundRobin
        stickySeconds = try c.decodeIfPresent(Int.self, forKey: .stickySeconds) ?? 0
        allowLAN = try c.decodeIfPresent(Bool.self, forKey: .allowLAN) ?? false
        maxConnections = try c.decodeIfPresent(Int.self, forKey: .maxConnections) ?? 512
        allowUnverifiedEgress = try c.decodeIfPresent(Bool.self, forKey: .allowUnverifiedEgress) ?? false
    }
}

public struct PortalSettings: Codable, Sendable, Equatable {
    public var baseURL: URL = URL(string: "http://4.3.2.1")!
    public var challengePath: String = "/cgi-bin/get_challenge"
    public var loginPath: String = "/cgi-bin/srun_portal"
    public var infoPath: String = "/cgi-bin/rad_user_info"
    public var logoutPath: String = "/cgi-bin/rad_user_dm"
    /// Entry ac_id used when fetching the portal page.
    public var entryACID: String = "1"
    /// Fallback auth acid when discovery fails.
    public var defaultACID: String = "1"
    /// Srun `type`: 0 = desktop client, 1 = mobile.
    public var clientType: String = "0"
    public var clientOS: String = "macOS"
    public var clientName: String = "Macintosh"
    public var n: String = "200"
    public var doubleStack: Bool = false

    public init() {}
}

public struct SessionSettings: Codable, Sendable, Equatable {
    /// Seconds between health checks of an online egress.
    public var checkInterval: Double = 30
    /// Backoff after a failed login, in seconds (grows to `maxBackoff`).
    public var initialBackoff: Double = 10
    public var maxBackoff: Double = 120
    /// How many consecutive failed probes before an egress is quarantined.
    public var failureThreshold: Int = 3

    public init() {}
}

// MARK: - Config document

public struct AppConfig: Codable, Sendable {
    public static let currentVersion = 1
    public var version: Int = AppConfig.currentVersion
    public var accounts: [Account] = []
    public var egresses: [Egress] = []
    public var proxy: ProxySettings = .init()
    public var portal: PortalSettings = .init()
    public var session: SessionSettings = .init()
    public var launchAtLogin: Bool = false
    public var showSpeedInMenuBar: Bool = true

    public init() {}

    public func account(id: UUID?) -> Account? {
        guard let id else { return nil }
        return accounts.first { $0.id == id }
    }

    public mutating func upsert(account: Account) {
        if let idx = accounts.firstIndex(where: { $0.id == account.id }) {
            accounts[idx] = account
        } else {
            accounts.append(account)
        }
    }

    public mutating func upsert(egress: Egress) {
        if let idx = egresses.firstIndex(where: { $0.id == egress.id }) {
            egresses[idx] = egress
        } else {
            egresses.append(egress)
        }
    }
}

// MARK: - Runtime state

public enum SessionPhase: String, Sendable {
    case unknown
    case offline
    case authenticating
    case online
    case failed
    case disabled
    /// Reachable on the network but the portal API could not confirm the
    /// session (e.g. a non-standard portal deployment).
    case unverified

    public var displayName: String {
        switch self {
        case .unknown: return "未检测"
        case .offline: return "未登录"
        case .authenticating: return "登录中"
        case .online: return "在线"
        case .failed: return "异常"
        case .disabled: return "已停用"
        case .unverified: return "未验证"
        }
    }
}

public struct SessionSnapshot: Sendable {
    public var egressID: UUID
    public var phase: SessionPhase
    public var username: String?
    public var onlineSeconds: Int?
    public var lastError: String?
    public var lastChecked: Date?
    public var publicAddress: String?

    public init(egressID: UUID, phase: SessionPhase = .unknown) {
        self.egressID = egressID
        self.phase = phase
    }
}

// MARK: - Errors

public enum LinkPoolError: LocalizedError, Sendable {
    case invalidAddress(String)
    case interfaceNotFound(String)
    case socket(String)
    case timeout(String)
    case httpStatus(Int, String)
    case portal(String)
    case protocolError(String)
    case notConfigured(String)

    public var errorDescription: String? {
        switch self {
        case .invalidAddress(let a): return "无效的 IP 地址：\(a)"
        case .interfaceNotFound(let n): return "找不到网络接口：\(n)"
        case .socket(let m): return "网络错误：\(m)"
        case .timeout(let m): return "请求超时：\(m)"
        case .httpStatus(let c, let m): return "HTTP \(c)：\(m)"
        case .portal(let m): return "门户返回错误：\(m)"
        case .protocolError(let m): return "协议错误：\(m)"
        case .notConfigured(let m): return "配置不完整：\(m)"
        }
    }
}
