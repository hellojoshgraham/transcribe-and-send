// Standalone opt-in test fixture. Its Paste action reads a private pasteboard,
// so the real Command-V path can be tested without touching the user's clipboard.
import AppKit

final class TestTextView: NSTextView {
    var returnCount = 0
    override func keyDown(with event: NSEvent) {
        if event.keyCode == 36 || event.keyCode == 76 { returnCount += 1 }
        // Only the menu's Paste action inserts fixture text. Ignore incidental
        // typing during this briefly focused test instead of retaining it.
    }
    override func paste(_ sender: Any?) {
        guard let name = ProcessInfo.processInfo.environment["TS_TEST_BOARD"],
              let output = ProcessInfo.processInfo.environment["TS_TEST_OUTPUT"],
              let text = NSPasteboard(name: .init(name)).string(forType: .string) else { return }
        insertText(text, replacementRange: selectedRange())
        let result: [String: Any] = ["text": string, "returns": returnCount]
        if let data = try? JSONSerialization.data(withJSONObject: result) { try? data.write(to: URL(fileURLWithPath: output), options: .atomic) }
    }
}

let app = NSApplication.shared
app.setActivationPolicy(.regular)
let menu = NSMenu()
let appItem = NSMenuItem(); appItem.submenu = NSMenu(title: "T&S test"); menu.addItem(appItem)
let item = NSMenuItem(); let edit = NSMenu(title: "Edit")
edit.autoenablesItems = false // The fixture reads a private, not general, pasteboard.
let paste = NSMenuItem(title: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
paste.keyEquivalentModifierMask = .command
edit.addItem(paste); item.submenu = edit; menu.addItem(item); app.mainMenu = menu
let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 480, height: 160), styleMask: [.titled, .closable], backing: .buffered, defer: false)
window.title = "T&S isolated paste test"
let field = TestTextView(frame: window.contentView!.bounds)
paste.target = field; paste.isEnabled = true
field.isEditable = true; field.isSelectable = true; field.font = .systemFont(ofSize: 18)
field.textContainerInset = NSSize(width: 20, height: 20)
window.contentView = field
window.center(); window.makeKeyAndOrderFront(nil); window.makeFirstResponder(field)
app.activate(ignoringOtherApps: true)
app.run()
