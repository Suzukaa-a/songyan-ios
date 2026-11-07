import CandidateKit
import Foundation
import KeyboardCore
import LayoutKit
import PackageManager
import SwiftUI
import UIKit

/// Input options (app side): same source as the in-keyboard instant options (capabilities are read from the actually deployed scheme,
/// saved per scheme identity; this page only reads/writes settings and never starts the engine, and whether an option takes effect is
/// decided by what the keyboard actually reads back). Says so when the current scheme has no verified options.
struct InputOptionsView: View {
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    /// Model of one toggle row: descriptor + current saved value (nil = not saved, use the scheme default).
    private struct OptionRow: Identifiable, Sendable {
        let state: EngineOptionState
        let descriptor: EngineOptionDescriptor
        var id: OptionPreferenceKey { OptionPreferenceKey(descriptor) }
    }

    @State private var rows: [OptionRow] = []
    @State private var hasActiveScheme = true
    @State private var loadError: String?
    @State private var saveErrors: [OptionPreferenceKey: String] = [:]
    @State private var saveRequests: [OptionPreferenceKey: UUID] = [:]
    @State private var viewRevision = UUID()
    @State private var loadRequest = UUID()
    /// Composition display toggle: shared definition (same key + App Group store); no second copy is created.
    /// The default is shared with the Host / Extension composition adapters.
    @AppStorage(
        KeyboardCompositionPreferences.enabledKey,
        store: KeyboardCompositionPreferences.defaults)
    private var inlineEnabled = KeyboardCompositionPreferences.defaultInlineEnabled
    @AppStorage(KeyboardIdleToolbarPreferences.key, store: KeyboardIdleToolbarPreferences.defaults)
    private var idleToolbarEnabled = KeyboardIdleToolbarPreferences.defaultEnabled
    /// Key feedback: the same App Group keys (KeyboardFeedbackPreferences) as the keyboard's
    /// instant settings.
    @AppStorage(
        KeyboardFeedbackPreferences.soundKey,
        store: KeyboardFeedbackPreferences.defaults)
    private var keySoundEnabled = true
    @AppStorage(
        KeyboardFeedbackPreferences.hapticKey,
        store: KeyboardFeedbackPreferences.defaults)
    private var keyHapticEnabled = false
    @AppStorage(
        KeyboardFeedbackPreferences.soundLevelKey,
        store: KeyboardFeedbackPreferences.defaults)
    private var keySoundLevelValue = KeyboardFeedbackLevel.medium.rawValue
    @AppStorage(
        KeyboardFeedbackPreferences.hapticLevelKey,
        store: KeyboardFeedbackPreferences.defaults)
    private var keyHapticLevelValue = KeyboardFeedbackLevel.medium.rawValue
    @AppStorage(KeyboardHeightPreferences.presetKey, store: KeyboardHeightPreferences.defaults)
    private var heightPresetValue = KeyboardHeightPreset.standard.rawValue
    @AppStorage(KeyboardOneHandPreferences.modeKey, store: KeyboardOneHandPreferences.defaults)
    private var oneHandValue = KeyboardOneHandMode.off.rawValue
    @AppStorage(KeyboardReadingPlacementPreferences.key, store: KeyboardReadingPlacementPreferences.defaults)
    private var readingPlacementValue = ReadingPlacement.row.rawValue
    /// Per-physical wide-screen dock. Read once per visit, written through the same shared
    /// preference path the keyboard reads at presentation, never from a per-key disk read.
    @State private var keyFlick = KeyboardKeyFeelPreferences.storedFlick
    /// Milliseconds; 0 follows each keyboard layout's own delay.
    @AppStorage(KeyboardKeyFeelPreferences.longPressDelayKey, store: KeyboardKeyFeelPreferences.defaults)
    private var longPressDelayValue = 0
    /// The Japanese twelve-key board's flick-only option (default off), read by the keyboard at
    /// each presentation like the key-feel options above.
    @AppStorage(KeyboardKana12Preferences.flickOnlyKey, store: KeyboardKana12Preferences.defaults)
    private var kanaFlickOnly = KeyboardKana12Preferences.defaultFlickOnly
    @State private var wideDockValues: [String: KeyboardContentDock] = [:]
    @StateObject private var typoCorrection = TypoCorrectionCenter.shared
    @StateObject private var prediction = PredictionCenter.shared
    @State private var importingPrediction = false
    @State private var predictionImportError: String?

