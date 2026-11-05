import Foundation
import KeyboardCore
import RimeKit
import os

/// One atomic file per resource/schema/switch: independent Host/extension edits do
/// not overwrite other switches. Inject the same directory to share preferences.
public struct OptionStore: Sendable {
    public let directory: URL
    public init(directory: URL) { self.directory = directory }

    private func file(_ option: EngineOptionDescriptor) -> URL {
        [option.resourceID, option.schemaID, option.choiceGroup.first ?? option.name].reduce(directory) { url, key in
            url.appendingPathComponent(key.utf8.map { String(format: "%02x", $0) }.joined())
        }.appendingPathExtension("json")
    }

    public func value(for option: EngineOptionDescriptor) throws -> Bool? {
        let url = file(option)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let data = try Data(contentsOf: url)
        if !option.choiceGroup.isEmpty {
            let selected = try JSONDecoder().decode(String.self, from: data)
            guard option.choiceGroup.contains(selected) else { return nil }
            return selected == option.name
        }
        return try JSONDecoder().decode(Bool.self, from: data)
    }

    public func save(_ value: Bool, for option: EngineOptionDescriptor) throws {
        try FileManager.default.createDirectory(
            at: file(option).deletingLastPathComponent(), withIntermediateDirectories: true)
        if !option.choiceGroup.isEmpty {
            guard value else { throw CocoaError(.fileWriteInvalidFileName) }
            try JSONEncoder().encode(option.name).write(to: file(option), options: .atomic)
        } else {
            try JSONEncoder().encode(value).write(to: file(option), options: .atomic)
        }
    }
}

/// Process-wide FIFO for preference reads/writes and diagnostic receipts. Enqueue
/// happens synchronously, before the returned Task can run on another actor.
/// This is separate from the read-only KeyboardResourceReadQueue.
enum OptionPersistenceIO {
    private static let queue = DispatchQueue(label: "rime.option-persistence", qos: .utility)

    static func enqueue<T: Sendable>(_ body: @escaping @Sendable () throws -> T) -> Task<T, Error> {
        let result = Pending<T>()
        queue.async { result.finish(Result(catching: body)) }
        return Task { try await result.value() }
    }

    /// Startup only: callers already run off-main on EngineOpQueue.
    static func preload<T>(_ body: () throws -> T) rethrows -> T {
        precondition(!Thread.isMainThread, "Preference preload must run off-main")
        return try queue.sync(execute: body)
    }

    private final class Pending<T: Sendable>: Sendable {
        private let state = OSAllocatedUnfairLock<(result: Result<T, Error>?, waiter: CheckedContinuation<T, Error>?)>(
            initialState: (nil, nil))
        func finish(_ result: Result<T, Error>) {
            let waiter = state.withLock { state in
                state.result = result
                defer { state.waiter = nil }
                return state.waiter
            }
            waiter?.resume(with: result)
        }
        func value() async throws -> T {
            try await withCheckedThrowingContinuation { continuation in
                let ready = state.withLock { state -> Result<T, Error>? in
                    if let result = state.result { return result }
                    state.waiter = continuation
                    return nil
                }
                if let ready { continuation.resume(with: ready) }
            }
        }
    }
}

struct OptionPreferenceKey: Hashable, Sendable {
    let resourceID: String
    let schemaID: String
    let name: String
    init(_ descriptor: EngineOptionDescriptor, name: String? = nil) {
        resourceID = descriptor.resourceID
        schemaID = descriptor.schemaID
        self.name = name ?? descriptor.name
    }
}

/// Engine preference snapshot: late reads and older writes cannot replace a newer
/// local choice. Errors remain errors; nil means no saved override.
// Mutable state is guarded by `lock`.
final class OptionPreferenceCache: @unchecked Sendable {
    struct SaveOutcome: Sendable {
        let isCurrent: Bool
        let result: Result<Void, Error>
    }
    private let lock = NSLock()
    private var values: [OptionPreferenceKey: Result<Bool?, Error>] = [:]
    private var revisions: [OptionPreferenceKey: UInt64] = [:]
    private let read: @Sendable (EngineOptionDescriptor) throws -> Bool?
    private let write: @Sendable (Bool, EngineOptionDescriptor) throws -> Void
    /// False while the store is read-only: a choice then lives in this cache for the
    /// session, and later refreshes keep it.
    private let persists: @Sendable () -> Bool
    private var sessionOnly: Set<OptionPreferenceKey> = []

