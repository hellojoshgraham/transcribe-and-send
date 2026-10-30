import XCTest
import AppKit
import SwiftUI
import TSCore
@testable import TSMac

final class PasteDesktopTests: XCTestCase {
    @MainActor
    func testRealTargetedPasteAndOverlayDoNotStealFocus() async throws {
        guard let executable = ProcessInfo.processInfo.environment["TS_TEST_PASTE_TARGET"] else {
            throw XCTSkip("Set TS_TEST_PASTE_TARGET to the compiled isolated fixture to enable desktop paste validation.")
        }
        guard AutomaticPaste.hasPermission else { throw XCTSkip("Requires existing Accessibility permission; tests do not request it.") }
        _ = NSApplication.shared
        let previous = NSWorkspace.shared.frontmostApplication
        let output = FileManager.default.temporaryDirectory.appendingPathComponent("ts-paste-test-\(UUID()).json")
        let board = NSPasteboard(name: .init("ts-paste-test-\(UUID())"))
        let text = "T&S test 🐶\nSecond line"
        board.clearContents(); XCTAssertTrue(board.setString(text, forType: .string))
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.environment = ProcessInfo.processInfo.environment.merging(["TS_TEST_BOARD": board.name.rawValue, "TS_TEST_OUTPUT": output.path]) { _, new in new }
        process.standardOutput = FileHandle.nullDevice; process.standardError = FileHandle.nullDevice
        let overlay = ReceiverOverlay()
        defer {
            overlay.hide()
            if process.isRunning { process.terminate() }
            previous?.activate(options: [])
            board.releaseGlobally()
            if FileManager.default.fileExists(atPath: output.path) { try? FileManager.default.removeItem(at: output) }
        }
        try process.run()
        var snapshot: FocusSnapshot?
        for _ in 0..<40 {
            if NSWorkspace.shared.frontmostApplication?.processIdentifier == process.processIdentifier {
                snapshot = FocusSnapshot.capture(requireTextField: true)
                if snapshot != nil { break }
            }
            try await Task.sleep(for: .milliseconds(100))
        }
        let target = try XCTUnwrap(snapshot, "Fixture text field must be accessible and focused")
        let service = AutomaticPaste(permission: { AutomaticPaste.hasPermission }, capture: { target },
                                     protectedInput: { false }, modifiersHeld: { false },
                                     clipboardMatches: { value, revision in board.string(forType: .string) == value && board.changeCount == revision },
                                     post: AutomaticPaste.postPaste)
        service.isAllowed = { true }
        let attempt = service.prepare()
        overlay.show(.preview)
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertTrue(target.stillFocused(), "Status preview must not take focus")
        overlay.show(.waiting)
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertTrue(target.stillFocused(), "Waiting panel must not take focus")
        overlay.show(.ready)
        let outcome = await attempt(text, board.changeCount) { true }
        XCTAssertEqual(outcome, .requested)
        overlay.show(.finished(outcome))
        for _ in 0..<30 where !FileManager.default.fileExists(atPath: output.path) { try await Task.sleep(for: .milliseconds(100)) }
        let result = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: output)) as? [String: Any])
        XCTAssertEqual(result["text"] as? String, text)
        XCTAssertEqual(result["returns"] as? Int, 0)
        XCTAssertTrue(target.stillFocused(), "Completion panel must not take focus")

        // Render only the product panel, never a screenshot of user content.
        if let directory = ProcessInfo.processInfo.environment["TS_TEST_PREVIEW_DIR"] {
            try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
            for (name, state) in [("preview", ReceiverProgress.preview), ("waiting", .waiting), ("ready", .ready), ("paste", .finished(.requested)), ("manual", .finished(.focusChanged)), ("screenshot-sending", .receivingImage), ("screenshot-ready", .imageReady(width: 1600, height: 900))] {
                for (appearance, scheme) in [("dark", ColorScheme.dark), ("light", .light)] {
                    let view = NSHostingView(rootView: ReceiverStatusView(progress: state).environment(\.colorScheme, scheme))
                    view.appearance = NSAppearance(named: scheme == .dark ? .darkAqua : .aqua)
                    view.frame = NSRect(x: 0, y: 0, width: 330, height: 126)
                    view.layoutSubtreeIfNeeded()
                    let bitmap = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
                    view.cacheDisplay(in: view.bounds, to: bitmap)
                    let png = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
                    try png.write(to: URL(fileURLWithPath: directory).appendingPathComponent("\(name)-\(appearance).png"))
                }
            }
        }
    }
}
