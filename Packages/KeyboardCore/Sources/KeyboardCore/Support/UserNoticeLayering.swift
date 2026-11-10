import Foundation

/// Layering of ordinary-flow notices (pure value; shared by Host and views).
///
/// Invariants:
///  * Success and actionable notices ordinary users need (install, update, start using,
///    adaptation done...) go through the plain-language channel and do not disappear when
///    developer options are off.
///  * Raw `diagnostics` (paths, UUIDs, English reasons, schema source names...) go only to
///    developer diagnostics, never into the ordinary flow.
///  * The same fact is not repeated in several places (e.g. the "installed" section and a
///    success notice).
public enum UserNoticeLayering {

    /// Ordinary notice lines: only the plain-language notice; developer diagnostics are a separate channel.
    public static func userLines(notice: String?) -> [String] {
        guard let notice, !notice.isEmpty else { return [] }
        return [notice]
    }
}
