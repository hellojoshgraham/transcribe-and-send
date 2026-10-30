import AppKit
import ApplicationServices
import XCTest
@testable import TSMac

/// Opt-in desktop integration test. Only uniquely tagged test events are used;
/// a HID-stage sink prevents them from reaching the focused application.
final class HotKeyRoutingTests: XCTestCase {
    @MainActor
    private final class Probe {
        let tag = Int64.random(in: 1...Int64.max)
        var upstreamEvents = 0
        var sessionEvents = 0
        var onUpstream: (() -> Void)?
        var taps: [(CFMachPort, CFRunLoopSource)] = []

        func install(at location: CGEventTapLocation) throws {
            let mask = (CGEventMask(1) << CGEventType.keyDown.rawValue) | (CGEventMask(1) << CGEventType.keyUp.rawValue)
            let tap = try XCTUnwrap(CGEvent.tapCreate(tap: location, place: .headInsertEventTap, options: .defaultTap, eventsOfInterest: mask, callback: { _, type, event, context in
                guard let context else { return Unmanaged.passUnretained(event) }
                return MainActor.assumeIsolated {
                    let probe = Unmanaged<Probe>.fromOpaque(context).takeUnretainedValue()
                    guard event.getIntegerValueField(.eventSourceUserData) == probe.tag else { return Unmanaged.passUnretained(event) }
                    if type == .keyDown || type == .keyUp {
                        probe.upstreamEvents += 1; probe.onUpstream?()
                    }
                    return nil
                }
            }, userInfo: Unmanaged.passUnretained(self).toOpaque()))
            let source = try XCTUnwrap(CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0))
            taps.append((tap, source))
            CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
            CGEvent.tapEnable(tap: tap, enable: true)
        }

