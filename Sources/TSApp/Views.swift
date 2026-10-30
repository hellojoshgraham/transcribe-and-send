import AppKit
import SwiftUI
import TSCore
import TSMac

struct MenuBarLabel: View {
    @ObservedObject var model: AppModel
    var body: some View {
        Group {
            if model.modeIndicatorVisible {
                Image(nsImage: ModeStatusImage.make(transmitting: model.activeRole == .send,
                                                   delivered: model.phase == .sent, failed: model.phase == .failed))
            } else {
                Label(model.phase == .sent ? "T&S ✓" : model.phase == .failed ? "T&S !" : "T&S", systemImage: model.symbol)
            }
        }
        .accessibilityLabel("T&S, \(model.activeRole == .send ? "TX transmit" : "RX receive"), \(model.title)")
        .help("\(model.activeRole == .send ? "TX" : "RX") · \(model.activeSwitchShortcut) to switch. \(model.detail)")
    }
}

struct MenuPanel: View {
    @ObservedObject var model: AppModel
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            MenuModeRow(role: model.activeRole, isBusy: model.busy, switchMode: model.switchMode)
            Text(model.activeSwitchShortcut).font(.caption).foregroundStyle(.secondary)
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: model.symbol).font(.system(size: 25, weight: .medium)).foregroundStyle(model.tint).frame(width: 30)
                VStack(alignment: .leading, spacing: 5) {
                    Text(model.title).font(.headline)
                    Text(model.detail).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
            }
            if model.activeRole == .send {
                HStack {
                    Text(model.recordingMode == .hold ? "Hold to talk" : "Press to start / stop").foregroundStyle(.secondary)
                    Spacer()
                    Text(model.preferences.shortcut.rawValue).fontWeight(.medium).padding(.horizontal, 9).padding(.vertical, 5)
                        .background(.quaternary, in: RoundedRectangle(cornerRadius: 6))
                }.font(.callout)
                if model.shortcutCapture != .local {
                    Text(model.shortcutStatus).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    if model.shortcutCapture == .needsAccessibility || model.shortcutCapture == .unavailable {
                        Button("Enable local shortcut…") { model.enableLocalShortcut() }
                    }
                }
                if !model.lastInput.isEmpty { Label(model.lastInput, systemImage: "mic").font(.caption).foregroundStyle(.secondary) }
                if model.busy { Button("Cancel capture or transfer", role: .cancel) { model.cancel() } }
                if model.preferences.copiesScreenshots {
                    Button { model.takeScreenshot() } label: {
                        HStack { Label("Take and send screenshot", systemImage: "crop"); Spacer(); Text("⌘ ⇧ 3").foregroundStyle(.secondary) }
                    }.disabled(model.busy)
                }
                if (model.retainedText != nil || model.retainedScreenshot != nil) && !model.busy {
                    HStack {
                        Button("Retry clipboard copy") { model.retry() }.buttonStyle(.borderedProminent)
                        Button("Copy locally") { model.copyRetained() }
                        Button("Discard") { model.discard() }
                    }
                    Text("Retry replaces the target clipboard. It never repeats an automatic paste.").font(.caption).foregroundStyle(.secondary)
                }
            } else {
                Button(model.receiverRunning ? "Stop receiving" : "Start receiving") {
                    if model.receiverRunning { model.stopReceiver() } else { model.startReceiver() }
                }
            }
            if let date = model.lastDelivery {
                HStack {
                    Text("Last confirmed").foregroundStyle(.secondary)
                    Spacer()
                    Text(date, style: .time)
                }.font(.caption)
            }
            Divider()
            HStack {
                Button("Settings…") { model.showSettings?() }.keyboardShortcut(",")
                Spacer()
                Button("Quit T&S") { NSApp.terminate(nil) }.keyboardShortcut("q")
            }.buttonStyle(.plain).font(.callout)
        }.padding(20).frame(width: 354)
    }
}

