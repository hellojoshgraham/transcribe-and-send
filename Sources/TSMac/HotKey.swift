import AppKit
import ApplicationServices
import Carbon
import TSCore

public enum Shortcut: String, CaseIterable, Codable {
    case optionSpace = "⌥ Space"
    case controlOptionSpace = "⌃ ⌥ Space"
    case controlOptionF8 = "⌃ ⌥ F8"
    case commandShiftSpace = "⌘ ⇧ Space"
    var key: UInt16 { self == .controlOptionF8 ? UInt16(kVK_F8) : UInt16(kVK_Space) }
    var carbonModifiers: UInt32 { self == .optionSpace ? UInt32(optionKey) : self == .commandShiftSpace ? UInt32(cmdKey | shiftKey) : UInt32(controlKey | optionKey) }
    var modifiers: ShortcutGesture.Modifiers { self == .optionSpace ? [.option] : self == .commandShiftSpace ? [.command, .shift] : [.control, .option] }
}

/// All callbacks/state live on the main run loop. Event callbacks only classify input and enqueue actions.
@MainActor
public final class HotKey {
    public enum CaptureState: Equatable { case off, needsAccessibility, local, sessionFallback, unavailable, secureInput }
    public var pressed: (() -> Void)?
    public var released: (() -> Void)?
    public var interrupted: (() -> Void)?
    public var captureChanged: ((CaptureState) -> Void)?
    public var switchMode: (() -> Void)?
    public var screenshotPressed: (() -> Void)?
    public var screenshotReleased: (() -> Void)?
    public var screenshotInterrupted: (() -> Void)?
    public private(set) var captureState: CaptureState = .off {
        didSet { if oldValue != captureState { captureChanged?(captureState) } }
    }
    private var shortcut: Shortcut?
    private var gesture: ShortcutGesture?
    private var screenshotGesture: ShortcutGesture?
    private var modeShortcut: ModeShortcut?
    private var modeGesture: ShortcutGesture?
    private var modeArmed = false
    private var tap: CFMachPort?
    private var source: CFRunLoopSource?
    private var tapLocation: CGEventTapLocation?
    private var healthTimer: Timer?
    private var activationObserver: NSObjectProtocol?
    private var rearmTask: Task<Void, Never>?
    private var references: [EventHotKeyRef] = []
    private var handler: EventHandlerRef?
    private var carbonDown = false
    private var generation = UUID()

    public init() {}

