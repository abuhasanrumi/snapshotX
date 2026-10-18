import CoreGraphics
import Foundation

enum CaptureKind: String, Codable {
    case screenshot
    case recording
}

struct CaptureItem: Codable, Identifiable, Equatable {
    let id: UUID
    let createdAt: Date
    let kind: CaptureKind
    let fileName: String
    let pixelWidth: Int
    let pixelHeight: Int
    /// Length of a recording. Nil for screenshots, and for history saved before recordings existed.
    var durationSeconds: Double? = nil

    var isRecording: Bool { kind == .recording }
    var fileExtension: String { (fileName as NSString).pathExtension.lowercased() }
    /// Recordings saved as MP4 need a video player. GIFs open like images.
    var isVideoFile: Bool { fileExtension == "mp4" }
}

/// Every capture is written to disk here and indexed, so it can be found again later.
/// Entries older than the retention window (one month by default) are pruned.
@MainActor
final class HistoryStore: ObservableObject {
    nonisolated static let defaultRetention: TimeInterval = 30 * 24 * 60 * 60

    nonisolated static var defaultDirectory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("SnapShotX/History", isDirectory: true)
    }

    /// Newest first.
    @Published private(set) var items: [CaptureItem] = []

    let directory: URL
    private let retention: TimeInterval
    private let now: () -> Date
    private let fileManager = FileManager.default

    private var indexURL: URL { directory.appendingPathComponent("index.json") }

    init(directory: URL = HistoryStore.defaultDirectory,
         retention: TimeInterval = HistoryStore.defaultRetention,
         now: @escaping () -> Date = Date.init) {
        self.directory = directory
        self.retention = retention
        self.now = now
        try? fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        load()
        prune()
    }

    func cursorURL(for item: CaptureItem) -> URL { directory.appendingPathComponent("\(item.id.uuidString).cursor.json") }
    func studioURL(for item: CaptureItem) -> URL { directory.appendingPathComponent("\(item.id.uuidString).studio.json") }

    private func removeFiles(of item: CaptureItem) {
        try? fileManager.removeItem(at: url(for: item))
        try? fileManager.removeItem(at: cursorURL(for: item))
        try? fileManager.removeItem(at: studioURL(for: item))
    }

    func url(for item: CaptureItem) -> URL {
        directory.appendingPathComponent(item.fileName)
    }

    @discardableResult
    func add(_ image: CGImage, kind: CaptureKind = .screenshot) throws -> CaptureItem {
        let id = UUID()
        let item = CaptureItem(id: id, createdAt: now(), kind: kind, fileName: "\(id.uuidString).png",
                               pixelWidth: image.width, pixelHeight: image.height)
        try ImageFile.writePNG(image, to: url(for: item))
        items.insert(item, at: 0)
        persist()
        prune()
        return item
    }

    /// Moves a finished recording into history. The file is moved, not copied.
    @discardableResult
    func addRecording(_ output: RecordingOutput) throws -> CaptureItem {
        let id = UUID()
        let item = CaptureItem(id: id, createdAt: now(), kind: .recording,
                               fileName: "\(id.uuidString).\(output.format.fileExtension)",
                               pixelWidth: Int(output.pixelSize.width), pixelHeight: Int(output.pixelSize.height),
                               durationSeconds: output.duration)
        try fileManager.moveItem(at: output.url, to: url(for: item))
        if let cursor = output.cursor, !cursor.isEmpty, let data = try? JSONEncoder().encode(cursor) {
            try? data.write(to: cursorURL(for: item), options: .atomic)
        }
        items.insert(item, at: 0)
        persist()
        prune()
        return item
    }

    func remove(_ item: CaptureItem) {
        removeFiles(of: item)
        items.removeAll { $0.id == item.id }
        persist()
    }

    func removeAll() {
        for item in items { removeFiles(of: item) }
        items.removeAll()
        persist()
    }

    func prune() {
        let cutoff = now().addingTimeInterval(-retention)
        let expired = items.filter { $0.createdAt < cutoff }
        guard !expired.isEmpty else { return }
        for item in expired { removeFiles(of: item) }
        items.removeAll { $0.createdAt < cutoff }
        persist()
    }

    // MARK: Persistence

    private func load() {
        guard let data = try? Data(contentsOf: indexURL) else { return }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let decoded = try? decoder.decode([CaptureItem].self, from: data) else { return }
        // Drop entries whose file was deleted behind our back.
        items = decoded
            .filter { fileManager.fileExists(atPath: url(for: $0).path) }
            .sorted { $0.createdAt > $1.createdAt }
    }

    private func persist() {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        if let data = try? encoder.encode(items) {
            try? data.write(to: indexURL, options: .atomic)
        }
    }
}
