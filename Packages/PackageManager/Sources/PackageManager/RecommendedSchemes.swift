import Foundation

public struct RecommendedSchemeLicense: Equatable, Sendable {
    public let name: String
    public let url: URL
}

public struct RecommendedSchemeArchive: Equatable, Sendable {
    public let id: String
    public let url: URL
    public let homepage: URL
    public let sha256: String
    public let byteCountHint: Int64
    public let licenses: [RecommendedSchemeLicense]
}

/// A recommendation describes every required upstream archive before the host starts a transfer.
/// Optional advertised IDs apply only to curated entries; ordinary imports retain their own schema_list.
public struct RecommendedSchemeSource: Identifiable, Equatable, Sendable {
    public let id: String
    public let nameKey: String
    public let detailKey: String
    public let languageTag: String
    public let archives: [RecommendedSchemeArchive]
    public let advertisedSchemaIDs: [String]?

    public var url: URL { archives[0].url }
    public var homepage: URL { archives[0].homepage }
    public var byteCountHint: Int64 { archives.reduce(0) { $0 + $1.byteCountHint } }

    public static func ordered(
        preferredLanguages: [String], sources: [RecommendedSchemeSource] = catalog
    ) -> [RecommendedSchemeSource] {
        guard let primary = preferredLanguages.first else { return sources }
        let locale = Locale(identifier: primary)
        let priority: [String]
        switch locale.language.languageCode?.identifier {
        case "ja":
            priority = sources.filter { $0.languageTag == "ja" }.map(\.id)
        case "zh":
            // Region picks the traditional-script methods, but a user who chose Simplified Chinese
            // there still types pinyin: only the script they read decides.
            if locale.language.script?.identifier == "Hans" { return sources }
            switch locale.region?.identifier {
            case "TW": priority = ["rime-bopomofo", "rime-cangjie"]
            case "HK", "MO": priority = ["rime-cangjie", "rime-quick", "rime-cantonese"]
            default: return sources
            }
        default: return sources
        }
        let rank = Dictionary(uniqueKeysWithValues: priority.enumerated().map { ($1, $0) })
        return sources.enumerated().sorted {
            (rank[$0.element.id] ?? priority.count, $0.offset)
                < (rank[$1.element.id] ?? priority.count, $1.offset)
        }.map(\.element)
    }

