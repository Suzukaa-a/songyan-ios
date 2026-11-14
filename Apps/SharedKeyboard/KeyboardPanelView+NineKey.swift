import CandidateKit
import Combine
import KeyboardCore
import LayoutKit
import QuickContentKit
import SwiftUI

extension KeyboardPanelView {
    /// One rail slot equals one number row (`metrics.rowHeight`), so the left
    /// column and the 3×3 grid start every row on the same line.
    private func t9RailSlotHeight(_ metrics: PhoneKeypadMetrics) -> CGFloat { CGFloat(metrics.rowHeight) }

    /// The engine-backed choices a phone rail shows while composing: spelling
    /// locks (or their undo) first, then the reading filter's undo and readings.
    typealias T9RailChoices = SpellingRailChoices

    private var liveT9RailChoices: T9RailChoices { controller.spellingRailChoices }

    /// The live choices once settled (nil otherwise); feeds `heldT9RailChoices`.
    var settledT9RailChoices: T9RailChoices? {
        guard compactSpellingCapability, controller.snapshot.isComposing, t9RailChoicesSettled else { return nil }
        return liveT9RailChoices
    }

    /// The rail's engine queries for the live composition have settled: the
    /// ambiguity report and the first reading page both arrived (or will not).
    var t9RailChoicesSettled: Bool {
        !controller.ambiguityQueryPending && !controller.awaitsFirstReadingPage
    }

    /// What the rail shows and whether it may act on it. Each key resets the
    /// engine-backed choices and re-queries them ~50ms later. Showing the reset
    /// state in between flashed the rail back to punctuation (a tap meant for a
    /// reading then committed the composition with a symbol) and let a late
    /// spelling report shift the readings under the finger. Until the queries
    /// settle, the previous choices stay on screen; spelling/reading taps are
    /// deferred and checked against the live result, while undo remains inert.
    var displayedT9RailChoices: (choices: T9RailChoices, interactive: Bool) {
        if t9RailChoicesSettled || !controller.snapshot.isComposing { return (liveT9RailChoices, true) }
        return (heldT9RailChoices ?? T9RailChoices(), false)
    }

    /// Readings/spelling choices get a readable size instead of the 14pt control
    /// label size; long spellings still shrink to fit the rail width.
    private static let t9RailChoiceTitleSize: Double = 17

    /// Three fixed punctuation slots; only engine-backed reading choices scroll.
    private func t9LeadingSidebar(_ metrics: PhoneKeypadMetrics) -> some View {
        let displayed = displayedT9RailChoices
        let showsReadingChoices =
            controller.snapshot.isComposing
            // Interactive means `displayed.choices` are the live ones; resolving them
            // again here and in `t9ReadingChoices` cost two more passes per render.
            && (displayed.interactive ? !displayed.choices.isEmpty : heldT9RailChoices != nil)
        return ZStack {
            if showsReadingChoices {
                ScrollView(.vertical, showsIndicators: false) {
                    LazyVStack(spacing: CGFloat(metrics.spacing)) { t9ReadingChoices(metrics, displayed: displayed) }
                }
                .sharpCandidateScrollEdges()
            } else {
                // The first three type directly; from the fourth on, there is no long press here: tapping the main-area first key cycles through them.
                KeyboardPhoneSymbolRail(
                    caps: SymbolPageTable.quickRail(
                        symbols: activeDefinition?.t9QuickSymbols ?? quickSymbols.symbols,
                        ascii: controller.usesASCIIPunctuation), metrics: metrics,
                    onSelect: { handleKey($0.action) })
            }
        }
        .id(showsReadingChoices)
        // Readings rarely fill all three slots. The rail reads as one column of
        // choices on a side-key surface instead of keys with an empty hole below.
        .background {
            if showsReadingChoices {
                let column = RoundedRectangle(cornerRadius: appearance.keyCornerRadius)
                column
                    .fill(appearance.color("control"))
                    .overlay {
                        column.strokeBorder(
                            appearance.color("border"), lineWidth: appearance.borderWidth(for: "control"))
                    }
                    .padding(.horizontal, keyAppearance.keyInsetX)
                    .padding(.vertical, appearance.keyInsetY)
            }
        }
        // Outside the identity switch above: entering or leaving a composition
        // must not re-read the shared quick-symbol store every time.
        .onAppear { quickSymbols.reload() }
        .onChange(of: hostBindingTick) { quickSymbols.reload() }
    }

