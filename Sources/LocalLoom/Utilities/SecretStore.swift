import Foundation
import Security

/// Tokens live in the login keychain as a single item, so an unsigned rebuild triggers
/// one keychain prompt rather than one per token.
final class SecretStore {
    static let shared = SecretStore()

    private let service = "com.localloom.app"
    private let account = "secrets"
    private lazy var values: [String: String] = load()

    func get(_ key: String) -> String? {
        values[key]
    }

    func set(_ value: String?, for key: String) {
        let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard values[key] != (trimmed.isEmpty ? nil : trimmed) else { return }
        values[key] = trimmed.isEmpty ? nil : trimmed
        save()
    }

    private var query: [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
    }

    private func load() -> [String: String] {
        var lookup = query
        lookup[kSecReturnData as String] = true
        var result: AnyObject?
        let status = SecItemCopyMatching(lookup as CFDictionary, &result)
        guard status == errSecSuccess, let data = result as? Data else {
            if status != errSecItemNotFound {
                print("[SecretStore] Keychain read failed: \(status)")
            }
            return [:]
        }
        return (try? JSONDecoder().decode([String: String].self, from: data)) ?? [:]
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(values) else { return }
        let status = SecItemUpdate(query as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if status == errSecItemNotFound {
            var item = query
            item[kSecValueData as String] = data
            let addStatus = SecItemAdd(item as CFDictionary, nil)
            if addStatus != errSecSuccess {
                print("[SecretStore] Keychain add failed: \(addStatus)")
            }
        } else if status != errSecSuccess {
            print("[SecretStore] Keychain update failed: \(status)")
        }
    }
}
