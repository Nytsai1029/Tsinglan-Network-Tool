import Foundation

/// Minimal IPv4 value type with the subnet math the tool needs.
public struct IPv4Address: Hashable, Codable, Sendable, CustomStringConvertible {
    /// Network byte order bytes, most significant first.
    public let bytes: (UInt8, UInt8, UInt8, UInt8)

    public init?(_ string: String) {
        var addr = in_addr()
        guard inet_pton(AF_INET, string, &addr) == 1 else { return nil }
        let v = UInt32(bigEndian: addr.s_addr)
        bytes = (UInt8((v >> 24) & 0xFF), UInt8((v >> 16) & 0xFF), UInt8((v >> 8) & 0xFF), UInt8(v & 0xFF))
    }

    public init(_ b0: UInt8, _ b1: UInt8, _ b2: UInt8, _ b3: UInt8) {
        bytes = (b0, b1, b2, b3)
    }

    public var description: String {
        "\(bytes.0).\(bytes.1).\(bytes.2).\(bytes.3)"
    }

    public var rawValue: UInt32 {
        (UInt32(bytes.0) << 24) | (UInt32(bytes.1) << 16) | (UInt32(bytes.2) << 8) | UInt32(bytes.3)
    }

    public init(rawValue: UInt32) {
        bytes = (UInt8((rawValue >> 24) & 0xFF), UInt8((rawValue >> 16) & 0xFF),
                 UInt8((rawValue >> 8) & 0xFF), UInt8(rawValue & 0xFF))
    }

    public var inAddr: in_addr {
        var a = in_addr()
        a.s_addr = rawValue.bigEndian
        return a
    }

    public var isLinkLocal: Bool {
        (rawValue & 0xFFFF_0000) == 0xA9FE_0000
    }

    public func isPrivateOrLinkLocal() -> Bool {
        let r = rawValue
        return (r & 0xFF00_0000) == 0x0A00_0000        // 10/8
            || (r & 0xFFF0_0000) == 0xAC10_0000        // 172.16/12
            || (r & 0xFFFF_0000) == 0xC0A8_0000        // 192.168/16
            || (r & 0xFFFF_0000) == 0xA9FE_0000        // 169.254/16
    }

    public static func == (lhs: IPv4Address, rhs: IPv4Address) -> Bool {
        lhs.rawValue == rhs.rawValue
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(rawValue)
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let string = try container.decode(String.self)
        guard let parsed = IPv4Address(string) else {
            throw DecodingError.dataCorruptedError(in: container,
                                                   debugDescription: "不是合法的 IPv4 地址：\(string)")
        }
        self = parsed
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(description)
    }
}

public struct IPv4Subnet: Sendable {
    public let address: IPv4Address
    public let prefixLength: Int

    public init?(address: IPv4Address, netmask: IPv4Address) {
        let mask = netmask.rawValue
        // Count contiguous ones.
        var ones = 0
        var seenZero = false
        for i in (0..<32).reversed() {
            let bit = (mask >> UInt32(i)) & 1
            if bit == 1 {
                if seenZero { return nil }
                ones += 1
            } else {
                seenZero = true
            }
        }
        self.address = IPv4Address(rawValue: address.rawValue & mask)
        self.prefixLength = ones
    }

    public init?(cidr: String) {
        let parts = cidr.split(separator: "/")
        guard parts.count == 2, let ip = IPv4Address(String(parts[0])), let p = Int(parts[1]), (0...32).contains(p) else {
            return nil
        }
        let mask: UInt32 = p == 0 ? 0 : (0xFFFF_FFFF << (32 - UInt32(p)))
        self.address = IPv4Address(rawValue: ip.rawValue & mask)
        self.prefixLength = p
    }

    public var netmask: IPv4Address {
        let mask: UInt32 = prefixLength == 0 ? 0 : (0xFFFF_FFFF << (32 - UInt32(prefixLength)))
        return IPv4Address(rawValue: mask)
    }

    public var broadcast: IPv4Address {
        IPv4Address(rawValue: address.rawValue | ~netmask.rawValue)
    }

    public var count: UInt64 {
        prefixLength >= 31 ? 2 : (1 << UInt64(32 - prefixLength))
    }

    public func contains(_ ip: IPv4Address) -> Bool {
        (ip.rawValue & netmask.rawValue) == address.rawValue
    }

    /// Candidate alias addresses, taken from the top of the range and skipping
    /// the network/broadcast addresses. The DHCP pool usually starts low, so
    /// the tail is the least likely to collide.
    public func candidateAliases(count: Int, excluding: Set<IPv4Address>) -> [IPv4Address] {
        guard prefixLength <= 30, count > 0 else { return [] }
        let first = address.rawValue + 1
        let last = broadcast.rawValue - 1
        var result: [IPv4Address] = []
        var candidate = last
        while candidate >= first && result.count < count {
            let ip = IPv4Address(rawValue: candidate)
            if !excluding.contains(ip) {
                result.append(ip)
            }
            if candidate == 0 { break }
            candidate -= 1
        }
        return result
    }
}
