import XCTest
import AppKit
import ImageIO
import TSCore
@testable import TSMac

final class ScreenshotPNGTests: XCTestCase {
    func testPNGDecodesAndNormalizationRemovesSourceMetadata() throws {
        let original = try ScreenshotFixtures.png(description: "private-fixture-metadata")
        let originalSource = try XCTUnwrap(CGImageSourceCreateWithData(original as CFData, nil))
        let originalProperties = try XCTUnwrap(CGImageSourceCopyPropertiesAtIndex(originalSource, 0, nil) as? [String: Any])
        XCTAssertEqual((originalProperties[kCGImagePropertyPNGDictionary as String] as? [String: Any])?[kCGImagePropertyPNGDescription as String] as? String, "private-fixture-metadata")
        let image = try ScreenshotPNG.normalize(original)
        XCTAssertEqual(image.width, 64); XCTAssertEqual(image.height, 32)
        let source = try XCTUnwrap(CGImageSourceCreateWithData(image.data as CFData, nil))
        let properties = try XCTUnwrap(CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [String: Any])
        XCTAssertNil((properties[kCGImagePropertyPNGDictionary as String] as? [String: Any])?[kCGImagePropertyPNGDescription as String])
        XCTAssertEqual(try ScreenshotPNG.validate(image.data), image)
    }

    func testMalformedTruncatedAndNonPNGImagesAreRejected() throws {
        let png = try ScreenshotFixtures.png()
        var corruptCRC = png; corruptCRC[29] ^= 1
        for bytes in [Data(), Data("not an image".utf8), Data(png.prefix(50)), Data(png.dropLast(40)), corruptCRC, Data(base64Encoded: "R0lGODlhAQABAIAAAAAAAP///ywAAAAAAQABAAACAUwAOw==")!] {
            XCTAssertThrowsError(try ScreenshotPNG.validate(bytes))
        }
    }

    func testByteAndPixelLimitsApplyBeforeDecode() throws {
        XCTAssertThrowsError(try ScreenshotPNG.validate(Data(repeating: 0, count: WireCodec.maxImageBytes + 1)))
        XCTAssertThrowsError(try ScreenshotPNG.validate(ScreenshotFixtures.oversizedHeader())) { error in
            XCTAssertTrue(error.localizedDescription.contains("32 megapixels"), "Dimensions must be checked before decoding image pixels")
        }
        XCTAssertThrowsError(try ScreenshotPNG.validate(ScreenshotFixtures.oversizedHeader(width: 8000, height: 8000))) { error in
            XCTAssertTrue(error.localizedDescription.contains("32 megapixels"))
        }
    }

    @MainActor func testNativeClipboardStoresReadablePNGWithoutFileOrTextFlavors() throws {
        let board = NSPasteboard(name: .init("ts-image-test-\(UUID())"))
        defer { board.releaseGlobally() }
        let image = try ScreenshotPNG.normalize(ScreenshotFixtures.png())
        XCTAssertTrue(Clipboard.write(image, to: board))
        XCTAssertEqual(board.data(forType: .png), image.data)
        XCTAssertNotNil(NSImage(pasteboard: board), "The received clipboard must be usable by native image consumers")
        XCTAssertNil(board.data(forType: .fileURL)); XCTAssertNil(board.string(forType: .string))
    }
}
