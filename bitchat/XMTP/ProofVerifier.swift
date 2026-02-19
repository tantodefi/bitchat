//
// ProofVerifier.swift
// bitchat
//
// Phase 1 of the Helios integration plan: Swift-native proof verification
// using eth_getProof Merkle-Patricia trie proofs.
//
// Verifies that an account's balance (nonce, codeHash, storageRoot) is
// correctly committed to in the Ethereum state trie, using the state root
// from the block header. This catches RPC providers returning wrong balances
// even without a full consensus light-client (Helios Phase 2+).
//
// References:
//   - EIP-1186: eth_getProof
//   - Ethereum Yellow Paper §4.1 (World State Trie)
//   - https://ethereum.org/en/developers/docs/data-structures-and-encoding/patricia-merkle-trie/
//
// This is free and unencumbered software released into the public domain.
// For more information, see <https://unlicense.org>
//

import BitLogger
import CryptoSwift
import Foundation

// MARK: - Verified Account Data

/// The account fields proven by an eth_getProof Merkle proof.
struct VerifiedAccount: Equatable {
    let nonce: UInt64
    let balance: BigUInt
    let storageRoot: Data  // 32 bytes
    let codeHash: Data     // 32 bytes
    
    /// Whether this is an EOA (no code deployed)
    var isEOA: Bool {
        // keccak256 of empty bytes
        codeHash == Data(Array<UInt8>(hex: "c5d2460186f7233c927e7db2dcc703c0e500b653ca82273b7bfad8045d85a470"))
    }
}

// MARK: - Proof Verification Errors

enum ProofVerificationError: Error, CustomStringConvertible {
    case invalidProof(String)
    case rlpDecodingFailed(String)
    case hashMismatch(expected: String, got: String)
    case invalidTrieNode(String)
    case accountDecodingFailed(String)
    case emptyProof
    case keyNotFound
    
    var description: String {
        switch self {
        case .invalidProof(let msg): return "Invalid proof: \(msg)"
        case .rlpDecodingFailed(let msg): return "RLP decoding failed: \(msg)"
        case .hashMismatch(let expected, let got): return "Hash mismatch: expected \(expected), got \(got)"
        case .invalidTrieNode(let msg): return "Invalid trie node: \(msg)"
        case .accountDecodingFailed(let msg): return "Account decoding failed: \(msg)"
        case .emptyProof: return "Empty proof"
        case .keyNotFound: return "Key not found in trie"
        }
    }
}

// MARK: - RLP Decoder

/// Minimal Recursive Length Prefix (RLP) decoder for Ethereum trie nodes.
/// Spec: https://ethereum.org/en/developers/docs/data-structures-and-encoding/rlp/
enum RLP {
    /// Decoded RLP item: either raw bytes or a list of items
    indirect enum Item {
        case bytes(Data)
        case list([Item])
        
        /// Extract raw bytes, or nil if this is a list
        var asData: Data? {
            if case .bytes(let d) = self { return d }
            return nil
        }
        
        /// Extract list items, or nil if this is bytes
        var asList: [Item]? {
            if case .list(let items) = self { return items }
            return nil
        }
        
        /// Extract as UInt64 (big-endian)
        var asUInt64: UInt64? {
            guard let data = asData else { return nil }
            if data.isEmpty { return 0 }
            guard data.count <= 8 else { return nil }
            var value: UInt64 = 0
            for byte in data {
                value = (value << 8) | UInt64(byte)
            }
            return value
        }
        
        /// Extract as BigUInt
        var asBigUInt: BigUInt? {
            guard let data = asData else { return nil }
            if data.isEmpty { return BigUInt(0) }
            let hex = data.map { String(format: "%02x", $0) }.joined()
            return BigUInt(hexString: hex)
        }
    }
    
    /// Decode an RLP-encoded byte sequence into an Item.
    static func decode(_ data: Data) throws -> Item {
        let (item, consumed) = try decodeItem(data, offset: 0)
        guard consumed == data.count else {
            throw ProofVerificationError.rlpDecodingFailed(
                "Trailing bytes: consumed \(consumed) of \(data.count)"
            )
        }
        return item
    }
    
