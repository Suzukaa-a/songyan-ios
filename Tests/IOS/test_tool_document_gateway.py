"""ToolKit document gateway contract over the real UITextDocumentProxy surface.

The probe compiles the production gateway and ToolKit sources for macOS and drives
them through a strict double of the proxy surface: the double implements only what
UITextDocumentProxy provides (contexts, selection, privacy, insertText,
deleteBackward) and counts the calls. This is a call-contract test, not an
end-to-end run inside the keyboard extension; the live simulator text field still
needs its own verification.
"""
import sys
import unittest

from swift_probe import ROOT, run, scratch_directory

TOOLKIT = ROOT / "Packages/ToolKit/Sources/ToolKit"
EXTENSION = ROOT / "Apps/KeyboardExtension"
GATEWAY_SOURCES = (EXTENSION / "ToolDocumentProxy.swift", EXTENSION / "ToolDocumentGateway.swift")

PROBE = r'''
import Foundation

// The real panel protocol lives in the SwiftUI panel file, which cannot be compiled
// for macOS. The probe repeats its contract so the production driver in
// ToolDocumentGateway.swift can compile; no driver logic is stubbed.
@MainActor
protocol ToolPanelDriving: AnyObject {
    var entries: [ToolPanelEntry] { get }
    var phase: ToolPhase { get }
    var preview: ToolPreview? { get }
    var writeBlock: ToolWriteBlock? { get }
    var undoWindow: Double? { get }
    var lastToolTitle: String? { get }
    func run(_ identity: ToolIdentity)
    func chooseResult(_ index: Int)
    func retry()
    func cancel()
    func copy() -> String?
    func replace()
    func insert()
    func undo()
    func dismiss() -> ToolDismissOutcome
}

struct FakeTool: TextTool {
    let identity = ToolIdentity(id: "probe", title: "Probe")
    let requiredCapabilities: ToolCapabilities = .text
    func run(input: ToolInput) async throws -> [String] { ["unused"] }
}

final class StrictProxy: ToolTextDocumentProxy {
    var documentIdentity: UUID? = UUID(uuidString: "00000000-0000-0000-0000-00000000A001")
    var characters: [Character] = []
    var caret = 0
    var selection: Range<Int>?
    var isSecureTextEntry: Bool? = false
    private(set) var textReads = 0
    private(set) var secureTextReads = 0
    private(set) var insertions: [String] = []
    private(set) var deletions = 0

    func setText(_ text: String) {
        characters = Array(text)
        caret = characters.count
        selection = nil
    }

    var text: String { String(characters) }

    var textBeforeCaret: String? {
        if isSecureTextEntry == true { secureTextReads += 1 }
        textReads += 1
        return String(characters[0..<min(caret, characters.count)])
    }

    var textAfterCaret: String? {
        if isSecureTextEntry == true { secureTextReads += 1 }
        textReads += 1
        return String(characters[min(caret, characters.count)...])
    }

    var selectedText: String? {
        if isSecureTextEntry == true { secureTextReads += 1 }
        textReads += 1
        guard let selection else { return nil }
        return String(characters[selection])
    }

    func insertText(_ text: String) {
        insertions.append(text)
        let inserted = Array(text)
        if let selection {
            characters.replaceSubrange(selection, with: inserted)
            caret = selection.lowerBound + inserted.count
            self.selection = nil
        } else {
            characters.insert(contentsOf: inserted, at: caret)
            caret += inserted.count
        }
    }

    func deleteBackward() {
        deletions += 1
        if let selection {
            characters.removeSubrange(selection)
            caret = selection.lowerBound
            self.selection = nil
        } else if caret > 0 {
            characters.remove(at: caret - 1)
            caret -= 1
        }
    }
}

var failures: [String] = []

func check(_ condition: Bool, _ name: String, _ detail: String = "") {
    if condition {
        print("PASS \(name)")
    } else {
        failures.append(name + (detail.isEmpty ? "" : ": " + detail))
        print("FAIL \(name) \(detail)")
    }
}

func makeGateway(
    _ proxy: StrictProxy, inputLimit: Int = 8,
    capabilities: ToolDocumentCapabilities = [.replacePrecedingTail]
) -> ToolDocumentGateway {
    ToolDocumentGateway(
        proxy: proxy, sessionID: UUID().uuidString,
        limits: ToolLimits(
            maximumInputUnits: inputLimit, runTimeout: 5, undoWindow: nil, maximumResults: 4),
        capabilities: capabilities)
}

func makeProductionGateway(_ proxy: StrictProxy, inputLimit: Int = 8) -> ToolDocumentGateway {
    ToolDocumentGateway(
        proxy: proxy, sessionID: UUID().uuidString,
        limits: ToolLimits(
            maximumInputUnits: inputLimit, runTimeout: 5, undoWindow: nil, maximumResults: 4))
}

func run(_ gateway: ToolDocumentGateway, results: [String], now: Double = 0) -> ToolRunToken? {
    guard case .run(let request) = gateway.start(tool: FakeTool(), now: now) else { return nil }
    _ = gateway.complete(results, token: request.runToken, now: now)
    return request.runToken
}

// 1. The production gateway declares only capabilities with real-proxy evidence.
// The deletion path (replacePrecedingTail) is not verified for a live field yet,
// so it stays off; neither capability may be assumed.
check(
    ToolDocumentGateway.capabilities.contains(.replacePrecedingTail),
    "capabilitiesDeclareVerifiedTailReplace")
check(
    !ToolDocumentGateway.capabilities.contains(.insertPreservingSelection),
    "capabilitiesDoNotClaimSelectionPreservingInsert")

// 2. A password field is never read, not even to learn its privacy.
do {
    let proxy = StrictProxy()
    proxy.isSecureTextEntry = true
    proxy.setText("secret")
    let gateway = makeGateway(proxy)
    let snapshot = gateway.snapshot()
    check(snapshot?.privacy == .password, "passwordSnapshot")
    check(proxy.secureTextReads == 0 && proxy.textReads == 0, "passwordNeverRead")
    let effect = gateway.start(tool: FakeTool(), now: 0)
    check(effect == .none, "passwordStartRefused")
    check(gateway.phase == .failed(.unavailable(.secureEntry)), "passwordUnavailableReason")
}

// 3. A normal field exposes its caret text, not a selection.
do {
    let proxy = StrictProxy()
    proxy.setText("hello")
    let gateway = makeGateway(proxy)
    let snapshot = gateway.snapshot()
    check(snapshot?.selectedText == nil, "noSelection")
    check(snapshot?.textBeforeCaret == "hello", "caretText")
    check(snapshot?.privacy == .normal, "normalPrivacy")
}

// 4. Truncated caret tail: replace the processed characters, then undo restores.
do {
    let proxy = StrictProxy()
    proxy.setText("abcdef")
    let gateway = makeGateway(proxy, inputLimit: 4)
    _ = run(gateway, results: ["XYZ"])
    let start = gateway.replace(now: 2)
    if case .requested(let request) = start {
        check(request.replacedText == "cdef", "truncatedReplacedText")
        check(request.requiresSubrange, "truncatedRequiresSubrange")
        check(gateway.apply(start, at: 2), "truncatedApply")
        check(proxy.text == "abXYZ", "truncatedWriteResult", proxy.text)
        check(proxy.deletions == 4, "truncatedDeleteCount", "\(proxy.deletions)")
        check(gateway.currentWrittenText() == "XYZ", "writtenTextReadBack")
        let undo = gateway.undo(now: 3)
        check(gateway.applyUndo(undo, at: 3), "truncatedUndoApply")
        check(proxy.text == "abcdef", "truncatedUndoResult", proxy.text)
    } else {
        check(false, "truncatedReplaceRequested", "\(start)")
    }
}

// 5. Deletion counts follow characters, not UTF-16 units.
do {
    let proxy = StrictProxy()
    proxy.setText("ae\u{301}b")  // a, e+combining acute (one character), b
    let gateway = makeGateway(proxy, inputLimit: 3)
    _ = run(gateway, results: ["X"])
    let start = gateway.replace(now: 2)
    let before = proxy.deletions
    if case .requested = start {
        check(gateway.apply(start, at: 2), "combiningApply")
        check(proxy.deletions - before == 2, "combiningDeletesTwoCharacters", "\(proxy.deletions - before)")
        check(proxy.text == "aX", "combiningWriteResult", proxy.text)
    } else {
        check(false, "combiningReplaceRequested", "\(start)")
    }

    let emoji = StrictProxy()
    emoji.setText("a\u{1F600}")
    let emojiGateway = makeGateway(emoji, inputLimit: 2)
    _ = run(emojiGateway, results: ["E"])
    let emojiStart = emojiGateway.replace(now: 2)
    let emojiDeletions = emoji.deletions
    if case .requested = emojiStart {
        check(emojiGateway.apply(emojiStart, at: 2), "emojiApply")
        check(emoji.deletions - emojiDeletions == 1, "emojiDeletesOneCharacter", "\(emoji.deletions - emojiDeletions)")
        check(emoji.text == "aE", "emojiWriteResult", emoji.text)
    } else {
        check(false, "emojiReplaceRequested", "\(emojiStart)")
    }
}

// 6. An empty result deletes the processed range; undo restores the original.
do {
    let proxy = StrictProxy()
    proxy.setText("abc")
    let gateway = makeGateway(proxy)
    _ = run(gateway, results: [""])
    let start = gateway.replace(now: 2)
    if case .requested(let request) = start {
        check(request.text.isEmpty, "emptyResultWrite")
        check(gateway.apply(start, at: 2), "emptyApply")
        check(proxy.text.isEmpty, "emptyWriteResult", proxy.text)
        let undo = gateway.undo(now: 3)
        check(gateway.applyUndo(undo, at: 3), "emptyUndoApply")
        check(proxy.text == "abc", "emptyUndoRestoresOriginal", proxy.text)
    } else {
        check(false, "emptyReplaceRequested", "\(start)")
    }
}

// 7. A truncated selection is never replaced; the preview is kept.
do {
    let proxy = StrictProxy()
    proxy.setText("abcdef")
    proxy.selection = 0..<6
    let gateway = makeGateway(proxy, inputLimit: 4)
    _ = run(gateway, results: ["X"])
    let start = gateway.replace(now: 2)
    check(start == .blocked(.unsupportedPartialReplacement), "truncatedSelectionBlocked", "\(start)")
    check(proxy.text == "abcdef", "truncatedSelectionUnchanged", proxy.text)
    check(gateway.preview != nil, "truncatedSelectionKeepsPreview")
}

// 8. Inserting while a selection is active needs an unverified capability.
do {
    let proxy = StrictProxy()
    proxy.setText("abc")
    proxy.selection = 0..<3
    let gateway = makeGateway(proxy)
    _ = run(gateway, results: ["OUT"])
    let start = gateway.insert(now: 2)
    check(start == .blocked(.unsupportedInsertion), "selectionInsertBlocked", "\(start)")
    check(proxy.text == "abc", "selectionInsertUnchanged", proxy.text)
    check(gateway.preview != nil, "selectionInsertKeepsPreview")
}

// 9. Undo refuses to overwrite text the user typed after the write.
do {
    let proxy = StrictProxy()
    proxy.setText("abc")
    proxy.selection = 0..<3
    let gateway = makeGateway(proxy)
    _ = run(gateway, results: ["OUT"])
    let start = gateway.replace(now: 2)
    if case .requested = start {
        check(gateway.apply(start, at: 2), "editedApply")
        check(proxy.text == "OUT", "editedWriteResult", proxy.text)
        proxy.insertText("!")
        check(proxy.text == "OUT!", "editedUserInput", proxy.text)
        let undo = gateway.undo(now: 3)
        check(undo == .blocked(.editedAfterWrite), "editedUndoBlocked", "\(undo)")
        check(proxy.text == "OUT!", "editedTextKept", proxy.text)
    } else {
        check(false, "editedReplaceRequested", "\(start)")
    }
}

// 10. A different field identity refuses the write.
do {
    let proxy = StrictProxy()
    proxy.setText("abc")
    let gateway = makeGateway(proxy)
    _ = run(gateway, results: ["OUT"])
    proxy.documentIdentity = UUID(uuidString: "00000000-0000-0000-0000-00000000A002")
    let start = gateway.replace(now: 2)
    check(start == .blocked(.documentChanged), "identityChangeBlocked", "\(start)")
    check(proxy.text == "abc", "identityChangeUnchanged", proxy.text)
}

// 11. A selection gained after the preview must not turn a caret write into a
// selection replacement: the reviewer's abcdef/limit4 case used to write XYZf.
do {
    let proxy = StrictProxy()
    proxy.setText("abcdef")
    let gateway = makeGateway(proxy, inputLimit: 4)
    _ = run(gateway, results: ["XYZ"])
    let start = gateway.replace(now: 2)
    proxy.selection = 3..<5  // "de", added after the preview
    check(!gateway.apply(start, at: 2), "selectionGainedAfterPreviewRefused")
    check(proxy.text == "abcdef", "selectionGainedTextKept", proxy.text)
    check(gateway.preview != nil, "selectionGainedKeepsPreview")
}

// 12. A field that became a password before apply must not be written.
do {
    let proxy = StrictProxy()
    proxy.setText("abcdef")
    let gateway = makeGateway(proxy, inputLimit: 4)
    _ = run(gateway, results: ["XYZ"])
    let start = gateway.replace(now: 2)
    proxy.isSecureTextEntry = true
    check(!gateway.apply(start, at: 2), "passwordGainedAfterPreviewRefused")
    check(proxy.text == "abcdef", "passwordGainedTextKept", proxy.text)
}

// 13. An empty result leaves no text to anchor undo: typing afterwards refuses.
do {
    let proxy = StrictProxy()
    proxy.setText("abc")
    let gateway = makeGateway(proxy)
    _ = run(gateway, results: [""])
    let start = gateway.replace(now: 2)
    check(gateway.apply(start, at: 2), "emptyThenInputApply")
    check(proxy.text.isEmpty, "emptyThenInputApplied", proxy.text)
    proxy.insertText("Z")
    let undo = gateway.undo(now: 3)
    check(undo == .blocked(.editedAfterWrite), "emptyThenInputUndoBlocked", "\(undo)")
    check(proxy.text == "Z", "emptyThenInputTextKept", proxy.text)
}

// 14. The production gateway fails closed for the unverified deletion path but
// keeps the insertText-only paths available.
do {
    let proxy = StrictProxy()
    proxy.setText("abcdef")
    let gateway = makeProductionGateway(proxy, inputLimit: 4)
    _ = run(gateway, results: ["XYZ"])
    let start = gateway.replace(now: 2)
    check(gateway.apply(start, at: 2), "productionTailReplaceWithVerifiedDeletion")
    check(proxy.text == "abXYZ", "productionTailReplaceResult", proxy.text)

    let selected = StrictProxy()
    selected.setText("abc")
    selected.selection = 0..<3
    let selectionGateway = makeProductionGateway(selected)
    _ = run(selectionGateway, results: ["OUT"])
    check(selectionGateway.apply(selectionGateway.replace(now: 2), at: 2), "productionWholeSelectionReplace")
    check(selected.text == "OUT", "productionWholeSelectionResult", selected.text)

    let inserting = StrictProxy()
    inserting.setText("abc")
    let insertGateway = makeProductionGateway(inserting)
    _ = run(insertGateway, results: ["OUT"])
    check(insertGateway.apply(insertGateway.insert(now: 2), at: 2), "productionCaretInsert")
    check(inserting.text == "abcOUT", "productionCaretInsertResult", inserting.text)
}

// 16. Without the evidence-backed capability no deletion path runs: neither a
// whole preceding replace nor an undo that would delete the written result.
do {
    let proxy = StrictProxy()
    proxy.setText("abc")
    let gateway = makeGateway(proxy, capabilities: [])
    _ = run(gateway, results: ["OUT"])
    let start = gateway.replace(now: 2)
    check(!gateway.apply(start, at: 2), "noCapabilityPrecedingApplyRefused")
    check(proxy.text == "abc", "noCapabilityPrecedingTextKept", proxy.text)
    check(gateway.preview != nil, "noCapabilityPrecedingKeepsPreview")

    let selected = StrictProxy()
    selected.setText("abc")
    selected.selection = 0..<3
    let selectionGateway = makeGateway(selected, capabilities: [])
    _ = run(selectionGateway, results: ["OUT"])
    check(
        selectionGateway.apply(selectionGateway.replace(now: 2), at: 2),
        "noCapabilitySelectionReplaceUsesInsertText")
    check(selected.text == "OUT", "noCapabilitySelectionResult", selected.text)
    let undo = selectionGateway.undo(now: 3)
    check(!selectionGateway.applyUndo(undo, at: 3), "noCapabilityUndoDeletionRefused")
    check(selected.text == "OUT", "noCapabilityUndoTextKept", selected.text)
}

// 15. Undo is position-sensitive: the same suffix at another caret position must
// not pass as "unchanged".
do {
    let proxy = StrictProxy()
    proxy.setText("XYabcd")
    let gateway = makeGateway(proxy, inputLimit: 4)  // trunk tail "abcd" -> "XY"
    _ = run(gateway, results: ["XY"])
    let start = gateway.replace(now: 2)
    if case .requested = start {
        check(gateway.apply(start, at: 2), "positionApply")
        check(proxy.text == "XYXY", "positionWriteResult", proxy.text)
        proxy.caret = 2  // before-caret "XY" has the written suffix at another position
        let movedUndo = gateway.undo(now: 3)
        check(movedUndo == .blocked(.editedAfterWrite), "positionMovedUndoBlocked", "\(movedUndo)")
        check(proxy.text == "XYXY", "positionMovedTextKept", proxy.text)
        proxy.caret = 4
        let backUndo = gateway.undo(now: 3)
        check(gateway.applyUndo(backUndo, at: 3), "positionRestoredUndoApply")
        check(proxy.text == "XYabcd", "positionRestoredResult", proxy.text)
    } else {
        check(false, "positionReplaceRequested", "\(start)")
    }
}

if failures.isEmpty {
    print("PASS all")
    exit(0)
}
print("FAILURES: \(failures.count)")
exit(1)
'''