    /// One action owner for engine-backed spelling/undo, reused by the bundled
    /// quick-symbol rail and imported phone definitions. Imports keep every
    /// declared rail key below these options in the same vertical scroller.
    ///
    /// Spelling and reading choices use the same UIKit key (`AlternateCharacterKey`)
    /// as the quick symbols in this scroller: the drawn cap and the tracked control
    /// are one view, so the visible slot is exactly the hit slot, and a tap is not
    /// arbitrated differently from the neighbouring keys. Every slot keeps the digit
    /// row pitch (no divider), so the rail and the 3×3 grid stay on the same lines.
    @ViewBuilder
    private func t9ReadingChoices(
        _ metrics: PhoneKeypadMetrics, displayed resolved: (choices: T9RailChoices, interactive: Bool)? = nil
    ) -> some View {
        if controller.snapshot.isComposing {
            let displayed = resolved ?? displayedT9RailChoices
            let choices = displayed.choices
            // Undo is the delete key (`KeyboardController.handleBackspaceTap`): the rail
            // only offers choices, never a separate back button.
            Group {
                // What is already chosen stays visible (accent, not tappable), so the
                // rail never goes blank once every typed syllable has a reading.
                if let locked = choices.lockedOption {
                    t9RailSelection(locked, metrics: metrics)
                        .accessibilityLabel(String(localized: "已锁定组合 \(locked)"))
                }
                if choices.isFiltering {
                    t9RailSelection(choices.readingPrefix.joined(separator: " "), metrics: metrics)
                        .accessibilityLabel(String(localized: "已选读音 \(choices.readingPrefix.joined(separator: " "))"))
                }
                if !choices.canUndoLock {
                    ForEach(Array(choices.lockOptions.enumerated()), id: \.offset) { index, option in
                        t9RailChoiceKey(
                            option, id: "lock-\(option)", slot: "lock-\(index)",
                            hint: String(localized: "锁定组合"), metrics: metrics
                        ) {
                            controller.selectRailSpelling(option)
                        }
                    }
                }
                ForEach(Array(choices.readings.enumerated()), id: \.offset) { index, reading in
                    t9RailChoiceKey(
                        reading, id: "reading-\(index)-\(reading)", slot: "reading-\(index)",
                        hint: String(localized: "选择读音"), metrics: metrics
                    ) {
                        controller.selectRailReading(reading, expectedPrefix: choices.readingPrefix)
                    }
                }
            }
            if displayed.interactive && controller.readingFilter.hasMore
                && !controller.readingFilter.readFailed && !controller.readingPrefetchSatisfied
            {
                Color.clear.frame(height: 1)
                    .task(id: controller.readingFilter.nextIndex) {
                        if !Task.isCancelled { controller.loadMoreReadings() }
                    }
            }
        }
    }

    /// An applied choice in the rail slot rhythm; the delete key undoes it.
    private func t9RailSelection(_ text: String, metrics: PhoneKeypadMetrics) -> some View {
        Text(text)
            .font(appearance.font(Self.t9RailChoiceTitleSize))
            .foregroundStyle(appearance.accentForeground)
            .lineLimit(2)
            .multilineTextAlignment(.center)
            .minimumScaleFactor(0.6)
            .padding(.horizontal, 4)
            .frame(maxWidth: .infinity)
            .frame(height: t9RailSlotHeight(metrics))
            .accessibilityHint(String(localized: "按删除键撤销"))
    }

    /// A trusted engine choice drawn and tracked by the rail's UIKit key.
    private func t9RailChoiceKey(
        _ title: String, id: String, slot: String, hint: String,
        metrics: PhoneKeypadMetrics,
        perform: @escaping () -> Void
    ) -> some View {
        AlternateCharacterKey(
            cap: KeyCap(id: id, title: title, subtitle: hint, action: .literal(title)),
            alternates: [], phoneKey: true, phoneSideKey: true,
            visualRole: KeyboardAppearance.railChoiceRole,
            titleSize: Self.t9RailChoiceTitleSize,
            accessibilityID: "t9.spelling.\(slot)",
            onSelect: { _ in selectionFeedbackAfterEffect(perform) }
        )
        // The UIKit control belongs to its rail slot, so typing updates it in place
        // instead of building a new one per key. A changed cap id (another choice,
        // or a lock turning into a reading) abandons a press still held on it and
        // `configure` swaps in the new action.
        .id(slot)
        .frame(height: t9RailSlotHeight(metrics))
    }

