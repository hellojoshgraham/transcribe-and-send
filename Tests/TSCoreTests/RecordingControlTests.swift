import XCTest
@testable import TSCore

final class RecordingControlTests: XCTestCase {
    func testToggleRequiresSecondPressAndIgnoresRelease() {
        XCTAssertEqual(RecordingControl.action(for: .pressed, mode: .toggle, state: .idle), .start)
        XCTAssertNil(RecordingControl.action(for: .released, mode: .toggle, state: .starting))
        XCTAssertNil(RecordingControl.action(for: .released, mode: .toggle, state: .recording))
        XCTAssertEqual(RecordingControl.action(for: .pressed, mode: .toggle, state: .starting), .stop)
        XCTAssertEqual(RecordingControl.action(for: .pressed, mode: .toggle, state: .recording), .stop)
        XCTAssertNil(RecordingControl.action(for: .pressed, mode: .toggle, state: .busy))
    }

    func testHoldBehaviorAndInterruptionRemainUnchanged() {
        XCTAssertEqual(RecordingControl.action(for: .pressed, mode: .hold, state: .idle), .start)
        XCTAssertNil(RecordingControl.action(for: .pressed, mode: .hold, state: .recording))
        for mode in RecordingMode.allCases {
            XCTAssertEqual(RecordingControl.action(for: .interrupted, mode: mode, state: .recording), .cancel)
            XCTAssertEqual(RecordingControl.action(for: .interrupted, mode: mode, state: .starting), .cancel)
        }
        XCTAssertEqual(RecordingControl.action(for: .released, mode: .hold, state: .starting), .stop)
        XCTAssertEqual(RecordingControl.action(for: .released, mode: .hold, state: .recording), .stop)
    }
}
