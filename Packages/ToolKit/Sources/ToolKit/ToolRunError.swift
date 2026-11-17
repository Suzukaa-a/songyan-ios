/// An error a tool has already worded for the user. The panel shows `toolMessage`; any other
/// error a run throws is logged and replaced by the panel's generic sentence, so host and
/// framework text never reaches the user.
public protocol ToolRunError: Error {
    var toolMessage: String? { get }
}
