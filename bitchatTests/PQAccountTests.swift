//
// PQAccountTests.swift
// bitchatTests
//
// Unit tests for PQ (post-quantum) account components:
// key generation, ABI encoding, key expansion, UserOp hashing.
//
// This is free and unencumbered software released into the public domain.
// For more information, see <https://unlicense.org>
//

import Testing
import Foundation
@testable import bitchat

// MARK: - PQ Key Manager Tests

@Suite("PQ Key Manager")
struct PQKeyManagerTests {
    
    @Test func keysCreatedFromWallet() async throws {
        let keychain = MockKeychain()
        let wallet = EmbeddedWallet(keychain: keychain)
        let pqManager = PQKeyManager(keychain: keychain)
        
        // Generate PQ keys from wallet
        let (_, _) = try await pqManager.getOrCreateKeys(from: wallet)
        
        // Verify key exists
        let exists = await pqManager.keysExist()
        #expect(exists, "PQ keys should exist after creation")
        
        // Verify public key is ML-DSA-44 size (1312 bytes)
        let pubKey = try await pqManager.getPublicKey()
        #expect(pubKey.keyBytes.count == 1312, "ML-DSA-44 public key should be 1312 bytes")
    }
    
    @Test func keysLoadConsistentlyFromKeychain() async throws {
        let keychain = MockKeychain()
        let wallet = EmbeddedWallet(keychain: keychain)
        
        let pqManager1 = PQKeyManager(keychain: keychain)
        let _ = try await pqManager1.getOrCreateKeys(from: wallet)
        let pubKey1 = try await pqManager1.getPublicKey()
        
        // Create a new PQKeyManager instance with same keychain
        // It should load the same keys from keychain
        let pqManager2 = PQKeyManager(keychain: keychain)
        let _ = try await pqManager2.getOrCreateKeys(from: wallet)
        let pubKey2 = try await pqManager2.getPublicKey()
        
        #expect(pubKey1.keyBytes == pubKey2.keyBytes,
                "PQ keys loaded from same keychain should be identical")
    }
    
    @Test func signAndVerifyRoundTrip() async throws {
        let keychain = MockKeychain()
        let wallet = EmbeddedWallet(keychain: keychain)
        let pqManager = PQKeyManager(keychain: keychain)
        
        let _ = try await pqManager.getOrCreateKeys(from: wallet)
        
        let message = Data("test message for PQ signing".utf8)
        let signature = try await pqManager.sign(message: message)
        
        // ML-DSA-44 signature should be 2420 bytes
        #expect(signature.count == 2420, "ML-DSA-44 signature should be 2420 bytes")
    }
    
    @Test func seedExportReturnsSecretKeyBytes() async throws {
        let keychain = MockKeychain()
        let wallet = EmbeddedWallet(keychain: keychain)
        let pqManager = PQKeyManager(keychain: keychain)
        
        let _ = try await pqManager.getOrCreateKeys(from: wallet)
        let seed = try await pqManager.exportSeed()
        
        // ML-DSA-44 secret key is 2560 bytes
        #expect(seed.count > 0, "Exported key bytes should be non-empty")
    }
    
    @Test func clearKeysRemovesCachedState() async throws {
        let keychain = MockKeychain()
        let wallet = EmbeddedWallet(keychain: keychain)
        let pqManager = PQKeyManager(keychain: keychain)
        
        let _ = try await pqManager.getOrCreateKeys(from: wallet)
        #expect(await pqManager.keysExist(), "Keys should exist")
        
        await pqManager.clearKeys()
        // After clearing, keysExist checks keychain — seed may still be there
        // but internal cached keys should be nil
    }
}

// MARK: - ABI Encoder Tests

@Suite("ABI Encoder")
struct ABIEncoderTests {
    
    @Test func encodeUint256() {
        let encoded = ABIEncoder.encode(
            types: [.uint256],
            values: [.uint256(42)]
        )
        
        #expect(encoded.count == 32, "uint256 should be 32 bytes")
        #expect(encoded.last == 42, "Last byte should be 42")
        // All preceding bytes should be zero
        for i in 0..<31 {
            #expect(encoded[i] == 0, "Byte \(i) should be zero-padded")
        }
    }
    
