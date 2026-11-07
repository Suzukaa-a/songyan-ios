import Darwin
import Foundation

/// Resolve external dependencies against the *actual file inventories* of plum's official
/// preset repositories. No filename-to-brand guess, no unbounded GitHub code search.
public enum RimeSourceDependencies {
    public static func acquire(
        for explicit: [AcquiredRimeSource], existingFiles: [String: Data] = [:],
        sharedOpenCCDirectory: URL? = nil,
        progress: @escaping @Sendable (String) -> Void = { _ in }
    ) async throws -> [AcquiredRimeSource] {
        // One ephemeral transport for the whole dependency resolution: every index
        // query and every dependency download shares it instead of one session per file.
        let transport = HTTPSResourceTransport()
        defer { transport.invalidate() }
        var dependencies: [AcquiredRimeSource] = []
        var inventories: [String: Set<String>]? = nil
        for _ in 0..<16 {
            try Task.checkCancellation()
            let sources = dependencies + explicit
            var files = existingFiles
            for source in sources {
                for (path, data) in source.files
                where source.recipe.installPatterns.contains(where: { fnmatch($0, path, FNM_PATHNAME) == 0 }) {
                    files[path] = data
                }
                // Declared external bytes are supplied in the following explicit UI step;
                // do not replace them with an unrelated repository's similarly named file.
                for resource in source.recipe.downloads where files[resource.path] == nil {
                    files[resource.path] = Data()
                }
            }
            let closure = try SchemeSourceCheck.dependencyClosure(files)
            let missing = (closure.required + closure.optional).filter { path in
                guard path.hasPrefix("opencc/"), let sharedOpenCCDirectory else { return true }
                return !FileManager.default.fileExists(
                    atPath: sharedOpenCCDirectory.appendingPathComponent(String(path.dropFirst(7))).path)
            }
            if missing.isEmpty { return sources }
            let optional = Set(closure.optional)
            if inventories == nil {
                progress(PackageText.string("dependencies.progress.querying"))
                var found: [String: Set<String>] = [:]
                for order in try await RimeSourceOrder.expand(":preset", transport: transport) {
                    struct Tree: Decodable {
                        struct Entry: Decodable {
                            let path: String
                            let type: String
                        }
                        let truncated: Bool
                        let tree: [Entry]
                    }
                    let url = URL(
                        string: "https://api.github.com/repos/\(order.repository)/git/trees/HEAD?recursive=1")!
                    let tree = try JSONDecoder().decode(
                        Tree.self, from: await transport.read(url, maximumBytes: 8 * 1024 * 1024))
                    guard !tree.truncated else {
                        throw RecipeInstallError.invalidResource(
                            PackageText.format("dependencies.error.indexTruncated", order.repository))
                    }
                    found[order.repository] = Set(tree.tree.filter { $0.type == "blob" }.map(\.path))
                }
                inventories = found
            }
            var providers = Set<String>()
            let acquired = Set(sources.map { $0.order.repository })
            for path in missing {
                let matches = inventories!.filter { $0.value.contains(path) }.map(\.key)
                guard matches.count == 1, let provider = matches.first, !acquired.contains(provider) else {
                    // A reverse lookup or preset vocabulary nobody provides is left out, as librime leaves it.
                    if optional.contains(path) { continue }
                    throw RecipeInstallError.invalidResource(
                        PackageText.format("dependencies.error.noUniqueProvider", path))
                }
                providers.insert(provider)
            }
            if providers.isEmpty { return sources }
            for repository in providers.sorted() {
                let sourceBytes = (dependencies + explicit).reduce(0) {
                    $0 + $1.files.values.reduce(0) { $0 + $1.count }
                }
                let modelBytes = (dependencies + explicit).reduce(0) {
                    $0 + $1.models.values.reduce(0) { $0 + $1.size }
                }
                progress(PackageText.format("dependencies.progress.downloading", repository))
                var dependency = try await AcquiredRimeSource.fetch(
                    RimeSourceOrder(repository),
                    sourceBudget: RecipeResourceBudget.sourceTotal - sourceBytes,
                    modelBudget: RecipeResourceBudget.modelTotal - modelBytes, progress: progress,
                    transport: transport)
                dependency.isDependency = true
                dependencies.append(dependency)
            }
        }
        throw RecipeInstallError.invalidResource(PackageText.string("dependencies.error.tooDeep"))
    }
}
