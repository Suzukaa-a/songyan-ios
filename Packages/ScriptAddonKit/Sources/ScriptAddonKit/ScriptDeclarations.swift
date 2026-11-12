import CryptoKit
import Foundation

/// What the shared C parser reports for a script header, mirrored as a value type.
/// The host never parses JavaScript itself: the runtime bridge fills this from
/// songyan_script_header_parse.
public struct ScriptDeclarations: Equatable, Sendable {
    public enum SettingKind: String, Codable, Equatable, Sendable {
        case text
        case url
        case choice
    }

    public struct Setting: Equatable, Sendable {
        public let key: String
        public let kind: SettingKind
        public let label: String

        public init(key: String, kind: SettingKind, label: String) {
            self.key = key
            self.kind = kind
            self.label = label
        }
    }

    public struct Secret: Equatable, Sendable {
        public let key: String
        public let label: String

        public init(key: String, label: String) {
            self.key = key
            self.label = label
        }
    }

    public let apiVersion: Int
    public let name: String
    public let summary: String?
    /// Hosts the script may connect to, folded to lowercase by the shared parser.
    public let connectHosts: [String]
    public let settings: [Setting]
    public let secrets: [Secret]
    /// The header declared @input audio; text input is always implicit.
    public let needsAudio: Bool

    public init(
        apiVersion: Int, name: String, summary: String?, connectHosts: [String],
        settings: [Setting], secrets: [Secret], needsAudio: Bool
    ) {
        self.apiVersion = apiVersion
        self.name = name
        self.summary = summary
        self.connectHosts = connectHosts
        self.settings = settings
        self.secrets = secrets
        self.needsAudio = needsAudio
    }

    /// The confirmation page shows these sites; order does not matter to the user.
    public var networkHosts: [String] {
        Array(Set(connectHosts)).sorted()
    }

    public var dependsOnNetwork: Bool { !connectHosts.isEmpty }

    public var settingKeys: Set<String> {
        Set(settings.map(\.key)).union(secrets.map(\.key))
    }

    /// Stable digest of everything the user has to confirm. Changing a connect host,
    /// a setting, a secret or the audio requirement changes the digest; changing the
    /// body or the name alone (which the list already shows) does not.
    public func confirmationDigest() throws -> String {
        struct Canonical: Codable {
            let api: Int
            let name: String
            let summary: String?
            let connects: [String]
            let settings: [SettingCanonical]
            let secrets: [SecretCanonical]
            let audio: Bool
        }
        struct SettingCanonical: Codable {
            let key: String
            let kind: String
            let label: String
        }
        struct SecretCanonical: Codable {
            let key: String
            let label: String
        }
        let canonical = Canonical(
            api: apiVersion,
            name: name,
            summary: summary,
            connects: networkHosts,
            settings: settings.map {
                SettingCanonical(key: $0.key, kind: $0.kind.rawValue, label: $0.label)
            },
            secrets: secrets.map { SecretCanonical(key: $0.key, label: $0.label) },
            audio: needsAudio)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(canonical)
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}
