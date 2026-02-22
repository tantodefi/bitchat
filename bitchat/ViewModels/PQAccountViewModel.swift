//
// PQAccountViewModel.swift
// bitchat
//
// ViewModel bridging PQ account services to SwiftUI.
// Provides observable state for account deployment, address, and transactions.
// Supports multi-chain deployment (Sepolia, Arbitrum Sepolia, or both).
//
// This is free and unencumbered software released into the public domain.
// For more information, see <https://unlicense.org>
//

import BitLogger
import Combine
import Foundation

// MARK: - PQ Deployment Chain Target

enum PQDeployTarget: String, CaseIterable, Identifiable {
    case sepolia = "Sepolia"
    case arbitrumSepolia = "Arbitrum Sepolia"
    case both = "Both Testnets"
    
    var id: String { rawValue }
    
    var chains: [PQAccountDeployer.Chain] {
        switch self {
        case .sepolia: return [.sepolia]
        case .arbitrumSepolia: return [.arbitrumSepolia]
        case .both: return [.sepolia, .arbitrumSepolia]
        }
    }
    
    var symbol: String { "⛓" }
}

// MARK: - Per-Chain Deployment Status

struct PQChainDeploymentStatus: Equatable, Identifiable {
    let chain: PQAccountDeployer.Chain
    var isDeployed: Bool
    var isDeploying: Bool
    var error: String?
    var txHash: String?
    
    var id: UInt64 { chain.chainId }
    
    var displayName: String { chain.name }
    
    var statusIcon: String {
        if isDeploying { return "arrow.triangle.2.circlepath" }
        if isDeployed { return "checkmark.circle.fill" }
        if error != nil { return "exclamationmark.triangle.fill" }
        return "circle.dashed"
    }
    
    var statusColor: String {
        if isDeploying { return "orange" }
        if isDeployed { return "green" }
        if error != nil { return "red" }
        return "secondary"
    }
}

// MARK: - PQ Account State

enum PQAccountState: Equatable {
    case notInitialized
    case initializing
    case keysReady
    case deploying
    case deployed(String) // account address
    case error(String)
    
    var isDeployed: Bool {
        if case .deployed = self { return true }
        return false
    }
    
    var accountAddress: String? {
        if case .deployed(let addr) = self { return addr }
        return nil
    }
    
    var displayStatus: String {
        switch self {
        case .notInitialized: return "Not initialized"
        case .initializing: return "Initializing..."
        case .keysReady: return "Keys ready (not deployed)"
        case .deploying: return "Deploying..."
        case .deployed(let addr): return "Deployed: \(addr.prefix(10))..."
        case .error(let msg): return "Error: \(msg)"
        }
    }
}

// MARK: - PQ Account ViewModel

@MainActor
final class PQAccountViewModel: ObservableObject {
    
    // MARK: - Published State
    
    @Published private(set) var state: PQAccountState = .notInitialized
    @Published private(set) var accountAddress: String?
    @Published private(set) var pqPublicKeyHex: String?
    @Published private(set) var isProcessingTransaction = false
    @Published private(set) var lastTransactionHash: String?
    @Published private(set) var lastError: String?
    
    /// Per-chain deployment status tracking
    @Published private(set) var chainStatuses: [PQChainDeploymentStatus] = []
    
    /// Selected deployment target
    @Published var deployTarget: PQDeployTarget = .sepolia
    
    /// Minimum gas required for deployment (rough estimate: ~0.005 ETH)
    static let minimumDeploymentGasETH: Double = 0.002
    
    /// UserDefaults key for persisting deployed chain IDs
    private static let deployedChainsKey = "pq-deployed-chain-ids"
    
    /// UserDefaults key for persisting the PQ counterfactual address
    /// (CREATE2 address is deterministic, safe to cache once computed)
    private static let persistedAddressKey = "pq-account-address"
    
    /// Whether the deployment services are configured (Pimlico API key set)
    var canDeploy: Bool {
        !chainServices.isEmpty
    }
    
    /// Whether all chains in the current target are already deployed
    var allTargetChainsDeployed: Bool {
        let targetChainIds = Set(deployTarget.chains.map(\.chainId))
        return targetChainIds.allSatisfy { chainId in
            chainStatuses.first(where: { $0.chain.chainId == chainId })?.isDeployed == true
        }
    }
    