    deinit {
        // Never leave a C callback holding a dangling userInfo pointer.
        healthTimer?.invalidate(); rearmTask?.cancel()
        if let activationObserver { NSWorkspace.shared.notificationCenter.removeObserver(activationObserver) }
        if let tap { CFMachPortInvalidate(tap) }
        if let source { CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes) }
        for reference in references { UnregisterEventHotKey(reference) }
        if let handler { RemoveEventHandler(handler) }
    }

    public func register(_ shortcut: Shortcut?, copyScreenshots: Bool = false, modeSwitch: ModeShortcut? = nil) throws {
        if let modeSwitch { try modeSwitch.validate(voice: shortcut, screenshots: copyScreenshots) }
        unregister()
        self.shortcut = shortcut
        gesture = shortcut.map { ShortcutGesture(key: $0.key, modifiers: $0.modifiers) }
        modeShortcut = modeSwitch
        modeGesture = modeSwitch.map { ShortcutGesture(key: $0.keyCode, modifiers: $0.modifiers) }
        screenshotGesture = copyScreenshots ? ShortcutGesture(key: UInt16(kVK_ANSI_3), modifiers: [.command, .shift]) : nil
        try refresh()
        healthTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { try? self?.refresh() }
        }
        // Remote clients may install their filters on activation. Reinsert ours at the head afterwards,
        // never while its physical key is held. Normal text/shortcuts still flow through unchanged.
        activationObserver = NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.rearmTask?.cancel()
                self?.rearmTask = Task { @MainActor [weak self] in
                    try? await Task.sleep(for: .milliseconds(250))
                    guard !Task.isCancelled, let self, self.tap != nil, self.gesture?.ownsKey != true, self.screenshotGesture?.ownsKey != true, self.modeGesture?.ownsKey != true else { return }
                    try? self.retryCapture()
                }
            }
        }
    }

    public func requestAccessibility() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }

    public func refresh() throws {
        guard shortcut != nil || modeShortcut != nil else { return }
        if !AXIsProcessTrusted() {
            if tap != nil { interruptGesture(); removeTap() }
            captureState = .needsAccessibility
            if references.isEmpty { try installCarbon() }
            return
        }
        if IsSecureEventInputEnabled() {
            interruptGesture()
            captureState = .secureInput
            return
        }
        if tap == nil {
            // Finish a hold on the old backend before changing it, including its queued release action.
            if !references.isEmpty && (carbonDown || configuredKeyIsDown) { return }
            // Keep the original Carbon path only until Accessibility is granted. Avoid duplicate dispatch.
            removeCarbon()
            guard installTap() else { captureState = .unavailable; return }
        }
        if let tap, !CGEvent.tapIsEnabled(tap: tap) {
            interruptGesture()
            CGEvent.tapEnable(tap: tap, enable: true)
        }
        captureState = tapLocation == .cghidEventTap ? .local : .sessionFallback
    }

    public func retryCapture() throws {
        guard shortcut != nil || modeShortcut != nil, gesture?.ownsKey != true, screenshotGesture?.ownsKey != true,
              modeGesture?.ownsKey != true, !carbonDown, !configuredKeyIsDown else { return }
        removeTap()
        try refresh()
    }

    private func installTap() -> Bool {
        let mask = (CGEventMask(1) << CGEventType.keyDown.rawValue)
            | (CGEventMask(1) << CGEventType.keyUp.rawValue)
            | (CGEventMask(1) << CGEventType.flagsChanged.rawValue)
        // A session tap cannot see keys already consumed at the HID stage.
        // Runtime-tested on macOS 14 with Accessibility as an ordinary user;
        // attempt HID first, and clearly report the weaker session fallback.
        for location in [CGEventTapLocation.cghidEventTap, .cgSessionEventTap] {
            guard let port = CGEvent.tapCreate(tap: location, place: .headInsertEventTap, options: .defaultTap, eventsOfInterest: mask, callback: { _, type, event, context in
                guard let context else { return Unmanaged.passUnretained(event) }
                return MainActor.assumeIsolated {
                    Unmanaged<HotKey>.fromOpaque(context).takeUnretainedValue().filter(type: type, event: event)
                }
            }, userInfo: Unmanaged.passUnretained(self).toOpaque()) else { continue }
            guard let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, port, 0) else {
                CFMachPortInvalidate(port); continue
            }
            tap = port; self.source = source; tapLocation = location
            CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
            CGEvent.tapEnable(tap: port, enable: true)
            if CGEvent.tapIsEnabled(tap: port) { return true }
            removeTap()
        }
        return false
    }

    private func filter(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            interruptGesture()
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            return Unmanaged.passUnretained(event)
        }
        // The earlier listener must still respect protected password entry.
        if IsSecureEventInputEnabled() {
            // The health timer publishes the UI status outside this callback.
            interruptGesture()
            return Unmanaged.passUnretained(event)
        }
        let input: ShortcutGesture.Event
        let key = UInt16(truncatingIfNeeded: event.getIntegerValueField(.keyboardEventKeycode))
        switch type {
        case .keyDown: input = .down(key: key, repeating: event.getIntegerValueField(.keyboardEventAutorepeat) != 0)
        case .keyUp: input = .up(key: key)
        case .flagsChanged: input = .modifiersChanged
        default: return Unmanaged.passUnretained(event)
        }
        var modifiers: ShortcutGesture.Modifiers = []
        if event.flags.contains(.maskControl) { modifiers.insert(.control) }
        if event.flags.contains(.maskAlternate) { modifiers.insert(.option) }
        if event.flags.contains(.maskCommand) { modifiers.insert(.command) }
        if event.flags.contains(.maskShift) { modifiers.insert(.shift) }
        let decision = gesture?.handle(input, modifiers: modifiers) ?? .init()
        let screenshot = screenshotGesture?.handle(input, modifiers: modifiers) ?? .init()
        let mode = modeGesture?.handle(input, modifiers: modifiers) ?? .init()
        if mode.action == .pressed { modeArmed = true }
        // Switch only after the physical key-up was consumed. Re-registering on
        // modifier release would lose ownership of a still-held key.
        if type == .keyUp, key == modeShortcut?.keyCode, modeArmed {
            modeArmed = false
            enqueueModeSwitch()
        }
        enqueue(decision.action)
        enqueue(screenshot.action, screenshot: true)
        // Returning nil consumes the reserved key before downstream filters and app delivery.
        return decision.consume || screenshot.consume || mode.consume ? nil : Unmanaged.passUnretained(event)
    }

    private func enqueue(_ action: ShortcutGesture.Action?, screenshot: Bool = false) {
        guard let action else { return }
        let generation = generation
        DispatchQueue.main.async { [weak self] in
            guard let self, self.generation == generation else { return }
            if screenshot {
                switch action {
                case .pressed: self.screenshotPressed?()
                case .released: self.screenshotReleased?()
                case .interrupted: self.screenshotInterrupted?()
                }
                return
            }
            switch action {
            case .pressed: self.pressed?()
            case .released: self.released?()
            case .interrupted: self.interrupted?()
            }
        }
    }

    private func interruptGesture() {
        guard shortcut != nil || modeShortcut != nil else { return }
        modeArmed = false
        _ = modeGesture?.interrupt(keyStillDown: modeShortcut.map { keyIsDown($0.keyCode) } ?? false)
        let down = shortcut.map { keyIsDown($0.key) } ?? false
        enqueue(gesture?.interrupt(keyStillDown: down).action)
        enqueue(screenshotGesture?.interrupt(keyStillDown: keyIsDown(UInt16(kVK_ANSI_3))).action, screenshot: true)
    }

    private func keyIsDown(_ key: UInt16) -> Bool {
        CGEventSource.keyState(.hidSystemState, key: key) || CGEventSource.keyState(.combinedSessionState, key: key)
    }

    private var configuredKeyIsDown: Bool {
        (shortcut.map { keyIsDown($0.key) } ?? false) || (modeShortcut.map { keyIsDown($0.keyCode) } ?? false)
            || (screenshotGesture != nil && keyIsDown(UInt16(kVK_ANSI_3)))
    }

    private func enqueueModeSwitch() {
        let generation = generation
        DispatchQueue.main.async { [weak self] in
            guard let self, self.generation == generation else { return }
            self.switchMode?()
        }
    }

    private func installCarbon() throws {
        var types = [EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed)), EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyReleased))]
        let status = InstallEventHandler(GetApplicationEventTarget(), { _, event, context in
            guard let event, let context else { return OSStatus(eventNotHandledErr) }
            MainActor.assumeIsolated {
                let owner = Unmanaged<HotKey>.fromOpaque(context).takeUnretainedValue()
                guard !IsSecureEventInputEnabled() else { owner.interruptGesture(); return }
                var identifier = EventHotKeyID()
                guard GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID), nil,
                                        MemoryLayout<EventHotKeyID>.size, nil, &identifier) == noErr else { return }
                if identifier.id == 2 {
                    if GetEventKind(event) == UInt32(kEventHotKeyPressed) { owner.modeArmed = true }
                    else if owner.modeArmed { owner.modeArmed = false; owner.enqueueModeSwitch() }
                    return
                }
                if GetEventKind(event) == UInt32(kEventHotKeyPressed), !owner.carbonDown {
                    owner.carbonDown = true; owner.enqueue(.pressed)
                } else if GetEventKind(event) == UInt32(kEventHotKeyReleased), owner.carbonDown {
                    owner.carbonDown = false; owner.enqueue(.released)
                }
            }
            return noErr
        }, types.count, &types, Unmanaged.passUnretained(self).toOpaque(), &handler)
        guard status == noErr else { throw TSError.message("T&S could not install its keyboard shortcut.") }
        var bindings: [(UInt16, UInt32, UInt32)] = []
        if let shortcut { bindings.append((shortcut.key, shortcut.carbonModifiers, 1)) }
        if let modeShortcut { bindings.append((modeShortcut.keyCode, modeShortcut.carbonModifiers, 2)) }
        for (key, modifiers, id) in bindings {
            var reference: EventHotKeyRef?
            let result = RegisterEventHotKey(UInt32(key), modifiers, EventHotKeyID(signature: 0x54534150, id: id), GetApplicationEventTarget(), 0, &reference)
            guard result == noErr, let reference else {
                removeCarbon(); throw TSError.message("This shortcut is already in use. Choose another shortcut in T&S settings.")
            }
            references.append(reference)
        }
    }

    private func removeCarbon() {
        for reference in references { UnregisterEventHotKey(reference) }; references = []
        if let handler { RemoveEventHandler(handler) }; handler = nil
    }

    private func removeTap() {
        if let tap { CGEvent.tapEnable(tap: tap, enable: false); CFMachPortInvalidate(tap) }
        if let source { CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes) }
        tap = nil; source = nil; tapLocation = nil
    }
    public func unregister() {
        generation = UUID()
        if gesture?.ownsKey == true || carbonDown { interrupted?() }
        if screenshotGesture?.ownsKey == true { screenshotInterrupted?() }
        healthTimer?.invalidate(); healthTimer = nil
        rearmTask?.cancel(); rearmTask = nil
        if let activationObserver { NSWorkspace.shared.notificationCenter.removeObserver(activationObserver) }; activationObserver = nil
        removeTap(); removeCarbon(); gesture = nil; screenshotGesture = nil; shortcut = nil; carbonDown = false
        modeGesture = nil; modeShortcut = nil; modeArmed = false
        captureState = .off
    }
}