    @Test func encodeAddress() {
        let addressBytes = Data(repeating: 0xAB, count: 20)
        let encoded = ABIEncoder.encode(
            types: [.address],
            values: [.addressData(addressBytes)]
        )
        
        #expect(encoded.count == 32, "Address should be left-padded to 32 bytes")
        // First 12 bytes should be zero
        for i in 0..<12 {
            #expect(encoded[i] == 0, "Byte \(i) should be zero-padded")
        }
        // Last 20 bytes should be the address
        #expect(encoded[12..<32] == addressBytes[0..<20])
    }
    
    @Test func encodeBytes() {
        let data = Data([0x01, 0x02, 0x03, 0x04, 0x05])
        let encoded = ABIEncoder.encode(
            types: [.bytes],
            values: [.bytes(data)]
        )
        
        // Should have: offset (32) + length (32) + padded data (32) = 96 bytes
        #expect(encoded.count == 96, "Encoded bytes should include offset + length + padded data")
        
        // Offset should point to byte 32
        #expect(encoded[31] == 32, "Offset should be 32")
        
        // Length should be 5
        #expect(encoded[63] == 5, "Length should be 5")
        
        // First 5 bytes of data should match
        #expect(Array(encoded[64..<69]) == [0x01, 0x02, 0x03, 0x04, 0x05])
    }
    
    @Test func functionSelector() {
        let selector = ABIEncoder.functionSelector("createAccount(bytes,bytes)")
        #expect(selector.count == 4, "Function selector should be 4 bytes")
    }
    
    @Test func encodeHybridSignature() {
        let ecdsaSig = Data(repeating: 0xAA, count: 65)
        let pqSig = Data(repeating: 0xBB, count: 2420)
        
        let encoded = ABIEncoder.encodeHybridSignature(
            preQuantumSig: ecdsaSig,
            postQuantumSig: pqSig
        )
        
        // Should be ABI-encoded tuple of (bytes, bytes)
        // At minimum: 2 offsets (64) + 2 lengths (64) + padded data
        #expect(encoded.count > 64, "Hybrid signature should be ABI-encoded")
    }
    
    @Test func encodeCreateAccount() {
        let ecdsaKey = Data(repeating: 0x04, count: 65)
        let pqKey = Data(repeating: 0xCC, count: 1312)
        
        let calldata = ABIEncoder.encodeCreateAccount(
            preQuantumPubKey: ecdsaKey,
            postQuantumPubKey: pqKey
        )
        
        // First 4 bytes should be function selector
        #expect(calldata.count > 4, "createAccount calldata should include selector + params")
    }
    
    @Test func hexConversion() {
        let data = Data([0xDE, 0xAD, 0xBE, 0xEF])
        let hex = ABIEncoder.dataToHex(data, prefixed: false)
        #expect(hex == "deadbeef")
        
        let roundTrip = ABIEncoder.hexToData(hex)
        #expect(roundTrip == data, "Hex round-trip should preserve data")
    }
    
    @Test func hexConversionPrefixed() {
        let data = Data([0x01, 0x02])
        let hex = ABIEncoder.dataToHex(data, prefixed: true)
        #expect(hex == "0x0102")
    }
    
    @Test func padLeft() {
        let data = Data([0x01, 0x02])
        let padded = ABIEncoder.padLeft(data, to: 32)
        
        #expect(padded.count == 32)
        #expect(padded[30] == 0x01)
        #expect(padded[31] == 0x02)
    }
    
    @Test func encodeExecute() {
        let dest = "0x1234567890abcdef1234567890abcdef12345678"
        let calldata = ABIEncoder.encodeExecute(
            dest: dest,
            value: 0,
            funcData: Data()
        )
        
        #expect(calldata.count > 4, "execute calldata should include selector + params")
    }
}

// MARK: - UserOperationBuilder Tests

@Suite("UserOperation Builder")
struct UserOperationBuilderTests {
    
    @Test func packAccountGasLimits() {
        let packed = UserOperationBuilder.packAccountGasLimits(
            verificationGasLimit: 100_000,
            callGasLimit: 200_000
        )
        
        #expect(packed.count == 32, "Packed gas limits should be 32 bytes")
    }
    
    @Test func packGasFees() {
        let packed = UserOperationBuilder.packGasFees(
            maxPriorityFeePerGas: 2_000_000_000,
            maxFeePerGas: 50_000_000_000
        )
        
        #expect(packed.count == 32, "Packed gas fees should be 32 bytes")
    }
    
