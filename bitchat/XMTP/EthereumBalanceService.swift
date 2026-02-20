//
// EthereumBalanceService.swift
// bitchat
//
// Privacy-focused Ethereum balance fetching using Flashbots Protect RPC via Tor.
// Flashbots Protect prevents transaction frontrunning and provides additional privacy.
//
// This is free and unencumbered software released into the public domain.
// For more information, see <https://unlicense.org>
//

import BitLogger
import Combine
import Foundation
import Tor

/// Service for fetching Ethereum wallet balances using privacy-focused RPC providers.
/// Routes requests through Tor for additional anonymity.
@MainActor
final class EthereumBalanceService: ObservableObject {
    /// Supported networks for balance fetching
    enum Network: String, CaseIterable {
        case ethereum = "Ethereum"
        case base = "Base"
        case arbitrum = "Arbitrum"
        case sepolia = "Sepolia"
        case arbitrumSepolia = "Arbitrum Sepolia"
        
        var chainId: Int {
            switch self {
            case .ethereum: return 1
            case .base: return 8453
            case .arbitrum: return 42161
            case .sepolia: return 11155111
            case .arbitrumSepolia: return 421614
            }
        }
        
        var rpcURL: URL {
            switch self {
            case .ethereum:
                // Flashbots Protect RPC - private, no frontrunning
                // https://docs.flashbots.net/flashbots-protect/quick-start
                return URL(string: "https://rpc.flashbots.net")!
            case .base:
                // Base public RPC (consider privacy alternatives in production)
                return URL(string: "https://mainnet.base.org")!
            case .arbitrum:
                // Arbitrum One public RPC
                return URL(string: "https://arb1.arbitrum.io/rpc")!
            case .sepolia:
                // Sepolia testnet - use dRPC (reliable public endpoint)
                return URL(string: "https://sepolia.drpc.org")!
            case .arbitrumSepolia:
                // Arbitrum Sepolia testnet
                return URL(string: "https://sepolia-rollup.arbitrum.io/rpc")!
            }
        }
        
        /// Fallback RPC URLs for each network
        var fallbackRPCs: [URL] {
            switch self {
            case .ethereum:
                return [
                    URL(string: "https://eth.llamarpc.com")!,
                    URL(string: "https://rpc.ankr.com/eth")!
                ]
            case .base:
                return [
                    URL(string: "https://base.llamarpc.com")!,
                    URL(string: "https://rpc.ankr.com/base")!
                ]
            case .arbitrum:
                return [
                    URL(string: "https://arbitrum.llamarpc.com")!,
                    URL(string: "https://rpc.ankr.com/arbitrum")!
                ]
            case .sepolia:
                return [
                    URL(string: "https://rpc2.sepolia.org")!,
                    URL(string: "https://1rpc.io/sepolia")!
                ]
            case .arbitrumSepolia:
                return [
                    URL(string: "https://arbitrum-sepolia.blockpi.network/v1/rpc/public")!
                ]
            }
        }
        
        var isTestnet: Bool {
            switch self {
            case .ethereum, .base, .arbitrum: return false
            case .sepolia, .arbitrumSepolia: return true
            }
        }
        
        var symbol: String {
            switch self {
            case .ethereum, .sepolia: return "ETH"
            case .base: return "ETH"
            case .arbitrum, .arbitrumSepolia: return "ETH"
            }
        }
        
        /// Networks shown in mainnet mode
        static var mainnets: [Network] {
            [.ethereum, .base, .arbitrum]
        }
        
        /// Networks shown in testnet mode
        static var testnets: [Network] {
            [.sepolia, .arbitrumSepolia]
        }
    }
    
    /// The trust level of a balance result.
    enum VerificationLevel: String, Equatable {
        /// Trustlessly verified via Helios consensus light client.
        /// State root attested by Ethereum's sync committee (BLS signatures).
        case heliosVerified
        
        /// Merkle proof is internally consistent, but the state root
        /// came from the same untrusted RPC (Phase 1 — not fully trustless).
        case proofConsistent
        
        /// No proof verification performed; RPC response trusted as-is.
        case unverified
        
