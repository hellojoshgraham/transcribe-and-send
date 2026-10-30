import XCTest
import AppKit
import Network
import TSCore
@testable import TSMac

final class ImageTransportTests: XCTestCase {
    @MainActor func testLargeFrameHeaderIsRejectedBeforeAuthenticatedPreparation() async throws {
        let key = PairingKey(); var writes = 0
        let receiver = try await start(key: key) { _ in writes += 1; return true }
        defer { receiver.stop() }
        let channel = SecureChannel(connection: NWConnection(host: "127.0.0.1", port: .init(rawValue: try XCTUnwrap(receiver.listeningPort))!, using: .tcp), key: key)
        defer { channel.close() }
        try await channel.start(); _ = try await channel.receive()
        var size = UInt32(WireCodec.maxFrameBytes + 1).bigEndian
        let header = withUnsafeBytes(of: &size) { Data($0) }
        channel.connection.send(content: header, completion: .contentProcessed { _ in })
        do { _ = try await channel.receive(); XCTFail("An oversized header must be rejected before reading its payload") } catch { }
        XCTAssertEqual(writes, 0)
    }

    @MainActor private func start(key: PairingKey, writer: @escaping @MainActor (ScreenshotPNG) -> Bool) async throws -> ClipboardReceiver {
        let ready = expectation(description: "Image receiver listening")
        let receiver = ClipboardReceiver(writeClipboard: { _ in XCTFail("Image must not use text writer"); return false }, writeImage: writer)
        receiver.onState = { _, active in if active { ready.fulfill() } }
        try receiver.listen(localIP: "127.0.0.1", allowedPeer: "127.0.0.1", port: 0, key: key)
        await fulfillment(of: [ready], timeout: 3)
        return receiver
    }

    @MainActor private func prepare(_ receiver: ClipboardReceiver, key: PairingKey) async throws -> (SecureChannel, UUID, UUID) {
        let channel = SecureChannel(connection: NWConnection(host: "127.0.0.1", port: .init(rawValue: try XCTUnwrap(receiver.listeningPort))!, using: .tcp), key: key)
        try await channel.start()
        let greeting = try await channel.receive(), id = UUID()
        var request = WireMessage(kind: .prepareImage, challenge: greeting.challenge)
        request.version = 2; request.requestID = id
        try await channel.send(request)
        let response = try await channel.receive()
        XCTAssertEqual(response.kind, .imagePrepared); XCTAssertEqual(response.requestID, id)
        return (channel, greeting.challenge, id)
    }

    private func payload(_ data: Data, challenge: UUID, id: UUID) -> WireMessage {
        var request = WireMessage(kind: .image, challenge: challenge, digest: WireCodec.imageDigest(data))
        request.version = 2; request.requestID = id; request.contentType = "public.png"; request.imageData = data
        return request
    }

    @MainActor func testLargePNGEncryptedRoundTripToRealPrivateClipboardNeverRequestsPaste() async throws {
        let image = try ScreenshotPNG.normalize(ScreenshotFixtures.png(width: 1100, height: 800, noisy: true))
        XCTAssertGreaterThan(image.data.count, WireCodec.maxFrameBytes, "Exercise the authenticated larger-frame path")
        let board = NSPasteboard(name: .init("ts-image-roundtrip-\(UUID())"))
        defer { board.releaseGlobally() }
        let key = PairingKey(); var writes = 0
        let receiver = try await start(key: key) { image in writes += 1; return Clipboard.write(image, to: board) }
        defer { receiver.stop() }
        receiver.preparePaste = { XCTFail("Screenshots must never prepare an automatic paste"); return { _, _, _ in .disabled } }
        var stages: [ReceiverProgress] = []
        receiver.onProgress = { stages.append($0) }
        try await ClipboardClient().imageExchange(image, host: "127.0.0.1", port: XCTUnwrap(receiver.listeningPort), key: key)
        XCTAssertEqual(writes, 1); XCTAssertEqual(board.data(forType: .png), image.data)
        XCTAssertNotNil(NSImage(pasteboard: board))
        XCTAssertEqual(stages, [.receivingImage, .imageReady(width: 1100, height: 800)])
    }

    @MainActor func testMalformedMismatchedAndUnsupportedPayloadsNeverWrite() async throws {
        let key = PairingKey(), png = try ScreenshotFixtures.png()
        var writes = 0
        let receiver = try await start(key: key) { _ in writes += 1; return true }
        defer { receiver.stop() }
        for corruption in 0..<6 {
            let (channel, challenge, id) = try await prepare(receiver, key: key)
            defer { channel.close() }
            var request = payload(corruption == 0 ? Data("invalid png".utf8) : png, challenge: corruption == 1 ? UUID() : challenge, id: corruption == 2 ? UUID() : id)
            if corruption == 3 { request.digest = "wrong" }
            if corruption == 4 { request.contentType = "public.tiff" }
            if corruption == 5 { request.text = "Mixed payload" }
            try await channel.send(request)
            do { _ = try await channel.receive(); XCTFail("Invalid screenshot must be rejected") } catch { }
        }
        XCTAssertEqual(writes, 0)
    }