    var body: some View {
        List {
            inlineCompositionSection
            Section {
                Toggle(String(localized: "快捷工具栏"), isOn: $idleToolbarEnabled)
                    .accessibilityIdentifier("inputOptions.idleToolbar")
            }
            keyboardHeightSection
            readingPlacementSection
            wideDockSection
            if UIDevice.current.userInterfaceIdiom == .phone { oneHandSection }
            Section {
                NavigationLink(String(localized: "双拼提示")) { ShuangpinHintManagementView() }
                    .accessibilityIdentifier("inputOptions.shuangpinHints")
                NavigationLink(String(localized: "模糊音")) { FuzzyPinyinSettingsView() }
                    .accessibilityIdentifier("inputOptions.fuzzyPinyin")
            }
            typoCorrectionSection
            predictionSection
            feedbackSection
            keyFeelSection
            optionSection
        }
        .navigationTitle(String(localized: "输入选项"))
        .navigationBarTitleDisplayMode(.inline)
        .task {
            reloadWideDocks()
            await reload()
            await typoCorrection.refresh()
            await prediction.refresh()
        }
        .onDisappear {
            viewRevision = UUID()
            loadRequest = UUID()
            saveRequests = [:]
        }
        .fileImporter(
            isPresented: $importingPrediction, allowedContentTypes: [.data],
            allowsMultipleSelection: false
        ) { result in
            switch result {
            case .success(let urls):
                guard let url = urls.first else { return }
                predictionImportError = nil
                prediction.importDatabase(from: url)
            case .failure(let error):
                let failure = error as NSError
                guard failure.domain != NSCocoaErrorDomain || failure.code != NSUserCancelledError else { return }
                predictionImportError = String(localized: "无法打开所选文件，请重新选择。")
            }
        }
    }

    private var oneHandSection: some View {
        Section {
            Picker(
                String(localized: "位置"),
                selection: Binding(
                    get: { KeyboardOneHandMode.resolve(oneHandValue) },
                    set: { oneHandValue = $0.rawValue }
                )
            ) {
                Text("关闭").tag(KeyboardOneHandMode.off)
                Text("左手").tag(KeyboardOneHandMode.left)
                Text("右手").tag(KeyboardOneHandMode.right)
            }
            .accessibilityIdentifier("inputOptions.oneHandMode")
        } header: {
            Text("单手模式")
        } footer: {
            Text("适用于 iPhone 竖屏，下次打开键盘时生效。")
        }
    }

    private var keyboardHeightSection: some View {
        Section {
            if dynamicTypeSize.isAccessibilitySize {
                keyboardHeightPicker.pickerStyle(.inline)
            } else {
                keyboardHeightPicker.pickerStyle(.segmented)
            }
        } header: {
            Text("键盘高度")
        } footer: {
            Text("下次打开键盘时生效，横屏保持紧凑高度。")
        }
    }

    private var keyboardHeightPicker: some View {
        Picker(
            String(localized: "高度"),
            selection: Binding(
                get: { KeyboardHeightPreset.resolve(heightPresetValue) },
                set: { heightPresetValue = $0.rawValue }
            )
        ) {
            Text("紧凑").tag(KeyboardHeightPreset.compact)
            Text("标准").tag(KeyboardHeightPreset.standard)
            Text("宽松").tag(KeyboardHeightPreset.comfortable)
        }
        .accessibilityIdentifier("inputOptions.keyboardHeight")
    }

