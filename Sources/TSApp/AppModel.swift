import AppKit
import SwiftUI
import ServiceManagement
import TSCore
import TSMac

struct Preferences: Codable {
    enum Role: String, Codable, CaseIterable { case send = "Send from this Mac", receive = "Receive on this Mac" }
    var role: Role = .send
    var targetIP = ""
    var localIP = ""
    var senderIP = ""
    var port = "53198"
    var superwhisperFolder = ""
    var shortcut: Shortcut = .optionSpace
    var modeShortcut: ModeShortcut?
    var switchShortcut: ModeShortcut {
        get { modeShortcut ?? .standard }
        set { modeShortcut = newValue }
    }
    var pairedIP: String {
        get { targetIP == senderIP || senderIP.isEmpty ? targetIP : targetIP.isEmpty ? senderIP : "" }
        set { targetIP = newValue; senderIP = newValue }
    }
    var hasDifferentLegacyPeers: Bool { !targetIP.isEmpty && !senderIP.isEmpty && targetIP != senderIP }
    mutating func migratePairing() {
        if targetIP.isEmpty { targetIP = senderIP }
        if senderIP.isEmpty { senderIP = targetIP }
    }
    var superwhisperConfigured = false
    var resumeReceiver = false
    // Optional envelope preserves decoding of every pre-0.2 saved preference.
    var workflow: WorkflowOptions?
    var copyScreenshots: Bool?
    var copiesScreenshots: Bool {
        get { copyScreenshots ?? false }
        set { copyScreenshots = newValue }
    }
    var workflowOptions: WorkflowOptions {
        get { workflow ?? WorkflowOptions() }
        set { workflow = newValue }
    }
}

@MainActor
final class AppModel: ObservableObject {
    enum Phase { case idle, starting, recording, capturing, transcribing, sending, cancelling, sent, failed, receiving }
    @Published var preferences: Preferences
    @Published private(set) var activeRole: Preferences.Role
    @Published private(set) var modeIndicatorVisible = false
    @Published var phase: Phase = .idle
    @Published var detail = "Set up your two Macs to get started."
    @Published var lastDelivery: Date?
    @Published var lastInput = ""
    @Published var retainedText: String?
    @Published var retainedScreenshot: ScreenshotPNG?
    @Published var keyFingerprint = "No pairing key saved"
    @Published var receiverRunning = false
    @Published var loginEnabled = SMAppService.mainApp.status == .enabled
    @Published var preferencesSaved = false
    @Published var shortcutCapture: HotKey.CaptureState = .off
    @Published private(set) var lastShortcutReceived: Date?
    @Published private(set) var shortcutForegroundApp = ""
    @Published private(set) var choosingFolder = false
    @Published private(set) var pastePermissionStatus = AutomaticPaste.permissionStatus
    var pastePermission: Bool { pastePermissionStatus == .available }
    @Published private(set) var screenshotPermission = ScreenshotCapture.hasPermission
    var showSettings: (() -> Void)?
    private var appliedPreferences: Preferences
    private let hotKey = HotKey()
    private let bridge = SuperwhisperBridge()
    private let client = ClipboardClient()
    private let automaticPaste = AutomaticPaste()
    private let overlay = ReceiverOverlay()
    private let screenshotCapture = ScreenshotCapture()
    private var screenshotArmed = false
    private var senderFocus: FocusSnapshot?
    private var automaticPasteIssue: String?
    private lazy var receiver = ClipboardReceiver(writeClipboard: Clipboard.write)
    private var task: Task<Void, Never>?
    private var watchdog: Task<Void, Never>?
    private var modeIndicatorTask: Task<Void, Never>?
    private var key: PairingKey?
    private var releasePending = false
    private var observers: [NSObjectProtocol] = []

    /// Native previews have no network, keyboard listener, preferences or Keychain side effects.
    init(preview: Preferences) {
        preferences = preview; appliedPreferences = preview; activeRole = preview.role
        detail = "Pair your Macs to get started."
    }