    @MainActor func testWriteFailureIsNeverAcknowledgedAsSuccess() async throws {
        let key = PairingKey(), image = try ScreenshotPNG.normalize(ScreenshotFixtures.png())
        let receiver = try await start(key: key) { _ in false }
        defer { receiver.stop() }
        do { try await ClipboardClient().imageExchange(image, host: "127.0.0.1", port: XCTUnwrap(receiver.listeningPort), key: key); XCTFail("Write failure must reach sender") } catch { }
    }

    @MainActor func testWrongKeyAndProductionLANAddressNeverWrite() async throws {
        let key = PairingKey(), image = try ScreenshotPNG.normalize(ScreenshotFixtures.png())
        var writes = 0
        let receiver = try await start(key: key) { _ in writes += 1; return true }
        defer { receiver.stop() }
        do { try await ClipboardClient().imageExchange(image, host: "127.0.0.1", port: XCTUnwrap(receiver.listeningPort), key: PairingKey()); XCTFail("Wrong key must fail") } catch { }
        do { try await ClipboardClient().sendScreenshot(image, host: "127.0.0.1", port: XCTUnwrap(receiver.listeningPort), key: key); XCTFail("Production API must reject non-Tailscale hosts") } catch { }
        XCTAssertEqual(writes, 0)
    }

    @MainActor func testCancellationPreventsPendingImageWrite() async throws {
        let key = PairingKey(); var writes = 0
        let receiver = try await start(key: key) { _ in writes += 1; return true }
        defer { receiver.stop() }
        let (channel, challenge, id) = try await prepare(receiver, key: key)
        defer { channel.close() }
        receiver.cancelImageDelivery()
        do { try await channel.send(payload(ScreenshotFixtures.png(), challenge: challenge, id: id)); _ = try await channel.receive(); XCTFail("Cancelled session must fail") } catch { }
        XCTAssertEqual(writes, 0)
    }

    @MainActor func testDuplicateAndReplayedImageCannotWriteAgain() async throws {
        let key = PairingKey(); var writes = 0
        let receiver = try await start(key: key) { _ in writes += 1; return true }
        defer { receiver.stop() }
        let (channel, challenge, id) = try await prepare(receiver, key: key)
        defer { channel.close() }
        let image = try ScreenshotFixtures.png(), request = payload(image, challenge: challenge, id: id)
        try await channel.send(request)
        try WireCodec.verifyImageReceipt(await channel.receive(), challenge: challenge, requestID: id, png: image)
        do { try await channel.send(request); _ = try await channel.receive(); XCTFail("One image per connection") } catch { }
        let (second, _, _) = try await prepare(receiver, key: key)
        defer { second.close() }
        try await second.send(request)
        do { _ = try await second.receive(); XCTFail("Cross-connection replay must fail") } catch { }
        XCTAssertEqual(writes, 1)
    }

    @MainActor func testImageCannotInterruptPreparedVoiceDelivery() async throws {
        let key = PairingKey(); var writes = 0
        let receiver = try await start(key: key) { _ in writes += 1; return true }
        defer { receiver.stop() }
        let voice = ClipboardClient()
        defer { voice.cancel() }
        try await voice.prepareAutomaticExchange(host: "127.0.0.1", port: XCTUnwrap(receiver.listeningPort), key: key)
        let image = try ScreenshotPNG.normalize(ScreenshotFixtures.png())
        do { try await ClipboardClient().imageExchange(image, host: "127.0.0.1", port: XCTUnwrap(receiver.listeningPort), key: key); XCTFail("Active dictation owns clipboard delivery") } catch { }
        XCTAssertEqual(writes, 0)
    }

    @MainActor func testOldReceiverIsDetectedBeforeAnyImageIsSent() async throws {
        let key = PairingKey(), ready = expectation(description: "Old listener ready"), closed = expectation(description: "Client closes without sending image")
        let listener = try NWListener(using: .tcp, on: .any)
        defer { listener.cancel() }
        listener.stateUpdateHandler = { state in if case .ready = state { ready.fulfill() } }
        listener.newConnectionHandler = { connection in
            Task { @MainActor in
                let channel = SecureChannel(connection: connection, key: key)
                defer { channel.close(); closed.fulfill() }
                do {
                    try await channel.start()
                    try await channel.send(WireMessage(kind: .challenge, challenge: UUID()))
                    _ = try await channel.receive(); XCTFail("No image or preparation may be sent to an old receiver")
                } catch { }
            }
        }
        listener.start(queue: .main)
        await fulfillment(of: [ready], timeout: 3)
        let image = try ScreenshotPNG.normalize(ScreenshotFixtures.png())
        do { try await ClipboardClient().imageExchange(image, host: "127.0.0.1", port: XCTUnwrap(listener.port?.rawValue), key: key); XCTFail("Upgrade must be required") }
        catch { XCTAssertTrue(error.localizedDescription.contains("Update T&S")) }
        await fulfillment(of: [closed], timeout: 3)
    }
}
