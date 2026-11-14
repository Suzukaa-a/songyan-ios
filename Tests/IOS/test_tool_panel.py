#!/usr/bin/env python3
"""Behaviour tests for the tool panel presentation.

The panel is a projection of ToolKit's one session: this probe drives the real
ToolSession through idle, running, preview, refused write, wrote and failed states and
asserts what the panel offers the user and what it says — plus that every user-facing
line it can produce exists in the String Catalog with Japanese and Traditional Chinese
translations. It is a public-API behaviour test: no private state is asserted and the
test does not read view source.

Run: python3 Tests/IOS/test_tool_panel.py
"""
import json
import sys
import unittest

from swift_probe import ROOT, run, scratch_directory

TOOLKIT = ROOT / "Packages/ToolKit/Sources/ToolKit"
PANEL = ROOT / "Apps/KeyboardExtension/ToolPanelPresentation.swift"
CATALOG = ROOT / "Resources/Localizable.xcstrings"

PROBE = r'''
import Foundation

struct FixedTool: TextTool {
    let identity: ToolIdentity
    let requiredCapabilities: ToolCapabilities
    func run(input: ToolInput) async throws -> [String] { [] }
}

func document(
    selected: String? = nil, before: String? = "abcdef", id: String = "doc-1",
    privacy: ToolDocumentPrivacy = .normal
) -> ToolDocumentSnapshot {
    ToolDocumentSnapshot(
        documentID: ToolDocumentID(rawValue: id), privacy: privacy, selectedText: selected,
        textBeforeCaret: before)
}

let limits = ToolLimits(maximumInputUnits: 8, runTimeout: 1, undoWindow: 5, maximumResults: 4)
let tool = FixedTool(identity: ToolIdentity(id: "polish", title: "润色"), requiredCapabilities: .text)
let capabilities: ToolDocumentCapabilities = [.replacePrecedingTail, .insertPreservingSelection]

var failures: [String] = []
func check(_ condition: Bool, _ name: String, _ detail: String = "") {
    if condition {
        print("PASS \(name)")
    } else {
        failures.append(name + (detail.isEmpty ? "" : ": " + detail))
        print("FAIL \(name) \(detail)")
    }
}

var keys = Set<String>()
func note(_ message: ToolPanelMessage?) {
    guard let message else { return }
    // A tool's own error text is shown verbatim and is not a catalog entry.
    if case .toolFailed(let text) = message, let text, !text.isEmpty { return }
    keys.insert(message.text)
}

func present(
    _ session: ToolSession, now: Double = 0, lastTitle: String? = nil
) -> ToolPanelPresentation {
    let presentation = ToolPanelPresentation.make(
        phase: session.phase, preview: session.preview, writeBlock: session.writeBlock,
        now: now, undoWindow: session.limits.undoWindow, lastToolTitle: lastTitle)
    note(presentation.message)
    return presentation
}

func startedSession() -> (ToolSession, ToolRunToken) {
    var session = ToolSession(limits: limits, sessionID: "probe")
    let effect = session.start(
        tool: tool, hostCapabilities: .text, document: document(),
        documentCapabilities: capabilities, now: 0)
    guard case .run(let request) = effect else {
        check(false, "startProducedRun", "\(effect)")
        return (session, ToolRunToken(rawValue: ""))
    }
    return (session, request.runToken)
}

// 1. The list is what an idle panel shows.
var idle = ToolSession(limits: limits, sessionID: "probe")
do {
    let presentation = present(idle)
    check(presentation.status == .tools, "idleShowsToolList")
    check(presentation.showsToolList, "idleListVisible")
    check(presentation.actions.isEmpty, "idleNoActions", "\(presentation.actions)")
    check(presentation.message == nil, "idleNoMessage")
}

// 2. A running addon offers cancel and says it is busy.
do {
    var (session, _) = startedSession()
    let presentation = present(session)
    check(presentation.status == .running, "runningStatus")
    check(presentation.actions == [.cancel], "runningOffersCancel", "\(presentation.actions)")
    check(presentation.isBusy, "runningBusy")
}

// 3. Results are the rows; pick one and the check mark follows the user's pick.
do {
    var (session, token) = startedSession()
    _ = session.complete(["甲", "乙"], token: token, now: 0)
    var presentation = present(session)
    check(presentation.status == .preview, "previewStatus")
    check(presentation.toolTitle == "润色", "previewToolTitle", "\(String(describing: presentation.toolTitle))")
    check(presentation.resultRows.map(\.text) == ["甲", "乙"], "previewRows")
    check(presentation.resultRows.first?.isSelected == true, "previewFirstSelected")
    check(presentation.actions == [.copy, .replace, .insert], "previewActions", "\(presentation.actions)")
    _ = session.chooseResult(1)
    presentation = present(session)
    check(presentation.resultRows.last?.isSelected == true, "chosenRowSelected")
    check(presentation.resultRows.first?.isSelected == false, "previousRowUnselected")
}

// 3b. A run on selected text offers no Insert: iOS refuses to insert over a selection.
do {
    var session = ToolSession(limits: limits, sessionID: "probe")
    let effect = session.start(
        tool: tool, hostCapabilities: .text, document: document(selected: "abc"),
        documentCapabilities: capabilities, now: 0)
    if case .run(let request) = effect {
        _ = session.complete(["X"], token: request.runToken, now: 0)
        let presentation = present(session)
        check(presentation.actions == [.copy, .replace], "selectionRunHidesInsert", "\(presentation.actions)")
    } else {
        check(false, "selectionRunStarted", "\(effect)")
    }
}

// 4. A write refused because the field changed keeps the preview and explains why.
do {
    var (session, token) = startedSession()
    _ = session.complete(["X"], token: token, now: 0)
    _ = session.replace(current: document(id: "doc-2"), now: 1)
    let presentation = present(session)
    check(presentation.message == .documentChanged, "changedFieldMessage")
    check(presentation.status == .preview, "changedFieldKeepsPreview")
    check(presentation.actions == [.copy, .replace, .insert], "changedFieldActions")
    _ = session.replace(current: document(before: nil, privacy: .noText), now: 1)
    let noText = present(session)
    check(noText.message == .noTextField, "noTextWriteMessage", "\(String(describing: noText.message))")
}

// 5. A password field never starts; the reason is the one the user sees.
do {
    var session = ToolSession(limits: limits, sessionID: "probe")
    _ = session.start(
        tool: tool, hostCapabilities: .text, document: document(privacy: .password),
        documentCapabilities: capabilities, now: 0)
    let presentation = present(session)
    check(presentation.status == .failed, "passwordStatus")
    check(presentation.message == .secureEntry, "passwordMessage")
    check(presentation.actions == [.retry], "passwordOffersRetry")
}

// 6. A missing input capability is reported per addon, not as a hidden failure.
do {
    var session = ToolSession(limits: limits, sessionID: "probe")
    let audio = FixedTool(identity: ToolIdentity(id: "hear", title: "听写"), requiredCapabilities: .audio)
    _ = session.start(
        tool: audio, hostCapabilities: .text, document: document(),
        documentCapabilities: capabilities, now: 0)
    let presentation = present(session)
    check(presentation.message == .missingCapabilities(.audio), "missingCapabilityMessage")
}

// 7. An empty list is "no result"; a literal timeout says timeout; a tool error keeps its text.
do {
    var (emptySession, emptyToken) = startedSession()
    _ = emptySession.complete([], token: emptyToken, now: 0)
    check(present(emptySession).message == .noResult, "noResultMessage")

    var (timeoutSession, _) = startedSession()
    _ = timeoutSession.tick(now: 2)
    check(present(timeoutSession).message == .timedOut, "timeoutMessage")
    check(present(timeoutSession).status == .failed, "timeoutStatus")

    var (errorSession, errorToken) = startedSession()
    _ = errorSession.fail(message: "网络断了", token: errorToken, now: 0)
    let error = present(errorSession)
    check(error.message == .toolFailed("网络断了"), "toolErrorMessage")
    check(error.message?.text == "网络断了", "toolErrorTextVerbatim")
}

// 8. Undo is offered only while the window is open; closing it is explained.
do {
    var (session, token) = startedSession()
    _ = session.complete(["X"], token: token, now: 0)
    _ = session.replace(current: document(), now: 1)
    check(session.writeSucceeded(at: 1), "wroteAccepted")
    let open = present(session, now: 2, lastTitle: "润色")
    check(open.status == .wrote, "wroteStatus")
    check(open.actions == [.undo], "wroteOffersUndo")
    let closed = present(session, now: 60, lastTitle: "润色")
    check(closed.actions.isEmpty, "expiredUndoWithdrawn", "\(closed.actions)")
    check(closed.message == .undoExpired, "expiredUndoMessage")
}

// 9. A write that turned into an insertion because the source changed says so, and undo is
// refused once the user edited after the write.
do {
    var (session, token) = startedSession()
    _ = session.complete(["X"], token: token, now: 0)
    _ = session.replace(current: document(before: "zzz"), now: 1)
    check(session.writeSucceeded(at: 1), "changedWriteAccepted")
    let presentation = present(session, now: 2, lastTitle: "润色")
    check(presentation.message == .sourceChanged, "sourceChangedMessage")
    _ = session.undo(current: document(before: "zzz"), writtenText: "not what was written", now: 2)
    let blocked = present(session, now: 2, lastTitle: "润色")
    check(blocked.message == .editedAfterWrite, "editedAfterWriteMessage")
}

// 10. Addon rows carry their own availability text.
do {
    let ready = ToolPanelEntry(identity: ToolIdentity(id: "a", title: "A"), availability: .ready)
    let blocked = ToolPanelEntry(
        identity: ToolIdentity(id: "b", title: "B"), availability: .missingCapabilities(.audio))
    check(ready.isAvailable && ready.unavailableText == nil, "readyRowHasNoDetail")
    check(!blocked.isAvailable, "blockedRowUnavailable")
    if let text = blocked.unavailableText { keys.insert(text) }
    check(blocked.unavailableText != nil, "blockedRowHasDetail")
}

for key in keys.sorted() { print("KEY:\(key)") }
if failures.isEmpty {
    print("PASS all")
    exit(0)
}
print("FAILURES: \(failures.count)")
exit(1)

'''


