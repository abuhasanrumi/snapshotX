import AppKit
import Carbon.HIToolbox
import XCTest
@testable import SnapShotX

final class KeystrokeTests: XCTestCase {
    private func label(_ keyCode: Int, chars: String?, base: String? = nil, _ flags: NSEvent.ModifierFlags = [], onlyCommand: Bool = false) -> String? {
        KeystrokeFormatter.describe(keyCode: UInt16(keyCode), characters: chars, charactersIgnoringModifiers: base ?? chars,
                                    modifiers: flags, onlyCommandKeys: onlyCommand)
    }

    func testShortcutsShowModifiersInMacOSOrder() {
        XCTAssertEqual(label(kVK_ANSI_C, chars: "c", [.command]), "⌘C")
        XCTAssertEqual(label(kVK_ANSI_4, chars: "$", base: "4", [.shift, .command]), "⇧⌘4")
        XCTAssertEqual(label(kVK_LeftArrow, chars: nil, [.control, .option]), "⌃⌥←")
        XCTAssertEqual(label(kVK_Space, chars: " ", [.command]), "⌘Space")
    }

    func testControlCombinationsUseTheKeyNotTheControlCharacter() {
        XCTAssertEqual(label(kVK_ANSI_C, chars: "\u{03}", base: "c", [.control]), "⌃C")
    }

    func testOrdinaryTypingIsShownAsTyped() {
        XCTAssertEqual(label(kVK_ANSI_A, chars: "a"), "a")
        XCTAssertEqual(label(kVK_ANSI_A, chars: "A", [.shift]), "A")
        XCTAssertEqual(label(kVK_Return, chars: "\r"), "⏎")
        XCTAssertEqual(label(kVK_Tab, chars: "\t", [.shift]), "⇧⇥")
    }

    func testOnlyShortcutsMode() {
        XCTAssertNil(label(kVK_ANSI_A, chars: "a", onlyCommand: true))
        XCTAssertNil(label(kVK_Return, chars: "\r", onlyCommand: true))
        XCTAssertNil(label(kVK_ANSI_A, chars: "A", [.shift], onlyCommand: true), "Shift alone is just typing")
        XCTAssertEqual(label(kVK_ANSI_C, chars: "c", [.command], onlyCommand: true), "⌘C")
    }

    func testKeysWithNoLabelAreIgnored() {
        XCTAssertNil(label(kVK_ANSI_A, chars: nil))
        XCTAssertNil(label(kVK_ANSI_A, chars: ""))
    }

    func testBufferCollectsKeysAndForgetsAfterAPause() {
        var buffer = KeystrokeBuffer(idleTimeout: 1.5, maxTokens: 3)
        let start = Date(timeIntervalSince1970: 1_000)
        buffer.add("h", at: start)
        buffer.add("i", at: start.addingTimeInterval(0.3))
        XCTAssertEqual(buffer.text(at: start.addingTimeInterval(0.4)), "h i")

        buffer.add("!", at: start.addingTimeInterval(0.6))
        buffer.add("?", at: start.addingTimeInterval(0.9))
        XCTAssertEqual(buffer.text(at: start.addingTimeInterval(1.0)), "i ! ?", "only the most recent keys are kept")

        XCTAssertNil(buffer.text(at: start.addingTimeInterval(3)), "faded after the pause")
        buffer.add("x", at: start.addingTimeInterval(3))
        XCTAssertEqual(buffer.text(at: start.addingTimeInterval(3.1)), "x", "typing after a pause starts fresh")
    }

    func testEmptyBufferShowsNothing() {
        XCTAssertNil(KeystrokeBuffer().text(at: Date()))
    }
}

@MainActor
final class RecordingSupportTests: XCTestCase {
    private var directory: URL!
    private var clock = Date(timeIntervalSince1970: 1_800_000_000)

