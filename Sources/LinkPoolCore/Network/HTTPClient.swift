import Foundation

public struct HTTPResponse: Sendable {
    public let status: Int
    public let headers: [String: String]
    public let body: Data
    public let url: URL

    public var text: String { String(data: body, encoding: .utf8) ?? "" }

    public func header(_ name: String) -> String? { headers[name.lowercased()] }

    public func jsonObject() throws -> Any {
        try JSONSerialization.jsonObject(with: body)
    }
}

public enum HTTPError: Error, LocalizedError {
    case unsupportedScheme(String)
    case invalidURL(String)
    case badStatusLine(String)
    case tooLarge(Int)
    case malformedResponse(String)

    public var errorDescription: String? {
        switch self {
        case .unsupportedScheme(let s): return "v1 仅支持 http://，不支持 \(s)://"
        case .invalidURL(let s): return "无效地址：\(s)"
        case .badStatusLine(let s): return "无法解析服务器响应：\(s)"
        case .tooLarge(let n): return "响应过大（>\(n) 字节）"
        case .malformedResponse(let s): return "响应格式错误：\(s)"
        }
    }
}

/// Minimal HTTP/1.1 client built on raw POSIX sockets so every request can be
/// pinned to a specific local source address / interface (the core requirement
/// for steering different sessions onto different uplinks). HTTPS is
/// intentionally unsupported: the portal speaks plain HTTP.
public final class HTTPClient {
    public var timeout: TimeInterval
    public var maxBodyBytes: Int
    public var userAgent: String

    public init(timeout: TimeInterval = 6, maxBodyBytes: Int = 4 * 1024 * 1024,
                userAgent: String = "LinkPool/0.1 (macOS)") {
        self.timeout = timeout
        self.maxBodyBytes = maxBodyBytes
        self.userAgent = userAgent
    }

    public func get(_ url: URL, headers: [String: String] = [:], source: EgressSource? = nil) throws -> HTTPResponse {
        try request("GET", url, headers: headers, body: nil, source: source)
    }

    /// Form-encoded POST (application/x-www-form-urlencoded).
    public func post(_ url: URL, form: [String: String],
                     headers: [String: String] = [:],
                     source: EgressSource? = nil) throws -> HTTPResponse {
        let encoded = form.keys.sorted().map { key in
            "\(Self.formEncode(key))=\(Self.formEncode(form[key] ?? ""))"
        }.joined(separator: "&")
        var all = headers
        all["Content-Type"] = "application/x-www-form-urlencoded"
        all["Content-Length"] = String(encoded.utf8.count)
        return try request("POST", url, headers: all, body: Data(encoded.utf8), source: source)
    }

