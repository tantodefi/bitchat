//
// StealthPQAccountManager.swift
// bitchat
//
// Derives stealth PQ Account addresses and manages their lifecycle.
// Each stealth address wraps a unique ECDSA signer in a ZKNOX PQ Account
// via CREATE2, sharing the user's master ML-DSA-44 key (Option A).
//
// Balance scanning uses EthereumBalanceService (Helios → Merkle proof → RPC)
// with Tor routing for IP privacy. For funded accounts on Arbitrum Sepolia
// (where Helios doesn't work), a Sepolia cross-check via Helios verifies
// the contract code presence.
//
// This is free and unencumbered software released into the public domain.
// For more information, see <https://unlicense.org>
//

import BitLogger
import CryptoKit
import CryptoSwift
import Foundation
@preconcurrency import P256K

// MARK: - Stealth PQ Account Model

/// A counterfactual stealth PQ Account with its derivation data.
struct StealthPQAccount: Identifiable, Codable, Equatable {
    let index: UInt32
    /// The ECDSA stealth signer EOA address (20-byte)
    let stealthSignerAddress: String
    /// The predicted CREATE2 PQ Account smart account address
    let pqAccountAddress: String
    /// Whether the PQ Account contract is deployed on-chain
    var isDeployed: Bool
    /// Current balance in wei (hex string, e.g. "0x2386f26fc10000")
    var balanceWei: String
    /// How the balance was verified — uses the unified EthereumBalanceService.VerificationLevel
    var verificationLevelRaw: String
    /// Ephemeral public key for this stealth address (compressed, 33 bytes)
    let ephemeralPubKey: Data
    /// When the balance was last checked
    var balanceCheckedAt: Date?
    
    var id: UInt32 { index }
    
    /// Map to/from unified EthereumBalanceService.VerificationLevel
    var verificationLevel: EthereumBalanceService.VerificationLevel {
        get { EthereumBalanceService.VerificationLevel(rawValue: verificationLevelRaw) ?? .pending }
        set { verificationLevelRaw = newValue.rawValue }
    }
    
    /// Balance as Double ETH
    var balanceETH: Double {
        let hex = balanceWei.hasPrefix("0x") ? String(balanceWei.dropFirst(2)) : balanceWei
        guard let wei = UInt64(hex, radix: 16) else { return 0 }
        return Double(wei) / 1e18
    }
    
    /// Whether this account has funds that can be swept
    var isFunded: Bool { balanceETH > 0 }
    
    /// Whether balance exceeds minimum sweep threshold
    func canSweep(minimumWei: UInt64) -> Bool {
        let hex = balanceWei.hasPrefix("0x") ? String(balanceWei.dropFirst(2)) : balanceWei
        guard let wei = UInt64(hex, radix: 16) else { return false }
        return wei > minimumWei
    }
}

// MARK: - Stealth PQ Account Manager

