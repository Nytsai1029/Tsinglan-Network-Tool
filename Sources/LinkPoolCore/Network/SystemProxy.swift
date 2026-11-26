import Foundation

public struct SystemProxyEntry: Codable, Sendable, Equatable {
    public var enabled: Bool
    public var host: String
    public var port: Int

    public init(enabled: Bool, host: String, port: Int) {
        self.enabled = enabled
        self.host = host
        self.port = port
    }
}

/// Everything needed to put one network service back exactly as it was.
public struct SystemProxySnapshot: Codable, Sendable, Equatable {
    public var service: String
    public var web: SystemProxyEntry
    public var secure: SystemProxyEntry
    public var socks: SystemProxyEntry
    public var bypass: [String]

    public init(service: String, web: SystemProxyEntry, secure: SystemProxyEntry, socks: SystemProxyEntry, bypass: [String]) {
        self.service = service
        self.web = web
        self.secure = secure
        self.socks = socks
        self.bypass = bypass
    }
}

public struct SystemProxyState: Sendable, Equatable {
    public var isEnabled: Bool
    public var host: String?
    public var port: Int?

    public init(isEnabled: Bool, host: String? = nil, port: Int? = nil) {
        self.isEnabled = isEnabled
        self.host = host
        self.port = port
    }

    public var matches: Bool {
        guard isEnabled, let host, let port else { return false }
        return (host == "127.0.0.1" || host == "localhost") && port > 0
    }
}

/// Reads and changes the macOS system proxy for the service that owns the
/// default route. Browsers follow these settings, so this is what makes
/// "start proxy" actually affect Safari/Chrome.
///
/// Before enabling we write a snapshot of the previous configuration; stopping
/// the proxy restores that snapshot, so the machine is left exactly as found.
public enum SystemProxy {
    private static let backupFile = "system-proxy-backup.json"

    // MARK: - Reading

    public static func serviceName(for device: String) -> String? {
        guard let output = Shell.run("/usr/sbin/networksetup", ["-listnetworkserviceorder"]) else { return nil }
        var current: String?
        for raw in output.split(separator: "\n") {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("("), let close = line.range(of: ") "), !line.contains("Device:") {
                current = String(line[close.upperBound...]).trimmingCharacters(in: .whitespaces)
            } else if line.contains("Device: \(device)") {
                return current
            }
        }
        return nil
    }

    public static func primaryServiceName() -> String? {
        guard let device = InterfaceScanner.defaultRouteInterface() else { return nil }
        return serviceName(for: device)
    }