    /// Whether any chain in the current target is currently deploying
    var isAnyTargetDeploying: Bool {
        let targetChainIds = Set(deployTarget.chains.map(\.chainId))
        return targetChainIds.contains(where: { chainId in
            chainStatuses.first(where: { $0.chain.chainId == chainId })?.isDeploying == true
        })
    }
    
    // MARK: - Dependencies
    
    private var pqKeyManager: PQKeyManager?
    
    /// Per-chain service sets (deployer + bundler + signer)
    struct ChainServiceSet {
        let chain: PQAccountDeployer.Chain
        let deployer: PQAccountDeployer
        let bundler: PimlicoBundler
        let signer: PQTransactionSigner
    }
    private var chainServices: [UInt64: ChainServiceSet] = [:]
    
    // MARK: - Configuration
    
    /// Immediately restore cached PQ account address and deployment state
    /// so that `displayAddress` works for PQ-mode users without network.
    /// Call after `configure()` but before `initializeKeys()`.
    func restoreCachedAddressIfNeeded() {
        guard accountAddress == nil else { return }
        if let cached = Self.loadPersistedAccountAddress() {
            accountAddress = cached
            // If any chain was persisted as deployed, honour that state
            if chainStatuses.contains(where: { $0.isDeployed }) {
                state = .deployed(cached)
            }
            SecureLogger.info("PQ address restored from cache early (pre-init)", category: .session)
        }
    }
    
    /// Configure with PQ service dependencies.
    /// Call after XMTPServiceContainer initializes PQ services.
    /// Only pqKeyManager is required; per-chain services are optional
    /// and only needed for on-chain deployment.
    func configure(
        pqKeyManager: PQKeyManager,
        chainServiceSets: [ChainServiceSet] = []
    ) {
        self.pqKeyManager = pqKeyManager
        self.chainServices = Dictionary(uniqueKeysWithValues: chainServiceSets.map { ($0.chain.chainId, $0) })
        
        // Initialize per-chain status tracking, restoring persisted deployment state
        let persistedChainIds = Self.loadDeployedChainIds()
        chainStatuses = PQAccountDeployer.Chain.allCases.map { chain in
            PQChainDeploymentStatus(
                chain: chain,
                isDeployed: persistedChainIds.contains(chain.chainId),
                isDeploying: false
            )
        }
    }
    
    // MARK: - Balance Checking
    
    /// Check if the wallet has sufficient gas on the given chain for deployment.
    /// Returns (hasSufficientGas, currentBalanceETH) tuple.
    func checkDeploymentBalance(
        chain: PQAccountDeployer.Chain,
        balanceService: EthereumBalanceService
    ) -> (sufficient: Bool, balance: Double) {
        let network: EthereumBalanceService.Network = chain == .sepolia ? .sepolia : .arbitrumSepolia
        if let balance = balanceService.balances[network] {
            return (balance.eth >= Self.minimumDeploymentGasETH, balance.eth)
        }
        return (false, 0)
    }
    
    /// Check all target chains for sufficient gas.
    /// Returns chains that have insufficient balance.
    func insufficientBalanceChains(
        balanceService: EthereumBalanceService
    ) -> [(chain: PQAccountDeployer.Chain, balance: Double)] {
        return deployTarget.chains.compactMap { chain in
            let (sufficient, balance) = checkDeploymentBalance(chain: chain, balanceService: balanceService)
            if !sufficient {
                return (chain, balance)
            }
            return nil
        }
    }
    
    // MARK: - Initialization
    
