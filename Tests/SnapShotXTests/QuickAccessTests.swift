import XCTest
@testable import SnapShotX

@MainActor
final class QuickAccessTests: XCTestCase {
    private func makeController() -> QuickAccessController {
        let suite = "snapshotx.quickaccess.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        addTeardownBlock { defaults.removePersistentDomain(forName: suite) }
        return QuickAccessController(prefs: Preferences(defaults: defaults), showsPanel: false)
    }

    private func item(_ kind: CaptureKind = .screenshot) -> CaptureItem {
        CaptureItem(id: UUID(), createdAt: Date(), kind: kind, fileName: kind == .screenshot ? "a.png" : "a.mp4",
                    pixelWidth: 100, pixelHeight: 50)
    }

    private let url = URL(fileURLWithPath: "/tmp/does-not-matter.png")

    func testStartsEmpty() {
        XCTAssertTrue(makeController().entries.isEmpty)
    }

    func testANewCaptureReplacesTheCardInsteadOfStackingAnother() {
        let controller = makeController()
        let first = item(), second = item()
        controller.add(item: first, url: url)
        controller.add(item: second, url: url)
        XCTAssertEqual(controller.entries.map(\.id), [second.id])
    }

    func testTheCardStaysUntilItIsClosed() async throws {
        let controller = makeController()
        let shot = item()
        controller.add(item: shot, url: url)
        // The card used to close itself after 6 seconds. Wait past that.
        try await Task.sleep(nanoseconds: 7_000_000_000)
        XCTAssertEqual(controller.entries.count, 1, "nothing but the cross or a new capture removes it")

        controller.dismiss(shot.id)
        XCTAssertTrue(controller.entries.isEmpty)
    }

    func testEditCopyAndSaveAllKeepTheCard() {
        let controller = makeController()
        let shot = item()
        var edited: CaptureItem?
        controller.onAnnotate = { edited = $0 }
        controller.onCopy = { _ in true }
        controller.onSave = { _ in true }
        controller.add(item: shot, url: url)

        controller.annotate(shot.id)
        controller.copy(shot.id)
        controller.save(shot.id)

        XCTAssertEqual(edited?.id, shot.id)
        XCTAssertEqual(controller.entries.map(\.id), [shot.id])
    }

    func testPlayingARecordingKeepsTheCardToo() {
        let controller = makeController()
        let clip = item(.recording)
        var opened: CaptureItem?
        controller.onOpen = { opened = $0 }
        controller.add(item: clip, url: url)
        controller.open(clip.id)
        XCTAssertEqual(opened?.id, clip.id)
        XCTAssertEqual(controller.entries.count, 1)
    }

    func testCopyAndSaveReportWhatHappened() {
        let controller = makeController()
        let shot = item()
        controller.onCopy = { _ in true }
        controller.onSave = { _ in false }
        controller.add(item: shot, url: url)

        controller.copy(shot.id)
        XCTAssertEqual(controller.entries.first?.badge, "Copied")
        controller.save(shot.id)
        XCTAssertEqual(controller.entries.first?.badge, "Save failed")
    }

    func testAutoCopyNoticeShowsOnTheNewCardAndFades() async throws {
        let controller = makeController()
        controller.add(item: item(), url: url, notice: "Copied")
        XCTAssertEqual(controller.entries.first?.badge, "Copied")

        try await Task.sleep(nanoseconds: 2_000_000_000)
        XCTAssertNil(controller.entries.first?.badge, "the notice is brief")
        XCTAssertEqual(controller.entries.count, 1, "while the card itself stays")
    }

    func testNoNoticeMeansNoBadge() {
        let controller = makeController()
        controller.add(item: item(), url: url)
        XCTAssertNil(controller.entries.first?.badge)
    }

    func testNoticeBelongsToTheCardItWasShownOn() async throws {
        let controller = makeController()
        let first = item(), second = item()
        controller.add(item: first, url: url, notice: "Copied")
        controller.add(item: second, url: url) // replaces the first before its notice fades
        try await Task.sleep(nanoseconds: 2_000_000_000)
        XCTAssertEqual(controller.entries.map(\.id), [second.id])
        XCTAssertNil(controller.entries.first?.badge)
    }
}
