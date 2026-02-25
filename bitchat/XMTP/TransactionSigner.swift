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
import Tor

/// Service for signing and queueing transactions for mesh relay
@MainActor
final class TransactionSigner {
    private let wallet: EmbeddedWallet
    private let meshRelay: MeshTransactionRelay
    private let balanceService: EthereumBalanceService
    
    /// Persistent nonce cache key prefix (App Group)
    private static let nonceCacheKey = "wallet-nonce-cache"
    
    /// App Group UserDefaults for persistence
    private var appGroupDefaults: UserDefaults {
        UserDefaults(suiteName: BitchatApp.groupID) ?? .standard
    }
    
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
    ///   - maxPriorityFeePerGas: Priority fee in wei (default: 1.5 gwei)
    ///   - maxFeePerGas: Max fee per gas in wei (default: 30 gwei)
    ///   - replyToPeerId: PeerID to send confirmation back to
    ///   - description: Human-readable description
    /// - Returns: The request ID for tracking
    func signAndQueueTransfer(
        to: String,
        amountWei: UInt64,
        data: Data? = nil,
        nonce: UInt64? = nil,
        maxPriorityFeePerGas: UInt64? = nil,
        maxFeePerGas: UInt64? = nil,
        replyToPeerId: String,
        description: String? = nil,
        selectedNetwork: EthereumBalanceService.Network? = nil
    ) async throws -> String {
        // Determine active network — use explicit selection if provided, else default
        let network = selectedNetwork ?? (balanceService.useTestnet ? EthereumBalanceService.Network.sepolia : EthereumBalanceService.Network.ethereum)
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
        
        // Gas parameters (EIP-1559) - use provided values or defaults
        let priorityFee = maxPriorityFeePerGas ?? 1_500_000_000 // Default: 1.5 gwei
        let maxFee = maxFeePerGas ?? 30_000_000_000 // Default: 30 gwei
        
        // Estimate gas dynamically — contract wallets (PQ accounts) need more than 21000
        let gasLimit: UInt64
        let txData = data ?? Data()
        do {
            let estimated = try await estimateGas(
                from: address, to: to, value: amountWei, data: txData, chainId: chainId
            )
            // Add 20% buffer for safety
            gasLimit = max(estimated * 120 / 100, 21000)
            SecureLogger.debug("📍 Gas estimate: \(estimated) → using \(gasLimit) (with 20% buffer)", category: .session)
        } catch {
            // Fallback: use higher gas for token transfers (ERC-20 transfer ~65k)
            gasLimit = txData.isEmpty ? 21000 : 65000
            SecureLogger.warning("Gas estimation failed, using fallback \(gasLimit): \(error.localizedDescription)", category: .session)
        }
        
        // Sign the transaction
        let signedTx = try await wallet.signTransaction(
            chainId: chainId,
            nonce: txNonce,
            maxPriorityFeePerGas: priorityFee,
            maxFeePerGas: maxFee,
            gasLimit: gasLimit,
            to: to,
            value: amountWei,
            data: txData
        )
        
        // Create payload for mesh relay
        let payload = TxSignedPayload(
            signedTx: signedTx,
            chainId: chainId,
            nonce: txNonce,
            gasLimit: gasLimit,
            maxFeePerGas: maxFee,
            maxPriorityFee: priorityFee,
            toAddress: to,
            replyToPeerId: replyToPeerId,
            fromAddress: address,
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
    ///   - maxPriorityFeePerGas: Priority fee in wei (default: 1.5 gwei)
    ///   - maxFeePerGas: Max fee per gas in wei (default: 30 gwei)
    ///   - replyToPeerId: PeerID to send confirmation back to
    ///   - description: Human-readable description
    /// - Returns: The request ID for tracking
    func signAndQueueContractCall(
        to: String,
        data: Data,
        value: UInt64 = 0,
        gasLimit: UInt64 = 100000,
        nonce: UInt64? = nil,
        maxPriorityFeePerGas: UInt64? = nil,
        maxFeePerGas: UInt64? = nil,
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
        
        // Gas parameters - use provided values or defaults
        let priorityFee = maxPriorityFeePerGas ?? 1_500_000_000 // Default: 1.5 gwei
        let maxFee = maxFeePerGas ?? 30_000_000_000 // Default: 30 gwei
        
        let signedTx = try await wallet.signTransaction(
            chainId: chainId,
            nonce: txNonce,
            maxPriorityFeePerGas: priorityFee,
            maxFeePerGas: maxFee,
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
            maxFeePerGas: maxFee,
            maxPriorityFee: priorityFee,
            toAddress: to,
            replyToPeerId: replyToPeerId,
            fromAddress: address,
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
        // Tier 1: Try Helios verified nonce (Ethereum mainnet)
        if chainId == 1 || chainId == 11155111 {
            if await HeliosManager.shared.isRunning {
                do {
                    let nonce = try await HeliosManager.shared.getNonce(address: address, pending: true)
                    SecureLogger.debug("Got Helios-verified nonce \(nonce) for \(address.prefix(10))…", category: .session)
                    saveNonceToCache(nonce, for: address, chainId: chainId)
                    return nonce
                } catch {
                    SecureLogger.warning("Helios nonce fetch failed, falling back to RPC: \(error)", category: .session)
                }
            }
        }

        // Tier 2: Fallback to RPC over Tor
        let rpcURLs: [String]
        switch chainId {
        case 1:
            rpcURLs = ["https://rpc.flashbots.net", "https://eth.llamarpc.com"]
        case 11155111:
            rpcURLs = ["https://sepolia.drpc.org", "https://rpc2.sepolia.org", "https://1rpc.io/sepolia"]
        case 8453:
            rpcURLs = ["https://mainnet.base.org", "https://base.llamarpc.com"]
        case 42161:
            rpcURLs = ["https://arb1.arbitrum.io/rpc", "https://arbitrum.llamarpc.com", "https://rpc.ankr.com/arbitrum"]
        case 421614:
            rpcURLs = ["https://sepolia-rollup.arbitrum.io/rpc", "https://arbitrum-sepolia-rpc.publicnode.com"]
        default:
            // Even for unsupported chains, check cache before throwing
            if let cachedNonce = loadNonceFromCache(for: address, chainId: chainId) {
                let queuedOnChain = meshRelay.pendingRelays.filter {
                    $0.payload.fromAddress?.lowercased() == address.lowercased() &&
                    $0.payload.chainId == chainId
                }.count
                return cachedNonce + UInt64(queuedOnChain)
            }
            throw TransactionError.unsupportedChain
        }
        
        let requestBody: [String: Any] = [
            "jsonrpc": "2.0",
            "id": 1,
            "method": "eth_getTransactionCount",
            "params": [address, "pending"]
        ]
        
        // Use Tor for mainnet, direct for testnets
        let session = (chainId == 1 || chainId == 8453 || chainId == 42161) ? TorURLSession.shared.session : URLSession.shared

        var lastError: Error = TransactionError.rpcFailed
        
        for rpcURL in rpcURLs {
            guard let url = URL(string: rpcURL) else { continue }
            
            do {
                var request = URLRequest(url: url)
                request.httpMethod = "POST"
                request.setValue("application/json", forHTTPHeaderField: "Content-Type")
                request.httpBody = try JSONSerialization.data(withJSONObject: requestBody)
                request.timeoutInterval = 10
                
                let (data, _) = try await session.data(for: request)
                
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
                saveNonceToCache(nonce, for: address, chainId: chainId)
                return nonce
                
            } catch {
                SecureLogger.debug("Nonce fetch failed from \(url.host ?? "unknown"): \(error.localizedDescription)", category: .session)
                lastError = error
                continue
            }
        }
        
        // Tier 3: Offline fallback — use cached nonce + count of queued txs on same chain
        if let cachedNonce = loadNonceFromCache(for: address, chainId: chainId) {
            let queuedOnChain = meshRelay.pendingRelays.filter {
                $0.payload.fromAddress?.lowercased() == address.lowercased() &&
                $0.payload.chainId == chainId
            }.count
            let offlineNonce = cachedNonce + UInt64(queuedOnChain)
            SecureLogger.warning("📴 Using offline cached nonce \(cachedNonce) + \(queuedOnChain) queued = \(offlineNonce)", category: .session)
            return offlineNonce
        }
        
        throw lastError
    }
    
    // MARK: - Nonce Cache
    
    private func saveNonceToCache(_ nonce: UInt64, for address: String, chainId: UInt64) {
        let key = "\(Self.nonceCacheKey)-\(address.lowercased())-\(chainId)"
        appGroupDefaults.set(Int(nonce), forKey: key)
        appGroupDefaults.set(Date().timeIntervalSince1970, forKey: key + "-ts")
    }
    
    private func loadNonceFromCache(for address: String, chainId: UInt64) -> UInt64? {
        let key = "\(Self.nonceCacheKey)-\(address.lowercased())-\(chainId)"
        guard appGroupDefaults.object(forKey: key) != nil else { return nil }
        let nonce = UInt64(appGroupDefaults.integer(forKey: key))
        
        // Check staleness — only trust nonce cache up to 24 hours
        let ts = appGroupDefaults.double(forKey: key + "-ts")
        if ts > 0 {
            let age = Date().timeIntervalSince1970 - ts
            if age > 24 * 60 * 60 {
                SecureLogger.warning("Nonce cache too old (\(Int(age))s), discarding", category: .session)
                return nil
            }
        }
        
        return nonce
    }
    
    private func formatEth(_ wei: UInt64) -> String {
        let eth = Double(wei) / 1e18
        if eth >= 0.001 {
            return String(format: "%.4f ETH", eth)
        } else {
            return "\(wei) wei"
        }
    }
    
    /// Estimate gas for a transaction.
    ///
    /// Tier 1: Helios verified estimate (Ethereum mainnet/Sepolia).
    /// Tier 2: RPC over Tor (mainnet) or direct (testnet).
    ///
    /// For simple EOA→EOA ETH transfers this returns 21000.
    /// For transfers to smart contract wallets (e.g. PQ accounts), this returns
    /// a higher value because the contract's receive/fallback function executes code.
    private func estimateGas(from: String, to: String, value: UInt64, data: Data = Data(), chainId: UInt64) async throws -> UInt64 {
        // Tier 1: Try Helios verified gas estimation
        if (chainId == 1 || chainId == 11155111), await HeliosManager.shared.isRunning {
            do {
                var callObj: [String: String] = [
                    "from": from,
                    "to": to,
                    "value": String(format: "0x%llx", value),
                ]
                if !data.isEmpty {
                    callObj["data"] = "0x" + data.map { String(format: "%02x", $0) }.joined()
                }
                let callJSON = try String(data: JSONSerialization.data(withJSONObject: callObj), encoding: .utf8) ?? "{}"
                let gas = try await HeliosManager.shared.estimateGas(callJSON: callJSON)
                SecureLogger.debug("Helios gas estimate: \(gas)", category: .session)
                return gas
            } catch {
                SecureLogger.warning("Helios gas estimate failed, falling back to RPC: \(error)", category: .session)
            }
        }

        // Tier 2: Fallback to RPC over Tor
        let rpcURLs: [String]
        switch chainId {
        case 1:
            rpcURLs = ["https://rpc.flashbots.net", "https://eth.llamarpc.com"]
        case 11155111:
            rpcURLs = ["https://sepolia.drpc.org", "https://rpc2.sepolia.org", "https://1rpc.io/sepolia"]
        case 8453:
            rpcURLs = ["https://mainnet.base.org", "https://base.llamarpc.com"]
        case 42161:
            rpcURLs = ["https://arb1.arbitrum.io/rpc", "https://arbitrum.llamarpc.com", "https://rpc.ankr.com/arbitrum"]
        case 421614:
            rpcURLs = ["https://sepolia-rollup.arbitrum.io/rpc", "https://arbitrum-sepolia-rpc.publicnode.com"]
        default:
            throw TransactionError.unsupportedChain
        }
        
        var txObject: [String: String] = [
            "from": from,
            "to": to,
            "value": String(format: "0x%llx", value),
        ]
        if !data.isEmpty {
            txObject["data"] = "0x" + data.map { String(format: "%02x", $0) }.joined()
        }
        
        let requestBody: [String: Any] = [
            "jsonrpc": "2.0",
            "id": 1,
            "method": "eth_estimateGas",
            "params": [txObject]
        ]
        
        let session = (chainId == 1 || chainId == 8453 || chainId == 42161) ? TorURLSession.shared.session : URLSession.shared

        var lastError: Error = TransactionError.rpcFailed
        
        for rpcURL in rpcURLs {
            guard let url = URL(string: rpcURL) else { continue }
            
            do {
                var request = URLRequest(url: url)
                request.httpMethod = "POST"
                request.setValue("application/json", forHTTPHeaderField: "Content-Type")
                request.httpBody = try JSONSerialization.data(withJSONObject: requestBody)
                request.timeoutInterval = 10
                
                let (responseData, _) = try await session.data(for: request)
                
                guard let json = try JSONSerialization.jsonObject(with: responseData) as? [String: Any] else {
                    continue
                }
                
                // If the RPC returned an error (e.g. execution reverted), throw it
                if let error = json["error"] as? [String: Any],
                   let message = error["message"] as? String {
                    throw TransactionError.rpcError(message)
                }
                
                guard let result = json["result"] as? String else {
                    continue
                }
                
                let hex = result.hasPrefix("0x") ? String(result.dropFirst(2)) : result
                guard let gas = UInt64(hex, radix: 16) else {
                    continue
                }
                
                SecureLogger.debug("Gas estimate from \(url.host ?? "unknown"): \(gas)", category: .session)
                return gas
                
            } catch let error as TransactionError {
                throw error
            } catch {
                SecureLogger.debug("Gas estimation failed from \(url.host ?? "unknown"): \(error.localizedDescription)", category: .session)
                lastError = error
                continue
            }
        }
        
        throw lastError
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
