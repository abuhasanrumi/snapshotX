import AVFoundation
import AppKit
import Combine

/// The state of one Studio Mode editing session: the project being edited, the preview player, undo history
/// and export progress. The recording itself is never modified.
@MainActor
final class StudioDocument: ObservableObject {
    @Published private(set) var project: StudioProject
    @Published var selectedZoom: UUID?
    @Published private(set) var layout: StudioLayout
    /// Playhead position in the original recording's time.
    @Published private(set) var currentTime = 0.0
    @Published private(set) var isPlaying = false
    @Published private(set) var exportProgress: Double?
    @Published var notice: String?

    let asset: AVURLAsset
    let cursor: CursorTrack?
    let sourceSize: CGSize
    /// Length of the whole original recording.
    let duration: Double
    let player = AVPlayer()

    private var undoStack: [StudioProject] = []
    private var redoStack: [StudioProject] = []
    private var changeSnapshot: StudioProject?
    private var buildTask: Task<Void, Never>?
    private var saveTask: Task<Void, Never>?
    private var trimOffset = 0.0
    private var editedDuration = 0.0
    private var timeObserver: Any?
    private let projectURL: URL?

    var hasCursor: Bool { !(cursor?.isEmpty ?? true) }
    var canUndo: Bool { !undoStack.isEmpty }
    var canRedo: Bool { !redoStack.isEmpty }
    var trim: (start: Double, end: Double) { project.trimRange(duration: duration) }
    var selected: ZoomSegment? { project.zooms.first { $0.id == selectedZoom } }

    init(videoURL: URL, cursor: CursorTrack?, projectURL: URL?, duration: Double, sourceSize: CGSize) {
        asset = AVURLAsset(url: videoURL)
        self.cursor = cursor
        self.projectURL = projectURL
        self.duration = duration
        self.sourceSize = sourceSize

        var loaded = StudioProject()
        if let projectURL, let data = try? Data(contentsOf: projectURL), let decoded = try? JSONDecoder().decode(StudioProject.self, from: data) {
            loaded = decoded
        } else if let cursor {
            loaded.zooms = SmartZoom.generate(from: cursor.clicks, duration: duration)
        }
        project = loaded
        layout = StudioLayout.make(sourceSize: sourceSize, background: loaded.background, preset: loaded.preset)

        player.actionAtItemEnd = .pause
        timeObserver = player.addPeriodicTimeObserver(forInterval: CMTime(value: 1, timescale: 30), queue: .main) { [weak self] time in
            MainActor.assumeIsolated { self?.tick(time) }
        }
        scheduleRebuild(immediately: true)
    }

    deinit {
        if let timeObserver { player.removeTimeObserver(timeObserver) }
    }

    // MARK: Editing

    /// One undoable change.
    func perform(_ change: (inout StudioProject) -> Void) {
        let before = project
        var edited = project
        change(&edited)
        guard edited != before else { return }
        undoStack.append(before)
        redoStack.removeAll()
        apply(edited)
    }

    /// A change that happens many times while dragging; wrap the drag in `beginChange` and `endChange`.
    func update(_ change: (inout StudioProject) -> Void) {
        var edited = project
        change(&edited)
        guard edited != project else { return }
        apply(edited)
    }

    func beginChange() { changeSnapshot = project }

    func endChange() {
        guard let snapshot = changeSnapshot else { return }
        changeSnapshot = nil
        if snapshot != project {
            undoStack.append(snapshot)
            redoStack.removeAll()
        }
    }

    func undo() {
        guard let previous = undoStack.popLast() else { return }
        redoStack.append(project)
        apply(previous)
    }

    func redo() {
        guard let next = redoStack.popLast() else { return }
        undoStack.append(project)
        apply(next)
    }

    private func apply(_ edited: StudioProject) {
        project = edited
        if let id = selectedZoom, !edited.zooms.contains(where: { $0.id == id }) { selectedZoom = nil }
        scheduleRebuild()
        scheduleSave()
    }

    func addZoom() {
        let start = min(currentTime, max(0, duration - 0.5))
        let segment = ZoomSegment(start: start, end: min(duration, start + 3), scale: 2, focus: hasCursor ? .cursor : .point(x: 0.5, y: 0.5))
        perform { $0.zooms.append(segment) }
        selectedZoom = segment.id
    }

