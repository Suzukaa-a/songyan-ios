import Darwin
import Foundation
import KeyboardCore
import LayoutKit

/// Deterministic library snapshot at the factory's I/O boundary.
enum KeyboardPageDraftProbe {
    static func authoredCategories() async throws -> [KeyboardPageCategory] {
        [
            KeyboardPageCategory(
                id: "common", name: "常用",
                keys: [
                    LayoutKey(label: "，", action: .init(.literal, value: "，"))
                ])
        ]
    }

    static func numericCopyName(marks: KeyboardNumericMarks, form: KeyboardNumericForm) -> String {
        "副本"
    }

    /* PRODUCTION_COPY_FUNCTION */

    /* PRODUCTION_EDITABLE_DRAFT_FUNCTION */
}

@main
struct Probe {
    static var failures: [String] = []

    static func check(_ condition: Bool, _ message: String) {
        if !condition { failures.append(message) }
    }

    static func keys(_ rows: [LayoutRow]) -> [LayoutKey] {
        rows.flatMap(\.keys)
    }

    static func main() async throws {
        var modified = KeyboardPagePresets.symbolsSystem
        modified.name = "作者符号页"
        let authorKey = LayoutKey(
            label: "笑脸", secondaryLabel: "副", width: 2.5,
            action: LayoutAction(.literal, value: "☺", asciiValue: ":)"),
            longPress: [LayoutOption(label: "长按", action: LayoutAction(.literal, value: "开心"))],
            titleMode: .custom)
        var firstRow = modified.rows[0].keys
        firstRow[0] = authorKey
        modified.rows[0] = LayoutRow(keys: firstRow)
        modified.split = LayoutSplitConfiguration(
            activation: .always, rowBreaks: [3, 3], gapFraction: 0.4)

        let rowsCopy = try await KeyboardPageDraftProbe.copy(modified, presentation: .rows)
        check(rowsCopy.id != modified.id, "copy gets a new id")
        check(rowsCopy.name == "作者符号页 副本", "copy keeps the author page name")
        check(rowsCopy.symbolPresentation == .rows, "automatic symbol page copies as authored rows")
        check(rowsCopy.defaultSymbolMarks == nil, "copy without a chosen branch follows the keyboard")
        let copiedKey = keys(rowsCopy.rows).first { $0.label == "笑脸" }
        check(copiedKey?.action.value == "☺", "author literal value survives")
        check(copiedKey?.action.asciiValue == ":)", "author ASCII value survives")
        check(copiedKey?.width == 2.5, "author width survives")
        check(copiedKey?.secondaryLabel == "副", "author secondary label survives")
        check(copiedKey?.titleMode == .custom, "author title mode survives")
        check(copiedKey?.longPress?.first?.label == "长按", "author long press survives")
        check(copiedKey?.longPress?.first?.action.value == "开心", "author long press action survives")
        check(rowsCopy.split?.rowBreaks == [3, 3], "author split cuts survive")
        check(rowsCopy.split?.gapFraction == 0.4, "author split gap survives")
        check(rowsCopy.split?.activation == .always, "author split activation survives")
        check(modified.rows[0].keys[0].label == "笑脸", "the source page is not mutated")

        let untouched = KeyboardPagePresets.symbolsSystem
        let asciiCopy = try await KeyboardPageDraftProbe.copy(
            untouched, presentation: .rows, numericMarks: .ascii)
        let asciiExpected = KeyboardPagePresets.symbolRowsPage(ascii: true).materialized(numericMarks: .ascii)
        check(
            asciiCopy.rows == asciiExpected.rows,
            "untouched automatic copy takes the ASCII label and long-press snapshot")
        check(asciiCopy.defaultSymbolMarks == .ascii, "untouched ASCII copy pins the ASCII branch")
        check(asciiCopy.rows != untouched.rows, "ASCII snapshot differs from the Chinese canonical rows")

        let chineseCopy = try await KeyboardPageDraftProbe.copy(
            untouched, presentation: .rows, numericMarks: .chinese)
        check(chineseCopy.defaultSymbolMarks == .chinese, "explicit Chinese copy pins Chinese")
        check(
            chineseCopy.rows
                == KeyboardPagePresets.symbolRowsPage(ascii: false).materialized(numericMarks: .chinese).rows,
            "untouched Chinese copy matches the canonical Chinese rows")

        let followingCopy = try await KeyboardPageDraftProbe.copy(untouched, presentation: .rows)
        check(followingCopy.defaultSymbolMarks == nil, "a copy without a chosen branch keeps following the input")
        let followingNumeric = try await KeyboardPageDraftProbe.copy(KeyboardPagePresets.numericAutomatic)
        check(followingNumeric.defaultSymbolMarks == nil, "an automatic 123 copy never pins the Chinese marks")

        // Editing an automatic page that pins a branch must keep that author choice.
        var explicitAutomatic = KeyboardPagePresets.numericAutomatic
        explicitAutomatic.defaultSymbolMarks = .ascii
        let explicitDraft = try await KeyboardPageDraftProbe.editableDraft(explicitAutomatic)
        check(explicitDraft.defaultSymbolMarks == .ascii, "editing keeps an explicit automatic branch")
        check(
            explicitDraft.rows == explicitAutomatic.materialized(numericMarks: .ascii).rows,
            "an explicit branch materializes with its own snapshot")
        var explicitSymbols = KeyboardPagePresets.symbolsSystem
        explicitSymbols.defaultSymbolMarks = .ascii
        let symbolsDraft = try await KeyboardPageDraftProbe.editableDraft(explicitSymbols)
        check(symbolsDraft.defaultSymbolMarks == .ascii, "editing keeps an explicit symbol branch")
        let followDraft = try await KeyboardPageDraftProbe.editableDraft(KeyboardPagePresets.numericAutomatic)
        check(followDraft.defaultSymbolMarks == nil, "editing a follow-input page keeps nil")
        let phoneSymbols = try await KeyboardPageDraftProbe.editableDraft(
            KeyboardPagePresets.symbolsSystem, numericForm: .phoneDigitPad)
        check(phoneSymbols.symbolPresentation == .categorized, "phone symbol editor matches the live category grid")
        check(phoneSymbols.categories?.first?.id == "common", "phone editor takes the displayed library categories")
        check(phoneSymbols.chrome?.trailingSpansBottom == true, "phone editor keeps the live full-height editing rail")
        let rowSymbols = try await KeyboardPageDraftProbe.editableDraft(KeyboardPagePresets.symbolsSystem)
        check(
            rowSymbols.chrome?.bottom.contains { $0.action.type == .symbolLibrary } == true,
            "the native More key stays editable instead of becoming a comma")

        if failures.isEmpty {
            print("keyboard-page-drafts: ok")
        } else {
            for failure in failures { print("FAIL: " + failure) }
            Darwin.exit(1)
        }
    }
}
