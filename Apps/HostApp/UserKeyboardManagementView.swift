import KeyboardCore
import LayoutKit
import SwiftUI

/// 我的键盘: the only place to choose what is on the keyboard. The added keyboards come first as a
/// short list (each opens its 页面搭配); below, every input method folds into one row whose layouts
/// are checked into a draft published once by "Save". "Use" publishes the draft plus that pair and
/// switches to it right away. The pair in use is marked 正在使用.
struct UserKeyboardManagementView: View {
    @Environment(\.dismiss) private var dismiss
    @StateObject private var center: UserKeyboardCenter
    private let returnsToSource: Bool
    @State private var selectedIDs: Set<String> = []
    @State private var baselineIDs: Set<String> = []
    @State private var initialized = false
    @State private var hasEditedSelection = false
    @State private var confirmingDiscard = false
    @State private var isSaving = false
    @State private var configuringKeyboard: UserKeyboard?
    /// Input methods unfolded in the add list; seeded once so a later save does not refold them.
    @State private var expandedGroupIDs: Set<String> = []
    /// Input-method order from the first read: saving puts added keyboards first in `items`, and the
    /// add list must not reshuffle under the finger.
    @State private var groupOrder: [String] = []
    @ObservedObject private var layoutManager = LayoutManager.shared

    init(
        center: UserKeyboardCenter? = nil, source: UserKeyboardSource = .active,
        returnsToSource: Bool = false
    ) {
        self.returnsToSource = returnsToSource
        _center = StateObject(wrappedValue: center ?? .scoped(to: source))
    }