    private func t9ImportedReadingRail(_ metrics: PhoneKeypadMetrics) -> some View {
        ScrollView(.vertical, showsIndicators: false) {
            LazyVStack(spacing: CGFloat(metrics.spacing)) {
                t9ReadingChoices(metrics)
            }
            .buttonStyle(KeyboardPressStyle())
        }
        .sharpCandidateScrollEdges()
    }

    /// A secondary rail built from the definition's auxiliary keys, laid out in
    /// deterministic row slots via `PhoneKeypadMetrics.slotSpans` — never an
    /// independent `VStack` whose `maxHeight` guesses at the grid.
    private func t9AuxiliaryRail(
        _ metrics: PhoneKeypadMetrics,
        position: LayoutAuxiliaryArea.Position
    ) -> some View {
        KeyboardPhoneDeclaredRail(
            keys: t9AuxiliaryKeys(position), position: position, metrics: metrics,
            readings: { t9ReadingChoices(metrics) },
            key: { key, index in definitionKey(key, id: "\(position.rawValue)-\(index)") })
    }

    /// The rail keys a phone keypad definition contributes on one side. This is used
    /// **only** for an imported definition (`PhoneKeypadRailPolicy.declared`); the
    /// bundled T9 is `bundledAuthored` and renders its own rail, so nothing declared
    /// here is used for it. Return is never filtered out — an import keeps exactly
    /// what it declared.
    func t9AuxiliaryKeys(_ position: LayoutAuxiliaryArea.Position) -> [LayoutKey] {
        guard let definition = activeDefinition else { return [] }
        return visibleKeys(PhoneKeypadRailPolicy.declaredKeys(in: definition, position: position))
    }

