import CoreGraphics
import Foundation

/// Everything that makes up an edit, apart from the original pixels. Saved in project files and used for undo.
struct EditorState: Codable, Equatable {
    var annotations: [Annotation] = []
    /// Non-destructive crop in image pixels.
    var crop: CGRect?
    var background = BackgroundStyle()
}

@MainActor
final class AnnotationDocument: ObservableObject {
    let baseImage: CGImage
    @Published private(set) var state: EditorState
    @Published private(set) var canUndo = false
    @Published private(set) var canRedo = false

    @Published var tool: AnnotationTool = .arrow
    @Published private(set) var color: RGBAColor = .red
    /// 1 to 12. Scaled to image pixels by `strokeUnit`.
    @Published private(set) var widthSetting: Double = 4
    @Published var selectedID: UUID?
    @Published var showsBackgroundInspector = false

    private var undoStack: [EditorState] = []
    private var redoStack: [EditorState] = []
    private var pending: EditorState?

    init(image: CGImage, state: EditorState = EditorState()) {
        baseImage = image
        self.state = state
    }

    var imageSize: CGSize { CGSize(width: baseImage.width, height: baseImage.height) }
    var imageRect: CGRect { CGRect(origin: .zero, size: imageSize) }

    /// One "width unit" in image pixels, so strokes look the same on a 1x and a 3x screenshot.
    var strokeUnit: Double { max(1, Double(max(baseImage.width, baseImage.height)) / 800) }

    var selected: Annotation? { state.annotations.first { $0.id == selectedID } }

    var nextCounterNumber: Int {
        let numbers = state.annotations.compactMap { annotation -> Int? in
            if case .counter(_, let n) = annotation.kind { return n }
            return nil
        }
        return (numbers.max() ?? 0) + 1
    }

    // MARK: Change tracking

    /// Marks the start of a user gesture. The state at this moment becomes one undo step.
    func beginChange() {
        if pending == nil { pending = state }
    }

    func endChange() {
        guard let before = pending else { return }
        pending = nil
        guard before != state else { return }
        undoStack.append(before)
        redoStack.removeAll()
        refreshUndoFlags()
    }

    /// Applies a change without creating an undo step, for use between `beginChange` and `endChange`.
    func update(_ change: (inout EditorState) -> Void) {
        var next = state
        change(&next)
        if next != state { state = next }
    }

    /// A one-shot change that is a single undo step.
    func perform(_ change: (inout EditorState) -> Void) {
        beginChange()
        update(change)
        endChange()
    }

    func undo() {
        guard let previous = undoStack.popLast() else { return }
        redoStack.append(state)
        state = previous
        pending = nil
        refreshUndoFlags()
    }

    func redo() {
        guard let next = redoStack.popLast() else { return }
        undoStack.append(state)
        state = next
        pending = nil
        refreshUndoFlags()
    }

    private func refreshUndoFlags() {
        canUndo = !undoStack.isEmpty
        canRedo = !redoStack.isEmpty
    }

    // MARK: Editing helpers

    func removeSelected() {
        guard let id = selectedID else { return }
        perform { $0.annotations.removeAll { $0.id == id } }
        selectedID = nil
    }

    func nudgeSelected(by delta: CGVector) {
        guard let id = selectedID else { return }
        perform { state in
            guard let i = state.annotations.firstIndex(where: { $0.id == id }) else { return }
            state.annotations[i] = state.annotations[i].translated(by: delta)
        }
    }

    /// Sets the drawing color, and recolors the selected annotation too.
    func setColor(_ newColor: RGBAColor) {
        color = newColor
        guard let id = selectedID else { return }
        perform { state in
            guard let i = state.annotations.firstIndex(where: { $0.id == id }) else { return }
            state.annotations[i].color = newColor
        }
    }

    func setWidthSetting(_ value: Double) {
        widthSetting = value
        guard let id = selectedID else { return }
        update { state in
            guard let i = state.annotations.firstIndex(where: { $0.id == id }) else { return }
            state.annotations[i].lineWidth = value * strokeUnit
            state.annotations[i].fontSize = value * 3.5 * strokeUnit
        }
    }

    func clearCrop() {
        perform { $0.crop = nil }
    }
}
