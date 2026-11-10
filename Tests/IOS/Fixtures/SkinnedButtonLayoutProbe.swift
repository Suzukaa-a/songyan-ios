import CoreText
import Foundation
import SwiftUI
import UIKit

// ---------------------------------------------------------------------------
// Seams for the dependencies of the production SkinnedButton. Only what its layout pass
// touches is modelled; the press visuals read the real button's subviews.
// ---------------------------------------------------------------------------

enum DebugProbe {
    static var touchRoutingEnabled = false
    static func touchRouting(point: CGPoint, hit: UIView?, nearKeys: [CGRect], routed: CGRect?) {}
}

final class KeyboardFeedbackService {
    static let shared = KeyboardFeedbackService()
    func selectionChanged() {}
    func keyTouchDown() {}
}

enum KeyRollover {
    static func keyDown(_ key: UIView) {}
    static func release(_ key: UIView) {}
}

struct KeyboardAppearance: Equatable {
    struct Typography: Equatable { var secondarySize: CGFloat = 10 }
    struct Skin: Equatable { var typography = Typography() }
    var skin = Skin()
    var controlTextSize: CGFloat = 16
    var controlIconSize: CGFloat = 18
    func visualRect(in bounds: CGRect) -> CGRect { bounds.insetBy(dx: 3, dy: 5) }
    func uiFont(_ size: CGFloat) -> UIFont { .systemFont(ofSize: size) }
    func text(on role: String, secondary: Bool = false) -> UIColor { .label }
}

final class SkinCapLayer: CALayer {
    func update(in view: UIView, appearance: KeyboardAppearance, role: String, pressed: Bool) {
        frame = appearance.visualRect(in: view.bounds)
    }
}

/// Records which layers each pass hands over, so the probe can see what the button exposes.
final class KeyboardKeyReleaseAnimator {
    static var lastLayers: [CALayer?] = []
    func resetPressVisual(layers: [CALayer?]) { Self.lastLayers = layers }
    func update(layer: CALayer, isPressed: Bool) {}
    func updatePressVisual(container: CALayer, layers: [CALayer?], isPressed: Bool) {}
}

/// Mirrors CursorSpaceKey.SpaceButton's own pass: super first, then it moves the title.
class SpaceLikeButton: SkinnedButton {
    override func layoutSubviews() {
        super.layoutSubviews()
        if let title = titleView {
            title.frame.origin.y -= 6
        }
    }
}

/// Counts layout passes of a space key hosted by SwiftUI, as the keyboard hosts its keys.
final class CountingSpaceButton: SpaceLikeButton {
    static var passes = 0
    override func layoutSubviews() {
        Self.passes += 1
        super.layoutSubviews()
    }
}

struct HostedSpaceKey: UIViewRepresentable {
    func makeUIView(context: Context) -> CountingSpaceButton {
        // The space key's own face: a plain title, then the language-tagged caption on top
        // (CursorSpaceKey.SpaceButton.refreshAppearance).
        let button = CountingSpaceButton(type: .custom)
        button.setTitle("空格", for: .normal)
        button.setTitleColor(.label, for: .normal)
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .center
        let caption = NSAttributedString(
            string: "空格",
            attributes: [
                NSAttributedString.Key(kCTLanguageAttributeName as String): "zh-Hans",
                .font: UIFont.systemFont(ofSize: 15, weight: .medium),
                .foregroundColor: UIColor.label, .paragraphStyle: paragraph,
            ])
        button.setAttributedTitle(caption, for: .normal)
        return button
    }
    func updateUIView(_ uiView: CountingSpaceButton, context: Context) {}
}

// ---------------------------------------------------------------------------
// Probe app
// ---------------------------------------------------------------------------

@main @MainActor final class SkinnedButtonLayoutProbe: UIResponder, UIApplicationDelegate {
    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
    ) -> Bool { true }
}

/// The current SDK only launches apps that adopt the scene life cycle; the probe runs once its
/// window scene connects. The fixed Objective-C name is what the Info.plist scene manifest names.
@objc(ProbeSceneDelegate) @MainActor final class ProbeSceneDelegate: UIResponder, UIWindowSceneDelegate {
    var window: UIWindow?
    var checks: [[String: Any]] = []
    var failures: [String] = []

