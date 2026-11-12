import Foundation

/// The document-proxy surface the tool gateway is allowed to use. UIKit's
/// UITextDocumentProxy provides exactly these reads and writes; there is no
/// range replacement, and an insertion always replaces the current selection.
protocol ToolTextDocumentProxy: AnyObject {
    var documentIdentity: UUID? { get }
    var textBeforeCaret: String? { get }
    var textAfterCaret: String? { get }
    var selectedText: String? { get }
    var isSecureTextEntry: Bool? { get }
    func insertText(_ text: String)
    func deleteBackward()
}

#if canImport(UIKit)
import UIKit

/// The live proxy, mapped onto the gateway surface without adding operations the
/// system proxy does not have.
final class LiveToolTextDocumentProxy: ToolTextDocumentProxy {
    private let proxy: UITextDocumentProxy

    init(proxy: UITextDocumentProxy) {
        self.proxy = proxy
    }

    var documentIdentity: UUID? { RimeDocumentIdentifier(proxy) }
    var textBeforeCaret: String? { proxy.documentContextBeforeInput }
    var textAfterCaret: String? { proxy.documentContextAfterInput }
    var selectedText: String? { proxy.selectedText }
    var isSecureTextEntry: Bool? { proxy.isSecureTextEntry }
    func insertText(_ text: String) { proxy.insertText(text) }
    func deleteBackward() { proxy.deleteBackward() }
}
#endif
