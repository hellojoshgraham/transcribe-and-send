/// Pure key-chord state machine. It stores only the reserved key's state, never typed text.
public struct ShortcutGesture {
    public struct Modifiers: OptionSet, Equatable {
        public let rawValue: UInt8
        public init(rawValue: UInt8) { self.rawValue = rawValue }
        public static let control = Self(rawValue: 1)
        public static let option = Self(rawValue: 2)
        public static let command = Self(rawValue: 4)
        public static let shift = Self(rawValue: 8)
    }
    public enum Event { case down(key: UInt16, repeating: Bool), up(key: UInt16), modifiersChanged }
    public enum Action: Equatable { case pressed, released, interrupted }
    public struct Decision: Equatable {
        public let consume: Bool
        public let action: Action?
        public init(consume: Bool = false, action: Action? = nil) { self.consume = consume; self.action = action }
    }

    public let key: UInt16
    public let modifiers: Modifiers
    public private(set) var ownsKey = false
    private var holding = false
    public init(key: UInt16, modifiers: Modifiers) { self.key = key; self.modifiers = modifiers }

    public mutating func handle(_ event: Event, modifiers current: Modifiers) -> Decision {
        switch event {
        case let .down(key, repeating) where key == self.key:
            if ownsKey { return Decision(consume: true) }
            guard !repeating, current == modifiers else { return Decision() }
            ownsKey = true; holding = true
            return Decision(consume: true, action: .pressed)
        case let .up(key) where key == self.key && ownsKey:
            let action: Action? = holding ? .released : nil
            ownsKey = false; holding = false
            return Decision(consume: true, action: action)
        case .modifiersChanged where holding && !current.isSuperset(of: modifiers):
            // Release may arrive in any order. Forward modifier transitions so Jump has balanced modifier state.
            holding = false
            return Decision(action: .released)
        default: return Decision()
        }
    }

    /// Losing input access cancels dictation, never treats it as a deliberate release/send.
    public mutating func interrupt(keyStillDown: Bool) -> Decision {
        let action: Action? = holding ? .interrupted : nil
        holding = false
        if !keyStillDown { ownsKey = false }
        return Decision(action: action)
    }
}
