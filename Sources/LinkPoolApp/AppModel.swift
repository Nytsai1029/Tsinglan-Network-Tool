import LinkPoolCore
import Foundation
import SwiftUI
import Combine

/// Thread-safe holder so the proxy can read the latest config without
/// retaining the UI model.
final class ConfigBox: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: AppConfig

    init(_ config: AppConfig) { self.stored = config }

    var value: AppConfig {
        get { lock.lock(); defer { lock.unlock() }; return stored }
        set { lock.lock(); stored = newValue; lock.unlock() }
    }
}

struct EgressSpeed: Equatable, Sendable {
    var down: Double = 0
    var up: Double = 0
    var connections: Int = 0
}

struct SpeedPoint: Identifiable, Equatable {
    let id = UUID()
    let date: Date
    let down: Double
    let up: Double
}

@MainActor
final class AppModel: ObservableObject {
    static let shared = AppModel()

    // MARK: - Published state

    @Published var config: AppConfig
    @Published private(set) var snapshots: [UUID: SessionManager.EgressRuntime] = [:]
    @Published private(set) var speeds: [UUID: EgressSpeed] = [:]
    @Published private(set) var totalDown: Double = 0
    @Published private(set) var totalUp: Double = 0
    @Published private(set) var history: [SpeedPoint] = []
    @Published private(set) var proxyState: ProxyServer.State = .stopped
    @Published private(set) var logs: [LogEntry] = []
    @Published private(set) var interfaces: [InterfaceInfo] = []
    @Published var selection: SidebarItem = .overview {
        didSet { UserDefaults.standard.set(selection.rawValue, forKey: Self.selectionKey) }
    }
    @Published var lastActionMessage: String?
    @Published var isBusy = false

    // MARK: - Services

    let sessions: SessionManager
    let proxy: ProxyServer
    private static let selectionKey = "sidebarSelection"
    private let store = ConfigStore.shared
    private let configBox: ConfigBox
    private var sampleTimer: Timer?
    private var lastTotals: [UUID: TrafficMetrics.Totals] = [:]
    private var lastSampleAt = Date()
    private var cancellables = Set<AnyCancellable>()

    // MARK: - Init

