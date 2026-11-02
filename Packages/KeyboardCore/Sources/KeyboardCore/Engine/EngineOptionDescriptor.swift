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
    public var id: String { name }

    public init(
        resourceID: String, schemaID: String, name: String, title: String,
        disabledLabel: String, enabledLabel: String,
        choiceGroup: [String] = [], choiceLabel: String? = nil
    ) {
        self.resourceID = resourceID
        self.schemaID = schemaID
        self.name = name
        self.title = title
        self.disabledLabel = disabledLabel
        self.enabledLabel = enabledLabel
        self.choiceGroup = choiceGroup
        self.choiceLabel = choiceLabel
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
