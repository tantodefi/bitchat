//
// ABIEncoder.swift
// bitchat
//
// Minimal Solidity ABI encoder for ERC-4337 post-quantum account operations.
// Supports function selectors, dynamic bytes, uint256, address, and arrays.
//
// This is free and unencumbered software released into the public domain.
// For more information, see <https://unlicense.org>
//

import CryptoSwift
import Foundation

// MARK: - ABI Types

/// Represents a Solidity ABI type for encoding
enum ABIType {
    case uint256
    case address
    case bytes       // dynamic bytes
    case bytesFixed(Int)  // bytes1..bytes32
    case bool
}

/// Represents a Solidity ABI value for encoding
enum ABIValue {
    case uint256(Data)      // 32-byte big-endian
    case address(String)    // 0x-prefixed hex address
    case addressData(Data)  // raw 20-byte address
    case bytes(Data)        // dynamic bytes
    case bool(Bool)
    
    /// Convenience: create uint256 from UInt64
    static func uint256(_ value: UInt64) -> ABIValue {
        var data = Data(repeating: 0, count: 24) // pad to 32 bytes
        var be = value.bigEndian
        data.append(Data(bytes: &be, count: 8))
        return .uint256(data)
    }
    
    /// Convenience: create uint256 from Data (left-pads to 32 bytes)
    static func uint256FromData(_ value: Data) -> ABIValue {
        let padded = ABIEncoder.padLeft(value, to: 32)
        return .uint256(padded)
    }
}

// MARK: - ABI Encoder

/// Minimal Solidity ABI encoder supporting the subset needed for PQ account operations.
///
/// Encoding rules (Solidity ABI):
/// - Static types (uint256, address, bool) are encoded inline as 32-byte words
/// - Dynamic types (bytes, string) use an offset pointer in the head, with data in the tail
/// - `encode(types:values:)` produces the same output as `abi.encode(...)` in Solidity
struct ABIEncoder {
    
    // MARK: - Core Encoding
    
    /// ABI-encode a list of typed values (equivalent to Solidity's `abi.encode(...)`)
    /// - Parameters:
    ///   - types: The ABI types in order
    ///   - values: The ABI values in order (must match types)
    /// - Returns: ABI-encoded bytes
    static func encode(types: [ABIType], values: [ABIValue]) -> Data {
        precondition(types.count == values.count, "Types and values count mismatch")
        
        var headSize = 0
        for type in types {
            switch type {
            case .bytes:
                headSize += 32 // offset pointer
            default:
                headSize += 32 // inline value
            }
        }
        
        var head = Data()
        var tail = Data()
        
        for i in 0..<types.count {
            switch types[i] {
            case .uint256:
                if case .uint256(let data) = values[i] {
                    head.append(padLeft(data, to: 32))
                }
                
            case .address:
                if case .address(let addr) = values[i] {
                    let addrData = hexToData(addr)
                    head.append(padLeft(addrData, to: 32))
                } else if case .addressData(let addrData) = values[i] {
                    head.append(padLeft(addrData, to: 32))
                }
                
            case .bool:
                if case .bool(let val) = values[i] {
                    var word = Data(repeating: 0, count: 32)
                    if val { word[31] = 1 }
                    head.append(word)
                }
                
            case .bytes:
                if case .bytes(let data) = values[i] {
                    // Offset pointer (head points to tail position)
                    let offset = UInt64(headSize + tail.count)
                    head.append(encodeUInt256(offset))
                    
                    // Tail: length (32 bytes) + data (padded to 32-byte boundary)
                    tail.append(encodeUInt256(UInt64(data.count)))
                    tail.append(data)
                    // Pad to 32-byte boundary
                    let padding = (32 - (data.count % 32)) % 32
                    if padding > 0 {
                        tail.append(Data(repeating: 0, count: padding))
                    }
                }
                
            case .bytesFixed(let size):
                if case .bytes(let data) = values[i] {
                    precondition(data.count <= size, "Fixed bytes overflow")
                    var word = Data(data)
                    // Right-pad to 32 bytes for bytesN
                    if word.count < 32 {
                        word.append(Data(repeating: 0, count: 32 - word.count))
                    }
                    head.append(word)
                }
            }
        }
        
        return head + tail
    }
    
