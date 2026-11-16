import AppearanceKit
import CandidateKit
import KeyboardCore
import LayoutKit
import SkinKit
import SwiftUI
import os

public enum KeyboardIdleToolbarPreferences {
    public static let key = "keyboard.idleToolbarEnabled.v1"
    public static let defaultEnabled = true
    public static var defaults: UserDefaults { KeyboardRecipeStore.sharedDefaults() ?? .standard }

    public static func read(from defaults: UserDefaults) -> Bool {
        defaults.object(forKey: key) as? Bool ?? defaultEnabled
    }
}

/// Read on presentation and explicit configuration events, never per key.
public enum KeyboardHeightPreferences {
    public static let presetKey = "keyboard.heightPreset.v1"
    public static var defaults: UserDefaults { KeyboardRecipeStore.sharedDefaults() ?? .standard }
    public static var current: KeyboardHeightPreset {
        KeyboardHeightPreset.resolve(defaults.string(forKey: presetKey))
    }
}

/// The candidate text scale. The keyboard reads the in-process copy while it draws and re-reads the
/// stored id at presentation (`refresh`), never per key; a write from this process updates the copy.
public enum CandidateTextSizePreferences {
    public static let key = "keyboard.candidateTextSize.v1"
    public static var defaults: UserDefaults { KeyboardRecipeStore.sharedDefaults() ?? .standard }

    private static let cache = OSAllocatedUnfairLock<CandidateTextSize?>(uncheckedState: nil)

    private static func load() -> CandidateTextSize {
        CandidateTextSize.resolve(SharedPreferences.object(forKey: key, in: defaults) as? String)
    }

    public static var current: CandidateTextSize {
        get {
            cache.withLockUnchecked { state in
                if let state { return state }
                let loaded = load()
                state = loaded
                return loaded
            }
        }
        set {
            SharedPreferences.set(newValue.rawValue, forKey: key, in: defaults)
            cache.withLockUnchecked { $0 = newValue }
        }
    }

    public static func refresh() {
        let loaded = load()
        cache.withLockUnchecked { $0 = loaded }
    }
}

/// Whether the collapsed candidate row draws engine comments. Cached like the candidate text size:
/// the keyboard reads the in-process copy while it draws and re-reads the stored value at presentation.
public enum CollapsedCandidateCommentPreferences {
    public static let key = "keyboard.collapsedCandidateComments.v1"
    public static var defaults: UserDefaults { KeyboardRecipeStore.sharedDefaults() ?? .standard }

    private static let cache = OSAllocatedUnfairLock<Bool?>(uncheckedState: nil)

    /// A missing or non-Bool value is the default: comments show in the single row.
    public static func read(from defaults: UserDefaults) -> Bool {
        SharedPreferences.object(forKey: key, in: defaults) as? Bool ?? true
    }

    public static var current: Bool {
        get {
            cache.withLockUnchecked { state in
                if let state { return state }
                let loaded = read(from: defaults)
                state = loaded
                return loaded
            }
        }
        set {
            SharedPreferences.set(newValue, forKey: key, in: defaults)
            cache.withLockUnchecked { $0 = newValue }
        }
    }

    public static func refresh() {
        let loaded = read(from: defaults)
        cache.withLockUnchecked { $0 = loaded }
    }
}

/// Whether wide boards (landscape, unfolded or tablet screens) widen the skin's key gaps with their
/// columns (`StandardKeyRowGeometry.keyGapScale`). On by default; cached like the comment switch.
public enum KeyGapScalingPreferences {
    public static let key = "keyboard.keyGapScaling.v1"
    public static var defaults: UserDefaults { KeyboardRecipeStore.sharedDefaults() ?? .standard }

    private static let cache = OSAllocatedUnfairLock<Bool?>(uncheckedState: nil)

    public static func read(from defaults: UserDefaults) -> Bool {
        SharedPreferences.object(forKey: key, in: defaults) as? Bool ?? true
    }

    public static var current: Bool {
        get {
            cache.withLockUnchecked { state in
                if let state { return state }
                let loaded = read(from: defaults)
                state = loaded
                return loaded
            }
        }
        set {
            SharedPreferences.set(newValue, forKey: key, in: defaults)
            cache.withLockUnchecked { $0 = newValue }
        }
    }

    public static func refresh() {
        let loaded = read(from: defaults)
        cache.withLockUnchecked { $0 = loaded }
    }
}

/// Whether the keyboard draws the skin's own background behind the keys. Off until the user turns
/// it on in 键盘外观; read when the appearance is built, like the gap scaling.
public enum SkinBackgroundPreferences {
    public static let key = "keyboard.skinBackground.v1"
    public static var defaults: UserDefaults { KeyboardRecipeStore.sharedDefaults() ?? .standard }

    private static let cache = OSAllocatedUnfairLock<Bool?>(uncheckedState: nil)

    public static func read(from defaults: UserDefaults) -> Bool {
        SharedPreferences.object(forKey: key, in: defaults) as? Bool ?? false
    }

    public static var current: Bool {
        get {
            cache.withLockUnchecked { state in
                if let state { return state }
                let loaded = read(from: defaults)
                state = loaded
                return loaded
            }
        }
        set {
            SharedPreferences.set(newValue, forKey: key, in: defaults)
            cache.withLockUnchecked { $0 = newValue }
        }
    }

    public static func refresh() {
        let loaded = read(from: defaults)
        cache.withLockUnchecked { $0 = loaded }
    }
}

/// Where a keyboard starts splitting, where it starts getting a blank margin beside the key area, and
/// how wide that margin is. Shared by the app
/// and the keyboard extension; the keyboard reads the in-process copy while it draws and re-reads
/// the stored values at presentation (`refresh`), never per key.
public enum KeyboardWidthPreferences {
    public static let splitWidthKey = "keyboard.splitWidth.v1"
    public static let marginWidthKey = "keyboard.marginWidth.v1"
    public static let sideMarginPercentKey = "keyboard.sideMarginPercent.v1"
    public static let middleGapPercentKey = "keyboard.wideMiddleGap.v1"
    public static let splitModeKey = "keyboard.splitMode.v1"
    public static var defaults: UserDefaults { KeyboardRecipeStore.sharedDefaults() ?? .standard }

    private static let cache = OSAllocatedUnfairLock<KeyboardWidthSettings?>(uncheckedState: nil)

    /// The stored choices; a missing or non-numeric value is the default.
    public static func read(from defaults: UserDefaults) -> KeyboardWidthSettings {
        func stored(_ key: String) -> NSNumber? {
            SharedPreferences.object(forKey: key, in: defaults) as? NSNumber
        }
        let splitWidth = stored(splitWidthKey)?.intValue ?? KeyboardWidthSettings.defaultSplitWidth
        // One width once decided both; a margin width never chosen keeps following that choice.
        let settings = KeyboardWidthSettings(
            splitWidth: splitWidth, marginWidth: stored(marginWidthKey)?.intValue ?? splitWidth,
            sideMarginPercent: stored(sideMarginPercentKey)?.doubleValue,
            middleGapPercent: stored(middleGapPercentKey)?.intValue ?? WideMiddleGap.defaultPercent,
            splitMode: KeyboardSplitMode.resolve(
                SharedPreferences.object(forKey: splitModeKey, in: defaults) as? String))
        // Splits read the gap where they are resolved, which is everywhere a keyboard is drawn.
        WideMiddleGap.percent = settings.middleGapPercent
        return settings
    }

    public static var current: KeyboardWidthSettings {
        cache.withLockUnchecked { state in
            if let state { return state }
            let loaded = read(from: defaults)
            state = loaded
            return loaded
        }
    }

    @discardableResult
    public static func refresh() -> KeyboardWidthSettings {
        let loaded = read(from: defaults)
        cache.withLockUnchecked { $0 = loaded }
        return loaded
    }