        func installSessionObserver() throws {
            let mask = (CGEventMask(1) << CGEventType.keyDown.rawValue) | (CGEventMask(1) << CGEventType.keyUp.rawValue)
            let tap = try XCTUnwrap(CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap, eventsOfInterest: mask, callback: { _, _, event, context in
                guard let context else { return Unmanaged.passUnretained(event) }
                return MainActor.assumeIsolated {
                    let probe = Unmanaged<Probe>.fromOpaque(context).takeUnretainedValue()
                    guard event.getIntegerValueField(.eventSourceUserData) == probe.tag else { return Unmanaged.passUnretained(event) }
                    probe.sessionEvents += 1
                    return nil
                }
            }, userInfo: Unmanaged.passUnretained(self).toOpaque()))
            let source = try XCTUnwrap(CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0))
            taps.append((tap, source))
            CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
            CGEvent.tapEnable(tap: tap, enable: true)
        }

        func post(down: Bool, repeating: Bool = false, modifiers: CGEventFlags? = nil, key: CGKeyCode = 100) throws {
            let source = try XCTUnwrap(CGEventSource(stateID: .privateState))
            let event = try XCTUnwrap(CGEvent(keyboardEventSource: source, virtualKey: key, keyDown: down))
            event.flags = modifiers ?? (down ? [.maskControl, .maskAlternate] : [])
            event.setIntegerValueField(.keyboardEventAutorepeat, value: repeating ? 1 : 0)
            event.setIntegerValueField(.eventSourceUserData, value: tag)
            event.post(tap: .cghidEventTap)
        }

        func close() {
            for (tap, source) in taps {
                CGEvent.tapEnable(tap: tap, enable: false)
                CFMachPortInvalidate(tap)
                CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes)
            }
            taps.removeAll()
        }
    }

    @MainActor
    func testModeSwitchStaysLocalInBothRolesAndConsumesRepeatAndRelease() async throws {
        guard ProcessInfo.processInfo.environment["TS_TEST_EVENT_TAPS"] == "1", AXIsProcessTrusted(), CGPreflightPostEventAccess() else {
            throw XCTSkip("Opt in to native routing with existing Accessibility permission.")
        }
        let probe = Probe(); defer { probe.close() }
        try probe.install(at: .cghidEventTap)
        let hotKey = HotKey(); defer { hotKey.unregister() }
        hotKey.pressed = { XCTFail("Mode switch must not start recording") }
        hotKey.screenshotPressed = { XCTFail("Mode switch must not capture a screenshot") }
        for transmitting in [true, false, true] {
            let switched = expectation(description: "Mode switch after key release")
            var count = 0
            hotKey.switchMode = { count += 1; switched.fulfill() }
            try hotKey.register(transmitting ? .optionSpace : nil, copyScreenshots: transmitting, modeSwitch: .standard)
            let flags: CGEventFlags = [.maskCommand, .maskAlternate, .maskShift]
            try probe.post(down: true, modifiers: flags, key: 1)
            try probe.post(down: true, repeating: true, modifiers: flags, key: 1)
            try probe.post(down: false, modifiers: [], key: 1)
            await fulfillment(of: [switched], timeout: 2)
            XCTAssertEqual(count, 1)
            XCTAssertEqual(probe.upstreamEvents, 0, "No key event may escape to a remote client")
        }
        let unrelated = expectation(description: "Voice and screenshot keys pass through in RX")
        unrelated.expectedFulfillmentCount = 4
        probe.onUpstream = { unrelated.fulfill() }
        try hotKey.register(nil, modeSwitch: .standard)
        try probe.post(down: true, modifiers: [.maskAlternate], key: 49)
        try probe.post(down: false, modifiers: [], key: 49)
        try probe.post(down: true, modifiers: [.maskCommand, .maskShift], key: 20)
        try probe.post(down: false, modifiers: [], key: 20)
        await fulfillment(of: [unrelated], timeout: 2)
    }

    @MainActor
    func testScreenshotShortcutIsLocalOnlyWhileEnabledAndDoesNotTriggerVoice() async throws {
        guard ProcessInfo.processInfo.environment["TS_TEST_EVENT_TAPS"] == "1", AXIsProcessTrusted(), CGPreflightPostEventAccess() else {
            throw XCTSkip("Opt in with TS_TEST_EVENT_TAPS=1 and existing Accessibility permission.")
        }
        let probe = Probe()
        defer { probe.close() }
        // The sink consumes every tagged event, including when the feature is off.
        // No screenshot command can reach macOS or the foreground application.
        try probe.install(at: .cghidEventTap)
        let hotKey = HotKey()
        defer { hotKey.unregister() }
        hotKey.pressed = { XCTFail("Screenshot must not start voice") }
        let pressed = expectation(description: "Screenshot press captured locally")
        let released = expectation(description: "Screenshot release captured once")
        hotKey.screenshotPressed = { pressed.fulfill() }; hotKey.screenshotReleased = { released.fulfill() }
        try hotKey.register(.optionSpace, copyScreenshots: true)
        try probe.post(down: true, modifiers: [.maskCommand, .maskShift], key: 20)
        try probe.post(down: true, repeating: true, modifiers: [.maskCommand, .maskShift], key: 20)
        try probe.post(down: false, modifiers: [], key: 20)
        await fulfillment(of: [pressed, released], timeout: 2, enforceOrder: true)
        XCTAssertEqual(probe.upstreamEvents, 0)
        hotKey.screenshotPressed = { XCTFail("Disabled screenshot mode must not run") }
        hotKey.screenshotReleased = { XCTFail("Disabled screenshot mode must not run") }
        try hotKey.register(.optionSpace, copyScreenshots: false)
        let pass = expectation(description: "Disabled chord passes to next filter")
        pass.expectedFulfillmentCount = 2
        probe.onUpstream = { pass.fulfill() }
        try probe.post(down: true, modifiers: [.maskCommand, .maskShift], key: 20)
        try probe.post(down: false, modifiers: [], key: 20)
        await fulfillment(of: [pass], timeout: 2)
        XCTAssertEqual(probe.upstreamEvents, 2)
    }

    @MainActor
    func testShortcutPrecedesAnUpstreamFilterThatHidesKeysFromSessionTaps() async throws {
        guard ProcessInfo.processInfo.environment["TS_TEST_EVENT_TAPS"] == "1" else {
            throw XCTSkip("Set TS_TEST_EVENT_TAPS=1 for the tagged desktop routing test.")
        }
        guard AXIsProcessTrusted(), CGPreflightPostEventAccess() else {
            throw XCTSkip("The test runner needs existing Accessibility access; tests never request it.")
        }
        let probe = Probe()
        defer { probe.close() }
        try probe.install(at: .cghidEventTap)
        try probe.installSessionObserver()
        let baseline = expectation(description: "Earlier filter consumes both tagged events")
        baseline.expectedFulfillmentCount = 2
        probe.onUpstream = { baseline.fulfill() }
        try probe.post(down: true)
        try probe.post(down: false)
        await fulfillment(of: [baseline], timeout: 2)
        probe.onUpstream = nil
        XCTAssertEqual(probe.upstreamEvents, 2)
        XCTAssertEqual(probe.sessionEvents, 0, "Even a head-inserted session tap never sees keys consumed at HID")

        let hotKey = HotKey()
        defer { hotKey.unregister() }
        let pressed = expectation(description: "Production shortcut receives press before the earlier filter")
        let released = expectation(description: "Production shortcut receives release")
        var presses = 0
        var releases = 0
        hotKey.pressed = { presses += 1; pressed.fulfill() }
        hotKey.released = { releases += 1; released.fulfill() }
        try hotKey.register(.controlOptionF8)
        try probe.post(down: true)
        try probe.post(down: true, repeating: true)
        try probe.post(down: false)
        await fulfillment(of: [pressed, released], timeout: 2, enforceOrder: true)
        XCTAssertEqual(probe.upstreamEvents, 2, "The production handler must consume the second pair before the competing filter")
        XCTAssertEqual(probe.sessionEvents, 0)
        XCTAssertEqual(presses, 1)
        XCTAssertEqual(releases, 1)

        let unrelated = expectation(description: "Unreserved F8 passes through unchanged")
        unrelated.expectedFulfillmentCount = 2
        probe.onUpstream = { unrelated.fulfill() }
        try probe.post(down: true, modifiers: [])
        try probe.post(down: false)
        await fulfillment(of: [unrelated], timeout: 2)
        probe.onUpstream = nil
        XCTAssertEqual(probe.upstreamEvents, 4)
        XCTAssertEqual(presses, 1)
        XCTAssertEqual(releases, 1)

        // A client can install another filter after activation. Reconnecting
        // the production listener must actually recreate it at the head.
        try probe.install(at: .cghidEventTap)
        try hotKey.retryCapture()
        let reconnectedPress = expectation(description: "Reconnected listener receives press")
        let reconnectedRelease = expectation(description: "Reconnected listener receives release")
        hotKey.pressed = { reconnectedPress.fulfill() }
        hotKey.released = { reconnectedRelease.fulfill() }
        try probe.post(down: true)
        try probe.post(down: false)
        await fulfillment(of: [reconnectedPress, reconnectedRelease], timeout: 2, enforceOrder: true)
        XCTAssertEqual(probe.upstreamEvents, 4)
        XCTAssertEqual(probe.sessionEvents, 0)
    }
}
