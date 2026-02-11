//
// StealthAddressManager.swift
// bitchat
//
// EIP-5564 Stealth Address implementation for private receiving addresses.
// Uses secp256k1 ECDH to generate one-time addresses that only the recipient can identify and spend from.
//
// This is free and unencumbered software released into the public domain.
// For more information, see <https://unlicense.org>
//

import BitLogger
import CryptoKit
import CryptoSwift
import Foundation
@preconcurrency import P256K

/// Manager for EIP-5564 stealth addresses.
/// Enables private receiving by generating one-time addresses that only the recipient can identify.
actor StealthAddressManager {
    
    // MARK: - Constants
    
    /// ERC5564Announcer contract address (deployed on all major networks)
    static let announcerContract = "0x55649E01B5Df198D18D95b5cc5051630cfD45564"
    
    /// Scheme ID for SECP256k1 with view tags (EIP-5564 scheme 1)
    static let schemeId: UInt8 = 1
    
    /// Stealth meta-address prefix
    static let stealthPrefix = "st:eth:0x"
    
    // MARK: - Properties
    
    private let wallet: EmbeddedWallet
    
    // Cached stealth keys (derived from main wallet key)
    private var cachedSpendingPubKey: Data?
    private var cachedViewingPrivKey: Data?
    private var cachedViewingPubKey: Data?
    
    // MARK: - Initialization
    
    init(wallet: EmbeddedWallet) {
        self.wallet = wallet
    }
    
    // MARK: - Key Derivation
    
    /// Derive the spending public key from the main wallet
    /// The spending key IS the main wallet key (no derivation needed)
    func getSpendingPublicKey() async throws -> Data {
        if let cached = cachedSpendingPubKey {
            return cached
        }
        
        let pubKey = try await wallet.getPublicKey()
        // Convert to compressed form (33 bytes)
        let compressed = try compressPublicKey(pubKey)
        cachedSpendingPubKey = compressed
        return compressed
    }
    
    /// Derive the viewing private key from the spending key
    /// viewing_key = keccak256(spending_key || "stealth-viewing-key")
    func getViewingPrivateKey() async throws -> Data {
        if let cached = cachedViewingPrivKey {
            return cached
        }
        
        let spendingKey = try await wallet.getOrCreatePrivateKey()
        let suffix = "stealth-viewing-key".data(using: .utf8)!
        
        var input = spendingKey
        input.append(suffix)
        
        let viewingKey = keccak256(input)
        cachedViewingPrivKey = viewingKey
        return viewingKey
    }
    
    /// Derive the viewing public key from the viewing private key
    func getViewingPublicKey() async throws -> Data {
        if let cached = cachedViewingPubKey {
            return cached
        }
        
        let viewingPrivKey = try await getViewingPrivateKey()
        let pubKey = try derivePublicKeyUncompressed(from: viewingPrivKey)
        // Convert to compressed form (33 bytes)
        let compressed = try compressPublicKey(pubKey)
        cachedViewingPubKey = compressed
        return compressed
    }
    
    /// Get the stealth meta-address in EIP-5564 format
    /// Format: st:eth:0x<P_spend 33 bytes><P_view 33 bytes>
    func getStealthMetaAddress() async throws -> String {
        let spendPubKey = try await getSpendingPublicKey()
        let viewPubKey = try await getViewingPublicKey()
        
        // Concatenate: P_spend (33 bytes) || P_view (33 bytes)
        var metaAddress = spendPubKey
        metaAddress.append(viewPubKey)
        
        return Self.stealthPrefix + metaAddress.toHexString()
    }
    
    // MARK: - Self-Generated Stealth Addresses
    
    /// Result of generating a self-stealth address
    struct SelfStealthAddressResult {
        /// The one-time stealth address
        let stealthAddress: String
        /// Ephemeral public key (compressed, 33 bytes)
        let ephemeralPubKey: Data
        /// View tag for identification
        let viewTag: UInt8
        /// Derivation index used
        let derivationIndex: UInt32
    }
    
    /// Generate a deterministic stealth address from our own meta-address.
    /// Uses HMAC-based key derivation for the ephemeral key to ensure determinism.
    /// - Parameter derivationIndex: Index for deterministic derivation (0, 1, 2, ...)
    /// - Returns: Self-stealth address result with all necessary data
    func generateSelfStealthAddress(derivationIndex: UInt32) async throws -> SelfStealthAddressResult {
        // Get our own stealth meta-address components
        let spendPubKey = try await getSpendingPublicKey()
        let viewPubKey = try await getViewingPublicKey()
        let viewingPrivKey = try await getViewingPrivateKey()
        
        // Generate deterministic ephemeral key using HMAC
        // ephemeral_seed = HMAC-SHA256(viewing_priv, "self-stealth-ephemeral:" || index)
        let indexData = withUnsafeBytes(of: derivationIndex.bigEndian) { Data($0) }
        let prefix = "self-stealth-ephemeral:".data(using: .utf8)!
        var hmacInput = prefix
        hmacInput.append(indexData)
        
        let hmac = HMAC<CryptoKit.SHA256>.authenticationCode(for: hmacInput, using: SymmetricKey(data: viewingPrivKey))
        let ephemeralPrivKey = Data(hmac)
        let ephemeralPubKey = try deriveCompressedPublicKey(from: ephemeralPrivKey)
        
        // Compute shared secret: S = ephemeral_priv * P_view
        let sharedSecret = try ecdhSharedSecret(privateKey: ephemeralPrivKey, publicKey: viewPubKey)
        
        // Hash the shared secret
        let hashedSecret = keccak256(sharedSecret)
        
        // View tag is first byte
        let viewTag = hashedSecret[0]
        
        // Compute stealth public key: P_stealth = P_spend + hash(S) * G
        let stealthPubKey = try addPublicKeys(spendPubKey, scalarMultiplyG(hashedSecret))
        
        // Derive address
        let stealthAddress = try deriveAddress(from: stealthPubKey)
        
        SecureLogger.debug("🥷 Generated self-stealth address #\(derivationIndex) with view tag: \(viewTag)", category: .session)
        
        return SelfStealthAddressResult(
            stealthAddress: stealthAddress,
            ephemeralPubKey: ephemeralPubKey,
            viewTag: viewTag,
            derivationIndex: derivationIndex
        )
    }
    
    // MARK: - Stealth Address Generation (Sender Side)
    
    /// Result of generating a stealth address for sending
    struct StealthAddressResult {
        /// The one-time stealth address to send funds to
        let stealthAddress: String
        /// Ephemeral public key to publish (compressed, 33 bytes)
        let ephemeralPubKey: Data
        /// View tag for efficient scanning (1 byte)
        let viewTag: UInt8
    }
    
    /// Generate a stealth address for sending funds to a recipient
    /// - Parameter stealthMetaAddress: Recipient's stealth meta-address (st:eth:0x...)
    /// - Returns: Stealth address, ephemeral public key, and view tag
    func generateStealthAddress(for stealthMetaAddress: String) throws -> StealthAddressResult {
        // Parse the stealth meta-address
        guard stealthMetaAddress.hasPrefix(Self.stealthPrefix) else {
            throw StealthError.invalidMetaAddress
        }
        
        let hexPart = String(stealthMetaAddress.dropFirst(Self.stealthPrefix.count))
        guard let metaBytes = Data(hexString: hexPart), metaBytes.count == 66 else {
            throw StealthError.invalidMetaAddress
        }
        
        // Extract P_spend (first 33 bytes) and P_view (last 33 bytes)
        let spendPubKey = metaBytes.prefix(33)
        let viewPubKey = metaBytes.suffix(33)
        
        // Generate ephemeral key pair
        let ephemeralPrivKey = generateRandomPrivateKey()
        let ephemeralPubKey = try deriveCompressedPublicKey(from: ephemeralPrivKey)
        
        // Compute shared secret: S = ephemeral_priv * P_view
        let sharedSecret = try ecdhSharedSecret(privateKey: ephemeralPrivKey, publicKey: Data(viewPubKey))
        
        // Hash the shared secret to get the stealth key tweak
        let hashedSecret = keccak256(sharedSecret)
        
        // Compute view tag (first byte of hashed secret)
        let viewTag = hashedSecret[0]
        
        // Compute stealth public key: P_stealth = P_spend + hash(S) * G
        let stealthPubKey = try addPublicKeys(Data(spendPubKey), scalarMultiplyG(hashedSecret))
        
        // Derive address from stealth public key
        let stealthAddress = try deriveAddress(from: stealthPubKey)
        
        SecureLogger.debug("🥷 Generated stealth address with view tag: \(viewTag)", category: .session)
        
        return StealthAddressResult(
            stealthAddress: stealthAddress,
            ephemeralPubKey: ephemeralPubKey,
            viewTag: viewTag
        )
    }
    
    // MARK: - Stealth Address Scanning (Recipient Side)
    
    /// Check if a stealth announcement is for us
    /// - Parameters:
    ///   - ephemeralPubKey: Ephemeral public key from announcement (compressed, 33 bytes)
    ///   - viewTag: View tag from announcement
    ///   - announcedAddress: The announced stealth address
    /// - Returns: True if this stealth address belongs to us
    func checkStealthAddress(
        ephemeralPubKey: Data,
        viewTag: UInt8,
        announcedAddress: String
    ) async throws -> Bool {
        // Compute shared secret: S = viewing_priv * P_ephemeral
        let viewingPrivKey = try await getViewingPrivateKey()
        let sharedSecret = try ecdhSharedSecret(privateKey: viewingPrivKey, publicKey: ephemeralPubKey)
        
        // Hash the shared secret
        let hashedSecret = keccak256(sharedSecret)
        
        // Quick check: does view tag match?
        let expectedViewTag = hashedSecret[0]
        guard viewTag == expectedViewTag else {
            // View tag doesn't match - not our address (255/256 of false positives filtered)
            return false
        }
        
        // View tag matches, do full verification
        // Compute expected stealth address: P_stealth = P_spend + hash(S) * G
        let spendPubKey = try await getSpendingPublicKey()
        let stealthPubKey = try addPublicKeys(spendPubKey, scalarMultiplyG(hashedSecret))
        let expectedAddress = try deriveAddress(from: stealthPubKey)
        
        let matches = expectedAddress.lowercased() == announcedAddress.lowercased()
        
        if matches {
            SecureLogger.info("🥷 Found matching stealth address!", category: .session)
        }
        
        return matches
    }
    
    /// Compute the private key for a stealth address we own
    /// - Parameter ephemeralPubKey: Ephemeral public key from the announcement
    /// - Returns: Private key for the stealth address
    func computeStealthKey(ephemeralPubKey: Data) async throws -> Data {
        // Compute shared secret: S = viewing_priv * P_ephemeral
        let viewingPrivKey = try await getViewingPrivateKey()
        let sharedSecret = try ecdhSharedSecret(privateKey: viewingPrivKey, publicKey: ephemeralPubKey)
        
        // Hash the shared secret
        let hashedSecret = keccak256(sharedSecret)
        
        // stealth_priv = spending_priv + hash(S) mod n
        let spendingPrivKey = try await wallet.getOrCreatePrivateKey()
        let stealthPrivKey = try addPrivateKeys(spendingPrivKey, hashedSecret)
        
        return stealthPrivKey
    }
    
    // MARK: - Announcement Parsing
    
    /// Parsed announcement from ERC5564Announcer contract
    struct StealthAnnouncement {
        let schemeId: UInt8
        let stealthAddress: String
        let ephemeralPubKey: Data
        let viewTag: UInt8
        let metadata: Data
        let blockNumber: UInt64
        let transactionHash: String
    }
    
    /// Decode an Announcement event from ERC5564Announcer
    /// Event: Announcement(uint256 indexed schemeId, address indexed stealthAddress, address indexed caller, bytes ephemeralPubKey, bytes metadata)
    func decodeAnnouncement(
        schemeId: UInt8,
        stealthAddress: String,
        ephemeralPubKey: Data,
        metadata: Data,
        blockNumber: UInt64,
        transactionHash: String
    ) throws -> StealthAnnouncement {
        // View tag is encoded in metadata (first byte) for scheme 1
        guard !metadata.isEmpty else {
            throw StealthError.invalidAnnouncement
        }
        
        let viewTag = metadata[0]
        
        return StealthAnnouncement(
            schemeId: schemeId,
            stealthAddress: stealthAddress,
            ephemeralPubKey: ephemeralPubKey,
            viewTag: viewTag,
            metadata: metadata,
            blockNumber: blockNumber,
            transactionHash: transactionHash
        )
    }
    
    // MARK: - Cryptographic Helpers
    
    /// Generate a random 32-byte private key
    private func generateRandomPrivateKey() -> Data {
        var bytes = Data(count: 32)
        _ = bytes.withUnsafeMutableBytes { ptr in
            SecRandomCopyBytes(kSecRandomDefault, 32, ptr.baseAddress!)
        }
        return bytes
    }
    
    /// Derive uncompressed public key (65 bytes with 0x04 prefix) from private key
    private func derivePublicKeyUncompressed(from privateKey: Data) throws -> Data {
        guard privateKey.count == 32 else {
            throw StealthError.invalidKey
        }
        
        let privKey = try P256K.Signing.PrivateKey(dataRepresentation: privateKey, format: .uncompressed)
        return privKey.publicKey.dataRepresentation
    }
    
    /// Derive compressed public key (33 bytes) from private key
    private func deriveCompressedPublicKey(from privateKey: Data) throws -> Data {
        guard privateKey.count == 32 else {
            throw StealthError.invalidKey
        }
        
        // Get uncompressed public key first, then compress it
        let uncompressedPubKey = try derivePublicKeyUncompressed(from: privateKey)
        return try compressPublicKey(uncompressedPubKey)
    }
    
    /// Compress a 65-byte public key to 33-byte compressed form
    private func compressPublicKey(_ uncompressed: Data) throws -> Data {
        guard uncompressed.count == 65, uncompressed[0] == 0x04 else {
            // Already compressed or invalid
            if uncompressed.count == 33 && (uncompressed[0] == 0x02 || uncompressed[0] == 0x03) {
                return uncompressed
            }
            throw StealthError.invalidKey
        }
        
        // Extract x and y coordinates
        let x = uncompressed[1...32]
        let y = uncompressed[33...64]
        
        // Determine parity of y
        let prefix: UInt8 = (y.last! & 1) == 0 ? 0x02 : 0x03
        
        var compressed = Data([prefix])
        compressed.append(x)
        return compressed
    }
    
    /// Decompress a 33-byte public key to 65-byte uncompressed form
    private func decompressPublicKey(_ compressed: Data) throws -> Data {
        guard compressed.count == 33 else {
            throw StealthError.invalidKey
        }
        
        // Use P256K to decompress by creating a key and getting uncompressed representation
        // This is a bit roundabout but ensures we use the library's curve math
        let pubKey = try P256K.Signing.PublicKey(dataRepresentation: compressed, format: .compressed)
        return pubKey.dataRepresentation
    }
    
    /// Perform ECDH to compute shared secret
    private func ecdhSharedSecret(privateKey: Data, publicKey: Data) throws -> Data {
        guard privateKey.count == 32 else {
            throw StealthError.invalidKey
        }
        
        // Ensure public key is in compressed form for P256K
        let compressedPubKey: Data
        if publicKey.count == 65 && publicKey[0] == 0x04 {
            compressedPubKey = try compressPublicKey(publicKey)
        } else if publicKey.count == 33 {
            compressedPubKey = publicKey
        } else {
            throw StealthError.invalidKey
        }
        
        // Use P256K's ECDH
        let privKey = try P256K.KeyAgreement.PrivateKey(dataRepresentation: privateKey, format: .uncompressed)
        let pubKey = try P256K.KeyAgreement.PublicKey(dataRepresentation: compressedPubKey, format: .compressed)
        
        let sharedSecret = try privKey.sharedSecretFromKeyAgreement(with: pubKey)
        
        // sharedSecret is the x-coordinate of the shared point
        return sharedSecret.withUnsafeBytes { Data($0) }
    }
    
    /// Scalar multiply a value by the generator point G
    /// Returns compressed public key (33 bytes)
    private func scalarMultiplyG(_ scalar: Data) throws -> Data {
        guard scalar.count == 32 else {
            throw StealthError.invalidKey
        }
        
        // Treat scalar as a private key and derive public key = scalar * G
        return try deriveCompressedPublicKey(from: scalar)
    }
    
    /// Add two public keys (point addition on the curve)
    private func addPublicKeys(_ pubKey1: Data, _ pubKey2: Data) throws -> Data {
        // Decompress both keys
        let p1 = try decompressPublicKey(pubKey1)
        let p2 = try decompressPublicKey(pubKey2)
        
        // For secp256k1 point addition, we need to implement the math or use FFI
        // P256K doesn't expose point addition directly, so we'll use CryptoSwift BigInt math
        
        // secp256k1 curve parameters
        let p = BigUInt(hexString: "FFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFEFFFFFC2F")!
        
        // Extract coordinates
        let x1 = BigUInt(data: Data(p1[1...32]))
        let y1 = BigUInt(data: Data(p1[33...64]))
        let x2 = BigUInt(data: Data(p2[1...32]))
        let y2 = BigUInt(data: Data(p2[33...64]))
        
        // Point addition formula
        // If P1 != P2: lambda = (y2 - y1) / (x2 - x1) mod p
        // x3 = lambda^2 - x1 - x2 mod p
        // y3 = lambda * (x1 - x3) - y1 mod p
        
        let (x3, y3): (BigUInt, BigUInt)
        
        if x1 == x2 && y1 == y2 {
            // Point doubling (same point)
            // lambda = (3*x1^2) / (2*y1) mod p
            let three = BigUInt(3)
            let two = BigUInt(2)
            let numerator = (three * x1 * x1) % p
            let denominator = (two * y1) % p
            let lambda = (numerator * modInverse(denominator, p)) % p
            
            x3 = ((lambda * lambda) + p + p - x1 - x2) % p
            y3 = ((lambda * ((x1 + p - x3) % p)) + p - y1) % p
        } else {
            // Different points
            let dy = (y2 + p - y1) % p
            let dx = (x2 + p - x1) % p
            let lambda = (dy * modInverse(dx, p)) % p
            
            x3 = ((lambda * lambda) + p + p - x1 - x2) % p
            y3 = ((lambda * ((x1 + p - x3) % p)) + p - y1) % p
        }
        
        // Construct uncompressed public key
        var result = Data([0x04])
        result.append(x3.serialize().padLeft(to: 32))
        result.append(y3.serialize().padLeft(to: 32))
        
        // Return compressed form
        return try compressPublicKey(result)
    }
    
    /// Add two private keys (scalar addition mod curve order)
    private func addPrivateKeys(_ key1: Data, _ key2: Data) throws -> Data {
        guard key1.count == 32, key2.count == 32 else {
            throw StealthError.invalidKey
        }
        
        // secp256k1 curve order
        let n = BigUInt(hexString: "FFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFEBAAEDCE6AF48A03BBFD25E8CD0364141")!
        
        let k1 = BigUInt(data: key1)
        let k2 = BigUInt(data: key2)
        
        let sum = (k1 + k2) % n
        
        return sum.serialize().padLeft(to: 32)
    }
    
    /// Modular inverse using extended Euclidean algorithm
    private func modInverse(_ a: BigUInt, _ m: BigUInt) -> BigUInt {
        // Extended Euclidean Algorithm
        var (old_r, r) = (a, m)
        var (old_s, s) = (BigUInt(1), BigUInt(0))
        
        while !r.isZero {
            let quotient = old_r / r
            (old_r, r) = (r, (old_r + m - (quotient % m) * (r % m)) % m)
            
            // Handle potential underflow in s calculation
            let qs = (quotient * s) % m
            if old_s >= qs {
                (old_s, s) = (s, (old_s - qs) % m)
            } else {
                (old_s, s) = (s, (m + old_s - qs) % m)
            }
        }
        
        return old_s % m
    }
    
    /// Keccak-256 hash
    private func keccak256(_ data: Data) -> Data {
        let bytes = Array(data)
        let hash = bytes.sha3(.keccak256)
        return Data(hash)
    }
    
    /// Derive Ethereum address from uncompressed public key
    private func deriveAddress(from publicKey: Data) throws -> String {
        let pubKeyToHash: Data
        
        if publicKey.count == 65 && publicKey[0] == 0x04 {
            // Remove 0x04 prefix
            pubKeyToHash = publicKey.dropFirst()
        } else if publicKey.count == 33 {
            // Decompress first
            let uncompressed = try decompressPublicKey(publicKey)
            pubKeyToHash = uncompressed.dropFirst()
        } else if publicKey.count == 64 {
            pubKeyToHash = publicKey
        } else {
            throw StealthError.invalidKey
        }
        
        // Hash the public key (x || y, 64 bytes)
        let hash = keccak256(pubKeyToHash)
        
        // Take last 20 bytes as address
        let addressBytes = hash.suffix(20)
        return "0x" + addressBytes.toHexString()
    }
}

