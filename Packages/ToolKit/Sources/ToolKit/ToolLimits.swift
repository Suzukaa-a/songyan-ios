// Limits one tool run is allowed to consume. Every value is supplied by the
// caller: production values come from the shared script bridge, so this package
// never picks one. Tests pass small numbers instead.
//
// Text lengths use UTF-16 code units on both platforms: Kotlin's String.length and
// Swift's utf16.count / NSRange agree on the same number.

public struct ToolLimits: Equatable, Sendable {
    /// Longest text one run may read, in UTF-16 code units. It applies to a
    /// selection and to the caret-preceding fallback alike.
    public let maximumInputUnits: Int

    /// Wall-clock budget of one run, in seconds.
    public let runTimeout: Double

    /// How long a written result stays undoable, in seconds. nil keeps undo
    /// available until the session is dismissed.
    public let undoWindow: Double?

    /// How many results one run may show; later results are dropped.
    public let maximumResults: Int

    public init(
        maximumInputUnits: Int, runTimeout: Double, undoWindow: Double?, maximumResults: Int
    ) {
        precondition(maximumInputUnits > 0, "maximumInputUnits must be positive")
        precondition(runTimeout > 0, "runTimeout must be positive")
        if let undoWindow {
            precondition(undoWindow > 0, "undoWindow must be positive")
        }
        precondition(maximumResults > 0, "maximumResults must be positive")
        self.maximumInputUnits = maximumInputUnits
        self.runTimeout = runTimeout
        self.undoWindow = undoWindow
        self.maximumResults = maximumResults
    }
}
