//
// StealthPQAccountTests.swift
// bitchatTests
//
// Tests for stealth PQ account derivation, CREATE2 prediction,
// balance verification, and ENS routing.
//
// This is free and unencumbered software released into the public domain.
// For more information, see <https://unlicense.org>
//

import Testing
import Foundation
@testable import bitchat

// MARK: - Stealth PQ Account Model Tests

@Suite("StealthPQAccount Model")
struct StealthPQAccountModelTests {
    
    @Test func balanceETHConversion() {
        let account = StealthPQAccount(
            index: 0,
            stealthSignerAddress: "0x1234567890abcdef1234567890abcdef12345678",
            pqAccountAddress: "0xabcdefabcdefabcdefabcdefabcdefabcdefabcd",
            isDeployed: false,
            balanceWei: "0x2386f26fc10000", // 0.01 ETH
            verificationLevelRaw: EthereumBalanceService.VerificationLevel.unverified.rawValue,
            ephemeralPubKey: Data(repeating: 0x02, count: 33)
        )
        
        let expectedETH = 0.01
        #expect(abs(account.balanceETH - expectedETH) < 0.0001,
                "0x2386f26fc10000 should be ~0.01 ETH, got \(account.balanceETH)")
    }
    
    @Test func isFundedWhenPositiveBalance() {
        let funded = StealthPQAccount(
            index: 0,
            stealthSignerAddress: "0x1111111111111111111111111111111111111111",
            pqAccountAddress: "0x2222222222222222222222222222222222222222",
            isDeployed: false,
            balanceWei: "0x38d7ea4c68000", // 0.001 ETH
            verificationLevelRaw: EthereumBalanceService.VerificationLevel.unverified.rawValue,
            ephemeralPubKey: Data(repeating: 0x02, count: 33)
        )
        #expect(funded.isFunded, "Account with 0.001 ETH should be funded")
        
        let empty = StealthPQAccount(
            index: 1,
            stealthSignerAddress: "0x1111111111111111111111111111111111111111",
            pqAccountAddress: "0x3333333333333333333333333333333333333333",
            isDeployed: false,
            balanceWei: "0x0",
            verificationLevelRaw: EthereumBalanceService.VerificationLevel.unverified.rawValue,
            ephemeralPubKey: Data(repeating: 0x02, count: 33)
        )
        #expect(!empty.isFunded, "Account with 0 balance should not be funded")
    }
    
    @Test func canSweepThreshold() {
        let minimumWei: UInt64 = 5_000_000_000_000_000 // 0.005 ETH
        
        let belowThreshold = StealthPQAccount(
            index: 0,
            stealthSignerAddress: "0x1111111111111111111111111111111111111111",
            pqAccountAddress: "0x2222222222222222222222222222222222222222",
            isDeployed: false,
            balanceWei: "0x38d7ea4c68000", // 0.001 ETH
            verificationLevelRaw: EthereumBalanceService.VerificationLevel.unverified.rawValue,
            ephemeralPubKey: Data(repeating: 0x02, count: 33)
        )
        #expect(!belowThreshold.canSweep(minimumWei: minimumWei),
                "0.001 ETH should be below sweep threshold of 0.005 ETH")
        
        let aboveThreshold = StealthPQAccount(
            index: 1,
            stealthSignerAddress: "0x1111111111111111111111111111111111111111",
            pqAccountAddress: "0x3333333333333333333333333333333333333333",
            isDeployed: false,
            balanceWei: "0x2386f26fc10000", // 0.01 ETH
            verificationLevelRaw: EthereumBalanceService.VerificationLevel.unverified.rawValue,
            ephemeralPubKey: Data(repeating: 0x02, count: 33)
        )
        #expect(aboveThreshold.canSweep(minimumWei: minimumWei),
                "0.01 ETH should be above sweep threshold of 0.005 ETH")
    }
    
    @Test func zeroBalanceFormatsCorrectly() {
        let account = StealthPQAccount(
            index: 0,
            stealthSignerAddress: "0x1111111111111111111111111111111111111111",
            pqAccountAddress: "0x2222222222222222222222222222222222222222",
            isDeployed: false,
            balanceWei: "0x0",
            verificationLevelRaw: EthereumBalanceService.VerificationLevel.pending.rawValue,
            ephemeralPubKey: Data(repeating: 0x02, count: 33)
        )
        #expect(account.balanceETH == 0.0, "Zero balance should convert to 0.0 ETH")
    }
}

// MARK: - ABIEncoder CREATE2 Tests

@Suite("ABIEncoder CREATE2")
struct ABIEncoderCREATE2Tests {
    
