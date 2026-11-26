import Foundation

public extension Notification.Name {
    static let linkPoolSessionsDidChange = Notification.Name("com.nytsai.linkpool.sessions.change")
}

/// Keeps one campus session per egress alive.
///
/// Safety rules baked in:
/// * Never calls `rad_user_dm` (logout) automatically.
/// * `autoLogin` is opt-in per egress; a detected live session is only read.
/// * At most one request per egress is in flight at a time.
public final class SessionManager: @unchecked Sendable {
    public struct EgressRuntime: Sendable {
        public var phase: SessionPhase = .unknown
        public var username: String?
        public var lastError: String?
        public var lastChecked: Date?
        public var onlineSince: Date?
        public var consecutiveFailures: Int = 0
        public var nextAttempt: Date?

        public init() {}
    }

    // Config / lifecycle live on a serial queue; network work runs concurrently.
    private let control = DispatchQueue(label: "com.nytsai.linkpool.session.control")
    private let work = DispatchQueue(label: "com.nytsai.linkpool.session.work", attributes: .concurrent)
    private let stateLock = NSLock()
    private var runtime: [UUID: EgressRuntime] = [:]
    private var inFlight: Set<UUID> = []

    private let configStore: ConfigStore
    private let portal: PortalService
    private var config: AppConfig
    private var timer: DispatchSourceTimer?
    private var running = false

    public init(configStore: ConfigStore = .shared, portal: PortalService = PortalService()) {
        self.configStore = configStore
        self.portal = portal
        self.config = configStore.load()
        for egress in config.egresses { runtime[egress.id] = EgressRuntime() }
    }

    // MARK: - Lifecycle

    public func start() {
        control.async { [weak self] in
            guard let self, !self.running else { return }
            self.running = true
            let source = DispatchSource.makeTimerSource(queue: self.control)
            source.schedule(deadline: .now() + 0.2,
                            repeating: max(5, self.config.session.checkInterval))
            source.setEventHandler { [weak self] in self?.checkAllOnControl(autoLogin: true) }
            source.resume()
            self.timer = source
            Log.shared.info("session", "会话管理器已启动，检查间隔 \(Int(self.config.session.checkInterval))s")
        }
    }

    public func stop() {
        control.async { [weak self] in
            guard let self else { return }
            self.running = false
            self.timer?.cancel()
            self.timer = nil
            Log.shared.info("session", "会话管理器已停止")
        }
    }

    public func update(config newConfig: AppConfig) {
        control.async { [weak self] in
            guard let self else { return }
            self.config = newConfig
            let validIDs = Set(newConfig.egresses.map(\.id))
            self.stateLock.lock()
            self.runtime = self.runtime.filter { validIDs.contains($0.key) }
            for egress in newConfig.egresses where self.runtime[egress.id] == nil {
                self.runtime[egress.id] = EgressRuntime()
            }
            self.stateLock.unlock()
            self.applyTimerIntervalIfNeeded()
        }
    }

    private func applyTimerIntervalIfNeeded() {
        guard running, let timer else { return }
        timer.schedule(deadline: .now() + 0.2,
                       repeating: max(5, config.session.checkInterval))
    }

    // MARK: - Reads

    public func snapshot(for egressID: UUID) -> EgressRuntime {
        stateLock.lock(); defer { stateLock.unlock() }
        return runtime[egressID] ?? EgressRuntime()
    }

    public func allSnapshots() -> [UUID: EgressRuntime] {
        stateLock.lock(); defer { stateLock.unlock() }
        return runtime
    }

    public func onlineEgressIDs() -> Set<UUID> {
        Set(allSnapshots().filter { $0.value.phase == .online }.keys)
    }

    // MARK: - Actions

    public func checkAll(autoLogin: Bool = true) {
        control.async { [weak self] in self?.checkAllOnControl(autoLogin: autoLogin) }
    }

    public func check(egressID: UUID, autoLogin: Bool = false) {
        control.async { [weak self] in
            guard let self, let egress = self.config.egresses.first(where: { $0.id == egressID }) else { return }
            self.dispatchCheck(egress: egress, config: self.config, autoLogin: autoLogin)
        }
    }

    /// Explicit user-initiated login. Safe: never touches other egresses.
    /// Logs one egress in. `passwordOverride` exists for headless testing and
    /// for callers that already hold the secret; nil means "read Keychain".
    public func login(egressID: UUID, passwordOverride: String? = nil) {
        control.async { [weak self] in
            guard let self, let egress = self.config.egresses.first(where: { $0.id == egressID }) else { return }
            let cfg = self.config
            self.work.async { self.performLogin(egress: egress, config: cfg, passwordOverride: passwordOverride) }
        }
    }

    /// Explicit logout of one egress. Must be confirmed in the UI.
    public func logout(egressID: UUID, completion: ((Result<Void, Error>) -> Void)? = nil) {
        control.async { [weak self] in
            guard let self,
                  let egress = self.config.egresses.first(where: { $0.id == egressID }),
                  let account = self.config.account(id: egress.accountID) else {
                completion?(.failure(PortalError.portalError("该链路没有绑定账号")))
                return
            }
            guard let addr = IPv4Address(egress.localAddress) else {
                completion?(.failure(PortalError.portalError("链路地址无效")))
                return
            }
            let cfg = self.config
            self.work.async {
                do {
                    try self.portal.logout(username: account.username, clientIP: addr.description,
                                           base: account.portalURL, settings: cfg.portal,
                                           source: EgressSource(address: addr, interfaceName: egress.interfaceName))
                    self.mutate(egressID) { $0.phase = .offline; $0.username = nil; $0.onlineSince = nil }
                    completion?(.success(()))
                } catch {
                    completion?(.failure(error))
                }
            }
        }
    }

