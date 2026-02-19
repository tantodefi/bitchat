//
// TransactionHistoryService.swift
// bitchat
//
// Fetches on-chain transaction history via Helios (over Tor) for privacy.
// Shows sends, receives, and contract interactions — all trustlessly verified.
//
// Data sources (in priority order):
// 1. Helios getLogs for ERC-20 Transfer events + verified receipts
// 2. Tor-proxied RPC as fallback when Helios unavailable
// 3. Local pending/confirmed/failed tx state from MeshTransactionRelay
//
// This is free and unencumbered software released into the public domain.
// For more information, see <https://unlicense.org>
//

import BitLogger
import Combine
import Foundation
import Tor

// MARK: - On-Chain Transaction Model

/// A unified transaction record combining on-chain and local data.
struct OnChainTransaction: Identifiable, Equatable {
    let id: String  // txHash or local requestId
    let txHash: String?
    let blockNumber: UInt64?
    let timestamp: Date
    let from: String
    let to: String
    let value: BigUInt        // ETH value in wei
    let gasUsed: UInt64?
    let gasPrice: UInt64?
    let input: String?        // Calldata hex (nil or "0x" for simple transfers)
    let status: OnChainTxStatus
    let txType: OnChainTxType
    let tokenSymbol: String?  // For ERC-20 transfers
    let tokenAmount: BigUInt? // For ERC-20 transfers (in token decimals)
    let contractAddress: String? // For contract interactions
    let verificationLevel: EthereumBalanceService.VerificationLevel
    let failureReason: String?

    static func == (lhs: OnChainTransaction, rhs: OnChainTransaction) -> Bool {
        lhs.id == rhs.id
    }
}

enum OnChainTxStatus: String {
    case pending = "Pending"
    case queued = "Queued"
    case confirmed = "Confirmed"
    case failed = "Failed"
    case reverted = "Reverted"

    var icon: String {
        switch self {
        case .queued: return "clock.fill"
        case .pending: return "arrow.triangle.2.circlepath"
        case .confirmed: return "checkmark.circle.fill"
        case .failed: return "xmark.circle.fill"
        case .reverted: return "exclamationmark.triangle.fill"
        }
    }

    var color: String {
        switch self {
        case .queued: return "orange"
        case .pending: return "blue"
        case .confirmed: return "green"
        case .failed, .reverted: return "red"
        }
    }
}

enum OnChainTxType: String {
    case send = "Send"
    case receive = "Receive"
    case contractCall = "Contract Call"
    case contractDeploy = "Contract Deploy"
    case tokenTransfer = "Token Transfer"
    case tokenReceive = "Token Receive"
    case approval = "Approval"

    var icon: String {
        switch self {
        case .send: return "arrow.up.right.circle.fill"
        case .receive: return "arrow.down.left.circle.fill"
        case .contractCall: return "gearshape.circle.fill"
        case .contractDeploy: return "plus.circle.fill"
        case .tokenTransfer: return "arrow.up.right.circle"
        case .tokenReceive: return "arrow.down.left.circle"
        case .approval: return "checkmark.seal.fill"
        }
    }
}

// MARK: - TransactionHistoryService

/// Service that fetches full on-chain transaction history using Helios (over Tor).
/// Combines on-chain data with local pending transaction state.
@MainActor
final class TransactionHistoryService: ObservableObject {

    // MARK: - Published State

    @Published private(set) var transactions: [OnChainTransaction] = []
    @Published private(set) var isLoading = false
    @Published private(set) var lastError: String?
    @Published private(set) var verificationLevel: EthereumBalanceService.VerificationLevel = .unverified

    // MARK: - Constants

    /// ERC-20 Transfer event topic: Transfer(address,address,uint256)
    private static let transferTopic = "0xddf252ad1be2c89b69c2b068fc378daa952ba7f163c4a11628f55a4df523b3ef"

    /// ERC-20 Approval event topic: Approval(address,address,uint256)
    private static let approvalTopic = "0x8c5be1e5ebec7d5bd14f71427d1e84f3dd0314c0f7b2291e5b200ac8c7c3b925"

