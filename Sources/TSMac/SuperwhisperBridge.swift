import AppKit
import TSCore

@MainActor
public final class SuperwhisperBridge {
    public static let bundleID = "com.superduper.superwhisper"
    private var gate: TranscriptGate?
    private var baseline: Set<String> = []
    private var folder: String?
    private let folderAccess = RecordingFolderAccess()

    public init() {}

    public static func suggestedFolder() -> String {
        if let parent = UserDefaults(suiteName: bundleID)?.string(forKey: "appFolderDirectory") {
            return URL(fileURLWithPath: parent).appendingPathComponent("superwhisper").path
        }
        return FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("superwhisper").path
    }

    public func hasSelectedFolder(_ folder: String) -> Bool { folderAccess.isSelected(folder: folder) }
    public func selectFolder(_ url: URL) throws { try folderAccess.select(url) }

    public func prepare(folder: String) throws {
        guard let appURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: Self.bundleID),
              let version = Bundle(url: appURL)?.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String,
              version.compare("2.16.3", options: .numeric) != .orderedAscending else {
            throw TSError.message("Install Superwhisper 2.16.3 or newer on this Mac, open it, and finish its microphone setup.")
        }
        guard !NSRunningApplication.runningApplications(withBundleIdentifier: Self.bundleID).isEmpty else {
            throw TSError.message("Open Superwhisper first, then hold your T&S shortcut again.")
        }
        baseline = try folderAccess.withAccess(folder: folder) { root in
            try RecordingFiles.recordingIDs(root: root)
        }
        self.folder = folder
        gate = TranscriptGate(baseline: baseline, clipboardCount: NSPasteboard.general.changeCount)
    }

    public func start() async throws { try await Self.open("superwhisper://record/start") }
    public func stop() async throws { try await Self.open("superwhisper://record/stop") }

    public func result() throws -> TranscriptMetadata? {
        guard let folder, gate != nil else { throw TSError.message("No dictation is active.") }
        let ids = try folderAccess.withAccess(folder: folder) { root in
            try RecordingFiles.recordingIDs(root: root).subtracting(baseline)
        }
        guard ids.count <= 1 else { throw TSError.message("More than one new Superwhisper recording appeared. Nothing was sent; try again without another recording running.") }
        var recordings: [String: Data] = [:]
        for id in ids {
            recordings[id] = try folderAccess.withAccess(folder: folder) { root in
                try RecordingFiles.metadata(at: root.appendingPathComponent("recordings").appendingPathComponent(id).appendingPathComponent("meta.json"))
            }
        }
        return try gate?.evaluate(recordings: recordings, clipboardText: NSPasteboard.general.string(forType: .string), clipboardCount: NSPasteboard.general.changeCount)
    }

    public func reset() { folder = nil; baseline = []; gate = nil }

    public static func open(_ address: String) async throws {
        guard let url = URL(string: address), let appURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else {
            throw TSError.message("Superwhisper is not installed.")
        }
        let config = NSWorkspace.OpenConfiguration()
        config.activates = false
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            NSWorkspace.shared.open([url], withApplicationAt: appURL, configuration: config) { _, error in
                if let error { continuation.resume(throwing: error) } else { continuation.resume() }
            }
        }
    }
}
