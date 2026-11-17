import CoreText
import Foundation
import Testing

@testable import KeyboardCore

@Suite struct ImportedFontsTests {
    static let arial = URL(fileURLWithPath: "/System/Library/Fonts/Supplemental/Arial.ttf")
    static let songti = URL(fileURLWithPath: "/System/Library/Fonts/Supplemental/Songti.ttc")

    private func makeLibrary() throws -> (ImportedFontLibrary, URL) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("fonts-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let suite = "fonts-test-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        let library = ImportedFontLibrary(
            directory: root.appendingPathComponent("Fonts"), preferences: ImportedFontPreferences(defaults: defaults))
        return (library, root)
    }

    private func trash(_ url: URL) { try? FileManager.default.trashItem(at: url, resultingItemURL: nil) }

    @Test func sanitizeKeepsNameAndLowercasesExtension() {
        #expect(ImportedFontNaming.sanitize("My Font.TTF") == "My Font.ttf")
        #expect(ImportedFontNaming.sanitize("宋体-Regular.otf") == "宋体-Regular.otf")
    }

    @Test func sanitizeReplacesPathAndControlCharacters() {
        #expect(ImportedFontNaming.sanitize("a:b*c?.ttf") == "a_b_c_.ttf")
        #expect(ImportedFontNaming.sanitize("../../evil.ttf") == "evil.ttf")
        #expect(ImportedFontNaming.sanitize("") == "font")
        #expect(ImportedFontNaming.sanitize("..hidden.ttf") == "hidden.ttf")
        #expect(ImportedFontNaming.sanitize(String(repeating: "a", count: 300) + ".ttf").count == 84)
    }

    @Test func uniqueAddsNumericSuffix() {
        #expect(ImportedFontNaming.unique("a.ttf", existing: []) == "a.ttf")
        #expect(ImportedFontNaming.unique("a.ttf", existing: ["a.ttf"]) == "a-2.ttf")
        #expect(ImportedFontNaming.unique("a.ttf", existing: ["a.ttf", "a-2.ttf"]) == "a-3.ttf")
    }