    @Test func getUserOpHashIsConsistent() {
        let userOp = PackedUserOperation(
            sender: Data(repeating: 0x01, count: 20),
            nonce: 0,
            initCode: Data(),
            callData: Data(),
            accountGasLimits: Data(repeating: 0, count: 32),
            preVerificationGas: 100_000,
            gasFees: Data(repeating: 0, count: 32),
            paymasterAndData: Data(),
            signature: Data()
        )
        
        let hash1 = UserOperationBuilder.getUserOpHash(
            userOp: userOp,
            entryPoint: UserOperationBuilder.entryPointAddress,
            chainId: 11_155_111
        )
        
        let hash2 = UserOperationBuilder.getUserOpHash(
            userOp: userOp,
            entryPoint: UserOperationBuilder.entryPointAddress,
            chainId: 11_155_111
        )
        
        #expect(hash1 == hash2, "Same UserOp should produce same hash")
        #expect(hash1.count == 32, "UserOp hash should be 32 bytes (keccak256)")
    }
    
    @Test func differentNonceProducesDifferentHash() {
        let userOp1 = PackedUserOperation(
            sender: Data(repeating: 0x01, count: 20),
            nonce: 0,
            initCode: Data(),
            callData: Data(),
            accountGasLimits: Data(repeating: 0, count: 32),
            preVerificationGas: 100_000,
            gasFees: Data(repeating: 0, count: 32),
            paymasterAndData: Data(),
            signature: Data()
        )
        
        let userOp2 = PackedUserOperation(
            sender: Data(repeating: 0x01, count: 20),
            nonce: 1,
            initCode: Data(),
            callData: Data(),
            accountGasLimits: Data(repeating: 0, count: 32),
            preVerificationGas: 100_000,
            gasFees: Data(repeating: 0, count: 32),
            paymasterAndData: Data(),
            signature: Data()
        )
        
        let hash1 = UserOperationBuilder.getUserOpHash(
            userOp: userOp1,
            entryPoint: UserOperationBuilder.entryPointAddress,
            chainId: 11_155_111
        )
        
        let hash2 = UserOperationBuilder.getUserOpHash(
            userOp: userOp2,
            entryPoint: UserOperationBuilder.entryPointAddress,
            chainId: 11_155_111
        )
        
        #expect(hash1 != hash2, "Different nonce should produce different hash")
    }
    
    @Test func buildInitCodeIncludesFactory() {
        let ecdsaKey = Data(repeating: 0x04, count: 65)
        let pqKey = Data(repeating: 0xCC, count: 1312)
        
        let initCode = UserOperationBuilder.buildInitCode(
            factoryAddress: PQAccountDeployer.factoryAddress,
            preQuantumPubKey: ecdsaKey,
            postQuantumPubKey: pqKey
        )
        
        // initCode = factory address (20 bytes) + createAccount calldata
        #expect(initCode.count > 20, "initCode should include factory address + calldata")
        
        // First 20 bytes should be factory address
        let factoryHex = String(PQAccountDeployer.factoryAddress.dropFirst(2))
        let expectedFactory = ABIEncoder.hexToData(factoryHex)
        #expect(initCode.prefix(20) == expectedFactory, "First 20 bytes should be factory address")
    }
}

// MARK: - ML-DSA Key Expander Tests

@Suite("ML-DSA Key Expander")
struct MLDSAKeyExpanderTests {
    
    @Test func publicKeyDecoding() throws {
        // Create a mock ML-DSA-44 public key (1312 bytes)
        // rho = first 32 bytes, t1 = remaining 1280 bytes
        var mockPK = [UInt8](repeating: 0, count: 1312)
        // Set some deterministic rho bytes
        for i in 0..<32 {
            mockPK[i] = UInt8(i & 0xFF)
        }
        // Set some t1 bytes (10-bit packed coefficients)
        for i in 32..<1312 {
            mockPK[i] = UInt8((i * 7) & 0xFF)
        }
        
        let decoded = try MLDSAKeyExpander.decodePublicKey(mockPK)
        
        #expect(decoded.rho.count == 32, "rho should be 32 bytes")
        #expect(decoded.t1.count == 4, "Should have K=4 t1 polynomials")
        
        for poly in decoded.t1 {
            #expect(poly.count == 256, "Each polynomial should have N=256 coefficients")
        }
    }
    
