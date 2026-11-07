import CandidateKit
import UIKit

/// The letter callout of a pressed key: a bubble joined to the keycap by curved
/// shoulders, filled and shadowed as one shape, like the system keyboard. One view per
/// panel overlay is reused for previews; a held alternate list owns a separate surface with
/// the same shape so overlapping fingers keep their own lists. A preview appears on touch-down
/// and stays at least `minimumVisible` after release, unless the next press takes it over.
final class KeyCalloutView: UIView {
    static let minimumVisible: CFTimeInterval = 0.05

    private let shape = CAShapeLayer()
    private let label = UILabel()
    private let incoming = UILabel()
    private let clip = UIView()
    private var bubbleRect = CGRect.zero
    private var joinsKey = false
    private var isSharedPreview = false
    private weak var owner: AnyObject?
    private var shownAt: CFTimeInterval = 0
    private var pendingHide: DispatchWorkItem?

    static func shared(in host: UIView) -> KeyCalloutView {
        if let existing = host.subviews.lazy.compactMap({ $0 as? KeyCalloutView }).first(where: { $0.isSharedPreview })
        {
            return existing
        }
        let view = KeyCalloutView(frame: host.bounds)
        view.isSharedPreview = true
        host.addSubview(view)
        return view
    }

    override init(frame: CGRect) {
        super.init(frame: frame)
        isUserInteractionEnabled = false
        isAccessibilityElement = false
        isHidden = true
        layer.shadowColor = UIColor.black.cgColor
        layer.shadowOpacity = 0.24
        layer.shadowRadius = 5
        layer.shadowOffset = CGSize(width: 0, height: 2)
        layer.addSublayer(shape)
        for text in [label, incoming] {
            text.textAlignment = .center
            text.adjustsFontSizeToFitWidth = true
            text.minimumScaleFactor = 0.6
            clip.addSubview(text)
        }
        incoming.isHidden = true
        // The labels scroll through the bubble and must not draw outside it.
        clip.clipsToBounds = true
        addSubview(clip)
    }