    /// Decode one RLP item starting at `offset`. Returns (item, bytesConsumed).
    private static func decodeItem(_ data: Data, offset: Int) throws -> (Item, Int) {
        guard offset < data.count else {
            throw ProofVerificationError.rlpDecodingFailed("Unexpected end of data at offset \(offset)")
        }
        
        let prefix = data[offset]
        
        if prefix <= 0x7F {
            // Single byte [0x00, 0x7F]
            return (.bytes(Data([prefix])), 1)
        } else if prefix <= 0xB7 {
            // Short string [0x80, 0xB7]: length = prefix - 0x80
            let length = Int(prefix - 0x80)
            if length == 0 {
                return (.bytes(Data()), 1)
            }
            guard offset + 1 + length <= data.count else {
                throw ProofVerificationError.rlpDecodingFailed("Short string overflow")
            }
            let payload = data[(offset + 1)..<(offset + 1 + length)]
            return (.bytes(Data(payload)), 1 + length)
        } else if prefix <= 0xBF {
            // Long string [0xB8, 0xBF]: next (prefix - 0xB7) bytes are the length
            let lengthOfLength = Int(prefix - 0xB7)
            guard offset + 1 + lengthOfLength <= data.count else {
                throw ProofVerificationError.rlpDecodingFailed("Long string length overflow")
            }
            let lengthData = data[(offset + 1)..<(offset + 1 + lengthOfLength)]
            let length = lengthData.reduce(0) { ($0 << 8) | Int($1) }
            guard length > 55 else {
                throw ProofVerificationError.rlpDecodingFailed("Long string with short length")
            }
            guard offset + 1 + lengthOfLength + length <= data.count else {
                throw ProofVerificationError.rlpDecodingFailed("Long string payload overflow")
            }
            let payload = data[(offset + 1 + lengthOfLength)..<(offset + 1 + lengthOfLength + length)]
            return (.bytes(Data(payload)), 1 + lengthOfLength + length)
        } else if prefix <= 0xF7 {
            // Short list [0xC0, 0xF7]: length = prefix - 0xC0
            let length = Int(prefix - 0xC0)
            if length == 0 {
                return (.list([]), 1)
            }
            guard offset + 1 + length <= data.count else {
                throw ProofVerificationError.rlpDecodingFailed("Short list overflow")
            }
            let listData = data[(offset + 1)..<(offset + 1 + length)]
            let items = try decodeList(Data(listData))
            return (.list(items), 1 + length)
        } else {
            // Long list [0xF8, 0xFF]: next (prefix - 0xF7) bytes are the length
            let lengthOfLength = Int(prefix - 0xF7)
            guard offset + 1 + lengthOfLength <= data.count else {
                throw ProofVerificationError.rlpDecodingFailed("Long list length overflow")
            }
            let lengthData = data[(offset + 1)..<(offset + 1 + lengthOfLength)]
            let length = lengthData.reduce(0) { ($0 << 8) | Int($1) }
            guard length > 55 else {
                throw ProofVerificationError.rlpDecodingFailed("Long list with short length")
            }
            guard offset + 1 + lengthOfLength + length <= data.count else {
                throw ProofVerificationError.rlpDecodingFailed("Long list payload overflow")
            }
            let listData = data[(offset + 1 + lengthOfLength)..<(offset + 1 + lengthOfLength + length)]
            let items = try decodeList(Data(listData))
            return (.list(items), 1 + lengthOfLength + length)
        }
    }
    
    /// Decode a sequence of concatenated RLP items (the payload of a list).
    private static func decodeList(_ data: Data) throws -> [Item] {
        var items: [Item] = []
        var offset = 0
        while offset < data.count {
            let (item, consumed) = try decodeItem(data, offset: offset)
            items.append(item)
            offset += consumed
        }
        return items
    }
    
    /// Encode raw bytes as RLP
    static func encode(_ data: Data) -> Data {
        if data.count == 1 && data[0] <= 0x7F {
            return data
        } else if data.count <= 55 {
            return Data([UInt8(0x80 + data.count)]) + data
        } else {
            let lengthBytes = encodeLength(data.count)
            return Data([UInt8(0xB7 + lengthBytes.count)]) + lengthBytes + data
        }
    }
    
