import XCTest
@testable import TSCore

final class TranscriptTests: XCTestCase {
    private func metadata(_ result: String = "Fresh words", realtime: Bool = false) throws -> Data {
        try JSONSerialization.data(withJSONObject: ["result": result, "duration": 2000, "realtimeEnabled": realtime, "recordingDevice": "Bluetooth headset", "modeName": "Voice"])
    }

    func testOnlyFreshStableMatchingResultIsAccepted() throws {
        var gate = TranscriptGate(baseline: ["old"], clipboardCount: 10)
        let now = Date(), files = ["old": try metadata("Old"), "new": try metadata()]
        XCTAssertNil(try gate.evaluate(recordings: files, clipboardText: "Fresh words", clipboardCount: 11, now: now))
        XCTAssertNil(try gate.evaluate(recordings: files, clipboardText: "Fresh words", clipboardCount: 11, now: now.addingTimeInterval(0.3)))
        let result = try gate.evaluate(recordings: files, clipboardText: "Fresh words", clipboardCount: 11, now: now.addingTimeInterval(0.6))
        XCTAssertEqual(result?.result, "Fresh words")
        XCTAssertEqual(result?.recordingDevice, "Bluetooth headset")
    }

    func testUnrelatedClipboardIsNeverRelayed() throws {
        var gate = TranscriptGate(baseline: [], clipboardCount: 10)
        let files = ["new": try metadata()]
        XCTAssertNil(try gate.evaluate(recordings: files, clipboardText: "password copied by user", clipboardCount: 11))
        XCTAssertNil(try gate.evaluate(recordings: files, clipboardText: "Fresh words", clipboardCount: 10))
    }

    func testOldRecordingAndPartialMetadataAreIgnored() throws {
        var gate = TranscriptGate(baseline: ["old"], clipboardCount: 10)
        XCTAssertNil(try gate.evaluate(recordings: ["old": try metadata()], clipboardText: "Fresh words", clipboardCount: 11))
        XCTAssertNil(try gate.evaluate(recordings: ["new": Data("{".utf8)], clipboardText: "Fresh words", clipboardCount: 11))
    }

    func testAmbiguityAndRealtimeFailClosed() throws {
        var gate = TranscriptGate(baseline: [], clipboardCount: 10)
        XCTAssertThrowsError(try gate.evaluate(recordings: ["one": try metadata(), "two": try metadata()], clipboardText: "Fresh words", clipboardCount: 11))
        XCTAssertThrowsError(try gate.evaluate(recordings: ["one": try metadata(realtime: true)], clipboardText: "Fresh words", clipboardCount: 11))
    }

    func testChangedOrInterruptedCandidateRestartsStabilityWindow() throws {
        var gate = TranscriptGate(baseline: [], clipboardCount: 10)
        let now = Date()
        XCTAssertNil(try gate.evaluate(recordings: ["new": try metadata()], clipboardText: "Fresh words", clipboardCount: 11, now: now))
        XCTAssertNil(try gate.evaluate(recordings: ["new": try metadata()], clipboardText: "Other", clipboardCount: 12, now: now.addingTimeInterval(0.6)))
        XCTAssertNil(try gate.evaluate(recordings: ["new": try metadata("Revised")], clipboardText: "Revised", clipboardCount: 13, now: now.addingTimeInterval(1)))
        XCTAssertEqual(try gate.evaluate(recordings: ["new": try metadata("Revised")], clipboardText: "Revised", clipboardCount: 13, now: now.addingTimeInterval(1.6))?.result, "Revised")
    }
}
