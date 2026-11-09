import CandidateKit
import KeyboardCore
import LayoutKit
import SwiftUI

// MARK: - Panel binding
//
// The Japanese twelve-key (kana12) board is the only page whose key area is one fixed surface.
// Everything it draws that is kana data lives in KeyboardCore (Kana12Layout); this file only
// binds it to the live panel: labels come from the shared label policy, presses go through the
// controller's kana handler so the press order matches the engine's landed state, and the two
// page-navigation actions arrive back through a queued callback.

/// New user-visible wording the kana surface and its settings row need that no shared label
/// policy already provides. Keycap and row wording is input-language data and stays out of here.
enum Kana12Wording {
    static let cursorLeft = String(localized: "kana.cursorLeft")
    static let modify = String(localized: "kana.modify")
    static let backspace = String(localized: "kana.backspace")
    static let flickHint = String(localized: "kana.flickHint")
    static let flickOnlyTitle = String(localized: "kana.flickOnly.title")
}

/// Japanese input data, not localized UI: the spoken name of each grid row names the kana row
/// itself (か行), exactly as a Japanese keyboard user hears it whatever the app language is.
enum Kana12RowNames {
    static let rows: [String: String] = [
        "a": "あ行", "ka": "か行", "sa": "さ行", "ta": "た行", "na": "な行",
        "ha": "は行", "ma": "ま行", "ya": "や行", "ra": "ら行", "wa": "わ行",
        "punctuation": "句読点",
    ]
}

/// The panel state a queued kana navigation may write. Capturing the bindings (never the view or
/// the controller) keeps the controller's navigation callback from retaining the panel graph.
struct Kana12NavigationBindings {
    let page: Binding<KeyboardPage>
    let showsAllCandidates: Binding<Bool>
}

extension KeyboardPanelView {
    // MARK: Surface eligibility

    /// Whether the canonical Japanese board draws its own four-row surface. Only the bundled,
    /// unedited kana12 definition qualifies; an edited board falls back to the ordinary configured
    /// rows, so the author's own faces stay visible. Chinese input keeps its normal rendering even
    /// when the pairing happens to be the kana board.
    var showsKana12Surface: Bool {
        page == .letters && !controller.isEnglishMode
            && controller.inputLanguage.language == .japanese
            && KeyboardPanelRules.isCanonicalKana12(activeDefinition)
    }

    /// The whole key area the kana surface takes: the three letter-row bands plus the control row's
    /// band, which is exactly the four rows the surface draws. The shell itself keeps its standard
    /// three-row height; a fifth row would grow the keyboard past the host's budget.
    var kana12AreaHeight: CGFloat {
        mainAreaHeight + KeyboardPanelGeometry.controlSpacing + keyHeight
    }

    /// The kana surface or, while candidates are expanded, the full candidate list in the same
    /// area (the surface owns the whole key area, so it has no footer row to leave under a list).
    @ViewBuilder
    var kana12KeyArea: some View {
        if showsExpandedCandidates {
            candidateRendererView(expanded: true)
                .frame(height: kana12AreaHeight, alignment: .top)
        } else {
            KeyAreaRenderGate(token: keyAreaRenderToken(phone: nil, readsComposition: true)) {
                kana12Surface
            }
            .equatable()
        }
    }

    /// Presentation only: the surface owns no composition, toggle-cycle, settings or engine state.
    private var kana12Surface: some View {
        Kana12KeyboardView(
            compositing: controller.snapshot.isComposing,
            labels: kana12Labels,
            systemSwitchKey: kana12SystemSwitchKey,
            languageKey: kana12LanguageKey,
            onAction: performKana12ViewAction
        )
        // The surface's fixed height already includes its own 4pt top/bottom inset, so its rows are
        // two points shorter than the panel's key rows to land exactly on the four bands above.
        .environment(\.keyboardKeyHeight, max(32, keyHeight - 2))
        .frame(height: kana12AreaHeight, alignment: .top)
    }

    /// The system keyboard switch keeps the native touch/accessibility behaviour (tap, hold and
    /// swipe up open the system list); the surface only supplies the slot.
    private var kana12SystemSwitchKey: AnyView? {
        guard let systemKeyboardSwitch else { return nil }
        return AnyView(
            NativeInputModeKey(
                handleEvent: systemKeyboardSwitch,
                accessibilitySwitch: { controller.handle(.switchKeyboard) }))
    }

    /// Tap toggles the input language through the kana queue; a long press opens the same
    /// keyboard list as the language key of the other boards.
    private var kana12LanguageKey: AnyView {
        let compositing = controller.snapshot.isComposing
        let title = kana12Labels.title(for: .language, compositing: compositing)
        let capID = "kana12-language"
        return AnyView(
            AlternateCharacterKey(
                cap: KeyCap(id: capID, title: title, subtitle: nil, action: .cycleLayout),
                alternates: userKeyboardAlternates,
                longPressDelay: keyLongPressDelay,
                layoutPicker: true,
                visualRole: "control",
                languageCurrentSideIsFirst: !controller.isEnglishMode,
                onSelect: { cap in
                    if cap.id == capID {
                        performKana12ViewAction(.language)
                    } else {
                        handleLanguageMenuCap(cap)
                    }
                }
            )
            .accessibilityLabel(
                kana12Labels.accessibility(for: .language, compositing: compositing)?.label ?? title))
    }

    // MARK: Labels

