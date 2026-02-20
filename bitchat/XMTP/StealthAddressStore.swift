//
// StealthAddressStore.swift
// bitchat
//
// Persistence layer for discovered stealth addresses.
// Stores addresses, labels, ephemeral keys, and sync state.
//
// This is free and unencumbered software released into the public domain.
// For more information, see <https://unlicense.org>
//

import BitLogger
import Foundation
import SwiftUI

/// A discovered stealth address that belongs to the user
struct DiscoveredStealthAddress: Identifiable, Codable, Equatable {
    let id: UUID
    
    /// The stealth address (0x...)
    let address: String
    
    /// Ephemeral public key used to generate this address (needed to derive private key)
    let ephemeralPubKey: Data
    
    /// View tag for quick identification
    let viewTag: UInt8
    
    /// Block number when the announcement was made
    let blockNumber: UInt64
    
    /// Transaction hash of the announcement
    let transactionHash: String
    
    /// Chain ID where this address exists
    let chainId: UInt64
    
    /// User-assigned label
    var label: String
    
    /// Timestamp when discovered
    let discoveredAt: Date
    
    /// Last known balance in wei (cached, may be stale)
    var cachedBalance: String?
    
    /// When the balance was last checked
    var balanceCheckedAt: Date?
    
    /// Whether funds have been swept from this address
    var isSwept: Bool
    
    /// Whether this is a self-generated address (from our own meta-address)
    var isSelfGenerated: Bool
    
    /// Derivation index for self-generated addresses (for deterministic derivation)
    var derivationIndex: UInt32?
    
    init(
        address: String,
        ephemeralPubKey: Data,
        viewTag: UInt8,
        blockNumber: UInt64,
        transactionHash: String,
        chainId: UInt64,
        label: String = "",
        isSelfGenerated: Bool = false,
        derivationIndex: UInt32? = nil
    ) {
        self.id = UUID()
        self.address = address.lowercased()
        self.ephemeralPubKey = ephemeralPubKey
        self.viewTag = viewTag
        self.blockNumber = blockNumber
        self.transactionHash = transactionHash
        self.chainId = chainId
        self.label = label
        self.discoveredAt = Date()
        self.cachedBalance = nil
        self.balanceCheckedAt = nil
        self.isSwept = false
        self.isSelfGenerated = isSelfGenerated
        self.derivationIndex = derivationIndex
    }
}

/// Persistent store for stealth addresses
@MainActor
final class StealthAddressStore: ObservableObject {
    
    // MARK: - Published State
    
    @Published private(set) var addresses: [DiscoveredStealthAddress] = []
    @Published private(set) var lastScanBlock: [UInt64: UInt64] = [:] // chainId -> blockNumber
    @Published private(set) var isScanning: Bool = false
    @Published private(set) var scanProgress: Double = 0.0
    
    // MARK: - Private Properties
    
    private let fileManager = FileManager.default
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()
    
    /// App Group container for persistence across reinstalls/rebuilds
    private var containerURL: URL {
        // Use App Group container if available, fall back to Documents
        if let groupURL = fileManager.containerURL(forSecurityApplicationGroupIdentifier: BitchatApp.groupID) {
            return groupURL
        }
        return fileManager.urls(for: .documentDirectory, in: .userDomainMask)[0]
    }
    
    private var storeURL: URL {
        containerURL.appendingPathComponent("stealth_addresses.json")
    }
    
    private var syncStateURL: URL {
        containerURL.appendingPathComponent("stealth_sync_state.json")
    }
    
    /// Legacy Documents folder URL (for migration)
    private var legacyStoreURL: URL {
        fileManager.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("stealth_addresses.json")
    }
    
    private var legacySyncStateURL: URL {
        fileManager.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("stealth_sync_state.json")
    }
    
    // MARK: - Initialization
    
    init() {
        migrateFromLegacyLocation()
        loadFromDisk()
    }
    
    // MARK: - Migration
    
    /// Migrate data from legacy Documents folder to App Group container
    private func migrateFromLegacyLocation() {
        // Only migrate if App Group is available and legacy files exist
        guard fileManager.containerURL(forSecurityApplicationGroupIdentifier: BitchatApp.groupID) != nil else {
            return
        }
        
        // Migrate stealth addresses
        if fileManager.fileExists(atPath: legacyStoreURL.path) && !fileManager.fileExists(atPath: storeURL.path) {
            do {
                try fileManager.moveItem(at: legacyStoreURL, to: storeURL)
                SecureLogger.info("🥷 Migrated stealth addresses to App Group container", category: .session)
            } catch {
                SecureLogger.error("🥷 Failed to migrate stealth addresses: \(error)", category: .session)
            }
        }
        
        // Migrate sync state
        if fileManager.fileExists(atPath: legacySyncStateURL.path) && !fileManager.fileExists(atPath: syncStateURL.path) {
            do {
                try fileManager.moveItem(at: legacySyncStateURL, to: syncStateURL)
                SecureLogger.info("🥷 Migrated stealth sync state to App Group container", category: .session)
            } catch {
                SecureLogger.error("🥷 Failed to migrate stealth sync state: \(error)", category: .session)
            }
        }
    }
    
