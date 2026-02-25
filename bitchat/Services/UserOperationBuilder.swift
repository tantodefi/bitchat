//
// UserOperationBuilder.swift
// bitchat
//
// ERC-4337 v0.7 PackedUserOperation builder with hybrid (ECDSA + ML-DSA-44) signing.
// Constructs, hashes, and signs UserOperations for the PQ smart account.
//
// This is free and unencumbered software released into the public domain.
// For more information, see <https://unlicense.org>
//

import BitLogger
import CryptoSwift
import Foundation
@preconcurrency import P256K
import SwiftDilithium

// MARK: - PackedUserOperation (ERC-4337 v0.7)

/// ERC-4337 v0.7 PackedUserOperation struct.
/// Fields are packed to reduce calldata cost per ERC-4337 v0.7.
struct PackedUserOperation {
    var sender: Data             // 20 bytes — the smart account address
    var nonce: Data              // 32 bytes — uint256
    var initCode: Data           // bytes — factory + factoryData for account creation, empty if deployed
    var callData: Data           // bytes — the call to execute
    var accountGasLimits: Data   // 32 bytes — packed: verificationGasLimit (16) || callGasLimit (16)
    var preVerificationGas: Data // 32 bytes — uint256
    var gasFees: Data            // 32 bytes — packed: maxPriorityFeePerGas (16) || maxFeePerGas (16)
    var paymasterAndData: Data   // bytes — paymaster + verificationGasLimit + postOpGasLimit + paymasterData
    var signature: Data          // bytes — hybrid signature (ECDSA + ML-DSA-44)
    
    /// Convenience initializer accepting UInt64 for nonce and preVerificationGas
    init(
        sender: Data,
        nonce: UInt64,
        initCode: Data,
        callData: Data,
        accountGasLimits: Data,
        preVerificationGas: UInt64,
        gasFees: Data,
        paymasterAndData: Data,
        signature: Data
    ) {
        self.sender = sender
        self.nonce = PackedUserOperation.uint256Data(nonce)
        self.initCode = initCode
        self.callData = callData
        self.accountGasLimits = accountGasLimits
        self.preVerificationGas = PackedUserOperation.uint256Data(preVerificationGas)
        self.gasFees = gasFees
        self.paymasterAndData = paymasterAndData
        self.signature = signature
    }
    
    /// Pack verificationGasLimit and callGasLimit into 32 bytes
    static func packAccountGasLimits(verificationGasLimit: UInt128, callGasLimit: UInt128) -> Data {
        var data = Data(repeating: 0, count: 32)
        // verificationGasLimit in upper 16 bytes, callGasLimit in lower 16 bytes
        let vgl = verificationGasLimit.bigEndianBytes
        let cgl = callGasLimit.bigEndianBytes
        data.replaceSubrange(0..<16, with: vgl)
        data.replaceSubrange(16..<32, with: cgl)
        return data
    }
    
    /// Convenience overload accepting UInt64
    static func packAccountGasLimits(verificationGasLimit: UInt64, callGasLimit: UInt64) -> Data {
        packAccountGasLimits(
            verificationGasLimit: UInt128(verificationGasLimit),
            callGasLimit: UInt128(callGasLimit)
        )
    }
    
    /// Pack maxPriorityFeePerGas and maxFeePerGas into 32 bytes
    static func packGasFees(maxPriorityFeePerGas: UInt128, maxFeePerGas: UInt128) -> Data {
        var data = Data(repeating: 0, count: 32)
        let mpf = maxPriorityFeePerGas.bigEndianBytes
        let mf = maxFeePerGas.bigEndianBytes
        data.replaceSubrange(0..<16, with: mpf)
        data.replaceSubrange(16..<32, with: mf)
        return data
    }
    
    /// Convenience overload accepting UInt64
    static func packGasFees(maxPriorityFeePerGas: UInt64, maxFeePerGas: UInt64) -> Data {
        packGasFees(
            maxPriorityFeePerGas: UInt128(maxPriorityFeePerGas),
            maxFeePerGas: UInt128(maxFeePerGas)
        )
    }
    
    /// Convert a UInt64 to 32-byte uint256 Data
    static func uint256Data(_ value: UInt64) -> Data {
        var data = Data(repeating: 0, count: 32)
        var bigEndian = value.bigEndian
        data.replaceSubrange(24..<32, with: Data(bytes: &bigEndian, count: 8))
        return data
    }
}

// MARK: - UInt128 Helper

/// Minimal UInt128 representation for gas packing
struct UInt128 {
    let high: UInt64
    let low: UInt64
    
    init(_ value: UInt64) {
        self.high = 0
        self.low = value
    }
    
