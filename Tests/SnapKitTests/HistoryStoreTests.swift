import CoreGraphics
import XCTest
@testable import SnapKit

@MainActor
final class HistoryStoreTests: XCTestCase {
    private var directory: URL!
    private var clock = Date(timeIntervalSince1970: 1_800_000_000)

    override func setUp() async throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("snapkit-tests-\(UUID().uuidString)")
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: directory)
    }

    private func makeStore(retention: TimeInterval = 30 * 24 * 3600) -> HistoryStore {
        HistoryStore(directory: directory, retention: retention, now: { [unowned self] in self.clock })
    }

    private func sampleImage(width: Int = 8, height: Int = 4) -> CGImage {
        let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                space: CGColorSpaceCreateDeviceRGB(),
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.setFillColor(CGColor(red: 1, green: 0, blue: 0, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        return context.makeImage()!
    }

    func testAddWritesPNGAndIndexesNewestFirst() throws {
        let store = makeStore()
        let first = try store.add(sampleImage())
        clock.addTimeInterval(60)
        let second = try store.add(sampleImage(width: 16, height: 8))

        XCTAssertEqual(store.items.map(\.id), [second.id, first.id])
        XCTAssertEqual(second.pixelWidth, 16)
        XCTAssertEqual(second.pixelHeight, 8)
        XCTAssertTrue(FileManager.default.fileExists(atPath: store.url(for: first).path))
        XCTAssertNotNil(ImageFile.thumbnail(url: store.url(for: first), maxPixelSize: 4))
    }

    func testItemsSurviveRelaunch() throws {
        let item = try makeStore().add(sampleImage())
        let reloaded = makeStore()
        XCTAssertEqual(reloaded.items, [item])
    }

    func testEntriesWithMissingFilesAreDroppedOnLoad() throws {
        let store = makeStore()
        let item = try store.add(sampleImage())
        try FileManager.default.removeItem(at: store.url(for: item))
        XCTAssertTrue(makeStore().items.isEmpty)
    }

    func testPruneRemovesExpiredEntriesAndTheirFiles() throws {
        let store = makeStore(retention: 100)
        let old = try store.add(sampleImage())
        clock.addTimeInterval(150)
        let fresh = try store.add(sampleImage()) // add() prunes

        XCTAssertEqual(store.items.map(\.id), [fresh.id])
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.url(for: old).path))
    }

    func testRemoveAndRemoveAll() throws {
        let store = makeStore()
        let a = try store.add(sampleImage())
        let b = try store.add(sampleImage())

        store.remove(a)
        XCTAssertEqual(store.items.map(\.id), [b.id])
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.url(for: a).path))

        store.removeAll()
        XCTAssertTrue(store.items.isEmpty)
        XCTAssertTrue(makeStore().items.isEmpty)
    }

    func testSaveFileNamesAreUniqueWithinAFolder() throws {
        let date = Date(timeIntervalSince1970: 1_800_000_000)
        let first = CaptureCoordinator.uniqueURL(in: directory, date: date)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data().write(to: first)
        let second = CaptureCoordinator.uniqueURL(in: directory, date: date)

        XCTAssertNotEqual(first, second)
        XCTAssertTrue(second.lastPathComponent.hasSuffix(" 2.png"))
    }
}
