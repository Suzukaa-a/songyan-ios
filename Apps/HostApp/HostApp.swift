import CandidateKit
import KeyboardCore
import SwiftUI

#if DEBUG
    import Darwin
    import Dispatch
    import Foundation
    import RimeBridge
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
        #if DEBUG
            DebugProbe.reportEnvironment(role: "hostApp")
        #endif
    }

    var body: some Scene {
        WindowGroup {
            Group {
                #if DEBUG
                    if DeploymentProbe.enabled {
                        Color.clear.task { await DeploymentProbe.runOnce() }
                    } else {
                        HostRootView()
                    }
                #else
                    HostRootView()
                #endif
            }
            // 'songyan://' exists only so the keyboard's settings panel can come back here
            // (an extension cannot open another app any other way). Landing on the home
            // screen is right: every setting starts from there, so no route is pending.
            .onOpenURL { url in
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

        @MainActor static func runOnce() async {
            let environment = ProcessInfo.processInfo.environment
            let mode = (environment[modeKey] ?? "").trimmingCharacters(in: .whitespaces).uppercased()
            let fixtures = environment[fixturesKey].map { URL(fileURLWithPath: $0, isDirectory: true) }
            do {
                let reportPath = try await EngineOwnershipCoordinator.shared.withExclusive {
                    try await EngineOpQueue.async { probe(mode: mode, fixtures: fixtures) }
                }
                print("DEPLOYMENT_PROBE_RESULT report=\(reportPath)")
            } catch {
                print("DEPLOYMENT_PROBE_RESULT error=\(error)")
            }
        }

        private enum ProbeError: Error {
            case message(String)
        }

        private static func probe(mode: String, fixtures: URL?) -> String {
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
            return reportPath
        }

        /// Repeated publication exposes large-file duplication without changing the production publisher.
        private static func publicationProbe(fixtures: URL?) -> String {
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
            return reportPath
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
#endif
