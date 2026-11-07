import AppearanceKit
import CandidateKit
import LayoutKit
import SkinKit
import SwiftUI
import UIKit

/// Appearance project editor: skin (colors/fonts/keycaps/background) + candidate-bar layout + display mode,
/// all belonging to the **same** appearance identity, saved once.
///
/// There is no standalone candidate-bar editor/"Apply": the candidate bar only edits layout behavior here; colors and font sizes are set in the
/// Font section (skin), so there is no third color source.
struct SkinEditorView: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var manager = AppearanceManager.shared
    @State private var draft: AppearanceDocument
    @State private var dark = false
    @State private var layoutID: String
    @State private var layouts: [LayoutDefinition] = []
    @State private var error: String?
    @State private var confirmingDiscard = false
    @State private var saving = false
    /// Draft at open time: used to detect unsaved changes (confirm before cancel/swipe-down dismissal).
    private let original: AppearanceDocument
    private let onSaved: ((AppearanceDocument) -> Void)?
    init(
        document: AppearanceDocument, previewLayoutID: String? = nil, previewDark: Bool = false,
        onSaved: ((AppearanceDocument) -> Void)? = nil
    ) {
        _dark = State(initialValue: previewDark)
        _layoutID = State(initialValue: previewLayoutID ?? "")
        original = document.normalized()
        _draft = State(initialValue: original)
        self.onSaved = onSaved
    }
    private var hasChanges: Bool { draft != original }
    var body: some View {
        NavigationStack {
            Form {
                Section(String(localized: "预览")) {
                    if layouts.isEmpty { ProgressView(String(localized: "正在读取布局…")) }
                    Picker(String(localized: "布局"), selection: $layoutID) {
                        ForEach(layouts) { Text($0.name).tag($0.id) }
                    }
                    Toggle(String(localized: "编辑深色"), isOn: $dark)
                    if let layout = layouts.first(where: { $0.id == layoutID }) {
                        KeyboardPreviewView(
                            layout: layout, skin: draft.skin, candidateBar: draft.candidateBar, previewDark: dark)
                    }
                }
                Section(String(localized: "候选栏预览")) {
                    CandidateBarPreviewView(bar: draft.candidateBar, skin: draft.skin, dark: dark)
                }
                Section(String(localized: "名称")) {
                    TextField(String(localized: "外观名称"), text: $draft.name)
                    TextField(
                        String(localized: "作者（可选）"),
                        text: Binding(
                            get: { draft.author ?? "" },
                            set: { draft.author = $0.isEmpty ? nil : $0 }))
                }
                Section(dark ? String(localized: "深色颜色") : String(localized: "浅色颜色")) {
                    ForEach(SkinDefinition.colorNames, id: \.self) { name in
                        ColorPicker(colorTitle(name), selection: colorBinding(name), supportsOpacity: false)
                    }
                }
                Section {
                    Picker(String(localized: "字体族"), selection: $draft.skin.typography.family) {
                        Text("系统").tag("system")
                        Text("圆体").tag("rounded")
                        Text("衬线体").tag("serif")
                        Text("等宽体").tag("monospaced")
                    }
                    Picker(String(localized: "字重"), selection: $draft.skin.typography.weight) {
                        Text("常规").tag("regular")
                        Text("中等").tag("medium")
                        Text("半粗").tag("semibold")
                    }
                    slider(String(localized: "主键字号"), value: $draft.skin.typography.keySize, range: 16...28)
                    slider(
                        String(localized: "副标题字号"), value: $draft.skin.typography.secondarySize,
                        range: 10...16)
                    slider(
                        String(localized: "候选字号"), value: $draft.skin.typography.candidateSize,
                        range: 16...30)
                } header: {
                    Text("字体")
                }
                Section(String(localized: "按键")) {
                    slider(String(localized: "圆角"), value: $draft.skin.keycap.cornerRadius, range: 0...16)
                    slider(String(localized: "边框"), value: $draft.skin.keycap.borderWidth, range: 0...2)
                    Picker(String(localized: "阴影"), selection: $draft.skin.keycap.shadow) {
                        Text("无").tag("none")
                        Text("轻微").tag("subtle")
                    }
                    slider(String(localized: "横向内缩"), value: $draft.skin.spacing.visualInsetX, range: 0...6)
                    slider(String(localized: "纵向内缩"), value: $draft.skin.spacing.visualInsetY, range: 0...6)
                }
                Section(String(localized: "背景")) {
                    Toggle(
                        String(localized: "双色纵向渐变"),
                        isOn: Binding(
                            get: { variant.background?.type == "linearGradient" },
                            set: { gradient in
                                var b = SkinDefinition.Background()
                                b.type = gradient ? "linearGradient" : "solid"
                                if gradient {
                                    b.from = variant.colors?["panel"] ?? "#D1D3D9"
                                    b.to = variant.colors?["accent"] ?? "#145ACC"
                                    b.direction = "vertical"
                                } else {
                                    b.color = variant.colors?["panel"] ?? "#D1D3D9"
                                }
                                var v = variant
                                v.background = b
                                variant = v
                            }))
                    if variant.background?.type == "linearGradient" {
                        ColorPicker(
                            String(localized: "起点"), selection: backgroundBinding("from"), supportsOpacity: false)
                        ColorPicker(String(localized: "终点"), selection: backgroundBinding("to"), supportsOpacity: false)
                    } else {
                        ColorPicker(
                            String(localized: "纯色"), selection: backgroundBinding("color"), supportsOpacity: false)
                    }
                }
                CandidateAreaEditorSections(document: $draft)
                Section {
                    Button(String(localized: "另存为副本")) { save(copy: true) }
                    Text("保存后轻点「应用」即可生效。")
                        .font(.caption)
                    if let error { Text(error).foregroundStyle(.red) }
                }
                .disabled(saving)
            }
            .disabled(saving)
            .navigationTitle(String(localized: "编辑外观"))
            .toolbarBackground(Color(uiColor: .systemGroupedBackground), for: .navigationBar)
            .toolbarBackground(.visible, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(String(localized: "取消")) { if hasChanges { confirmingDiscard = true } else { dismiss() } }
                        .disabled(saving)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(String(localized: "保存")) { save(copy: false) }
                        .disabled(saving)
                        .accessibilityIdentifier("skinEditor.save")
                }
            }
            .confirmationDialog(
                String(localized: "放弃未保存的更改？"), isPresented: $confirmingDiscard, titleVisibility: .visible
            ) {
                Button(String(localized: "放弃更改"), role: .destructive) { dismiss() }
                Button(String(localized: "继续编辑"), role: .cancel) {}
            }
        }
        .interactiveDismissDisabled(hasChanges || saving)
        .task {
            guard layouts.isEmpty else { return }
            do {
                let preview = try await AppearancePreviewLoader.load()
                guard !Task.isCancelled else { return }
                layouts = preview.layouts
                if layoutID.isEmpty { layoutID = preview.selectedID }
            } catch { self.error = String(localized: "无法读取预览布局，请重新打开外观。") }
        }
    }
    /// Display mode belongs to this appearance project: editing only changes the draft, committed together on save/apply.
    private var variant: SkinDefinition.Variant {
        get { (dark ? draft.skin.variants.dark : draft.skin.variants.light) ?? .init() }
        nonmutating set {
            var skin = draft.skin
            if dark { skin.variants.dark = newValue } else { skin.variants.light = newValue }
            draft = draft.replacing(skin: skin)
        }
    }
    private func colorTitle(_ name: String) -> String {
        [
            "panel": String(localized: "面板背景"), "key": String(localized: "字母键背景"),
            "control": String(localized: "功能键背景"), "accent": String(localized: "强调色"),
            "text": String(localized: "主文字"), "secondaryText": String(localized: "次要文字"),
            "accentText": String(localized: "强调文字"), "pressed": String(localized: "按下状态"),
            "selected": String(localized: "选中状态"), "border": String(localized: "边框"),
        ].first { $0.key == name }?.value ?? name
    }
    private func slider(_ title: String, value: Binding<Double>, range: ClosedRange<Double>) -> some View {
        VStack(alignment: .leading) {
            Text("\(title)：\(value.wrappedValue, specifier: "%.1f")")
            Slider(value: value, in: range, step: 0.5)
                .accessibilityLabel(title)
                .accessibilityValue(String(format: "%.1f", value.wrappedValue))
        }
    }
    private func hex(_ color: Color) -> String {
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        UIColor(color).getRed(&r, green: &g, blue: &b, alpha: &a)
        // The color picker can return Display P3 or other wide-gamut components (<0 or >1); clamp to sRGB, otherwise an invalid hex is produced and discarded.
        let byte = { (v: CGFloat) in Int((min(max(v, 0), 1) * 255).rounded()) }
        return String(format: "#%02X%02X%02X", byte(r), byte(g), byte(b))
    }
    private func colorBinding(_ name: String) -> Binding<Color> {
        Binding(
            get: { KeyboardAppearance(skin: draft.skin, dark: dark).color(name) },
            set: { color in
                var v = variant
                var colors = v.colors ?? [:]
                colors[name] = hex(color)
                v.colors = colors
                variant = v
            })
    }
    private func backgroundBinding(_ field: String) -> Binding<Color> {
        Binding(
            get: {
                let b = variant.background
                let hex = field == "from" ? b?.from : field == "to" ? b?.to : b?.color
                let c = hex.flatMap(SkinColor.init(hex:)) ?? draft.skin.resolvedColors(dark: dark)["panel"]!
                return Color(red: c.red, green: c.green, blue: c.blue)
            },
            set: { color in
                var v = variant
                var b = v.background ?? .init()
                if field == "from" {
                    b.from = hex(color)
                } else if field == "to" {
                    b.to = hex(color)
                } else {
                    b.color = hex(color)
                }
                v.background = b
                variant = v
            })
    }
    private func save(copy: Bool) {
        guard !saving else { return }
        saving = true
        // Flush the active text field before normalizing the saved draft.
        UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
        Task { @MainActor in
            await Task.yield()
            defer { saving = false }
            do {
                let saved = (copy ? draft.copy() : draft).normalized()
                try await manager.save(saved, replacing: !copy)
                onSaved?(saved)
                dismiss()
            } catch { self.error = error.localizedDescription }
        }
    }
}
