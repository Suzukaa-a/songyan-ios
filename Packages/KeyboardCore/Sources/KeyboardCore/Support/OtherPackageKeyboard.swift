import Foundation

/// One extra item of the keyboard menu: a keyboard of another input scheme package, or the
/// bundled built-in input. Built from the shared record; the keyboard extension only lists it.
public struct OtherPackageKeyboard: Equatable, Sendable, Identifiable {
    public enum Target: Equatable, Sendable {
        /// A package with a kept generation: activate it, then select the keyboard.
        case keptPackage(rosterKey: String)
        /// The recorded package, while the built-in input is running: turn it back on, then select the keyboard.
        case recordedPackage
        /// The bundled built-in input.
        case builtin
    }

    public let target: Target
    /// Nil for the built-in input.
    public let keyboard: PublishedKeyboard?
    public let packageName: String
    /// Input method plus layout, like the current package's entries.
    public let title: String

    public init(target: Target, keyboard: PublishedKeyboard?, packageName: String, title: String) {
        self.target = target
        self.keyboard = keyboard
        self.packageName = packageName
        self.title = title
    }

    /// Menu cap identity; the prefix keeps it apart from the current package's keyboards.
    public static let capIDPrefix = "other-keyboard:"

    public var id: String {
        switch target {
        case .builtin: return Self.capIDPrefix + "builtin"
        case .keptPackage(let key): return Self.capIDPrefix + "\(key)|\(keyboard?.id ?? "")"
        case .recordedPackage: return Self.capIDPrefix + "recorded|\(keyboard?.id ?? "")"
        }
    }
}
