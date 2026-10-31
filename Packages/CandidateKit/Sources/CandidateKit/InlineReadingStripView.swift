import SwiftUI

/// The inline readings section: its own horizontal scroller with a fade at the trailing end
/// while more cells lie beyond it, and a divider pinned at its end.
///
/// Cells share the candidate cells' text position (the text block and the 2pt indicator slot
/// below it, centred in the row), so readings and candidates sit on one baseline.
@available(iOS 17.0, macOS 14.0, *)
public struct InlineReadingStripView: View {
    let items: [InlineReadingItem]
    let layout: InlineReadingStrip.Layout
    let height: CGFloat
    let font: Font
    let textColor: Color
    let accentColor: Color
    let dividerColor: Color
    let interactive: Bool
    /// Non-nil while more readings can be read: runs when the end of the section scrolls into view.
    let loadMoreID: Int?
    let onChoose: (InlineReadingAction) -> Void
    let onLoadMore: () -> Void

    @State private var atEnd = true
    private static let space = "inlineReadingStrip"

    public init(
        items: [InlineReadingItem], layout: InlineReadingStrip.Layout, height: CGFloat, font: Font,
        textColor: Color, accentColor: Color, dividerColor: Color, interactive: Bool,
        loadMoreID: Int?, onChoose: @escaping (InlineReadingAction) -> Void,
        onLoadMore: @escaping () -> Void
    ) {
        self.items = items
        self.layout = layout
        self.height = height
        self.font = font
        self.textColor = textColor
        self.accentColor = accentColor
        self.dividerColor = dividerColor
        self.interactive = interactive
        self.loadMoreID = loadMoreID
        self.onChoose = onChoose
        self.onLoadMore = onLoadMore
    }

    public var body: some View {
        let width = CGFloat(layout.sections.width)
        ZStack(alignment: .trailing) {
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(spacing: 0) {
                    ForEach(Array(items.enumerated()), id: \.offset) { index, item in
                        cell(item, width: CGFloat(layout.cellWidths[index]))
                    }
                    if let loadMoreID, interactive {
                        Color.clear.frame(width: 1, height: height)
                            .task(id: loadMoreID) { if !Task.isCancelled { onLoadMore() } }
                    }
                }
                .padding(.leading, CGFloat(InlineReadingStrip.startInset))
                .background(
                    GeometryReader { proxy in
                        Color.clear.preference(
                            key: InlineReadingOffsetKey.self,
                            value: proxy.frame(in: .named(Self.space)).minX)
                    })
            }
            .coordinateSpace(name: Self.space)
            .onPreferenceChange(InlineReadingOffsetKey.self) { offset in
                let end = -Double(offset) >= layout.sections.maxScroll - 0.5
                if end != atEnd { atEnd = end }
            }
            .scrollBounceBehavior(.basedOnSize)
            .sharpCandidateScrollEdges()
            // Items are positional: new content starts at its first cell.
            .id(items)
            .mask(alignment: .leading) { fade(width: width) }
            // Pinned: stays put however far the cells scroll.
            Rectangle()
                .fill(dividerColor)
                .frame(width: 0.5, height: height * 0.5)
                .accessibilityHidden(true)
        }
        .frame(width: width, height: height)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("读音")
    }

    @ViewBuilder
    private func fade(width: CGFloat) -> some View {
        if layout.sections.scrolls && !atEnd {
            HStack(spacing: 0) {
                Rectangle().fill(.black)
                LinearGradient(colors: [.black, .clear], startPoint: .leading, endPoint: .trailing)
                    .frame(width: min(width, CGFloat(InlineReadingStrip.fadeWidth)))
            }
            .frame(width: width, alignment: .leading)
        } else {
            Rectangle().fill(.black)
        }
    }

    @ViewBuilder
    private func cell(_ item: InlineReadingItem, width: CGFloat) -> some View {
        switch item.kind {
        case .choice:
            Button {
                if let action = item.action { onChoose(action) }
            } label: {
                cellText(item, width: width, color: textColor)
            }
            .buttonStyle(CandidatePressStyle(tint: textColor))
            .disabled(!interactive)
            .accessibilityLabel(item.accessibilityLabel)
            .accessibilityInputLabels(item.inputLabels.map { Text(verbatim: $0) })
        case .selected:
            cellText(item, width: width, color: accentColor)
                .accessibilityLabel(item.accessibilityLabel)
                .accessibilityHint(item.accessibilityHint ?? "")
        }
    }

    private func cellText(_ item: InlineReadingItem, width: CGFloat, color: Color) -> some View {
        VStack(spacing: 1) {
            Text(item.label).font(font).lineLimit(1)
            Color.clear.frame(height: 2)
        }
        .foregroundStyle(color)
        // Cells are positional: new text replaces old in one frame instead of cross-fading.
        .transaction { $0.animation = nil }
        .frame(width: width, height: height)
        .contentShape(Rectangle())
    }
}

private struct InlineReadingOffsetKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = nextValue() }
}
