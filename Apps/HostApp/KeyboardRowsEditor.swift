import LayoutKit
import SwiftUI

/// Shared structural editor for main layouts and direct-input pages: rows and their keys. The
/// selected key's own actions live in `SelectedRowKeyActions`, next to its fields.
struct KeyboardRowsEditor: View {
    @Binding var rows: [LayoutRow]
    @Binding var selected: LayoutKeyPath
    @State private var pendingRowRemoval: Int?
    private let rowKeyLimit = LayoutResourceBudget.keysPerRegion

    var body: some View {
        Section(String(localized: "行与按键")) {
            ForEach(rows.indices, id: \.self) { row in
                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        Text("第 \(row + 1) 行").font(.headline)
                        Spacer()
                        Button {
                            moveRow(row, by: -1)
                        } label: {
                            Image(systemName: "arrow.up")
                        }
                        .disabled(row == 0).accessibilityLabel(Text("上移这一行"))
                        Button {
                            moveRow(row, by: 1)
                        } label: {
                            Image(systemName: "arrow.down")
                        }
                        .disabled(row == rows.count - 1).accessibilityLabel(Text("下移这一行"))
                        Button(role: .destructive) {
                            pendingRowRemoval = row
                        } label: {
                            Image(systemName: "trash")
                        }
                        .disabled(rows.count == 1).accessibilityLabel(Text("删除这一行"))
                    }
                    ScrollView(.horizontal) {
                        HStack(spacing: 6) {
                            ForEach(rows[row].keys.indices, id: \.self) { index in
                                KeyChip(
                                    label: rows[row].keys[index].label,
                                    isSelected: selected == .row(row, key: index)
                                ) { selected = .row(row, key: index) }
                            }
                            Button {
                                appendKey(row)
                            } label: {
                                Image(systemName: "plus")
                            }
                            .disabled(rows[row].keys.count >= rowKeyLimit)
                            .accessibilityLabel(Text("添加按键"))
                        }
                    }
                }
                .padding(.vertical, 6)
            }
            Button(String(localized: "添加一行"), systemImage: "plus") {
                rows.append(LayoutRow(keys: [newKey]))
                selected = .row(rows.count - 1, key: 0)
            }
            .disabled(rows.count >= LayoutResourceBudget.rows)
        }
        .buttonStyle(.borderless)
        .confirmationDialog(
            pendingRowRemoval.map { String(localized: "删除第 \($0 + 1) 行？") } ?? "",
            isPresented: Binding(get: { pendingRowRemoval != nil }, set: { if !$0 { pendingRowRemoval = nil } }),
            titleVisibility: .visible
        ) {
            Button(String(localized: "删除这一行"), role: .destructive) {
                guard let row = pendingRowRemoval, rows.indices.contains(row), rows.count > 1 else { return }
                pendingRowRemoval = nil
                rows.remove(at: row)
                selected = .row(0, key: 0)
            }
        } message: {
            if let row = pendingRowRemoval, rows.indices.contains(row) {
                Text("这一行的 \(rows[row].keys.count) 个按键会一起删除。")
            }
        }
    }

    private var newKey: LayoutKey { LayoutKey(label: "新键", action: .init(.literal, value: "。"), titleMode: nil) }

    private func appendKey(_ row: Int) {
        var keys = rows[row].keys
        keys.append(newKey)
        rows[row] = LayoutRow(keys: keys)
        selected = .row(row, key: keys.count - 1)
    }

    private func moveRow(_ row: Int, by offset: Int) {
        rows.swapAt(row, row + offset)
        selected = .row(row + offset, key: 0)
    }
}

/// Order, copy and delete for the selected row key. Sits right under the key's fields.
struct SelectedRowKeyActions: View {
    @Binding var rows: [LayoutRow]
    @Binding var selected: LayoutKeyPath
    private let rowKeyLimit = LayoutResourceBudget.keysPerRegion

