import Foundation

/// Whether the keyboard splits into two halves on a wide surface. A layout carries its own split
/// (the merged pads split automatically); this device setting can switch splitting on for every
/// layout or off for all of them. The Android keyboard has the same three choices.
public enum KeyboardSplitMode: String, CaseIterable, Sendable {
    /// Each layout's own setting decides.
    case layout
    /// Every layout without a split of its own splits on a wide surface. A layout its author set
    /// not to split keeps that, and the 9-key keyboard never splits: its wide-screen form is the
    /// candidates beside it.
    case on
    /// No layout splits.
    case off

    public static func resolve(_ stored: String?) -> Self { stored.flatMap(Self.init(rawValue:)) ?? .layout }

    /// The split that applies to a layout's own `split` under this mode, nil for an unsplit keyboard.
    /// `isPhoneKeypad` is the 9-key shell, which this mode never splits.
    public func applied(to split: LayoutSplitConfiguration?, isPhoneKeypad: Bool = false) -> LayoutSplitConfiguration? {
        switch self {
        case .off: return nil
        case .layout: return split
        case .on:
            if isPhoneKeypad { return split }
            guard let split else { return LayoutSplitConfiguration() }
            return split
        }
    }
}
