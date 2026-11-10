import KeyboardCore
import SwiftUI

/// Home verification entry. Only a standard system text input control is provided here; the keyboard UI must be presented by iOS through the installed
/// KeyboardExtension; the Host does not embed or simulate a keyboard panel.
struct TryInputView: View {
    var body: some View {
        SystemKeyboardTestView(title: String(localized: "试打"))
    }
}

struct SystemKeyboardTestView: View {
    let title: String
    var context: String? = nil
    @State private var text = ""
    @State private var copied = false
    @State private var clearRevision = 0
    @State private var inputKind = InputKind.text
    @FocusState private var focused: Bool

    private enum InputKind: CaseIterable, Identifiable, Hashable {
        case text, url, number
        var id: Self { self }

        var displayName: String {
            switch self {
            case .text: return String(localized: "文本")
            case .url: return String(localized: "网址")
            case .number: return String(localized: "数字")
            }
        }
        var keyboardType: UIKeyboardType {
            switch self {
            case .text: return .default
            case .url: return .URL
            case .number: return .decimalPad
            }
        }
    }

    /// Try-typing note for source detail: after choosing Songyan, the currently applied source is used,
    /// not necessarily the source that opened the try-typing entry. The text comes from the shared terminology (unit-testable).
    static func sourceContext(name: String, inUse: Bool, howToUse: String) -> String {
        UserTerminology.trySourceContext(name: name, inUse: inUse, howToUse: howToUse)
    }

    var body: some View {
        List {
            Section {
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: "info.circle.fill")
                        .foregroundStyle(Color.accentColor)
                        .font(.subheadline)
                    VStack(alignment: .leading, spacing: 4) {
                        Text("轻点输入框并长按 🌐 选择「松烟键盘」。若未找到，请先在「设置」>「键盘与完全访问」中添加。")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                        if let context {
                            Text(context).font(.footnote).foregroundStyle(.secondary)
                        } else {
                            // The home entry belongs to no source: explains that the input scheme in use is what gets typed, and how to switch keyboards.
                            Text(UserTerminology.tryUsesCurrentScheme)
                                .font(.footnote).foregroundStyle(.secondary)
                        }
                    }
                }
                .padding(.vertical, 2)
            }
            Section(String(localized: "输入框")) {
                Picker(String(localized: "输入类型"), selection: $inputKind) {
                    ForEach(InputKind.allCases) { kind in Text(kind.displayName).tag(kind) }
                }
                .pickerStyle(.segmented)
                .padding(.vertical, 2)

                TextEditor(text: $text)
                    .id(inputKind)
                    .focused($focused)
                    .keyboardType(inputKind.keyboardType)
                    .task(id: inputKind) { focused = true }
                    .frame(minHeight: 180)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .accessibilityLabel(String(localized: "试打输入框"))
                    // A fresh native editor also ends the old marked-text session when clearing.
                    .id(clearRevision)
            }
        }
        .toolbar {
            ToolbarItemGroup(placement: .topBarTrailing) {
                clearButton
                copyButton
            }
            #if SONGYAN_PERF
                ToolbarItem(placement: .topBarTrailing) {
                    Button(String(localized: "重置")) {
                        text = ""
                        focused = false
                    }
                    .accessibilityIdentifier("perf.resetTryout")
                }
            #endif
        }
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
        .task { focused = true }
        .onChange(of: text) { _, _ in copied = false }
    }

    private var clearButton: some View {
        Button(role: .destructive) {
            text = ""
            clearRevision += 1
        } label: {
            Label(String(localized: "清空"), systemImage: "trash")
        }
        .disabled(text.isEmpty)
    }

    private var copyButton: some View {
        Button {
            UIPasteboard.general.string = text
            copied = true
            UIAccessibility.post(notification: .announcement, argument: String(localized: "已复制"))
        } label: {
            Label(
                copied ? String(localized: "已复制") : String(localized: "复制内容"),
                systemImage: copied ? "checkmark" : "doc.on.doc")
        }
        .disabled(text.isEmpty)
    }
}