    var body: some View {
        if case .row(let row, let index) = selected,
            rows.indices.contains(row), rows[row].keys.indices.contains(index)
        {
            Section(String(localized: "移动选中按键")) {
                HStack {
                    Button(String(localized: "左移")) { moveKey(row, index, by: -1) }.disabled(index == 0)
                    Spacer()
                    Button(String(localized: "右移")) { moveKey(row, index, by: 1) }.disabled(
                        index == rows[row].keys.count - 1)
                }
                HStack {
                    Button(String(localized: "移到上一行")) { transferKey(row, index, to: row - 1) }
                        .disabled(
                            row == 0 || rows[row].keys.count == 1
                                || (row > 0 && rows[row - 1].keys.count >= rowKeyLimit))
                    Spacer()
                    Button(String(localized: "移到下一行")) { transferKey(row, index, to: row + 1) }
                        .disabled(
                            row == rows.count - 1 || rows[row].keys.count == 1
                                || (row < rows.count - 1 && rows[row + 1].keys.count >= rowKeyLimit)
                        )
                }
                Button(String(localized: "复制按键")) {
                    var keys = rows[row].keys
                    keys.insert(keys[index], at: index + 1)
                    rows[row] = LayoutRow(keys: keys)
                    selected = .row(row, key: index + 1)
                }
                .disabled(rows[row].keys.count >= rowKeyLimit)
                Button(String(localized: "删除按键"), role: .destructive) {
                    var keys = rows[row].keys
                    keys.remove(at: index)
                    rows[row] = LayoutRow(keys: keys)
                    selected = .row(row, key: min(index, keys.count - 1))
                }
                .disabled(rows[row].keys.count == 1)
            }
            .buttonStyle(.borderless)
        }
    }

    private func moveKey(_ row: Int, _ index: Int, by offset: Int) {
        var keys = rows[row].keys
        keys.swapAt(index, index + offset)
        rows[row] = LayoutRow(keys: keys)
        selected = .row(row, key: index + offset)
    }

    private func transferKey(_ row: Int, _ index: Int, to target: Int) {
        var source = rows[row].keys
        let key = source.remove(at: index)
        var destination = rows[target].keys
        destination.append(key)
        rows[row] = LayoutRow(keys: source)
        rows[target] = LayoutRow(keys: destination)
        selected = .row(target, key: destination.count - 1)
    }
}

/// One selectable key in a structural list.
struct KeyChip: View {
    let label: String
    let isSelected: Bool
    let select: () -> Void

