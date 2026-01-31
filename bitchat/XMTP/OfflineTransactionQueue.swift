//
// OfflineTransactionQueue.swift
// bitchat
//
// Queue for offline transaction requests with BLE mesh relay support.
// Default: Attempt relay through connected BLE peers, fallback to local queue.
//
// This is free and unencumbered software released into the public domain.
// For more information, see <https://unlicense.org>
//

import BitLogger
import Combine
import Foundation

/// Strategy for handling offline transactions
enum TransactionRelayStrategy: String, Codable, CaseIterable {
    /// Try to relay through BLE peers first, queue locally if no peers available
    case relayFirst = "relay_first"
    /// Always queue locally until direct internet connectivity
    case queueOnly = "queue_only"
    
    var displayName: String {
        switch self {
        case .relayFirst:
            return "Relay through mesh (faster)"
        case .queueOnly:
            return "Queue locally (more private)"
        }
    }
    
    var description: String {
        switch self {
        case .relayFirst:
            return "Transactions are relayed through nearby Bluetooth peers who have internet connectivity. Faster execution but peers see transaction metadata."
        case .queueOnly:
            return "Transactions wait in local queue until you have direct internet. More private but delays execution."
        }
    }
}

/// Pending transaction with metadata
struct PendingTransaction: Codable, Identifiable {
    let id: String
    let request: TransactionRequest
    let recipientInboxId: String
    let createdAt: Date
    var attempts: Int
    var lastAttemptAt: Date?
    var status: PendingTransactionStatus
    var relayedVia: String? // PeerID of relay node if relayed
    
    init(request: TransactionRequest, recipientInboxId: String) {
        self.id = request.id
        self.request = request
        self.recipientInboxId = recipientInboxId
        self.createdAt = Date()
        self.attempts = 0
        self.lastAttemptAt = nil
        self.status = .pending
        self.relayedVia = nil
    }
}

enum PendingTransactionStatus: String, Codable {
    case pending
    case relaying
    case relayed
    case submitted
    case confirmed
    case failed
}

/// Manages offline transaction queue with BLE mesh relay support
@MainActor
final class OfflineTransactionQueue: ObservableObject {
    // MARK: - Properties
    
    private let keychain: KeychainManagerProtocol
    private let storageKey = "offline-transaction-queue"
    private let keychainService = "chat.bitchat.xmtp.transactions"
    private let settingsKey = "transaction-relay-strategy"
    
    @Published private(set) var pendingTransactions: [PendingTransaction] = []
    @Published var relayStrategy: TransactionRelayStrategy = .relayFirst {
        didSet {
            saveStrategy()
        }
    }
    
    // Dependencies
    private weak var bleService: BLEService?
    private weak var xmtpClient: XMTPClientService?
    
    // Transaction relay packet type
    private static let txRelayPacketType: UInt8 = 0x50 // Custom packet type for tx relay
    
    // Limits
    private static let maxQueueSize = 100
    private static let maxAttempts = 10
    private static let transactionTTL: TimeInterval = 7 * 24 * 60 * 60 // 7 days
    private static let retryInterval: TimeInterval = 60 // 1 minute
    
    // MARK: - Initialization
    
    init(keychain: KeychainManagerProtocol) {
        self.keychain = keychain
        loadQueue()
        loadStrategy()
    }
    
    func configure(bleService: BLEService?, xmtpClient: XMTPClientService?) {
        self.bleService = bleService
        self.xmtpClient = xmtpClient
    }
    
    // MARK: - Queue Management
    
    /// Add a transaction to the queue
    func queueTransaction(_ request: TransactionRequest, to recipientInboxId: String) {
        let pending = PendingTransaction(request: request, recipientInboxId: recipientInboxId)
        
        // Enforce queue size limit
        if pendingTransactions.count >= Self.maxQueueSize {
            // Remove oldest pending transaction
            if let oldest = pendingTransactions.filter({ $0.status == .pending }).sorted(by: { $0.createdAt < $1.createdAt }).first {
                pendingTransactions.removeAll { $0.id == oldest.id }
                SecureLogger.warning("📤 Transaction queue overflow - removed oldest: \(oldest.id.prefix(8))…", category: .session)
            }
        }
        
        pendingTransactions.append(pending)
        saveQueue()
        
        SecureLogger.info("📤 Queued transaction \(request.id.prefix(8))… for \(recipientInboxId.prefix(16))…", category: .session)
        
        // Attempt to process immediately based on strategy
        Task {
            await processQueue()
        }
    }
    