    public static func set(splitWidth: Int) {
        write(KeyboardWidthSettings.clampedSplitWidth(splitWidth), key: splitWidthKey)
    }

    public static func set(marginWidth: Int) {
        write(KeyboardWidthSettings.clampedSplitWidth(marginWidth), key: marginWidthKey)
    }

    public static func set(splitMode: KeyboardSplitMode) {
        write(splitMode.rawValue, key: splitModeKey)
    }

    public static func set(middleGapPercent: Int) {
        write(WideMiddleGap.clampedPercent(middleGapPercent), key: middleGapPercentKey)
    }

    public static func set(sideMarginPercent: Double) {
        write(KeyboardWidthSettings.clampedSideMarginPercent(sideMarginPercent), key: sideMarginPercentKey)
    }

    /// Back to the default margin, which gives way to a system inset (`effectiveSideMarginPercent`).
    public static func resetSideMargin() {
        SharedPreferences.remove(forKey: sideMarginPercentKey, in: defaults)
        refresh()
        NotificationCenter.default.post(name: .keyboardWidthChanged, object: nil)
    }

    private static func write(_ value: Any, key: String) {
        SharedPreferences.set(value, forKey: key, in: defaults)
        refresh()
        NotificationCenter.default.post(name: .keyboardWidthChanged, object: nil)
    }
}

/// Which idle-toolbar buttons show and in what order. Nothing is stored for the default layout.
/// Read at each presentation like the on/off switch, never per key.
public enum KeyboardIdleToolbarLayoutPreferences {
    public static let key = "keyboard.idleToolbarLayout.v1"
    public static var defaults: UserDefaults { KeyboardRecipeStore.sharedDefaults() ?? .standard }

    public static func read(from defaults: UserDefaults) -> IdleToolbarLayout {
        IdleToolbarLayout.parse(defaults.string(forKey: key))
    }

    public static func write(_ layout: IdleToolbarLayout, to defaults: UserDefaults) {
        if layout.isDefault {
            defaults.removeObject(forKey: key)
        } else {
            defaults.set(layout.toWire(), forKey: key)
        }
    }
}

/// Where the readings of a 14-key / 18-key layout show. Read at each presentation (it decides
/// whether the shell reserves a reading row), never per key.
public enum KeyboardReadingPlacementPreferences {
    public static let key = ReadingPlacementStorage.key
    public static var defaults: UserDefaults { KeyboardRecipeStore.sharedDefaults() ?? .standard }
    public static var current: ReadingPlacement {
        ReadingPlacement.resolve(SharedPreferences.object(forKey: key, in: defaults) as? String)
    }
}

/// One-handed mode, adopted at the next presentation like the height preset; the
/// in-keyboard restore control turns it off in place.
public enum KeyboardOneHandPreferences {
    public static let modeKey = "keyboard.oneHand.v1"
    public static var defaults: UserDefaults { KeyboardRecipeStore.sharedDefaults() ?? .standard }
    public static var current: KeyboardOneHandMode {
        KeyboardOneHandMode.resolve(SharedPreferences.object(forKey: modeKey, in: defaults) as? String)
    }
    public static func set(_ mode: KeyboardOneHandMode) {
        SharedPreferences.set(mode.rawValue, forKey: modeKey, in: defaults)
    }

    /// The narrowed keyboard's width in percent of the full width.
    public static let widthPercentKey = "keyboard.oneHandWidthPercent.v1"
    public static var widthPercent: Int {
        let stored = (SharedPreferences.object(forKey: widthPercentKey, in: defaults) as? NSNumber)?.intValue
        return KeyboardOneHandLayoutPolicy.clampedWidthPercent(
            stored ?? KeyboardOneHandLayoutPolicy.defaultWidthPercent)
    }
}

/// Sliding sideways over the keys moves the cursor while nothing is being typed; off by default.
public enum KeyboardCursorSwipePreferences {
    public static let key = "keyboard.cursorSwipeAnywhere.v1"
    public static var isEnabled: Bool {
        (SharedPreferences.object(forKey: key, in: KeyboardOneHandPreferences.defaults) as? Bool) ?? false
    }
}

/// Key feel shared by the app and the keyboard extension: the global long-press delay and the
/// corner-hint flick of character keys. Keys read the in-process copy on every render, so the stored
/// values are re-read only when a keyboard presentation starts (`refresh`).
public enum KeyboardKeyFeelPreferences {
    public static let longPressDelayKey = "keyboard.longPressDelayMs.v1"
    public static let flickKey = KeyFlick.Setting.storageKey
    public static var defaults: UserDefaults { KeyboardRecipeStore.sharedDefaults() ?? .standard }

    private struct Snapshot {
        var longPressMilliseconds: Int?
        var flick: KeyFlick.Setting
    }

    private static let cache = OSAllocatedUnfairLock<Snapshot?>(uncheckedState: nil)

    private static func load() -> Snapshot {
        Snapshot(
            longPressMilliseconds: LongPressDelaySetting.resolve(
                SharedPreferences.object(forKey: longPressDelayKey, in: defaults)),
            flick: storedFlick)
    }

    /// The stored choice read now, for settings screens that are not on the key hot path.
    public static var storedFlick: KeyFlick.Setting {
        KeyFlick.Setting.resolve(
            stored: SharedPreferences.object(forKey: flickKey, in: defaults),
            legacyEnabled: SharedPreferences.object(forKey: KeyFlick.Setting.legacyEnabledKey, in: defaults))
    }

    private static var snapshot: Snapshot {
        cache.withLockUnchecked { state in
            if let state { return state }
            let loaded = load()
            state = loaded
            return loaded
        }
    }

    public static func refresh() {
        let loaded = load()
        cache.withLockUnchecked { $0 = loaded }
    }

    /// Milliseconds; nil follows each layout's own delay.
    public static var longPressMilliseconds: Int? { snapshot.longPressMilliseconds }
    public static var flick: KeyFlick.Setting { snapshot.flick }

    /// Writing the new value retires the old on/off switch, so a later read never revives it.
    public static func setFlick(_ setting: KeyFlick.Setting) {
        SharedPreferences.set(setting.rawValue, forKey: flickKey, in: defaults)
        if KeyboardRecipeStore.canWriteSharedContainer {
            defaults.removeObject(forKey: KeyFlick.Setting.legacyEnabledKey)
        }
    }

    public static func longPressDelay(layout: Double?) -> TimeInterval {
        LongPressDelaySetting.effectiveDelay(layout: layout, override: longPressMilliseconds)
    }
}

/// The Japanese twelve-key board's "只用 flick" option (default off): when off, repeated taps of the
/// same key cycle that row's kana; when on, only flicks do. Read at each presentation like the key
/// feel options, never per key.
public enum KeyboardKana12Preferences {
    public static let flickOnlyKey = "keyboard.kana12FlickOnly.v1"
    public static let defaultFlickOnly = false
    public static var defaults: UserDefaults { KeyboardRecipeStore.sharedDefaults() ?? .standard }

    public static var flickOnly: Bool {
        (SharedPreferences.object(forKey: flickOnlyKey, in: defaults) as? Bool) ?? defaultFlickOnly
    }
}

/// Where a width-capped wide-screen keyboard sits. One value per physical layout, so a
/// 9-key phone pad can hug the left while a 14-key pad stays centred. Unknown or missing
/// values resolve to centre; the keyboard re-reads them per presentation, never per key.
public enum KeyboardContentDockPreferences {
    private static let keyPrefix = "keyboard.wideContentDock.v1."
    public static var defaults: UserDefaults { KeyboardRecipeStore.sharedDefaults() ?? .standard }

    public static func key(for layout: KeyboardLayoutKind) -> String { keyPrefix + layout.rawValue }

    public static func dock(for layout: KeyboardLayoutKind) -> KeyboardContentDock {
        KeyboardContentDock.resolve(
            SharedPreferences.object(forKey: key(for: layout), in: defaults) as? String)
    }