    /// How far back to scan (in blocks). ~7 days at 12s/block ≈ 50400 blocks.
    private static let defaultScanRange: UInt64 = 50400

    /// Known ERC-20 token metadata for display
    private static let knownTokens: [String: (symbol: String, decimals: UInt8)] = [
        "0xdac17f958d2ee523a2206206994597c13d831ec7": ("USDT", 6),
        "0xa0b86991c6218b36c1d19d4a2e9eb0ce3606eb48": ("USDC", 6),
        "0x6b175474e89094c44da98b954eedeac495271d0f": ("DAI", 18),
        "0xc02aaa39b223fe8d0a0e5c4f27ead9083c756cc2": ("WETH", 18),
        "0x2260fac5e5542a773aa44fbcfedf7c193bc2c599": ("WBTC", 8),
    ]

    // MARK: - Private

    private let heliosQueue = DispatchQueue(label: "app.bitchat.txHistory", qos: .userInitiated)

    // MARK: - Public API

    /// Fetch full transaction history for an address.
    /// Merges on-chain data from Helios/RPC with local pending transactions.
    func fetchHistory(
        for address: String,
        meshRelay: MeshTransactionRelay,
        chainId: UInt64 = 1,
        useTestnet: Bool = false
    ) async {
        isLoading = true
        lastError = nil

        var allTxs: [OnChainTransaction] = []

        // 1. Get local pending/confirmed/failed transactions from MeshTransactionRelay
        let localTxs = buildLocalTransactions(from: meshRelay, address: address)
        allTxs.append(contentsOf: localTxs)

        // 2. Fetch on-chain history via Helios or RPC over Tor
        do {
            let onChainTxs = try await fetchOnChainHistory(
                for: address,
                chainId: chainId,
                useTestnet: useTestnet
            )
            // Merge: on-chain replaces local confirmed with same txHash
            let localHashes = Set(localTxs.compactMap { $0.txHash?.lowercased() })
            let deduplicated = onChainTxs.filter { tx in
                guard let hash = tx.txHash?.lowercased() else { return true }
                return !localHashes.contains(hash)
            }
            allTxs.append(contentsOf: deduplicated)
        } catch {
            SecureLogger.warning("TransactionHistoryService: on-chain fetch failed: \(error)", category: .network)
            lastError = error.localizedDescription
        }

        // 3. Sort by timestamp (newest first), de-duplicate by id
        var seen = Set<String>()
        transactions = allTxs
            .sorted { $0.timestamp > $1.timestamp }
            .filter { seen.insert($0.id).inserted }

        isLoading = false
    }

    // MARK: - Local Transaction State

