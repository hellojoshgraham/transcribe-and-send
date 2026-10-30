import AppKit
import Security
import Darwin
import TSCore

public enum LocalNetwork {
    public static func tailscaleAddresses() -> [String] {
        var head: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&head) == 0 else { return [] }
        defer { freeifaddrs(head) }
        var addresses: Set<String> = []
        var cursor = head
        while let item = cursor {
            defer { cursor = item.pointee.ifa_next }
            guard let address = item.pointee.ifa_addr, address.pointee.sa_family == UInt8(AF_INET) else { continue }
            var buffer = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            if getnameinfo(address, socklen_t(address.pointee.sa_len), &buffer, socklen_t(buffer.count), nil, 0, NI_NUMERICHOST) == 0 {
                let ip = String(cString: buffer)
                if TailAddress.isValid(ip) { addresses.insert(ip) }
            }
        }
        return addresses.sorted()
    }
}

public enum KeyStore {
    private static let query: [String: Any] = [
        kSecClass as String: kSecClassGenericPassword,
        kSecAttrService as String: "au.com.instantai.transcribe-and-send",
        kSecAttrAccount as String: "pairing-key",
        kSecAttrSynchronizable as String: false
    ]

    public static func read() throws -> PairingKey? {
        var query = query
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = item as? Data else { throw error(status) }
        return try PairingKey(encoded: data.base64EncodedString())
    }

    public static func save(_ key: PairingKey) throws {
        let attributes: [String: Any] = [kSecValueData as String: key.data, kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly]
        var status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            status = SecItemAdd(query.merging(attributes) { _, new in new } as CFDictionary, nil)
        }
        guard status == errSecSuccess else { throw error(status) }
    }

    private static func error(_ status: OSStatus) -> Error {
        TSError.message("Keychain: \(SecCopyErrorMessageString(status, nil) as String? ?? String(status))")
    }
}

@MainActor
public enum Clipboard {
    public static func writePairingCode(_ code: String) -> Bool {
        let item = NSPasteboardItem()
        item.setString(code, forType: .string)
        for name in ["org.nspasteboard.TransientType", "org.nspasteboard.ConcealedType"] {
            item.setData(Data(), forType: NSPasteboard.PasteboardType(name))
        }
        NSPasteboard.general.clearContents()
        return NSPasteboard.general.writeObjects([item])
    }

    public static func write(_ screenshot: ScreenshotPNG, to pasteboard: NSPasteboard = .general) -> Bool {
        let item = NSPasteboardItem()
        guard item.setData(screenshot.data, forType: .png) else { return false }
        item.setData(Data(), forType: NSPasteboard.PasteboardType("org.nspasteboard.TransientType"))
        pasteboard.clearContents()
        return pasteboard.writeObjects([item]) && pasteboard.data(forType: .png) == screenshot.data
    }

    public static func write(_ text: String) -> Bool {
        let pasteboard = NSPasteboard.general
        let item = NSPasteboardItem()
        item.setString(text, forType: .string)
        item.setData(Data(), forType: NSPasteboard.PasteboardType("org.nspasteboard.TransientType"))
        pasteboard.clearContents()
        return pasteboard.writeObjects([item]) && pasteboard.string(forType: .string) == text
    }
}