    /// Initialize PQ keys from the embedded wallet.
    /// Call this during app startup after the wallet is ready.
    func initializeKeys(from wallet: EmbeddedWallet) async {
        guard let pqKeyManager else {
            state = .error("PQ services not configured")
            return
        }
        
        state = .initializing
        lastError = nil
        
        do {
            let _ = try await pqKeyManager.getOrCreateKeys(from: wallet)
            
            // Get public key for display
            let pubKey = try await pqKeyManager.getPublicKey()
            let pubKeyBytes = pubKey.keyBytes
            let hexStr = pubKeyBytes.prefix(16).map { String(format: "%02x", $0) }.joined()
            pqPublicKeyHex = hexStr + "..."
            
            // Compute counterfactual address (same on all chains due to CREATE2)
            if let firstService = chainServices.values.first {
                // Factory expects ETH address (20 bytes) as preQuantumPubKey
                let eoaAddress = try await wallet.getAddress()
                let eoaHex = eoaAddress.hasPrefix("0x") ? String(eoaAddress.dropFirst(2)) : eoaAddress
                let preQKey = ABIEncoder.hexToData(eoaHex)
                
                // Factory expects expanded ML-DSA key (~22KB) as postQuantumPubKey
                let expandedPQKey = try MLDSAKeyExpander.toExpandedEncodedBytes(publicKey: pubKey.keyBytes)
                
                // Timeout the address computation (15s max)
                let address: String? = try? await withThrowingTaskGroup(of: String.self) { group in
                    group.addTask {
                        try await firstService.deployer.getAddress(
                            preQuantumPubKey: preQKey,
                            postQuantumPubKey: expandedPQKey
                        )
                    }
                    group.addTask {
                        try await Task.sleep(nanoseconds: 15_000_000_000)
                        throw DeployerError.networkError("Timeout computing address")
                    }
                    let result = try await group.next()!
                    group.cancelAll()
                    return result
                }
                
                if let address {
                    accountAddress = address
                    Self.persistAccountAddress(address)
                    
                    // Check deployment status on all configured chains
                    await checkAllChainDeployments(address: address)
                    
                    // If deployed on any chain, show as deployed
                    if chainStatuses.contains(where: { $0.isDeployed }) {
                        state = .deployed(address)
                    } else {
                        state = .keysReady
                    }
                } else if let cachedAddress = Self.loadPersistedAccountAddress() {
                    // Address computation timed out (offline) — restore from cache
                    accountAddress = cachedAddress
                    
                    // chainStatuses already restored persisted deployment flags in configure(),
                    // so if any chain was previously deployed, honour that state offline.
                    if chainStatuses.contains(where: { $0.isDeployed }) {
                        state = .deployed(cachedAddress)
                        SecureLogger.info("PQ address restored from cache (offline), state: deployed", category: .session)
                    } else {
                        state = .keysReady
                        SecureLogger.warning("PQ address restored from cache but no deployed chains found", category: .session)
                    }
                } else {
                    // Address computation timed out — keys are still ready
                    state = .keysReady
                    SecureLogger.warning("PQ address computation timed out, continuing with keys ready", category: .session)
                }
            } else {
                // No chain services configured — try restoring cached address
                if let cachedAddress = Self.loadPersistedAccountAddress(),
                   chainStatuses.contains(where: { $0.isDeployed }) {
                    accountAddress = cachedAddress
                    state = .deployed(cachedAddress)
                } else {
                    state = .keysReady
                }
            }
            
            SecureLogger.info("PQ account initialized, state: \(state.displayStatus)", category: .session)
            
        } catch {
            // If we have a cached address + persisted deployment, restore
            // deployed state so the wallet remains usable offline.
            if let cachedAddress = Self.loadPersistedAccountAddress(),
               chainStatuses.contains(where: { $0.isDeployed }) {
                accountAddress = cachedAddress
                state = .deployed(cachedAddress)
                lastError = nil
                SecureLogger.info("PQ key init failed but restored deployed state from cache (offline)", category: .session)
            } else {
                state = .error(error.localizedDescription)
                lastError = error.localizedDescription
                SecureLogger.error("PQ key initialization failed: \(error)", category: .session)
            }
        }
    }
    
    /// Check deployment status on all configured chains (concurrent with timeout).
    /// Never downgrades a persisted "deployed" status on RPC failure — only
    /// upgrades "not deployed" → "deployed" when an RPC confirms it.
    private func checkAllChainDeployments(address: String) async {
        await withTaskGroup(of: (UInt64, Bool?).self) { group in
            for (chainId, serviceSet) in chainServices {
                group.addTask {
                    do {
                        // 10-second timeout per chain check
                        let deployed = try await withThrowingTaskGroup(of: Bool.self) { inner in
                            inner.addTask {
                                try await serviceSet.deployer.isDeployed(address: address)
                            }
                            inner.addTask {
                                try await Task.sleep(nanoseconds: 10_000_000_000)
                                throw DeployerError.networkError("Timeout checking deployment")
                            }
                            let result = try await inner.next()!
                            inner.cancelAll()
                            return result
                        }
                        return (chainId, deployed)
                    } catch {
                        // RPC failed — return nil so we don't override persisted state
                        return (chainId, nil)
                    }
                }
            }
            for await (chainId, rpcResult) in group {
                if let idx = chainStatuses.firstIndex(where: { $0.chain.chainId == chainId }) {
                    if let rpcResult {
                        // RPC responded — update and persist if newly deployed
                        if rpcResult && !chainStatuses[idx].isDeployed {
                            chainStatuses[idx].isDeployed = true
                            Self.persistDeployedChainId(chainId)
                        } else if rpcResult {
                            chainStatuses[idx].isDeployed = true
                        }
                        // Note: we do NOT set isDeployed=false here even if RPC says so,
                        // because a confirmed deployment can't un-deploy (contract is permanent).
                    }
                    // If rpcResult is nil (RPC failed), keep the persisted state as-is.
                }
            }
        }
    }
    
