//
// XMTPIdentityBridge.swift
// bitchat
//
// Bridge between XMTP wallet identities and Noise Protocol static keys.
// Maps Ethereum addresses (XMTP inbox IDs) to Noise public keys for BLE mesh routing.
//
// This is free and unencumbered software released into the public domain.
// For more information, see <https://unlicense.org>
//

import BitLogger
import CryptoKit
import Foundation

/// Bridge between XMTP wallet identities and Noise Protocol identities.
/// Enables routing messages from XMTP contacts to BLE mesh peers.
final class XMTPIdentityBridge {
    private let keychainService = "chat.bitchat.xmtp.identity"
    private let deviceSeedKey = "xmtp-device-seed"
    private let inboxIdKey = "xmtp-inbox-id"
    private let ownNoiseKeyName = "own-noise-public-key"
    
    // In-memory caches
    private var deviceSeedCache: Data?
    private var derivedGroupCache: [String: String] = [:] // geohash -> groupId
    private let cacheLock = NSLock()
    
    private let keychain: KeychainManagerProtocol
    
    init(keychain: KeychainManagerProtocol) {
        self.keychain = keychain
    }
    
    // MARK: - XMTP Identity
    
    /// Get the stored XMTP inbox ID for this device
    func getStoredInboxId() -> String? {
        guard let existingData = keychain.load(key: inboxIdKey, service: keychainService),
              let inboxId = String(data: existingData, encoding: .utf8) else {
            return nil
        }
        return inboxId
    }
    
    /// Store the actual XMTP inbox ID after client creation
    func storeInboxId(_ inboxId: String) {
        if let data = inboxId.data(using: .utf8) {
            keychain.save(key: inboxIdKey, data: data, service: keychainService, accessible: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly)
            SecureLogger.debug("Stored XMTP inbox ID: \(inboxId.prefix(16))…", category: .session)
        }
    }
    
    /// Get our own Noise public key (stored during BLE session setup)
    func getOwnNoisePublicKey() -> Data? {
        return keychain.load(key: ownNoiseKeyName, service: keychainService)
    }
    
    /// Store our own Noise public key 
    func storeOwnNoisePublicKey(_ publicKey: Data) {
        keychain.save(key: ownNoiseKeyName, data: publicKey, service: keychainService, accessible: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly)
    }
    
    // MARK: - Noise ↔ XMTP Mapping
    
    /// Associate an XMTP inbox ID with a Noise public key (for favorites/contacts)
    func associateIdentity(noisePublicKey: Data, with inboxId: String) {
        let key = "xmtp-noise-\(noisePublicKey.base64EncodedString())"
        if let data = inboxId.data(using: .utf8) {
            keychain.save(key: key, data: data, service: keychainService, accessible: nil)
            SecureLogger.debug("Associated XMTP inbox \(inboxId.prefix(16))… with Noise key", category: .session)
        }
        
        // Also store reverse mapping
        let reverseKey = "noise-xmtp-\(inboxId)"
        keychain.save(key: reverseKey, data: noisePublicKey, service: keychainService, accessible: nil)
    }
    
    /// Get XMTP inbox ID associated with a Noise public key
    func getXMTPInboxId(for noisePublicKey: Data) -> String? {
        let key = "xmtp-noise-\(noisePublicKey.base64EncodedString())"
        guard let data = keychain.load(key: key, service: keychainService),
              let inboxId = String(data: data, encoding: .utf8) else {
            return nil
        }
        return inboxId
    }
    
    /// Get Noise public key associated with an XMTP inbox ID
    func getNoisePublicKey(for inboxId: String) -> Data? {
        let key = "noise-xmtp-\(inboxId)"
        return keychain.load(key: key, service: keychainService)
    }
    
    /// Resolve PeerID from XMTP inbox ID
    func resolvePeerID(for inboxId: String) -> PeerID? {
        guard let noiseKey = getNoisePublicKey(for: inboxId) else {
            return nil
        }
        return PeerID(publicKey: noiseKey)
    }
    
    // MARK: - Per-Geohash Groups (Location Channels)
    
    /// Returns a stable device seed used to derive unlinkable per-geohash group identifiers.
    private func getOrCreateDeviceSeed() -> Data {
        if let cached = deviceSeedCache { return cached }
        if let existing = keychain.load(key: deviceSeedKey, service: keychainService) {
            deviceSeedCache = existing
            return existing
        }
        
        var seed = Data(count: 32)
        _ = seed.withUnsafeMutableBytes { ptr in
            SecRandomCopyBytes(kSecRandomDefault, 32, ptr.baseAddress!)
        }
        
        keychain.save(
            key: deviceSeedKey,
            data: seed,
            service: keychainService,
            accessible: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        )
        deviceSeedCache = seed
        return seed
    }
    
    /// Derive a deterministic XMTP group ID for a given geohash.
    /// Uses HMAC-SHA256(deviceSeed, "xmtp-geo:" + geohash) to create a stable group identifier.
    func deriveGroupId(forGeohash geohash: String) -> String {
        cacheLock.lock()
        if let cached = derivedGroupCache[geohash] {
            cacheLock.unlock()
            return cached
        }
        cacheLock.unlock()
        
        let seed = getOrCreateDeviceSeed()
        let input = "xmtp-geo:\(geohash)"
        guard let inputData = input.data(using: .utf8) else {
            return "geo-\(geohash)"
        }
        
        let code = HMAC<SHA256>.authenticationCode(for: inputData, using: SymmetricKey(data: seed))
        let groupId = Data(code).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
        
        cacheLock.lock()
        derivedGroupCache[geohash] = groupId
        cacheLock.unlock()
        
        return groupId
    }
    
    /// Generate a human-readable group name for a geohash location channel
    func groupName(forGeohash geohash: String) -> String {
        "📍 Location: \(geohash.prefix(6))"
    }
    
    // MARK: - Cleanup
    
    /// Clear all XMTP identity associations (panic mode)
    func clearAllAssociations() {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecMatchLimit as String: kSecMatchLimitAll,
            kSecReturnAttributes as String: true
        ]
        
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecSuccess, let items = result as? [[String: Any]] {
            for item in items {
                var deleteQuery: [String: Any] = [
                    kSecClass as String: kSecClassGenericPassword,
                    kSecAttrService as String: keychainService
                ]
                if let account = item[kSecAttrAccount as String] as? String {
                    deleteQuery[kSecAttrAccount as String] = account
                }
                SecItemDelete(deleteQuery as CFDictionary)
            }
        }
        
        // Clear caches
        deviceSeedCache = nil
        cacheLock.lock()
        derivedGroupCache.removeAll()
        cacheLock.unlock()
        
        SecureLogger.warning("🧹 Cleared all XMTP identity associations", category: .session)
    }
}

// MARK: - Identity Resolution Helpers

extension XMTPIdentityBridge {
    /// Check if we can reach a peer via XMTP (they have an associated inbox ID)
    func canReachViaXMTP(_ peerID: PeerID) -> Bool {
        guard let noiseKey = peerID.noiseKey else { return false }
        return getXMTPInboxId(for: noiseKey) != nil
    }
    
    /// Get all known XMTP-reachable peers
    func getXMTPReachablePeers() -> [PeerID] {
        // This would scan the keychain for all xmtp-noise-* entries
        // For now, return empty - will be populated by FavoritesPersistenceService
        return []
    }
}
