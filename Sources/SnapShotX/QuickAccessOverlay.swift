import AppKit
import SwiftUI

/// The small floating stack of cards that appears in a screen corner after each capture.
@MainActor
final class QuickAccessController: ObservableObject {
    struct Entry: Identifiable {
        let item: CaptureItem
        let url: URL
        let thumbnail: NSImage
        var expiresAt: Date
        var badge: String?
        var id: UUID { item.id }
    }

    static let cardWidth: CGFloat = 212
    static let cardHeight: CGFloat = 140
    private static let spacing: CGFloat = 10
    private static let padding: CGFloat = 10
    private static let maxCards = 4

    @Published private(set) var entries: [Entry] = []

    var onCopy: (CaptureItem) -> Bool = { _ in false }
    var onSave: (CaptureItem) -> Bool = { _ in false }
    var onAnnotate: (CaptureItem) -> Void = { _ in }
    var onPin: (CaptureItem) -> Void = { _ in }

    private let prefs: Preferences
    private var panel: NSPanel?
    private var timer: Timer?

    init(prefs: Preferences) {
        self.prefs = prefs
    }

    /// Entries in on-screen order: the newest card sits closest to the chosen corner.
    var displayEntries: [Entry] {
        prefs.overlayCorner.isBottom ? entries.reversed() : entries
    }

    var stackAlignment: Alignment { prefs.overlayCorner.isBottom ? .bottom : .top }

    func add(item: CaptureItem, url: URL) {
        let image = ImageFile.thumbnail(url: url, maxPixelSize: 480)
            .map { NSImage(cgImage: $0, size: .zero) } ?? NSImage()
        entries.insert(Entry(item: item, url: url, thumbnail: image, expiresAt: newExpiry()), at: 0)
        if entries.count > Self.maxCards { entries.removeLast(entries.count - Self.maxCards) }
        presentPanel()
        startTimer()
    }

    func dismiss(_ id: UUID) {
        entries.removeAll { $0.id == id }
        if entries.isEmpty { hidePanel() } else { layoutPanel() }
    }

    func setHovering(_ id: UUID, _ hovering: Bool) {
        guard let index = entries.firstIndex(where: { $0.id == id }) else { return }
        entries[index].expiresAt = hovering ? .distantFuture : newExpiry()
    }

    func copy(_ id: UUID) {
        guard let entry = entries.first(where: { $0.id == id }) else { return }
        flash(onCopy(entry.item) ? "Copied" : "Copy failed", for: id)
    }

    func save(_ id: UUID) {
        guard let entry = entries.first(where: { $0.id == id }) else { return }
        flash(onSave(entry.item) ? "Saved" : "Save failed", for: id)
    }

    func annotate(_ id: UUID) {
        guard let entry = entries.first(where: { $0.id == id }) else { return }
        onAnnotate(entry.item)
        dismiss(id)
    }

    func pin(_ id: UUID) {
        guard let entry = entries.first(where: { $0.id == id }) else { return }
        onPin(entry.item)
        dismiss(id)
    }

    // MARK: Internals

    private func newExpiry() -> Date {
        let seconds = prefs.overlayAutoCloseSeconds
        return seconds > 0 ? Date().addingTimeInterval(seconds) : .distantFuture
    }

    private func flash(_ text: String, for id: UUID) {
        guard let index = entries.firstIndex(where: { $0.id == id }) else { return }
        entries[index].badge = text
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.4) { [weak self] in
            MainActor.assumeIsolated {
                guard let self, let i = self.entries.firstIndex(where: { $0.id == id }) else { return }
                self.entries[i].badge = nil
            }
        }
    }

    private func startTimer() {
        guard timer == nil else { return }
        timer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.expireEntries() }
        }
    }

    private func expireEntries() {
        let now = Date()
        let expired = entries.filter { $0.expiresAt <= now }.map(\.id)
        expired.forEach(dismiss)
        if entries.isEmpty {
            timer?.invalidate()
            timer = nil
        }
    }

    private func presentPanel() {
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

    private func hidePanel() {
        panel?.orderOut(nil)
        timer?.invalidate()
        timer = nil
    }

    private func layoutPanel() {
        guard let panel, let screen = NSScreen.underMouse else { return }
        let count = CGFloat(entries.count)
        let width = Self.cardWidth + Self.padding * 2
        let height = count * Self.cardHeight + max(0, count - 1) * Self.spacing + Self.padding * 2

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
        VStack(spacing: 10) {
            ForEach(controller.displayEntries) { entry in
                QuickAccessCard(entry: entry, controller: controller)
                    .transition(.opacity)
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: controller.stackAlignment)
        .animation(.easeOut(duration: 0.18), value: controller.entries.count)
    }
}

private struct QuickAccessCard: View {
    let entry: QuickAccessController.Entry
    let controller: QuickAccessController
    @State private var hovering = false

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 12).fill(Color.black.opacity(0.6))
            Image(nsImage: entry.thumbnail)
                .resizable()
                .scaledToFit()
                .padding(8)

            if hovering {
                Color.black.opacity(0.45)
                VStack(spacing: 8) {
                    HStack(spacing: 8) {
                        CardButton(symbol: "pencil.tip.crop.circle", title: "Annotate") { controller.annotate(entry.id) }
                        CardButton(symbol: "pin", title: "Pin") { controller.pin(entry.id) }
                    }
                    HStack(spacing: 8) {
                        CardButton(symbol: "doc.on.doc", title: "Copy") { controller.copy(entry.id) }
                        CardButton(symbol: "square.and.arrow.down", title: "Save") { controller.save(entry.id) }
                    }
                }
                VStack {
                    HStack {
                        Spacer()
                        Button { controller.dismiss(entry.id) } label: {
                            Image(systemName: "xmark.circle.fill")
                                .font(.system(size: 18))
                                .foregroundStyle(.white.opacity(0.9))
                        }
                        .buttonStyle(.plain)
                        .help("Close")
                    }
                    Spacer()
                }
                .padding(6)
            }

            if let badge = entry.badge {
                Text(badge)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(Capsule().fill(Color.accentColor))
            }
        }
        .frame(width: QuickAccessController.cardWidth, height: QuickAccessController.cardHeight)
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.white.opacity(0.15), lineWidth: 1))
        .shadow(color: .black.opacity(0.35), radius: 8, y: 3)
        .onHover { inside in
            hovering = inside
            controller.setHovering(entry.id, inside)
        }
        .onDrag { NSItemProvider(contentsOf: entry.url) ?? NSItemProvider() }
    }
}

private struct CardButton: View {
    let symbol: String
    let title: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Label(title, systemImage: symbol)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.white)
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(Capsule().fill(Color.white.opacity(0.22)))
        }
        .buttonStyle(.plain)
    }
}
