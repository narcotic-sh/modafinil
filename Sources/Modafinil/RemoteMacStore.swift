import Foundation
import ModafinilRemoteProtocol
import Security

/// Pairings with other Macs this Mac can wake and put to sleep, kept in the login
/// keychain because each one holds that Mac's command secret and the relay secret.
struct RemoteMacStore {
    private let service = "com.narcotic.modafinil.remote-macs"
    private let account = "paired-macs"

    static func identifier(_ configuration: PairingConfiguration) -> String {
        "\(configuration.macHost):\(configuration.macPort)"
    }

    func load() throws -> [PairingConfiguration] {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return [] }
        guard status == errSecSuccess, let data = result as? Data else { throw StoreError(status: status) }
        return (try? JSONDecoder().decode([PairingConfiguration].self, from: data)) ?? []
    }

    func save(_ macs: [PairingConfiguration]) throws {
        let data = try JSONEncoder().encode(macs)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        let attributes: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        ]
        let update = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if update == errSecSuccess { return }
        guard update == errSecItemNotFound else { throw StoreError(status: update) }
        var insertion = query
        attributes.forEach { insertion[$0.key] = $0.value }
        let add = SecItemAdd(insertion as CFDictionary, nil)
        guard add == errSecSuccess else { throw StoreError(status: add) }
    }

    /// Adds the Mac, or replaces the pairing of the Mac at the same address.
    func upsert(_ configuration: PairingConfiguration) throws {
        var macs = try load()
        let id = Self.identifier(configuration)
        if let index = macs.firstIndex(where: { Self.identifier($0) == id }) {
            macs[index] = configuration
        } else {
            macs.append(configuration)
        }
        try save(macs)
    }

    func deleteAll() {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        SecItemDelete(query as CFDictionary)
    }

    struct StoreError: LocalizedError {
        let status: OSStatus
        var errorDescription: String? {
            SecCopyErrorMessageString(status, nil) as String? ?? "The paired Macs could not be read from the keychain."
        }
    }
}
