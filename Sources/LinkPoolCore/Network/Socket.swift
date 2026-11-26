import Foundation

public struct EgressSource: Hashable, Sendable {
    public let address: IPv4Address
    public let interfaceName: String?

    public init(address: IPv4Address, interfaceName: String? = nil) {
        self.address = address
        self.interfaceName = interfaceName
    }

    public init?(ip: String, interfaceName: String?) {
        guard let addr = IPv4Address(ip) else { return nil }
        self.address = addr
        self.interfaceName = interfaceName
    }
}

public enum SocketError: Error, LocalizedError {
    case create(Int32)
    case option(Int32, String)
    case bind(Int32, String)
    case connect(Int32, String)
    case timeout(String)
    case closed

    public var errorDescription: String? {
        switch self {
        case .create(let e): return "创建套接字失败 errno=\(e)"
        case .option(let e, let n): return "设置 \(n) 失败 errno=\(e)"
        case .bind(let e, let a): return "绑定 \(a) 失败 errno=\(e)"
        case .connect(let e, let t): return "连接 \(t) 失败 errno=\(e)"
        case .timeout(let t): return "连接 \(t) 超时"
        case .closed: return "连接已关闭"
        }
    }
}

public enum SocketBox {
    public static func makeStream() throws -> Int32 {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { throw SocketError.create(errno) }
        var one: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
        return fd
    }

    public static func setNonBlocking(_ fd: Int32, _ enabled: Bool) {
        let flags = fcntl(fd, F_GETFL, 0)
        if enabled {
            _ = fcntl(fd, F_SETFL, flags | O_NONBLOCK)
        } else {
            _ = fcntl(fd, F_SETFL, flags & ~O_NONBLOCK)
        }
    }

    public static func setTimeout(_ fd: Int32, seconds: TimeInterval) {
        var tv = timeval(tv_sec: Int(seconds), tv_usec: Int32((seconds - Double(Int(seconds))) * 1_000_000))
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
    }

    public static func bind(_ fd: Int32, source: EgressSource) throws {
        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = 0
        addr.sin_addr = source.address.inAddr
        let rc = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard rc == 0 else { throw SocketError.bind(errno, source.address.description) }

        if let ifname = source.interfaceName, let idx = InterfaceScanner.index(of: ifname) {
            var index = idx
            if setsockopt(fd, IPPROTO_IP, IP_BOUND_IF, &index, socklen_t(MemoryLayout<UInt32>.size)) != 0 {
                Log.shared.warn("socket", "IP_BOUND_IF(\(ifname)) 失败 errno=\(errno)，仅使用源地址绑定")
            }
        }
    }

    public static func connect(_ fd: Int32, host: String, port: UInt16, timeout: TimeInterval) throws {
        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = port.bigEndian
        guard inet_pton(AF_INET, host, &addr.sin_addr) == 1 else {
            throw SocketError.connect(EINVAL, host)
        }

        setNonBlocking(fd, true)
        let rc = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        if rc != 0 {
            guard errno == EINPROGRESS else {
                setNonBlocking(fd, false)
                throw SocketError.connect(errno, "\(host):\(port)")
            }
            var pfd = pollfd(fd: fd, events: Int16(POLLOUT), revents: 0)
            let ms = Int32(max(1, timeout * 1000))
            let pr = poll(&pfd, 1, ms)
            if pr == 0 {
                setNonBlocking(fd, false)
                throw SocketError.timeout("\(host):\(port)")
            }
            var soError: Int32 = 0
            var len = socklen_t(MemoryLayout<Int32>.size)
            getsockopt(fd, SOL_SOCKET, SO_ERROR, &soError, &len)
            if soError != 0 {
                setNonBlocking(fd, false)
                throw SocketError.connect(soError, "\(host):\(port)")
            }
        }
        setNonBlocking(fd, false)
        setTimeout(fd, seconds: timeout)
    }

    /// Opens a TCP connection, optionally bound to a specific source/interface.
    public static func open(host: String, port: UInt16, source: EgressSource?, timeout: TimeInterval) throws -> Int32 {
        let fd = try makeStream()
        do {
            if let source { try bind(fd, source: source) }
            try connect(fd, host: host, port: port, timeout: timeout)
            return fd
        } catch {
            close(fd)
            throw error
        }
    }

    public static func writeAll(_ fd: Int32, _ data: Data) throws {
        try data.withUnsafeBytes { raw in
            var offset = 0
            let base = raw.baseAddress!.assumingMemoryBound(to: UInt8.self)
            while offset < raw.count {
                let n = Darwin.send(fd, base + offset, raw.count - offset, 0)
                if n > 0 { offset += n; continue }
                if n < 0 && errno == EINTR { continue }
                throw SocketError.closed
            }
        }
    }

    public static func readSome(_ fd: Int32, max: Int = 65536) throws -> Data? {
        var buf = [UInt8](repeating: 0, count: max)
        while true {
            let n = recv(fd, &buf, max, 0)
            if n > 0 { return Data(buf[0..<n]) }
            if n == 0 { return nil }
            if errno == EINTR { continue }
            if errno == EAGAIN || errno == EWOULDBLOCK { throw SocketError.timeout("read") }
            throw SocketError.closed
        }
    }

    public static func waitReadable(_ fd: Int32, timeout: TimeInterval) -> Bool {
        var pfd = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
        let ms = Int32(max(0, timeout * 1000))
        while true {
            let r = poll(&pfd, 1, ms)
            if r > 0 { return true }
            if r == 0 { return false }
            if errno == EINTR { continue }
            return false
        }
    }

    /// Reads exactly `n` bytes. Returns nil on a clean EOF before any byte.
    public static func readExactly(_ fd: Int32, _ n: Int) throws -> Data? {
        guard n > 0 else { return Data() }
        var data = Data()
        data.reserveCapacity(n)
        var buffer = [UInt8](repeating: 0, count: 4096)
        while data.count < n {
            let want = min(buffer.count, n - data.count)
            let got = recv(fd, &buffer, want, 0)
            if got > 0 {
                data.append(contentsOf: buffer[0..<got])
            } else if got == 0 {
                return data.isEmpty ? nil : data
            } else if errno == EINTR {
                continue
            } else {
                throw SocketError.closed
            }
        }
        return data
    }

    public static func resolveIPv4(_ host: String) -> [String] {
        var hints = addrinfo()
        hints.ai_family = AF_INET
        hints.ai_socktype = SOCK_STREAM
        var res: UnsafeMutablePointer<addrinfo>?
        guard getaddrinfo(host, nil, &hints, &res) == 0, let first = res else { return [] }
        defer { freeaddrinfo(res) }
        var out: [String] = []
        var ptr: UnsafeMutablePointer<addrinfo>? = first
        while let cur = ptr {
            if let sa = cur.pointee.ai_addr {
                let sin = UnsafeRawPointer(sa).assumingMemoryBound(to: sockaddr_in.self).pointee
                let ip = IPv4Address(rawValue: UInt32(bigEndian: sin.sin_addr.s_addr))
                out.append(ip.description)
            }
            ptr = cur.pointee.ai_next
        }
        return out
    }
}
