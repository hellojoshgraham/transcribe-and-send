import AppKit
import SwiftUI
import TSCore

private final class StatusPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

@MainActor
public final class ReceiverOverlay {
    private var panel: NSPanel?
    private var dismissal: Task<Void, Never>?
    public init() {}

    public func show(_ progress: ReceiverProgress) {
        dismissal?.cancel()
        if panel == nil {
            let panel = StatusPanel(contentRect: NSRect(x: 0, y: 0, width: 330, height: 126), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
            panel.isReleasedWhenClosed = false; panel.isOpaque = false; panel.backgroundColor = .clear
            panel.level = .floating; panel.hasShadow = true; panel.ignoresMouseEvents = true
            panel.hidesOnDeactivate = false
            panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
            self.panel = panel
        }
        guard let panel else { return }
        panel.contentView = NSHostingView(rootView: ReceiverStatusView(progress: progress))
        if let frame = NSScreen.main?.visibleFrame {
            panel.setFrameOrigin(NSPoint(x: frame.maxX - 354, y: frame.minY + 24))
        }
        panel.orderFrontRegardless() // Never activate T&S or make this a key window.
        let duration: Double
        switch progress {
        case .waiting: duration = 112
        case .ready, .pasting: duration = 15
        case .receivingImage: duration = 47
        case .preview, .finished, .cancelled, .imageReady, .imageCancelled: duration = 5
        }
        dismissal = Task { [weak self] in
            try? await Task.sleep(for: .seconds(duration))
            guard !Task.isCancelled else { return }
            self?.hide()
        }
    }

    public func hide() { dismissal?.cancel(); dismissal = nil; panel?.orderOut(nil) }
}

struct ReceiverStatusView: View {
    let progress: ReceiverProgress
    @Environment(\.colorScheme) private var colorScheme
    private var accent: Color { colorScheme == .dark ? Color(red: 0.73, green: 0.71, blue: 0.96) : Color(red: 0.34, green: 0.32, blue: 0.68) }
    private var success: Color { colorScheme == .dark ? Color(red: 0.36, green: 0.79, blue: 0.65) : Color(red: 0.10, green: 0.48, blue: 0.39) }
    private var title: String {
        switch progress {
        case .preview: return "T&S status preview"
        case .waiting: return "Waiting for your words"
        case .ready: return "Clipboard ready"
        case .pasting: return "Sending Paste"
        case .finished(let outcome): return outcome == .requested ? "Paste shortcut sent" : "Paste manually"
        case .cancelled: return "Dictation cancelled"
        case .receivingImage: return "Receiving screenshot"
        case .imageReady: return "Screenshot ready"
        case .imageCancelled: return "Screenshot not delivered"
        }
    }
    private var detail: String {
        switch progress {
        case .preview: return "Delivery updates appear here without taking focus."
        case .waiting: return "Transcribing on the sending Mac…"
        case .ready: return "Your text has arrived securely."
        case .pasting: return "Into your selected text field."
        case .finished(let outcome): return outcome == .requested ? "Ready for your next thought." : outcome.message
        case .cancelled: return "No further paste will be requested."
        case .receivingImage: return "From the sending Mac, securely."
        case .imageReady(let width, let height): return "\(width) × \(height) pixels. Paste with ⌘V."
        case .imageCancelled: return "Check T&S on the sending Mac to retry."
        }
    }
    private var step: Int {
        switch progress {
        case .preview: return 0
        case .waiting: return 0
        case .ready, .receivingImage: return 1
        case .pasting, .finished: return 2
        case .imageReady: return 3
        case .cancelled, .imageCancelled: return -1
        }
    }
    private var isImage: Bool { switch progress { case .receivingImage, .imageReady, .imageCancelled: return true; default: return false } }
    private var manual: Bool { if case let .finished(outcome) = progress { return outcome != .requested }; return false }
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: isImage ? "photo" : "waveform").font(.system(size: 22, weight: .medium))
                    .foregroundStyle(accent).padding(.top, 2)
                VStack(alignment: .leading, spacing: 4) {
                    Text(title).font(.system(size: 14, weight: .semibold, design: .rounded))
                    Text(detail).font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
                Text("T&S").font(.system(size: 10, weight: .medium)).foregroundStyle(.secondary)
            }
            HStack(spacing: 9) {
                stage(isImage ? "Capture" : "Waiting", index: 0)
                Rectangle().fill(.quaternary).frame(height: 1)
                stage(isImage ? "Send" : "Ready", index: 1)
                Rectangle().fill(.quaternary).frame(height: 1)
                stage(isImage ? "Ready" : "Paste", index: 2)
            }
        }.padding(16).frame(width: 330, height: 126, alignment: .leading)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
            .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(.primary.opacity(0.08), lineWidth: 1))
    }
    private func stage(_ title: String, index: Int) -> some View {
        HStack(spacing: 4) {
            Image(systemName: index < step || (index == 2 && progress == .finished(.requested)) ? "checkmark.circle.fill" : manual && index == 2 ? "hand.raised.fill" : "circle")
            Text(title)
        }.font(.system(size: 10, weight: index == step ? .semibold : .regular))
            .foregroundStyle(manual && index == 2 ? Color.orange : index <= step ? success : Color.secondary)
    }
}