    init() {
        let loaded = ConfigStore.shared.load()
        let box = ConfigBox(loaded)
        self.config = loaded
        self.configBox = box
        self.sessions = SessionManager()
        self.proxy = ProxyServer(sessions: sessions, configProvider: { box.value })

        proxy.onStateChange = { [weak self] state in
            Task { @MainActor in self?.proxyState = state }
        }
        NotificationCenter.default.publisher(for: .linkPoolSessionsDidChange)
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.refreshRuntime() }
            .store(in: &cancellables)
        NotificationCenter.default.publisher(for: .linkPoolLogDidAppend)
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.refreshLogs() }
            .store(in: &cancellables)

        if let raw = UserDefaults.standard.string(forKey: Self.selectionKey),
           let saved = SidebarItem(rawValue: raw) {
            selection = saved
        }

        sessions.start()
        refreshInterfaces()
        refreshLogs()
        startSampling()
        refreshRuntime()
    }

    deinit {
        sampleTimer?.invalidate()
    }

    // MARK: - Persistence

    func persist(immediate: Bool = false) {
        configBox.value = config
        sessions.update(config: config)
        if immediate {
            store.saveNow(config)
        } else {
            store.save(config)
        }
    }

    // MARK: - Accounts

    func account(id: UUID?) -> Account? { config.account(id: id) }

    func saveAccount(_ account: Account, password: String?) {
        var updated = account
        updated.username = account.username.trimmingCharacters(in: .whitespacesAndNewlines)
        updated.name = account.name.trimmingCharacters(in: .whitespacesAndNewlines)
        updated.updatedAt = Date()
        config.upsert(account: updated)
        if let password, !password.isEmpty {
            Keychain.set(password, for: updated.secretKey)
        }
        persist(immediate: true)
        flash("已保存账号 \(updated.name)")
    }

    func deleteAccount(_ account: Account) {
        config.accounts.removeAll { $0.id == account.id }
        for index in config.egresses.indices where config.egresses[index].accountID == account.id {
            config.egresses[index].accountID = nil
            config.egresses[index].autoLogin = false
        }
        Keychain.delete(account.secretKey)
        persist(immediate: true)
        flash("已删除账号 \(account.name)")
    }

    func password(for account: Account) -> String {
        Keychain.get(account.secretKey) ?? ""
    }

    // MARK: - Egresses

    @discardableResult
    func saveEgress(_ egress: Egress) -> Bool {
        let duplicate = config.egresses.contains {
            $0.id != egress.id && $0.interfaceName == egress.interfaceName
                && $0.localAddress == egress.localAddress
        }
        guard !duplicate else {
            flash("该地址已经是一条链路，不能重复添加")
            return false
        }
        config.upsert(egress: egress)
        persist(immediate: true)
        sessions.check(egressID: egress.id, autoLogin: false)
        return true
    }

    func deleteEgress(_ egress: Egress) {
        let alias = egress.localAddress
        let iface = egress.interfaceName
        config.egresses.removeAll { $0.id == egress.id }
        persist(immediate: true)
        if egress.kind == .alias, interfaces.first(where: { $0.name == iface })?.addresses.contains(where: { $0.address.description == alias }) == true {
            // Leave the address in place: removing it is an explicit action in
            // the UI so we never tear down an address another app may use.
        }
        flash("已移除链路 \(egress.name)")
    }

    func login(egress: Egress) {
        sessions.login(egressID: egress.id)
    }

    func logout(egress: Egress) {
        sessions.logout(egressID: egress.id) { [weak self] result in
            Task { @MainActor in
                switch result {
                case .success: self?.flash("已注销 \(egress.name)")
                case .failure(let error): self?.flash("注销失败：\(error.localizedDescription)")
                }
            }
        }
    }

    // MARK: - Aliases (requires admin)

    func addAlias(on interface: InterfaceInfo, address: IPv4Address, netmask: IPv4Address) -> Bool {
        let command = "ifconfig \(interface.name) alias \(address.description) netmask \(netmask.description)"
        let (ok, output) = Shell.runAsAdmin(command)
        if ok {
            flash("已添加地址 \(address.description)")
            refreshInterfaces()
        } else {
            flash("添加地址失败：\(output)")
        }
        return ok
    }

    func removeAlias(on interface: InterfaceInfo, address: IPv4Address) -> Bool {
        let command = "ifconfig \(interface.name) -alias \(address.description)"
        let (ok, output) = Shell.runAsAdmin(command)
        if ok {
            flash("已移除地址 \(address.description)")
            refreshInterfaces()
        } else {
            flash("移除地址失败：\(output)")
        }
        return ok
    }

    // MARK: - Proxy

    var proxyAddress: String { "\(config.proxy.host):\(config.proxy.port)" }

    func toggleProxy() {
        do {
            if case .running = proxy.state {
                proxy.stop()
            } else {
                try proxy.start()
            }
        } catch {
            proxyState = .failed(error.localizedDescription)
            flash(error.localizedDescription)
        }
    }

    // MARK: - Refresh

    func refreshInterfaces() {
        interfaces = InterfaceScanner.scan(includeInactive: false).filter { iface in
            // Hide adapters that only carry a self-assigned 169.254.x.x address:
            // they cannot reach the campus network and only add noise.
            iface.addresses.contains { !$0.address.isLinkLocal } || iface.isDefaultRoute
        }
    }

    func refreshRuntime() {
        snapshots = sessions.allSnapshots()
    }

    func refreshLogs() {
        logs = Array(Log.shared.snapshot().suffix(600))
    }

    func checkAll() {
        sessions.checkAll(autoLogin: false)
        flash("正在刷新所有链路状态")
    }

    private func startSampling() {
        lastSampleAt = Date()
        lastTotals = proxy.metrics.allTotals()
        let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.sample() }
        }
        RunLoop.main.add(timer, forMode: .common)
        sampleTimer = timer
    }

    private func sample() {
        let now = Date()
        let elapsed = max(0.2, now.timeIntervalSince(lastSampleAt))
        let totals = proxy.metrics.allTotals()
        var newSpeeds: [UUID: EgressSpeed] = [:]
        var downTotal = 0.0
        var upTotal = 0.0

        for egress in config.egresses {
            let current = totals[egress.id] ?? TrafficMetrics.Totals()
            let previous = lastTotals[egress.id] ?? TrafficMetrics.Totals()
            let down = Double(current.bytesIn &- previous.bytesIn) / elapsed
            let up = Double(current.bytesOut &- previous.bytesOut) / elapsed
            newSpeeds[egress.id] = EgressSpeed(down: down, up: up, connections: current.activeConnections)
            downTotal += down
            upTotal += up
        }

        lastTotals = totals
        lastSampleAt = now
        speeds = newSpeeds
        totalDown = downTotal
        totalUp = upTotal
        history.append(SpeedPoint(date: now, down: downTotal, up: upTotal))
        if history.count > 120 { history.removeFirst(history.count - 120) }
    }

    // MARK: - Helpers

    func flash(_ message: String) {
        lastActionMessage = message
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 4_000_000_000)
            if self.lastActionMessage == message { self.lastActionMessage = nil }
        }
    }

    var onlineCount: Int {
        snapshots.values.filter { $0.phase == .online }.count
    }

    var enabledEgressCount: Int {
        config.egresses.filter(\.isEnabled).count
    }

    var menuBarText: String {
        guard case .running = proxyState else { return "LinkPool" }
        return "↓ " + Formatters.speed(totalDown)
    }

    func speed(for egress: Egress) -> EgressSpeed { speeds[egress.id] ?? EgressSpeed() }

    func snapshot(for egress: Egress) -> SessionManager.EgressRuntime {
        snapshots[egress.id] ?? SessionManager.EgressRuntime()
    }
}

