import Foundation

/// Whether the keyboard splits into two halves on a wide surface. A layout carries its own split
/// (the merged pads split automatically); this device setting can switch splitting on for every
/// layout or off for all of them. The Android keyboard has the same three choices.
public enum KeyboardSplitMode: String, CaseIterable, Sendable {
    /// Each layout's own setting decides.
    case layout
    /// Every layout splits on a wide surface, at its own row cuts when it has them.
    case on
    /// No layout splits.
    case off

    public static func resolve(_ stored: String?) -> Self { stored.flatMap(Self.init(rawValue:)) ?? .layout }

    /// The split that applies to a layout's own `split` under this mode, nil for an unsplit keyboard.
    public func applied(to split: LayoutSplitConfiguration?) -> LayoutSplitConfiguration? {
        switch self {
        case .off: return nil
        case .layout: return split
        case .on:
            guard var split else { return LayoutSplitConfiguration() }
            if split.activation == .off { split.activation = .automatic }
            return split
        }
    }
}
