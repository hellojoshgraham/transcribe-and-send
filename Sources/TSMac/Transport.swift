import Foundation
import Network
import AppKit
import TSCore

/// Network.framework callbacks and all state are confined to the main actor.
@MainActor
final class SecureChannel {
    let connection: NWConnection
    let key: PairingKey
    private var deadline: DispatchWorkItem?
    private var readiness: CheckedContinuation<Void, Error>?
    private var terminalError: Error?
    private(set) var isClosed = false

    init(connection: NWConnection, key: PairingKey) { self.connection = connection; self.key = key }

    func start(timeout: TimeInterval = 12) async throws {
        if let terminalError { throw terminalError }
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            readiness = continuation
            connection.stateUpdateHandler = { [weak self] state in
                MainActor.assumeIsolated {
                    guard let self, let continuation = self.readiness else { return }
                    switch state {
                    case .ready: self.readiness = nil; continuation.resume()
                    case .failed(let error): self.readiness = nil; continuation.resume(throwing: error)
                    case .cancelled: self.readiness = nil; continuation.resume(throwing: TSError.message("Connection timed out or was cancelled. Check Tailscale and the receiver."))
                    default: break
                    }
                }
            }
            setDeadline(seconds: timeout)
            connection.start(queue: .main)
        }
    }

    func setDeadline(seconds: TimeInterval) {
        deadline?.cancel()
        guard !isClosed else { return }
        let timeout = DispatchWorkItem { [weak self] in
            self?.close(error: TSError.message("Connection timed out. Check that Tailscale is connected and T&S is receiving on the other Mac."))
        }
        deadline = timeout
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds, execute: timeout)
    }

    func send(_ message: WireMessage) async throws {
        if let terminalError { throw terminalError }
        let frame: Data
        if message.kind == .image {
            let key = key
            frame = try await Task.detached(priority: .userInitiated) {
                try WireCodec.frame(WireCodec.seal(message, key: key, maximumBytes: WireCodec.maxImageFrameBytes), maximumBytes: WireCodec.maxImageFrameBytes)
            }.value
        } else { frame = try WireCodec.frame(WireCodec.seal(message, key: key)) }
        try Task.checkCancellation()
        if let terminalError { throw terminalError }
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            connection.send(content: frame, completion: .contentProcessed { error in
                MainActor.assumeIsolated {
                    if let error = self.terminalError ?? error { continuation.resume(throwing: error) }
                    else { continuation.resume() }
                }
            })
        }
    }

    func receive(maximumBytes: Int = WireCodec.maxFrameBytes) async throws -> WireMessage {
        let size = try WireCodec.frameLength(await read(count: 4), maximumBytes: maximumBytes)
        let data = try await read(count: size)
        if maximumBytes > WireCodec.maxFrameBytes {
            let key = key
            return try await Task.detached(priority: .userInitiated) { try WireCodec.open(data, key: key, maximumBytes: maximumBytes) }.value
        }
        return try WireCodec.open(data, key: key)
    }

    private func read(count: Int) async throws -> Data {
        if let terminalError { throw terminalError }
        return try await withCheckedThrowingContinuation { continuation in
            connection.receive(minimumIncompleteLength: count, maximumLength: count) { data, _, _, error in
                MainActor.assumeIsolated {
                    if let error = self.terminalError ?? error { continuation.resume(throwing: error) }
                    else if let data, data.count == count { continuation.resume(returning: data) }
                    else { continuation.resume(throwing: TSError.message("The receiving Mac closed the connection before confirming delivery.")) }
                }
            }
        }
    }

    func close(error: Error = CancellationError()) {
        guard !isClosed else { return }
        terminalError = error
        isClosed = true
        deadline?.cancel(); deadline = nil
        let pending = readiness; readiness = nil
        connection.stateUpdateHandler = nil; connection.cancel()
        // Removing the state callback must not leave start() suspended forever.
        pending?.resume(throwing: error)
    }
}

@MainActor
public final class ClipboardClient {
    private var channel: SecureChannel?
    private var automaticContext: (challenge: UUID, requestID: UUID)?
    public var automaticDeliveryReady: Bool { automaticContext != nil }
    public init() {}
    public func cancel() { channel?.close(); channel = nil; automaticContext = nil }

