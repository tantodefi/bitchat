//
// ProofVerifierTests.swift
// bitchatTests
//
// Tests for Phase 1 Helios integration: RLP decoding, Merkle-Patricia trie
// proof verification, and eth_getProof response validation.
//
// This is free and unencumbered software released into the public domain.
// For more information, see <https://unlicense.org>
//

import Testing
import Foundation
@testable import bitchat

// MARK: - RLP Decoder Tests

@Suite("RLP Decoder")
struct RLPDecoderTests {
    
    // MARK: - Single Byte
    
    @Test func rlp_decodeSingleByte() throws {
        // 0x41 = "A" (single byte, no prefix needed)
        let data = Data([0x41])
        let item = try RLP.decode(data)
        #expect(item.asData == Data([0x41]))
    }
    
    @Test func rlp_decodeZeroByte() throws {
        // 0x00 is a single byte value
        let data = Data([0x00])
        let item = try RLP.decode(data)
        #expect(item.asData == Data([0x00]))
    }
    
    @Test func rlp_decode0x7f() throws {
        // 0x7F is the max single-byte value
        let data = Data([0x7F])
        let item = try RLP.decode(data)
        #expect(item.asData == Data([0x7F]))
    }
    
    // MARK: - Short String
    
    @Test func rlp_decodeEmptyString() throws {
        // 0x80 = empty string
        let data = Data([0x80])
        let item = try RLP.decode(data)
        #expect(item.asData == Data())
    }
    
    @Test func rlp_decodeShortString() throws {
        // "dog" = [0x83, 0x64, 0x6F, 0x67]
        let data = Data([0x83, 0x64, 0x6F, 0x67])
        let item = try RLP.decode(data)
        #expect(item.asData == Data([0x64, 0x6F, 0x67]))
    }
    
    @Test func rlp_decode55ByteString() throws {
        // 55-byte string: 0x80 + 55 = 0xB7 prefix, then 55 bytes
        let payload = Data(repeating: 0xAB, count: 55)
        let encoded = Data([0xB7]) + payload
        let item = try RLP.decode(encoded)
        #expect(item.asData == payload)
    }
    
    // MARK: - Long String
    
    @Test func rlp_decodeLongString() throws {
        // 56-byte string: 0xB8 prefix, 1-byte length (56), then 56 bytes
        let payload = Data(repeating: 0xCD, count: 56)
        let encoded = Data([0xB8, 0x38]) + payload
        let item = try RLP.decode(encoded)
        #expect(item.asData == payload)
    }
    
    @Test func rlp_decode256ByteString() throws {
        // 256-byte string: 0xB9 prefix, 2-byte length (0x0100), then 256 bytes
        let payload = Data(repeating: 0xEF, count: 256)
        let encoded = Data([0xB9, 0x01, 0x00]) + payload
        let item = try RLP.decode(encoded)
        #expect(item.asData?.count == 256)
    }
    
    // MARK: - Empty List
    
    @Test func rlp_decodeEmptyList() throws {
        // 0xC0 = empty list
        let data = Data([0xC0])
        let item = try RLP.decode(data)
        #expect(item.asList?.count == 0)
    }
    
    // MARK: - Short List
    
    @Test func rlp_decodeListOfStrings() throws {
        // ["cat", "dog"]
        // cat = 0x83, 0x63, 0x61, 0x74
        // dog = 0x83, 0x64, 0x6F, 0x67
        // total payload = 8 bytes, so prefix = 0xC8
        let data = Data([0xC8, 0x83, 0x63, 0x61, 0x74, 0x83, 0x64, 0x6F, 0x67])
        let item = try RLP.decode(data)
        let list = item.asList
        #expect(list?.count == 2)
        #expect(list?[0].asData == Data([0x63, 0x61, 0x74])) // "cat"
        #expect(list?[1].asData == Data([0x64, 0x6F, 0x67])) // "dog"
    }
    
    @Test func rlp_decodeNestedList() throws {
        // [[], [[]]]
        // [] = 0xC0
        // [[]] = 0xC1, 0xC0
        // [[], [[]]] = 0xC3, 0xC0, 0xC1, 0xC0
        let data = Data([0xC3, 0xC0, 0xC1, 0xC0])
        let item = try RLP.decode(data)
        let list = item.asList
        #expect(list?.count == 2)
        #expect(list?[0].asList?.count == 0)
        #expect(list?[1].asList?.count == 1)
    }
    
