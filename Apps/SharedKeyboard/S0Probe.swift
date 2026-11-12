#if DEBUG
    import Darwin
    import Foundation
    import OSLog
    import Security
    import UIKit
    import os

    /// S0 verification probes (Debug only, opt-in, bounded).
    ///
    /// The porting plan asks five questions before a script engine can be planned: how much
    /// text a keyboard extension actually receives (`selectedText` and the `documentContext*`
    /// pair), whether Keychain items written by the host app are readable inside the extension,
    /// whether the extension can reach the network at all (plaintext LAN and HTTPS, with and
    /// without Full Access), how much memory the extension process may still allocate, and what
    /// a QuickJS runtime costs inside that process (probe builds only, see the engine section).
    ///
    /// Everything recorded here is a length, a status code or a byte size: no input text, no
    /// candidate text, no Keychain value. Results are logged on the `DebugProbe` category as
    /// `s0Probe ...` lines and, when the shared container accepts writes, also written to
    /// `Library/Caches/s0-probe-<role>.json` in the App Group container.
    ///
    /// Gate: the App Group default `debug.s0Probe` (set by Tools/CI/scripts/s0-probe.sh) or
    /// `SONGYAN_S0_PROBE=1` in the host app's launch environment; a probe build compiles
    /// `SONGYAN_S0_PROBE` into both targets so an installed device build samples without either.
    /// Release builds contain none of this file's code.
    enum S0Probe {
        static let enabledKey = "debug.s0Probe"
        static let httpURLKey = "debug.s0ProbeHTTPURL"
        static let httpsURLKey = "debug.s0ProbeHTTPSURL"

        private static let logger = Logger.debugProbe
        private static let keychainService = "app.songyan.s0probe"
        /// Account names are probe-local and carry no user data. Each access group dimension gets
        /// its own account so one side's write can never satisfy the other side's query by
        /// accident: the extension's own item is written under a different account than the host's.
        private static let defaultHostAccount = "probe-host-default"
        private static let appGroupHostAccount = "probe-host-appgroup"
        private static let defaultExtensionAccount = "probe-extension-default"
        private static let appGroupExtensionAccount = "probe-extension-appgroup"
        /// Fixed non-secret marker; probes only report whether it came back and how long it is.
        private static let keychainMarker = Data("songyan-s0-probe-marker".utf8)
        private static let writeQueue = DispatchQueue(label: "app.songyan.s0probe", qos: .utility)
        private static let results = OSAllocatedUnfairLock<[String: Any]>(uncheckedState: [:])
        private static let appearanceCounter = OSAllocatedUnfairLock<Int>(uncheckedState: 0)
        /// Count of text/selection callbacks seen; a counter only, because those fire while typing.
        private static let changeCounter = OSAllocatedUnfairLock<Int>(uncheckedState: 0)
        private static let sampleCount = OSAllocatedUnfairLock<Int>(uncheckedState: 0)
        private static let skippedSensitive = OSAllocatedUnfairLock<Int>(uncheckedState: 0)
        private static let pendingContextSample = OSAllocatedUnfairLock<DispatchWorkItem?>(uncheckedState: nil)
        private static let networkStarted = OSAllocatedUnfairLock<Bool>(uncheckedState: false)
        private static let keychainStarted = OSAllocatedUnfairLock<Bool>(uncheckedState: false)
        private static let containerWriteChecked = OSAllocatedUnfairLock<Bool>(uncheckedState: false)
        /// Bumped when the recorded fields change shape, so an artifact can be told apart.
        static let probeVersion = 3

        /// Read once per process. The extension reads it from the App Group defaults at first
        /// use; the host app also accepts the launch environment, so a scripted run can enable
        /// the probe without touching preferences first.
        static var enabled: Bool { isEnabled }

        #if SONGYAN_S0_PROBE
            /// A probe build compiles the switch into both targets: an installed device build can
            /// be given neither an App Group default nor a launch environment from the outside.
            private static let isEnabled = true
        #else
            private static let isEnabled: Bool = {
                if ProcessInfo.processInfo.environment["SONGYAN_S0_PROBE"] == "1" { return true }
                return KeyboardRecipeStore.sharedDefaults()?.bool(forKey: enabledKey) ?? false
            }()
        #endif

        static var currentRole: String {
            Bundle.main.bundleURL.pathExtension == "appex" ? "keyboardExtension" : "hostApp"
        }

        // MARK: - Input context (lengths only)

        #if SONGYAN_S0_PROBE
            /// Requested from the text and selection callbacks, which run while typing. The callback
            /// itself only counts and arms one debounce timer: no proxy read, no disk write. A burst of
            /// changes therefore produces one sample, taken on the main queue after the burst, and the
            /// sample is logged only, so typing never costs a file write. The provider returns nil once
            /// the controller no longer owns the host, because a proxy must not be read after teardown.
            /// Compiled only into the S0 probe build (`SONGYAN_S0_PROBE`): an ordinary Debug build has
            /// no change sampling at all.
            static func contextAfterChange(event: String, proxy: @escaping () -> UITextDocumentProxy?) {
                guard enabled else { return }
                changeCounter.withLockUnchecked { $0 += 1 }
                let work = DispatchWorkItem {
                    pendingContextSample.withLockUnchecked { $0 = nil }
                    guard let proxy = proxy() else { return }
                    sampleCount.withLockUnchecked { $0 += 1 }
                    sampleContext(proxy, event: "change-\(event)", hasFullAccess: nil, storeArtifact: false)
                }
                pendingContextSample.withLockUnchecked { pending in
                    pending?.cancel()
                    pending = work
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.25, execute: work)
            }
        #endif

        /// One sample of what the host shows the extension around the caret, taken on appearance
        /// where the callback is not a typing path. Lengths only: no text is read out or kept.
        static func contextOnAppearance(_ proxy: UITextDocumentProxy, hasFullAccess: Bool) {
            guard enabled else { return }
            let appearance = appearanceCounter.withLockUnchecked { value -> Int in
                value += 1
                return value
            }
            sampleContext(
                proxy, event: "appear", appearance: appearance, hasFullAccess: hasFullAccess,
                storeArtifact: true)
        }

        /// Never sampled: secure-entry fields and password / one-time-code fields. Only a fixed
        /// marker is logged for a skipped field, so neither its type name nor any value is recorded.
        private static func isSensitiveField(_ proxy: UITextDocumentProxy) -> Bool {
            if proxy.isSecureTextEntry == true { return true }
            switch proxy.textContentType {
            case UITextContentType.password, UITextContentType.newPassword, UITextContentType.oneTimeCode:
                return true
            default:
                return false
            }
        }

        private static func sampleContext(
            _ proxy: UITextDocumentProxy, event: String, appearance: Int? = nil,
            hasFullAccess: Bool?, storeArtifact: Bool
        ) {
            guard !isSensitiveField(proxy) else {
                skippedSensitive.withLockUnchecked { $0 += 1 }
                logger.notice(
                    "s0Probe context role=\(currentRole, privacy: .public) event=\(event, privacy: .public) skipped=sensitiveField"
                )
                return
            }
            let selected = proxy.selectedText
            let before = proxy.documentContextBeforeInput
            let after = proxy.documentContextAfterInput
            let appearance = appearance ?? appearanceCounter.withLockUnchecked { $0 }
            let selectedChars = selected?.count ?? -1
            let selectedUnits = selected?.utf16.count ?? -1
            let beforeChars = before?.count ?? -1
            let beforeUnits = before?.utf16.count ?? -1
            let afterChars = after?.count ?? -1
            let afterUnits = after?.utf16.count ?? -1
            let keyboardType = Int((proxy.keyboardType ?? .default).rawValue)
            let returnKeyType = Int((proxy.returnKeyType ?? .default).rawValue)
            let contentType = proxy.textContentType?.rawValue ?? "-"
            let reading = memory()
            let fields: [String: Any] = [
                "event": event,
                "appearance": appearance,
                "changesSeen": changeCounter.withLockUnchecked { $0 },
                "samplesTaken": sampleCount.withLockUnchecked { $0 },
                "selectedNil": selected == nil ? 1 : 0,
                "selectedChars": selectedChars,
                "selectedUTF16": selectedUnits,
                "beforeNil": before == nil ? 1 : 0,
                "beforeChars": beforeChars,
                "beforeUTF16": beforeUnits,
                "afterNil": after == nil ? 1 : 0,
                "afterChars": afterChars,
                "afterUTF16": afterUnits,
                "hasText": proxy.hasText ? 1 : 0,
                "keyboardType": keyboardType,
                "returnKeyType": returnKeyType,
                "autocapitalization": Int((proxy.autocapitalizationType ?? .none).rawValue),
                "contentType": contentType,
                "fullAccess": hasFullAccess.map { $0 ? 1 : 0 } ?? -1,
                "footprintBytes": reading.footprint,
                "availableBytes": reading.available,
            ]
            if storeArtifact {
                store("context", fields)
            }
            logger.notice(
                """
                s0Probe context role=\(currentRole, privacy: .public) event=\(event, privacy: .public) \
                appearance=\(appearance, privacy: .public) selectedNil=\(selected == nil ? 1 : 0, privacy: .public) \
                selectedChars=\(selectedChars, privacy: .public) selectedUTF16=\(selectedUnits, privacy: .public) \
                beforeNil=\(before == nil ? 1 : 0, privacy: .public) beforeChars=\(beforeChars, privacy: .public) \
                beforeUTF16=\(beforeUnits, privacy: .public) afterNil=\(after == nil ? 1 : 0, privacy: .public) \
                afterChars=\(afterChars, privacy: .public) hasText=\(proxy.hasText ? 1 : 0, privacy: .public) \
                keyboardType=\(keyboardType, privacy: .public) returnKeyType=\(returnKeyType, privacy: .public) \
                contentType=\(contentType, privacy: .public) \
                fullAccess=\(hasFullAccess.map { $0 ? 1 : 0 } ?? -1, privacy: .public) \
                footprintBytes=\(reading.footprint, privacy: .public) availableBytes=\(reading.available, privacy: .public)
                """)
        }

        // MARK: - Memory

        /// Current and peak physical footprint plus the bytes iOS will still let this process
        /// allocate before a jetsam kill. The last one is what a script engine has to fit into.
        struct MemoryReading {
            let footprint: UInt64
            let available: UInt64
        }

        private typealias AvailableMemoryFunction = @convention(c) () -> UInt64

        private static let availableMemoryPointer: AvailableMemoryFunction? = {
            guard let symbol = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "os_proc_available_memory") else {
                return nil
            }
            return unsafeBitCast(symbol, to: AvailableMemoryFunction.self)
        }()

        static func memory() -> MemoryReading {
            var info = task_vm_info_data_t()
            var count = mach_msg_type_number_t(
                MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
            let result = withUnsafeMutablePointer(to: &info) { pointer in
                pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { rebound in
                    task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), rebound, &count)
                }
            }
            let footprint = result == KERN_SUCCESS ? UInt64(info.phys_footprint) : 0
            let available = availableMemoryPointer?() ?? 0
            return MemoryReading(footprint: footprint, available: available)
        }

        /// Logs one memory line. Used after the panel has been laid out, when the steady-state
        /// footprint of a keyboard appearance is known.
        static func logMemory(_ stage: String) {
            guard enabled else { return }
            let reading = memory()
            logger.notice(
                """
                s0Probe memory role=\(currentRole, privacy: .public) stage=\(stage, privacy: .public) \
                footprintBytes=\(reading.footprint, privacy: .public) availableBytes=\(reading.available, privacy: .public)
                """)
        }

        // MARK: - App Group write

        /// Writes and removes one small file in the shared container. Full Access is reported
        /// separately; this is the actual permission test, so the artifact never infers one from
        /// the other. Runs once per process.
        static func appGroupWriteCheck() {
            guard enabled else { return }
            let first = containerWriteChecked.withLockUnchecked { checked -> Bool in
                if checked { return false }
                checked = true
                return true
            }
            guard first else { return }
            var result: [String: Any] = ["attempted": 0, "ok": 0, "errorCode": 0]
            if let container = KeyboardRecipeStore.sharedContainerURL() {
                let directory = container.appendingPathComponent("Library/Caches", isDirectory: true)
                let url = directory.appendingPathComponent("s0-probe-write-test.txt")
                result["attempted"] = 1
                do {
                    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                    try Data("s0".utf8).write(to: url, options: .atomic)
                    try? FileManager.default.removeItem(at: url)
                    result["ok"] = 1
                } catch {
                    result["errorCode"] = (error as NSError).code
                }
            }
            store("appGroupWrite", result)
            logger.notice(
                """
                s0Probe appGroupWrite role=\(currentRole, privacy: .public) \
                attempted=\(result["attempted"] as? Int ?? -1, privacy: .public) \
                ok=\(result["ok"] as? Int ?? -1, privacy: .public) \
                errorCode=\(result["errorCode"] as? Int ?? -1, privacy: .public)
                """)
        }

        // MARK: - Keychain

        /// Access group dimension. `unspecified` leaves the attribute out of the query, which is
        /// what production code that never names a group does: keychain services then uses the
        /// process's default group, and a search matches any group the process belongs to.
        /// `appGroup` names the App Group both targets already carry. Apple's access group list is
        /// the keychain access groups entitlement, then the app ID, then the application groups,
        /// so the existing App Group is already a shared keychain access group for both processes
        /// and no keychain entitlement is needed to measure it.
        private enum KeychainGroup: String, CaseIterable {
            case unspecified
            case appGroup
        }

        private struct KeychainClass: @unchecked Sendable {
            let name: String
            let accessibility: CFString
        }

        private static let keychainClasses = [
            KeychainClass(name: "afterFirstUnlock", accessibility: kSecAttrAccessibleAfterFirstUnlock),
            KeychainClass(name: "whenUnlocked", accessibility: kSecAttrAccessibleWhenUnlocked),
        ]

        /// One status observation. Only status codes, byte counts and whether the fixed non-secret
        /// marker came back are recorded; the marker's content is never logged or stored.
        private struct KeychainMeasurement {
            let role: String
            let action: String
            let group: KeychainGroup
            let account: String
            let itemClass: String
            let status: Int
            let found: Int
            let bytes: Int
            let same: Int

            var fields: [String: Any] {
                [
                    "role": role, "action": action, "group": group.rawValue, "account": account,
                    "class": itemClass, "status": status, "found": found, "bytes": bytes, "same": same,
                ]
            }

            var logLine: String {
                "s0Probe keychain role=\(role) action=\(action) group=\(group.rawValue) "
                    + "class=\(itemClass) status=\(status) found=\(found) bytes=\(bytes) same=\(same)"
            }
        }

        private static func keychainQuery(
            _ item: KeychainClass, account: String, group: KeychainGroup
        ) -> [String: Any] {
            var query: [String: Any] = [
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: keychainService,
                kSecAttrAccount as String: "\(account)-\(item.name)",
            ]
            if group == .appGroup {
                query[kSecAttrAccessGroup as String] = KeyboardRecipeStore.groupID
            }
            return query
        }

        private static func keychainWrite(
            _ item: KeychainClass, account: String, group: KeychainGroup
        ) -> Int {
            var query = keychainQuery(item, account: account, group: group)
            SecItemDelete(query as CFDictionary)
            query[kSecValueData as String] = keychainMarker
            query[kSecAttrAccessible as String] = item.accessibility
            return Int(SecItemAdd(query as CFDictionary, nil))
        }

        private static func keychainRead(
            _ item: KeychainClass, account: String, group: KeychainGroup
        ) -> (status: Int, found: Int, bytes: Int, same: Int) {
            var query = keychainQuery(item, account: account, group: group)
            query[kSecReturnData as String] = true
            query[kSecMatchLimit as String] = kSecMatchLimitOne
            var result: CFTypeRef?
            let status = Int(SecItemCopyMatching(query as CFDictionary, &result))
            let data = result as? Data
            return (status, data == nil ? 0 : 1, data?.count ?? -1, data == keychainMarker ? 1 : 0)
        }

        private static func wrote(
            role: String, action: String, item: KeychainClass, account: String, group: KeychainGroup
        ) -> KeychainMeasurement {
            let status = keychainWrite(item, account: account, group: group)
            return KeychainMeasurement(
                role: role, action: action, group: group, account: account, itemClass: item.name,
                status: status, found: 0, bytes: -1, same: 0)
        }

        private static func read(
            role: String, action: String, item: KeychainClass, account: String, group: KeychainGroup
        ) -> KeychainMeasurement {
            let reading = keychainRead(item, account: account, group: group)
            return KeychainMeasurement(
                role: role, action: action, group: group, account: account, itemClass: item.name,
                status: reading.status, found: reading.found, bytes: reading.bytes, same: reading.same)
        }

        private static func recordKeychain(_ measurements: [KeychainMeasurement]) {
            store("keychain", measurements.map(\.fields))
            for measurement in measurements {
                logger.notice("\(measurement.logLine, privacy: .public)")
            }
        }

        /// Host-app side. Writes the non-secret marker twice per accessibility class: once with no
        /// access group (the default group of this process, the control) and once in the App Group
        /// both processes already share. The reads are the control that both items exist.
        static func hostKeychainWrite() {
            guard enabled else { return }
            var measurements: [KeychainMeasurement] = []
            for item in keychainClasses {
                measurements.append(
                    wrote(
                        role: "hostApp", action: "writeDefault", item: item,
                        account: defaultHostAccount, group: .unspecified))
                measurements.append(
                    wrote(
                        role: "hostApp", action: "writeAppGroup", item: item,
                        account: appGroupHostAccount, group: .appGroup))
                measurements.append(
                    read(
                        role: "hostApp", action: "readOwnDefault", item: item,
                        account: defaultHostAccount, group: .unspecified))
                measurements.append(
                    read(
                        role: "hostApp", action: "readOwnAppGroup", item: item,
                        account: appGroupHostAccount, group: .appGroup))
                measurements.append(
                    read(
                        role: "hostApp", action: "readOwnAppGroupWithoutGroup", item: item,
                        account: appGroupHostAccount, group: .unspecified))
            }
            recordKeychain(measurements)
        }

        /// Extension side, once per process. The measurement that matters is whether the item the
        /// host wrote into the App Group access group is readable here; the default-group read and
        /// the extension's own writes are the controls.
        static func extensionKeychain() {
            guard enabled else { return }
            let first = keychainStarted.withLockUnchecked { started -> Bool in
                if started { return false }
                started = true
                return true
            }
            guard first else { return }
            var measurements: [KeychainMeasurement] = []
            for item in keychainClasses {
                measurements.append(
                    read(
                        role: "keyboardExtension", action: "readHostDefault", item: item,
                        account: defaultHostAccount, group: .unspecified))
                measurements.append(
                    read(
                        role: "keyboardExtension", action: "readHostAppGroup", item: item,
                        account: appGroupHostAccount, group: .appGroup))
                measurements.append(
                    read(
                        role: "keyboardExtension", action: "readHostAppGroupWithoutGroup", item: item,
                        account: appGroupHostAccount, group: .unspecified))
                measurements.append(
                    wrote(
                        role: "keyboardExtension", action: "writeOwnDefault", item: item,
                        account: defaultExtensionAccount, group: .unspecified))
                measurements.append(
                    wrote(
                        role: "keyboardExtension", action: "writeOwnAppGroup", item: item,
                        account: appGroupExtensionAccount, group: .appGroup))
                measurements.append(
                    read(
                        role: "keyboardExtension", action: "readOwnAppGroup", item: item,
                        account: appGroupExtensionAccount, group: .appGroup))
            }
            recordKeychain(measurements)
        }

        /// Collects the per-target network outcomes across concurrent data tasks.
        private final class NetworkCollector: @unchecked Sendable {
            private let lock = NSLock()
            private var stored: [(name: String, fields: [String: Any])] = []

            func append(name: String, fields: [String: Any]) {
                lock.lock()
                stored.append((name, fields))
                lock.unlock()
            }

            func entries() -> [(name: String, fields: [String: Any])] {
                lock.lock()
                defer { lock.unlock() }
                return stored
            }
        }

        /// The address the probe fetches. The App Group defaults hold it on the simulator; a probe
        /// build also embeds it in its own Info.plist, which stays readable even in a round where
        /// the shared container is not, so the network item can be measured without that read.
        private static func probeAddress(_ key: String, plistKey: String) -> String {
            if let value = KeyboardRecipeStore.sharedDefaults()?.string(forKey: key), !value.isEmpty {
                return value
            }
            return Bundle.main.object(forInfoDictionaryKey: plistKey) as? String ?? ""
        }

        // MARK: - Network

        /// Host-app control run and extension run share one implementation: the same plaintext
        /// LAN URL and the same HTTPS URL are fetched and the outcome is recorded as a status
        /// code or a URL error code. Full Access is recorded alongside, because a keyboard
        /// extension without it is supposed to be unable to reach the network at all.
        static func network(hasFullAccess: Bool, stage: String) {
            guard enabled else { return }
            let shouldRun = networkStarted.withLockUnchecked { started -> Bool in
                if started { return false }
                started = true
                return true
            }
            guard shouldRun else { return }
            let lan = probeAddress(httpURLKey, plistKey: "SongyanS0ProbeHTTPURL")
            let https = probeAddress(httpsURLKey, plistKey: "SongyanS0ProbeHTTPSURL")
            let targets: [(String, String)] = [("lan", lan), ("https", https)].filter { !$0.1.isEmpty }
            guard !targets.isEmpty else {
                logger.notice("s0Probe network role=\(currentRole, privacy: .public) skipped=noURL")
                return
            }
            let configuration = URLSessionConfiguration.ephemeral
            configuration.timeoutIntervalForRequest = 5
            configuration.timeoutIntervalForResource = 8
            configuration.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
            let session = URLSession(configuration: configuration)
            let group = DispatchGroup()
            let collected = NetworkCollector()
            for (name, urlString) in targets {
                guard let url = URL(string: urlString) else { continue }
                group.enter()
                let started = ProcessInfo.processInfo.systemUptime
                session.dataTask(with: url) { data, response, error in
                    defer { group.leave() }
                    var fields: [String: Any] = [
                        "ms": Int((ProcessInfo.processInfo.systemUptime - started) * 1000),
                        "httpStatus": (response as? HTTPURLResponse)?.statusCode ?? -1,
                        "bytes": data?.count ?? -1,
                        "plaintext": url.scheme?.lowercased() == "http" ? 1 : 0,
                    ]
                    if let error = error as NSError? {
                        fields["errorCode"] = error.code
                        fields["errorDomain"] = error.domain
                    } else {
                        fields["errorCode"] = 0
                        fields["errorDomain"] = "-"
                    }
                    collected.append(name: name, fields: fields)
                }.resume()
            }
            group.notify(queue: .main) {
                session.invalidateAndCancel()
                let entries = collected.entries()
                var merged: [String: Any] = [
                    "stage": stage,
                    "fullAccess": hasFullAccess ? 1 : 0,
                    "role": currentRole,
                ]
                for entry in entries { merged[entry.name] = entry.fields }
                store("network", merged)
                for entry in entries.sorted(by: { $0.name < $1.name }) {
                    let status = entry.fields["httpStatus"] as? Int ?? -1
                    let bytes = entry.fields["bytes"] as? Int ?? -1
                    let ms = entry.fields["ms"] as? Int ?? -1
                    let plaintext = entry.fields["plaintext"] as? Int ?? -1
                    let code = entry.fields["errorCode"] as? Int ?? -1
                    let domain = entry.fields["errorDomain"] as? String ?? "-"
                    logger.notice(
                        """
                        s0Probe network role=\(currentRole, privacy: .public) stage=\(stage, privacy: .public) \
                        target=\(entry.name, privacy: .public) fullAccess=\(hasFullAccess ? 1 : 0, privacy: .public) \
                        plaintext=\(plaintext, privacy: .public) httpStatus=\(status, privacy: .public) \
                        bytes=\(bytes, privacy: .public) ms=\(ms, privacy: .public) \
                        errorDomain=\(domain, privacy: .public) errorCode=\(code, privacy: .public)
                        """)
                }
            }
        }

        // MARK: - Engine (QuickJS inside this process)

        /// Probe builds link a QuickJS-ng archive into the extension through `S0_QUICKJS_LDFLAGS`
        /// (unset in every other build), so this code runs the engine in the extension's own process
        /// and under its own memory budget, which a spawned process cannot answer. Ordinary builds
        /// resolve no engine symbols and record `skipped=notLinked`. The tag and digest are probe
        /// inputs, not a version pin: no build setting outside a probe run names an engine.
        private static let engineStarted = OSAllocatedUnfairLock<Bool>(uncheckedState: false)
        private static let engineQueue = DispatchQueue(
            label: "app.songyan.s0probe.engine", qos: .userInitiated)

        private typealias EngineABIFunction = @convention(c) () -> Int32
        private typealias EngineTagFunction = @convention(c) () -> UnsafePointer<CChar>?
        private typealias EngineMeasureFunction =
            @convention(c) (UnsafePointer<CChar>?, UInt32, UnsafeMutablePointer<CChar>?, UInt32) -> Int32

        /// A probe build signs the archive's globals into the extension binary itself, so this needs
        /// no file for the OS to validate and would work on a device as well as in the simulator.
        private struct EngineSymbols {
            let abi: EngineABIFunction
            let tag: EngineTagFunction
            let measure: EngineMeasureFunction

            static func resolve() -> EngineSymbols? {
                let defaultHandle = UnsafeMutableRawPointer(bitPattern: -2)
                guard
                    let abiSymbol = dlsym(defaultHandle, "s0qjs_abi"),
                    let tagSymbol = dlsym(defaultHandle, "s0qjs_tag"),
                    let measureSymbol = dlsym(defaultHandle, "s0qjs_measure")
                else { return nil }
                return EngineSymbols(
                    abi: unsafeBitCast(abiSymbol, to: EngineABIFunction.self),
                    tag: unsafeBitCast(tagSymbol, to: EngineTagFunction.self),
                    measure: unsafeBitCast(measureSymbol, to: EngineMeasureFunction.self))
            }
        }

        /// One engine run: a fresh runtime and one of the shared probe workloads. A limit of 0 means
        /// no limit; the sweep's limits are inputs that find where a run stops fitting, not a chosen
        /// product limit.
        private struct EngineRun {
            let name: String
            let workload: String
            let limitMB: UInt32
        }

        private static let engineRuns = [
            EngineRun(name: "bootstrap", workload: "", limitMB: 0),
            EngineRun(name: "small", workload: "small", limitMB: 0),
            EngineRun(name: "large", workload: "large", limitMB: 0),
            EngineRun(name: "largeLimit2MB", workload: "large", limitMB: 2),
            EngineRun(name: "largeLimit4MB", workload: "large", limitMB: 4),
            EngineRun(name: "largeLimit6MB", workload: "large", limitMB: 6),
            EngineRun(name: "largeLimit8MB", workload: "large", limitMB: 8),
            EngineRun(name: "largeLimit12MB", workload: "large", limitMB: 12),
            EngineRun(name: "largeLimit16MB", workload: "large", limitMB: 16),
            EngineRun(name: "largeLimit24MB", workload: "large", limitMB: 24),
            EngineRun(name: "largeLimit32MB", workload: "large", limitMB: 32),
        ]

        /// Runs once per process, after the appearance has been handled: the engine work takes a few
        /// hundred milliseconds and must not sit in the keyboard's first layout. The engine runs on
        /// its own queue; the completion fires on that queue once every run has been recorded, or
        /// at once when no engine is linked, so a normal build still runs what comes after it.
        static func engineAfterAppearance(_ completion: @escaping @Sendable () -> Void) {
            guard enabled else { return }
            let first = engineStarted.withLockUnchecked { started -> Bool in
                if started { return false }
                started = true
                return true
            }
            guard first else { return }
            engineQueue.async {
                defer { completion() }
                guard let symbols = EngineSymbols.resolve() else {
                    store("engine", ["skipped": "notLinked"])
                    logger.notice("s0Probe engine role=\(currentRole, privacy: .public) skipped=notLinked")
                    return
                }
                var runs: [String: Any] = [:]
                var coldStartMs = 0.0
                for run in engineRuns {
                    let measured = measure(symbols, run)
                    runs[run.name] = measured
                    if run.name == "bootstrap" {
                        coldStartMs =
                            (measured["runtimeMs"] as? Double ?? 0) + (measured["bootstrapMs"] as? Double ?? 0)
                    }
                    logEngineRun(run, measured)
                }
                store(
                    "engine",
                    [
                        "abi": Int(symbols.abi()),
                        "tag": symbols.tag().map { String(cString: $0) } ?? "-",
                        "coldStartMs": coldStartMs,
                        "runs": runs,
                    ])
            }
        }

        /// Reads one engine report as key=value lines. The engine writes only lengths and sizes, so
        /// every field is a number or a status word; nothing from the host's input is involved.
        private static func measure(_ symbols: EngineSymbols, _ run: EngineRun) -> [String: Any] {
            var output = [CChar](repeating: 0, count: 2048)
            let written = run.workload.withCString { workload in
                output.withUnsafeMutableBufferPointer { buffer in
                    symbols.measure(workload, run.limitMB, buffer.baseAddress, UInt32(buffer.count))
                }
            }
            guard written > 0 else { return ["ok": 0, "error": "buffer too small"] }
            let text = output.withUnsafeBufferPointer { buffer in
                buffer.baseAddress.map { String(cString: $0) } ?? ""
            }
            var fields: [String: String] = [:]
            for line in text.split(separator: "\n") {
                guard let separator = line.firstIndex(of: "=") else { continue }
                fields[String(line[..<separator])] = String(line[line.index(after: separator)...])
            }
            let number: (String) -> Int = { Int(fields[$0] ?? "") ?? 0 }
            let decimal: (String) -> Double = { Double(fields[$0] ?? "") ?? 0 }
            let before = number("footprintBeforeBytes")
            let after = number("footprintAfterBytes")
            let peakBefore = number("peakBeforeBytes")
            let peakAfter = number("peakAfterBytes")
            return [
                "ok": number("ok"),
                "bootstrapOk": number("bootstrapOk"),
                "limitMB": number("limitMB"),
                "runtimeMs": decimal("runtimeMs"),
                "bootstrapMs": decimal("bootstrapMs"),
                "workloadMs": decimal("workloadMs"),
                "footprintBeforeBytes": before,
                "footprintAfterRuntimeBytes": number("footprintAfterRuntimeBytes"),
                "footprintAfterBytes": after,
                "footprintDeltaBytes": after - before,
                "peakBeforeBytes": peakBefore,
                "peakAfterBytes": peakAfter,
                "peakDeltaBytes": peakAfter - peakBefore,
                "availableBeforeBytes": number("availableBeforeBytes"),
                "availableAfterBytes": number("availableAfterBytes"),
                "result": fields["result"] ?? "-",
                "error": fields["error"] ?? "",
            ]
        }

        private static func logEngineRun(_ run: EngineRun, _ measured: [String: Any]) {
            logger.notice(
                """
                s0Probe engine role=\(currentRole, privacy: .public) run=\(run.name, privacy: .public) \
                ok=\(measured["ok"] as? Int ?? 0, privacy: .public) limitMB=\(run.limitMB, privacy: .public) \
                runtimeMs=\(measured["runtimeMs"] as? Double ?? 0, privacy: .public) \
                workloadMs=\(measured["workloadMs"] as? Double ?? 0, privacy: .public) \
                footprintDeltaBytes=\(measured["footprintDeltaBytes"] as? Int ?? 0, privacy: .public) \
                peakDeltaBytes=\(measured["peakDeltaBytes"] as? Int ?? 0, privacy: .public) \
                error=\(measured["error"] as? String ?? "", privacy: .public)
                """)
        }

        // MARK: - Artifact

        private static func store(_ key: String, _ value: Any) {
            results.withLockUnchecked { $0[key] = value }
            writeResults()
        }

        private static func writeResults() {
            let snapshot = results.withLockUnchecked { $0 }
            let role = currentRole
            let container = KeyboardRecipeStore.sharedContainerURL()
            writeQueue.async {
                var document = snapshot
                document["role"] = role
                document["probeVersion"] = probeVersion
                document["updated"] = ISO8601DateFormatter().string(from: Date())
                document["contextChanges"] = changeCounter.withLockUnchecked { $0 }
                document["contextSamples"] = sampleCount.withLockUnchecked { $0 }
                document["contextSkippedSensitive"] = skippedSensitive.withLockUnchecked { $0 }
                document["keychainAccounts"] = [
                    "defaultHost": defaultHostAccount, "appGroupHost": appGroupHostAccount,
                    "defaultExtension": defaultExtensionAccount, "appGroupExtension": appGroupExtensionAccount,
                ]
                document["keychainAppGroup"] = KeyboardRecipeStore.groupID
                guard let container else {
                    logger.notice("s0Probe artifact role=\(role, privacy: .public) wrote=0 reason=noContainer")
                    return
                }
                let directory = container.appendingPathComponent("Library/Caches", isDirectory: true)
                let url = directory.appendingPathComponent("s0-probe-\(role).json")
                do {
                    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                    let data = try JSONSerialization.data(
                        withJSONObject: document, options: [.prettyPrinted, .sortedKeys])
                    try data.write(to: url, options: .atomic)
                    logger.notice("s0Probe artifact role=\(role, privacy: .public) wrote=1")
                } catch {
                    logger.notice(
                        """
                        s0Probe artifact role=\(role, privacy: .public) wrote=0 \
                        error=\((error as NSError).code, privacy: .public)
                        """)
                }
            }
        }
    }

    // MARK: - Entry points

    extension S0Probe {
        /// Host app launch (Debug): control measurements that do not need the keyboard on screen.
        /// The host always has network and a writable sandbox, so its results are the control
        /// group for the extension's.
        static func hostDidLaunch() {
            guard enabled else { return }
            #if SONGYAN_S0_PROBE
                hostExportProbeArtifacts()
            #endif
            hostKeychainWrite()
            network(hasFullAccess: true, stage: "hostLaunch")
        }

        #if SONGYAN_S0_PROBE
            /// Copies the artifacts this run left in the shared container into the app's own
            /// Documents folder, which a probe build exposes to the Files app. Opening 松烟 after
            /// using the keyboard is how the report leaves a device without any device-side tool.
            static func hostExportProbeArtifacts() {
                writeQueue.async {
                    guard let container = KeyboardRecipeStore.sharedContainerURL() else { return }
                    let source = container.appendingPathComponent("Library/Caches", isDirectory: true)
                    let names =
                        (try? FileManager.default.contentsOfDirectory(atPath: source.path)) ?? []
                    let artifacts = names.filter { $0.hasPrefix("s0-probe-") && $0.hasSuffix(".json") }
                    guard !artifacts.isEmpty else { return }
                    let documents =
                        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
                        .appendingPathComponent("S0Probe", isDirectory: true)
                    try? FileManager.default.createDirectory(
                        at: documents, withIntermediateDirectories: true)
                    for name in artifacts {
                        let from = source.appendingPathComponent(name)
                        let to = documents.appendingPathComponent(name)
                        try? FileManager.default.removeItem(at: to)
                        try? FileManager.default.copyItem(at: from, to: to)
                    }
                    logger.notice(
                        """
                        s0Probe export role=\(currentRole, privacy: .public) \
                        files=\(artifacts.count, privacy: .public)
                        """)
                }
            }
        #endif

        /// Extension appearance: context lengths, Keychain readability, network reachability and
        /// the process memory budget. The Keychain and network runs happen once per process;
        /// later appearances only sample context and memory again.
        static func extensionDidAppear(_ proxy: UITextDocumentProxy, hasFullAccess: Bool) {
            guard enabled else { return }
            appGroupWriteCheck()
            contextOnAppearance(proxy, hasFullAccess: hasFullAccess)
            logMemory("appear")
            extensionKeychain()
            // The engine runs first: a fetch in flight while its footprint is sampled would add
            // socket buffers to the delta. The network probe keeps its own artifact entry.
            engineAfterAppearance {
                network(hasFullAccess: hasFullAccess, stage: "extensionAppear")
            }
        }
    }
#endif