    public static func set(_ dock: KeyboardContentDock, for layout: KeyboardLayoutKind) {
        SharedPreferences.set(dock.rawValue, forKey: key(for: layout), in: defaults)
        NotificationCenter.default.post(name: .keyboardContentDockChanged, object: layout)
    }
}

/// Where the 9-key keyboard puts its expanded candidates on a screen with room beside it: the
/// left (the default), the right, or nowhere. Re-read per presentation, never per key.
public enum NineKeyCandidateSidePreferences {
    public static let key = "keyboard.nineKeyCandidateSide.v1"
    public static var defaults: UserDefaults { KeyboardRecipeStore.sharedDefaults() ?? .standard }

    public static var current: NineKeyCandidateSide {
        NineKeyCandidateSide.resolve(SharedPreferences.object(forKey: key, in: defaults) as? String)
    }

    public static func set(_ side: NineKeyCandidateSide) {
        SharedPreferences.set(side.rawValue, forKey: key, in: defaults)
        NotificationCenter.default.post(name: .keyboardContentDockChanged, object: nil)
    }
}

extension Notification.Name {
    /// The single appearance-change notification: skin, candidate-area layout and display mode share one
    /// appearance identity, so there is one change channel.
    static let keyboardAppearanceChanged = Notification.Name("keyboard.appearance.changed")

    /// The keyboard panel **lost its rendering host**: sent in-process by the extension host from the
    /// view controller's `viewWillDisappear`. Used to cancel one-shot gestures such as press-and-hold and
    /// to end the Taptic session; it replaces `UIApplication.willResignActiveNotification`, which is not
    /// available to scenes/extensions: a keyboard extension has no app lifecycle, so
    /// `UIApplication.*Notification` never fires there (`didMoveToWindow` remains the fallback).
    ///
    /// Delivered only **in this process**: it is a host lifecycle event, not a cross-process data change.
    /// The host typing area does not send it (its panel is destroyed with the view).
    static let keyboardPanelHostWillDisappear = Notification.Name("keyboard.panelHostWillDisappear")

    /// A wide-screen dock preference changed in the host app while its own panel is visible.
    /// The extension cannot receive this cross-process write; it re-reads on the next presentation.
    static let keyboardContentDockChanged = Notification.Name("keyboard.wideContentDock.changed")

    /// The split width or side margin changed in the host app while its own panel is visible.
    static let keyboardWidthChanged = Notification.Name("keyboard.width.changed")
}

/// The selected definition's facts one presentation's shell height is budgeted for.
/// Fixed for the presentation: a layout switch re-fits inside it, and the next
/// presentation starts at the newly selected definition's height.
public struct KeyboardPresentationShell: Equatable {
    public var readingRow: Bool
    public var candidateArea: Bool
    /// Letter rows the physical definition draws above its control row. The shell spreads the
    /// standard three-row key area over them, so a taller board keeps the same outer height and
    /// every other page re-fits inside it.
    public var mainRows: Int
    public init(
        readingRow: Bool, candidateArea: Bool,
        mainRows: Int = KeyboardPanelGeometry.standardMainRowCount
    ) {
        self.readingRow = readingRow
        self.candidateArea = candidateArea
        self.mainRows = mainRows
    }
}

/// The input view starts with an in-memory default appearance and a cached
/// geometry budget. The complete appearance is resolved by the Host off-main.
public struct KeyboardInitialPresentation {
    public var appearance = AppearanceSnapshot()
    public private(set) var heightPreset: KeyboardHeightPreset = .standard
    public private(set) var hasValidAppearance = false
    /// Whether the cold-start first frame reserves height for the standalone reading row: only reuses the
    /// eligibility hint (`CandidateReadingRowHint`) the host last **adopted** that matches the current layout selection; no hint or mismatch -> false.
    public private(set) var readingRowReserved = false
    public private(set) var candidateAreaReserved = true
    /// Physical letter rows of the saved layout selection. The bundled registration table answers
    /// it synchronously, so the first frame is already budgeted for a four-row board instead of
    /// growing the shell once the layout registry settles.
    public private(set) var physicalMainRows = KeyboardPanelGeometry.standardMainRowCount
    /// Only geometry is cached; a palette or candidate layout must never be
    /// reconstructed from UserDefaults instead of the validated store snapshot.
    public private(set) var candidateHeight = CandidateBarDefinition.systemDefault.collapsed.height
    public private(set) var candidateSize = SkinDefinition.systemDefault.typography.candidateSize
    private static let geometryBudgetKey = "keyboard.appearance.geometryBudget.v1"

    /// Called only after a completed, accepted read on KeyboardResourceReadQueue.
    public static func recordGeometry(from snapshot: AppearanceSnapshot) {
        let height = snapshot.document.candidateBar.collapsed.height
        let size = snapshot.document.skin.typography.candidateSize
        guard (36...56).contains(height), (16...30).contains(size) else { return }
        let budget = ["candidateHeight": height, "candidateSize": size]
        let defaults = UserDefaults.standard
        guard defaults.dictionary(forKey: geometryBudgetKey) as? [String: Double] != budget else { return }
        defaults.set(budget, forKey: geometryBudgetKey)
    }

    /// Selection context shared by cold start and host recording (same defaults source, no duplicated key-name logic).
    private static func readingRowSelection(layoutKind: String?) -> String {
        CandidateReadingRowHint.selectionKey(
            layoutKind: layoutKind,
            definitionID: UserDefaults.standard.string(forKey: "keyboard.selectedLayoutDefinitionID"))
    }

    private static var readingRowSelection: String {
        readingRowSelection(layoutKind: UserDefaults.standard.string(forKey: AppSettings.selectedLayoutKey))
    }

    /// Called after the host adopts eligibility: records it as `layout`'s cold-start first-frame hint (not
    /// rewritten if unchanged). Hints are kept per keyboard, so a switch that is not remembered (or not yet
    /// saved) leaves the hint of the keyboard the next presentation shows in place.
    public static func recordReadingRow(
        eligible: Bool, candidateAreaRequired: Bool = true, layout: KeyboardLayoutKind
    ) {
        let defaults = UserDefaults.standard
        let hint = CandidateReadingRowHint(
            selection: readingRowSelection(layoutKind: layout.rawValue), eligible: eligible,
            candidateAreaRequired: candidateAreaRequired)
        guard
            let hints = CandidateReadingRowHint.recording(
                hint, into: defaults.object(forKey: CandidateReadingRowHint.defaultsKey))
        else { return }
        defaults.set(hints, forKey: CandidateReadingRowHint.defaultsKey)
    }

    private static let mainRowsKey = "keyboard.presentation.mainRows.v1"

    /// Records the letter rows the panel reported for the keyboard of `layout`. A board the input
    /// method picks (Zhuyin's four rows) is not named by the saved definition, so without this every
    /// presentation would start at the standard three rows and cut off the control row.
    public static func recordPhysicalMainRows(_ rows: Int, layout: KeyboardLayoutKind) {
        guard KeyboardPanelGeometry.standardMainRowCount...maximumRecordedMainRows ~= rows else { return }
        let defaults = UserDefaults.standard
        let selection = readingRowSelection(layoutKind: layout.rawValue)
        var stored = defaults.dictionary(forKey: mainRowsKey) as? [String: Int] ?? [:]
        guard stored[selection] != rows else { return }
        stored[selection] = rows
        defaults.set(stored, forKey: mainRowsKey)
    }

    private static let maximumRecordedMainRows = 6

