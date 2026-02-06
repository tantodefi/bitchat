//
// TransactionSigner.swift
// bitchat
//
// High-level transaction signing service that combines EmbeddedWallet
// with MeshTransactionRelay for offline-capable transaction broadcasting.
//
// This is free and unencumbered software released into the public domain.
// For more information, see <https://unlicense.org>
//

import BitLogger
import Foundation

/// Service for signing and queueing transactions for mesh relay
@MainActor
final class TransactionSigner {
    private let wallet: EmbeddedWallet
    private let meshRelay: MeshTransactionRelay
    private let balanceService: EthereumBalanceService
    
    init(wallet: EmbeddedWallet, meshRelay: MeshTransactionRelay, balanceService: EthereumBalanceService) {
        self.wallet = wallet
        self.meshRelay = meshRelay
        self.balanceService = balanceService
    }
    
    /// Sign and queue a simple ETH transfer
    /// - Parameters:
    ///   - to: Destination address (0x prefixed)
    ///   - amountWei: Amount in wei
    ///   - nonce: Transaction nonce (fetch from RPC if nil)
    ///   - replyToPeerId: PeerID to send confirmation back to
    ///   - description: Human-readable description
    /// - Returns: The request ID for tracking
    func signAndQueueTransfer(
        to: String,
        amountWei: UInt64,
        nonce: UInt64? = nil,
        replyToPeerId: String,
        description: String? = nil
    ) async throws -> String {
        // Determine active network
        let network = balanceService.useTestnet ? EthereumBalanceService.Network.sepolia : EthereumBalanceService.Network.ethereum
        let chainId = UInt64(network.chainId)
        
        // Get wallet address
        let address = try await wallet.getAddress()
        // Use print for unredacted address logging during debug
        print("📍 [TX DEBUG] Signing tx FROM address: \(address)")
        SecureLogger.debug("📍 Signing tx FROM address: \(address)", category: .session)
        
        // Get nonce from RPC if not provided
        let txNonce: UInt64
        if let providedNonce = nonce {
            txNonce = providedNonce
        } else {
            txNonce = try await fetchNonce(for: address, chainId: chainId)
        }
        SecureLogger.debug("📍 Using nonce: \(txNonce) for chain: \(chainId)", category: .session)
        
        // Gas parameters (EIP-1559)
        let gasLimit: UInt64 = 21000 // Standard ETH transfer
        let maxPriorityFeePerGas: UInt64 = 1_500_000_000 // 1.5 gwei
        let maxFeePerGas: UInt64 = 50_000_000_000 // 50 gwei
        
        // Sign the transaction
        let signedTx = try await wallet.signTransaction(
            chainId: chainId,
            nonce: txNonce,
            maxPriorityFeePerGas: maxPriorityFeePerGas,
            maxFeePerGas: maxFeePerGas,
            gasLimit: gasLimit,
            to: to,
            value: amountWei,
            data: Data()
        )
        
        // Create payload for mesh relay
        let payload = TxSignedPayload(
            signedTx: signedTx,
            chainId: chainId,
            nonce: txNonce,
            gasLimit: gasLimit,
            maxFeePerGas: maxFeePerGas,
            maxPriorityFee: maxPriorityFeePerGas,
            toAddress: to,
            replyToPeerId: replyToPeerId,
            description: description ?? "Transfer \(formatEth(amountWei)) to \(to.prefix(10))…",
            transactionType: "transfer",
            currency: network.symbol,
            amount: amountWei,
            decimals: 18
        )
        
        // Queue for mesh relay
        meshRelay.queueTransaction(payload)
        
        SecureLogger.info("📝 Signed and queued transfer: \(payload.requestId.prefix(8))… → \(to.prefix(10))…", category: .session)
        
        return payload.requestId
    }
    
