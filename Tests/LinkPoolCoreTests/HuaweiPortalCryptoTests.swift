import XCTest
@testable import LinkPoolCore

final class HuaweiPortalCryptoTests: XCTestCase {
    func testKnownVectors() {
        XCTAssertEqual(HuaweiPortalCrypto.rc4Hex("p@ssw0rd", key: "1795679821000"),
                       "2ac22de83d63df6e")
        XCTAssertEqual(HuaweiPortalCrypto.rc4Hex("Tsinglan@2026", key: "1795679821000"),
                       "0ef137f52d3fcc64246176dccc")
        XCTAssertEqual(HuaweiPortalCrypto.rc4Hex("abc123", key: "1795679821000"),
                       "3be03daa7860")
    }

    func testEmptyInputs() {
        XCTAssertEqual(HuaweiPortalCrypto.rc4Hex("", key: "1"), "")
        XCTAssertEqual(HuaweiPortalCrypto.rc4Hex("abc", key: ""), "")
    }

    func testLengthAndAlphabet() {
        let out = HuaweiPortalCrypto.rc4Hex("hello world", key: "1700000000000")
        XCTAssertEqual(out.count, 22)
        XCTAssertTrue(out.allSatisfy { $0.isHexDigit })
    }
}