    public func sendScreenshot(_ screenshot: ScreenshotPNG, host: String, port: UInt16, key: PairingKey) async throws {
        guard TailAddress.isValid(host) else { throw TSError.message("Use the target Mac’s Tailscale IPv4 address (100.x.x.x).") }
        try await imageExchange(screenshot, host: host, port: port, key: key)
    }

    func imageExchange(_ screenshot: ScreenshotPNG, host: String, port: UInt16, key: PairingKey) async throws {
        guard channel == nil, port > 0 else { throw TSError.message("A transfer is already in progress or the port is invalid.") }
        let channel = SecureChannel(connection: NWConnection(host: .init(host), port: .init(rawValue: port)!, using: .tcp), key: key)
        self.channel = channel
        defer { channel.close(); if self.channel === channel { self.channel = nil } }
        try await channel.start()
        let greeting = try await channel.receive()
        guard greeting.kind == .challenge, greeting.capabilities?.contains("pngClipboard-v1") == true else {
            throw TSError.message("Update T&S on the receiving Mac to copy screenshots. The screenshot is still on this Mac’s clipboard.")
        }
        let requestID = UUID()
        var preparation = WireMessage(kind: .prepareImage, challenge: greeting.challenge)
        preparation.version = 2; preparation.requestID = requestID
        try await channel.send(preparation)
        let ready = try await channel.receive()
        guard ready.kind == .imagePrepared, ready.version == 2, ready.challenge == greeting.challenge,
              ready.requestID == requestID, ready.success == true else { throw TSError.message("The receiving Mac could not prepare its screenshot clipboard.") }
        try Task.checkCancellation()
        guard self.channel === channel else { throw CancellationError() }
        channel.setDeadline(seconds: 45)
        var request = WireMessage(kind: .image, challenge: greeting.challenge, digest: WireCodec.imageDigest(screenshot.data))
        request.version = 2; request.requestID = requestID; request.contentType = "public.png"; request.imageData = screenshot.data
        try await channel.send(request)
        let receipt = try await channel.receive()
        try WireCodec.verifyImageReceipt(receipt, challenge: greeting.challenge, requestID: requestID, png: screenshot.data)
    }

    public func prepareAutomaticDelivery(host: String, port: UInt16, key: PairingKey) async throws {
        guard TailAddress.isValid(host) else { throw TSError.message("Use the target Mac’s Tailscale IPv4 address (100.x.x.x).") }
        try await prepareAutomaticExchange(host: host, port: port, key: key)
    }

    func prepareAutomaticExchange(host: String, port: UInt16, key: PairingKey) async throws {
        guard channel == nil, port > 0 else { throw TSError.message("A transfer is already in progress or the port is invalid.") }
        let channel = SecureChannel(connection: NWConnection(host: .init(host), port: .init(rawValue: port)!, using: .tcp), key: key)
        self.channel = channel
        do {
            try await channel.start()
            let greeting = try await channel.receive()
            guard greeting.kind == .challenge, greeting.capabilities?.contains("automaticPaste-v1") == true else {
                throw TSError.message("Update T&S on the receiving Mac to use automatic paste.")
            }
            let requestID = UUID()
            var request = WireMessage(kind: .preparePaste, challenge: greeting.challenge)
            request.requestID = requestID
            try await channel.send(request)
            let reply = try await channel.receive()
            guard reply.kind == .prepared, reply.challenge == greeting.challenge, reply.requestID == requestID, reply.success == true else {
                throw TSError.message("The receiver could not prepare automatic paste.")
            }
            try Task.checkCancellation()
            guard self.channel === channel else { throw CancellationError() }
            channel.setDeadline(seconds: 110)
            automaticContext = (greeting.challenge, requestID)
        } catch {
            channel.close()
            if self.channel === channel { self.channel = nil; automaticContext = nil }
            throw error
        }
    }

