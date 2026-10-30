import Foundation

/// An explicit, sensitive exchange format; never a URL or remote command.
public struct PairingCode {
    public let address: String
    public let port: UInt16
    public let key: PairingKey
    private struct Payload: Codable { let version: Int; let address: String; let port: UInt16; let key: String }
    private static let prefix = "ts-pair:1:"

    public init(address: String, port: UInt16, key: PairingKey) throws {
        guard TailAddress.isValid(address), port > 0 else { throw TSError.message("Pairing requires a Tailscale IPv4 address and a valid port.") }
        self.address = address; self.port = port; self.key = key
    }
    public init(encoded: String) throws {
        let code = encoded.trimmingCharacters(in: .whitespacesAndNewlines)
        guard code.utf8.count <= 1024, code.hasPrefix(Self.prefix),
              let data = Data(base64Encoded: String(code.dropFirst(Self.prefix.count))),
              let payload = try? JSONDecoder().decode(Payload.self, from: data), payload.version == 1 else {
            throw TSError.message("This is not a valid T&S pairing code. Copy a new code from the other Mac.")
        }
        try self.init(address: payload.address, port: payload.port, key: PairingKey(encoded: payload.key))
    }
    public func encoded() throws -> String {
        Self.prefix + (try JSONEncoder().encode(Payload(version: 1, address: address, port: port, key: key.encoded))).base64EncodedString()
    }
}
