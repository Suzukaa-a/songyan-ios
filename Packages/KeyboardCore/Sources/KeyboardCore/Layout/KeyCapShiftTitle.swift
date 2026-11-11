/// Which keycap titles follow Shift. Shift turns a code key's lowercase ASCII letter into a capital
/// in every input mode (see `InputSession.tap`), so the keycap shows what the key will type.
/// Only the title changes: the action stays the lowercase `.code`, and key ids never carry case.
public enum KeyCapShiftTitle {
    /// The title to draw. A custom title is the author's own face and a key whose action Shift does
    /// not change (literals, multi-letter codes, digits, controls) keeps its title.
    public static func title(
        _ title: String, action: KeyAction, isCustom: Bool = false, shiftActive: Bool
    ) -> String {
        guard shiftActive, !isCustom, followsShift(action) else { return title }
        return title.uppercased()
    }

    /// Whether Shift changes what this action types: a single ASCII lowercase letter code.
    public static func followsShift(_ action: KeyAction) -> Bool {
        guard case .code(let value) = action, value.utf8.count == 1, let byte = value.utf8.first else { return false }
        return (97...122).contains(byte)
    }
}