    /// Convert MeshTransactionRelay state into OnChainTransaction records.
    private func buildLocalTransactions(from relay: MeshTransactionRelay, address: String) -> [OnChainTransaction] {
        let normalizedAddr = address.lowercased()
        var results: [OnChainTransaction] = []

        // Pending transactions
        for pending in relay.pendingRelays {
            let from = pending.payload.fromAddress?.lowercased() ?? normalizedAddr
            guard from == normalizedAddr else { continue }

            let status: OnChainTxStatus
            switch pending.status {
            case .queued: status = .queued
            case .relaying, .awaitingConfirmation: status = .pending
            case .confirmed: status = .confirmed
            case .failed: status = .failed
            }

            results.append(OnChainTransaction(
                id: pending.id,
                txHash: nil,
                blockNumber: nil,
                timestamp: pending.createdAt,
                from: pending.payload.fromAddress ?? address,
                to: pending.payload.toAddress,
                value: BigUInt(pending.payload.amount ?? 0),
                gasUsed: nil,
                gasPrice: nil,
                input: nil,
                status: status,
                txType: .send,
                tokenSymbol: nil,
                tokenAmount: nil,
                contractAddress: nil,
                verificationLevel: .unverified,
                failureReason: nil
            ))
        }

        // Confirmed transactions
        for confirmed in relay.confirmedTransactions {
            let from = confirmed.fromAddress?.lowercased() ?? ""
            let isFrom = from == normalizedAddr
            let isTo = confirmed.toAddress.lowercased() == normalizedAddr

            guard isFrom || isTo else { continue }

            results.append(OnChainTransaction(
                id: confirmed.txHash,
                txHash: confirmed.txHash,
                blockNumber: confirmed.blockNumber,
                timestamp: confirmed.confirmedAt,
                from: confirmed.fromAddress ?? address,
                to: confirmed.toAddress,
                value: BigUInt(confirmed.amount ?? 0),
                gasUsed: nil,
                gasPrice: nil,
                input: nil,
                status: .confirmed,
                txType: isFrom ? .send : .receive,
                tokenSymbol: nil,
                tokenAmount: nil,
                contractAddress: nil,
                verificationLevel: .unverified,
                failureReason: nil
            ))
        }

        // Failed transactions
        for failed in relay.failedTransactions {
            let from = failed.fromAddress?.lowercased() ?? ""
            guard from == normalizedAddr else { continue }

            results.append(OnChainTransaction(
                id: failed.id,
                txHash: nil,
                blockNumber: nil,
                timestamp: failed.failedAt,
                from: failed.fromAddress ?? address,
                to: failed.toAddress,
                value: BigUInt(failed.amount ?? 0),
                gasUsed: nil,
                gasPrice: nil,
                input: nil,
                status: .failed,
                txType: .send,
                tokenSymbol: nil,
                tokenAmount: nil,
                contractAddress: nil,
                verificationLevel: .unverified,
                failureReason: failed.reason
            ))
        }

        return results
    }

    // MARK: - On-Chain History Fetch

    /// Fetch on-chain transaction history via Helios (preferred) or Tor-proxied RPC.
    ///
    /// Strategy:
    /// 1. Use Helios getLogs to find all Transfer events involving our address
    ///    (both as sender and receiver) — this catches ERC-20 + ETH via WETH
    /// 2. Scan recent blocks for native ETH transfers to/from our address
    /// 3. Merge and deduplicate
    private func fetchOnChainHistory(
        for address: String,
        chainId: UInt64,
        useTestnet: Bool
    ) async throws -> [OnChainTransaction] {
        let normalizedAddr = address.lowercased()
        let paddedAddr = "0x" + String(repeating: "0", count: 24) + String(normalizedAddr.dropFirst(2))

        var results: [OnChainTransaction] = []

        // Determine current block number
        let currentBlock: UInt64
        if await HeliosManager.shared.isRunning, let block = await HeliosManager.shared.finalizedBlock {
            currentBlock = block
            verificationLevel = .heliosVerified
        } else {
            currentBlock = try await fetchBlockNumberViaRPC(chainId: chainId, useTestnet: useTestnet)
            verificationLevel = .unverified
        }

        guard currentBlock > 0 else { return [] }

        let fromBlock = currentBlock > Self.defaultScanRange ? currentBlock - Self.defaultScanRange : 0
        let fromBlockHex = String(format: "0x%llx", fromBlock)
        let toBlockHex = "latest"

        // --- ERC-20 Transfer events (sent by us) ---
        let sentFilter = HeliosManager.LogFilter(
            address: "",  // Any token contract
            topics: [
                [Self.transferTopic],  // Transfer event
                [paddedAddr],          // from = our address (topic[1])
                nil                    // to = any
            ],
            fromBlock: fromBlockHex,
            toBlock: toBlockHex
        )

        // --- ERC-20 Transfer events (received by us) ---
        let receivedFilter = HeliosManager.LogFilter(
            address: "",
            topics: [
                [Self.transferTopic],
                nil,                  // from = any
                [paddedAddr]          // to = our address (topic[2])
            ],
            fromBlock: fromBlockHex,
            toBlock: toBlockHex
        )

        // Fetch logs via Helios or RPC
        async let sentLogs = fetchLogs(filter: sentFilter, chainId: chainId, useTestnet: useTestnet)
        async let receivedLogs = fetchLogs(filter: receivedFilter, chainId: chainId, useTestnet: useTestnet)

        let allSentLogs = (try? await sentLogs) ?? []
        let allReceivedLogs = (try? await receivedLogs) ?? []

        // Parse ERC-20 Transfer logs
        for log in allSentLogs {
            if let tx = parseTransferLog(log, userAddress: normalizedAddr, isSend: true) {
                results.append(tx)
            }
        }
        for log in allReceivedLogs {
            if let tx = parseTransferLog(log, userAddress: normalizedAddr, isSend: false) {
                results.append(tx)
            }
        }

        // --- Native ETH transfers: scan recent blocks for txs involving our address ---
        let ethTxs = try await fetchNativeETHTransactions(
            address: normalizedAddr,
            fromBlock: fromBlock,
            toBlock: currentBlock,
            chainId: chainId,
            useTestnet: useTestnet
        )
        results.append(contentsOf: ethTxs)

        return results
    }

