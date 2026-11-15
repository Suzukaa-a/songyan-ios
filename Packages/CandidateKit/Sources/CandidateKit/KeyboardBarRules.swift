import LayoutKit

// MARK: - Candidate band

/// Whether a page keeps the candidate band. A layout's own letters follow the layout; ABC always
/// keeps its word suggestions, 123 and #+= only a live composition. On a wide surface the keyboard's
/// dismiss entry sits in the band, and without it a rail beside the keys takes their width, so every
/// page keeps the band there: flipping to 123 never narrows the key area.
public enum KeyboardCandidateBand {
    public static func required(
        definitionPage: Bool, definitionRequires: Bool, lettersPage: Bool, keepsForComposition: Bool,
        wideDismiss: Bool
    ) -> Bool {
        if definitionPage { return definitionRequires }
        return lettersPage || keepsForComposition || wideDismiss
    }
}

// MARK: - Authored control-row shortcuts

/// The shortcuts the keyboard bar adds around an authored control row, and which entries that row
/// already declares. A row that declares its own 123 key is drawn as the author stored it, as on
/// Android: the editor starts from the keyboard's whole bottom row, so nothing is missing from it.
/// An older row without one keeps the shortcuts it always had, so no layout loses its way to the
/// 123 page. A declared entry is never duplicated: a 中英 key counts under either action kind an
/// authored row may use for it. The globe is added whenever the system needs one and the layout
/// has none, since it is the only way to the next keyboard.
public struct KeyboardFooterShortcutPlan: Equatable {
    public let supplementShortcuts: Bool
    public let declaresNumericShortcut: Bool
    public let declaresSymbolShortcut: Bool
    public let declaresLayoutSwitch: Bool

    public init(controlRow: LayoutRow?, supplementShortcuts: Bool = true) {
        let keys = controlRow?.keys ?? []
        let declaresNumericShortcut = keys.contains { $0.action.pageSwitchTarget == .numeric }
        self.supplementShortcuts = supplementShortcuts && !declaresNumericShortcut
        self.declaresNumericShortcut = declaresNumericShortcut
        declaresSymbolShortcut = keys.contains { $0.action.pageSwitchTarget == .symbols }
        declaresLayoutSwitch = keys.contains {
            $0.action.type == .modeSwitch || $0.action.type == .languageSwitch
        }
    }

    /// Whether the bar adds its 123 shortcut.
    public var addsNumericShortcut: Bool { supplementShortcuts && !declaresNumericShortcut }

    /// Whether the bar adds its symbol-page shortcut.
    public var addsSymbolShortcut: Bool { supplementShortcuts && !declaresSymbolShortcut }

    /// Whether the bar adds its 中/英 shortcut; a declared one stays where the author put it.
    public var addsLayoutSwitch: Bool { supplementShortcuts && !declaresLayoutSwitch }

    /// Whether the bar adds the globe key.
    public func addsGlobe(definitionHasGlobe: Bool, showsGlobe: Bool) -> Bool {
        !definitionHasGlobe && showsGlobe
    }

    /// Whether the bar supplements this physical layout's authored footer. Only the bundled boards
    /// whose footer declares every control key rely on the declaration alone.
    public static func supplements(physicalLayoutID: String?) -> Bool {
        guard let physicalLayoutID else { return true }
        return physicalLayoutID != BuiltinLayouts.zhuyin41.id
            && physicalLayoutID != BuiltinLayouts.cangjie26.id
    }
}
