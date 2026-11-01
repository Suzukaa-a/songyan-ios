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

/// A jump to another layout is a visit: the user's own layout and input method come back when the
/// visit ends. Pure so where 返回 goes is tested without a keyboard.
public struct LayoutPageJumpVisit: Equatable, Sendable {
    public struct Place: Equatable, Sendable {
        public let layout: LayoutInput.Builtin
        public let schemaID: String
        public init(layout: LayoutInput.Builtin, schemaID: String) {
            self.layout = layout
            self.schemaID = schemaID
        }
    }

    /// The user's own layout, kept from the first jump of a chain.
    public let origin: Place
    /// What the last jump switched to.
    public let visited: Place
    /// The page the last jump opened on `visited`.
    public let visitedPage: LayoutAction.PageTarget

    /// The visit a jump from `running` starts or continues, once it landed on `visited`.
    public static func after(
        jumpingFrom running: Place, landedOn visited: Place, opening page: LayoutAction.PageTarget = .numeric,
        continuing existing: LayoutPageJumpVisit?
    ) -> LayoutPageJumpVisit {
        let origin = existing.flatMap { $0.visited == running ? $0.origin : nil } ?? running
        return LayoutPageJumpVisit(origin: origin, visited: visited, visitedPage: page)
    }

    /// The page to open on the user's own layout when the visited layout switches to `requested`
    /// (e.g. 符 on a visited 123 page), or nil when that is the visited page itself. Without this the
    /// visited layout's own symbol page would hide the user's, and a jump key there could not loop.
    public func pageAfterLeaving(requested: LayoutAction.PageTarget) -> LayoutAction.PageTarget? {
        requested == .letters || requested == visitedPage ? nil : requested
    }

    /// Where to switch back to, or nil when the user already left the visited layout some other way
    /// (the visit is over and nothing is restored) or is on the origin already.
    public func restoreTarget(running: Place) -> Place? {
        running == visited && running != origin ? origin : nil
    }
}