    public func sendAutomatically(_ text: String, permitPaste: () -> Bool) async throws -> PasteOutcome {
        guard let channel, let context = automaticContext else { throw TSError.message("Automatic paste was not prepared.") }
        defer {
            channel.close()
            if self.channel === channel { self.channel = nil; automaticContext = nil }
        }
        try WireCodec.validateText(text)
        try Task.checkCancellation()
        channel.setDeadline(seconds: 12)
        var request = WireMessage(kind: .text, challenge: context.challenge, text: text)
        request.requestID = context.requestID
        try await channel.send(request)
        let ready = try await channel.receive()
        try WireCodec.verifyReceipt(ready, challenge: context.challenge, text: text)
        guard ready.requestID == context.requestID else { throw TSError.message("The clipboard receipt belongs to another dictation.") }
        try Task.checkCancellation()
        // The paste command is sent only after the exact clipboard write is acknowledged.
        var paste = WireMessage(kind: .paste, challenge: context.challenge, digest: WireCodec.digest(text))
        paste.requestID = context.requestID; paste.pasteRequested = permitPaste()
        try await channel.send(paste)
        let reply = try await channel.receive()
        guard reply.kind == .pasteReceipt, reply.challenge == context.challenge, reply.requestID == context.requestID,
              reply.digest == paste.digest, reply.success == true, let outcome = reply.pasteOutcome else {
            throw TSError.message("The receiver did not confirm the paste request. It may already have pasted; retry only copies to its clipboard.")
        }
        return outcome
    }

    public func send(text: String?, host: String, port: UInt16, key: PairingKey) async throws {
        guard TailAddress.isValid(host) else { throw TSError.message("Use the target Mac’s Tailscale IPv4 address (100.x.x.x).") }
        try await exchange(text: text, host: host, port: port, key: key)
    }

    // Internal loopback entry point is used by integration tests; the app calls validated send().
    func exchange(text: String?, host: String, port: UInt16, key: PairingKey) async throws {
        guard channel == nil, port > 0 else { throw TSError.message("A transfer is already in progress or the port is invalid.") }
        if let text { try WireCodec.validateText(text) }
        let connection = NWConnection(host: NWEndpoint.Host(host), port: NWEndpoint.Port(rawValue: port)!, using: .tcp)
        let channel = SecureChannel(connection: connection, key: key)
        self.channel = channel
        defer { channel.close(); if self.channel === channel { self.channel = nil } }
        try await channel.start()
        let greeting = try await channel.receive()
        guard greeting.kind == .challenge else { throw TSError.message("The receiver returned an invalid challenge.") }
        try await channel.send(WireMessage(kind: text == nil ? .probe : .text, challenge: greeting.challenge, text: text))
        let receipt = try await channel.receive()
        try WireCodec.verifyReceipt(receipt, challenge: greeting.challenge, text: text)
    }
}

public enum ReceiverProgress: Equatable {
    case preview
    case waiting, ready, pasting, finished(PasteOutcome), cancelled
    case receivingImage, imageReady(width: Int, height: Int), imageCancelled
}

public typealias PasteAttempt = @MainActor (String, Int, () -> Bool) async -> PasteOutcome

@MainActor
public final class ClipboardReceiver {
    private var listener: NWListener?
    private var channels: [UUID: SecureChannel] = [:]
    private var runID = UUID()
    var listeningPort: UInt16? { listener?.port?.rawValue }
    public var onState: ((String, Bool) -> Void)?
    public var onReceived: (() -> Void)?
    public var onProgress: ((ReceiverProgress) -> Void)?
    public var preparePaste: (() -> PasteAttempt)?
    private let writeClipboard: (String) -> Bool
    private let clipboardRevision: () -> Int
    public var onActivityChanged: (() -> Void)?
    public var deliveryInProgress: Bool { automaticOwner != nil || imageOwner != nil || !textOwners.isEmpty }
    private var automaticOwner: UUID? { didSet { if oldValue != automaticOwner { onActivityChanged?() } } }
    private var imageOwner: UUID? { didSet { if oldValue != imageOwner { onActivityChanged?() } } }
    private var textOwners: Set<UUID> = [] { didSet { if oldValue != textOwners { onActivityChanged?() } } }
    private let writeImage: @MainActor (ScreenshotPNG) -> Bool

    public init(writeClipboard: @escaping (String) -> Bool, clipboardRevision: @escaping () -> Int = { NSPasteboard.general.changeCount }, writeImage: @escaping @MainActor (ScreenshotPNG) -> Bool = { Clipboard.write($0) }) {
        self.writeClipboard = writeClipboard; self.clipboardRevision = clipboardRevision; self.writeImage = writeImage
    }