    @Test func keccak256HashesCorrectly() {
        // Test vector: keccak256("") = 0xc5d246...
        let emptyHash = ABIEncoder.keccak256(Data())
        let hex = emptyHash.map { String(format: "%02x", $0) }.joined()
        #expect(hex == "c5d2460186f7233c927e7db2dcc703c0e500b653ca82273b7bfad8045d85a470",
                "keccak256('') should produce known hash")
    }
    
    @Test func keccak256NonEmptyInput() {
        // keccak256("hello") = known value
        let hello = "hello".data(using: .utf8)!
        let hash = ABIEncoder.keccak256(hello)
        #expect(hash.count == 32, "keccak256 output should be 32 bytes")
        
        let hex = hash.map { String(format: "%02x", $0) }.joined()
        #expect(hex == "1c8aff950685c2ed4bc3174f3472287b56d9517b9c948127319a09a7a36deac8",
                "keccak256('hello') should match known hash")
    }
    
    @Test func predictCREATE2AddressFormat() {
        let deployer = "0xe28F039653772C32b0eDB1db7c7A5FA250DDA0e5"
        let salt = Data(repeating: 0x00, count: 32)
        let initCodeHash = Data(repeating: 0xAA, count: 32)
        
        let address = ABIEncoder.predictCREATE2Address(
            deployer: deployer,
            salt: salt,
            initCodeHash: initCodeHash
        )
        
        #expect(address.hasPrefix("0x"), "CREATE2 address should start with 0x")
        #expect(address.count == 42, "CREATE2 address should be 42 characters (0x + 40 hex)")
    }
    
    @Test func predictCREATE2AddressDeterministic() {
        let deployer = "0xe28F039653772C32b0eDB1db7c7A5FA250DDA0e5"
        let salt = Data(repeating: 0x01, count: 32)
        let initCodeHash = ABIEncoder.keccak256(Data("test creation code".utf8))
        
        let addr1 = ABIEncoder.predictCREATE2Address(deployer: deployer, salt: salt, initCodeHash: initCodeHash)
        let addr2 = ABIEncoder.predictCREATE2Address(deployer: deployer, salt: salt, initCodeHash: initCodeHash)
        
        #expect(addr1 == addr2, "CREATE2 with same inputs should produce same address")
    }
    
    @Test func predictCREATE2DifferentSaltsDifferentAddresses() {
        let deployer = "0xe28F039653772C32b0eDB1db7c7A5FA250DDA0e5"
        let initCodeHash = ABIEncoder.keccak256(Data("test creation code".utf8))
        let salt1 = Data(repeating: 0x01, count: 32)
        let salt2 = Data(repeating: 0x02, count: 32)
        
        let addr1 = ABIEncoder.predictCREATE2Address(deployer: deployer, salt: salt1, initCodeHash: initCodeHash)
        let addr2 = ABIEncoder.predictCREATE2Address(deployer: deployer, salt: salt2, initCodeHash: initCodeHash)
        
        #expect(addr1 != addr2, "CREATE2 with different salts should produce different addresses")
    }
}

// MARK: - PQAccountDeployer Local Prediction Tests

@Suite("PQAccountDeployer Local Prediction")
struct PQAccountDeployerLocalPredictionTests {
    
    @Test func predictAddressLocallyFormat() {
        let preQKey = Data(repeating: 0xAA, count: 20)
        let postQKey = Data(repeating: 0xBB, count: 100) // Simplified for test
        let creationCode = Data(repeating: 0xCC, count: 200) // Simplified for test
        
        let address = PQAccountDeployer.predictAddressLocally(
            preQuantumPubKey: preQKey,
            postQuantumPubKey: postQKey,
            accountCreationCode: creationCode
        )
        
        #expect(address.hasPrefix("0x"), "Predicted address should start with 0x")
        #expect(address.count == 42, "Predicted address should be 42 characters")
    }
    
    @Test func predictAddressLocallyDeterministic() {
        let preQKey = Data(repeating: 0x11, count: 20)
        let postQKey = Data(repeating: 0x22, count: 100)
        let creationCode = Data(repeating: 0x33, count: 200)
        
        let addr1 = PQAccountDeployer.predictAddressLocally(
            preQuantumPubKey: preQKey,
            postQuantumPubKey: postQKey,
            accountCreationCode: creationCode
        )
        let addr2 = PQAccountDeployer.predictAddressLocally(
            preQuantumPubKey: preQKey,
            postQuantumPubKey: postQKey,
            accountCreationCode: creationCode
        )
        
        #expect(addr1 == addr2, "Same inputs should give same predicted address")
    }
    