    /// Encode a list of already-RLP-encoded items
    static func encodeList(_ items: [Data]) -> Data {
        let payload = items.reduce(Data()) { $0 + $1 }
        if payload.count <= 55 {
            return Data([UInt8(0xC0 + payload.count)]) + payload
        } else {
            let lengthBytes = encodeLength(payload.count)
            return Data([UInt8(0xF7 + lengthBytes.count)]) + lengthBytes + payload
        }
    }
    
    private static func encodeLength(_ length: Int) -> Data {
        if length < 256 {
            return Data([UInt8(length)])
        } else if length < 65536 {
            return Data([UInt8(length >> 8), UInt8(length & 0xFF)])
        } else if length < 16_777_216 {
            return Data([UInt8(length >> 16), UInt8((length >> 8) & 0xFF), UInt8(length & 0xFF)])
        } else {
            return Data([UInt8(length >> 24), UInt8((length >> 16) & 0xFF), UInt8((length >> 8) & 0xFF), UInt8(length & 0xFF)])
        }
    }
}

// MARK: - Hex-Prefix (Compact) Encoding

/// Ethereum's hex-prefix encoding for trie node paths.
/// Spec: https://ethereum.org/en/developers/docs/data-structures-and-encoding/patricia-merkle-trie/#specification
enum HexPrefix {
    struct Decoded {
        let nibbles: [UInt8]  // path nibbles (0-15)
        let isLeaf: Bool
    }
    
    /// Decode a hex-prefix (compact) encoded path.
    /// First nibble flags: 0 = extension/even, 1 = extension/odd, 2 = leaf/even, 3 = leaf/odd
    static func decode(_ data: Data) -> Decoded {
        guard !data.isEmpty else {
            return Decoded(nibbles: [], isLeaf: false)
        }
        
        let firstByte = data[0]
        let highNibble = firstByte >> 4
        let lowNibble = firstByte & 0x0F
        
        let isLeaf = highNibble >= 2
        let isOdd = highNibble & 1 == 1
        
        var nibbles: [UInt8] = []
        
        if isOdd {
            // Odd: first nibble is the low nibble of first byte
            nibbles.append(lowNibble)
        }
        // Even: first byte is just flags, skip it
        
        // Remaining bytes: split into nibbles
        for byte in data.dropFirst() {
            nibbles.append(byte >> 4)
            nibbles.append(byte & 0x0F)
        }
        
        return Decoded(nibbles: nibbles, isLeaf: isLeaf)
    }
}

// MARK: - Merkle-Patricia Trie Proof Verifier

/// Verifies Merkle-Patricia trie proofs as returned by eth_getProof.
enum MerklePatriciaProof {
    
    /// Verify an account proof against a state root.
    ///
    /// - Parameters:
    ///   - proof: Array of RLP-encoded trie nodes (from accountProof in eth_getProof)
    ///   - address: The Ethereum address being proved (20 bytes hex with 0x prefix)
    ///   - stateRoot: The state root from the block header (32 bytes)
    /// - Returns: The verified account data (nonce, balance, storageRoot, codeHash)
    static func verifyAccountProof(
        proof: [Data],
        address: String,
        stateRoot: Data
    ) throws -> VerifiedAccount {
        guard !proof.isEmpty else {
            throw ProofVerificationError.emptyProof
        }
        
        // The key in the state trie is keccak256(address)
        let addressBytes = hexToBytes(address)
        let key = Data(addressBytes.sha3(.keccak256))
        
        // Convert key to nibbles for trie traversal
        let keyNibbles = bytesToNibbles(key)
        
        // Walk the proof
        let accountRLP = try verifyProof(
            proof: proof,
            rootHash: stateRoot,
            keyNibbles: keyNibbles
        )
        
        // Decode the account RLP: [nonce, balance, storageRoot, codeHash]
        return try decodeAccount(accountRLP)
    }
    
