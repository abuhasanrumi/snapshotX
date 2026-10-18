import AppKit
import ScreenCaptureKit
import SwiftUI

final class RecordingHUDModel: ObservableObject {
    @Published var elapsed: TimeInterval = 0
    @Published var isProcessing = false
    @Published var notice: String?
    @Published var isPaused = false
    var onPause: () -> Void = {}
    var onStop: () -> Void = {}
    var onCancel: () -> Void = {}
}

/// One screen recording from start to finished file: shows the controls, runs the overlays, drives the
/// recorder, then mixes audio or converts to GIF. `run` returns when the user stops (or nil if they cancel).
@MainActor
final class RecordingSession {
    enum Target {
        case area(screen: NSScreen, rect: CGRect)
        case display(NSScreen)
        case window(id: CGWindowID, frame: CGRect)

        /// The recorded region in AppKit global coordinates.
        var region: CGRect {
            switch self {
            case .area(_, let rect): return rect
            case .display(let screen): return screen.frame
            case .window(_, let frame): return frame
            }
        }
    }

    enum SessionError: LocalizedError {
        case displayNotFound
        case windowNotFound

        var errorDescription: String? {
            switch self {
            case .displayNotFound: return "The display to record is no longer available."
            case .windowNotFound: return "That window closed before the recording could start."
            }
        }
    }

    let hud = RecordingHUDModel()
    private let permissions: PermissionManager
    private let recorder = ScreenRecorder()
    private let clicks = ClickHighlighter()
    private let keystrokes = KeystrokeOverlay()
    private let camera = CameraBubble()
    private let cursorRecorder = CursorRecorder()
    private var studioActive = false

    private var hudPanel: NSPanel?
    private var outline: NSWindow?
    private var timer: Timer?
    private var startedAt = Date()
    private var stopContinuation: CheckedContinuation<Void, Never>?
    private var cancelled = false
    private var endRequested = false
    private var streamError: Error?
    private var pixelSize = CGSize.zero
    private var options = RecordingOptions()

    private(set) var isRecording = false

    init(permissions: PermissionManager) {
        self.permissions = permissions
    }

    private var pausedAt: Date?
    private var pausedTotal: TimeInterval = 0

    /// Pauses, or resumes if already paused. What happens in between is left out of the video.
    func togglePause() {
        guard isRecording else { return }
        if let began = pausedAt {
            pausedTotal += Date().timeIntervalSince(began)
            pausedAt = nil
            recorder.resume()
            hud.isPaused = false
        } else {
            pausedAt = Date()
            recorder.pause()
            hud.isPaused = true
        }
    }

    func stop() { requestEnd(cancelled: false) }
    func cancel() { requestEnd(cancelled: true) }

    private func requestEnd(cancelled: Bool) {
        if cancelled { self.cancelled = true }
        endRequested = true // remembered in case Stop is pressed before the recording has finished starting
        stopContinuation?.resume()
        stopContinuation = nil
    }

    /// Records until `stop()` or `cancel()`. Returns nil on cancel.
    func run(target: Target, options: RecordingOptions) async throws -> RecordingOutput? {
        self.options = options
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("SnapShotX-Recordings", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let videoURL = folder.appendingPathComponent("\(UUID().uuidString).mp4")

        do {
            try await begin(target: target, videoURL: videoURL)
        } catch {
            await tearDownAfterFailure(videoURL)
            throw error
        }

        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            if endRequested { return continuation.resume() }
            stopContinuation = continuation
        }
        return try await finish(videoURL: videoURL)
    }

    // MARK: Starting

