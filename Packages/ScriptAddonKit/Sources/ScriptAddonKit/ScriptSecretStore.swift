import Foundation
import Security

/// Where a script's declared secrets live. Secret values never enter the script file or
/// the state JSON; the store only records their keys. The Host app writes here with the
/// shared App Group access group, and the keyboard extension reads the same items.
public protocol ScriptSecretStore: Sendable {
    func setSecret(_ value: String, for key: String, scriptID: String) throws
    func secret(for key: String, scriptID: String) throws -> String?
    func deleteSecret(for key: String, scriptID: String) throws
    func deleteAllSecrets(scriptID: String) throws
}

/// Keychain-backed implementation. Items are generic passwords named
/// "<service>.<scriptID>.<key>" in the shared access group, so the extension can read
/// them after the Host app saves them.
public struct KeychainScriptSecretStore: ScriptSecretStore {
    public enum KeychainError: Error, Equatable {
        case status(OSStatus)
        case invalidValue
    }

    public let service: String
    public let accessGroup: String?

    public init(service: String = "app.songyan.script", accessGroup: String? = nil) {
        self.service = service
        self.accessGroup = accessGroup
    }

    private func account(scriptID: String, key: String) -> String {
        "\(scriptID).\(key)"
    }

    private func query(scriptID: String, key: String) -> [String: Any] {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account(scriptID: scriptID, key: key),
        ]
        if let accessGroup { query[kSecAttrAccessGroup as String] = accessGroup }
        return query
    }

    public func setSecret(_ value: String, for key: String, scriptID: String) throws {
        guard let data = value.data(using: .utf8) else { throw KeychainError.invalidValue }
        var base = query(scriptID: scriptID, key: key)
        base[kSecValueData as String] = data
        base[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        let status = SecItemAdd(base as CFDictionary, nil)
        if status == errSecDuplicateItem {
            let attributes: [String: Any] = [kSecValueData as String: data]
            let updateStatus = SecItemUpdate(
                query(scriptID: scriptID, key: key) as CFDictionary,
                attributes as CFDictionary)
            guard updateStatus == errSecSuccess else { throw KeychainError.status(updateStatus) }
            return
        }
        guard status == errSecSuccess else { throw KeychainError.status(status) }
    }

    public func secret(for key: String, scriptID: String) throws -> String? {
        var query = query(scriptID: scriptID, key: key)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else { throw KeychainError.status(status) }
        guard let data = item as? Data, let value = String(data: data, encoding: .utf8) else {
            throw KeychainError.invalidValue
        }
        return value
    }

    public func deleteSecret(for key: String, scriptID: String) throws {
        let status = SecItemDelete(query(scriptID: scriptID, key: key) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw KeychainError.status(status)
        }
    }

    public func deleteAllSecrets(scriptID: String) throws {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
        ]
        if let accessGroup { query[kSecAttrAccessGroup as String] = accessGroup }
        // Delete each account this script declared by matching the account prefix.
        let all: [String: Any] = query.merging([
            kSecReturnAttributes as String: true,
            kSecMatchLimit as String: kSecMatchLimitAll,
        ]) {
            $1
        }
        var result: CFTypeRef?
        let status = SecItemCopyMatching(all as CFDictionary, &result)
        if status == errSecItemNotFound { return }
        guard status == errSecSuccess else { throw KeychainError.status(status) }
        let items = (result as? [[String: Any]]) ?? []
        let prefix = scriptID + "."
        for item in items {
            guard let account = item[kSecAttrAccount as String] as? String,
                account.hasPrefix(prefix)
            else { continue }
            var remove = query
            remove[kSecAttrAccount as String] = account
            let removeStatus = SecItemDelete(remove as CFDictionary)
            guard removeStatus == errSecSuccess || removeStatus == errSecItemNotFound else {
                throw KeychainError.status(removeStatus)
            }
        }
    }
}