    func scene(_ scene: UIScene, willConnectTo session: UISceneSession, options: UIScene.ConnectionOptions) {
        guard let scene = scene as? UIWindowScene else { return }
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 390, height: 276)
        window.rootViewController = UIViewController()
        self.window = window
        window.makeKeyAndVisible()
        run()
    }

    func record(_ name: String, _ passed: Bool, _ detail: String = "") {
        checks.append(["name": name, "passed": passed, "detail": detail])
        if !passed { failures.append(name + (detail.isEmpty ? "" : ": " + detail)) }
    }

    /// Lays a button out the way the keyboard does: in a window, again after a press, again
    /// after a resize. A layout pass that re-enters itself never returns from here.
    func exercise(_ button: SkinnedButton, in host: UIView) {
        host.addSubview(button)
        button.frame = CGRect(x: 10, y: 10, width: 180, height: 46)
        button.layoutIfNeeded()
        button.isHighlighted = true
        button.layoutIfNeeded()
        button.isHighlighted = false
        button.frame = CGRect(x: 10, y: 10, width: 200, height: 50)
        button.layoutIfNeeded()
    }

    func run() {
        guard let host = window?.rootViewController?.view else {
            record("probeWindowAvailable", false, "no window or host view")
            publish()
            return
        }

        let titled = SpaceLikeButton(type: .custom)
        titled.setTitle("空格", for: .normal)
        exercise(titled, in: host)
        record("titleOnlyButtonLaysOut", true)
        record(
            "titleOnlyButtonCreatesNoImageView",
            titled.subviews.allSatisfy { !($0 is UIImageView) },
            titled.subviews.map { String(describing: type(of: $0)) }.joined(separator: ","))

        let glyph = SkinnedButton(type: .custom)
        glyph.setImage(UIImage(systemName: "delete.left"), for: .normal)
        exercise(glyph, in: host)
        let glyphLayers = KeyboardKeyReleaseAnimator.lastLayers.compactMap { $0 }
        record("glyphButtonLaysOut", true)
        record(
            "glyphMovesWithThePress",
            glyph.imageView.map { image in glyphLayers.contains { $0 === image.layer } } == true)

        let author = SkinnedButton(type: .custom)
        author.applyAuthorFace(title: "確定", subtitle: "↵", glyph: "return")
        exercise(author, in: host)
        let authorLayers = KeyboardKeyReleaseAnimator.lastLayers.compactMap { $0 }
        record("authorTitleLaysOut", true)
        record(
            "authorTitleMovesWithThePress",
            author.titleLabel.map { label in authorLayers.contains { $0 === label.layer } } == true)

        // A pass that invalidates the key's own size makes the SwiftUI host lay it out again, for
        // ever: the main thread never gets back here and the report is never written.
        let hosting = UIHostingController(rootView: HostedSpaceKey().frame(width: 180, height: 46))
        hosting.view.frame = CGRect(x: 0, y: 100, width: 390, height: 100)
        host.addSubview(hosting.view)
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
            let settled = CountingSpaceButton.passes
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
                let extra = CountingSpaceButton.passes - settled
                self.record("hostedKeyLaidOut", settled > 0, "\(settled) passes")
                self.record("hostedKeySettles", extra <= 2, "\(extra) passes in the second after settling")
                self.publish()
            }
        }
    }

    func publish() {
        let report: [String: Any] = [
            "passed": failures.isEmpty,
            "checks": checks,
            "scope": "production SkinnedButton layout pass, real UIKit UIButton on the simulator",
            "system": UIDevice.current.systemVersion,
        ]
        let directory = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        if let data = try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]) {
            try? data.write(to: directory.appendingPathComponent("skinned-button-layout-report.json"), options: .atomic)
        }
        if !failures.isEmpty {
            FileHandle.standardError.write(Data(("FAIL " + failures.joined(separator: ", ")).utf8))
        }
    }
}