    init(store: OptionStore, persists: @escaping @Sendable () -> Bool = { true }) {
        read = { try store.value(for: $0) }
        write = { try store.save($0, for: $1) }
        self.persists = persists
    }
    /// Inject disk boundaries for the production-source concurrency probe.
    init(
        read: @escaping @Sendable (EngineOptionDescriptor) throws -> Bool?,
        write: @escaping @Sendable (Bool, EngineOptionDescriptor) throws -> Void,
        persists: @escaping @Sendable () -> Bool = { true }
    ) {
        self.read = read
        self.write = write
        self.persists = persists
    }

    func value(for descriptor: EngineOptionDescriptor) throws -> Bool? {
        lock.lock()
        let result = values[OptionPreferenceKey(descriptor)] ?? .success(nil)
        lock.unlock()
        return try result.get()
    }

    func preload(_ descriptors: [EngineOptionDescriptor]) {
        lock.lock()
        let versions = revisions
        lock.unlock()
        OptionPersistenceIO.preload { refresh(descriptors, versions: versions) }
    }

    func beginRefresh(_ descriptors: [EngineOptionDescriptor]) -> Task<Void, Error> {
        lock.lock()
        defer { lock.unlock() }
        let versions = revisions
        return OptionPersistenceIO.enqueue { [self] in refresh(descriptors, versions: versions) }
    }

    private func refresh(_ descriptors: [EngineOptionDescriptor], versions: [OptionPreferenceKey: UInt64]) {
        var seen: Set<OptionPreferenceKey> = []
        for descriptor in descriptors where seen.insert(OptionPreferenceKey(descriptor)).inserted {
            let result = Result { try read(descriptor) }
            lock.lock()
            if !sessionOnly.contains(OptionPreferenceKey(descriptor)),
                revisions[OptionPreferenceKey(descriptor), default: 0]
                    == versions[OptionPreferenceKey(descriptor), default: 0]
            {
                values[OptionPreferenceKey(descriptor)] = result
            }
            lock.unlock()
        }
    }

    func beginSave(_ value: Bool, for descriptor: EngineOptionDescriptor) -> Task<SaveOutcome, Error> {
        lock.lock()
        defer { lock.unlock() }
        let revision = revisions[OptionPreferenceKey(descriptor), default: 0] &+ 1
        let keys =
            descriptor.choiceGroup.isEmpty
            ? [OptionPreferenceKey(descriptor)]
            : descriptor.choiceGroup.map { OptionPreferenceKey(descriptor, name: $0) }
        for key in keys {
            revisions[key] = revision
            values[key] = .success(descriptor.choiceGroup.isEmpty ? value : key.name == descriptor.name)
        }
        guard persists() else {
            sessionOnly.formUnion(keys)
            return Task { SaveOutcome(isCurrent: true, result: .success(())) }
        }
        sessionOnly.subtract(keys)
        return OptionPersistenceIO.enqueue { [self] in
            let result = Result { try write(value, descriptor) }
            lock.lock()
            defer { lock.unlock() }
            let current = revisions[OptionPreferenceKey(descriptor)] == revision
            if current, case .failure(let error) = result {
                for key in keys { values[key] = .failure(error) }
            }
            return SaveOutcome(isCurrent: current, result: result)
        }
    }
}

/// Conservative reader for librime's emitted (expanded) build/*.schema.yaml.
/// It deliberately does not interpret source YAML includes/patches, Lua filters,
/// arbitrary OpenCC transforms, or unknown serializations as supported features.
enum SchemaOptionCapabilities {
    /// Read the selected schema's own switch reset value; no engine session is created.
    static func defaultValue(for option: EngineOptionDescriptor, compiledDirectory: URL) -> Bool {
        guard
            let yaml = try? String(
                contentsOf: compiledDirectory.appendingPathComponent(option.schemaID + ".schema.yaml"), encoding: .utf8),
            let api = rime_get_api()
        else { return false }
        var config = RimeConfig()
        defer { _ = api.pointee.config_close(&config) }
        guard yaml.withCString({ api.pointee.config_load_string(&config, $0) }) != 0 else { return false }
        let count = Int(api.pointee.config_list_size(&config, "switches"))
        for index in 0..<count {
            let path = "switches/@\(index)"
            let name = (path + "/name").withCString { key in
                api.pointee.config_get_cstring(&config, key).map { String(cString: $0) }
            }
            if !option.choiceGroup.isEmpty {
                let members = Int(api.pointee.config_list_size(&config, (path + "/options")))
                for member in 0..<members {
                    let value = (path + "/options/@\(member)").withCString { key in
                        api.pointee.config_get_cstring(&config, key).map { String(cString: $0) }
                    }
                    if value == option.name {
                        var reset: Int32 = 0
                        _ = (path + "/reset").withCString { api.pointee.config_get_int(&config, $0, &reset) }
                        return Int(reset) == member
                    }
                }
            }
            if name == option.name {
                var value: Int32 = 0
                _ = (path + "/reset").withCString { api.pointee.config_get_int(&config, $0, &value) }
                return value != 0
            }
        }
        return false
    }