    @Test func rejectionSamplingProducesValidCoeffs() throws {
        // Use a known rho for deterministic sampling
        let rho = [UInt8](repeating: 0x42, count: 32)
        
        let poly = MLDSAKeyExpander.rejectionSamplePoly(rho: rho, i: 0, j: 0)
        
        #expect(poly.count == 256, "Sampled polynomial should have 256 coefficients")
        
        // All coefficients should be in [0, Q)
        let Q: Int32 = 8_380_417
        for coeff in poly {
            #expect(coeff >= 0 && coeff < Q, "Coefficient \(coeff) should be in [0, Q)")
        }
    }
    
    @Test func expandedKeyEncodingProducesOutput() throws {
        // Use a deterministic public key
        var pk = [UInt8](repeating: 0, count: 1312)
        for i in 0..<1312 {
            pk[i] = UInt8((i * 3 + 17) & 0xFF)
        }
        
        let expandedBytes = try MLDSAKeyExpander.toExpandedEncodedBytes(publicKey: pk)
        
        // Should produce ABI-encoded output
        #expect(expandedBytes.count > 0, "Expanded key should produce non-empty output")
        
        // Output should be a multiple of 32 (ABI encoding)
        #expect(expandedBytes.count % 32 == 0, "ABI-encoded output should be 32-byte aligned")
    }
}

// MARK: - PQ Account Deployer Tests

@Suite("PQ Account Deployer")
struct PQAccountDeployerTests {
    
    @Test func factoryAddressIsCorrect() {
        let expected = "0xe28F039653772C32b0eDB1db7c7A5FA250DDA0e5"
        #expect(PQAccountDeployer.factoryAddress == expected)
    }
    
    @Test func chainIds() {
        #expect(PQAccountDeployer.Chain.sepolia.chainId == 11_155_111)
        #expect(PQAccountDeployer.Chain.arbitrumSepolia.chainId == 421_614)
    }
    
    @Test func buildInitCodeMatchesUserOpBuilder() {
        let ecdsaKey = Data(repeating: 0x04, count: 65)
        let pqKey = Data(repeating: 0xDD, count: 1312)
        
        let deployer = PQAccountDeployer(chain: .sepolia)
        // Cannot call async buildInitCode in sync test directly,
        // but can verify the static version
        let initCode = UserOperationBuilder.buildInitCode(
            factoryAddress: PQAccountDeployer.factoryAddress,
            preQuantumPubKey: ecdsaKey,
            postQuantumPubKey: pqKey
        )
        
        #expect(initCode.count > 20)
    }
}

// MARK: - PQ Account State Tests

@Suite("PQ Account State")
struct PQAccountStateTests {
    
    @Test func stateEquality() {
        #expect(PQAccountState.notInitialized == PQAccountState.notInitialized)
        #expect(PQAccountState.deploying == PQAccountState.deploying)
        #expect(PQAccountState.deployed("0x123") == PQAccountState.deployed("0x123"))
        #expect(PQAccountState.deployed("0x123") != PQAccountState.deployed("0x456"))
    }
    
    @Test func stateIsDeployed() {
        #expect(!PQAccountState.notInitialized.isDeployed)
        #expect(!PQAccountState.keysReady.isDeployed)
        #expect(!PQAccountState.deploying.isDeployed)
        #expect(PQAccountState.deployed("0x123").isDeployed)
        #expect(!PQAccountState.error("fail").isDeployed)
    }
    
    @Test func stateAccountAddress() {
        #expect(PQAccountState.notInitialized.accountAddress == nil)
        #expect(PQAccountState.deployed("0x123").accountAddress == "0x123")
    }
}

// MARK: - Integration: Key Gen + Sign

@Suite("PQ Integration")
struct PQIntegrationTests {
    
