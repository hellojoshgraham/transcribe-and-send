import Foundation
import TSCore

/// Only a folder explicitly chosen in the open panel may be read. A failed read
/// revokes the saved grant, so another shortcut (or relaunch) cannot retry it.
@MainActor
final class RecordingFolderAccess {
    private struct Grant: Codable {
        let path: String
        let bookmark: Data
    }

    private static let defaultsKey = "superwhisperFolderGrant"
    private let defaults: UserDefaults
    private var grant: Grant?
    private var scopedURL: URL?

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        grant = defaults.data(forKey: Self.defaultsKey).flatMap { try? JSONDecoder().decode(Grant.self, from: $0) }
        // Do not resolve bookmarks or touch the protected folder at launch.
    }

    deinit { scopedURL?.stopAccessingSecurityScopedResource() }

    func isSelected(folder: String) -> Bool { grant?.path == Self.path(folder) }

    func select(_ url: URL) throws {
        invalidate()
        let panelScope = url.startAccessingSecurityScopedResource()
        defer { if panelScope { url.stopAccessingSecurityScopedResource() } }
        do {
            let bookmark = try url.bookmarkData(options: [.withSecurityScope, .securityScopeAllowOnlyReadAccess], includingResourceValuesForKeys: nil, relativeTo: nil)
            let selection = Grant(path: Self.path(url.path), bookmark: bookmark)
            grant = selection
            try withAccess(folder: url.path) { root in
                try RecordingFiles.validate(root: root)
            }
            defaults.set(try JSONEncoder().encode(selection), forKey: Self.defaultsKey)
        } catch {
            invalidate()
            throw error
        }
    }

    func withAccess<T>(folder: String, _ operation: (URL) throws -> T) throws -> T {
        guard let grant, isSelected(folder: folder) else {
            throw TSError.message("Choose your Superwhisper folder in T&S Settings before recording. Folder access is granted only through Choose folder…")
        }
        do {
            if scopedURL == nil {
                var stale = false
                let url = try URL(resolvingBookmarkData: grant.bookmark, options: [.withSecurityScope, .withoutUI, .withoutMounting], relativeTo: nil, bookmarkDataIsStale: &stale)
                guard !stale, url.startAccessingSecurityScopedResource() else {
                    throw TSError.message("The saved folder permission needs to be renewed.")
                }
                scopedURL = url
            }
            guard let scopedURL else { throw TSError.message("The selected folder is unavailable.") }
            return try operation(scopedURL)
        } catch {
            invalidate()
            throw TSError.message("Superwhisper folder access stopped. Nothing was sent. Choose the active Superwhisper folder again in T&S Settings. \(error.localizedDescription)")
        }
    }

    private func invalidate() {
        scopedURL?.stopAccessingSecurityScopedResource()
        scopedURL = nil
        grant = nil
        defaults.removeObject(forKey: Self.defaultsKey)
    }

    private static func path(_ folder: String) -> String {
        URL(fileURLWithPath: (folder as NSString).expandingTildeInPath, isDirectory: true).standardizedFileURL.path
    }
}

struct RecordingFiles {
    static let metadataLimit = 8 * 1024 * 1024

    static func validate(root: URL) throws {
        let settings = root.appendingPathComponent("settings/settings.json")
        guard try settings.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true else {
            throw TSError.message("Select the folder containing recordings, modes, and settings/settings.json.")
        }
        _ = try recordingIDs(root: root)
    }

    static func recordingIDs(root: URL) throws -> Set<String> {
        let directory = root.appendingPathComponent("recordings", isDirectory: true)
        let entries = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])
        // Attribute failures must propagate too; denial is not an empty folder.
        return Set(try entries.filter { try $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory == true }.map(\.lastPathComponent))
    }

    static func metadata(at url: URL, read: (URL, Int) throws -> Data = readBounded) throws -> Data {
        do {
            let data = try read(url, metadataLimit + 1)
            guard data.count <= metadataLimit else { throw TSError.message("Superwhisper’s recording metadata is too large to read safely.") }
            return data
        } catch {
            // A recording folder can appear before meta.json is written. Only
            // that missing-file case is retryable; permission/I/O errors stop.
            if isMissingFile(error) { return Data() }
            throw error
        }
    }

    private static func readBounded(_ url: URL, _ limit: Int) throws -> Data {
        let file = try FileHandle(forReadingFrom: url)
        defer { try? file.close() }
        return try file.read(upToCount: limit) ?? Data()
    }

    private static func isMissingFile(_ error: Error) -> Bool {
        let error = error as NSError
        // Prefer the underlying system error: a wrapper must not turn EACCES
        // into a retryable "missing" result.
        if let underlying = error.userInfo[NSUnderlyingErrorKey] as? NSError {
            return isMissingFile(underlying)
        }
        if error.domain == NSPOSIXErrorDomain { return error.code == Int(ENOENT) }
        return error.domain == NSCocoaErrorDomain && [NSFileReadNoSuchFileError, NSFileNoSuchFileError].contains(error.code)
    }
}