    static func read(
        resourceID: String, schemaID: String, compiledDirectory: URL,
        sharedDirectory: URL
    ) -> [EngineOptionDescriptor] {
        guard !resourceID.isEmpty,
            let yaml = try? String(
                contentsOf: compiledDirectory.appendingPathComponent(schemaID + ".schema.yaml"),
                encoding: .utf8)
        else { return [] }
        return parse(resourceID: resourceID, schemaID: schemaID, yaml: yaml) {
            verifiedOpenCC($0, sharedDirectory: sharedDirectory)
        }
    }

    static func parse(
        resourceID: String, schemaID: String, yaml: String,
        openccKind: (String) -> String?
    ) -> [EngineOptionDescriptor] {
        var sections: [String: [String]] = [:]
        var section = ""
        for line in yaml.components(separatedBy: .newlines) where !line.isEmpty {
            if !line.hasPrefix(" "), line.hasSuffix(":"), !line.hasPrefix("#") {
                section = String(line.dropLast())
            } else if !line.hasPrefix("#") {
                sections[section, default: []].append(line)
            }
        }
        func scalar(_ text: String) -> String {
            text.trimmingCharacters(in: .whitespaces).trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
        }
        func depth(_ text: String) -> Int { text.prefix(while: { $0 == " " }).count }
        func field(_ lines: [String], _ key: String) -> String? {
            guard let top = lines.filter({ !$0.trimmingCharacters(in: .whitespaces).isEmpty }).map(depth).min(),
                let line = lines.first(where: {
                    depth($0) == top && $0.trimmingCharacters(in: .whitespaces).hasPrefix(key + ":")
                })
            else { return nil }
            let value = scalar(String(line.trimmingCharacters(in: .whitespaces).dropFirst(key.count + 1)))
            return value.isEmpty ? nil : value
        }
        func list(_ lines: [String], _ key: String) -> [String] {
            if let value = field(lines, key), value.hasPrefix("["), value.hasSuffix("]") {
                return value.dropFirst().dropLast().split(separator: ",").map { scalar(String($0)) }
            }
            guard let start = lines.firstIndex(where: { $0.trimmingCharacters(in: .whitespaces) == key + ":" }) else {
                return []
            }
            let indent = depth(lines[start])
            return lines.dropFirst(start + 1).prefix(while: {
                depth($0) > indent || (depth($0) == indent && $0.trimmingCharacters(in: .whitespaces).hasPrefix("- "))
            })
            .filter { $0.trimmingCharacters(in: .whitespaces).hasPrefix("- ") }
            .map { scalar(String($0.trimmingCharacters(in: .whitespaces).dropFirst(2))) }
        }
        let switchLines = sections["switches"] ?? []
        let itemDepth = switchLines.filter { $0.trimmingCharacters(in: .whitespaces).hasPrefix("- ") }.map(depth).min()
        var items: [[String]] = []
        for line in switchLines {
            if depth(line) == itemDepth, line.trimmingCharacters(in: .whitespaces).hasPrefix("- ") {
                items.append([
                    String(repeating: " ", count: depth(line) + 2)
                        + String(line.trimmingCharacters(in: .whitespaces).dropFirst(2))
                ])
            } else if !items.isEmpty {
                items[items.count - 1].append(line)
            }
        }
        var filters: [String] = []
        var filterDepth: Int?
        for line in sections["engine"] ?? [] {
            let text = line.trimmingCharacters(in: .whitespaces)
            if text == "filters:" {
                filterDepth = depth(line)
                continue
            }
            guard let indent = filterDepth else { continue }
            if text.hasPrefix("- "), depth(line) >= indent {
                filters.append(scalar(String(text.dropFirst(2))))
            } else if depth(line) <= indent {
                break
            }
        }
        var conversions: [String: String] = [:]
        // The schema's own OpenCC config per switch: the input language reads the real declaration,
        // never a converter guessed from the presentation kind.
        var declaredConfigs: [String: String] = [:]
        var driven = Set<String>()
        for filter in filters where filter == "simplifier" || filter.hasPrefix("simplifier@") {
            let namespace = filter == "simplifier" ? filter : String(filter.dropFirst("simplifier@".count))
            let fields = sections[namespace] ?? []
            let name = field(fields, "option_name") ?? "simplification"
            if driven.insert(name).inserted {
                let config = field(fields, "opencc_config") ?? "t2s.json"
                conversions[name] = openccKind(config)
                if conversions[name] != nil { declaredConfigs[name] = config }
            }
        }
        var result: [EngineOptionDescriptor] = []
        for item in items {
            if let name = field(item, "name") {
                guard let title = name == "full_shape" ? "全角" : conversions[name] else { continue }
                result.append(
                    .init(
                        resourceID: resourceID, schemaID: schemaID, name: name,
                        title: title, disabledLabel: "关闭", enabledLabel: "开启",
                        declaredConversion: declaredConfigs[name]))
                continue
            }
            let options = list(item, "options"), labels = list(item, "states")
            guard options.count >= 2, labels.count == options.count, labels.allSatisfy({ !$0.isEmpty }),
                Set(options).count == options.count
            else { continue }
            let kinds = options.compactMap { conversions[$0] }
            guard !kinds.isEmpty, kinds.allSatisfy({ $0 == "繁体输出" || $0 == "简体输出" }),
                !options.contains(where: { driven.contains($0) && conversions[$0] == nil })
            else { continue }
            for (index, option) in options.enumerated() {
                result.append(
                    .init(
                        resourceID: resourceID, schemaID: schemaID, name: option,
                        title: "字形", disabledLabel: labels[index], enabledLabel: labels[index],
                        choiceGroup: options, choiceLabel: labels[index],
                        declaredConversion: declaredConfigs[option]))
            }
        }
        var seen = Set<String>()
        return result.filter { seen.insert($0.name).inserted }
    }