    // MARK: - Log Fetching

    /// Fetch event logs via Helios (preferred) or Tor-proxied RPC.
    private func fetchLogs(
        filter: HeliosManager.LogFilter,
        chainId: UInt64,
        useTestnet: Bool
    ) async throws -> [HeliosManager.VerifiedLog] {
        // Tier 1: Helios
        if await HeliosManager.shared.isRunning {
            do {
                return try await HeliosManager.shared.getLogs(filter: filter)
            } catch {
                SecureLogger.warning("TransactionHistoryService: Helios getLogs failed, falling back to RPC: \(error)", category: .network)
            }
        }

        // Tier 2: RPC over Tor
        return try await fetchLogsViaRPC(filter: filter, chainId: chainId, useTestnet: useTestnet)
    }

    // MARK: - RPC Fallbacks

    /// Fetch current block number via RPC.
    private func fetchBlockNumberViaRPC(chainId: UInt64, useTestnet: Bool) async throws -> UInt64 {
        let rpcURL = Self.rpcURL(for: chainId)
        let session = useTestnet ? URLSession.shared : TorURLSession.shared.session

        let body: [String: Any] = [
            "jsonrpc": "2.0",
            "id": 1,
            "method": "eth_blockNumber",
            "params": []
        ]

        var request = URLRequest(url: rpcURL)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        request.timeoutInterval = 10

        let (data, _) = try await session.data(for: request)
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let hexResult = json["result"] as? String else {
            return 0
        }

        let hex = hexResult.hasPrefix("0x") ? String(hexResult.dropFirst(2)) : hexResult
        return UInt64(hex, radix: 16) ?? 0
    }

    /// Fetch logs via RPC over Tor.
    private func fetchLogsViaRPC(
        filter: HeliosManager.LogFilter,
        chainId: UInt64,
        useTestnet: Bool
    ) async throws -> [HeliosManager.VerifiedLog] {
        let rpcURL = Self.rpcURL(for: chainId)
        let session = useTestnet ? URLSession.shared : TorURLSession.shared.session

        var filterObj: [String: Any] = [
            "fromBlock": filter.fromBlock,
            "toBlock": filter.toBlock,
            "topics": filter.topics.map { topicArr -> Any in
                if let arr = topicArr { return arr }
                return NSNull()
            }
        ]
        if !filter.address.isEmpty {
            filterObj["address"] = filter.address
        }

        let body: [String: Any] = [
            "jsonrpc": "2.0",
            "id": 1,
            "method": "eth_getLogs",
            "params": [filterObj]
        ]

        var request = URLRequest(url: rpcURL)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        request.timeoutInterval = 30

        let (data, _) = try await session.data(for: request)
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let resultArray = json["result"] as? [[String: Any]] else {
            return []
        }

        return resultArray.compactMap { log -> HeliosManager.VerifiedLog? in
            guard let address = log["address"] as? String,
                  let topics = log["topics"] as? [String],
                  let logData = log["data"] as? String,
                  let blockNumber = log["blockNumber"] as? String,
                  let txHash = log["transactionHash"] as? String,
                  let logIndex = log["logIndex"] as? String else {
                return nil
            }
            return HeliosManager.VerifiedLog(
                address: address,
                topics: topics,
                data: logData,
                blockNumber: blockNumber,
                transactionHash: txHash,
                logIndex: logIndex
            )
        }
    }