        /// Balance has not been fetched yet.
        case pending
    }
    
    struct Balance: Equatable {
        let network: Network
        let wei: BigUInt
        let lastUpdated: Date
        /// How this balance was verified
        let verificationLevel: VerificationLevel
        
        /// Backwards-compatible convenience: true if any form of proof was checked
        var isProofVerified: Bool {
            verificationLevel == .heliosVerified || verificationLevel == .proofConsistent
        }
        
        init(network: Network, wei: BigUInt, lastUpdated: Date, verificationLevel: VerificationLevel = .unverified) {
            self.network = network
            self.wei = wei
            self.lastUpdated = lastUpdated
            self.verificationLevel = verificationLevel
        }
        
        /// Legacy initializer for backwards compat
        init(network: Network, wei: BigUInt, lastUpdated: Date, isProofVerified: Bool) {
            self.network = network
            self.wei = wei
            self.lastUpdated = lastUpdated
            self.verificationLevel = isProofVerified ? .proofConsistent : .unverified
        }
        
        var eth: Double {
            let divisor = BigUInt(10).power(18)
            let wholePart = wei / divisor
            let fractionalPart = wei % divisor
            
            // Convert to Double with reasonable precision
            let fractionalDouble = fractionalPart.toDouble() / divisor.toDouble()
            return wholePart.toDouble() + fractionalDouble
        }
        
        var formattedETH: String {
            String(format: "%.6f", eth)
        }
    }
    
    // MARK: - Published State
    
    @Published private(set) var balances: [Network: Balance] = [:]
    @Published private(set) var isLoading: Bool = false
    @Published private(set) var lastError: String?
    
    /// Monotonically increasing counter used to discard stale fetch results.
    /// Incremented by `clearBalances()` so that any in-flight `fetchBalances`
    /// stops writing into `balances` after a mode switch.
    private var fetchGeneration: Int = 0
    @Published var useTestnet: Bool = true {
        didSet {
            UserDefaults.standard.set(useTestnet, forKey: "wallet-use-testnet")
            // Clear balances when switching network mode
            balances.removeAll()
        }
    }
    
    // MARK: - Properties
    
    private var activeNetworks: [Network] {
        useTestnet ? Network.testnets : Network.mainnets
    }
    
    // MARK: - Initialization
    
    init() {
        // Load saved testnet preference (default to true for safety)
        if UserDefaults.standard.object(forKey: "wallet-use-testnet") != nil {
            self.useTestnet = UserDefaults.standard.bool(forKey: "wallet-use-testnet")
        } else {
            self.useTestnet = true
        }
        
        // Load proof verification preference (default to enabled)
        if UserDefaults.standard.object(forKey: "wallet-proof-verification") != nil {
            self.proofVerificationEnabled = UserDefaults.standard.bool(forKey: "wallet-proof-verification")
        } else {
            self.proofVerificationEnabled = true
        }
    }
    
    // MARK: - Public Methods
    
    /// Clear all cached balances (e.g. when switching between EOA and PQ account).
    /// Also invalidates any in-flight `fetchBalances` calls so their stale results
    /// are discarded instead of being written back into `balances`.
    func clearBalances() {
        fetchGeneration += 1
        balances.removeAll()
        lastError = nil
    }
    
    /// Fetches balance for the given address on all supported networks.
    ///
    /// Uses `fetchGeneration` to detect if `clearBalances()` was called while
    /// results were still arriving. If the generation has advanced, remaining
    /// results are discarded so that balances from a previous address never
    /// leak into the current view.
    func fetchBalances(for address: String) async {
        guard isValidAddress(address) else {
            lastError = "Invalid Ethereum address"
            return
        }
        
        let myGeneration = fetchGeneration
        isLoading = true
        lastError = nil
        
        await withTaskGroup(of: (Network, Balance?).self) { group in
            for network in activeNetworks {
                group.addTask { [weak self] in
                    guard let self = self else { return (network, nil) }
                    let balance = await self.fetchBalance(for: address, network: network)
                    return (network, balance)
                }
            }
            
            for await (network, balance) in group {
                // If clearBalances() was called (e.g. user toggled account mode),
                // the generation will have advanced — discard all remaining results.
                guard myGeneration == fetchGeneration else {
                    group.cancelAll()
                    break
                }
                if let balance = balance {
                    balances[network] = balance
                }
            }
        }
        
        // Only clear loading state if we're still the active fetch
        if myGeneration == fetchGeneration {
            isLoading = false
        }
    }
    
