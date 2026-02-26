//
// TransactionHistoryService.swift
// bitchat
//
// Multi-strategy on-chain transaction history via Helios (over Tor) for privacy.
// Reconstructs full history trustlessly — no Etherscan, no centralized indexer.
//
// Data sources (in priority order):
// 1. Persistent TransactionStore — cached hashes from prior sessions
// 2. Helios getTransactionReceipt — verified receipt for every known hash
// 3. Helios getLogs — ERC-20 Transfer/Approval events for the address
// 4. Helios getBlockByNumber — native ETH transfers via block scanning
// 5. Nonce-based gap detection — compares known sent tx count vs on-chain nonce
// 6. ERC-4337 UserOperationEvent logs — PQ smart account transactions
// 7. Local MeshTransactionRelay state — pending, confirmed, failed txs
// 8. Tor-proxied RPC as fallback when Helios unavailable
//
// All discovered transactions are persisted to TransactionStore so they
// survive app restarts and are never lost once found.
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
    let chainId: UInt64       // Chain ID (1=mainnet, 11155111=sepolia, 421614=arb sepolia, etc.)

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

/// Multi-strategy transaction history service using Helios (over Tor).
///
/// **Strategy overview (executed in order):**
/// 1. Load cached tx hashes from `TransactionStore` (instant, no network)
/// 2. Merge local pending/confirmed/failed from `MeshTransactionRelay`
/// 3. Fetch verified receipts for ALL known hashes via Helios `getTransactionReceipt`
/// 4. Scan ERC-20 Transfer/Approval logs via Helios `getLogs` (~7 day window)
/// 5. Scan ERC-4337 UserOperationEvent logs for PQ account transactions
/// 6. Scan recent blocks for native ETH transfers (adaptive range)
/// 7. Detect nonce gaps → expand scan range if we're missing sent txs
/// 8. Cache all newly discovered txs to `TransactionStore` for next session
///
/// **Privacy:** No Etherscan, no centralized indexer. All data flows through
/// either Helios (cryptographically verified) or Tor-proxied RPC.
@MainActor
final class TransactionHistoryService: ObservableObject {

    // MARK: - Published State

    @Published private(set) var transactions: [OnChainTransaction] = []
    @Published private(set) var isLoading = false
    @Published private(set) var lastError: String?
    @Published private(set) var verificationLevel: EthereumBalanceService.VerificationLevel = .unverified
    @Published private(set) var discoveryProgress: String = ""

    // MARK: - Constants

    /// ERC-20 Transfer event topic: Transfer(address,address,uint256)
    private static let transferTopic = "0xddf252ad1be2c89b69c2b068fc378daa952ba7f163c4a11628f55a4df523b3ef"

    /// ERC-20 Approval event topic: Approval(address,address,uint256)
    private static let approvalTopic = "0x8c5be1e5ebec7d5bd14f71427d1e84f3dd0314c0f7b2291e5b200ac8c7c3b925"

    /// ERC-4337 v0.7 EntryPoint UserOperationEvent topic:
    /// UserOperationEvent(bytes32 indexed userOpHash, address indexed sender, address indexed paymaster, uint256 nonce, bool success, uint256 actualGasCost, uint256 actualGasUsed)
    private static let userOperationEventTopic = "0x49628fd1471006c1482da88028e9ce4dbb080b815c9b0344d39e5a8e6ec1419f"

    /// ERC-4337 v0.7 EntryPoint address (same on all chains)
    private static let entryPointV07 = "0x0000000071727De22E5E9d8BAf0edAc6f37da032"

    /// How far back to scan for ERC-20 logs (in blocks). ~7 days at 12s/block.
    private static let defaultLogScanRange: UInt64 = 50400

    /// How far back to scan blocks for native ETH transfers.
    /// Adaptive: starts at 500 blocks (~1.5h), expands if nonce gap detected.
    private static let defaultBlockScanRange: UInt64 = 500

