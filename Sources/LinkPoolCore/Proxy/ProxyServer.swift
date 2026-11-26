import Foundation

public enum ProxyError: Error, LocalizedError {
    case bindFailed(Int32, String)
    case listenFailed(Int32)
    case noEgress
    case badRequest(String)

    public var errorDescription: String? {
        switch self {
        case .bindFailed(let e, let a): return "无法监听 \(a)（errno=\(e)），端口可能已被占用"
        case .listenFailed(let e): return "listen 失败 errno=\(e)"
        case .noEgress: return "没有可用的在线链路"
        case .badRequest(let m): return "请求无效：\(m)"
        }
    }
}

/// Local SOCKS5 + HTTP CONNECT proxy. Each accepted connection is assigned an
/// egress and its upstream socket is bound to that egress's source address, so
/// the campus AC sees traffic from the matching authenticated IP.
public final class ProxyServer: @unchecked Sendable {
    public enum State: Equatable, Sendable {
        case stopped
        case running(host: String, port: Int)
        case failed(String)
    }

    public private(set) var state: State = .stopped
    public var onStateChange: ((State) -> Void)?

    public let metrics = TrafficMetrics()
    public let selector = EgressSelector()

    private let acceptQueue = DispatchQueue(label: "com.nytsai.linkpool.proxy.accept")
    private let workQueue = DispatchQueue(label: "com.nytsai.linkpool.proxy.conn", attributes: .concurrent)
    private let stateLock = NSLock()
    private var listenFD: Int32 = -1
    private var connectionLimit = DispatchSemaphore(value: 512)
    private var connections = 0

    private let sessions: SessionManager
    private let configProvider: () -> AppConfig
    private let handshakeTimeout: TimeInterval = 10

    public init(sessions: SessionManager, configProvider: @escaping () -> AppConfig) {
        self.sessions = sessions
        self.configProvider = configProvider
    }

    deinit { stop() }

    // MARK: - Lifecycle

