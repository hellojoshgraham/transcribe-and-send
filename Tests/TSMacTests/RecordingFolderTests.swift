import XCTest
@testable import TSMac

final class RecordingFolderTests: XCTestCase {
    private func fixture() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("ts-folder-tests-\(UUID())", isDirectory: true)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("settings"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("recordings"), withIntermediateDirectories: true)
        try Data("{}".utf8).write(to: root.appendingPathComponent("settings/settings.json"))
        return root
    }

    @MainActor
    func testNoSelectionNeverAttemptsAReadIncludingAfterRelaunch() throws {
        let suite = "ts-folder-tests-\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let access = RecordingFolderAccess(defaults: defaults)
        var reads = 0
        for _ in 0..<10 {
            XCTAssertThrowsError(try access.withAccess(folder: "/does-not-need-to-exist") { _ in reads += 1 })
        }
        let relaunched = RecordingFolderAccess(defaults: defaults)
        XCTAssertThrowsError(try relaunched.withAccess(folder: "/does-not-need-to-exist") { _ in reads += 1 })
        XCTAssertEqual(reads, 0)
    }

    @MainActor
    func testSelectionRestoresReadAccessAndEnumeratesOnlyRecordingDirectories() throws {
        let root = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root.appendingPathComponent("recordings/new-recording"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("recordings/.hidden"), withIntermediateDirectories: true)
        try Data().write(to: root.appendingPathComponent("recordings/ignore-file"))
        let suite = "ts-folder-tests-\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        try RecordingFolderAccess(defaults: defaults).select(root)
        let restored = RecordingFolderAccess(defaults: defaults)
        XCTAssertTrue(restored.isSelected(folder: root.path))
        let ids = try restored.withAccess(folder: root.path) { try RecordingFiles.recordingIDs(root: $0) }
        XCTAssertEqual(ids, ["new-recording"])
    }

    @MainActor
    func testDeniedReadStopsRetriesPersistsAcrossRelaunchAndRequiresExplicitSelection() throws {
        let root = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let suite = "ts-folder-tests-\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let access = RecordingFolderAccess(defaults: defaults)
        try access.select(root)
        var reads = 0
        for _ in 0..<10 {
            XCTAssertThrowsError(try access.withAccess(folder: root.path) { url in
                try RecordingFiles.metadata(at: url.appendingPathComponent("meta.json")) { _, _ in
                    reads += 1
                    throw NSError(domain: NSPOSIXErrorDomain, code: Int(EACCES))
                }
            })
        }
        XCTAssertEqual(reads, 1, "An access failure must never be polled again")
        XCTAssertFalse(access.isSelected(folder: root.path))
        let relaunched = RecordingFolderAccess(defaults: defaults)
        XCTAssertThrowsError(try relaunched.withAccess(folder: root.path) { _ in reads += 1 })
        XCTAssertEqual(reads, 1)
        try relaunched.select(root)
        try relaunched.withAccess(folder: root.path) { _ in reads += 1 }
        XCTAssertEqual(reads, 2, "Only an explicit selection restores access")
    }

    @MainActor
    func testChangedPathCannotReuseAnotherFoldersGrant() throws {
        let root = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let suite = "ts-folder-tests-\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let access = RecordingFolderAccess(defaults: defaults)
        try access.select(root)
        var reads = 0
        XCTAssertThrowsError(try access.withAccess(folder: root.appendingPathComponent("other").path) { _ in reads += 1 })
        XCTAssertEqual(reads, 0)
    }

    @MainActor
    func testUnreadableSavedBookmarkNeverAttemptsAReadAndIsCleared() throws {
        let suite = "ts-folder-tests-\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let saved: [String: String] = ["path": "/tmp/ts-invalid-bookmark", "bookmark": Data("broken".utf8).base64EncodedString()]
        defaults.set(try JSONSerialization.data(withJSONObject: saved), forKey: "superwhisperFolderGrant")
        let access = RecordingFolderAccess(defaults: defaults)
        var reads = 0
        XCTAssertThrowsError(try access.withAccess(folder: "/tmp/ts-invalid-bookmark") { _ in reads += 1 })
        XCTAssertEqual(reads, 0)
        XCTAssertNil(defaults.data(forKey: "superwhisperFolderGrant"))
    }

    @MainActor
    func testInvalidSelectionDoesNotLeaveAGrant() throws {
        let root = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.removeItem(at: root.appendingPathComponent("settings/settings.json"))
        let suite = "ts-folder-tests-\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let access = RecordingFolderAccess(defaults: defaults)
        XCTAssertThrowsError(try access.select(root))
        XCTAssertFalse(access.isSelected(folder: root.path))
    }

    @MainActor
    func testDirectoryFailureIsNotAnEmptyBaselineAndBlocksFurtherReads() throws {
        let root = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let suite = "ts-folder-tests-\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let access = RecordingFolderAccess(defaults: defaults)
        try access.select(root)
        try FileManager.default.removeItem(at: root.appendingPathComponent("recordings"))
        XCTAssertThrowsError(try access.withAccess(folder: root.path) { try RecordingFiles.recordingIDs(root: $0) })
        XCTAssertFalse(access.isSelected(folder: root.path))
        XCTAssertThrowsError(try access.withAccess(folder: root.path) { _ in XCTFail("No more reads after failure") })
    }

    func testMissingAndPartiallyWrittenMetadataRemainRetryable() throws {
        let root = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("recordings/meta.json")
        XCTAssertEqual(try RecordingFiles.metadata(at: url), Data())
        let partial = Data("{\"result\":".utf8)
        try partial.write(to: url)
        XCTAssertEqual(try RecordingFiles.metadata(at: url), partial)
        let complete = Data("{\"result\":\"Finished\"}".utf8)
        try complete.write(to: url)
        XCTAssertEqual(try RecordingFiles.metadata(at: url), complete)
    }

    func testPermissionAndUnknownErrorsAreNeverConvertedIntoPendingMetadata() {
        let denied = NSError(domain: NSPOSIXErrorDomain, code: Int(EACCES))
        let errors = [
            denied,
            NSError(domain: NSPOSIXErrorDomain, code: Int(EPERM)),
            NSError(domain: NSCocoaErrorDomain, code: NSFileReadNoPermissionError),
            NSError(domain: NSCocoaErrorDomain, code: NSFileReadNoSuchFileError, userInfo: [NSUnderlyingErrorKey: denied]),
            NSError(domain: NSPOSIXErrorDomain, code: Int(EIO))
        ]
        for error in errors {
            var attempts = 0
            XCTAssertThrowsError(try RecordingFiles.metadata(at: URL(fileURLWithPath: "/unused")) { _, _ in
                attempts += 1
                throw error
            })
            XCTAssertEqual(attempts, 1)
        }
    }

    func testBoundedReadRejectsOversizedMetadata() throws {
        let root = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("recordings/meta.json")
        try Data(repeating: 0, count: RecordingFiles.metadataLimit + 1).write(to: url)
        XCTAssertThrowsError(try RecordingFiles.metadata(at: url))
        XCTAssertThrowsError(try RecordingFiles.metadata(at: url) { _, limit in
            XCTAssertEqual(limit, RecordingFiles.metadataLimit + 1)
            return Data(repeating: 0, count: limit)
        })
    }
}
