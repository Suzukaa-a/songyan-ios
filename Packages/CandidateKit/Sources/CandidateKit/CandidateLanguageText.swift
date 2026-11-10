import KeyboardCore
import SwiftUI

#if canImport(UIKit)
    import UIKit
#endif

/// How a candidate line that does not fit is shortened.
public enum CandidateTextTruncation: Sendable {
    case tail
    case middle
}

#if canImport(UIKit)
    /// Candidate, composition-badge and keycap text drawn with CoreText's language attribute.
    ///
    /// The input language is part of the drawn run, and SwiftUI Text cannot take text attributes, so the
    /// text goes through a UILabel whose attributed string is built by `CandidateTextLanguage`. Font,
    /// colour, wrapping and truncation stay the ones the surrounding layout already reserves space for.
    ///
    /// The text is not an accessibility element: the tappable candidate cell and the key announce their
    /// own label, and a second reading of the same glyphs would be noise.
    public struct CandidateLanguageText: UIViewRepresentable {
        public let text: String
        public let language: InputLanguage
        public let fontSize: Double
        public let fontFamily: String
        public let fontWeight: String
        public let color: Color
        /// 1 keeps one truncated line (collapsed strip, badge); nil wraps (expanded candidates).
        public let lineLimit: Int?
        public let truncation: CandidateTextTruncation

        @Environment(\.self) private var environment

        public init(
            text: String, language: InputLanguage, fontSize: Double,
            fontFamily: String, fontWeight: String, color: Color,
            lineLimit: Int?, truncation: CandidateTextTruncation = .tail
        ) {
            self.text = text
            self.language = language
            self.fontSize = fontSize
            self.fontFamily = fontFamily
            self.fontWeight = fontWeight
            self.color = color
            self.lineLimit = lineLimit
            self.truncation = truncation
        }

        public func makeUIView(context: Context) -> UILabel {
            let label = UILabel()
            label.isAccessibilityElement = false
            label.setContentHuggingPriority(.defaultLow, for: .horizontal)
            label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            render(label)
            return label
        }

        public func updateUIView(_ label: UILabel, context: Context) { render(label) }

        public func sizeThatFits(
            _ proposal: ProposedViewSize, uiView: UILabel, context: Context
        ) -> CGSize? {
            // Measure the same attributed text the label draws (language attribute included), so the
            // reserved box wraps and truncates exactly where the drawn glyphs do.
            render(uiView)
            let font = CandidateTextFont.uiFont(size: fontSize, family: fontFamily, weight: fontWeight)
            let lineHeight = ceil(font.lineHeight)
            guard let proposedWidth = proposal.width else {
                let ideal = uiView.sizeThatFits(
                    CGSize(width: CGFloat.greatestFiniteMagnitude, height: .greatestFiniteMagnitude))
                return CGSize(width: ceil(ideal.width), height: lineHeight)
            }
            let width = max(0, proposedWidth)
            let measured = uiView.sizeThatFits(
                CGSize(width: width, height: .greatestFiniteMagnitude))
            if lineLimit == 1 {
                return CGSize(width: ceil(min(measured.width, width)), height: lineHeight)
            }
            return CGSize(width: width, height: ceil(measured.height))
        }

        private var lineBreakMode: NSLineBreakMode {
            guard lineLimit == 1 else { return .byWordWrapping }
            return truncation == .middle ? .byTruncatingMiddle : .byTruncatingTail
        }

        private func render(_ label: UILabel) {
            if label.numberOfLines != (lineLimit ?? 0) { label.numberOfLines = lineLimit ?? 0 }
            if label.lineBreakMode != lineBreakMode { label.lineBreakMode = lineBreakMode }
            let string = attributedString
            if label.attributedText != string { label.attributedText = string }
        }

        private var attributedString: NSAttributedString {
            let font = CandidateTextFont.uiFont(size: fontSize, family: fontFamily, weight: fontWeight)
            let paragraph = NSMutableParagraphStyle()
            paragraph.alignment = .left
            paragraph.lineBreakMode = lineBreakMode
            let string = CandidateTextLanguage.attributed(text, language: language)
            if string.length > 0 {
                string.addAttributes(
                    [
                        .font: font, .foregroundColor: color.uiColor(in: environment),
                        .paragraphStyle: paragraph,
                    ], range: NSRange(location: 0, length: string.length))
            }
            return string
        }
    }

    extension Color {
        /// The colour as the current environment resolves it (dark mode, increased contrast), not as the
        /// screen's default traits would: a UIKit view receives no SwiftUI style updates on its own.
        fileprivate func uiColor(in environment: EnvironmentValues) -> UIColor {
            let resolved = resolve(in: environment)
            return UIColor(
                red: CGFloat(resolved.red), green: CGFloat(resolved.green),
                blue: CGFloat(resolved.blue), alpha: CGFloat(resolved.opacity))
        }
    }
#else
    /// macOS fallback for tests and previews: the product draws this text on iOS, where the CoreText
    /// attribute takes effect; this keeps the same font, colour, line limit and truncation.
    public struct CandidateLanguageText: View {
        public let text: String
        public let language: InputLanguage
        public let fontSize: Double
        public let fontFamily: String
        public let fontWeight: String
        public let color: Color
        public let lineLimit: Int?
        public let truncation: CandidateTextTruncation

        public init(
            text: String, language: InputLanguage, fontSize: Double,
            fontFamily: String, fontWeight: String, color: Color,
            lineLimit: Int?, truncation: CandidateTextTruncation = .tail
        ) {
            self.text = text
            self.language = language
            self.fontSize = fontSize
            self.fontFamily = fontFamily
            self.fontWeight = fontWeight
            self.color = color
            self.lineLimit = lineLimit
            self.truncation = truncation
        }

        public var body: some View {
            Text(text)
                .font(CandidateTextFont.swiftUI(size: fontSize, family: fontFamily, weight: fontWeight))
                .foregroundStyle(color)
                .lineLimit(lineLimit)
                .truncationMode(truncation == .middle ? .middle : .tail)
        }
    }
#endif

/// The first text baseline of CandidateLanguageText for the expanded rows' firstTextBaseline HStack:
/// a UIKit view has no baseline of its own, and without this its selection badge would align to the
/// view's bottom edge instead of the first line, moving every badge down.
struct CandidateLanguageTextBaseline: ViewModifier {
    let fontSize: Double
    let fontFamily: String
    let fontWeight: String

    func body(content: Content) -> some View {
        #if canImport(UIKit)
            content.alignmentGuide(.firstTextBaseline) { _ in
                CandidateTextFont.firstBaseline(size: fontSize, family: fontFamily, weight: fontWeight)
            }
        #else
            content
        #endif
    }
}