    init() {
        let data = UserDefaults.standard.data(forKey: "preferences")
        var loaded = data.flatMap { try? JSONDecoder().decode(Preferences.self, from: $0) } ?? Preferences()
        if data == nil { loaded.workflowOptions.recordingMode = .toggle }
        loaded.migratePairing()
        if loaded.localIP.isEmpty, LocalNetwork.tailscaleAddresses().count == 1 { loaded.localIP = LocalNetwork.tailscaleAddresses()[0] }
        appliedPreferences = loaded
        preferences = loaded
        activeRole = loaded.role
        if preferences.superwhisperFolder.isEmpty { preferences.superwhisperFolder = SuperwhisperBridge.suggestedFolder() }
        do { key = try KeyStore.read(); keyFingerprint = key?.fingerprint ?? "No pairing key saved" }
        catch { detail = error.localizedDescription; phase = .failed }
        hotKey.pressed = { [weak self] in
            guard let self else { return }
            self.lastShortcutReceived = Date()
            self.shortcutForegroundApp = NSWorkspace.shared.frontmostApplication?.localizedName ?? "Unknown app"
            self.handleShortcut(.pressed)
        }
        hotKey.switchMode = { [weak self] in self?.switchModeFromShortcut() }
        hotKey.released = { [weak self] in self?.handleShortcut(.released) }
        hotKey.interrupted = { [weak self] in self?.handleShortcut(.interrupted) }
        hotKey.screenshotPressed = { [weak self] in
            guard let self else { return }
            self.screenshotArmed = self.activeRole == .send && self.appliedPreferences.copiesScreenshots && !self.busy
        }
        hotKey.screenshotReleased = { [weak self] in
            guard let self, self.screenshotArmed else { return }
            self.screenshotArmed = false; self.takeScreenshot()
        }
        hotKey.screenshotInterrupted = { [weak self] in self?.screenshotArmed = false }
        hotKey.captureChanged = { [weak self] state in
            guard let self else { return }
            self.shortcutCapture = state
            if [.off, .needsAccessibility, .unavailable, .secureInput].contains(state) {
                self.handleShortcut(.interrupted); self.screenshotArmed = false
                if self.phase == .capturing { self.cancel() }
            }
        }
        automaticPaste.isAllowed = { [weak self] in
            self?.activeRole == .receive && self?.appliedPreferences.workflowOptions.allowAutomaticPaste == true && self?.receiverRunning == true
        }
        receiver.preparePaste = { [weak self] in self?.automaticPaste.prepare() ?? { _, _, _ in .cancelled } }
        receiver.onProgress = { [weak self] progress in self?.receiveProgress(progress) }
        receiver.onActivityChanged = { [weak self] in self?.objectWillChange.send() }
        receiver.onState = { [weak self] message, ready in
            self?.receiverRunning = ready; self?.detail = message; self?.phase = ready ? .receiving : .failed
        }
        receiver.onReceived = { [weak self] in
            self?.lastDelivery = Date(); self?.phase = .sent; self?.detail = "Received. Ready to paste on this Mac."
            if self?.preferences.workflowOptions.showReceiverStatus == true { self?.overlay.show(.ready) }
        }
        do { try applyRole() } catch { fail(error) }
        if activeRole == .receive && preferences.resumeReceiver { startReceiver() }
        let center = NSWorkspace.shared.notificationCenter
        observers.append(center.addObserver(forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor [weak self] in self?.refreshPastePermission() }
        })
        observers.append(center.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.cancel(); self?.hotKey.unregister(); self?.stopReceiver(persist: false)
            }
        })
        observers.append(center.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                do { try self.applyRole(self.activeRole, settings: self.appliedPreferences) } catch { self.fail(error) }
                if self.activeRole == .send { return }
                guard self.preferences.resumeReceiver else { return }
                // Give Tailscale a chance to reconnect. Binding is revalidated and fails closed if unavailable.
                try? await Task.sleep(for: .seconds(3)); self.startReceiver()
            }
        })
    }

    var busy: Bool { choosingFolder || receiver.deliveryInProgress || [.starting, .recording, .capturing, .transcribing, .sending, .cancelling].contains(phase) }
    var recordingMode: RecordingMode { appliedPreferences.workflowOptions.recordingMode }
    var activeSwitchShortcut: String { appliedPreferences.switchShortcut.label }
    var hasPairingKey: Bool { key != nil }
    func handleShortcut(_ event: ShortcutGesture.Action) {
        let state: RecordingControl.State = phase == .starting ? .starting : phase == .recording ? .recording : busy ? .busy : .idle
        switch RecordingControl.action(for: event, mode: recordingMode, state: state) {
        case .start: beginRecording()
        case .stop: endRecording()
        case .cancel: cancel()
        case nil: break
        }
    }
    func enableAutomaticPaste() { AutomaticPaste.requestPermission(); refreshPastePermission() }
    func refreshPastePermission() { pastePermissionStatus = AutomaticPaste.permissionStatus; screenshotPermission = ScreenshotCapture.hasPermission }
    func previewDeliveryStatus() { overlay.show(.preview) }
    func enableScreenshotPermission() { ScreenshotCapture.requestPermission(); refreshPastePermission() }
    private func receiveProgress(_ progress: ReceiverProgress) {
        guard activeRole == .receive else { return }
        if preferences.workflowOptions.showReceiverStatus { overlay.show(progress) }
        switch progress {
        case .preview: break
        case .waiting: phase = .transcribing; detail = "Waiting for transcription on the sending Mac."
        case .ready: phase = .sent; detail = "Clipboard ready."
        case .pasting: phase = .sending; detail = "Requesting Paste in the selected text field."
        case .finished(let result): phase = result == .clipboardChanged ? .failed : .sent; detail = result.message
        case .cancelled: phase = receiverRunning ? .receiving : .idle; detail = "Automatic delivery ended. No further paste will be requested."
        case .receivingImage: phase = .sending; detail = "Receiving a screenshot from the sending Mac."
        case .imageReady(let width, let height):
            phase = .sent; lastDelivery = Date(); detail = "Screenshot ready (\(width) × \(height)). Paste with Command–V."
        case .imageCancelled: phase = receiverRunning ? .receiving : .idle; detail = "Screenshot transfer ended without a confirmed clipboard write."
        }
    }
    var folderSelected: Bool { bridge.hasSelectedFolder(preferences.superwhisperFolder) }

    func chooseSuperwhisperFolder() {
        guard !busy else { return }
        choosingFolder = true
        defer { choosingFolder = false }
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true; panel.canChooseFiles = false; panel.allowsMultipleSelection = false
        panel.prompt = "Choose folder"
        panel.message = "Choose Superwhisper’s active folder (containing recordings, modes, and settings). T&S will remember read-only access to this folder."
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try bridge.selectFolder(url)
            preferences.superwhisperFolder = url.path
            appliedPreferences.superwhisperFolder = url.path
            persist()
            phase = .idle; detail = "Superwhisper folder selected. Ready to record."
        } catch { fail(error) }
    }
    var shortcutStatus: String {
        switch shortcutCapture {
        case .off: return "Local shortcut is off"
        case .needsAccessibility: return "Allow Accessibility on this Mac to keep the shortcut local while using Jump Desktop."
        case .local: return "Early keyboard listener ready"
        case .sessionFallback: return "Limited keyboard listener. Jump Desktop may receive the shortcut first."
        case .unavailable: return "Local capture could not start. Check Accessibility for this copy of T&S, then reopen it."
        case .secureInput: return "macOS Secure Keyboard Entry is active. Leave the protected input or turn off Secure Keyboard Entry in the app that enabled it."
        }
    }
    func enableLocalShortcut() { hotKey.requestAccessibility() }
    func retryLocalShortcut() { do { try hotKey.retryCapture() } catch { fail(error) } }
    var symbol: String {
        switch phase {
        case .starting, .recording: return "mic.fill"
        case .capturing: return "crop"
        case .transcribing: return "waveform"
        case .sending: return "arrow.up.circle"
        case .cancelling: return "stop.circle"
        case .sent: return "checkmark.circle.fill"
        case .failed: return "exclamationmark.circle.fill"
        case .receiving: return "arrow.down.circle"
        case .idle: return "waveform"
        }
    }
    var tint: Color { phase == .failed ? .orange : phase == .sent ? Color(red: 0.10, green: 0.48, blue: 0.39) : phase == .recording ? .red : .accentColor }
    var title: String {
        switch phase {
        case .idle: return "Ready when you are"
        case .starting: return "Opening microphone"
        case .recording: return "Recording in Superwhisper"
        case .capturing: return "Select your screenshot"
        case .transcribing: return "Transcribing"
        case .sending: return "Sending securely"
        case .cancelling: return "Stopping"
        case .sent: return activeRole == .receive ? "Clipboard ready" : "Sent to your Mac"
        case .failed: return "Needs attention"
        case .receiving: return "Ready to receive"
        }
    }

    @discardableResult func save(pairingKey: String = "") -> Bool {
        guard !busy else { return false }
        let previous = appliedPreferences
        do {
            try preferences.switchShortcut.validate(voice: preferences.shortcut, screenshots: preferences.copiesScreenshots)
            _ = try port()
            guard !preferences.hasDifferentLegacyPeers else { throw TSError.message("Choose one paired Mac. Your previous send and receive addresses differ; both are shown in Connection settings.") }
            for address in [preferences.pairedIP, preferences.localIP] where !address.isEmpty {
                guard TailAddress.isValid(address) else { throw TSError.message("Enter a Tailscale IPv4 address in the 100.64–100.127 range.") }
            }
            guard preferences.pairedIP.isEmpty || preferences.pairedIP != preferences.localIP else { throw TSError.message("Pair with the other Mac, not this Mac’s address.") }
            let newKey = pairingKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : try PairingKey(encoded: pairingKey)
            // Validate and install shortcuts before changing the saved key or receiver.
            try applyRole(activeRole, settings: preferences)
            if let newKey { try KeyStore.save(newKey); key = newKey; keyFingerprint = newKey.fingerprint }
            stopReceiver(persist: false)
            preferences.role = activeRole
            appliedPreferences = preferences
            persist(); preferencesSaved = true
            phase = .idle; detail = "Settings saved."
            if activeRole == .receive && preferences.resumeReceiver { startReceiver() }
            return true
        } catch {
            try? applyRole(activeRole, settings: previous)
            fail(error); return false
        }
    }

    private func switchModeFromShortcut() {
        let previousRole = activeRole
        switchMode()
        guard activeRole != previousRole else { return }
        modeIndicatorTask?.cancel()
        modeIndicatorVisible = true
        modeIndicatorTask = Task { [weak self] in
            do { try await Task.sleep(for: .milliseconds(500)) } catch { return }
            guard !Task.isCancelled else { return }
            self?.modeIndicatorVisible = false
        }
    }

    func switchMode() {
        guard !busy else { return }
        let previousRole = activeRole
        let next: Preferences.Role = activeRole == .send ? .receive : .send
        do {
            if next == .receive { _ = try receiverSettings(appliedPreferences) }
            try applyRole(next, settings: appliedPreferences)
            stopReceiver(persist: false)
            preferences.role = next; preferences.resumeReceiver = next == .receive
            appliedPreferences.role = next; appliedPreferences.resumeReceiver = next == .receive
            // A global shortcut must not save unrelated edits in an open Settings window.
            UserDefaults.standard.set(try JSONEncoder().encode(appliedPreferences), forKey: "preferences")
            phase = .idle
            if next == .receive { startReceiver() }
            else { detail = "TX selected. Set the other Mac to RX to send there." }
        } catch {
            try? applyRole(previousRole, settings: appliedPreferences)
            fail(error)
        }
    }

    func detectLocalAddress() {
        let addresses = localAddresses()
        if addresses.count == 1 { preferences.localIP = addresses[0] }
        else { fail(TSError.message(addresses.isEmpty ? "Connect Tailscale on this Mac first." : "More than one Tailscale address is available. Select this Mac’s address in Advanced connection settings.")) }
    }

    func pairingCode() -> String? {
        guard !busy else { return nil }
        do {
            if preferences.localIP.isEmpty { detectLocalAddress() }
            guard localAddresses().contains(preferences.localIP) else { throw TSError.message("Connect Tailscale and detect this Mac’s address before creating its pairing code.") }
            let number = try port()
            let shared = key ?? PairingKey()
            let code = try PairingCode(address: preferences.localIP, port: number, key: shared).encoded()
            if key == nil { try KeyStore.save(shared); key = shared; keyFingerprint = shared.fingerprint }
            return code
        } catch { fail(error); return nil }
    }

    func importPairingCode(_ code: PairingCode) -> Bool {
        guard !busy else { return false }
        guard !localAddresses().contains(code.address), code.address != preferences.localIP else {
            fail(TSError.message("That code belongs to this Mac. Paste the other Mac’s code.")); return false
        }
        let previous = preferences
        preferences.pairedIP = code.address; preferences.port = String(code.port)
        if preferences.localIP.isEmpty { detectLocalAddress() }
        if save(pairingKey: code.key.encoded) {
            detail = "Paired settings saved. Copy this Mac’s code back to the other Mac to finish both directions."
            return true
        }
        preferences = previous
        return false
    }

    func generateKey() -> String? {
        guard !busy else { return nil }
        do {
            stopReceiver()
            let newKey = PairingKey(); try KeyStore.save(newKey); key = newKey; keyFingerprint = newKey.fingerprint
            detail = "New pairing key saved. Exchange pairing codes again on both Macs."
            phase = .idle
            return newKey.encoded
        } catch { fail(error); return nil }
    }

    func localAddresses() -> [String] { LocalNetwork.tailscaleAddresses() }
    private func persist() {
        var saved = appliedPreferences
        saved.role = activeRole
        UserDefaults.standard.set(try? JSONEncoder().encode(saved), forKey: "preferences")
    }
    private func applyRole(_ requestedRole: Preferences.Role? = nil, settings: Preferences? = nil) throws {
        let config = settings ?? appliedPreferences
        let role = requestedRole ?? config.role
        try config.switchShortcut.validate(voice: config.shortcut, screenshots: config.copiesScreenshots)
        try hotKey.register(role == .send ? config.shortcut : nil,
                            copyScreenshots: role == .send && config.copiesScreenshots, modeSwitch: config.switchShortcut)
        activeRole = role
    }
    private func port() throws -> UInt16 {
        guard let value = UInt16(preferences.port), value > 0 else { throw TSError.message("Enter a port between 1 and 65535.") }; return value
    }
    private func senderSettings() throws -> (String, UInt16, PairingKey) {
        guard let key else { throw TSError.message("Save the receiving Mac’s pairing key in Settings first.") }
        guard TailAddress.isValid(appliedPreferences.targetIP) else { throw TSError.message("Enter the receiving Mac’s Tailscale IPv4 address in Settings.") }
        guard !LocalNetwork.tailscaleAddresses().isEmpty else {
            throw TSError.message("Connect Tailscale on this Mac, then try again. Jump Desktop can stay connected while Tailscale is off.")
        }
        guard let number = UInt16(appliedPreferences.port), number > 0 else { throw TSError.message("Save a valid connection port first.") }
        return (appliedPreferences.targetIP, number, key)
    }

    func beginRecording() {
        guard activeRole == .send, !busy else { return }
        // Claim the operation before any permission-sensitive work. A system
        // modal can run a nested event loop and deliver another hotkey event.
        releasePending = false; phase = .starting
        do {
            _ = try senderSettings()
            guard preferences.superwhisperConfigured else { throw TSError.message("Finish the Superwhisper checklist in T&S Settings before recording.") }
            try bridge.prepare(folder: preferences.superwhisperFolder)
            guard phase == .starting else { bridge.reset(); return }
            retainedText = nil; retainedScreenshot = nil; senderFocus = nil; automaticPasteIssue = nil
            detail = "Speak when Superwhisper shows its waveform."
            task = Task {
                do {
                    try await bridge.start()
                    guard !Task.isCancelled else { try? await bridge.stop(); return }
                    phase = .recording
                    detail = recordingMode == .hold ? "Release your shortcut to transcribe and send." : "Press your shortcut again to transcribe and send."
                    if releasePending { endRecording() }
                } catch { if !Task.isCancelled { bridge.reset(); fail(error) } }
            }
            watchdog?.cancel()
            watchdog = Task {
                try? await Task.sleep(for: .seconds(120))
                guard !Task.isCancelled, phase == .recording || phase == .starting else { return }
                cancel(); detail = "Recording stopped at the two-minute safety limit. Nothing was sent."
            }
        } catch { bridge.reset(); if phase == .starting { fail(error) } }
    }

    func endRecording() {
        if phase == .starting { releasePending = true; return }
        guard phase == .recording else { return }
        watchdog?.cancel(); phase = .transcribing; detail = "Waiting for the completed Superwhisper result."
        // Keep the sending Mac's current remote window stable too. The receiver
        // separately captures and checks its actual focused text field.
        if appliedPreferences.workflowOptions.automaticallyPaste { senderFocus = FocusSnapshot.capture(requireTextField: false) }
        task = Task {
            do {
                try await bridge.stop()
                if appliedPreferences.workflowOptions.automaticallyPaste {
                    do {
                        let (host, port, key) = try senderSettings()
                        try await client.prepareAutomaticDelivery(host: host, port: port, key: key)
                    } catch is CancellationError { throw CancellationError() }
                    catch {
                        try Task.checkCancellation()
                        client.cancel(); automaticPasteIssue = error.localizedDescription
                    }
                }
                let deadline = Date().addingTimeInterval(90)
                while Date() < deadline {
                    try Task.checkCancellation()
                    if let metadata = try bridge.result() {
                        bridge.reset(); lastInput = metadata.recordingDevice
                        retainedText = metadata.result
                        await deliver(metadata.result)
                        return
                    }
                    try await Task.sleep(for: .milliseconds(150))
                }
                throw TSError.message("No completed result arrived. Check Superwhisper: Paste result text off, Replace with dictation on, Realtime off, and the correct recordings folder. Nothing was sent.")
            } catch is CancellationError { client.cancel(); bridge.reset() }
            catch { if !Task.isCancelled { client.cancel(); bridge.reset(); fail(error) } }
        }
    }

    private func deliver(_ text: String) async {
        do {
            try Task.checkCancellation()
            let (host, port, key) = try senderSettings()
            phase = .sending; detail = "Waiting for the receiving Mac to confirm its clipboard."
            let outcome: PasteOutcome?
            if client.automaticDeliveryReady {
                outcome = try await client.sendAutomatically(text) { self.senderFocus?.stillFocused() == true }
            } else {
                try await client.send(text: text, host: host, port: port, key: key)
                outcome = nil
            }
            try Task.checkCancellation()
            phase = outcome == .clipboardChanged ? .failed : .sent; lastDelivery = Date()
            if let outcome { detail = outcome.message }
            else if let issue = automaticPasteIssue { detail = "Clipboard confirmed. Paste manually. \(issue)" }
            else { detail = "Confirmed on \(host). Paste in Jump Desktop." }
            if outcome != .clipboardChanged { retainedText = nil }
        } catch is CancellationError { }
        catch { if !Task.isCancelled { client.cancel(); fail(TSError.message("Delivery was not confirmed. \(error.localizedDescription) The target may already have received or pasted it. Retry copies to its clipboard only.")) } }
    }

    func takeScreenshot() {
        guard activeRole == .send, appliedPreferences.copiesScreenshots, !busy else { return }
        do { _ = try senderSettings() } catch { fail(error); return }
        retainedScreenshot = nil; retainedText = nil; lastInput = ""
        phase = .capturing; detail = "Drag a region on the sending Mac. Escape cancels without sending."
        task = Task {
            do {
                let screenshot = try await screenshotCapture.capture()
                try Task.checkCancellation()
                retainedScreenshot = screenshot
                guard Clipboard.write(screenshot) else { throw TSError.message("Could not copy the screenshot locally. Use Copy locally or Retry clipboard copy.") }
                await deliverScreenshot(screenshot)
            } catch is CancellationError {
                if !Task.isCancelled { phase = .idle; detail = "Screenshot cancelled. Nothing was sent." }
            } catch { if !Task.isCancelled { fail(error) } }
        }
    }

    private func deliverScreenshot(_ screenshot: ScreenshotPNG) async {
        do {
            try Task.checkCancellation()
            let (host, port, key) = try senderSettings()
            phase = .sending; detail = "Sending screenshot. Waiting for the target clipboard."
            try await client.sendScreenshot(screenshot, host: host, port: port, key: key)
            try Task.checkCancellation()
            retainedScreenshot = nil; lastDelivery = Date(); phase = .sent
            detail = "Screenshot confirmed on \(host). Paste inside Jump Desktop with Command–V."
        } catch is CancellationError { }
        catch { if !Task.isCancelled { client.cancel(); fail(TSError.message("Screenshot delivery was not confirmed. \(error.localizedDescription) Retry copies only; it never pastes.")) } }
    }

    func retry() {
        guard !busy else { return }
        if let retainedScreenshot {
            client.cancel(); phase = .sending
            task = Task { await deliverScreenshot(retainedScreenshot) }
            return
        }
        guard let retainedText else { return }
        client.cancel(); senderFocus = nil; automaticPasteIssue = "Retry copies only; automatic paste is not repeated."
        phase = .sending
        task = Task { await deliver(retainedText) }
    }
    func discard() { retainedText = nil; retainedScreenshot = nil; phase = .idle; detail = "Pending content discarded from T&S memory." }
    func copyRetained() { if let retainedScreenshot { _ = Clipboard.write(retainedScreenshot) } else if let retainedText { _ = Clipboard.write(retainedText) } }

    func testConnection() {
        guard !busy else { return }
        phase = .sending; detail = "Checking the paired receiver without changing its clipboard."
        task = Task {
            do {
                let (host, port, key) = try senderSettings()
                try await client.send(text: nil, host: host, port: port, key: key)
                try Task.checkCancellation()
                phase = .idle; detail = "Connected and authenticated. Ready to record."
            } catch is CancellationError { } catch { if !Task.isCancelled { fail(error) } }
        }
    }

    private func receiverSettings(_ config: Preferences) throws -> (String, String, UInt16) {
        guard key != nil else { throw TSError.message("Pair your Macs in Connection settings before switching to RX.") }
        guard TailAddress.isValid(config.senderIP), let port = UInt16(config.port), port > 0 else {
            throw TSError.message("Save the other Mac’s address and port in Connection settings first.")
        }
        guard localAddresses().contains(config.localIP) else { throw TSError.message("Connect Tailscale, detect this Mac’s address, then save settings before switching to RX.") }
        return (config.localIP, config.senderIP, port)
    }

    func startReceiver() {
        do {
            guard activeRole == .receive, let key else { throw TSError.message("Generate or save a pairing key first.") }
            let settings = try receiverSettings(appliedPreferences)
            try receiver.start(localIP: settings.0, allowedPeer: settings.1, port: settings.2, key: key)
            preferences.resumeReceiver = true; appliedPreferences.resumeReceiver = true; persist(); detail = "Starting receiver…"
        } catch { receiverRunning = false; fail(error) }
    }
    func stopReceiver(persist shouldPersist: Bool = true) {
        receiver.stop(); receiverRunning = false; overlay.hide()
        if shouldPersist { preferences.resumeReceiver = false; appliedPreferences.resumeReceiver = false; persist(); phase = .idle; detail = "Receiving is off." }
    }

    func cancel() {
        if activeRole == .receive { receiver.cancelAutomaticDelivery(); receiver.cancelImageDelivery(); return }
        guard phase != .cancelling else { return }
        let wasRecording = phase == .recording || phase == .starting
        let previous = task
        previous?.cancel(); watchdog?.cancel(); client.cancel(); screenshotCapture.cancel(); screenshotArmed = false
        phase = .cancelling; detail = "Stopping the current operation…"
        task = Task {
            await previous?.value
            if wasRecording { try? await bridge.stop() }
            bridge.reset()
            senderFocus = nil; automaticPasteIssue = nil
            phase = .idle; detail = "Cancelled. Any completed transfer may already be on the target clipboard."
        }
    }
    func shutdown() async {
        modeIndicatorTask?.cancel(); modeIndicatorVisible = false
        cancel(); await task?.value; receiver.stop(); hotKey.unregister()
    }
    func openSuperwhisper() { Task { do { try await SuperwhisperBridge.open("superwhisper://settings") } catch { fail(error) } } }
    func setLogin(_ enabled: Bool) {
        do {
            if enabled { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            loginEnabled = SMAppService.mainApp.status == .enabled
            if enabled && !loginEnabled { detail = "Approve T&S in System Settings → General → Login Items." }
        } catch { fail(error) }
    }
    func fail(_ error: Error) { phase = .failed; detail = error.localizedDescription }
}
