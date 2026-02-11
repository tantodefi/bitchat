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
    
    // MARK: - Transaction Signing
    
    /// EIP-7702 Authorization for delegating code to a contract
    struct EIP7702Authorization: Equatable {
        let chainId: UInt64
        let codeAddress: String  // Contract to delegate to
        let nonce: UInt64
    }
    
    /// Sign an EIP-7702 authorization tuple
    /// The authorization allows this EOA to temporarily use code from another address
    /// - Parameter authorization: The authorization parameters
    /// - Returns: Signed authorization (chain_id, address, nonce, y_parity, r, s)
    func signAuthorization(_ authorization: EIP7702Authorization) throws -> Data {
        let privateKey = try getOrCreatePrivateKey()
        
        // Authorization signing hash: keccak256(MAGIC || rlp([chain_id, address, nonce]))
        // MAGIC = 0x05 for EIP-7702
        let codeAddressData = Data(hexString: authorization.codeAddress.hasPrefix("0x") 
            ? String(authorization.codeAddress.dropFirst(2)) 
            : authorization.codeAddress) ?? Data()
        
        let authPayload: [Any] = [
            rlpEncode(authorization.chainId),
            codeAddressData,
            rlpEncode(authorization.nonce)
        ]
        
        let encodedPayload = rlpEncodeList(authPayload)
        
        // Prepend MAGIC byte and hash
        var toHash = Data([0x05])
        toHash.append(encodedPayload)
        let authHash = keccak256(toHash)
        
        // Sign the hash
        let signature = try signTransactionHash(authHash, privateKey: privateKey)
        
        // Extract signature components
        var r = Data(signature[0..<32])
        var s = Data(signature[32..<64])
        let yParity = signature[64] // 0 or 1
        
        // Strip leading zeros for canonical encoding
        while r.first == 0 && r.count > 1 { r.removeFirst() }
        while s.first == 0 && s.count > 1 { s.removeFirst() }
        
        // Return RLP([chain_id, address, nonce, y_parity, r, s])
        let signedAuth: [Any] = [
            rlpEncode(authorization.chainId),
            codeAddressData,
            rlpEncode(authorization.nonce),
            rlpEncode(UInt64(yParity)),
            r,
            s
        ]
        
        return rlpEncodeList(signedAuth)
    }
    
    /// Sign an EIP-7702 "set code" transaction (type 0x04)
    /// - Parameters:
    ///   - chainId: Chain ID
    ///   - nonce: Transaction nonce
    ///   - maxPriorityFeePerGas: Max priority fee in wei
    ///   - maxFeePerGas: Max fee per gas in wei
    ///   - gasLimit: Gas limit
    ///   - to: Destination address
    ///   - value: Value in wei
    ///   - data: Call data
    ///   - authorizations: List of EIP-7702 authorizations
    /// - Returns: RLP-encoded signed transaction ready for broadcast
    func signEIP7702Transaction(
        chainId: UInt64,
        nonce: UInt64,
        maxPriorityFeePerGas: UInt64,
        maxFeePerGas: UInt64,
        gasLimit: UInt64,
        to: String,
        value: UInt64,
        data: Data = Data(),
        authorizations: [EIP7702Authorization]
    ) throws -> Data {
        let privateKey = try getOrCreatePrivateKey()
        
        // Build authorization list
        var authList: [Any] = []
        for auth in authorizations {
            let signedAuth = try signAuthorization(auth)
            authList.append(signedAuth)
        }
        
        let toAddress = Data(hexString: to.hasPrefix("0x") ? String(to.dropFirst(2)) : to) ?? Data()
        
        // Build unsigned EIP-7702 transaction (type 4)
        // RLP([chain_id, nonce, max_priority_fee_per_gas, max_fee_per_gas, gas_limit, to, value, data, access_list, authorization_list])
        let unsignedTx: [Any] = [
            rlpEncode(chainId),
            rlpEncode(nonce),
            rlpEncode(maxPriorityFeePerGas),
            rlpEncode(maxFeePerGas),
            rlpEncode(gasLimit),
            toAddress,
            rlpEncode(value),
            data,
            [] as [Any], // Empty access list
            authList
        ]
        
        let encodedUnsigned = rlpEncodeList(unsignedTx)
        
        // Hash with EIP-7702 type prefix (0x04)
        var toHash = Data([0x04])
        toHash.append(encodedUnsigned)
        let txHash = keccak256(toHash)
        
        // Sign the hash
        let signature = try signTransactionHash(txHash, privateKey: privateKey)
        
        // Extract r, s, v
        var r = Data(signature[0..<32])
        var s = Data(signature[32..<64])
        let v = signature[64]
        
        while r.first == 0 && r.count > 1 { r.removeFirst() }
        while s.first == 0 && s.count > 1 { s.removeFirst() }
        
        // Build signed transaction
        let signedTx: [Any] = [
            rlpEncode(chainId),
            rlpEncode(nonce),
            rlpEncode(maxPriorityFeePerGas),
            rlpEncode(maxFeePerGas),
            rlpEncode(gasLimit),
            toAddress,
            rlpEncode(value),
            data,
            [] as [Any],
            authList,
            rlpEncode(UInt64(v)),
            r,
            s
        ]
        
        let encodedSigned = rlpEncodeList(signedTx)
        
        // Prepend type byte for EIP-7702
        var result = Data([0x04])
        result.append(encodedSigned)
        
        return result
    }

    /// Sign an EIP-1559 transaction and return the RLP-encoded signed transaction
    /// - Parameters:
    ///   - chainId: Chain ID (e.g., 1 for mainnet, 11155111 for Sepolia)
    ///   - nonce: Transaction nonce
    ///   - maxPriorityFeePerGas: Max priority fee in wei
    ///   - maxFeePerGas: Max fee per gas in wei
    ///   - gasLimit: Gas limit
    ///   - to: Destination address (hex string with 0x prefix)
    ///   - value: Value in wei
    ///   - data: Call data (empty for simple transfers)
    /// - Returns: RLP-encoded signed transaction ready for broadcast
    func signTransaction(
        chainId: UInt64,
        nonce: UInt64,
        maxPriorityFeePerGas: UInt64,
        maxFeePerGas: UInt64,
        gasLimit: UInt64,
        to: String,
        value: UInt64,
        data: Data = Data()
    ) throws -> Data {
        let privateKey = try getOrCreatePrivateKey()
        
        // Build unsigned EIP-1559 transaction (type 2)
        // RLP([chainId, nonce, maxPriorityFeePerGas, maxFeePerGas, gasLimit, to, value, data, accessList])
        let toAddress = Data(hexString: to.hasPrefix("0x") ? String(to.dropFirst(2)) : to) ?? Data()
        
        let unsignedTx: [Any] = [
            rlpEncode(chainId),
            rlpEncode(nonce),
            rlpEncode(maxPriorityFeePerGas),
            rlpEncode(maxFeePerGas),
            rlpEncode(gasLimit),
            toAddress,
            rlpEncode(value),
            data,
            [] as [Any] // Empty access list
        ]
        
        // RLP encode the unsigned transaction
        let encodedUnsigned = rlpEncodeList(unsignedTx)
        
        // Hash with EIP-1559 type prefix (0x02)
        var toHash = Data([0x02])
        toHash.append(encodedUnsigned)
        let txHash = keccak256(toHash)
        
        // Sign the hash
        let signature = try signTransactionHash(txHash, privateKey: privateKey)
        
        // Extract r, s, v from signature
        // Important: Convert slices to fresh Data and strip leading zeros for canonical encoding
        var r = Data(signature[0..<32])
        var s = Data(signature[32..<64])
        let v = signature[64] // Recovery ID (0 or 1 for EIP-1559)
        
        // Strip leading zeros from r and s (required for canonical RLP encoding)
        while r.first == 0 && r.count > 1 {
            r.removeFirst()
        }
        while s.first == 0 && s.count > 1 {
            s.removeFirst()
        }
        
        // Build signed transaction
        // RLP([chainId, nonce, maxPriorityFeePerGas, maxFeePerGas, gasLimit, to, value, data, accessList, v, r, s])
        let signedTx: [Any] = [
            rlpEncode(chainId),
            rlpEncode(nonce),
            rlpEncode(maxPriorityFeePerGas),
            rlpEncode(maxFeePerGas),
            rlpEncode(gasLimit),
            toAddress,
            rlpEncode(value),
            data,
            [] as [Any], // Empty access list
            rlpEncode(UInt64(v)), // Recovery ID (0 or 1)
            r,
            s
        ]
        
        let encodedSigned = rlpEncodeList(signedTx)
        
        // Prepend type byte for EIP-1559
        var result = Data([0x02])
        result.append(encodedSigned)
        
        return result
    }
    
    /// Sign a transaction hash (keccak256 of unsigned tx)
    /// Returns 65-byte signature: r (32) || s (32) || v (1) where v is raw recovery ID (0 or 1)
    private func signTransactionHash(_ hash: Data, privateKey: Data) throws -> Data {
        guard hash.count == 32, privateKey.count == 32 else {
            throw WalletError.invalidSignatureInput
        }
        
        do {
            // Use P256K.Recovery for recoverable secp256k1 signature
            let privKey = try P256K.Recovery.PrivateKey(dataRepresentation: privateKey, format: .uncompressed)
            
            // CRITICAL: Use HashDigest (which conforms to Digest) to sign the RAW hash
            // If we pass Data directly, P256K will SHA256 hash it again (double-hashing = wrong signature)
            let digest = HashDigest(Array(hash))
            let recoverySignature = try privKey.signature(for: digest)
            
            // Log the address being used for debugging
            if let knownAddress = cachedAddress {
                // Use print for unredacted address logging during debug
                print("📍 [TX DEBUG] Signing with cached address: \(knownAddress)")
                SecureLogger.debug("📍 Signing tx hash with address: \(knownAddress)", category: .session)
            }
            
            // Get compact representation with recovery ID
            let compact = try recoverySignature.compactRepresentation
            
            // EIP-1559 transaction format: r (32 bytes) || s (32 bytes) || v (1 byte)
            // v = raw recoveryId (0 or 1), NOT the legacy 27/28 format
            var fullSignature = compact.signature  // 64 bytes: r || s
            let v = UInt8(compact.recoveryId)      // 0 or 1
            fullSignature.append(v)
            
            SecureLogger.debug("📍 Signature v (recovery ID): \(v)", category: .session)
            
            return fullSignature // 65 bytes total
        } catch {
            throw WalletError.signingFailed
        }
    }
    
    // MARK: - RLP Encoding Helpers
    
    private func rlpEncode(_ value: UInt64) -> Data {
        if value == 0 {
            return Data() // Empty data represents 0 - will be encoded as 0x80 by rlpEncodeBytes
        }
        var bytes = withUnsafeBytes(of: value.bigEndian) { Data($0) }
        // Remove leading zeros
        while bytes.first == 0 && bytes.count > 1 {
            bytes.removeFirst()
        }
        return bytes
    }
    
    private func rlpEncodeList(_ items: [Any]) -> Data {
        var payload = Data()
        for item in items {
            if let data = item as? Data {
                payload.append(rlpEncodeBytes(data))
            } else if let list = item as? [Any] {
                payload.append(rlpEncodeList(list))
            }
        }
        return rlpEncodeLength(payload.count, offset: 0xc0) + payload
    }
    
    private func rlpEncodeBytes(_ data: Data) -> Data {
        // Empty data is encoded as 0x80
        if data.isEmpty {
            return Data([0x80])
        }
        // Single byte < 0x80 is encoded as itself
        // Use .first to handle Data slices with non-zero startIndex
        if data.count == 1, let firstByte = data.first, firstByte < 0x80 {
            return Data([firstByte])
        }
        // Ensure we return fresh Data (not a slice) for proper concatenation
        return rlpEncodeLength(data.count, offset: 0x80) + Data(data)
    }
    
    private func rlpEncodeLength(_ length: Int, offset: UInt8) -> Data {
        if length < 56 {
            return Data([offset + UInt8(length)])
        }
        var lenBytes = withUnsafeBytes(of: UInt64(length).bigEndian) { Data($0) }
        while lenBytes.first == 0 {
            lenBytes.removeFirst()
        }
        return Data([offset + 55 + UInt8(lenBytes.count)]) + lenBytes
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
