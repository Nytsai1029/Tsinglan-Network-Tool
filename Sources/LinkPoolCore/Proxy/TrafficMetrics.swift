import Foundation

/// Lock-protected byte counters per egress. Cheap enough to update once per
/// 64 KiB chunk and to sample twice a second from the UI.
public final class TrafficMetrics: @unchecked Sendable {
    public struct Totals: Sendable, Equatable {
        public var bytesIn: UInt64 = 0
        public var bytesOut: UInt64 = 0
        public var activeConnections: Int = 0

        public var total: UInt64 { bytesIn &+ bytesOut }

        public init() {}

        public init(bytesIn: UInt64, bytesOut: UInt64, activeConnections: Int) {
            self.bytesIn = bytesIn
            self.bytesOut = bytesOut
            self.activeConnections = activeConnections
        }
    }

    private struct Counter {
        var bytesIn: UInt64 = 0
        var bytesOut: UInt64 = 0
        var active: Int = 0
    }

    private let lock = NSLock()
    private var counters: [UUID: Counter] = [:]
    private var globalConnections = 0

    public init() {}

    public func addIn(_ egress: UUID, _ bytes: Int) {
        guard bytes > 0 else { return }
        lock.lock(); counters[egress, default: Counter()].bytesIn &+= UInt64(bytes); lock.unlock()
    }

    public func addOut(_ egress: UUID, _ bytes: Int) {
        guard bytes > 0 else { return }
        lock.lock(); counters[egress, default: Counter()].bytesOut &+= UInt64(bytes); lock.unlock()
    }

    public func connectionOpened(_ egress: UUID) {
        lock.lock()
        counters[egress, default: Counter()].active += 1
        globalConnections += 1
        lock.unlock()
    }

    public func connectionClosed(_ egress: UUID) {
        lock.lock()
        if var counter = counters[egress] {
            counter.active = max(0, counter.active - 1)
            counters[egress] = counter
        }
        globalConnections = max(0, globalConnections - 1)
        lock.unlock()
    }

    public func totals(for egress: UUID) -> Totals {
        lock.lock(); defer { lock.unlock() }
        guard let counter = counters[egress] else { return Totals() }
        return Totals(bytesIn: counter.bytesIn, bytesOut: counter.bytesOut,
                      activeConnections: counter.active)
    }

    public func grandTotals() -> Totals {
        allTotals().values.reduce(into: Totals()) { acc, item in
            acc.bytesIn &+= item.bytesIn
            acc.bytesOut &+= item.bytesOut
            acc.activeConnections += item.activeConnections
        }
    }

    public func allTotals() -> [UUID: Totals] {
        lock.lock(); defer { lock.unlock() }
        return counters.mapValues {
            Totals(bytesIn: $0.bytesIn, bytesOut: $0.bytesOut, activeConnections: $0.active)
        }
    }

    public var activeConnections: Int {
        lock.lock(); defer { lock.unlock() }
        return globalConnections
    }

    public func reset() {
        lock.lock(); counters.removeAll(); globalConnections = 0; lock.unlock()
    }
}

/// Chooses which egress carries a new connection.
public final class EgressSelector: @unchecked Sendable {
    private let lock = NSLock()
    private var cursor = 0
    private var active: [UUID: Int] = [:]
    private var sticky: [String: (egress: UUID, expires: Date)] = [:]

    public init() {}

    public func select(from candidates: [Egress], host: String,
                       strategy: ProxyStrategy, stickySeconds: Int) -> Egress? {
        guard !candidates.isEmpty else { return nil }
        lock.lock(); defer { lock.unlock() }

        if stickySeconds > 0 {
            if let pin = sticky[host], pin.expires > Date(),
               let match = candidates.first(where: { $0.id == pin.egress }) {
                return match
            }
            defer {}
        }

        let pool = candidates.filter { $0.isEnabled && $0.weight > 0 }
        guard !pool.isEmpty else { return nil }

        let chosen: Egress
        switch strategy {
        case .roundRobin:
            let total = pool.reduce(0) { $0 + max(1, $1.weight) }
            var slot = cursor % max(1, total)
            cursor = (cursor + 1) & 0x7FFF_FFFF
            chosen = pool.first { egress in
                slot -= max(1, egress.weight)
                return slot < 0
            } ?? pool[0]
        case .leastConnections:
            chosen = pool.min {
                Double(active[$0.id] ?? 0) / Double(max(1, $0.weight))
                    < Double(active[$1.id] ?? 0) / Double(max(1, $1.weight))
            } ?? pool[0]
        case .weighted:
            let total = pool.reduce(0) { $0 + max(1, $1.weight) }
            var slot = Int.random(in: 0..<max(1, total))
            chosen = pool.first { egress in
                slot -= max(1, egress.weight)
                return slot < 0
            } ?? pool[0]
        }

        if stickySeconds > 0 {
            sticky[host] = (chosen.id, Date().addingTimeInterval(TimeInterval(stickySeconds)))
        }
        return chosen
    }

    public func connectionOpened(_ egress: UUID) {
        lock.lock(); active[egress, default: 0] += 1; lock.unlock()
    }

    public func connectionClosed(_ egress: UUID) {
        lock.lock()
        active[egress] = max(0, (active[egress] ?? 1) - 1)
        lock.unlock()
    }

    public func reset() {
        lock.lock(); active.removeAll(); sticky.removeAll(); cursor = 0; lock.unlock()
    }
}