    static func verifiedOpenCC(_ config: String, sharedDirectory: URL) -> String? {
        let root = sharedDirectory.appendingPathComponent("opencc").standardizedFileURL
        func resolve(_ path: String) -> URL? {
            let url = root.appendingPathComponent(path).standardizedFileURL
            return url.path.hasPrefix(root.path + "/") && FileManager.default.fileExists(atPath: url.path) ? url : nil
        }
        guard let url = resolve(config), let data = try? Data(contentsOf: url),
            let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        else { return nil }
        func validDict(_ dict: [String: Any]) -> Bool {
            switch dict["type"] as? String {
            case "group":
                guard let dicts = dict["dicts"] as? [[String: Any]], !dicts.isEmpty else { return false }
                return dicts.allSatisfy(validDict)
            case "text", "ocd2", "ocd":
                guard let path = dict["file"] as? String, let file = resolve(path),
                    let size = try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize
                else { return false }
                return size > 0
            default: return false
            }
        }
        guard let chain = json["conversion_chain"] as? [[String: Any]], !chain.isEmpty,
            chain.allSatisfy({ ($0["dict"] as? [String: Any]).map(validDict) == true }),
            let segmentation = json["segmentation"] as? [String: Any],
            let dict = segmentation["dict"] as? [String: Any], validDict(dict)
        else { return nil }
        let name = json["name"] as? String ?? ""
        if name == "Emoji" || name.hasSuffix(" to Emoji") { return "Emoji 候选" }
        if name.contains("Simplified Chinese to Traditional Chinese")
            || name.contains("Traditional Chinese to Traditional Chinese")
        {
            return "繁体输出"
        }
        if name.contains("Traditional Chinese to Simplified Chinese") { return "简体输出" }
        switch config {
        case "s2t.json", "s2tw.json", "s2hk.json", "t2tw.json", "t2hk.json", "t2hkf.json": return "繁体输出"
        case "t2s.json": return "简体输出"
        case "emoji.json": return "Emoji 候选"
        default: return nil
        }
    }
}
