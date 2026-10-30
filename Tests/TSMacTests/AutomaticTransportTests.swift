import XCTest
import Network
import TSCore
@testable import TSMac

final class AutomaticTransportTests: XCTestCase {
    @MainActor func testClosingPendingConnectionCompletesCancellation() async {
        let completed = expectation(description: "A cancelled connection resumes its caller")
        let channel = SecureChannel(connection: NWConnection(host: "127.0.0.1", port: 9, using: .tcp), key: PairingKey())
        Task { @MainActor in
            // Queue close before Network.framework can deliver its first state.
            DispatchQueue.main.async { channel.close() }
            do { try await channel.start(); XCTFail("A closed pending connection must not become ready") }
            catch is CancellationError { }
            catch { XCTFail("Expected cancellation, received \(error)") }
            completed.fulfill()
        }
        await fulfillment(of: [completed], timeout: 3)
    }

    @MainActor
    private func start(key: PairingKey, writer: @escaping (String) -> Bool = { _ in true }) async throws -> ClipboardReceiver {
        let ready = expectation(description: "Receiver listening")
        let receiver = ClipboardReceiver(writeClipboard: writer, clipboardRevision: { 7 })
        receiver.onState = { _, active in if active { ready.fulfill() } }
        try receiver.listen(localIP: "127.0.0.1", allowedPeer: "127.0.0.1", port: 0, key: key)
        await fulfillment(of: [ready], timeout: 3)
        return receiver
    }

    @MainActor
    private func prepare(_ receiver: ClipboardReceiver, key: PairingKey) async throws -> (SecureChannel, UUID, UUID) {
        let channel = SecureChannel(connection: NWConnection(host: "127.0.0.1", port: .init(rawValue: try XCTUnwrap(receiver.listeningPort))!, using: .tcp), key: key)
        try await channel.start()
        let greeting = try await channel.receive()
        let id = UUID()
        var request = WireMessage(kind: .preparePaste, challenge: greeting.challenge); request.requestID = id
        try await channel.send(request)
        let response = try await channel.receive()
        XCTAssertEqual(response.kind, .prepared); XCTAssertEqual(response.requestID, id)
        return (channel, greeting.challenge, id)
    }

    @MainActor
    private func copy(_ text: String, channel: SecureChannel, challenge: UUID, id: UUID) async throws {
        var request = WireMessage(kind: .text, challenge: challenge, text: text); request.requestID = id
        try await channel.send(request)
        let response = try await channel.receive()
        try WireCodec.verifyReceipt(response, challenge: challenge, text: text)
        XCTAssertEqual(response.requestID, id)
    }

    @MainActor func testAcknowledgedClipboardPrecedesExactlyOnePasteCommand() async throws {
        let key = PairingKey(); var writes = 0, pastes = 0
        let receiver = try await start(key: key) { _ in writes += 1; return true }
        defer { receiver.stop() }
        var activity: [Bool] = []
        receiver.onActivityChanged = { activity.append(receiver.deliveryInProgress) }
        var stages: [ReceiverProgress] = []
        receiver.onProgress = { stages.append($0) }
        receiver.preparePaste = { { text, revision, active in
            XCTAssertEqual(text, "Hello 🐶"); XCTAssertEqual(revision, 7); XCTAssertEqual(writes, 1)
            XCTAssertTrue(active()); pastes += 1; return .requested
        } }
        let (channel, challenge, id) = try await prepare(receiver, key: key)
        defer { channel.close() }
        XCTAssertTrue(receiver.deliveryInProgress)
        XCTAssertEqual(stages, [.waiting]); XCTAssertEqual(writes, 0)
        try await copy("Hello 🐶", channel: channel, challenge: challenge, id: id)
        XCTAssertTrue(receiver.deliveryInProgress, "Keep switching blocked between clipboard receipt and paste")
        XCTAssertEqual(pastes, 0, "Clipboard write alone never triggers paste")
        var paste = WireMessage(kind: .paste, challenge: challenge, digest: WireCodec.digest("Hello 🐶"))
        paste.requestID = id; paste.pasteRequested = true
        try await channel.send(paste)
        let reply = try await channel.receive()
        XCTAssertEqual(reply.kind, .pasteReceipt); XCTAssertEqual(reply.pasteOutcome, .requested)
        XCTAssertEqual(reply.digest, paste.digest); XCTAssertEqual(reply.requestID, id)
        XCTAssertEqual(pastes, 1)
        do { try await channel.send(paste); _ = try await channel.receive(); XCTFail("A second paste must not be accepted") } catch { }
        XCTAssertEqual(pastes, 1)
        XCTAssertEqual(stages, [.waiting, .ready, .pasting, .finished(.requested)])
        XCTAssertFalse(receiver.deliveryInProgress)
        XCTAssertEqual(activity, [true, false])
    }