    public func start(localIP: String, allowedPeer: String, port: UInt16, key: PairingKey) throws {
        guard TailAddress.isValid(localIP), TailAddress.isValid(allowedPeer), localIP != allowedPeer, port > 0 else {
            throw TSError.message("Enter this Mac’s and the sending Mac’s different Tailscale IPv4 addresses.")
        }
        guard LocalNetwork.tailscaleAddresses().contains(localIP) else {
            throw TSError.message("This Tailscale address is not active on this Mac. Connect Tailscale, then start receiving again.")
        }
        try listen(localIP: localIP, allowedPeer: allowedPeer, port: port, key: key)
    }

    func listen(localIP: String, allowedPeer: String, port: UInt16, key: PairingKey) throws {
        stop()
        guard let endpointPort = NWEndpoint.Port(rawValue: port) else { throw TSError.message("Invalid port.") }
        let generation = runID
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: NWEndpoint.Host(localIP), port: endpointPort)
        let listener = try NWListener(using: parameters)
        self.listener = listener
        listener.stateUpdateHandler = { [weak self] state in
            MainActor.assumeIsolated {
            guard self?.runID == generation else { return }
            switch state {
            case .ready: self?.onState?("Ready to receive", true)
            case .failed(let error): self?.onState?("Receiver stopped: \(error.localizedDescription)", false); self?.stop()
            case .waiting: self?.onState?("Waiting for Tailscale", false)
            default: break
            }
            }
        }
        listener.newConnectionHandler = { [weak self] connection in
            MainActor.assumeIsolated {
            guard let self, self.runID == generation, self.channels.count < 4,
                  case let .hostPort(host, _) = connection.endpoint,
                  String(describing: host) == allowedPeer else { connection.cancel(); return }
            let id = UUID()
            let channel = SecureChannel(connection: connection, key: key)
            self.channels[id] = channel
            Task { @MainActor in
                defer { channel.close(); self.channels.removeValue(forKey: id); self.textOwners.remove(id) }
                do {
                    try await channel.start()
                    // A new random challenge for every TCP connection prevents replay, including after restart.
                    let challenge = UUID()
                    var greeting = WireMessage(kind: .challenge, challenge: challenge)
                    greeting.capabilities = ["automaticPaste-v1", "pngClipboard-v1"]
                    try await channel.send(greeting)
                    let request = try await channel.receive()
                    guard self.runID == generation, request.challenge == challenge else { throw TSError.message("Invalid challenge or stopped receiver.") }
                    let success: Bool
                    switch request.kind {
                    case .prepareImage:
                        try await self.receiveImage(channel: channel, request: request, owner: id, generation: generation)
                        return
                    case .preparePaste:
                        try await self.receiveAutomatic(channel: channel, request: request, owner: id, generation: generation)
                        return
                    case .probe:
                        guard request.text == nil else { throw TSError.message("Invalid probe.") }
                        success = true
                    case .text:
                        guard self.imageOwner == nil, let text = request.text, request.requestID == nil else { throw TSError.message("Missing text or unexpected dictation session.") }
                        try WireCodec.validateText(text)
                        self.textOwners.insert(id)
                        success = self.writeClipboard(text)
                        if success { self.onReceived?() }
                    default: throw TSError.message("Invalid request.")
                    }
                    try await channel.send(WireMessage(kind: .receipt, challenge: challenge, digest: request.text.map(WireCodec.digest), success: success))
                } catch {
                    // No payload, credentials, or unauthenticated peer error is logged or surfaced in the UI.
                }
            }
            }
        }
        listener.start(queue: .main)
    }

    private func receiveAutomatic(channel: SecureChannel, request: WireMessage, owner: UUID, generation: UUID) async throws {
        guard automaticOwner == nil, imageOwner == nil, let requestID = request.requestID, request.text == nil else {
            throw TSError.message("Another automatic delivery is active or the request is invalid.")
        }
        automaticOwner = owner
        var finished = false
        defer {
            if automaticOwner == owner {
                automaticOwner = nil
                if !finished, runID == generation { onProgress?(.cancelled) }
            }
        }
        // Capture focus before showing the nonactivating status panel.
        let attempt = preparePaste?() ?? { _, _, _ in .disabled }
        onProgress?(.waiting)
        channel.setDeadline(seconds: 110) // Extended only after authenticated preparation.
        var prepared = WireMessage(kind: .prepared, challenge: request.challenge, success: true)
        prepared.requestID = requestID
        try await channel.send(prepared)
        let textRequest = try await channel.receive()
        guard runID == generation, automaticOwner == owner, textRequest.kind == .text, textRequest.challenge == request.challenge,
              textRequest.requestID == requestID, let text = textRequest.text else { throw TSError.message("Invalid dictation session.") }
        try WireCodec.validateText(text)
        let written = writeClipboard(text)
        let revision = clipboardRevision()
        var ready = WireMessage(kind: .receipt, challenge: request.challenge, digest: WireCodec.digest(text), success: written)
        ready.requestID = requestID
        if written { onReceived?(); onProgress?(.ready) }
        channel.setDeadline(seconds: 12)
        try await channel.send(ready)
        guard written else { return }
        let paste = try await channel.receive()
        guard runID == generation, automaticOwner == owner, paste.kind == .paste, paste.challenge == request.challenge,
              paste.requestID == requestID, paste.digest == ready.digest, paste.text == nil,
              let requested = paste.pasteRequested else { throw TSError.message("Invalid paste request.") }
        let outcome: PasteOutcome
        if requested {
            onProgress?(.pasting)
            outcome = await attempt(text, revision) { self.runID == generation && self.automaticOwner == owner && !channel.isClosed }
        } else { outcome = .senderFocusChanged }
        guard runID == generation, automaticOwner == owner else { return }
        onProgress?(.finished(outcome)); finished = true
        var receipt = WireMessage(kind: .pasteReceipt, challenge: request.challenge, digest: ready.digest, success: true)
        receipt.requestID = requestID; receipt.pasteOutcome = outcome
        try await channel.send(receipt)
        // This connection processes exactly one paste command, then closes.
        // A failed receipt is never followed by an automatic retry.
    }

    private func receiveImage(channel: SecureChannel, request: WireMessage, owner: UUID, generation: UUID) async throws {
        guard imageOwner == nil, automaticOwner == nil, request.version == 2, let requestID = request.requestID,
              request.imageData == nil, request.text == nil else { throw TSError.message("Another delivery is active or the screenshot request is invalid.") }
        imageOwner = owner
        var finished = false
        defer {
            if imageOwner == owner {
                imageOwner = nil
                if !finished, runID == generation { onProgress?(.imageCancelled) }
            }
        }
        onProgress?(.receivingImage)
        channel.setDeadline(seconds: 45)
        var ready = WireMessage(kind: .imagePrepared, challenge: request.challenge, success: true)
        ready.version = 2; ready.requestID = requestID
        try await channel.send(ready)
        // No larger allocation is accepted until a valid authenticated preparation.
        let payload = try await channel.receive(maximumBytes: WireCodec.maxImageFrameBytes)
        guard runID == generation, imageOwner == owner, payload.kind == .image, payload.version == 2,
              payload.challenge == request.challenge, payload.requestID == requestID, payload.contentType == "public.png",
              payload.text == nil, let data = payload.imageData, data.count <= WireCodec.maxImageBytes,
              payload.digest == WireCodec.imageDigest(data) else { throw TSError.message("Invalid screenshot payload.") }
        let screenshot = try await Task.detached(priority: .userInitiated) { try ScreenshotPNG.validate(data) }.value
        guard runID == generation, imageOwner == owner, !channel.isClosed else { return }
        let written = writeImage(screenshot)
        if written { onProgress?(.imageReady(width: screenshot.width, height: screenshot.height)); finished = true }
        var receipt = WireMessage(kind: .imageReceipt, challenge: request.challenge, digest: payload.digest, success: written)
        receipt.version = 2; receipt.requestID = requestID; receipt.contentType = "public.png"
        try await channel.send(receipt)
        // Images are clipboard-only. No automatic-paste path is reachable here.
    }

    public func cancelImageDelivery() {
        guard let owner = imageOwner else { return }
        imageOwner = nil; channels[owner]?.connection.cancel(); onProgress?(.imageCancelled)
    }

    public func cancelAutomaticDelivery() {
        guard let owner = automaticOwner else { return }
        automaticOwner = nil
        channels[owner]?.connection.cancel()
        onProgress?(.cancelled)
    }

    public func stop() {
        runID = UUID()
        textOwners.removeAll()
        if automaticOwner != nil { automaticOwner = nil; onProgress?(.cancelled) }
        if imageOwner != nil { imageOwner = nil; onProgress?(.imageCancelled) }
        listener?.stateUpdateHandler = nil; listener?.newConnectionHandler = nil
        listener?.cancel(); listener = nil
        for channel in channels.values { channel.connection.cancel() }
    }
}