    /// Scrolls the key's label out toward `direction` (a unit step) and `text` in from the
    /// opposite side, by one bubble height (width when sideways) times `progress`.
    /// Progress 0 restores the plain label.
    func setTransition(incoming text: String?, direction: CGVector, progress: CGFloat, bubbleAlpha: CGFloat = 1) {
        alpha = bubbleAlpha
        let p = min(1, max(0, progress))
        guard p > 0, let text else {
            label.transform = .identity
            label.alpha = 1
            incoming.isHidden = true
            return
        }
        let size = bubbleRect.size
        label.transform = CGAffineTransform(
            translationX: direction.dx * size.width * p, y: direction.dy * size.height * p)
        label.alpha = 1 - p
        incoming.isHidden = false
        incoming.text = text
        incoming.font = label.font
        incoming.textColor = label.textColor
        // Not `frame`: the label is already translated, and copying its frame would offset the
        // incoming text by that translation again and push it out of the clipped bubble.
        incoming.transform = .identity
        incoming.bounds = label.bounds
        incoming.center = label.center
        incoming.transform = CGAffineTransform(
            translationX: -direction.dx * size.width * (1 - p), y: -direction.dy * size.height * (1 - p))
        incoming.alpha = p
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func show(
        _ text: String, bubble: CGRect, key: CGRect, keyRadius: CGFloat,
        fill: UIColor, textColor: UIColor, border: UIColor, borderWidth: CGFloat,
        font: UIFont, for owner: AnyObject, expandingFrom preview: KeyCalloutView? = nil
    ) {
        let source = preview.flatMap { $0.owner === owner && !$0.isHidden && $0.alpha > 0 ? $0 : nil }
        pendingHide?.cancel()
        pendingHide = nil
        self.owner = owner
        shownAt = CACurrentMediaTime()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        if let host = superview {
            frame = host.bounds
            host.bringSubviewToFront(self)
        }
        let (path, joined) = Self.path(bubble: bubble, key: key, bubbleRadius: max(10, keyRadius), keyRadius: keyRadius)
        joinsKey = joined
        shape.removeAnimation(forKey: "calloutExpansion")
        layer.removeAnimation(forKey: "calloutExpansion")
        clip.layer.removeAnimation(forKey: "calloutBounds")
        clip.layer.removeAnimation(forKey: "calloutPosition")
        shape.path = path
        layer.shadowPath = path
        shape.fillColor = fill.cgColor
        // Two overlapping outlines would draw border lines across the overlap.
        shape.strokeColor = joined ? border.cgColor : nil
        shape.lineWidth = max(0.75, borderWidth + 0.25)
        label.text = text
        label.font = font
        label.textColor = textColor
        bubbleRect = bubble
        clip.frame = bubble
        label.transform = .identity
        label.alpha = 1
        label.frame = clip.bounds.insetBy(dx: 2, dy: 2)
        incoming.isHidden = true
        alpha = 1
        isHidden = false
        CATransaction.commit()
        if let source, !UIAccessibility.isReduceMotionEnabled {
            // The model geometry is final before the list is attached: drag picking never follows
            // the animated bounds. Only the bubble and its clipped content expand.
            if source.joinsKey == joined, let from = source.shape.path {
                animate(shape, keyPath: "path", from: from, to: path, key: "calloutExpansion")
                animate(layer, keyPath: "shadowPath", from: from, to: path, key: "calloutExpansion")
            }
            animate(
                clip.layer, keyPath: "bounds",
                from: CGRect(origin: .zero, size: source.bubbleRect.size), to: clip.bounds, key: "calloutBounds")
            animate(
                clip.layer, keyPath: "position",
                from: CGPoint(x: source.bubbleRect.midX, y: source.bubbleRect.midY),
                to: clip.center, key: "calloutPosition")
        }
    }

    /// A held key owns its list surface until release; another finger can still use the shared preview.
    func containAlternates(_ scroll: UIScrollView, replacing preview: KeyCalloutView? = nil) {
        scroll.frame = clip.bounds
        clip.addSubview(scroll)
        guard let preview, !UIAccessibility.isReduceMotionEnabled else { return }
        // One alternate replaces the preview glyph in place; it has no separate selection card.
        label.text = preview.label.text
        label.font = preview.label.font
        label.alpha = 0
        for (target, from, to) in [(label.layer, Float(1), Float(0)), (scroll.layer, Float(0), Float(1))] {
            let fade = CABasicAnimation(keyPath: "opacity")
            fade.fromValue = from
            fade.toValue = to
            fade.duration = KeyboardPressPhysics.fadeDuration * 0.8
            fade.timingFunction = CAMediaTimingFunction(name: .easeOut)
            target.add(fade, forKey: "alternateReplacement")
        }
    }

    private func animate(_ target: CALayer, keyPath: String, from: Any, to: Any, key: String) {
        let animation = CASpringAnimation(
            perceptualDuration: KeyboardPressPhysics.releaseDuration * 0.8,
            bounce: CGFloat(KeyboardPressPhysics.releaseDesignBounce))
        animation.keyPath = keyPath
        animation.fromValue = from
        animation.toValue = to
        animation.duration = animation.settlingDuration
        target.add(animation, forKey: key)
    }

    /// Keep the shell and its contents together, scaling around the bubble rather than the full overlay.
    func setDropProgress(_ progress: CGFloat) {
        alpha = 1 - 0.6 * progress
        guard !UIAccessibility.isReduceMotionEnabled else {
            transform = .identity
            return
        }
        let scale = 1 - 0.08 * progress
        let anchor = CGPoint(x: bubbleRect.midX - bounds.midX, y: bubbleRect.midY - bounds.midY)
        transform = CGAffineTransform(translationX: anchor.x, y: anchor.y + 6 * progress)
            .scaledBy(x: scale, y: scale)
            .translatedBy(x: -anchor.x, y: -anchor.y)
    }

    /// Only the key that showed the callout can hide it; a newer press already owns it.
    func hide(for owner: AnyObject, immediately: Bool) {
        guard self.owner === owner else { return }
        pendingHide?.cancel()
        let remaining = immediately ? 0 : shownAt + Self.minimumVisible - CACurrentMediaTime()
        guard remaining > 0 else {
            pendingHide = nil
            isHidden = true
            self.owner = nil
            return
        }
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.owner === owner else { return }
            self.isHidden = true
            self.owner = nil
            self.pendingHide = nil
        }
        pendingHide = work
        DispatchQueue.main.asyncAfter(deadline: .now() + remaining, execute: work)
    }

