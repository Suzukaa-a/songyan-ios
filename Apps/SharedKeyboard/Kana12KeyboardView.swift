import CandidateKit
import KeyboardCore
import SkinKit
import SwiftUI

// MARK: - Contract

/// A flick direction on a kana key. `.center` is the plain tap.
///
/// The five slots are the same ones the system Japanese flick keyboard shows, so the cross
/// preview and the emitted action always name the same target.
enum Kana12Direction: String, CaseIterable, Equatable, Sendable {
    case center
    case left
    case up
    case right
    case down
}

/// The kana12 surface's only output. It reports intent and never touches the engine, the
/// toggle cycle or settings, so the owner binds it to whatever composition model it has.
///
/// `.kana` is emitted only for a direction the row actually carries: the わ key has no down
/// glyph, so that flick types nothing instead of inventing one.
enum Kana12ViewAction: Equatable, Sendable {
    case kana(rowId: String, direction: Kana12Direction)
    case modify
    case cursorLeft
    case symbols
    case numbers
    case language
    case backspace
    case space
    case enter
}

/// One kana key of the 4x3 grid and its five flick targets.
struct Kana12Row: Equatable, Sendable {
    let id: String
    let center: String
    let left: String?
    let up: String?
    let right: String?
    let down: String?

    init(
        id: String, center: String, left: String? = nil, up: String? = nil,
        right: String? = nil, down: String? = nil
    ) {
        self.id = id
        self.center = center
        self.left = left
        self.up = up
        self.right = right
        self.down = down
    }

    func glyph(for direction: Kana12Direction) -> String? {
        switch direction {
        case .center: return center
        case .left: return left
        case .up: return up
        case .right: return right
        case .down: return down
        }
    }
}

/// The fixed kana12 key table. The row IDs are the contract the owner receives; they are
/// input-language data rather than localized UI, so they stay out of the labels struct.
enum Kana12KanaRows {
    private static func row(_ key: Kana12Key) -> Kana12Row {
        func face(_ direction: Kana12FlickDirection) -> String? {
            switch Kana12Layout.output(for: key, direction: direction) {
            case .kana(let value), .literal(let value): return value
            case nil: return nil
            }
        }
        return Kana12Row(
            id: key.rawValue, center: face(.tap)!, left: face(.left), up: face(.up),
            right: face(.right), down: face(.down))
    }

    static let rowA = row(.a)
    static let rowKa = row(.ka)
    static let rowSa = row(.sa)
    static let rowTa = row(.ta)
    static let rowNa = row(.na)
    static let rowHa = row(.ha)
    static let rowMa = row(.ma)
    static let rowYa = row(.ya)
    static let rowRa = row(.ra)
    static let rowWa = row(.wa)
    static let rowPunctuation = row(.punctuation)

    /// The three upper rows of the centre block, in draw order.
    static let letterRows: [[Kana12Row]] = [
        [rowA, rowKa, rowSa],
        [rowTa, rowNa, rowHa],
        [rowMa, rowYa, rowRa],
    ]
    /// The centre block's fourth row after the modify key: わ and the punctuation key.
    static let bottomRow: [Kana12Row] = [rowWa, rowPunctuation]
    static let all: [Kana12Row] = letterRows.flatMap { $0 } + bottomRow

    static func row(id: String) -> Kana12Row? {
        all.first { $0.id == id }
    }

    /// The centre block position of a row, used only to place the cross preview over the
    /// key being pressed.
    static func gridPosition(ofRowID id: String) -> (row: Int, column: Int)? {
        for (rowIndex, rows) in letterRows.enumerated() {
            if let column = rows.firstIndex(where: { $0.id == id }) {
                return (row: rowIndex, column: column)
            }
        }
        if let column = bottomRow.firstIndex(where: { $0.id == id }) {
            return (row: 3, column: column + 1)
        }
        return nil
    }
}

/// The non-kana keys around the centre block. Their visible titles and spoken descriptions
/// are caller-supplied because they are UI strings, not input-language keycap data.
enum Kana12FunctionKey: String, Equatable, Sendable {
    case cursorLeft
    case modify
    case symbols
    case numbers
    case language
    case backspace
    case space
    case enter
}

