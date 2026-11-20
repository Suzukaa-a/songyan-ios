"""Exercise the production preparation gate with real on-disk capability fixtures."""
import sys
import unittest

from swift_probe import ROOT, compile_swift, run, scratch_directory, section


@unittest.skipUnless(sys.platform == "darwin", "requires macOS Swift")
class KeyboardPreparationReuseTests(unittest.TestCase):
    def test_reuses_only_matching_compiled_capabilities(self):
        adapter = (ROOT / "Apps/HostApp/CompactAdapterDeployment.swift").read_text()
        registry = section(adapter, "    static func registeredRequests(", "    /// Reuse the compiled")
        reuse = section(adapter, "    static func canReuseBuild(", "    /// Deploy-callback")
        routing = section(adapter, "    /// One route per source", "    /// Whether a requested combination")
        available = section(adapter, "    static func combinationAvailable(", "\n}\n") + "\n"
        source = r'''
import Foundation
import KeyboardCore

enum RecipeInstallError: Error { case invalidResource(String) }
struct SchemePackageDeclaration: Decodable {
    struct Binding: Decodable { let layout: String; let schemaID: String }
    let bindings: [Binding]
}
enum CompactSchemaAdapter { static let displayGeneratorVersion = 6 }
enum CompactAdapterDeployment {
    static let generatorVersionFileName = "keyboard-adapter-generator.txt"
// METHODS
}
@main struct Probe {
    static func main() throws {
        let root = URL(fileURLWithPath: CommandLine.arguments[1])
        let resources = root.appendingPathComponent("resources")
        let user = root.appendingPathComponent("user")
        let build = user.appendingPathComponent("build")
        let fm = FileManager.default
        try fm.createDirectory(at: resources, withIntermediateDirectories: true)
        try fm.createDirectory(at: build, withIntermediateDirectories: true)
        let schemas = [KeyboardSchemaDescriptor(id: "custom", name: "自定义", alphabet: "abc")]
        let native = PublishedKeyboard(schemaID: "custom", layout: .qwerty26)
        let compact = PublishedKeyboard(schemaID: "custom", layout: .phone9)
        func reusable(
            _ list: [PublishedKeyboard],
            folds: (PublishedKeyboard) -> [KeyboardLayoutKind: CompactFold?] = { _ in [:] }
        ) throws -> Bool {
            try CompactAdapterDeployment.canReuseBuild(resourceURL: resources,
                userDataURL: user, enabledSchemas: schemas, requested: list, folds: folds)
        }
        precondition(try !reusable([native]), "Missing compiled schema must rebuild")
        let stamp = build.appendingPathComponent("keyboard-adapter-generator.txt")
        precondition(!CompactAdapterDeployment.generatorIsCurrent(build: build), "A missing stamp is outdated")
        try Data("5".utf8).write(to: stamp)
        precondition(!CompactAdapterDeployment.generatorIsCurrent(build: build), "An older stamp is outdated")
        try Data("schema: custom".utf8).write(to: build.appendingPathComponent("custom.schema.yaml"))
        precondition(try !reusable([native]), "An older generator must regenerate")
        try Data("6".utf8).write(to: stamp)
        precondition(CompactAdapterDeployment.generatorIsCurrent(build: build), "The current stamp is up to date")
        try Data("schema: custom".utf8).write(to: build.appendingPathComponent("custom.schema.yaml"))
        precondition(try reusable([native]), "Native keyboard must skip full reinstall")
        precondition(try !reusable([compact]), "New compact keyboard must generate")
        precondition(try !reusable([PublishedKeyboard(schemaID: "absent", layout: .qwerty26)]))
        let record = KeyboardResourceSet.EncodingAdapter(sourceSchemaID: "custom", schemaID: "custom_t9", layout: .phone9)
        try JSONEncoder().encode([record]).write(to: build.appendingPathComponent("keyboard-adapters.json"))
        precondition(try !reusable([native]), "Deleting a compact keyboard must remove its adapter")
        precondition(try !reusable([compact]), "Missing companion must rebuild")
        try Data("schema: companion".utf8).write(to: build.appendingPathComponent("custom_t9.schema.yaml"))
        precondition(try reusable([compact, native]), "Existing capabilities can be reused")
        try fm.removeItem(at: build.appendingPathComponent("custom_t9.schema.yaml"))
        precondition(try !reusable([compact]), "Deleted artifact must invalidate preparation")
        try Data("schema: companion".utf8).write(to: build.appendingPathComponent("custom_t9.schema.yaml"))
        try fm.removeItem(at: build.appendingPathComponent("keyboard-adapters.json"))

        // A keyboard drawing a 9-key layout of its own grouping needs that grouping's companion.
        var own = CompactFold.phone9.map
        own["c"] = "3"
        let ownFold = CompactFold.of(kind: .phone9, map: own)!
        let drawsOwn: (PublishedKeyboard) -> [KeyboardLayoutKind: CompactFold?] = { _ in [.phone9: ownFold] }
        try JSONEncoder().encode([record]).write(to: build.appendingPathComponent("keyboard-adapters.json"))
        precondition(try !reusable([compact], folds: drawsOwn), "Another grouping must generate its companion")
        let ownRecord = KeyboardResourceSet.EncodingAdapter(
            sourceSchemaID: "custom", schemaID: "custom_t9_own", layout: .phone9, fold: ownFold)
        try JSONEncoder().encode([ownRecord]).write(to: build.appendingPathComponent("keyboard-adapters.json"))
        try Data("schema: companion".utf8).write(to: build.appendingPathComponent("custom_t9_own.schema.yaml"))
        precondition(try reusable([compact], folds: drawsOwn), "Its built companion can be reused")
        precondition(try !reusable([compact]), "The bundled grouping is not the one built")
        precondition(try CompactAdapterDeployment.registeredRequests(build: build).first?.fold == ownFold,
            "A rebuild reads the grouping back from the registry")
        try fm.removeItem(at: build.appendingPathComponent("keyboard-adapters.json"))

        let numeric = CompactAdapterDeployment.layoutRoutes([.merged14, .phone9], numericSource: true)
        precondition(numeric.native == .phone9 && numeric.companions == [.merged14],
            "A natively served phone layout must not also get a companion")
        let records = [
            KeyboardResourceSet.EncodingAdapter(sourceSchemaID: "custom", schemaID: "custom", layout: .phone9),
            KeyboardResourceSet.EncodingAdapter(sourceSchemaID: "custom", schemaID: "custom_14", layout: .merged14),
        ]
        try JSONEncoder().encode(records).write(to: build.appendingPathComponent("keyboard-adapters.json"))
        precondition(try CompactAdapterDeployment.registeredRequests(build: build).count == 2,
            "One route per pair must be readable")
        try fm.removeItem(at: build.appendingPathComponent("keyboard-adapters.json"))
        let letters = CompactAdapterDeployment.layoutRoutes([.phone9], numericSource: false)
        precondition(letters.native == nil && letters.companions == [.phone9])
        let ownTask = CompanionTask(schemaID: "custom", layout: .phone9, fold: ownFold)
        let ownRoute = CompactAdapterDeployment.companionRoutes([ownTask], numericSource: true)
        precondition(ownRoute.native == nil && ownRoute.companions == [ownTask],
            "Only the bundled 9-key grouping runs natively on a numeric source")

        let published = root.appendingPathComponent("published")
        try fm.createDirectory(at: published, withIntermediateDirectories: true)
        try Data("5".utf8).write(to: published.appendingPathComponent("keyboard-adapter-generator.txt"))
        func rebuild(_ enabled: Bool, _ list: [PublishedKeyboard]) -> Bool {
            CompactAdapterDeployment.publicationNeedsRebuild(enabled: enabled, keyboards: list, publishedBuild: published)
        }
        precondition(rebuild(true, [compact]),
            "An old published build must be republished even when the installed build is current")
        precondition(!rebuild(false, [compact]), "A stopped scheme must not be republished")
        precondition(!rebuild(true, [native]), "26-key keyboards have no adapters to rebuild")
        try Data("6".utf8).write(to: published.appendingPathComponent("keyboard-adapter-generator.txt"))
        precondition(!rebuild(true, [compact]), "A current published build needs nothing")
        print("preparation reuse behavior passed")
    }
}
'''
        # Swift precondition uses a nonthrowing autoclosure.
        source = source.replace("precondition(try ", "precondition(try! ")
        source = source.replace("// METHODS", registry + reuse + routing + available)
        with scratch_directory("keyboard-preparation-reuse") as directory:
            generated = directory / "PreparationProbe.swift"
            generated.write_text(source)
            binary = compile_swift(directory, [generated, ROOT / "Packages/PackageManager/Sources/PackageManager/InstalledPackageLayout.swift"],
                                  library=True, dependencies=("KeyboardCore",))
            print(run([str(binary), str(directory)]), end="")


if __name__ == "__main__":
    unittest.main()