    /// Whether proof verification is enabled (Phase 1 of Helios integration).
    /// When true, balances are fetched via eth_getProof and verified against
    /// the block's state root using Merkle-Patricia trie proofs.
    @Published var proofVerificationEnabled: Bool = true {
        didSet {
            UserDefaults.standard.set(proofVerificationEnabled, forKey: "wallet-proof-verification")
        }
    }
    
    /// Statistics on proof verification (visible in Wallet Settings)
    @Published private(set) var proofStats = ProofStats()
    
    struct ProofStats {
        var totalQueries: Int = 0
        var proofVerified: Int = 0
        var proofFailed: Int = 0
        var fallbackUsed: Int = 0
        var mismatchDetected: Int = 0
        var heliosVerified: Int = 0
        var heliosFailed: Int = 0
        
        var verificationRate: Double {
            guard totalQueries > 0 else { return 0 }
            return Double(proofVerified + heliosVerified) / Double(totalQueries)
        }
    }
    
    // MARK: - Balance Fetching
    
    /// Fetches balance for a specific network.
    ///
    /// Verification hierarchy (best to worst):
    /// 1. **Helios** — Trustlessly verified against consensus-attested state root
    /// 2. **Phase 1 proof** — Merkle proof checked, but state root from same RPC
    /// 3. **Unverified** — Raw eth_getBalance, trusting RPC
    func fetchBalance(for address: String, network: Network) async -> Balance? {
        // Tier 1: Try Helios trustless verification (Ethereum mainnet only for now)
        if await heliosAvailableForNetwork(network) {
            if let balance = await fetchBalanceViaHelios(for: address, network: network) {
                return balance
            }
            // Helios failed — fall through to Phase 1 proof
            SecureLogger.warning(
                "EthereumBalanceService: Helios verification failed for \(network.rawValue), trying proof fallback",
                category: .network
            )
        }
        
        // Tier 2: Try Phase 1 proof-consistent verification (eth_getProof)
        if proofVerificationEnabled {
            if let balance = await fetchBalanceWithProof(for: address, network: network) {
                return balance
            }
            // Proof verification failed — fall through to unverified
            SecureLogger.warning(
                "EthereumBalanceService: Proof verification failed for \(network.rawValue), falling back to eth_getBalance",
                category: .network
            )
            await MainActor.run { proofStats.fallbackUsed += 1 }
        }
        
        // Tier 3: Unverified eth_getBalance (legacy path, trusts RPC)
        return await fetchBalanceUnverified(for: address, network: network)
    }
    
    /// Check if Helios is available for a given network.
    /// Currently Helios supports Ethereum mainnet and Sepolia.
    /// Also verifies Helios is synced to the matching network.
    private func heliosAvailableForNetwork(_ network: Network) async -> Bool {
        // Only use Helios for networks it supports
        let isRunning = await HeliosManager.shared.isRunning
        guard isRunning else { return false }
        let activeNet = await HeliosManager.shared.activeNetwork
        switch network {
        case .ethereum:
            return activeNet == .mainnet
        case .sepolia:
            return activeNet == .sepolia
        case .base, .arbitrum, .arbitrumSepolia:
            // Phase 2: Add Base (OP Stack) support
            return false
        }
    }
    