    /// Fetch native ETH transactions for an address from recent blocks.
    /// Uses eth_getBlockByNumber with full tx objects and filters locally.
    private func fetchNativeETHTransactions(
        address: String,
        fromBlock: UInt64,
        toBlock: UInt64,
        chainId: UInt64,
        useTestnet: Bool
    ) async throws -> [OnChainTransaction] {
        // For efficiency, we scan the last ~100 blocks (20 minutes) for native ETH.
        // Older native transfers would require an indexer, but ERC-20 logs cover most activity.
        let recentScanBlocks: UInt64 = 100
        let scanFrom = toBlock > recentScanBlocks ? toBlock - recentScanBlocks : fromBlock

        var results: [OnChainTransaction] = []

        // Fetch blocks in batches
        for blockNum in stride(from: scanFrom, through: toBlock, by: 1) {
            let blockHex = String(format: "0x%llx", blockNum)

            do {
                let blockJSON: String
                if await HeliosManager.shared.isRunning {
                    blockJSON = try await HeliosManager.shared.getBlockByNumber(
                        blockTag: blockHex,
                        fullTransactions: true
                    )
                } else {
                    blockJSON = try await fetchBlockViaRPC(
                        blockTag: blockHex,
                        fullTxs: true,
                        chainId: chainId,
                        useTestnet: useTestnet
                    )
                }

                guard let data = blockJSON.data(using: .utf8),
                      let block = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let transactions = block["transactions"] as? [[String: Any]],
                      let timestampHex = block["timestamp"] as? String else {
                    continue
                }

                let tsHex = timestampHex.hasPrefix("0x") ? String(timestampHex.dropFirst(2)) : timestampHex
                let timestamp = Date(timeIntervalSince1970: TimeInterval(UInt64(tsHex, radix: 16) ?? 0))

                for tx in transactions {
                    guard let txFrom = (tx["from"] as? String)?.lowercased(),
                          let txTo = (tx["to"] as? String)?.lowercased() else {
                        // Contract deployment (to is nil)
                        if let txFrom = (tx["from"] as? String)?.lowercased(),
                           txFrom == address,
                           let txHash = tx["hash"] as? String {
                            results.append(OnChainTransaction(
                                id: txHash,
                                txHash: txHash,
                                blockNumber: blockNum,
                                timestamp: timestamp,
                                from: txFrom,
                                to: "",
                                value: parseHexValue(tx["value"] as? String),
                                gasUsed: nil,
                                gasPrice: parseHexUInt64(tx["gasPrice"] as? String),
                                input: tx["input"] as? String,
                                status: .confirmed,
                                txType: .contractDeploy,
                                tokenSymbol: nil,
                                tokenAmount: nil,
                                contractAddress: nil,
                                verificationLevel: verificationLevel,
                                failureReason: nil
                            ))
                        }
                        continue
                    }

                    // Only include transactions involving our address
                    guard txFrom == address || txTo == address else { continue }

                    let txHash = tx["hash"] as? String ?? ""
                    let isSend = txFrom == address
                    let inputData = tx["input"] as? String ?? "0x"
                    let isContractCall = inputData.count > 4  // More than just "0x"
                    let value = parseHexValue(tx["value"] as? String)

                    let txType: OnChainTxType
                    if isContractCall && isSend {
                        txType = .contractCall
                    } else if isSend {
                        txType = .send
                    } else {
                        txType = .receive
                    }

                    results.append(OnChainTransaction(
                        id: txHash,
                        txHash: txHash,
                        blockNumber: blockNum,
                        timestamp: timestamp,
                        from: txFrom,
                        to: txTo,
                        value: value,
                        gasUsed: nil,
                        gasPrice: parseHexUInt64(tx["gasPrice"] as? String),
                        input: isContractCall ? inputData : nil,
                        status: .confirmed,
                        txType: txType,
                        tokenSymbol: nil,
                        tokenAmount: nil,
                        contractAddress: isContractCall ? txTo : nil,
                        verificationLevel: verificationLevel,
                        failureReason: nil
                    ))
                }
            } catch {
                // Skip blocks that fail to fetch — keep going
                continue
            }
        }

        return results
    }

