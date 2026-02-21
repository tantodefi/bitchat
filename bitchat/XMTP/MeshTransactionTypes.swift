//
// MeshTransactionTypes.swift
// bitchat
//
// Native mesh protocol transaction types for offline transaction relay.
// These packets are Noise-encrypted and sent via BLE mesh.
//
// This is free and unencumbered software released into the public domain.
// For more information, see <https://unlicense.org>
//

import Foundation

// MARK: - Packet Types

/// Transaction-related packet types for mesh relay
/// Reserved range: 0x50-0x5F
enum TxPacketType: UInt8, CaseIterable {
    /// Legacy: Transaction relay request (deprecated, use txSigned)
    case txRequest = 0x50
    
    /// Pre-signed transaction ready for broadcast
    case txSigned = 0x51
    
    /// Transaction confirmation with hash
    case txConfirm = 0x52
    
    /// Transaction rejected by relay peer
    case txReject = 0x53
    
    /// ERC-4337 UserOperation for PQ account (bundler submission)
    case txUserOp = 0x54
    
    var description: String {
        switch self {
        case .txRequest: return "txRequest"
        case .txSigned: return "txSigned"
        case .txConfirm: return "txConfirm"
        case .txReject: return "txReject"
        case .txUserOp: return "txUserOp"
        }
    }
}

// MARK: - Signed Transaction Payload

/// A pre-signed transaction ready for mesh relay and broadcast
struct TxSignedPayload: Codable {
    /// Unique request ID for tracking
    let requestId: String
    
    /// Chain ID (1 = mainnet, 11155111 = sepolia)
    let chainId: UInt64
    
    /// RLP-encoded signed transaction (ready to broadcast)
    let signedTx: Data
    
    /// Transaction nonce (for replay protection)
    let nonce: UInt64
    
    /// Gas limit
    let gasLimit: UInt64
    
    /// Max fee per gas (wei)
    let maxFeePerGas: UInt64
    
    /// Max priority fee (wei)
    let maxPriorityFee: UInt64
    
    /// Timestamp when signed
    let signedAt: Date
    
    /// Human-readable description for display
    let description: String?
    
    /// Transaction type for UI display
    let transactionType: String?
    
    /// Currency symbol (ETH, USDC, etc.)
    let currency: String?
    
    /// Amount in smallest unit
    let amount: UInt64?
    
    /// Token decimals
    let decimals: UInt8?
    
    /// Destination address
    let toAddress: String
    
    /// Sender address (EOA or PQ account that initiated the transaction)
    let fromAddress: String?
    
    /// PeerID to send confirmation back to
    let replyToPeerId: String
    
    init(
        signedTx: Data,
        chainId: UInt64,
        nonce: UInt64,
        gasLimit: UInt64,
        maxFeePerGas: UInt64,
        maxPriorityFee: UInt64,
        toAddress: String,
        replyToPeerId: String,
        fromAddress: String? = nil,
        description: String? = nil,
        transactionType: String? = nil,
        currency: String? = nil,
        amount: UInt64? = nil,
        decimals: UInt8? = nil
    ) {
        self.requestId = UUID().uuidString
        self.chainId = chainId
        self.signedTx = signedTx
        self.nonce = nonce
        self.gasLimit = gasLimit
        self.maxFeePerGas = maxFeePerGas
        self.maxPriorityFee = maxPriorityFee
        self.signedAt = Date()
        self.toAddress = toAddress
        self.fromAddress = fromAddress
        self.replyToPeerId = replyToPeerId
        self.description = description
        self.transactionType = transactionType
        self.currency = currency
        self.amount = amount
        self.decimals = decimals
    }
    
    /// Encode to binary for mesh transmission
    func encode() -> Data? {
        try? JSONEncoder().encode(self)
    }
    
    /// Decode from binary
    static func decode(_ data: Data) -> TxSignedPayload? {
        try? JSONDecoder().decode(TxSignedPayload.self, from: data)
    }
}

// MARK: - Transaction Confirmation

/// Confirmation payload sent back after broadcast
struct TxConfirmPayload: Codable {
    /// Matches the original request ID
    let requestId: String
    
    /// Transaction hash (32 bytes hex)
    let txHash: String
    
    /// Transaction status
    let status: TxStatus
    
    /// Block number if confirmed
    let blockNumber: UInt64?
    
    /// Gas used if confirmed
    let gasUsed: UInt64?
    
    /// Timestamp of confirmation
    let confirmedAt: Date
    
    init(requestId: String, txHash: String, status: TxStatus, blockNumber: UInt64? = nil, gasUsed: UInt64? = nil) {
        self.requestId = requestId
        self.txHash = txHash
        self.status = status
        self.blockNumber = blockNumber
        self.gasUsed = gasUsed
        self.confirmedAt = Date()
    }
    
    func encode() -> Data? {
        try? JSONEncoder().encode(self)
    }
    
    static func decode(_ data: Data) -> TxConfirmPayload? {
        try? JSONDecoder().decode(TxConfirmPayload.self, from: data)
    }
}

/// Transaction status
enum TxStatus: String, Codable {
    case pending    // Submitted to mempool
    case confirmed  // Included in block
    case failed     // Reverted or dropped
}

// MARK: - Transaction Rejection

/// Rejection payload if relay peer refuses
struct TxRejectPayload: Codable {
    let requestId: String
    let reason: TxRejectReason
    let message: String?
    
    func encode() -> Data? {
        try? JSONEncoder().encode(self)
    }
    
    static func decode(_ data: Data) -> TxRejectPayload? {
        try? JSONDecoder().decode(TxRejectPayload.self, from: data)
    }
}