    var body: some View {
        Button(label, action: select)
            .buttonStyle(.bordered)
            .tint(isSelected ? .accentColor : .secondary)
            .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

struct KeyboardSplitEditor: View {
    let rows: [LayoutRow]
    /// Optional row names; the page editor names its authored footer row.
    var rowTitles: [String] = []
    @Binding var split: LayoutSplitConfiguration?
    var allowsInheritance = false
    var inheritanceTitle = String(localized: "和主键盘一样拆分")
    /// A main layout only chooses when it splits; the gap and the cuts live in its split view.
    var activationOnly = false
    /// The cuts the keyboard draws before any is saved (the bundled 26/18-key hand cuts).
    var defaultBreaks: [Int]? = nil
    /// No stored split means the split is off, never the initializer's default-on value.
    private var configuration: LayoutSplitConfiguration { split ?? LayoutSplitConfiguration(activation: .off) }

    /// The stored cut, or the same middle default the keyboard uses before a cut is saved.
    private var breaks: [Int] {
        configuration.cutPositions(rowKeyCounts: rows.map { $0.keys.count }, defaults: defaultBreaks)
    }

    var body: some View {
        if activationOnly {
            Section {
                Picker(
                    String(localized: "拆分时机"),
                    selection: Binding(
                        get: { configuration.activation },
                        set: { activation in update { $0.activation = activation } })
                ) {
                    Text("不拆分").tag(LayoutSplitConfiguration.Activation.off)
                    Text("宽屏时").tag(LayoutSplitConfiguration.Activation.automatic)
                    Text("始终").tag(LayoutSplitConfiguration.Activation.always)
                }
            } header: {
                Text("大屏拆分")
            } footer: {
                Text("拆分后，键盘分成左右两边，各自靠近一只手。")
            }
        } else {
            fullSection
        }
    }

    private var fullSection: some View {
        Section(String(localized: "拆分")) {
            if allowsInheritance {
                Toggle(
                    inheritanceTitle,
                    isOn: Binding(
                        get: { split == nil },
                        set: { follows in split = follows ? nil : LayoutSplitConfiguration(activation: .off) }))
            }
            if !allowsInheritance || split != nil {
                Toggle(
                    String(localized: "拆分键盘"),
                    isOn: Binding(
                        get: { configuration.activation != .off },
                        set: { enabled in update { $0.activation = enabled ? .automatic : .off } }))
                if configuration.activation != .off {
                    Picker(
                        String(localized: "拆分时机"),
                        selection: Binding(
                            get: { configuration.activation },
                            set: { activation in update { $0.activation = activation } })
                    ) {
                        Text("宽屏时").tag(LayoutSplitConfiguration.Activation.automatic)
                        Text("始终").tag(LayoutSplitConfiguration.Activation.always)
                    }
                    Toggle(
                        String(localized: "自动间距"),
                        isOn: Binding(
                            get: { configuration.automaticGap },
                            set: { automatic in update { $0.automaticGap = automatic } }))
                    if !configuration.automaticGap {
                        Slider(
                            value: Binding(
                                get: { configuration.gapFraction },
                                set: { fraction in update { $0.gapFraction = fraction } }), in: 0.05...0.85
                        ) { Text("中间间距") }
                    }
                    ForEach(rows.indices, id: \.self) { row in
                        Stepper(
                            String(localized: "\(rowTitle(row))：左侧 \(breaks[row]) 个键"),
                            value: Binding(
                                get: { breaks[row] },
                                set: { value in
                                    var updated = configuration
                                    updated.rowBreaks = breaks
                                    updated.rowBreaks[row] = value
                                    split = updated
                                }), in: rows[row].keys.count > 1 ? 1...(rows[row].keys.count - 1) : 1...1
                        )
                        .disabled(rows[row].keys.count <= 1)
                    }
                }
            }
        }
    }

    private func rowTitle(_ row: Int) -> String {
        rowTitles.indices.contains(row) ? rowTitles[row] : String(localized: "第 \(row + 1) 行")
    }

    private func update(_ change: (inout LayoutSplitConfiguration) -> Void) {
        // Cuts are written only by the steppers, so an untouched split keeps the layout's defaults.
        var value = configuration
        change(&value)
        split = value
    }

    static func adjusted(_ split: LayoutSplitConfiguration?, rows: [LayoutRow]) -> LayoutSplitConfiguration? {
        split?.adjusted(to: rows)
    }
}

/// Lists and adds the authored function keys. Empty arrays are deliberate: a deleted key stays
/// deleted. Ordering, copying and deleting the selected key live in the page editor's
/// "按键位置" section, next to the key's fields.
struct KeyboardChromeKeysEditor: View {
    @Binding var chrome: KeyboardPageChrome
    @Binding var selected: KeyboardPageKeyPath
    /// A categorized page's left rail is category navigation, so it has no authored keys.
    var allowsLeading = true

    var body: some View {
        Section(String(localized: "底行按键")) {
            ScrollView(.horizontal) {
                HStack(spacing: 6) {
                    chips(region: .bottom)
                    addButton(.bottom, label: String(localized: "添加底行按键"))
                }
            }
        }
        Section(String(localized: "右侧栏")) {
            chips(region: .trailing)
            addButton(.trailing, label: String(localized: "添加按键"))
        }
        if allowsLeading {
            Section(String(localized: "左侧栏")) {
                chips(region: .leading)
                addButton(.leading, label: String(localized: "添加按键"))
            }
        }
        if !chrome.trailing.isEmpty || (allowsLeading && !chrome.leading.isEmpty) {
            Section {
                if !chrome.trailing.isEmpty {
                    Toggle(String(localized: "右侧栏延伸到底行"), isOn: $chrome.trailingSpansBottom)
                    OptionalWidthField(
                        title: String(localized: "右侧栏宽度"),
                        placeholder: String(localized: "跟随键盘"),
                        value: $chrome.trailingWidth)
                }
                if allowsLeading && !chrome.leading.isEmpty {
                    OptionalWidthField(
                        title: String(localized: "左侧栏宽度"),
                        placeholder: String(localized: "跟随键盘"),
                        value: $chrome.leadingWidth)
                }
            } header: {
                Text("栏宽")
            } footer: {
                Text("留空时跟随键盘。")
            }
        }
    }

    private func chips(region: KeyboardPageChrome.Region) -> some View {
        let keys = chrome.keys(in: region)
        return ForEach(keys.indices, id: \.self) { index in
            KeyChip(label: keys[index].label, isSelected: selected == .chrome(region, key: index)) {
                selected = .chrome(region, key: index)
            }
        }
    }

    @ViewBuilder
    private func addButton(_ region: KeyboardPageChrome.Region, label: String) -> some View {
        let full = chrome.keys(in: region).count >= LayoutResourceBudget.keysPerRegion
        if region == .bottom {
            Button {
                append(region)
            } label: {
                Image(systemName: "plus")
            }
            .buttonStyle(.borderless)
            .disabled(full)
            .accessibilityLabel(Text(label))
        } else {
            Button(label, systemImage: "plus") { append(region) }
                .buttonStyle(.borderless)
                .disabled(full)
        }
    }

    /// Rail keys size by relative height; the footer sizes by relative width.
    private func newKey(_ region: KeyboardPageChrome.Region) -> LayoutKey {
        switch region {
        case .bottom:
            return LayoutKey(label: "空格", action: LayoutAction(.space), titleMode: .automatic)
        case .leading, .trailing:
            return LayoutKey(label: "⌫", action: LayoutAction(.backspace), titleMode: .automatic)
        }
    }

    private func append(_ region: KeyboardPageChrome.Region) {
        let keys = chrome.keys(in: region) + [newKey(region)]
        guard keys.count <= LayoutResourceBudget.keysPerRegion else { return }
        chrome = chrome.settingKeys(keys, in: region)
        selected = .chrome(region, key: keys.count - 1)
    }
}

/// Width text that is currently not a positive number. A form holding one must not save: the
/// field keeps its old value while invalid, so saving would silently write what is not shown.
@MainActor
final class WidthFieldValidity: ObservableObject {
    @Published private(set) var invalidCount = 0
    private var fields: Set<UUID> = []

    nonisolated init() {}

    var isInvalid: Bool { invalidCount > 0 }

    func setInvalid(_ invalid: Bool, for field: UUID) {
        let changed: Bool
        if invalid {
            changed = fields.insert(field).inserted
        } else {
            changed = fields.remove(field) != nil
        }
        if changed { invalidCount = fields.count }
    }
}

private struct WidthFieldValidityKey: EnvironmentKey {
    static var defaultValue: WidthFieldValidity { WidthFieldValidity() }
}

extension EnvironmentValues {
    var widthFieldValidity: WidthFieldValidity {
        get { self[WidthFieldValidityKey.self] }
        set { self[WidthFieldValidityKey.self] = newValue }
    }
}

/// Optional point or relative size: empty means the running keyboard decides. Reads and writes
/// numbers in the user's locale, so a comma decimal separator works where the keypad offers one.
struct OptionalWidthField: View {
    let title: String
    var placeholder = String(localized: "自动")
    @Binding var value: Double?
    @Environment(\.widthFieldValidity) private var validity: WidthFieldValidity
    @Environment(\.locale) private var locale
    @State private var fieldID = UUID()
    @State private var text = ""
    @State private var invalid = false
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(title)
                Spacer()
                TextField(placeholder, text: $text)
                    .keyboardType(.decimalPad).multilineTextAlignment(.trailing)
                    .focused($focused)
                    .onChange(of: text) { _, newValue in
                        apply(newValue)
                    }
            }
            if invalid {
                Text("请填写大于 0 的数字，或者留空。").font(.footnote).foregroundStyle(.red)
            }
        }
        .onAppear { text = value.map(format) ?? "" }
        .onChange(of: focused) { _, isFocused in
            // Leaving the field drops text that was never accepted, instead of showing an error
            // next to a value the draft does not have.
            if !isFocused { revertInvalidText() }
        }
        .onDisappear { validity.setInvalid(false, for: fieldID) }
    }

    private func format(_ number: Double) -> String {
        if number == number.rounded(), number.magnitude < 1e15 { return String(Int(number)) }
        return String(number).replacingOccurrences(of: ".", with: locale.decimalSeparator ?? ".")
    }

    /// Widths never carry grouping, so either decimal mark is read as the decimal point: the
    /// locale's keypad may offer "," and a hardware keyboard may type ".".
    private func parse(_ text: String) -> Double? {
        Double(text.replacingOccurrences(of: ",", with: "."))
    }

    private func apply(_ newValue: String) {
        let trimmed = newValue.trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty {
            value = nil
            mark(false)
            return
        }
        if let number = parse(trimmed), number.isFinite, number > 0 {
            value = number
            mark(false)
        } else {
            mark(true)
        }
    }

    private func mark(_ isInvalid: Bool) {
        invalid = isInvalid
        validity.setInvalid(isInvalid, for: fieldID)
    }

    private func revertInvalidText() {
        guard invalid else { return }
        text = value.map(format) ?? ""
        mark(false)
    }
}