/// A function key's spoken name and hint, supplied by the caller so every UI language can
/// translate them without a Chinese or Japanese literal living in this view.
struct Kana12FunctionKeyAccessibility: Equatable, Sendable {
    let label: String
    let hint: String?

    init(label: String, hint: String? = nil) {
        self.label = label
        self.hint = hint
    }
}

/// Everything the surface draws that is UI text or a spoken description.
///
/// The kana glyphs themselves are input-language data in `Kana12KanaRows`; this struct holds
/// only the strings a localized keyboard chrome owns.
struct Kana12Labels: Equatable, Sendable {
    let cursorLeft: String
    let modify: String
    let symbols: String
    /// Fills the rail's fourth slot while the system switch key is not shown.
    let numbers: String
    let language: String
    let backspace: String
    /// Shown when no composition is live.
    let space: String
    /// Shown on the space key while a composition is live (変換).
    let convert: String
    /// Shown on the return key while a composition is live (確定).
    let confirm: String
    /// Shown on the return key when no composition is live (改行).
    let newline: String
    /// Spoken row names keyed by row id, e.g. "ka" for the か row. A missing entry falls
    /// back to the key's centre glyph.
    let rowNames: [String: String]
    /// Spoken names and hints for the function keys, keyed by key.
    let controlAccessibility: [Kana12FunctionKey: Kana12FunctionKeyAccessibility]
    /// Overrides `controlAccessibility` while a composition is live, for the space and return
    /// keys whose visible title changes (空白/変換, 改行/確定).
    let composingControlAccessibility: [Kana12FunctionKey: Kana12FunctionKeyAccessibility]
    /// One hint shared by every kana key; nil keeps the keys' default spoken value only.
    let kanaFlickHint: String?

    init(
        cursorLeft: String,
        modify: String,
        symbols: String,
        numbers: String,
        language: String,
        backspace: String,
        space: String,
        convert: String,
        confirm: String,
        newline: String,
        rowNames: [String: String] = [:],
        controlAccessibility: [Kana12FunctionKey: Kana12FunctionKeyAccessibility] = [:],
        composingControlAccessibility: [Kana12FunctionKey: Kana12FunctionKeyAccessibility] = [:],
        kanaFlickHint: String? = nil
    ) {
        self.cursorLeft = cursorLeft
        self.modify = modify
        self.symbols = symbols
        self.numbers = numbers
        self.language = language
        self.backspace = backspace
        self.space = space
        self.convert = convert
        self.confirm = confirm
        self.newline = newline
        self.rowNames = rowNames
        self.controlAccessibility = controlAccessibility
        self.composingControlAccessibility = composingControlAccessibility
        self.kanaFlickHint = kanaFlickHint
    }

    func title(for key: Kana12FunctionKey, compositing: Bool) -> String {
        switch key {
        case .cursorLeft: return cursorLeft
        case .modify: return modify
        case .symbols: return symbols
        case .numbers: return numbers
        case .language: return language
        case .backspace: return backspace
        case .space: return compositing ? convert : space
        case .enter: return compositing ? confirm : newline
        }
    }

    func accessibility(
        for key: Kana12FunctionKey, compositing: Bool
    ) -> Kana12FunctionKeyAccessibility? {
        let composing = compositing ? composingControlAccessibility[key] : nil
        return composing ?? controlAccessibility[key]
    }
}

// MARK: - Surface

/// The standalone kana12 (Japanese twelve-key) key surface.
///
/// Layout is fixed: a 4x3 centre block (あ か さ / た な は / ま や ら / 小゛゜ わ 、。?!)
/// between a left rail (cursor left, 記号, あ/A, system switch or 123) and a right rail (delete,
/// space, return). The return key spans the lower two rows; the host supplies its existing
/// system switch so its input-mode menu and accessibility behavior stay shared.
///
/// The view is presentation only. It owns no composition, toggle-cycle, settings or engine
/// state; the owner maps `Kana12ViewAction` onto the real keyboard controller.
struct Kana12KeyboardView: View {
    @Environment(\.keyboardAppearance) private var appearance
    @Environment(\.keyboardKeyHeight) private var keyHeight

