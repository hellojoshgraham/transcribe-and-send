import Foundation

/// Metadata shape verified against Superwhisper 2.19.3. Unknown/missing fields fail closed.
public struct TranscriptMetadata: Decodable {
    public let result: String
    public let duration: Double
    public let realtimeEnabled: Bool
    public let recordingDevice: String
    public let modeName: String
}

public struct TranscriptGate {
    private let baseline: Set<String>
    private let initialClipboardCount: Int
    private var previousCandidate: String?
    private var candidateSince: Date?

    public init(baseline: Set<String>, clipboardCount: Int) {
        self.baseline = baseline; initialClipboardCount = clipboardCount
    }

    /// A fresh single recording AND its final clipboard output must agree. Never relay arbitrary clipboard changes.
    public mutating func evaluate(recordings: [String: Data], clipboardText: String?, clipboardCount: Int, now: Date = Date()) throws -> TranscriptMetadata? {
        let newIDs = Set(recordings.keys).subtracting(baseline)
        guard newIDs.count <= 1 else { throw TSError.message("Multiple recordings appeared. Nothing was sent; finish other Superwhisper recordings and try again.") }
        guard let id = newIDs.first, let data = recordings[id],
              let metadata = try? JSONDecoder().decode(TranscriptMetadata.self, from: data),
              !metadata.result.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            resetCandidate(); return nil
        }
        guard !metadata.realtimeEnabled else { throw TSError.message("Turn off Realtime in Superwhisper for T&S. Streaming output cannot be sent safely.") }
        guard clipboardCount != initialClipboardCount, clipboardText == metadata.result else { resetCandidate(); return nil }
        try WireCodec.validateText(metadata.result)
        let candidate = id + ":" + WireCodec.digest(metadata.result)
        if candidate != previousCandidate { previousCandidate = candidate; candidateSince = now; return nil }
        guard let candidateSince, now.timeIntervalSince(candidateSince) >= 0.5 else { return nil }
        return metadata
    }

    private mutating func resetCandidate() { previousCandidate = nil; candidateSince = nil }
}