@unittest.skipUnless(sys.platform == "darwin", "requires macOS Swift")
class ToolDocumentGatewayTests(unittest.TestCase):
    def test_gateway_contract_on_the_real_proxy_surface(self):
        sources = sorted(TOOLKIT.glob("*.swift"))
        self.assertTrue(sources, "ToolKit sources missing")
        texts = [path.read_text(encoding="utf-8") for path in sources]
        texts += [
            path.read_text(encoding="utf-8").replace("import ToolKit\n", "")
            for path in GATEWAY_SOURCES
        ]
        # The gateway source now also holds ToolPanelDriver, which needs the panel's
        # presentation types (ToolPanelEntry) and the ToolPanelDriving contract above.
        presentation = (EXTENSION / "ToolPanelPresentation.swift").read_text(encoding="utf-8")
        texts.append(presentation.replace("import ToolKit\n", ""))
        with scratch_directory("tool-document-gateway") as directory:
            production = directory / "Production.swift"
            production.write_text("\n".join(texts), encoding="utf-8")
            main = directory / "main.swift"
            main.write_text(PROBE, encoding="utf-8")
            binary = directory / "probe"
            run([
                "xcrun", "swiftc", "-swift-version", "5",
                str(production), str(main), "-o", str(binary),
            ])
            output = run([str(binary)])
        self.assertIn("PASS all", output, output)
        self.assertNotIn("FAIL ", output, output)


if __name__ == "__main__":
    unittest.main()
