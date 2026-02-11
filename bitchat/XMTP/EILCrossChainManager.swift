//
// EILCrossChainManager.swift
// bitchat
//
// Ethereum Interop Layer (EIL) cross-chain swap manager.
// Uses EIP-7702 to enable EOAs to interact with EIL's CrossChainPaymaster.
//
// This is free and unencumbered software released into the public domain.
// For more information, see <https://unlicense.org>
//

import BitLogger
import CryptoSwift
import Foundation

/// Manager for EIL cross-chain swaps using EIP-7702
actor EILCrossChainManager {
    
    // MARK: - Constants
    
    /// Known EIL contract addresses per chain (placeholder - update with real addresses)
    static let crossChainPaymasters: [UInt64: String] = [
        1: "0x0000000000000000000000000000000000000000",      // Mainnet (TBD)
        10: "0x0000000000000000000000000000000000000000",     // Optimism (TBD)
        8453: "0x0000000000000000000000000000000000000000",   // Base (TBD)
        42161: "0x0000000000000000000000000000000000000000",  // Arbitrum (TBD)
        11155111: "0x0000000000000000000000000000000000000000" // Sepolia (TBD)
    ]
    
    /// Supported chains for cross-chain swaps
    static let supportedChains: [SupportedChain] = [
        SupportedChain(id: 1, name: "Ethereum", symbol: "ETH", isTestnet: false),
        SupportedChain(id: 10, name: "Optimism", symbol: "ETH", isTestnet: false),
        SupportedChain(id: 8453, name: "Base", symbol: "ETH", isTestnet: false),
        SupportedChain(id: 42161, name: "Arbitrum One", symbol: "ETH", isTestnet: false),
        SupportedChain(id: 11155111, name: "Sepolia", symbol: "ETH", isTestnet: true)
    ]
    
    // MARK: - Types
    
    struct SupportedChain: Identifiable, Equatable {
        let id: UInt64
        let name: String
        let symbol: String
        let isTestnet: Bool
    }
    
    /// A voucher request to swap assets cross-chain
    struct VoucherRequest: Identifiable, Codable {
        let id: UUID
        let sourceChainId: UInt64
        let destinationChainId: UInt64
        let sourceToken: String  // Address or "native" for ETH
        let destinationToken: String
        let amount: String       // In wei
        let minReceive: String   // Minimum amount to receive (slippage protection)
        let recipient: String    // Destination address
        let deadline: Date       // Request expiration
        let createdAt: Date
        
        var status: VoucherStatus = .pending
        var sourceTxHash: String?
        var destinationTxHash: String?
        var xlpAddress: String?
        var error: String?
        
        init(
            sourceChainId: UInt64,
            destinationChainId: UInt64,
            sourceToken: String = "native",
            destinationToken: String = "native",
            amount: String,
            minReceive: String,
            recipient: String,
            deadline: Date = Date().addingTimeInterval(3600) // 1 hour default
        ) {
            self.id = UUID()
            self.sourceChainId = sourceChainId
            self.destinationChainId = destinationChainId
            self.sourceToken = sourceToken
            self.destinationToken = destinationToken
            self.amount = amount
            self.minReceive = minReceive
            self.recipient = recipient
            self.deadline = deadline
            self.createdAt = Date()
        }
    }
    
    enum VoucherStatus: String, Codable {
        case pending        // Created, not yet submitted
        case sourcing       // Looking for XLP liquidity
        case matched        // XLP found, awaiting source tx
        case submitted      // Source tx submitted
        case confirming     // Waiting for source confirmations
        case bridging       // Cross-chain message in flight
        case completing     // Destination tx being executed
        case completed      // Successfully completed
        case failed         // Failed at some step
        case expired        // Deadline passed
    }
    
    /// An Atomic Swap Voucher from an XLP
    struct AtomicSwapVoucher: Codable {
        let voucherHash: String
        let xlpAddress: String
        let sourceChainId: UInt64
        let destinationChainId: UInt64
        let sourceAmount: String
        let destinationAmount: String
        let expiresAt: Date
        let signature: Data
    }
    
    // MARK: - Properties
    
    private let wallet: EmbeddedWallet
    private var activeRequests: [VoucherRequest] = []
    
    // MARK: - Initialization
    
    init(wallet: EmbeddedWallet) {
        self.wallet = wallet
    }
    
    // MARK: - Chain Info
    
    /// Get chains available for cross-chain swaps
    func getAvailableChains(includeTestnets: Bool = false) -> [SupportedChain] {
        if includeTestnets {
            return Self.supportedChains
        }
        return Self.supportedChains.filter { !$0.isTestnet }
    }
    
    /// Check if a chain pair is supported
    func isSwapSupported(from sourceChain: UInt64, to destinationChain: UInt64) -> Bool {
        guard sourceChain != destinationChain else { return false }
        
        let sourceSupported = Self.crossChainPaymasters[sourceChain] != nil
        let destSupported = Self.crossChainPaymasters[destinationChain] != nil
        
        return sourceSupported && destSupported
    }
    
    // MARK: - Quote
    
    /// Quote result for a cross-chain swap
    struct SwapQuote {
        let sourceChainId: UInt64
        let destinationChainId: UInt64
        let sourceAmount: String
        let destinationAmount: String  // Estimated receive amount
        let fee: String               // Fee in source token
        let estimatedTime: TimeInterval
        let priceImpact: Double       // As percentage (e.g., 0.5 for 0.5%)
        let xlpAddress: String?       // Matched XLP if available
    }
    
    /// Get a quote for a cross-chain swap
    /// - Parameters:
    ///   - sourceChainId: Source chain
    ///   - destinationChainId: Destination chain
    ///   - amount: Amount in wei
    /// - Returns: Quote with estimated output and fees
    func getQuote(
        sourceChainId: UInt64,
        destinationChainId: UInt64,
        amount: String
    ) async throws -> SwapQuote {
        guard isSwapSupported(from: sourceChainId, to: destinationChainId) else {
            throw EILError.unsupportedChainPair
        }
        
        // In a full implementation, this would:
        // 1. Query XLP network for available liquidity
        // 2. Calculate fees based on current gas prices
        // 3. Return best available quote
        
        // Placeholder quote calculation
        let amountValue = Decimal(string: amount) ?? 0
        
        // Assume 0.3% fee + estimated gas
        let feePercent = Decimal(0.003)
        let fee = amountValue * feePercent
        let destinationAmount = amountValue - fee
        
        return SwapQuote(
            sourceChainId: sourceChainId,
            destinationChainId: destinationChainId,
            sourceAmount: amount,
            destinationAmount: destinationAmount.description,
            fee: fee.description,
            estimatedTime: 300, // 5 minutes
            priceImpact: 0.1,
            xlpAddress: nil
        )
    }
    
    // MARK: - Swap Execution
    
    /// Initiate a cross-chain swap
    /// - Parameters:
    ///   - sourceChainId: Source chain
    ///   - destinationChainId: Destination chain
    ///   - amount: Amount in wei
    ///   - minReceive: Minimum amount to receive (slippage protection)
    ///   - recipient: Destination address (defaults to sender)
    /// - Returns: Voucher request for tracking
    func initiateSwap(
        sourceChainId: UInt64,
        destinationChainId: UInt64,
        amount: String,
        minReceive: String,
        recipient: String? = nil
    ) async throws -> VoucherRequest {
        let walletAddress = try await wallet.getAddress()
        let recipientAddress = recipient ?? walletAddress
        
        // Create voucher request
        var request = VoucherRequest(
            sourceChainId: sourceChainId,
            destinationChainId: destinationChainId,
            amount: amount,
            minReceive: minReceive,
            recipient: recipientAddress
        )
        
        // Validate the swap
        guard isSwapSupported(from: sourceChainId, to: destinationChainId) else {
            throw EILError.unsupportedChainPair
        }
        
        // In a full implementation, this would:
        // 1. Create EIP-7702 authorization for CrossChainPaymaster
        // 2. Build and sign the swap transaction
        // 3. Submit to source chain
        // 4. Monitor for XLP matching
        
        request.status = .sourcing
        activeRequests.append(request)
        
        SecureLogger.info("🌉 Initiated cross-chain swap: \(sourceChainId) → \(destinationChainId)", category: .session)
        
        return request
    }
    
    /// Build the EIP-7702 authorization for CrossChainPaymaster
    func buildCrossChainAuthorization(
        chainId: UInt64,
        nonce: UInt64
    ) async throws -> EmbeddedWallet.EIP7702Authorization {
        guard let paymasterAddress = Self.crossChainPaymasters[chainId] else {
            throw EILError.unsupportedChainPair
        }
        
        return EmbeddedWallet.EIP7702Authorization(
            chainId: chainId,
            codeAddress: paymasterAddress,
            nonce: nonce
        )
    }
    
    /// Build swap calldata for CrossChainPaymaster
    func buildSwapCalldata(request: VoucherRequest) throws -> Data {
        // EIL CrossChainPaymaster.initiateSwap(destinationChainId, recipient, minReceive)
        // Function selector: keccak256("initiateSwap(uint256,address,uint256)")[:4]
        
        let selector = keccak256("initiateSwap(uint256,address,uint256)".data(using: .utf8)!).prefix(4)
        
        // ABI encode parameters
        var calldata = Data(selector)
        
        // uint256 destinationChainId
        calldata.append(encodeUint256(request.destinationChainId))
        
        // address recipient
        let recipientData = Data(hexString: request.recipient.hasPrefix("0x") 
            ? String(request.recipient.dropFirst(2)) 
            : request.recipient) ?? Data()
        calldata.append(Data(repeating: 0, count: 12)) // Pad to 32 bytes
        calldata.append(recipientData)
        
        // uint256 minReceive
        if let minReceive = UInt64(request.minReceive) {
            calldata.append(encodeUint256(minReceive))
        } else {
            calldata.append(Data(repeating: 0, count: 32))
        }
        
        return calldata
    }
    
    // MARK: - Request Tracking
    
    /// Get all active swap requests
    func getActiveRequests() -> [VoucherRequest] {
        activeRequests.filter { 
            $0.status != .completed && 
            $0.status != .failed && 
            $0.status != .expired 
        }
    }
    
    /// Get request by ID
    func getRequest(id: UUID) -> VoucherRequest? {
        activeRequests.first { $0.id == id }
    }
    
    /// Update request status
    func updateRequestStatus(id: UUID, status: VoucherStatus, txHash: String? = nil, error: String? = nil) {
        guard let index = activeRequests.firstIndex(where: { $0.id == id }) else { return }
        
        activeRequests[index].status = status
        
        if let txHash = txHash {
            if status == .submitted || status == .confirming {
                activeRequests[index].sourceTxHash = txHash
            } else if status == .completing || status == .completed {
                activeRequests[index].destinationTxHash = txHash
            }
        }
        
        if let error = error {
            activeRequests[index].error = error
        }
        
        SecureLogger.debug("🌉 Swap \(id) status: \(status.rawValue)", category: .session)
    }
    
    // MARK: - Helpers
    
    private func keccak256(_ data: Data) -> Data {
        let bytes = Array(data)
        let hash = bytes.sha3(.keccak256)
        return Data(hash)
    }
    
    private func encodeUint256(_ value: UInt64) -> Data {
        var result = Data(repeating: 0, count: 24)
        var bigEndian = value.bigEndian
        result.append(Data(bytes: &bigEndian, count: 8))
        return result
    }
}

// MARK: - Errors

enum EILError: Error, LocalizedError {
    case unsupportedChainPair
    case insufficientLiquidity
    case quoteFailed
    case swapFailed
    case transactionFailed
    case timeout
    case invalidAmount
    
    var errorDescription: String? {
        switch self {
        case .unsupportedChainPair:
            return "This chain pair is not supported for cross-chain swaps"
        case .insufficientLiquidity:
            return "Insufficient liquidity for this swap"
        case .quoteFailed:
            return "Failed to get swap quote"
        case .swapFailed:
            return "Swap execution failed"
        case .transactionFailed:
            return "Transaction failed"
        case .timeout:
            return "Swap timed out"
        case .invalidAmount:
            return "Invalid swap amount"
        }
    }
}
