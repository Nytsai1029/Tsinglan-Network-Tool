import Foundation
import LinkPoolCore

// A deliberately small CLI: the GUI is the product, this is for debugging and
// for headless use on a server/SSH session.

let args = Array(CommandLine.arguments.dropFirst())
let command = args.first ?? "help"

func findEgress(_ query: String, in config: AppConfig) -> Egress? {
    config.egresses.first { $0.id.uuidString.lowercased().hasPrefix(query.lowercased()) }
        ?? config.egresses.first { $0.name.localizedCaseInsensitiveContains(query) }
        ?? config.egresses.first { $0.localAddress == query }
}

func describe(_ phase: SessionPhase) -> String {
    switch phase {
    case .online: return "在线"
    case .offline: return "离线"
    case .authenticating: return "认证中"
    case .failed: return "失败"
    case .disabled: return "停用"
    case .unknown: return "未知"
    case .unverified: return "未验证"
    }
}

func printStatus(_ config: AppConfig, _ sessions: SessionManager) {
    let snapshots = sessions.allSnapshots()
    print("账号 \(config.accounts.count) 个 · 链路 \(config.egresses.count) 条 · 代理 \(config.proxy.host):\(config.proxy.port)")
    for egress in config.egresses {
        let snapshot = snapshots[egress.id] ?? SessionManager.EgressRuntime()
        let account = config.account(id: egress.accountID)?.username ?? "-"
        let line = "  \(egress.name)  ·  \(egress.localAddress)  ·  \(egress.interfaceName)  ·  \(describe(snapshot.phase))  ·  \(account)"
        print(line)
        if let error = snapshot.lastError, snapshot.phase != .online {
            print("     ⚠︎ \(error)")
        }
    }
}

switch command {
case "interfaces":
    for iface in InterfaceScanner.scan() {
        let addrs = iface.addresses.map { "\($0.address)/\($0.subnet?.prefixLength ?? 0)" }.joined(separator: ", ")
        print("\(iface.name)\t\(iface.displayName)\t\(addrs)\t\(iface.macAddress ?? "-")\(iface.isDefaultRoute ? "\tdefault" : "")")
    }

case "status", "check":
    let store = ConfigStore.shared
    let config = store.load()
    let sessions = SessionManager(configStore: store)
    sessions.start()
    sessions.update(config: config)
    sessions.checkAll(autoLogin: args.contains("--auto-login"))
    Thread.sleep(forTimeInterval: 1.8)
    printStatus(config, sessions)

case "login", "logout":
    guard args.count >= 2 else { FileHandle.standardError.write(Data("用法: linkpoolctl \(command) <链路名|IP|UUID> [--password-file <路径>]".utf8)); exit(2) }
    let store = ConfigStore.shared
    let config = store.load()
    guard let egress = findEgress(args[1], in: config) else {
        FileHandle.standardError.write(Data("找不到链路：\(args[1])".utf8)); exit(1)
    }
    let sessions = SessionManager(configStore: store)
    sessions.start()
    sessions.update(config: config)
    if command == "login" {
        var password: String?
        if let flag = args.firstIndex(of: "--password-file"), args.count > flag + 1 {
            password = (try? String(contentsOfFile: args[flag + 1], encoding: .utf8))?
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
        sessions.login(egressID: egress.id, passwordOverride: password)
        for _ in 0..<40 {
            Thread.sleep(forTimeInterval: 0.5)
            let snapshot = sessions.snapshot(for: egress.id)
            if snapshot.phase != .authenticating && snapshot.phase != .unknown {
                print("\(egress.name): \(describe(snapshot.phase))\(snapshot.lastError.map { " — \($0)" } ?? "")")
                exit(snapshot.phase == .online ? 0 : 1)
            }
        }
        print("\(egress.name): 认证超时")
        exit(1)
    } else {
        let semaphore = DispatchSemaphore(value: 0)
        var failure: String?
        sessions.logout(egressID: egress.id) { result in
            if case .failure(let error) = result { failure = error.localizedDescription }
            semaphore.signal()
        }
        semaphore.wait()
        print("\(egress.name): \(failure ?? "已注销")")
        exit(failure == nil ? 0 : 1)
    }

case "secret":
    let store = ConfigStore.shared
    let config = store.load()
    guard let name = args.dropFirst().first,
          let account = config.accounts.first(where: {
              $0.name == name || $0.username == name
                  || $0.id.uuidString.lowercased().hasPrefix(name.lowercased())
          }) else {
        FileHandle.standardError.write(Data("用法: linkpoolctl secret <账号名|用户名|UUID>".utf8)); exit(2)
    }
    if let value = Keychain.get(account.secretKey) {
        print("\(account.username): 钥匙串中已保存密码（\(value.count) 个字符）")
    } else {
        print("\(account.username): 钥匙串中没有密码")
        exit(1)
    }

case "sysproxy":
    let store = ConfigStore.shared
    let config = store.load()
    let state = SystemProxy.current()
    let service = args.count >= 3 ? args[2] : SystemProxy.primaryServiceName()
    print("网络服务: \(service ?? "未找到默认网络服务")")
    print("系统代理: \(state.isEnabled ? "开" : "关")\(state.host.map { " · \($0):\(state.port ?? 0)" } ?? "")")
    if let service, let entry = SystemProxy.serviceProxy(service) {
        print("服务「\(service)」: \(entry.enabled ? "开" : "关") · \(entry.host):\(entry.port)")
    }
    if args.count >= 2 {
        guard let service else { exit(1) }
        switch args[1] {
        case "on":
            let (ok, message) = SystemProxy.enable(service: service, host: config.proxy.host, port: config.proxy.port)
            print(ok ? "已开启系统代理 → \(config.proxy.host):\(config.proxy.port)" : "开启失败: \(message)")
            exit(ok ? 0 : 1)
        case "off":
            let (ok, message) = SystemProxy.disable(service: service)
            print(ok ? "已关闭系统代理" : "关闭失败: \(message)")
            exit(ok ? 0 : 1)
        default:
            print("用法: linkpoolctl sysproxy [on|off]")
        }
    }

case "serve":
    let store = ConfigStore.shared
    let config = store.load()
    let sessions = SessionManager(configStore: store)
    sessions.start()
    sessions.update(config: config)
    sessions.checkAll(autoLogin: false)
    Thread.sleep(forTimeInterval: 1.5)
    let box = CLIBox(config)
    let proxy = ProxyServer(sessions: sessions, configProvider: { box.value })
    do {
        try proxy.start()
    } catch {
        FileHandle.standardError.write(Data("代理启动失败：\(error.localizedDescription)".utf8)); exit(1)
    }
    printStatus(config, sessions)
    print("SOCKS5/HTTP 代理已监听 \(config.proxy.host):\(config.proxy.port) — Ctrl-C 退出")
    signal(SIGINT) { _ in exit(0) }
    dispatchMain()

default:
    print("""
    linkpoolctl — LinkPool 命令行

      interfaces            列出网卡与地址
      status                查看账号/链路状态（只读检查）
      check [--auto-login]  主动检查，可选自动登录
      login <链路>          登录指定链路
      logout <链路>         注销指定链路（显式操作）
      serve                 前台运行代理
      secret <账号>         检查账号密码是否在钥匙串中
      sysproxy [on|off] [服务] 查看/设置 macOS 系统代理（默认当前网络服务）

    配置目录：\(AppPaths.supportDirectory.path)
    """)
}

final class CLIBox: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: AppConfig
    init(_ config: AppConfig) { stored = config }
    var value: AppConfig { lock.lock(); defer { lock.unlock() }; return stored }
}
