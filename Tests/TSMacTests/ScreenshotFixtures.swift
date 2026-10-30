import Foundation
import CoreGraphics
import ImageIO
import XCTest

enum ScreenshotFixtures {
    static func png(width: Int = 64, height: Int = 32, noisy: Bool = false, description: String? = nil) throws -> Data {
        var pixels = [UInt8](repeating: 255, count: width * height * 4)
        var seed: UInt32 = 7381
        for index in stride(from: 0, to: pixels.count, by: 4) {
            for component in 0..<3 {
                seed = seed &* 1_664_525 &+ 1_013_904_223
                pixels[index + component] = noisy ? UInt8(truncatingIfNeeded: seed >> 24) : [80, 110, 200][component]
            }
        }
        let image = try pixels.withUnsafeMutableBytes { buffer -> CGImage in
            let context = try XCTUnwrap(CGContext(data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8,
                                                 bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
            return try XCTUnwrap(context.makeImage())
        }
        let output = NSMutableData()
        let destination = try XCTUnwrap(CGImageDestinationCreateWithData(output, "public.png" as CFString, 1, nil))
        let properties: [CFString: Any] = description.map { [kCGImagePropertyPNGDictionary: [kCGImagePropertyPNGDescription: $0]] } ?? [:]
        CGImageDestinationAddImage(destination, image, properties as CFDictionary)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        return output as Data
    }

    static func oversizedHeader(width: UInt32 = 16_385, height: UInt32 = 32) throws -> Data {
        var bytes = try png()
        bytes.replaceSubrange(16..<20, with: withUnsafeBytes(of: width.bigEndian, Array.init))
        bytes.replaceSubrange(20..<24, with: withUnsafeBytes(of: height.bigEndian, Array.init))
        var crc: UInt32 = 0xffffffff
        for byte in bytes[12..<29] {
            crc ^= UInt32(byte)
            for _ in 0..<8 { crc = (crc >> 1) ^ (crc & 1 == 1 ? 0xedb88320 : 0) }
        }
        crc ^= 0xffffffff
        bytes.replaceSubrange(29..<33, with: withUnsafeBytes(of: crc.bigEndian, Array.init))
        return bytes
    }
}