    // MARK: - Account RLP (nonce, balance, storageRoot, codeHash)
    
    @Test func rlp_decodeAccountData() throws {
        // An Ethereum account: [nonce=0, balance=0, storageRoot=emptyTrieRoot, codeHash=emptyKeccak]
        // nonce=0: 0x80 (empty bytes = 0)
        // balance=0: 0x80
        // storageRoot: 32 bytes (0xa0 prefix + 32 bytes)
        // codeHash: 32 bytes (0xa0 prefix + 32 bytes)
        let emptyStorageRoot = Data(Array<UInt8>(hex: "56e81f171bcc55a6ff8345e692c0f86e5b48e01b996cadc001622fb5e363b421"))
        let emptyCodeHash = Data(Array<UInt8>(hex: "c5d2460186f7233c927e7db2dcc703c0e500b653ca82273b7bfad8045d85a470"))
        
        // Build the RLP manually
        let nonceRLP = RLP.encode(Data())  // 0 = empty bytes
        let balanceRLP = RLP.encode(Data()) // 0
        let storageRootRLP = RLP.encode(emptyStorageRoot)
        let codeHashRLP = RLP.encode(emptyCodeHash)
        
        let accountRLP = RLP.encodeList([nonceRLP, balanceRLP, storageRootRLP, codeHashRLP])
        
        let item = try RLP.decode(accountRLP)
        let list = item.asList
        #expect(list?.count == 4)
        #expect(list?[0].asUInt64 == 0)
        #expect(list?[1].asBigUInt?.isZero == true)
        #expect(list?[2].asData == emptyStorageRoot)
        #expect(list?[3].asData == emptyCodeHash)
    }
    
    // MARK: - BigUInt from RLP
    
    @Test func rlp_bigUIntFromBytes() throws {
        // 1 ETH = 10^18 = 0x0DE0B6B3A7640000
        let balanceBytes = Data([0x0D, 0xE0, 0xB6, 0xB3, 0xA7, 0x64, 0x00, 0x00])
        let encoded = RLP.encode(balanceBytes)
        let item = try RLP.decode(encoded)
        let balance = item.asBigUInt
        #expect(balance != nil)
        #expect(balance!.description == "1000000000000000000")
    }
    
    // MARK: - Round-trip
    
    @Test func rlp_encodeDecodeRoundTrip() throws {
        let data = Data([0x01, 0x02, 0x03, 0x04, 0x05])
        let encoded = RLP.encode(data)
        let decoded = try RLP.decode(encoded)
        #expect(decoded.asData == data)
    }
}

// MARK: - Hex-Prefix Encoding Tests

@Suite("Hex-Prefix Encoding")
struct HexPrefixTests {
    
    @Test func hexPrefix_evenExtension() {
        // Even extension: first nibble = 0x00
        let data = Data([0x00, 0x01, 0x23])
        let decoded = HexPrefix.decode(data)
        #expect(!decoded.isLeaf)
        #expect(decoded.nibbles == [0x0, 0x1, 0x2, 0x3])
    }
    
    @Test func hexPrefix_oddExtension() {
        // Odd extension: first nibble = 0x1X where X is first path nibble
        let data = Data([0x11, 0x23])
        let decoded = HexPrefix.decode(data)
        #expect(!decoded.isLeaf)
        #expect(decoded.nibbles == [0x1, 0x2, 0x3])
    }
    
    @Test func hexPrefix_evenLeaf() {
        // Even leaf: first nibble = 0x20
        let data = Data([0x20, 0x01, 0x23])
        let decoded = HexPrefix.decode(data)
        #expect(decoded.isLeaf)
        #expect(decoded.nibbles == [0x0, 0x1, 0x2, 0x3])
    }
    
    @Test func hexPrefix_oddLeaf() {
        // Odd leaf: first nibble = 0x3X
        let data = Data([0x3A, 0xBC])
        let decoded = HexPrefix.decode(data)
        #expect(decoded.isLeaf)
        #expect(decoded.nibbles == [0xA, 0xB, 0xC])
    }
    
    @Test func hexPrefix_emptyPath() {
        let data = Data([0x00])
        let decoded = HexPrefix.decode(data)
        #expect(!decoded.isLeaf)
        #expect(decoded.nibbles.isEmpty)
    }
}

