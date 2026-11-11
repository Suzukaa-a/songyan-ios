import AppearanceKit
import CandidateKit
import SkinKit
import SwiftUI

// MARK: - Candidate bar style (part of the applied appearance)

/// 键盘外观 > 候选栏样式: edits the candidate bar layout of the appearance in use. A built-in appearance
/// is read-only, so saving applies an editable copy of it.
struct CandidateBarStyleView: View {
    @ObservedObject private var manager = AppearanceManager.shared
    @State private var draft = AppearanceDocument.systemDefault
    @State private var loaded = false
    @State private var toast: String?
    @State private var textSize = CandidateTextSizePreferences.current

    private var hasChanges: Bool { loaded && draft.candidateBar != manager.applied.candidateBar }

    var body: some View {
        Form {
            // A device preference applied at once, not part of the appearance file.
            Section {
                Picker(String(localized: "候选字号"), selection: $textSize) {
                    ForEach(CandidateTextSize.allCases, id: \.self) { Text($0.displayName).tag($0) }
                }
                .pickerStyle(.inline)
                .accessibilityIdentifier("candidateBarStyle.textSize")
            } header: {
                Text("候选字号")
            }
            CandidateAreaEditorSections(document: $draft)
            if let error = manager.error { Section { Text(error).foregroundStyle(.red) } }
        }
        .navigationTitle(String(localized: "候选栏样式"))
        .navigationBarTitleDisplayMode(.inline)
        .disabled(manager.isLoading || manager.isMutating)
        .savedToast($toast)
        .onChange(of: textSize) { CandidateTextSizePreferences.current = textSize }
        .onChange(of: manager.isLoading, initial: true) {
            guard !manager.isLoading, !loaded else { return }
            draft = manager.applied
            loaded = true
        }
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button(String(localized: "保存")) {
                    Task {
                        let target = manager.applied.isBuiltin ? draft.copy() : draft
                        guard await manager.apply(target) else { return }
                        draft = manager.applied
                        toast = String(localized: "已保存")
                        manager.message = nil
                    }
                }
                .disabled(!hasChanges || manager.isMutating)
            }
        }
    }
}

extension CandidateTextSize {
    var displayName: String {
        switch self {
        case .small: return String(localized: "小")
        case .standard: return String(localized: "标准")
        case .large: return String(localized: "大")
        case .extraLarge: return String(localized: "特大")
        }
    }
}

/// Candidate bar layout sections: row height, spacing, expanded arrangement and the page/expand buttons.
struct CandidateAreaEditorSections: View {
    @Binding var document: AppearanceDocument

    private var bar: CandidateBarDefinition { document.candidateBar }

    var body: some View {
        Section {
            Picker(String(localized: "显示规则"), selection: barBinding(\.compositionRow.visible)) {
                Text("仅输入时显示（推荐）").tag(CandidateBarDefinition.CompositionRow.Visibility.composingOnly)
                Text("始终显示").tag(CandidateBarDefinition.CompositionRow.Visibility.composingWithIdleRaw)
                Text("不显示").tag(CandidateBarDefinition.CompositionRow.Visibility.hidden)
            }
        } header: {
            Text("拼写行")
        }

        Section(String(localized: "单行")) {
            slider(String(localized: "行高"), value: barBinding(\.collapsed.height), range: 36...56)
            slider(String(localized: "候选项内边距"), value: barBinding(\.collapsed.cellPaddingX), range: 4...24)
            slider(String(localized: "候选项间距"), value: barBinding(\.collapsed.cellSpacing), range: 0...16)
            Toggle(String(localized: "候选较少时平分宽度"), isOn: fillsWidth)
        }

        Section(String(localized: "展开")) {
            Picker(String(localized: "模式"), selection: barBinding(\.expanded.mode)) {
                Text("自适应（推荐）").tag(CandidateBarDefinition.Expanded.Mode.adaptive)
                Text("单列").tag(CandidateBarDefinition.Expanded.Mode.list)
                Text("网格").tag(CandidateBarDefinition.Expanded.Mode.grid)
            }
            if bar.expanded.mode == .grid {
                Stepper(
                    String(localized: "列数：\(bar.expanded.columns)"), value: barBinding(\.expanded.columns), in: 1...4)
            }
            slider(String(localized: "行间距"), value: barBinding(\.expanded.rowSpacing), range: 0...16)
            slider(String(localized: "列间距"), value: barBinding(\.expanded.columnSpacing), range: 0...16)
            slider(
                String(localized: "长词单独成行（字数）"),
                value: Binding(
                    get: { Double(bar.expanded.fullRowTextLength) },
                    set: { value in setBar { $0.expanded.fullRowTextLength = Int(value.rounded()) } }),
                range: 1...40)
        }

        Section(String(localized: "翻页与展开")) {
            Picker(String(localized: "翻页按钮位置"), selection: barBinding(\.controls.pagePosition)) {
                Text("两端（默认）").tag(CandidateBarDefinition.Controls.PagePosition.both)
                Text("右侧").tag(CandidateBarDefinition.Controls.PagePosition.trailing)
                Text("左侧").tag(CandidateBarDefinition.Controls.PagePosition.leading)
            }
            Toggle(String(localized: "显示展开与收起按钮"), isOn: barBinding(\.controls.showsExpand))
        }
    }

    // MARK: Bindings (written through the document so its three identities stay in lockstep)

    private func setBar(_ mutate: (inout CandidateBarDefinition) -> Void) {
        var bar = document.candidateBar
        mutate(&bar)
        document = document.replacing(candidateBar: bar)
    }

    private func barBinding<T>(_ keyPath: WritableKeyPath<CandidateBarDefinition, T>) -> Binding<T> {
        Binding(
            get: { document.candidateBar[keyPath: keyPath] },
            set: { value in setBar { $0[keyPath: keyPath] = value } })
    }

    private var fillsWidth: Binding<Bool> {
        Binding(
            get: { document.candidateBar.collapsed.fillsAvailableWidth ?? true },
            set: { value in setBar { $0.collapsed.fillsAvailableWidth = value } })
    }

    private func slider(_ title: String, value: Binding<Double>, range: ClosedRange<Double>) -> some View {
        VStack(alignment: .leading) {
            Text("\(title)：\(value.wrappedValue, specifier: "%.0f")")
            Slider(value: value, in: range, step: 1)
                .accessibilityLabel(title)
                .accessibilityValue(String(Int(value.wrappedValue.rounded())))
        }
    }
}
