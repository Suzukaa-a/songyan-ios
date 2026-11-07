import CandidateKit
import Combine
import KeyboardCore
import LayoutKit
import SwiftUI

/// A key that acts on release. While it is held, the next key's touch-down commits
/// it first (`KeyRollover`).
@MainActor protocol KeyboardRolloverPress: AnyObject {
    func commitRolloverPress()
}

/// The key a finger is still on as a plain tap. Fast two-thumb typing lands the next key
/// before this one lifts; like the system keyboard, that touch-down commits this key first,
/// so keys keep press order instead of lift order. Every key's touch-down reports here.
@MainActor enum KeyRollover {
    private static weak var pending: (any KeyboardRolloverPress)?

    /// A key went down: the press still held on another key is typed first.
    static func keyDown(_ key: AnyObject) {
        guard let held = pending, held !== key else { return }
        pending = nil
        held.commitRolloverPress()
    }

    /// `key` is now a plain tap that the next touch-down types first.
    static func hold(_ key: any KeyboardRolloverPress) { pending = key }

    /// `key` no longer acts on release as a plain tap (lifted, cancelled, held, slid off).
    static func release(_ key: AnyObject) {
        if pending === key { pending = nil }
    }
}

/// Ordered alternate KeyCaps are the renderer's data boundary; no LayoutKit types required.
struct AlternateCharacterKey: UIViewRepresentable {
    @Environment(\.keyboardPanelHostLifetime) private var hostLifetime
    @Environment(\.keyboardAppearance) private var appearance
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.keyboardPopupSurface) private var popupSurface
    let cap: KeyCap
    let alternates: [KeyCap]
    var longPressDelay: TimeInterval = 0.35
    var layoutPicker = false
    var phoneKey = false
    var phoneSideKey = false
    var requiresExplicitAlternateSelection = false
    var showsKeyPreview = false
    var visualRole: String? = nil
    /// Explicit title size (points) for keys whose label is content rather than a
    /// keycap glyph, e.g. the 9-key rail's readings. nil = the role's key size.
    var titleSize: Double? = nil
    /// The letters of a merged cap (`["w", "e"]`): the first in the primary tone, the
    /// rest in the secondary tone. Empty for ordinary keys.
    var letterGroup: [String] = []
    /// One shuangpin hint per letter of `letterGroup`, drawn in a column under its letter.
    var groupHints: [String?] = []
    /// One cap per letter of a two-letter key: a sideways swipe types the left or right one.
    var letterSwipe: [KeyCap] = []
    /// The user's flick direction; nil while flicking is off, or while the key leaves flicking to
    /// the shared default (see `flickEligible`).
    var flickConfigured: KeyFlick.Direction? = nil
    /// The typed long-press options; a flick types the one that shows the key's corner hint.
    /// nil asks the shared default to use the drawn `alternates`.
    var flickOptions: [KeyCap]? = nil
    /// A nine-key digit key's own digit, typed whatever the hint shows.
    var flickDigit: KeyCap? = nil
    /// Whether a vertical drag on this key past the threshold is a flick or voids the press,
    /// whether or not the key has a target. nil asks the shared default: an ordinary character key
    /// that draws a corner mark flicks it, every other key keeps its taps. A caller that manages
    /// flicking itself (the definition rows) passes it explicitly, false included.
    var flickEligible: Bool? = nil
    /// The subtitle is a shuangpin final table: draw it as a small line under the
    /// letter and keep the corner for the first long-press alternate (the digit),
    /// as on the quanpin 26-key.
    var syllableHintBelow = false
    /// The layout shows hints on its letter keys: a key without a hint still keeps the band, so the
    /// letters of a row share one baseline.
    var reservesHintBand = false
    /// Overrides the default AX hint. The default only describes "long-press alternate", which is wrong for a tap-cycling key
    /// (the 9-key idle first key); that key must announce the real cycling order.
    var accessibilityHintOverride: String? = nil
    var accessibilityID: String? = nil
    let onSelect: (KeyCap) -> Void

    func makeUIView(context: Context) -> CharacterButton {
        let button = CharacterButton(frame: .zero)
        button.appearance = appearance
        button.popupSurface = popupSurface
        button.hostLifetime = hostLifetime
        button.accessibilityIdentifier = accessibilityID
        button.configure(
            cap: cap, alternates: alternates, longPressDelay: longPressDelay, layoutPicker: layoutPicker,
            phoneKey: phoneKey, phoneSideKey: phoneSideKey,
            requiresExplicitAlternateSelection: requiresExplicitAlternateSelection,
            showsKeyPreview: showsKeyPreview,
            visualRole: visualRole, titleSize: titleSize, letterGroup: letterGroup,
            groupHints: groupHints, letterSwipe: letterSwipe,
            flickConfigured: flickConfigured, flickOptions: flickOptions, flickDigit: flickDigit,
            flickEligible: flickEligible,
            syllableHintBelow: syllableHintBelow, reservesHintBand: reservesHintBand,
            accessibilityHintOverride: accessibilityHintOverride, onSelect: onSelect)
        button.isEnabled = isEnabled
        return button
    }

    func updateUIView(_ button: CharacterButton, context: Context) {
        button.appearance = appearance
        button.popupSurface = popupSurface
        button.hostLifetime = hostLifetime
        button.accessibilityIdentifier = accessibilityID
        button.configure(
            cap: cap, alternates: alternates, longPressDelay: longPressDelay, layoutPicker: layoutPicker,
            phoneKey: phoneKey, phoneSideKey: phoneSideKey,
            requiresExplicitAlternateSelection: requiresExplicitAlternateSelection,
            showsKeyPreview: showsKeyPreview,
            visualRole: visualRole, titleSize: titleSize, letterGroup: letterGroup,
            groupHints: groupHints, letterSwipe: letterSwipe,
            flickConfigured: flickConfigured, flickOptions: flickOptions, flickDigit: flickDigit,
            flickEligible: flickEligible,
            syllableHintBelow: syllableHintBelow, reservesHintBand: reservesHintBand,
            accessibilityHintOverride: accessibilityHintOverride, onSelect: onSelect)
        // `isEnabled` repaints the cap in its setter; only write a real change.
        if button.isEnabled != isEnabled { button.isEnabled = isEnabled }
        if !isEnabled { button.cancelPress() }
    }

    static func dismantleUIView(_ button: CharacterButton, coordinator: ()) { button.cancelPress() }

    final class CharacterButton: UIControl, KeyboardKeyHitTarget, KeyboardRolloverPress {
        var hostLifetime: KeyboardPanelHostLifetime? {
            didSet {
                guard oldValue !== hostLifetime else { return }
                cancelPress()
                rebindPanelHostObserver(self, selector: #selector(abandonPress), from: oldValue, to: hostLifetime)
            }
        }
        var appearance = KeyboardAppearance()
        private let capLayer = SkinCapLayer()
        private let releaseAnimator = KeyboardKeyReleaseAnimator()
        let title = UILabel()
        let subtitle = UILabel()
        private let alternateHint = UILabel()
        var cap: KeyCap?
        var alternates: [KeyCap] = []
        private var longPressDelay: TimeInterval = 0.35
        private var onSelect: ((KeyCap) -> Void)?
        var holdTimer: Timer?
        var popup: UIScrollView?
        weak var keyPreview: KeyCalloutView?
        var popupLabels: [UILabel] = []
        /// Trailing checkmark of the current keyboard in the language-key menu.
        var layoutCheckmarks: [Int: UIImageView] = [:]
        var scrollTimer: Timer?
        weak var popupSurface: UIView?
        var popupHostSize = CGSize.zero
        weak var popupHost: UIView?
        /// A popup *cell* index (blind-drag space), not an alternate index.
        var highlightedAlternate: Int?
        /// Popup cell → alternate index. A key on the right half mirrors its
        /// popup: the options run right to left from the cell above the finger.
        var cellAlternates: [Int] = []
        var lastLocation = CGPoint.zero
        /// The language menu's stationary-release target is anchored to the
        /// original touch, not to the key's changing SwiftUI/UIView bounds.
        var layoutHoldOrigin = CGPoint.zero
        /// Blind drag: the long-press origin and the popup grid, both in the
        /// popup's **content** coordinate space, so vertical auto-scroll is
        /// accounted for and the mapping never depends on precise cell landing.
        var dragOrigin = CGPoint.zero
        /// The same long-press point in **window** space. The drop-away cancel
        /// is measured from it on screen, because content coordinates move with
        /// the popup's auto-scroll.
        var dragOriginInWindow = CGPoint.zero
        var dragGeometry: AlternateDragPicker.Geometry?
        /// Ordinary keys only: keeps the opening default (usually not under the
        /// finger) from jumping against the finger's motion.
        var motionGuard: AlternateDragPicker.MotionGuard?
        /// The opening default: horizontal travel steps through options from it.
        var dragAnchor: Int?
        private var previousSize = CGSize.zero
        var layoutPicker = false
        private var phoneKey = false
        private var phoneSideKey = false
        private var visualRole: String?
        var didHold = false
        var requiresExplicitAlternateSelection = false
        var showsKeyPreview = false
        private var titleSize: Double?
        private var letterGroup: [String] = []
        private var groupHints: [String?] = []
        private var letterSwipe: [KeyCap] = []
        /// Per-letter hint labels of a merged cap, one per letter while any hint shows.
        private var columnHints: [UILabel] = []
        /// Least space between the title's line and a bottom hint on a short key (a landscape row).
        private static let stackedTitleGap: CGFloat = 1
        /// Sideways pick on a two-letter key (`LetterSwipeTracker`).
        private var letterTracker: LetterSwipeTracker?
        var didLetterSwipe = false
        /// The finger left a two-letter key sideways before the swipe locked.
        var exitedSideways = false
        /// The letter the swipe currently picks; drawn in the primary tone.
        private var swipeChoice: Int?
        private var flickConfigured: KeyFlick.Direction?
        private var flickOptions: [KeyCap] = []
        private var flickDigit: KeyCap?
        private var flickEligible = false
        /// The direction the vertical drag past the threshold went; nil until one does. Only the
        /// configured direction types, the other one voids the press.
        var flickDirection: KeyFlick.Direction?
        /// Drawn progress of the flick transition, and what it is drawn on.
        private var flickEase = EasedProgress()
        private var flickLink: CADisplayLink?
        private var flickSide: Int?
        private let flickLayer = UIView()
        private let flickTitle = UILabel()
        private let flickHint = UILabel()
        private var flickLetters: [UILabel] = []
        private var syllableHintBelow = false
        private var reservesHintBand = false
        /// The key font the row's letters are aligned to, so a shrunk merged cap keeps the shared baseline.
        private var referenceTitleFont = UIFont.systemFont(ofSize: 17)
        /// Overrides the default AX hint (the default only describes "long-press alternate", wrong for a tap-cycling key).
        /// Assigned only from `configure`; takes no part in state outside `Configuration`.
        private var accessibilityHintOverride: String?
        /// Window-space touch-down point; an upward travel past
        /// `flickThreshold` before the hold fires, in the configured direction, types the flick target.
        private var touchOrigin = CGPoint.zero
        var didSwipeUp = false
        /// A flick shorter than this (or than 40% of the key) is finger drift in a
        /// normal tap; 20pt let slightly upward taps on 9-key type the digit (`KeyFlick`).
        private var flickThreshold: Double { KeyFlick.threshold(keyHeight: Double(bounds.height)) }
        private var hasFlick: Bool { flickEligible }

        /// The corner hint as drawn: the corner label, or the subtitle that took its place when the
        /// first option is the subtitle itself.
        private var drawnHintLabel: UILabel? {
            if !(alternateHint.text ?? "").isEmpty { return alternateHint }
            if !(subtitle.text ?? "").isEmpty { return subtitle }
            return nil
        }

        /// A flick types only what the key shows: its digit, or the option labelled like the hint.
        private var flickTarget: KeyCap? {
            guard hasFlick else { return nil }
            return KeyFlick.target(
                options: flickOptions, label: \.title, hint: drawnHintLabel?.text, digit: flickDigit)
        }
        /// The finger left the key before a hold completed. Like the system
        /// keyboard, the character key under the finger at lift types instead.
        var slidOff = false
        /// This press was already typed by a rollover; the rest of its touch is inert.
        var consumed = false
        /// A flick key's touch rose out of the key without becoming its swipe-up.
        var exitedUpward = false
        /// A flick key's touch sank out of the key without becoming its swipe-down.
        var exitedDownward = false
        var explicitSelection = ExplicitAlternateSelection()
        /// Everything `configure` derives the labels, hints and cap paint from.
        /// SwiftUI calls `updateUIView` for every key on every panel update (each
        /// keystroke re-renders the panel); an unchanged key must not re-measure
        /// its labels, rebuild accessibility actions and schedule another layout.
        private struct Configuration: Equatable {
            let cap: KeyCap
            let alternates: [KeyCap]
            let longPressDelay: TimeInterval
            let layoutPicker: Bool
            let phoneKey: Bool
            let phoneSideKey: Bool
            let requiresExplicitAlternateSelection: Bool
            let showsKeyPreview: Bool
            let visualRole: String?
            let titleSize: Double?
            let letterGroup: [String]
            let groupHints: [String?]
            let letterSwipe: [KeyCap]
            let flickConfigured: KeyFlick.Direction?
            let flickOptions: [KeyCap]
            let flickDigit: KeyCap?
            let flickEligible: Bool
            let syllableHintBelow: Bool
            let reservesHintBand: Bool
            let accessibilityHintOverride: String?
            let appearance: KeyboardAppearance
        }
        private var configuration: Configuration?

        /// The flick a key has once the shared default is applied (see `resolvedFlick`).
        private struct Flick {
            var configured: KeyFlick.Direction? = nil
            var options: [KeyCap] = []
            var digit: KeyCap? = nil
            var eligible = false
        }

        /// What a vertical drag on this key types.
        ///
        /// The page renderers do not configure flicking: their keys hand over the drawn `alternates`
        /// and nothing else, so only the mark the key finally shows in its corner may be typed. A
        /// caller that manages flicking itself (the definition rows) passes at least one flick
        /// input, and that decision is used as given, a false `flickEligible` or an empty option
        /// list included.
        private static func resolvedFlick(
            cap: KeyCap, alternates: [KeyCap], flickConfigured: KeyFlick.Direction?,
            flickOptions: [KeyCap]?, flickDigit: KeyCap?, flickEligible: Bool?,
            layoutPicker: Bool, phoneKey: Bool, phoneSideKey: Bool,
            syllableHintBelow: Bool
        ) -> Flick {
            if flickEligible != nil || flickConfigured != nil || flickOptions != nil || flickDigit != nil {
                return Flick(
                    configured: flickConfigured, options: flickOptions ?? [],
                    digit: flickDigit, eligible: (flickEligible ?? false) && flickConfigured != nil)
            }
            // A menu key, a nine-key shell key and every action that is not plain text keep their
            // taps: those keys select tools, switch keyboards or write a preference.
            let setting = KeyboardKeyFeelPreferences.flick
            guard let direction = setting.direction, !layoutPicker, !phoneKey, !phoneSideKey,
                cap.action.flicksItsHint
            else { return Flick(configured: nil) }
            // Only text types: a page-level control option in the same list stays a long press.
            let options = alternates.filter { $0.action.typesText }
            let hints = hintTexts(
                cap: cap, alternates: alternates, phoneKey: false, phoneSideKey: false,
                layoutPicker: false, syllableHintBelow: syllableHintBelow)
            // What the key shows besides its title: the corner mark, else the subtitle.
            let corner = nonEmpty(hints.corner) ?? nonEmpty(hints.subtitle)
            guard KeyFlick.target(options: options, label: { $0.title }, hint: corner, digit: nil) != nil
            else { return Flick(configured: nil) }
            return Flick(configured: direction, options: options, digit: nil, eligible: true)
        }

        /// The texts `configure` draws under the title and in the corner. Flick eligibility reads
        /// the same values, so a flick can only type a mark the key really shows.
        private static func hintTexts(
            cap: KeyCap, alternates: [KeyCap], phoneKey: Bool, phoneSideKey: Bool,
            layoutPicker: Bool, syllableHintBelow: Bool
        ) -> (subtitle: String?, corner: String?) {
            KeyHintLayoutPolicy.texts(
                title: cap.title, subtitle: cap.subtitle, alternate: alternates.first?.title,
                phoneKey: phoneKey, phoneSideKey: phoneSideKey,
                menuIndicator: layoutPicker ? KeyboardToolsAffordance.indicatorGlyph : nil,
                syllableHintBelow: syllableHintBelow)
        }

        private static func nonEmpty(_ text: String?) -> String? {
            guard let text, !text.isEmpty else { return nil }
            return text
        }

        override init(frame: CGRect) {
            super.init(frame: frame)
            isAccessibilityElement = true
            accessibilityTraits = .keyboardKey
            isMultipleTouchEnabled = false
            layer.cornerRadius = 6
            layer.borderWidth = 0.5
            title.textAlignment = .center
            title.font = .systemFont(ofSize: 22, weight: .medium)
            title.adjustsFontSizeToFitWidth = true
            title.minimumScaleFactor = 0.6
            subtitle.font = .systemFont(ofSize: 10)
            subtitle.textColor = .secondaryLabel
            subtitle.textAlignment = .center
            subtitle.adjustsFontSizeToFitWidth = true
            alternateHint.font = .systemFont(ofSize: 9)
            alternateHint.textColor = .secondaryLabel
            alternateHint.textAlignment = .right
            for label in [title, subtitle, alternateHint] {
                label.isUserInteractionEnabled = false
                addSubview(label)
            }
            // The flick transition is drawn on copies of the labels in their own layer, because the
            // press physics owns the transforms of the real labels' layers.
            flickLayer.isUserInteractionEnabled = false
            flickLayer.isHidden = true
            for label in [flickTitle, flickHint] {
                label.textAlignment = .center
                label.isUserInteractionEnabled = false
                flickLayer.addSubview(label)
            }
            addSubview(flickLayer)
        }

        required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

        func configure(
            cap: KeyCap, alternates: [KeyCap], longPressDelay: TimeInterval,
            layoutPicker: Bool, phoneKey: Bool, phoneSideKey: Bool,
            requiresExplicitAlternateSelection: Bool,
            showsKeyPreview: Bool,
            visualRole: String?, titleSize: Double? = nil,
            letterGroup: [String] = [], groupHints: [String?] = [],
            letterSwipe: [KeyCap] = [], flickConfigured: KeyFlick.Direction? = nil,
            flickOptions: [KeyCap]? = nil, flickDigit: KeyCap? = nil, flickEligible: Bool? = nil,
            syllableHintBelow: Bool = false, reservesHintBand: Bool = false,
            accessibilityHintOverride: String? = nil,
            onSelect: @escaping (KeyCap) -> Void
        ) {
            // The action closure is cheap to swap and must always be the latest one.
            self.onSelect = onSelect
            let flick = Self.resolvedFlick(
                cap: cap, alternates: alternates, flickConfigured: flickConfigured,
                flickOptions: flickOptions, flickDigit: flickDigit, flickEligible: flickEligible,
                layoutPicker: layoutPicker, phoneKey: phoneKey, phoneSideKey: phoneSideKey,
                syllableHintBelow: syllableHintBelow)
            let next = Configuration(
                cap: cap, alternates: alternates, longPressDelay: longPressDelay,
                layoutPicker: layoutPicker, phoneKey: phoneKey, phoneSideKey: phoneSideKey,
                requiresExplicitAlternateSelection: requiresExplicitAlternateSelection,
                showsKeyPreview: showsKeyPreview,
                visualRole: visualRole, titleSize: titleSize, letterGroup: letterGroup,
                groupHints: groupHints, letterSwipe: letterSwipe,
                flickConfigured: flick.configured, flickOptions: flick.options,
                flickDigit: flick.digit, flickEligible: flick.eligible,
                syllableHintBelow: syllableHintBelow, reservesHintBand: reservesHintBand,
                accessibilityHintOverride: accessibilityHintOverride,
                appearance: appearance)
            guard next != configuration else { return }
            configuration = next
            // Cancel the press only when key identity/behavior changes; a re-render that changes only the title (e.g. Shift) must not swallow a key still held
            // (when typing quickly, the previous key's release consumes the one-shot Shift while the next is not yet released). Alternate changes cancel only while the candidate popup is open.
            if self.cap?.id != cap.id || self.cap?.action != cap.action || self.longPressDelay != longPressDelay
                || self.requiresExplicitAlternateSelection != requiresExplicitAlternateSelection
                || self.letterSwipe != letterSwipe
                || (popup != nil && self.alternates != alternates)
            {
                abandonPress()
                releaseAnimator.cancelRelease(layers: pressVisualLayers)
            }
            self.cap = cap
            self.alternates = alternates
            self.longPressDelay = longPressDelay
            self.layoutPicker = layoutPicker
            self.phoneKey = phoneKey
            self.phoneSideKey = phoneSideKey
            self.visualRole = visualRole
            self.requiresExplicitAlternateSelection = requiresExplicitAlternateSelection
            self.showsKeyPreview = showsKeyPreview
            self.titleSize = titleSize
            self.letterGroup = letterGroup
            self.groupHints = groupHints
            self.letterSwipe = letterSwipe.count == 2 ? letterSwipe : []
            configureColumnHints()
            self.flickConfigured = flick.configured
            self.flickOptions = flick.options
            self.flickDigit = flick.digit
            self.flickEligible = flick.eligible
            self.syllableHintBelow = syllableHintBelow
            self.reservesHintBand = reservesHintBand
            self.accessibilityHintOverride = accessibilityHintOverride
            title.text = cap.title
            let hints = Self.hintTexts(
                cap: cap, alternates: alternates, phoneKey: phoneKey, phoneSideKey: phoneSideKey,
                layoutPicker: layoutPicker,
                syllableHintBelow: syllableHintBelow)
            subtitle.text = hints.subtitle
            alternateHint.text = hints.corner
            // Hint policy: every hint is one line (`KeyHintLayoutPolicy`).
            alternateHint.font = .systemFont(ofSize: phoneKey ? 11 : 9)
            accessibilityLabel = cap.title
            accessibilityValue = cap.subtitle
            accessibilityHint =
                accessibilityHintOverride
                ?? (alternates.isEmpty ? nil : "长按并滑动选择副键，也可使用辅助功能操作")
            if letterGroup.count > 1 {
                accessibilityLabel = letterGroup.joined(separator: " ")
                let described = zip(letterGroup, groupHints).compactMap { letter, hint in
                    hint.map { "\(letter)：\($0)" }
                }
                accessibilityValue = described.isEmpty ? nil : described.joined(separator: "，")
                if !self.letterSwipe.isEmpty, alternates.isEmpty, accessibilityHintOverride == nil {
                    accessibilityHint = "向左或向右滑动可输入对应的字母，也可使用辅助功能操作"
                }
            }
            if layoutPicker {
                if cap.subtitle == "返回" {
                    accessibilityLabel = cap.title == "中文" ? "返回中文字母页" : "返回英文字母页"
                } else {
                    accessibilityLabel = cap.title == "中文" ? "切换到中文输入" : "切换到英文输入"
                }
                // Final assignment: the long-press list contains the added keyboards and, at the end, More tools.
                accessibilityHint =
                    alternates.isEmpty
                    ? UserTerminology.userKeyboardSwitcherEmpty
                    : "长按滑选已添加的键盘或更多工具，按住列表边缘滚动；也可使用辅助功能操作"
            }
            accessibilityCustomActions = (self.letterSwipe + alternates).map { alternate in
                UIAccessibilityCustomAction(
                    name:
                        "\(requiresExplicitAlternateSelection ? "设为快捷符号：" : layoutPicker ? "切换键盘：" : "输入 ")\(alternate.title)"
                ) { [weak self] _ in
                    guard let self, self.isEnabled else { return false }
                    self.onSelect?(alternate)
                    return true
                }
            }
            updateAppearance(in: bounds)
            setNeedsLayout()
        }

        override func layoutSubviews() {
            // A frame write on a transformed layer is undefined: every pass starts
            // from identity, lays out cleanly, then re-applies the press physics.
            releaseAnimator.resetPressVisual(layers: pressVisualLayers)
            super.layoutSubviews()
            updateAppearance(in: bounds)
            if previousSize != bounds.size {
                cancelPress()
                previousSize = bounds.size
            }
            let visual = appearance.visualRect(in: bounds)
            let content = visual.insetBy(dx: 3, dy: 2)
            // Hint policy (`KeyHintLayoutPolicy`): every hint is one line and bottom-aligned, and a
            // key that shows or reserves a hint band puts its letter at the row's shared baseline.
            let hintHeight = bottomHintHeight
            let subtitleHeight = CGFloat(KeyHintLayoutPolicy.height(lineHeight: Double(subtitle.font.lineHeight)))
            subtitle.frame = CGRect(
                x: content.minX, y: content.maxY - subtitleHeight, width: content.width, height: subtitleHeight)
            alternateHint.frame = CGRect(
                x: content.minX, y: content.minY, width: content.width,
                height: CGFloat(KeyHintLayoutPolicy.height(lineHeight: Double(alternateHint.font.lineHeight))))
            if appearance.isSystemDefault {
                // Primary labels share one baseline even when a key has no secondary label.
                if hintHeight > 0 {
                    let mid = CGFloat(
                        KeyHintLayoutPolicy.titleMidY(
                            contentHeight: Double(content.height), lineHeight: Double(referenceTitleFont.lineHeight),
                            hintHeight: Double(hintHeight), gap: Double(Self.stackedTitleGap)))
                    // A key whose letter is set smaller than the row's reference font keeps the reference baseline.
                    let offset =
                        (referenceTitleFont.ascender + referenceTitleFont.descender) / 2
                        - (title.font.ascender + title.font.descender) / 2
                    title.frame = CGRect(
                        x: content.minX, y: content.minY + mid - content.height / 2 + offset,
                        width: content.width, height: content.height)
                } else {
                    title.frame = content
                }
            } else {
                title.frame = CGRect(
                    x: content.minX, y: hintHeight > 0 ? content.minY + 4 : content.minY,
                    width: content.width, height: hintHeight > 0 ? 29 : content.height)
            }
            layoutColumnHints(in: content)
            // Bounds and centre, not frame: the press physics may have transformed this layer.
            flickLayer.bounds = bounds
            flickLayer.center = CGPoint(x: bounds.midX, y: bounds.midY)
            if flickEase.targetValue > 0 || !flickLayer.isHidden {
                applyFlick(flickEase.value(at: CACurrentMediaTime()))
            }
            // Under a callout the keycap keeps its full size so the callout's stem meets its edges.
            releaseAnimator.updatePressVisual(
                container: layer, layers: pressVisualLayers,
                isPressed: isHighlighted, scales: !showsCallout)
        }

        /// Applies the shared hint policy to a hint label: one line at the natural size, shrunk to fit
        /// down to the policy floor, then truncated. The baseline stays where the natural font puts it.
        private func applyHintLayout(to label: UILabel, availableWidth: CGFloat, natural: UIFont, shrinks: Bool) {
            if label.font != natural { label.font = natural }
            label.numberOfLines = 1
            label.lineBreakMode = .byTruncatingTail
            label.baselineAdjustment = .alignBaselines
            label.adjustsFontSizeToFitWidth = shrinks
            label.minimumScaleFactor = shrinks ? CGFloat(KeyHintLayoutPolicy.minimumScaleFactor) : 0
        }

        /// The cap surface and its glyphs move together. The button's own layer is
        /// deliberately not transformed, so `bounds.contains` in tracking, the hit
        /// target and the popup placement stay exactly as before.
        private var pressVisualLayers: [CALayer?] {
            [capLayer, title.layer, subtitle.layer, alternateHint.layer, flickLayer.layer] + columnHints.map(\.layer)
        }

        private func updateAppearance(in bounds: CGRect) {
            let isControl: Bool
            switch cap?.action {
            case .code?, .literal?, .letterVariant?, .space?: isControl = false
            default: isControl = true
            }
            let role =
                isHighlighted
                ? "pressed"
                : visualRole ?? (cap?.action == .enter ? "accent" : ((isControl || phoneSideKey) ? "control" : "key"))
            capLayer.update(in: self, appearance: appearance, role: role, pressed: isHighlighted)
            // A disabled key (e.g. "Search" with an empty search field) must be visibly untappable.
            alpha = isEnabled ? 1 : 0.45
            title.textColor = appearance.text(on: role)
            subtitle.textColor = appearance.text(on: role, secondary: true)
            alternateHint.textColor = appearance.text(on: role, secondary: true)
            let base =
                titleSize
                ?? (isControl || phoneSideKey
                    ? appearance.controlTextSize
                    : phoneKey ? appearance.phoneKeyTextSize : appearance.keyTextSize)
            // Hints first: the title size depends on the room the bottom hint leaves.
            // Resolve the hint policy here so any appearance refresh (including a
            // press) re-applies the right font size and line behaviour before the
            // frames are computed in `layoutSubviews`.
            let secondaryFont = appearance.uiFont(appearance.skin.typography.secondarySize)
            let content = appearance.visualRect(in: bounds).insetBy(dx: 3, dy: 2)
            let contentWidth = content.width
            applyHintLayout(to: subtitle, availableWidth: contentWidth, natural: secondaryFont, shrinks: true)
            applyHintLayout(to: alternateHint, availableWidth: contentWidth, natural: secondaryFont, shrinks: false)
            let columnWidth = CGFloat(
                KeyHintLayoutPolicy.columnWidth(
                    total: Double(contentWidth),
                    columns: columnHints.count))
            for (index, label) in columnHints.enumerated() {
                let hintColour = appearance.text(on: role, secondary: true)
                label.textColor =
                    swipeChoice.map { $0 == index ? hintColour : hintColour.withAlphaComponent(0.3) }
                    ?? hintColour
                label.textAlignment = .center
                applyHintLayout(to: label, availableWidth: columnWidth, natural: secondaryFont, shrinks: true)
            }
            // Merged keys / letter clusters shrink to the actual available width (QQ scaling floor: see scaledFontSize),
            // while a single letter keeps the default key font size; the label's own adjustsFontSizeToFitWidth remains the fallback.
            // The font setter invalidates the label's layout even for an equal font.
            var titleFont = appearance.uiFont(
                appearance.scaledFontSize(
                    base, label: title.text ?? "", availableWidth: bounds.width - 10))
            var referenceFont = appearance.uiFont(base)
            // Only when even the top margin leaves no room above the hint does the title shrink.
            let hintHeight = bottomHintHeight
            let titleRoom = content.height + 2 - Self.stackedTitleGap - hintHeight
            func fitted(_ font: UIFont) -> UIFont {
                hintHeight > 0 && font.lineHeight > titleRoom
                    ? font.withSize(font.pointSize * max(0.75, titleRoom / font.lineHeight)) : font
            }
            titleFont = fitted(titleFont)
            referenceFont = fitted(referenceFont)
            referenceTitleFont = referenceFont
            if title.font != titleFont { title.font = titleFont }
            if letterGroup.count > 1 {
                let merged = mergedTitle(font: titleFont, role: role, contentWidth: contentWidth)
                if title.attributedText != merged { title.attributedText = merged }
            }
        }

        /// Height of the hint line under the title: the subtitle, the per-letter columns, or the band a
        /// key without a hint keeps so its letter stays level with its row; 0 when the layout has none.
        private var bottomHintHeight: CGFloat {
            if let first = columnHints.first {
                return CGFloat(KeyHintLayoutPolicy.height(lineHeight: Double(first.font.lineHeight)))
            }
            guard !(subtitle.text ?? "").isEmpty || reservesHintBand else { return 0 }
            return CGFloat(KeyHintLayoutPolicy.height(lineHeight: Double(subtitle.font.lineHeight)))
        }

        /// The letters of a merged cap: the picked (or first) letter in the primary tone.
        /// With per-letter hints the letters spread so each sits over its own hint column;
        /// otherwise a fixed gap reads as separate letters without splitting the cap in two.
        private func mergedTitle(font: UIFont, role: String, contentWidth: CGFloat) -> NSAttributedString {
            let primary = swipeChoice ?? 0
            let text = NSMutableAttributedString()
            for (index, letter) in letterGroup.enumerated() {
                // The pressed cap draws both tones alike, so a swipe fades the letters it leaves out.
                let colour =
                    swipeChoice == nil
                    ? appearance.text(on: role, secondary: index != primary)
                    : index == primary ? appearance.text(on: role) : appearance.text(on: role).withAlphaComponent(0.3)
                text.append(NSAttributedString(string: letter, attributes: [.font: font, .foregroundColor: colour]))
            }
            let widths = letterGroup.map { KeyboardTextMeasure.width(of: $0, font: font) }
            let columns = CGFloat(
                KeyHintLayoutPolicy.columnWidth(
                    total: Double(contentWidth),
                    columns: letterGroup.count))
            var offset = 0
            for index in letterGroup.indices.dropLast() {
                let length = (letterGroup[index] as NSString).length
                // Centre to centre: one column plus the gap between columns.
                let kern =
                    columnHints.isEmpty
                    ? font.pointSize * 0.4
                    : max(0, columns + CGFloat(KeyHintLayoutPolicy.columnGap) - (widths[index] + widths[index + 1]) / 2)
                text.addAttribute(.kern, value: kern, range: NSRange(location: offset + length - 1, length: 1))
                offset += length
            }
            return text
        }

        /// Creates one hint label per letter while any letter of a merged cap has a hint.
        private func configureColumnHints() {
            let wanted =
                letterGroup.count > 1 && groupHints.count == letterGroup.count
                && groupHints.contains { !($0 ?? "").isEmpty }
            if !wanted {
                columnHints.forEach { $0.removeFromSuperview() }
                columnHints = []
                return
            }
            while columnHints.count < letterGroup.count {
                let label = UILabel()
                label.isUserInteractionEnabled = false
                label.textAlignment = .center
                addSubview(label)
                columnHints.append(label)
            }
            while columnHints.count > letterGroup.count { columnHints.removeLast().removeFromSuperview() }
            // A zero-width break after each slash lets a two-line hint wrap between
            // finals ("ong/" + "iong") instead of mid-syllable.
            for (label, hint) in zip(columnHints, groupHints) {
                label.text = hint?.replacingOccurrences(of: "/", with: "/\u{200B}")
            }
            // The per-letter columns replace the single subtitle line.
            subtitle.text = nil
        }

        private func layoutColumnHints(in content: CGRect) {
            guard !columnHints.isEmpty else { return }
            let width = CGFloat(
                KeyHintLayoutPolicy.columnWidth(
                    total: Double(content.width),
                    columns: columnHints.count))
            let gap = CGFloat(KeyHintLayoutPolicy.columnGap)
            let lineHeight = Double(columnHints.first?.font.lineHeight ?? 12)
            let height = CGFloat(KeyHintLayoutPolicy.height(lineHeight: lineHeight))
            for (index, label) in columnHints.enumerated() {
                label.frame = CGRect(
                    x: content.minX + CGFloat(index) * (width + gap),
                    y: content.maxY - height, width: width, height: height)
            }
        }

        override var isHighlighted: Bool {
            didSet {
                // `cancelPress()` runs on every begin/configure change; only a real
                // press transition repaints the cap and replays the press physics.
                guard isHighlighted != oldValue else { return }
                updateAppearance(in: bounds)
                setNeedsLayout()
            }
        }
        override var isEnabled: Bool { didSet { if isEnabled != oldValue { updateAppearance(in: bounds) } } }

        override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
            // Feedback on touch-down (system keyboard behavior); the effect feedback of the same keypress is then coalesced, not repeated.
            if isEnabled {
                KeyboardFeedbackService.shared.keyTouchDown()
                KeyRollover.keyDown(self)
            }
            super.touchesBegan(touches, with: event)
        }

        /// A finger sliding slightly off the keycap still counts as pressing this key (ordinary finger jitter/offset); only a clear slide-away cancels.
        private var trackingBounds: CGRect {
            bounds.insetBy(dx: -min(10, bounds.width * 0.25), dy: -min(10, bounds.height * 0.2))
        }

        /// On this key: inside its slop, or still where it landed. A touch routed here
        /// from a gap or the keyboard edge (`FeedbackInputView.hitTest`) starts outside
        /// the slop and must not count as having slid off.
        private func isOnKey(_ touch: UITouch) -> Bool {
            if trackingBounds.contains(touch.location(in: self)) { return true }
            let point = touch.location(in: window)
            return hypot(point.x - touchOrigin.x, point.y - touchOrigin.y) < 10
        }

        private var typesCharacter: Bool {
            switch cap?.action {
            case .code?, .literal?, .letterVariant?: return !layoutPicker
            default: return false
            }
        }

        /// Return keeps press order like the character keys (a letter lifted before it would
        /// otherwise join the composition it was about to confirm), but a slide off it still cancels.
        private var joinsRollover: Bool { typesCharacter || (cap?.action == .enter && !layoutPicker) }

        func commitRolloverPress() {
            guard popup == nil, !didHold, !didSwipeUp, !didLetterSwipe, !slidOff,
                isHighlighted, joinsRollover, let cap
            else { return }
            cancelPress()
            consumed = true
            onSelect?(cap)
        }

        override func beginTracking(_ touch: UITouch, with event: UIEvent?) -> Bool {
            cancelPress()
            consumed = false
            isHighlighted = true
            lastLocation = touch.location(in: window)
            layoutHoldOrigin = lastLocation
            touchOrigin = lastLocation
            letterTracker = letterSwipe.isEmpty ? nil : LetterSwipeTracker(letterCount: letterSwipe.count)
            if joinsRollover { KeyRollover.hold(self) }
            showKeyPreviewIfNeeded()
            if layoutPicker || !alternates.isEmpty {
                // Main run loop timers fire on the main thread.
                let timer = Timer(timeInterval: longPressDelay, repeats: false) { [weak self] _ in
                    MainActor.assumeIsolated { self?.holdDelayElapsed() }
                }
                holdTimer = timer
                RunLoop.main.add(timer, forMode: .common)
            }
            return true
        }

        override func continueTracking(_ touch: UITouch, with event: UIEvent?) -> Bool {
            lastLocation = touch.location(in: window)
            if slidOff || consumed { return true }
            // A merged key picks a letter sideways and flicks vertically, whichever way the finger
            // first goes clearly: a swipe that locked ignores vertical travel, and a flick past the
            // threshold ignores sideways travel until the finger comes back.
            var sideways = false
            if popup == nil, letterTracker != nil {
                let rise = Double(touchOrigin.y - lastLocation.y)
                let flickOwns = didSwipeUp && !KeyFlick.isGivenBack(rise: rise, direction: flickDirection ?? .up)
                if !flickOwns {
                    let swiped = trackLetterSwipe()
                    if swiped || abs(lastLocation.x - touchOrigin.x) > abs(lastLocation.y - touchOrigin.y) {
                        updateSidewaysFlick()
                        if swiped { return true }
                        sideways = true
                    }
                }
            }
            // Re-read on every crossing: a drag that voided the wrong way and came back can still
            // arm the configured way.
            if popup == nil, !sideways, hasFlick,
                let direction = KeyFlick.direction(
                    rise: Double(touchOrigin.y - lastLocation.y),
                    dx: Double(lastLocation.x - touchOrigin.x), threshold: flickThreshold)
            {
                // A short vertical drag: the hold popup no longer opens for this press. Past the
                // threshold the wrong way, or with nothing to type, the release types nothing, not
                // the key under the finger.
                holdTimer?.invalidate()
                holdTimer = nil
                didSwipeUp = true
                flickDirection = direction
            }
            if popup == nil, !sideways { updateVerticalFlick() }
            if didSwipeUp, !sideways { return true }
            if popup != nil {
                updateSelection(at: lastLocation)
            } else if !isOnKey(touch) {
                // Leaving before a hold completes ends this key's press. A character key
                // keeps tracking so the key under the finger at lift can type (a fast
                // tap that rolls onto the neighbour is not silently eaten); any other
                // key cancels.
                guard typesCharacter else {
                    cancelPress()
                    return false
                }
                // Rising out of a flick key may still become its swipe-up, never the key above;
                // a rise that never qualifies (rolling up and sideways) types the key itself.
                if hasFlick, lastLocation.y < touchOrigin.y {
                    holdTimer?.invalidate()
                    holdTimer = nil
                    exitedUpward = true
                    return true
                }
                // Sinking out of a flick key may still become its swipe-down; if it does not, the
                // key under the finger at lift types, as for any slide off.
                if hasFlick, lastLocation.y > touchOrigin.y {
                    holdTimer?.invalidate()
                    holdTimer = nil
                    exitedDownward = true
                    return true
                }
                // Leaving a two-letter key sideways is the start of its swipe, not a roll onto the neighbour.
                if letterTracker != nil,
                    abs(lastLocation.x - touchOrigin.x) > abs(lastLocation.y - touchOrigin.y)
                {
                    holdTimer?.invalidate()
                    holdTimer = nil
                    exitedSideways = true
                    return true
                }
                holdTimer?.invalidate()
                holdTimer = nil
                keyPreview?.hide(for: self, immediately: true)
                keyPreview = nil
                KeyRollover.release(self)
                isHighlighted = false
                slidOff = true
            }
            return true
        }

        /// The enabled character key under a window point (gaps route through
        /// `FeedbackInputView.hitTest`); overlays and non-character keys yield nil.
        private func characterKey(at point: CGPoint) -> CharacterButton? {
            var view = window?.hitTest(point, with: nil)
            while let current = view, !(current is CharacterButton) { view = current.superview }
            guard let key = view as? CharacterButton, key.isEnabled, key.typesCharacter, key.cap != nil else {
                return nil
            }
            return key
        }

        override func endTracking(_ touch: UITouch?, with event: UIEvent?) {
            let selected: KeyCap?
            if consumed {
                consumed = false
                cancelPress()
                return
            } else if let popup {
                let point = touch?.location(in: window) ?? lastLocation
                if touch != nil { updateSelection(at: point, emitHighlight: false) }
                selected = popupReleaseSelection(at: point, in: popup)
                if selected == nil, !layoutPicker,
                    AlternateDragPicker.dropProgress(dragDrop(at: point)) >= 1,
                    !UIAccessibility.isReduceMotionEnabled,
                    let cancelled = popupHost as? KeyCalloutView
                {
                    // Keep the whole visual alive until its exit finishes; touch state clears below.
                    self.popup = nil
                    popupHost = nil
                    UIView.animate(withDuration: 0.18, delay: 0, options: [.curveEaseOut]) {
                        cancelled.alpha = 0
                        cancelled.transform = cancelled.transform.translatedBy(x: 0, y: 8)
                    } completion: { _ in
                        cancelled.removeFromSuperview()
                    }
                }
            } else if slidOff {
                let target = touch.flatMap { characterKey(at: $0.location(in: window)) }
                cancelPress()
                if let target, let cap = target.cap { target.onSelect?(cap) }
                return
            } else if didLetterSwipe {
                // A picked letter types wherever the finger lifts, as a flick does. A flick given
                // back before the swipe locked no longer counts.
                selected = swipeChoice.map { letterSwipe[$0] } ?? (isHighlighted ? cap : nil)
            } else if didSwipeUp {
                let rise = Double(touchOrigin.y - (touch?.location(in: window) ?? lastLocation).y)
                let target = flickTarget
                switch KeyFlick.release(
                    rise: rise, direction: flickDirection ?? .up, configured: flickConfigured ?? .up,
                    hasTarget: target != nil)
                {
                // Not gated on `isHighlighted`: UIKit drops it as soon as the finger leaves the
                // key, and a flick naturally ends past the key. Only coming back cancels it.
                case .tap: selected = cap
                case .option: selected = target
                case .nothing: selected = nil
                }
            } else if exitedDownward {
                // Same as `slidOff`: lifting over space, Return or another non-character key types nothing.
                let target = touch.flatMap { characterKey(at: $0.location(in: window)) }
                cancelPress()
                if let target, let cap = target.cap { target.onSelect?(cap) }
                return
            } else {
                selected =
                    !didHold && (exitedUpward || exitedSideways || touch.map(isOnKey) == true)
                        && isHighlighted ? cap : nil
            }
            cancelPress()
            if let selected { onSelect?(selected) }
        }

        override func cancelTracking(with event: UIEvent?) { cancelPress() }

        // MARK: - Flick transition

        /// Progress of a vertical flick toward the corner hint, along the configured direction.
        private func updateVerticalFlick() {
            guard let configured = flickConfigured, hasFlick, flickTarget != nil else {
                return setFlickTarget(0, side: nil)
            }
            let rise = Double(touchOrigin.y - lastLocation.y)
            let armed =
                didSwipeUp && flickDirection == configured && !KeyFlick.isGivenBack(rise: rise, direction: configured)
            let progress = KeyFlick.progress(
                travel: KeyFlick.travel(rise: rise, direction: configured), threshold: flickThreshold,
                armed: armed)
            setFlickTarget(progress, side: nil)
        }

        /// Progress of the sideways swipe of a merged key toward the letter it would pick.
        private func updateSidewaysFlick() {
            guard letterTracker != nil, letterSwipe.count == 2 else { return }
            let dx = Double(lastLocation.x - touchOrigin.x)
            let dy = Double(lastLocation.y - touchOrigin.y)
            let picked = swipeChoice
            let progress = KeyFlick.sidewaysProgress(
                dx: dx, dy: dy, lockDistance: LetterSwipeTracker.lockDistance, picked: picked != nil)
            setFlickTarget(progress, side: picked ?? (dx < 0 ? 0 : letterSwipe.count - 1))
        }

        private func setFlickTarget(_ progress: Double, side: Int?) {
            if progress > 0 { flickSide = side }
            let now = CACurrentMediaTime()
            guard flickEase.setTarget(progress, at: now, reduceMotion: UIAccessibility.isReduceMotionEnabled) else {
                return
            }
            applyFlick(flickEase.value(at: now))
            guard !flickEase.isSettled(at: now), flickLink == nil else { return }
            let link = CADisplayLink(target: self, selector: #selector(flickTick))
            link.add(to: .main, forMode: .common)
            flickLink = link
        }

        @objc private func flickTick() {
            let now = CACurrentMediaTime()
            applyFlick(flickEase.value(at: now))
            if flickEase.isSettled(at: now) { stopFlickLink() }
        }

        private func stopFlickLink() {
            flickLink?.invalidate()
            flickLink = nil
        }

        /// Ends the transition at once and shows the key as it is.
        func resetFlickVisual() {
            stopFlickLink()
            flickEase.reset()
            flickSide = nil
            applyFlick(0)
        }

        private func blend(_ from: UIColor, _ to: UIColor, _ p: CGFloat) -> UIColor {
            var a: (CGFloat, CGFloat, CGFloat, CGFloat) = (0, 0, 0, 0)
            var b = a
            guard from.getRed(&a.0, green: &a.1, blue: &a.2, alpha: &a.3),
                to.getRed(&b.0, green: &b.1, blue: &b.2, alpha: &b.3)
            else { return p < 0.5 ? from : to }
            return UIColor(
                red: a.0 + (b.0 - a.0) * p, green: a.1 + (b.1 - a.1) * p,
                blue: a.2 + (b.2 - a.2) * p, alpha: a.3 + (b.3 - a.3) * p)
        }

        /// Draws the transition at progress `value`: on the keycap and in the bubble above it.
        private func applyFlick(_ value: Double) {
            let p = CGFloat(value)
            guard p > 0, window != nil else {
                guard !flickLayer.isHidden else { return }
                flickLayer.isHidden = true
                title.alpha = 1
                alternateHint.alpha = 1
                subtitle.alpha = 1
                flickLetters.forEach { $0.isHidden = true }
                keyPreview?.setTransition(
                    incoming: nil, direction: .zero, progress: 0, bubbleAlpha: showsCallout ? 1 : 0)
                return
            }
            // Geometry comes from bounds and centres: the press physics transforms the real labels'
            // layers (and this overlay alike), which makes their frames unreliable.
            let titleCentre = title.center
            if let side = flickSide {
                guard flickLetterTexts.count >= 2 else { return }
                flickLayer.isHidden = false
                title.alpha = 0
                flickHint.isHidden = true
                flickTitle.isHidden = true
                layoutFlickLetters(side: side, progress: p, titleCentre: titleCentre)
                showFlickBubble(
                    incoming: letterSwipe[side].title, direction: CGVector(dx: side == 0 ? -1 : 1, dy: 0),
                    progress: p)
                return
            }
            guard let source = drawnHintLabel else { return }
            flickLayer.isHidden = false
            title.alpha = 0
            source.alpha = 0
            flickLetters.forEach { $0.isHidden = true }
            flickTitle.isHidden = false
            flickHint.isHidden = false
            flickTitle.attributedText = nil
            flickTitle.text = title.text
            flickTitle.font = title.font
            flickTitle.textColor = title.textColor
            flickTitle.transform = .identity
            flickTitle.bounds = title.bounds
            flickTitle.center = titleCentre
            flickTitle.alpha = 1 - p
            flickTitle.transform = CGAffineTransform(scaleX: 1 - 0.4 * p, y: 1 - 0.4 * p)
            let hintFont = source.font ?? .systemFont(ofSize: 9)
            let size = hintFont.pointSize + (title.font.pointSize - hintFont.pointSize) * p
            let text = source.text ?? ""
            flickHint.text = text
            flickHint.font = hintFont.withSize(size)
            flickHint.textColor = blend(source.textColor, title.textColor, p)
            // The label keeps the title's frame; only its centre glides from where the hint is drawn.
            flickHint.transform = .identity
            flickHint.bounds = CGRect(origin: .zero, size: title.bounds.size)
            let hintWidth = KeyboardTextMeasure.width(of: text, font: hintFont)
            let half = source.bounds.width / 2
            let from: CGPoint
            switch source.textAlignment {
            case .right: from = CGPoint(x: source.center.x + half - hintWidth / 2, y: source.center.y)
            case .left: from = CGPoint(x: source.center.x - half + hintWidth / 2, y: source.center.y)
            default: from = source.center
            }
            flickHint.center = CGPoint(
                x: from.x + (titleCentre.x - from.x) * p, y: from.y + (titleCentre.y - from.y) * p)
            let direction = CGVector(dx: 0, dy: flickConfigured == .down ? 1 : -1)
            showFlickBubble(incoming: text, direction: direction, progress: p)
        }

        /// The letters a merged key's swipe draws: its letter group, or the title's own characters
        /// when the key has no group, so the title is never hidden with nothing drawn in its place.
        private var flickLetterTexts: [String] {
            if letterGroup.count >= 2 { return letterGroup }
            return (title.text ?? "").filter { !$0.isWhitespace }.map(String.init)
        }

        /// The letters of a merged key as separate labels: the picked one glides to the key's
        /// centre and grows, the others fade.
        private func layoutFlickLetters(side: Int, progress p: CGFloat, titleCentre: CGPoint) {
            let letterGroup = flickLetterTexts
            while flickLetters.count < letterGroup.count {
                let label = UILabel()
                label.textAlignment = .center
                label.isUserInteractionEnabled = false
                flickLayer.addSubview(label)
                flickLetters.append(label)
            }
            let font = title.font ?? .systemFont(ofSize: 22)
            let widths = letterGroup.map { KeyboardTextMeasure.width(of: $0, font: font) }
            let text = title.attributedText ?? NSAttributedString(string: letterGroup.joined())
            let total = text.size().width
            var left = titleCentre.x - total / 2
            var offset = 0
            for (index, letter) in letterGroup.enumerated() {
                let label = flickLetters[index]
                label.isHidden = false
                label.text = letter
                label.font = font
                label.textColor = appearance.text(on: "pressed")
                label.transform = .identity
                label.bounds = CGRect(
                    origin: .zero, size: CGSize(width: widths[index] + 4, height: title.bounds.height))
                let centre = CGPoint(x: left + widths[index] / 2, y: titleCentre.y)
                let picked = index == side
                let target = titleCentre
                label.center =
                    picked
                    ? CGPoint(x: centre.x + (target.x - centre.x) * p, y: centre.y + (target.y - centre.y) * p)
                    : centre
                let scale = picked ? 1 + 0.25 * p : 1
                label.transform = CGAffineTransform(scaleX: scale, y: scale)
                label.alpha = picked ? 1 : 1 - p
                let length = (letter as NSString).length
                let kern =
                    offset + length - 1 < text.length
                    ? (text.attribute(.kern, at: offset + length - 1, effectiveRange: nil) as? CGFloat ?? 0) : 0
                left += widths[index] + kern
                offset += length
            }
            for index in letterGroup.count..<flickLetters.count { flickLetters[index].isHidden = true }
        }

        /// The key preview, or a bubble that fades in when the key has none, scrolling the key's
        /// label out in the finger's direction and the new one in from the opposite side.
        private func showFlickBubble(incoming: String, direction: CGVector, progress p: CGFloat) {
            if keyPreview == nil { presentKeyPreview(text: cap?.title ?? "") }
            guard let callout = keyPreview else { return }
            callout.setTransition(
                incoming: incoming, direction: direction, progress: p, bubbleAlpha: showsCallout ? 1 : p)
        }

        /// Feeds the sideways swipe of a two-letter key; true once the swipe owns the press.
        private func trackLetterSwipe() -> Bool {
            guard var tracker = letterTracker else { return false }
            let changed = tracker.update(
                dx: Double(lastLocation.x - touchOrigin.x),
                dy: Double(lastLocation.y - touchOrigin.y))
            letterTracker = tracker
            guard tracker.isLocked else { return false }
            if !didLetterSwipe {
                // The swipe replaces the hold menu and the slide-off typing for this press.
                didLetterSwipe = true
                holdTimer?.invalidate()
                holdTimer = nil
                KeyRollover.release(self)
            }
            if changed {
                swipeChoice = tracker.choice
                updateAppearance(in: bounds)
                if tracker.choice != nil { KeyboardFeedbackService.shared.alternateHighlightMoved() }
            }
            return true
        }

        /// Clears the sideways swipe state of the current press.
        func resetLetterSwipe() {
            letterTracker = nil
            didLetterSwipe = false
            exitedSideways = false
            if swipeChoice != nil {
                swipeChoice = nil
                updateAppearance(in: bounds)
            }
        }
        override func point(inside point: CGPoint, with event: UIEvent?) -> Bool {
            super.point(inside: point, with: event) || KeyboardRoutedTouch.accepts(self, point)
        }

        override func accessibilityActivate() -> Bool {
            guard isEnabled, let cap else { return false }
            onSelect?(cap)
            return true
        }

        override func didMoveToWindow() {
            super.didMoveToWindow()
            if window == nil { cancelPress() }
        }

    }
}

private extension KeyAction {
    /// Whether a key carrying this action is a plain character key, the same set `KeyFlick`
    /// treats as flick eligible.
    var flicksItsHint: Bool {
        switch self {
        case .code(_), .literal(_): return true
        default: return false
        }
    }

    /// Whether this action types text: the only thing a flick may type. A letter variant is text
    /// too, even though a key carrying it is not a flick key of its own.
    var typesText: Bool {
        switch self {
        case .code(_), .literal(_), .letterVariant(_): return true
        default: return false
        }
    }
}
