import Foundation
import XCTest
@testable import LinkPoolCore

/// End-to-end tests for the Huawei AC client against a throw-away loopback
/// HTTP server: verifies the exact form fields, the RC4 password and JSON
/// parsing without ever touching a real campus session.
final class HuaweiACClientTests: XCTestCase {
    func testLoginSendsExpectedFormAndParsesSuccess() throws {
        let server = try TinyHTTPServer { request in
            // Echo a success response; stash the request for assertions.
            _ = request
            return (200, #"{"success":true,"msg":"登录成功","userName":"tls0228"}"#, [:])
        }
        defer { server.stop() }

        var settings = PortalSettings()
        settings.baseURL = URL(string: "http://127.0.0.1:\(server.port)")!
        settings.captiveCheckURL = "http://127.0.0.1:\(server.port)/generate_204"
        settings.huaweiLoginPath = "/ac_portal/login.php"

        let account = Account(name: "测试", username: "tls0228",
                              portalURL: settings.baseURL)
        let client = HuaweiACClient(timeout: 5)
        let result = try client.login(account: account, password: "p@ssw0rd", settings: settings,
                                      source: EgressSource(address: IPv4Address("127.0.0.1")!))

        XCTAssertEqual(result.message, "登录成功")

        let request = try XCTUnwrap(server.lastRequest)
        XCTAssertTrue(request.hasPrefix("POST /ac_portal/login.php HTTP/1.1"))
        XCTAssertTrue(request.contains("Content-Type: application/x-www-form-urlencoded"))
        let body = try XCTUnwrap(request.components(separatedBy: "\r\n\r\n").last)
        let fields = parseForm(body)
        XCTAssertEqual(fields["opr"], "pwdLogin")
        XCTAssertEqual(fields["userName"], "tls0228")
        XCTAssertEqual(fields["rememberPwd"], "1")
        let tag = try XCTUnwrap(fields["auth_tag"] as String?)
        XCTAssertEqual(fields["pwd"], HuaweiPortalCrypto.rc4Hex("p@ssw0rd", key: tag))
    }

    func testLoginSurfacesServerMessage() throws {
        let server = try TinyHTTPServer { _ in
            (200, #"{"success":false,"msg":"用户名或密码错误"}"#, [:])
        }
        defer { server.stop() }

        var settings = PortalSettings()
        settings.baseURL = URL(string: "http://127.0.0.1:\(server.port)")!
        settings.huaweiLoginPath = "/ac_portal/login.php"
        let account = Account(name: "测试", username: "nobody", portalURL: settings.baseURL)

        XCTAssertThrowsError(try HuaweiACClient(timeout: 5)
            .login(account: account, password: "x", settings: settings, source: nil)) { error in
            XCTAssertTrue(error.localizedDescription.contains("用户名或密码错误"))
        }
    }

    func testLogoutPostsOprLogout() throws {
        let server = try TinyHTTPServer { _ in
            (200, #"{"success":true,"msg":"注销成功"}"#, [:])
        }
        defer { server.stop() }

        var settings = PortalSettings()
        settings.baseURL = URL(string: "http://127.0.0.1:\(server.port)")!
        settings.huaweiLoginPath = "/ac_portal/login.php"
        let message = try HuaweiACClient(timeout: 5).logout(base: settings.baseURL, settings: settings, source: nil)
        XCTAssertEqual(message, "注销成功")

        let request = try XCTUnwrap(server.lastRequest)
        XCTAssertTrue(request.hasPrefix("POST /ac_portal/login.php HTTP/1.1"))
        let body = try XCTUnwrap(request.components(separatedBy: "\r\n\r\n").last)
        XCTAssertEqual(parseForm(body)["opr"], "logout")
    }

    func testStatusDetectsCaptiveRedirect() throws {
        let server = try TinyHTTPServer { _ in
            (302, "", ["Location": "http://127.0.0.1/ac_portal/20231023153358/pc.html"])
        }
        defer { server.stop() }

        var settings = PortalSettings()
        settings.baseURL = URL(string: "http://127.0.0.1:\(server.port)")!
        settings.captiveCheckURL = "http://127.0.0.1:\(server.port)/generate_204"
        let status = HuaweiACClient(timeout: 5).status(base: settings.baseURL, settings: settings, source: nil)
        XCTAssertFalse(status.isOnline)
        XCTAssertTrue(status.reachable)
    }

    func testStatusDetects204AsOnline() throws {
        let server = try TinyHTTPServer { _ in (204, "", [:]) }
        defer { server.stop() }

        var settings = PortalSettings()
        settings.baseURL = URL(string: "http://127.0.0.1:\(server.port)")!
        settings.captiveCheckURL = "http://127.0.0.1:\(server.port)/generate_204"
        let status = HuaweiACClient(timeout: 5).status(base: settings.baseURL, settings: settings, source: nil)
        XCTAssertTrue(status.isOnline)
        XCTAssertTrue(status.reachable)
    }

    private func parseForm(_ body: String) -> [String: String] {
        var out: [String: String] = [:]
        for pair in body.split(separator: "&") {
            let parts = pair.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            guard parts.count == 2 else { continue }
            let key = String(parts[0]).removingPercentEncoding ?? String(parts[0])
            let value = String(parts[1]).replacingOccurrences(of: "+", with: " ")
                .removingPercentEncoding ?? String(parts[1])
            out[key] = value
        }
        return out
    }
}

/// One-shot HTTP/1.1 server on 127.0.0.1, used only inside tests.
private final class TinyHTTPServer {
    typealias Handler = (String) -> (Int, String, [String: String])

    let port: UInt16
    private let listenFD: Int32
    private let lock = NSLock()
    private var storedRequest: String?
    private var stopped = false
    private let queue = DispatchQueue(label: "tiny-http-server")

    var lastRequest: String? {
        lock.lock(); defer { lock.unlock() }
        return storedRequest
    }

    init(handler: @escaping Handler) throws {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { throw XCTSkip("无法创建监听套接字") }

        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = 0
        addr.sin_addr = IPv4Address("127.0.0.1")!.inAddr
        let bindRC = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                Darwin.bind(fd, sa, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bindRC == 0, listen(fd, 4) == 0 else {
            close(fd)
            throw XCTSkip("无法监听回环端口")
        }

        var bound = sockaddr_in()
        var len = socklen_t(MemoryLayout<sockaddr_in>.size)
        _ = withUnsafeMutablePointer(to: &bound) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                getsockname(fd, sa, &len)
            }
        }
        self.listenFD = fd
        self.port = UInt16(bigEndian: bound.sin_port)

        queue.async { [weak self] in
            guard let self else { return }
            let client = accept(self.listenFD, nil, nil)
            guard client >= 0 else { return }
            defer { close(client) }

            var data = Data()
            while !data.contains(Data("\r\n\r\n".utf8)) {
                guard let chunk = try? SocketBox.readSome(client) else { break }
                data.append(chunk)
            }
            if let text = String(data: data, encoding: .utf8),
               let range = text.range(of: "\r\n\r\n") {
                let head = String(text[..<range.lowerBound])
                let contentLength = head.components(separatedBy: "\r\n")
                    .first { $0.lowercased().hasPrefix("content-length:") }
                    .flatMap { Int($0.split(separator: ":")[1].trimmingCharacters(in: .whitespaces)) } ?? 0
                var body = String(text[range.upperBound...])
                while body.utf8.count < contentLength {
                    guard let chunk = try? SocketBox.readSome(client),
                          let piece = String(data: chunk, encoding: .utf8) else { break }
                    body += piece
                }
                let full = head + "\r\n\r\n" + body
                self.lock.lock(); self.storedRequest = full; self.lock.unlock()

                let (status, payload, headers) = handler(full)
                var response = "HTTP/1.1 \(status) \(status == 204 ? "No Content" : "OK")\r\n"
                var all = headers
                all["Content-Length"] = String(payload.utf8.count)
                all["Connection"] = "close"
                for (k, v) in all { response += "\(k): \(v)\r\n" }
                response += "\r\n" + payload
                try? SocketBox.writeAll(client, Data(response.utf8))
            }
        }
    }

    func stop() {
        lock.lock(); defer { lock.unlock() }
        guard !stopped else { return }
        stopped = true
        close(listenFD)
    }
}
