import AVFoundation
import AppKit
import SwiftUI

/// Shows an AVPlayer's video, scaled to fit, with no playback controls.
private struct PlayerSurface: NSViewRepresentable {
    let player: AVPlayer

    final class HostView: NSView {
        let playerLayer = AVPlayerLayer()
        override init(frame: NSRect) {
            super.init(frame: frame)
            wantsLayer = true
            layer = CALayer()
            playerLayer.videoGravity = .resizeAspect
            layer?.addSublayer(playerLayer)
        }
        required init?(coder: NSCoder) { fatalError() }
        override func layout() {
            super.layout()
            playerLayer.frame = bounds
        }
    }

    func makeNSView(context: Context) -> HostView {
        let view = HostView(frame: .zero)
        view.playerLayer.player = player
        return view
    }

    func updateNSView(_ view: HostView, context: Context) {
        view.playerLayer.player = player
    }
}

struct StudioView: View {
    @ObservedObject var document: StudioDocument
    @ObservedObject var presets: BackgroundPresetStore
    var onExport: (StudioExporter.Format) -> Void

    @State private var format = StudioExporter.Format.mp4
    @State private var cropping = false
    @State private var draft = ZoomCamera.Crop.full
    @State private var frame: CGImage?
    @State private var aspect: Double?

    var body: some View {
        HStack(spacing: 0) {
            VStack(spacing: 0) {
                if let notice = document.notice { banner(notice, symbol: "exclamationmark.triangle.fill") }
                else if !document.hasCursor {
                    banner("No cursor data in this recording. Turn on Studio mode before recording to get smart zooms and cursor effects.",
                           symbol: "info.circle.fill")
                }
                if cropping {
                    StudioCropEditor(image: frame, crop: $draft, lockedAspect: aspect)
                        .padding(16)
                        .background(Color.black.opacity(0.06))
                    cropBar
                } else {
                    PlayerSurface(player: document.player)
                        .aspectRatio(document.layout.renderSize, contentMode: .fit)
                        .clipShape(RoundedRectangle(cornerRadius: 6))
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .padding(16)
                        .background(Color.black.opacity(0.06))
                    transport
                    StudioTimeline(document: document)
                        .frame(height: 96)
                        .padding(.horizontal, 16)
                        .padding(.bottom, 12)
                }
            }
            Divider()
            inspector.frame(width: 320)
        }
    }