    static func formEncode(_ value: String) -> String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        return value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
    }

    private func request(_ method: String, _ url: URL, headers: [String: String],
                         body: Data?, source: EgressSource?) throws -> HTTPResponse {
        guard url.scheme?.lowercased() == "http" else {
            throw HTTPError.unsupportedScheme(url.scheme ?? "?")
        }
        guard let host = url.host, !host.isEmpty else {
            throw HTTPError.invalidURL(url.absoluteString)
        }
        let port = UInt16(url.port ?? 80)
        guard let ip = IPv4Address(host)?.description ?? SocketBox.resolveIPv4(host).first else {
            throw HTTPError.invalidURL("无法解析主机 \(host)")
        }

        var path = url.path.isEmpty ? "/" : url.path
        if let query = url.query, !query.isEmpty { path += "?" + query }

        var request = "\(method) \(path) HTTP/1.1\r\n"
        request += "Host: \(host)" + (port == 80 ? "" : ":\(port)") + "\r\n"
        request += "User-Agent: \(userAgent)\r\n"
        request += "Accept: */*\r\n"
        request += "Accept-Encoding: identity\r\n"
        request += "Connection: close\r\n"
        for (k, v) in headers { request += "\(k): \(v)\r\n" }
        request += "\r\n"
        var payload = Data(request.utf8)
        if let body { payload.append(body) }

        let fd = try SocketBox.open(host: ip, port: port, source: source, timeout: timeout)
        defer { close(fd) }
        try SocketBox.writeAll(fd, payload)

        var buffer = Data()
        var headerEnd: Range<Data.Index>?
        while headerEnd == nil {
            guard let chunk = try SocketBox.readSome(fd) else {
                throw HTTPError.malformedResponse("连接在响应头之前关闭")
            }
            buffer.append(chunk)
            headerEnd = buffer.range(of: Data("\r\n\r\n".utf8))
            if buffer.count > 1024 * 1024 { throw HTTPError.tooLarge(buffer.count) }
        }
        guard let headerRange = headerEnd else {
            throw HTTPError.malformedResponse("缺少响应头结束标记")
        }
        let headerData = buffer[buffer.startIndex..<headerRange.lowerBound]
        guard let headerText = String(data: headerData, encoding: .utf8) else {
            throw HTTPError.malformedResponse("响应头不是 UTF-8")
        }
        let lines = headerText.components(separatedBy: "\r\n")
        guard let statusLine = lines.first else { throw HTTPError.badStatusLine("") }
        let statusParts = statusLine.split(separator: " ", maxSplits: 2)
        guard statusParts.count >= 2, let status = Int(statusParts[1]) else {
            throw HTTPError.badStatusLine(statusLine)
        }
        var headersOut: [String: String] = [:]
        for line in lines.dropFirst() {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let key = line[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
            let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            headersOut[key] = value
        }

        var body = Data(buffer[headerRange.upperBound...])

        if headersOut["transfer-encoding"]?.lowercased().contains("chunked") == true {
            body = try readChunked(fd: fd, initial: body)
        } else if let lenText = headersOut["content-length"], let len = Int(lenText) {
            if len > maxBodyBytes { throw HTTPError.tooLarge(len) }
            while body.count < len {
                guard let chunk = try SocketBox.readSome(fd) else { break }
                body.append(chunk)
                if body.count > maxBodyBytes { throw HTTPError.tooLarge(body.count) }
            }
            if body.count > len { body = body.prefix(len) }
        } else {
            while let chunk = try SocketBox.readSome(fd) {
                body.append(chunk)
                if body.count > maxBodyBytes { throw HTTPError.tooLarge(body.count) }
            }
        }

        return HTTPResponse(status: status, headers: headersOut, body: body, url: url)
    }

    /// GET following up to `maxRedirects` 3xx responses.
    public func getFollowingRedirects(_ url: URL, maxRedirects: Int = 5,
                                      headers: [String: String] = [:],
                                      source: EgressSource? = nil) throws -> HTTPResponse {
        var current = url
        for _ in 0...maxRedirects {
            let response = try get(current, headers: headers, source: source)
            guard (300..<400).contains(response.status),
                  let location = response.header("location"),
                  let next = URL(string: location, relativeTo: current)?.absoluteURL else {
                return response
            }
            current = next
        }
        return try get(current, headers: headers, source: source)
    }

    private func readChunked(fd: Int32, initial: Data) throws -> Data {
        var buffer = initial
        var out = Data()
        var cursor = buffer.startIndex
        while true {
            // Ensure the size line is complete.
            while buffer[cursor...].range(of: Data("\r\n".utf8)) == nil {
                guard let chunk = try SocketBox.readSome(fd) else { return out }
                buffer.append(chunk)
                if buffer.count > maxBodyBytes { throw HTTPError.tooLarge(buffer.count) }
            }
            guard let lineEnd = buffer[cursor...].range(of: Data("\r\n".utf8))?.lowerBound else {
                throw HTTPError.malformedResponse("chunk 长度行缺失")
            }
            let line = String(data: buffer[cursor..<lineEnd], encoding: .utf8) ?? ""
            let sizeText = line.split(separator: ";").first.map(String.init) ?? ""
            guard let size = Int(sizeText, radix: 16) else {
                throw HTTPError.malformedResponse("chunk 长度非法：\(line)")
            }
            cursor = buffer.index(lineEnd, offsetBy: 2)
            if size == 0 { return out }

            while buffer.distance(from: cursor, to: buffer.endIndex) < size + 2 {
                guard let chunk = try SocketBox.readSome(fd) else { return out }
                buffer.append(chunk)
                if buffer.count > maxBodyBytes { throw HTTPError.tooLarge(buffer.count) }
            }
            out.append(buffer[cursor..<buffer.index(cursor, offsetBy: size)])
            if out.count > maxBodyBytes { throw HTTPError.tooLarge(out.count) }
            cursor = buffer.index(cursor, offsetBy: size + 2)
        }
    }
}