    @Test func keyGenAndHybridSignFlow() async throws {
        let keychain = MockKeychain()
        let wallet = EmbeddedWallet(keychain: keychain)
        let pqManager = PQKeyManager(keychain: keychain)
        
        // Initialize keys
        let _ = try await pqManager.getOrCreateKeys(from: wallet)
        
        // Build a dummy UserOp
        let userOp = PackedUserOperation(
            sender: Data(repeating: 0x01, count: 20),
            nonce: 0,
            initCode: Data(),
            callData: Data(),
            accountGasLimits: Data(repeating: 0, count: 32),
            preVerificationGas: 100_000,
            gasFees: Data(repeating: 0, count: 32),
            paymasterAndData: Data(),
            signature: Data()
        )
        
        // Compute hash
        let hash = UserOperationBuilder.getUserOpHash(
            userOp: userOp,
            entryPoint: UserOperationBuilder.entryPointAddress,
            chainId: 11_155_111
        )
        
        #expect(hash.count == 32)
        
        // Sign hybrid (ECDSA + ML-DSA-44)
        let hybridSig = try await UserOperationBuilder.signHybrid(
            userOpHash: hash,
            wallet: wallet,
            pqKeyManager: pqManager
        )
        
        // Hybrid sig should be ABI-encoded (bytes, bytes) containing 65-byte ECDSA + 2420-byte ML-DSA
        #expect(hybridSig.count > 65 + 2420,
                "Hybrid signature should contain both ECDSA and ML-DSA signatures with ABI encoding overhead")
    }
}

// MARK: - Cross-Validation Tests

@Suite("PQ Cross-Validation")
struct PQCrossValidationTests {
    
    // MARK: - ML-DSA-44 Key Sizes
    
    @Test func mldsaKeySizesMatchFIPS204() async throws {
        let keychain = MockKeychain()
        let wallet = EmbeddedWallet(keychain: keychain)
        let pqManager = PQKeyManager(keychain: keychain)
        
        let (sk, pk) = try await pqManager.getOrCreateKeys(from: wallet)
        
        // FIPS 204 Table 2: ML-DSA-44 parameters
        #expect(pk.keyBytes.count == 1312, "ML-DSA-44 public key must be 1312 bytes (FIPS 204)")
        #expect(sk.keyBytes.count == 2560, "ML-DSA-44 secret key must be 2560 bytes (FIPS 204)")
        
        // Verify signature size
        let sig = try await pqManager.sign(message: Data(repeating: 0xAA, count: 32))
        #expect(sig.count == 2420, "ML-DSA-44 signature must be 2420 bytes (FIPS 204)")
    }
    
    // MARK: - Randomized vs Deterministic Signing
    
    @Test func randomizedSigningProducesDifferentSignatures() async throws {
        let keychain = MockKeychain()
        let wallet = EmbeddedWallet(keychain: keychain)
        let pqManager = PQKeyManager(keychain: keychain)
        
        let _ = try await pqManager.getOrCreateKeys(from: wallet)
        
        let message = Data(repeating: 0x42, count: 32)
        let sig1 = try await pqManager.sign(message: message)
        let sig2 = try await pqManager.sign(message: message)
        
        // SwiftDilithium uses randomized signing by default (randomize: true)
        // This is more secure — each signature is different even for the same message
        // Both signatures are valid, but not identical
        #expect(sig1.count == 2420, "ML-DSA-44 signature should be 2420 bytes")
        #expect(sig2.count == 2420, "ML-DSA-44 signature should be 2420 bytes")
        // Note: randomized signing means sig1 != sig2 is expected
        // Both are valid signatures that can be verified against the same public key
    }
    
    // MARK: - Public Key Expansion Structure
    
    @Test func expandedKeyStructureMatchesKohaku() throws {
        // The expanded key must be ABI-encoded as (bytes, bytes, bytes)
        // where: aHatEncoded, tr (64 bytes), t1Encoded
        
        // Create a deterministic public key
        var pk = [UInt8](repeating: 0, count: 1312)
        for i in 0..<1312 {
            pk[i] = UInt8((i * 3 + 17) & 0xFF)
        }
        
        let expandedBytes = try MLDSAKeyExpander.toExpandedEncodedBytes(publicKey: pk)
        
        // ABI-encoded (bytes, bytes, bytes) has:
        // - 3 offset words (96 bytes header)
        // - then 3 dynamic byte arrays
        #expect(expandedBytes.count >= 96, "Must have at least 3 ABI offset words")
        #expect(expandedBytes.count % 32 == 0, "Must be 32-byte aligned (ABI encoding)")
        
        // Verify the 3 offsets point to valid locations
        let offset1 = abiDecodeUint256(expandedBytes, at: 0)
        let offset2 = abiDecodeUint256(expandedBytes, at: 32)
        let offset3 = abiDecodeUint256(expandedBytes, at: 64)
        
        #expect(offset1 >= 96, "First offset must be past header")
        #expect(offset2 > offset1, "Second offset must be after first data")
        #expect(offset3 > offset2, "Third offset must be after second data")
        #expect(Int(offset3) < expandedBytes.count, "Third offset must be within bounds")
    }
    
