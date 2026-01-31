//
// EmbeddedWallet.swift
// bitchat
//
// Embedded Ethereum wallet for XMTP identity signing without external wallet dependencies.
// Generates and stores a secp256k1 keypair locally in keychain for message signing.
//
// This is free and unencumbered software released into the public domain.
// For more information, see <https://unlicense.org>
//

import BitLogger
import CryptoKit
import CryptoSwift
import Foundation
@preconcurrency import P256K
import XMTP

/// Embedded wallet for local Ethereum key management and XMTP signing.
/// Stores private key securely in keychain and provides signing capabilities
/// without requiring external wallet connections.
actor EmbeddedWallet {
    private let keychain: KeychainManagerProtocol
    private let keychainService = "chat.bitchat.xmtp.wallet"
    private let privateKeyName = "embedded-wallet-private-key"
    
    // Cached key material
    private var cachedPrivateKey: Data?
    private var cachedAddress: String?
    
    init(keychain: KeychainManagerProtocol) {
        self.keychain = keychain
    }
    
    // MARK: - Key Management
    
    /// Get or create the embedded wallet's private key
    func getOrCreatePrivateKey() throws -> Data {
        if let cached = cachedPrivateKey {
            return cached
        }
        
        // Try to load from keychain
        if let existingKey = keychain.load(key: privateKeyName, service: keychainService) {
            cachedPrivateKey = existingKey
            SecureLogger.logKeyOperation(.load, keyType: "embedded wallet key", success: true)
            return existingKey
        }
        
        // Generate new 32-byte private key
        var privateKey = Data(count: 32)
        let result = privateKey.withUnsafeMutableBytes { ptr in
            SecRandomCopyBytes(kSecRandomDefault, 32, ptr.baseAddress!)
        }
        
        guard result == errSecSuccess else {
            SecureLogger.logKeyOperation(.generate, keyType: "embedded wallet key", success: false)
            throw WalletError.keyGenerationFailed
        }
        
        // Store in keychain with strong protection
        keychain.save(
            key: privateKeyName,
            data: privateKey,
            service: keychainService,
            accessible: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        )
        
        cachedPrivateKey = privateKey
        SecureLogger.logKeyOperation(.generate, keyType: "embedded wallet key", success: true)
        
        return privateKey
    }
    
    /// Derive Ethereum address from private key
    func getAddress() throws -> String {
        if let cached = cachedAddress {
            return cached
        }
        
        let privateKey = try getOrCreatePrivateKey()
        let address = try deriveEthereumAddress(from: privateKey)
        cachedAddress = address
        return address
    }
    
    /// Get the public key bytes (uncompressed, 65 bytes with 0x04 prefix)
    func getPublicKey() throws -> Data {
        let privateKey = try getOrCreatePrivateKey()
        return try derivePublicKey(from: privateKey)
    }
    
    /// Sign a message using personal_sign format (EIP-191)
    /// Uses XMTP's Rust FFI for consistent signature format
    func signMessage(_ message: String) throws -> Data {
        let privateKey = try getOrCreatePrivateKey()
        
        // Use XMTP's FFI for consistent EIP-191 signing (hashing: true applies the personal_sign prefix)
        return try ethereumSignRecoverable(msg: Data(message.utf8), privateKey32: privateKey, hashing: true)
    }
    
    /// Sign raw bytes (for XMTP MLS)
    /// Uses XMTP's Rust FFI for consistent signature format
    func signBytes(_ bytes: Data) throws -> Data {
        let privateKey = try getOrCreatePrivateKey()
        // For raw bytes, use hashing: true to apply proper EIP-191 formatting
        return try ethereumSignRecoverable(msg: bytes, privateKey32: privateKey, hashing: true)
    }
    
    /// Clear all wallet data (panic mode)
    func clearWallet() {
        keychain.delete(key: privateKeyName, service: keychainService)
        cachedPrivateKey = nil
        cachedAddress = nil
        SecureLogger.warning("🧹 Embedded wallet cleared", category: .session)
    }
    
    /// Check if wallet exists
    func walletExists() -> Bool {
        keychain.load(key: privateKeyName, service: keychainService) != nil
    }
    
    // MARK: - Private Helpers
    
    private func derivePublicKey(from privateKey: Data) throws -> Data {
        // Use XMTP's FFI for consistent public key generation
        guard privateKey.count == 32 else {
            throw WalletError.invalidPrivateKey
        }
        
        return try ethereumGeneratePublicKey(privateKey32: privateKey)
    }
    
    private func deriveEthereumAddress(from privateKey: Data) throws -> String {
        let publicKey = try derivePublicKey(from: privateKey)
        // Use XMTP's FFI for consistent address derivation
        return try ethereumAddressFromPubkey(pubkey: publicKey).lowercased()
    }
    
    // Keep signWithSecp256k1 as fallback but it's no longer used for XMTP signing
    private func signWithSecp256k1(hash: Data, privateKey: Data) throws -> Data {
        guard hash.count == 32, privateKey.count == 32 else {
            throw WalletError.invalidSignatureInput
        }
        
        do {
            // Use P256K.Recovery to get a recoverable signature with recovery ID
            let privKey = try P256K.Recovery.PrivateKey(dataRepresentation: privateKey, format: .uncompressed)
            let recoverySignature = try privKey.signature(for: hash)
            
            // Get compact representation with recovery ID
            let compact = try recoverySignature.compactRepresentation
            
            // Ethereum signature format: r (32 bytes) || s (32 bytes) || v (1 byte)
            // v = recoveryId + 27 for uncompressed keys
            var fullSignature = compact.signature
            let v = UInt8(compact.recoveryId) + 27
            fullSignature.append(v)
            
            return fullSignature // 65 bytes total
        } catch {
            throw WalletError.signingFailed
        }
    }
    
    /// Keccak-256 hash implementation for Ethereum address derivation
    private func keccak256(_ data: Data) -> Data {
        // Use CryptoSwift's Keccak-256 (same as Ethereum's keccak256)
        let bytes = Array(data)
        let hash = bytes.sha3(.keccak256)
        return Data(hash)
    }
}

// MARK: - XMTP SigningKey Conformance

/// Wrapper to make EmbeddedWallet conform to XMTP's SigningKey protocol
public struct EmbeddedWalletSigner: SigningKey {
    private let wallet: EmbeddedWallet
    private let addressCache: String
    
    public var identity: PublicIdentity {
        PublicIdentity(kind: .ethereum, identifier: addressCache)
    }
    
    public var type: SignerType { .EOA }
    
    init(wallet: EmbeddedWallet, address: String) {
        self.wallet = wallet
        self.addressCache = address
    }
    
    public func sign(_ message: String) async throws -> SignedData {
        let signature = try await wallet.signMessage(message)
        return SignedData(rawData: signature)
    }
}

// MARK: - Errors

enum WalletError: Error, LocalizedError {
    case keyGenerationFailed
    case invalidPrivateKey
    case publicKeyDerivationFailed
    case invalidMessage
    case invalidSignatureInput
    case signingFailed
    case walletNotInitialized
    
    var errorDescription: String? {
        switch self {
        case .keyGenerationFailed:
            return "Failed to generate secure private key"
        case .invalidPrivateKey:
            return "Invalid private key format"
        case .publicKeyDerivationFailed:
            return "Failed to derive public key from private key"
        case .invalidMessage:
            return "Invalid message format for signing"
        case .invalidSignatureInput:
            return "Invalid input for signature operation"
        case .signingFailed:
            return "Failed to sign message"
        case .walletNotInitialized:
            return "Wallet has not been initialized"
        }
    }
}
