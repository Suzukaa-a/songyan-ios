import CandidateKit
import KeyboardCore
import SwiftUI

#if DEBUG
    import Darwin
    import Dispatch
    import Foundation
    import RimeBridge
    import SkinKit
#endif

/// Host app preference keys (shared via AppStorage), persisted in the HostApp sandbox UserDefaults.
enum HostAppKeys {
    /// Developer Options switch: off by default. When on, shows diagnostic entry points and technical details
    /// (version/commit/paths/component probes/engine self-test). The regular UI stays simple.
    static let developerOptionsEnabled = "app.songyan.settings.developerOptions"
}

@main
struct HostApp: App {

    init() {
        // Candidate renderer registration (source-level extension point; the default renderer is the production rendering path).
        CandidateRenders.installDefault()
        ConfigurationBackupModel.registerBackgroundTask()
        #if DEBUG
            DebugProbe.reportEnvironment(role: "hostApp")
        #endif
    }

    var body: some Scene {
        WindowGroup {
            Group {
                #if DEBUG
                    if DeploymentProbe.enabled {
                        ProbeLaunchView()
                    } else if GlyphProbe.enabled {
                        GlyphProbeView()
                    } else {
                        BackupReadyView()
                    }
                #else
                    BackupReadyView()
                #endif
            }
            .onOpenURL { url in
                // `songyan://` exists only so the keyboard's settings panel can come back here
                // (an extension cannot open another app any other way). Landing on the home
                // screen is right: every setting starts from there, so no route is pending.
                #if DEBUG
                    DebugOrientation.handle(url)
                #endif
            }
        }
    }
}