    private func banner(_ text: String, symbol: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: symbol)
            Text(text).font(.callout).lineLimit(2)
            Spacer()
        }
        .padding(.horizontal, 14).padding(.vertical, 8)
        .background(Color.yellow.opacity(0.18))
    }

    // MARK: Transport

    private var transport: some View {
        HStack(spacing: 10) {
            IconButton(symbol: document.isPlaying ? "pause.fill" : "play.fill", help: document.isPlaying ? "Pause" : "Play",
                       style: .accent, size: 32) { document.togglePlay() }
                .keyboardShortcut(.space, modifiers: [])
            IconButton(symbol: "backward.end.fill", help: "Back to start") { document.seek(to: document.trim.start) }
            Text("\(DurationFormat.string(document.currentTime - document.trim.start)) / \(DurationFormat.string(document.trim.end - document.trim.start))")
                .font(.system(size: 12, design: .monospaced)).foregroundStyle(.secondary)
            Spacer()
            IconButton(symbol: "crop", help: "Crop the recording", isOn: document.project.crop != nil) { startCrop() }
            IconButton(symbol: "plus.magnifyingglass", help: "Add a zoom at the playhead") { document.addZoom() }
            IconButton(symbol: "wand.and.stars", help: "Create zooms from clicks again") { document.regenerateZooms() }
                .disabled(!document.hasCursor)
            IconButton(symbol: "trash", help: "Delete the selected zoom", style: .destructive, size: 28) { document.deleteSelectedZoom() }
                .disabled(document.selectedZoom == nil)
            IconButton(symbol: "arrow.uturn.backward", help: "Undo") { document.undo() }
                .disabled(!document.canUndo)
                .keyboardShortcut("z", modifiers: .command)
            IconButton(symbol: "arrow.uturn.forward", help: "Redo") { document.redo() }
                .disabled(!document.canRedo)
                .keyboardShortcut("z", modifiers: [.command, .shift])
        }
        .padding(.horizontal, 16).padding(.vertical, 8)
    }

    // MARK: Crop

    private func startCrop() {
        document.pause()
        draft = document.project.crop ?? .full
        aspect = nil
        cropping = true
        Task { frame = await document.fullFrame() }
    }

    private var cropBar: some View {
        HStack(spacing: 10) {
            Text("Crop").font(.headline)
            Picker("Shape", selection: Binding(get: { aspect }, set: { value in
                aspect = value
                if let value, let frame {
                    draft = StudioCropEditor.crop(aspect: value, imageAspect: Double(frame.width) / Double(frame.height), around: draft)
                }
            })) {
                Text("Free").tag(Double?.none)
                Text("16:9").tag(Double?.some(16.0 / 9))
                Text("4:3").tag(Double?.some(4.0 / 3))
                Text("1:1").tag(Double?.some(1))
                Text("9:16").tag(Double?.some(9.0 / 16))
            }
            .pickerStyle(.segmented).frame(width: 260).labelsHidden()
            Spacer()
            Button("Reset") { draft = .full; aspect = nil }
            Button("Cancel") { cropping = false }
            Button("Apply") {
                let full = draft.width > 0.999 && draft.height > 0.999
                document.perform { $0.crop = full ? nil : draft.clamped() }
                cropping = false
            }
            .buttonStyle(.borderedProminent)
        }
        .padding(.horizontal, 16).padding(.vertical, 10)
    }

    // MARK: Inspector

    private var inspector: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                zoomSection
                cursorSection
                Divider()
                BackgroundControls(
                    style: document.project.background,
                    presets: presets,
                    apply: { change in document.perform { change(&$0.background) } },
                    update: { change in document.update { change(&$0.background) } },
                    beginChange: { document.beginChange() },
                    endChange: { document.endChange() }
                )
                .frame(minHeight: 420)
                Divider()
                exportSection
            }
            .padding(16)
        }
    }

    private func heading(_ title: String) -> some View {
        Text(title).font(.subheadline.weight(.semibold)).foregroundStyle(.secondary)
    }

    @ViewBuilder private var zoomSection: some View {
        heading("Zoom")
        if let zoom = document.selected {
            HStack {
                Text("Strength").frame(width: 70, alignment: .leading)
                Slider(value: Binding(
                    get: { zoom.scale },
                    set: { value in document.update { p in if let i = p.zooms.firstIndex(where: { $0.id == zoom.id }) { p.zooms[i].scale = value } } }
                ), in: 1.2...4, onEditingChanged: { $0 ? document.beginChange() : document.endChange() })
                Text(String(format: "%.1f×", zoom.scale)).font(.caption.monospacedDigit()).frame(width: 36)
            }
            HStack {
                Text("Focus").frame(width: 70, alignment: .leading)
                Picker("", selection: Binding(
                    get: { zoom.focus == .cursor },
                    set: { follow in
                        if follow { document.followCursor(for: zoom.id) } else { document.holdFocusAtPlayhead(for: zoom.id) }
                    }
                )) {
                    Text("Follow cursor").tag(true)
                    Text("Hold here").tag(false)
                }
                .pickerStyle(.segmented).labelsHidden()
                .disabled(!document.hasCursor)
            }
        } else {
            Text("Select a zoom on the timeline, or add one at the playhead.").font(.caption).foregroundStyle(.secondary)
        }
    }

    @ViewBuilder private var cursorSection: some View {
        heading("Cursor")
        Toggle("Show cursor", isOn: Binding(get: { document.project.cursor.visible }, set: { v in document.perform { $0.cursor.visible = v } }))
        Toggle("Click effect", isOn: Binding(get: { document.project.cursor.clickEffect }, set: { v in document.perform { $0.cursor.clickEffect = v } }))
        cursorSlider("Size", range: 0.5...3, get: { $0.size }, set: { $0.size = $1 })
        cursorSlider("Smoothing", range: 0...1, get: { $0.smoothing }, set: { $0.smoothing = $1 })
    }

    private func cursorSlider(_ title: String, range: ClosedRange<Double>, get: @escaping (CursorStyle) -> Double,
                              set: @escaping (inout CursorStyle, Double) -> Void) -> some View {
        HStack {
            Text(title).frame(width: 70, alignment: .leading)
            Slider(value: Binding(
                get: { get(document.project.cursor) },
                set: { value in document.update { set(&$0.cursor, value) } }
            ), in: range, onEditingChanged: { $0 ? document.beginChange() : document.endChange() })
        }
        .disabled(!document.hasCursor || !document.project.cursor.visible)
    }

    @ViewBuilder private var exportSection: some View {
        heading("Export")
        Picker("Size", selection: Binding(get: { document.project.preset }, set: { v in document.perform { $0.preset = v } })) {
            ForEach(StudioExportPreset.allCases) { Text($0.title).tag($0) }
        }
        Picker("Format", selection: $format) {
            Text("MP4").tag(StudioExporter.Format.mp4)
            Text("GIF").tag(StudioExporter.Format.gif)
        }
        .pickerStyle(.segmented)
        Text("Output \(Int(document.layout.renderSize.width)) × \(Int(document.layout.renderSize.height))")
            .font(.caption).foregroundStyle(.secondary)
        if let progress = document.exportProgress {
            ProgressView(value: progress)
            Text("Exporting… \(Int(progress * 100))%").font(.caption).foregroundStyle(.secondary)
        } else {
            Button { onExport(format) } label: {
                Label("Export", systemImage: "square.and.arrow.up").frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent).controlSize(.large)
        }
    }
}