    let compositing: Bool
    let labels: Kana12Labels
    let systemSwitchKey: AnyView?
    /// The panel's language key, so a long press lists the added keyboards like every other board.
    let languageKey: AnyView?
    /// The panel's repeating delete, so holding it keeps deleting like every other board.
    let deleteKey: AnyView?
    let onAction: (Kana12ViewAction) -> Void

    @State private var presses = Kana12Presses()

    private static let spacing: CGFloat = 4
    private static let padding: CGFloat = 4

    init(
        compositing: Bool,
        labels: Kana12Labels,
        systemSwitchKey: AnyView? = nil,
        languageKey: AnyView? = nil,
        deleteKey: AnyView? = nil,
        onAction: @escaping (Kana12ViewAction) -> Void
    ) {
        self.compositing = compositing
        self.labels = labels
        self.systemSwitchKey = systemSwitchKey
        self.languageKey = languageKey
        self.deleteKey = deleteKey
        self.onAction = onAction
    }

    /// Follow the panel's shared key height so the four rows match the letter rows the panel
    /// fits around this surface.
    private var rowHeight: CGFloat { max(32, keyHeight) }
    private var surfaceHeight: CGFloat { rowHeight * 4 + Self.spacing * 3 + Self.padding * 2 }

    var body: some View {
        GeometryReader { proxy in
            let metrics = Kana12LayoutMetrics(
                size: CGSize(width: proxy.size.width, height: surfaceHeight),
                rowHeight: rowHeight,
                spacing: Self.spacing,
                padding: Self.padding)
            content(metrics: metrics)
                .frame(width: proxy.size.width, height: surfaceHeight, alignment: .topLeading)
                .overlay(alignment: .topLeading) {
                    flickPreview(metrics: metrics)
                }
        }
        .frame(height: surfaceHeight)
        .onDisappear { presses = Kana12Presses() }
    }

    // MARK: Key area

    private func content(metrics: Kana12LayoutMetrics) -> some View {
        HStack(spacing: metrics.spacing) {
            leadingRail(metrics: metrics)
            centreGrid(metrics: metrics)
            trailingRail(metrics: metrics)
        }
        .padding(metrics.padding)
    }

    private func leadingRail(metrics: Kana12LayoutMetrics) -> some View {
        VStack(spacing: metrics.spacing) {
            functionKey(.cursorLeft, role: "control").frame(height: metrics.rowHeight)
            functionKey(.symbols, role: "control").frame(height: metrics.rowHeight)
            Group {
                if let languageKey {
                    languageKey
                } else {
                    functionKey(.language, role: "control")
                }
            }
            .frame(height: metrics.rowHeight)
            Group {
                if let systemSwitchKey {
                    systemSwitchKey
                } else {
                    // The kana board has no digits, so the slot the system switch leaves empty
                    // opens the numeric page instead of a hole.
                    functionKey(.numbers, role: "control")
                }
            }
            .frame(height: metrics.rowHeight)
        }
        .frame(width: metrics.keyWidth)
    }

    private func centreGrid(metrics: Kana12LayoutMetrics) -> some View {
        VStack(spacing: metrics.spacing) {
            ForEach(0..<Kana12KanaRows.letterRows.count, id: \.self) { index in
                kanaRow(Kana12KanaRows.letterRows[index], metrics: metrics)
            }
            HStack(spacing: metrics.spacing) {
                functionKey(.modify, role: "key")
                    .frame(width: metrics.keyWidth, height: metrics.rowHeight)
                ForEach(Kana12KanaRows.bottomRow, id: \.id) { row in
                    kanaKey(row, metrics: metrics)
                        .frame(width: metrics.keyWidth, height: metrics.rowHeight)
                }
            }
        }
    }

    private func kanaRow(_ rows: [Kana12Row], metrics: Kana12LayoutMetrics) -> some View {
        HStack(spacing: metrics.spacing) {
            ForEach(rows, id: \.id) { row in
                kanaKey(row, metrics: metrics)
                    .frame(width: metrics.keyWidth, height: metrics.rowHeight)
            }
        }
    }