    /// Fetch balance via Helios trustless light client.
    /// Returns `.heliosVerified` balance or nil on failure.
    private func fetchBalanceViaHelios(for address: String, network: Network) async -> Balance? {
        do {
            let balanceHex = try await HeliosManager.shared.getBalance(address: address)
            
            guard let wei = BigUInt(hexString: balanceHex) else {
                SecureLogger.warning(
                    "EthereumBalanceService: Failed to parse Helios balance hex: \(balanceHex)",
                    category: .network
                )
                return nil
            }
            
            await MainActor.run {
                proofStats.totalQueries += 1
                proofStats.heliosVerified += 1
            }
            
            SecureLogger.info(
                "EthereumBalanceService: ✓✓ Helios-verified balance on \(network.rawValue) = \(wei) wei",
                category: .network
            )
            
            return Balance(
                network: network,
                wei: wei,
                lastUpdated: Date(),
                verificationLevel: .heliosVerified
            )
        } catch {
            SecureLogger.warning(
                "EthereumBalanceService: Helios query failed for \(network.rawValue): \(error)",
                category: .network
            )
            await MainActor.run { proofStats.heliosFailed += 1 }
            return nil
        }
    }
    
    /// Fetch balance with Merkle proof verification via eth_getProof.
    /// Returns nil if proof verification fails (caller should fall back).
    private func fetchBalanceWithProof(for address: String, network: Network) async -> Balance? {
        let session = network.isTestnet ? URLSession.shared : TorURLSession.shared.session
        let allRPCs = [network.rpcURL] + network.fallbackRPCs
        
        for rpcURL in allRPCs {
            do {
                // Step 1: Get the latest block header (for state root)
                let blockHeader = try await fetchBlockHeader(
                    session: session,
                    rpcURL: rpcURL,
                    blockTag: "latest"
                )
                
                guard let stateRoot = Data(hexString: blockHeader.stateRoot) else {
                    SecureLogger.warning("EthereumBalanceService: Invalid stateRoot hex from \(rpcURL.host ?? "?")", category: .network)
                    continue
                }
                
                // Step 2: Get the account proof
                let proofResponse = try await fetchGetProof(
                    session: session,
                    rpcURL: rpcURL,
                    address: address,
                    blockTag: blockHeader.numberHex
                )
                
                // Step 3: Verify the proof against the state root
                let result = try MerklePatriciaProof.verifyBalance(
                    proofResponse: proofResponse,
                    stateRoot: stateRoot,
                    blockNumber: blockHeader.number
                )
                
                await MainActor.run {
                    proofStats.totalQueries += 1
                    proofStats.proofVerified += 1
                    if !result.balanceConsistent {
                        proofStats.mismatchDetected += 1
                    }
                }
                
                if !result.balanceConsistent {
                    // RPC lied about the balance! Use the proven balance instead.
                    SecureLogger.error(
                        "EthereumBalanceService: ⚠️ RPC BALANCE MISMATCH on \(network.rawValue)! Using Merkle-proven balance.",
                        category: .network
                    )
                }
                
                SecureLogger.info(
                    "EthereumBalanceService: ✓ Proof-verified balance on \(network.rawValue) = \(result.account.balance) wei (block \(blockHeader.number), via \(rpcURL.host ?? "?"))",
                    category: .network
                )
                
                return Balance(
                    network: network,
                    wei: result.account.balance,
                    lastUpdated: Date(),
                    verificationLevel: .proofConsistent
                )
                
            } catch {
                SecureLogger.warning(
                    "EthereumBalanceService: Proof verification failed via \(rpcURL.host ?? "?"): \(error)",
                    category: .network
                )
                await MainActor.run { proofStats.proofFailed += 1 }
                continue // Try next RPC
            }
        }
        
        return nil // All RPCs failed proof verification
    }
    
