import CryptoKit
import Darwin
import Foundation

public struct AcquiredRimeSource: Sendable {
    public let order: RimeSourceOrder
    public let revision: String
    public let files: [String: Data]
    public let models: [String: RecipeFileResource]
    public let recipe: DeclarativeRecipe
    public internal(set) var isDependency: Bool = false
    public var archivePrefix: String { "source-repositories/" + order.repository + "/" }
    public var externalResources: [RecipeExternalResource] { recipe.downloads }

    public static func fetch(
        _ order: RimeSourceOrder,
        sourceBudget: Int = RecipeResourceBudget.sourceTotal,
        modelBudget: Int = RecipeResourceBudget.modelTotal,
        progress: @escaping @Sendable (String) -> Void = { _ in }
    ) async throws -> Self {
        let transport = HTTPSResourceTransport()
        defer { transport.invalidate() }
        return try await fetch(
            order, sourceBudget: sourceBudget, modelBudget: modelBudget,
            progress: progress, transport: transport)
    }

    /// Batch entry point: `transport` is reused for the metadata reads and every file of
    /// this source (and, via `RimeSourceDependencies.acquire`, the whole dependency closure)
    /// instead of creating one ephemeral session per file.
    static func fetch(
        _ order: RimeSourceOrder,
        sourceBudget: Int,
        modelBudget: Int,
        progress: @escaping @Sendable (String) -> Void,
        transport: HTTPSResourceTransport
    ) async throws -> Self {
        struct Commit: Decodable { let sha: String }
        struct Tree: Decodable {
            struct Entry: Decodable {
                let path: String
                let mode: String
                let type: String
                let size: Int?
            }
            let truncated: Bool
            let tree: [Entry]
        }
        let escaped = (order.ref ?? "HEAD").addingPercentEncoding(withAllowedCharacters: .alphanumerics)!
        let commitURL = URL(string: "https://api.github.com/repos/\(order.repository)/commits/\(escaped)")!
        let commit = try JSONDecoder().decode(
            Commit.self, from: await transport.read(commitURL, maximumBytes: 8 * 1024 * 1024))
        guard commit.sha.range(of: "^[a-f0-9]{40}$", options: .regularExpression) != nil else {
            throw RecipeInstallError.invalidResource(PackageText.string("source.error.versionUnavailable"))
        }
        progress("\(order.repository) @ \(commit.sha.prefix(10))")
        let treeURL = URL(
            string: "https://api.github.com/repos/\(order.repository)/git/trees/\(commit.sha)?recursive=1")!
        let tree = try JSONDecoder().decode(
            Tree.self, from: await transport.read(treeURL, maximumBytes: 8 * 1024 * 1024))
        guard !tree.truncated, tree.tree.count <= 20_000 else {
            throw RecipeInstallError.invalidResource(PackageText.string("source.error.treeTruncated"))
        }
        if let unsupported = tree.tree.first(where: { $0.type == "commit" || $0.mode == "120000" }) {
            throw RecipeInstallError.invalidResource(
                PackageText.format("source.error.submoduleOrSymlink", order.repository + "/" + unsupported.path))
        }
        let entries = tree.tree.filter { entry in
            guard entry.type == "blob" else { return false }
            let path = entry.path.lowercased()
            return SchemeSourceCheck.isRuntimeSourceFile(entry.path)
                || path == "license" || path == "copying" || path == "build/.gitkeep"
        }
        var sizes: [String: Int] = [:]
        for entry in entries {
            guard SchemeSourceCheck.safe(entry.path), let size = entry.size else {
                throw RecipeInstallError.invalidResource(PackageText.format("source.error.invalidEntry", entry.path))
            }
            // Generated artifacts are never fetched into the original resource pool.
            if entry.path.hasPrefix("build/") && entry.path != "build/.gitkeep" { continue }
            sizes[entry.path] = size
        }
        var files: [String: Data] = [:], models: [String: RecipeFileResource] = [:]
        let selectedPath = order.recipe.isEmpty ? "recipe.yaml" : order.recipe + ".recipe.yaml"
        var selected: DeclarativeRecipe?
        if let size = sizes[selectedPath] {
            let url = URL(
                string: "https://raw.githubusercontent.com/\(order.repository)/\(commit.sha)/\(selectedPath)")!
            let bytes = try await transport.read(url, maximumBytes: size)
            selected = try DeclarativeRecipe(path: selectedPath, source: bytes)
            if !order.recipe.isEmpty, selected?.declaredName != order.recipe {
                throw RecipeInstallError.invalidResource(
                    PackageText.format("source.error.recipeMismatch", selectedPath))
            }
            files[selectedPath] = bytes
        }
        if let selected {
            sizes = sizes.filter { path, _ in
                !RecipeResourceBudget.isModel(path)
                    || selected.installPatterns.contains { fnmatch($0, path, FNM_PATHNAME) == 0 }
            }
        }
        try RecipeResourceBudget.validate(sizes)
        guard sizes.filter({ !RecipeResourceBudget.isModel($0.key) }).values.reduce(0, +) <= sourceBudget,
            sizes.filter({ RecipeResourceBudget.isModel($0.key) }).values.reduce(0, +) <= modelBudget
        else {
            throw RecipeInstallError.invalidResource(PackageText.string("source.error.totalTooLarge"))
        }
        for path in sizes.keys.sorted() {
            try Task.checkCancellation()
            if files[path] != nil { continue }
            if RecipeResourceBudget.isModel(path), let selected,
                !selected.installPatterns.contains(where: { fnmatch($0, path, FNM_PATHNAME) == 0 })
            {
                continue
            }
            let escapedPath = path.split(separator: "/").map {
                String($0).addingPercentEncoding(withAllowedCharacters: .urlPathAllowed)!
            }.joined(separator: "/")
            let url = URL(string: "https://raw.githubusercontent.com/\(order.repository)/\(commit.sha)/\(escapedPath)")!
            progress(PackageText.format("source.progress.downloading", order.repository, path))
            if RecipeResourceBudget.isModel(path) {
                models[path] = try await RecipeFileResource.download(
                    from: url, directory: FileManager.default.temporaryDirectory,
                    maximumBytes: sizes[path]!, transport: transport)
                guard models[path]!.size == sizes[path] else {
                    throw RecipeInstallError.invalidResource(PackageText.format("source.error.modelSizeMismatch", path))
                }
                let handle = try FileHandle(forReadingFrom: models[path]!.url)
                let head = try handle.read(upToCount: 128) ?? Data()
                try handle.close()
                guard !head.starts(with: Data("version https://git-lfs.github.com/spec/".utf8)) else {
                    throw RecipeInstallError.invalidResource(PackageText.format("source.error.gitLFS", path))
                }
            } else {
                let data = try await transport.read(url, maximumBytes: sizes[path]!)
                guard data.count == sizes[path],
                    !data.starts(with: Data("version https://git-lfs.github.com/spec/".utf8))
                else {
                    throw RecipeInstallError.invalidResource(PackageText.format("source.error.sizeOrGitLFS", path))
                }
                files[path] = data
            }
        }
        let recipePath = order.recipe.isEmpty ? "recipe.yaml" : order.recipe + ".recipe.yaml"
        let recipe: DeclarativeRecipe
        if let source = files[recipePath] {
            recipe = try DeclarativeRecipe(path: recipePath, source: source)
        } else if !order.recipe.isEmpty {
            throw RecipeInstallError.invalidResource(
                PackageText.format("source.error.recipeMissing", order.repository + "/" + recipePath))
        } else {
            // Match install_files_from_package, including its exclusion of user custom.
            var paths = sizes.keys.filter { path in
                if !path.contains("/") {
                    return path.hasSuffix(".txt") || path.hasSuffix(".gram") || Prediction.isDatabasePath(path)
                        || (path.hasSuffix(".yaml") && path != "recipe.yaml" && !path.hasSuffix(".custom.yaml")
                            && !path.hasSuffix(".recipe.yaml"))
                }
                return path.hasPrefix("opencc/") && path.split(separator: "/").count == 2
                    && [".json", ".ocd", ".txt"].contains(where: path.hasSuffix)
            }.sorted()
            guard !paths.isEmpty else {
                throw RecipeInstallError.invalidResource(
                    PackageText.format("source.error.defaultRecipeMissing", order.repository))
            }
            // Plum's legacy root-file glob is a seed, not a complete modern
            // source package: dictionaries and @* Lua modules can live in subdirectories.
            // Prefer this repository's actual bytes before looking for external providers.
            paths = try SchemeSourceCheck.expandingLocalDependencies(paths, inventory: files)
            let selectedFiles = files.filter { paths.contains($0.key) }
            let requiredModels = SchemeGrammarRequirements.paths(in: selectedFiles).filter { models[$0] == nil }
            let downloads = requiredModels.compactMap { path -> String? in
                guard let url = SchemeGrammarRequirements.suggestedURL(for: path) else { return nil }
                paths.append(path)
                return "  - \(path)::\(url.absoluteString)\n"
            }
            let text =
                "recipe:\n  description: " + PackageText.string("recipe.description.sourceDependencies") + "\n"
                + (downloads.isEmpty ? "" : "download_files:\n" + downloads.joined())
                + "install_files:\n" + paths.sorted().map { "  - " + $0 + "\n" }.joined()
            recipe = try DeclarativeRecipe(path: "keyboard-default.recipe.yaml", source: Data(text.utf8))
        }
        return Self(order: order, revision: commit.sha, files: files, models: models, recipe: recipe)
    }
}