    @MainActor func testWrongSessionChallengeAndDigestNeverPaste() async throws {
        for corruption in 0..<3 {
            let key = PairingKey(); var pastes = 0
            let receiver = try await start(key: key)
            defer { receiver.stop() }
            receiver.preparePaste = { { _, _, _ in pastes += 1; return .requested } }
            let (channel, challenge, id) = try await prepare(receiver, key: key)
            defer { channel.close() }
            try await copy("Bound text", channel: channel, challenge: challenge, id: id)
            var paste = WireMessage(kind: .paste, challenge: corruption == 0 ? UUID() : challenge, digest: WireCodec.digest(corruption == 1 ? "Wrong text" : "Bound text"))
            paste.requestID = corruption == 2 ? UUID() : id; paste.pasteRequested = true
            try await channel.send(paste)
            do { _ = try await channel.receive(); XCTFail("Invalid paste binding must fail") } catch { }
            XCTAssertEqual(pastes, 0)
        }
    }

    @MainActor func testClientSourceFocusChangeSkipsPasteButConfirmsClipboard() async throws {
        let key = PairingKey(); var writes = 0, pastes = 0
        let receiver = try await start(key: key) { _ in writes += 1; return true }
        defer { receiver.stop() }
        receiver.preparePaste = { { _, _, _ in pastes += 1; return .requested } }
        let client = ClipboardClient()
        try await client.prepareAutomaticExchange(host: "127.0.0.1", port: XCTUnwrap(receiver.listeningPort), key: key)
        let result = try await client.sendAutomatically("Stay on clipboard") { false }
        XCTAssertEqual(result, .senderFocusChanged); XCTAssertEqual(writes, 1); XCTAssertEqual(pastes, 0)
        XCTAssertFalse(client.automaticDeliveryReady)
    }

    @MainActor func testReceiverDefaultsToClipboardOnlyWithoutExplicitPermission() async throws {
        let key = PairingKey(); var writes = 0
        let receiver = try await start(key: key) { _ in writes += 1; return true }
        defer { receiver.stop() }
        let client = ClipboardClient()
        try await client.prepareAutomaticExchange(host: "127.0.0.1", port: XCTUnwrap(receiver.listeningPort), key: key)
        let result = try await client.sendAutomatically("Manual paste") { true }
        XCTAssertEqual(result, .disabled); XCTAssertEqual(writes, 1)
    }

    @MainActor func testFailedClipboardWriteNeverReachesPaste() async throws {
        let key = PairingKey(); var pastes = 0
        let receiver = try await start(key: key, writer: { _ in false })
        defer { receiver.stop() }
        receiver.preparePaste = { { _, _, _ in pastes += 1; return .requested } }
        let client = ClipboardClient()
        try await client.prepareAutomaticExchange(host: "127.0.0.1", port: XCTUnwrap(receiver.listeningPort), key: key)
        do { _ = try await client.sendAutomatically("Cannot write") { true }; XCTFail("Write failure must fail") } catch { }
        XCTAssertEqual(pastes, 0); XCTAssertFalse(client.automaticDeliveryReady)
    }

