import Foundation
import ModafinilRemoteProtocol

extension Notification.Name {
    static let modafinilCompanionConfigurationDidChange = Notification.Name(
        "com.narcotic.modafinil.companionConfigurationDidChange"
    )
}

final class CompanionConfigurationStore {
    static let macPort: UInt16 = 48_765
    static let defaultRelayPort: UInt16 = 48_766

    private enum Key {
        static let legacySecret = "companion.secret"
        static let relayHost = "companion.relayHost"
        static let relayPort = "companion.relayPort"
        static let targetMACs = "companion.targetMACs"
        static let wakeArmed = "companion.wakeArmed"
    }

    private enum KeychainAccount {
        static let macSecret = "companion-secret"
        static let relaySecret = "companion-relay-secret"
    }

    private let defaults: UserDefaults
    private let keychain = CompanionSecretKeychain()
    private var cachedSecret: Data
    private var cachedRelaySecret: Data

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        cachedSecret = Self.loadOrCreateSecret(
            keychain: keychain,
            account: KeychainAccount.macSecret,
            legacyDefaults: defaults
        )
        cachedRelaySecret = Self.loadOrCreateSecret(
            keychain: keychain,
            account: KeychainAccount.relaySecret,
            legacyDefaults: nil
        )
    }

    /// Authenticates iPhone commands to this Mac's listener.
    var secret: Data { cachedSecret }

    /// Authenticates iPhone wake requests to the XR relay. Kept separate so
    /// a compromise of the jailbroken relay phone cannot control this Mac.
    /// Re-read so a secret imported from the command line shows up in a running app.
    var relaySecret: Data {
        if let stored = keychain.secret(account: KeychainAccount.relaySecret), stored.count == 32 {
            cachedRelaySecret = stored
        }
        return cachedRelaySecret
    }

    var relayHost: String {
        defaults.string(forKey: Key.relayHost) ?? ""
    }

    var relayPort: UInt16 {
        let storedValue = defaults.integer(forKey: Key.relayPort)
        guard storedValue > 0, let port = UInt16(exactly: storedValue) else {
            return Self.defaultRelayPort
        }
        return port
    }

    var configuredTargetMACs: String? {
        defaults.string(forKey: Key.targetMACs)
    }

    var isWakeArmed: Bool {
        get { defaults.bool(forKey: Key.wakeArmed) }
        set {
            defaults.set(newValue, forKey: Key.wakeArmed)
            defaults.synchronize()
        }
    }

    func updatePairing(
        relayHost: String,
        relayPort: UInt16,
        targetMACs: String
    ) {
        defaults.set(
            relayHost.trimmingCharacters(in: .whitespacesAndNewlines),
            forKey: Key.relayHost
        )
        defaults.set(Int(relayPort), forKey: Key.relayPort)
        defaults.set(
            targetMACs.trimmingCharacters(in: .whitespacesAndNewlines),
            forKey: Key.targetMACs
        )
        NotificationCenter.default.post(
            name: .modafinilCompanionConfigurationDidChange,
            object: self
        )
    }

    func resetSecrets() {
        cachedSecret = RemoteAuthentication.generateSecret()
        cachedRelaySecret = RemoteAuthentication.generateSecret()
        keychain.setSecret(cachedSecret, account: KeychainAccount.macSecret)
        keychain.setSecret(cachedRelaySecret, account: KeychainAccount.relaySecret)
        NotificationCenter.default.post(
            name: .modafinilCompanionConfigurationDidChange,
            object: self
        )
    }

    /// Uses the relay secret another Mac already shares with the iPad relay, so
    /// one relay can wake several Macs. The Mac command secret stays unique.
    @discardableResult
    func importRelaySecret(base64 text: String) -> Bool {
        guard let data = Data(base64Encoded: text.trimmingCharacters(in: .whitespacesAndNewlines)),
              data.count == 32, keychain.setSecret(data, account: KeychainAccount.relaySecret) else {
            return false
        }
        cachedRelaySecret = data
        NotificationCenter.default.post(name: .modafinilCompanionConfigurationDidChange, object: self)
        return true
    }

    func deleteSecrets() {
        keychain.deleteSecret(account: KeychainAccount.macSecret)
        keychain.deleteSecret(account: KeychainAccount.relaySecret)
        defaults.removeObject(forKey: Key.legacySecret)
    }

    func pairingConfiguration(
        networkInformation: CompanionNetworkInformation
    ) -> PairingConfiguration {
        PairingConfiguration(
            displayName: Host.current().localizedName ?? "Mac",
            macHost: networkInformation.tailscaleIPv4 ?? "",
            macPort: Self.macPort,
            relayHost: relayHost,
            relayPort: relayPort,
            targetMAC: networkInformation.wakeTargetMACs(configured: configuredTargetMACs) ?? "",
            secret: secret,
            relaySecret: relaySecret
        )
    }

    private static func loadOrCreateSecret(
        keychain: CompanionSecretKeychain,
        account: String,
        legacyDefaults: UserDefaults?
    ) -> Data {
        if let existing = keychain.secret(account: account), existing.count == 32 {
            return existing
        }

        if let legacyDefaults,
           let legacy = legacyDefaults.data(forKey: Key.legacySecret),
           legacy.count == 32
        {
            if keychain.setSecret(legacy, account: account) {
                legacyDefaults.removeObject(forKey: Key.legacySecret)
            }
            return legacy
        }

        let secret = RemoteAuthentication.generateSecret()
        keychain.setSecret(secret, account: account)
        return secret
    }
}