#if DEBUG
    /// 'xcrun simctl openurl <udid> "songyan://debug/orientation?to=landscape"' (or 'portrait') rotates the
    /// simulator without Simulator.app, so the keyboard's landscape layout can be driven from scripts.
    enum DebugOrientation {
        @MainActor static func handle(_ url: URL) {
            guard url.host == "debug", url.path == "/orientation" else { return }
            let target = URLComponents(url: url, resolvingAgainstBaseURL: false)?
                .queryItems?.first { $0.name == "to" }?.value
            let mask: UIInterfaceOrientationMask = target == "landscape" ? .landscapeRight : .portrait
            for case let scene as UIWindowScene in UIApplication.shared.connectedScenes {
                scene.requestGeometryUpdate(.iOS(interfaceOrientations: mask)) { _ in }
            }
        }
    }

    // MARK: - Deployment probe (Debug only)

    /// Keeps exploratory deployments out of the normal startup path and its persisted settings.
    enum DeploymentProbe {
        static let modeKey = "SONGYAN_DEPLOYMENT_PROBE"
        static let fixturesKey = "SONGYAN_DEPLOYMENT_PROBE_FIXTURES"
        static let expectedVersion = "1.17.0"

        static var enabled: Bool {
            !(ProcessInfo.processInfo.environment[modeKey] ?? "").trimmingCharacters(in: .whitespaces).isEmpty
        }

        /// Returns true only when the normal UI should open afterwards (mode E published successfully).
        @MainActor static func runOnce() async -> Bool {
            let environment = ProcessInfo.processInfo.environment
            let mode = (environment[modeKey] ?? "").trimmingCharacters(in: .whitespaces).uppercased()
            let fixtures = environment[fixturesKey].map { URL(fileURLWithPath: $0, isDirectory: true) }
            do {
                let outcome = try await EngineOwnershipCoordinator.shared.withExclusive {
                    if mode == "K" { return try await kanaRuntimeProbe(fixtures: fixtures) }
                    return try await EngineOpQueue.async { probe(mode: mode, fixtures: fixtures) }
                }
                print("DEPLOYMENT_PROBE_RESULT success=\(outcome.success) report=\(outcome.reportPath)")
                return mode == "E" && outcome.success
            } catch {
                print("DEPLOYMENT_PROBE_RESULT error=\(error)")
                return false
            }
        }

        private enum ProbeError: Error {
            case message(String)
        }

        private struct Outcome {
            let reportPath: String
            let success: Bool
        }

        @MainActor private static func kanaRuntimeProbe(fixtures: URL?) async throws -> Outcome {
            guard let fixtures else { throw ProbeError.message("missing kana fixture") }
            let run = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("Kana12Probe/" + UUID().uuidString, isDirectory: true)
            let reportURL = run.appendingPathComponent("report.json")
            let backend = RimeBackend(
                sharedDirectory: fixtures.appendingPathComponent("source"),
                userDirectory: run.appendingPathComponent("user"),
                prebuiltDirectory: fixtures.appendingPathComponent("compiled"))
            var report: [String: Any] = ["mode": "K", "success": false]
            var checks: [[String: Any]] = []
            var controller: KeyboardController?
            do {
                try await EngineOpQueue.async {
                    try FileManager.default.createDirectory(at: run, withIntermediateDirectories: true)
                    try backend.startIfNeeded()
                    try backend.selectSchema("kagiroi")
                }
                let keyboard = KeyboardController(layout: .qwerty26, engine: backend)
                controller = keyboard
                var committed = ""
                keyboard.onDispatchCommit = {
                    committed += $0
                    return true
                }
                func press(_ action: Kana12ViewAction) async throws {
                    keyboard.handleKana12(action)
                    for _ in 0..<200 {
                        if keyboard.session.pendingCodes.isEmpty && keyboard.kana12.queued.isEmpty { return }
                        try await Task.sleep(nanoseconds: 5_000_000)
                    }
                    throw ProbeError.message("kana queue did not settle")
                }
                func clear() async throws {
                    try await EngineOpQueue.async { backend.clearComposition() }
                    keyboard.session.refresh()
                    keyboard.resetKana12State()
                    committed = ""
                }
                func check(_ name: String, _ actual: String, _ expected: String) {
                    checks.append(["name": name, "actual": actual, "expected": expected, "passed": actual == expected])
                }
                try await press(.kana(rowId: "ka", direction: .center))
                check("first kana", keyboard.snapshot.rawInput, "か")
                try await press(.kana(rowId: "ka", direction: .center))
                check("repeated tap replaces the kana", keyboard.snapshot.rawInput, "き")
                try await clear()
                try await press(.kana(rowId: "sa", direction: .up))
                try await press(.kana(rowId: "sa", direction: .left))
                check("flick types sushi", keyboard.snapshot.rawInput, "すし")
                try await press(.enter)
                check("Return commits raw kana", committed, "すし")
                try await clear()
                try await press(.kana(rowId: "ta", direction: .up))
                try await press(.modify)
                check("modifier makes small tsu", keyboard.snapshot.rawInput, "っ")
                try await press(.modify)
                check("modifier makes voiced tsu", keyboard.snapshot.rawInput, "づ")
                try await clear()
                keyboard.kana12FlickOnly = true
                try await press(.kana(rowId: "ka", direction: .center))
                try await press(.kana(rowId: "ka", direction: .center))
                check("flick only keeps repeated kana", keyboard.snapshot.rawInput, "かか")
                let before = keyboard.snapshot.preeditCaretByte
                try await press(.cursorLeft)
                checks.append([
                    "name": "left moves composition caret without committing",
                    "passed":
                        keyboard.snapshot.isComposing && keyboard.snapshot.preeditCaretByte < before
                        && committed.isEmpty,
                ])
                report["success"] = checks.allSatisfy { $0["passed"] as? Bool == true }
                report["checks"] = checks
            } catch {
                report["checks"] = checks
                report["error"] = String(describing: error)
            }
            controller?.retire()
            let data = try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
            try await EngineOpQueue.async {
                backend.shutdown()
                try FileManager.default.createDirectory(at: run, withIntermediateDirectories: true)
                try data.write(to: reportURL)
            }
            return Outcome(reportPath: reportURL.path, success: report["success"] as? Bool == true)
        }

        private static func probe(mode: String, fixtures: URL?) -> Outcome {
            // Mode E publishes from the build mode A/B leaves behind, so it must branch before
            // the directory reset below deletes that build.
            if mode == "E" { return runtimeProbe(fixtures: fixtures) }
            // Publication measurement must not touch the deployment probe's directories: it reuses
            // the build mode B leaves there and resets only its own root.
            if mode == "P" { return publicationProbe(fixtures: fixtures) }
            let fm = FileManager.default
            let root = fixtures ?? URL(fileURLWithPath: "/nonexistent", isDirectory: true)
            let source = root.appendingPathComponent("source", isDirectory: true)
            let prebuilt = root.appendingPathComponent("prebuilt", isDirectory: true)
            let shared = mode == "A" ? source : prebuilt
            let caches = fm.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            let runDirectory = caches.appendingPathComponent("DeploymentProbe", isDirectory: true)
            let reportPath = runDirectory.appendingPathComponent("report.json").path
            let user = runDirectory.appendingPathComponent("user", isDirectory: true)
            let build = user.appendingPathComponent("build", isDirectory: true)
            let confirmationUser = runDirectory.appendingPathComponent("user-prebuilt", isDirectory: true)
            try? fm.removeItem(at: user)
            try? fm.removeItem(at: confirmationUser)
            try? fm.createDirectory(at: runDirectory, withIntermediateDirectories: true)
            try? fm.removeItem(at: URL(fileURLWithPath: reportPath))

            var report: [String: Any] = ["mode": mode]
            var seedChanges: [[String: Any]] = []
            var deployStart: CFAbsoluteTime?
            let footprint = PeakFootprint()
            footprint.start()
            do {
                if mode != "A" && mode != "B" { throw ProbeError.message("mode must be A or B") }
                guard isDirectory(shared) else { throw ProbeError.message("missing \(shared.path)") }
                guard fm.fileExists(atPath: shared.appendingPathComponent("default.yaml").path) else {
                    throw ProbeError.message("missing \(shared.path)/default.yaml")
                }
                if mode == "B" {
                    let upstream = prebuilt.appendingPathComponent("build", isDirectory: true)
                    guard isDirectory(upstream) else { throw ProbeError.message("missing \(upstream.path)") }
                    try fm.createDirectory(at: build, withIntermediateDirectories: true)
                    for item in try fm.contentsOfDirectory(at: upstream, includingPropertiesForKeys: nil)
                    where item.pathExtension == "bin" {
                        let target = build.appendingPathComponent(item.lastPathComponent)
                        try? fm.removeItem(at: target)
                        try fm.copyItem(at: item, to: target)
                        seedChanges.append(["name": item.lastPathComponent, "mtimeBefore": modificationTime(target)])
                    }
                }

                if mode == "A" {
                    try EngineSchemaSelection.seedCompiledBuild(resources: shared, user: user)
                }
                deployStart = CFAbsoluteTimeGetCurrent()
                let engine = RimeEngine(
                    configuration: .init(
                        sharedDirectory: shared, userDirectory: user, appName: "rime.songyan.deploymentprobe"))
                do { try engine.start() } catch {
                    engine.shutdown()
                    throw error
                }
                if let deployStart {
                    report["deploySeconds"] = CFAbsoluteTimeGetCurrent() - deployStart
                }
                report["version"] = engine.engineVersion
                engine.shutdown()
                guard report["version"] as? String == expectedVersion else {
                    throw ProbeError.message(
                        "engine version is not " + expectedVersion + ": "
                            + (report["version"] as? String ?? "unknown"))
                }

                if mode == "B" {
                    for index in seedChanges.indices {
                        let name = seedChanges[index]["name"] as? String ?? ""
                        seedChanges[index]["mtimeAfter"] = modificationTime(build.appendingPathComponent(name))
                    }
                }

                let prebuiltEngine = RimeEngine(
                    configuration: .init(
                        sharedDirectory: shared, userDirectory: confirmationUser,
                        appName: "rime.songyan.deploymentprobe.prebuilt", prebuiltDirectory: build))
                do { try prebuiltEngine.start() } catch {
                    prebuiltEngine.shutdown()
                    throw error
                }
                let result = nihongo(prebuiltEngine)
                prebuiltEngine.shutdown()
                report["preedit"] = result.preedit
                report["candidates"] = result.candidates
                let found = result.candidates.contains("日本語")
                report["success"] = found
                if !found { report["error"] = "nihongo candidates do not contain 日本語: \(result.candidates)" }
            } catch {
                report["success"] = false
                report["error"] = "\(error)"
                if report["deploySeconds"] == nil, let deployStart {
                    report["deploySeconds"] = CFAbsoluteTimeGetCurrent() - deployStart
                }
            }
            report["seedChanges"] = seedChanges
            report["compiledBytes"] = bytes(in: build)
            report["totalBytes"] = bytes(in: runDirectory)
            report["peakFootprintBytes"] = footprint.stop()
            let data = try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
            try? data?.write(to: URL(fileURLWithPath: reportPath), options: .atomic)
            print("DEPLOYMENT_PROBE_RESULT success=\(report["success"] ?? false) report=\(reportPath)")
            return Outcome(reportPath: reportPath, success: report["success"] as? Bool ?? false)
        }

        /// Mode E: a production publish into the simulator's real App Group, so the keyboard
        /// extension can be exercised with the kagiroi data staged for the simulator. The report
        /// is written under the host app's caches for the operator; a missing fixture fails here
        /// and leaves the previous publication untouched.
        private static func runtimeProbe(fixtures: URL?) -> Outcome {
            let fm = FileManager.default
            let caches = fm.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            let base = caches.appendingPathComponent("RuntimeProbe", isDirectory: true)
            let compiled = caches.appendingPathComponent("DeploymentProbe/user/build", isDirectory: true)
            try? fm.createDirectory(at: base, withIntermediateDirectories: true)
            let reportPath = base.appendingPathComponent("report.json").path
            try? fm.removeItem(at: URL(fileURLWithPath: reportPath))
            let fixturesRoot = fixtures ?? URL(fileURLWithPath: "/nonexistent", isDirectory: true)
            let resources = fixturesRoot.appendingPathComponent("prebuilt", isDirectory: true)
            var report: [String: Any] = ["mode": "E", "compiled": compiled.path]
            do {
                guard isDirectory(resources),
                    fm.fileExists(atPath: resources.appendingPathComponent("default.yaml").path)
                else { throw ProbeError.message("missing \(resources.path)") }
                guard isDirectory(compiled),
                    fm.fileExists(atPath: compiled.appendingPathComponent("kagiroi.schema.yaml").path)
                else { throw ProbeError.message("missing \(compiled.path), run mode A or B first") }
                // Omitting rootURL publishes into the App Group container the extension reads.
                report["root"] = try KeyboardRecipeStore.root().path
                try KeyboardRecipeStore.publish(
                    resources: resources, compiledBuild: compiled, revision: "runtime-1",
                    kind: .userScheme, packageID: "kagiroi-perf",
                    schemas: [KeyboardSchemaDescriptor(id: "kagiroi", name: "kagiroi")],
                    selectedSchemaID: "kagiroi", layout: .qwerty26,
                    publishedKeyboards: [PublishedKeyboard(schemaID: "kagiroi", layout: .qwerty26)])
                report["success"] = true
            } catch {
                report["success"] = false
                report["error"] = "\(error)"
            }
            let data = try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
            try? data?.write(to: URL(fileURLWithPath: reportPath), options: .atomic)
            print("DEPLOYMENT_PROBE_RESULT success=\(report["success"] ?? false) report=\(reportPath)")
            return Outcome(reportPath: reportPath, success: report["success"] as? Bool ?? false)
        }

        /// Repeated publication exposes large-file duplication without changing the production publisher.
        private static func publicationProbe(fixtures: URL?) -> Outcome {
            let fm = FileManager.default
            let caches = fm.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            let base = caches.appendingPathComponent("PublicationProbe", isDirectory: true)
            let reportPath = base.appendingPathComponent("report.json").path
            let published = base.appendingPathComponent("root", isDirectory: true)
            try? fm.removeItem(at: base)
            try? fm.createDirectory(at: published, withIntermediateDirectories: true)

            let fixturesRoot = fixtures ?? URL(fileURLWithPath: "/nonexistent", isDirectory: true)
            let resources = fixturesRoot.appendingPathComponent("prebuilt", isDirectory: true)
            let compiled = caches.appendingPathComponent("DeploymentProbe/user/build", isDirectory: true)
            let revisions = ["1", "2"]
            var report: [String: Any] = ["mode": "P", "publishedRoot": published.path, "revisions": revisions]
            do {
                guard isDirectory(resources),
                    fm.fileExists(atPath: resources.appendingPathComponent("default.yaml").path)
                else { throw ProbeError.message("missing \(resources.path)") }
                guard isDirectory(compiled),
                    fm.fileExists(atPath: compiled.appendingPathComponent("default.yaml").path)
                else { throw ProbeError.message("missing \(compiled.path), run mode B first") }
                var generations: [String] = []
                for revision in revisions {
                    try KeyboardRecipeStore.publish(
                        resources: resources, compiledBuild: compiled, revision: revision,
                        rootURL: published, kind: .userScheme, packageID: "kagiroi-probe",
                        schemas: [KeyboardSchemaDescriptor(id: "kagiroi", name: "kagiroi")],
                        selectedSchemaID: "kagiroi", layout: .qwerty26)
                    let active = try Data(contentsOf: published.appendingPathComponent("active.json"))
                    let record = try JSONSerialization.jsonObject(with: active) as? [String: Any]
                    guard let generation = record?["generation"] as? String else {
                        throw ProbeError.message("active.json has no generation after revision \(revision)")
                    }
                    generations.append(generation)
                }
                let versions = published.appendingPathComponent("versions", isDirectory: true)
                let present = generations.filter {
                    fm.fileExists(atPath: versions.appendingPathComponent($0).path)
                }
                report["generations"] = generations
                report["versionCount"] = (try? fm.contentsOfDirectory(atPath: versions.path))?.count ?? 0
                // Success means both publishes succeeded and both versions still exist; the ratio is
                // reported separately and never turns a completed measurement into a failure.
                report["success"] = present.count == generations.count
                if present.count != generations.count {
                    report["error"] = "published generations are missing on disk"
                }
            } catch {
                report["success"] = false
                report["error"] = "\(error)"
            }
            let usage = diskUsage(in: published)
            let compiledBytes = diskUsage(in: compiled).logical
            report["logicalBytes"] = usage.logical
            report["uniqueBytes"] = usage.unique
            report["compiledBytes"] = compiledBytes
            let ratio = compiledBytes > 0 ? Double(usage.unique) / Double(compiledBytes) : 0
            report["ratio"] = ratio
            report["needsSharing"] = ratio > 1.3
            let data = try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
            try? data?.write(to: URL(fileURLWithPath: reportPath), options: .atomic)
            print("DEPLOYMENT_PROBE_RESULT success=\(report["success"] ?? false) report=\(reportPath)")
            return Outcome(reportPath: reportPath, success: report["success"] as? Bool ?? false)
        }

        /// Deduplicates by device/inode so entries sharing storage count once.
        private static func diskUsage(in directory: URL) -> (logical: Int64, unique: Int64) {
            var logical: Int64 = 0
            var unique: Int64 = 0
            var seen = Set<String>()
            guard
                let enumerator = FileManager.default.enumerator(
                    at: directory, includingPropertiesForKeys: [.isRegularFileKey])
            else { return (logical, unique) }
            for case let item as URL in enumerator {
                guard (try? item.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true else {
                    continue
                }
                var info = stat()
                guard item.path.withCString({ stat($0, &info) }) == 0 else { continue }
                logical += Int64(info.st_size)
                if seen.insert("\(info.st_dev):\(info.st_ino)").inserted {
                    unique += Int64(info.st_size)
                }
            }
            return (logical, unique)
        }

        private static func nihongo(_ engine: RimeEngine) -> (preedit: String, candidates: [String]) {
            guard engine.selectSchema("kagiroi") else { return ("", []) }
            engine.clearComposition()
            guard let state = (try? engine.processKeySequence("nihongo"))?.state else { return ("", []) }
            return (state.preedit, state.candidates.prefix(5).map(\.text))
        }

        private static func bytes(in directory: URL) -> Int64 {
            guard
                let enumerator = FileManager.default.enumerator(
                    at: directory, includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey])
            else { return 0 }
            var total: Int64 = 0
            for case let item as URL in enumerator {
                guard let values = try? item.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey]),
                    values.isRegularFile == true
                else { continue }
                total += Int64(values.fileSize ?? 0)
            }
            return total
        }

        private static func modificationTime(_ url: URL) -> Double {
            ((try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast)
                .timeIntervalSince1970
        }

        private static func isDirectory(_ url: URL) -> Bool {
            var isDirectory: ObjCBool = false
            return FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) && isDirectory.boolValue
        }

        final class PeakFootprint: @unchecked Sendable {
            private let lock = NSLock()
            private var peak: UInt64 = 0
            private var timer: DispatchSourceTimer?

            func start() {
                let timer = DispatchSource.makeTimerSource(queue: DispatchQueue(label: "app.songyan.deploymentprobe"))
                timer.schedule(deadline: .now(), repeating: .milliseconds(50))
                timer.setEventHandler { [weak self] in self?.sample() }
                timer.resume()
                self.timer = timer
            }

            func stop() -> UInt64 {
                timer?.cancel()
                timer = nil
                sample()
                lock.lock()
                defer { lock.unlock() }
                return peak
            }

            private func sample() {
                var info = task_vm_info_data_t()
                var count = mach_msg_type_number_t(
                    MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
                let result = withUnsafeMutablePointer(to: &info) { pointer in
                    pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { rebound in
                        task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), rebound, &count)
                    }
                }
                let footprint = result == KERN_SUCCESS ? info.phys_footprint : 0
                lock.lock()
                peak = max(peak, footprint)
                lock.unlock()
            }
        }
    }

    /// Host root while a deployment probe starts. Modes A/B/P only measure and keep the blank
    /// probe screen; mode E publishes first and then opens the normal UI, so the host's engine
    /// never starts while a publication is being written.
    private struct ProbeLaunchView: View {
        @State private var released = false

        var body: some View {
            if released {
                HostRootView()
            } else {
                Color.clear.task {
                    if await DeploymentProbe.runOnce() { released = true }
                }
            }
        }
    }
    // MARK: - Glyph rendering probe (Debug only)

    /// Selects the glyph rendering fixture instead of the normal UI with 'SONGYAN_GLYPH_PROBE=1'.
    /// It exists so a simulator screenshot can compare the same fixed characters in each input language
    /// through the production candidate renderer; it reads no user text and is not built into Release.
    enum GlyphProbe {
        static let modeKey = "SONGYAN_GLYPH_PROBE"
        static var enabled: Bool {
            (ProcessInfo.processInfo.environment[modeKey] ?? "") == "1"
        }
    }

    /// The production candidate renderer with three fixed characters per input language: one collapsed
    /// candidate row and one expanded flow each. Font and colours come from the same skin resolution as
    /// the keyboard, so the screenshot shows exactly what a candidate would draw.
    private struct GlyphProbeView: View {
        private let texts = ["直", "骨", "海"]
        private let languages: [InputLanguage] = [.simplifiedChinese, .traditionalChinese, .japanese]
        private let appearance = KeyboardAppearance(skin: .systemDefault, dark: false)

        var body: some View {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    Text("字形渲染检查：同样的文字，不同输入语言")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                    ForEach(languages, id: \.rawValue) { language in
                        VStack(alignment: .leading, spacing: 4) {
                            Text(verbatim: language.rawValue).font(.caption.weight(.semibold))
                            collapsedRow(language)
                            expandedRows(language).frame(height: 88)
                        }
                    }
                }
                .padding(16)
            }
            .environment(
                \.candidateSkinToken,
                CandidateSkinToken(
                    candidateColor: Color(uiColor: appearance.text(on: "panel")),
                    secondaryColor: Color(uiColor: appearance.text(on: "panel", secondary: true)),
                    accentColor: appearance.accentForeground,
                    panelColor: appearance.color("panel"),
                    fontFamily: appearance.skin.typography.family,
                    fontWeight: appearance.skin.typography.weight)
            )
            .background(appearance.color("panel"))
        }

        private func collapsedRow(_ language: InputLanguage) -> some View {
            CandidateRendererRegistry.renderer(id: DefaultCandidateAreaRenderer.rendererID)
                .makeCollapsed(context(language, expanded: false))
                .frame(height: 44)
        }

        private func expandedRows(_ language: InputLanguage) -> some View {
            CandidateRendererRegistry.renderer(id: DefaultCandidateAreaRenderer.rendererID)
                .makeExpanded(context(language, expanded: true))
        }

        private func context(_ language: InputLanguage, expanded: Bool) -> CandidateAreaContext {
            let candidates = texts.enumerated().map { Candidate(index: $0.offset, text: $0.element) }
            let state = CandidatePresentationState(
                preedit: "zhi gu hai", rawInput: "zhiguhai",
                candidates: candidates, highlightedIndex: 0,
                pageIndex: 0, canPageBackward: false, canPageForward: false, isComposing: true)
            return CandidateAreaContext(
                state: state, bar: .systemDefault,
                actions: CandidateAreaActionSink { _ in },
                typography: CandidateTypography(candidateSize: 24, secondarySize: 12),
                isExpanded: expanded, inputLanguage: language)
        }
    }

#endif