    public static func load() -> Self {
        var result = Self()
        result.heightPreset = KeyboardHeightPreferences.current
        let defaults = UserDefaults.standard
        let storedHint = defaults.object(forKey: CandidateReadingRowHint.defaultsKey)
        // The hint records the layout's eligibility; only the row placement turns it into height.
        result.readingRowReserved =
            KeyboardReadingPlacementPreferences.current == .row
            && CandidateReadingRowHint.resolve(
                storedValue: storedHint, currentSelection: readingRowSelection)
        result.candidateAreaReserved = CandidateReadingRowHint.resolveCandidateArea(
            storedValue: storedHint, currentSelection: readingRowSelection)
        let recordedRows = (defaults.dictionary(forKey: mainRowsKey) as? [String: Int])?[readingRowSelection]
        result.physicalMainRows =
            recordedRows.flatMap {
                KeyboardPanelGeometry.standardMainRowCount...maximumRecordedMainRows ~= $0 ? $0 : nil
            }
            ?? KeyboardPanelGeometry.physicalMainRowBudget(
                forDefinitionID: defaults.string(forKey: "keyboard.selectedLayoutDefinitionID"))
        if let budget = defaults.dictionary(forKey: geometryBudgetKey) as? [String: Double],
            let height = budget["candidateHeight"], (36...56).contains(height),
            let size = budget["candidateSize"], (16...30).contains(size)
        {
            result.candidateHeight = height
            result.candidateSize = size * CandidateTextSizePreferences.current.factor
        }
        return result
    }

    public var skin: SkinDefinition { appearance.document.skin }
    public var candidateBar: CandidateBarDefinition { appearance.document.candidateBar }

    /// Cached inputs seed first presentation; accepted live reports update the visible budget separately.
    public func shellHeight(compact: Bool) -> CGFloat {
        CGFloat(presentationBudget(compact: compact).shellHeight)
    }

    public func presentationBudget(compact: Bool) -> KeyboardPanelPresentationBudget {
        KeyboardPanelPresentationBudget(
            candidateHeight: candidateHeight,
            candidateSize: candidateSize,
            readingRow: readingRowReserved,
            candidateArea: candidateAreaReserved,
            compact: compact, heightPreset: heightPreset,
            physicalMainRows: physicalMainRows)
    }

    public var presentationShell: KeyboardPresentationShell {
        KeyboardPresentationShell(
            readingRow: readingRowReserved, candidateArea: candidateAreaReserved,
            mainRows: physicalMainRows)
    }

    public func appearance(systemDark: Bool) -> KeyboardAppearance {
        KeyboardAppearance(skin: skin, dark: systemDark)
    }
}

/// One resolved palette and font model for UIKit controls and engine-free SwiftUI previews.
///
/// Every keycap asks for several colours and fonts on each configure/layout pass.
/// Resolving them from the skin (hex parsing, WCAG contrast with `pow`, font
/// descriptors) on every call made a single keystroke cost hundreds of palette
/// resolutions on the main thread, so the resolved palette is shared per
/// `(skin, dark)` and fonts/measurements are cached process-wide.
public struct KeyboardAppearance: Equatable, Sendable {
    public var skin: SkinDefinition {
        didSet { palette = KeyboardPalette.resolve(skin: skin, dark: dark, tray: drawsSkinBackground) }
    }
    public var dark: Bool {
        didSet { palette = KeyboardPalette.resolve(skin: skin, dark: dark, tray: drawsSkinBackground) }
    }
    private var palette: KeyboardPalette
    /// How much wider the board's columns are than a phone's (`StandardKeyRowGeometry.keyGapScale`):
    /// the skin's gaps grow with it. Only the painted cap shrinks; touch areas still meet, so no
    /// tap lands in a dead gap.
    public var keyGapScale = 1.0
    /// Device-level choice to widen gaps on wide boards at all; read when the appearance is built.
    public var scalesKeyGaps = KeyGapScalingPreferences.current
    /// Device-level: draw the skin background behind the keys. The keys are then separated from
    /// that background rather than from the system surface, so the palette follows it.
    public var drawsSkinBackground = SkinBackgroundPreferences.current {
        didSet {
            if drawsSkinBackground != oldValue {
                palette = KeyboardPalette.resolve(skin: skin, dark: dark, tray: drawsSkinBackground)
            }
        }
    }
    /// Device-level candidate text scale; read from the cached preference when the appearance is built.
    public var candidateTextSize = CandidateTextSizePreferences.current
    /// Device-level choice to draw engine comments in the collapsed candidate row.
    public var showsCollapsedCandidateComments = CollapsedCandidateCommentPreferences.current
    /// The skin's candidate size with the device scale applied.
    public var candidateFontSize: Double { skin.typography.candidateSize * candidateTextSize.factor }
    /// The skin's comment size with the device scale applied.
    public var candidateSecondaryFontSize: Double { skin.typography.secondarySize * candidateTextSize.factor }
    public init(skin: SkinDefinition = .systemDefault, dark: Bool = false) {
        // Stored/fallback/default appearances share one source; custom skins stay exact.
        let skin = skin.id == SkinDefinition.systemDefault.id ? .systemDefault : skin
        self.skin = skin
        self.dark = dark
        self.palette = KeyboardPalette.resolve(skin: skin, dark: dark, tray: drawsSkinBackground)
    }

    /// The palette is derived from `(skin, dark)`, so those two (and the cap geometry flag) decide equality.
    /// SwiftUI uses this to skip environment-driven updates when a parent rebuilds
    /// an identical appearance.
    public static func == (lhs: KeyboardAppearance, rhs: KeyboardAppearance) -> Bool {
        lhs.dark == rhs.dark && lhs.skin == rhs.skin && lhs.keyGapScale == rhs.keyGapScale
            && lhs.scalesKeyGaps == rhs.scalesKeyGaps
            && lhs.drawsSkinBackground == rhs.drawsSkinBackground
            && lhs.candidateTextSize == rhs.candidateTextSize
            && lhs.showsCollapsedCandidateComments == rhs.showsCollapsedCandidateComments
    }

    public var isSystemDefault: Bool { skin.id == SkinDefinition.systemDefault.id }

    /// Stand-in for the system keyboard surface in host-app previews: the product never paints this
    /// on the real keyboard, and a skin's own panel colour or background must not show here either.
    public var previewSurface: Color {
        KeyboardAppearance(skin: .systemDefault, dark: dark).color("panel")
    }

    /// Accent for glyphs drawn directly on the panel (status icons, the chosen
    /// reading, tool links, checkmarks). The system palette's `accent` is a pale
    /// return-key *fill*; as a glyph on the panel it nearly vanished, so a fill
    /// without contrast is deepened (or lightened in dark mode) until legible.
    public var accentForeground: Color { Color(uiColor: palette.accentForeground) }
    /// A faint veil over the drawn background, when the keys need it to stand out (see `KeyContrast`).
    var trayVeil: Color? { palette.trayVeil }
    public var uiAccentForeground: UIColor { palette.accentForeground }

    /// Every skin's key size sits on one scale: the default 22 draws the system keyboard's sizes, so
    /// the built-in appearances (and copies) match the system default, and an edited size scales
    /// smoothly instead of jumping to a literal point size.
    private var keyScale: Double {
        skin.typography.keySize / SkinDefinition.systemDefault.typography.keySize * labelScale
    }
    /// Labels on a wide board grow with its columns (`StandardKeyRowGeometry.labelScale`).
    var labelScale: Double { StandardKeyRowGeometry.labelScale(keyGapScale) }

