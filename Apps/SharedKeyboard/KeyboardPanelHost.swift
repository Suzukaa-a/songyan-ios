import AppearanceKit
import CandidateKit
import KeyboardCore
import LayoutKit
import SkinKit
import SwiftUI

/// Placeholder/status view for the panel: starting / failed with retry / keyboard panel once ready.
/// Shared by the host app's typing area and the keyboard extension so startup and error behavior match.
///
/// Appearance (skin + candidate-area layout + display mode) has exactly one read path and one snapshot,
/// so skin and candidate bar always belong to the same generation (no "new skin, old candidate area" state).
public struct KeyboardPanelHost: View {
    @ObservedObject var session: KeyboardPadSession
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.verticalSizeClass) private var verticalSizeClass
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @State private var appearanceSnapshot = AppearanceSnapshot()
    @State private var shuangpinHints: ShuangpinHintSnapshot?
    @State private var shuangpinHintRevision: UInt64 = 0
    @State private var shuangpinHintReadGate = LatestWinsReadGate()
    @State private var appearanceReadError: String?
    @State private var hasValidAppearance = false
    /// The ready controller's host appearance (Extension only; nil in the Host trial area,
    /// which has no `UITextDocumentProxy`). Only a fallback until the surface trait is known.
    private var hostAppearance: HostKeyboardAppearance {
        guard let controller = session.controller else { return .unspecified }
        return HostKeyboardAppearance(controller.keyboardAppearance)
    }
    private var appearance: KeyboardAppearance {
        // The controller's proxy traits can change while the session and skin
        // snapshot stay identical. Reading this tick makes the *parent* resolve
        // its palette again; a tick observed only by the child does not refresh
        // this computed environment value.
        _ = hostTraitsTick
        let host = hostAppearance
        let dark = KeyboardAppearancePolicy.resolvedDark(
            hostAppearance: host, systemDark: colorScheme == .dark,
            systemTraitKnown: systemTraitKnown)
        var resolved = KeyboardAppearance(skin: appearanceSnapshot.document.skin, dark: dark)
        resolved.candidateTextSize = storedCandidateTextSize
        resolved.showsCollapsedCandidateComments = storedCollapsedCandidateComments
        resolved.scalesKeyGaps = storedScalesKeyGaps
        return resolved
    }
    /// Runtime-only rescue; implementations must not require a shared selection write.
    private let onRestoreBuiltin: (() -> Void)?
    private let systemKeyboardSwitch: ((UIView, UIEvent) -> Void)?
    private let keyAlternates: ((KeyCap) -> [KeyCap])?
    private let layoutRegistry: LayoutRegistry?
    private let selectedLayoutID: String?
    private let loadsStoredLayouts: Bool
    private let additionalTools: AnyView?
    private let statusMessage: String?
    private let onStatusDetails: (() -> Void)?
    /// Injected by the extension: opens the host app (the extension has no application object of
    /// its own). The trial area in the app leaves it nil.
    private let openHostApp: ((URL, @escaping @MainActor (Bool) -> Void) -> Void)?
    /// Extension-only real dismissal for the wide-screen header entry; nil in the app trial.
    private let dismissKeyboard: (() -> Void)?
    private let onAppearanceChange: ((KeyboardAppearance) -> Void)?
    private let systemTraitKnown: Bool
    /// Optional reporting for embedded hosts; the extension adopts its own native budget.
    private let onPanelHeightChange: ((CGFloat) -> Void)?
    private let onPresentationBudgetChange: ((KeyboardPanelPresentationBudget) -> Void)?
    /// Accepted geometry seeds cold entry; explicit layout and appearance events update the native budget.
    @State private var initialGeometryBudget: (height: Double, size: Double)?
    private var candidateHeight: Double {
        if presentationBudget != nil { return appearanceSnapshot.document.candidateBar.collapsed.height }
        return initialGeometryBudget?.height ?? appearanceSnapshot.document.candidateBar.collapsed.height
    }
    private var candidateSize: Double {
        if presentationBudget != nil { return appearance.candidateFontSize }
        return initialGeometryBudget?.size ?? appearance.candidateFontSize
    }
    private var compactReadingRow: Bool { presentationBudget?.compact ?? (verticalSizeClass == .compact) }
    @State private var storedHeightPreset = KeyboardHeightPreferences.current
    @State private var storedCandidateTextSize = CandidateTextSizePreferences.current
    @State private var storedCollapsedCandidateComments = CollapsedCandidateCommentPreferences.current
    @State private var storedScalesKeyGaps = KeyGapScalingPreferences.current
    private var keyHeight: CGFloat {
        CGFloat(presentationBudget?.keyHeight ?? heightPreset.keyHeight(compact: compactReadingRow))
    }
    /// The extension's budget carries the preset it was measured with; the app trial reads it live.
    private var heightPreset: KeyboardHeightPreset { presentationBudget?.heightPreset ?? storedHeightPreset }

    /// Physical definitions submit new budgets; transient pages keep fitting the current definition.
    private var fixedShellHeight: CGFloat {
        if let presentationBudget { return CGFloat(presentationBudget.shellHeight) }
        let shell = definitionShell
        return CGFloat(
            KeyboardPanelGeometry.presentationShellHeight(
                candidateHeight: candidateHeight,
                keyHeight: keyHeight,
                candidateSize: candidateSize,
                readingRow: shell.readingRow,
                candidateArea: shell.candidateArea,
                compactReadingRow: compactReadingRow,
                physicalMainRows: shell.mainRows))
    }
    private let presentationBudget: KeyboardPanelPresentationBudget?
    /// Adopted on every host (re)binding; the in-panel restore turns it off in place.
    @State private var oneHandMode = KeyboardOneHandPreferences.current
    @State private var oneHandWidthPercent = KeyboardOneHandPreferences.widthPercent
    /// The side the toolbar button turns back on. Starts on the right, like the Android keyboard.
    @State private var lastOneHandSide: KeyboardOneHandMode =
        KeyboardOneHandPreferences.current == .off ? .right : KeyboardOneHandPreferences.current
    /// The selected definition's own page facts (ABC/123 grants excluded).
    @State private var definitionShell = KeyboardPresentationShell(readingRow: false, candidateArea: true)
    /// Letter rows the current page draws: the definition's budget on its letters page, three on
    /// the shared ABC/123 pages. The host re-fits the page inside the unchanged shell with this
    /// count instead of stretching the candidate band by the spare row.
    @State private var drawnMainRows = KeyboardPanelGeometry.standardMainRowCount
    /// Fit the current native height while UIKit applies a new configuration budget.
    /// The next geometry receipt adopts the requested height within the same presentation.
    private let presentedHeight: CGFloat?
    private var layoutShellHeight: CGFloat { presentedHeight ?? fixedShellHeight }
    private func panelFit(shellHeight: CGFloat) -> KeyboardPanelFit {
        // A shell taller than this budget (presented before a rotation to landscape) first lets
        // the rows grow back toward the portrait height, so the surplus does not all become a
        // tall, empty candidate bar.
        let rowCap =
            shellHeight > fixedShellHeight + 0.5
            ? max(keyHeight, CGFloat(heightPreset.keyHeight(compact: false))) : keyHeight
        return KeyboardPanelGeometry.fit(
            shellHeight: Double(shellHeight), candidateHeight: candidateHeight,
            standardKeyHeight: Double(rowCap),
            readingRowReserved: readingRowGranted,
            candidateAreaReserved: candidateAreaGranted,
            candidateSize: candidateSize,
            compactReadingRow: compactReadingRow,
            drawnMainRows: drawnMainRows)
    }
    /// Key rows never exceed the standard key height; the rest of the shared shell
    /// goes to the candidate area (or stays blank above a page without one).
    private var layoutFit: KeyboardPanelFit { panelFit(shellHeight: layoutShellHeight) }
    private func allowsOneHand(panelWidth: CGFloat) -> Bool {
        KeyboardOneHandLayoutPolicy.isAvailable(
            panelWidth: Double(panelWidth),
            isPhone: UIDevice.current.userInterfaceIdiom == .phone,
            compactHeight: verticalSizeClass == .compact,
            regularWidth: horizontalSizeClass == .regular)
    }

    /// The one write path for one-handed mode from the keyboard (settings row and gutter).
    private func setOneHandMode(_ mode: KeyboardOneHandMode) {
        guard mode != oneHandMode else { return }
        KeyboardOneHandPreferences.set(mode)
        oneHandMode = mode
        if mode != .off { lastOneHandSide = mode }
        // Keys move under any recorded route's window point, so drop it.
        KeyboardRoutedTouch.clear()
    }
    /// Standalone reading row granted by the host (the single owner). The initial value comes from the
    /// cold-start hint (`KeyboardInitialPresentation.readingRowReserved`), the same source as the first `loadView` frame.
    @State private var readingRowGranted = false
    /// Adopted at every presentation like the height preset; the row placement is what reserves height for the row.
    @State private var readingPlacement = KeyboardReadingPlacementPreferences.current
    @State private var candidateAreaGranted = true
    /// Latest eligibility report from the panel (a fact); only adopted as the granted value once the layout source has settled.
    @State private var latestReadingRowReport: CandidateReadingRowReport?
    /// Whether the layout source has settled (registry read, or it is certain only the bundled one applies).
    /// The extension passes it explicitly; when nil it is derived from the host's own read state (host typing area).
    private let layoutSourceSettled: Bool?
    private var resolvedLayoutSourceSettled: Bool {
        if let layoutSourceSettled { return layoutSourceSettled }
        if layoutRegistry != nil || !loadsStoredLayouts { return true }
        return storedRegistry != nil || layoutReadError != nil
    }
    private var registryAvailable: Bool { (layoutRegistry ?? storedRegistry) != nil }
    @State private var storedRegistry: LayoutRegistry?
    @State private var storedLayoutID: String?
    /// Bumped only when the ready controller reports a host-trait change, so the
    /// resolved skin variant (and background) follows the focused field live.
    @State private var hostTraitsTick = 0
    /// Scene/extension-safe replacement for observing `UIApplication.didBecomeActive`
    /// (which never fires in a keyboard extension). The extension controller bumps
    /// this on every `viewWillAppear` — i.e. each time the panel gains a new host
    /// (unlock, cross-app return). The Host trial area leaves it at 0.
    private let hostBindingTick: Int
    @State private var layoutReadError: String?
    /// Latest-wins generation gate: when notifications trigger several async reads, an old result must not overwrite a newer one.
    @State private var layoutReadGate = LatestWinsReadGate()
    @State private var appearanceReadGate = LatestWinsReadGate()
    @State private var showsLayoutErrorDetails = false
    @State private var showsErrorDetails = false
    @State private var showsTransitionDetails = false
    @State private var isRetryingPublishedKeyboards = false
    public init(
        session: KeyboardPadSession, onRestoreBuiltin: (() -> Void)? = nil,
        systemKeyboardSwitch: ((UIView, UIEvent) -> Void)? = nil,
        keyAlternates: ((KeyCap) -> [KeyCap])? = nil,
        layoutRegistry: LayoutRegistry? = nil, selectedLayoutID: String? = nil,
        loadsStoredLayouts: Bool = true, additionalTools: AnyView? = nil,
        statusMessage: String? = nil, onStatusDetails: (() -> Void)? = nil,
        onPanelHeightChange: ((CGFloat) -> Void)? = nil,
        onPresentationBudgetChange: ((KeyboardPanelPresentationBudget) -> Void)? = nil,
        initialPresentation: KeyboardInitialPresentation? = nil,
        onAppearanceChange: ((KeyboardAppearance) -> Void)? = nil,
        systemTraitKnown: Bool = false,
        hostBindingTick: Int = 0,
        layoutSourceSettled: Bool? = nil,
        presentedHeight: CGFloat? = nil,
        presentationBudget: KeyboardPanelPresentationBudget? = nil,
        openHostApp: ((URL, @escaping @MainActor (Bool) -> Void) -> Void)? = nil,
        dismissKeyboard: (() -> Void)? = nil
    ) {
        self.session = session
        self.onRestoreBuiltin = onRestoreBuiltin
        self.systemKeyboardSwitch = systemKeyboardSwitch
        self.keyAlternates = keyAlternates
        self.layoutRegistry = layoutRegistry
        self.selectedLayoutID = selectedLayoutID
        self.loadsStoredLayouts = loadsStoredLayouts
        self.additionalTools = additionalTools
        self.statusMessage = statusMessage
        self.onStatusDetails = onStatusDetails
        self.openHostApp = openHostApp
        self.dismissKeyboard = dismissKeyboard
        self.onAppearanceChange = onAppearanceChange
        self.systemTraitKnown = systemTraitKnown
        self.hostBindingTick = hostBindingTick
        self.onPanelHeightChange = onPanelHeightChange
        self.onPresentationBudgetChange = onPresentationBudgetChange
        self.layoutSourceSettled = layoutSourceSettled
        self.presentedHeight = presentedHeight
        self.presentationBudget = presentationBudget
        if let initialPresentation {
            _appearanceSnapshot = State(initialValue: initialPresentation.appearance)
            _hasValidAppearance = State(initialValue: initialPresentation.hasValidAppearance)
            _readingRowGranted = State(initialValue: initialPresentation.readingRowReserved)
            _candidateAreaGranted = State(initialValue: initialPresentation.candidateAreaReserved)
            _definitionShell = State(initialValue: initialPresentation.presentationShell)
            _drawnMainRows = State(initialValue: initialPresentation.physicalMainRows)
            _initialGeometryBudget = State(
                initialValue: (
                    initialPresentation.candidateHeight,
                    initialPresentation.candidateSize
                ))
        }
    }

    public var body: some View {
        phaseSurface
            // Every scroller in the keyboard (built-in or DIY layout, tools, symbols,
            // error details) inherits this: iOS 26's soft edge blur never applies.
            .sharpCandidateScrollEdges()
            // The Host owns the external budget in every phase. A physical-layout
            // capability change must reach UIInputView even if the ready subtree
            // is replaced in the same SwiftUI update.
            .onAppear {
                KeyboardKeyFeelPreferences.refresh()
                CandidateTextSizePreferences.refresh()
                storedCandidateTextSize = CandidateTextSizePreferences.current
                CollapsedCandidateCommentPreferences.refresh()
                storedCollapsedCandidateComments = CollapsedCandidateCommentPreferences.current
                KeyGapScalingPreferences.refresh()
                storedScalesKeyGaps = KeyGapScalingPreferences.current
                storedHeightPreset = KeyboardHeightPreferences.current
                if presentationBudget == nil {
                    readingPlacement = KeyboardReadingPlacementPreferences.current
                }
                onPanelHeightChange?(fixedShellHeight)
                adoptBudgetedShell()
                reportPresentationBudget()
            }
            .onChange(of: fixedShellHeight) { _, height in onPanelHeightChange?(height) }
            .onChange(of: session.phase) {
                showsErrorDetails = false
            }
            .onChange(of: session.publishedKeyboardError) {
                if session.publishedKeyboardError == nil,
                    session.transitionError == nil, session.controller?.inputError == nil
                {
                    showsTransitionDetails = false
                }
            }
            .onAppear { onAppearanceChange?(appearance) }
            .onChange(of: appearanceSnapshot) { onAppearanceChange?(appearance) }
            .onChange(of: colorScheme) { onAppearanceChange?(appearance) }
            .onAppear(perform: reloadStoredLayouts)
            .onAppear(perform: reloadAppearance)
            .onAppear(perform: reloadShuangpinHints)
            // On leaving, invalidate in-flight read tasks so a late old read cannot overwrite the next appearance's snapshot.
            .onDisappear {
                layoutReadGate.invalidate()
                appearanceReadGate.invalidate()
                shuangpinHintReadGate.invalidate()
            }
            // Appearance has a single change channel, so skin and candidate area always come from one re-read.
            .onReceive(NotificationCenter.default.publisher(for: .keyboardAppearanceChanged)) { _ in reloadAppearance()
            }
            // A keyboard extension has no app lifecycle: `UIApplication.didBecomeActiveNotification` never fires
            // in an extension. The extension controller therefore increments the counter explicitly each time it
            // gets a new host (`viewWillAppear`, including unlock / return from another app); the host typing
            // area does not inject it (`nil`) and keeps reading on onAppear.
            // A new host binding is a new presentation: re-read shared preferences.
            .onChange(of: hostBindingTick) {
                adoptBudgetedShell()
                // The panel only reports when its report changes. A board whose rows the saved
                // selection cannot name (one picked by the input method) would otherwise keep the
                // budget's row count and lose its control row below the shell.
                applyReadingRowReport()
                KeyboardKeyFeelPreferences.refresh()
                CandidateTextSizePreferences.refresh()
                storedCandidateTextSize = CandidateTextSizePreferences.current
                CollapsedCandidateCommentPreferences.refresh()
                storedCollapsedCandidateComments = CollapsedCandidateCommentPreferences.current
                KeyGapScalingPreferences.refresh()
                storedScalesKeyGaps = KeyGapScalingPreferences.current
                oneHandMode = KeyboardOneHandPreferences.current
                oneHandWidthPercent = KeyboardOneHandPreferences.widthPercent
                if oneHandMode != .off { lastOneHandSide = oneHandMode }
                storedHeightPreset = KeyboardHeightPreferences.current
                readingPlacement = KeyboardReadingPlacementPreferences.current
                reloadStoredLayouts()
                reloadAppearance()
                reloadShuangpinHints()
            }
            .onReceive(NotificationCenter.default.publisher(for: Notification.Name("keyboard.shuangpinHints.changed")))
        { _ in
            reloadShuangpinHints()
        }
            // When the layout source settles / the registry arrives, re-evaluate the latest report (the report itself may be unchanged).
            .onChange(of: resolvedLayoutSourceSettled) { applyReadingRowReport() }
            .onChange(of: registryAvailable) { applyReadingRowReport() }
            .onChange(of: readingPlacement) { applyReadingRowReport() }
            .environment(\.keyboardAppearance, appearance)
            // SwiftUI controls (candidates, bar controls, readings, tools buttons) give the key feedback on press.
            .environment(\.keyboardTouchDownFeedback, { KeyboardFeedbackService.shared.keyTouchDown() })
    }

    /// Every settled phase uses the same fixed outer height. On a cold-start cache miss or right after a
    /// configuration change, a background read may adjust that fixed budget once; candidate state changes never change the height.
    ///  - loading / error / unconfigured: fixed budget (non-zero on the first frame);
    ///  - ready: the same `fixedShellHeight` constrains the content; candidate/status changes only swap the bar's contents.
    @ViewBuilder
    private var phaseSurface: some View {
        if showsLayoutErrorDetails, let message = appearanceReadError ?? layoutReadError {
            loadingSurface { errorDetails(message, layoutError: true) }
        } else if showsErrorDetails, case .failed(let message) = session.phase {
            loadingSurface { errorDetails(message, layoutError: false) }
        } else {
            switch session.phase {
            case .starting:
                if let layout = startingLayout {
                    startingKeys(layout)
                } else {
                    loadingSurface { startingSurface }
                }
            case .failed:
                loadingSurface { failureSurface }
            case .ready:
                if let controller = session.controller {
                    readySurface(controller)
                } else {
                    // Theoretically unreachable (`.ready` always has a controller); still use the same fixed budget to avoid a zero-height panel.
                    Color.clear.keyboardPanelHeight(layoutShellHeight)
                }
            }
        }
    }

    /// loading / error / unconfigured share the same fixed budget; the system keyboard's key row counts inside it.
    private func loadingSurface<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        VStack(spacing: 4) {
            content()
            if let systemKeyboardSwitch {
                systemKeyboardRow(systemKeyboardSwitch)
            }
        }
        .keyboardPanelHeight(layoutShellHeight)
    }

    private func systemKeyboardRow(_ handleEvent: @escaping (UIView, UIEvent) -> Void) -> some View {
        HStack {
            NativeInputModeKey(
                handleEvent: handleEvent,
                accessibilitySwitch: { session.host?.switchKeyboard() }
            )
            .frame(width: 44, height: 44)
            Spacer()
        }
        .padding(.horizontal, 4)
    }

    private var retryTitle: String {
        if session.controller?.session.inputUnavailableReason != nil {
            return String(localized: "放弃组合并重试")
        }
        return String(localized: "重试")
    }

    private var restoreBuiltinTitle: String {
        if onRestoreBuiltin == nil { return String(localized: "恢复已配置方案") }
        return String(localized: "临时使用\(ProductionInputAvailability.fallbackInputMethodName)")
    }

    /// Real startup failure: explicit message plus retry.
    private var failureSurface: some View {
        VStack(spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
            Text("键盘暂时无法使用").font(.headline)
            Text(
                session.controller?.session.inputUnavailableReason != nil
                    ? String(localized: "当前输入状态无法确认。重试将放弃尚未上屏的输入，已上屏文字保留。")
                    : String(localized: "请重试后继续输入。")
            )
            .font(.footnote)
            .foregroundStyle(.secondary)
            HStack {
                Button(retryTitle) {
                    session.retry()
                }
                .buttonStyle(.borderedProminent)
                if session.resourceSet != nil {
                    Button(restoreBuiltinTitle) {
                        if let onRestoreBuiltin { onRestoreBuiltin() } else { session.restoreConfiguredRoute() }
                    }
                    .buttonStyle(.bordered)
                }
            }
            .frame(minHeight: 44)
            Button(String(localized: "错误详情")) { showsErrorDetails = true }
                .frame(minHeight: 44)
        }
        .padding()
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// Ready phase: the sole height owner is the **host itself** (`fixedShellHeight`, the same value as
    /// loading/error). Neither host nor panel reads back child heights, so there is no child-parent-child readback lag.
    private func readySurface(_ controller: KeyboardController) -> some View {
        // Plan from the laid-out panel size, not the screen: embedded trial areas are narrower.
        GeometryReader { proxy in
            self.readyContent(controller, panelSize: proxy.size)
                .onChange(of: proxy.size) { _, _ in
                    // A resize moves keys away from any point retained by an active touch.
                    KeyboardRoutedTouch.clear()
                }
        }
    }

    private func readyContent(_ controller: KeyboardController, panelSize: CGSize) -> some View {
        let oneHandAvailable = allowsOneHand(panelWidth: panelSize.width)
        let plan = KeyboardOneHandLayoutPolicy.plan(
            mode: oneHandMode,
            panelWidth: Double(panelSize.width),
            isAvailable: oneHandAvailable,
            widthPercent: oneHandWidthPercent)
        return FixedPhaseHeight(height: layoutShellHeight) {
            KeyboardPanelView(
                controller: controller, onSelectLayout: session.selectLayout,
                onSelectLayoutBound: { layout, schemaID in
                    session.selectLayout(layout, boundSchemaID: schemaID)
                },
                systemKeyboardSwitch: systemKeyboardSwitch, keyAlternates: keyAlternates,
                layoutRegistry: layoutRegistry ?? storedRegistry,
                selectedLayoutID: selectedLayoutID ?? storedLayoutID,
                allowsCursorMovement: session.host != nil,
                statusMessage: resolvedStatusMessage(controller),
                onStatusDetails: {
                    if session.transitionError != nil || controller.inputError != nil {
                        showsTransitionDetails.toggle()
                    } else if session.publishedKeyboardError != nil {
                        showsTransitionDetails.toggle()
                    } else if appearanceReadError != nil {
                        showsLayoutErrorDetails = true
                    } else if let onStatusDetails {
                        onStatusDetails()
                    } else {
                        showsLayoutErrorDetails = true
                    }
                },
                additionalTools: AnyView(
                    Group {
                        KeyboardToolsSection(title: String(localized: "输入")) {
                            InlineCompositionToggle(session: session)
                            if oneHandAvailable {
                                KeyboardToolsSeparator()
                                OneHandModeRow(mode: oneHandMode) { setOneHandMode($0) }
                            }
                        }
                        KeyboardOptionsView(controller: controller)
                        if let additionalTools { additionalTools }
                    }),
                insertTools: AnyView(QuickInsertView(state: session.quickInsert)),
                openHostApp: openHostApp,
                dismissKeyboard: dismissKeyboard,
                candidateBar: appearanceSnapshot.document.candidateBar,
                hostBindingTick: hostBindingTick,
                shuangpinHints: shuangpinHints, shuangpinHintRevision: shuangpinHintRevision,
                readingRowReserved: readingRowGranted,
                readingPlacement: readingPlacement,
                candidateAreaReserved: candidateAreaGranted,
                keyHeight: CGFloat(layoutFit.keyHeight),
                candidateBandHeight: CGFloat(layoutFit.headerHeight),
                topSlack: CGFloat(layoutFit.topSlack),
                readingRowBandHeight: CGFloat(layoutFit.readingRowHeight),
                topTrim: CGFloat(layoutFit.topTrim),
                onReadingRowReport: { report in
                    latestReadingRowReport = report
                    applyReadingRowReport()
                },
                oneHand: oneHandAvailable
                    ? OneHandToolbarControl(mode: oneHandMode) {
                        setOneHandMode(oneHandMode == .off ? lastOneHandSide : .off)
                    } : nil
            )
            // Host-trait changes (field focus / forced light/dark field) may not
            // publish `objectWillChange`, so bump a tick to force a repaint of the
            // host's resolved appearance even though the fixed height never changes.
            .onReceive(controller.hostTraitsChanged) { _ in hostTraitsTick &+= 1 }
            // Status-details overlay: only when explicitly opened (showsTransitionDetails) and there is a
            // displayable error; it never silently covers candidates.
            .overlay(alignment: .top) { transitionDetailsOverlay(controller) }
        }
        // A real width change (not a scale transform), so key frames and candidate
        // wrapping observe the reduced width.
        .frame(width: plan.active ? CGFloat(plan.contentWidth) : nil, alignment: .top)
        .frame(maxWidth: .infinity, alignment: plan.gutterOnLeft ? .trailing : .leading)
        .overlay(alignment: plan.gutterOnLeft ? .leading : .trailing) {
            if plan.active {
                OneHandGutterRepresentable(
                    swap: { setOneHandMode(oneHandMode == .left ? .right : .left) },
                    restore: { setOneHandMode(.off) }
                )
                .frame(width: CGFloat(plan.gutterWidth), height: layoutShellHeight)
                .contentShape(Rectangle())
            }
        }
    }

    /// Status-details overlay: uses an opaque panel background (no material/blur) and is confined to a
    /// small area above the keyboard's top bar so it does not swallow candidate taps.
    @ViewBuilder
    private func transitionDetailsOverlay(_ controller: KeyboardController) -> some View {
        if showsTransitionDetails,
            let message = session.transitionError ?? controller.inputError ?? session.publishedKeyboardError
        {
            HStack(alignment: .top, spacing: 12) {
                Text(message).font(.footnote)
                    .foregroundStyle(Color(uiColor: appearance.text(on: "panel")))
                if session.transitionError == nil && controller.inputError == nil
                    && session.publishedKeyboardError != nil
                {
                    Button {
                        isRetryingPublishedKeyboards = true
                        Task {
                            await session.refreshPublishedKeyboards()
                            isRetryingPublishedKeyboards = false
                            if session.publishedKeyboardError == nil { showsTransitionDetails = false }
                        }
                    } label: {
                        Image(systemName: "arrow.clockwise")
                            .frame(width: 44, height: 44)
                    }
                    .accessibilityLabel(String(localized: "重新读取我的键盘"))
                    .disabled(isRetryingPublishedKeyboards)
                }
                Button {
                    session.dismissTransitionError()
                    showsTransitionDetails = false
                } label: {
                    Image(systemName: "xmark")
                        .frame(width: 44, height: 44)
                }
                .accessibilityLabel(String(localized: "关闭提示"))
            }
            .padding(8)
            .background(
                RoundedRectangle(cornerRadius: 10)
                    .fill(appearance.color("panel"))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 10)
                    .strokeBorder(appearance.color("border"), lineWidth: 1)
            )
            .padding(4)
            .accessibilityElement(children: .contain)
            .accessibilityAddTraits(.isModal)
        }
    }

    /// The one status text shared by host and panel: the host also produces status (layout/appearance
    /// read failures, unfinished operations) and the panel's top bar shows the same string, or the two would diverge.
    /// Under the fixed budget it does not affect panel height, only the bar's contents.
    private func resolvedStatusMessage(_ controller: KeyboardController) -> String? {
        let operationFailed = session.transitionError != nil || controller.inputError != nil
        return (operationFailed ? String(localized: "操作未完成") : nil)
            ?? (session.publishedKeyboardError == nil ? nil : String(localized: "我的键盘读取失败 · 可重试"))
            ?? statusMessage
            ?? (appearanceReadError == nil ? nil : String(localized: "外观读取失败 · 暂用有效外观"))
            ?? (layoutReadError == nil ? nil : String(localized: "布局读取失败 · 暂用内置"))
    }

    /// Engine-boot surface.
    ///
    /// Every starting frame is deliberately neutral: no "first use" explanation is
    /// ever placed in an early surface that iOS may replay on a later keyboard entry.
    /// A slow boot remains observable and accessible through the progress indicator;
    /// only a real `.failed` phase exposes retry and error details, so an in-flight
    /// boot is never interrupted by a misleading retry action.
    /// The layout the keyboard last drew, once the stored layouts are read; nil before the first
    /// ready keyboard, when the starting panel shows instead.
    private var startingLayout: LayoutDefinition? {
        // The user's skin first: keys in the default look would change colour when it arrives.
        guard hasValidAppearance,
            let id = UserDefaults.standard.string(forKey: KeyboardStartingKeys.lastLayoutKey)
        else { return nil }
        if let stored = (layoutRegistry ?? storedRegistry)?.resolvedLayout(id: id) { return stored }
        guard resolvedLayoutSourceSettled else { return nil }
        return BuiltinLayouts.all.first { $0.id == id }
    }

    /// While the engine starts the keyboard already shows its keys; what is typed is decoded, in
    /// order, as soon as the engine is ready. Keys that need the engine's state (pages, shift,
    /// menus) wait for it.
    private func startingKeys(_ layout: LayoutDefinition) -> some View {
        FixedPhaseHeight(height: layoutShellHeight) {
            KeyboardStartingKeys(
                layout: layout, candidateBar: appearanceSnapshot.document.candidateBar,
                // The rows the keyboard will draw in this shell, so nothing moves when it takes over.
                keyHeight: CGFloat(layoutFit.keyHeight), showsGlobe: systemKeyboardSwitch != nil,
                widthSettings: KeyboardWidthPreferences.read(from: KeyboardWidthPreferences.defaults),
                onKey: { key in
                    switch key.action.type {
                    case .code, .literal, .space, .backspace, .enter:
                        session.bufferStartupKey(key.action.keyAction(usesASCIIPunctuation: false))
                    default:
                        break
                    }
                }
            )
            .frame(maxHeight: .infinity, alignment: .bottom)
        }
    }

    private var startingSurface: some View {
        // A keyboard picked from the menu is usually up within this; its spinner would only flash.
        DelayedProgressView(delay: session.announcesNextKeyboard ? .milliseconds(300) : .zero)
            .accessibilityLabel(String(localized: "键盘正在启动"))
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func errorSurfaceTitle(layoutError: Bool, inputError: Bool) -> String {
        if inputError { return String(localized: "输入操作未完成") }
        if layoutError {
            if appearanceReadError == nil { return String(localized: "无法读取布局 · 暂用内置") }
            return String(localized: "无法读取外观 · 暂用有效外观")
        }
        return String(localized: "键盘未能启动")
    }

    private func errorDetails(_ message: String, layoutError: Bool, inputError: Bool = false) -> some View {
        VStack(spacing: 8) {
            HStack {
                if let systemKeyboardSwitch {
                    NativeInputModeKey(
                        handleEvent: systemKeyboardSwitch,
                        accessibilitySwitch: { session.host?.switchKeyboard() }
                    )
                    .frame(width: 44, height: 44)
                }
                Button(String(localized: "返回键盘")) {
                    showsLayoutErrorDetails = false
                    showsErrorDetails = false
                    showsTransitionDetails = false
                }
                .frame(minWidth: 72, minHeight: 44)
                Spacer()
                if !inputError {
                    Button(String(localized: "重试")) {
                        if layoutError {
                            reloadStoredLayouts()
                            reloadAppearance()
                        } else {
                            showsErrorDetails = false
                            session.retry()
                        }
                    }
                    .frame(minWidth: 44, minHeight: 44)
                }
            }
            Text(errorSurfaceTitle(layoutError: layoutError, inputError: inputError)).font(.headline)
            ScrollView {
                Text(message)
                    .font(.callout)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            }
        }
        .padding(.horizontal, 8)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// Adopts the panel's eligibility report (only when the layout source has settled and the report matches the current source).
    /// After adopting, records the cold-start hint so the next `loadView` first frame is sized with the same granted value.
    private func applyReadingRowReport() {
        guard let report = latestReadingRowReport,
            CandidateReadingRowGrant.accepts(
                report, layoutSourceSettled: resolvedLayoutSourceSettled,
                registryAvailable: registryAvailable)
        else { return }
        let reservesRow = report.eligible && readingPlacement == .row
        if readingRowGranted != reservesRow { readingRowGranted = reservesRow }
        if candidateAreaGranted != report.candidateAreaRequired {
            candidateAreaGranted = report.candidateAreaRequired
        }
        // The physical row count belongs to the definition; the drawn count changes per page and
        // only re-fits the current page inside the unchanged shell.
        var physicalRowsChanged = false
        if definitionShell.mainRows != report.physicalMainRowCount {
            definitionShell.mainRows = report.physicalMainRowCount
            physicalRowsChanged = true
        }
        if drawnMainRows != report.drawnMainRowCount { drawnMainRows = report.drawnMainRowCount }
        // Only the Chinese letters page describes the definition; ABC/123 grants are
        // page state and must not become the next cold start's hint.
        if !report.pageOverride {
            let shell = KeyboardPresentationShell(
                readingRow: reservesRow,
                candidateArea: report.candidateAreaRequired,
                mainRows: definitionShell.mainRows)
            if definitionShell != shell { definitionShell = shell }
            KeyboardInitialPresentation.recordReadingRow(
                eligible: report.eligible,
                candidateAreaRequired: report.candidateAreaRequired,
                layout: session.layout)
            KeyboardInitialPresentation.recordPhysicalMainRows(definitionShell.mainRows, layout: session.layout)
            reportPresentationBudget()
        } else if physicalRowsChanged {
            reportPresentationBudget()
        }
        KeyboardLifecycleDiagnostics.emit(
            "readingRowGrant",
            [
                "layout": session.layout.rawValue,
                "eligible": report.eligible ? "1" : "0",
                "granted": readingRowGranted ? "1" : "0",
                "candidateArea": candidateAreaGranted ? "1" : "0",
                "physicalRows": "\(definitionShell.mainRows)",
                "drawnRows": "\(drawnMainRows)",
                "registry": report.resolvedFromRegistry ? "1" : "0",
                "configured": String(format: "%.1f", candidateHeight),
                "effective": String(
                    format: "%.1f",
                    CandidateBarDefinition.Collapsed.effectiveHeight(
                        candidateHeight, candidateSize: candidateSize)),
                "shell": String(format: "%.1f", Double(fixedShellHeight)),
            ])
    }

    /// A new presentation starts from the shell the extension budgeted for the current selection;
    /// reporting the previous presentation's shell would grow and then shrink the keyboard.
    private func adoptBudgetedShell() {
        guard let presentationBudget else { return }
        let shell = KeyboardPresentationShell(
            readingRow: presentationBudget.readingRow, candidateArea: presentationBudget.candidateArea,
            mainRows: presentationBudget.physicalMainRows)
        if definitionShell != shell { definitionShell = shell }
        if drawnMainRows != presentationBudget.physicalMainRows {
            drawnMainRows = presentationBudget.physicalMainRows
        }
    }

    private func reportPresentationBudget() {
        guard let onPresentationBudgetChange else { return }
        // Until the appearance read succeeds, keep the accepted first-frame geometry seed.
        let height = hasValidAppearance ? candidateHeight : (presentationBudget?.candidateHeight ?? candidateHeight)
        let size = hasValidAppearance ? candidateSize : (presentationBudget?.candidateSize ?? candidateSize)
        onPresentationBudgetChange(
            KeyboardPanelPresentationBudget(
                candidateHeight: height, candidateSize: size,
                readingRow: definitionShell.readingRow, candidateArea: definitionShell.candidateArea,
                compact: compactReadingRow, heightPreset: storedHeightPreset,
                physicalMainRows: definitionShell.mainRows))
    }

    private func reloadShuangpinHints() {
        let token = shuangpinHintReadGate.begin()
        // Keep the current hints while reading; clearing first would flash the keys.
        Task { @MainActor in
            let snapshot: ShuangpinHintSnapshot?
            do {
                snapshot = try await KeyboardResourceReadQueue.async { () throws -> ShuangpinHintSnapshot? in
                    guard let root = KeyboardRecipeStore.sharedContainerURL() else { return nil }
                    return try ShuangpinHintStore(
                        directory: root.appendingPathComponent(ShuangpinHintStore.directoryName, isDirectory: true)
                    ).load()
                }
            } catch {
                snapshot = nil
            }
            guard shuangpinHintReadGate.accepts(token), snapshot != shuangpinHints else { return }
            shuangpinHintRevision &+= 1
            shuangpinHints = snapshot
        }
    }

    private func reloadStoredLayouts() {
        guard loadsStoredLayouts, layoutRegistry == nil else { return }
        storedLayoutID = UserDefaults.standard.string(forKey: "keyboard.selectedLayoutDefinitionID")
        // Reading `layouts.json` is an independent file read: run it on the dedicated read queue (not serialized
        // with the engine-ownership queue). Latest-wins: a late old read must not overwrite a newer result.
        let token = layoutReadGate.begin()
        Task { @MainActor in
            let result = await KeyboardLifecycleDiagnostics.measureAsync("layoutRead") {
                do {
                    return try await KeyboardResourceReadQueue.async { () -> Result<LayoutRegistry, Error> in
                        Result { try LayoutStore(directoryURL: RimePaths.layoutStoreReadLocation().url).load() }
                    }
                } catch {
                    return .failure(error)
                }
            }
            guard layoutReadGate.accepts(token) else { return }
            switch result {
            case .success(let registry):
                storedRegistry = registry
                layoutReadError = nil
                showsLayoutErrorDetails = false
            case .failure(let error):
                storedRegistry = nil
                layoutReadError = error.localizedDescription
            }
        }
    }

    /// The single read path for appearance (skin + candidate-area layout + display mode).
    ///
    /// One read yields one snapshot with a consistent identity: skin and candidate bar come from the same
    /// commit, so there is no "skin read ok, candidate area read failed" state.
    /// On corruption it prefers the in-process valid value, then the built-in default, and keeps an
    /// explicit error; it never writes a damaged file.
    ///
    /// The read is an independent file read: it runs on the dedicated read queue and the main thread only
    /// applies the result (`AppearanceStore.read()` never throws; the result carries snapshot and error).
    /// The latest-wins generation keeps an old read from overwriting a newer atomic snapshot when the window re-lays out.
    private func reloadAppearance() {
        let token = appearanceReadGate.begin()
        Task { @MainActor in
            let read = await KeyboardLifecycleDiagnostics.measureAsync("appearanceRead") {
                do {
                    return try await KeyboardResourceReadQueue.async { () -> AppearanceReadResult? in
                        RimePaths.sharedAppearanceReadStore()?.read()
                    }
                } catch {
                    return nil
                }
            }
            guard appearanceReadGate.accepts(token) else { return }
            defer { reportPresentationBudget() }
            guard let read else {
                if !hasValidAppearance {
                    appearanceSnapshot = AppearanceSnapshot()
                    initialGeometryBudget = nil
                }
                return
            }
            KeyboardLifecycleDiagnostics.emit(
                "appearanceResolved",
                [
                    "source": String(describing: read.source),
                    "error": read.error == nil ? "0" : "1",
                    "configured": String(format: "%.1f", read.snapshot.document.candidateBar.collapsed.height),
                    "candidateSize": String(format: "%.1f", read.snapshot.document.skin.typography.candidateSize),
                    "systemSkin": read.snapshot.document.skin == .systemDefault ? "1" : "0",
                ])
            if read.error == nil {
                appearanceSnapshot = read.snapshot
                initialGeometryBudget = nil
                hasValidAppearance = true
                appearanceReadError = nil
                KeyboardInitialPresentation.recordGeometry(from: read.snapshot)
                return
            }
            if !hasValidAppearance {
                appearanceSnapshot = read.snapshot
                initialGeometryBudget = nil
            }
            appearanceReadError = read.error
        }
    }
}

/// Fixed-height shell for the ready phase.
///
/// The old implementation stored the height reported by the child in host `@State` and then used it to
/// constrain the child (child-parent-child readback): the `@State` initial 0 made the first frame
/// `.frame(height: 0)`, and every candidate/status change laid out with the **previous** frame's height
/// (clipping the bottom control row when taller, leaving a header-height blank band when shorter).
///
/// The host computes the height **once** (`KeyboardPanelGeometry.fixedPanelHeight`) and passes it
/// as a value, shared with the loading/error phases and the panel content. Candidate state only updates
/// the bar's contents, so UIKit's shell and SwiftUI never negotiate a new height in the same frame
/// and the candidate bar is never drawn into the first key row.
/// Neither host nor panel reads back child heights: the shell height belongs only to the typed `UIInputView` / host.
private struct FixedPhaseHeight<Content: View>: View {
    let height: CGFloat
    @ViewBuilder var content: () -> Content

    var body: some View {
        content()
            // Same budget entry as the loading/error phases (content top-aligned).
            .keyboardPanelHeight(height)
    }
}

/// Instant toggle for inline composition (in the keyboard tools and the host settings, same source):
/// reads and writes the same `KeyboardCompositionPreferences.enabledKey` (App Group defaults); after a
/// toggle it only calls `session.refreshCompositionPresentation()`, with no commit and no engine key.
/// The default comes from `KeyboardCompositionPreferences`.
struct InlineCompositionToggle: View {
    @ObservedObject private var session: KeyboardPadSession
    @State private var enabled = KeyboardCompositionPreferences.inlineEnabled

    init(session: KeyboardPadSession) {
        self.session = session
    }

    var body: some View {
        KeyboardToolsRow(
            icon: "character.cursor.ibeam",
            title: String(localized: "在输入框中显示拼写"),
            mark: .toggle(enabled),
            accessibilityLabel: String(localized: "在输入框中显示拼写"),
            accessibilityValue: enabled ? String(localized: "开启") : String(localized: "关闭"),
            accessibilityHint: String(localized: "开启后，正在输入的字母显示在输入框内")
        ) {
            enabled.toggle()
            KeyboardCompositionPreferences.inlineEnabled = enabled
            session.refreshCompositionPresentation()
        }
    }
}

/// One-handed mode in the keyboard's own settings, so it can be switched where it is used; the
/// choice applies at once and is the same preference the app's input options edit.
struct OneHandModeRow: View {
    @Environment(\.keyboardAppearance) private var appearance
    let mode: KeyboardOneHandMode
    let onSelect: (KeyboardOneHandMode) -> Void

    private static let choices: [(KeyboardOneHandMode, String)] = [
        (.off, String(localized: "关闭")), (.left, String(localized: "左手")), (.right, String(localized: "右手")),
    ]

    var body: some View {
        HStack(spacing: KeyboardToolsStyle.iconTitleSpacing) {
            Image(systemName: "hand.raised")
                .font(.system(size: 16, weight: .medium))
                .foregroundStyle(Color(uiColor: appearance.text(on: "key", secondary: true)))
                .frame(width: KeyboardToolsStyle.iconColumnWidth)
                .accessibilityHidden(true)
            Text("单手模式")
                .font(.body)
                .foregroundStyle(Color(uiColor: appearance.text(on: "key")))
                .lineLimit(1)
                .minimumScaleFactor(0.8)
            Spacer(minLength: 8)
            HStack(spacing: 6) {
                ForEach(Self.choices, id: \.0) { choice, title in
                    Button {
                        onSelect(choice)
                    } label: {
                        Text(title)
                            .font(.subheadline.weight(mode == choice ? .semibold : .regular))
                            .lineLimit(1)
                            // Two characters always fit: never let the row squeeze them to "…".
                            .fixedSize()
                            .padding(.horizontal, 12)
                            .frame(minWidth: 44, minHeight: KeyboardToolsStyle.rowMinHeight)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(KeyboardToolsKeyButtonStyle(role: mode == choice ? "accent" : "control"))
                    .accessibilityLabel(String(localized: "单手模式：\(title)"))
                    .accessibilityAddTraits(mode == choice ? .isSelected : [])
                }
            }
        }
        .padding(.horizontal, KeyboardToolsStyle.contentHorizontalInset)
        .frame(maxWidth: .infinity, minHeight: KeyboardToolsStyle.rowMinHeight, alignment: .leading)
    }
}

/// SwiftUI bridge for the gutter controls, framed to the whole gutter.
private struct OneHandGutterRepresentable: UIViewRepresentable {
    let swap: () -> Void
    let restore: () -> Void
    @Environment(\.keyboardAppearance) private var appearance

    func makeUIView(context: Context) -> OneHandGutterControl {
        let control = OneHandGutterControl(swap: swap, restore: restore)
        control.affordanceTint = appearance.text(on: "panel", secondary: true)
        return control
    }

    func updateUIView(_ uiView: OneHandGutterControl, context: Context) {
        uiView.swap = swap
        uiView.restore = restore
        uiView.affordanceTint = appearance.text(on: "panel", secondary: true)
    }
}

/// Fills the blank gutter of one-handed mode, with the two controls of the Android keyboard at
/// its bottom: move the keys to the other side, and restore the full width. The rest of the
/// gutter swallows touches. Being one UIControl keeps the whole gutter out of
/// `FeedbackInputView`'s nearest-key gap routing (which returns this control itself, so the
/// touch picks its button here), and it reports its window frame so the gutter never types.
final class OneHandGutterControl: UIControl {
    var swap: () -> Void
    var restore: () -> Void
    var affordanceTint: UIColor = .secondaryLabel {
        didSet { buttons.forEach { $0.tintColor = affordanceTint } }
    }
    private let swapButton: GutterButton
    private let restoreButton: GutterButton
    private var buttons: [GutterButton] { [swapButton, restoreButton] }
    static let buttonHeight: CGFloat = 48

    init(swap: @escaping () -> Void, restore: @escaping () -> Void) {
        self.swap = swap
        self.restore = restore
        swapButton = GutterButton(
            symbol: "arrow.left.arrow.right", label: String(localized: "键盘换到另一侧"),
            identifier: "keyboard.oneHand.swap")
        restoreButton = GutterButton(
            symbol: "arrow.left.and.right", label: String(localized: "恢复全宽键盘"),
            identifier: "keyboard.oneHand.restore")
        super.init(frame: .zero)
        // Near-transparent so the control still receives touches.
        backgroundColor = UIColor(white: 0, alpha: 0.01)
        isAccessibilityElement = false
        swapButton.onActivate = { [weak self] in self?.perform(.swap) }
        restoreButton.onActivate = { [weak self] in self?.perform(.restore) }
        buttons.forEach(addSubview)
        accessibilityElements = buttons
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    private enum Action { case swap, restore }

    /// A degenerate layout pass must not claim coverage it cannot deliver.
    private var coversGutter: Bool {
        window != nil && !isHidden && bounds.width >= 44 && bounds.height >= 2 * Self.buttonHeight
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        updateRoutingRegion()
    }

    override var isHidden: Bool {
        didSet { updateRoutingRegion() }
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let height = Self.buttonHeight
        restoreButton.frame = CGRect(x: 0, y: bounds.maxY - height, width: bounds.width, height: height)
        swapButton.frame = CGRect(x: 0, y: bounds.maxY - 2 * height, width: bounds.width, height: height)
        updateRoutingRegion()
    }

    private func updateRoutingRegion() {
        let frame = coversGutter ? window.map { convert(bounds, to: $0) } : nil
        KeyboardRoutedTouch.registerOneHandGutter(self, frame: frame)
    }

    private func perform(_ action: Action) {
        guard isEnabled else { return }
        switch action {
        case .swap: swap()
        case .restore: restore()
        }
        KeyboardFeedbackService.shared.selectionChanged()
    }

    /// Acts on touch-down, as the whole-gutter restore did; a touch outside both buttons does nothing.
    override func beginTracking(_ touch: UITouch, with event: UIEvent?) -> Bool {
        let point = touch.location(in: self)
        if swapButton.frame.contains(point) {
            perform(.swap)
        } else if restoreButton.frame.contains(point) {
            perform(.restore)
        }
        return false
    }
}

/// One gutter button: an inert glyph for touches (the gutter control resolves them) and a real
/// button for VoiceOver.
private final class GutterButton: UIView {
    var onActivate: () -> Void = {}
    private let glyph: UIImageView

    init(symbol: String, label: String, identifier: String) {
        glyph = UIImageView(image: UIImage(systemName: symbol))
        super.init(frame: .zero)
        isUserInteractionEnabled = false
        isAccessibilityElement = true
        accessibilityLabel = label
        accessibilityTraits = .button
        accessibilityIdentifier = identifier
        glyph.translatesAutoresizingMaskIntoConstraints = false
        addSubview(glyph)
        NSLayoutConstraint.activate([
            glyph.centerXAnchor.constraint(equalTo: centerXAnchor),
            glyph.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override var tintColor: UIColor! {
        didSet { glyph.tintColor = tintColor }
    }

    override func accessibilityActivate() -> Bool {
        onActivate()
        return true
    }

    // The glyph ignores touches, but VoiceOver still needs the button's own frame.
    override var accessibilityFrame: CGRect {
        get { UIAccessibility.convertToScreenCoordinates(bounds, in: self) }
        set {}
    }
}

/// A progress indicator that shows only once [delay] has passed.
private struct DelayedProgressView: View {
    let delay: Duration
    @State private var shown = false

    var body: some View {
        ProgressView()
            .opacity(shown || delay == .zero ? 1 : 0)
            .task {
                guard delay != .zero else { return }
                try? await Task.sleep(for: delay)
                shown = true
            }
    }
}
