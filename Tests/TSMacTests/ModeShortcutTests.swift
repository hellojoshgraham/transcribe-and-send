import XCTest
@testable import TSMac

final class ModeShortcutTests: XCTestCase {
    func testDefaultCustomAndPersistedSwitchShortcuts() throws {
        XCTAssertEqual(ModeShortcut.standard.label, "⌥ ⇧ ⌘ S")
        try ModeShortcut.standard.validate(voice: .optionSpace, screenshots: true)
        let custom = ModeShortcut(keyCode: 100, modifierMask: 5)
        try custom.validate(voice: .optionSpace, screenshots: true)
        XCTAssertEqual(try JSONDecoder().decode(ModeShortcut.self, from: JSONEncoder().encode(custom)), custom)
    }
    func testConflictsAndUnsafePlainKeysAreRejectedBeforeRegistration() {
        for chord in [ModeShortcut(keyCode: 49, modifierMask: 2), ModeShortcut(keyCode: 20, modifierMask: 12),
                      ModeShortcut(keyCode: 1, modifierMask: 0), ModeShortcut(keyCode: 1, modifierMask: 8),
                      ModeShortcut(keyCode: 1, modifierMask: 255), ModeShortcut(keyCode: 65535, modifierMask: 4)] {
            XCTAssertThrowsError(try chord.validate(voice: .optionSpace, screenshots: true))
        }
    }
}