    /// Chains that are not yet deployed but have services configured.
    var undeployedChains: [PQAccountDeployer.Chain] {
        PQAccountDeployer.Chain.allCases.filter { chain in
            let deployed = chainStatuses.first(where: { $0.chain.chainId == chain.chainId })?.isDeployed == true
            let hasServices = chainServices[chain.chainId] != nil
            return !deployed && hasServices
        }
    }
    
    /// Whether there are additional chains available for deployment
    /// (e.g., deployed on Sepolia but not yet on Arbitrum Sepolia).
    var hasUndeployedChains: Bool {
        !undeployedChains.isEmpty
    }
    
    // MARK: - Gas Estimation (UI)
    
    /// Fetch the live gas price from the network for UI gas estimation.
    /// Uses Helios on Sepolia when available, otherwise RPC.
    /// Returns gas price in wei. Falls back to 2 gwei on error.
    func fetchLiveGasPrice(chain: PQAccountDeployer.Chain = .sepolia) async -> UInt64 {
        guard let services = chainServices[chain.chainId] else { return 2_000_000_000 }
        do {
            return try await services.deployer.getGasPrice()
        } catch {
            return 2_000_000_000 // 2 gwei fallback
        }
    }
    
    /// Compute estimated gas cost in wei for a PQ UserOp transfer.
    /// Uses the same maxFee formula as PQTransactionSigner for consistency.
    /// `liveGasPrice` should come from `fetchLiveGasPrice()`.
    static func estimatePQGasCost(liveGasPrice: UInt64) -> BigUInt {
        let basePrice = liveGasPrice > 0 ? liveGasPrice : 2_000_000_000
        // maxFee formula matches PQTransactionSigner.executeTransaction
        let priorityFee = max(basePrice / 10, 100_000_000)  // 10% of base, min 0.1 gwei
        let maxFee = basePrice * 3 / 2 + priorityFee         // 1.5x base + priority
        // Conservative total gas for UI estimate (verification + call + preVerification).
        // ML-DSA-44 on-chain verification is gas-intensive but the bundler
        // does the real estimation at signing time.
        let totalGas: UInt64 = 2_000_000
        return BigUInt(totalGas) * BigUInt(maxFee)
    }
    
    // MARK: - Deployment
    
    /// Deploy the PQ smart account on the selected target chain(s).
    /// Works in both .keysReady and .deployed states — if already deployed
    /// on one chain, deploys on any remaining undeployed chains.
    /// CREATE2 guarantees the same address on all EVM chains.
    func deployToTarget() async {
        let chains = deployTarget.chains
        
        // Filter to only undeployed chains that have services
        let chainsToDeploy = chains.filter { chain in
            let alreadyDeployed = chainStatuses.first(where: { $0.chain.chainId == chain.chainId })?.isDeployed == true
            let hasServices = chainServices[chain.chainId] != nil
            return !alreadyDeployed && hasServices
        }
        
        guard !chainsToDeploy.isEmpty else {
            lastError = "All selected chains already deployed or not configured"
            return
        }
        
        let previousState = state
        state = .deploying
        lastError = nil
        
        // Deploy on each chain concurrently
        await withTaskGroup(of: Void.self) { group in
            for chain in chainsToDeploy {
                group.addTask { [weak self] in
                    await self?.deployOnChain(chain)
                }
            }
        }
        
        // Update overall state
        if let address = accountAddress,
           chainStatuses.contains(where: { $0.isDeployed }) {
            state = .deployed(address)
        } else if chainStatuses.contains(where: { $0.error != nil }) {
            let errors = chainStatuses.compactMap(\.error).joined(separator: "; ")
            // If we were already deployed on at least one chain, stay deployed
            if case .deployed(let addr) = previousState {
                state = .deployed(addr)
                lastError = errors
            } else {
                state = .error(errors)
            }
        } else {
            state = .keysReady
        }
    }
    