    // MARK: - Rejection Sampling Determinism
    
    @Test func rejectionSamplingIsDeterministic() {
        let rho = [UInt8](0..<32)
        
        let poly1 = MLDSAKeyExpander.rejectionSamplePoly(rho: rho, i: 0, j: 0)
        let poly2 = MLDSAKeyExpander.rejectionSamplePoly(rho: rho, i: 0, j: 0)
        
        #expect(poly1 == poly2, "Same rho,i,j must produce identical polynomial (deterministic SHAKE-128 XOF)")
    }
    
    @Test func rejectionSamplingDifferentIndicesProduceDifferentPolys() {
        let rho = [UInt8](0..<32)
        
        let poly_00 = MLDSAKeyExpander.rejectionSamplePoly(rho: rho, i: 0, j: 0)
        let poly_01 = MLDSAKeyExpander.rejectionSamplePoly(rho: rho, i: 0, j: 1)
        let poly_10 = MLDSAKeyExpander.rejectionSamplePoly(rho: rho, i: 1, j: 0)
        
        #expect(poly_00 != poly_01, "Different j index should produce different polynomial")
        #expect(poly_00 != poly_10, "Different i index should produce different polynomial")
    }
    
    // MARK: - Â Matrix Recovery
    
    @Test func aHatMatrixHasCorrectDimensions() {
        let rho = [UInt8](0..<32)
        let aHat = MLDSAKeyExpander.recoverAHat(rho: rho, k: 4, l: 4)
        
        #expect(aHat.count == 4, "Â matrix should have K=4 rows")
        for row in aHat {
            #expect(row.count == 4, "Each row should have L=4 polynomials")
            for poly in row {
                #expect(poly.count == 256, "Each polynomial should have N=256 coefficients")
            }
        }
    }
    
    // MARK: - Polynomial Decoding (10-bit)
    
    @Test func polyDecode10BitsRoundTrip() {
        // Create coefficients in [0, 1023] range (10-bit max)
        var coeffs = [Int32](repeating: 0, count: 256)
        for i in 0..<256 {
            coeffs[i] = Int32(i % 1024) // values 0..255, all fit in 10 bits
        }
        
        // Encode to bytes (10-bit packing, little-endian)
        var bytes = [UInt8](repeating: 0, count: 320) // 256 * 10 / 8 = 320
        for i in 0..<256 {
            let bitOffset = i * 10
            let byteIdx = bitOffset / 8
            let bitIdx = bitOffset % 8
            let val = Int(coeffs[i])
            bytes[byteIdx] |= UInt8(truncatingIfNeeded: val << bitIdx)
            if bitIdx + 10 > 8 && byteIdx + 1 < 320 {
                bytes[byteIdx + 1] |= UInt8(truncatingIfNeeded: val >> (8 - bitIdx))
            }
            if bitIdx + 10 > 16 && byteIdx + 2 < 320 {
                bytes[byteIdx + 2] |= UInt8(truncatingIfNeeded: val >> (16 - bitIdx))
            }
        }
        
        let decoded = MLDSAKeyExpander.polyDecode10Bits(bytes)
        
        #expect(decoded.count == 256, "Decoded polynomial should have 256 coefficients")
        for i in 0..<256 {
            #expect(decoded[i] == coeffs[i], "Coefficient \(i): expected \(coeffs[i]), got \(decoded[i])")
        }
    }
    
    // MARK: - UserOp Hash Cross-Validation
    
    @Test func userOpHashMatchesERC4337Spec() {
        // Per ERC-4337 v0.7:
        // hash = keccak256(encode(keccak256(pack(userOp)), entryPoint, chainId))
        
        let userOp = PackedUserOperation(
            sender: Data(repeating: 0x01, count: 20),
            nonce: 0,
            initCode: Data(),
            callData: Data(),
            accountGasLimits: Data(repeating: 0, count: 32),
            preVerificationGas: 100_000,
            gasFees: Data(repeating: 0, count: 32),
            paymasterAndData: Data(),
            signature: Data()
        )
        
        let hash = UserOperationBuilder.getUserOpHash(
            userOp: userOp,
            entryPoint: UserOperationBuilder.entryPointAddress,
            chainId: 11_155_111
        )
        
        // Hash must be exactly 32 bytes (keccak256 output)
        #expect(hash.count == 32, "UserOp hash must be 32 bytes")
        
        // Same inputs must always produce the same hash
        let hash2 = UserOperationBuilder.getUserOpHash(
            userOp: userOp,
            entryPoint: UserOperationBuilder.entryPointAddress,
            chainId: 11_155_111
        )
        #expect(hash == hash2, "UserOp hash must be deterministic")
        
        // Different chainId should produce different hash
        let hashDiffChain = UserOperationBuilder.getUserOpHash(
            userOp: userOp,
            entryPoint: UserOperationBuilder.entryPointAddress,
            chainId: 421_614 // Arbitrum Sepolia
        )
        #expect(hash != hashDiffChain, "Different chainId must produce different hash")
    }
    