/// The split view of the layout editor: the keys as they are when the keyboard splits, left keys,
/// the gap, right keys, row by row. Editing is the whole-view key tools applied to the halves; the
/// logic lives in `LayoutDefinition` (see `SplitArrangementEditing`).
struct SplitArrangementEditor: View {
    @Binding var layout: LayoutDefinition
    @Binding var selected: SplitKeyAddress
    let defaultBreaks: [Int]?
    let setSplit: (LayoutSplitConfiguration) -> Void

    private var configuration: LayoutSplitConfiguration { layout.split ?? LayoutSplitConfiguration(activation: .off) }
    private var rows: [LayoutRow] { layout.splitLetterRows(defaultBreaks: defaultBreaks) }
    private var cuts: [Int] { layout.splitCuts(defaultBreaks: defaultBreaks) }

    var body: some View {
        let rows = rows
        let cuts = cuts
        Section {
            SplitKeyGrid(
                rows: rows, cuts: cuts,
                gapFraction: configuration.automaticGap
                    ? LayoutSplitConfiguration.defaultGapFraction : configuration.gapFraction,
                selected: selected
            ) { selected = $0 }
        } header: {
            Text("拆分时的按键")
        } footer: {
            Text("左边、间距、右边。在这里改的键只在键盘拆分时使用。")
        }
        keyActions(rows: rows, cuts: cuts)
        Section(String(localized: "两边的间距")) {
            Toggle(
                String(localized: "自动间距"),
                isOn: Binding(
                    get: { configuration.automaticGap },
                    set: { automatic in
                        var updated = configuration
                        updated.automaticGap = automatic
                        setSplit(updated)
                    }))
            if !configuration.automaticGap {
                VStack(alignment: .leading) {
                    LabeledContent(
                        String(localized: "间距"), value: "\(Int((configuration.gapFraction * 100).rounded()))%")
                    Slider(
                        value: Binding(
                            get: { configuration.gapFraction },
                            set: { fraction in
                                var updated = configuration
                                updated.gapFraction = fraction
                                setSplit(updated)
                            }), in: 0.05...0.85)
                }
            }
        }
        Section(String(localized: "每行在哪里分开")) {
            ForEach(rows.indices, id: \.self) { row in
                HStack {
                    Text("第 \(row + 1) 行：左边 \(cuts[row]) 个键")
                    Spacer()
                    Button(String(localized: "左边少一个键")) { moveCut(row, by: -1) }
                        .disabled(layout.movingSplitCut(row: row, by: -1, defaultBreaks: defaultBreaks) == nil)
                    Button(String(localized: "左边多一个键")) { moveCut(row, by: 1) }
                        .disabled(layout.movingSplitCut(row: row, by: 1, defaultBreaks: defaultBreaks) == nil)
                }
                .buttonStyle(.borderless).font(.footnote)
            }
        }
        if layout.hasExplicitSplit {
            Section {
                Button(String(localized: "恢复为自动拆分")) {
                    layout = layout.restoringAutomaticSplit()
                    selected = SplitKeyAddress(row: 0, key: 0)
                }
            } footer: {
                Text("丢掉拆分时单独改过的按键，按键盘的行和分开的位置自动拆分。")
            }
        }
    }

