import AppKit
import SwiftUI

/// The background options (fill, layout, presets), shared by the screenshot editor and the Studio video editor.
/// The owner supplies the current style and how to change it, so each can do its own undo handling.
struct BackgroundControls: View {
    var style: BackgroundStyle
    @ObservedObject var presets: BackgroundPresetStore
    /// A discrete change that should be one undo step.
    var apply: ((inout BackgroundStyle) -> Void) -> Void
    /// A change made repeatedly while dragging a slider.
    var update: ((inout BackgroundStyle) -> Void) -> Void
    var beginChange: () -> Void
    var endChange: () -> Void
    /// When set, shows an Auto button that picks colors to match the picture.
    var autoBalance: (() -> Void)? = nil

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Toggle("Background", isOn: Binding(
                    get: { style.enabled },
                    set: { value in apply { $0.enabled = value } }
                ))
                .toggleStyle(.switch)
                .font(.headline)

                Group {
                    section("Gradients") {
                        if let autoBalance {
                            Button { autoBalance() } label: { Label("Auto balance", systemImage: "wand.and.stars") }
                                .help("Pick colors from the picture")
                        }
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
                            set: { value in apply { $0.aspect = value } }
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
                                apply { $0 = preset.style }
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
                get: { style[keyPath: keyPath] },
                set: { newValue in update { $0[keyPath: keyPath] = newValue } }
            ), in: range, onEditingChanged: { editing in
                editing ? beginChange() : endChange()
            })
        }
    }

    private var alignmentGrid: some View {
        LazyVGrid(columns: Array(repeating: GridItem(.fixed(26), spacing: 4), count: 3), spacing: 4) {
            ForEach(BackgroundAlignment.allCases) { alignment in
                Button { apply { $0.alignment = alignment } } label: {
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
        apply {
            $0.fill = fill
            $0.enabled = true
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