    private var readingPlacementSection: some View {
        Section {
            Picker(
                String(localized: "读音位置"),
                selection: Binding(
                    get: { ReadingPlacement.resolve(readingPlacementValue) },
                    set: { readingPlacementValue = $0.rawValue }
                )
            ) {
                Text("候选栏上方单独一行").tag(ReadingPlacement.row)
                Text("候选栏最左").tag(ReadingPlacement.candidateBar)
            }
            .pickerStyle(.inline)
            .labelsHidden()
            .accessibilityIdentifier("inputOptions.readingPlacement")
        } header: {
            Text("14 键 / 18 键读音")
        } footer: {
            Text("放在候选栏最左时，读音单独滚动，键盘不会变高。下次打开键盘时生效。")
        }
    }

    private static let wideDockLayouts: [KeyboardLayoutKind] = [.phone9, .merged14, .merged18]

    private var wideDockSection: some View {
        Section {
            ForEach(Self.wideDockLayouts, id: \.rawValue) { layout in
                Picker(
                    UserTerminology.layoutName(layout),
                    selection: Binding(
                        get: { (wideDockValues[layout.rawValue] ?? .center).rawValue },
                        set: { value in
                            let dock = KeyboardContentDock.resolve(value)
                            wideDockValues[layout.rawValue] = dock
                            KeyboardContentDockPreferences.set(dock, for: layout)
                        }
                    )
                ) {
                    Text("靠左").tag(KeyboardContentDock.left.rawValue)
                    Text("居中").tag(KeyboardContentDock.center.rawValue)
                    Text("靠右").tag(KeyboardContentDock.right.rawValue)
                }
                .accessibilityIdentifier("inputOptions.wideDock.\(layout.rawValue)")
            }
        } header: {
            Text("宽屏键盘位置")
        } footer: {
            Text("下次打开键盘时生效。")
        }
    }

    private func reloadWideDocks() {
        for layout in Self.wideDockLayouts {
            wideDockValues[layout.rawValue] = KeyboardContentDockPreferences.dock(for: layout)
        }
    }

    // MARK: - Input display (shares one switch with the keyboard; shared definition)

    private var inlineCompositionSection: some View {
        Section {
            Toggle(isOn: $inlineEnabled) {
                Text("在输入框中显示拼写")
            }
            .accessibilityIdentifier("inputOptions.inlineSpelling")
            .accessibilityValue(inlineEnabled ? String(localized: "已开启") : String(localized: "已关闭"))
        } header: {
            Text("输入显示")
        } footer: {
            Text("在支持的输入框中直接显示拼写。")
        }
    }

    // MARK: - Typo correction (written by the normal install flow and proven by engine read-back; display trusts only the config the keyboard actually uses)

    private var typoCorrectionSection: some View {
        Section {
            Toggle(
                isOn: Binding(
                    get: { typoCorrection.state == .on || typoCorrection.state == .userManaged(true) },
                    set: { typoCorrection.setEnabled($0) })
            ) {
                Text("错键纠正")
            }
            .disabled(!typoCorrectionToggleable)
            .accessibilityIdentifier("inputOptions.typoCorrection")
            if typoCorrection.working {
                ProgressView(String(localized: "正在保存…")).font(.footnote)
            } else if let failure = typoCorrection.failure {
                Label(failure, systemImage: "exclamationmark.triangle")
                    .font(.caption).foregroundStyle(.red)
            } else if let notice = typoCorrection.notice {
                Text(notice).font(.caption).foregroundStyle(.secondary)
            }
            if let status = typoCorrectionStatus {
                Text(status).font(.caption).foregroundStyle(.secondary)
            }
        } header: {
            Text("纠错")
        } footer: {
            Text("自动纠正误按的相邻字母，仅适用于 26 键。")
        }
    }