    @Test func differentKeysGiveDifferentAddresses() {
        let preQKey1 = Data(repeating: 0x11, count: 20)
        let preQKey2 = Data(repeating: 0x12, count: 20)
        let postQKey = Data(repeating: 0x22, count: 100)
        let creationCode = Data(repeating: 0x33, count: 200)
        
        let addr1 = PQAccountDeployer.predictAddressLocally(
            preQuantumPubKey: preQKey1,
            postQuantumPubKey: postQKey,
            accountCreationCode: creationCode
        )
        let addr2 = PQAccountDeployer.predictAddressLocally(
            preQuantumPubKey: preQKey2,
            postQuantumPubKey: postQKey,
            accountCreationCode: creationCode
        )
        
        #expect(addr1 != addr2, "Different preQuantum keys should give different addresses")
    }
}

// MARK: - ENS Resolver pq.dstealth.eth Routing Tests

@Suite("ENS Resolver PQ Routing")
struct ENSResolverPQRoutingTests {
    
    @Test func canResolveRecognizesPQDstealth() async {
        let resolver = ENSResolver.shared
        let canResolve = await resolver.canResolve("alice.pq.dstealth.eth")
        #expect(canResolve, "ENSResolver should recognize .pq.dstealth.eth")
    }
    
    @Test func canResolveStillWorksDstealth() async {
        let resolver = ENSResolver.shared
        let canResolve = await resolver.canResolve("alice.dstealth.eth")
        #expect(canResolve, "ENSResolver should still recognize .dstealth.eth")
    }
    
    @Test func canResolveRejectsUnknown() async {
        let resolver = ENSResolver.shared
        let canResolve = await resolver.canResolve("alice.unknown.com")
        #expect(!canResolve, "ENSResolver should reject unknown domains")
    }
    
    @Test func looksLikeENSNameAcceptsPQDstealth() {
        let result = ENSResolver.looksLikeENSName("alice.pq.dstealth.eth")
        #expect(result, "alice.pq.dstealth.eth should look like an ENS name")
    }
}

// MARK: - Stealth PQ Account Manager Integration Tests

@Suite("StealthPQAccountManager Integration")
struct StealthPQAccountManagerIntegrationTests {
    
    @Test func managerCreatesWithoutCrash() async throws {
        let keychain = MockKeychain()
        let wallet = EmbeddedWallet(keychain: keychain)
        let stealthManager = StealthAddressManager(wallet: wallet)
        let pqKeyManager = PQKeyManager(keychain: keychain)
        let deployer = PQAccountDeployer(chain: .arbitrumSepolia)
        let balanceService = await EthereumBalanceService()
        
        let manager = StealthPQAccountManager(
            wallet: wallet,
            stealthAddressManager: stealthManager,
            pqKeyManager: pqKeyManager,
            deployer: deployer,
            balanceService: balanceService
        )
        
        // Verify we can read the current index
        let index = await manager.currentDerivationIndex
        #expect(index == 0, "Initial index should be 0")
    }
    
    @Test func advanceIndexIncrementsCorrectly() async throws {
        let keychain = MockKeychain()
        let wallet = EmbeddedWallet(keychain: keychain)
        let stealthManager = StealthAddressManager(wallet: wallet)
        let pqKeyManager = PQKeyManager(keychain: keychain)
        let deployer = PQAccountDeployer(chain: .arbitrumSepolia)
        let balanceService = await EthereumBalanceService()
        
        let manager = StealthPQAccountManager(
            wallet: wallet,
            stealthAddressManager: stealthManager,
            pqKeyManager: pqKeyManager,
            deployer: deployer,
            balanceService: balanceService
        )
        
        let idx1 = await manager.advanceIndex()
        #expect(idx1 == 1)
        
        let idx2 = await manager.advanceIndex()
        #expect(idx2 == 2)
        
        let current = await manager.currentDerivationIndex
        #expect(current == 2)
    }
    
