import Foundation
import CoreGraphics
import ImageIO
import zlib
import TSCore

/// One bounded, fully decoded PNG. File paths and arbitrary image formats never cross the network.
public struct ScreenshotPNG: Sendable, Equatable {
    public static let maxDimension = 16_384
    public static let maxPixels = 32_000_000
    public let data: Data
    public let width: Int
    public let height: Int

    private init(data: Data, width: Int, height: Int) { self.data = data; self.width = width; self.height = height }

    public static func validate(_ data: Data) throws -> ScreenshotPNG {
        let image = try decode(data)
        return ScreenshotPNG(data: data, width: image.width, height: image.height)
    }

    /// Re-encode capture pixels without the source's EXIF, text, or file metadata.
    public static func normalize(_ data: Data) throws -> ScreenshotPNG {
        let image = try decode(data)
        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(output, "public.png" as CFString, 1, nil) else {
            throw TSError.message("Could not encode this screenshot.")
        }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination), output.length <= WireCodec.maxImageBytes else {
            throw TSError.message("This screenshot exceeds 16 MB. Select a smaller region.")
        }
        return ScreenshotPNG(data: output as Data, width: image.width, height: image.height)
    }

    private static func decode(_ data: Data) throws -> CGImage {
        guard data.count <= WireCodec.maxImageBytes else { throw TSError.message("This screenshot exceeds 16 MB. Select a smaller region.") }
        try validateContainer(data)
        guard let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary),
              CGImageSourceGetType(source) as String? == "public.png", CGImageSourceGetCount(source) == 1,
              CGImageSourceGetStatus(source) == .statusComplete,
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int,
              let depth = properties[kCGImagePropertyDepth] as? Int, (1...8).contains(depth) else {
            throw TSError.message("The screenshot is not a complete, single PNG image.")
        }
        try validateDimensions(width: width, height: height)
        guard let image = CGImageSourceCreateImageAtIndex(source, 0, [kCGImageSourceShouldCacheImmediately: true] as CFDictionary),
              CGImageSourceGetStatusAtIndex(source, 0) == .statusComplete,
              image.width == width, image.height == height else { throw TSError.message("The screenshot could not be decoded completely.") }
        return image
    }

    private static func validateDimensions(width: Int, height: Int) throws {
        guard width > 0, height > 0, width <= maxDimension, height <= maxDimension, width <= maxPixels / height else {
            throw TSError.message("This screenshot exceeds 32 megapixels or 16,384 pixels on one side. Select a smaller region.")
        }
    }

    private static func validateContainer(_ data: Data) throws {
        let invalid = TSError.message("The screenshot is not a complete, single PNG image.")
        guard data.starts(with: [137, 80, 78, 71, 13, 10, 26, 10]) else { throw invalid }
        try data.withUnsafeBytes { (bytes: UnsafeRawBufferPointer) in
            func word(_ offset: Int) -> UInt32 {
                (0..<4).reduce(UInt32(0)) { ($0 << 8) | UInt32(bytes[offset + $1]) }
            }
            var offset = 8, chunks = 0
            var hasPixels = false
            while offset <= bytes.count - 12 {
                chunks += 1
                let count = Int(word(offset)), kind = word(offset + 4)
                guard chunks <= 2048, count <= bytes.count - offset - 12 else { throw invalid }
                let pointer = bytes.baseAddress!.advanced(by: offset + 4).assumingMemoryBound(to: UInt8.self)
                guard UInt32(truncatingIfNeeded: crc32(0, pointer, uInt(count + 4))) == word(offset + count + 8) else { throw invalid }
                if chunks == 1 {
                    guard kind == 0x49484452, count == 13 else { throw invalid } // IHDR
                    // Check the declared allocation before even constructing an ImageIO source.
                    try validateDimensions(width: Int(word(offset + 8)), height: Int(word(offset + 12)))
                }
                else if kind == 0x49484452 { throw invalid }
                // Reject APNG even if the platform decoder reports only its first frame.
                guard ![0x6163544c, 0x6663544c, 0x66644154].contains(kind) else { throw invalid }
                if kind == 0x49444154 { hasPixels = true } // IDAT
                offset += count + 12
                if kind == 0x49454e44 { // IEND is required; ImageIO tolerates some truncated PNGs.
                    guard count == 0, hasPixels, offset == bytes.count else { throw invalid }
                    return
                }
            }
            throw invalid
        }
    }
}
