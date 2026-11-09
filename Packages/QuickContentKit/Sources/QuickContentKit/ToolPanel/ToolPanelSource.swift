import Foundation

/// The one text a tool processes, shown at the top of the tool panel (M-D3).
///
/// A tool never sees the field itself: it receives exactly one bounded string. The panel says which
/// string that is, and the user may switch between the selection and the paragraph before the cursor.
public enum ToolPanelSource: String, CaseIterable, Hashable, Sendable {
    /// The text selected in the field; the primary source, because the user already pointed at it.
    case selection
    /// The paragraph that ends at the cursor, used when nothing is selected.
    case paragraphBeforeCursor
}

/// Why a source cannot be used right now. The interface turns each case into one short line, so the
/// panel can explain a disabled source instead of silently hiding it.
public enum ToolPanelSourceUnavailable: Equatable, Sendable {
    case nothingSelected
    case noTextBeforeCursor
}