    @Test func deriveStealthSignerProducesValidAddress() async throws {
        let keychain = MockKeychain()
        let wallet = EmbeddedWallet(keychain: keychain)
        let stealthManager = StealthAddressManager(wallet: wallet)
        let pqKeyManager = PQKeyManager(keychain: keychain)
        let deployer = PQAccountDeployer(chain: .arbitrumSepolia)
        let balanceService = await EthereumBalanceService()
        
        let manager = StealthPQAccountManager(
            wallet: wallet,
            stealthAddressManager: stealthManager,
            pqKeyManager: pqKeyManager,
            deployer: deployer,
            balanceService: balanceService
        )
        
        let result = try await manager.deriveStealthSigner(at: 0)
        
        #expect(result.stealthAddress.hasPrefix("0x"),
                "Stealth address should be 0x-prefixed")
        #expect(result.stealthAddress.count == 42,
                "Stealth address should be 42 chars")
        #expect(result.ephemeralPubKey.count == 33,
                "Compressed ephemeral pubkey should be 33 bytes")
    }
    
    @Test func differentIndicesProduceDifferentStealthAddresses() async throws {
        let keychain = MockKeychain()
        let wallet = EmbeddedWallet(keychain: keychain)
        let stealthManager = StealthAddressManager(wallet: wallet)
        let pqKeyManager = PQKeyManager(keychain: keychain)
        let deployer = PQAccountDeployer(chain: .arbitrumSepolia)
        let balanceService = await EthereumBalanceService()
        
        let manager = StealthPQAccountManager(
            wallet: wallet,
            stealthAddressManager: stealthManager,
            pqKeyManager: pqKeyManager,
            deployer: deployer,
            balanceService: balanceService
        )
        
        let result0 = try await manager.deriveStealthSigner(at: 0)
        let result1 = try await manager.deriveStealthSigner(at: 1)
        let result2 = try await manager.deriveStealthSigner(at: 2)
        
        #expect(result0.stealthAddress != result1.stealthAddress,
                "Different indices should produce different stealth addresses")
        #expect(result1.stealthAddress != result2.stealthAddress,
                "Different indices should produce different stealth addresses")
        #expect(result0.stealthAddress != result2.stealthAddress,
                "Different indices should produce different stealth addresses")
    }
    
    @Test func sameIndexProducesSameStealthAddress() async throws {
        let keychain = MockKeychain()
        let wallet = EmbeddedWallet(keychain: keychain)
        let stealthManager = StealthAddressManager(wallet: wallet)
        let pqKeyManager = PQKeyManager(keychain: keychain)
        let deployer = PQAccountDeployer(chain: .arbitrumSepolia)
        let balanceService = await EthereumBalanceService()
        
        let manager = StealthPQAccountManager(
            wallet: wallet,
            stealthAddressManager: stealthManager,
            pqKeyManager: pqKeyManager,
            deployer: deployer,
            balanceService: balanceService
        )
        
        let result1 = try await manager.deriveStealthSigner(at: 5)
        let result2 = try await manager.deriveStealthSigner(at: 5)
        
        #expect(result1.stealthAddress == result2.stealthAddress,
                "Same index should always derive the same stealth address (deterministic)")
    }
    
    @Test func allAccountsStartsEmpty() async throws {
        let keychain = MockKeychain()
        let wallet = EmbeddedWallet(keychain: keychain)
        let stealthManager = StealthAddressManager(wallet: wallet)
        let pqKeyManager = PQKeyManager(keychain: keychain)
        let deployer = PQAccountDeployer(chain: .arbitrumSepolia)
        let balanceService = await EthereumBalanceService()
        
        let manager = StealthPQAccountManager(
            wallet: wallet,
            stealthAddressManager: stealthManager,
            pqKeyManager: pqKeyManager,
            deployer: deployer,
            balanceService: balanceService
        )
        
        let all = await manager.allAccounts
        #expect(all.isEmpty, "Accounts should start empty before any scan")
    }
}

// MARK: - UserOperationBuilder Stealth Signing Tests

@Suite("UserOperationBuilder Stealth Signing")
struct UserOperationBuilderStealthSigningTests {
    
    @Test func signHybridWithStealthKeyProducesValidSignature() async throws {
        let keychain = MockKeychain()
        let wallet = EmbeddedWallet(keychain: keychain)
        let pqKeyManager = PQKeyManager(keychain: keychain)
        
        // Initialize PQ keys
        let _ = try await pqKeyManager.getOrCreateKeys(from: wallet)
        
        // Create a fake 32-byte stealth private key
        let stealthKey = Data(repeating: 0x42, count: 32)
        
        // Create a fake 32-byte UserOp hash
        let userOpHash = Data(repeating: 0xAB, count: 32)
        
        let signature = try await UserOperationBuilder.signHybridWithStealthKey(
            userOpHash: userOpHash,
            stealthPrivateKey: stealthKey,
            pqKeyManager: pqKeyManager
        )
        
        // Hybrid signature = ABI-encoded(ECDSA 65 bytes, ML-DSA-44 2420 bytes)
        // The ABI encoding adds headers + padding, so it's larger
        #expect(signature.count > 2420 + 65,
                "Hybrid signature should contain both ECDSA and ML-DSA-44 components")
    }
}
