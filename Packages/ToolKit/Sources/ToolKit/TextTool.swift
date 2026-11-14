/// What a tool is called and how the host refers to it. The title is data the
/// user sees, not a string this package localizes.
public struct ToolIdentity: Equatable, Hashable, Sendable {
    public let id: String
    public let title: String

    public init(id: String, title: String) {
        self.id = id
        self.title = title
    }
}

/// Capabilities a tool may require or a host may provide.
public struct ToolCapabilities: OptionSet, Sendable {
    public let rawValue: Int

    public init(rawValue: Int) {
        self.rawValue = rawValue
    }

    public static let text = ToolCapabilities(rawValue: 1 << 0)
    public static let audio = ToolCapabilities(rawValue: 1 << 1)
}

/// One implementation of the keyboard's single "tool" interface: a text script,
/// a built-in module or an external implementation. A tool declares what it
/// needs; the host supplies what it has, and the session compares the two.
public protocol TextTool: Sendable {
    var identity: ToolIdentity { get }
    var requiredCapabilities: ToolCapabilities { get }
    /// The tool's own wall-clock budget in seconds, when it knows better than the host
    /// (a script that declares a long timeout for a slow model). nil uses the host limit.
    var runTimeout: Double? { get }
    func run(input: ToolInput) async throws -> [String]
}

extension TextTool {
    public var runTimeout: Double? { nil }
}