@unittest.skipUnless(sys.platform == "darwin", "requires macOS Swift")
class ToolPanelTests(unittest.TestCase):
    def test_panel_presentation_and_strings(self):
        toolkit_sources = sorted(TOOLKIT.glob("*.swift"))
        self.assertTrue(toolkit_sources, "ToolKit sources missing")
        self.assertTrue(PANEL.is_file(), "panel presentation source missing")
        texts = [path.read_text(encoding="utf-8") for path in toolkit_sources]
        texts.append(PANEL.read_text(encoding="utf-8").replace("import ToolKit\n", ""))
        with scratch_directory("tool-panel") as directory:
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

        self.assertNotIn("FAIL ", output, output)
        self.assertIn("PASS all", output, output)

        keys = sorted(
            {line.split("KEY:", 1)[1] for line in output.splitlines() if line.startswith("KEY:")})
        self.assertTrue(keys, "probe reported no user-facing strings")
        catalog = json.loads(CATALOG.read_text(encoding="utf-8"))["strings"]
        for key in keys:
            entry = catalog.get(key)
            self.assertIsNotNone(entry, f"String Catalog is missing {key!r}")
            for locale in ("zh-Hans", "zh-Hant", "ja"):
                unit = entry["localizations"].get(locale, {}).get("stringUnit", {})
                self.assertEqual(unit.get("state"), "translated", f"{key!r} {locale} not translated")
                self.assertTrue(unit.get("value"), f"{key!r} {locale} empty")


if __name__ == "__main__":
    unittest.main()