    /// The candidate bar on a wide board: its padding and spacing grow with the candidate text,
    /// the same rate as key labels, so the candidates keep their proportions to the keys.
    func scalingCandidateBar(_ bar: CandidateBarDefinition) -> CandidateBarDefinition {
        guard labelScale != 1 else { return bar }
        var scaled = bar
        scaled.collapsed.cellPaddingX *= labelScale
        scaled.collapsed.cellSpacing *= labelScale
        scaled.expanded.columnSpacing *= labelScale
        scaled.expanded.rowSpacing *= labelScale
        return scaled
    }
    /// The skin's corner radius on this board (`StandardKeyRowGeometry.cornerScale`).
    public var keyCornerRadius: Double {
        skin.keycap.cornerRadius * StandardKeyRowGeometry.cornerScale(keyGapScale)
    }
    public var controlTextSize: Double { 14 * keyScale }
    public var keyTextSize: Double { 18 * keyScale }
    /// Letters on the 9-key phone pad, a step smaller than single-letter keys.
    public var phoneKeyTextSize: Double { 17 * keyScale }
    public var controlIconSize: Double { min(20, skin.typography.keySize) * labelScale }
    /// Scales font size to the available key width: long labels (merged keys, nine-key letter clusters,
    /// function words) shrink to the measured width, single letters keep the familiar system key size; the
    /// lower bound is 55% so narrow keys do not turn into tiny text.
    public func scaledFontSize(_ base: Double, label: String, availableWidth: CGFloat) -> Double {
        let base = label.count > 1 ? min(base, keyTextSize) : base
        guard availableWidth > 0, !label.isEmpty else { return base }
        let width = KeyboardTextMeasure.width(of: label, font: uiFont(base))
        guard width > availableWidth else { return base }
        return max(base * 0.55, base * availableWidth / width)
    }
    /// Each side of a cap inside its slot, widened on a wide board.
    public var keyInsetX: Double {
        StandardKeyRowGeometry.capInset(
            skin.spacing.visualInsetX, scale: StandardKeyRowGeometry.horizontalGapScale(keyGapScale))
    }
    public var keyInsetY: Double {
        StandardKeyRowGeometry.capInset(
            skin.spacing.visualInsetY, scale: StandardKeyRowGeometry.verticalGapScale(keyGapScale))
    }

    /// This appearance on a board whose letter rows are `width` wide.
    public func scalingKeyGaps(width: Double, split: ActiveLayoutSplit?) -> Self {
        var scaled = self
        scaled.keyGapScale = scalesKeyGaps ? StandardKeyRowGeometry(width: width, split: split).keyGapScale() : 1
        return scaled
    }

    public func visualRect(in bounds: CGRect) -> CGRect {
        bounds.insetBy(dx: keyInsetX, dy: keyInsetY)
    }
    /// A choice on the 9-key rail: the rail draws one control-coloured column, outlined once, so
    /// each choice takes the control colour without an outline of its own.
    public static let railChoiceRole = "railChoice"
    private static func paletteRole(_ role: String) -> String { role == railChoiceRole ? "control" : role }

    public func color(_ name: String) -> Color { Color(uiColor: uiColor(name)) }
    public func uiColor(_ name: String) -> UIColor {
        // The rail already paints the column; a second translucent fill per choice showed as boxes.
        name == Self.railChoiceRole ? .clear : palette.fill(name)
    }
    /// The function keys of a dark, borderless skin get a hairline; see `outlinesFunctionKeys`.
    public func borderWidth(for role: String) -> Double {
        if role == Self.railChoiceRole { return 0 }
        return (role == "control" || role == "accent") && palette.outlinesControls ? 1 : skin.keycap.borderWidth
    }
    public func text(on role: String, secondary: Bool = false) -> UIColor {
        palette.text(on: Self.paletteRole(role), secondary: secondary)
    }
    public func uiFont(_ size: Double) -> UIFont {
        KeyboardFontCache.font(size: size, weight: skin.typography.weight, family: skin.typography.family)
    }
    public func font(_ size: Double) -> Font { Font(uiFont(size)) }
}
/// The colours of one `(skin, dark)` pair, resolved once. Instances are immutable
/// and shared through a small most-recently-used cache: a keyboard only ever
/// shows a handful of `(skin, dark)` pairs (light/dark of the applied skin plus
/// previews), and `SkinDefinition ==` short-circuits on shared storage.
private final class KeyboardPalette: Sendable {
    private let resolved: [String: SkinColor]
    private let fills: [String: UIColor]
    private let texts: [String: UIColor]
    private let secondaryTexts: [String: UIColor]
    let accentForeground: UIColor
    let outlinesControls: Bool
    /// Laid over the skin's background when the letter keys cannot part from it on their own.
    let trayVeil: Color?
    /// Keys are drawn over the system keyboard surface of the mode, so translucent fills are judged
    /// as composited over it.
    private let surface: SkinColor

    private init(skin: SkinDefinition, dark: Bool, tray: Bool) {
        var colors = skin.resolvedColors(dark: dark)
        // Behind the keys is the skin's own background when the keyboard draws it, else the system's.
        var traySamples = tray ? SkinBackgroundTray.samples(of: skin, dark: dark) : []
        let veil = traySamples.isEmpty ? nil : KeyContrast.separate(&colors, from: traySamples)
        if let veil { traySamples = traySamples.map { veil.composited(over: $0) } }
        trayVeil = veil.map { Color(red: $0.red, green: $0.green, blue: $0.blue, opacity: $0.alpha) }
        let surface = traySamples.isEmpty ? SkinDefinition.systemSurface(dark: dark) : SkinColor.average(traySamples)
        self.surface = surface
        resolved = colors
        func ui(_ c: SkinColor) -> UIColor { UIColor(red: c.red, green: c.green, blue: c.blue, alpha: c.alpha) }
        fills = colors.mapValues(ui)
        var texts: [String: UIColor] = [:]
        var secondary: [String: UIColor] = [:]
        for role in colors.keys {
            texts[role] = ui(Self.textColor(colors, role: role, secondary: false, surface: surface))
            secondary[role] = ui(Self.textColor(colors, role: role, secondary: true, surface: surface))
        }
        self.texts = texts
        secondaryTexts = secondary
        let panel = (colors["panel"] ?? colors["key"]!).composited(over: surface)
        let accent = (colors["accent"] ?? panel).composited(over: panel)
        accentForeground = ui(Self.legibleAccent(accent, text: colors["accentText"], on: panel))
        outlinesControls = skin.outlinesFunctionKeys(dark: dark)
    }

    /// An authored accent that already reads as a glyph on the panel (3:1) is
    /// kept exactly. A fill that does not (the system palette's pale return-key
    /// blue, or its dark counterpart) is moved towards the palette's own accent
    /// text colour, or black/white when that is not legible either, until it
    /// reads as text (4.5:1): the hue survives instead of turning grey or white.
    private static func legibleAccent(_ accent: SkinColor, text: SkinColor?, on panel: SkinColor) -> SkinColor {
        if accent.contrast(on: panel) >= 3 { return accent }
        let black = SkinColor(hex: "#000000")!, white = SkinColor(hex: "#FFFFFF")!
        let extreme = black.contrast(on: panel) >= white.contrast(on: panel) ? black : white
        let target = text.map { $0.contrast(on: panel) >= 4.5 ? $0 : extreme } ?? extreme
        for step in 1...10 {
            let t = Double(step) / 10
            func mix(_ a: Double, _ b: Double) -> Int { Int(((a + (b - a) * t) * 255).rounded()) }
            let hex = String(
                format: "#%02X%02X%02X", mix(accent.red, target.red),
                mix(accent.green, target.green), mix(accent.blue, target.blue))
            if let candidate = SkinColor(hex: hex), candidate.contrast(on: panel) >= 4.5 { return candidate }
        }
        return target
    }

    private static func textColor(
        _ colors: [String: SkinColor], role: String, secondary: Bool, surface: SkinColor
    ) -> SkinColor {
        colors[secondary ? "secondaryText" : (role == "accent" ? "accentText" : "text")]!
            .contrasting(on: colors[role] ?? colors["key"]!, over: surface)
    }

    func fill(_ name: String) -> UIColor { fills[name] ?? .black }

    func text(on role: String, secondary: Bool) -> UIColor {
        if let cached = (secondary ? secondaryTexts : texts)[role] { return cached }
        // Unknown role: contrast against the key surface, exactly as before.
        let c = Self.textColor(resolved, role: role, secondary: secondary, surface: surface)
        return UIColor(red: c.red, green: c.green, blue: c.blue, alpha: c.alpha)
    }