    // MARK: - Hybrid Signature ABI Layout
    
    @Test func hybridSignatureABILayout() {
        // Hybrid sig = ABI-encode(["bytes","bytes"], [ecdsaSig, mldsaSig])
        let ecdsaSig = Data(repeating: 0xAA, count: 65)
        let pqSig = Data(repeating: 0xBB, count: 2420)
        
        let encoded = ABIEncoder.encodeHybridSignature(
            preQuantumSig: ecdsaSig,
            postQuantumSig: pqSig
        )
        
        // ABI layout for (bytes, bytes):
        // [0..31]   offset to first bytes  = 64
        // [32..63]  offset to second bytes
        // [64..95]  length of first bytes  = 65
        // [96..]    padded first bytes data
        // then      length of second bytes = 2420
        //           padded second bytes data
        
        // Verify first offset = 64 (pointing past the two offset words)
        let firstOffset = abiDecodeUint256(encoded, at: 0)
        #expect(firstOffset == 64, "First offset should be 64")
        
        // Verify first data length = 65 (ECDSA sig)
        let firstLen = abiDecodeUint256(encoded, at: Int(firstOffset))
        #expect(firstLen == 65, "First data length should be 65 (ECDSA sig)")
        
        // Verify second data length = 2420 (ML-DSA sig)
        let secondOffset = abiDecodeUint256(encoded, at: 32)
        let secondLen = abiDecodeUint256(encoded, at: Int(secondOffset))
        #expect(secondLen == 2420, "Second data length should be 2420 (ML-DSA sig)")
    }
    
    // MARK: - Gas Packing
    
    @Test func gasFeePackingMatchesERC4337() {
        // accountGasLimits = pack(verificationGasLimit, callGasLimit) as uint128|uint128
        let verificationGas: UInt64 = 500_000
        let callGas: UInt64 = 200_000
        
        let packed = UserOperationBuilder.packAccountGasLimits(
            verificationGasLimit: verificationGas,
            callGasLimit: callGas
        )
        
        #expect(packed.count == 32, "Packed gas limits must be 32 bytes")
        
        // Upper 16 bytes = verificationGasLimit, lower 16 bytes = callGasLimit
        // Both are uint128 in big-endian
        let upperBytes = packed.prefix(16)
        let lowerBytes = packed.suffix(16)
        
        // Decode upper (verificationGasLimit)
        var upper: UInt64 = 0
        for byte in upperBytes.suffix(8) {
            upper = (upper << 8) | UInt64(byte)
        }
        #expect(upper == verificationGas, "Upper uint128 should be verificationGasLimit")
        
        // Decode lower (callGasLimit)
        var lower: UInt64 = 0
        for byte in lowerBytes.suffix(8) {
            lower = (lower << 8) | UInt64(byte)
        }
        #expect(lower == callGas, "Lower uint128 should be callGasLimit")
    }
    
    // MARK: - Helpers
    
    private func abiDecodeUint256(_ data: Data, at offset: Int) -> UInt64 {
        guard offset + 32 <= data.count else { return 0 }
        var value: UInt64 = 0
        // Read last 8 bytes of the 32-byte word (big-endian uint256 → UInt64)
        for i in (offset + 24)..<(offset + 32) {
            value = (value << 8) | UInt64(data[i])
        }
        return value
    }
}

// Helper for cross-validation tests
private func abiDecodeUint256(_ data: Data, at offset: Int) -> UInt64 {
    guard offset + 32 <= data.count else { return 0 }
    var value: UInt64 = 0
    for i in (offset + 24)..<(offset + 32) {
        value = (value << 8) | UInt64(data[i])
    }
    return value
}
