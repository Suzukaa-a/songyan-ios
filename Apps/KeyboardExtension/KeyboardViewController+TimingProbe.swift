import CandidateKit
import Combine
import KeyboardCore
import LayoutKit
import OSLog
import SwiftUI
import UIKit

#if DEBUG
    // Translation is linked only into the Debug extension for the M0.3 technical probe.
    import Translation
#endif

#if DEBUG
    extension KeyboardViewController {
        // MARK: Timing probe (Debug builds only, opt-in, hard-capped; records geometry only, never input)

        /// Attribution probe for the cold-start anomaly frame (one frame with a full-width overshoot): a CADisplayLink
        /// samples the CALayer model and presentation geometry of root / hosting / window / superview for 6 s after
        /// launch, to tell an in-extension layer presentation change from host-side snapshotting/clipping.
        /// Compiled into Debug builds only and gated like the other diagnostics (`KeyboardLifecycleDiagnostics.isEnabled`);
        /// because it samples every frame it also needs its own `keyboard.frameTimingProbe` default. Stops itself at
        /// 6.0 s or 240 lines, and on release. Reads only geometry and opacity/background/selfSizing state, never text,
        /// candidates or input.
        private static let timingProbeKey = "keyboard.frameTimingProbe"
        private static let timingProbeLogger = Logger.keyboardTiming
        private static let timingProbeMaxLines = 240
        private static let timingProbeMaxSeconds: CFTimeInterval = 6.0

        func startTimingProbeIfEnabled() {
            guard KeyboardLifecycleDiagnostics.isEnabled, UserDefaults.standard.bool(forKey: Self.timingProbeKey),
                !timingProbeActive
            else { return }
            timingProbeActive = true
            timingProbeStartedAt = ProcessInfo.processInfo.systemUptime
            timingProbeLastEmitAt = 0
            timingProbeLines = 0
            timingProbeLastSignature = ""
            let link = CADisplayLink(target: self, selector: #selector(timingProbeTick))
            link.add(to: .main, forMode: .common)
            timingProbeLink = link
            Self.timingProbeLogger.debug("timingProbe start")
        }

        func stopTimingProbe() {
            guard timingProbeActive else { return }
            timingProbeLink?.invalidate()
            timingProbeLink = nil
            timingProbeActive = false
            Self.timingProbeLogger.debug("timingProbe stop lines=\(self.timingProbeLines, privacy: .public)")
        }

        @objc private func timingProbeTick() {
            guard timingProbeActive else { return }
            let elapsed = ProcessInfo.processInfo.systemUptime - timingProbeStartedAt
            if elapsed > Self.timingProbeMaxSeconds || timingProbeLines >= Self.timingProbeMaxLines {
                stopTimingProbe()
                return
            }
            let signature = timingProbeSignature()
            let due = elapsed - timingProbeLastEmitAt >= 0.5
            guard signature != timingProbeLastSignature || due else { return }
            timingProbeLastSignature = signature
            timingProbeLastEmitAt = elapsed
            timingProbeLines += 1
            let time = String(format: "%.3f", elapsed)
            Self.timingProbeLogger.debug("timingProbe t=\(time, privacy: .public) \(signature, privacy: .public)")
        }

        private func timingProbeSignature() -> String {
            guard isViewLoaded else { return "notLoaded" }
            var parts: [String] = []
            parts.append("rootM[\(Self.timingModelGeometry(view))]")
            parts.append("rootP[\(Self.timingPresentationGeometry(view))]")
            if let host = hostingController?.view {
                parts.append("hostM[\(Self.timingModelGeometry(host))]")
                parts.append("hostP[\(Self.timingPresentationGeometry(host))]")
            }
            if let win = view.window {
                parts.append("winM[\(Self.timingModelGeometry(win))]")
                parts.append("winSup[\(win.superview.map { Self.timingModelGeometry($0) } ?? "nil")]")
            } else {
                parts.append("winM[nil]")
            }
            let input = panelInputView
            let bg = view.backgroundColor.map { "\($0)" } ?? "nil"
            parts.append(
                "opaque=\(view.isOpaque) bg=\(bg) selfSizing=\(inputView?.allowsSelfSizing ?? false) budget=\(input?.panelHeight ?? -1)"
            )
            return parts.joined(separator: " ")
        }

        private static func timingModelGeometry(_ v: UIView) -> String {
            let l = v.layer
            let t = l.transform
            let tf =
                CATransform3DIsIdentity(t) ? "I" : String(format: "[%.2f,%.2f,%.2f,%.2f]", t.m11, t.m12, t.m21, t.m22)
            return String(
                format:
                    "frame=(%.1f,%.1f,%.1f,%.1f) bounds=(%.1f,%.1f,%.1f,%.1f) pos=(%.1f,%.1f) anchor=(%.2f,%.2f) tf=%@ op=%@ hidden=%@",
                l.frame.origin.x, l.frame.origin.y, l.frame.width, l.frame.height,
                l.bounds.origin.x, l.bounds.origin.y, l.bounds.width, l.bounds.height,
                l.position.x, l.position.y, l.anchorPoint.x, l.anchorPoint.y,
                tf, l.isOpaque ? "1" : "0", l.isHidden ? "1" : "0")
        }

        private static func timingPresentationGeometry(_ v: UIView) -> String {
            guard let p = v.layer.presentation() else { return "nil" }
            return String(
                format: "frame=(%.1f,%.1f,%.1f,%.1f) bounds=(%.1f,%.1f,%.1f,%.1f) pos=(%.1f,%.1f)",
                p.frame.origin.x, p.frame.origin.y, p.frame.width, p.frame.height,
                p.bounds.origin.x, p.bounds.origin.y, p.bounds.width, p.bounds.height,
                p.position.x, p.position.y)
        }

        // MARK: Translation capability probe
        //
        // One fixed synthetic translation ("Hello", en -> ja) when the App Group switch
        // `debug.translationProbe` is on. Uses the iOS 26+ no-UI
        // `TranslationSession(installedSource:target:)`, which cannot request model downloads,
        // so no network or download UI is involved. Never reads host text or user data.

        private static let translationProbeKey = "debug.translationProbe"

        func startTranslationProbeIfEnabled() {
            guard KeyboardRecipeStore.sharedDefaults()?.bool(forKey: Self.translationProbeKey) == true,
                translationProbeTask == nil
            else { return }
            // Keep the non-Sendable session off the main actor: create and use it inside one
            // nonisolated async function instead of passing it across isolation boundaries.
            translationProbeTask = Task { await Self.runTranslationProbe() }
        }

        private nonisolated static func runTranslationProbe() async {
            let logger = Logger.debugProbe
            guard #available(iOS 26.0, *) else {
                logger.notice(
                    "translationProbe unavailable os=\(ProcessInfo.processInfo.operatingSystemVersionString, privacy: .public)"
                )
                return
            }
            let source = Locale.Language(identifier: "en")
            let target = Locale.Language(identifier: "ja")
            let availability = LanguageAvailability()
            let status = await availability.status(from: source, to: target)
            let supportedCount = await availability.supportedLanguages.count
            let session = TranslationSession(installedSource: source, target: target)
            let canRequestDownloads = session.canRequestDownloads
            let isReady = await session.isReady
            logger.notice(
                "translationProbe stage=session pid=\(ProcessInfo.processInfo.processIdentifier, privacy: .public) role=\(DebugProbe.currentRole, privacy: .public) status=\(String(describing: status), privacy: .public) supported=\(supportedCount, privacy: .public) canRequestDownloads=\(canRequestDownloads, privacy: .public) isReady=\(isReady, privacy: .public) source=\(String(describing: session.sourceLanguage), privacy: .public) target=\(String(describing: session.targetLanguage), privacy: .public) sample=Hello en-ja"
            )
            let started = ProcessInfo.processInfo.systemUptime
            do {
                let response = try await session.translate("Hello")
                let elapsed = String(format: "%.1f", (ProcessInfo.processInfo.systemUptime - started) * 1000)
                logger.notice(
                    "translationProbe stage=result pid=\(ProcessInfo.processInfo.processIdentifier, privacy: .public) outcome=success elapsedMs=\(elapsed, privacy: .public) targetText=\(response.targetText, privacy: .public)"
                )
            } catch {
                let elapsed = String(format: "%.1f", (ProcessInfo.processInfo.systemUptime - started) * 1000)
                logger.notice(
                    "translationProbe stage=result pid=\(ProcessInfo.processInfo.processIdentifier, privacy: .public) outcome=error elapsedMs=\(elapsed, privacy: .public) error=\(String(describing: error), privacy: .public)"
                )
            }
        }
    }
#endif