    /// Legacy unverified balance fetch via eth_getBalance.
    /// Trusts the RPC provider to return honest data.
    private func fetchBalanceUnverified(for address: String, network: Network) async -> Balance? {
        let session = network.isTestnet ? URLSession.shared : TorURLSession.shared.session
        
        let payload: [String: Any] = [
            "jsonrpc": "2.0",
            "method": "eth_getBalance",
            "params": [address, "latest"],
            "id": 1
        ]
        
        guard let jsonData = try? JSONSerialization.data(withJSONObject: payload) else {
            SecureLogger.error("EthereumBalanceService: Failed to encode request", category: .network)
            return nil
        }
        
        let allRPCs = [network.rpcURL] + network.fallbackRPCs
        
        for rpcURL in allRPCs {
            var request = URLRequest(url: rpcURL)
            request.httpMethod = "POST"
            request.httpBody = jsonData
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.timeoutInterval = 15
            
            do {
                let (data, response) = try await session.data(for: request)
                
                guard let httpResponse = response as? HTTPURLResponse,
                      httpResponse.statusCode == 200 else {
                    SecureLogger.warning("EthereumBalanceService: Bad response from \(rpcURL.host ?? "unknown") for \(network.rawValue)", category: .network)
                    continue
                }
                
                guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let resultHex = json["result"] as? String else {
                    SecureLogger.warning("EthereumBalanceService: Invalid JSON from \(rpcURL.host ?? "unknown") for \(network.rawValue)", category: .network)
                    continue
                }
                
                guard let wei = BigUInt(hexString: resultHex) else {
                    SecureLogger.warning("EthereumBalanceService: Failed to parse balance hex", category: .network)
                    continue
                }
                
                SecureLogger.debug("EthereumBalanceService: \(network.rawValue) balance = \(wei) [unverified] (via \(rpcURL.host ?? "unknown"))", category: .network)
                
                await MainActor.run { proofStats.totalQueries += 1 }
                
                return Balance(network: network, wei: wei, lastUpdated: Date(), verificationLevel: .unverified)
            } catch {
                SecureLogger.warning("EthereumBalanceService: \(rpcURL.host ?? "unknown") failed: \(error.localizedDescription)", category: .network)
                continue
            }
        }
        
        SecureLogger.error("EthereumBalanceService: All RPCs failed for \(network.rawValue)", category: .network)
        await MainActor.run {
            lastError = "Failed to connect to \(network.rawValue) RPC"
        }
        return nil
    }
    
    // MARK: - Single Address Balance Fetch (for external callers)
    
    /// Fetch the verified balance for a single address on a specific network.
    /// This is the public entry point for other actors (e.g. StealthPQAccountManager)
    /// that need to fetch a balance with the full Helios → proof → RPC verification hierarchy.
    ///
    /// Routes through Tor for mainnet, direct for testnet — matching the existing privacy policy.
    func fetchSingleAddressBalance(
        address: String,
        network: Network
    ) async -> Balance? {
        await fetchBalance(for: address, network: network)
    }
    
    // MARK: - RPC Helpers (eth_getProof, eth_getBlockByNumber)
    
    /// Minimal block header fields needed for proof verification.
    struct BlockHeader {
        let number: UInt64
        let numberHex: String
        let stateRoot: String
    }
    
    /// Fetch the block header to obtain the state root.
    private func fetchBlockHeader(
        session: URLSession,
        rpcURL: URL,
        blockTag: String
    ) async throws -> BlockHeader {
        let payload: [String: Any] = [
            "jsonrpc": "2.0",
            "method": "eth_getBlockByNumber",
            "params": [blockTag, false],
            "id": 2
        ]
        
        guard let jsonData = try? JSONSerialization.data(withJSONObject: payload) else {
            throw ProofVerificationError.invalidProof("Failed to encode block request")
        }
        
        var request = URLRequest(url: rpcURL)
        request.httpMethod = "POST"
        request.httpBody = jsonData
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 15
        
        let (data, response) = try await session.data(for: request)
        
        guard let httpResponse = response as? HTTPURLResponse,
              httpResponse.statusCode == 200 else {
            throw ProofVerificationError.invalidProof("Block header request failed")
        }
        
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let result = json["result"] as? [String: Any],
              let stateRoot = result["stateRoot"] as? String,
              let numberHex = result["number"] as? String else {
            throw ProofVerificationError.invalidProof("Invalid block header response")
        }
        
        // Parse block number from hex
        let numStr = numberHex.hasPrefix("0x") ? String(numberHex.dropFirst(2)) : numberHex
        let blockNumber = UInt64(numStr, radix: 16) ?? 0
        
        return BlockHeader(number: blockNumber, numberHex: numberHex, stateRoot: stateRoot)
    }
    
