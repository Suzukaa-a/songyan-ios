import SwiftUI

/// A short confirmation that a save went through: a capsule at the bottom that fades after a moment, with the
/// system success haptic. Set the binding to the text to show; it is cleared when the toast goes away.
private struct SavedToast: ViewModifier {
    @Binding var text: String?
    @State private var shown: String?
    @State private var haptic = 0

    func body(content: Content) -> some View {
        content
            .overlay(alignment: .bottom) {
                if let shown {
                    Label(shown, systemImage: "checkmark.circle.fill")
                        .font(.subheadline.weight(.medium))
                        .padding(.horizontal, 16).padding(.vertical, 10)
                        .background(.regularMaterial, in: Capsule())
                        .shadow(color: .black.opacity(0.15), radius: 8, y: 2)
                        .padding(.bottom, 24)
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                        .accessibilityAddTraits(.isStaticText)
                }
            }
            .sensoryFeedback(.success, trigger: haptic)
            .onChange(of: text) { _, new in present(new) }
            .onAppear { present(text) }
            .task(id: shown) {
                guard shown != nil else { return }
                try? await Task.sleep(for: .seconds(2))
                guard !Task.isCancelled else { return }
                withAnimation(.easeOut) { shown = nil }
            }
    }

    private func present(_ new: String?) {
        guard let new else { return }
        withAnimation(.snappy) { shown = new }
        haptic += 1
        text = nil
        UIAccessibility.post(notification: .announcement, argument: new)
    }
}

extension View {
    /// Shows `text` once as a brief confirmation, then clears it.
    func savedToast(_ text: Binding<String?>) -> some View { modifier(SavedToast(text: text)) }
}