    /// Verify a storage proof against a storage root.
    ///
    /// - Parameters:
    ///   - proof: Array of RLP-encoded trie nodes (from storageProof[].proof)
    ///   - slot: The storage slot (32 bytes hex with 0x prefix)
    ///   - storageRoot: The account's storage root (from accountProof verification)
    /// - Returns: The verified storage value as Data
    static func verifyStorageProof(
        proof: [Data],
        slot: String,
        storageRoot: Data
    ) throws -> Data {
        // For empty storage (storageRoot == keccak256(RLP("")))
        let emptyRoot = Data(Array<UInt8>(hex: "56e81f171bcc55a6ff8345e692c0f86e5b48e01b996cadc001622fb5e363b421"))
        if storageRoot == emptyRoot {
            return Data(count: 32) // zero value
        }
        
        guard !proof.isEmpty else {
            throw ProofVerificationError.emptyProof
        }
        
        // The key in the storage trie is keccak256(slot)
        let slotBytes = hexToBytes(slot)
        let key = Data(slotBytes.sha3(.keccak256))
        let keyNibbles = bytesToNibbles(key)
        
        // Walk the proof
        let valueRLP = try verifyProof(
            proof: proof,
            rootHash: storageRoot,
            keyNibbles: keyNibbles
        )
        
        // Storage values are RLP-encoded
        guard let decoded = try RLP.decode(valueRLP).asData else {
            throw ProofVerificationError.invalidProof("Storage value is not bytes")
        }
        
        // Pad to 32 bytes
        if decoded.count < 32 {
            return Data(count: 32 - decoded.count) + decoded
        }
        return decoded
    }
    
    // MARK: - Core Proof Verification
    
    /// Walk through proof nodes verifying hashes and following the key path.
    /// Returns the value at the proven key, or throws if proof is invalid.
    private static func verifyProof(
        proof: [Data],
        rootHash: Data,
        keyNibbles: [UInt8]
    ) throws -> Data {
        var expectedHash = rootHash
        var keyOffset = 0
        
        for (index, nodeRLP) in proof.enumerated() {
            let isLast = index == proof.count - 1
            
            // Verify this node hashes to the expected hash
            // (The root node is embedded directly for short nodes)
            if nodeRLP.count >= 32 {
                let nodeHash = Data(Array(nodeRLP).sha3(.keccak256))
                guard nodeHash == expectedHash else {
                    throw ProofVerificationError.hashMismatch(
                        expected: expectedHash.hex,
                        got: nodeHash.hex
                    )
                }
            } else if index == 0 {
                // Root node might be shorter than 32 bytes for very small tries
                let nodeHash = Data(Array(nodeRLP).sha3(.keccak256))
                guard nodeHash == expectedHash else {
                    throw ProofVerificationError.hashMismatch(
                        expected: expectedHash.hex,
                        got: nodeHash.hex
                    )
                }
            }
            
            // Decode the node
            let node = try RLP.decode(nodeRLP)
            guard let items = node.asList else {
                throw ProofVerificationError.invalidTrieNode("Node is not a list")
            }
            
            if items.count == 17 {
                // Branch node: 16 children + value
                if isLast {
                    // The value is at items[16]
                    if keyOffset == keyNibbles.count {
                        guard let value = items[16].asData, !value.isEmpty else {
                            throw ProofVerificationError.keyNotFound
                        }
                        return value
                    }
                    throw ProofVerificationError.keyNotFound
                }
                
                // Follow the next nibble
                guard keyOffset < keyNibbles.count else {
                    throw ProofVerificationError.invalidProof("Key exhausted at branch node")
                }
                let nibble = Int(keyNibbles[keyOffset])
                keyOffset += 1
                
                // Get the child reference
                guard let childRef = items[nibble].asData else {
                    throw ProofVerificationError.invalidTrieNode("Branch child \(nibble) is not bytes")
                }
                
                if childRef.isEmpty {
                    throw ProofVerificationError.keyNotFound
                }
                
                if childRef.count == 32 {
                    expectedHash = childRef
                } else {
                    // Inline node (< 32 bytes) — this shouldn't happen in proofs
                    // but handle it gracefully
                    expectedHash = childRef
                }
                
            } else if items.count == 2 {
                // Extension or Leaf node
                guard let pathData = items[0].asData else {
                    throw ProofVerificationError.invalidTrieNode("Path is not bytes")
                }
                
                let decoded = HexPrefix.decode(pathData)
                let pathNibbles = decoded.nibbles
                
                // Verify the path matches our key
                let remainingKey = Array(keyNibbles[keyOffset...])
                guard remainingKey.count >= pathNibbles.count else {
                    throw ProofVerificationError.keyNotFound
                }
                
                for i in 0..<pathNibbles.count {
                    guard pathNibbles[i] == remainingKey[i] else {
                        throw ProofVerificationError.keyNotFound
                    }
                }
                
                keyOffset += pathNibbles.count
                
                if decoded.isLeaf {
                    // Leaf node: items[1] is the value
                    guard isLast || keyOffset == keyNibbles.count else {
                        throw ProofVerificationError.invalidProof(
                            "Leaf node but key not fully consumed (\(keyOffset)/\(keyNibbles.count))"
                        )
                    }
                    guard let value = items[1].asData else {
                        throw ProofVerificationError.invalidTrieNode("Leaf value is not bytes")
                    }
                    return value
                } else {
                    // Extension node: items[1] is the next node hash
                    guard let nextHash = items[1].asData else {
                        throw ProofVerificationError.invalidTrieNode("Extension next is not bytes")
                    }
                    if nextHash.count == 32 {
                        expectedHash = nextHash
                    } else if nextHash.count < 32 {
                        // Inline node
                        expectedHash = nextHash
                    } else {
                        throw ProofVerificationError.invalidTrieNode("Extension next hash is \(nextHash.count) bytes")
                    }
                }
            } else {
                throw ProofVerificationError.invalidTrieNode("Node has \(items.count) items (expected 2 or 17)")
            }
        }
        
        throw ProofVerificationError.invalidProof("Proof ended without reaching value")
    }
    