    /// ABI-encode packed (no padding, equivalent to Solidity's `abi.encodePacked(...)`)
    static func encodePacked(_ values: [ABIValue]) -> Data {
        var result = Data()
        for value in values {
            switch value {
            case .uint256(let data):
                result.append(data)
            case .address(let addr):
                result.append(hexToData(addr))
            case .addressData(let data):
                result.append(data)
            case .bytes(let data):
                result.append(data)
            case .bool(let val):
                result.append(val ? 1 : 0)
            }
        }
        return result
    }
    
    // MARK: - Convenience Methods for PQ Account
    
    /// Encode a hybrid signature: `abi.encode(bytes preQuantumSig, bytes postQuantumSig)`
    /// - Parameters:
    ///   - preQuantumSig: ECDSA signature (65 bytes: r + s + v)
    ///   - postQuantumSig: ML-DSA-44 signature (2420 bytes)
    /// - Returns: ABI-encoded hybrid signature
    static func encodeHybridSignature(preQuantumSig: Data, postQuantumSig: Data) -> Data {
        encode(
            types: [.bytes, .bytes],
            values: [.bytes(preQuantumSig), .bytes(postQuantumSig)]
        )
    }
    
    /// Encode `createAccount(bytes preQuantumPubKey, bytes postQuantumPubKey)` calldata
    /// - Parameters:
    ///   - preQuantumPubKey: ECDSA public key (20 bytes address, ABI-encoded)
    ///   - postQuantumPubKey: ML-DSA-44 expanded public key (~20KB ABI-encoded)
    /// - Returns: Full calldata including 4-byte function selector
    static func encodeCreateAccount(preQuantumPubKey: Data, postQuantumPubKey: Data) -> Data {
        let selector = functionSelector("createAccount(bytes,bytes)")
        let params = encode(
            types: [.bytes, .bytes],
            values: [.bytes(preQuantumPubKey), .bytes(postQuantumPubKey)]
        )
        return selector + params
    }
    
    /// Encode `getAddress(bytes preQuantumPubKey, bytes postQuantumPubKey)` calldata
    static func encodeGetAddress(preQuantumPubKey: Data, postQuantumPubKey: Data) -> Data {
        let selector = functionSelector("getAddress(bytes,bytes)")
        let params = encode(
            types: [.bytes, .bytes],
            values: [.bytes(preQuantumPubKey), .bytes(postQuantumPubKey)]
        )
        return selector + params
    }
    
    /// Encode `execute(address dest, uint256 value, bytes calldata func)` calldata
    static func encodeExecute(dest: String, value: UInt64, funcData: Data) -> Data {
        let selector = functionSelector("execute(address,uint256,bytes)")
        let params = encode(
            types: [.address, .uint256, .bytes],
            values: [.address(dest), .uint256(value), .bytes(funcData)]
        )
        return selector + params
    }
    
    /// Encode `getNonce()` calldata
    static func encodeGetNonce() -> Data {
        functionSelector("getNonce()")
    }
    
    // MARK: - Function Selector
    
    /// Compute the 4-byte function selector from a Solidity function signature
    /// - Parameter signature: e.g. "createAccount(bytes,bytes)"
    /// - Returns: First 4 bytes of keccak256(signature)
    static func functionSelector(_ signature: String) -> Data {
        let hash = Array(signature.utf8).sha3(.keccak256)
        return Data(hash[0..<4])
    }
    
    // MARK: - Decoding Helpers
    
    /// Decode a uint256 from ABI-encoded response (first 32 bytes)
    static func decodeUInt256(_ data: Data) -> UInt64? {
        guard data.count >= 32 else { return nil }
        // Take last 8 bytes (big-endian uint64, sufficient for most values)
        let bytes = Data(data[24..<32])
        return bytes.withUnsafeBytes { $0.load(as: UInt64.self).bigEndian }
    }
    
