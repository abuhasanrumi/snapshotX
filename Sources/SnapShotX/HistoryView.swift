import AppKit
import SwiftUI

struct HistoryView: View {
    @ObservedObject var store: HistoryStore
    let actions: HistoryActions

    @State private var confirmingClear = false

    private let columns = [GridItem(.adaptive(minimum: 190, maximum: 260), spacing: 14)]

    var body: some View {
        Group {
            if store.items.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "clock.arrow.circlepath").font(.system(size: 36)).foregroundStyle(.secondary)
                    Text("No captures yet").font(.headline)
                    Text("Screenshots and recordings you take stay here for 30 days.").foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVGrid(columns: columns, spacing: 14) {
                        ForEach(store.items) { item in
                            HistoryCell(item: item, url: store.url(for: item), actions: actions)
                        }
                    }
                    .padding(16)
                }
            }
        }
        .frame(minWidth: 520, minHeight: 360)
        .toolbar {
            ToolbarItem {
                IconButton(symbol: "trash", help: "Clear all history", size: 28) { confirmingClear = true }
                    .disabled(store.items.isEmpty)
            }
        }
        .confirmationDialog("Delete all \(store.items.count) captures from history?",
                            isPresented: $confirmingClear, titleVisibility: .visible) {
            Button("Delete All", role: .destructive) { store.removeAll() }
        } message: {
            Text("Files you saved elsewhere are not affected.")
        }
    }
}

struct HistoryActions {
    var annotate: (CaptureItem) -> Void
    var pin: (CaptureItem) -> Void
    var copy: (CaptureItem) -> Void
    var saveAs: (CaptureItem) -> Void
    var reveal: (CaptureItem) -> Void
    var open: (CaptureItem) -> Void
    var delete: (CaptureItem) -> Void
}

private struct HistoryCell: View {
    let item: CaptureItem
    let url: URL
    let actions: HistoryActions

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            AsyncThumbnail(url: url)
                .frame(height: 130)
                .frame(maxWidth: .infinity)
                .background(RoundedRectangle(cornerRadius: 8).fill(Color.secondary.opacity(0.12)))
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .overlay(alignment: .bottomLeading) {
                    if item.isRecording, let seconds = item.durationSeconds {
                        HStack(spacing: 4) {
                            Image(systemName: item.isVideoFile ? "play.fill" : "photo.on.rectangle.angled")
                            Text(DurationFormat.string(seconds)).monospacedDigit()
                        }
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(Capsule().fill(Color.black.opacity(0.7)))
                        .padding(6)
                    }
                }
                .onTapGesture(count: 2) { item.isRecording ? actions.open(item) : actions.annotate(item) }
                .onDrag { NSItemProvider(contentsOf: url) ?? NSItemProvider() }
            Text(item.createdAt.formatted(date: .abbreviated, time: .shortened))
                .font(.caption)
            Text("\(item.pixelWidth) × \(item.pixelHeight)")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .contextMenu {
            if item.isRecording {
                Button(item.isVideoFile ? "Play" : "Open") { actions.open(item) }
            } else {
                Button("Annotate…") { actions.annotate(item) }
                Button("Pin to Screen") { actions.pin(item) }
            }
            Button("Copy") { actions.copy(item) }
            Button("Save As…") { actions.saveAs(item) }
            if !item.isRecording { Button("Open in Default App") { actions.open(item) } }
            Button("Show in Finder") { actions.reveal(item) }
            Divider()
            Button("Delete", role: .destructive) { actions.delete(item) }
        }
    }
}

private struct AsyncThumbnail: View {
    let url: URL
    @State private var image: NSImage?

    var body: some View {
        Group {
            if let image {
                Image(nsImage: image).resizable().scaledToFit()
            } else {
                ProgressView().controlSize(.small)
            }
        }
        .task(id: url) {
            let url = url
            let loaded = await Task.detached(priority: .utility) {
                ImageFile.thumbnail(url: url, maxPixelSize: 520)
            }.value
            image = loaded.map { NSImage(cgImage: $0, size: .zero) }
        }
    }
}

@MainActor
final class HistoryWindowController {
    private var window: NSWindow?
    private let store: HistoryStore
    private let actions: HistoryActions

    init(store: HistoryStore, actions: HistoryActions) {
        self.store = store
        self.actions = actions
    }

    func show() {
        if window == nil {
            let window = NSWindow(contentViewController: NSHostingController(rootView: HistoryView(store: store, actions: actions)))
            window.title = "Capture History"
            window.styleMask = [.titled, .closable, .resizable, .miniaturizable]
            window.setContentSize(NSSize(width: 760, height: 520))
            window.isReleasedWhenClosed = false
            window.center()
            self.window = window
        }
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }
}