struct MenuModeRow: View {
    let role: Preferences.Role
    let isBusy: Bool
    let switchMode: () -> Void
    @Environment(\.colorScheme) private var colorScheme
    private var accent: Color { colorScheme == .dark ? Color(red: 0.73, green: 0.71, blue: 0.96) : Color(red: 0.34, green: 0.32, blue: 0.68) }

    var body: some View {
        HStack(spacing: 12) {
            HStack(spacing: 4) {
                mode("TX", selected: role == .send)
                mode("RX", selected: role == .receive)
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Current mode")
            .accessibilityValue(role == .send ? "TX, transmit" : "RX, receive")
            Spacer()
            Button("Switch", action: switchMode)
                .disabled(isBusy)
                .accessibilityLabel(role == .send ? "Switch to receive mode" : "Switch to transmit mode")
                .help(isBusy ? "Finish or cancel the current operation before switching." : role == .send ? "Start receiving on this Mac." : "Stop receiving and enable local sending shortcuts.")
        }
    }

    private func mode(_ title: String, selected: Bool) -> some View {
        Text(title).font(.system(size: 12, weight: selected ? .semibold : .regular))
            .foregroundStyle(selected ? accent : Color.secondary)
            .padding(.horizontal, 12).padding(.vertical, 6)
            .background(selected ? accent.opacity(0.16) : Color.clear, in: RoundedRectangle(cornerRadius: 6))
    }
}

struct SettingsView: View {
    @ObservedObject var model: AppModel
    @State private var tab = 0
    @State private var importCode = ""
    @State private var pendingCode: PairingCode?
    @State private var pairingConfirmation = false
    @State private var pairingKey = ""
    @State private var rotateConfirmation = false
    private let accent = Color(red: 0.34, green: 0.32, blue: 0.68)

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 18) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("T&S").font(.system(size: 26, weight: .semibold, design: .rounded))
                    Text("Two Macs. One connection.").font(.callout).foregroundStyle(.secondary)
                }
                Spacer()
                VStack(alignment: .trailing, spacing: 7) {
                    MenuModeRow(role: model.activeRole, isBusy: model.busy, switchMode: model.switchMode).frame(width: 220)
                    Text(model.activeSwitchShortcut).font(.caption).foregroundStyle(.secondary)
                }
            }.padding(24)
            TabView(selection: $tab) {
                connection.tabItem { Label("Connection", systemImage: "link") }.tag(0)
                sending.tabItem { Label("Send", systemImage: "arrow.up") }.tag(1)
                receiving.tabItem { Label("Receive", systemImage: "arrow.down") }.tag(2)
                general.tabItem { Label("Shortcuts & app", systemImage: "keyboard") }.tag(3)
            }.padding(.horizontal, 12).disabled(model.busy)
            Divider()
            HStack(spacing: 12) {
                Image(systemName: model.symbol).foregroundStyle(model.tint)
                Text(model.detail).font(.caption).foregroundStyle(.secondary).lineLimit(3).frame(maxWidth: .infinity, alignment: .leading)
                if model.busy { Button("Cancel") { model.cancel() } }
                Button("Save settings") {
                    if model.save(pairingKey: pairingKey) { pairingKey = "" }
                }.buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction).disabled(model.busy)
            }.padding(18)
        }.frame(minWidth: 620, idealWidth: 680, minHeight: 580, idealHeight: 730).background(Color(nsColor: .windowBackgroundColor)).tint(accent)
        .confirmationDialog("Pair with this Mac?", isPresented: $pairingConfirmation) {
            Button("Pair with this Mac") {
                if let pendingCode, model.importPairingCode(pendingCode) { importCode = ""; pairingKey = "" }
                pendingCode = nil
            }
            Button("Cancel", role: .cancel) { pendingCode = nil }
        } message: {
            if let pendingCode {
                Text("Address: \(pendingCode.address)\nKey fingerprint: \(pendingCode.key.fingerprint)\nThis replaces the saved connection and shared key. Compare the fingerprint on both Macs.")
            }
        }
        .confirmationDialog("Replace the shared pairing key?", isPresented: $rotateConfirmation) {
            Button("Replace key", role: .destructive) { _ = model.generateKey() }
        } message: { Text("Receiving will stop. Exchange pairing codes again on both Macs before sending.") }
        .onDisappear { importCode = ""; pendingCode = nil; pairingKey = "" }
    }

    init(model: AppModel, initialTab: Int = 0) {
        self.model = model
        _tab = State(initialValue: initialTab)
    }

    private var connection: some View {
        Form {
            Section {
                PairingInstructions()
                Button(model.hasPairingKey ? "Copy this Mac’s pairing code" : "Create & copy pairing code") {
                    if let code = model.pairingCode() {
                        if Clipboard.writePairingCode(code) { model.detail = "Pairing code copied. Keep it private; paste it into T&S on the other Mac." }
                        else { model.fail(TSError.message("Could not copy the pairing code.")) }
                    }
                }
                HStack {
                    SecureField("Other Mac’s code", text: $importCode, prompt: Text("Paste pairing code"))
                    Button("Review pairing…") {
                        do { pendingCode = try PairingCode(encoded: importCode); pairingConfirmation = true }
                        catch { model.fail(error) }
                    }.disabled(importCode.isEmpty)
                }
                LabeledContent("Key fingerprint", value: model.keyFingerprint).font(.caption).textSelection(.enabled)
            } header: { Text("Pair once, use either direction") } footer: {
                Text("The code contains your shared secret. Share it only with your other Mac. T&S stores the key in Keychain and never includes it in a diagnostic report.")
            }
            Section {
                TextField("Other Mac’s Tailscale IPv4", text: $model.preferences.pairedIP, prompt: Text("100.x.x.x"))
                if model.preferences.hasDifferentLegacyPeers {
                    Text("Your older setup uses different peers: send to \(model.preferences.targetIP), receive from \(model.preferences.senderIP). Enter the one Mac you want to pair in both directions before saving.")
                        .font(.caption).foregroundStyle(.orange)
                }
                HStack {
                    LabeledContent("This Mac", value: model.preferences.localIP.isEmpty ? "Connect Tailscale" : model.preferences.localIP)
                    Button("Detect") { model.detectLocalAddress() }
                }
                Button("Test saved connection") { model.testConnection() }
                    .disabled(model.activeRole != .send)
                DisclosureGroup("Advanced connection settings") {
                    TextField("This Mac’s Tailscale IPv4", text: $model.preferences.localIP)
                    TextField("Port on both Macs", text: $model.preferences.port)
                    SecureField("Shared key", text: $pairingKey, prompt: Text("Leave blank to keep the saved key"))
                    Button("Replace shared key…") { rotateConfirmation = true }
                }
            } header: { Text("One trusted Mac") } footer: {
                Text("Use TX on the Mac you’re working from and RX on the other Mac. Switching affects this Mac only. A connection test leaves the other clipboard untouched.")
            }
        }.formStyle(.grouped)
    }

    private var sending: some View {
        Form {
                    Section {
                        Picker("Voice shortcut", selection: $model.preferences.shortcut) {
                            ForEach(Shortcut.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                        }
                        Picker("Recording", selection: $model.preferences.workflowOptions.recordingMode) {
                            ForEach(RecordingMode.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                        }
                        Toggle("Automatically paste on the receiving Mac", isOn: $model.preferences.workflowOptions.automaticallyPaste)
                        Text("Automatic paste also needs permission on the receiving Mac. Keep its text field selected while waiting. T&S sends Paste, never Return.")
                            .font(.caption).foregroundStyle(.secondary)
                        LabeledContent("Local shortcut", value: model.shortcutStatus)
                            .font(.callout).foregroundStyle(.secondary)
                        HStack {
                            if model.shortcutCapture == .needsAccessibility || model.shortcutCapture == .unavailable {
                                Button("Enable local shortcut…") { model.enableLocalShortcut() }
                            }
                            Button("Reconnect keyboard listener") { model.retryLocalShortcut() }
                        }
                        if let received = model.lastShortcutReceived {
                            HStack {
                                Text("Last shortcut received")
                                Spacer()
                                Text(received, style: .time)
                                Text("· \(model.shortcutForegroundApp)")
                            }.font(.caption).foregroundStyle(.secondary)
                        } else {
                            Text("No shortcut received since opening T&S.").font(.caption).foregroundStyle(.secondary)
                        }
                        Text("Test your shortcut with Jump Desktop focused, then check the last received time here. Accessibility enables the local listener on this Mac. Other typing passes through; T&S never stores or sends typed characters.")
                            .font(.caption).foregroundStyle(.secondary)
                        HStack {
                            VStack(alignment: .leading, spacing: 4) {
                                Text("Superwhisper folder")
                                Text(model.preferences.superwhisperFolder).font(.caption).foregroundStyle(.secondary)
                                    .lineLimit(2).textSelection(.enabled)
                            }
                            Spacer()
                            Button("Choose folder…") { model.chooseSuperwhisperFolder() }
                        }
                        Label(model.folderSelected ? "Folder selected. Access will be checked when you record." : "Choose the folder once to allow T&S to read your dictation results.", systemImage: model.folderSelected ? "folder.badge.checkmark" : "folder.badge.questionmark")
                            .font(.caption).foregroundStyle(.secondary)
                        Button("Open Superwhisper settings") { model.openSuperwhisper() }
                        VStack(alignment: .leading, spacing: 7) {
                            Label("Select this Mac or Bluetooth headset microphone.", systemImage: "mic")
                            Label("Turn off Paste result text and Realtime.", systemImage: "text.cursor")
                            Label("Set Clipboard content to Replace with dictation.", systemImage: "doc.on.clipboard")
                            Label("Choose a local voice model to keep audio on this Mac.", systemImage: "laptopcomputer")
                        }.font(.callout).foregroundStyle(.secondary).padding(.vertical, 4)
                        Toggle("I’ve configured Superwhisper for this workflow", isOn: $model.preferences.superwhisperConfigured)
                    } header: { Text("Local voice capture") } footer: {
                        Text("Speak when Superwhisper shows its waveform. Stop with your selected recording gesture. T&S uses Superwhisper’s current mode; avoid other recordings while it is working. Turn off Jump Desktop clipboard sharing if it overwrites the received text.")
                    }

            ScreenshotSettingsSection(enabled: $model.preferences.copiesScreenshots, permission: model.screenshotPermission,
                                      enablePermission: model.enableScreenshotPermission, checkPermission: model.refreshPastePermission)
        }.formStyle(.grouped)
    }

    private var receiving: some View {
        Form {
            Section {
                Label(model.receiverRunning ? "Listening on Tailscale" : "Receiving is off", systemImage: model.receiverRunning ? "checkmark.shield" : "pause.circle")
                if model.activeRole == .receive {
                    Button(model.receiverRunning ? "Stop receiving" : "Start receiving") {
                        if model.receiverRunning { model.stopReceiver() } else { model.startReceiver() }
                    }
                } else { Text("Switch to RX to receive on this Mac.").foregroundStyle(.secondary) }
            }
                    Section {
                        Toggle("Allow automatic paste from the paired Mac", isOn: $model.preferences.workflowOptions.allowAutomaticPaste)
                        Toggle("Show delivery status", isOn: $model.preferences.workflowOptions.showReceiverStatus)
                        if model.preferences.workflowOptions.allowAutomaticPaste {
                            Label(model.pastePermissionStatus.message, systemImage: model.pastePermission ? "checkmark.shield" : "hand.raised")
                                .font(.callout).foregroundStyle(.secondary)
                            if !model.pastePermission {
                                Text("Already switched on in System Settings? Quit T&S, remove its old Accessibility entry, then add the copy in Applications and reopen T&S. Keep one installed copy on each Mac.")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                            HStack {
                                Button("Enable paste permission…") { model.enableAutomaticPaste() }
                                Button("Check permission") { model.refreshPastePermission() }
                            }
                        }
                        Button("Preview delivery status") { model.previewDeliveryStatus() }
                    } header: { Text("Automatic paste") } footer: {
                        Text("For voice, T&S can send Command–V to the same focused text field after its clipboard is ready. If the field, window, or clipboard changes, paste is skipped. Screenshots are always pasted manually. The small status panel never takes keyboard focus.")
                    }

        }.formStyle(.grouped)
    }

    private var general: some View {
        Form {
            Section {
                ModeShortcutEditor(shortcut: $model.preferences.switchShortcut)
                LabeledContent("Keyboard listener", value: model.shortcutStatus).font(.caption)
                HStack {
                    Button("Enable Accessibility…") { model.enableLocalShortcut() }
                    Button("Reconnect listener") { model.retryLocalShortcut() }
                }
            } header: { Text("Switch TX / RX") } footer: {
                Text("Works locally in both modes, including with a remote desktop focused. Switching is unavailable during recording or transfer. Key labels use the US keyboard layout; macOS or other apps may reserve some combinations.")
            }
            Section {
                Toggle("Open T&S at login", isOn: Binding(get: { model.loginEnabled }, set: { model.setLogin($0) }))
                LabeledContent("Version", value: "0.4.1")
                Text("No transcript history or analytics in T&S. Superwhisper manages its own audio and history.").font(.callout).foregroundStyle(.secondary)
            }
        }.formStyle(.grouped)
    }
}

struct PairingInstructions: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Copy a code from the first Mac and pair it on the second.", systemImage: "1.circle")
            Label("Copy the second Mac’s code back to the first to finish.", systemImage: "2.circle")
        }.font(.callout).fixedSize(horizontal: false, vertical: true)
    }
}