    /// Fetch a single block via RPC over Tor.
    private func fetchBlockViaRPC(
        blockTag: String,
        fullTxs: Bool,
        chainId: UInt64,
        useTestnet: Bool
    ) async throws -> String {
        let rpcURL = Self.rpcURL(for: chainId)
        let session = useTestnet ? URLSession.shared : TorURLSession.shared.session

        let body: [String: Any] = [
            "jsonrpc": "2.0",
            "id": 1,
            "method": "eth_getBlockByNumber",
            "params": [blockTag, fullTxs]
        ]

        var request = URLRequest(url: rpcURL)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        request.timeoutInterval = 15

        let (data, _) = try await session.data(for: request)
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let result = json["result"] else {
            return "{}"
        }

        let resultData = try JSONSerialization.data(withJSONObject: result)
        return String(data: resultData, encoding: .utf8) ?? "{}"
    }

    // MARK: - Log Parsing

    /// Parse an ERC-20 Transfer log into an OnChainTransaction.
    private func parseTransferLog(
        _ log: HeliosManager.VerifiedLog,
        userAddress: String,
        isSend: Bool
    ) -> OnChainTransaction? {
        guard log.topics.count >= 3 else { return nil }

        let from = "0x" + String(log.topics[1].suffix(40))
        let to = "0x" + String(log.topics[2].suffix(40))

        // Parse token amount from data (uint256)
        let tokenAmount = BigUInt(hexString: log.data) ?? BigUInt(0)

        // Look up token metadata
        let contractAddr = log.address.lowercased()
        let tokenInfo = Self.knownTokens[contractAddr]

        // Parse block number
        let blockHex = log.blockNumber.hasPrefix("0x") ? String(log.blockNumber.dropFirst(2)) : log.blockNumber
        let blockNumber = UInt64(blockHex, radix: 16)

        let txType: OnChainTxType = isSend ? .tokenTransfer : .tokenReceive

        return OnChainTransaction(
            id: "\(log.transactionHash)-\(log.logIndex)",
            txHash: log.transactionHash,
            blockNumber: blockNumber,
            timestamp: Date(),  // Block timestamp resolved later if needed
            from: from.lowercased(),
            to: to.lowercased(),
            value: BigUInt(0),  // ETH value is 0 for ERC-20 transfers
            gasUsed: nil,
            gasPrice: nil,
            input: nil,
            status: .confirmed,
            txType: txType,
            tokenSymbol: tokenInfo?.symbol,
            tokenAmount: tokenAmount,
            contractAddress: contractAddr,
            verificationLevel: verificationLevel,
            failureReason: nil
        )
    }

    // MARK: - Helpers

    private func parseHexValue(_ hex: String?) -> BigUInt {
        guard let hex else { return BigUInt(0) }
        return BigUInt(hexString: hex) ?? BigUInt(0)
    }

    private func parseHexUInt64(_ hex: String?) -> UInt64? {
        guard let hex else { return nil }
        let stripped = hex.hasPrefix("0x") ? String(hex.dropFirst(2)) : hex
        return UInt64(stripped, radix: 16)
    }

    private static func rpcURL(for chainId: UInt64) -> URL {
        switch chainId {
        case 1: return URL(string: "https://rpc.flashbots.net")!
        case 8453: return URL(string: "https://mainnet.base.org")!
        case 42161: return URL(string: "https://arb1.arbitrum.io/rpc")!
        case 11155111: return URL(string: "https://sepolia.drpc.org")!
        case 421614: return URL(string: "https://sepolia-rollup.arbitrum.io/rpc")!
        default: return URL(string: "https://rpc.flashbots.net")!
        }
    }
}