    public static let catalog: [RecommendedSchemeSource] = [
        RecommendedSchemeSource(
            id: "rime-ice", nameKey: "catalog.ice.name", detailKey: "catalog.ice.detail", languageTag: "zh-Hans",
            archives: [
                RecommendedSchemeArchive(
                    id: "rime-ice",
                    url: URL(
                        string:
                            "https://codeload.github.com/iDvel/rime-ice/zip/fbb516b2786e4d5444383706d13c31c2e4d10c08")!,
                    homepage: URL(string: "https://github.com/iDvel/rime-ice")!,
                    sha256: "4c6b9c84115e9aa24cfaf55e389363785451943fe70e4e7670b2ec59fc0056d3",
                    byteCountHint: 16_944_925,
                    licenses: [
                        RecommendedSchemeLicense(
                            name: "GPL-3.0",
                            url: URL(
                                string:
                                    "https://github.com/iDvel/rime-ice/blob/fbb516b2786e4d5444383706d13c31c2e4d10c08/LICENSE"
                            )!)
                    ])
            ],
            advertisedSchemaIDs: nil),
        RecommendedSchemeSource(
            id: "rime-wanxiang", nameKey: "catalog.wanxiang.name", detailKey: "catalog.wanxiang.detail",
            languageTag: "zh-Hans",
            archives: [
                RecommendedSchemeArchive(
                    id: "rime-wanxiang",
                    url: URL(
                        string:
                            "https://github.com/amzxyz/rime-wanxiang/releases/download/v18.1.3/rime-wanxiang-base.zip")!,
                    homepage: URL(string: "https://github.com/amzxyz/rime-wanxiang")!,
                    sha256: "fc6495ba8489a898737ca29883dedaf61ff3baf593c78900dc59102c919d0e63",
                    byteCountHint: 26_011_020,
                    licenses: [
                        RecommendedSchemeLicense(
                            name: "CC-BY-4.0",
                            url: URL(
                                string:
                                    "https://github.com/amzxyz/rime-wanxiang/blob/7e4e264e7e61fa6d3837c58325d2c4a194562ffc/LICENSE"
                            )!)
                    ])
            ],
            advertisedSchemaIDs: nil),
        RecommendedSchemeSource(
            id: "rime-bopomofo", nameKey: "catalog.bopomofo.name", detailKey: "catalog.bopomofo.detail",
            languageTag: "zh-Hant", archives: [bopomofo, terra, essay, stroke, luna],
            advertisedSchemaIDs: ["bopomofo_tw", "bopomofo"]),
        RecommendedSchemeSource(
            id: "rime-cangjie", nameKey: "catalog.cangjie.name", detailKey: "catalog.cangjie.detail",
            languageTag: "zh-Hant", archives: [cangjie, luna, essay, stroke], advertisedSchemaIDs: ["cangjie5"]),
        RecommendedSchemeSource(
            id: "rime-quick", nameKey: "catalog.quick.name", detailKey: "catalog.quick.detail",
            languageTag: "zh-Hant", archives: [quick, cangjie, luna, essay, stroke],
            advertisedSchemaIDs: ["quick5"]),
        RecommendedSchemeSource(
            id: "rime-cantonese", nameKey: "catalog.cantonese.name", detailKey: "catalog.cantonese.detail",
            languageTag: "zh-Hant", archives: [cantonese, luna, stroke, cangjie, loengfan, emoji, essay],
            advertisedSchemaIDs: ["jyut6ping3"]),
        RecommendedSchemeSource(
            id: "rime-kagiroi", nameKey: "catalog.kagiroi.name", detailKey: "catalog.kagiroi.detail",
            languageTag: "ja", archives: [kagiroi], advertisedSchemaIDs: ["kagiroi"]),
    ]

    /// Upstream's own prebuilt package (the `build` branch commit generated from source
    /// 808a1954). Compiling the source dictionaries on a phone runs out of memory, so the
    /// catalog takes the compiled tables as upstream ships them, its dictionary set included.
    private static let kagiroi = RecommendedSchemeArchive(
        id: "rime-kagiroi",
        url: URL(
            string:
                "https://codeload.github.com/rimeinn/rime-kagiroi/zip/1c4cd914a92ec433e2c90436414d7d05eeded6c9")!,
        homepage: URL(string: "https://github.com/rimeinn/rime-kagiroi")!,
        sha256: "4091251313f98b76c49a340f21b94ae0d606993e4134c7c8ba0c5d969c6fa4a2",
        byteCountHint: 67_182_927,
        licenses: [
            RecommendedSchemeLicense(
                name: "GPL-3.0",
                url: URL(
                    string:
                        "https://github.com/rimeinn/rime-kagiroi/blob/808a195415e6d7bd3a41b1747039d8459bfde207/LICENSE"
                )!),
            RecommendedSchemeLicense(
                name: "Mozc",
                url: URL(
                    string:
                        "https://github.com/google/mozc/blob/006ed69bf545548a8a3596b13f58cb22cf3d8a2f/src/data/dictionary_oss/README.txt"
                )!),
        ])

    private static let bopomofo = upstreamArchive(
        owner: "rime", repository: "rime-bopomofo", revision: "6085c9a38a4a728047862b33d67eee18aa86f3b9",
        sha256: "97247bcd63774686e9f86f1920ab58bb272032cbb3a622f4ffd669ad8f40df00", bytes: 12487,
        licenses: [("LGPL-3.0", "LICENSE")])

    private static let terra = upstreamArchive(
        owner: "rime", repository: "rime-terra-pinyin", revision: "723e51bc266cf9464530c1ddedb856aa18e3da34",
        sha256: "eed62b2a8bf56ac51c0931bb1c22a1e6b404a77be4984e7d3da787ef20d58fb5", bytes: 732915,
        licenses: [("LGPL-3.0", "LICENSE")])