    // MARK: - Address Management
    
    /// Add a newly discovered stealth address
    func addAddress(_ address: DiscoveredStealthAddress) {
        // Check for duplicates
        guard !addresses.contains(where: { $0.address == address.address && $0.chainId == address.chainId }) else {
            SecureLogger.debug("🥷 Duplicate stealth address, skipping: \(address.address.prefix(10))...", category: .session)
            return
        }
        
        addresses.append(address)
        addresses.sort { $0.discoveredAt > $1.discoveredAt }
        saveToDisk()
        
        SecureLogger.info("🥷 Added new stealth address: \(address.address.prefix(10))...", category: .session)
    }
    
    /// Update the label for an address
    func updateLabel(for addressId: UUID, label: String) {
        guard let index = addresses.firstIndex(where: { $0.id == addressId }) else { return }
        addresses[index].label = label
        saveToDisk()
    }
    
    /// Update cached balance for an address
    func updateBalance(for addressId: UUID, balance: String) {
        guard let index = addresses.firstIndex(where: { $0.id == addressId }) else { return }
        addresses[index].cachedBalance = balance
        addresses[index].balanceCheckedAt = Date()
        saveToDisk()
    }
    
    /// Mark an address as swept
    func markAsSwept(addressId: UUID) {
        guard let index = addresses.firstIndex(where: { $0.id == addressId }) else { return }
        addresses[index].isSwept = true
        saveToDisk()
    }
    
    /// Remove an address
    func removeAddress(addressId: UUID) {
        addresses.removeAll { $0.id == addressId }
        saveToDisk()
    }
    
    /// Get addresses for a specific chain
    func addresses(for chainId: UInt64) -> [DiscoveredStealthAddress] {
        addresses.filter { $0.chainId == chainId }
    }
    
    /// Get non-swept addresses with balance
    func addressesWithBalance(for chainId: UInt64) -> [DiscoveredStealthAddress] {
        addresses.filter { 
            $0.chainId == chainId && 
            !$0.isSwept && 
            $0.cachedBalance != nil && 
            $0.cachedBalance != "0" 
        }
    }
    
    // MARK: - Bulk Balance Scanning
    
    /// Scan all non-swept addresses for balances using EthereumBalanceService.
    ///
    /// Routes through the Helios → Merkle proof → RPC pipeline with Tor for
    /// privacy. Updates cached balances and persists to disk.
    ///
    /// - Parameters:
    ///   - balanceService: The balance service to use for fetching
    ///   - chainId: Optional chain ID filter (scans all chains if nil)
    /// - Returns: Number of addresses with non-zero balance
    @discardableResult
    func scanAllBalances(
        balanceService: EthereumBalanceService,
        chainId: UInt64? = nil
    ) async -> Int {
        let targets = addresses.enumerated().filter { _, addr in
            !addr.isSwept && (chainId == nil || addr.chainId == chainId)
        }
        
        guard !targets.isEmpty else { return 0 }
        
        setScanningState(isScanning: true, progress: 0)
        var fundedCount = 0
        
        for (offset, (index, address)) in targets.enumerated() {
            let network = networkForChainId(address.chainId)
            
            if let balance = await balanceService.fetchSingleAddressBalance(
                address: address.address,
                network: network
            ) {
                let hexBalance = balance.wei.hexString
                addresses[index].cachedBalance = hexBalance
                addresses[index].balanceCheckedAt = Date()
                
                if !balance.wei.isZero {
                    fundedCount += 1
                    SecureLogger.debug(
                        "🥷 Found balance \(hexBalance) at stealth \(address.address.prefix(10))... [\(balance.verificationLevel.rawValue)]",
                        category: .session
                    )
                }
            }
            
            // Update progress
            let progress = Double(offset + 1) / Double(targets.count)
            setScanningState(isScanning: true, progress: progress)
        }
        
        saveToDisk()
        setScanningState(isScanning: false, progress: 1.0)
        
        SecureLogger.info(
            "🥷 Bulk scan complete: \(fundedCount)/\(targets.count) addresses funded",
            category: .session
        )
        return fundedCount
    }
    
    /// Map chain ID to EthereumBalanceService.Network
    private func networkForChainId(_ chainId: UInt64) -> EthereumBalanceService.Network {
        switch chainId {
        case 1: return .ethereum
        case 8453: return .base
        case 42161: return .arbitrum
        case 11155111: return .sepolia
        case 421614: return .arbitrumSepolia
        default: return .ethereum
        }
    }
    
    // MARK: - Scan State
    
    /// Update the last scanned block for a chain
    func updateLastScanBlock(_ blockNumber: UInt64, for chainId: UInt64) {
        lastScanBlock[chainId] = blockNumber
        saveSyncState()
    }
    
