import AppKit
import ApplicationServices
import Carbon
import TSCore

/// Retains accessibility element identities, never their text or values.
@MainActor
public struct FocusSnapshot {
    let processID: pid_t
    let matches: () -> Bool
    public func stillFocused() -> Bool { matches() }

    public static func capture(requireTextField: Bool) -> FocusSnapshot? {
        guard AXIsProcessTrusted(), !IsSecureEventInputEnabled(),
              let front = NSWorkspace.shared.frontmostApplication, front.processIdentifier != getpid() else { return nil }
        let pid = front.processIdentifier
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 0.25)
        guard let window = element(app, kAXFocusedWindowAttribute) else { return nil }
        let field = requireTextField ? element(app, kAXFocusedUIElementAttribute) : nil
        if requireTextField {
            guard let field, isTextField(field) else { return nil }
        }
        return FocusSnapshot(processID: pid) {
            guard NSWorkspace.shared.frontmostApplication?.processIdentifier == pid,
                  let currentWindow = element(app, kAXFocusedWindowAttribute), CFEqual(window, currentWindow) else { return false }
            guard let field else { return true }
            guard let current = element(app, kAXFocusedUIElementAttribute), CFEqual(field, current), isTextField(current) else { return false }
            return true
        }
    }

    private static func element(_ parent: AXUIElement, _ attribute: String) -> AXUIElement? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(parent, attribute as CFString, &value) == .success,
              let value, CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        return (value as! AXUIElement)
    }

    private static func string(_ element: AXUIElement, _ attribute: String) -> String? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else { return nil }
        return value as? String
    }

    private static func isTextField(_ element: AXUIElement) -> Bool {
        guard let role = string(element, kAXRoleAttribute),
              [kAXTextFieldRole, kAXTextAreaRole, kAXComboBoxRole].contains(role) else { return false }
        return string(element, kAXSubroleAttribute) != kAXSecureTextFieldSubrole
    }
}

@MainActor
public final class AutomaticPaste {
    public enum PermissionStatus {
        case accessibilityNeeded, eventPostingNeeded, available
        public var message: String {
            switch self {
            case .accessibilityNeeded: return "macOS has not granted Accessibility to this running copy of T&S."
            case .eventPostingNeeded: return "Accessibility is available, but macOS has not allowed T&S to send the Paste shortcut."
            case .available: return "Paste permission is available"
            }
        }
    }
    public var isAllowed: () -> Bool = { false }
    private let permission: () -> Bool
    private let capture: () -> FocusSnapshot?
    private let protectedInput: () -> Bool
    private let modifiersHeld: () -> Bool
    private let clipboardMatches: (String, Int) -> Bool
    private let post: (pid_t) -> Bool

    public convenience init() {
        self.init(permission: { Self.hasPermission }, capture: { FocusSnapshot.capture(requireTextField: true) },
                  protectedInput: { IsSecureEventInputEnabled() }, modifiersHeld: {
            !CGEventSource.flagsState(.combinedSessionState).intersection([.maskCommand, .maskControl, .maskAlternate, .maskShift]).isEmpty
        }, clipboardMatches: { text, revision in
            NSPasteboard.general.changeCount == revision && NSPasteboard.general.string(forType: .string) == text
        }, post: Self.postPaste)
    }

    init(permission: @escaping () -> Bool, capture: @escaping () -> FocusSnapshot?, protectedInput: @escaping () -> Bool,
         modifiersHeld: @escaping () -> Bool, clipboardMatches: @escaping (String, Int) -> Bool, post: @escaping (pid_t) -> Bool) {
        self.permission = permission; self.capture = capture; self.protectedInput = protectedInput
        self.modifiersHeld = modifiersHeld; self.clipboardMatches = clipboardMatches; self.post = post
    }

    public static var permissionStatus: PermissionStatus {
        if !AXIsProcessTrusted() { return .accessibilityNeeded }
        return CGPreflightPostEventAccess() ? .available : .eventPostingNeeded
    }
    public static var hasPermission: Bool { permissionStatus == .available }
    public static func requestPermission() {
        if !AXIsProcessTrusted() {
            _ = AXIsProcessTrustedWithOptions([kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary)
        } else if !CGPreflightPostEventAccess() {
            _ = CGRequestPostEventAccess()
        }
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") { NSWorkspace.shared.open(url) }
    }

    public func prepare() -> PasteAttempt {
        guard isAllowed() else { return { _, _, _ in .disabled } }
        guard permission() else { return { _, _, _ in .permissionNeeded } }
        guard !protectedInput() else { return { _, _, _ in .protectedInput } }
        guard let target = capture() else { return { _, _, _ in .focusUnavailable } }
        return { [weak self] text, revision, stillActive in
            guard let self else { return .cancelled }
            // The user's stop shortcut may still have a modifier held briefly.
            for _ in 0..<20 where self.modifiersHeld() {
                guard stillActive(), !Task.isCancelled else { return .cancelled }
                do { try await Task.sleep(for: .milliseconds(50)) } catch { return .cancelled }
            }
            guard stillActive(), !Task.isCancelled else { return .cancelled }
            guard self.isAllowed() else { return .disabled }
            guard self.permission() else { return .permissionNeeded }
            guard !self.protectedInput() else { return .protectedInput }
            guard target.stillFocused() else { return .focusChanged }
            guard self.clipboardMatches(text, revision) else { return .clipboardChanged }
            guard !self.modifiersHeld() else { return .modifiersHeld }
            return self.post(target.processID) ? .requested : .permissionNeeded
        }
    }

    static func postPaste(to pid: pid_t) -> Bool {
        guard let source = CGEventSource(stateID: .privateState),
              let down = CGEvent(keyboardEventSource: source, virtualKey: UInt16(kVK_ANSI_V), keyDown: true),
              let up = CGEvent(keyboardEventSource: source, virtualKey: UInt16(kVK_ANSI_V), keyDown: false) else { return false }
        down.flags = .maskCommand; up.flags = .maskCommand
        // Fixed Cmd+V only, targeted to the captured app. No Return, shell,
        // arbitrary keys, activation, or focus change is available remotely.
        down.postToPid(pid); up.postToPid(pid)
        return true // Event submission, not proof the target application inserted text.
    }
}