    /// Process pending transactions based on current strategy
    func processQueue() async {
        let pending = pendingTransactions.filter { $0.status == .pending }
        
        for transaction in pending {
            await processTransaction(transaction)
        }
    }
    
    private func processTransaction(_ transaction: PendingTransaction) async {
        var tx = transaction
        
        // Check TTL
        if Date().timeIntervalSince(tx.createdAt) > Self.transactionTTL {
            tx.status = .failed
            updateTransaction(tx)
            SecureLogger.warning("⏰ Transaction expired: \(tx.id.prefix(8))…", category: .session)
            return
        }
        
        // Check max attempts
        if tx.attempts >= Self.maxAttempts {
            tx.status = .failed
            updateTransaction(tx)
            SecureLogger.warning("❌ Transaction max attempts reached: \(tx.id.prefix(8))…", category: .session)
            return
        }
        
        tx.attempts += 1
        tx.lastAttemptAt = Date()
        
        switch relayStrategy {
        case .relayFirst:
            // Try XMTP first if connected
            if let xmtpClient = xmtpClient, xmtpClient.isConnected {
                await sendViaXMTP(tx)
            } else if let connectedPeer = findConnectedPeerWithInternet() {
                // Try BLE relay
                await relayViaBLE(tx, through: connectedPeer)
            } else {
                // No options, keep in queue
                updateTransaction(tx)
                SecureLogger.debug("📤 No relay path for transaction \(tx.id.prefix(8))…, kept in queue", category: .session)
            }
            
        case .queueOnly:
            // Only send via XMTP when directly connected
            if let xmtpClient = xmtpClient, xmtpClient.isConnected {
                await sendViaXMTP(tx)
            } else {
                updateTransaction(tx)
            }
        }
    }
    
    private func sendViaXMTP(_ transaction: PendingTransaction) async {
        guard let xmtpClient = xmtpClient else { return }
        
        var tx = transaction
        tx.status = .submitted
        updateTransaction(tx)
        
        do {
            let conversation = try await xmtpClient.findOrCreateDM(with: tx.recipientInboxId)
            try await xmtpClient.sendTransactionRequest(tx.request, to: conversation)
            
            tx.status = .confirmed
            updateTransaction(tx)
            
            SecureLogger.info("✅ Transaction sent via XMTP: \(tx.id.prefix(8))…", category: .session)
        } catch {
            tx.status = .pending
            updateTransaction(tx)
            SecureLogger.error("❌ Transaction send failed: \(error.localizedDescription)", category: .session)
        }
    }
    
    private func relayViaBLE(_ transaction: PendingTransaction, through peerID: PeerID) async {
        guard let bleService = bleService else { return }
        
        var tx = transaction
        tx.status = .relaying
        tx.relayedVia = peerID.id
        updateTransaction(tx)
        
        // Encode transaction as relay packet
        guard let packetData = encodeTransactionRelayPacket(tx) else {
            tx.status = .pending
            updateTransaction(tx)
            return
        }
        
        // Create BitChat packet for relay
        let packet = BitchatPacket(
            type: Self.txRelayPacketType,
            ttl: 2, // Limit hops for security
            senderID: bleService.myPeerID,
            payload: packetData,
            isRSR: false
        )
        
        // Send via BLE
        if let data = packet.toBinaryData() {
            bleService.sendDirectedPacket(data, to: peerID)
            
            tx.status = .relayed
            updateTransaction(tx)
            
            SecureLogger.info("🔀 Transaction relayed via BLE peer \(peerID.id.prefix(8))…: \(tx.id.prefix(8))…", category: .session)
        } else {
            tx.status = .pending
            updateTransaction(tx)
        }
    }
    