    init(high: UInt64, low: UInt64) {
        self.high = high
        self.low = low
    }
    
    /// 16-byte big-endian representation
    var bigEndianBytes: Data {
        var data = Data(count: 16)
        var h = high.bigEndian
        var l = low.bigEndian
        data.replaceSubrange(0..<8, with: Data(bytes: &h, count: 8))
        data.replaceSubrange(8..<16, with: Data(bytes: &l, count: 8))
        return data
    }
}

// MARK: - UserOperation Builder

/// Builds and signs ERC-4337 v0.7 PackedUserOperations with hybrid signatures.
struct UserOperationBuilder {
    
    /// ERC-4337 v0.7 EntryPoint address
    static let entryPointV07 = "0x0000000071727De22E5E9d8BAf0edAc6f37da032"
    
    /// Convenience alias
    static var entryPointAddress: String { entryPointV07 }
    
    // MARK: - Gas Packing Forwarding
    
    /// Pack verificationGasLimit and callGasLimit (forwards to PackedUserOperation)
    static func packAccountGasLimits(verificationGasLimit: UInt64, callGasLimit: UInt64) -> Data {
        PackedUserOperation.packAccountGasLimits(verificationGasLimit: verificationGasLimit, callGasLimit: callGasLimit)
    }
    
    /// Pack maxPriorityFeePerGas and maxFeePerGas (forwards to PackedUserOperation)
    static func packGasFees(maxPriorityFeePerGas: UInt64, maxFeePerGas: UInt64) -> Data {
        PackedUserOperation.packGasFees(maxPriorityFeePerGas: maxPriorityFeePerGas, maxFeePerGas: maxFeePerGas)
    }
    
    /// Compute the UserOperation hash per ERC-4337 v0.7 specification.
    /// `userOpHash = keccak256(keccak256(packed_fields), entryPoint, chainId)`
    static func getUserOpHash(userOp: PackedUserOperation, entryPoint: String = entryPointV07, chainId: UInt64) -> Data {
        // Pack the UserOperation fields (without signature)
        var innerPacked = Data()
        
        // sender (address, padded to 32)
        innerPacked.append(ABIEncoder.padLeft(userOp.sender, to: 32))
        
        // nonce (uint256)
        innerPacked.append(ABIEncoder.padLeft(userOp.nonce, to: 32))
        
        // hashInitCode = keccak256(initCode)
        let hashInitCode = keccak256(userOp.initCode)
        innerPacked.append(hashInitCode)
        
        // hashCallData = keccak256(callData)
        let hashCallData = keccak256(userOp.callData)
        innerPacked.append(hashCallData)
        
        // accountGasLimits (bytes32)
        innerPacked.append(userOp.accountGasLimits)
        
        // preVerificationGas (uint256)
        innerPacked.append(ABIEncoder.padLeft(userOp.preVerificationGas, to: 32))
        
        // gasFees (bytes32)
        innerPacked.append(userOp.gasFees)
        
        // hashPaymasterAndData = keccak256(paymasterAndData)
        let hashPaymasterAndData = keccak256(userOp.paymasterAndData)
        innerPacked.append(hashPaymasterAndData)
        
        // Inner hash
        let innerHash = keccak256(innerPacked)
        
        // Outer hash: keccak256(innerHash || entryPoint || chainId)
        var outerPacked = Data()
        outerPacked.append(innerHash)
        
        // entryPoint (address, padded to 32)
        let entryPointBytes = ABIEncoder.hexToData(String(entryPoint.dropFirst(2)))
        outerPacked.append(ABIEncoder.padLeft(entryPointBytes, to: 32))
        
        // chainId (uint256)
        outerPacked.append(ABIEncoder.padLeft(uint256Bytes(chainId), to: 32))
        
        return keccak256(outerPacked)
    }
    