    /// Deploy on all remaining undeployed chains (convenience for "Deploy Everywhere").
    func deployOnRemainingChains() async {
        let saved = deployTarget
        deployTarget = .both
        await deployToTarget()
        deployTarget = saved
    }
    
    /// Deploy on a specific chain
    private func deployOnChain(_ chain: PQAccountDeployer.Chain) async {
        guard let serviceSet = chainServices[chain.chainId] else { return }
        
        // Mark deploying
        if let idx = chainStatuses.firstIndex(where: { $0.chain.chainId == chain.chainId }) {
            chainStatuses[idx].isDeploying = true
            chainStatuses[idx].error = nil
        }
        
        do {
            let txHash = try await serviceSet.signer.deployDirect()
            
            if let idx = chainStatuses.firstIndex(where: { $0.chain.chainId == chain.chainId }) {
                chainStatuses[idx].txHash = txHash
            }

            // Persist deploy tx hash to TransactionStore
            if let address = accountAddress {
                TransactionStore.shared.record(
                    CachedTransaction(
                        id: txHash,
                        txHash: txHash,
                        from: address.lowercased(),
                        to: "",
                        value: "0x0",
                        timestamp: Date(),
                        blockNumber: nil,
                        chainId: chain.chainId,
                        source: .pqDeploy
                    ),
                    for: address
                )
            }
            
            // Poll for deployment confirmation
            if let address = accountAddress {
                for _ in 0..<30 {
                    try await Task.sleep(nanoseconds: 4_000_000_000) // 4s
                    if try await serviceSet.deployer.isDeployed(address: address) {
                        if let idx = chainStatuses.firstIndex(where: { $0.chain.chainId == chain.chainId }) {
                            chainStatuses[idx].isDeployed = true
                            chainStatuses[idx].isDeploying = false
                        }
                        Self.persistDeployedChainId(chain.chainId)
                        SecureLogger.info("PQ account deployed on \(chain.name) at \(address)", category: .session)
                        return
                    }
                }
                // Timeout
                if let idx = chainStatuses.firstIndex(where: { $0.chain.chainId == chain.chainId }) {
                    chainStatuses[idx].isDeploying = false
                    chainStatuses[idx].error = "Not confirmed after 120s"
                }
            }
        } catch {
            if let idx = chainStatuses.firstIndex(where: { $0.chain.chainId == chain.chainId }) {
                chainStatuses[idx].isDeploying = false
                chainStatuses[idx].error = error.localizedDescription
            }
            SecureLogger.error("PQ deploy on \(chain.name) failed: \(error)", category: .session)
        }
    }
    
    // MARK: - Legacy single-chain methods (kept for compatibility)
    
    /// Deploy the PQ smart account via ERC-4337 bundler.
    func deploy() async {
        await deployToTarget()
    }
    
    /// Deploy via direct EOA transaction (no bundler).
    func deployDirect() async {
        await deployToTarget()
    }
    
    // MARK: - Transactions
    
