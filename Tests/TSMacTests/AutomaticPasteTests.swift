import XCTest
import TSCore
@testable import TSMac

final class AutomaticPasteTests: XCTestCase {
    @MainActor
    private final class Environment {
        var allowed = true, permission = true, focused = true, protected = false, modifiers = false, active = true
        var text = "Current dictation", revision = 12
        var captures = 0, posts: [pid_t] = []
        lazy var service: AutomaticPaste = {
            let service = AutomaticPaste(permission: { self.permission }, capture: {
                self.captures += 1
                return FocusSnapshot(processID: 12345, matches: { self.focused })
            }, protectedInput: { self.protected }, modifiersHeld: { self.modifiers }, clipboardMatches: { text, revision in
                self.text == text && self.revision == revision
            }, post: { pid in self.posts.append(pid); return true })
            service.isAllowed = { self.allowed }
            return service
        }()
    }

    @MainActor func testPasteUsesCapturedProcessOnlyAfterAllChecks() async {
        let env = Environment()
        let prepared = env.service.prepare()
        XCTAssertEqual(env.captures, 1); XCTAssertTrue(env.posts.isEmpty)
        let result = await prepared(env.text, 12) { env.active }
        XCTAssertEqual(result, .requested); XCTAssertEqual(env.posts, [12345])
    }

    @MainActor func testMissingConsentPermissionAndProtectedInputNeverCaptureFocusOrPost() async {
        for expected in [PasteOutcome.disabled, .permissionNeeded, .protectedInput] {
            let env = Environment()
            env.allowed = expected != .disabled
            env.permission = expected != .permissionNeeded
            env.protected = expected == .protectedInput
            let attempt = env.service.prepare()
            let result = await attempt(env.text, 12) { true }
            XCTAssertEqual(result, expected); XCTAssertEqual(env.captures, 0); XCTAssertTrue(env.posts.isEmpty)
        }
    }

    @MainActor func testFocusClipboardPermissionAndConsentAreRecheckedBeforePaste() async {
        for expected in [PasteOutcome.focusChanged, .clipboardChanged, .permissionNeeded, .disabled, .protectedInput, .cancelled] {
            let env = Environment()
            let attempt = env.service.prepare()
            switch expected {
            case .focusChanged: env.focused = false
            case .clipboardChanged: env.revision += 1
            case .permissionNeeded: env.permission = false
            case .disabled: env.allowed = false
            case .protectedInput: env.protected = true
            case .cancelled: env.active = false
            default: break
            }
            let result = await attempt(env.text, 12) { env.active }
            XCTAssertEqual(result, expected); XCTAssertTrue(env.posts.isEmpty)
        }
    }

    @MainActor func testReleaseOfStopShortcutModifiersIsAwaited() async throws {
        let env = Environment(); env.modifiers = true
        let attempt = env.service.prepare()
        let release = Task { try await Task.sleep(for: .milliseconds(70)); env.modifiers = false }
        let result = await attempt(env.text, 12) { env.active }
        try await release.value
        XCTAssertEqual(result, .requested); XCTAssertEqual(env.posts.count, 1)
    }

    @MainActor func testCancelWhileWaitingForModifiersNeverPosts() async throws {
        let env = Environment(); env.modifiers = true
        let attempt = env.service.prepare()
        let cancel = Task { try await Task.sleep(for: .milliseconds(70)); env.active = false }
        let result = await attempt(env.text, 12) { env.active }
        try await cancel.value
        XCTAssertEqual(result, .cancelled); XCTAssertTrue(env.posts.isEmpty)
    }

    @MainActor func testHeldModifiersTimeOutWithoutPaste() async {
        let env = Environment(); env.modifiers = true
        let result = await env.service.prepare()(env.text, 12) { true }
        XCTAssertEqual(result, .modifiersHeld); XCTAssertTrue(env.posts.isEmpty)
    }
}
