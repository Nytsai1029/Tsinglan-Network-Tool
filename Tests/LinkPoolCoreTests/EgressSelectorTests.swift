import XCTest
@testable import LinkPoolCore

final class EgressSelectorTests: XCTestCase {
    private func egress(_ name: String, weight: Int = 1) -> Egress {
        Egress(name: name, interfaceName: "en0", localAddress: "10.0.0.1", weight: weight)
    }

    func testRoundRobinHonoursWeights() {
        let selector = EgressSelector()
        let a = egress("A", weight: 1)
        let b = egress("B", weight: 3)
        var counts: [String: Int] = [:]
        for _ in 0..<8 {
            let chosen = selector.select(from: [a, b], host: "example.com",
                                         strategy: .roundRobin, stickySeconds: 0)
            counts[chosen!.name, default: 0] += 1
        }
        XCTAssertEqual(counts["A"], 2)
        XCTAssertEqual(counts["B"], 6)
    }

    func testLeastConnectionsPrefersIdleLink() {
        let selector = EgressSelector()
        let a = egress("A")
        let b = egress("B")
        selector.connectionOpened(a.id)
        selector.connectionOpened(a.id)
        for _ in 0..<3 {
            XCTAssertEqual(selector.select(from: [a, b], host: "h", strategy: .leastConnections,
                                           stickySeconds: 0)?.id, b.id)
        }
    }

    func testStickyKeepsHostOnOneEgress() {
        let selector = EgressSelector()
        let a = egress("A")
        let b = egress("B")
        let first = selector.select(from: [a, b], host: "bank.example", strategy: .roundRobin, stickySeconds: 60)
        for _ in 0..<5 {
            XCTAssertEqual(selector.select(from: [a, b], host: "bank.example", strategy: .roundRobin,
                                           stickySeconds: 60)?.id, first?.id)
        }
        // A different host may use the other link.
        let other = selector.select(from: [a, b], host: "cdn.example", strategy: .roundRobin, stickySeconds: 60)
        XCTAssertNotNil(other)
    }

    func testEmptyPoolReturnsNil() {
        XCTAssertNil(EgressSelector().select(from: [], host: "h", strategy: .roundRobin, stickySeconds: 0))
    }
}