    /// Maximum blocks to scan for native ETH when nonce gap detected.
    private static let maxBlockScanRange: UInt64 = 5000

    /// Concurrent block fetch batch size
    private static let blockFetchBatchSize = 20

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
    ///
    /// Multi-strategy approach:
    /// 1. Cached transactions from TransactionStore (survives restarts)
    /// 2. Local pending/confirmed/failed from MeshTransactionRelay
    /// 3. Verified receipts for all known tx hashes
    /// 4. On-chain event log scanning (ERC-20 + ERC-4337)
    /// 5. Native ETH block scanning (adaptive range)
    /// 6. Nonce gap detection with expanded scanning
    /// 7. Persists all newly discovered transactions
    func fetchHistory(
        for address: String,
        meshRelay: MeshTransactionRelay,
        chainId: UInt64 = 1,
        useTestnet: Bool = false,
        pqAddress: String? = nil
    ) async {
        isLoading = true
        lastError = nil
        discoveryProgress = "Loading cached history…"

        var allTxs: [OnChainTransaction] = []
        let normalizedAddr = address.lowercased()

        // ── Step 1: Load cached transactions from persistent store ──
        let store = TransactionStore.shared
        let cachedTxs = store.allTransactions(for: normalizedAddr)
        let cachedHashes = Set(cachedTxs.map { $0.txHash.lowercased() })
        SecureLogger.info("TransactionHistoryService: \(cachedTxs.count) cached tx hashes loaded", category: .network)

        // ── Step 1b: Materialize PQ account cached transactions directly ──
        // PQ sends store userOpHash (not blockchain txHash), so receipt lookup
        // will fail for them. We materialize them as display objects immediately.
        let pqCachedTxs = cachedTxs.filter { $0.source == .pqAccount || $0.source == .pqDeploy }
        for pqTx in pqCachedTxs {
            let weiValue = BigUInt(hexString: pqTx.value) ?? BigUInt(0)
            let isDeploy = pqTx.source == .pqDeploy
            allTxs.append(OnChainTransaction(
                id: pqTx.id,
                txHash: pqTx.txHash,
                blockNumber: pqTx.blockNumber,
                timestamp: pqTx.timestamp,
                from: pqTx.from,
                to: pqTx.to,
                value: weiValue,
                gasUsed: nil,
                gasPrice: nil,
                input: nil,
                status: .confirmed,
                txType: isDeploy ? .contractDeploy : (!weiValue.isZero ? .send : .contractCall),
                tokenSymbol: nil,
                tokenAmount: nil,
                contractAddress: isDeploy ? pqTx.to : nil,
                verificationLevel: .unverified,
                failureReason: nil,
                chainId: pqTx.chainId
            ))
        }

        // ── Step 2: Local pending/confirmed/failed from MeshTransactionRelay ──
        discoveryProgress = "Loading local transactions…"
        let localTxs = buildLocalTransactions(from: meshRelay, address: address)
        allTxs.append(contentsOf: localTxs)

        // Also persist local confirmed txs that have hashes (so they survive relay clear)
        let localConfirmedWithHash = localTxs.filter { $0.txHash != nil && $0.status == .confirmed }
        let newLocalCached = localConfirmedWithHash.compactMap { tx -> CachedTransaction? in
            guard let hash = tx.txHash else { return nil }
            guard !cachedHashes.contains(hash.lowercased()) else { return nil }
            return CachedTransaction(
                id: hash,
                txHash: hash,
                from: tx.from.lowercased(),
                to: tx.to.lowercased(),
                value: tx.value.hexString,
                timestamp: tx.timestamp,
                blockNumber: tx.blockNumber,
                chainId: chainId,
                source: .meshRelay
            )
        }
        store.recordBatch(newLocalCached, for: normalizedAddr)

        // Publish cached + local transactions immediately so the UI shows
        // data right away even when offline. Network steps below will update.
        do {
            var seen = Set<String>()
            transactions = allTxs
                .sorted { $0.timestamp > $1.timestamp }
                .filter { seen.insert($0.id).inserted }
        }

        // ── Step 3: Fetch verified receipts for all known tx hashes ──
        // Exclude PQ cached hashes — they are userOpHashes, not real txHashes,
        // so eth_getTransactionReceipt will return null and waste RPC calls.
        discoveryProgress = "Verifying known transactions…"
        let pqHashSet = Set(pqCachedTxs.map { $0.txHash.lowercased() })
        let allKnownHashes = cachedHashes.union(Set(localTxs.compactMap { $0.txHash?.lowercased() })).subtracting(pqHashSet)

        if !allKnownHashes.isEmpty {
            let receiptTxs = await fetchReceiptsForKnownHashes(
                hashes: allKnownHashes,
                address: normalizedAddr,
                chainId: chainId,
                useTestnet: useTestnet,
                pqAddress: pqAddress
            )
            allTxs.append(contentsOf: receiptTxs)
            SecureLogger.info("TransactionHistoryService: \(receiptTxs.count) txs from receipt lookup", category: .network)
        }

        // ── Step 4: On-chain event scanning + block scanning ──
        do {
            discoveryProgress = "Scanning on-chain events…"
            let onChainTxs = try await fetchOnChainHistory(
                for: address,
                chainId: chainId,
                useTestnet: useTestnet,
                pqAddress: pqAddress
            )

            // Merge: deduplicate against what we already have
            let existingHashes = Set(allTxs.compactMap { $0.txHash?.lowercased() })
            let deduplicated = onChainTxs.filter { tx in
                guard let hash = tx.txHash?.lowercased() else { return true }
                return !existingHashes.contains(hash)
            }
            allTxs.append(contentsOf: deduplicated)

            // Cache newly discovered on-chain txs
            let newOnChainCached = deduplicated.compactMap { tx -> CachedTransaction? in
                guard let hash = tx.txHash else { return nil }
                return CachedTransaction(
                    id: hash,
                    txHash: hash,
                    from: tx.from.lowercased(),
                    to: tx.to.lowercased(),
                    value: tx.value.hexString,
                    timestamp: tx.timestamp,
                    blockNumber: tx.blockNumber,
                    chainId: chainId,
                    source: .onChainScan
                )
            }
            store.recordBatch(newOnChainCached, for: normalizedAddr)
            SecureLogger.info("TransactionHistoryService: \(onChainTxs.count) txs from on-chain scan, \(newOnChainCached.count) newly cached", category: .network)
        } catch {
            SecureLogger.warning("TransactionHistoryService: on-chain fetch failed: \(error)", category: .network)
            lastError = error.localizedDescription
        }

        // ── Step 5: Sort, deduplicate, and publish ──
        discoveryProgress = ""
        var seen = Set<String>()
        transactions = allTxs
            .sorted { $0.timestamp > $1.timestamp }
            .filter { seen.insert($0.id).inserted }

        SecureLogger.info("TransactionHistoryService: \(transactions.count) total transactions", category: .network)
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
                failureReason: nil,
                chainId: pending.payload.chainId
            ))
        }

        // Confirmed transactions
        for confirmed in relay.confirmedTransactions {
            let from = confirmed.fromAddress?.lowercased() ?? normalizedAddr
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
                failureReason: nil,
                chainId: confirmed.chainId
            ))
        }

        // Failed transactions
        for failed in relay.failedTransactions {
            let from = failed.fromAddress?.lowercased() ?? normalizedAddr
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
                failureReason: failed.reason,
                chainId: failed.chainId
            ))
        }

        return results
    }

    // MARK: - Receipt-Based Enrichment

    /// Fetch verified transaction receipts for all known tx hashes.
    /// This is the most reliable way to reconstruct history — if we have the hash,
    /// Helios can verify the full receipt against the consensus-attested state root.
    private func fetchReceiptsForKnownHashes(
        hashes: Set<String>,
        address: String,
        chainId: UInt64,
        useTestnet: Bool,
        pqAddress: String? = nil
    ) async -> [OnChainTransaction] {
        var results: [OnChainTransaction] = []
        let heliosAvailable = await HeliosManager.shared.isRunning

        // Fetch receipts concurrently in batches to avoid overwhelming Helios
        let hashArray = Array(hashes)
        let batchSize = 10

        for batchStart in stride(from: 0, to: hashArray.count, by: batchSize) {
            let batchEnd = min(batchStart + batchSize, hashArray.count)
            let batch = Array(hashArray[batchStart..<batchEnd])

            await withTaskGroup(of: OnChainTransaction?.self) { group in
                for txHash in batch {
                    group.addTask { [weak self] in
                        guard let self else { return nil }
                        return await self.fetchAndParseReceipt(
                            txHash: txHash,
                            address: address,
                            chainId: chainId,
                            useTestnet: useTestnet,
                            heliosAvailable: heliosAvailable,
                            pqAddress: pqAddress
                        )
                    }
                }
                for await tx in group {
                    if let tx { results.append(tx) }
                }
            }
        }

        if heliosAvailable && !results.isEmpty {
            verificationLevel = .heliosVerified
        }
        return results
    }

    /// Fetch a single transaction receipt and parse it into an OnChainTransaction.
    private func fetchAndParseReceipt(
        txHash: String,
        address: String,
        chainId: UInt64,
        useTestnet: Bool,
        heliosAvailable: Bool,
        pqAddress: String? = nil
    ) async -> OnChainTransaction? {
        do {
            let receiptJSON: String
            if heliosAvailable {
                receiptJSON = try await HeliosManager.shared.getTransactionReceipt(txHash: txHash)
            } else {
                receiptJSON = try await fetchReceiptViaRPC(txHash: txHash, chainId: chainId, useTestnet: useTestnet)
            }

            guard let data = receiptJSON.data(using: .utf8),
                  let receipt = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                return nil
            }

            // Parse receipt fields
            let from = (receipt["from"] as? String)?.lowercased() ?? ""
            let to = (receipt["to"] as? String)?.lowercased() ?? ""
            let statusHex = receipt["status"] as? String ?? "0x1"
            let isSuccess = statusHex != "0x0"

            let blockHex = receipt["blockNumber"] as? String ?? "0x0"
            let blockStr = blockHex.hasPrefix("0x") ? String(blockHex.dropFirst(2)) : blockHex
            let blockNumber = UInt64(blockStr, radix: 16) ?? 0

            let gasUsedHex = receipt["gasUsed"] as? String
            let gasUsed = parseHexUInt64(gasUsedHex)

            let effectiveGasPriceHex = receipt["effectiveGasPrice"] as? String
            let gasPrice = parseHexUInt64(effectiveGasPriceHex)

            // Determine tx type based on from/to relationship to our address.
            // Also accept PQ smart account address — ERC-4337 UserOps are sent by
            // the bundler's EOA to the EntryPoint contract, so from/to won't match
            // the user's EOA. But the PQ address may appear in internal traces/logs.
            let normalizedAddr = address.lowercased()
            let normalizedPQ = pqAddress?.lowercased()
            let isSend = from == normalizedAddr || from == normalizedPQ
            let isReceive = to == normalizedAddr || to == normalizedPQ
            guard isSend || isReceive else { return nil }

            // Try to get the actual tx value by fetching block timestamp too
            let timestamp = await fetchBlockTimestamp(
                blockNumber: blockNumber,
                chainId: chainId,
                useTestnet: useTestnet,
                heliosAvailable: heliosAvailable
            ) ?? Date()

            // Check if this is a contract interaction (has logs or to-address has code)
            let logs = receipt["logs"] as? [[String: Any]] ?? []
            let hasCalldata = to.isEmpty || !logs.isEmpty

            let txType: OnChainTxType
            if to.isEmpty {
                txType = .contractDeploy
            } else if hasCalldata && logs.count > 0 && isSend {
                txType = .contractCall
            } else if isSend {
                txType = .send
            } else {
                txType = .receive
            }

            let level: EthereumBalanceService.VerificationLevel = heliosAvailable ? .heliosVerified : .unverified

            return OnChainTransaction(
                id: txHash.lowercased(),
                txHash: txHash,
                blockNumber: blockNumber,
                timestamp: timestamp,
                from: from,
                to: to,
                value: BigUInt(0), // Receipt doesn't include value; will be overridden if found in block scan
                gasUsed: gasUsed,
                gasPrice: gasPrice,
                input: nil,
                status: isSuccess ? .confirmed : .reverted,
                txType: txType,
                tokenSymbol: nil,
                tokenAmount: nil,
                contractAddress: hasCalldata && !to.isEmpty ? to : nil,
                verificationLevel: level,
                failureReason: isSuccess ? nil : "Transaction reverted",
                chainId: chainId
            )
        } catch {
            // Receipt fetch failed — skip this hash silently
            return nil
        }
    }

    /// Fetch block timestamp for a given block number.
    private func fetchBlockTimestamp(
        blockNumber: UInt64,
        chainId: UInt64,
        useTestnet: Bool,
        heliosAvailable: Bool
    ) async -> Date? {
        let blockHex = String(format: "0x%llx", blockNumber)
        do {
            let blockJSON: String
            if heliosAvailable {
                blockJSON = try await HeliosManager.shared.getBlockByNumber(blockTag: blockHex, fullTransactions: false)
            } else {
                blockJSON = try await fetchBlockViaRPC(blockTag: blockHex, fullTxs: false, chainId: chainId, useTestnet: useTestnet)
            }

            guard let data = blockJSON.data(using: .utf8),
                  let block = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let tsHex = block["timestamp"] as? String else { return nil }

            let stripped = tsHex.hasPrefix("0x") ? String(tsHex.dropFirst(2)) : tsHex
            guard let ts = UInt64(stripped, radix: 16) else { return nil }
            return Date(timeIntervalSince1970: TimeInterval(ts))
        } catch {
            return nil
        }
    }

    // MARK: - On-Chain History Fetch

    /// Fetch on-chain transaction history via Helios (preferred) or Tor-proxied RPC.
    ///
    /// Enhanced strategy:
    /// 1. ERC-20 Transfer/Approval event logs (~7 day window)
    /// 2. ERC-4337 UserOperationEvent logs for PQ account (if address provided)
    /// 3. Native ETH block scanning (adaptive range: 500–5000 blocks)
    /// 4. Nonce gap detection: expand scan if we're missing sent txs
    private func fetchOnChainHistory(
        for address: String,
        chainId: UInt64,
        useTestnet: Bool,
        pqAddress: String? = nil
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

        let logFromBlock = currentBlock > Self.defaultLogScanRange ? currentBlock - Self.defaultLogScanRange : 0
        let logFromBlockHex = String(format: "0x%llx", logFromBlock)
        let toBlockHex = "latest"

        // ── ERC-20 Transfer events (sent + received) ──
        discoveryProgress = "Scanning ERC-20 transfers…"

        let sentFilter = HeliosManager.LogFilter(
            address: "",
            topics: [
                [Self.transferTopic],
                [paddedAddr],
                nil
            ],
            fromBlock: logFromBlockHex,
            toBlock: toBlockHex
        )

        let receivedFilter = HeliosManager.LogFilter(
            address: "",
            topics: [
                [Self.transferTopic],
                nil,
                [paddedAddr]
            ],
            fromBlock: logFromBlockHex,
            toBlock: toBlockHex
        )

        async let sentLogs = fetchLogs(filter: sentFilter, chainId: chainId, useTestnet: useTestnet)
        async let receivedLogs = fetchLogs(filter: receivedFilter, chainId: chainId, useTestnet: useTestnet)

        let allSentLogs = (try? await sentLogs) ?? []
        let allReceivedLogs = (try? await receivedLogs) ?? []

        for log in allSentLogs {
            if let tx = parseTransferLog(log, userAddress: normalizedAddr, isSend: true, chainId: chainId) {
                results.append(tx)
            }
        }
        for log in allReceivedLogs {
            if let tx = parseTransferLog(log, userAddress: normalizedAddr, isSend: false, chainId: chainId) {
                results.append(tx)
            }
        }

        // ── ERC-4337 UserOperationEvent for PQ account ──
        if let pqAddr = pqAddress?.lowercased() {
            discoveryProgress = "Scanning PQ account operations…"
            let pqPadded = "0x" + String(repeating: "0", count: 24) + String(pqAddr.dropFirst(2))

            let userOpFilter = HeliosManager.LogFilter(
                address: Self.entryPointV07,
                topics: [
                    [Self.userOperationEventTopic],
                    nil,         // userOpHash (any)
                    [pqPadded]   // sender = PQ account (topic[2])
                ],
                fromBlock: logFromBlockHex,
                toBlock: toBlockHex
            )

            let userOpLogs = (try? await fetchLogs(filter: userOpFilter, chainId: chainId, useTestnet: useTestnet)) ?? []
            for log in userOpLogs {
                if let tx = parseUserOperationLog(log, pqAddress: pqAddr, chainId: chainId) {
                    results.append(tx)
                }
            }
            SecureLogger.info("TransactionHistoryService: \(userOpLogs.count) UserOperation events found for PQ account", category: .network)
        }

        // ── Nonce gap detection for adaptive block scanning ──
        discoveryProgress = "Checking for missing transactions…"
        var blockScanRange = Self.defaultBlockScanRange

        do {
            let onChainNonce: UInt64
            if await HeliosManager.shared.isRunning {
                onChainNonce = try await HeliosManager.shared.getNonce(address: normalizedAddr)
            } else {
                onChainNonce = try await fetchNonceViaRPC(address: normalizedAddr, chainId: chainId, useTestnet: useTestnet)
            }

            // Count known sent txs (from local + discovered so far)
            let knownSentCount = results.filter { $0.from.lowercased() == normalizedAddr }.count
                + TransactionStore.shared.allTransactions(for: normalizedAddr).filter { $0.from.lowercased() == normalizedAddr }.count

            if onChainNonce > knownSentCount {
                let gap = onChainNonce - UInt64(knownSentCount)
                SecureLogger.info("TransactionHistoryService: Nonce gap detected: on-chain=\(onChainNonce), known=\(knownSentCount), gap=\(gap)", category: .network)
                // Expand scan range proportionally (each tx is ~12s apart minimum)
                blockScanRange = min(Self.maxBlockScanRange, blockScanRange + gap * 100)
            }
        } catch {
            SecureLogger.warning("TransactionHistoryService: Nonce check failed: \(error)", category: .network)
        }

        // ── Native ETH transfers: scan blocks (adaptive range) ──
        discoveryProgress = "Scanning blocks for ETH transfers…"
        let ethTxs = try await fetchNativeETHTransactions(
            address: normalizedAddr,
            fromBlock: currentBlock > blockScanRange ? currentBlock - blockScanRange : 0,
            toBlock: currentBlock,
            chainId: chainId,
            useTestnet: useTestnet
        )
        results.append(contentsOf: ethTxs)

        return results
    }

    // MARK: - ERC-4337 UserOperation Parsing

    /// Parse an ERC-4337 UserOperationEvent log into an OnChainTransaction.
    private func parseUserOperationLog(_ log: HeliosManager.VerifiedLog, pqAddress: String, chainId: UInt64) -> OnChainTransaction? {
        // UserOperationEvent(bytes32 indexed userOpHash, address indexed sender, address indexed paymaster,
        //                    uint256 nonce, bool success, uint256 actualGasCost, uint256 actualGasUsed)
        // topics[0] = event signature hash
        // topics[1] = userOpHash (indexed)
        // topics[2] = sender (indexed)
        // topics[3] = paymaster (indexed)
        guard log.topics.count >= 3 else { return nil }

        let userOpHash = log.topics.count > 1 ? log.topics[1] : ""
        _ = userOpHash // available for future correlation

        // Parse data fields: nonce (32) + success (32) + gasCost (32) + gasUsed (32)
        let dataHex = log.data.hasPrefix("0x") ? String(log.data.dropFirst(2)) : log.data
        let success: Bool
        let actualGasUsed: UInt64?
        if dataHex.count >= 128 {
            let successHex = String(dataHex[dataHex.index(dataHex.startIndex, offsetBy: 64)..<dataHex.index(dataHex.startIndex, offsetBy: 128)])
            success = successHex.last != "0"
            // Parse actualGasUsed from bytes 192..256 (4th word)
            if dataHex.count >= 256 {
                let gasUsedHex = String(dataHex[dataHex.index(dataHex.startIndex, offsetBy: 192)..<dataHex.index(dataHex.startIndex, offsetBy: 256)])
                actualGasUsed = UInt64(gasUsedHex, radix: 16)
            } else {
                actualGasUsed = nil
            }
        } else {
            success = true
            actualGasUsed = nil
        }

        let blockHex = log.blockNumber.hasPrefix("0x") ? String(log.blockNumber.dropFirst(2)) : log.blockNumber
        let blockNumber = UInt64(blockHex, radix: 16)

        // Try to find the actual destination and value from the cached PQ transaction.
        // The on-chain tx is EntryPoint.handleOps, but the user cares about the inner
        // execute(dest, value, data) call — match by userOpHash or tx hash.
        let normalizedPQ = pqAddress.lowercased()
        let cachedPQTxs = TransactionStore.shared.allTransactions(for: normalizedPQ)
            .filter { $0.source == .pqAccount }

        // Try to match by on-chain txHash (if a cached entry has same chain + recent timestamp)
        // or just pick the closest cached PQ tx within a reasonable time window.
        let matchedCached = cachedPQTxs.first { cached in
            cached.chainId == chainId
        }

        let displayTo = matchedCached?.to ?? Self.entryPointV07
        let displayValue = matchedCached.flatMap { BigUInt(hexString: $0.value) } ?? BigUInt(0)
        let txType: OnChainTxType = !displayValue.isZero ? .send : .contractCall

        return OnChainTransaction(
            id: "\(log.transactionHash)-userop",
            txHash: log.transactionHash,
            blockNumber: blockNumber,
            timestamp: matchedCached?.timestamp ?? Date(),
            from: pqAddress,
            to: displayTo,
            value: displayValue,
            gasUsed: actualGasUsed,
            gasPrice: nil,
            input: nil,
            status: success ? .confirmed : .reverted,
            txType: txType,
            tokenSymbol: nil,
            tokenAmount: nil,
            contractAddress: displayTo != Self.entryPointV07 ? nil : Self.entryPointV07,
            verificationLevel: verificationLevel,
            failureReason: success ? nil : "UserOperation reverted",
            chainId: chainId
        )
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
    /// Uses concurrent batch fetching of eth_getBlockByNumber for efficiency.
    /// Scans the full range passed in (caller determines adaptive range).
    private func fetchNativeETHTransactions(
        address: String,
        fromBlock: UInt64,
        toBlock: UInt64,
        chainId: UInt64,
        useTestnet: Bool
    ) async throws -> [OnChainTransaction] {
        guard toBlock >= fromBlock else { return [] }

        let totalBlocks = toBlock - fromBlock + 1
        SecureLogger.info("TransactionHistoryService: Scanning \(totalBlocks) blocks (\(fromBlock)–\(toBlock)) for native ETH", category: .network)

        var allResults: [OnChainTransaction] = []
        let heliosAvailable = await HeliosManager.shared.isRunning

        // Fetch blocks in concurrent batches
        let batchSize = UInt64(Self.blockFetchBatchSize)

        for batchStart in stride(from: fromBlock, through: toBlock, by: Int(batchSize)) {
            let batchEnd = min(batchStart + batchSize - 1, toBlock)

            let batchResults: [OnChainTransaction] = await withTaskGroup(of: [OnChainTransaction].self) { group in
                for blockNum in batchStart...batchEnd {
                    group.addTask { [weak self] in
                        guard let self else { return [] }
                        return await self.fetchTransactionsFromBlock(
                            blockNum: blockNum,
                            address: address,
                            chainId: chainId,
                            useTestnet: useTestnet,
                            heliosAvailable: heliosAvailable
                        )
                    }
                }

                var results: [OnChainTransaction] = []
                for await blockTxs in group {
                    results.append(contentsOf: blockTxs)
                }
                return results
            }

            allResults.append(contentsOf: batchResults)
        }

        return allResults
    }

    /// Fetch and parse all transactions from a single block involving our address.
    private func fetchTransactionsFromBlock(
        blockNum: UInt64,
        address: String,
        chainId: UInt64,
        useTestnet: Bool,
        heliosAvailable: Bool
    ) async -> [OnChainTransaction] {
        let blockHex = String(format: "0x%llx", blockNum)

        do {
            let blockJSON: String
            if heliosAvailable {
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
                return []
            }

            let tsHex = timestampHex.hasPrefix("0x") ? String(timestampHex.dropFirst(2)) : timestampHex
            let timestamp = Date(timeIntervalSince1970: TimeInterval(UInt64(tsHex, radix: 16) ?? 0))

            var results: [OnChainTransaction] = []

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
                            failureReason: nil,
                            chainId: chainId
                        ))
                    }
                    continue
                }

                // Only include transactions involving our address
                guard txFrom == address || txTo == address else { continue }

                let txHash = tx["hash"] as? String ?? ""
                let isSend = txFrom == address
                let inputData = tx["input"] as? String ?? "0x"
                let isContractCall = inputData.count > 4
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
                    failureReason: nil,
                    chainId: chainId
                ))
            }

            return results
        } catch {
            return []
        }
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
              let result = json["result"],
              !(result is NSNull) else {
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
        isSend: Bool,
        chainId: UInt64
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
            failureReason: nil,
            chainId: chainId
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

    // MARK: - Additional RPC Fallbacks

    /// Fetch a transaction receipt via RPC over Tor (fallback when Helios unavailable).
    private func fetchReceiptViaRPC(
        txHash: String,
        chainId: UInt64,
        useTestnet: Bool
    ) async throws -> String {
        let rpcURL = Self.rpcURL(for: chainId)
        let session = useTestnet ? URLSession.shared : TorURLSession.shared.session

        let body: [String: Any] = [
            "jsonrpc": "2.0",
            "id": 1,
            "method": "eth_getTransactionReceipt",
            "params": [txHash]
        ]

        var request = URLRequest(url: rpcURL)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        request.timeoutInterval = 15

        let (data, _) = try await session.data(for: request)
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let result = json["result"],
              !(result is NSNull) else {
            return "{}"
        }

        let resultData = try JSONSerialization.data(withJSONObject: result)
        return String(data: resultData, encoding: .utf8) ?? "{}"
    }

    /// Fetch the nonce (transaction count) for an address via RPC over Tor.
    private func fetchNonceViaRPC(
        address: String,
        chainId: UInt64,
        useTestnet: Bool
    ) async throws -> UInt64 {
        let rpcURL = Self.rpcURL(for: chainId)
        let session = useTestnet ? URLSession.shared : TorURLSession.shared.session

        let body: [String: Any] = [
            "jsonrpc": "2.0",
            "id": 1,
            "method": "eth_getTransactionCount",
            "params": [address, "latest"]
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
}