    // MARK: - Account Decoding
    
    /// Decode an RLP-encoded Ethereum account: [nonce, balance, storageRoot, codeHash]
    private static func decodeAccount(_ data: Data) throws -> VerifiedAccount {
        let item = try RLP.decode(data)
        guard let items = item.asList, items.count == 4 else {
            throw ProofVerificationError.accountDecodingFailed(
                "Expected list of 4, got \(item.asList?.count ?? -1)"
            )
        }
        
        guard let nonce = items[0].asUInt64 else {
            throw ProofVerificationError.accountDecodingFailed("Invalid nonce")
        }
        
        guard let balance = items[1].asBigUInt else {
            throw ProofVerificationError.accountDecodingFailed("Invalid balance")
        }
        
        guard let storageRoot = items[2].asData, storageRoot.count == 32 else {
            throw ProofVerificationError.accountDecodingFailed(
                "Invalid storageRoot (\(items[2].asData?.count ?? 0) bytes)"
            )
        }
        
        guard let codeHash = items[3].asData, codeHash.count == 32 else {
            throw ProofVerificationError.accountDecodingFailed(
                "Invalid codeHash (\(items[3].asData?.count ?? 0) bytes)"
            )
        }
        
        return VerifiedAccount(
            nonce: nonce,
            balance: balance,
            storageRoot: storageRoot,
            codeHash: codeHash
        )
    }
    
    // MARK: - Helpers
    
    /// Convert a hex string (with or without 0x prefix) to bytes.
    private static func hexToBytes(_ hex: String) -> [UInt8] {
        let clean = hex.hasPrefix("0x") ? String(hex.dropFirst(2)) : hex
        var bytes: [UInt8] = []
        var index = clean.startIndex
        while index < clean.endIndex {
            let nextIndex = clean.index(index, offsetBy: 2, limitedBy: clean.endIndex) ?? clean.endIndex
            if let byte = UInt8(clean[index..<nextIndex], radix: 16) {
                bytes.append(byte)
            }
            index = nextIndex
        }
        return bytes
    }
    
    /// Convert bytes to nibbles (half-bytes).
    private static func bytesToNibbles(_ data: Data) -> [UInt8] {
        var nibbles: [UInt8] = []
        nibbles.reserveCapacity(data.count * 2)
        for byte in data {
            nibbles.append(byte >> 4)
            nibbles.append(byte & 0x0F)
        }
        return nibbles
    }
}

// MARK: - Data Hex Convenience

extension Data {
    /// Hex string representation (no 0x prefix).
    /// Note: Data(hexString:) init is defined in BinaryEncodingUtils.swift
    var hex: String {
        map { String(format: "%02x", $0) }.joined()
    }
}