    private var typoCorrectionToggleable: Bool {
        guard !typoCorrection.working else { return false }
        switch typoCorrection.state {
        case .on, .off: return true
        case .loading, .noSource, .unavailable, .userManaged: return false
        }
    }

    private var typoCorrectionStatus: String? {
        switch typoCorrection.state {
        case .loading: return String(localized: "正在读取…")
        case .noSource: return String(localized: "未选择输入方案。")
        case .unavailable(let reason): return reason
        case .userManaged: return String(localized: "由输入方案决定")
        case .on, .off: return nil
        }
    }

    // MARK: - Commit prediction (librime-predict; the dictionary is user-imported, the app neither bundles nor downloads it)

    private var predictionSection: some View {
        Section {
            if prediction.state == .schemeManaged || prediction.state == .userManaged {
                LabeledContent(String(localized: "上屏联想"), value: String(localized: "由输入方案决定"))
            } else {
                Toggle(
                    isOn: Binding(
                        get: { prediction.state == .on },
                        set: { prediction.setEnabled($0) })
                ) {
                    Text("上屏联想")
                }
                .disabled(!predictionToggleable)
                .accessibilityIdentifier("inputOptions.nextWordPrediction")
            }
            if predictionImportable {
                Button(
                    prediction.databaseBytes == nil
                        ? String(localized: "导入联想词库（predict.db）") : String(localized: "替换联想词库")
                ) {
                    predictionImportError = nil
                    importingPrediction = true
                }
                .disabled(prediction.working)
            }
            if let predictionImportError {
                Label(predictionImportError, systemImage: "exclamationmark.triangle")
                    .font(.caption).foregroundStyle(.red)
            }
            if let bytes = prediction.databaseBytes {
                Text("已导入联想词库（\(HostStorePaths.fileSizeText(bytes))）")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if prediction.working {
                ProgressView(String(localized: "正在保存…")).font(.footnote)
            } else if let failure = prediction.failure {
                Label(failure, systemImage: "exclamationmark.triangle")
                    .font(.caption).foregroundStyle(.red)
            } else if let notice = prediction.notice {
                Text(notice).font(.caption).foregroundStyle(.secondary)
            }
            if let status = predictionStatus {
                Text(status).font(.caption).foregroundStyle(.secondary)
            }
        } header: {
            Text("联想")
        } footer: {
            Text(
                prediction.state == .schemeManaged || prediction.state == .userManaged
                    ? "联想由当前输入方案提供。"
                    : "输入词语后推荐后续用词。需要先导入联想词库（predict.db）。")
        }
    }

    private var predictionToggleable: Bool {
        guard !prediction.working else { return false }
        switch prediction.state {
        case .on, .off: return true
        default: return false
        }
    }

    private var predictionImportable: Bool {
        switch prediction.state {
        case .on, .off, .noDatabase, .databaseMissing: return true
        default: return false
        }
    }

    private var predictionStatus: String? {
        switch prediction.state {
        case .loading: return String(localized: "正在读取…")
        case .noSource: return String(localized: "未选择输入方案。")
        case .unavailable(let reason): return reason
        case .schemeManaged, .userManaged: return nil
        case .noDatabase: return String(localized: "导入联想词库后即可开启。")
        case .databaseMissing: return String(localized: "联想词库缺失或已损坏，请重新导入。")
        case .on, .off: return nil
        }
    }

    // MARK: - Key feedback (sound/haptics with a strength level)

    private var feedbackSection: some View {
        Section {
            Toggle(isOn: $keySoundEnabled) {
                Text("按键声音")
            }
            .accessibilityIdentifier("inputOptions.keySound")
            .accessibilityValue(keySoundEnabled ? String(localized: "已开启") : String(localized: "已关闭"))
            if keySoundEnabled {
                if dynamicTypeSize.isAccessibilitySize {
                    keySoundLevelPicker.pickerStyle(.inline)
                } else {
                    keySoundLevelPicker.pickerStyle(.segmented)
                }
            }
            Toggle(isOn: $keyHapticEnabled) {
                Text("按键触感")
            }
            .accessibilityIdentifier("inputOptions.keyHaptic")
            .accessibilityValue(keyHapticEnabled ? String(localized: "已开启") : String(localized: "已关闭"))
            if keyHapticEnabled {
                if dynamicTypeSize.isAccessibilitySize {
                    keyHapticLevelPicker.pickerStyle(.inline)
                } else {
                    keyHapticLevelPicker.pickerStyle(.segmented)
                }
            }
        } header: {
            Text("按键反馈")
        } footer: {
            Text("需要开启「允许完全访问」。")
        }
    }

    // MARK: - Key feel (long-press delay, flick)

    private var keyFeelSection: some View {
        Section {
            Picker(
                String(localized: "滑动输入角上的字符"),
                selection: Binding(
                    get: { keyFlick },
                    set: {
                        keyFlick = $0
                        KeyboardKeyFeelPreferences.setFlick($0)
                    }
                )
            ) {
                Text("关闭").tag(KeyFlick.Setting.off)
                Text("上滑").tag(KeyFlick.Setting.up)
                Text("下滑").tag(KeyFlick.Setting.down)
            }
            .accessibilityIdentifier("inputOptions.keyFlick")
            Picker(
                String(localized: "长按延迟"),
                selection: Binding(
                    get: { LongPressDelaySetting.resolve(longPressDelayValue) ?? 0 },
                    set: { longPressDelayValue = $0 }
                )
            ) {
                Text("跟随键盘布局").tag(0)
                ForEach(LongPressDelaySetting.choices, id: \.self) { milliseconds in
                    Text("\(milliseconds) 毫秒").tag(milliseconds)
                }
            }
            .accessibilityIdentifier("inputOptions.longPressDelay")
            Toggle(isOn: $kanaFlickOnly) {
                Text(Kana12Wording.flickOnlyTitle)
            }
            .accessibilityIdentifier("inputOptions.kanaFlickOnly")
        } header: {
            Text("按键手感")
        } footer: {
            Text("按键右上角的小字，滑一下就能输入。下次打开键盘时生效。")
        }
    }

    private var keySoundLevelPicker: some View {
        Picker(String(localized: "声音强度"), selection: keySoundLevelBinding) {
            ForEach(KeyboardFeedbackLevel.allCases, id: \.self) { level in
                Text(level.displayName).tag(level.rawValue)
            }
        }
        .accessibilityIdentifier("inputOptions.keySoundLevel")
    }

    private var keyHapticLevelPicker: some View {
        Picker(String(localized: "触感强度"), selection: keyHapticLevelBinding) {
            ForEach(KeyboardFeedbackLevel.allCases, id: \.self) { level in
                Text(level.displayName).tag(level.rawValue)
            }
        }
        .accessibilityIdentifier("inputOptions.keyHapticLevel")
    }

    /// Writes through the service so its cache and audio/haptic warm-up stay in step.
    private var keySoundLevelBinding: Binding<String> {
        Binding(
            get: { keySoundLevelValue },
            set: { newValue in
                guard let level = KeyboardFeedbackLevel(rawValue: newValue) else { return }
                KeyboardFeedbackService.shared.setSoundLevel(level)
                keySoundLevelValue = KeyboardFeedbackPreferences.soundLevel.rawValue
                KeyboardFeedbackService.shared.previewKeyFeedback(sound: true, haptic: false, level: level)
            })
    }

    private var keyHapticLevelBinding: Binding<String> {
        Binding(
            get: { keyHapticLevelValue },
            set: { newValue in
                guard let level = KeyboardFeedbackLevel(rawValue: newValue) else { return }
                KeyboardFeedbackService.shared.setHapticLevel(level)
                keyHapticLevelValue = KeyboardFeedbackPreferences.hapticLevel.rawValue
                KeyboardFeedbackService.shared.previewKeyFeedback(sound: false, haptic: true, level: level)
            })
    }

    // MARK: - Options of the current input method

    private var optionSection: some View {
        Section {
            if let loadError {
                failureRow(String(localized: "无法读取选项"), detail: loadError)
                Button(String(localized: "重新读取")) { Task { await reload() } }
            } else if rows.isEmpty {
                Text(hasActiveScheme ? "暂无可以调整的选项。" : "未选择输入方案。")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(
                    rows.filter {
                        $0.descriptor.choiceGroup.isEmpty || $0.descriptor.choiceGroup.first == $0.descriptor.name
                    }
                ) { row in
                    if row.descriptor.choiceGroup.isEmpty {
                        optionRow(row)
                    } else {
                        choiceRow(row)
                    }
                }
            }
        } header: {
            Text("输入方式选项")
        } footer: {
            Text("下次打开键盘时生效。")
        }
    }

    private func choiceRow(_ representative: OptionRow) -> some View {
        let members = rows.filter { $0.descriptor.choiceGroup == representative.descriptor.choiceGroup }
        return VStack(alignment: .leading, spacing: 6) {
            Picker(
                representative.descriptor.title,
                selection: Binding(
                    get: { members.first(where: { $0.state.value })?.descriptor.name ?? "" },
                    set: { name in
                        if let selected = members.first(where: { $0.descriptor.name == name }) {
                            binding(for: selected).wrappedValue = true
                        }
                    }
                )
            ) {
                if !members.contains(where: { $0.state.value }) { Text("选择").tag("") }
                ForEach(members) { row in
                    // The bundled scheme's four states are worded by the catalog; every other group
                    // keeps the labels its author wrote in the schema.
                    Text(
                        row.descriptor.knownScriptState.map { ScriptStateLabels.label(for: $0) }
                            ?? row.descriptor.choiceLabel ?? row.descriptor.enabledLabel
                    ).tag(row.descriptor.name)
                }
            }
            .disabled(members.contains { saveRequests[$0.id] != nil })
            .accessibilityIdentifier("inputOptions.engine.\(representative.descriptor.name)")
            if members.contains(where: { saveRequests[$0.id] != nil }) {
                ProgressView(String(localized: "正在保存…")).font(.caption)
            }
            if let error = members.compactMap({ saveErrors[$0.id] }).first {
                Label(error, systemImage: "exclamationmark.triangle")
                    .font(.caption).foregroundStyle(.red)
            }
        }
    }

    private func optionRow(_ row: OptionRow) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Toggle(isOn: binding(for: row)) {
                Text(row.descriptor.title)
            }
            .disabled(saveRequests[row.id] != nil)
            .accessibilityIdentifier("inputOptions.engine.\(row.descriptor.name)")
            .accessibilityValue(row.state.value ? row.descriptor.enabledLabel : row.descriptor.disabledLabel)
            if saveRequests[row.id] != nil {
                ProgressView(String(localized: "正在保存…")).font(.caption)
            }
            if let error = saveErrors[row.id] {
                Label(error, systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.red)
            }
        }
    }

    private func binding(for row: OptionRow) -> Binding<Bool> {
        Binding(
            get: { row.state.value },
            set: { newValue in
                let request = UUID()
                let scope = viewRevision
                saveRequests[row.id] = request
                saveErrors[row.id] = nil
                loadRequest = UUID()  // An older read cannot undo this touch.
                let saving = OptionPersistenceIO.enqueue {
                    try OptionStore(directory: RimePaths.optionPreferencesDirectory())
                        .save(newValue, for: row.descriptor)
                }
                Task { @MainActor in
                    let result = await saving.result
                    guard viewRevision == scope, saveRequests[row.id] == request else { return }
                    saveRequests[row.id] = nil
                    guard let index = rows.firstIndex(where: { $0.id == row.id }) else { return }
                    switch result {
                    case .success:
                        if !row.descriptor.choiceGroup.isEmpty, newValue {
                            for member in rows.indices
                            where rows[member].descriptor.choiceGroup == row.descriptor.choiceGroup {
                                let descriptor = rows[member].descriptor
                                rows[member] = OptionRow(
                                    state: EngineOptionState(
                                        descriptor: descriptor, value: descriptor.name == row.descriptor.name),
                                    descriptor: descriptor)
                            }
                        } else {
                            rows[index] = OptionRow(
                                state: EngineOptionState(descriptor: row.descriptor, value: newValue),
                                descriptor: row.descriptor)
                        }
                        saveErrors[row.id] = nil
                    case .failure(let error):
                        HostLog.append("input option save failed: \(error.localizedDescription)")
                        saveErrors[row.id] = String(localized: "保存失败，请重试。")
                    }
                }
            })
    }

    private func failureRow(_ title: String, detail message: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Label(title, systemImage: "xmark.octagon.fill")
                .foregroundStyle(.red).font(.subheadline.bold())
            Text(message).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
        }
        .padding(.vertical, 2)
    }

    // MARK: - Data source (same as the keyboard extension)

    /// Resource metadata uses the read queue; preferences share the save FIFO.
    private func reload() async {
        let request = UUID()
        loadRequest = request
        let scope = viewRevision
        loadError = nil
        do {
            let source = try await KeyboardResourceReadQueue.async { () throws -> [(EngineOptionDescriptor, Bool)]? in
                guard let snapshot = try KeyboardRecipeStore.snapshot(selectedOnly: true) else { return nil }
                let activation = snapshot.activation
                // Only read capabilities of the selected schema; without a selection, the first required schema
                // (same order as runtime selectSchema).
                guard let schemaID = activation.selectedSchemaID ?? activation.requiredSchemaIDs.first else {
                    return []
                }
                let descriptors = Self.readDescriptors(
                    resourceID: activation.resourceID,
                    buildDirectory: snapshot.build,
                    sharedDirectory: snapshot.resources,
                    schemaID: schemaID)
                return descriptors.map { descriptor in
                    (
                        descriptor,
                        SchemaOptionCapabilities.defaultValue(
                            for: descriptor,
                            compiledDirectory: snapshot.build)
                    )
                }
            }
            guard viewRevision == scope, loadRequest == request, !Task.isCancelled else { return }
            let loaded = try await OptionPersistenceIO.enqueue { () throws -> [OptionRow]? in
                guard let source else { return nil }
                let store = OptionStore(directory: RimePaths.optionPreferencesDirectory())
                return try source.map { descriptor, engineDefault in
                    let saved = try store.value(for: descriptor)
                    return OptionRow(
                        state: EngineOptionState(
                            descriptor: descriptor,
                            value: saved ?? engineDefault),
                        descriptor: descriptor)
                }
            }.value
            guard viewRevision == scope, loadRequest == request, !Task.isCancelled else { return }
            hasActiveScheme = loaded != nil
            rows = loaded ?? []
        } catch {
            guard viewRevision == scope, loadRequest == request, !Task.isCancelled else { return }
            HostLog.append("input options reload failed: \(error.localizedDescription)")
            loadError = String(localized: "无法读取选项，请重试。")
        }
    }

    /// Resolves capabilities from the deployed build directory with the same conservative reader (single schema; same-named options are not merged).
    nonisolated private static func readDescriptors(
        resourceID: String, buildDirectory: URL, sharedDirectory: URL,
        schemaID: String
    ) -> [EngineOptionDescriptor] {
        SchemaOptionCapabilities.read(
            resourceID: resourceID,
            schemaID: schemaID,
            compiledDirectory: buildDirectory,
            sharedDirectory: sharedDirectory)
    }

}