    @ViewBuilder
    private func keyActions(rows: [LayoutRow], cuts: [Int]) -> some View {
        if rows.indices.contains(selected.row), rows[selected.row].keys.indices.contains(selected.key) {
            let key = rows[selected.row].keys[selected.key]
            Section(String(localized: "移动选中按键")) {
                HStack {
                    Button(String(localized: "左移")) {
                        apply(layout.movingSplitKey(at: selected, by: -1, defaultBreaks: defaultBreaks))
                    }
                    .disabled(selected.key == 0)
                    Spacer()
                    Button(String(localized: "右移")) {
                        apply(layout.movingSplitKey(at: selected, by: 1, defaultBreaks: defaultBreaks))
                    }
                    .disabled(selected.key == rows[selected.row].keys.count - 1)
                }
                Button(String(localized: "在后面添加按键")) {
                    apply(
                        layout.addingSplitKey(
                            after: selected, key: LayoutKey(label: "新键", action: .init(.literal, value: "。")),
                            defaultBreaks: defaultBreaks))
                }
                .disabled(rows[selected.row].keys.count >= LayoutResourceBudget.keysPerRegion)
                Button(String(localized: "复制按键")) {
                    apply(layout.addingSplitKey(after: selected, key: key, defaultBreaks: defaultBreaks))
                }
                .disabled(rows[selected.row].keys.count >= LayoutResourceBudget.keysPerRegion)
                Button(String(localized: "删除按键"), role: .destructive) {
                    apply(layout.removingSplitKey(at: selected, defaultBreaks: defaultBreaks))
                }
                .disabled(layout.removingSplitKey(at: selected, defaultBreaks: defaultBreaks) == nil)
            }
            .buttonStyle(.borderless)
        }
    }