    private static let recent = OSAllocatedUnfairLock<
        [(skin: SkinDefinition, dark: Bool, tray: Bool, palette: KeyboardPalette)]
    >(initialState: [])

    static func resolve(skin: SkinDefinition, dark: Bool, tray: Bool) -> KeyboardPalette {
        recent.withLock { recent in
            if let index = recent.firstIndex(where: { $0.dark == dark && $0.tray == tray && $0.skin == skin }) {
                let hit = recent.remove(at: index)
                recent.append(hit)
                return hit.palette
            }
            let palette = KeyboardPalette(skin: skin, dark: dark, tray: tray)
            recent.append((skin, dark, tray, palette))
            if recent.count > 6 { recent.removeFirst(recent.count - 6) }
            return palette
        }
    }
}

/// Process-wide font cache: building a designed system font goes through a
/// descriptor lookup that is far more expensive than the dictionary hit.
enum KeyboardFontCache {
    // NSCache is internally synchronized; it just is not annotated Sendable.
    nonisolated(unsafe) private static let cache = NSCache<NSString, UIFont>()

    static func font(size: Double, weight: String, family: String) -> UIFont {
        let key = "\(family)|\(weight)|\(size)" as NSString
        if let cached = cache.object(forKey: key) { return cached }
        let uiWeight: UIFont.Weight = weight == "semibold" ? .semibold : weight == "regular" ? .regular : .medium
        let base = UIFont.systemFont(ofSize: size, weight: uiWeight)
        let design: UIFontDescriptor.SystemDesign =
            family == "rounded"
            ? .rounded
            : family == "serif"
                ? .serif
                : family == "monospaced" ? .monospaced : .default
        let font = UIFont(descriptor: base.fontDescriptor.withDesign(design) ?? base.fontDescriptor, size: size)
        cache.setObject(font, forKey: key)
        return font
    }
}

/// Cached single-line text widths for keycap fitting (labels repeat on every pass).
enum KeyboardTextMeasure {
    // NSCache is internally synchronized; it just is not annotated Sendable.
    nonisolated(unsafe) private static let cache = NSCache<NSString, NSNumber>()

    static func width(of text: String, font: UIFont) -> CGFloat {
        let key = "\(font.fontName)|\(font.pointSize)|\(text)" as NSString
        if let cached = cache.object(forKey: key) { return CGFloat(cached.doubleValue) }
        let width = (text as NSString).size(withAttributes: [.font: font]).width
        cache.setObject(NSNumber(value: Double(width)), forKey: key)
        return width
    }
}

private struct KeyboardAppearanceKey: EnvironmentKey { static let defaultValue = KeyboardAppearance() }

/// UIKit → UIKit-free policy mapping (`KeyboardAppearancePolicy` lives in SkinKit so it
/// is testable off-device). `.default` maps to `.unspecified`.
extension HostKeyboardAppearance {
    init(_ appearance: UIKeyboardAppearance) {
        switch appearance {
        case .light: self = .light
        case .dark: self = .dark
        default: self = .unspecified
        }
    }
}

extension EnvironmentValues {
    public var keyboardAppearance: KeyboardAppearance {
        get { self[KeyboardAppearanceKey.self] }
        set { self[KeyboardAppearanceKey.self] = newValue }
    }
}

struct SkinKeyBackground: View {
    @Environment(\.keyboardAppearance) private var appearance
    /// Set by the press modifier so the SwiftUI keycap tightens its shadow with
    /// the same constants as the UIKit keycaps (`KeyboardPressPhysics`).
    @Environment(\.keyboardKeyPressed) private var pressed
    var role = "key"
    var body: some View {
        RoundedRectangle(cornerRadius: appearance.keyCornerRadius)
            .fill(appearance.color(role))
            .overlay(
                RoundedRectangle(cornerRadius: appearance.keyCornerRadius).stroke(
                    appearance.color("border"), lineWidth: appearance.borderWidth(for: role))
            )
            .shadow(
                color: .black.opacity(restShadowOpacity),
                radius: 0,
                y: pressed ? KeyboardPressPhysics.shadowOffsetY(from: 1) : 1
            )
            .padding(.horizontal, appearance.keyInsetX)
            .padding(.vertical, appearance.keyInsetY)
            .allowsHitTesting(false)
    }

    private var restShadowOpacity: Double {
        let rest = appearance.skin.keycap.shadow == "subtle" ? 0.18 : 0
        return pressed ? Double(KeyboardPressPhysics.shadowOpacity(from: Float(rest))) : rest
    }
}

/// Render-only: a pressed keycap's shadow tightens. Never touches layout.
private struct KeyboardKeyPressedKey: EnvironmentKey { static let defaultValue = false }
extension EnvironmentValues {
    var keyboardKeyPressed: Bool {
        get { self[KeyboardKeyPressedKey.self] }
        set { self[KeyboardKeyPressedKey.self] = newValue }
    }
}

/// Visual layer is inset; the UIControl bounds and tracking remain full-sized.
final class SkinCapLayer: CALayer {
    @MainActor func update(in view: UIView, appearance: KeyboardAppearance, role: String, pressed: Bool = false) {
        if superlayer == nil { view.layer.insertSublayer(self, at: 0) }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        frame = appearance.visualRect(in: view.bounds)
        cornerRadius = appearance.keyCornerRadius
        backgroundColor = appearance.uiColor(role).cgColor
        borderWidth = appearance.borderWidth(for: role)
        borderColor = appearance.uiColor("border").cgColor
        let restOpacity: Float = appearance.skin.keycap.shadow == "subtle" ? 0.18 : 0
        shadowColor = UIColor.black.cgColor
        shadowOpacity = pressed ? KeyboardPressPhysics.shadowOpacity(from: restOpacity) : restOpacity
        shadowOffset = CGSize(
            width: 0,
            height: pressed ? KeyboardPressPhysics.shadowOffsetY(from: 1) : 1)
        shadowRadius = 0
        view.backgroundColor = .clear
        view.layer.borderWidth = 0
        CATransaction.commit()
    }
}

/// Key hit target: the root input view hands touches that land in the gap between two adjacent keys to the nearer key.
protocol KeyboardKeyHitTarget: UIView {}

/// The gap/edge point `FeedbackInputView.hitTest` last routed to a key. After hit
/// testing, UIKit asks the chosen view `point(inside:)` again at the real touch
/// point and drops the touch when it is outside, so a routed key accepts exactly
/// that one point (window space) in addition to its own bounds.
@MainActor
enum KeyboardRoutedTouch {
    private static weak var key: UIView?
    private static var windowPoint = CGPoint.zero

    static func route(_ key: UIView, at windowPoint: CGPoint) {
        self.key = key
        self.windowPoint = windowPoint
    }

    /// Drops a recorded route so a stale entry cannot outlive the layout that produced it
    /// (one-handed restore moves keys under a recorded window point).
    static func clear() {
        key = nil
        windowPoint = .zero
    }

    // MARK: One-handed gutter exclusion

    /// True while a restore control covers the gutter; `FeedbackInputView` then
    /// declines nearest-key routing for gutter touches.
    private static var oneHandGutterExposed = false
    /// The control's frame in window coordinates; nil when unknown.
    private static var oneHandGutterWindowFrame: CGRect?
    private static weak var oneHandGutterControl: UIControl?

    static func setOneHandGutter(exposed: Bool) {
        oneHandGutterExposed = exposed
        if !exposed {
            oneHandGutterWindowFrame = nil
            oneHandGutterControl = nil
            // A route recorded against the narrowed layout must not survive it.
            clear()
        }
    }

    static func setOneHandGutterFrame(_ frame: CGRect?, control: UIControl? = nil) {
        oneHandGutterWindowFrame = frame
        oneHandGutterControl = frame == nil ? nil : control
    }