    private func findConnectedPeerWithInternet() -> PeerID? {
        guard let bleService = bleService else { return nil }
        
        // Get connected peers that might have internet
        // In a real implementation, peers would advertise their connectivity status
        let peers = bleService.currentPeerSnapshots()
        
        // For now, return any connected peer (they might relay for us)
        return peers.first(where: { $0.isConnected })?.peerID
    }
    
    // MARK: - BLE Relay Packet Handling
    
    /// Encode transaction for BLE relay
    private func encodeTransactionRelayPacket(_ transaction: PendingTransaction) -> Data? {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return try? encoder.encode(transaction)
    }
    
    /// Decode incoming relay packet
    func decodeTransactionRelayPacket(_ data: Data) -> PendingTransaction? {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(PendingTransaction.self, from: data)
    }
    
    /// Handle incoming transaction relay request (for nodes that have internet)
    func handleIncomingRelayRequest(_ data: Data, from senderPeerID: PeerID) {
        guard let transaction = decodeTransactionRelayPacket(data) else {
            SecureLogger.warning("Invalid transaction relay packet from \(senderPeerID.id.prefix(8))…", category: .session)
            return
        }
        
        SecureLogger.info("📥 Received transaction relay request: \(transaction.id.prefix(8))…", category: .session)
        
        // Queue for sending when we have XMTP connectivity
        var relayedTx = transaction
        relayedTx.relayedVia = senderPeerID.id
        pendingTransactions.append(relayedTx)
        saveQueue()
        
        // Try to process immediately
        Task {
            await processQueue()
        }
    }
    
    // MARK: - Transaction Updates
    
    private func updateTransaction(_ transaction: PendingTransaction) {
        if let index = pendingTransactions.firstIndex(where: { $0.id == transaction.id }) {
            pendingTransactions[index] = transaction
        }
        saveQueue()
    }
    
    /// Remove completed or failed transactions older than TTL
    func cleanup() {
        let now = Date()
        pendingTransactions.removeAll { tx in
            (tx.status == .confirmed || tx.status == .failed) &&
            now.timeIntervalSince(tx.createdAt) > Self.transactionTTL
        }
        saveQueue()
    }
    
    /// Clear all pending transactions (panic mode)
    func clearAll() {
        pendingTransactions.removeAll()
        saveQueue()
        SecureLogger.warning("🧹 Cleared all pending transactions", category: .session)
    }
    
    // MARK: - Persistence
    
    private func loadQueue() {
        guard let data = keychain.load(key: storageKey, service: keychainService) else { return }
        
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        
        if let transactions = try? decoder.decode([PendingTransaction].self, from: data) {
            pendingTransactions = transactions
            SecureLogger.debug("📥 Loaded \(transactions.count) pending transactions", category: .session)
        }
    }
    
    private func saveQueue() {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        
        guard let data = try? encoder.encode(pendingTransactions) else { return }
        keychain.save(key: storageKey, data: data, service: keychainService, accessible: nil)
    }
    
    private func loadStrategy() {
        guard let data = keychain.load(key: settingsKey, service: keychainService),
              let strategyString = String(data: data, encoding: .utf8),
              let strategy = TransactionRelayStrategy(rawValue: strategyString) else {
            relayStrategy = .relayFirst // Default
            return
        }
        relayStrategy = strategy
    }
    
    private func saveStrategy() {
        guard let data = relayStrategy.rawValue.data(using: .utf8) else { return }
        keychain.save(key: settingsKey, data: data, service: keychainService, accessible: nil)
    }
}

// MARK: - BLEService Extension for Direct Packets

extension BLEService {
    /// Send a directed packet to a specific peer (placeholder - needs BLE implementation)
    func sendDirectedPacket(_ data: Data, to peerID: PeerID) {
        // This would use the existing BLE infrastructure to send a directed packet
        // Implementation depends on existing BLEService methods
        SecureLogger.debug("📤 Sending directed packet to \(peerID.id.prefix(8))…", category: .session)
    }
}
