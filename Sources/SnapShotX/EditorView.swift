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

    private var style: BackgroundStyle { document.state.background }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Toggle("Background", isOn: Binding(
                    get: { style.enabled },
                    set: { value in document.perform { $0.background.enabled = value } }
                ))
                .toggleStyle(.switch)
                .font(.headline)

                Group {
                    section("Gradients") {
                        LazyVGrid(columns: Array(repeating: GridItem(.fixed(44), spacing: 8), count: 5), spacing: 8) {
                            ForEach(BackgroundCatalog.gradients) { gradient in
                                Button { setFill(.gradient(gradient.spec)) } label: {
                                    RoundedRectangle(cornerRadius: 8)
                                        .fill(LinearGradient(colors: gradient.spec.colors.map { Color(nsColor: $0.nsColor) },
                                                             startPoint: .topLeading, endPoint: .bottomTrailing))
                                        .frame(width: 44, height: 44)
                                        .overlay(RoundedRectangle(cornerRadius: 8)
                                            .stroke(Color.accentColor, lineWidth: style.fill == .gradient(gradient.spec) ? 3 : 0))
                                }
                                .buttonStyle(.plain)
                                .help(gradient.name)
                            }
                        }
                    }

                    section("Solid and image") {
                        HStack(spacing: 8) {
                            ForEach(BackgroundCatalog.solids, id: \.self) { color in
                                Button { setFill(.solid(color)) } label: {
                                    Circle()
                                        .fill(Color(nsColor: color.nsColor))
                                        .frame(width: 24, height: 24)
                                        .overlay(Circle().stroke(Color.primary.opacity(0.25), lineWidth: 1))
                                        .overlay(Circle().stroke(Color.accentColor, lineWidth: style.fill == .solid(color) ? 2.5 : 0).padding(-3))
                                }
                                .buttonStyle(.plain)
                            }
                            ColorPicker("Custom", selection: customSolid, supportsOpacity: true).labelsHidden()
                            Spacer()
                            Button("Image…", action: chooseImage)
                        }
                    }

                    section("Layout") {
                        slider("Padding", value: \.padding, range: 0...0.5)
                        slider("Corners", value: \.cornerRadius, range: 0...0.1)
                        slider("Shadow", value: \.shadow, range: 0...1)
                        Picker("Aspect ratio", selection: Binding(
                            get: { style.aspect },
                            set: { value in document.perform { $0.background.aspect = value } }
                        )) {
                            ForEach(BackgroundAspect.allCases) { Text($0.title).tag($0) }
                        }
                        HStack(alignment: .top) {
                            Text("Alignment").frame(width: 70, alignment: .leading)
                            alignmentGrid
                        }
                    }

                    section("Presets") {
                        Button("Save Current as Preset…", action: savePreset)
                        ForEach(presets.items) { preset in
                            Button(preset.name) {
                                document.perform { $0.background = preset.style }
                            }
                            .contextMenu { Button("Delete", role: .destructive) { presets.remove(preset) } }
                        }
                        if presets.items.isEmpty {
                            Text("Saved looks appear here. Right-click one to delete it.")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
                .disabled(!style.enabled)
                .opacity(style.enabled ? 1 : 0.45)
            }
            .padding(16)
        }
    }

    private func section<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.subheadline.weight(.semibold)).foregroundStyle(.secondary)
            content()
        }
    }

    private func slider(_ title: String, value keyPath: WritableKeyPath<BackgroundStyle, Double>, range: ClosedRange<Double>) -> some View {
        HStack {
            Text(title).frame(width: 70, alignment: .leading)
            Slider(value: Binding(
                get: { document.state.background[keyPath: keyPath] },
                set: { newValue in document.update { $0.background[keyPath: keyPath] = newValue } }
            ), in: range, onEditingChanged: { editing in
                editing ? document.beginChange() : document.endChange()
            })
        }
    }

    private var alignmentGrid: some View {
        LazyVGrid(columns: Array(repeating: GridItem(.fixed(26), spacing: 4), count: 3), spacing: 4) {
            ForEach(BackgroundAlignment.allCases) { alignment in
                Button { document.perform { $0.background.alignment = alignment } } label: {
                    RoundedRectangle(cornerRadius: 4)
                        .fill(style.alignment == alignment ? Color.accentColor : Color.secondary.opacity(0.25))
                        .frame(width: 26, height: 20)
                }
                .buttonStyle(.plain)
            }
        }
    }

    private var customSolid: Binding<Color> {
        Binding(
            get: {
                if case .solid(let color) = style.fill { return Color(nsColor: color.nsColor) }
                return .white
            },
            set: { setFill(.solid(RGBAColor(NSColor($0)))) }
        )
    }

    private func setFill(_ fill: BackgroundStyle.Fill) {
        document.perform {
            $0.background.fill = fill
            $0.background.enabled = true
        }
    }

    private func chooseImage() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image]
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        setFill(.image(path: url.path))
    }

    private func savePreset() {
        let alert = NSAlert()
        alert.messageText = "Name this preset"
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Cancel")
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 240, height: 24))
        field.placeholderString = "My look"
        alert.accessoryView = field
        alert.window.initialFirstResponder = field
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        presets.add(name: field.stringValue, style: style)
    }
}