    var body: some View {
        List {
            statusSection
            if case .ready = center.phase {
                // Sits at the top, next to the disabled Save button it explains.
                if needsOneKeyboard {
                    Section {
                        Label(UserTerminology.userKeyboardSaveNeedsOne, systemImage: "exclamationmark.circle")
                            .foregroundStyle(.orange)
                    }
                }
                // Checked keyboards are always listed here, so folding an input method never hides one.
                if !selectedItems.isEmpty {
                    Section(UserTerminology.userKeyboardAdded) {
                        ForEach(selectedItems) { item in addedRow(item) }
                    }
                }
                Section("自定义键盘") {
                    NavigationLink(UserTerminology.pageLibrary) {
                        KeyboardPageManagementView(keyboardNames: keyboardNames)
                    }
                    NavigationLink(UserTerminology.keyboardLayout) {
                        LayoutManagementView(keyboardNames: keyboardNames)
                    }
                }
                if !groups.isEmpty {
                    Section(UserTerminology.addUserKeyboard) {
                        ForEach(groups, id: \.id) { group in
                            DisclosureGroup(isExpanded: expansion(for: group.id)) {
                                ForEach(group.items) { item in pickRow(item, inputMethod: group.name) }
                            } label: {
                                groupLabel(group)
                            }
                        }
                    }
                }
                if groups.isEmpty {
                    Section { Text(UserTerminology.userKeyboardEmptyHint).foregroundStyle(.secondary) }
                } else {
                    Section {
                        Text(UserTerminology.userKeyboardFootnote)
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                }
            }
        }
        .navigationTitle(UserTerminology.userKeyboard)
        .navigationBarTitleDisplayMode(.inline)
        .navigationDestination(
            isPresented: Binding(
                get: { configuringKeyboard != nil },
                set: { if !$0 { configuringKeyboard = nil } }
            )
        ) {
            if let configuringKeyboard {
                KeyboardCompositionView(
                    keyboard: configuringKeyboard, keyboardNames: keyboardNames,
                    sourceSchemas: center.sourceSchemas)
            }
        }
        // With unsaved changes, going back directly (discarding the draft) is not allowed: becomes "Cancel" with a second confirmation.
        .navigationBarBackButtonHidden(hasChanges || isSaving || center.busyKeyboardID != nil)
        .interactiveDismissDisabled(isSaving || center.busyKeyboardID != nil)
        .confirmationDialog("放弃未保存的更改？", isPresented: $confirmingDiscard, titleVisibility: .visible) {
            Button("放弃更改", role: .destructive) {
                guard !isSaving, center.busyKeyboardID == nil else { return }
                resetDraft()
                dismiss()
            }
            .disabled(isSaving || center.busyKeyboardID != nil)
            Button("继续编辑", role: .cancel) {}
        }
        .toolbar {
            if hasChanges, !isSaving, center.busyKeyboardID == nil {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") {
                        guard !isSaving, center.busyKeyboardID == nil else { return }
                        confirmingDiscard = true
                    }
                }
            }
            ToolbarItem(placement: .confirmationAction) {
                Button("保存") { save() }
                    .accessibilityIdentifier("userKeyboard.save")
                    .disabled(!canSave)
            }
        }
        .task {
            guard !hasChanges else { return }
            await center.refresh()
            resetDraft()
        }
        .refreshable {
            guard !hasChanges, !isSaving, center.busyKeyboardID == nil else { return }
            await center.refresh()
            resetDraft()
        }
    }

    @ViewBuilder
    private var statusSection: some View {
        switch center.phase {
        case .loading:
            Section { ProgressView("正在读取键盘…") }
        case .failed(let message):
            Section {
                Label(message, systemImage: "exclamationmark.triangle").foregroundStyle(.orange)
                Button("重新读取") {
                    Task {
                        await center.refresh()
                        resetDraft()
                    }
                }
            }
        case .readOnly(let message):
            Section {
                Label(message, systemImage: "info.circle").foregroundStyle(.secondary)
                if returnsToSource {
                    Button(UserTerminology.inputScheme) { dismiss() }
                } else {
                    NavigationLink(UserTerminology.inputScheme) { InputSchemeListView() }
                }
            }
        case .needsSource:
            Section {
                Label(UserTerminology.userKeyboardNeedsSourceHint, systemImage: "info.circle")
                    .foregroundStyle(.secondary)
                if returnsToSource {
                    Button(UserTerminology.inputScheme) { dismiss() }
                } else {
                    NavigationLink(UserTerminology.inputScheme) { InputSchemeListView() }
                }
            }
        case .ready:
            if center.sourceNeedsUpdate {
                Section {
                    Text("输入方案已更新，轻点「保存」即可使用新版本。")
                        .font(.footnote).foregroundStyle(.secondary)
                }
            }
            if isSaving || center.busyKeyboardID != nil {
                Section { ProgressView(UserTerminology.userKeyboardSaving) }
            } else if center.resultMessage == nil,
                let current = items.first(where: { $0.id == center.currentKeyboardID })
            {
                Section {
                    LabeledContent(UserTerminology.statusInUse, value: current.keyboard.title)
                }
            }
            if let result = center.resultMessage {
                Section {
                    Label(result, systemImage: "checkmark.circle").foregroundStyle(.green)
                    NavigationLink("试打当前键盘") { TryInputView() }
                }
            }
            if let error = center.errorMessage {
                Section {
                    Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(.orange)
                    Button("知道了") { center.dismissMessages() }
                }
            }
        }
    }

    private struct Item: Identifiable {
        let id: String
        let inputMethodID: String
        let inputMethodName: String
        let layout: KeyboardLayoutKind
        var keyboard: UserKeyboard {
            UserKeyboard(inputMethodID: inputMethodID, inputMethodName: inputMethodName, layout: layout)
        }
    }

    private struct Group {
        let id: String
        let name: String
        let items: [Item]
    }

    private var items: [Item] {
        let published = center.publishedKeyboards.map {
            Item(
                id: $0.id, inputMethodID: $0.inputMethodID,
                inputMethodName: displayName($0.inputMethodName), layout: $0.layout)
        }
        let addable = center.addableKeyboards.map {
            Item(
                id: $0.id, inputMethodID: $0.inputMethodID,
                inputMethodName: displayName($0.inputMethodName), layout: $0.layout)
        }
        var seen = Set<String>()
        return (published + addable).filter { seen.insert($0.id).inserted }
    }

    private var groups: [Group] {
        var order: [String] = []
        var grouped: [String: [Item]] = [:]
        var names: [String: String] = [:]
        for item in items {
            if grouped[item.inputMethodID] == nil { order.append(item.inputMethodID) }
            grouped[item.inputMethodID, default: []].append(item)
            names[item.inputMethodID] = item.inputMethodName
        }
        let rank = Dictionary(groupOrder.enumerated().map { ($1, $0) }, uniquingKeysWith: { first, _ in first })
        let stable = order.enumerated().sorted {
            (rank[$0.element] ?? groupOrder.count + $0.offset, $0.offset)
                < (rank[$1.element] ?? groupOrder.count + $1.offset, $1.offset)
        }
        return stable.map { _, id in
            Group(
                id: id, name: names[id] ?? "输入方式",
                items: (grouped[id] ?? []).sorted { Self.layoutRank($0.layout) < Self.layoutRank($1.layout) })
        }
    }

    private static func layoutRank(_ layout: KeyboardLayoutKind) -> Int {
        KeyboardLayoutKind.allCases.firstIndex(of: layout) ?? Int.max
    }

    private var hasChanges: Bool { initialized && hasEditedSelection && selectedIDs != baselineIDs }

    /// Keyboards turned on in the draft (in page order).
    private var selectedItems: [Item] { items.filter { selectedIDs.contains($0.id) } }

    private var selectedRoster: [UserKeyboard] { selectedItems.map(\.keyboard) }

    /// No keyboard turned on after the change: cannot save, explained in place.
    private var needsOneKeyboard: Bool { hasChanges && selectedRoster.isEmpty }

    /// The current source must be edited then saved; a non-current source can save its existing list to switch back; an empty list can never be published.
    private var canSave: Bool {
        guard case .ready = center.phase else { return false }
        return initialized && (selectedIDs != baselineIDs || !center.sourceIsCurrent) && !selectedRoster.isEmpty
            && !isSaving && center.busyKeyboardID == nil && center.supportsManagement
    }

    private func displayName(_ name: String) -> String {
        name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? UserTerminology.inputMethod : name
    }

    private var isBusy: Bool { isSaving || center.busyKeyboardID != nil }

    private var keyboardNames: KeyboardNames {
        let publishedIDs = Set(center.publishedKeyboards.map(\.id))
        return KeyboardNames(
            known: Dictionary(items.map { ($0.id, $0.keyboard.title) }, uniquingKeysWith: { first, _ in first }),
            active: items.filter { publishedIDs.contains($0.id) || selectedIDs.contains($0.id) }
                .map { $0.keyboard.compositionKey })
    }

    /// The paired main layout's name when it is not the shape's own preset, shown under the shape.
    private func customMainName(_ item: Item, main: LayoutDefinition) -> String? {
        main.id == BuiltinLayouts.preset(for: item.layout.builtinLayout).id ? nil : main.name
    }

    /// An added keyboard: the row opens its 页面搭配; the trailing control is 正在使用 or "Use".
    private func addedRow(_ item: Item) -> some View {
        let inUse = center.currentKeyboardID == item.id
        let available = isAvailable(item)
        let main = mainLayout(for: item)
        let customMain = main.flatMap { customMainName(item, main: $0) }
        return HStack(spacing: 12) {
            Button {
                configuringKeyboard = item.keyboard
            } label: {
                HStack(spacing: 12) {
                    if let main {
                        LayoutThumbnail(definition: main).accessibilityHidden(true)
                    } else {
                        Image(systemName: "exclamationmark.triangle")
                            .foregroundStyle(.secondary)
                            .frame(width: LayoutThumbnail.width)
                            .accessibilityHidden(true)
                    }
                    VStack(alignment: .leading, spacing: 2) {
                        Text(item.keyboard.title).foregroundStyle(.primary).fixedSize(horizontal: false, vertical: true)
                        // Names the destination so the row reads as the way into 页面搭配.
                        HStack(spacing: 3) {
                            Image(systemName: "square.stack.3d.up")
                            Text(
                                customMain.map { "\(UserTerminology.pageComposition) · \($0)" }
                                    ?? UserTerminology.pageComposition)
                        }
                        .font(.caption)
                        .foregroundStyle(Color.accentColor)
                        .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: 4)
                    Image(systemName: "chevron.right")
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(.tertiary)
                        .accessibilityHidden(true)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(isBusy || !available)
            .accessibilityIdentifier("userKeyboard.pages." + item.id)
            .accessibilityLabel(customMain.map { "\(item.keyboard.title)，\($0)" } ?? item.keyboard.title)
            .accessibilityHint("打开\(UserTerminology.pageComposition)")
            if !available {
                Text("不可用")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .fixedSize()
                    .accessibilityLabel("\(item.keyboard.title)，不可用")
            } else if inUse {
                HStack(spacing: 3) {
                    Image(systemName: "checkmark")
                    Text(UserTerminology.statusInUse)
                }
                .font(.footnote)
                .foregroundStyle(.green)
                .fixedSize()
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("\(item.keyboard.title)，\(UserTerminology.statusInUse)")
            } else {
                Button(UserTerminology.startUsing) { use(item) }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .disabled(isBusy || !center.supportsManagement)
                    .accessibilityIdentifier("userKeyboard.use." + item.id)
                    .accessibilityLabel("\(UserTerminology.startUsing)\(item.keyboard.title)")
            }
        }
        .alignmentGuide(.listRowSeparatorLeading) { _ in LayoutThumbnail.width + 12 }
        .swipeActions {
            Button("移除", role: .destructive) { binding(for: item.id).wrappedValue = false }
                .disabled(isBusy || !center.supportsManagement)
        }
    }

    private func groupLabel(_ group: Group) -> some View {
        let added = group.items.filter { selectedIDs.contains($0.id) }.count
        return HStack {
            Text(group.name).foregroundStyle(.primary)
            Spacer(minLength: 8)
            if added > 0 {
                Text("已添加 \(added) 个").font(.subheadline).foregroundStyle(.secondary)
            }
        }
    }

    /// One layout of an input method: the row checks it into the draft; long-press uses it or opens
    /// its 页面搭配 without adding it first.
    private func pickRow(_ item: Item, inputMethod: String) -> some View {
        let selected = selectedIDs.contains(item.id)
        let available = isAvailable(item)
        let name = UserTerminology.userKeyboardToggleLabel(inputMethod: inputMethod, layout: item.layout)
        let main = mainLayout(for: item)
        let customMain = main.flatMap { customMainName(item, main: $0) }
        return Button {
            binding(for: item.id).wrappedValue.toggle()
        } label: {
            HStack(spacing: 12) {
                Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                    .font(.title3)
                    .foregroundStyle(selected ? Color.accentColor : Color.secondary)
                VStack(alignment: .leading, spacing: 2) {
                    Text(UserTerminology.layoutName(item.layout)).foregroundStyle(.primary)
                    if let customMain {
                        Text(customMain).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    } else if !available {
                        Text("不可用").font(.caption).foregroundStyle(.secondary)
                    }
                }
                Spacer(minLength: 4)
                if let main {
                    LayoutThumbnail(definition: main).accessibilityHidden(true)
                } else {
                    Image(systemName: "exclamationmark.triangle")
                        .foregroundStyle(.secondary)
                        .frame(width: LayoutThumbnail.width)
                        .accessibilityHidden(true)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(isBusy || !center.supportsManagement || !available)
        .contextMenu {
            if center.currentKeyboardID != item.id {
                Button(UserTerminology.startUsing) { use(item) }
                    .disabled(isBusy || !center.supportsManagement || !available)
            }
            Button(UserTerminology.pageComposition) { configuringKeyboard = item.keyboard }
                .disabled(isBusy || !available)
        }
        .accessibilityIdentifier("userKeyboard.card." + item.id)
        .accessibilityLabel(customMain.map { "\(name)，\($0)" } ?? name)
        .accessibilityValue(
            selected ? UserTerminology.userKeyboardSelected : UserTerminology.userKeyboardNotSelected
        )
        .accessibilityAddTraits(selected ? [.isSelected] : [])
        .accessibilityHint(UserTerminology.userKeyboardDraftHint)
        .accessibilityAction(named: UserTerminology.startUsing) { use(item) }
        .accessibilityAction(named: UserTerminology.pageComposition) { configuringKeyboard = item.keyboard }
    }

    private func expansion(for id: String) -> Binding<Bool> {
        Binding(
            get: { expandedGroupIDs.contains(id) },
            set: { open in
                if open { expandedGroupIDs.insert(id) } else { expandedGroupIDs.remove(id) }
            })
    }

    /// Whether this published keyboard's shape may be used by its input method. A stale published
    /// entry outside the rule is reported as unavailable, never resolved to a forbidden shape.
    private func isAvailable(_ item: Item) -> Bool {
        HostLayoutAvailability.allows(
            kind: item.layout, schemaID: item.inputMethodID, descriptors: center.sourceSchemas)
    }

    /// The paired main layout, or nil when the keyboard itself is unavailable.
    private func mainLayout(for item: Item) -> LayoutDefinition? {
        guard isAvailable(item) else { return nil }
        let registry = layoutManager.registry
        let availability = HostLayoutAvailability.policy(
            schemaID: item.keyboard.inputMethodID, descriptors: center.sourceSchemas)
        return registry.resolvedLayout(
            id: registry.usableMainLayoutID(
                for: item.keyboard.compositionKey, availability: availability))
    }

    private func binding(for id: String) -> Binding<Bool> {
        Binding(
            get: { selectedIDs.contains(id) },
            set: { enabled in
                if enabled { selectedIDs.insert(id) } else { selectedIDs.remove(id) }
                hasEditedSelection = true
                center.dismissMessages()
            })
    }

    private func resetDraft() {
        let ids = Set(center.publishedKeyboards.map(\.id))
        // Offer one usable starting point without publishing a choice the user has not confirmed.
        let suggested =
            items.first(where: { $0.layout == .qwerty26 && isAvailable($0) })
            ?? items.first(where: isAvailable)
        selectedIDs = ids.isEmpty ? Set(suggested.map { [$0.id] } ?? []) : ids
        baselineIDs = ids
        hasEditedSelection = false
        if !initialized {
            let all = groups
            groupOrder = all.map(\.id)
            // A short list stays open; a long one opens only where something is already added.
            expandedGroupIDs = Set(
                all.count <= 3
                    ? all.map(\.id)
                    : all.filter { $0.items.contains { selectedIDs.contains($0.id) } }.map(\.id))
        }
        initialized = true
    }

    @MainActor
    private func save() {
        guard canSave else { return }
        let roster = selectedRoster
        // Block dismissal synchronously before the asynchronous transaction starts.
        isSaving = true
        Task { @MainActor in
            defer { isSaving = false }
            if await center.apply(roster) { resetDraft() }
        }
    }

    /// "Use now": publishes the draft with this pair added and switches the keyboard to it.
    @MainActor
    private func use(_ item: Item) {
        guard case .ready = center.phase, initialized, !isBusy, center.supportsManagement,
            isAvailable(item)
        else { return }
        let roster = items.filter { selectedIDs.contains($0.id) || $0.id == item.id }.map(\.keyboard)
        isSaving = true
        Task { @MainActor in
            defer { isSaving = false }
            if await center.apply(roster, selecting: item.keyboard) { resetDraft() }
        }
    }
}

/// The layout's shape as bars as wide as its keys, with no labels: at list-row size, text only
/// blurred the outline that tells 26, 14, 18 and 9 keys apart.
private struct LayoutThumbnail: View {
    static let width: CGFloat = 64
    let definition: LayoutDefinition

    var body: some View {
        Canvas { context, size in
            let rows = definition.rows.filter { !$0.keys.isEmpty }
            guard !rows.isEmpty else { return }
            let gap: CGFloat = 2
            let count = CGFloat(rows.count)
            let barHeight = min(5, (size.height - gap * (count - 1)) / count)
            let top = (size.height - barHeight * count - gap * (count - 1)) / 2
            let color = GraphicsContext.Shading.color(Color.secondary.opacity(0.55))
            for (rowIndex, row) in rows.enumerated() {
                let total = row.keys.reduce(0) { $0 + max($1.widthWeight, 0.1) }
                let usable = size.width - gap * CGFloat(row.keys.count - 1)
                let y = top + CGFloat(rowIndex) * (barHeight + gap)
                var x: CGFloat = 0
                for key in row.keys {
                    let width = usable * CGFloat(max(key.widthWeight, 0.1) / total)
                    let rect = CGRect(x: x, y: y, width: width, height: barHeight)
                    context.fill(Path(roundedRect: rect, cornerRadius: 1.5), with: color)
                    x += width + gap
                }
            }
        }
        .frame(width: Self.width, height: 36)
    }
}
