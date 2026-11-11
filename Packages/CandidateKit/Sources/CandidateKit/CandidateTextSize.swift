/// A device-level scale for candidate text, applied on top of the skin's `typography.candidateSize`.
/// The ids and factors match the Android keyboard so a skin reads the same on both; an unknown or
/// missing stored id resolves to `.standard`.
public enum CandidateTextSize: String, CaseIterable, Sendable {
    case small
    case standard
    case large
    case extraLarge = "extra_large"

    public static let defaultValue: CandidateTextSize = .standard

    public static func resolve(_ storedValue: String?) -> CandidateTextSize {
        storedValue.flatMap(Self.init(rawValue:)) ?? defaultValue
    }

    public var factor: Double {
        switch self {
        case .small: return 0.85
        case .standard: return 1
        case .large: return 1.15
        case .extraLarge: return 1.3
        }
    }

    /// Candidate words and the comment/secondary text beside them scale by the same factor.
    public func scaled(_ typography: CandidateTypography) -> CandidateTypography {
        CandidateTypography(
            candidateSize: typography.candidateSize * factor,
            secondarySize: typography.secondarySize * factor)
    }
}