    private func trailingRail(metrics: Kana12LayoutMetrics) -> some View {
        VStack(spacing: metrics.spacing) {
            Group {
                if let deleteKey {
                    deleteKey
                } else {
                    functionKey(.backspace, role: "control")
                }
            }
            .frame(height: metrics.rowHeight)
            functionKey(.space, role: "key").frame(height: metrics.rowHeight)
            functionKey(.enter, role: "accent")
                .frame(height: metrics.rowHeight * 2 + metrics.spacing)
        }
        .frame(width: metrics.keyWidth)
    }

    // MARK: Keys

    private func kanaKey(_ row: Kana12Row, metrics: Kana12LayoutMetrics) -> some View {
        Kana12KanaKey(
            row: row,
            rowName: labels.rowNames[row.id] ?? row.center,
            flickHint: labels.kanaFlickHint,
            isPressed: presses.isPressed(row.id),
            onChanged: { translation in
                presses.move(rowID: row.id, translation: translation, cell: metrics.previewCell)
            },
            onEnded: { translation in
                if let action = presses.end(row, translation: translation, cell: metrics.previewCell) {
                    onAction(action)
                }
            },
            onAccessibilityCenter: {
                onAction(.kana(rowId: row.id, direction: .center))
            },
            onAccessibilityDirection: { direction in
                onAction(.kana(rowId: row.id, direction: direction))
            })
    }

    private func functionKey(_ key: Kana12FunctionKey, role: String) -> some View {
        let title = labels.title(for: key, compositing: compositing)
        let description = labels.accessibility(for: key, compositing: compositing)
        // Symbol-only function keys read at the icon size; word labels follow their cap role.
        let textSize =
            key == .backspace || key == .cursorLeft
            ? appearance.controlIconSize
            : (role == "key" ? appearance.keyTextSize : appearance.controlTextSize)
        return Kana12FunctionKeyButton(
            title: title,
            role: role,
            textSize: textSize,
            accessibilityLabel: description?.label ?? title,
            accessibilityHint: description?.hint,
            action: { onAction(Self.viewAction(for: key)) }
        )
        .background {
            if key == .space || key == .backspace { KeyboardSidewaysGestureOwner() }
        }
    }

    @ViewBuilder
    private func flickPreview(metrics: Kana12LayoutMetrics) -> some View {
        if let press = presses.preview, !press.isCancelled,
            let row = Kana12KanaRows.row(id: press.rowID),
            let rect = metrics.rect(forRowID: press.rowID)
        {
            Kana12FlickPreview(
                row: row,
                direction: Kana12FlickRules.direction(translation: press.translation),
                cell: metrics.previewCell,
                center: metrics.previewCenter(for: rect))
        }
    }

    private static func viewAction(for key: Kana12FunctionKey) -> Kana12ViewAction {
        switch key {
        case .cursorLeft: return .cursorLeft
        case .modify: return .modify
        case .symbols: return .symbols
        case .numbers: return .numbers
        case .language: return .language
        case .backspace: return .backspace
        case .space: return .space
        case .enter: return .enter
        }
    }
}

// MARK: - Press state

struct Kana12Press: Equatable {
    let rowID: String
    var translation: CGSize
    var isCancelled: Bool
}

/// The kana keys under fingers, one entry per key, so a two-thumb rollover types every key it
/// touches, each on its own release.
struct Kana12Presses: Equatable {
    private var byRow: [String: Kana12Press] = [:]
    /// The newest press owns the flick preview.
    private var previewRowID: String?

    var preview: Kana12Press? { previewRowID.flatMap { byRow[$0] } }

    func isPressed(_ rowID: String) -> Bool { byRow[rowID] != nil }

    mutating func move(rowID: String, translation: CGSize, cell: CGFloat) {
        let cancelled = Kana12FlickRules.isCancelled(translation: translation, cell: cell)
        if var current = byRow[rowID] {
            current.translation = translation
            current.isCancelled = current.isCancelled || cancelled
            byRow[rowID] = current
            return
        }
        byRow[rowID] = Kana12Press(rowID: rowID, translation: translation, isCancelled: cancelled)
        previewRowID = rowID
    }

