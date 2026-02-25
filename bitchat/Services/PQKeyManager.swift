//
// PQKeyManager.swift
// bitchat
//
// ML-DSA-44 key lifecycle management for post-quantum ERC-4337 accounts.
// Generates, stores, and manages ML-DSA-44 keypairs in iOS Keychain.
//
// This is free and unencumbered software released into the public domain.
// For more information, see <https://unlicense.org>
//

import BitLogger
import CryptoSwift
import Foundation
import SwiftDilithium

// MARK: - PQ Key Manager

/// Manages ML-DSA-44 keypair lifecycle for post-quantum account security.
/// Follows the same actor-based pattern as `EmbeddedWallet` for thread safety.
actor PQKeyManager {
    
    private let keychain: KeychainManagerProtocol
    private let keychainService = "chat.bitchat.pq.keys"
    
    // Keychain item names
    private let secretKeyBytesName = "pq-secret-key-bytes"
    private let publicKeyBytesName = "pq-public-key-bytes"
    private let accountAddressKeyName = "pq-account-address"
    
    // Cached key material
    private var cachedSecretKey: SecretKey?
    private var cachedPublicKey: PublicKey?
    
    init(keychain: KeychainManagerProtocol) {
        self.keychain = keychain
    }
    
    // MARK: - Key Lifecycle
    
    /// Get or create ML-DSA-44 keys. Generates once and stores in keychain.
    /// - Parameter wallet: The embedded wallet (used as context, not for seed derivation).
    /// - Returns: Tuple of (SecretKey, PublicKey) for ML-DSA-44
    @discardableResult
    func getOrCreateKeys(from wallet: EmbeddedWallet) async throws -> (SecretKey, PublicKey) {
        // Return cached if available
        if let sk = cachedSecretKey, let pk = cachedPublicKey {
            return (sk, pk)
        }
        
        // Try to load key bytes from keychain
        if let skData = keychain.load(key: secretKeyBytesName, service: keychainService),
           let pkData = keychain.load(key: publicKeyBytesName, service: keychainService) {
            let sk = try SecretKey(keyBytes: Array(skData))
            let pk = try PublicKey(keyBytes: Array(pkData))
            cachedSecretKey = sk
            cachedPublicKey = pk
            SecureLogger.logKeyOperation(.load, keyType: "pq-mldsa44", success: true)
            return (sk, pk)
        }
        
        // Generate fresh ML-DSA-44 keypair
        let (sk, pk) = Dilithium.GenerateKeyPair(kind: .ML_DSA_44)
        
        // Store key bytes in keychain
        keychain.save(
            key: secretKeyBytesName,
            data: Data(sk.keyBytes),
            service: keychainService,
            accessible: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        )
        keychain.save(
            key: publicKeyBytesName,
            data: Data(pk.keyBytes),
            service: keychainService,
            accessible: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        )
        
        cachedSecretKey = sk
        cachedPublicKey = pk
        SecureLogger.logKeyOperation(.generate, keyType: "pq-mldsa44", success: true)
        return (sk, pk)
    }
    
    /// Check if PQ keys exist in keychain
    func keysExist() -> Bool {
        keychain.load(key: secretKeyBytesName, service: keychainService) != nil
    }
    
    /// Get the cached public key, or load from keychain
    func getPublicKey() throws -> PublicKey {
        if let pk = cachedPublicKey {
            return pk
        }
        guard let pkData = keychain.load(key: publicKeyBytesName, service: keychainService) else {
            throw PQKeyError.keysNotGenerated
        }
        let pk = try PublicKey(keyBytes: Array(pkData))
        cachedPublicKey = pk
        return pk
    }
    
    /// Get the cached secret key, or load from keychain
    func getSecretKey() throws -> SecretKey {
        if let sk = cachedSecretKey {
            return sk
        }
        guard let skData = keychain.load(key: secretKeyBytesName, service: keychainService) else {
            throw PQKeyError.keysNotGenerated
        }
        let sk = try SecretKey(keyBytes: Array(skData))
        cachedSecretKey = sk
        return sk
    }
    
    // MARK: - Signing
    
    /// Sign a message with ML-DSA-44. Returns a 2420-byte deterministic signature.
    ///
    /// Uses the standard FIPS 204 Algorithm 2 (`Sign`) which prepends the domain
    /// separator `[0x00, 0x00]` (pure mode, empty context) before calling
    /// `SignInternal`. The on-chain ZKNOX dilithium verifier's ISigVerifier.verify()
    /// applies the same prefix: `mPrime = abi.encodePacked(bytes1(0), bytes1(0), m)`
    /// before calling `verifyInternal`, so both sides must agree on the prefix.
    ///
    /// - Parameter message: The message bytes to sign (typically a 32-byte hash)
    /// - Returns: ML-DSA-44 signature (2420 bytes)
    func sign(message: Data) throws -> Data {
        let sk = try getSecretKey()
        let signature = sk.Sign(message: Array(message), randomize: false)
        return Data(signature)
    }
    
    // MARK: - Account Address Tracking
    
    /// Get the deployed PQ account address (if any)
    func getAccountAddress() -> String? {
        guard let data = keychain.load(key: accountAddressKeyName, service: keychainService) else {
            return nil
        }
        return String(data: data, encoding: .utf8)
    }
    
    /// Store the deployed PQ account address
    func setAccountAddress(_ address: String) {
        guard let data = address.data(using: .utf8) else { return }
        keychain.save(
            key: accountAddressKeyName,
            data: data,
            service: keychainService,
            accessible: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        )
    }
    
    // MARK: - Export
    
    /// Export the secret key bytes for backup purposes
    func exportSeed() throws -> Data {
        guard let skData = keychain.load(key: secretKeyBytesName, service: keychainService) else {
            throw PQKeyError.keysNotGenerated
        }
        return skData
    }
    
    // MARK: - Clear
    
    /// Delete all PQ key material (panic mode)
    func clearKeys() {
        keychain.delete(key: secretKeyBytesName, service: keychainService)
        keychain.delete(key: publicKeyBytesName, service: keychainService)
        keychain.delete(key: accountAddressKeyName, service: keychainService)
        cachedSecretKey = nil
        cachedPublicKey = nil
        SecureLogger.warning("🧹 PQ keys cleared", category: .session)
    }
}

// MARK: - Errors

enum PQKeyError: Error, LocalizedError {
    case keysNotGenerated
    case invalidSeed
    case keyDerivationFailed(Error)
    case signingFailed(Error)
    
    var errorDescription: String? {
        switch self {
        case .keysNotGenerated:
            return "PQ keys have not been generated yet"
        case .invalidSeed:
            return "Invalid PQ seed (expected 32 bytes)"
        case .keyDerivationFailed(let error):
            return "Failed to derive ML-DSA-44 keys: \(error.localizedDescription)"
        case .signingFailed(let error):
            return "ML-DSA-44 signing failed: \(error.localizedDescription)"
        }
    }
}