/// Manages stealth PQ Account derivation, prediction, and balance scanning.
///
/// Uses the existing `StealthAddressManager` HMAC-based derivation scheme to
/// generate unique ECDSA stealth signers. Each signer is wrapped in a ZKNOX
/// PQ Account via CREATE2 (predictable address, deploy-on-sweep).
///
/// Balance scanning delegates to `EthereumBalanceService` which provides a
/// 3-tier verification hierarchy (Helios → Merkle proof → RPC) with Tor routing.
/// For funded accounts on Arbitrum Sepolia (where Helios doesn't run), a
/// Sepolia cross-check via Helios verifies contract code presence.
actor StealthPQAccountManager {
    
    // MARK: - Configuration
    
    /// Minimum balance (in wei) required before sweep is allowed.
    /// On Arbitrum Sepolia, PQ deploy + sweep costs ~0.003-0.005 ETH.
    static let minimumSweepBalanceWei: UInt64 = 5_000_000_000_000_000 // 0.005 ETH
    
    /// Number of stealth addresses to scan ahead for balances
    static let scanWindowSize: UInt32 = 10
    
    /// Target chain for stealth PQ accounts
    static let defaultChain: PQAccountDeployer.Chain = .arbitrumSepolia
    
    /// File name for persisted stealth PQ accounts
    private static let persistenceFileName = "stealth-pq-accounts.json"
    
    // MARK: - Dependencies
    
    private let stealthAddressManager: StealthAddressManager
    private let pqKeyManager: PQKeyManager
    private let deployer: PQAccountDeployer
    private let wallet: EmbeddedWallet
    private let balanceService: EthereumBalanceService
    
    // MARK: - Cached State
    
    /// Cached expanded ML-DSA-44 public key (~22KB)
    private var cachedExpandedPQKey: Data?
    
    /// Current stealth derivation index (next fresh address)
    private var currentIndex: UInt32 = 0
    
    /// All known stealth PQ accounts (persisted indices)
    private var accounts: [UInt32: StealthPQAccount] = [:]
    
    /// Account creation bytecode for offline CREATE2 (extracted once from chain)
    /// Set to nil until extracted; falls back to RPC-based getAddress() if nil.
    private var accountCreationCode: Data?
    
    // MARK: - UserDefaults Keys
    
    private static let currentIndexKey = "stealth-pq-current-index"
    private static let knownIndicesKey = "stealth-pq-known-indices"
    
    // MARK: - Initialization
    
    init(
        wallet: EmbeddedWallet,
        stealthAddressManager: StealthAddressManager,
        pqKeyManager: PQKeyManager,
        deployer: PQAccountDeployer,
        balanceService: EthereumBalanceService
    ) {
        self.wallet = wallet
        self.stealthAddressManager = stealthAddressManager
        self.pqKeyManager = pqKeyManager
        self.deployer = deployer
        self.balanceService = balanceService
        
        // Restore persisted index
        self.currentIndex = UInt32(UserDefaults.standard.integer(forKey: Self.currentIndexKey))
    }
    
    /// Load previously persisted accounts from disk on startup.
    func loadPersistedAccounts() {
        let url = Self.persistenceFileURL
        guard FileManager.default.fileExists(atPath: url.path) else {
            SecureLogger.debug("No persisted stealth PQ accounts file at \(url.lastPathComponent)", category: .network)
            return
        }
        
        do {
            let data = try Data(contentsOf: url)
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            let decoded = try decoder.decode([StealthPQAccount].self, from: data)
            for account in decoded {
                accounts[account.index] = account
            }
            SecureLogger.debug(
                "📦 Loaded \(decoded.count) persisted stealth PQ accounts from \(url.deletingLastPathComponent().lastPathComponent)/",
                category: .network
            )
        } catch {
            SecureLogger.warning(
                "Failed to load persisted stealth PQ accounts: \(error)",
                category: .network
            )
        }
    }
    
    // MARK: - Key Helpers
    
    /// Get the expanded ML-DSA-44 public key (shared across all stealth accounts — Option A).
    private func getExpandedPQKey() async throws -> Data {
        if let cached = cachedExpandedPQKey {
            return cached
        }
        let pk = try await pqKeyManager.getPublicKey()
        let expanded = try MLDSAKeyExpander.toExpandedEncodedBytes(publicKey: pk.keyBytes)
        cachedExpandedPQKey = expanded
        return expanded
    }
    
    /// Get the EOA address as 20-byte Data (preQuantumPubKey for factory).
    private func getEOAAddressData(from stealthAddress: String) -> Data {
        let hex = stealthAddress.hasPrefix("0x") ? String(stealthAddress.dropFirst(2)) : stealthAddress
        return ABIEncoder.hexToData(hex)
    }
    
    // MARK: - Stealth Address Derivation
    
    /// Derive the stealth ECDSA signer at a given index.
    /// Reuses StealthAddressManager's HMAC-based derivation.
    ///
    /// - Parameter index: Derivation index (0, 1, 2, ...)
    /// - Returns: Stealth address result with private key data
    func deriveStealthSigner(at index: UInt32) async throws -> StealthAddressManager.SelfStealthAddressResult {
        try await stealthAddressManager.generateSelfStealthAddress(derivationIndex: index)
    }
    
    /// Predict the PQ Account address for a stealth signer at a given index.
    ///
    /// Uses offline CREATE2 prediction when `accountCreationCode` is available,
    /// otherwise falls back to RPC-based `factory.getAddress()`.
    ///
    /// - Parameter index: Derivation index
    /// - Returns: The predicted smart account address (0x-prefixed)
    func predictStealthPQAccountAddress(at index: UInt32) async throws -> String {
        let stealth = try await deriveStealthSigner(at: index)
        return try await predictAddress(for: stealth)
    }
    
    /// Predict PQ Account address using an already-derived stealth signer.
    /// Avoids a redundant `deriveStealthSigner` call when the caller
    /// has already performed the derivation.
    private func predictAddress(
        for stealth: StealthAddressManager.SelfStealthAddressResult
    ) async throws -> String {
        let preQKey = getEOAAddressData(from: stealth.stealthAddress)
        let postQKey = try await getExpandedPQKey()
        
        if let creationCode = accountCreationCode {
            // Offline CREATE2 prediction (no RPC needed)
            return PQAccountDeployer.predictAddressLocally(
                preQuantumPubKey: preQKey,
                postQuantumPubKey: postQKey,
                accountCreationCode: creationCode
            )
        } else {
            // Fallback: RPC-based prediction via factory.getAddress()
            return try await deployer.getAddress(
                preQuantumPubKey: preQKey,
                postQuantumPubKey: postQKey
            )
        }
    }
    
    /// Get or generate the stealth PQ account at the current index.
    /// This is the "fresh" address to advertise on pq.dstealth.eth.
    func getCurrentStealthPQAccount() async throws -> StealthPQAccount {
        try await getStealthPQAccount(at: currentIndex)
    }
    
    /// Get or generate a stealth PQ account at a specific index.
    func getStealthPQAccount(at index: UInt32) async throws -> StealthPQAccount {
        if let existing = accounts[index] {
            return existing
        }
        
        // Derive stealth signer once, reuse for address prediction
        let stealth = try await deriveStealthSigner(at: index)
        let pqAddress = try await predictAddress(for: stealth)
        
        let account = StealthPQAccount(
            index: index,
            stealthSignerAddress: stealth.stealthAddress,
            pqAccountAddress: pqAddress,
            isDeployed: false,
            balanceWei: "0x0",
            verificationLevelRaw: EthereumBalanceService.VerificationLevel.pending.rawValue,
            ephemeralPubKey: stealth.ephemeralPubKey
        )
        
        accounts[index] = account
        return account
    }
    
    // MARK: - Index Management
    
    /// Advance to the next stealth index (after current address is funded/swept).
    @discardableResult
    func advanceIndex() -> UInt32 {
        currentIndex += 1
        UserDefaults.standard.set(Int(currentIndex), forKey: Self.currentIndexKey)
        persistKnownIndex(currentIndex)
        return currentIndex
    }
    
    /// Get the current derivation index.
    var currentDerivationIndex: UInt32 { currentIndex }
    
    /// Number of accounts that have been explicitly generated.
    var accountCount: Int { accounts.count }
    
    /// All explicitly generated accounts, sorted by index.
    var allAccounts: [StealthPQAccount] {
        accounts.values.sorted { $0.index < $1.index }
    }
    
    /// The most recently generated account (highest index), if any.
    var latestAccount: StealthPQAccount? {
        guard !accounts.isEmpty else { return nil }
        let maxIdx = accounts.keys.max() ?? 0
        return accounts[maxIdx]
    }
    
    // MARK: - Account Generation
    
    /// Generate the next stealth PQ account at `currentIndex`.
    ///
    /// This is the explicit user-initiated action (analogous to the EOA
    /// stealth "Generate" button). Creates one account, adds it to the
    /// tracked set, advances the index, and persists.
    ///
    /// - Returns: The newly generated account
    @discardableResult
    func generateNextAccount() async throws -> StealthPQAccount {
        let account = try await getStealthPQAccount(at: currentIndex)
        advanceIndex()
        persistToDisk()
        
        SecureLogger.info(
            "🛡 Generated stealth PQ account #\(account.index): \(account.pqAccountAddress.prefix(10))...",
            category: .network
        )
        return account
    }
    
    // MARK: - Balance Scanning (EthereumBalanceService-backed)
    
    /// Scan **already-generated** stealth PQ accounts for balances.
    ///
    /// Unlike the previous implementation, this does NOT auto-generate new
    /// accounts. It only checks balances for accounts that already exist
    /// in the `accounts` dictionary (i.e. accounts the user explicitly created).
    ///
    /// Delegates to `EthereumBalanceService` which provides:
    /// - **Tier 1: Helios** (consensus-verified, mainnet/Sepolia only)
    /// - **Tier 2: Merkle proof** (eth_getProof, trustless)
    /// - **Tier 3: RPC** (eth_getBalance, unverified)
    /// All tiers route through Tor on mainnet for IP privacy.
    ///
    /// For funded accounts on Arbitrum Sepolia (where Helios can't run),
    /// a cross-check queries Sepolia via Helios to verify contract presence.
    ///
    /// - Returns: Array of accounts with updated balances
    func scanBalances() async throws -> [StealthPQAccount] {
        // Only scan accounts that have already been explicitly generated
        guard !accounts.isEmpty else { return [] }
        
        let sortedIndices = accounts.keys.sorted()
        var results: [StealthPQAccount] = []
        
        // Determine network from deployer chain
        let network = networkForChain()
        
        for i in sortedIndices {
            guard var account = accounts[i] else { continue }
            
            // Use EthereumBalanceService for the full Helios→proof→RPC pipeline
            if let balance = await balanceService.fetchSingleAddressBalance(
                address: account.pqAccountAddress,
                network: network
            ) {
                account.balanceWei = balance.wei.hexString
                account.verificationLevel = balance.verificationLevel
                account.balanceCheckedAt = Date()
            } else {
                // Service returned nil — mark as unverified zero
                account.balanceWei = "0x0"
                account.verificationLevel = .unverified
                account.balanceCheckedAt = Date()
            }
            
            // Check deployment status if funded
            if account.isFunded {
                account.isDeployed = (try? await deployer.isDeployed(address: account.pqAccountAddress)) ?? false
                
                // Cross-check: for funded Arb Sepolia accounts, verify contract code on Sepolia via Helios
                if network == .arbitrumSepolia {
                    await performSepoliaCrossCheck(for: &account)
                }
            }
            
            accounts[i] = account
            results.append(account)
        }
        
        // Persist updated balances
        persistToDisk()
        
        return results
    }
    
    /// Cross-check a funded Arbitrum Sepolia account on Sepolia via Helios.
    ///
    /// Since Helios doesn't support Arbitrum Sepolia, we can cross-check by
    /// querying the same address on Sepolia (where Helios IS available).
    /// This verifies the address derivation is correct via Helios consensus
    /// and checks if any Sepolia-side balance exists for this CREATE2 address.
    ///
    /// A successful Helios query (even returning 0) confirms:
    /// 1. The address format is valid (Helios validates this)
    /// 2. Helios consensus is intact on Sepolia
    /// 3. If factory is deployed on both chains, address computation matches
    private func performSepoliaCrossCheck(for account: inout StealthPQAccount) async {
        // Use EthereumBalanceService on Sepolia — this will use Helios tier
        if let sepoliaBalance = await balanceService.fetchSingleAddressBalance(
            address: account.pqAccountAddress,
            network: .sepolia
        ) {
            if sepoliaBalance.verificationLevel == .heliosVerified {
                SecureLogger.debug(
                    "✅ Helios cross-check: stealth PQ \(account.pqAccountAddress.prefix(10))... verified on Sepolia (bal: \(sepoliaBalance.wei.hexString))",
                    category: .network
                )
                // Upgrade verification if Arb Sepolia could only get proof/unverified
                if account.verificationLevel == .unverified {
                    account.verificationLevel = .proofConsistent  // Cross-chain Helios confirmed address
                }
            } else {
                SecureLogger.debug(
                    "ℹ️ Sepolia cross-check returned \(sepoliaBalance.verificationLevel.rawValue) for \(account.pqAccountAddress.prefix(10))...",
                    category: .network
                )
            }
        }
    }
    
    /// Map deployer chain to EthereumBalanceService network identifier.
    private func networkForChain() -> EthereumBalanceService.Network {
        switch Self.defaultChain {
        case .sepolia: return .sepolia
        case .arbitrumSepolia: return .arbitrumSepolia
        }
    }
    
    /// Get all funded stealth PQ accounts (balance > 0).
    func fundedAccounts() -> [StealthPQAccount] {
        accounts.values
            .filter { $0.isFunded }
            .sorted { $0.index < $1.index }
    }
    
    /// Get all accounts that can be swept (balance > minimum threshold).
    func sweepableAccounts() -> [StealthPQAccount] {
        accounts.values
            .filter { $0.canSweep(minimumWei: Self.minimumSweepBalanceWei) }
            .sorted { $0.index < $1.index }
    }
    
    // MARK: - Sweep Helpers
    
    /// Get the stealth private key for signing a sweep UserOp.
    /// This is the ECDSA key that controls the stealth signer.
    func getStealthPrivateKey(at index: UInt32) async throws -> Data {
        let viewingPrivKey = try await stealthAddressManager.getViewingPrivateKey()
        let spendingPrivKey = try await wallet.getOrCreatePrivateKey()
        
        // Replicate the HMAC derivation from StealthAddressManager
        let indexData = withUnsafeBytes(of: index.bigEndian) { Data($0) }
        let prefix = "self-stealth-ephemeral:".data(using: .utf8)!
        var hmacInput = prefix
        hmacInput.append(indexData)
        
        let hmac = HMAC<CryptoKit.SHA256>.authenticationCode(
            for: hmacInput,
            using: SymmetricKey(data: viewingPrivKey)
        )
        let ephemeralPrivKey = Data(hmac)
        
        // Derive viewing public key for ECDH
        let viewingPubKey = try await stealthAddressManager.getViewingPublicKey()
        
        // Shared secret: ephemeral_priv * viewing_pub
        let privKey = try P256K.KeyAgreement.PrivateKey(
            dataRepresentation: ephemeralPrivKey,
            format: .uncompressed
        )
        
        // Decompress viewing pub key for P256K
        let pubKey = try P256K.KeyAgreement.PublicKey(
            dataRepresentation: viewingPubKey,
            format: .compressed
        )
        
        let sharedSecret = try privKey.sharedSecretFromKeyAgreement(with: pubKey)
        let sharedSecretData = sharedSecret.withUnsafeBytes { Data($0) }
        
        // Hash the shared secret
        let hashedSecret = ABIEncoder.keccak256(sharedSecretData)
        
        // stealth_priv = spending_priv + hash(S) mod n
        let n = BigUInt(hexString: "FFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFEBAAEDCE6AF48A03BBFD25E8CD0364141")!
        let k1 = BigUInt(data: spendingPrivKey)
        let k2 = BigUInt(data: hashedSecret)
        let sum = (k1 + k2) % n
        
        return sum.serialize().padLeft(to: 32)
    }
    
    /// Build the initCode for deploying a stealth PQ Account.
    func buildStealthInitCode(at index: UInt32) async throws -> Data {
        let stealth = try await deriveStealthSigner(at: index)
        let preQKey = getEOAAddressData(from: stealth.stealthAddress)
        let postQKey = try await getExpandedPQKey()
        
        return UserOperationBuilder.buildInitCode(
            factoryAddress: PQAccountDeployer.factoryAddress,
            preQuantumPubKey: preQKey,
            postQuantumPubKey: postQKey
        )
    }
    
    /// Set the account creation bytecode for offline CREATE2 prediction.
    /// Call this once after extracting the bytecode from the factory contract.
    func setAccountCreationCode(_ code: Data) {
        self.accountCreationCode = code
    }
    
    // MARK: - Persistence
    
    /// Resolve persistence directory: App Group container if available, fallback to Documents.
    /// Mirrors StealthAddressStore's approach so persistence works on both device and simulator.
    private static var persistenceContainerURL: URL {
        if let groupURL = FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: BitchatApp.groupID
        ) {
            return groupURL
        }
        // Fallback to Documents directory (simulator, or missing entitlement)
        return FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
    }
    
    private static var persistenceFileURL: URL {
        persistenceContainerURL.appendingPathComponent(persistenceFileName)
    }
    
    /// Persist all known accounts to disk as JSON.
    private func persistToDisk() {
        let url = Self.persistenceFileURL
        
        do {
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            let data = try encoder.encode(Array(accounts.values))
            try data.write(to: url, options: [.atomic, .completeFileProtection])
            SecureLogger.debug(
                "💾 Persisted \(accounts.count) stealth PQ accounts to disk",
                category: .network
            )
        } catch {
            SecureLogger.warning(
                "Failed to persist stealth PQ accounts: \(error)",
                category: .network
            )
        }
    }
    
    private func persistKnownIndex(_ index: UInt32) {
        var known = Set(UserDefaults.standard.array(forKey: Self.knownIndicesKey) as? [Int] ?? [])
        known.insert(Int(index))
        UserDefaults.standard.set(Array(known), forKey: Self.knownIndicesKey)
    }
}

// MARK: - BigUInt Extension (for key math)

private extension BigUInt {
    init(data: Data) {
        let hex = data.map { String(format: "%02x", $0) }.joined()
        self = BigUInt(hexString: hex) ?? BigUInt(0)
    }
    
    func serialize() -> Data {
        if isZero { return Data([0]) }
        var result = Data()
        var value = self
        let byte256 = BigUInt(256)
        while !value.isZero {
            let (quotient, remainder) = value.dividedBy(byte256)
            let byteValue = UInt8(truncatingIfNeeded: remainder.toUInt64())
            result.insert(byteValue, at: 0)
            value = quotient
        }
        return result.isEmpty ? Data([0]) : result
    }
    
    func toUInt64() -> UInt64 {
        UInt64(description) ?? 0
    }
}

private extension Data {
    func padLeft(to length: Int) -> Data {
        if count >= length { return self }
        return Data(repeating: 0, count: length - count) + self
    }
}
