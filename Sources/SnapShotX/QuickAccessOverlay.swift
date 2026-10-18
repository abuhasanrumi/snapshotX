import AppKit
import SwiftUI

/// The card that appears in a screen corner after a capture. It stays until it is closed or the next
/// capture replaces it, so it never vanishes while you are still deciding. Once its capture has been copied (automatically
/// or by the Copy button) it leaves by itself after `copiedLifetime` seconds.
@MainActor
final class QuickAccessController: ObservableObject {
    struct Entry: Identifiable {
        let item: CaptureItem
        let url: URL
        let thumbnail: NSImage
        var badge: String?
        var id: UUID { item.id }
    }

    static let cardWidth: CGFloat = 212
    static let cardHeight: CGFloat = 140
    private static let padding: CGFloat = 10

    /// Zero or one entry: a new capture replaces the old card.
    @Published private(set) var entries: [Entry] = []

    var onCopy: (CaptureItem) -> Bool = { _ in false }
    var onSave: (CaptureItem) -> Bool = { _ in false }
    var onAnnotate: (CaptureItem) -> Void = { _ in }
    var onOpen: (CaptureItem) -> Void = { _ in }

    private let prefs: Preferences
    private let showsPanel: Bool
    private var panel: NSPanel?
    private var expiry: Task<Void, Never>?
    /// How long a card stays after its capture has been copied. Copying again starts the time over.
    var copiedLifetime: TimeInterval = 30

    /// `showsPanel: false` keeps the state without putting a window on screen, for tests.
    init(prefs: Preferences, showsPanel: Bool = true) {
        self.prefs = prefs
        self.showsPanel = showsPanel
    }

    var stackAlignment: Alignment { prefs.overlayCorner.isBottom ? .bottom : .top }

    /// Shows a capture in the corner, replacing whatever was there. `notice` is a short confirmation
    /// (such as "Copied") shown on the card for a moment.
    func add(item: CaptureItem, url: URL, notice: String? = nil) {
        let image = ImageFile.thumbnail(url: url, maxPixelSize: 480)
            .map { NSImage(cgImage: $0, size: .zero) } ?? NSImage()
        entries = [Entry(item: item, url: url, thumbnail: image)]
        presentPanel()
        expiry?.cancel()
        if let notice { flash(notice, for: item.id) }
        if notice == "Copied" { scheduleExpiry(for: item.id) }
    }

    private func scheduleExpiry(for id: UUID) {
        expiry?.cancel()
        let lifetime = copiedLifetime
        expiry = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(lifetime * 1_000_000_000))
            guard !Task.isCancelled else { return }
            self?.dismiss(id)
        }
    }

    func dismiss(_ id: UUID) {
        entries.removeAll { $0.id == id }
        if entries.isEmpty { panel?.orderOut(nil) }
    }

    func copy(_ id: UUID) {
        guard let entry = entries.first(where: { $0.id == id }) else { return }
        let copied = onCopy(entry.item)
        flash(copied ? "Copied" : "Copy failed", for: id)
        if copied { scheduleExpiry(for: id) }
    }

    func save(_ id: UUID) {
        guard let entry = entries.first(where: { $0.id == id }) else { return }
        flash(onSave(entry.item) ? "Saved" : "Save failed", for: id)
    }

    /// Opens the editor. The card stays, so the original can still be copied or saved.
    func annotate(_ id: UUID) {
        guard let entry = entries.first(where: { $0.id == id }) else { return }
        onAnnotate(entry.item)
    }

    /// Plays a recording. The card stays.
    func open(_ id: UUID) {
        guard let entry = entries.first(where: { $0.id == id }) else { return }
        onOpen(entry.item)
    }

    // MARK: Internals

    private func flash(_ text: String, for id: UUID) {
        guard let index = entries.firstIndex(where: { $0.id == id }) else { return }
        entries[index].badge = text
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.6) { [weak self] in
            MainActor.assumeIsolated {
                guard let self, let i = self.entries.firstIndex(where: { $0.id == id }) else { return }
                self.entries[i].badge = nil
            }
        }
    }

    private func presentPanel() {
        guard showsPanel else { return }
        if panel == nil {
            let panel = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel],
                                backing: .buffered, defer: false)
            panel.level = .floating
            panel.isOpaque = false
            panel.backgroundColor = .clear
            panel.hasShadow = false
            panel.hidesOnDeactivate = false
            panel.isReleasedWhenClosed = false
            panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
            panel.contentView = NSHostingView(rootView: QuickAccessView(controller: self))
            self.panel = panel
        }
        layoutPanel()
        panel?.orderFrontRegardless()
    }

    private func layoutPanel() {
        guard let panel, let screen = NSScreen.underMouse else { return }
        let width = Self.cardWidth + Self.padding * 2
        let height = Self.cardHeight + Self.padding * 2

        let area = screen.visibleFrame
        let corner = prefs.overlayCorner
        let x = corner.isLeft ? area.minX + 6 : area.maxX - width - 6
        let y = corner.isBottom ? area.minY + 6 : area.maxY - height - 6
        panel.setFrame(NSRect(x: x, y: y, width: width, height: height), display: true)
    }
}

