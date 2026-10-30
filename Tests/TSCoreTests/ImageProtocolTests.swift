import XCTest
@testable import TSCore

final class ImageProtocolTests: XCTestCase {
    func testImageMessagesRequireVersionTwoAndTextCannotCarryImages() throws {
        var image = WireMessage(kind: .image, challenge: UUID())
        XCTAssertThrowsError(try image.validate())
        image.version = 2; XCTAssertNoThrow(try image.validate())
        var text = WireMessage(kind: .text, challenge: UUID(), text: "hello")
        text.imageData = Data([1]); XCTAssertThrowsError(try text.validate())
        text.imageData = nil; XCTAssertNoThrow(try text.validate())
    }

    func testLargerFramesRequireExplicitImageAllowanceAndRemainBounded() throws {
        let data = Data(repeating: 7, count: WireCodec.maxFrameBytes + 1)
        XCTAssertThrowsError(try WireCodec.frame(data))
        let frame = try WireCodec.frame(data, maximumBytes: WireCodec.maxImageFrameBytes)
        XCTAssertThrowsError(try WireCodec.frameLength(Data(frame.prefix(4))))
        XCTAssertEqual(try WireCodec.frameLength(Data(frame.prefix(4)), maximumBytes: WireCodec.maxImageFrameBytes), data.count)
        var length = UInt32(WireCodec.maxImageFrameBytes + 1).bigEndian
        let tooLarge = withUnsafeBytes(of: &length) { Data($0) }
        XCTAssertThrowsError(try WireCodec.frameLength(tooLarge, maximumBytes: WireCodec.maxImageFrameBytes))
        XCTAssertEqual(WireCodec.maxTextBytes, 256 * 1024)
    }

    func testImageReceiptMustBindExactImageSessionChallengeAndSuccess() throws {
        let data = Data("fixture".utf8), challenge = UUID(), id = UUID()
        var receipt = WireMessage(kind: .imageReceipt, challenge: challenge, digest: WireCodec.imageDigest(data), success: true)
        receipt.version = 2; receipt.requestID = id; receipt.contentType = "public.png"
        XCTAssertNoThrow(try WireCodec.verifyImageReceipt(receipt, challenge: challenge, requestID: id, png: data))
        XCTAssertThrowsError(try WireCodec.verifyImageReceipt(receipt, challenge: UUID(), requestID: id, png: data))
        XCTAssertThrowsError(try WireCodec.verifyImageReceipt(receipt, challenge: challenge, requestID: UUID(), png: data))
        XCTAssertThrowsError(try WireCodec.verifyImageReceipt(receipt, challenge: challenge, requestID: id, png: Data([1])))
        receipt.success = false
        XCTAssertThrowsError(try WireCodec.verifyImageReceipt(receipt, challenge: challenge, requestID: id, png: data))
    }
}
