import XCTest
@testable import TSCore

final class ShortcutGestureTests: XCTestCase {
    private let chord: ShortcutGesture.Modifiers = [.control, .option]
    private func gesture() -> ShortcutGesture { ShortcutGesture(key: 49, modifiers: chord) }

    func testReservedKeyPressRepeatAndReleaseAreConsumed() {
        var filter = gesture()
        XCTAssertEqual(filter.handle(.down(key: 49, repeating: false), modifiers: chord), .init(consume: true, action: .pressed))
        XCTAssertEqual(filter.handle(.down(key: 49, repeating: true), modifiers: chord), .init(consume: true))
        XCTAssertEqual(filter.handle(.up(key: 49), modifiers: chord), .init(consume: true, action: .released))
        XCTAssertEqual(filter.handle(.up(key: 49), modifiers: chord), .init())
    }

    func testUnrelatedTypingAndExtraModifiersPassThrough() {
        var filter = gesture()
        XCTAssertEqual(filter.handle(.down(key: 0, repeating: false), modifiers: chord), .init())
        XCTAssertEqual(filter.handle(.up(key: 0), modifiers: chord), .init())
        XCTAssertEqual(filter.handle(.down(key: 49, repeating: false), modifiers: []), .init())
        XCTAssertEqual(filter.handle(.down(key: 49, repeating: false), modifiers: [.control, .option, .shift]), .init())
        XCTAssertEqual(filter.handle(.modifiersChanged, modifiers: chord), .init())
    }

    func testReleaseModifierFirstStopsOnceAndStillSuppressesSpace() {
        var filter = gesture()
        _ = filter.handle(.down(key: 49, repeating: false), modifiers: chord)
        XCTAssertEqual(filter.handle(.modifiersChanged, modifiers: [.control]), .init(action: .released))
        XCTAssertEqual(filter.handle(.modifiersChanged, modifiers: []), .init())
        XCTAssertEqual(filter.handle(.down(key: 49, repeating: true), modifiers: []), .init(consume: true))
        XCTAssertEqual(filter.handle(.up(key: 49), modifiers: []), .init(consume: true))
        XCTAssertFalse(filter.ownsKey)
    }

    func testSpaceFirstReleaseThenModifiersHasNoDuplicateStop() {
        var filter = gesture()
        _ = filter.handle(.down(key: 49, repeating: false), modifiers: chord)
        XCTAssertEqual(filter.handle(.up(key: 49), modifiers: chord), .init(consume: true, action: .released))
        XCTAssertEqual(filter.handle(.modifiersChanged, modifiers: []), .init())
    }

    func testModifierAddedWhileSpaceAlreadyRepeatingDoesNotStart() {
        var filter = gesture()
        XCTAssertEqual(filter.handle(.down(key: 49, repeating: false), modifiers: []), .init())
        XCTAssertEqual(filter.handle(.modifiersChanged, modifiers: chord), .init())
        XCTAssertEqual(filter.handle(.down(key: 49, repeating: true), modifiers: chord), .init())
        XCTAssertEqual(filter.handle(.up(key: 49), modifiers: chord), .init())
    }

    func testInterruptionCancelsWithoutSendingAndDrainsHeldKey() {
        var filter = gesture()
        _ = filter.handle(.down(key: 49, repeating: false), modifiers: chord)
        XCTAssertEqual(filter.interrupt(keyStillDown: true), .init(action: .interrupted))
        XCTAssertEqual(filter.handle(.down(key: 49, repeating: true), modifiers: chord), .init(consume: true))
        XCTAssertEqual(filter.handle(.up(key: 49), modifiers: []), .init(consume: true))
        XCTAssertEqual(filter.handle(.down(key: 49, repeating: false), modifiers: chord), .init(consume: true, action: .pressed))
    }

    func testLostReleaseClearsCaptureOnInterruption() {
        var filter = gesture()
        _ = filter.handle(.down(key: 49, repeating: false), modifiers: chord)
        XCTAssertEqual(filter.interrupt(keyStillDown: false), .init(action: .interrupted))
        XCTAssertFalse(filter.ownsKey)
        XCTAssertEqual(filter.handle(.down(key: 49, repeating: false), modifiers: []), .init())
    }

    func testExtraModifierDuringHoldDoesNotEndDictation() {
        var filter = gesture()
        _ = filter.handle(.down(key: 49, repeating: false), modifiers: chord)
        XCTAssertEqual(filter.handle(.modifiersChanged, modifiers: [.control, .option, .shift]), .init())
        XCTAssertEqual(filter.handle(.up(key: 49), modifiers: [.control, .option, .shift]), .init(consume: true, action: .released))
    }
}