enum SidebarItem: String, CaseIterable, Identifiable {
    case overview, accounts, egresses, proxy, logs, settings
    var id: String { rawValue }
    var title: String {
        switch self {
        case .overview: return "概览"
        case .accounts: return "账号"
        case .egresses: return "链路"
        case .proxy: return "代理"
        case .logs: return "日志"
        case .settings: return "设置"
        }
    }
    var icon: String {
        switch self {
        case .overview: return "gauge.with.dots.needle.67percent"
        case .accounts: return "person.2.fill"
        case .egresses: return "point.3.connected.trianglepath.dotted"
        case .proxy: return "network"
        case .logs: return "text.alignleft"
        case .settings: return "gearshape.fill"
        }
    }
}

enum Formatters {
    static func speed(_ bytesPerSecond: Double) -> String {
        guard bytesPerSecond > 0.01 else { return "0 B/s" }
        let units = ["B/s", "KB/s", "MB/s", "GB/s"]
        var value = bytesPerSecond
        var index = 0
        while value >= 1024 && index < units.count - 1 {
            value /= 1024
            index += 1
        }
        return String(format: value >= 100 ? "%.0f %@" : "%.1f %@", value, units[index])
    }

    static func bytes(_ count: UInt64) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(clamping: count), countStyle: .binary)
    }

    static func duration(_ seconds: Int) -> String {
        let h = seconds / 3600
        let m = (seconds % 3600) / 60
        if h > 0 { return "\(h) 小时 \(m) 分" }
        if m > 0 { return "\(m) 分钟" }
        return "\(seconds) 秒"
    }

    static func time(_ date: Date?) -> String {
        guard let date else { return "—" }
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        return formatter.string(from: date)
    }
}