    /// Fetch eth_getProof for an address (no storage keys needed for balance).
    private func fetchGetProof(
        session: URLSession,
        rpcURL: URL,
        address: String,
        blockTag: String
    ) async throws -> EthGetProofResponse {
        let payload: [String: Any] = [
            "jsonrpc": "2.0",
            "method": "eth_getProof",
            "params": [address, [] as [String], blockTag],
            "id": 3
        ]
        
        guard let jsonData = try? JSONSerialization.data(withJSONObject: payload) else {
            throw ProofVerificationError.invalidProof("Failed to encode proof request")
        }
        
        var request = URLRequest(url: rpcURL)
        request.httpMethod = "POST"
        request.httpBody = jsonData
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 20 // Proofs are larger, allow more time
        
        let (data, response) = try await session.data(for: request)
        
        guard let httpResponse = response as? HTTPURLResponse,
              httpResponse.statusCode == 200 else {
            throw ProofVerificationError.invalidProof("eth_getProof request failed")
        }
        
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw ProofVerificationError.invalidProof("Invalid JSON in eth_getProof response")
        }
        
        // Check for JSON-RPC error
        if let error = json["error"] as? [String: Any] {
            let message = error["message"] as? String ?? "Unknown"
            throw ProofVerificationError.invalidProof("RPC error: \(message)")
        }
        
        guard let result = json["result"] as? [String: Any] else {
            throw ProofVerificationError.invalidProof("Missing result in eth_getProof response")
        }
        
        return try EthGetProofResponse.parse(from: result)
    }
    
    // MARK: - Private Helpers
    
    private func isValidAddress(_ address: String) -> Bool {
        // Basic Ethereum address validation
        let stripped = address.hasPrefix("0x") ? String(address.dropFirst(2)) : address
        guard stripped.count == 40 else { return false }
        return stripped.allSatisfy { $0.isHexDigit }
    }
}

// MARK: - BigUInt (Minimal Implementation)

/// Minimal unsigned big integer for wei handling.
/// Avoids external dependencies while supporting 256-bit values.
struct BigUInt: Equatable, CustomStringConvertible {
    private var words: [UInt64]
    
    init(_ value: UInt64 = 0) {
        self.words = value == 0 ? [] : [value]
    }
    
    init?(hexString: String) {
        let hex = hexString.hasPrefix("0x") ? String(hexString.dropFirst(2)) : hexString
        guard !hex.isEmpty else {
            self.words = []
            return
        }
        
        // Parse hex string in 16-character (64-bit) chunks from right to left
        var result: [UInt64] = []
        var remaining = hex
        
        while !remaining.isEmpty {
            let chunkEnd = remaining.endIndex
            let chunkStart = remaining.index(chunkEnd, offsetBy: -min(16, remaining.count))
            let chunk = String(remaining[chunkStart..<chunkEnd])
            
            guard let value = UInt64(chunk, radix: 16) else { return nil }
            result.append(value)
            remaining = String(remaining[..<chunkStart])
        }
        
        // Remove leading zeros
        while result.last == 0 { result.removeLast() }
        self.words = result
    }
    
    var description: String {
        if words.isEmpty { return "0" }
        // Simple decimal conversion for display
        return toDecimalString()
    }
    
    /// Convert to Double (may lose precision for very large values)
    func toDouble() -> Double {
        if words.isEmpty { return 0 }
        
        // For small values, use direct conversion
        if words.count == 1 {
            return Double(words[0])
        }
        
        // For larger values, combine words
        var result: Double = 0
        let multiplier: Double = pow(2, 64)
        var wordMultiplier: Double = 1
        
        for word in words {
            result += Double(word) * wordMultiplier
            wordMultiplier *= multiplier
        }
        
        return result
    }
    
    private func toDecimalString() -> String {
        if words.isEmpty { return "0" }
        
        // For small values, use direct conversion
        if words.count == 1 {
            return String(words[0])
        }
        
        // For larger values, use repeated division
        var result = ""
        var current = self
        let ten = BigUInt(10)
        
        while !current.isZero {
            let (quotient, remainder) = current.dividedBy(ten)
            result = remainder.description + result
            current = quotient
        }
        
        return result.isEmpty ? "0" : result
    }
    