    func deleteSelectedZoom() {
        guard let id = selectedZoom else { return }
        perform { $0.zooms.removeAll { $0.id == id } }
        selectedZoom = nil
    }

    func regenerateZooms() {
        guard let cursor else { return }
        let generated = SmartZoom.generate(from: cursor.clicks, duration: duration)
        perform { $0.zooms = generated }
        selectedZoom = nil
        notice = generated.isEmpty ? "No clicks were recorded, so there is nothing to zoom to." : nil
    }

    func holdFocusAtPlayhead(for id: UUID) {
        guard let point = cursor?.position(at: currentTime, smoothing: project.cursor.smoothing) else { return }
        let clamped = (x: min(1, max(0, point.x)), y: min(1, max(0, point.y)))
        perform { project in
            if let i = project.zooms.firstIndex(where: { $0.id == id }) { project.zooms[i].focus = .point(x: clamped.x, y: clamped.y) }
        }
    }

    func followCursor(for id: UUID) {
        perform { project in
            if let i = project.zooms.firstIndex(where: { $0.id == id }) { project.zooms[i].focus = .cursor }
        }
    }

    // MARK: Playback

    func togglePlay() { isPlaying ? pause() : play() }

    func play() {
        let range = trim
        if currentTime >= range.end - 0.05 { seek(to: range.start) }
        player.play()
        isPlaying = true
    }

    func pause() {
        player.pause()
        isPlaying = false
    }

    /// Moves the playhead to a time in the original recording (clamped to the kept part).
    func seek(to time: Double) {
        let range = trim
        let clamped = min(max(time, range.start), range.end)
        currentTime = clamped
        let target = CMTime(seconds: max(0, clamped - trimOffset), preferredTimescale: 600)
        player.seek(to: target, toleranceBefore: .zero, toleranceAfter: .zero)
    }

    private func tick(_ time: CMTime) {
        guard time.isValid else { return }
        currentTime = time.seconds + trimOffset
        if isPlaying, editedDuration > 0, time.seconds >= editedDuration - 0.04 { pause() }
    }

    // MARK: Preview

    private func scheduleRebuild(immediately: Bool = false) {
        buildTask?.cancel()
        buildTask = Task { [weak self] in
            if !immediately { try? await Task.sleep(nanoseconds: 120_000_000) }
            guard !Task.isCancelled else { return }
            await self?.rebuild()
        }
    }

    private func rebuild() async {
        let wasPlaying = isPlaying
        let position = currentTime
        do {
            let built = try await StudioComposition.build(asset: asset, project: project, cursor: cursor)
            guard !Task.isCancelled else { return }
            let item = AVPlayerItem(asset: built.composition)
            item.videoComposition = built.videoComposition
            item.audioMix = built.audioMix
            trimOffset = built.renderer.timeOffset
            editedDuration = built.duration
            layout = built.renderer.layout
            player.replaceCurrentItem(with: item)
            seek(to: position)
            if wasPlaying { player.play() }
        } catch {
            notice = error.localizedDescription
        }
    }

    // MARK: Saving the project

    private func scheduleSave() {
        guard let projectURL else { return }
        saveTask?.cancel()
        let snapshot = project
        saveTask = Task {
            try? await Task.sleep(nanoseconds: 400_000_000)
            guard !Task.isCancelled else { return }
            if let data = try? JSONEncoder().encode(snapshot) { try? data.write(to: projectURL, options: .atomic) }
        }
    }

    func saveNow() {
        guard let projectURL, let data = try? JSONEncoder().encode(project) else { return }
        try? data.write(to: projectURL, options: .atomic)
    }

    // MARK: Export

    func export(to url: URL, format: StudioExporter.Format) async {
        pause()
        exportProgress = 0
        defer { exportProgress = nil }
        do {
            try await StudioExporter.export(asset: asset, project: project, cursor: cursor, to: url, format: format) { value in
                Task { @MainActor [weak self] in if self?.exportProgress != nil { self?.exportProgress = value } }
            }
            Toast.show("Exported \(url.lastPathComponent)")
            NSWorkspace.shared.activateFileViewerSelecting([url])
        } catch {
            notice = "Export failed: \(error.localizedDescription)"
        }
    }
}
