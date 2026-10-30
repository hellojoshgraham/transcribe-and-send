import XCTest
import TSCore
@testable import TSMac

final class ScreenshotCaptureTests: XCTestCase {
    @MainActor func testDeniedPermissionNeverLaunchesCapture() async {
        let capture = ScreenshotCapture(permission: { false }, runCapture: { _ in XCTFail("No process should be launched"); return 0 })
        do { _ = try await capture.capture(); XCTFail("Permission is required") } catch { XCTAssertTrue(error.localizedDescription.contains("Screen Recording")) }
    }

    @MainActor func testSuccessfulCaptureUsesPrivateTemporaryFileAndRemovesIt() async throws {
        let original = try ScreenshotFixtures.png(description: "discarded metadata")
        var directory: URL?
        let capture = ScreenshotCapture(permission: { true }, runCapture: { destination in
            directory = destination.deletingLastPathComponent()
            let attributes = try FileManager.default.attributesOfItem(atPath: directory!.path)
            XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o700)
            XCTAssertEqual(ScreenshotCapture.arguments(destination: destination), ["-i", "-s", "-x", "-t", "png", destination.path])
            try original.write(to: destination)
            return 0
        })
        let image = try await capture.capture()
        XCTAssertEqual(image.width, 64); XCTAssertEqual(image.height, 32)
        XCTAssertFalse(FileManager.default.fileExists(atPath: try XCTUnwrap(directory).path))
    }

    @MainActor func testEscapeOrMissingOutputNeverReusesClipboardAndAlwaysCleansUp() async throws {
        for status: Int32 in [0, 1] {
            var directory: URL?
            let capture = ScreenshotCapture(permission: { true }, runCapture: { destination in directory = destination.deletingLastPathComponent(); return status })
            do { _ = try await capture.capture(); XCTFail("No new file means no screenshot") } catch is CancellationError { } catch { XCTFail("Unexpected \(error)") }
            XCTAssertFalse(FileManager.default.fileExists(atPath: try XCTUnwrap(directory).path))
        }
    }

    @MainActor func testExplicitCancellationDiscardsEvenCompletedCaptureAndCleansUp() async throws {
        var directory: URL?
        var capture: ScreenshotCapture!
        capture = ScreenshotCapture(permission: { true }, runCapture: { destination in
            directory = destination.deletingLastPathComponent()
            try ScreenshotFixtures.png().write(to: destination)
            capture.cancel()
            return 0
        })
        do { _ = try await capture.capture(); XCTFail("Cancelled pixels must not be sent") } catch is CancellationError { } catch { XCTFail("Unexpected \(error)") }
        XCTAssertFalse(FileManager.default.fileExists(atPath: try XCTUnwrap(directory).path))
    }

    @MainActor func testMalformedCaptureIsNotReturnedAndTemporaryFileIsRemoved() async throws {
        var directory: URL?
        let capture = ScreenshotCapture(permission: { true }, runCapture: { destination in
            directory = destination.deletingLastPathComponent()
            try Data("invalid".utf8).write(to: destination)
            return 0
        })
        do { _ = try await capture.capture(); XCTFail("Invalid pixels must fail") } catch { }
        XCTAssertFalse(FileManager.default.fileExists(atPath: try XCTUnwrap(directory).path))
    }
}