    private func begin(target: Target, videoURL: URL) async throws {
        let region = target.region
        let isWindow: Bool
        if case .window = target { isWindow = true } else { isWindow = false }

        recorder.onStreamError = { [weak self] error in
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.streamStopped(error) } }
        }

        showHUD(near: region)
        if case .area = target { showOutline(around: region) }

        // Overlays are separate windows, so only whole-screen and area recordings pick them up.
        studioActive = options.studioMode && options.format == .mp4
        if !isWindow {
            if options.highlightClicks && !studioActive { clicks.start() }
            if options.showKeystrokes {
                if !keystrokes.start(anchor: region, onlyCommandKeys: options.onlyCommandKeys) {
                    hud.notice = "Allow Accessibility to show keystrokes"
                    permissions.requestAccessibility()
                }
            }
            if options.camera {
                let started = await camera.start(size: options.cameraSize, shape: options.cameraShape, anchor: region)
                if !started { hud.notice = "Camera unavailable. Check camera permission." }
            }
        }

        // Let the new windows register with ScreenCaptureKit so the controls can be left out of the video.
        try await Task.sleep(nanoseconds: 250_000_000)

        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        let hidden = Set([hudPanel?.windowNumber, outline?.windowNumber].compactMap { $0 }.map { CGWindowID($0) })
        let excluded = content.windows.filter { hidden.contains($0.windowID) }

        let configuration: ScreenRecorder.Configuration
        switch target {
        case .area(let screen, let rect):
            guard let display = Self.display(for: screen, in: content) else { throw SessionError.displayNotFound }
            let size = RecordingGeometry.pixelSize(points: rect.size, scale: screen.backingScaleFactor)
            configuration = .init(filter: SCContentFilter(display: display, excludingWindows: excluded),
                                  sourceRect: Geometry.displayLocalRect(selection: rect, screenFrame: screen.frame),
                                  pixelSize: size, options: options, outputURL: videoURL)
        case .display(let screen):
            guard let display = Self.display(for: screen, in: content) else { throw SessionError.displayNotFound }
            let size = RecordingGeometry.pixelSize(points: screen.frame.size, scale: screen.backingScaleFactor)
            configuration = .init(filter: SCContentFilter(display: display, excludingWindows: excluded),
                                  sourceRect: nil, pixelSize: size, options: options, outputURL: videoURL)
        case .window(let id, _):
            guard let window = content.windows.first(where: { $0.windowID == id }) else { throw SessionError.windowNotFound }
            let filter = SCContentFilter(desktopIndependentWindow: window)
            let info = SCShareableContent.info(for: filter)
            let size = RecordingGeometry.pixelSize(points: info.contentRect.size, scale: CGFloat(info.pointPixelScale))
            configuration = .init(filter: filter, sourceRect: nil, pixelSize: size, options: options, outputURL: videoURL)
        }

        pixelSize = configuration.pixelSize
        try await recorder.start(configuration)
        if studioActive {
            let scale: CGFloat
            switch target {
            case .area(let screen, _), .display(let screen): scale = screen.backingScaleFactor
            case .window: scale = NSScreen.screens.first { $0.frame.intersects(region) }?.backingScaleFactor ?? 2
            }
            cursorRecorder.start(region: region, pixelsPerPoint: Double(scale))
        }
        if recorder.microphoneUnavailable { hud.notice = "Microphone unavailable. Check microphone permission." }

        isRecording = true
        startedAt = Date()
        timer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                let now = self.pausedAt ?? Date()
                self.hud.elapsed = now.timeIntervalSince(self.startedAt) - self.pausedTotal
            }
        }
    }

    private static func display(for screen: NSScreen, in content: SCShareableContent) -> SCDisplay? {
        guard let id = screen.displayID else { return nil }
        return content.displays.first { $0.displayID == id }
    }

    private func streamStopped(_ error: Error) {
        guard isRecording else { return }
        streamError = error
        requestEnd(cancelled: false)
    }

    // MARK: Finishing

    private func finish(videoURL: URL) async throws -> RecordingOutput? {
        timer?.invalidate()
        timer = nil
        isRecording = false
        clicks.stop()
        keystrokes.stop()
        camera.stop()
        cursorRecorder.stop()
        outline?.orderOut(nil)

        if cancelled {
            await recorder.cancel()
            closeHUD()
            try? FileManager.default.removeItem(at: videoURL)
            return nil
        }

        hud.isProcessing = true
        defer { closeHUD() }

        let summary: RecordingWriter.Summary
        do {
            summary = try await recorder.stop()
        } catch {
            try? FileManager.default.removeItem(at: videoURL)
            throw streamError ?? error
        }

        // System audio and microphone are written as separate tracks. Fold them into one so every player plays both.
        if await AudioMixer.audioTrackCount(in: videoURL) > 1 {
            let mixed = videoURL.deletingPathExtension().appendingPathExtension("mixed.mp4")
            do {
                try await AudioMixer.mixAudioTracks(in: videoURL, to: mixed)
                try FileManager.default.removeItem(at: videoURL)
                try FileManager.default.moveItem(at: mixed, to: videoURL)
            } catch {
                try? FileManager.default.removeItem(at: mixed) // keep the two-track file rather than lose the recording
            }
        }

        guard options.format == .gif else {
            let track = studioActive ? cursorRecorder.track(start: summary.start, pauses: summary.pauses) : nil
            return RecordingOutput(url: videoURL, duration: summary.duration, pixelSize: pixelSize, format: .mp4, cursor: track)
        }
        let gifURL = videoURL.deletingPathExtension().appendingPathExtension("gif")
        defer { try? FileManager.default.removeItem(at: videoURL) }
        try await GIFExporter.export(from: videoURL, to: gifURL, fps: options.gifFPS, maxWidth: options.gifMaxWidth)
        return RecordingOutput(url: gifURL, duration: summary.duration, pixelSize: pixelSize, format: .gif)
    }

    private func tearDownAfterFailure(_ videoURL: URL) async {
        timer?.invalidate()
        timer = nil
        isRecording = false
        clicks.stop()
        keystrokes.stop()
        camera.stop()
        cursorRecorder.stop()
        outline?.orderOut(nil)
        await recorder.cancel()
        closeHUD()
        try? FileManager.default.removeItem(at: videoURL)
    }

    // MARK: Windows

    private func showHUD(near region: CGRect) {
        hud.onPause = { [weak self] in self?.togglePause() }
        hud.onStop = { [weak self] in self?.stop() }
        hud.onCancel = { [weak self] in self?.cancel() }
        let hosting = NSHostingView(rootView: RecordingHUDView(model: hud))
        hosting.layoutSubtreeIfNeeded()
        let size = hosting.fittingSize

        let panel = NSPanel(contentRect: NSRect(origin: .zero, size: size), styleMask: [.borderless, .nonactivatingPanel],
                            backing: .buffered, defer: false)
        panel.level = NSWindow.Level(rawValue: NSWindow.Level.screenSaver.rawValue + 1)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        panel.contentView = hosting

        let screen = NSScreen.screens.first { $0.frame.intersects(region) } ?? NSScreen.main ?? NSScreen.screens[0]
        let area = screen.visibleFrame
        panel.setFrameOrigin(NSPoint(x: area.midX - size.width / 2, y: area.minY + 28))
        panel.orderFrontRegardless()
        hudPanel = panel
    }

    private func closeHUD() {
        hudPanel?.orderOut(nil)
        hudPanel = nil
        outline?.orderOut(nil)
        outline = nil
    }

    /// A thin border just outside the recorded area, so it is clear what is being recorded without being in the video.
    private func showOutline(around region: CGRect) {
        let frame = region.insetBy(dx: -3, dy: -3)
        let window = NSWindow(contentRect: frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.level = .screenSaver
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = false
        window.ignoresMouseEvents = true
        window.isReleasedWhenClosed = false
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        let view = NSView(frame: NSRect(origin: .zero, size: frame.size))
        view.wantsLayer = true
        view.layer?.borderColor = NSColor.systemRed.cgColor
        view.layer?.borderWidth = 3
        view.layer?.cornerRadius = 3
        window.contentView = view
        window.orderFrontRegardless()
        outline = window
    }
}