    /// Decode an address from ABI-encoded response (20 bytes from offset 12)
    static func decodeAddress(_ data: Data) -> String? {
        guard data.count >= 32 else { return nil }
        let addressBytes = Data(data[12..<32])
        return "0x" + addressBytes.map { String(format: "%02x", $0) }.joined()
    }
    
    /// Decode dynamic bytes from ABI-encoded response
    static func decodeBytes(_ data: Data, offset: Int = 0) -> Data? {
        guard data.count >= offset + 64 else { return nil }
        // Read offset pointer
        guard let ptrValue = decodeUInt256(Data(data[offset..<(offset + 32)])) else { return nil }
        let ptr = Int(ptrValue)
        // Read length
        guard data.count >= ptr + 32 else { return nil }
        guard let length = decodeUInt256(Data(data[ptr..<(ptr + 32)])) else { return nil }
        let len = Int(length)
        // Read data
        guard data.count >= ptr + 32 + len else { return nil }
        return Data(data[(ptr + 32)..<(ptr + 32 + len)])
    }
    
    // MARK: - Utilities
    
    /// Encode a UInt64 as a 32-byte big-endian uint256
    static func encodeUInt256(_ value: UInt64) -> Data {
        var result = Data(repeating: 0, count: 24)
        var be = value.bigEndian
        result.append(Data(bytes: &be, count: 8))
        return result
    }
    
    /// Encode arbitrary Data as a 32-byte big-endian uint256 (left-padded)
    static func encodeUInt256(data: Data) -> Data {
        padLeft(data, to: 32)
    }
    
    /// Left-pad data to a target length with zeros
    static func padLeft(_ data: Data, to length: Int) -> Data {
        if data.count >= length {
            return Data(data.suffix(length))
        }
        var padded = Data(repeating: 0, count: length - data.count)
        padded.append(data)
        return padded
    }
    
    /// Convert a hex string (with or without 0x prefix) to Data
    static func hexToData(_ hex: String) -> Data {
        let cleanHex = hex.hasPrefix("0x") ? String(hex.dropFirst(2)) : hex
        var data = Data()
        var index = cleanHex.startIndex
        while index < cleanHex.endIndex {
            let nextIndex = cleanHex.index(index, offsetBy: 2, limitedBy: cleanHex.endIndex) ?? cleanHex.endIndex
            if let byte = UInt8(cleanHex[index..<nextIndex], radix: 16) {
                data.append(byte)
            }
            index = nextIndex
        }
        return data
    }
    
    /// Convert Data to hex string
    /// - Parameters:
    ///   - data: The data to convert
    ///   - prefixed: Whether to include "0x" prefix (default: true)
    /// - Returns: Hex string representation
    static func dataToHex(_ data: Data, prefixed: Bool = true) -> String {
        let hex = data.map { String(format: "%02x", $0) }.joined()
        return prefixed ? "0x" + hex : hex
    }
    
    // MARK: - Keccak-256
    
    /// Keccak-256 hash (convenience wrapper for CryptoSwift)
    static func keccak256(_ data: Data) -> Data {
        Data(Array(data).sha3(.keccak256))
    }
    
    // MARK: - CREATE2 Address Prediction
    
    /// Predict a contract address deployed via CREATE2.
    /// `address = keccak256(0xff ++ deployer ++ salt ++ keccak256(initCode))[12:]`
    ///
    /// - Parameters:
    ///   - deployer: Factory contract address (20 bytes hex with 0x prefix)
    ///   - salt: 32-byte CREATE2 salt
    ///   - initCodeHash: keccak256 of the full init code (creation code + constructor args)
    /// - Returns: Predicted address as 0x-prefixed hex string
    static func predictCREATE2Address(
        deployer: String,
        salt: Data,
        initCodeHash: Data
    ) -> String {
        let deployerBytes = hexToData(deployer)
        var packed = Data([0xff])
        packed.append(deployerBytes)
        packed.append(padLeft(salt, to: 32))
        packed.append(initCodeHash)
        let hash = keccak256(packed)
        let addressBytes = hash.suffix(20)
        return "0x" + addressBytes.map { String(format: "%02x", $0) }.joined()
    }
}