/// Reasons for rejecting a relay request
enum TxRejectReason: String, Codable {
    case noInternet         // Relay peer has no internet
    case invalidTx          // Transaction validation failed
    case unsupportedChain   // Chain ID not supported
    case gasToLow           // Gas price below minimum
    case rateLimited        // Too many relay requests
    case policyViolation    // Relay peer policy rejection
    case bundlerRejected    // ERC-4337 bundler rejected the UserOp
}

// MARK: - ERC-4337 UserOperation Payload

/// A fully signed ERC-4337 UserOperation for PQ smart account transactions.
/// Relayed via BLE mesh so a peer with internet can submit to the Pimlico bundler.
struct TxUserOpPayload: Codable {
    /// Unique request ID for tracking
    let requestId: String
    
    /// Chain ID (11155111 = Sepolia, 421614 = Arbitrum Sepolia)
    let chainId: UInt64
    
    /// Pimlico API key (needed by relay peer to submit to bundler)
    let pimlicoAPIKey: String
    
    /// Serialized UserOp fields (JSON-RPC compatible unpacked format)
    let sender: String              // 0x-prefixed hex address
    let nonce: String               // 0x-prefixed hex uint256
    let callData: String            // 0x-prefixed hex
    let signature: String           // 0x-prefixed hex (hybrid ECDSA + ML-DSA-44)
    let verificationGasLimit: String
    let callGasLimit: String
    let preVerificationGas: String
    let maxPriorityFeePerGas: String
    let maxFeePerGas: String
    
    /// Factory fields (non-empty only if account not yet deployed)
    let factory: String?
    let factoryData: String?
    
    /// Paymaster fields (empty for self-funded)
    let paymaster: String?
    let paymasterVerificationGasLimit: String?
    let paymasterPostOpGasLimit: String?
    let paymasterData: String?
    
    /// Timestamp when signed
    let signedAt: Date
    
    /// Human-readable description for display
    let description: String?
    
    /// Destination address (for UI/tracking)
    let toAddress: String
    
    /// Sender PQ account address (for UI/tracking)
    let fromAddress: String?
    
    /// Amount in wei (for UI/tracking)
    let amount: UInt64?
    
    /// PeerID to send confirmation back to
    let replyToPeerId: String
    
    func encode() -> Data? {
        try? JSONEncoder().encode(self)
    }
    
    static func decode(_ data: Data) -> TxUserOpPayload? {
        try? JSONDecoder().decode(TxUserOpPayload.self, from: data)
    }
    
    /// Convert back to a bundler-compatible dictionary for eth_sendUserOperation
    func toBundlerDict() -> [String: Any] {
        var dict: [String: Any] = [
            "sender": sender,
            "nonce": nonce,
            "callData": callData,
            "signature": signature,
            "verificationGasLimit": verificationGasLimit,
            "callGasLimit": callGasLimit,
            "preVerificationGas": preVerificationGas,
            "maxPriorityFeePerGas": maxPriorityFeePerGas,
            "maxFeePerGas": maxFeePerGas,
        ]
        if let factory = factory, !factory.isEmpty && factory != "0x" {
            dict["factory"] = factory
            dict["factoryData"] = factoryData ?? "0x"
        }
        if let paymaster = paymaster, !paymaster.isEmpty && paymaster != "0x" {
            dict["paymaster"] = paymaster
            dict["paymasterVerificationGasLimit"] = paymasterVerificationGasLimit ?? "0x0"
            dict["paymasterPostOpGasLimit"] = paymasterPostOpGasLimit ?? "0x0"
            dict["paymasterData"] = paymasterData ?? "0x"
        }
        return dict
    }
}

// MARK: - XMTP-Compatible Transaction Reference

/// XMTP-standard transaction reference for sharing completed tx in chat
/// Matches the XMTP TransactionReference content type structure
struct XMTPTransactionReference: Codable {
    /// Namespace (always "eip155" for Ethereum)
    let namespace: String
    
    /// Network/chain ID
    let networkId: UInt64
    
    /// Transaction hash
    let reference: String
    
    /// Display metadata
    let metadata: TransactionReferenceMetadata
    
    init(chainId: UInt64, txHash: String, metadata: TransactionReferenceMetadata) {
        self.namespace = "eip155"
        self.networkId = chainId
        self.reference = txHash
        self.metadata = metadata
    }
}

struct TransactionReferenceMetadata: Codable {
    let transactionType: String?
    let currency: String?
    let amount: UInt64?
    let decimals: UInt8?
    let fromAddress: String?
    let toAddress: String?
    let description: String?
}

// MARK: - XMTP-Compatible WalletSendCalls

/// XMTP-standard transaction request for agents
/// Matches the XMTP WalletSendCalls content type (XIP-59)
struct XMTPWalletSendCalls: Codable {
    let version: String
    let chainId: String  // Hex format "0x1"
    let from: String
    let calls: [WalletSendCall]
    let capabilities: [String: String]?
    
    init(chainId: UInt64, from: String, calls: [WalletSendCall], capabilities: [String: String]? = nil) {
        self.version = "1.0"
        self.chainId = String(format: "0x%x", chainId)
        self.from = from
        self.calls = calls
        self.capabilities = capabilities
    }
}

struct WalletSendCall: Codable {
    let to: String
    let data: String?
    let value: String?
    let gas: String?
    let metadata: WalletSendCallMetadata?
}

struct WalletSendCallMetadata: Codable {
    let description: String?
    let transactionType: String?
    let currency: String?
    let amount: UInt64?
    let decimals: UInt8?
    let toAddress: String?
    let platform: String?
    let apy: String?
}
