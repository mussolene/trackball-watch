import XCTest
@testable import TrackBallWatch_Watch_App

@MainActor
final class GestureRecognizerTests: XCTestCase {

    var recognizer: GestureRecognizer!
    var detected: [TBPPacket] = []

    override func setUp() {
        super.setUp()
        recognizer = GestureRecognizer()
        detected = []
        recognizer.onGestureDetected = { [weak self] pkt in
            self?.detected.append(pkt)
        }
    }

    func testTapDetected() async throws {
        // Quick touch with small movement → TAP
        recognizer.onTouch(x: 0, y: 0, phase: .began)
        try await Task.sleep(for: .milliseconds(100))
        recognizer.onTouch(x: 10, y: 5, phase: .moved)
        recognizer.onTouchEnded()

        XCTAssertEqual(detected.count, 1)
        XCTAssertEqual(detected.first?.type, .gesture)
        let gestureType = detected.first?.payload.first
        XCTAssertEqual(gestureType, TBPPacket.GestureType.tap.rawValue)
    }

    func testLongPressDetected() async throws {
        // Hold for > 0.8 seconds → LONG_PRESS
        recognizer.onTouch(x: 0, y: 0, phase: .began)
        try await Task.sleep(for: .milliseconds(900))
        recognizer.onTouchEnded()

        XCTAssertEqual(detected.count, 1)
        let gestureType = detected.first?.payload.first
        XCTAssertEqual(gestureType, TBPPacket.GestureType.longPress.rawValue)
    }

    func testNoFlingOnSlowRelease() {
        // Large movement but slow velocity → SWIPE, not FLING
        recognizer.onTouch(x: 0, y: 0, phase: .began)
        recognizer.onTouch(x: 5000, y: 0, phase: .moved)
        recognizer.onTouchEnded()

        XCTAssertEqual(detected.count, 1)
        let gestureType = detected.first?.payload.first
        // Should be SWIPE (4) not FLING (5)
        XCTAssertEqual(gestureType, TBPPacket.GestureType.swipe.rawValue)
    }
}
