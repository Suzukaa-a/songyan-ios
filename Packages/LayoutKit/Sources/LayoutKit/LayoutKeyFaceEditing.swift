import Foundation

/// Title edits for key editors. `allowsTitleMode` is true where keys can follow the live keyboard
/// state (pages, and main-layout function keys); elsewhere every edit keeps the stored face.
public extension LayoutKey {
    var isFunctionKey: Bool { action.type != .code && action.type != .literal }

    /// Literal keys with a live face (a paired branch, or an explicit title mode carried by new
    /// built-in rows) get the same follow-function/custom choice as function keys. A legacy fixed
    /// literal with no title mode never had one.
    var supportsLiveTitle: Bool {
        if isFunctionKey { return true }
        guard action.type == .literal else { return false }
        return action.asciiValue != nil || titleMode != nil
    }

    /// A legacy space key or paired literal without a title mode always shows its stored label;
    /// showing "follow" for it would promise a live title it never had (editing the ASCII variant
    /// gives the key one). Other implicit nil cases
    /// (enter, globe, backspace, shift) keep following the live function title.
    var displayedTitleMode: LayoutKeyTitleMode {
        if titleMode == nil, action.type == .space || action.asciiValue != nil { return .custom }
        return titleMode ?? .automatic
    }

    /// Editing a title switches a live key to the author's own title. Keys without a live face
    /// keep their existing title semantics.
    func editingLabel(_ text: String, allowsTitleMode: Bool) -> LayoutKey {
        let titled = title(text)
        return allowsTitleMode && supportsLiveTitle ? titled : titled.settingTitleMode(titleMode)
    }

    /// A character key carries no title class; switching to a function key restores the live
    /// title. Literal edits keep the face the key already had, except that filling the ASCII variant
    /// of a key without a title mode makes it show what it types in the current branch; a title the
    /// author typed (`.custom`) always stays.
    func editingAction(_ newAction: LayoutAction, allowsTitleMode: Bool) -> LayoutKey {
        let updated = settingAction(newAction)
        guard allowsTitleMode else { return updated }
        switch newAction.type {
        case .layoutPageSwitch:
            guard let target = newAction.layoutPageJump else { return updated }
            return settingJumpTarget(target)
        case .code:
            return updated.settingTitleMode(nil)
        case .literal:
            // A function key switched into literal starts as fixed text; editing an existing
            // literal keeps its stored face, and a key with two variants follows the branch.
            let kept = action.type == .literal ? titleMode : nil
            return updated.settingTitleMode(newAction.asciiValue != nil && kept == nil ? .automatic : kept)
        default:
            return updated.settingTitleMode(titleMode ?? .automatic)
        }
    }

    /// A jump key is named after the page it opens until the author writes a title of their own:
    /// the title follows the target while it is empty or still the title of the page it pointed at.
    func settingJumpTarget(_ target: LayoutAction.PageJump) -> LayoutKey {
        let previous = action.layoutPageJump
        let trimmed = label.trimmingCharacters(in: .whitespacesAndNewlines)
        let generated = trimmed.isEmpty || previous.map { label == $0.pageLabel } == true
        let named = generated || previous == nil
        let updated = settingAction(.layoutPageSwitch(target))
        guard named else { return updated }
        return updated.settingTitleMode(.automatic).settingLabel(target.pageLabel)
    }
}

public extension LayoutAction.PageJump {
    /// The title of the page a jump opens, the same as that page's own switch key.
    var pageLabel: String { page == .symbols ? "符号" : "123" }
}

public extension LayoutAction.Kind {
    /// The kinds a key editor offers, in list order. A jump is a page key only, and `stored` stays
    /// visible as the current choice even when it is not offered.
    static func editorChoices(
        allowsCode: Bool, allowsFunctionActions: Bool, allowsJump: Bool, stored: LayoutAction.Kind
    ) -> [LayoutAction.Kind] {
        var kinds: [LayoutAction.Kind] = allowsCode ? [.code, .literal] : [.literal]
        if allowsFunctionActions {
            kinds += [
                .space, .enter, .backspace, .globe, .modeSwitch, .shift, .pageSwitch, .languageSwitch, .symbolLock,
                .clearInput,
            ]
            if allowsJump { kinds.append(.layoutPageSwitch) }
        }
        if !kinds.contains(stored) { kinds.append(stored) }
        return kinds
    }
}

public extension KeyboardPageKeyPath {
    /// A jump key sits in a page's content rows or a side column, not its footer.
    var allowsJumpKey: Bool {
        if case .chrome(let region, _) = self { return region != .bottom }
        return true
    }
}
