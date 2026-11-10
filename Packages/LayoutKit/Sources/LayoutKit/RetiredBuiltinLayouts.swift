import Foundation

/// Earlier versions of the bundled layouts. A saved catalog stores every bundled layout in full and
/// the stored copy wins, so a fix to a bundled layout would never reach a device that saved one. A
/// stored built-in equal to a retired version is therefore the unedited old bundle and gets the
/// current definition; one that equals neither is a user edit and stays.
/// The data is generated from git history (Tools/Layouts/gen_retired_layouts.py).
enum RetiredBuiltinLayouts {
    private struct Tolerant: Decodable {
        let layout: LayoutDefinition?
        init(from decoder: Decoder) throws {
            layout = try? LayoutDefinition(from: decoder)
        }
    }

    /// Read on first use only: a catalog whose built-ins all match the bundle never gets here.
    private static let versions: [String: [LayoutDefinition]] = {
        guard let url = Bundle.module.url(forResource: "RetiredBuiltinLayouts", withExtension: "json"),
            let data = try? Data(contentsOf: url)
        else { return [:] }
        return decodeVersions(data)
    }()

    /// Entries that no longer decode are skipped, and so is a file that is not the expected shape.
    static func decodeVersions(_ data: Data) -> [String: [LayoutDefinition]] {
        guard let entries = try? JSONDecoder().decode([String: [Tolerant]].self, from: data) else { return [:] }
        return entries.mapValues { $0.compactMap(\.layout) }
    }

    static func isRetired(_ layout: LayoutDefinition) -> Bool {
        versions[layout.id]?.contains(layout) ?? false
    }
}