    @Test func cascadePutsChosenFirstThenImportOrder() {
        let order = ["a.ttf", "b.ttf", "c.ttf", "d.ttf"]
        #expect(
            ImportedFontCascade.order(chosen: "c.ttf", importOrder: order, readable: Set(order))
                == ["c.ttf", "a.ttf", "b.ttf", "d.ttf"])
    }

    @Test func cascadeSkipsUnreadableFonts() {
        let order = ["a.ttf", "b.ttf", "c.ttf"]
        #expect(
            ImportedFontCascade.order(chosen: "c.ttf", importOrder: order, readable: ["a.ttf", "c.ttf"])
                == ["c.ttf", "a.ttf"])
    }

    @Test func cascadeIsEmptyWithoutAReadableChoice() {
        let order = ["a.ttf", "b.ttf"]
        #expect(ImportedFontCascade.order(chosen: nil, importOrder: order, readable: Set(order)).isEmpty)
        #expect(ImportedFontCascade.order(chosen: "", importOrder: order, readable: Set(order)).isEmpty)
        #expect(ImportedFontCascade.order(chosen: "x.ttf", importOrder: order, readable: Set(order)).isEmpty)
        #expect(ImportedFontCascade.order(chosen: "a.ttf", importOrder: order, readable: ["b.ttf"]).isEmpty)
    }

    @Test func preferencesDefaultToSystem() throws {
        let (library, root) = try makeLibrary()
        defer { trash(root) }
        #expect(library.preferences.candidateFont == nil)
        #expect(library.preferences.keyLabelFont == nil)
        #expect(library.preferences.importOrder.isEmpty)
    }

    @Test func preferencesRoundTripAndEmptyMeansSystem() throws {
        let (library, root) = try makeLibrary()
        defer { trash(root) }
        library.preferences.candidateFont = "a.ttf"
        library.preferences.keyLabelFont = "b.ttf"
        library.preferences.importOrder = ["a.ttf", "b.ttf"]
        #expect(library.preferences.candidateFont == "a.ttf")
        #expect(library.preferences.keyLabelFont == "b.ttf")
        #expect(library.preferences.importOrder == ["a.ttf", "b.ttf"])
        library.preferences.candidateFont = ""
        #expect(library.preferences.candidateFont == nil)
        library.preferences.defaults.set("", forKey: ImportedFontPreferences.keyLabelKey)
        #expect(library.preferences.keyLabelFont == nil)
    }

    @Test func readsFamilyNameFromFile() {
        #expect(ImportedFontReader.familyName(at: Self.arial) == "Arial")
        #expect(ImportedFontReader.postScriptName(at: Self.arial) == "ArialMT")
        #expect(ImportedFontReader.familyName(at: Self.songti) != nil)
    }

    @Test func nonFontFileHasNoFamily() throws {
        let (_, root) = try makeLibrary()
        defer { trash(root) }
        let bogus = root.appendingPathComponent("bogus.ttf")
        try Data("not a font".utf8).write(to: bogus)
        #expect(ImportedFontReader.familyName(at: bogus) == nil)
        #expect(ImportedFontReader.familyName(at: root.appendingPathComponent("missing.ttf")) == nil)
    }

    @Test func importCopiesFontsAndRejectsOthers() throws {
        let (library, root) = try makeLibrary()
        defer { trash(root) }
        let bogus = root.appendingPathComponent("bogus.ttf")
        try Data("not a font".utf8).write(to: bogus)
        let text = root.appendingPathComponent("notes.txt")
        try Data("hi".utf8).write(to: text)
        let result = library.importFiles([Self.arial, bogus, text, Self.songti])
        #expect(result.imported.map(\.storedName) == ["Arial.ttf", "Songti.ttc"])
        #expect(result.imported.first?.family == "Arial")
        #expect(result.rejected == ["bogus.ttf", "notes.txt"])
        #expect(library.list().map(\.storedName) == ["Arial.ttf", "Songti.ttc"])
        #expect(library.preferences.importOrder == ["Arial.ttf", "Songti.ttc"])
        // A rejected file leaves nothing behind, not even staging files.
        let files = try FileManager.default.contentsOfDirectory(atPath: library.directory.path)
        #expect(Set(files) == ["Arial.ttf", "Songti.ttc"])
    }

    @Test func importingTheSameFileTwiceKeepsBothUnderNumberedNames() throws {
        let (library, root) = try makeLibrary()
        defer { trash(root) }
        _ = library.importFiles([Self.arial])
        let second = library.importFiles([Self.arial])
        #expect(second.imported.map(\.storedName) == ["Arial-2.ttf"])
        #expect(library.preferences.importOrder == ["Arial.ttf", "Arial-2.ttf"])
    }

    @Test func unreadableFileOnDiskIsListedWithoutFamily() throws {
        let (library, root) = try makeLibrary()
        defer { trash(root) }
        _ = library.importFiles([Self.arial])
        try Data("broken".utf8).write(to: library.url(for: "Broken.otf"))
        let list = library.list()
        #expect(list.map(\.storedName) == ["Arial.ttf", "Broken.otf"])
        #expect(list.map(\.isReadable) == [true, false])
    }

    @Test func deleteRemovesFileOrderAndChoices() throws {
        let (library, root) = try makeLibrary()
        defer { trash(root) }
        _ = library.importFiles([Self.arial, Self.songti])
        library.preferences.candidateFont = "Arial.ttf"
        library.preferences.keyLabelFont = "Songti.ttc"
        library.delete("Arial.ttf")
        #expect(library.list().map(\.storedName) == ["Songti.ttc"])
        #expect(library.preferences.importOrder == ["Songti.ttc"])
        #expect(library.preferences.candidateFont == nil)
        #expect(library.preferences.keyLabelFont == "Songti.ttc")
    }

    @Test func familyStringRoundTrips() throws {
        let family = try #require(ImportedFontFamily.encode(postScriptNames: ["ArialMT", "Foo-Regular"]))
        #expect(ImportedFontFamily.decode(family) == ["ArialMT", "Foo-Regular"])
        #expect(ImportedFontFamily.decode("serif") == nil)
        #expect(ImportedFontFamily.encode(postScriptNames: []) == nil)
    }

    @Test func prepareReturnsNilWithoutAChoice() throws {
        let (library, root) = try makeLibrary()
        defer { trash(root) }
        _ = library.importFiles([Self.arial])
        #expect(ImportedFontRuntime.prepare(chosen: nil, library: library) == nil)
        #expect(ImportedFontRuntime.prepare(chosen: "Missing.ttf", library: library) == nil)
    }

    @Test func prepareOrdersChosenThenImportOrder() throws {
        let (library, root) = try makeLibrary()
        defer { trash(root) }
        _ = library.importFiles([Self.arial, Self.songti])
        try Data("broken".utf8).write(to: library.url(for: "Broken.otf"))
        let family = try #require(ImportedFontRuntime.prepare(chosen: "Songti.ttc", library: library))
        let names = try #require(ImportedFontFamily.decode(family))
        #expect(names.count == 2)
        #expect(names[1] == "ArialMT")
        let font = try #require(ImportedFontFamily.ctFont(family: family, size: 20))
        #expect(CTFontCopyPostScriptName(font) as String == names[0])
    }

    @Test func brokenChosenFontFallsBackToSystem() throws {
        let (library, root) = try makeLibrary()
        defer { trash(root) }
        _ = library.importFiles([Self.arial])
        try Data("broken".utf8).write(to: library.url(for: "Broken.otf"))
        #expect(ImportedFontRuntime.prepare(chosen: "Broken.otf", library: library) == nil)
    }
}
