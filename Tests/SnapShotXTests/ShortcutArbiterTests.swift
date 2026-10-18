import XCTest
@testable import SnapShotX

final class ShortcutArbiterTests: XCTestCase {
    private func decide(_ action: HotkeyAction, _ activity: CaptureActivity = CaptureActivity()) -> ShortcutDecision {
        ShortcutArbiter.decide(action, activity: activity)
    }

    func testEverythingStartsWhenNothingIsGoingOn() {
        for action in HotkeyAction.allCases {
            XCTAssertEqual(decide(action), .start, action.rawValue)
        }
    }

    func testAShortcutIsNeverIgnoredWithoutAReasonWhileOnlyBusy() {
        XCTAssertEqual(decide(.captureArea, CaptureActivity(isBusy: true)), .ignore)
        XCTAssertEqual(decide(.openHistory, CaptureActivity(isBusy: true)), .start, "history is always allowed")
    }

    func testRecordingStopsOnItsOwnShortcutAndExplainsOthers() {
        let recording = CaptureActivity(isRecording: true, isBusy: true)
        XCTAssertEqual(decide(.recordScreen, recording), .stopRecording)
        XCTAssertEqual(decide(.captureArea, recording), .explain("Stop the recording first"))
        XCTAssertEqual(decide(.allInOne, recording), .explain("Stop the recording first"))
        XCTAssertEqual(decide(.openHistory, recording), .start)
    }

    func testScrollingFinishesOnItsOwnShortcutAndExplainsOthers() {
        let scrolling = CaptureActivity(isScrolling: true, isBusy: true)
        XCTAssertEqual(decide(.scrollingCapture, scrolling), .finishScrolling)
        XCTAssertEqual(decide(.recordScreen, scrolling), .explain("Finish the scrolling capture first"))
    }

    func testTheSameShortcutClosesAnOpenOverlay() {
        let overlay = CaptureActivity(isOverlayOpen: true, overlayOwner: .captureArea, isBusy: true)
        XCTAssertEqual(decide(.captureArea, overlay), .closeOverlay)
    }

    func testADifferentShortcutSwitchesCaptureWhileAnOverlayIsOpen() {
        let overlay = CaptureActivity(isOverlayOpen: true, overlayOwner: .captureArea, isBusy: true)
        XCTAssertEqual(decide(.captureWindow, overlay), .switchToAction)
        XCTAssertEqual(decide(.allInOne, overlay), .switchToAction)
        XCTAssertEqual(decide(.recordScreen, overlay), .switchToAction)
    }

    func testAllInOneToggles() {
        let overlay = CaptureActivity(isOverlayOpen: true, overlayOwner: .allInOne, isBusy: true)
        XCTAssertEqual(decide(.allInOne, overlay), .closeOverlay)
        XCTAssertEqual(decide(.captureText, overlay), .switchToAction)
    }

    func testRecordingTakesPriorityOverAStaleOverlayFlag() {
        let activity = CaptureActivity(isRecording: true, isOverlayOpen: true, overlayOwner: .allInOne, isBusy: true)
        XCTAssertEqual(decide(.recordScreen, activity), .stopRecording)
    }

    func testShortcutFeedbackIsRecordedAndFlashesBriefly() {
        let store = ShortcutStore(defaults: UserDefaults(suiteName: "snapshotx.arbiter.\(UUID().uuidString)")!)
        XCTAssertNil(store.lastTriggered)
        let time = Date(timeIntervalSince1970: 1_800_000_000)
        store.noteTriggered(.captureArea, at: time)
        XCTAssertEqual(store.lastTriggered, ShortcutStore.Trigger(action: .captureArea, time: time))
        XCTAssertEqual(store.flashing, .captureArea)

        let faded = expectation(description: "highlight fades")
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { faded.fulfill() }
        wait(for: [faded], timeout: 3)
        XCTAssertNil(store.flashing)
        XCTAssertNotNil(store.lastTriggered, "the last shortcut stays shown after the highlight fades")
    }
}