    // MARK: - Core

    private func checkAllOnControl(autoLogin: Bool) {
        let cfg = config
        for egress in cfg.egresses where egress.isEnabled {
            dispatchCheck(egress: egress, config: cfg, autoLogin: autoLogin)
        }
    }

    private func dispatchCheck(egress: Egress, config cfg: AppConfig, autoLogin: Bool) {
        stateLock.lock()
        let alreadyRunning = inFlight.contains(egress.id)
        if !alreadyRunning { inFlight.insert(egress.id) }
        stateLock.unlock()
        guard !alreadyRunning else { return }

        work.async { [weak self] in
            guard let self else { return }
            defer {
                self.stateLock.lock(); self.inFlight.remove(egress.id); self.stateLock.unlock()
            }
            self.performCheck(egress: egress, config: cfg, autoLogin: autoLogin)
        }
    }

    private func performCheck(egress: Egress, config cfg: AppConfig, autoLogin: Bool) {
        guard egress.isEnabled else {
            mutate(egress.id) { $0.phase = .disabled }
            return
        }
        guard let addr = IPv4Address(egress.localAddress) else {
            mutate(egress.id) { $0.phase = .failed; $0.lastError = "地址无效" }
            return
        }

        let account = cfg.account(id: egress.accountID)
        let base = account?.portalURL ?? cfg.portal.baseURL
        let source = EgressSource(address: addr, interfaceName: egress.interfaceName)
        let status = portal.status(clientIP: addr.description, base: base,
                                   settings: cfg.portal, source: source)

        mutate(egress.id) { state in
            state.lastChecked = Date()
            if status.isOnline {
                state.phase = .online
                state.username = status.userName
                state.lastError = nil
                state.consecutiveFailures = 0
                state.nextAttempt = nil
                if state.onlineSince == nil { state.onlineSince = Date() }
            } else if !status.reachable {
                state.consecutiveFailures += 1
                state.lastError = "门户不可达：\(status.errorMessage ?? "超时")"
                state.phase = .unverified
            } else {
                if state.phase != .authenticating { state.phase = .offline }
                state.username = nil
                state.onlineSince = nil
                state.lastError = status.errorMessage
            }
        }

        guard autoLogin, !status.isOnline, status.reachable, egress.autoLogin else { return }
        if let next = snapshot(for: egress.id).nextAttempt, next > Date() { return }
        performLogin(egress: egress, config: cfg)
    }

    private func performLogin(egress: Egress, config cfg: AppConfig, passwordOverride: String? = nil) {
        guard let addr = IPv4Address(egress.localAddress) else { return }
        guard let account = cfg.account(id: egress.accountID) else {
            mutate(egress.id) { $0.phase = .failed; $0.lastError = "未绑定账号" }
            return
        }
        guard account.isEnabled else {
            mutate(egress.id) { $0.phase = .failed; $0.lastError = "账号已停用" }
            return
        }
        // One account = one session. Logging the same account in twice can kick
        // the older session off the portal, so refuse before touching the network.
        if let other = cfg.egresses.first(where: { $0.id != egress.id && $0.accountID == account.id }),
           snapshot(for: other.id).phase == .online {
            mutate(egress.id) {
                $0.phase = .failed
                $0.lastError = "该账号已在「\(other.name)」在线；每条链路需要一个独立账号"
            }
            return
        }
        guard let password = passwordOverride ?? Keychain.get(account.secretKey), !password.isEmpty else {
            mutate(egress.id) { $0.phase = .failed; $0.lastError = "钥匙串中没有密码" }
            return
        }

        mutate(egress.id) { $0.phase = .authenticating; $0.lastError = nil }
        Log.shared.info("session", "\(egress.name) 开始登录 \(account.username)@\(egress.localAddress)")
        do {
            let result = try portal.login(account: account, password: password,
                                          clientIP: addr.description, settings: cfg.portal,
                                          source: EgressSource(address: addr, interfaceName: egress.interfaceName))
            usleep(400_000)
            let status = portal.status(clientIP: addr.description, base: account.portalURL,
                                       settings: cfg.portal,
                                       source: EgressSource(address: addr, interfaceName: egress.interfaceName))
            if status.isOnline {
                mutate(egress.id) {
                    $0.phase = .online
                    $0.username = status.userName ?? account.username
                    $0.lastError = nil
                    $0.consecutiveFailures = 0
                    $0.nextAttempt = nil
                    $0.onlineSince = Date()
                }
                Log.shared.info("session", "\(egress.name) 登录成功：\(result.message)")
            } else {
                throw PortalError.portalError(status.errorMessage ?? "登录返回成功但会话未建立")
            }
        } catch {
            let failures = snapshot(for: egress.id).consecutiveFailures + 1
            let delay = min(cfg.session.maxBackoff,
                            cfg.session.initialBackoff * pow(2, Double(max(0, failures - 1))))
            mutate(egress.id) {
                $0.phase = .failed
                $0.lastError = error.localizedDescription
                $0.consecutiveFailures = failures
                $0.nextAttempt = Date().addingTimeInterval(delay)
            }
            Log.shared.error("session", "\(egress.name) 登录失败：\(error.localizedDescription)（\(Int(delay))s 后重试）")
        }
    }

    private func mutate(_ egressID: UUID, _ body: (inout EgressRuntime) -> Void) {
        stateLock.lock()
        var state = runtime[egressID] ?? EgressRuntime()
        body(&state)
        runtime[egressID] = state
        stateLock.unlock()
        DispatchQueue.main.async {
            NotificationCenter.default.post(name: .linkPoolSessionsDidChange, object: nil)
        }
    }
}
