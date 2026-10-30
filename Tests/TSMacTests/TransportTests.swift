import XCTest
import Network
import AppKit
import TSCore
@testable import TSMac

final class TransportTests: XCTestCase {
    @MainActor
    func testExpiredConnectionReportsFailureInsteadOfSilentCancellation() async throws {
        let receiver = try await startedReceiver(key: PairingKey()) { _ in XCTFail("Must not write"); return false }
        defer { receiver.stop() }
        let channel = SecureChannel(connection: NWConnection(host: "127.0.0.1", port: .init(rawValue: try XCTUnwrap(receiver.listeningPort))!, using: .tcp), key: PairingKey())
        defer { channel.close() }
        do {
            try await channel.start(timeout: 0)
            XCTFail("An expired connection must fail")
        } catch is CancellationError {
            XCTFail("A deadline is a delivery failure, not a user cancellation")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("timed out"))
        }
    }

    @MainActor
    func testTimeoutWhileWaitingForReplyReportsFailure() async throws {
        let key = PairingKey()
        let receiver = try await startedReceiver(key: key) { _ in XCTFail("Must not write"); return false }
        defer { receiver.stop() }
        let channel = SecureChannel(connection: NWConnection(host: "127.0.0.1", port: .init(rawValue: try XCTUnwrap(receiver.listeningPort))!, using: .tcp), key: key)
        defer { channel.close() }
        try await channel.start()
        _ = try await channel.receive()
        channel.setDeadline(seconds: 0.02)
        do { _ = try await channel.receive(); XCTFail("No reply should arrive") }
        catch is CancellationError { XCTFail("Timeout must remain a visible failure") }
        catch { XCTAssertTrue(error.localizedDescription.contains("timed out")) }
        do { try await channel.start(); XCTFail("Closed channels cannot restart") }
        catch { XCTAssertTrue(error.localizedDescription.contains("timed out")) }
    }

    @MainActor
    func testExplicitCancellationStaysCancellation() async throws {
        let channel = SecureChannel(connection: NWConnection(host: "127.0.0.1", port: 53198, using: .tcp), key: PairingKey())
        channel.close()
        do { try await channel.start(); XCTFail("A cancelled channel cannot start") }
        catch is CancellationError { }
        catch { XCTFail("Unexpected error: \(error)") }
    }

    @MainActor
    private func startedReceiver(key: PairingKey, writer: @escaping (String) -> Bool) async throws -> ClipboardReceiver {
        let ready = expectation(description: "Listener ready")
        let receiver = ClipboardReceiver(writeClipboard: writer)
        receiver.onState = { _, active in if active { ready.fulfill() } }
        try receiver.listen(localIP: "127.0.0.1", allowedPeer: "127.0.0.1", port: 0, key: key)
        await fulfillment(of: [ready], timeout: 3)
        return receiver
    }

    @MainActor
    func testRealTCPEncryptedClipboardRoundTripAndProbe() async throws {
        let key = PairingKey()
        // A private named macOS pasteboard exercises real AppKit without overwriting the user’s clipboard.
        let pasteboard = NSPasteboard(name: .init("ts-tests-\(UUID())"))
        defer { pasteboard.releaseGlobally() }
        pasteboard.setString("original", forType: .string)
        var writes = 0
        let receiver = try await startedReceiver(key: key) { text in
            writes += 1; pasteboard.clearContents()
            return pasteboard.setString(text, forType: .string) && pasteboard.string(forType: .string) == text
        }
        defer { receiver.stop() }
        var activity: [Bool] = []
        receiver.onActivityChanged = { activity.append(receiver.deliveryInProgress) }
        let port = try XCTUnwrap(receiver.listeningPort)
        let client = ClipboardClient()
        try await client.exchange(text: nil, host: "127.0.0.1", port: port, key: key)
        XCTAssertEqual(pasteboard.string(forType: .string), "original"); XCTAssertEqual(writes, 0)
        let text = "T&S test 🏳️‍🌈\nSecond line — 你好"
        try await client.exchange(text: text, host: "127.0.0.1", port: port, key: key)
        XCTAssertEqual(pasteboard.string(forType: .string), text); XCTAssertEqual(writes, 1)
        XCTAssertTrue(activity.contains(true), "A clipboard write must mark receiving busy until its receipt")
    }

    @MainActor
    func testWrongCredentialsNeverWrite() async throws {
        var writes = 0
        let receiver = try await startedReceiver(key: PairingKey()) { _ in writes += 1; return true }
        defer { receiver.stop() }
        do {
            try await ClipboardClient().exchange(text: "Forbidden", host: "127.0.0.1", port: XCTUnwrap(receiver.listeningPort), key: PairingKey())
            XCTFail("Wrong key must fail")
        } catch { }
        XCTAssertEqual(writes, 0)
    }

    @MainActor
    func testFailedClipboardWriteIsNotReportedAsSent() async throws {
        let key = PairingKey()
        let receiver = try await startedReceiver(key: key) { _ in false }
        defer { receiver.stop() }
        do {
            try await ClipboardClient().exchange(text: "Not written", host: "127.0.0.1", port: XCTUnwrap(receiver.listeningPort), key: key)
            XCTFail("Failed write must fail delivery")
        } catch { }
    }

    @MainActor
    func testReplayedChallengeNeverWrites() async throws {
        let key = PairingKey()
        var writes = 0
        let receiver = try await startedReceiver(key: key) { _ in writes += 1; return true }
        defer { receiver.stop() }
        let port = try XCTUnwrap(receiver.listeningPort)
        let first = SecureChannel(connection: NWConnection(host: "127.0.0.1", port: .init(rawValue: port)!, using: .tcp), key: key)
        try await first.start()
        let oldChallenge = try await first.receive().challenge
        first.close()
        let second = SecureChannel(connection: NWConnection(host: "127.0.0.1", port: .init(rawValue: port)!, using: .tcp), key: key)
        defer { second.close() }
        try await second.start()
        let currentChallenge = try await second.receive().challenge
        XCTAssertNotEqual(oldChallenge, currentChallenge)
        try await second.send(WireMessage(kind: .text, challenge: oldChallenge, text: "Replay"))
        do { _ = try await second.receive(); XCTFail("Replay must be disconnected") } catch { }
        XCTAssertEqual(writes, 0)
    }

    @MainActor
    func testProductionAPIsRejectLoopbackAndLAN() async {
        let receiver = ClipboardReceiver { _ in XCTFail("Must never write"); return true }
        XCTAssertThrowsError(try receiver.start(localIP: "0.0.0.0", allowedPeer: "100.64.1.2", port: 53198, key: PairingKey()))
        do { try await ClipboardClient().send(text: "no", host: "192.168.1.1", port: 53198, key: PairingKey()); XCTFail("LAN must be rejected") } catch { }
    }
}
