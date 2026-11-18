import Foundation

/// Whether a package in use reads the files of another stored package.
public enum DependencyUse {
    private static let sharedSuffixes = [".dict.yaml", ".schema.yaml"]
    private static let sharedName = "essay.txt"

    /// True when the package in use carries a copy of one of the dictionaries, schemes or the word
    /// list the other package ships, which is how it came to hold files it was imported without.
    public static func reads(user: URL, other: URL) -> Bool {
        let fm = FileManager.default
        func size(_ url: URL) -> Int? { (try? fm.attributesOfItem(atPath: url.path)[.size]) as? Int }
        guard user.standardizedFileURL != other.standardizedFileURL,
            let names = try? fm.contentsOfDirectory(atPath: other.path)
        else { return false }
        return names.contains { name in
            (sharedSuffixes.contains(where: name.hasSuffix) || name == sharedName)
                && size(other.appendingPathComponent(name)).map { $0 == size(user.appendingPathComponent(name)) }
                    == true
        }
    }
}