    /// Every face follows the scheme's input language (Japanese), never the app UI language: the
    /// space and Return keys keep their live conversion titles, and the language key names its
    /// target exactly like the shared control row.
    private var kana12Labels: Kana12Labels {
        let script = KeyLabelScript.japanese
        let intent = controller.returnKeyIntent
        return Kana12Labels(
            cursorLeft: "←",
            modify: "小゛゜",
            symbols: KeyLabelPolicy.symbolPageTitle(script: script),
            numbers: KeyLabelPolicy.numericPageTitle,
            language: KeyLabelPolicy.languageTitle(
                script: script, action: .toggleLanguage,
                isEnglishMode: controller.isEnglishMode,
                usesASCIIPunctuation: effectiveUsesASCIIPunctuation),
            backspace: "⌫",
            space: KeyLabelPolicy.spaceTitle(script: script, isComposing: false),
            convert: KeyLabelPolicy.spaceTitle(script: script, isComposing: true),
            confirm: KeyLabelPolicy.returnTitle(script: script, isComposing: true, intent: intent),
            newline: KeyLabelPolicy.returnTitle(script: script, isComposing: false, intent: intent),
            rowNames: Kana12RowNames.rows,
            controlAccessibility: kana12ControlAccessibility,
            composingControlAccessibility: kana12ComposingControlAccessibility,
            kanaFlickHint: Kana12Wording.flickHint)
    }

    private var kana12ControlAccessibility: [Kana12FunctionKey: Kana12FunctionKeyAccessibility] {
        let script = KeyLabelScript.japanese
        let intent = controller.returnKeyIntent
        return [
            .cursorLeft: Kana12FunctionKeyAccessibility(label: Kana12Wording.cursorLeft),
            .modify: Kana12FunctionKeyAccessibility(label: Kana12Wording.modify),
            .symbols: Kana12FunctionKeyAccessibility(
                label: KeyLabelPolicy.pageSwitchAccessibilityLabel(target: .symbols, isBundledPhonePad: false)),
            .numbers: Kana12FunctionKeyAccessibility(
                label: KeyLabelPolicy.pageSwitchAccessibilityLabel(target: .numeric, isBundledPhonePad: false)),
            .language: Kana12FunctionKeyAccessibility(
                label: KeyLabelPolicy.languageAccessibilityLabel(
                    script: script, action: .toggleLanguage,
                    isEnglishMode: controller.isEnglishMode,
                    usesASCIIPunctuation: effectiveUsesASCIIPunctuation)),
            .backspace: Kana12FunctionKeyAccessibility(label: Kana12Wording.backspace),
            .space: Kana12FunctionKeyAccessibility(
                label: KeyLabelPolicy.spaceAccessibilityLabel(script: script, isComposing: false)),
            .enter: Kana12FunctionKeyAccessibility(
                label: KeyLabelPolicy.returnAccessibilityLabel(isComposing: false, intent: intent)),
        ]
    }

    private var kana12ComposingControlAccessibility: [Kana12FunctionKey: Kana12FunctionKeyAccessibility] {
        let script = KeyLabelScript.japanese
        return [
            .space: Kana12FunctionKeyAccessibility(
                label: KeyLabelPolicy.spaceAccessibilityLabel(script: script, isComposing: true)),
            .enter: Kana12FunctionKeyAccessibility(
                label: KeyLabelPolicy.returnAccessibilityLabel(
                    isComposing: true, intent: controller.returnKeyIntent)),
        ]
    }

    // MARK: Dispatch

    /// One press from the surface. The controller resolves the gesture against the composition the
    /// engine actually landed and queues it behind earlier presses, so a fast flick sequence types
    /// in order and never waits on the engine queue here.
    func performKana12ViewAction(_ action: Kana12ViewAction) {
        emitKeyFeedback()
        controller.handleKana12(action)
    }

    /// The stored kana action of an edited board, reached through the ordinary definition/page key
    /// dispatcher. It still means the kana gesture, so it goes to the kana handler instead of being
    /// flattened into an engine key action the schema does not define.
    func performKana12LayoutAction(_ action: LayoutAction) {
        guard controller.inputLanguage.language == .japanese else { return }
        switch action.type {
        case .kana:
            guard let rowID = action.value, Kana12Key(rawValue: rowID) != nil else { return }
            emitKeyFeedback()
            controller.handleKana12(.kana(rowId: rowID, direction: .center))
        case .kanaModifier:
            emitKeyFeedback()
            controller.handleKana12(.modify)
        case .cursorLeft:
            emitKeyFeedback()
            controller.handleKana12(.cursorLeft)
        default:
            break
        }
    }

    // MARK: Lifecycle

    /// Installs the queued navigation callback and reads the flick-only option for this
    /// presentation. The callback runs after every earlier kana press has landed, so opening the
    /// symbol page or switching the input language keeps the presses that were already queued.
    func installKana12PanelBinding() {
        refreshKana12Preferences()
        let bindings = Kana12NavigationBindings(
            page: $page, showsAllCandidates: $showsAllCandidates)
        controller.onKana12Navigation = { [weak controller] action in
            switch action {
            case .symbols:
                // Only the page changes: the kana state is deliberately kept, because presses that
                // are still queued belong to the composition the user is typing.
                bindings.page.wrappedValue = .symbols
                bindings.showsAllCandidates.wrappedValue = false
            case .numbers:
                bindings.page.wrappedValue = .numeric
                bindings.showsAllCandidates.wrappedValue = false
            case .language:
                controller?.toggleInputMode()
            default:
                break
            }
        }
    }

    /// Re-reads the stored option; called at each presentation and host re-binding, never per key.
    func refreshKana12Preferences() {
        let flickOnly = KeyboardKana12Preferences.flickOnly
        if controller.kana12FlickOnly != flickOnly { controller.kana12FlickOnly = flickOnly }
    }

    /// The keyboard is gone: drop the callback (it must not outlive the panel) and every queued
    /// press. Merely opening a page inside this panel never calls this.
    func clearKana12PanelBinding() {
        controller.onKana12Navigation = nil
        controller.resetKana12State()
    }
}