    /// Only the owner may retire its region; an old view must not clear a replacement.
    static func registerOneHandGutter(_ control: UIControl, frame: CGRect?) {
        guard let frame else {
            if oneHandGutterControl === control { setOneHandGutter(exposed: false) }
            return
        }
        oneHandGutterControl = control
        oneHandGutterWindowFrame = frame
        oneHandGutterExposed = true
    }

    /// SwiftUI can return its transparent container instead of this visible native descendant.
    static func oneHandRestoreTarget(at point: CGPoint, in window: UIWindow) -> UIControl? {
        guard pointIsInOneHandGutter(point), let control = oneHandGutterControl,
            control.window === window, control.isEnabled,
            control.bounds.contains(control.convert(point, from: window))
        else { return nil }
        var ancestor: UIView? = control
        while let view = ancestor {
            guard !view.isHidden, view.alpha > 0.01, view.isUserInteractionEnabled else { return nil }
            ancestor = view.superview
        }
        return control
    }

    /// Whether a window-coordinate point falls into the live restore gutter.
    static func pointIsInOneHandGutter(_ windowPoint: CGPoint) -> Bool {
        oneHandGutterExposed && oneHandGutterWindowFrame?.contains(windowPoint) == true
    }

    // MARK: Wide content blank exclusion

    /// The view spanning a docked wide keyboard's real content, so the blank margins beside it
    /// never route to the nearest key. Its frame is read at hit-test time in window space, so it
    /// cannot go stale; a deallocated or replaced reporter leaves no region behind.
    private static weak var wideContentView: UIView?

    /// Only the registered view may retire its region; an old view must not clear a replacement.
    static func registerWideContent(_ view: UIView, active: Bool) {
        if active {
            guard wideContentView !== view else { return }
            wideContentView = view
        } else {
            guard wideContentView === view else { return }
            wideContentView = nil
        }
        // Keys moved under a recorded window point; the route cannot survive.
        clear()
    }

    static func pointIsOutsideWideContent(_ windowPoint: CGPoint, in window: UIWindow) -> Bool {
        guard let view = wideContentView, view.window === window else { return false }
        let frame = view.convert(view.bounds, to: window)
        guard frame.width > 0, frame.height > 0 else { return false }
        return !frame.contains(windowPoint)
    }

    static func accepts(_ view: UIView, _ point: CGPoint) -> Bool {
        guard view === key, let window = view.window else { return false }
        let p = view.convert(point, to: window)
        return abs(p.x - windowPoint.x) < 0.5 && abs(p.y - windowPoint.y) < 0.5
    }
}

/// Fades a key's label views with the shared caret-drag fade: one opacity animation per change,
/// nothing running between changes. The keycap layer is never in `labels`. A key leaving its
/// window detaches the observer (`didMoveToWindow`), so no deinit is needed.
@MainActor
final class KeyLabelFadeBinding {
    private var token: NSObjectProtocol?

    func attach(to view: UIView, labels: @escaping @MainActor () -> [UIView?]) {
        detach()
        guard view.window != nil else { return }
        let fade = KeyLabelFade.shared
        let current = fade.opacity
        for label in labels() { label?.alpha = current }
        token = NotificationCenter.default.addObserver(
            forName: .keyLabelFadeDidChange, object: fade, queue: .main
        ) { _ in
            MainActor.assumeIsolated {
                let views = labels()
                let target = fade.opacity
                UIView.animate(
                    withDuration: fade.animationDuration, delay: 0,
                    options: [.beginFromCurrentState, .allowUserInteraction]
                ) {
                    for label in views { label?.alpha = target }
                }
            }
        }
    }

    func detach() {
        if let token { NotificationCenter.default.removeObserver(token) }
        token = nil
    }
}

class SkinnedButton: UIButton, KeyboardKeyHitTarget {
    private let labelFadeBinding = KeyLabelFadeBinding()
    /// The views that carry this key's text and glyph; they fade while the space bar drags the caret.
    var fadingLabelViews: [UIView?] { [titleView, glyphView, authorSubtitleLabel] }
    override func didMoveToWindow() {
        super.didMoveToWindow()
        labelFadeBinding.attach(to: self) { [weak self] in self?.fadingLabelViews ?? [] }
    }
    /// Feedback on touch down (system keyboard behavior); the globe key leaves switch feedback to the system, so subclasses can turn this off.
    var emitsTouchDownFeedback: Bool { true }
    override func point(inside point: CGPoint, with event: UIEvent?) -> Bool {
        super.point(inside: point, with: event) || KeyboardRoutedTouch.accepts(self, point)
    }
    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        if isEnabled {
            if emitsTouchDownFeedback { KeyboardFeedbackService.shared.keyTouchDown() }
            // Every key keeps press order: a character still held is typed before this key acts.
            KeyRollover.keyDown(self)
        }
        super.touchesBegan(touches, with: event)
    }
    // Representables reassign these on every SwiftUI update; only a real change
    // needs another layout pass (and another cap-layer repaint).
    var appearance = KeyboardAppearance() { didSet { if appearance != oldValue { setNeedsLayout() } } }
    var skinRole = "control" { didSet { if skinRole != oldValue { setNeedsLayout() } } }
    private let capLayer = SkinCapLayer()
    private let releaseAnimator = KeyboardKeyReleaseAnimator()
    override var isHighlighted: Bool { didSet { setNeedsLayout() } }
    /// Author face of a native control (Shift, globe, Delete): a title replaces the glyph.
    private(set) var authorTitle: String?
    private var glyphName: String?
    /// The author's secondary label under the face; created on first use.
    private var authorSubtitleLabel: UILabel?
    private var showsAuthorSubtitle: Bool { authorSubtitleLabel?.isHidden == false }

    /// Rendering only: touch handling stays the native control's.
    func applyAuthorFace(title: String?, subtitle: String?, glyph: String) {
        let title = title?.isEmpty == false ? title : nil
        if let title {
            if authorTitle != title || glyphName != nil {
                glyphName = nil
                setImage(nil, for: .normal)
                setTitle(title, for: .normal)
                titleLabel?.adjustsFontSizeToFitWidth = true
                titleLabel?.minimumScaleFactor = 0.6
            }
        } else if authorTitle != nil || glyphName != glyph {
            setTitle(nil, for: .normal)
            glyphName = glyph
            setImage(UIImage(systemName: glyph), for: .normal)
        }
        authorTitle = title
        let subtitle = subtitle?.isEmpty == false ? subtitle : nil
        guard subtitle != nil || showsAuthorSubtitle else { return }
        let label = authorSubtitleLabel ?? makeAuthorSubtitleLabel()
        label.text = subtitle
        label.isHidden = subtitle == nil
        setNeedsLayout()
    }

    /// The button's own title and glyph views, captured whenever its face changes. A layout pass
    /// must not use the `titleLabel` / `imageView` getters: they create the view or apply the
    /// title again, and either invalidates the key's size. A creation lays the button out from
    /// inside the pass until the stack runs out; a reapplied language-tagged title makes the
    /// SwiftUI host lay the key out again, for ever.
    private(set) weak var titleView: UILabel?
    private weak var glyphView: UIImageView?

    override func setTitle(_ title: String?, for state: UIControl.State) {
        super.setTitle(title, for: state)
        captureFaceViews()
    }

    override func setAttributedTitle(_ title: NSAttributedString?, for state: UIControl.State) {
        super.setAttributedTitle(title, for: state)
        captureFaceViews()
    }

    override func setImage(_ image: UIImage?, for state: UIControl.State) {
        super.setImage(image, for: state)
        captureFaceViews()
    }

    private func captureFaceViews() {
        titleView = currentTitle != nil || currentAttributedTitle != nil ? titleLabel : nil
        glyphView = currentImage != nil ? imageView : nil
    }

    private func makeAuthorSubtitleLabel() -> UILabel {
        let label = UILabel()
        label.textAlignment = .center
        label.isUserInteractionEnabled = false
        addSubview(label)
        authorSubtitleLabel = label
        return label
    }

    override func layoutSubviews() {
        // A frame write on a transformed layer is undefined: start every pass
        // from identity and re-apply the press physics at the end.
        releaseAnimator.resetPressVisual(layers: pressVisualLayers)
        super.layoutSubviews()
        let role = isHighlighted ? "pressed" : skinRole
        if let label = authorSubtitleLabel, !label.isHidden {
            let visual = appearance.visualRect(in: bounds)
            label.font = appearance.uiFont(appearance.skin.typography.secondarySize)
            label.textColor = appearance.text(on: role, secondary: true)
            label.frame = CGRect(
                x: visual.minX + 3, y: visual.maxY - 16, width: max(0, visual.width - 6), height: 14)
        }
        capLayer.update(in: self, appearance: appearance, role: role, pressed: isHighlighted)
        releaseAnimator.update(layer: capLayer, isPressed: isHighlighted)
        releaseAnimator.updatePressVisual(container: layer, layers: pressVisualLayers, isPressed: isHighlighted)
        // Each of these writes invalidates the key's size even when the value is the same, and the
        // SwiftUI host answers that with another layout pass: only a change is written.
        let textColor = appearance.text(on: role)
        if tintColor != textColor { tintColor = textColor }
        if titleColor(for: .normal) != textColor { setTitleColor(textColor, for: .normal) }
        // A language-tagged title carries its own font.
        if currentAttributedTitle == nil, let label = titleView {
            let font = appearance.uiFont(appearance.controlTextSize)
            if label.font != font { label.font = font }
        }
        let symbols = UIImage.SymbolConfiguration(pointSize: appearance.controlIconSize, weight: .regular)
        if preferredSymbolConfigurationForImage(in: .normal) != symbols {
            setPreferredSymbolConfiguration(symbols, forImageIn: .normal)
        }
    }
    /// The keycap surface plus its glyphs move together; the button's own layer
    /// (hit testing / tracking geometry) is deliberately not transformed.
    private var pressVisualLayers: [CALayer?] {
        [capLayer, titleView?.layer, glyphView?.layer, authorSubtitleLabel?.layer]
    }
    /// A secondary label lifts the title/glyph so the two read as one face.
    override func contentRect(forBounds bounds: CGRect) -> CGRect {
        let rect = appearance.visualRect(in: bounds)
        return showsAuthorSubtitle ? rect.offsetBy(dx: 0, dy: -4) : rect
    }
}

