import Carbon
import TSCore

/// Physical key codes, not typed characters. Labels use the US key layout.
public struct ModeShortcut: Codable, Equatable {
    public var keyCode: UInt16
    public var modifierMask: UInt8
    public init(keyCode: UInt16 = 1, modifierMask: UInt8 = 14) {
        self.keyCode = keyCode; self.modifierMask = modifierMask
    }
    public static let standard = ModeShortcut()
    public static let keys: [(code: UInt16, name: String)] = [
        (0,"A"),(11,"B"),(8,"C"),(2,"D"),(14,"E"),(3,"F"),(5,"G"),(4,"H"),(34,"I"),
        (38,"J"),(40,"K"),(37,"L"),(46,"M"),(45,"N"),(31,"O"),(35,"P"),(12,"Q"),
        (15,"R"),(1,"S"),(17,"T"),(32,"U"),(9,"V"),(13,"W"),(7,"X"),(16,"Y"),(6,"Z"),
        (29,"0"),(18,"1"),(19,"2"),(20,"3"),(21,"4"),(23,"5"),(22,"6"),(26,"7"),(28,"8"),(25,"9"),
        (49,"Space"),(122,"F1"),(120,"F2"),(99,"F3"),(118,"F4"),(96,"F5"),(97,"F6"),
        (98,"F7"),(100,"F8"),(101,"F9"),(109,"F10"),(103,"F11"),(111,"F12")
    ]
    public var label: String {
        let symbols: [(UInt8, String)] = [(1,"⌃"),(2,"⌥"),(8,"⇧"),(4,"⌘")]
        return (symbols.filter { modifierMask & $0.0 != 0 }.map(\.1) + [Self.keys.first { $0.code == keyCode }?.name ?? "?"]).joined(separator: " ")
    }
    var modifiers: ShortcutGesture.Modifiers { .init(rawValue: modifierMask) }
    var carbonModifiers: UInt32 {
        var result: UInt32 = 0
        if modifierMask & 1 != 0 { result |= UInt32(controlKey) }
        if modifierMask & 2 != 0 { result |= UInt32(optionKey) }
        if modifierMask & 4 != 0 { result |= UInt32(cmdKey) }
        if modifierMask & 8 != 0 { result |= UInt32(shiftKey) }
        return result
    }
    public func validate(voice: Shortcut?, screenshots: Bool) throws {
        guard Self.keys.contains(where: { $0.code == keyCode }), modifierMask & ~15 == 0,
              modifierMask & 7 != 0 else { throw TSError.message("Use Command, Option or Control with a key for the mode shortcut.") }
        guard !(keyCode == voice?.key && modifiers == voice?.modifiers),
              !(screenshots && keyCode == UInt16(kVK_ANSI_3) && modifiers == [.command, .shift]) else {
            throw TSError.message("Choose a mode shortcut different from the voice and screenshot shortcuts.")
        }
    }
}