    /// Ends the press on `row` and returns what it types, if anything.
    mutating func end(_ row: Kana12Row, translation: CGSize, cell: CGFloat) -> Kana12ViewAction? {
        guard let current = byRow.removeValue(forKey: row.id) else { return nil }
        if previewRowID == row.id { previewRowID = nil }
        let cancelled = current.isCancelled || Kana12FlickRules.isCancelled(translation: translation, cell: cell)
        guard !cancelled else { return nil }
        let direction = Kana12FlickRules.direction(translation: translation)
        // Past the threshold with no glyph that way types nothing, like a flick with no target.
        guard row.glyph(for: direction) != nil else { return nil }
        return .kana(rowId: row.id, direction: direction)
    }
}

/// The flick decision, kept out of the view so the cardinal rule and the cancel rule are
/// stated once and are easy to retune.
enum Kana12FlickRules {
    /// How far the finger must travel before a cardinal direction replaces the tap (points).
    static let selectionDistance: CGFloat = 16
    /// A press dragged farther than this is a cancel, not a long flick: it types nothing.
    static let cancelDistance: CGFloat = 88
    /// At least this much of the cell size is also treated as a cancel, for wide keys.
    static let cancelCellShare: CGFloat = 1.8

    static func direction(translation: CGSize) -> Kana12Direction {
        let dx = translation.width
        let dy = translation.height
        guard max(abs(dx), abs(dy)) >= selectionDistance else { return .center }
        // Cardinal selection: the dominant axis wins, and an exact diagonal stays horizontal.
        if abs(dx) >= abs(dy) { return dx < 0 ? .left : .right }
        return dy < 0 ? .up : .down
    }

    static func isCancelled(translation: CGSize, cell: CGFloat) -> Bool {
        let limit = max(cancelDistance, cell * cancelCellShare)
        let distance = (translation.width * translation.width + translation.height * translation.height)
            .squareRoot()
        return distance > limit
    }
}

// MARK: - Metrics

private struct Kana12LayoutMetrics {
    let size: CGSize
    let rowHeight: CGFloat
    let spacing: CGFloat
    let padding: CGFloat

    /// Five equal columns: left rail, three centre keys, right rail.
    var keyWidth: CGFloat { max(24, (size.width - padding * 2 - spacing * 4) / 5) }
    var previewCell: CGFloat { min(keyWidth, rowHeight) }

    func rect(forRowID id: String) -> CGRect? {
        guard let position = Kana12KanaRows.gridPosition(ofRowID: id) else { return nil }
        let x = padding + CGFloat(position.column + 1) * (keyWidth + spacing)
        let y = padding + CGFloat(position.row) * (rowHeight + spacing)
        return CGRect(x: x, y: y, width: keyWidth, height: rowHeight)
    }

    /// Centre the three-cell-wide cross on the pressed key, but keep the whole cross inside
    /// the surface: a top-row preview would otherwise be clipped by the keyboard's top edge.
    func previewCenter(for rect: CGRect) -> CGPoint {
        let half = previewCell * 1.5
        let lowerX = padding + half
        let upperX = max(lowerX, size.width - padding - half)
        let lowerY = padding + half
        let upperY = max(lowerY, size.height - padding - half)
        return CGPoint(
            x: min(max(rect.midX, lowerX), upperX),
            y: min(max(rect.midY, lowerY), upperY))
    }
}

// MARK: - Kana key

private struct Kana12KanaKey: View {
    @Environment(\.keyboardAppearance) private var appearance

    let row: Kana12Row
    let rowName: String
    let flickHint: String?
    let isPressed: Bool
    let onChanged: (CGSize) -> Void
    let onEnded: (CGSize) -> Void
    let onAccessibilityCenter: () -> Void
    let onAccessibilityDirection: (Kana12Direction) -> Void

