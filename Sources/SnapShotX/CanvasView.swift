import AppKit
import Combine
import SwiftUI

/// Draws the edit and turns mouse and keyboard input into annotation changes.
final class AnnotationCanvasView: NSView, NSTextFieldDelegate, NSUserInterfaceValidations {
    private let document: AnnotationDocument
    private let cache = EffectCache()
    private var cancellables = Set<AnyCancellable>()
    var onCopy: () -> Void = {}

    private enum Drag {
        case creating(id: UUID, start: CGPoint)
        case moving(id: UUID, last: CGPoint)
        case resizing(id: UUID, handle: HandleID)
        case cropping(start: CGPoint)
    }

    private struct RenderKey: Equatable {
        var state: EditorState
        var scale: Double
        var ignoring: Bool
        var hiding: UUID?
    }

    private struct Mapping {
        var geo: CompositeGeometry
        var scale: CGFloat
        var origin: CGPoint

        var canvasRect: CGRect {
            CGRect(x: origin.x, y: origin.y, width: geo.canvasSize.width * scale, height: geo.canvasSize.height * scale)
        }

        func viewPoint(fromImage p: CGPoint) -> CGPoint {
            let c = geo.canvasPoint(fromImage: p)
            return CGPoint(x: origin.x + c.x * scale, y: origin.y + c.y * scale)
        }

        func imagePoint(fromView p: CGPoint) -> CGPoint {
            geo.imagePoint(fromCanvas: CGPoint(x: (p.x - origin.x) / scale, y: (p.y - origin.y) / scale))
        }

        func viewRect(fromImage r: CGRect) -> CGRect {
            let a = viewPoint(fromImage: CGPoint(x: r.minX, y: r.minY))
            let b = viewPoint(fromImage: CGPoint(x: r.maxX, y: r.maxY))
            return CGRect(x: a.x, y: a.y, width: b.x - a.x, height: b.y - a.y)
        }
    }

    private var drag: Drag?
    private var lastRender: (key: RenderKey, image: CGImage)?
    private var editingField: NSTextField?
    private var editingTarget: (id: UUID?, origin: CGPoint, color: RGBAColor, fontSize: Double)?

    init(document: AnnotationDocument) {
        self.document = document
        super.init(frame: .zero)
        document.objectWillChange
            .sink { [weak self] in
                DispatchQueue.main.async {
                    guard let self else { return }
                    self.needsDisplay = true
                    self.window?.invalidateCursorRects(for: self)
                }
            }
            .store(in: &cancellables)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        window?.makeFirstResponder(self)
    }

    override func resetCursorRects() {
        let creating: Set<AnnotationTool> = [.select]
        addCursorRect(bounds, cursor: creating.contains(document.tool) ? .arrow : .crosshair)
    }

    // MARK: Layout

    private var ignoringCropAndBackground: Bool { document.tool == .crop }

    private func mapping() -> Mapping {
        let geo = Renderer.geometry(imageSize: document.imageSize, state: document.state,
                                    ignoreCropAndBackground: ignoringCropAndBackground)
        let margin: CGFloat = 24
        let available = CGSize(width: max(1, bounds.width - margin * 2), height: max(1, bounds.height - margin * 2))
        let scale = min(available.width / geo.canvasSize.width, available.height / geo.canvasSize.height, 1)
        let size = CGSize(width: geo.canvasSize.width * scale, height: geo.canvasSize.height * scale)
        return Mapping(geo: geo, scale: scale,
                       origin: CGPoint(x: (bounds.width - size.width) / 2, y: (bounds.height - size.height) / 2))
    }

    private func imagePoint(_ event: NSEvent, mapping m: Mapping) -> CGPoint {
        m.imagePoint(fromView: convert(event.locationInWindow, from: nil))
    }

    // MARK: Drawing

    override func draw(_ dirtyRect: NSRect) {
        NSColor(white: 0.14, alpha: 1).setFill()
        bounds.fill()

        let m = mapping()
        let backing = window?.backingScaleFactor ?? 2
        let key = RenderKey(state: document.state, scale: Double(m.scale * backing),
                            ignoring: ignoringCropAndBackground, hiding: editingTarget?.id)
        let image: CGImage
        if let last = lastRender, last.key == key {
            image = last.image
        } else if let rendered = Renderer.render(base: document.baseImage, state: document.state, scale: m.scale * backing,
                                                 ignoreCropAndBackground: ignoringCropAndBackground,
                                                 hiding: editingTarget?.id, cache: cache) {
            lastRender = (key, rendered)
            image = rendered
        } else {
            return
        }

        let canvas = m.canvasRect
        NSImage(cgImage: image, size: canvas.size)
            .draw(in: canvas, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)

        if document.tool == .crop {
            drawCropOverlay(m)
        } else {
            drawSelection(m)
        }
    }