    override func setUp() async throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("snapshotx-rec-tests-\(UUID().uuidString)")
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: directory)
    }

    private func makeStore(retention: TimeInterval = 30 * 24 * 3600) -> HistoryStore {
        HistoryStore(directory: directory, retention: retention, now: { [unowned self] in self.clock })
    }

    private func fakeRecording(format: RecordingFormat = .mp4, duration: TimeInterval = 12.5) throws -> RecordingOutput {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("temp-\(UUID().uuidString).\(format.fileExtension)")
        try Data("not really a video".utf8).write(to: url)
        return RecordingOutput(url: url, duration: duration, pixelSize: CGSize(width: 1920, height: 1080), format: format)
    }

    // MARK: History

    func testRecordingsMoveIntoHistoryWithTheirDetails() throws {
        let store = makeStore()
        let output = try fakeRecording()
        let item = try store.addRecording(output)

        XCTAssertEqual(item.kind, .recording)
        XCTAssertTrue(item.isRecording)
        XCTAssertTrue(item.isVideoFile)
        XCTAssertEqual(item.fileExtension, "mp4")
        XCTAssertEqual(item.durationSeconds, 12.5)
        XCTAssertEqual(item.pixelWidth, 1920)
        XCTAssertTrue(FileManager.default.fileExists(atPath: store.url(for: item).path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: output.url.path), "the temp file is moved, not copied")
    }

    func testGIFRecordingsOpenLikeImages() throws {
        let item = try makeStore().addRecording(try fakeRecording(format: .gif))
        XCTAssertTrue(item.isRecording)
        XCTAssertFalse(item.isVideoFile)
        XCTAssertEqual(item.fileExtension, "gif")
    }

    func testRecordingsSurviveRelaunchAndExpireLikeScreenshots() throws {
        let store = makeStore(retention: 100)
        let item = try store.addRecording(try fakeRecording())
        XCTAssertEqual(makeStore(retention: 100).items.map(\.id), [item.id])

        clock.addTimeInterval(150)
        let reloaded = makeStore(retention: 100)
        XCTAssertTrue(reloaded.items.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.url(for: item).path))
    }

    func testHistorySavedBeforeRecordingsExistedStillLoads() throws {
        let json = """
        {"id":"\(UUID().uuidString)","createdAt":"2026-01-01T00:00:00Z","kind":"screenshot","fileName":"a.png","pixelWidth":10,"pixelHeight":5}
        """
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let item = try decoder.decode(CaptureItem.self, from: Data(json.utf8))
        XCTAssertNil(item.durationSeconds)
        XCTAssertFalse(item.isRecording)
    }

    // MARK: Formatting and names

    func testDurationsFormatAsClockTime() {
        XCTAssertEqual(DurationFormat.string(0), "0:00")
        XCTAssertEqual(DurationFormat.string(7.9), "0:07")
        XCTAssertEqual(DurationFormat.string(754), "12:34")
        XCTAssertEqual(DurationFormat.string(3723), "1:02:03")
        XCTAssertEqual(DurationFormat.string(-5), "0:00")
    }

    func testSavedFileNamesCarryTheRightExtension() throws {
        let date = Date(timeIntervalSince1970: 1_800_000_000)
        XCTAssertTrue(CaptureCoordinator.fileName(for: date, ext: "mp4").hasPrefix("SnapShotX "))
        XCTAssertTrue(CaptureCoordinator.fileName(for: date, ext: "mp4").hasSuffix(".mp4"))
        XCTAssertTrue(CaptureCoordinator.fileName(for: date).hasSuffix(".png"), "screenshots still default to PNG")

        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let first = CaptureCoordinator.uniqueURL(in: directory, date: date, ext: "gif")
        try Data().write(to: first)
        XCTAssertTrue(CaptureCoordinator.uniqueURL(in: directory, date: date, ext: "gif").lastPathComponent.hasSuffix(" 2.gif"))
    }

    // MARK: Preferences, URL, All-in-One memory

    func testRecordingOptionsPersistAndBadDataFallsBackToDefaults() {
        let suite = "snapshotx.rec.prefs.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        addTeardownBlock { defaults.removePersistentDomain(forName: suite) }

        let prefs = Preferences(defaults: defaults)
        XCTAssertEqual(prefs.recording, RecordingOptions())
        prefs.recording.microphone = true
        prefs.recording.fps = 60
        prefs.recording.format = .gif
        XCTAssertEqual(Preferences(defaults: defaults).recording, prefs.recording)

        defaults.set(Data("garbage".utf8), forKey: "prefs.recordingOptions.v1")
        XCTAssertEqual(Preferences(defaults: defaults).recording, RecordingOptions())
    }

    func testRecordScreenCommandAndRecordingSettingsTab() throws {
        let command = try XCTUnwrap(URLCommand.parse(URL(string: "snapshotx://record-screen?x=1&y=2&width=300&height=200&display=2")!))
        XCTAssertEqual(command.kind, .recordScreen)
        XCTAssertEqual(command.rect, CGRect(x: 1, y: 2, width: 300, height: 200))
        XCTAssertEqual(command.display, 2)
        XCTAssertEqual(URLCommand.parse(URL(string: "snapshotx://open-settings?tab=recording")!)?.tab, .recording)
    }

    func testAllInOneRemembersRecordMode() {
        let suite = "snapshotx.rec.memory.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        addTeardownBlock { defaults.removePersistentDomain(forName: suite) }
        AllInOneMemory(displayID: 1, rect: CGRect(x: 0, y: 0, width: 400, height: 300), mode: .record).save(to: defaults)
        XCTAssertEqual(AllInOneMemory.load(from: defaults)?.mode, .record)
        XCTAssertTrue(AllInOneMode.allCases.contains(.record))
    }

    // MARK: Thumbnails

    func testVideoThumbnailIsAScaledStillFrame() async throws {
        let url = SyntheticMedia.tempURL("thumb")
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        try await SyntheticMedia.makeMovie(at: url, seconds: 1)

        let image = try XCTUnwrap(ImageFile.thumbnail(url: url, maxPixelSize: 64))
        XCTAssertLessThanOrEqual(image.width, 64)
        XCTAssertLessThanOrEqual(image.height, 64)
        XCTAssertGreaterThan(image.width, 0)
    }
}
