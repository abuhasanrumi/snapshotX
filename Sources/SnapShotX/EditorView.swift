import AppKit
import SwiftUI

struct EditorActions {
    var copy: () -> Void
    var save: () -> Void
    var saveAs: () -> Void
    var saveProject: () -> Void
    var pin: () -> Void
    var dragFileURL: () -> URL?
}

struct EditorView: View {
    @ObservedObject var document: AnnotationDocument
    @ObservedObject var presets: BackgroundPresetStore
    let actions: EditorActions

    var body: some View {
        VStack(spacing: 0) {
            EditorToolbar(document: document, actions: actions)
            Divider()
            HStack(spacing: 0) {
                AnnotationCanvas(document: document, onCopy: actions.copy)
                if document.showsBackgroundInspector {
                    Divider()
                    BackgroundInspector(document: document, presets: presets)
                        .frame(width: 290)
                }
            }
        }
    }
}

// MARK: - Toolbar

struct EditorToolbar: View {
    @ObservedObject var document: AnnotationDocument
    let actions: EditorActions

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                HStack(spacing: 2) {
                    ForEach(AnnotationTool.allCases) { tool in
                        IconButton(symbol: tool.symbol, help: tool.title, shape: .square, size: 30, isOn: document.tool == tool) {
                            document.tool = tool
                        }
                    }
                }
                Divider().frame(height: 20)
                IconButton(symbol: "arrow.uturn.backward", help: "Undo  ⌘Z", size: 28) { document.undo() }
                    .disabled(!document.canUndo)
                IconButton(symbol: "arrow.uturn.forward", help: "Redo  ⇧⌘Z", size: 28) { document.redo() }
                    .disabled(!document.canRedo)
                Spacer(minLength: 8)
                if document.state.crop != nil {
                    IconButton(symbol: "arrow.counterclockwise", help: "Reset crop", size: 28) { document.clearCrop() }
                }
                IconButton(symbol: "photo.artframe", help: "Background, padding and shadow", shape: .square, size: 30,
                           isOn: document.showsBackgroundInspector) {
                    document.showsBackgroundInspector.toggle()
                }
                Divider().frame(height: 20)
                IconButton(symbol: "doc.on.doc", help: "Copy  ⌘C", size: 30) { actions.copy() }
                IconButton(symbol: "pin", help: "Pin to screen", size: 30) { actions.pin() }
                IconButton(symbol: "square.and.arrow.down", help: "Save", size: 30) { actions.save() }
                Menu {
                    Button("Save As…", action: actions.saveAs)
                    Button("Save Editable Project…", action: actions.saveProject)
                } label: { Image(systemName: "ellipsis.circle") }
                    .menuStyle(.borderlessButton)
                    .fixedSize()
                    .help("More ways to save")
                Image(systemName: "hand.draw")
                    .font(.system(size: 14, weight: .semibold))
                    .frame(width: 30, height: 30)
                    .background(Circle().fill(Color.secondary.opacity(0.18)))
                    .onDrag {
                        if let url = actions.dragFileURL() { return NSItemProvider(contentsOf: url) ?? NSItemProvider() }
                        return NSItemProvider()
                    }
                    .help("Drag the finished image into any app")
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)

            Divider()

            HStack(spacing: 8) {
                ForEach(RGBAColor.palette, id: \.self) { swatch in
                    Button { document.setColor(swatch) } label: {
                        Circle()
                            .fill(Color(nsColor: swatch.nsColor))
                            .frame(width: 18, height: 18)
                            .overlay(Circle().stroke(Color.primary.opacity(0.25), lineWidth: 1))
                            .overlay(Circle().stroke(Color.accentColor, lineWidth: document.color == swatch ? 2.5 : 0).padding(-3))
                    }
                    .buttonStyle(.plain)
                }
                ColorPicker("Color", selection: colorBinding, supportsOpacity: false)
                    .labelsHidden()
                    .help("Custom color. The picker can also sample any color on screen.")
                Divider().frame(height: 18)
                Image(systemName: "lineweight").foregroundStyle(.secondary)
                Slider(value: widthBinding, in: 1...12, onEditingChanged: { editing in
                    editing ? document.beginChange() : document.endChange()
                })
                .frame(width: 120)
                .help("Stroke width and text size")
                Spacer()
                Text(hint).font(.caption).foregroundStyle(.secondary)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
        }
    }

    private var colorBinding: Binding<Color> {
        Binding(get: { Color(nsColor: document.color.nsColor) },
                set: { document.setColor(RGBAColor(NSColor($0))) })
    }

    private var widthBinding: Binding<Double> {
        Binding(get: { document.widthSetting }, set: { document.setWidthSetting($0) })
    }

    private var hint: String {
        switch document.tool {
        case .select: return "Click to select, drag to move, ⌫ to delete"
        case .crop: return "Drag to crop, Return to apply"
        case .text: return "Click to type, Return to finish"
        case .counter: return "Click to place numbered steps"
        case .blur, .pixelate: return "Drag over what you want to hide"
        case .spotlight: return "Drag over what to emphasize"
        default: return "Hold ⇧ to constrain"
        }
    }
}

// MARK: - Background inspector

private struct BackgroundInspector: View {
    @ObservedObject var document: AnnotationDocument
    @ObservedObject var presets: BackgroundPresetStore

    var body: some View {
        BackgroundControls(
            style: document.state.background,
            presets: presets,
            apply: { change in document.perform { change(&$0.background) } },
            update: { change in document.update { change(&$0.background) } },
            beginChange: { document.beginChange() },
            endChange: { document.endChange() }
        )
    }
}
