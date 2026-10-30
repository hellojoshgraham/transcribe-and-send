import AppKit
import CoreGraphics
import TSCore

/// Runs only after the user's explicit screenshot gesture. Never watches the clipboard.
@MainActor
public final class ScreenshotCapture {
    public static var hasPermission: Bool { CGPreflightScreenCaptureAccess() }
    public static func requestPermission() {
        _ = CGRequestScreenCaptureAccess()
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") { NSWorkspace.shared.open(url) }
    }

    private var process: Process?
    private var cancellationRequested = false
    private var active = false
    private var timeout: Task<Void, Never>?
    private let permission: () -> Bool
    private let runCapture: ((URL) async throws -> Int32)?

    public convenience init() { self.init(permission: { Self.hasPermission }, runCapture: nil) }
    init(permission: @escaping () -> Bool, runCapture: ((URL) async throws -> Int32)?) {
        self.permission = permission; self.runCapture = runCapture
    }

    // Fixed executable/arguments; neither file names nor commands come from the peer.
    static func arguments(destination: URL) -> [String] { ["-i", "-s", "-x", "-t", "png", destination.path] }

    public func capture() async throws -> ScreenshotPNG {
        try Task.checkCancellation()
        guard permission() else { throw TSError.message("Enable Screen Recording for T&S in Settings on the sending Mac, then try again.") }
        guard !active else { throw TSError.message("A screenshot is already being selected.") }
        active = true
        defer { active = false }
        cancellationRequested = false
        // Avoid Shift/Control changing the system selection tool while the chord is released.
        for _ in 0..<40 where !CGEventSource.flagsState(.combinedSessionState).intersection([.maskCommand, .maskShift, .maskControl, .maskAlternate]).isEmpty {
            try await Task.sleep(for: .milliseconds(50))
            guard !cancellationRequested else { throw CancellationError() }
        }
        guard CGEventSource.flagsState(.combinedSessionState).intersection([.maskCommand, .maskShift, .maskControl, .maskAlternate]).isEmpty else {
            throw TSError.message("Release the shortcut keys, then try the screenshot again.")
        }
        var template = Array(FileManager.default.temporaryDirectory.appendingPathComponent("ts-screenshot-XXXXXX").path.utf8CString)
        guard mkdtemp(&template) != nil else { throw TSError.message("Could not create private screenshot storage.") }
        let directory = URL(fileURLWithPath: String(cString: template), isDirectory: true)
        let destination = directory.appendingPathComponent("capture.png")
        defer {
            timeout?.cancel(); timeout = nil
            try? FileManager.default.removeItem(at: directory)
        }
        let result: Int32
        if let runCapture { result = try await runCapture(destination) }
        else { result = try await run(destination: destination) }
        try Task.checkCancellation()
        guard !cancellationRequested else { throw CancellationError() }
        // Escape produces no file. Never fall back to an older clipboard image.
        guard result == 0, FileManager.default.fileExists(atPath: destination.path) else { throw CancellationError() }
        let image = try await Task.detached(priority: .userInitiated) {
            let file = try FileHandle(forReadingFrom: destination)
            defer { try? file.close() }
            let bytes = try file.read(upToCount: WireCodec.maxImageBytes + 1) ?? Data()
            return try ScreenshotPNG.normalize(bytes)
        }.value
        try Task.checkCancellation()
        guard !cancellationRequested else { throw CancellationError() }
        return image
    }

    private func run(destination: URL) async throws -> Int32 {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
        process.arguments = Self.arguments(destination: destination)
        process.standardOutput = FileHandle.nullDevice; process.standardError = FileHandle.nullDevice
        self.process = process
        defer { self.process = nil }
        return try await withCheckedThrowingContinuation { continuation in
            process.terminationHandler = { process in continuation.resume(returning: process.terminationStatus) }
            do { try process.run() }
            catch { process.terminationHandler = nil; continuation.resume(throwing: error); return }
            timeout = Task { [weak self] in
                try? await Task.sleep(for: .seconds(120))
                guard !Task.isCancelled else { return }
                self?.cancel()
            }
        }
    }

    public func cancel() {
        cancellationRequested = true
        guard let process, process.isRunning else { return }
        process.terminate()
        // Bound cancellation even if the system capture UI ignores SIGTERM.
        let pid = process.processIdentifier
        Task {
            try? await Task.sleep(for: .seconds(1))
            if process.isRunning { kill(pid, SIGKILL) }
        }
    }
}
