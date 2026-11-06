import Foundation

/// The three tool examples that ship with the app.
///
/// The store seeds them on first use and keeps only their enable, order and pin settings; it
/// never copies or edits a built-in. The conversion example takes its OpenCC config from the
/// caller because the interface knows the input language; the package must not read an engine or
/// a profile to choose one.
public enum BuiltinToolDefinitions {
    public static let simplificationID = "builtin-simplify"
    public static let halfwidthID = "builtin-halfwidth"
    public static let uppercaseID = "builtin-uppercase"

    /// Traditional Chinese for Taiwan. Used when the caller has no input-language fact; the
    /// interface passes s2t or t2s instead when the input language asks for them.
    public static let defaultSimplificationConfig: OpenCCToolConfig = .s2twp

    public static func simplification(
        config: OpenCCToolConfig = defaultSimplificationConfig
    ) -> ToolDefinition {
        ToolDefinition(
            id: simplificationID,
            name: [
                "zh-Hans": "繁简转换",
                "zh-Hant": "繁簡轉換",
                "ja": "簡繁変換",
                "en": "Convert Chinese",
            ],
            steps: [.opencc(config: config)])
    }

    public static func halfwidth() -> ToolDefinition {
        ToolDefinition(
            id: halfwidthID,
            name: [
                "zh-Hans": "全角转半角",
                "zh-Hant": "全形轉半形",
                "ja": "全角を半角に",
                "en": "Convert to halfwidth",
            ],
            steps: [.width(mode: .toHalf)])
    }

    public static func uppercase() -> ToolDefinition {
        ToolDefinition(
            id: uppercaseID,
            name: [
                "zh-Hans": "英文大写",
                "zh-Hant": "英文大寫",
                "ja": "英字を大文字に",
                "en": "Uppercase",
            ],
            steps: [.caseTransform(mode: .upper)])
    }

    /// The examples in list order: conversion, width, case.
    public static func all(
        simplificationConfig: OpenCCToolConfig = defaultSimplificationConfig
    ) -> [ToolDefinition] {
        [simplification(config: simplificationConfig), halfwidth(), uppercase()]
    }
}