    var isZero: Bool {
        words.isEmpty || words.allSatisfy { $0 == 0 }
    }

    /// Hex string representation (0x-prefixed, no leading zeros).
    var hexString: String {
        if words.isEmpty { return "0x0" }
        var hex = ""
        for (i, word) in words.reversed().enumerated() {
            if i == 0 {
                hex += String(word, radix: 16)
            } else {
                hex += String(format: "%016llx", word)
            }
        }
        return "0x" + hex
    }
    
    static func + (lhs: BigUInt, rhs: BigUInt) -> BigUInt {
        var result: [UInt64] = []
        var carry: UInt64 = 0
        let maxLen = max(lhs.words.count, rhs.words.count)
        
        for i in 0..<maxLen {
            let a = i < lhs.words.count ? lhs.words[i] : 0
            let b = i < rhs.words.count ? rhs.words[i] : 0
            let (sum1, overflow1) = a.addingReportingOverflow(b)
            let (sum2, overflow2) = sum1.addingReportingOverflow(carry)
            result.append(sum2)
            carry = (overflow1 ? 1 : 0) + (overflow2 ? 1 : 0)
        }
        
        if carry > 0 { result.append(carry) }
        while result.last == 0 { result.removeLast() }
        
        var bigUInt = BigUInt()
        bigUInt.words = result
        return bigUInt
    }
    
    static func * (lhs: BigUInt, rhs: BigUInt) -> BigUInt {
        if lhs.isZero || rhs.isZero { return BigUInt() }
        
        var result = Array(repeating: UInt64(0), count: lhs.words.count + rhs.words.count)
        
        for i in 0..<lhs.words.count {
            var carry: UInt64 = 0
            for j in 0..<rhs.words.count {
                let (high, low) = lhs.words[i].multipliedFullWidth(by: rhs.words[j])
                let (sum1, o1) = result[i + j].addingReportingOverflow(low)
                let (sum2, o2) = sum1.addingReportingOverflow(carry)
                result[i + j] = sum2
                carry = high + (o1 ? 1 : 0) + (o2 ? 1 : 0)
            }
            if carry > 0 { result[i + rhs.words.count] = carry }
        }
        
        while result.last == 0 { result.removeLast() }
        var bigUInt = BigUInt()
        bigUInt.words = result
        return bigUInt
    }
    
    static func / (lhs: BigUInt, rhs: BigUInt) -> BigUInt {
        lhs.dividedBy(rhs).quotient
    }
    
    static func % (lhs: BigUInt, rhs: BigUInt) -> BigUInt {
        lhs.dividedBy(rhs).remainder
    }
    
    func dividedBy(_ divisor: BigUInt) -> (quotient: BigUInt, remainder: BigUInt) {
        if divisor.isZero { fatalError("Division by zero") }
        if self.isZero { return (BigUInt(), BigUInt()) }
        
        // Simple case: single word divisor
        if divisor.words.count == 1 {
            let (q, r) = dividedBySingleWord(divisor.words[0])
            return (q, BigUInt(r))
        }
        
        // For larger divisors, use long division (simplified)
        var quotient = BigUInt()
        var remainder = BigUInt()
        
        let bits = words.count * 64
        for i in (0..<bits).reversed() {
            remainder = remainder * BigUInt(2)
            if getBit(i) {
                remainder = remainder + BigUInt(1)
            }
            if remainder >= divisor {
                remainder = remainder - divisor
                quotient.setBit(i)
            }
        }
        
        return (quotient, remainder)
    }
    
    private func dividedBySingleWord(_ divisor: UInt64) -> (quotient: BigUInt, remainder: UInt64) {
        var quotientWords: [UInt64] = []
        var remainder: UInt64 = 0
        
        for word in words.reversed() {
            let dividend = (DoubleWord(remainder) << 64) | DoubleWord(word)
            let (q, r) = dividend.quotientAndRemainder(dividingBy: DoubleWord(divisor))
            quotientWords.insert(q.low, at: 0)
            remainder = r.low
        }
        
        while quotientWords.last == 0 { quotientWords.removeLast() }
        var quotient = BigUInt()
        quotient.words = quotientWords
        return (quotient, remainder)
    }
    
