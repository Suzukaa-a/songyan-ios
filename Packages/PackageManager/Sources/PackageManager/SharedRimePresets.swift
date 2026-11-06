import Foundation

/// Frontend-owned configuration, distinct from package source and private dictionaries.
/// Missing prelude files are supplied from the frontend copy, and the kagiroi scheme
/// gets the install-time patch it needs beside the package; Rime retains ownership of
/// include/custom/patch merge semantics.
enum SharedRimePresets {
    static let revision = "082425ea0684bca36474415d4a0e8db9b016487e"
    static let configurationNames = ["default.yaml", "key_bindings.yaml", "punctuation.yaml", "symbols.yaml"]

    static func supplement(
        _ files: inout [String: Data], openCCDirectory: URL? = nil, enabledSchemaIDs: [String]? = nil
    ) throws {
        // Use the frontend's real OpenCC distribution, including binary dictionaries.
        // These bytes belong only to the effective workspace, never recipe source candidates.
        if let directory = openCCDirectory {
            let info = try directory.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            guard info.isDirectory == true, info.isSymbolicLink != true else {
                throw RecipeInstallError.invalidResource(PackageText.string("presets.error.invalidOpenCCDirectory"))
            }
            for url in try FileManager.default.contentsOfDirectory(
                at: directory, includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
            {
                let path = "opencc/" + url.lastPathComponent
                guard SchemeSourceCheck.safe(path) else { throw RecipeInstallError.invalidResource(path) }
                if files[path] != nil { continue }
                let info = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
                guard info.isRegularFile == true, info.isSymbolicLink != true,
                    let size = info.fileSize, size <= RecipeResourceBudget.sourceFile
                else {
                    throw RecipeInstallError.invalidResource(path)
                }
                files[path] = try Data(contentsOf: url)
            }
        }
        let schemas =
            enabledSchemaIDs
            ?? InstalledPackageLayout.topLevelSchemaFiles(in: files.keys)
            .map { String($0.dropLast(12)) }.sorted()
        for name in configurationNames where files[name] == nil {
            var data = try bundled(name)
            if name == "default.yaml" {
                // The upstream distribution list names optional packages. This frontend installs
                // selected schemas instead; retain every other upstream preset verbatim.
                let text = String(decoding: data, as: UTF8.self)
                let list =
                    schemas.isEmpty
                    ? "schema_list: []\n" : "schema_list:\n" + schemas.map { "  - schema: \($0)\n" }.joined()
                data = Data(
                    text.replacingOccurrences(
                        of: "(?m)^schema_list:\\n(?:  - schema: [^\\n]+\\n)*", with: list, options: .regularExpression
                    ).utf8)
            }
            files[name] = data
        }
        // Keep attribution with installed readable sources as well as in the app bundle.
        for name in ["LICENSE", "AUTHORS", "PROVENANCE.md", "COPYING"] {
            let path = "frontend-rime-prelude/" + name
            if files[path] == nil { files[path] = try bundled(name) }
        }
        // Scheme-specific patches travel beside the source, never inside it.
        JapaneseSchemePresets.supplement(&files)
    }

    static func bundled(_ name: String) throws -> Data {
        guard let root = Bundle.module.url(forResource: "RimePrelude", withExtension: nil) else {
            throw RecipeInstallError.invalidResource(PackageText.string("presets.error.missingPrelude"))
        }
        return try Data(contentsOf: root.appendingPathComponent(name))
    }
}
