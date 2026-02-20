//
// TransactionStore.swift
// bitchat
//
// Persistent cache of known transaction hashes and metadata.
// Ensures transaction history survives app restarts and is never lost
// once discovered — even if on-chain block scanning windows move past.
//
// Storage: App Group UserDefaults, keyed per wallet address.
// Format: JSON-encoded array of CachedTransaction records.
//
// This is free and unencumbered software released into the public domain.
// For more information, see <https://unlicense.org>
//

import BitLogger
import Foundation

// MARK: - Cached Transaction Record

/// Minimal persistent record of a known transaction.
/// Full details are re-fetched via Helios `getTransactionReceipt` on demand.
struct CachedTransaction: Codable, Equatable, Identifiable {
    let id: String           // txHash (or userOpHash for PQ)
    let txHash: String
    let from: String
    let to: String
    let value: String        // Hex-encoded wei value
    let timestamp: Date
    let blockNumber: UInt64?
    let chainId: UInt64
    let source: TxSource

    /// Where this transaction was discovered from.
    enum TxSource: String, Codable {
        case meshRelay          // Sent via MeshTransactionRelay (EOA)
        case pqAccount          // Sent via PQ smart account (ERC-4337)
        case pqDeploy           // PQ account deployment tx
        case onChainScan        // Discovered by block/log scanning
        case receiptLookup      // Discovered via getTransactionReceipt
    }
}

// MARK: - TransactionStore

/// Persistent store for transaction hashes and metadata.
///
/// **Privacy:** All data is stored locally on-device in the App Group
/// container. No external services are contacted for storage. Transaction
/// data is only fetched via Helios (verified, over Tor) or Tor-proxied RPC.
///
/// **Usage flow:**
/// 1. When a tx is sent → `record()` the hash immediately
/// 2. When history is loaded → `knownHashes(for:)` provides all stored hashes
/// 3. TransactionHistoryService fetches receipts for known hashes via Helios
/// 4. Newly discovered on-chain txs are also recorded for future sessions
@MainActor
final class TransactionStore {
    static let shared = TransactionStore()

    private let defaults: UserDefaults
    private static let storeKeyPrefix = "tx-store-"

    /// In-memory cache, keyed by lowercased address.
    private var cache: [String: [CachedTransaction]] = [:]

    private init() {
        defaults = UserDefaults(suiteName: BitchatApp.groupID) ?? .standard
    }

    // MARK: - Public API

    /// Record a transaction hash for an address.
    /// Deduplicates by txHash — safe to call multiple times.
    func record(_ tx: CachedTransaction, for address: String) {
        let key = address.lowercased()
        var existing = load(for: key)

        // Deduplicate by txHash
        if existing.contains(where: { $0.txHash.lowercased() == tx.txHash.lowercased() }) {
            return
        }

        existing.append(tx)
        save(existing, for: key)
        cache[key] = existing
    }

    /// Record multiple transactions at once (deduplicates).
    func recordBatch(_ txs: [CachedTransaction], for address: String) {
        guard !txs.isEmpty else { return }
        let key = address.lowercased()
        var existing = load(for: key)
        let existingHashes = Set(existing.map { $0.txHash.lowercased() })

        var added = false
        for tx in txs {
            if !existingHashes.contains(tx.txHash.lowercased()) {
                existing.append(tx)
                added = true
            }
        }

        if added {
            save(existing, for: key)
            cache[key] = existing
        }
    }

    /// Update a cached transaction's block number (e.g., after receipt fetch).
    func updateBlockNumber(txHash: String, blockNumber: UInt64, for address: String) {
        let key = address.lowercased()
        var existing = load(for: key)
        if let idx = existing.firstIndex(where: { $0.txHash.lowercased() == txHash.lowercased() }) {
            let old = existing[idx]
            existing[idx] = CachedTransaction(
                id: old.id,
                txHash: old.txHash,
                from: old.from,
                to: old.to,
                value: old.value,
                timestamp: old.timestamp,
                blockNumber: blockNumber,
                chainId: old.chainId,
                source: old.source
            )
            save(existing, for: key)
            cache[key] = existing
        }
    }

    /// Get all known transaction hashes for an address.
    func knownHashes(for address: String) -> Set<String> {
        let txs = load(for: address.lowercased())
        return Set(txs.map { $0.txHash.lowercased() })
    }

    /// Get all cached transactions for an address.
    func allTransactions(for address: String) -> [CachedTransaction] {
        return load(for: address.lowercased())
    }

    /// Get count of known transactions for an address.
    func count(for address: String) -> Int {
        return load(for: address.lowercased()).count
    }

    /// Clear all cached transactions for an address.
    func clear(for address: String) {
        let key = address.lowercased()
        defaults.removeObject(forKey: Self.storeKeyPrefix + key)
        cache.removeValue(forKey: key)
    }

    // MARK: - Internal

    private func load(for key: String) -> [CachedTransaction] {
        if let cached = cache[key] { return cached }

        guard let data = defaults.data(forKey: Self.storeKeyPrefix + key) else { return [] }
        do {
            let txs = try JSONDecoder().decode([CachedTransaction].self, from: data)
            cache[key] = txs
            return txs
        } catch {
            SecureLogger.warning("TransactionStore: Failed to decode cache for \(key.prefix(10))…: \(error)", category: .session)
            return []
        }
    }

    private func save(_ txs: [CachedTransaction], for key: String) {
        do {
            let data = try JSONEncoder().encode(txs)
            defaults.set(data, forKey: Self.storeKeyPrefix + key)
        } catch {
            SecureLogger.warning("TransactionStore: Failed to encode cache for \(key.prefix(10))…: \(error)", category: .session)
        }
    }
}