    private static let essay = upstreamArchive(
        owner: "rime", repository: "rime-essay", revision: "054920de4f54c9e5994276a96a4fc2a35cb51aa3",
        sha256: "f1ed067efee9d13d53ac6b1bdc3a57873d48fcd375cdbda0e9c2ef0d79158bac", bytes: 2577894,
        licenses: [("LGPL-3.0", "LICENSE")])

    private static let stroke = upstreamArchive(
        owner: "rime", repository: "rime-stroke", revision: "1e8fff9b9494ddec23b0cbc526bcfd8171a6fd48",
        sha256: "058ffc2a3ce4de7137a170cf38feeeef06dcfac040ed3d173589d43d7dd7fc95", bytes: 1068491,
        licenses: [("LGPL-3.0", "LICENSE")])

    private static let cangjie = upstreamArchive(
        owner: "rime", repository: "rime-cangjie", revision: "fcb3d7dd94ac1304663d575727d24d8107f6b082",
        sha256: "6e32880ad439d9f9966cf6e1d2c3524bbd1d24219800cda0d9122607b08ee295", bytes: 403456,
        licenses: [("LGPL-3.0", "LICENSE")])

    private static let quick = upstreamArchive(
        owner: "rime", repository: "rime-quick", revision: "5dcdb9e353d314239e9c8cddc0f42d52da4837bb",
        sha256: "ed0053fbc824398e94735bc040f3b10e7af32588f4a8ecc48c663cfb0ed475c0", bytes: 40231,
        licenses: [("LGPL-3.0", "LICENSE")])

    private static let luna = upstreamArchive(
        owner: "rime", repository: "rime-luna-pinyin", revision: "56b934b099dfbeab842320f13aa8b461a6ab3e42",
        sha256: "96f96206361a9f5e9ec5af7f102cb1c6b04e3f394746150e5fa62ae87290f9c2", bytes: 398121,
        licenses: [("LGPL-3.0", "LICENSE")])

    private static let cantonese = upstreamArchive(
        owner: "rime", repository: "rime-cantonese", revision: "259f0e48bba840c3a2e0d117539e96937f3d89bc",
        sha256: "9ef08e9529e2afbd9b0f84917e5194d8e7e00808cddcb4769fd91e5df13ef96f", bytes: 4819857,
        licenses: [("CC-BY-4.0", "LICENSE-CC-BY"), ("ODbL-1.0", "LICENSE-ODbL")])

    private static let emoji = upstreamArchive(
        owner: "rime", repository: "rime-emoji-cantonese", revision: "e89d9bdb1c454cf8dbc15db21cce0f6b1a54ed99",
        sha256: "6436f0193048d6351f726f4a714ca779492f9abfed6d1bbe9abc01e38e9d0fb4", bytes: 48321,
        licenses: [("CC0-1.0", "LICENSE")])

    private static let loengfan = upstreamArchive(
        owner: "CanCLID", repository: "rime-loengfan", revision: "987ac95b02f957e8764a2f45222a4006c188ed50",
        sha256: "81dbfca498be152bdb9f2a102f5700b1d9f8ac74062bb1fb0dd59abeeb3adca7", bytes: 564392,
        licenses: [("CC-BY-4.0", "LICENSE")])

    private static func upstreamArchive(
        owner: String, repository: String, revision: String, sha256: String, bytes: Int64,
        licenses: [(name: String, file: String)]
    ) -> RecommendedSchemeArchive {
        let homepage = "https://github.com/" + owner + "/" + repository
        return RecommendedSchemeArchive(
            id: repository,
            url: URL(string: "https://codeload.github.com/\(owner)/\(repository)/zip/\(revision)")!,
            homepage: URL(string: homepage)!, sha256: sha256, byteCountHint: bytes,
            licenses: licenses.map {
                RecommendedSchemeLicense(
                    name: $0.name, url: URL(string: homepage + "/blob/" + revision + "/" + $0.file)!)
            })
    }
}
