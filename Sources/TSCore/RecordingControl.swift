public enum RecordingMode: String, Codable, CaseIterable {
    case hold = "Hold to talk"
    case toggle = "Press to start / stop"
}

public struct WorkflowOptions: Codable, Equatable {
    public var recordingMode: RecordingMode = .hold
    public var automaticallyPaste = false
    public var allowAutomaticPaste = false
    public var showReceiverStatus = true
    public init() {}
}

public enum RecordingControl {
    public enum State { case idle, starting, recording, busy }
    public enum Action: Equatable { case start, stop, cancel }
    public static func action(for event: ShortcutGesture.Action, mode: RecordingMode, state: State) -> Action? {
        switch (event, state) {
        case (.interrupted, .starting), (.interrupted, .recording): return .cancel
        case (.pressed, .idle): return .start
        case (.pressed, .starting), (.pressed, .recording): return mode == .toggle ? .stop : nil
        case (.released, .starting), (.released, .recording): return mode == .hold ? .stop : nil
        default: return nil
        }
    }
}
