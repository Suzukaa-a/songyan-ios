import Foundation

/// Keeps the keycaps readable as keys over the skin's background, the same rule the Android
/// keyboard applies in its own `KeyContrast`: a letter key stands out from the background, a
/// function key from both. Only the fills move, and only as far as needed, so a skin that already
/// separates is left exactly as authored. Every sample of the background counts, so a gradient keeps
/// the keys apart at both ends.
///
/// Android gives way on the background when the letter key is already at the end of the scale (a
/// white key on a near-white background). Here the background may be a picture, so instead of
/// recolouring it the keyboard lays a faint veil over it, returned by `separate`.
public enum KeyContrast {
    static let keyAgainstBackground = 1.3
    static let functionAgainstKey = 1.25
    static let functionAgainstBackground = 1.2
    /// Relative luminance above which a background counts as light (about L* 50).
    static let lightBackground = 0.18

    /// Moves `colors["key"]` and `colors["control"]` apart from `background` and each other; returns
    /// the veil (a colour with alpha) to lay over the background, or nil when none is needed.
    @discardableResult
    public static func separate(_ colors: inout [String: SkinColor], from background: [SkinColor]) -> SkinColor? {
        guard var key = colors["key"], var function = colors["control"], !background.isEmpty,
            key.alpha >= 1, function.alpha >= 1
        else { return nil }
        var samples = background
        var veil: SkinColor?
        func worst(_ color: SkinColor) -> Double { samples.map { color.contrast(on: $0) }.min() ?? 21 }
        let keyLighter = luminance(key) >= luminance(SkinColor.average(background))
        if worst(key) < keyAgainstBackground {
            key = push(key, keyAgainstBackground, towardsWhite: keyLighter, measure: worst)
        }
        if worst(key) < keyAgainstBackground {
            // The key is at the end of the scale: the background gives way under a veil.
            let end = keyLighter ? "000000" : "FFFFFF"
            let original = samples
            let alpha = least(keyAgainstBackground) { alpha in
                original.map { key.contrast(on: tint(end, alpha).composited(over: $0)) }.min() ?? 21
            }
            veil = tint(end, alpha)
            samples = original.map { tint(end, alpha).composited(over: $0) }
        }
        if function.contrast(on: key) < functionAgainstKey {
            // A function key keeps the side of the letter key it was authored on.
            let lighter = luminance(function) > luminance(key)
            function = push(function, functionAgainstKey, towardsWhite: lighter) { $0.contrast(on: key) }
        }
        if worst(function) < functionAgainstBackground {
            // A light keyboard takes its function keys darker than the background, as the system does;
            // a dark one lighter. They must still part from the letter key afterwards.
            let towardsWhite = luminance(SkinColor.average(samples)) <= lightBackground
            function = push(function, functionAgainstBackground, towardsWhite: towardsWhite) {
                min(worst($0) / functionAgainstBackground, $0.contrast(on: key) / functionAgainstKey)
                    * functionAgainstBackground
            }
        }
        colors["key"] = key
        colors["control"] = function
        return veil
    }

    private static func tint(_ end: String, _ alpha: Double) -> SkinColor {
        SkinColor(hex: "#" + end + String(format: "%02X", Int((alpha * 255).rounded())))!
    }

    /// The least amount in 0...1 for which `measure` reaches `minimum` (1 when nothing does).
    private static func least(_ minimum: Double, measure: (Double) -> Double) -> Double {
        if measure(1) < minimum { return 1 }
        var low = 0.0
        var high = 1.0
        for _ in 0..<12 {
            let mid = (low + high) / 2
            if measure(mid) >= minimum { high = mid } else { low = mid }
        }
        return high
    }

    private static func luminance(_ color: SkinColor) -> Double {
        // contrast(on: black) = (L + 0.05) / 0.05.
        color.contrast(on: SkinColor(hex: "#000000")!) * 0.05 - 0.05
    }

    /// Moves `color` towards white or black, the least that brings `measure` to `minimum`, or all
    /// the way when even the end does not.
    private static func push(
        _ color: SkinColor, _ minimum: Double, towardsWhite: Bool, measure: (SkinColor) -> Double
    ) -> SkinColor {
        let end = towardsWhite ? "FFFFFF" : "000000"
        let amount = least(minimum) { measure(tint(end, $0).composited(over: color)) }
        return tint(end, amount).composited(over: color)
    }
}

extension SkinColor {
    /// The mean of `colors` (opaque), for judging translucent fills over a background of several colours.
    public static func average(_ colors: [SkinColor]) -> SkinColor {
        let n = Double(max(1, colors.count))
        func channel(_ value: (SkinColor) -> Double) -> Int {
            Int((colors.map(value).reduce(0, +) / n * 255).rounded())
        }
        return SkinColor(
            hex: String(format: "#%02X%02X%02X", channel(\.red), channel(\.green), channel(\.blue)))!
    }
}