    /// The candidates beside a docked 9-key keyboard: a mirror of the keys, the same width, the
    /// same top and bottom and the same row pitch, each candidate on a keycap. With nothing typed
    /// the caps stay, faint, so the side never reads as empty. The swap button sits in the gap.
    func sideCandidateArea(_ plan: NineKeySideCandidatePlan, keyArea: CGRect) -> some View {
        let width = CGFloat(plan.candidateWidth)
        let strip = CGFloat(plan.stripWidth)
        let x = plan.side == .left ? keyArea.minX - strip - width : keyArea.maxX + strip
        let swapX = plan.side == .left ? keyArea.minX - strip : keyArea.maxX
        let context = candidateAreaContext()
        let pending = controller.snapshot.isComposing || !controller.session.pendingCodes.isEmpty
        let live = pending ? context.displayEntries : []
        // A key still decoding empties the list for a moment: the last real candidates stay on
        // screen instead, inert, since their indices no longer match the engine.
        let held = pending && live.isEmpty && !sideCandidateHold.shown.isEmpty
        let shown = held ? sideCandidateHold.shown : live
        let texts = shown.map(\.text)
        if texts != sideCandidateHold.shown.map(\.text) {
            // What was on screen fades out over the new list; see the onChange below.
            sideCandidateHold.outgoing = sideCandidateHold.shown
            sideCandidateHold.shown = shown
        }
        let rowHeight = keyArea.height / 4
        let typography = candidateTypography
        return ZStack(alignment: .topLeading) {
            ZStack {
                if !sideCandidateHold.outgoing.isEmpty {
                    SideCandidateKeys(
                        entries: sideCandidateHold.outgoing, rowHeight: rowHeight, typography: typography,
                        onSelect: nil, onReachEnd: nil
                    )
                    .opacity(sideCandidateOutgoing)
                    // Only ever a picture of the last list: a touch always lands on the new one.
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
                }
                SideCandidateKeys(
                    entries: shown, rowHeight: rowHeight, typography: typography,
                    onSelect: held
                        ? nil
                        : { entry in
                            let action = context.selectAction(entry)
                            if let run = context.actions.prepare(action) {
                                _ = run()
                            } else {
                                context.actions.perform(action)
                            }
                        },
                    onReachEnd: held || !context.hasMoreEntries ? nil : { context.actions.perform(.loadMore) }
                )
                .opacity(sideCandidateFade)
            }
            .frame(width: width, height: keyArea.height)
            .padding(.leading, x)
            .padding(.top, keyArea.minY)
            sideCandidateSwapButton(plan.side, width: plan.stripWidth)
                .frame(height: keyArea.height)
                .padding(.leading, swapX)
                .padding(.top, keyArea.minY)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .environment(\.keyboardAppearance, keyAppearance)
        .onChange(of: texts) { _, _ in
            // Cross-fade: the old list fades out as the new one fades in. Opacity only, so every
            // cell stays where it is hit-tested; the new list never falls below UIKit's
            // hit-test alpha, and the old one takes no touches.
            var instant = Transaction()
            instant.disablesAnimations = true
            withTransaction(instant) {
                sideCandidateOutgoing = 1
                sideCandidateFade = 0.4
            }
            Task { @MainActor in
                withAnimation(.easeOut(duration: 0.09)) {
                    sideCandidateOutgoing = 0
                    sideCandidateFade = 1
                }
            }
        }
    }

    private func sideCandidateSwapButton(_ side: NineKeyCandidateSide, width: Double) -> some View {
        Button {
            emitKeyFeedback()
            let next = side.mirrored
            nineKeyCandidateSide = next
            NineKeyCandidateSidePreferences.set(next)
        } label: {
            Image(systemName: "arrow.left.arrow.right")
                .font(appearance.font(appearance.controlIconSize))
                .foregroundStyle(Color(uiColor: appearance.text(on: "panel", secondary: true)))
                .frame(width: CGFloat(width), height: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(KeyboardPressStyle())
        .frame(width: CGFloat(width))
        .accessibilityLabel(String(localized: "候选区换到另一侧"))
        .accessibilityIdentifier("keyboard.sideCandidateSwap")
    }

    var standardT9Keypad: some View {
        StablePhoneKeypadShell(
            trailingSpansControlRow: isBuiltinPhonePad,
            expandsForSplit: activeSplit != nil,
            leading: { metrics in
                t9Rail(.leading, metrics: metrics)
            },
            main: { metrics in
                VStack(spacing: CGFloat(metrics.spacing)) {
                    if showsAllCandidates && !controller.snapshot.candidates.isEmpty {
                        expandedCandidates
                    } else {
                        // Per-key candidate/reading publishes re-ran and re-laid out the
                        // whole grid; it only changes with the key-area inputs.
                        KeyAreaRenderGate(token: keyAreaRenderToken(phone: metrics)) {
                            VStack(spacing: CGFloat(metrics.spacing)) {
                                ForEach(Array(definitionMainRows.enumerated()), id: \.offset) { index, row in
                                    definitionRow(
                                        row, id: "row-\(index)", spacing: CGFloat(metrics.spacing),
                                        split: activeSplit, rowIndex: index)
                                }
                            }
                        }.equatable()
                    }
                }
                // Candidate expand/collapse replaces the same area in place; page and
                // language switches likewise have no ancestor key-area animation.
            },
            trailing: { metrics in
                // An imported trailing rail may carry reading choices; only the bundled
                // editing rail is static.
                if isBuiltinPhonePad {
                    KeyAreaRenderGate(token: keyAreaRenderToken(phone: metrics)) {
                        t9Rail(.trailing, metrics: metrics)
                    }.equatable()
                } else {
                    t9Rail(.trailing, metrics: metrics)
                }
            },
            bottom: { metrics in
                // The bundled T9 keeps the shared standard control row. An imported
                // phone keypad keeps the DIY bottom bar it declared (its own control
                // row plus globe/layout switch), so importing a layout never silently
                // rewrites its information architecture.
                KeyAreaRenderGate(token: keyAreaRenderToken(phone: metrics)) {
                    if isBuiltinPhonePad { phoneControlRow(metrics) } else { layoutUtilityBar }
                }.equatable()
            })
    }

    /// A phone letter definition gets a phone digit pad on 123: 1–9 in the 3×3 grid, Delete, 0 and
    /// the comma in the right column, the page's punctuation in the rail and the control row on
    /// the grid's columns below. #+= stays the shared full symbol page.
    var phoneSymbolKeypad: some View {
        KeyboardPhoneDigitPad(
            usesASCIIPunctuation: effectiveUsesASCIIPunctuation, split: activeSplit,
            trailingSpansControlRow: false,
            showsExpanded: showsAllCandidates && !controller.snapshot.candidates.isEmpty,
            alternates: alternates, onKey: { handleKey($0.action) },
            expanded: { expandedCandidates },
            trailing: { metrics in
                if isBuiltinPhonePad {
                    KeyboardPhoneDigitTrailingRail(
                        metrics: metrics, comma: controlPolicy.utilityText,
                        commaAlternates: controlPolicy.utilityAlternates,
                        onDelete: { isRepeating in handleKey(.backspace, emitFeedback: !isRepeating) },
                        onKey: { handleKey($0.action) })
                } else {
                    t9Rail(.trailing, metrics: metrics)
                }
            },
            bottom: { metrics in
                phoneControlRow(metrics)
            })
    }

    /// The symbol page of every layout (#+= on 26/14/18-key, 符号 on 9-key):
    /// categories in the leading rail, the open category's symbols in a grid of
    /// digit-pad-height keys (four columns, two for kaomoji) that scrolls
    /// vertically, the ⌫ / 重输 / ⏎ column and the phone-pad control row, so a
    /// thumb reaches every symbol without hunting through rows of narrow keys.
    ///
    /// Like Sogou and iFlytek, one symbol returns to the page the user types on
    /// unless 锁定 is on; the lock lasts for this keyboard session.
    var phoneCategorySymbolKeypad: some View {
        let categories = phoneSymbolCategories
        let open = categories.first { $0.id == phoneSymbolCategoryID } ?? categories[0]
        let categorySplit = resolvedCategorySplit(open.split)
        return KeyboardCategorySymbolPad(
            categories: categories, open: open, split: categorySplit,
            trailingSpansControlRow: usesFixedEditingRail,
            onSelectCategory: { id in
                emitKeyFeedback()
                phoneSymbolCategoryID = id
            },
            key: { key, index in
                if open.authoredKeys != nil {
                    authoredPageKey(
                        key, id: "category-\(open.id)-\(index)", kind: .symbols,
                        onSelect: { action, feedback in recordCategoryAction(action, emitFeedback: feedback) })
                } else {
                    AlternateCharacterKey(cap: open.caps[index], alternates: [], showsKeyPreview: true) { cap in
                        recordCategoryAction(cap.action)
                    }
                }
            },
            trailing: { metrics in
                if usesFixedEditingRail { t9FixedEditingRail(metrics) } else { t9Rail(.trailing, metrics: metrics) }
            },
            bottom: { metrics in
                phoneControlRow(metrics, splitOverride: categorySplit?.withoutRowBreaks)
            }
        )
        // Every visit opens on 常用. Also picks up library edits made in the app
        // and recents from the symbol panel.
        .onAppear {
            phoneSymbolCategoryID = categories[0].id
            symbolLibrary.reload()
        }
        // Uses are recorded when the page closes, so 最近 never reorders under the
        // finger while several symbols are typed in a row.
        .onDisappear {
            symbolLibrary.recordUses(pendingSymbolUses)
            pendingSymbolUses = []
        }
    }

    /// Full-width marks lead in Chinese punctuation, half-width ones in English or
    /// ASCII punctuation, matching what the letter page's punctuation types.
    func recordCategoryAction(_ action: KeyAction, emitFeedback: Bool = true) {
        if action == .cycleLayout {
            handleDefinitionAction(action)
            return
        }
        guard handleKey(action, emitFeedback: emitFeedback), case .literal(let text) = action else { return }
        if !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { pendingSymbolUses.append(text) }
        if !symbolPageLocked { page = controller.hostPreferredInput == .numeric ? .numeric : .letters }
    }

    var phoneSymbolCategories: [SymbolPageTable.PhoneSymbolCategory] {
        let ascii = controller.isEnglishMode || controller.usesASCIIPunctuation
        let authored = pageDefinition?.categories
        return symbolLibrary.pageCategories(
            authored: authored, ascii: ascii, showsGlobe: systemKeyboardSwitch != nil,
            // Only the built-in tabs take the pairing's missing marks; a user's categories stay as made.
            leadingMarks: authored == nil ? pairingMissingMarks(ascii: ascii) : [],
            script: controller.inputLanguageScript)
    }

    /// Both rails go through the one policy: only the bundled T9 gets the
    /// shell-authored static keys. An import keeps all declared keys; verified
    /// reading choices are added only to its leading scroller while composing.
    /// Delete/return are never fabricated for an import.
    @ViewBuilder
    private func t9Rail(_ position: LayoutAuxiliaryArea.Position, metrics: PhoneKeypadMetrics) -> some View {
        let keys = t9AuxiliaryKeys(position)
        switch PhoneKeypadRailPolicy.content(isBuiltinPhonePad: isBuiltinPhonePad, declaredKeyCount: keys.count) {
        case .bundledAuthored:
            if position == .leading {
                t9LeadingSidebar(metrics)
            } else {
                t9FixedEditingRail(metrics)
            }
        case .declared:
            t9AuxiliaryRail(metrics, position: position)
        case .empty:
            if position == .leading && controller.snapshot.isComposing {
                t9ImportedReadingRail(metrics)
            } else {
                Color.clear
            }
        }
    }

    /// No pinyin-cycle key on the right: real readings are picked directly in the left scrolling rail.
    /// Only reachable for the bundled definition and the categorised symbol page.
    private func t9FixedEditingRail(_ metrics: PhoneKeypadMetrics) -> some View {
        KeyboardFixedEditingRail(
            metrics: metrics, returnTitle: controller.returnKeyTitle,
            returnAccessibilityLabel: controller.returnKeyAccessibilityLabel,
            isReturnEnabled: controller.isReturnKeyEnabled, isComposing: controller.snapshot.isComposing,
            onDelete: { isRepeating in handleKey(.backspace, emitFeedback: !isRepeating) },
            onReset: { keyFeedbackAfterEffect { _ = controller.discardComposition() } },
            onReturn: { handleDefinitionAction($0.action) })
    }
}

/// The 9-key side candidates on keycaps, in rows as tall as the key rows beside them. Scrolls a
/// row at a time past the rows that fit; `onSelect` nil draws an inert picture.
private struct SideCandidateKeys: View {
    let entries: [BrowserCandidate]
    let rowHeight: CGFloat
    let typography: CandidateTypography
    let onSelect: ((BrowserCandidate) -> Void)?
    let onReachEnd: (() -> Void)?
    @Environment(\.keyboardAppearance) private var appearance

    var body: some View {
        GeometryReader { proxy in
            let width = proxy.size.width
            let columns = CandidateExpandedGrid.columns(availableWidth: width, fontSize: typography.candidateSize)
            let unit = width / CGFloat(columns)
            let filled = CandidateExpandedGrid.rows(
                entries: entries, columns: columns, columnWidth: unit, typography: typography, cellPaddingX: 6)
            let blank = Array(repeating: CandidateExpandedGrid.Cell(entry: nil, span: 1), count: columns)
            let visibleRows = max(1, Int((proxy.size.height + 0.5) / max(1, rowHeight)))
            let rows = filled + Array(repeating: blank, count: max(0, visibleRows - filled.count))
            ScrollView(.vertical, showsIndicators: false) {
                LazyVStack(spacing: 0) {
                    ForEach(Array(rows.enumerated()), id: \.offset) { index, row in
                        HStack(spacing: 0) {
                            ForEach(Array(row.enumerated()), id: \.offset) { _, slot in
                                cap(slot.entry)
                                    .frame(width: unit * CGFloat(slot.span), height: rowHeight)
                            }
                        }
                        .onAppear {
                            if index == filled.count - 1 { onReachEnd?() }
                        }
                    }
                }
            }
            .scrollDisabled(filled.count <= visibleRows)
        }
    }

    @ViewBuilder
    private func cap(_ entry: BrowserCandidate?) -> some View {
        if let entry {
            Button {
                onSelect?(entry)
            } label: {
                Text(entry.text)
                    .font(appearance.font(typography.candidateSize))
                    .foregroundStyle(Color(uiColor: appearance.text(on: "key")))
                    .lineLimit(1)
                    .minimumScaleFactor(0.5)
                    .padding(.horizontal, 6)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background { capShape }
                    .contentShape(Rectangle())
            }
            .buttonStyle(KeyboardPressStyle())
            .disabled(onSelect == nil)
            .accessibilityLabel(entry.text)
        } else {
            capShape.opacity(0.4).accessibilityHidden(true)
        }
    }

    /// The same cap a key draws: its fill, corner, border and the skin's hard shadow.
    private var capShape: some View {
        let shape = RoundedRectangle(cornerRadius: appearance.keyCornerRadius)
        return
            shape
            .fill(appearance.color("key"))
            .overlay { shape.strokeBorder(appearance.color("border"), lineWidth: appearance.borderWidth(for: "key")) }
            .shadow(
                color: .black.opacity(appearance.skin.keycap.shadow == "subtle" ? 0.18 : 0), radius: 0, x: 0, y: 1)
            .padding(.horizontal, appearance.keyInsetX)
            .padding(.vertical, appearance.keyInsetY)
    }
}
