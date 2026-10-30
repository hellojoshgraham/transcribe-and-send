import XCTest
@testable import TSCore

final class SecurityTests: XCTestCase {
    func testTailnetRangeAndRejectUntrustedDestinations() {
        for ip in ["100.64.0.1", "100.127.255.254", "100.100.1.2"] { XCTAssertTrue(TailAddress.isValid(ip), ip) }
        for ip in ["100.63.0.1", "100.128.0.1", "192.168.1.1", "127.0.0.1", "example.com", "100.064.0.1", "100.64.0.999", "100.64.0.1:22", "100.64.0.1\n", "１００.64.0.1", "100.64.0"] { XCTAssertFalse(TailAddress.isValid(ip), ip) }
    }

    func testEncryptedUnicodeRoundTrip() throws {
        let key = PairingKey()
        let message = WireMessage(kind: .text, challenge: UUID(), text: "Unicode test 🏳️‍🌈\n你好 — café")
        let encrypted = try WireCodec.seal(message, key: key)
        XCTAssertFalse(String(decoding: encrypted, as: UTF8.self).contains("Unicode test"))
        XCTAssertEqual(try WireCodec.open(encrypted, key: key), message)
        XCTAssertEqual(try WireCodec.frameLength(WireCodec.frame(encrypted).prefix(4)), encrypted.count)
    }

    func testTamperAndWrongKeyRejected() throws {
        let key = PairingKey(), message = WireMessage(kind: .probe, challenge: UUID())
        var encrypted = try WireCodec.seal(message, key: key)
        XCTAssertThrowsError(try WireCodec.open(encrypted, key: PairingKey()))
        encrypted[encrypted.count - 1] ^= 1
        XCTAssertThrowsError(try WireCodec.open(encrypted, key: key))
    }

    func testOldAndFutureMessagesRejected() throws {
        let key = PairingKey(), now = Date()
        for offset in [-61.0, 61.0] {
            let message = WireMessage(kind: .probe, challenge: UUID(), now: now.addingTimeInterval(offset))
            XCTAssertThrowsError(try WireCodec.open(WireCodec.seal(message, key: key), key: key, now: now))
        }
    }

    func testReceiptMustConfirmExactTransfer() throws {
        let challenge = UUID(), text = "A transcript"
        let good = WireMessage(kind: .receipt, challenge: challenge, digest: WireCodec.digest(text), success: true)
        XCTAssertNoThrow(try WireCodec.verifyReceipt(good, challenge: challenge, text: text))
        XCTAssertThrowsError(try WireCodec.verifyReceipt(good, challenge: UUID(), text: text))
        XCTAssertThrowsError(try WireCodec.verifyReceipt(good, challenge: challenge, text: "different"))
        let failed = WireMessage(kind: .receipt, challenge: challenge, digest: WireCodec.digest(text), success: false)
        XCTAssertThrowsError(try WireCodec.verifyReceipt(failed, challenge: challenge, text: text))
    }

    func testBoundedFramesAndInvalidKeys() {
        for bytes in [Data(), Data([0, 0, 0, 0]), Data([255, 255, 255, 255]), Data([0, 0, 0, 27])] {
            XCTAssertThrowsError(try WireCodec.frameLength(bytes))
        }
        XCTAssertThrowsError(try PairingKey(encoded: "password"))
        XCTAssertThrowsError(try PairingKey(encoded: Data(repeating: 1, count: 16).base64EncodedString()))
    }

    func testTextValidation() {
        for text in ["", " \n", "bad\0text", String(repeating: "x", count: WireCodec.maxTextBytes + 1)] {
            XCTAssertThrowsError(try WireCodec.validateText(text))
        }
        XCTAssertNoThrow(try WireCodec.validateText("line 1\nline 2 🐶"))
    }

    func testCiphertextIsDifferentEachTime() throws {
        let key = PairingKey(), message = WireMessage(kind: .probe, challenge: UUID())
        XCTAssertNotEqual(try WireCodec.seal(message, key: key), try WireCodec.seal(message, key: key))
    }
}