// MARK: - Background tray

/// What the keyboard draws behind its key area once 显示外观背景 is on: the skin's keyboard colour and
/// background, the veil that keeps the keys apart from it, and soft top and bottom edges, so the band
/// eases into the candidate bar and the system's bottom row. The keyboard and the host app's preview
/// both use it; callers give it the frame to fill.
struct KeyAreaBackground: View {
    let appearance: KeyboardAppearance

    var body: some View {
        if appearance.drawsSkinBackground {
            let variant = appearance.dark ? appearance.skin.variants.dark : appearance.skin.variants.light
            SkinBackgroundTray(panel: appearance.color("panel"), background: variant?.background)
                .overlay { appearance.trayVeil }
                .mask {
                    VStack(spacing: 0) {
                        LinearGradient(colors: [.clear, .black], startPoint: .top, endPoint: .bottom)
                            .frame(height: 8)
                        Color.black
                        LinearGradient(colors: [.black, .clear], startPoint: .top, endPoint: .bottom)
                            .frame(height: 8)
                    }
                }
        }
    }
}

/// The skin's keyboard colour and background, drawn as a band behind the key area only, as Android
/// draws them behind its whole keyboard. The candidate bar above
/// it and the system's bottom row below stay on the system keyboard surface, so the band never
/// competes with the rounded sheet iOS draws around the keyboard.
struct SkinBackgroundTray: View {
    /// The skin's keyboard colour (`panel`), the base Android draws every keyboard on.
    let panel: Color
    /// The skin's own background over it, when it authors one.
    let background: SkinDefinition.Background?

    var body: some View {
        ZStack {
            panel
            if let background { fill(background) }
        }
    }

    @ViewBuilder private func fill(_ background: SkinDefinition.Background) -> some View {
        switch background.type {
        case "linearGradient":
            LinearGradient(
                colors: Self.stops(background), startPoint: Self.start(background), endPoint: Self.end(background))
        case "image":
            if let image = Self.image(background.image) {
                GeometryReader { proxy in
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFill()
                        .frame(
                            width: proxy.size.width, height: proxy.size.height,
                            alignment: Self.imageAlignment(background)
                        )
                        .clipped()
                }
            }
        default:
            Self.color(background.color) ?? .clear
        }
    }

    private static func stops(_ background: SkinDefinition.Background) -> [Color] {
        let hexes = background.colors ?? [background.from, background.to].compactMap { $0 }
        return hexes.compactMap(color)
    }
    private static func start(_ background: SkinDefinition.Background) -> UnitPoint {
        switch background.direction {
        case "horizontal": return .leading
        case "diagonal": return .topLeading
        default: return .top
        }
    }
    private static func end(_ background: SkinDefinition.Background) -> UnitPoint {
        switch background.direction {
        case "horizontal": return .trailing
        case "diagonal": return .bottomTrailing
        default: return .bottom
        }
    }
    private static func imageAlignment(_ background: SkinDefinition.Background) -> Alignment {
        switch background.align {
        case "top": return .top
        case "bottom": return .bottom
        default: return .center
        }
    }

    /// The colours the keys sit on: the keyboard colour, or over it a solid colour, every gradient
    /// stop (the keys must read over each), or an image's average.
    static func samples(of skin: SkinDefinition, dark: Bool) -> [SkinColor] {
        let surface = SkinDefinition.systemSurface(dark: dark)
        let resolved = skin.resolvedColors(dark: dark)
        let panel = (resolved["panel"] ?? resolved["key"]!).composited(over: surface)
        guard let background = (dark ? skin.variants.dark : skin.variants.light)?.background else { return [panel] }
        let colors: [SkinColor]
        switch background.type {
        case "linearGradient":
            colors = (background.colors ?? [background.from, background.to].compactMap { $0 })
                .compactMap(SkinColor.init(hex:))
        case "image":
            colors = image(background.image).flatMap(averageColor).map { [$0] } ?? []
        default:
            colors = background.color.flatMap(SkinColor.init(hex:)).map { [$0] } ?? []
        }
        return colors.isEmpty ? [panel] : colors.map { $0.composited(over: panel) }
    }

    /// An image drawn into one pixel: its average colour.
    private static func averageColor(_ image: UIImage) -> SkinColor? {
        guard let cg = image.cgImage else { return nil }
        var pixel = [UInt8](repeating: 0, count: 4)
        let drawn = pixel.withUnsafeMutableBytes { buffer -> Bool in
            guard
                let context = CGContext(
                    data: buffer.baseAddress, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                    space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)
            else { return false }
            context.interpolationQuality = .medium
            context.draw(cg, in: CGRect(x: 0, y: 0, width: 1, height: 1))
            return true
        }
        guard drawn else { return nil }
        return SkinColor(hex: String(format: "#%02X%02X%02X", pixel[0], pixel[1], pixel[2]))
    }

    private static func color(_ hex: String?) -> Color? {
        guard let hex, let c = SkinColor(hex: hex) else { return nil }
        return Color(red: c.red, green: c.green, blue: c.blue, opacity: c.alpha)
    }
    private static func image(_ dataURL: String?) -> UIImage? {
        guard let dataURL, let comma = dataURL.firstIndex(of: ","),
            let data = Data(base64Encoded: String(dataURL[dataURL.index(after: comma)...]))
        else { return nil }
        return UIImage(data: data)
    }
}
