import XCTest
import AppKit
import SwiftUI
@testable import TSApp

final class ScreenshotSettingsPreviewTests: XCTestCase {
    @MainActor func testNativeScreenshotSettingsRenderWithoutLiveAppState() throws {
        guard let directory = ProcessInfo.processInfo.environment["TS_TEST_PREVIEW_DIR"] else {
            throw XCTSkip("Set TS_TEST_PREVIEW_DIR to render native settings previews.")
        }
        _ = NSApplication.shared
        try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
        for (name, scheme) in [("dark", ColorScheme.dark), ("light", .light)] {
            for tab in 0..<4 {
            let full = NSHostingView(rootView: SettingsView(model: AppModel(preview: Preferences()), initialTab: tab).environment(\.colorScheme, scheme))
            full.appearance = NSAppearance(named: scheme == .dark ? .darkAqua : .aqua)
            full.frame = NSRect(x: 0, y: 0, width: 680, height: 760)
            full.layoutSubtreeIfNeeded()
            let fullBitmap = try XCTUnwrap(full.bitmapImageRepForCachingDisplay(in: full.bounds))
            full.cacheDisplay(in: full.bounds, to: fullBitmap)
            try XCTUnwrap(fullBitmap.representation(using: .png, properties: [:])).write(to: URL(fileURLWithPath: directory).appendingPathComponent("settings-\(tab)-\(name).png"))
            }
            for tx in [true, false] {
                let icon = ModeStatusImage.make(transmitting: tx, delivered: true)
                let rendered = NSHostingView(rootView: Image(nsImage: icon).foregroundStyle(Color.primary)
                    .padding(16).background(Color(nsColor: .windowBackgroundColor)).environment(\.colorScheme, scheme))
                rendered.appearance = NSAppearance(named: scheme == .dark ? .darkAqua : .aqua)
                rendered.frame = NSRect(x: 0, y: 0, width: 110, height: 50)
                rendered.layoutSubtreeIfNeeded()
                let bitmap = try XCTUnwrap(rendered.bitmapImageRepForCachingDisplay(in: rendered.bounds))
                rendered.cacheDisplay(in: rendered.bounds, to: bitmap)
                try XCTUnwrap(bitmap.representation(using: .png, properties: [:])).write(to: URL(fileURLWithPath: directory).appendingPathComponent("menubar-\(tx ? "tx" : "rx")-\(name).png"))
            }
            let form = Form {
                ScreenshotSettingsSection(enabled: .constant(true), permission: false, enablePermission: {}, checkPermission: {})
            }.formStyle(.grouped).frame(width: 640, height: 330).environment(\.colorScheme, scheme)
            let view = NSHostingView(rootView: form)
            view.appearance = NSAppearance(named: scheme == .dark ? .darkAqua : .aqua)
            view.frame = NSRect(x: 0, y: 0, width: 640, height: 330)
            view.layoutSubtreeIfNeeded()
            let bitmap = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
            view.cacheDisplay(in: view.bounds, to: bitmap)
            let png = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
            try png.write(to: URL(fileURLWithPath: directory).appendingPathComponent("screenshot-settings-\(name).png"))
            for role in Preferences.Role.allCases {
                let row = MenuModeRow(role: role, isBusy: false, switchMode: {})
                    .padding(20).frame(width: 354).background(Color(nsColor: .windowBackgroundColor))
                    .environment(\.colorScheme, scheme)
                let rowView = NSHostingView(rootView: row)
                rowView.appearance = view.appearance
                rowView.frame = NSRect(x: 0, y: 0, width: 354, height: 70)
                rowView.layoutSubtreeIfNeeded()
                let rowBitmap = try XCTUnwrap(rowView.bitmapImageRepForCachingDisplay(in: rowView.bounds))
                rowView.cacheDisplay(in: rowView.bounds, to: rowBitmap)
                let rowPNG = try XCTUnwrap(rowBitmap.representation(using: .png, properties: [:]))
                try rowPNG.write(to: URL(fileURLWithPath: directory).appendingPathComponent("mode-\(role == .send ? "tx" : "rx")-\(name).png"))
            }
        }
    }
}
