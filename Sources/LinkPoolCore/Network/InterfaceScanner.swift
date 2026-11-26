import Foundation

public struct InterfaceAddress: Hashable, Sendable {
    public let address: IPv4Address
    public let netmask: IPv4Address
    public var subnet: IPv4Subnet? { IPv4Subnet(address: address, netmask: netmask) }
}

public struct InterfaceInfo: Identifiable, Hashable, Sendable {
    public var id: String { name }
    public let name: String
    public let addresses: [InterfaceAddress]
    public let isUp: Bool
    public let isLoopback: Bool
    public let macAddress: String?
    public let hardwarePort: String?
    public let isDefaultRoute: Bool

    public var displayName: String {
        if let hardwarePort, !hardwarePort.isEmpty { return hardwarePort }
        if name.hasPrefix("en") { return "以太网/无线 \(name)" }
        if name.hasPrefix("utun") { return "VPN 隧道 \(name)" }
        if name.hasPrefix("bridge") { return "网桥 \(name)" }
        return name
    }

    public var isWireless: Bool {
        hardwarePort?.localizedCaseInsensitiveContains("wi-fi") == true
            || hardwarePort?.localizedCaseInsensitiveContains("airport") == true
    }

    public var primaryIPv4: IPv4Address? { addresses.first?.address }
}

public enum InterfaceScanner {
    /// Enumerates non-loopback interfaces that currently have at least one IPv4
    /// address. `includeInactive` also returns interfaces without addresses.
    public static func scan(includeInactive: Bool = false) -> [InterfaceInfo] {
        var result: [InterfaceInfo] = []
        var ifaddrPtr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddrPtr) == 0, let first = ifaddrPtr else { return [] }
        defer { freeifaddrs(ifaddrPtr) }

        let ports = hardwarePorts()
        let defaultIface = defaultRouteInterface()

        var byName: [String: (addrs: [InterfaceAddress], up: Bool, loopback: Bool, mac: String?)] = [:]

        var ptr: UnsafeMutablePointer<ifaddrs>? = first
        while let cur = ptr {
            defer { ptr = cur.pointee.ifa_next }
            let name = String(cString: cur.pointee.ifa_name)
            let flags = Int32(cur.pointee.ifa_flags)
            let isLoopback = (flags & IFF_LOOPBACK) != 0
            let isUp = (flags & IFF_UP) != 0 && (flags & IFF_RUNNING) != 0

            var entry = byName[name] ?? ([], isUp, isLoopback, nil)
            entry.up = entry.up || isUp
            entry.loopback = isLoopback

            if let sa = cur.pointee.ifa_addr, sa.pointee.sa_family == UInt8(AF_INET) {
                let sin = UnsafeRawPointer(sa).assumingMemoryBound(to: sockaddr_in.self).pointee
                let addr = IPv4Address(rawValue: UInt32(bigEndian: sin.sin_addr.s_addr))
                var mask = IPv4Address(255, 255, 255, 255)
                if let ma = cur.pointee.ifa_netmask {
                    let m = UnsafeRawPointer(ma).assumingMemoryBound(to: sockaddr_in.self).pointee
                    mask = IPv4Address(rawValue: UInt32(bigEndian: m.sin_addr.s_addr))
                }
                entry.addrs.append(InterfaceAddress(address: addr, netmask: mask))
            } else if let sa = cur.pointee.ifa_addr, sa.pointee.sa_family == UInt8(AF_LINK) {
                let sll = UnsafeRawPointer(sa).assumingMemoryBound(to: sockaddr_dl.self).pointee
                if sll.sdl_alen == 6 {
                    let mac = withUnsafeBytes(of: sll.sdl_data) { raw -> String in
                        let base = raw.baseAddress!.advanced(by: Int(sll.sdl_nlen))
                        let bytes = base.assumingMemoryBound(to: UInt8.self)
                        return (0..<6).map { String(format: "%02x", bytes[$0]) }.joined(separator: ":")
                    }
                    entry.mac = mac
                }
            }
            byName[name] = entry
        }

        for (name, entry) in byName.sorted(by: { $0.key < $1.key }) {
            if entry.loopback { continue }
            if !includeInactive && entry.addrs.isEmpty { continue }
            result.append(InterfaceInfo(
                name: name,
                addresses: entry.addrs,
                isUp: entry.up,
                isLoopback: entry.loopback,
                macAddress: entry.mac,
                hardwarePort: ports[name],
                isDefaultRoute: name == defaultIface
            ))
        }
        return result
    }

    public static func interface(named name: String) -> InterfaceInfo? {
        scan(includeInactive: true).first { $0.name == name }
    }

    public static func index(of name: String) -> UInt32? {
        let idx = if_nametoindex(name)
        return idx == 0 ? nil : idx
    }

    /// Parses `networksetup -listallhardwareports` into device -> port name.
    public static func hardwarePorts() -> [String: String] {
        guard let output = Shell.run("/usr/sbin/networksetup", ["-listallhardwareports"]) else { return [:] }
        var result: [String: String] = [:]
        var currentPort: String?
        for line in output.split(separator: "\n") {
            let s = line.trimmingCharacters(in: .whitespaces)
            if s.hasPrefix("Hardware Port:") {
                currentPort = s.replacingOccurrences(of: "Hardware Port:", with: "").trimmingCharacters(in: .whitespaces)
            } else if s.hasPrefix("Device:"), let port = currentPort {
                let dev = s.replacingOccurrences(of: "Device:", with: "").trimmingCharacters(in: .whitespaces)
                result[dev] = port
            }
        }
        return result
    }

    public static func defaultRouteInterface() -> String? {
        guard let output = Shell.run("/sbin/route", ["-n", "get", "default"]) else { return nil }
        for line in output.split(separator: "\n") where line.contains("interface:") {
            return line.split(separator: ":").last?.trimmingCharacters(in: .whitespaces)
        }
        return nil
    }

    /// Best guess at the interface that carries campus traffic.
    public static func primaryInterface() -> InterfaceInfo? {
        let all = scan()
        if let name = defaultRouteInterface(), let hit = all.first(where: { $0.name == name }) {
            return hit
        }
        return all.first { $0.name.hasPrefix("en") } ?? all.first
    }
}
