import Foundation

/// What a jump key does when tapped. Pure so the decision is tested without a keyboard.
public enum LayoutPageJumpPlan: Equatable, Sendable {
    /// The key is not a usable jump: a target the running input method cannot use, or one this
    /// version does not know. The keyboard stays as it was.
    case ignore
    /// The target is the running layout: only the page opens.
    case openPage(LayoutAction.PageTarget)
    /// Switch to the layout the way the keyboard menu does; open the page only if that succeeded.
    case switchLayout(LayoutInput.Builtin, thenOpen: LayoutAction.PageTarget)

    /// `reachable` is every layout the running input method can switch to; the running one needs
    /// no entry.
    public static func plan(
        for action: LayoutAction, running: LayoutInput.Builtin, reachable: Set<LayoutInput.Builtin>
    ) -> LayoutPageJumpPlan {
        guard let jump = action.layoutPageJump else { return .ignore }
        if jump.layout == running { return .openPage(jump.page) }
        return reachable.contains(jump.layout) ? .switchLayout(jump.layout, thenOpen: jump.page) : .ignore
    }
}
