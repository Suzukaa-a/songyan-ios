import Foundation
import KeyboardCore
import PackageManager
import SwiftUI

/// First-launch routing: strict, asynchronous, and never scans directories in `App.init`.
///
/// Only a strictly decodable, usable publication record or install receipt counts as
/// "already configured". Empty directories, leftover staging/log files and corrupt JSON do not,
/// so upgrading users are not misrouted and new users are not skipped past onboarding.
@MainActor
enum HostLaunchRouter {

    /// - Parameter activationRoot: test injection only (App Group root); nil in production.
    static func hasUsableConfiguration(
        activationRoot: URL? = nil,
        includeStores: Bool = true
    ) async -> Bool {
        // 1) App Group publication record: `snapshot(selectedOnly:)` strictly validates the generation,
        //    enabled manifest and compiled schemes; any failure throws, meaning no usable publication.
        //    Disk reads go through the resource read queue, off the main thread.
        if let snapshot = try? await KeyboardResourceReadQueue.async({
            try KeyboardRecipeStore.snapshot(rootURL: activationRoot, selectedOnly: true)
        }),
            !ProductionInputAvailability.isBuiltin(resourceID: snapshot.activation.resourceID)
        {
            return true
        }
        guard includeStores else { return false }
        // 2) Strictly decoded install receipts (generic import source / dictionary build).
        if await InstalledConfigurationProbe.hasAnyActiveInstallation(inPackageStoreRoot: SchemeImportCenter.storeRoot)
        {
            return true
        }
        if await InstalledConfigurationProbe.hasActiveInstallation(inStoreRoot: DictionaryImportCenter.storeRoot) {
            return true
        }
        return false
    }
}

/// Host root view: checks the persisted completion flag first, then decides whether to probe asynchronously.
///
///  - First frame: `onboardingCompleted == true` renders the home screen directly, with no probe
///    or loading state and no full-screen `ProgressView` flash; only incomplete users are probed.
///  - The probe runs in `task`, not by enumerating directories synchronously in `App.init`.
///  - Only strictly decoded real records are trusted; leftover files cannot cause a false positive.
///  - "Skip onboarding" enters the home screen without writing the completion flag.
struct HostRootView: View {
    @AppStorage(AppSettings.onboardingCompletedKey) private var onboardingCompleted = false
    @State private var probeRoute: LaunchConfigurationPolicy.Route?

    var body: some View {
        Group {
            switch LaunchConfigurationPolicy.initialRoute(onboardingCompleted: onboardingCompleted) {
            case .main:
                // Completed: home screen on the first frame, no probe or loading state.
                MainTabView()
            case .probe, .onboarding:
                switch probeRoute {
                case .none:
                    DelayedSpinner().frame(maxHeight: .infinity)
                case .some(.main), .some(.probe):
                    MainTabView()
                case .some(.onboarding):
                    OnboardingView(
                        presentation: .standalone,
                        onFinish: { finishOnboarding() },
                        onSkip: { skipOnboarding() })
                }
            }
        }
        .task {
            // Completed users must never trigger the probe.
            guard LaunchConfigurationPolicy.initialRoute(onboardingCompleted: onboardingCompleted) == .probe,
                probeRoute == nil
            else { return }
            let route = LaunchConfigurationPolicy.routeAfterProbe(
                hasUsableConfiguration: await HostLaunchRouter.hasUsableConfiguration())
            // A usable configuration counts as completed onboarding, so later cold starts go straight home.
            if route == .main { onboardingCompleted = true }
            probeRoute = route
        }
    }

    /// Onboarding finished: write the completion flag and enter the home screen.
    private func finishOnboarding() {
        onboardingCompleted = true
        probeRoute = .main
    }

    /// Skipped: enter the home screen this time without writing the flag (the next launch re-decides from the real configuration).
    private func skipOnboarding() {
        probeRoute = .main
    }
}

// MARK: - Loading

/// The one way a page shows it is still reading. Reads are usually done within a frame or two, so
/// nothing shows at first; a slow read then gets a quiet spinner that fades in. No caption: what the
/// page is reading is already in its title.
struct DelayedSpinner: View {
    @State private var visible = false

    var body: some View {
        ProgressView()
            .frame(maxWidth: .infinity)
            .opacity(visible ? 1 : 0)
            .accessibilityHidden(!visible)
            .task {
                try? await Task.sleep(for: .milliseconds(400))
                guard !Task.isCancelled else { return }
                withAnimation(.easeIn(duration: 0.2)) { visible = true }
            }
    }
}

extension View {
    /// Covers a page that has nothing to show yet with `DelayedSpinner`, instead of a loading row
    /// that the content replaces a moment later.
    func loadingOverlay(_ loading: Bool) -> some View {
        overlay {
            if loading { DelayedSpinner().frame(maxHeight: .infinity) }
        }
    }
}
