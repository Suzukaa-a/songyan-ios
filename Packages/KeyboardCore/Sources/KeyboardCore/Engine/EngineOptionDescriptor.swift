import Foundation

/// A verified schema switch or native radio-group member, with labels from its schema.
public struct EngineOptionDescriptor: Identifiable, Equatable, Sendable {
    public let resourceID: String
    public let schemaID: String
    public let name: String
    public let title: String
    public let disabledLabel: String
    public let enabledLabel: String
    public let choiceGroup: [String]
    public let choiceLabel: String?
    /// The OpenCC config this switch applies when it is on, exactly as the schema declares it
    /// (e.g. `s2t.json`); nil for a switch that converts no script. Read at parse time so the
    /// input language never has to infer a converter from a presentation label.
    public let declaredConversion: String?
    /// The bundled scheme's script state this member stands for, when the scheme's declaration is
    /// the bundled one; the UI words only these, so a scheme an author words itself is untouched.
    public let knownScriptState: BuiltinScriptState?
    /// A switch or group the schema declares for itself (`extended_charset`, `ascii_punct`), not one of
    /// the script, emoji or full-width switches the keyboard words itself.
    public let isDeclared: Bool
    /// The two labels are the schema's own state labels, not the generic 关闭/开启.
    public let statesWorded: Bool
    public var id: String { name }

    public init(
        resourceID: String, schemaID: String, name: String, title: String,
        disabledLabel: String, enabledLabel: String,
        choiceGroup: [String] = [], choiceLabel: String? = nil,
        declaredConversion: String? = nil, knownScriptState: BuiltinScriptState? = nil,
        isDeclared: Bool = false, statesWorded: Bool = false
    ) {
        self.resourceID = resourceID
        self.schemaID = schemaID
        self.name = name
        self.title = title
        self.disabledLabel = disabledLabel
        self.enabledLabel = enabledLabel
        self.choiceGroup = choiceGroup
        self.choiceLabel = choiceLabel
        self.declaredConversion = declaredConversion
        self.knownScriptState = knownScriptState
        self.isDeclared = isDeclared
        self.statesWorded = isDeclared || statesWorded
    }
}

public struct EngineOptionState: Identifiable, Equatable, Sendable {
    public let descriptor: EngineOptionDescriptor
    public let value: Bool
    public var id: String { descriptor.id }
    public init(descriptor: EngineOptionDescriptor, value: Bool) {
        self.descriptor = descriptor
        self.value = value
    }
}