// MARK: - Timeline

private struct StudioTimeline: View {
    @ObservedObject var document: StudioDocument
    /// The value a drag started from, so the edit follows the pointer instead of compounding as it updates.
    @State private var dragOrigin: Double?

    private let laneTop: CGFloat = 22
    private let handleWidth: CGFloat = 10

    var body: some View {
        GeometryReader { geo in
            let width = max(1, geo.size.width)
            let duration = max(0.1, document.duration)
            let perPixel = duration / Double(width)
            let x = { (t: Double) in CGFloat(t / duration) * width }
            let trim = document.trim

            ZStack(alignment: .topLeading) {
                RoundedRectangle(cornerRadius: 8).fill(Color.secondary.opacity(0.14))
                    .contentShape(Rectangle())
                    .gesture(DragGesture(minimumDistance: 0).onChanged { document.seek(to: Double(min(max(0, $0.location.x), width)) * perPixel) })

                ruler(width: width, duration: duration)

                ForEach(document.project.zooms) { zoom in
                    zoomBlock(zoom, x: x, perPixel: perPixel, height: geo.size.height - laneTop - 8)
                }

                // Parts that will be cut
                Rectangle().fill(Color.black.opacity(0.35)).frame(width: x(trim.start), height: geo.size.height).allowsHitTesting(false)
                Rectangle().fill(Color.black.opacity(0.35)).frame(width: width - x(trim.end), height: geo.size.height)
                    .offset(x: x(trim.end)).allowsHitTesting(false)
                trimHandle(at: x(trim.start), isStart: true, perPixel: perPixel)
                trimHandle(at: x(trim.end), isStart: false, perPixel: perPixel)

                Rectangle().fill(Color.red).frame(width: 2, height: geo.size.height)
                    .offset(x: x(document.currentTime) - 1).allowsHitTesting(false)
            }
            .clipShape(RoundedRectangle(cornerRadius: 8))
        }
    }

