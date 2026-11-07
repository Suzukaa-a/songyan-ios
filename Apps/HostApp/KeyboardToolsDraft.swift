import Foundation
import QuickContentKit

/// The step types the editor can add. The raw value is the file format's own type name, so one
/// spelling serves the menu, the picker and the JSON.
enum KeyboardToolStepType: String, CaseIterable, Identifiable {
    case opencc
    case replace
    case map
    case caseTransform = "case"
    case width
    case template

    var id: String { rawValue }
}

/// One editable step of a tool.
///
/// It mirrors ToolStep but keeps every parameter as a draft value, so the form can hold a
/// half-typed regular expression or a map table that is not finished yet; nothing is validated
/// until the user taps Save.
struct KeyboardToolStepDraft: Equatable, Identifiable {
    let id: UUID
    var type: KeyboardToolStepType
    var openCCConfig: OpenCCToolConfig
    var pattern: String
    var replacement: String
    /// One "original=new" pair per line; the author never types a JSON object.
    var mapLines: String
    var caseMode: ToolStep.CaseMode
    var widthMode: ToolStep.WidthMode

    /// A new step with the parameters a user can start from.
    init(type: KeyboardToolStepType) {
        id = UUID()
        self.type = type
        openCCConfig = .s2twp
        pattern = type == .template ? "「{text}」" : ""
        replacement = ""
        mapLines = ""
        caseMode = .upper
        widthMode = .toHalf
    }

    /// The editable form of a step read from a file.
    init(step: ToolStep) {
        id = UUID()
        type = .opencc
        openCCConfig = .s2twp
        pattern = ""
        replacement = ""
        mapLines = ""
        caseMode = .upper
        widthMode = .toHalf
        switch step {
        case .opencc(let config):
            type = .opencc
            openCCConfig = config
        case .replace(let draftPattern, let draftReplacement):
            type = .replace
            pattern = draftPattern
            replacement = draftReplacement
        case .map(let table):
            type = .map
            mapLines = table.keys.sorted().map { key in
                key + "=" + (table[key] ?? "")
            }.joined(separator: "\n")
        case .caseTransform(let mode):
            type = .caseTransform
            caseMode = mode
        case .width(let mode):
            type = .width
            widthMode = mode
        case .template(let draftPattern):
            type = .template
            pattern = draftPattern
        }
    }

    /// The production step this draft describes, or the reason it cannot describe one.
    func step(stepNumber: Int) throws -> ToolStep {
        switch type {
        case .opencc:
            return .opencc(config: openCCConfig)
        case .replace:
            return .replace(pattern: pattern, replacement: replacement)
        case .caseTransform:
            return .caseTransform(mode: caseMode)
        case .width:
            return .width(mode: widthMode)
        case .template:
            return .template(pattern: pattern)
        case .map:
            return .map(table: try mapTable(stepNumber: stepNumber))
        }
    }

    private func mapTable(stepNumber: Int) throws -> [String: String] {
        var table: [String: String] = [:]
        let lines = mapLines.split(whereSeparator: { $0.isNewline })
        for (offset, rawLine) in lines.enumerated() {
            let line = String(rawLine).trimmingCharacters(in: .whitespaces)
            guard let separator = line.firstIndex(of: "=") else {
                throw KeyboardToolDraftError.mapLine(step: stepNumber, line: offset + 1)
            }
            let key = String(line[line.startIndex..<separator])
                .trimmingCharacters(in: .whitespaces)
            let value = String(line[line.index(after: separator)...])
                .trimmingCharacters(in: .whitespaces)
            guard key.count == 1, !value.isEmpty else {
                throw KeyboardToolDraftError.mapLine(step: stepNumber, line: offset + 1)
            }
            table[key] = value
        }
        return table
    }
}

/// One tool while it is being edited. Kept apart from ToolDefinition so the form can hold values
/// the validator would reject (an empty name, an incomplete step) until the user taps Save.
struct KeyboardToolDraft: Equatable, Identifiable {
    var id: String
    /// Names by language tag; a copy starts with every name the example has.
    var name: [String: String]
    var steps: [KeyboardToolStepDraft]

    init(definition: ToolDefinition) {
        id = definition.id
        name = definition.name
        steps = definition.steps.map(KeyboardToolStepDraft.init(step:))
    }

    /// The name the form edits, in the app's source language.
    ///
    /// Editing it replaces the whole name map: a name the user typed is their own word, and keeping
    /// the example's translations would show a different name in another interface language.
    var editableName: String {
        get { name["zh-Hans"] ?? "" }
        set { name = newValue.isEmpty ? [:] : ["zh-Hans": newValue] }
    }

    /// The tool file this draft describes. Validation runs here so a refused draft names its
    /// problem before anything is written; the store validates again on save.
    func definition() throws -> ToolDefinition {
        var trimmedNames: [String: String] = [:]
        for (tag, value) in name {
            trimmedNames[tag] = value.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        guard !trimmedNames.isEmpty else { throw KeyboardToolDraftError.nameMissing }
        var builtSteps: [ToolStep] = []
        for (offset, stepDraft) in steps.enumerated() {
            builtSteps.append(try stepDraft.step(stepNumber: offset + 1))
        }
        let definition = ToolDefinition(id: id, name: trimmedNames, steps: builtSteps)
        try definition.validate()
        return definition
    }

    mutating func addStep(_ type: KeyboardToolStepType) {
        steps.append(KeyboardToolStepDraft(type: type))
    }
}

/// Why the editor cannot produce a tool file yet. The message is the one sentence the form shows.
enum KeyboardToolDraftError: Error, Equatable, Sendable {
    case nameMissing
    case mapLine(step: Int, line: Int)

    var message: String {
        switch self {
        case .nameMissing:
            return KeyboardToolsCopy.text("keyboardTools.error.nameMissing")
        case .mapLine(let step, let line):
            return String(format: KeyboardToolsCopy.text("keyboardTools.error.mapLine"), step, line)
        }
    }
}