    /// Sign and queue a contract call
    /// - Parameters:
    ///   - to: Contract address
    ///   - data: Encoded function call data
    ///   - value: Value to send (usually 0 for contract calls)
    ///   - gasLimit: Gas limit for the call
    ///   - nonce: Transaction nonce
    ///   - replyToPeerId: PeerID to send confirmation back to
    ///   - description: Human-readable description
    /// - Returns: The request ID for tracking
    func signAndQueueContractCall(
        to: String,
        data: Data,
        value: UInt64 = 0,
        gasLimit: UInt64 = 100000,
        nonce: UInt64? = nil,
        replyToPeerId: String,
        description: String? = nil,
        transactionType: String? = nil,
        currency: String? = nil,
        amount: UInt64? = nil,
        decimals: UInt8? = nil
    ) async throws -> String {
        let network = balanceService.useTestnet ? EthereumBalanceService.Network.sepolia : EthereumBalanceService.Network.ethereum
        let chainId = UInt64(network.chainId)
        
        // Get wallet address
        let address = try await wallet.getAddress()
        
        // Get nonce from RPC if not provided
        let txNonce: UInt64
        if let providedNonce = nonce {
            txNonce = providedNonce
        } else {
            txNonce = try await fetchNonce(for: address, chainId: chainId)
        }
        
        let maxPriorityFeePerGas: UInt64 = 1_500_000_000
        let maxFeePerGas: UInt64 = 50_000_000_000
        
        let signedTx = try await wallet.signTransaction(
            chainId: chainId,
            nonce: txNonce,
            maxPriorityFeePerGas: maxPriorityFeePerGas,
            maxFeePerGas: maxFeePerGas,
            gasLimit: gasLimit,
            to: to,
            value: value,
            data: data
        )
        
        let payload = TxSignedPayload(
            signedTx: signedTx,
            chainId: chainId,
            nonce: txNonce,
            gasLimit: gasLimit,
            maxFeePerGas: maxFeePerGas,
            maxPriorityFee: maxPriorityFeePerGas,
            toAddress: to,
            replyToPeerId: replyToPeerId,
            description: description,
            transactionType: transactionType,
            currency: currency,
            amount: amount,
            decimals: decimals
        )
        
        meshRelay.queueTransaction(payload)
        
        return payload.requestId
    }
    
    // MARK: - Helpers
    
    private func fetchNonce(for address: String, chainId: UInt64) async throws -> UInt64 {
        // Primary and fallback RPCs for each chain
        let rpcURLs: [String]
        switch chainId {
        case 1:
            rpcURLs = ["https://rpc.flashbots.net", "https://eth.llamarpc.com"]
        case 11155111:
            rpcURLs = ["https://sepolia.drpc.org", "https://rpc2.sepolia.org", "https://1rpc.io/sepolia"]
        case 8453:
            rpcURLs = ["https://mainnet.base.org", "https://base.llamarpc.com"]
        default:
            throw TransactionError.unsupportedChain
        }
        
        let requestBody: [String: Any] = [
            "jsonrpc": "2.0",
            "id": 1,
            "method": "eth_getTransactionCount",
            "params": [address, "pending"]
        ]
        
        var lastError: Error = TransactionError.rpcFailed
        
        for rpcURL in rpcURLs {
            guard let url = URL(string: rpcURL) else { continue }
            
            do {
                var request = URLRequest(url: url)
                request.httpMethod = "POST"
                request.setValue("application/json", forHTTPHeaderField: "Content-Type")
                request.httpBody = try JSONSerialization.data(withJSONObject: requestBody)
                request.timeoutInterval = 10
                
                let (data, _) = try await URLSession.shared.data(for: request)
                
                guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let result = json["result"] as? String else {
                    continue
                }
                
                // Parse hex nonce
                let hex = result.hasPrefix("0x") ? String(result.dropFirst(2)) : result
                guard let nonce = UInt64(hex, radix: 16) else {
                    continue
                }
                
                SecureLogger.debug("Got nonce \(nonce) from \(url.host ?? "unknown")", category: .session)
                return nonce
                
            } catch {
                SecureLogger.debug("Nonce fetch failed from \(url.host ?? "unknown"): \(error.localizedDescription)", category: .session)
                lastError = error
                continue
            }
        }
        
        throw lastError
    }
    
    private func formatEth(_ wei: UInt64) -> String {
        let eth = Double(wei) / 1e18
        if eth >= 0.001 {
            return String(format: "%.4f ETH", eth)
        } else {
            return "\(wei) wei"
        }
    }
}

// MARK: - Convenience Extension

extension XMTPServiceContainer {
    /// Create a transaction signer using container services
    func createTransactionSigner() -> TransactionSigner {
        TransactionSigner(
            wallet: wallet,
            meshRelay: meshTransactionRelay,
            balanceService: balanceService
        )
    }
}
