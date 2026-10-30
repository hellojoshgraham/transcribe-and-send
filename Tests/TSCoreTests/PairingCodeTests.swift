import XCTest
@testable import TSCore

final class PairingCodeTests: XCTestCase {
    func testPairingCodeRoundTripPreservesOnlyConnectionData() throws {
        let key = PairingKey()
        let code = try PairingCode(address: "100.64.1.2", port: 53198, key: key)
        let restored = try PairingCode(encoded: "\n" + code.encoded() + "\n")
        XCTAssertEqual(restored.address, code.address)
        XCTAssertEqual(restored.port, code.port)
        XCTAssertEqual(restored.key.data, key.data)
    }

    func testInvalidUnboundedAndNonTailscaleCodesAreRejected() throws {
        for text in ["", "https://example.com", "ts-pair:2:abcd", String(repeating: "a", count: 2048)] {
            XCTAssertThrowsError(try PairingCode(encoded: text))
        }
        for address in ["127.0.0.1", "192.168.1.2", "example.com", "100.64.1.2:22"] {
            XCTAssertThrowsError(try PairingCode(address: address, port: 53198, key: PairingKey()))
        }
        for payload in [
            "{\"version\":2,\"address\":\"100.64.1.2\",\"port\":53198,\"key\":\"bad\"}",
            "{\"version\":1,\"address\":\"100.64.1.2\",\"port\":0,\"key\":\"bad\"}",
            "{\"version\":1,\"address\":\"100.64.1.2\",\"port\":53198,\"key\":\"bad\"}"
        ] {
            XCTAssertThrowsError(try PairingCode(encoded: "ts-pair:1:" + Data(payload.utf8).base64EncodedString()))
        }
    }
}