    private func getBit(_ index: Int) -> Bool {
        let wordIndex = index / 64
        let bitIndex = index % 64
        guard wordIndex < words.count else { return false }
        return (words[wordIndex] >> bitIndex) & 1 == 1
    }
    
    private mutating func setBit(_ index: Int) {
        let wordIndex = index / 64
        let bitIndex = index % 64
        while words.count <= wordIndex { words.append(0) }
        words[wordIndex] |= (1 << bitIndex)
    }
    
    static func - (lhs: BigUInt, rhs: BigUInt) -> BigUInt {
        var result: [UInt64] = []
        var borrow: UInt64 = 0
        
        for i in 0..<lhs.words.count {
            let a = lhs.words[i]
            let b = i < rhs.words.count ? rhs.words[i] : 0
            let (diff1, overflow1) = a.subtractingReportingOverflow(b)
            let (diff2, overflow2) = diff1.subtractingReportingOverflow(borrow)
            result.append(diff2)
            borrow = (overflow1 ? 1 : 0) + (overflow2 ? 1 : 0)
        }
        
        while result.last == 0 { result.removeLast() }
        var bigUInt = BigUInt()
        bigUInt.words = result
        return bigUInt
    }
    
    static func >= (lhs: BigUInt, rhs: BigUInt) -> Bool {
        if lhs.words.count != rhs.words.count {
            return lhs.words.count > rhs.words.count
        }
        for i in (0..<lhs.words.count).reversed() {
            if lhs.words[i] != rhs.words[i] {
                return lhs.words[i] > rhs.words[i]
            }
        }
        return true
    }
    
    func power(_ exponent: Int) -> BigUInt {
        if exponent == 0 { return BigUInt(1) }
        var result = BigUInt(1)
        var base = self
        var exp = exponent
        
        while exp > 0 {
            if exp & 1 == 1 {
                result = result * base
            }
            base = base * base
            exp >>= 1
        }
        
        return result
    }
}

// MARK: - DoubleWord Helper (for division)

private struct DoubleWord {
    let high: UInt64
    let low: UInt64
    
    init(_ value: UInt64) {
        self.high = 0
        self.low = value
    }
    
    init(high: UInt64, low: UInt64) {
        self.high = high
        self.low = low
    }
    
    static func << (lhs: DoubleWord, rhs: Int) -> DoubleWord {
        if rhs >= 128 { return DoubleWord(0) }
        if rhs >= 64 {
            return DoubleWord(high: lhs.low << (rhs - 64), low: 0)
        }
        if rhs == 0 { return lhs }
        let newHigh = (lhs.high << rhs) | (lhs.low >> (64 - rhs))
        let newLow = lhs.low << rhs
        return DoubleWord(high: newHigh, low: newLow)
    }
    
    static func | (lhs: DoubleWord, rhs: DoubleWord) -> DoubleWord {
        DoubleWord(high: lhs.high | rhs.high, low: lhs.low | rhs.low)
    }
    
    func quotientAndRemainder(dividingBy divisor: DoubleWord) -> (DoubleWord, DoubleWord) {
        // Simple division for our use case (divisor fits in UInt64)
        if divisor.high == 0 && high == 0 {
            let (q, r) = low.quotientAndRemainder(dividingBy: divisor.low)
            return (DoubleWord(q), DoubleWord(r))
        }
        
        // For cases where dividend is 128-bit but divisor is 64-bit
        if divisor.high == 0 {
            let div = divisor.low
            let (qHigh, remHigh) = high.quotientAndRemainder(dividingBy: div)
            let combined = (DoubleWord(remHigh) << 64) | DoubleWord(low)
            // Approximate division
            let qLow = combined.low / div
            let remainder = combined.low % div
            return (DoubleWord(high: qHigh, low: qLow), DoubleWord(remainder))
        }
        
        // Fallback for larger divisors
        return (DoubleWord(0), self)
    }
}
