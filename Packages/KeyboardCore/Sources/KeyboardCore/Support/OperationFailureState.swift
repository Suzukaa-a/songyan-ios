import Foundation

/// Structured description of whether state changed when an operation failed (pure value).
///
/// The failure page must describe the state truthfully rather than always claim "unchanged".
/// The installer is an atomic transaction (an error before commit keeps the previous active
/// generation), so "not committed" is provable; but some failures happen after the commit
/// (e.g. the install succeeded and only the source record write failed), where the content is
/// saved but not applied. The two cases must be distinguished and given actionable steps.
public enum OperationFailureState: Equatable, Sendable {
    /// Transaction not committed: neither installed content nor the current keyboard changed (provable with the atomic installer).
    case nothingCommitted
    /// Installed content is saved but the current keyboard is unchanged (not yet applied, or only a secondary record write failed).
    case installedNotApplied
    /// State cannot be proven: claim nothing and ask the user to reload.
    case unknown

    /// Status line (plain wording, no internal terms).
    public var stateLine: String {
        switch self {
        case .nothingCommitted:
            return String(localized: "core.status.nothingCommitted", bundle: .module)
        case .installedNotApplied:
            return String(localized: "core.status.installedNotApplied", bundle: .module)
        case .unknown:
            return String(localized: "core.status.unknown", bundle: .module)
        }
    }

    /// Next-step hint; `nil` means no extra hint is needed.
    public var nextStep: String? {
        switch self {
        case .nothingCommitted:
            return String(localized: "core.status.retryOrOtherFile", bundle: .module)
        case .installedNotApplied:
            return String(
                format: String(localized: "core.status.retryOrStartUsing", bundle: .module),
                UserTerminology.useThisInputScheme)
        case .unknown:
            return String(localized: "core.status.reload", bundle: .module)
        }
    }
}