    @MainActor func testDisconnectAfterClipboardReceiptNeverPastes() async throws {
        let key = PairingKey(); var pastes = 0
        let receiver = try await start(key: key)
        defer { receiver.stop() }
        let cancelled = expectation(description: "Disconnected session clears waiting overlay")
        receiver.onProgress = { if $0 == .cancelled { cancelled.fulfill() } }
        receiver.preparePaste = { { _, _, _ in pastes += 1; return .requested } }
        let (channel, challenge, id) = try await prepare(receiver, key: key)
        try await copy("Copied only", channel: channel, challenge: challenge, id: id)
        channel.close()
        await fulfillment(of: [cancelled], timeout: 3)
        XCTAssertEqual(pastes, 0)
    }

    @MainActor func testReceiverCancellationInvalidatesPreparedDelivery() async throws {
        let key = PairingKey(); var writes = 0, pastes = 0
        let receiver = try await start(key: key) { _ in writes += 1; return true }
        defer { receiver.stop() }
        receiver.preparePaste = { { _, _, _ in pastes += 1; return .requested } }
        let client = ClipboardClient()
        try await client.prepareAutomaticExchange(host: "127.0.0.1", port: XCTUnwrap(receiver.listeningPort), key: key)
        receiver.cancelAutomaticDelivery()
        do { _ = try await client.sendAutomatically("Cancelled") { true }; XCTFail("Cancelled session must fail") } catch { }
        XCTAssertEqual(writes, 0); XCTAssertEqual(pastes, 0)
    }

    @MainActor func testAnotherPreparationCannotReplaceTheActiveTarget() async throws {
        let key = PairingKey(); var captures = 0, pastes = 0
        let receiver = try await start(key: key)
        defer { receiver.stop() }
        receiver.preparePaste = { captures += 1; return { _, _, _ in pastes += 1; return .requested } }
        let first = ClipboardClient(), second = ClipboardClient()
        let port = try XCTUnwrap(receiver.listeningPort)
        try await first.prepareAutomaticExchange(host: "127.0.0.1", port: port, key: key)
        do { try await second.prepareAutomaticExchange(host: "127.0.0.1", port: port, key: key); XCTFail("One prepared target at a time") } catch { }
        let outcome = try await first.sendAutomatically("Original target") { true }
        XCTAssertEqual(outcome, .requested); XCTAssertEqual(captures, 1); XCTAssertEqual(pastes, 1)
    }

    @MainActor func testOldReceiverAllowsManualTransferAfterCapabilityCheckFails() async throws {
        let key = PairingKey(), ready = expectation(description: "Legacy listener ready")
        let listener = try NWListener(using: .tcp, on: .any)
        defer { listener.cancel() }
        var writes = 0
        listener.stateUpdateHandler = { state in if case .ready = state { ready.fulfill() } }
        listener.newConnectionHandler = { connection in
            Task { @MainActor in
                let channel = SecureChannel(connection: connection, key: key)
                defer { channel.close() }
                do {
                    try await channel.start()
                    let challenge = UUID()
                    try await channel.send(WireMessage(kind: .challenge, challenge: challenge)) // 0.1.x has no capabilities.
                    let request = try await channel.receive()
                    guard request.kind == .text, request.challenge == challenge, let text = request.text else { return }
                    writes += 1
                    try await channel.send(WireMessage(kind: .receipt, challenge: challenge, digest: WireCodec.digest(text), success: true))
                } catch { }
            }
        }
        listener.start(queue: .main)
        await fulfillment(of: [ready], timeout: 3)
        let port = try XCTUnwrap(listener.port?.rawValue), client = ClipboardClient()
        do { try await client.prepareAutomaticExchange(host: "127.0.0.1", port: port, key: key); XCTFail("Must require advertised support") } catch { }
        XCTAssertEqual(writes, 0); XCTAssertFalse(client.automaticDeliveryReady)
        try await client.exchange(text: "Manual fallback", host: "127.0.0.1", port: port, key: key)
        XCTAssertEqual(writes, 1)
    }
}