struct ModeShortcutEditor: View {
    @Binding var shortcut: ModeShortcut
    var body: some View {
        HStack {
            ForEach([(UInt8(1), "⌃"), (2, "⌥"), (8, "⇧"), (4, "⌘")], id: \.0) { mask, label in
                Toggle(label, isOn: Binding(get: { shortcut.modifierMask & mask != 0 }, set: {
                    if $0 { shortcut.modifierMask |= mask } else { shortcut.modifierMask &= ~mask }
                })).toggleStyle(.button)
                .accessibilityLabel(mask == 1 ? "Control" : mask == 2 ? "Option" : mask == 8 ? "Shift" : "Command")
            }
            Picker("Key", selection: $shortcut.keyCode) {
                ForEach(ModeShortcut.keys, id: \.code) { Text($0.name).tag($0.code) }
            }.frame(width: 140)
            Spacer()
            Button("Reset") { shortcut = .standard }
        }
        LabeledContent("Shortcut", value: shortcut.label)
    }
}

struct ScreenshotSettingsSection: View {
    @Binding var enabled: Bool
    let permission: Bool
    let enablePermission: () -> Void
    let checkPermission: () -> Void

    var body: some View {
        Section {
            Toggle("Copy screenshots", isOn: $enabled)
            if enabled {
                LabeledContent("Select a region", value: "⌘ ⇧ 3")
                Text("Keep Jump Desktop focused. Press the shortcut, drag a region on this Mac, then paste on your other Mac once T&S confirms delivery.")
                    .font(.callout).foregroundStyle(.secondary)
                Label(permission ? "Screen Recording permission is available" : "Allow Screen Recording on this Mac to capture a region", systemImage: permission ? "checkmark.shield" : "rectangle.dashed")
                    .font(.caption).foregroundStyle(.secondary)
                HStack {
                    Button("Enable screenshot permission…", action: enablePermission)
                    Button("Check permission", action: checkPermission)
                }
            }
        } header: { Text("Screenshots") } footer: {
            Text("While enabled, ⌘⇧3 selects a region locally instead of capturing the full screen. Escape cancels. Only captures you start here are sent; other clipboard images stay local. Screenshots are pasted manually, even when voice automatic paste is on.")
        }
    }
}