    var body: some View {
        Text(row.center)
            .font(appearance.font(appearance.keyTextSize))
            .lineLimit(1)
            .minimumScaleFactor(0.55)
            .foregroundStyle(Color(uiColor: appearance.text(on: "key")))
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(SkinKeyBackground(role: "key"))
            .contentShape(Rectangle())
            .background { KeyboardSidewaysGestureOwner() }
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { onChanged($0.translation) }
                    .onEnded { onEnded($0.translation) }
            )
            .overlay {
                RoundedRectangle(cornerRadius: appearance.skin.keycap.cornerRadius)
                    .fill(Color.primary.opacity(isPressed ? KeyboardPressPhysics.overlayOpacity : 0))
                    .padding(.horizontal, appearance.skin.spacing.visualInsetX)
                    .padding(.vertical, appearance.skin.spacing.visualInsetY)
                    .allowsHitTesting(false)
            }
            .keyboardPressMovement(isPressed: isPressed)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(rowName)
            .accessibilityValue(row.center)
            .accessibilityHint(flickHint ?? "")
            .accessibilityAddTraits(.isKeyboardKey)
            .accessibilityAction { onAccessibilityCenter() }
            .kana12AccessibilityAction(row.left) { onAccessibilityDirection(.left) }
            .kana12AccessibilityAction(row.up) { onAccessibilityDirection(.up) }
            .kana12AccessibilityAction(row.right) { onAccessibilityDirection(.right) }
            .kana12AccessibilityAction(row.down) { onAccessibilityDirection(.down) }
    }
}

// MARK: - Function key

private struct Kana12FunctionKeyButton: View {
    @Environment(\.keyboardAppearance) private var appearance

    let title: String
    let role: String
    let textSize: Double
    let accessibilityLabel: String
    let accessibilityHint: String?
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(appearance.font(textSize))
                .lineLimit(1)
                .minimumScaleFactor(0.55)
                .foregroundStyle(Color(uiColor: appearance.text(on: role)))
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(SkinKeyBackground(role: role))
                .contentShape(Rectangle())
        }
        .buttonStyle(KeyboardPressStyle())
        .accessibilityLabel(accessibilityLabel)
        .accessibilityHint(accessibilityHint ?? "")
        .accessibilityAddTraits(.isKeyboardKey)
    }
}

// MARK: - Flick preview

/// The cross shown under the finger while a kana key is held: centre glyph plus the four
/// cardinal targets, the current pick painted with the skin's selected role.
private struct Kana12FlickPreview: View {
    @Environment(\.keyboardAppearance) private var appearance

    let row: Kana12Row
    let direction: Kana12Direction
    let cell: CGFloat
    let center: CGPoint

    var body: some View {
        ZStack(alignment: .topLeading) {
            slot(.up, glyph: row.up, x: cell, y: 0)
            slot(.left, glyph: row.left, x: 0, y: cell)
            slot(.center, glyph: row.center, x: cell, y: cell)
            slot(.right, glyph: row.right, x: cell * 2, y: cell)
            slot(.down, glyph: row.down, x: cell, y: cell * 2)
        }
        .frame(width: cell * 3, height: cell * 3, alignment: .topLeading)
        .position(x: center.x, y: center.y)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
        .shadow(color: .black.opacity(0.18), radius: 4, y: 2)
    }

    @ViewBuilder
    private func slot(_ slotDirection: Kana12Direction, glyph: String?, x: CGFloat, y: CGFloat) -> some View {
        let isSelected = slotDirection == direction
        Group {
            if let glyph {
                Text(glyph)
                    .font(appearance.font(appearance.keyTextSize))
                    .lineLimit(1)
                    .minimumScaleFactor(0.55)
                    .foregroundStyle(Color(uiColor: appearance.text(on: isSelected ? "selected" : "key")))
                    .frame(width: cell, height: cell)
                    .background(SkinKeyBackground(role: isSelected ? "selected" : "key"))
            } else {
                // Keep the cross shape even where the row has no target, so a missing
                // direction reads as "nothing here" instead of a broken preview.
                Color.clear
                    .frame(width: cell, height: cell)
                    .background(SkinKeyBackground(role: "control"))
                    .opacity(0.45)
            }
        }
        .offset(x: x, y: y)
    }
}

// MARK: - Accessibility helpers

private extension View {
    /// Adds one named VoiceOver action per direction the row actually carries. A direction
    /// without a glyph gets no action, matching the fact that its flick types nothing.
    @ViewBuilder
    func kana12AccessibilityAction(_ glyph: String?, perform: @escaping () -> Void) -> some View {
        if let glyph {
            accessibilityAction(named: Text(glyph), perform)
        } else {
            self
        }
    }
}