    /// Create a hybrid signature: ABI-encode(ECDSA_sig, MLDSA_sig)
    /// - Parameters:
    ///   - userOpHash: The 32-byte UserOperation hash to sign
    ///   - wallet: The EOA wallet for ECDSA signing
    ///   - pqKeyManager: The PQ key manager for ML-DSA-44 signing
    /// - Returns: ABI-encoded hybrid signature
    static func signHybrid(
        userOpHash: Data,
        wallet: EmbeddedWallet,
        pqKeyManager: PQKeyManager
    ) async throws -> Data {
        // 1. ECDSA sign the userOpHash (produces 65 bytes: r||s||v)
        let ecdsaSig = try await signWithECDSA(hash: userOpHash, wallet: wallet)
        
        // 2. ML-DSA-44 sign the userOpHash (produces 2420 bytes)
        let mldsaSig = try await pqKeyManager.sign(message: userOpHash)
        
        // ── AA23 Diagnostic: log signature components ──
        let vByte = ecdsaSig.count >= 65 ? ecdsaSig[64] : 0
        SecureLogger.info(
            "PQ signHybrid: ecdsaSigLen=\(ecdsaSig.count)B (v=\(vByte)), mldsaSigLen=\(mldsaSig.count)B, "
            + "userOpHash=0x\(userOpHash.map { String(format: "%02x", $0) }.joined().prefix(16))…",
            category: .session
        )
        // Log first 8 bytes of each signature for cross-checking
        let ecdsaHead = ecdsaSig.prefix(8).map { String(format: "%02x", $0) }.joined()
        let mldsaHead = mldsaSig.prefix(8).map { String(format: "%02x", $0) }.joined()
        SecureLogger.debug(
            "PQ signHybrid: ecdsa[0:8]=\(ecdsaHead), mldsa[0:8]=\(mldsaHead)",
            category: .session
        )
        
        // ── AA24 Diagnostic: verify both signatures locally before submission ──
        
        // 2a. Verify ML-DSA-44 signature locally using SwiftDilithium
        do {
            let pk = try await pqKeyManager.getPublicKey()
            let mldsaValid = pk.Verify(message: Array(userOpHash), signature: Array(mldsaSig))
            SecureLogger.info(
                "PQ DIAG: ML-DSA local verify (FIPS 204 pure mode) = \(mldsaValid ? "✅ PASS" : "❌ FAIL")",
                category: .session
            )
            if !mldsaValid {
                SecureLogger.error(
                    "PQ DIAG: ⚠️ ML-DSA signature is INVALID locally — signing is broken!",
                    category: .session
                )
            }
        } catch {
            SecureLogger.error(
                "PQ DIAG: ML-DSA verify check error: \(error)",
                category: .session
            )
        }
        
        // 2b. Verify ECDSA signing key matches the expected EOA address
        do {
            let privateKey = try await wallet.getOrCreatePrivateKey()
            let pubKeyAgreement = try P256K.KeyAgreement.PrivateKey(
                dataRepresentation: privateKey, format: .uncompressed
            )
            let uncompressedPub = pubKeyAgreement.publicKey.dataRepresentation // 65 bytes (04 + x + y)
            let pubKeyRaw = Data(uncompressedPub.dropFirst(1)) // 64 bytes: x + y
            let addressHash = keccak256(pubKeyRaw)
            let derivedAddress = "0x" + addressHash.suffix(20).map { String(format: "%02x", $0) }.joined()
            let expectedAddress = try await wallet.getAddress()
            let addressMatch = derivedAddress.lowercased() == expectedAddress.lowercased()
            SecureLogger.info(
                "PQ DIAG: ECDSA key→address=\(derivedAddress.prefix(14))…, "
                + "expected=\(expectedAddress.prefix(14))…, match=\(addressMatch ? "✅" : "❌")",
                category: .session
            )
            if !addressMatch {
                SecureLogger.error(
                    "PQ DIAG: ⚠️ ECDSA signing key does NOT match stored preQuantumPubKey!",
                    category: .session
                )
            }
        } catch {
            SecureLogger.error(
                "PQ DIAG: ECDSA address check error: \(error)",
                category: .session
            )
        }
        
        // 3. ABI-encode as hybrid: encode(bytes, bytes) = [ecdsaSig, mldsaSig]
        let encoded = ABIEncoder.encodeHybridSignature(
            preQuantumSig: ecdsaSig,
            postQuantumSig: mldsaSig
        )
        
        SecureLogger.debug(
            "PQ signHybrid: ABI-encoded hybridSig total=\(encoded.count)B",
            category: .session
        )
        
        return encoded
    }
    
    /// Sign a hash with the EOA's secp256k1 key directly (raw, no EIP-191 prefix).
    /// Returns 65 bytes: r(32) || s(32) || v(1) where v = recovery ID (0 or 1)
    private static func signWithECDSA(hash: Data, wallet: EmbeddedWallet) async throws -> Data {
        let privateKey = try await wallet.getOrCreatePrivateKey()
        
        guard hash.count == 32, privateKey.count == 32 else {
            throw UserOpError.invalidSignatureInput
        }
        
        // Use P256K recovery signing with raw hash (no re-hashing)
        let privKey = try P256K.Recovery.PrivateKey(dataRepresentation: privateKey, format: .uncompressed)
        let digest = HashDigest(Array(hash))
        let recoverySignature = try privKey.signature(for: digest)
        let compact = try recoverySignature.compactRepresentation
        
        // r(32) || s(32) || v(1) where v = recoveryId + 27 for Solidity ecrecover
        var fullSignature = compact.signature  // 64 bytes
        fullSignature.append(UInt8(compact.recoveryId) + 27)
        
        return fullSignature  // 65 bytes
    }
    
