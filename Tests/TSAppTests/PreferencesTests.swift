import XCTest
import TSCore
import TSMac
@testable import TSApp

final class PreferencesTests: XCTestCase {
    func testExistingPreferencesSurviveUpgradeWithoutEnablingAutomaticPaste() throws {
        let data = Data(#"{"role":"Send from this Mac","targetIP":"100.64.1.2","localIP":"100.64.1.3","senderIP":"100.64.1.4","port":"53199","superwhisperFolder":"/example/superwhisper","shortcut":"⌃ ⌥ Space","superwhisperConfigured":true,"resumeReceiver":true}"#.utf8)
        let preferences = try JSONDecoder().decode(Preferences.self, from: data)
        XCTAssertEqual(preferences.targetIP, "100.64.1.2"); XCTAssertEqual(preferences.port, "53199")
        XCTAssertEqual(preferences.superwhisperFolder, "/example/superwhisper"); XCTAssertTrue(preferences.superwhisperConfigured)
        XCTAssertTrue(preferences.resumeReceiver); XCTAssertEqual(preferences.shortcut, .controlOptionSpace)
        XCTAssertEqual(preferences.workflowOptions.recordingMode, .hold)
        XCTAssertFalse(preferences.workflowOptions.automaticallyPaste); XCTAssertFalse(preferences.workflowOptions.allowAutomaticPaste)
        XCTAssertTrue(preferences.workflowOptions.showReceiverStatus)
        XCTAssertFalse(preferences.copiesScreenshots)
        XCTAssertEqual(preferences.switchShortcut, .standard)
        XCTAssertTrue(preferences.hasDifferentLegacyPeers)
        XCTAssertEqual(preferences.senderIP, "100.64.1.4", "Do not silently change an existing allowlist")
    }

    func testNewWorkflowChoicesRoundTrip() throws {
        var preferences = Preferences()
        preferences.workflowOptions.recordingMode = .toggle
        preferences.workflowOptions.automaticallyPaste = true
        preferences.workflowOptions.allowAutomaticPaste = true
        preferences.shortcut = .optionSpace
        preferences.copiesScreenshots = true
        preferences.switchShortcut = ModeShortcut(keyCode: 100, modifierMask: 5)
        let restored = try JSONDecoder().decode(Preferences.self, from: JSONEncoder().encode(preferences))
        XCTAssertEqual(restored.workflowOptions, preferences.workflowOptions)
        XCTAssertEqual(restored.shortcut, .optionSpace)
        XCTAssertTrue(restored.copiesScreenshots)
        XCTAssertEqual(restored.switchShortcut, preferences.switchShortcut)
    }

    func testOneDirectionPairingMigratesWithoutReplacingDifferentPeers() {
        var sender = Preferences(); sender.targetIP = "100.64.1.2"
        sender.migratePairing()
        XCTAssertEqual(sender.senderIP, sender.targetIP)
        var receiver = Preferences(); receiver.senderIP = "100.64.1.3"
        receiver.migratePairing()
        XCTAssertEqual(receiver.targetIP, receiver.senderIP)
        receiver.targetIP = "100.64.1.4"
        receiver.migratePairing()
        XCTAssertTrue(receiver.hasDifferentLegacyPeers)
        XCTAssertTrue(receiver.pairedIP.isEmpty)
        receiver.pairedIP = "100.64.1.5"
        XCTAssertEqual(receiver.targetIP, receiver.senderIP)
    }
}