    /// Execute a transaction through the PQ smart account on a specific chain.
    /// Falls back to offline mesh relay if the bundler is unreachable.
    func executeTransaction(
        to dest: String,
        value: UInt64 = 0,
        data: Data = Data(),
        chain: PQAccountDeployer.Chain = .sepolia,
        meshRelay: MeshTransactionRelay? = nil,
        replyToPeerId: String? = nil
    ) async -> String? {
        guard let serviceSet = chainServices[chain.chainId] else {
            lastError = "Transaction signer not configured for \(chain.name)"
            return nil
        }
        
        guard state.isDeployed else {
            lastError = "Account not deployed"
            return nil
        }
        
        isProcessingTransaction = true
        lastError = nil
        
        do {
            let hash = try await serviceSet.signer.executeTransaction(
                dest: dest,
                value: value,
                data: data
            )
            lastTransactionHash = hash
            isProcessingTransaction = false

            // Persist to TransactionStore so it appears in history after restart
            if let address = accountAddress {
                TransactionStore.shared.record(
                    CachedTransaction(
                        id: hash,
                        txHash: hash,
                        from: address.lowercased(),
                        to: dest.lowercased(),
                        value: String(format: "0x%llx", value),
                        timestamp: Date(),
                        blockNumber: nil,
                        chainId: chain.chainId,
                        source: .pqAccount
                    ),
                    for: address
                )
            }

            return hash
        } catch {
            // Only fall through to mesh relay for network errors (URLError, timeout, etc.).
            // Bundler validation errors (AA* codes, RPC errors) mean the UserOp is invalid —
            // relaying the same invalid op through a peer won't fix it.
            let isNetworkError: Bool
            if let urlError = error as? URLError {
                isNetworkError = true
                SecureLogger.info("PQ bundler network error (\(urlError.code.rawValue)), will try mesh relay", category: .session)
            } else if case TransactionError.rpcFailed = error {
                isNetworkError = true
            } else if case DeployerError.networkError = error {
                isNetworkError = true
                SecureLogger.info("PQ deployer network error, will try mesh relay", category: .session)
            } else if case BundlerError.networkError = error {
                isNetworkError = true
                SecureLogger.info("PQ bundler network error, will try mesh relay", category: .session)
            } else if case BundlerError.httpError = error {
                isNetworkError = true
                SecureLogger.info("PQ bundler HTTP error, will try mesh relay", category: .session)
            } else if case PQTransactionError.rpcError = error {
                isNetworkError = true
                SecureLogger.info("PQ RPC error, will try mesh relay", category: .session)
            } else {
                isNetworkError = false
            }
            
            if isNetworkError, let meshRelay = meshRelay {
                let peerIdForReply = replyToPeerId ?? (accountAddress ?? "")
                SecureLogger.info("PQ bundler unreachable, attempting offline mesh relay for \(dest.prefix(10))…", category: .session)
                
                do {
                    let userOpPayload = try await serviceSet.signer.buildSignedUserOpForRelay(
                        dest: dest,
                        value: value,
                        data: data,
                        replyToPeerId: peerIdForReply
                    )
                    
                    meshRelay.queueUserOp(userOpPayload)
                    
                    let requestId = userOpPayload.requestId
                    lastTransactionHash = requestId
                    isProcessingTransaction = false
                    SecureLogger.info("📤 PQ UserOp queued for mesh relay: \(requestId.prefix(8))…", category: .session)
                    return requestId
                } catch {
                    SecureLogger.error("PQ offline UserOp build failed: \(error)", category: .session)
                    lastError = "Offline send failed: \(error.localizedDescription)"
                    isProcessingTransaction = false
                    return nil
                }
            }
            
            lastError = error.localizedDescription
            isProcessingTransaction = false
            SecureLogger.error("PQ transaction failed: \(error)", category: .session)
            return nil
        }
    }
    
    /// Execute and wait for confirmation on a specific chain.
    func executeAndWait(
        to dest: String,
        value: UInt64 = 0,
        data: Data = Data(),
        chain: PQAccountDeployer.Chain = .sepolia
    ) async -> Bool {
        guard let serviceSet = chainServices[chain.chainId] else {
            lastError = "Transaction signer not configured for \(chain.name)"
            return false
        }
        
        guard state.isDeployed else {
            lastError = "Account not deployed"
            return false
        }
        
        isProcessingTransaction = true
        lastError = nil
        
        do {
            let receipt = try await serviceSet.signer.executeAndWait(
                dest: dest,
                value: value,
                data: data
            )
            lastTransactionHash = receipt.userOpHash
            isProcessingTransaction = false

            // Persist to TransactionStore so it appears in history after restart
            if let address = accountAddress {
                TransactionStore.shared.record(
                    CachedTransaction(
                        id: receipt.userOpHash,
                        txHash: receipt.userOpHash,
                        from: address.lowercased(),
                        to: dest.lowercased(),
                        value: String(format: "0x%llx", value),
                        timestamp: Date(),
                        blockNumber: nil,
                        chainId: chain.chainId,
                        source: .pqAccount
                    ),
                    for: address
                )
            }

            return receipt.success
        } catch {
            lastError = error.localizedDescription
            isProcessingTransaction = false
            SecureLogger.error("PQ transaction failed: \(error)", category: .session)
            return false
        }
    }
    
    // MARK: - Key Export
    