// MARK: - Data Extension Tests

@Suite("Data Hex Extension")
struct DataHexTests {
    
    @Test func data_hexString() {
        let data = Data([0xDE, 0xAD, 0xBE, 0xEF])
        #expect(data.hex == "deadbeef")
    }
    
    @Test func data_initFromHexString() {
        let data = Data(hexString: "0xdeadbeef")
        #expect(data != nil)
        #expect(data == Data([0xDE, 0xAD, 0xBE, 0xEF]))
    }
    
    @Test func data_initFromHexStringNoPrefix() {
        let data = Data(hexString: "cafebabe")
        #expect(data != nil)
        #expect(data?.count == 4)
    }
    
    @Test func data_initFromInvalidHexReturnsNil() {
        #expect(Data(hexString: "0xZZZZ") == nil)
        #expect(Data(hexString: "0x123") == nil) // Odd length
    }
}

// MARK: - Merkle-Patricia Proof Tests

@Suite("Merkle-Patricia Proof Verification")
struct MerklePatriciaProofTests {
    
    @Test func proofVerification_emptyProofThrows() throws {
        do {
            let _ = try MerklePatriciaProof.verifyAccountProof(
                proof: [],
                address: "0x0000000000000000000000000000000000000001",
                stateRoot: Data(count: 32)
            )
            #expect(Bool(false), "Should have thrown")
        } catch let error as ProofVerificationError {
            if case .emptyProof = error {
                // Expected
            } else {
                #expect(Bool(false), "Wrong error type: \(error)")
            }
        }
    }
    
    @Test func proofVerification_hashMismatchThrows() throws {
        // A proof node that doesn't hash to the state root
        let fakeNode = Data(repeating: 0xFF, count: 64)
        let fakeStateRoot = Data(repeating: 0x00, count: 32)
        
        do {
            let _ = try MerklePatriciaProof.verifyAccountProof(
                proof: [fakeNode],
                address: "0x0000000000000000000000000000000000000001",
                stateRoot: fakeStateRoot
            )
            #expect(Bool(false), "Should have thrown")
        } catch let error as ProofVerificationError {
            if case .hashMismatch = error {
                // Expected — the node doesn't hash to the state root
            } else {
                // RLP decoding or other errors are also acceptable here
                // since the node data is garbage
            }
        }
    }
    
    /// Build a minimal valid proof (single leaf node) and verify it.
    @Test func proofVerification_singleLeafNode() throws {
        // For a trie with a single account, the proof is just one leaf node.
        // The leaf contains: [hex-prefix-encoded-path, rlp-encoded-account]
        
        let address = "0x0000000000000000000000000000000000000001"
        let addressBytes = Array<UInt8>(hex: "0000000000000000000000000000000000000001")
        let keyHash = Data(addressBytes.sha3(.keccak256))
        let keyNibbles = keyHash.flatMap { [($0 >> 4), ($0 & 0x0F)] }
        
        // Build hex-prefix path for a leaf with the full key
        // Leaf + even nibbles: prefix = 0x20
        var pathBytes = Data([0x20])
        for i in stride(from: 0, to: keyNibbles.count, by: 2) {
            pathBytes.append((keyNibbles[i] << 4) | keyNibbles[i + 1])
        }
        
        // Build account RLP: [nonce=1, balance=1000, storageRoot, codeHash]
        let emptyStorageRoot = Data(Array<UInt8>(hex: "56e81f171bcc55a6ff8345e692c0f86e5b48e01b996cadc001622fb5e363b421"))
        let emptyCodeHash = Data(Array<UInt8>(hex: "c5d2460186f7233c927e7db2dcc703c0e500b653ca82273b7bfad8045d85a470"))
        
        let nonceRLP = RLP.encode(Data([0x01]))   // nonce = 1
        let balanceRLP = RLP.encode(Data([0x03, 0xE8]))  // balance = 1000
        let storageRLP = RLP.encode(emptyStorageRoot)
        let codeHashRLP = RLP.encode(emptyCodeHash)
        let accountRLP = RLP.encodeList([nonceRLP, balanceRLP, storageRLP, codeHashRLP])
        
        // Build leaf node: [path, accountRLP]
        let pathEncoded = RLP.encode(pathBytes)
        let valueEncoded = RLP.encode(accountRLP)
        let leafNode = RLP.encodeList([pathEncoded, valueEncoded])
        
        // State root = keccak256(leafNode)
        let stateRoot = Data(Array(leafNode).sha3(.keccak256))
        
        // Verify
        let account = try MerklePatriciaProof.verifyAccountProof(
            proof: [leafNode],
            address: address,
            stateRoot: stateRoot
        )
        
        #expect(account.nonce == 1)
        #expect(account.balance.description == "1000")
        #expect(account.storageRoot == emptyStorageRoot)
        #expect(account.codeHash == emptyCodeHash)
        #expect(account.isEOA)
    }
    