    /// Build initCode for account creation: factory address + createAccount calldata
    static func buildInitCode(
        factoryAddress: String,
        preQuantumPubKey: Data,
        postQuantumPubKey: Data
    ) -> Data {
        // initCode = factory_address (20 bytes) + createAccount(preQuantumPubKey, postQuantumPubKey)
        let factoryBytes = ABIEncoder.hexToData(String(factoryAddress.dropFirst(2)))
        let createAccountCalldata = ABIEncoder.encodeCreateAccount(
            preQuantumPubKey: preQuantumPubKey,
            postQuantumPubKey: postQuantumPubKey
        )
        
        var initCode = Data()
        initCode.append(factoryBytes)
        initCode.append(createAccountCalldata)
        return initCode
    }
    
    /// Create a hybrid signature using an arbitrary stealth ECDSA key + master PQ key.
    /// Used for stealth PQ account sweeps where the ECDSA key differs from the main wallet.
    ///
    /// - Parameters:
    ///   - userOpHash: The 32-byte UserOperation hash to sign
    ///   - stealthPrivateKey: The 32-byte stealth ECDSA private key
    ///   - pqKeyManager: The PQ key manager for ML-DSA-44 signing (shared master key)
    /// - Returns: ABI-encoded hybrid signature
    static func signHybridWithStealthKey(
        userOpHash: Data,
        stealthPrivateKey: Data,
        pqKeyManager: PQKeyManager
    ) async throws -> Data {
        // 1. ECDSA sign with stealth key
        guard userOpHash.count == 32, stealthPrivateKey.count == 32 else {
            throw UserOpError.invalidSignatureInput
        }
        let privKey = try P256K.Recovery.PrivateKey(dataRepresentation: stealthPrivateKey, format: .uncompressed)
        let digest = HashDigest(Array(userOpHash))
        let recoverySignature = try privKey.signature(for: digest)
        let compact = try recoverySignature.compactRepresentation
        var ecdsaSig = compact.signature // 64 bytes
        ecdsaSig.append(UInt8(compact.recoveryId) + 27)
        
        // 2. ML-DSA-44 sign with master PQ key (shared across all stealth accounts)
        let mldsaSig = try await pqKeyManager.sign(message: userOpHash)
        
        // ── AA23 Diagnostic: log stealth signature components ──
        // Derive the signer address from the stealth private key for verification
        let pubKey = try P256K.KeyAgreement.PrivateKey(dataRepresentation: stealthPrivateKey, format: .uncompressed)
        let uncompressedPub = pubKey.publicKey.dataRepresentation // 65 bytes (04 + x + y)
        let pubKeyHash = Data(Array(uncompressedPub.dropFirst()).sha3(.keccak256)) // hash of x||y
        let derivedAddress = "0x" + pubKeyHash.suffix(20).map { String(format: "%02x", $0) }.joined()
        
        let vByte = ecdsaSig.count >= 65 ? ecdsaSig[64] : 0
        SecureLogger.info(
            "PQ signHybridStealth: ecdsaSigLen=\(ecdsaSig.count)B (v=\(vByte)), mldsaSigLen=\(mldsaSig.count)B, "
            + "derivedSignerAddr=\(derivedAddress.prefix(14))…, "
            + "userOpHash=0x\(userOpHash.map { String(format: "%02x", $0) }.joined().prefix(16))…",
            category: .session
        )
        
        // 3. ABI-encode as hybrid
        return ABIEncoder.encodeHybridSignature(
            preQuantumSig: ecdsaSig,
            postQuantumSig: mldsaSig
        )
    }
    
    // MARK: - Helpers
    
    private static func keccak256(_ data: Data) -> Data {
        Data(Array(data).sha3(.keccak256))
    }
    
    private static func uint256Bytes(_ value: UInt64) -> Data {
        var data = Data(repeating: 0, count: 32)
        var bigEndian = value.bigEndian
        data.replaceSubrange(24..<32, with: Data(bytes: &bigEndian, count: 8))
        return data
    }
}

// MARK: - Errors

enum UserOpError: Error, LocalizedError {
    case invalidSignatureInput
    case signingFailed(Error)
    case invalidUserOp(String)
    
    var errorDescription: String? {
        switch self {
        case .invalidSignatureInput:
            return "Invalid input for UserOp signature"
        case .signingFailed(let error):
            return "UserOp signing failed: \(error.localizedDescription)"
        case .invalidUserOp(let reason):
            return "Invalid UserOperation: \(reason)"
        }
    }
}