    /// Bubble on top, keycap below, joined by curves that leave the bubble's lower
    /// corners and land on the keycap's sides. When the keyboard's top edge pushes the
    /// bubble down onto the key, the two are drawn as overlapping rounded rectangles.
    static func path(
        bubble: CGRect, key: CGRect, bubbleRadius: CGFloat,
        keyRadius: CGFloat
    ) -> (path: CGPath, joined: Bool) {
        let shoulder = min(8, bubble.height / 4)
        let keyRadius = min(keyRadius, key.width / 2, key.height / 2)
        guard bubble.maxY <= key.minY + 0.5,
            key.maxY - keyRadius >= bubble.maxY + shoulder
        else {
            let path = UIBezierPath(roundedRect: bubble, cornerRadius: bubbleRadius)
            path.append(UIBezierPath(roundedRect: key, cornerRadius: keyRadius))
            return (path.cgPath, false)
        }
        let r = min(bubbleRadius, bubble.width / 2, (bubble.height - shoulder) / 2)
        let neck = bubble.maxY
        let path = UIBezierPath()
        path.move(to: CGPoint(x: bubble.minX, y: bubble.minY + r))
        path.addArc(
            withCenter: CGPoint(x: bubble.minX + r, y: bubble.minY + r), radius: r,
            startAngle: .pi, endAngle: 1.5 * .pi, clockwise: true)
        path.addLine(to: CGPoint(x: bubble.maxX - r, y: bubble.minY))
        path.addArc(
            withCenter: CGPoint(x: bubble.maxX - r, y: bubble.minY + r), radius: r,
            startAngle: 1.5 * .pi, endAngle: 0, clockwise: true)
        path.addLine(to: CGPoint(x: bubble.maxX, y: neck - shoulder))
        path.addCurve(
            to: CGPoint(x: key.maxX, y: neck + shoulder),
            controlPoint1: CGPoint(x: bubble.maxX, y: neck),
            controlPoint2: CGPoint(x: key.maxX, y: neck))
        path.addLine(to: CGPoint(x: key.maxX, y: key.maxY - keyRadius))
        path.addArc(
            withCenter: CGPoint(x: key.maxX - keyRadius, y: key.maxY - keyRadius), radius: keyRadius,
            startAngle: 0, endAngle: 0.5 * .pi, clockwise: true)
        path.addLine(to: CGPoint(x: key.minX + keyRadius, y: key.maxY))
        path.addArc(
            withCenter: CGPoint(x: key.minX + keyRadius, y: key.maxY - keyRadius), radius: keyRadius,
            startAngle: 0.5 * .pi, endAngle: .pi, clockwise: true)
        path.addLine(to: CGPoint(x: key.minX, y: neck + shoulder))
        path.addCurve(
            to: CGPoint(x: bubble.minX, y: neck - shoulder),
            controlPoint1: CGPoint(x: key.minX, y: neck),
            controlPoint2: CGPoint(x: bubble.minX, y: neck))
        path.close()
        return (path.cgPath, true)
    }
}