struct RecordingHUDView: View {
    @ObservedObject var model: RecordingHUDModel
    @State private var pulse = false

    var body: some View {
        HStack(spacing: 12) {
            if model.isProcessing {
                ProgressView().controlSize(.small)
                Text("Processing…").font(.system(size: 13, weight: .medium))
            } else {
                // The animation is scoped to this dot, so nothing else in the HUD is ever part of the pulse.
                Circle()
                    .fill(model.isPaused ? Color.orange : Color.red)
                    .frame(width: 10, height: 10)
                    .opacity(pulse && !model.isPaused ? 0.35 : 1)
                    .animation(.easeInOut(duration: 0.8).repeatForever(), value: pulse)
                    .onAppear { pulse = true }
                Text(DurationFormat.string(model.elapsed))
                    .font(.system(size: 14, weight: .semibold, design: .monospaced))
                if let notice = model.notice {
                    Text(notice).font(.system(size: 11)).foregroundStyle(.orange).lineLimit(1)
                }
                IconButton(symbol: model.isPaused ? "play.fill" : "pause.fill", help: model.isPaused ? "Resume recording" : "Pause recording", size: 26) { model.onPause() }
                IconButton(symbol: "stop.fill", help: "Stop recording", style: .destructive, size: 30) { model.onStop() }
                IconButton(symbol: "trash", help: "Discard the recording", size: 26) { model.onCancel() }
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(RoundedRectangle(cornerRadius: 14).fill(.regularMaterial))
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(Color.primary.opacity(0.12), lineWidth: 1))
        .padding(8)
    }
}