    /// Current global proxy configuration (`scutil --proxy`, what System
    /// Settings shows).
    public static func current() -> SystemProxyState {
        guard let text = Shell.run("/usr/bin/scutil", ["--proxy"]) else {
            return SystemProxyState(isEnabled: false)
        }
        var values: [String: String] = [:]
        for raw in text.split(separator: "\n") {
            let line = raw.trimmingCharacters(in: .whitespaces)
            guard let colon = line.firstIndex(of: ":") else { continue }
            let key = String(line[..<colon]).trimmingCharacters(in: .whitespaces)
            let value = String(line[line.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
            values[key] = value
        }
        let enabled = values["HTTPEnable"] == "1" || values["HTTPSEnable"] == "1" || values["SOCKSEnable"] == "1"
        let host = values["HTTPProxy"] ?? values["HTTPSProxy"] ?? values["SOCKSProxy"]
        let port = Int(values["HTTPPort"] ?? values["HTTPSPort"] ?? values["SOCKSPort"] ?? "")
        return SystemProxyState(isEnabled: enabled, host: host, port: port)
    }

    /// One service's HTTP proxy entry.
    public static func serviceProxy(_ service: String) -> (enabled: Bool, host: String, port: Int)? {
        guard let entry = readEntry(service: service, proxy: "webproxy") else { return nil }
        return (entry.enabled, entry.host, entry.port)
    }

    private static func readEntry(service: String, proxy: String) -> SystemProxyEntry? {
        guard let output = Shell.run("/usr/sbin/networksetup", ["-get\(proxy)", service]) else { return nil }
        var enabled = false
        var host = ""
        var port = 0
        for raw in output.split(separator: "\n") {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("Enabled:") { enabled = line.contains("Yes") }
            if line.hasPrefix("Server:") { host = String(line.dropFirst("Server:".count)).trimmingCharacters(in: .whitespaces) }
            if line.hasPrefix("Port:") { port = Int(line.dropFirst("Port:".count).trimmingCharacters(in: .whitespaces)) ?? 0 }
        }
        return SystemProxyEntry(enabled: enabled, host: host, port: port)
    }

    private static func readBypass(service: String) -> [String] {
        guard let output = Shell.run("/usr/sbin/networksetup", ["-getproxybypassdomains", service]) else { return [] }
        return output.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }

    public static func snapshot(service: String) -> SystemProxySnapshot? {
        guard let web = readEntry(service: service, proxy: "webproxy"),
              let secure = readEntry(service: service, proxy: "securewebproxy"),
              let socks = readEntry(service: service, proxy: "socksfirewallproxy") else { return nil }
        return SystemProxySnapshot(service: service, web: web, secure: secure, socks: socks, bypass: readBypass(service: service))
    }

    // MARK: - Snapshot persistence

    private static var backupURL: URL {
        AppPaths.ensure()
        return AppPaths.supportDirectory.appendingPathComponent(backupFile)
    }

    static func loadSnapshot() -> SystemProxySnapshot? {
        guard let data = try? Data(contentsOf: backupURL) else { return nil }
        return try? JSONDecoder().decode(SystemProxySnapshot.self, from: data)
    }

    @discardableResult
    static func saveSnapshot(_ snapshot: SystemProxySnapshot) -> Bool {
        guard let data = try? JSONEncoder().encode(snapshot) else { return false }
        do {
            try data.write(to: backupURL, options: .atomic)
            return true
        } catch {
            Log.shared.error("systemproxy", "无法保存系统代理备份：\(error.localizedDescription)")
            return false
        }
    }

    static func clearSnapshot() {
        try? FileManager.default.removeItem(at: backupURL)
    }

    /// A snapshot left behind means a previous run enabled the proxy but never
    /// restored it (crash, force quit). The app uses this to recover on launch.
    public static func pendingSnapshot() -> SystemProxySnapshot? { loadSnapshot() }

    // MARK: - Applying

    /// Sets HTTP, HTTPS and SOCKS proxies to the local listener and enables
    /// them. Most admin accounts can do this without a prompt; if macOS
    /// refuses, we fall back to an AppleScript authorization dialog.
    public static func enable(service: String, host: String, port: Int) -> (Bool, String) {
        if let pending = loadSnapshot(), pending.service != service {
            _ = restore(pending)
            clearSnapshot()
        }
        guard let previous = loadSnapshot() ?? snapshot(service: service) else {
            return (false, "无法读取当前系统代理设置")
        }
        if loadSnapshot() == nil, !saveSnapshot(previous) {
            return (false, "无法保存当前系统代理设置，已取消修改")
        }

        let commands = setCommands(service: service, host: host, port: port)
        let result = runDirect(commands)
        if result.0, let state = serviceProxy(service), state.enabled, state.port == port {
            return (true, "")
        }
        // Direct attempt failed (or silently did nothing): try authorization.
        let admin = Shell.runAsAdmin(commands.joined(separator: " && "))
        if admin.0, let state = serviceProxy(service), state.enabled, state.port == port {
            return (true, "")
        }
        _ = restore(previous)
        clearSnapshot()
        return (false, admin.0 ? "系统代理没有生效" : admin.1)
    }

    /// Turns the three proxy types off, then restores the snapshot captured by
    /// `enable` so host/port and bypass domains are exactly as before.
    public static func disable(service: String) -> (Bool, String) {
        let target = loadSnapshot()?.service ?? service
        let commands = [
            "/usr/sbin/networksetup -setwebproxystate \(quote(target)) off",
            "/usr/sbin/networksetup -setsecurewebproxystate \(quote(target)) off",
            "/usr/sbin/networksetup -setsocksfirewallproxystate \(quote(target)) off"
        ]
        let result = runDirect(commands)
        var restored = true
        if let previous = loadSnapshot(), previous.service == target {
            restored = restore(previous).0
            clearSnapshot()
        }
        if !result.0 {
            let admin = Shell.runAsAdmin(commands.joined(separator: " && "))
            if !admin.0 { return (false, admin.1) }
        }
        return (restored, restored ? "" : "已关闭代理，但恢复原设置时出错")
    }

    private static func setCommands(service: String, host: String, port: Int) -> [String] {
        let name = quote(service)
        return [
            "/usr/sbin/networksetup -setwebproxy \(name) \(quote(host)) \(port)",
            "/usr/sbin/networksetup -setsecurewebproxy \(name) \(quote(host)) \(port)",
            "/usr/sbin/networksetup -setsocksfirewallproxy \(name) \(quote(host)) \(port)",
            "/usr/sbin/networksetup -setwebproxystate \(name) on",
            "/usr/sbin/networksetup -setsecurewebproxystate \(name) on",
            "/usr/sbin/networksetup -setsocksfirewallproxystate \(name) on",
            "/usr/sbin/networksetup -setproxybypassdomains \(name) 127.0.0.1 localhost '*.local' 4.3.2.1"
        ]
    }

    @discardableResult
    private static func restore(_ snapshot: SystemProxySnapshot) -> (Bool, String) {
        var commands: [String] = []
        commands += entryCommands(service: snapshot.service, proxy: "webproxy", state: "webproxystate", entry: snapshot.web)
        commands += entryCommands(service: snapshot.service, proxy: "securewebproxy", state: "securewebproxystate", entry: snapshot.secure)
        commands += entryCommands(service: snapshot.service, proxy: "socksfirewallproxy", state: "socksfirewallproxystate", entry: snapshot.socks)
        if snapshot.bypass.isEmpty {
            // `Empty` is networksetup's documented way to clear the list.
            commands.append("/usr/sbin/networksetup -setproxybypassdomains \(quote(snapshot.service)) Empty")
        } else {
            let domains = snapshot.bypass.map(quote).joined(separator: " ")
            commands.append("/usr/sbin/networksetup -setproxybypassdomains \(quote(snapshot.service)) \(domains)")
        }
        return runDirect(commands)
    }

    private static func entryCommands(service: String, proxy: String, state: String, entry: SystemProxyEntry) -> [String] {
        var commands: [String] = []
        if !entry.host.isEmpty, entry.port > 0 {
            commands.append("/usr/sbin/networksetup -set\(proxy) \(quote(service)) \(quote(entry.host)) \(entry.port)")
        }
        commands.append("/usr/sbin/networksetup -set\(state) \(quote(service)) \(entry.enabled ? "on" : "off")")
        return commands
    }

    private static func runDirect(_ commands: [String]) -> (Bool, String) {
        for command in commands {
            let (status, output) = Shell.runStatus("/bin/sh", ["-c", command])
            if status != 0 {
                return (false, output.trimmingCharacters(in: .whitespacesAndNewlines))
            }
        }
        return (true, "")
    }

    private static func quote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
