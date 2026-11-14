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
        /// What a choice setting offers, in declaration order; the first is the default.
        /// Empty for text and URL settings.
        public let options: [String]

        public init(key: String, kind: SettingKind, label: String, options: [String] = []) {
            self.key = key
            self.kind = kind
            self.label = label
            self.options = options
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
    /// The header's @timeout in seconds, nil when it declares none. Shown to the user; it is not
    /// part of the confirmation digest.
    public let timeoutSeconds: Int?

    public init(
        apiVersion: Int, name: String, summary: String?, connectHosts: [String],
        settings: [Setting], secrets: [Secret], needsAudio: Bool, timeoutSeconds: Int? = nil
    ) {
        self.apiVersion = apiVersion
        self.name = name
        self.summary = summary
        self.connectHosts = connectHosts
        self.settings = settings
        self.secrets = secrets
        self.needsAudio = needsAudio
        self.timeoutSeconds = timeoutSeconds
    }

    /// The confirmation page shows these sites; order does not matter to the user.
    public var networkHosts: [String] {
        Array(Set(connectHosts)).sorted()
    }

    /// A url setting lets the user point the script at their own address, so it goes online
    /// without any @connect host.
    public var hasURLSetting: Bool { settings.contains { $0.kind == .url } }

    /// How the declared @timeout reads on the confirmation and detail pages: seconds below two
    /// minutes, otherwise whole minutes rounded up. Nil when the script declares none.
    public var timeoutDisplay: (value: Int, isMinutes: Bool)? {
        guard let seconds = timeoutSeconds, seconds > 0 else { return nil }
        return seconds >= 120 ? ((seconds + 59) / 60, true) : (seconds, false)
    }

    public var dependsOnNetwork: Bool { !connectHosts.isEmpty || hasURLSetting }

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
            /// Omitted for settings without options, so their digest is unchanged.
            let options: [String]?
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
                SettingCanonical(
                    key: $0.key, kind: $0.kind.rawValue, label: $0.label,
                    options: $0.options.isEmpty ? nil : $0.options)
            },
            secrets: secrets.map { SecretCanonical(key: $0.key, label: $0.label) },
            audio: needsAudio)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(canonical)
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}