// MARK: - eth_getProof Response Types

/// Parsed response from eth_getProof JSON-RPC call.
struct EthGetProofResponse {
    let address: String
    let accountProof: [Data]        // Array of RLP-encoded trie nodes
    let balance: String             // Hex balance (for cross-check)
    let codeHash: String
    let nonce: String
    let storageHash: String
    let storageProof: [StorageProofItem]
    
    struct StorageProofItem {
        let key: String
        let value: String
        let proof: [Data]
    }
    
    /// Parse from JSON dictionary (eth_getProof result)
    static func parse(from json: [String: Any]) throws -> EthGetProofResponse {
        guard let address = json["address"] as? String else {
            throw ProofVerificationError.invalidProof("Missing address")
        }
        
        guard let proofHexArray = json["accountProof"] as? [String] else {
            throw ProofVerificationError.invalidProof("Missing accountProof")
        }
        
        let accountProof = try proofHexArray.map { hex -> Data in
            guard let data = Data(hexString: hex) else {
                throw ProofVerificationError.invalidProof("Invalid hex in accountProof: \(hex.prefix(20))...")
            }
            return data
        }
        
        guard let balance = json["balance"] as? String,
              let codeHash = json["codeHash"] as? String,
              let nonce = json["nonce"] as? String,
              let storageHash = json["storageHash"] as? String else {
            throw ProofVerificationError.invalidProof("Missing account fields")
        }
        
        var storageProofItems: [StorageProofItem] = []
        if let storageProofs = json["storageProof"] as? [[String: Any]] {
            for sp in storageProofs {
                guard let key = sp["key"] as? String,
                      let value = sp["value"] as? String,
                      let proofHex = sp["proof"] as? [String] else {
                    continue
                }
                let proofData = try proofHex.map { hex -> Data in
                    guard let data = Data(hexString: hex) else {
                        throw ProofVerificationError.invalidProof("Invalid hex in storageProof")
                    }
                    return data
                }
                storageProofItems.append(StorageProofItem(key: key, value: value, proof: proofData))
            }
        }
        
        return EthGetProofResponse(
            address: address,
            accountProof: accountProof,
            balance: balance,
            codeHash: codeHash,
            nonce: nonce,
            storageHash: storageHash,
            storageProof: storageProofItems
        )
    }
}

// MARK: - High-Level Verification API

extension MerklePatriciaProof {
    
    /// Result of a verified balance query
    struct VerifiedBalanceResult {
        let account: VerifiedAccount
        let blockNumber: UInt64
        let stateRoot: Data
        let isProofValid: Bool
        
        /// Whether the proven balance matches the RPC-claimed balance
        let balanceConsistent: Bool
    }
    
    /// Verify an eth_getProof response against a state root.
    ///
    /// - Parameters:
    ///   - proofResponse: Parsed eth_getProof response
    ///   - stateRoot: State root from the block header (32 bytes)
    ///   - blockNumber: Block number for logging
    /// - Returns: Verified balance result with consistency check
    static func verifyBalance(
        proofResponse: EthGetProofResponse,
        stateRoot: Data,
        blockNumber: UInt64
    ) throws -> VerifiedBalanceResult {
        // Verify the account proof
        let account = try verifyAccountProof(
            proof: proofResponse.accountProof,
            address: proofResponse.address,
            stateRoot: stateRoot
        )
        
        // Cross-check: does the proven balance match the RPC-claimed balance?
        let claimedBalance = BigUInt(hexString: proofResponse.balance)
        let balanceConsistent = (claimedBalance == account.balance)
        
        if !balanceConsistent {
            SecureLogger.warning(
                "ProofVerifier: Balance mismatch! Proven=\(account.balance) Claimed=\(proofResponse.balance) for \(proofResponse.address)",
                category: .network
            )
        } else {
            SecureLogger.debug(
                "ProofVerifier: Balance verified ✓ \(account.balance) wei at block \(blockNumber) for \(proofResponse.address.prefix(10))...",
                category: .network
            )
        }
        
        return VerifiedBalanceResult(
            account: account,
            blockNumber: blockNumber,
            stateRoot: stateRoot,
            isProofValid: true,
            balanceConsistent: balanceConsistent
        )
    }
}