    private func apply(_ edit: (layout: LayoutDefinition, selected: SplitKeyAddress)?) {
        guard let edit else { return }
        layout = edit.layout
        selected = edit.selected
    }

    private func moveCut(_ row: Int, by delta: Int) {
        if let moved = layout.movingSplitCut(row: row, by: delta, defaultBreaks: defaultBreaks) { layout = moved }
    }
}

/// The letter rows of the split view: left keys, a gap drawn in proportion to the keys, right keys.
private struct SplitKeyGrid: View {
    let rows: [LayoutRow]
    let cuts: [Int]
    let gapFraction: Double
    let selected: SplitKeyAddress
    let select: (SplitKeyAddress) -> Void
    private let spacing: CGFloat = 3

    /// The gap as key widths: the share of the widest row the gap takes of the whole width.
    private var gapWeight: Double {
        let widest = rows.map { $0.keys.reduce(0) { $0 + $1.widthWeight } }.max() ?? 1
        return gapFraction * widest / (1 - gapFraction)
    }

    var body: some View {
        let widest = rows.map { $0.keys.reduce(0) { $0 + $1.widthWeight } }.max() ?? 1
        let widestCount = rows.map { $0.keys.count }.max() ?? 1
        VStack(spacing: spacing) {
            ForEach(rows.indices, id: \.self) { row in
                GeometryReader { proxy in
                    let unit = max(
                        1, (proxy.size.width - spacing * CGFloat(widestCount - 1)) / CGFloat(widest + gapWeight))
                    let keys = rows[row].keys
                    let cut = min(cuts[row], keys.count)
                    HStack(spacing: spacing) {
                        ForEach(0..<cut, id: \.self) { chip(row, $0, keys[$0], unit) }
                        if cut < keys.count {
                            Spacer(minLength: CGFloat(gapWeight) * unit)
                            ForEach(cut..<keys.count, id: \.self) { chip(row, $0, keys[$0], unit) }
                        } else {
                            Spacer(minLength: 0)
                        }
                    }
                }
                .frame(height: 36)
            }
        }
    }

    private func chip(_ row: Int, _ index: Int, _ key: LayoutKey, _ unit: CGFloat) -> some View {
        let isSelected = selected == SplitKeyAddress(row: row, key: index)
        return Button {
            select(SplitKeyAddress(row: row, key: index))
        } label: {
            Text(key.label).font(.footnote).lineLimit(1).minimumScaleFactor(0.5)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .buttonStyle(.plain)
        .background(
            RoundedRectangle(cornerRadius: 6).fill(
                isSelected ? Color.accentColor.opacity(0.3) : Color.secondary.opacity(0.15))
        )
        .overlay(RoundedRectangle(cornerRadius: 6).stroke(isSelected ? Color.accentColor : .clear, lineWidth: 1.5))
        .frame(width: max(1, CGFloat(key.widthWeight) * unit))
        .accessibilityLabel(key.label)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}