    public func start() throws {
        let config = configProvider()
        let host = config.proxy.host
        let port = config.proxy.port
        guard listenFD < 0 else { return }

        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { throw ProxyError.bindFailed(errno, "\(host):\(port)") }
        var one: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &one, socklen_t(MemoryLayout<Int32>.size))
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))

        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = UInt16(port).bigEndian
        guard inet_pton(AF_INET, host, &addr.sin_addr) == 1 else {
            close(fd)
            throw ProxyError.bindFailed(EINVAL, "\(host):\(port)")
        }
        let bindResult = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bindResult == 0 else {
            let err = errno
            close(fd)
            throw ProxyError.bindFailed(err, "\(host):\(port)")
        }
        guard Darwin.listen(fd, 256) == 0 else {
            let err = errno
            close(fd)
            throw ProxyError.listenFailed(err)
        }

        stateLock.lock()
        listenFD = fd
        connectionLimit = DispatchSemaphore(value: max(16, config.proxy.maxConnections))
        state = .running(host: host, port: port)
        stateLock.unlock()

        Log.shared.info("proxy", "代理已启动 \(host):\(port)（SOCKS5 + HTTP）")
        publishState()
        acceptQueue.async { [weak self] in self?.acceptLoop(fd: fd) }
    }

    public func stop() {
        stateLock.lock()
        let fd = listenFD
        listenFD = -1
        state = .stopped
        stateLock.unlock()
        if fd >= 0 {
            shutdown(fd, SHUT_RDWR)
            close(fd)
        }
        selector.reset()
        Log.shared.info("proxy", "代理已停止")
        publishState()
    }

    public func toggle() throws {
        if case .running = state { stop() } else { try start() }
    }

    private func publishState() {
        let snapshot = state
        DispatchQueue.main.async { [weak self] in self?.onStateChange?(snapshot) }
    }

    private func acceptLoop(fd: Int32) {
        while true {
            var addr = sockaddr_in()
            var len = socklen_t(MemoryLayout<sockaddr_in>.size)
            let client = withUnsafeMutablePointer(to: &addr) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    accept(fd, $0, &len)
                }
            }
            if client < 0 {
                if errno == EINTR { continue }
                break
            }
            var one: Int32 = 1
            setsockopt(client, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))

            stateLock.lock()
            let limit = connectionLimit
            stateLock.unlock()
            guard limit.wait(timeout: .now()) == .success else {
                Log.shared.warn("proxy", "连接数达到上限，拒绝新连接")
                close(client)
                continue
            }
            workQueue.async { [weak self] in
                guard let self else { close(client); return }
                defer {
                    close(client)
                    limit.signal()
                }
                self.handle(client: client)
            }
        }
        Log.shared.debug("proxy", "accept 循环退出")
    }

    // MARK: - Connection handling

    private func handle(client: Int32) {
        guard SocketBox.waitReadable(client, timeout: handshakeTimeout) else {
            Log.shared.debug("proxy", "客户端握手超时")
            return
        }
        var first: UInt8 = 0
        let peeked = recv(client, &first, 1, MSG_PEEK)
        guard peeked == 1 else { return }

        do {
            if first == 0x05 {
                try handleSOCKS5(client: client)
            } else {
                try handleHTTP(client: client, firstByte: first)
            }
        } catch {
            Log.shared.debug("proxy", "连接结束：\(error.localizedDescription)")
        }
    }

    private func handleSOCKS5(client: Int32) throws {
        guard let head = try SocketBox.readExactly(client, 2), head.count == 2, head[0] == 0x05 else {
            throw ProxyError.badRequest("SOCKS 版本")
        }
        let methodCount = Int(head[1])
        guard let methods = try SocketBox.readExactly(client, methodCount) else {
            throw ProxyError.badRequest("SOCKS 方法")
        }
        guard methods.contains(0x00) else {
            try? SocketBox.writeAll(client, Data([0x05, 0xFF]))
            throw ProxyError.badRequest("不支持认证方式")
        }
        try SocketBox.writeAll(client, Data([0x05, 0x00]))

        guard let request = try SocketBox.readExactly(client, 4), request.count == 4 else {
            throw ProxyError.badRequest("SOCKS 请求")
        }
        guard request[0] == 0x05, request[1] == 0x01 else {
            try? SocketBox.writeAll(client, Data([0x05, 0x07, 0x00, 0x01, 0, 0, 0, 0, 0, 0]))
            throw ProxyError.badRequest("仅支持 CONNECT")
        }

        let host: String
        switch request[3] {
        case 0x01:
            guard let raw = try SocketBox.readExactly(client, 4) else { throw ProxyError.badRequest("IPv4") }
            host = IPv4Address(rawValue: raw.withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) }.bigEndian).description
        case 0x03:
            guard let lenByte = try SocketBox.readExactly(client, 1), let length = lenByte.first,
                  let name = try SocketBox.readExactly(client, Int(length)),
                  let string = String(data: name, encoding: .utf8) else {
                throw ProxyError.badRequest("域名")
            }
            host = string
        case 0x04:
            guard let raw = try SocketBox.readExactly(client, 16) else { throw ProxyError.badRequest("IPv6") }
            var addr = in6_addr()
            withUnsafeMutableBytes(of: &addr) { dst in raw.copyBytes(to: dst) }
            var text = [CChar](repeating: 0, count: Int(INET6_ADDRSTRLEN))
            inet_ntop(AF_INET6, &addr, &text, socklen_t(INET6_ADDRSTRLEN))
            host = String(cString: text)
        default:
            throw ProxyError.badRequest("地址类型")
        }
        guard let portData = try SocketBox.readExactly(client, 2), portData.count == 2 else {
            throw ProxyError.badRequest("端口")
        }
        let port = UInt16(portData[0]) << 8 | UInt16(portData[1])

        guard let (upstream, egress) = try openUpstream(host: host, port: port) else {
            try? SocketBox.writeAll(client, Data([0x05, 0x03, 0x00, 0x01, 0, 0, 0, 0, 0, 0]))
            throw ProxyError.noEgress
        }
        try SocketBox.writeAll(client, Data([0x05, 0x00, 0x00, 0x01, 0, 0, 0, 0, 0, 0]))
        relay(client: client, upstream: upstream, egress: egress)
    }

    private func handleHTTP(client: Int32, firstByte: UInt8) throws {
        var buffer = Data([firstByte])
        let deadline = Date().addingTimeInterval(handshakeTimeout)
        while buffer.range(of: Data("\r\n\r\n".utf8)) == nil {
            guard Date() < deadline else { throw ProxyError.badRequest("请求头超时") }
            guard SocketBox.waitReadable(client, timeout: 1) else { continue }
            guard let chunk = try SocketBox.readSome(client), !chunk.isEmpty else {
                throw ProxyError.badRequest("请求头不完整")
            }
            buffer.append(chunk)
            if buffer.count > 128 * 1024 { throw ProxyError.badRequest("请求头过大") }
        }
        guard let headerEnd = buffer.range(of: Data("\r\n\r\n".utf8)),
              let headerText = String(data: buffer[..<headerEnd.lowerBound], encoding: .utf8) else {
            throw ProxyError.badRequest("无法解码请求头")
        }
        let lines = headerText.components(separatedBy: "\r\n")
        guard let requestLine = lines.first else { throw ProxyError.badRequest("缺少请求行") }
        let parts = requestLine.split(separator: " ")
        guard parts.count >= 3 else { throw ProxyError.badRequest("请求行格式") }
        let method = String(parts[0])
        let target = String(parts[1])

        if method.uppercased() == "CONNECT" {
            let (host, port) = Self.splitHostPort(target, defaultPort: 443)
            guard let (upstream, egress) = try openUpstream(host: host, port: port) else {
                try? SocketBox.writeAll(client, Data("HTTP/1.1 502 Bad Gateway\r\n\r\n".utf8))
                throw ProxyError.noEgress
            }
            try SocketBox.writeAll(client, Data("HTTP/1.1 200 Connection Established\r\nProxy-Agent: LinkPool\r\n\r\n".utf8))
            relay(client: client, upstream: upstream, egress: egress)
            return
        }

        // Plain HTTP proxy request (absolute URI). Rewrite to origin form.
        guard let url = URL(string: target), let host = url.host else {
            throw ProxyError.badRequest("仅支持绝对 URI")
        }
        let port = UInt16(url.port ?? 80)
        guard let (upstream, egress) = try openUpstream(host: host, port: port) else {
            try? SocketBox.writeAll(client, Data("HTTP/1.1 502 Bad Gateway\r\n\r\n".utf8))
            throw ProxyError.noEgress
        }
        var forwarded = "\(method) \(url.path.isEmpty ? "/" : url.path)" +
            (url.query.map { "?\($0)" } ?? "") + " HTTP/1.1\r\n"
        var sawHost = false
        for line in lines.dropFirst() where !line.isEmpty {
            let lower = line.lowercased()
            if lower.hasPrefix("proxy-connection:") || lower.hasPrefix("connection:") { continue }
            if lower.hasPrefix("host:") { sawHost = true }
            forwarded += line + "\r\n"
        }
        if !sawHost { forwarded += "Host: \(host)\r\n" }
        forwarded += "Connection: close\r\n\r\n"
        try SocketBox.writeAll(upstream, Data(forwarded.utf8))
        if buffer.count > headerEnd.upperBound {
            try SocketBox.writeAll(upstream, buffer[headerEnd.upperBound...])
        }
        relay(client: client, upstream: upstream, egress: egress)
    }

    // MARK: - Upstream

    private func openUpstream(host: String, port: UInt16) throws -> (Int32, UUID)? {
        let config = configProvider()
        let onlineIDs = sessions.onlineEgressIDs()
        var candidates = config.egresses.filter { $0.isEnabled && onlineIDs.contains($0.id) }
        if candidates.isEmpty && config.proxy.allowUnverifiedEgress {
            let snapshots = sessions.allSnapshots()
            candidates = config.egresses.filter { egress in
                guard egress.isEnabled else { return false }
                let phase = snapshots[egress.id]?.phase ?? .unknown
                return phase == .unknown || phase == .unverified
            }
        }
        guard let egress = selector.select(from: candidates, host: host,
                                           strategy: config.proxy.strategy,
                                           stickySeconds: config.proxy.stickySeconds) else {
            Log.shared.warn("proxy", "没有在线链路可用于 \(host):\(port)")
            return nil
        }
        guard let addr = IPv4Address(egress.localAddress) else { return nil }

        let resolved: String
        if IPv4Address(host) != nil {
            resolved = host
        } else if let ip = SocketBox.resolveIPv4(host).first {
            resolved = ip
        } else {
            Log.shared.warn("proxy", "域名解析失败：\(host)")
            return nil
        }

        let source = EgressSource(address: addr, interfaceName: egress.interfaceName)
        let fd = try SocketBox.open(host: resolved, port: port, source: source, timeout: handshakeTimeout)
        selector.connectionOpened(egress.id)
        metrics.connectionOpened(egress.id)
        Log.shared.debug("proxy", "\(host):\(port) → \(egress.name) [\(egress.localAddress)]")
        return (fd, egress.id)
    }

    // MARK: - Relay

    private func relay(client: Int32, upstream: Int32, egress: UUID) {
        SocketBox.setTimeout(client, seconds: 0)
        SocketBox.setTimeout(upstream, seconds: 0)
        defer {
            selector.connectionClosed(egress)
            metrics.connectionClosed(egress)
            shutdown(client, SHUT_RDWR)
            shutdown(upstream, SHUT_RDWR)
            close(upstream)
        }

        var pollfds = [
            pollfd(fd: client, events: Int16(POLLIN), revents: 0),
            pollfd(fd: upstream, events: Int16(POLLIN), revents: 0),
        ]
        var clientOpen = true
        var upstreamOpen = true
        var buffer = [UInt8](repeating: 0, count: 64 * 1024)
        var failed = false

        while (clientOpen || upstreamOpen) && !failed {
            pollfds[0].events = clientOpen ? Int16(POLLIN) : 0
            pollfds[1].events = upstreamOpen ? Int16(POLLIN) : 0
            let ready = poll(&pollfds, 2, 600_000)
            if ready < 0 {
                if errno == EINTR { continue }
                break
            }
            if ready == 0 { break }

            if clientOpen, pollfds[0].revents & Int16(POLLIN) != 0 {
                let n = recv(client, &buffer, buffer.count, 0)
                if n > 0 {
                    metrics.addOut(egress, n)
                    do { try SocketBox.writeAll(upstream, Data(buffer[0..<n])) } catch { failed = true }
                } else if n == 0 || (errno != EINTR && errno != EAGAIN) {
                    clientOpen = false
                    shutdown(upstream, SHUT_WR)
                }
            } else if clientOpen, pollfds[0].revents & (Int16(POLLHUP) | Int16(POLLERR)) != 0 {
                clientOpen = false
                shutdown(upstream, SHUT_WR)
            }

            if upstreamOpen, pollfds[1].revents & Int16(POLLIN) != 0 {
                let n = recv(upstream, &buffer, buffer.count, 0)
                if n > 0 {
                    metrics.addIn(egress, n)
                    do { try SocketBox.writeAll(client, Data(buffer[0..<n])) } catch { failed = true }
                } else if n == 0 || (errno != EINTR && errno != EAGAIN) {
                    upstreamOpen = false
                    shutdown(client, SHUT_WR)
                }
            } else if upstreamOpen, pollfds[1].revents & (Int16(POLLHUP) | Int16(POLLERR)) != 0 {
                upstreamOpen = false
                shutdown(client, SHUT_WR)
            }
        }
    }

    private static func splitHostPort(_ text: String, defaultPort: UInt16) -> (String, UInt16) {
        if text.hasPrefix("[") {
            if let close = text.firstIndex(of: "]") {
                let host = String(text[text.index(after: text.startIndex)..<close])
                let rest = text[text.index(after: close)...]
                if rest.hasPrefix(":"), let port = UInt16(rest.dropFirst()) { return (host, port) }
                return (host, defaultPort)
            }
        }
        let parts = text.split(separator: ":")
        if parts.count == 2, let port = UInt16(parts[1]) { return (String(parts[0]), port) }
        return (text, defaultPort)
    }
}