struct QuickAccessView: View {
    @ObservedObject var controller: QuickAccessController

    var body: some View {
        VStack(spacing: 0) {
            ForEach(controller.entries) { entry in
                QuickAccessCard(entry: entry, controller: controller)
                    .transition(.opacity)
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: controller.stackAlignment)
        .animation(.easeOut(duration: 0.18), value: controller.entries.map(\.id))
    }
}

struct QuickAccessCard: View {
    let entry: QuickAccessController.Entry
    let controller: QuickAccessController
    /// Shows the actions without a hover, for previews.
    var forceActions = false
    @State private var hovering = false

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 12).fill(Color.black.opacity(0.6))
            Image(nsImage: entry.thumbnail)
                .resizable()
                .scaledToFit()
                .padding(8)

            if entry.item.isRecording, let seconds = entry.item.durationSeconds {
                VStack {
                    Spacer()
                    HStack {
                        HStack(spacing: 4) {
                            Image(systemName: entry.item.isVideoFile ? "video.fill" : "photo.on.rectangle.angled")
                            Text(DurationFormat.string(seconds)).monospacedDigit()
                        }
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(Capsule().fill(Color.black.opacity(0.7)))
                        Spacer()
                    }
                }
                .padding(8)
                .allowsHitTesting(false)
            }

            if hovering || forceActions {
                Color.black.opacity(0.45)
                // Edit, copy, save. The tooltip says which is which.
                HStack(spacing: 12) {
                    if entry.item.isRecording {
                        if entry.item.isVideoFile {
                            IconButton(symbol: "square.and.pencil", help: "Edit in Studio", style: .overMedia, size: 38) { controller.annotate(entry.id) }
                        }
                        IconButton(symbol: "play.fill", help: "Play", style: .overMedia, size: 38) { controller.open(entry.id) }
                    } else {
                        IconButton(symbol: "square.and.pencil", help: "Edit", style: .overMedia, size: 38) { controller.annotate(entry.id) }
                    }
                    IconButton(symbol: "doc.on.doc", help: entry.item.isRecording ? "Copy file" : "Copy", style: .overMedia, size: 38) { controller.copy(entry.id) }
                    IconButton(symbol: "square.and.arrow.down", help: "Save", style: .overMedia, size: 38) { controller.save(entry.id) }
                }
            }

            // Always there, because the card stays until it is closed.
            VStack {
                HStack {
                    IconButton(symbol: "xmark", help: "Close", style: .dark, size: 22) { controller.dismiss(entry.id) }
                    Spacer()
                }
                Spacer()
            }
            .padding(7)

            // Feedback goes in the corner so it never covers the icons it is reporting on.
            if let badge = entry.badge {
                VStack {
                    HStack {
                        Spacer()
                        Text(badge)
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 9)
                            .padding(.vertical, 4)
                            .background(Capsule().fill(Color.accentColor))
                    }
                    Spacer()
                }
                .padding(7)
                .allowsHitTesting(false)
            }
        }
        .frame(width: QuickAccessController.cardWidth, height: QuickAccessController.cardHeight)
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.white.opacity(0.15), lineWidth: 1))
        .shadow(color: .black.opacity(0.35), radius: 8, y: 3)
        .onHover { hovering = $0 }
        .onDrag { NSItemProvider(contentsOf: entry.url) ?? NSItemProvider() }
    }
}