    private func drawSelection(_ m: Mapping) {
        guard let selected = document.selected else { return }
        let rect = m.viewRect(fromImage: selected.bounds)
        let outline = NSBezierPath(rect: rect.insetBy(dx: -2, dy: -2))
        outline.setLineDash([5, 4], count: 2, phase: 0)
        outline.lineWidth = 1
        NSColor.controlAccentColor.setStroke()
        outline.stroke()

        for handle in selected.handles {
            let p = m.viewPoint(fromImage: handle.point)
            let box = NSRect(x: p.x - 5, y: p.y - 5, width: 10, height: 10)
            NSColor.white.setFill()
            NSBezierPath(ovalIn: box).fill()
            NSColor.controlAccentColor.setStroke()
            let ring = NSBezierPath(ovalIn: box)
            ring.lineWidth = 1.5
            ring.stroke()
        }
    }

    private func drawCropOverlay(_ m: Mapping) {
        let full = m.viewRect(fromImage: document.imageRect)
        let crop = document.state.crop.map { m.viewRect(fromImage: $0) } ?? full
        let dim = NSBezierPath(rect: full)
        dim.append(NSBezierPath(rect: crop))
        dim.windingRule = .evenOdd
        NSColor.black.withAlphaComponent(0.55).setFill()
        dim.fill()

        let border = NSBezierPath(rect: crop)
        border.lineWidth = 1.5
        NSColor.white.setStroke()
        border.stroke()

        if let size = document.state.crop?.size {
            let text = "\(Int(size.width)) × \(Int(size.height))  ·  Return to apply" as NSString
            let attributes: [NSAttributedString.Key: Any] = [
                .font: NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .medium), .foregroundColor: NSColor.white,
            ]
            let textSize = text.size(withAttributes: attributes)
            let pill = NSRect(x: crop.minX, y: max(full.minY, crop.minY - textSize.height - 12),
                              width: textSize.width + 12, height: textSize.height + 6)
            NSColor.black.withAlphaComponent(0.75).setFill()
            NSBezierPath(roundedRect: pill, xRadius: 6, yRadius: 6).fill()
            text.draw(at: NSPoint(x: pill.minX + 6, y: pill.minY + 3), withAttributes: attributes)
        }
    }

    // MARK: Mouse

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self) // also commits any text being edited
        let m = mapping()
        let p = imagePoint(event, mapping: m)
        let tolerance = 6 / m.scale

        switch document.tool {
        case .select:
            mouseDownSelect(at: p, tolerance: tolerance, clickCount: event.clickCount)
        case .crop:
            document.beginChange()
            drag = .cropping(start: Geometry.clamp(p, to: document.imageRect))
        case .text:
            if let existing = textAnnotation(at: p, tolerance: tolerance) {
                beginTextEditing(existing: existing, mapping: m)
            } else {
                beginTextEditing(newAt: Geometry.clamp(p, to: document.imageRect), mapping: m)
            }
        case .counter:
            let center = Geometry.clamp(p, to: document.imageRect)
            let annotation = makeAnnotation(for: .counter, at: center)!
            document.perform { $0.annotations.append(annotation) }
            document.selectedID = annotation.id
        default:
            let start = Geometry.clamp(p, to: document.imageRect)
            guard let annotation = makeAnnotation(for: document.tool, at: start) else { return }
            document.beginChange()
            document.update { $0.annotations.append(annotation) }
            document.selectedID = annotation.id
            drag = .creating(id: annotation.id, start: start)
        }
    }

    private func mouseDownSelect(at p: CGPoint, tolerance: CGFloat, clickCount: Int) {
        if let selected = document.selected {
            for handle in selected.handles where hypot(handle.point.x - p.x, handle.point.y - p.y) <= tolerance * 1.6 {
                document.beginChange()
                drag = .resizing(id: selected.id, handle: handle.id)
                return
            }
        }
        if let hit = document.state.annotations.last(where: { $0.hitTest(p, tolerance: tolerance) }) {
            document.selectedID = hit.id
            if clickCount == 2, case .text = hit.kind {
                beginTextEditing(existing: hit, mapping: mapping())
                return
            }
            document.beginChange()
            drag = .moving(id: hit.id, last: p)
        } else {
            document.selectedID = nil
        }
    }

    override func mouseDragged(with event: NSEvent) {
        let m = mapping()
        let raw = imagePoint(event, mapping: m)
        let p = Geometry.clamp(raw, to: document.imageRect)
        let shift = event.modifierFlags.contains(.shift)

        switch drag {
        case .creating(let id, let start):
            document.update { state in
                guard let i = state.annotations.firstIndex(where: { $0.id == id }) else { return }
                state.annotations[i].kind = Self.kind(state.annotations[i].kind, draggedFrom: start, to: p, constrain: shift)
            }
        case .moving(let id, let last):
            let delta = CGVector(dx: raw.x - last.x, dy: raw.y - last.y)
            document.update { state in
                guard let i = state.annotations.firstIndex(where: { $0.id == id }) else { return }
                state.annotations[i] = state.annotations[i].translated(by: delta)
            }
            drag = .moving(id: id, last: raw)
        case .resizing(let id, let handle):
            document.update { state in
                guard let i = state.annotations.firstIndex(where: { $0.id == id }) else { return }
                state.annotations[i] = state.annotations[i].resized(handle: handle, to: p)
            }
        case .cropping(let start):
            let rect: CGRect
            if let aspect = document.cropAspect {
                rect = Geometry.aspectRect(from: start, to: p, aspect: aspect, within: document.imageRect).integral
            } else {
                rect = Geometry.normalizedRect(from: start, to: p).integral
            }
            document.update { $0.crop = rect }
        case nil:
            break
        }
    }

    override func mouseUp(with event: NSEvent) {
        defer {
            drag = nil
            document.endChange()
        }
        switch drag {
        case .creating(let id, _):
            document.update { state in
                guard let i = state.annotations.firstIndex(where: { $0.id == id }) else { return }
                let annotation = state.annotations[i]
                if Self.isDegenerate(annotation) {
                    state.annotations.remove(at: i)
                } else if case .pencil(let points) = annotation.kind {
                    state.annotations[i].kind = .pencil(points: PathSmoothing.smooth(points))
                }
            }
        case .cropping:
            if let crop = document.state.crop, crop.width < 8 || crop.height < 8 {
                document.update { $0.crop = nil }
            }
        default:
            break
        }
    }

    private static func kind(_ kind: AnnotationKind, draggedFrom start: CGPoint, to p: CGPoint, constrain: Bool) -> AnnotationKind {
        func rect() -> CGRect { constrain ? Geometry.squareRect(from: start, to: p) : Geometry.normalizedRect(from: start, to: p) }
        let end = constrain ? Geometry.constrainedEnd(from: start, to: p) : p
        switch kind {
        case .arrow: return .arrow(start: start, end: end)
        case .line: return .line(start: start, end: end)
        case .rectangle(_, let filled): return .rectangle(rect: rect(), filled: filled)
        case .ellipse(_, let filled): return .ellipse(rect: rect(), filled: filled)
        case .spotlight: return .spotlight(rect: rect())
        case .blur: return .blur(rect: rect())
        case .pixelate: return .pixelate(rect: rect())
        case .pencil(var points): points.append(p); return .pencil(points: points)
        case .highlighter(var points): points.append(p); return .highlighter(points: points)
        case .text, .counter: return kind
        }
    }

    private static func isDegenerate(_ a: Annotation) -> Bool {
        switch a.kind {
        case .arrow(let s, let e), .line(let s, let e): return hypot(e.x - s.x, e.y - s.y) < 3
        case .rectangle(let r, _), .ellipse(let r, _), .spotlight(let r), .blur(let r), .pixelate(let r):
            return r.width < 3 || r.height < 3
        default: return false
        }
    }

    private func makeAnnotation(for tool: AnnotationTool, at p: CGPoint) -> Annotation? {
        let unit = document.strokeUnit
        let kind: AnnotationKind
        switch tool {
        case .arrow: kind = .arrow(start: p, end: p)
        case .line: kind = .line(start: p, end: p)
        case .rectangle: kind = .rectangle(rect: CGRect(origin: p, size: .zero), filled: false)
        case .filledRectangle: kind = .rectangle(rect: CGRect(origin: p, size: .zero), filled: true)
        case .ellipse: kind = .ellipse(rect: CGRect(origin: p, size: .zero), filled: false)
        case .pencil: kind = .pencil(points: [p])
        case .highlighter: kind = .highlighter(points: [p])
        case .spotlight: kind = .spotlight(rect: CGRect(origin: p, size: .zero))
        case .blur: kind = .blur(rect: CGRect(origin: p, size: .zero))
        case .pixelate: kind = .pixelate(rect: CGRect(origin: p, size: .zero))
        case .counter: kind = .counter(center: p, number: document.nextCounterNumber)
        case .text, .select, .crop: return nil
        }
        return Annotation(kind: kind, color: document.color,
                          lineWidth: document.widthSetting * unit, fontSize: document.widthSetting * 3.5 * unit)
    }

    // MARK: Text editing

    private func textAnnotation(at p: CGPoint, tolerance: CGFloat) -> Annotation? {
        document.state.annotations.last { annotation in
            if case .text = annotation.kind { return annotation.hitTest(p, tolerance: tolerance) }
            return false
        }
    }

    private func beginTextEditing(newAt origin: CGPoint, mapping m: Mapping) {
        let unit = document.strokeUnit
        startField(id: nil, origin: origin, text: "", color: document.color,
                   fontSize: document.widthSetting * 3.5 * unit, mapping: m)
    }

    private func beginTextEditing(existing: Annotation, mapping m: Mapping) {
        guard case .text(let origin, let string) = existing.kind else { return }
        document.selectedID = existing.id
        startField(id: existing.id, origin: origin, text: string, color: existing.color, fontSize: existing.fontSize, mapping: m)
    }

    private func startField(id: UUID?, origin: CGPoint, text: String, color: RGBAColor, fontSize: Double, mapping m: Mapping) {
        finishEditing(commit: true)
        editingTarget = (id, origin, color, fontSize)

        let pointSize = CGFloat(fontSize) * m.scale
        let field = NSTextField(string: text)
        field.isBordered = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.font = TextMetrics.font(size: Double(pointSize))
        field.textColor = color.nsColor
        field.delegate = self
        field.cell?.usesSingleLineMode = true
        field.cell?.isScrollable = true
        let viewOrigin = m.viewPoint(fromImage: origin)
        field.frame = NSRect(x: viewOrigin.x, y: viewOrigin.y, width: max(260, bounds.width - viewOrigin.x - 24),
                             height: ceil(pointSize * 1.3))
        addSubview(field)
        editingField = field
        window?.makeFirstResponder(field)
        needsDisplay = true
    }

    private func finishEditing(commit: Bool) {
        guard let field = editingField, let target = editingTarget else { return }
        editingField = nil
        editingTarget = nil
        let string = field.stringValue
        field.delegate = nil
        field.removeFromSuperview()

        if commit {
            if let id = target.id {
                document.perform { state in
                    guard let i = state.annotations.firstIndex(where: { $0.id == id }) else { return }
                    if string.isEmpty {
                        state.annotations.remove(at: i)
                    } else {
                        state.annotations[i].kind = .text(origin: target.origin, string: string)
                    }
                }
            } else if !string.isEmpty {
                let annotation = Annotation(kind: .text(origin: target.origin, string: string), color: target.color,
                                            lineWidth: document.widthSetting * document.strokeUnit, fontSize: target.fontSize)
                document.perform { $0.annotations.append(annotation) }
                document.selectedID = annotation.id
            }
        }
        window?.makeFirstResponder(self)
        needsDisplay = true
    }

    func controlTextDidEndEditing(_ obj: Notification) {
        finishEditing(commit: true)
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        if commandSelector == #selector(NSResponder.cancelOperation(_:)) {
            finishEditing(commit: false)
            return true
        }
        return false
    }

    // MARK: Keyboard and menu actions

    override func keyDown(with event: NSEvent) {
        let step: CGFloat = event.modifierFlags.contains(.shift) ? 10 : 1
        switch event.keyCode {
        case 51, 117: document.removeSelected()
        case 53:
            if document.tool == .crop { document.tool = .select } else { document.selectedID = nil }
        case 36, 76:
            if document.tool == .crop { document.tool = .select }
        case 123: document.nudgeSelected(by: CGVector(dx: -step, dy: 0))
        case 124: document.nudgeSelected(by: CGVector(dx: step, dy: 0))
        case 125: document.nudgeSelected(by: CGVector(dx: 0, dy: step))
        case 126: document.nudgeSelected(by: CGVector(dx: 0, dy: -step))
        default: super.keyDown(with: event)
        }
    }

    @objc func undo(_ sender: Any?) { document.undo() }
    @objc func redo(_ sender: Any?) { document.redo() }
    @objc func copy(_ sender: Any?) { onCopy() }

    func validateUserInterfaceItem(_ item: NSValidatedUserInterfaceItem) -> Bool {
        switch item.action {
        case #selector(undo(_:)): return document.canUndo
        case #selector(redo(_:)): return document.canRedo
        default: return true
        }
    }
}

struct AnnotationCanvas: NSViewRepresentable {
    let document: AnnotationDocument
    let onCopy: () -> Void

    func makeNSView(context: Context) -> AnnotationCanvasView {
        let view = AnnotationCanvasView(document: document)
        view.onCopy = onCopy
        return view
    }

    func updateNSView(_ view: AnnotationCanvasView, context: Context) {
        view.onCopy = onCopy
    }
}