    /// Export PQ seed for backup purposes (32-byte hex).
    func exportSeed() async -> String? {
        guard let pqKeyManager else { return nil }
        
        do {
            let seed = try await pqKeyManager.exportSeed()
            return seed.map { String(format: "%02x", $0) }.joined()
        } catch {
            lastError = error.localizedDescription
            return nil
        }
    }
    
    // MARK: - Reset
    
    /// Clear all PQ keys and reset state.
    func reset() async {
        if let pqKeyManager {
            await pqKeyManager.clearKeys()
        }
        state = .notInitialized
        accountAddress = nil
        pqPublicKeyHex = nil
        lastTransactionHash = nil
        lastError = nil
        chainStatuses = chainStatuses.map { status in
            PQChainDeploymentStatus(chain: status.chain, isDeployed: false, isDeploying: false)
        }
        // Clear persisted deployment state
        UserDefaults.standard.removeObject(forKey: Self.deployedChainsKey)
        UserDefaults.standard.removeObject(forKey: Self.persistedAddressKey)
    }
    
    // MARK: - Deployment Persistence
    
    /// Load persisted deployed chain IDs from UserDefaults.
    /// Note: UserDefaults stores numbers as NSNumber which bridges to Int,
    /// so we read [Int] and convert to UInt64.
    private static func loadDeployedChainIds() -> Set<UInt64> {
        let stored = UserDefaults.standard.array(forKey: deployedChainsKey) as? [Int] ?? []
        return Set(stored.map { UInt64($0) })
    }
    
    /// Persist a newly-deployed chain ID to UserDefaults.
    private static func persistDeployedChainId(_ chainId: UInt64) {
        var current = loadDeployedChainIds()
        current.insert(chainId)
        UserDefaults.standard.set(current.map { Int($0) }, forKey: deployedChainsKey)
    }
    
    /// Persist the PQ counterfactual address (deterministic via CREATE2, safe to cache).
    private static func persistAccountAddress(_ address: String) {
        UserDefaults.standard.set(address, forKey: persistedAddressKey)
    }
    
    /// Load persisted PQ account address, if any.
    private static func loadPersistedAccountAddress() -> String? {
        UserDefaults.standard.string(forKey: persistedAddressKey)
    }
    
    // MARK: - Stealth PQ Account Integration
    
    /// The stealth PQ account manager, created after keys are ready.
    private var stealthPQManager: StealthPQAccountManager?
    
    /// The stealth PQ account view model for SwiftUI binding.
    @Published private(set) var stealthPQViewModel: StealthPQAccountViewModel?
    
    /// Initialize stealth PQ account management after main PQ setup.
    /// Call after `initializeKeys` succeeds and user has an ENS username.
    ///
    /// - Parameters:
    ///   - wallet: The embedded wallet (for stealth key derivation)
    ///   - stealthAddressManager: The existing stealth address manager (reuses HMAC derivation)
    ///   - ensUsername: The user's dstealth.eth username (e.g., "alice")
    ///   - balanceService: The balance service for Helios/proof/RPC balance scanning
    func initializeStealthPQ(
        wallet: EmbeddedWallet,
        stealthAddressManager: StealthAddressManager,
        ensUsername: String,
        balanceService: EthereumBalanceService
    ) async {
        guard let pqKeyManager else {
            SecureLogger.warning("Cannot init stealth PQ: no PQKeyManager", category: .session)
            return
        }
        
        // Use Arbitrum Sepolia for gas efficiency
        let targetChain = StealthPQAccountManager.defaultChain
        guard let serviceSet = chainServices[targetChain.chainId] else {
            SecureLogger.warning("Cannot init stealth PQ: no services for \(targetChain.name)", category: .session)
            return
        }
        
        let manager = StealthPQAccountManager(
            wallet: wallet,
            stealthAddressManager: stealthAddressManager,
            pqKeyManager: pqKeyManager,
            deployer: serviceSet.deployer,
            balanceService: balanceService
        )
        
        // Load previously persisted accounts
        await manager.loadPersistedAccounts()
        
        self.stealthPQManager = manager
        
        let viewModel = StealthPQAccountViewModel(
            manager: manager,
            signer: serviceSet.signer,
            ensUsername: ensUsername
        )
        
        self.stealthPQViewModel = viewModel
        
        // Load persisted accounts + register ENS
        await viewModel.loadAccounts()
        await viewModel.registerENS()
        
        SecureLogger.info("Stealth PQ account initialized for \(ensUsername).pq.dstealth.eth", category: .session)
    }
}