// MARK: - Errors

enum StealthError: Error, LocalizedError {
    case invalidMetaAddress
    case invalidKey
    case invalidAnnouncement
    case ecdhFailed
    case addressDerivationFailed
    
    var errorDescription: String? {
        switch self {
        case .invalidMetaAddress:
            return "Invalid stealth meta-address format"
        case .invalidKey:
            return "Invalid key format or length"
        case .invalidAnnouncement:
            return "Invalid stealth announcement format"
        case .ecdhFailed:
            return "ECDH key agreement failed"
        case .addressDerivationFailed:
            return "Failed to derive address from public key"
        }
    }
}

// MARK: - BigUInt Extension

private extension BigUInt {
    /// Initialize from raw bytes
    init(data: Data) {
        // Parse data as big-endian bytes
        let hex = data.map { String(format: "%02x", $0) }.joined()
        self = BigUInt(hexString: hex) ?? BigUInt(0)
    }
    
    /// Serialize to big-endian Data
    func serialize() -> Data {
        if isZero { return Data([0]) }
        
        // Serialize directly to bytes
        return serializeToBytes()
    }
    
    /// Internal method to serialize to bytes
    private func serializeToBytes() -> Data {
        if isZero { return Data([0]) }
        
        // Use division by 256 to extract bytes
        var result = Data()
        var value = self
        let byte256 = BigUInt(256)
        
        while !value.isZero {
            let (quotient, remainder) = value.dividedBy(byte256)
            // Convert remainder to UInt8
            let byteValue = UInt8(truncatingIfNeeded: remainder.toUInt64())
            result.insert(byteValue, at: 0)
            value = quotient
        }
        
        return result.isEmpty ? Data([0]) : result
    }
    
    /// Convert to UInt64 (may truncate)
    func toUInt64() -> UInt64 {
        // Simple case - parse from description for small values
        return UInt64(description) ?? 0
    }
}

private extension Data {
    /// Pad data to specified length with leading zeros
    func padLeft(to length: Int) -> Data {
        if count >= length { return self }
        return Data(repeating: 0, count: length - count) + self
    }
}
