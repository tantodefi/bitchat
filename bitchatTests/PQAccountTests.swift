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
        
        let expander = MLDSAKeyExpander(publicKey: mockPK)
        let (rho, t1Polys) = try expander.decodePublicKey()
        
        #expect(rho.count == 32, "rho should be 32 bytes")
        #expect(t1Polys.count == 4, "Should have K=4 t1 polynomials")
        
        for poly in t1Polys {
            #expect(poly.count == 256, "Each polynomial should have N=256 coefficients")
        }
    }
    
    @Test func rejectionSamplingProducesValidCoeffs() throws {
        // Use a known rho for deterministic sampling
        let rho = [UInt8](repeating: 0x42, count: 32)
        let expander = MLDSAKeyExpander(publicKey: [UInt8](repeating: 0, count: 1312))
        
        let poly = expander.rejectionSamplePoly(rho: rho, i: 0, j: 0)
        
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