    /// Get the starting block for scanning
    func getStartBlock(for chainId: UInt64) -> UInt64 {
        // Start from last scan block, or a reasonable default
        lastScanBlock[chainId] ?? getDefaultStartBlock(for: chainId)
    }
    
    /// Set scanning state
    func setScanningState(isScanning: Bool, progress: Double = 0.0) {
        self.isScanning = isScanning
        self.scanProgress = progress
    }
    
    // MARK: - Persistence
    
    private func saveToDisk() {
        do {
            encoder.outputFormatting = .prettyPrinted
            let data = try encoder.encode(addresses)
            try data.write(to: storeURL, options: .atomic)
            SecureLogger.debug("🥷 Saved \(addresses.count) stealth addresses to disk", category: .session)
        } catch {
            SecureLogger.error("🥷 Failed to save stealth addresses: \(error)", category: .session)
        }
    }
    
    private func loadFromDisk() {
        guard fileManager.fileExists(atPath: storeURL.path) else {
            SecureLogger.debug("🥷 No stealth address file found, starting fresh", category: .session)
            return
        }
        
        do {
            let data = try Data(contentsOf: storeURL)
            addresses = try decoder.decode([DiscoveredStealthAddress].self, from: data)
            SecureLogger.info("🥷 Loaded \(addresses.count) stealth addresses from disk", category: .session)
        } catch {
            SecureLogger.error("🥷 Failed to load stealth addresses: \(error)", category: .session)
        }
        
        loadSyncState()
    }
    
    private func saveSyncState() {
        do {
            let data = try encoder.encode(lastScanBlock)
            try data.write(to: syncStateURL, options: .atomic)
        } catch {
            SecureLogger.error("🥷 Failed to save sync state: \(error)", category: .session)
        }
    }
    
    private func loadSyncState() {
        guard fileManager.fileExists(atPath: syncStateURL.path) else { return }
        
        do {
            let data = try Data(contentsOf: syncStateURL)
            lastScanBlock = try decoder.decode([UInt64: UInt64].self, from: data)
        } catch {
            SecureLogger.error("🥷 Failed to load sync state: \(error)", category: .session)
        }
    }
    
    /// Get a reasonable default start block for a chain
    /// These are approximate blocks from when ERC5564Announcer was deployed
    private func getDefaultStartBlock(for chainId: UInt64) -> UInt64 {
        switch chainId {
        case 1:      // Ethereum mainnet
            return 19_000_000
        case 11155111: // Sepolia
            return 5_000_000
        case 10:     // Optimism
            return 115_000_000
        case 8453:   // Base
            return 10_000_000
        case 42161:  // Arbitrum One
            return 175_000_000
        default:
            return 0
        }
    }
    
    // MARK: - Statistics
    
    /// Total number of addresses
    var totalCount: Int { addresses.count }
    
    /// Number of addresses with non-zero balance
    var withBalanceCount: Int {
        addresses.filter { $0.cachedBalance != nil && $0.cachedBalance != "0" && !$0.isSwept }.count
    }
    
    /// Number of swept addresses
    var sweptCount: Int {
        addresses.filter { $0.isSwept }.count
    }
    
    /// Number of self-generated addresses
    var selfGeneratedCount: Int {
        addresses.filter { $0.isSelfGenerated }.count
    }
    
    /// Get self-generated addresses for a specific chain
    func selfGeneratedAddresses(for chainId: UInt64) -> [DiscoveredStealthAddress] {
        addresses.filter { $0.chainId == chainId && $0.isSelfGenerated }
    }
    
    /// Get discovered (not self-generated) addresses for a specific chain
    func discoveredAddresses(for chainId: UInt64) -> [DiscoveredStealthAddress] {
        addresses.filter { $0.chainId == chainId && !$0.isSelfGenerated }
    }
    
    /// Get next derivation index for self-generated addresses
    func nextDerivationIndex(for chainId: UInt64) -> UInt32 {
        let existing = selfGeneratedAddresses(for: chainId)
        let maxIndex = existing.compactMap { $0.derivationIndex }.max() ?? 0
        return maxIndex + 1
    }
}

// MARK: - Preview Support

#if DEBUG
extension StealthAddressStore {
    static var preview: StealthAddressStore {
        let store = StealthAddressStore()
        store.addresses = [
            DiscoveredStealthAddress(
                address: "0x1234567890abcdef1234567890abcdef12345678",
                ephemeralPubKey: Data(repeating: 0x02, count: 33),
                viewTag: 42,
                blockNumber: 19_500_000,
                transactionHash: "0xabc123",
                chainId: 1,
                label: "Payment from Alice"
            ),
            DiscoveredStealthAddress(
                address: "0xabcdef1234567890abcdef1234567890abcdef12",
                ephemeralPubKey: Data(repeating: 0x03, count: 33),
                viewTag: 128,
                blockNumber: 19_600_000,
                transactionHash: "0xdef456",
                chainId: 1,
                label: ""
            )
        ]
        store.addresses[0].cachedBalance = "100000000000000000" // 0.1 ETH
        return store
    }
}
#endif