    // MARK: - EthGetProofResponse Parsing
    
    @Test func ethGetProofResponse_parse() throws {
        let json: [String: Any] = [
            "address": "0x1234567890abcdef1234567890abcdef12345678",
            "accountProof": ["0xf8518080808080a0deadbeef"],
            "balance": "0x3e8",
            "codeHash": "0xc5d2460186f7233c927e7db2dcc703c0e500b653ca82273b7bfad8045d85a470",
            "nonce": "0x1",
            "storageHash": "0x56e81f171bcc55a6ff8345e692c0f86e5b48e01b996cadc001622fb5e363b421",
            "storageProof": [] as [[String: Any]]
        ]
        
        let response = try EthGetProofResponse.parse(from: json)
        #expect(response.address == "0x1234567890abcdef1234567890abcdef12345678")
        #expect(response.balance == "0x3e8")
        #expect(response.nonce == "0x1")
        #expect(response.accountProof.count == 1)
        #expect(response.storageProof.isEmpty)
    }
    
    @Test func ethGetProofResponse_parseMissingFieldsThrows() {
        let json: [String: Any] = [
            "address": "0x1234",
            // Missing accountProof
        ]
        
        do {
            let _ = try EthGetProofResponse.parse(from: json)
            #expect(Bool(false), "Should have thrown")
        } catch {
            // Expected
        }
    }
}

// MARK: - Verified Account Tests

@Suite("VerifiedAccount")
struct VerifiedAccountTests {
    
    @Test func verifiedAccount_isEOA() {
        let emptyCodeHash = Data(Array<UInt8>(hex: "c5d2460186f7233c927e7db2dcc703c0e500b653ca82273b7bfad8045d85a470"))
        let account = VerifiedAccount(
            nonce: 0,
            balance: BigUInt(0),
            storageRoot: Data(count: 32),
            codeHash: emptyCodeHash
        )
        #expect(account.isEOA)
    }
    
    @Test func verifiedAccount_isContract() {
        let contractCodeHash = Data(repeating: 0xAB, count: 32)
        let account = VerifiedAccount(
            nonce: 1,
            balance: BigUInt(1000),
            storageRoot: Data(count: 32),
            codeHash: contractCodeHash
        )
        #expect(!account.isEOA)
    }
}

// MARK: - Balance Service Proof Integration Tests

@Suite("Balance Service Proof Integration")
struct BalanceServiceProofTests {
    
    @MainActor
    @Test func balanceService_proofVerificationEnabledByDefault() {
        let service = EthereumBalanceService()
        #expect(service.proofVerificationEnabled)
    }
    
    @MainActor
    @Test func balanceService_proofStatsInitiallyZero() {
        let service = EthereumBalanceService()
        #expect(service.proofStats.totalQueries == 0)
        #expect(service.proofStats.proofVerified == 0)
        #expect(service.proofStats.proofFailed == 0)
        #expect(service.proofStats.fallbackUsed == 0)
        #expect(service.proofStats.mismatchDetected == 0)
        #expect(service.proofStats.verificationRate == 0)
    }
    
    @MainActor
    @Test func balance_isProofVerifiedDefault() {
        let balance = EthereumBalanceService.Balance(
            network: .sepolia,
            wei: BigUInt(1000),
            lastUpdated: Date()
        )
        #expect(!balance.isProofVerified)
    }
    
    @MainActor
    @Test func balance_isProofVerifiedWhenSet() {
        let balance = EthereumBalanceService.Balance(
            network: .sepolia,
            wei: BigUInt(1000),
            lastUpdated: Date(),
            isProofVerified: true
        )
        #expect(balance.isProofVerified)
    }
}