    private func ruler(width: CGFloat, duration: Double) -> some View {
        let step = [1.0, 2, 5, 10, 15, 30, 60, 120, 300].first { duration / $0 <= 12 } ?? 600
        return ZStack(alignment: .topLeading) {
            ForEach(0..<Int(duration / step) + 1, id: \.self) { index in
                let t = Double(index) * step
                Text(DurationFormat.string(t)).font(.system(size: 9, design: .monospaced)).foregroundStyle(.secondary)
                    .offset(x: CGFloat(t / duration) * width + 3, y: 3)
            }
        }
        .allowsHitTesting(false)
    }

    /// A drag that edits one number. `origin` is its value when the drag began; `apply` receives that value plus the drag in seconds.
    private func drag(origin: @escaping () -> Double, perPixel: Double, apply: @escaping (Double) -> Void) -> some Gesture {
        DragGesture(minimumDistance: 2)
            .onChanged { value in
                if dragOrigin == nil { document.beginChange(); dragOrigin = origin() }
                apply((dragOrigin ?? 0) + Double(value.translation.width) * perPixel)
            }
            .onEnded { _ in
                document.endChange()
                dragOrigin = nil
            }
    }

    private func zoomBlock(_ zoom: ZoomSegment, x: (Double) -> CGFloat, perPixel: Double, height: CGFloat) -> some View {
        let selected = document.selectedZoom == zoom.id
        let left = x(zoom.start), blockWidth = max(14, x(zoom.end) - x(zoom.start))
        let length = zoom.duration
        let id = zoom.id
        return ZStack(alignment: .leading) {
            RoundedRectangle(cornerRadius: 6)
                .fill(Color.accentColor.opacity(selected ? 0.85 : 0.55))
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.white.opacity(selected ? 0.9 : 0), lineWidth: 1.5))
            Text(String(format: "%.1f×", zoom.scale)).font(.system(size: 10, weight: .semibold)).foregroundStyle(.white).padding(.leading, 12)
                .allowsHitTesting(false)
            HStack {
                handle.gesture(drag(origin: { zoom.start }, perPixel: perPixel) { value in
                    document.update { p in
                        guard let i = p.zooms.firstIndex(where: { $0.id == id }) else { return }
                        p.zooms[i].start = min(max(0, value), p.zooms[i].end - 0.5)
                    }
                })
                Spacer(minLength: 0)
                handle.gesture(drag(origin: { zoom.end }, perPixel: perPixel) { value in
                    document.update { p in
                        guard let i = p.zooms.firstIndex(where: { $0.id == id }) else { return }
                        p.zooms[i].end = max(min(document.duration, value), p.zooms[i].start + 0.5)
                    }
                })
            }
        }
        .frame(width: blockWidth, height: height)
        .offset(x: left, y: laneTop)
        .onTapGesture {
            document.selectedZoom = id
            document.seek(to: zoom.start)
        }
        .gesture(drag(origin: { zoom.start }, perPixel: perPixel) { value in
            if document.selectedZoom != id { document.selectedZoom = id }
            let start = min(max(0, value), max(0, document.duration - length))
            document.update { p in
                guard let i = p.zooms.firstIndex(where: { $0.id == id }) else { return }
                p.zooms[i].start = start
                p.zooms[i].end = start + length
            }
        })
    }

    private var handle: some View {
        Rectangle().fill(Color.white.opacity(0.001)).frame(width: handleWidth)
            .overlay(Capsule().fill(Color.white.opacity(0.85)).frame(width: 3, height: 14))
    }

    private func trimHandle(at position: CGFloat, isStart: Bool, perPixel: Double) -> some View {
        Capsule().fill(Color.yellow).frame(width: 6, height: 36)
            .overlay(Capsule().stroke(Color.black.opacity(0.3), lineWidth: 0.5))
            .padding(8)
            .contentShape(Rectangle())
            .offset(x: position - 11, y: 0)
            .gesture(drag(origin: { isStart ? document.trim.start : document.trim.end }, perPixel: perPixel) { value in
                document.update { p in
                    let full = document.duration
                    if isStart { p.trimStart = min(max(0, value), (p.trimEnd ?? full) - 0.1) }
                    else { p.trimEnd = max(min(full, value), p.trimStart + 0.1) }
                }
                document.seek(to: value)
            })
    }
}
