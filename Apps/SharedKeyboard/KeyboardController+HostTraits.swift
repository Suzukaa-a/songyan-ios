import CandidateKit
import Combine
import Foundation
import KeyboardCore
import LayoutKit
import OSLog
import UIKit

extension KeyboardController {
    /// `beforeCursor == nil` means unavailable, never an empty field. A proxy
    /// cursor prefix cannot prove whole-document emptiness; only a host with
    /// independent full-document knowledge may supply `documentIsEmpty`.
    public func updateHostTraits(
        keyboardType: UIKeyboardType, returnKeyType: UIReturnKeyType,
        keyboardAppearance: UIKeyboardAppearance,
        autocapitalizationType: UITextAutocapitalizationType? = nil,
        enablesReturnKeyAutomatically: Bool? = nil,
        beforeCursor: String? = nil,
        documentIsEmpty: Bool? = nil,
        hasSelectedText: Bool = false
    ) {
        let kindChanged = self.keyboardType != keyboardType
        let capitalization = autocapitalizationType.map(HostKeyboardTypePolicy.AutoCapitalization.init)
        let contextChanged = hostContextBeforeInput != beforeCursor
        let capitalizationChanged = hostCapitalization != capitalization
        let returnEnabledChanged =
            self.enablesReturnKeyAutomatically != enablesReturnKeyAutomatically
            || hostDocumentIsEmpty != documentIsEmpty
            || hostHasSelectedText != hasSelectedText
        var changed = false
        if kindChanged {
            self.keyboardType = keyboardType
            changed = true
        }
        if self.returnKeyType != returnKeyType {
            self.returnKeyType = returnKeyType
            changed = true
        }
        if self.keyboardAppearance != keyboardAppearance {
            self.keyboardAppearance = keyboardAppearance
            changed = true
        }
        hostCapitalization = capitalization
        hostContextBeforeInput = beforeCursor
        self.enablesReturnKeyAutomatically = enablesReturnKeyAutomatically
        hostDocumentIsEmpty = documentIsEmpty
        hostHasSelectedText = hasSelectedText
        if kindChanged { reconcileHostInput() }
        if kindChanged || capitalizationChanged || contextChanged { reconcileAutomaticShift() }
        // The return key reads `isReturnKeyEnabled` while rendering; repaint the panel
        // itself, not only the host's appearance, when that input changes.
        if returnEnabledChanged { objectWillChange.send() }
        if changed || returnEnabledChanged { hostTraitsChanged.send() }
    }

    private func reconcileHostInput() {
        switch HostKeyboardTypePolicy.preferredInput(HostKeyboardTypeKind(keyboardType)) {
        case .english:
            if hostRestoredMode == nil && inputMode != .english {
                setInputMode(.english)
                if inputMode == .english { hostRestoredMode = .chinese }
            }
        case .numeric, .unchanged:
            if let restored = hostRestoredMode {
                setInputMode(restored)
                if inputMode == restored { hostRestoredMode = nil }
            }
        }
    }

    func reconcileAutomaticShift() {
        // An empty document's before-input is nil; when the host confirms it is empty (`hasText == false`)
        // treat it as "", otherwise the first letter in an empty field would never auto-capitalize.
        // Unknown stays nil (no sentence-start inference).
        let context = hostContextBeforeInput ?? (hostDocumentIsEmpty == true ? "" : nil)
        let wanted =
            hostCapitalization.map {
                HostKeyboardTypePolicy.shouldCapitalize(
                    $0, beforeCursor: context,
                    kind: HostKeyboardTypeKind(keyboardType))
            } ?? false
        if automaticShiftArmed && (!wanted || shiftState == .off) {
            if shiftState == .once { session.setAutomaticShift(false) }
            automaticShiftArmed = false
        }
        if wanted && shiftState == .off && isEnglishMode {
            session.setAutomaticShift(true)
            automaticShiftArmed = session.shiftState == .once
        }
    }

    public var isReturnKeyEnabled: Bool {
        let isSearch = [.search, .google, .yahoo].contains(returnKeyType)
        return snapshot.isComposing
            || HostKeyboardTypePolicy.returnEnabled(
                isSearch: isSearch, enablesAutomatically: enablesReturnKeyAutomatically,
                documentIsEmpty: hostDocumentIsEmpty)
    }

    public var hostPreferredInput: HostKeyboardTypePolicy.PreferredInput {
        HostKeyboardTypePolicy.preferredInput(HostKeyboardTypeKind(keyboardType))
    }

    public var usesASCIIPunctuation: Bool {
        isEnglishMode || snapshot.isAsciiPunct
            || HostKeyboardTypePolicy.requiresASCIIPunctuation(HostKeyboardTypeKind(keyboardType))
    }

    /// What the host Return key will do, as the label table's language-independent value.
    public var returnKeyIntent: KeyLabelPolicy.ReturnIntent {
        switch returnKeyType {
        case .go: return .go
        case .google, .yahoo, .search: return .search
        case .join: return .join
        case .next: return .next
        case .route: return .route
        case .send: return .send
        case .done: return .done
        case .emergencyCall: return .emergencyCall
        case .continue: return .continueAction
        default: return .lineBreak
        }
    }

    public var returnKeyTitle: String {
        KeyLabelPolicy.returnTitle(
            script: inputLanguageScript, isComposing: snapshot.isComposing, intent: returnKeyIntent)
    }

    /// Spoken Return name: composition confirms, otherwise the visible action word.
    public var returnKeyAccessibilityLabel: String {
        KeyLabelPolicy.returnAccessibilityLabel(isComposing: snapshot.isComposing, intent: returnKeyIntent)
    }
}
