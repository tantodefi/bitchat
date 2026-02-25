//
// PQTransactionSigner.swift
// bitchat
//
// Orchestrates PQ account transactions via ERC-4337.
// Coordinates EmbeddedWallet, PQKeyManager, UserOperationBuilder,
// and PimlicoBundler to build, sign, and submit UserOperations.
//
// This is free and unencumbered software released into the public domain.
// For more information, see <https://unlicense.org>
//

import BitLogger
import Foundation
import Tor

// MARK: - PQ Transaction Signer

/// Orchestrates end-to-end PQ account transactions.
/// Builds a UserOperation, signs it with hybrid ECDSA + ML-DSA-44,
/// estimates gas via the bundler, re-signs, and submits.
actor PQTransactionSigner {
    
    private let wallet: EmbeddedWallet
    private let pqKeyManager: PQKeyManager
    private let bundler: PimlicoBundler
    private let deployer: PQAccountDeployer
    private let chainId: UInt64
    
    private var _accountAddress: String?
    private var _cachedExpandedPQKey: Data?
    
    // MARK: - Offline Gas Cache
    
    /// Cached gas values from last successful online transaction for offline fallback
    private struct GasCache: Codable {
        let baseGasPrice: UInt64
        let verificationGasLimit: UInt64
        let callGasLimit: UInt64
        let preVerificationGas: UInt64
        let lastNonce: UInt64
        let timestamp: Date
    }
    
    /// UserDefaults key for gas cache (per chainId)
    private var gasCacheKey: String { "pq-gas-cache-\\(chainId)" }
    
    /// Cache gas values from a successful online transaction
    private func saveGasCache(
        baseGasPrice: UInt64,
        verificationGasLimit: UInt64,
        callGasLimit: UInt64,
        preVerificationGas: UInt64,
        nonce: UInt64
    ) {
        let cache = GasCache(
            baseGasPrice: baseGasPrice,
            verificationGasLimit: verificationGasLimit,
            callGasLimit: callGasLimit,
            preVerificationGas: preVerificationGas,
            lastNonce: nonce,
            timestamp: Date()
        )
        if let data = try? JSONEncoder().encode(cache) {
            UserDefaults.standard.set(data, forKey: gasCacheKey)
        }
    }
    
    /// Load cached gas values for offline use
    private func loadGasCache() -> GasCache? {
        guard let data = UserDefaults.standard.data(forKey: gasCacheKey),
              let cache = try? JSONDecoder().decode(GasCache.self, from: data) else {
            return nil
        }
        // Accept cache up to 24 hours old
        guard Date().timeIntervalSince(cache.timestamp) < 24 * 60 * 60 else { return nil }
        return cache
    }
    
    init(
        wallet: EmbeddedWallet,
        pqKeyManager: PQKeyManager,
        bundler: PimlicoBundler,
        deployer: PQAccountDeployer,
        chainId: UInt64
    ) {
        self.wallet = wallet
        self.pqKeyManager = pqKeyManager
        self.bundler = bundler
        self.deployer = deployer
        self.chainId = chainId
    }
    
    // MARK: - Key Helpers
    
    /// Get the EOA address as raw 20-byte Data for the factory's `preQuantumPubKey` parameter.
    /// The ZKNOX mldsa_k1 factory expects the Ethereum address (20 bytes), NOT the public key.
    private func getPreQuantumKeyForFactory() async throws -> Data {
        let address = try await wallet.getAddress()
        let hex = address.hasPrefix("0x") ? String(address.dropFirst(2)) : address
        return ABIEncoder.hexToData(hex)
    }
    
    /// Get the expanded ML-DSA-44 public key (~22KB) for the factory's `postQuantumPubKey` parameter.
    /// The factory expects the fully expanded key (Â-hat matrix + tr + t1), NOT the raw 1312-byte key.
    private func getPostQuantumKeyForFactory() async throws -> Data {
        if let cached = _cachedExpandedPQKey {
            return cached
        }
        let pk = try await pqKeyManager.getPublicKey()
        let expanded = try MLDSAKeyExpander.toExpandedEncodedBytes(publicKey: pk.keyBytes)
        _cachedExpandedPQKey = expanded
        SecureLogger.info("PQ key expanded: \(pk.keyBytes.count) → \(expanded.count) bytes", category: .session)
        return expanded
    }
    
    // MARK: - Account Address
    
    /// Get or compute the PQ account address (counterfactual if not deployed).
    func getAccountAddress() async throws -> String {
        if let cached = _accountAddress {
            return cached
        }
        
        // Get factory-compatible key formats
        let preQKey = try await getPreQuantumKeyForFactory()
        let postQKey = try await getPostQuantumKeyForFactory()
        
        // Compute counterfactual address
        let address = try await deployer.getAddress(
            preQuantumPubKey: preQKey,
            postQuantumPubKey: postQKey
        )
        
        _accountAddress = address
        await pqKeyManager.setAccountAddress(address)
        return address
    }
    
    // MARK: - Execute Transaction
    
    /// Execute a transaction through the PQ smart account.
    /// - Parameters:
    ///   - dest: Target contract address (hex string with 0x prefix)
    ///   - value: ETH value to send (in wei)
    ///   - data: Calldata for the target contract
    /// - Returns: UserOperation hash (can be used to track receipt)
    func executeTransaction(
        dest: String,
        value: UInt64 = 0,
        data: Data = Data()
    ) async throws -> String {
        let sender = try await getAccountAddress()
        
        // Check if account is deployed
        let deployed = try await deployer.isDeployed(address: sender)
        
        // Build execute calldata
        let executeCalldata = ABIEncoder.encodeExecute(
            dest: dest,
            value: value,
            funcData: data
        )
        
        // Build initCode if not deployed
        var initCode = Data()
        if !deployed {
            let preQKey = try await getPreQuantumKeyForFactory()
            let postQKey = try await getPostQuantumKeyForFactory()
            initCode = await deployer.buildInitCode(
                preQuantumPubKey: preQKey,
                postQuantumPubKey: postQKey
            )
        }
        
        // Get nonce from entrypoint (0 for first tx if not deployed)
        let nonce: UInt64 = deployed ? try await getEntryPointNonce(sender: sender) : 0
        
        // Fetch live gas price from the network
        let baseGasPrice = try await deployer.getGasPrice()
        let priorityFee = max(baseGasPrice / 10, 100_000_000) // 10% of base, min 0.1 gwei
        let maxFee = baseGasPrice * 3 / 2 + priorityFee       // 1.5x base + priority
        
        SecureLogger.info("PQ UserOp gas: maxFee=\(maxFee / 1_000_000_000)gwei, priority=\(priorityFee / 1_000_000_000)gwei", category: .session)
        
        // Build initial UserOp with HIGH placeholder gas limits for estimation.
        // ML-DSA-44 on-chain verification is extremely gas-intensive (~2–20M gas)
        // so verificationGasLimit must be large enough for the bundler's simulation
        // to complete without OOG. AA23 = validateUserOp reverted, AA24 = OOG.
        // Use 20M for first tx (with deploy initCode) and 15M for subsequent txs.
        let estimationVGL: UInt64 = deployed ? 15_000_000 : 20_000_000
        
        SecureLogger.info(
            "PQ UserOp: sender=\(sender.prefix(14))…, deployed=\(deployed), nonce=\(nonce), initCode=\(initCode.count)B, VGL=\(estimationVGL)",
            category: .session
        )
        
        var userOp = PackedUserOperation(
            sender: ABIEncoder.hexToData(String(sender.dropFirst(2))),
            nonce: nonce,
            initCode: initCode,
            callData: executeCalldata,
            accountGasLimits: UserOperationBuilder.packAccountGasLimits(
                verificationGasLimit: estimationVGL,
                callGasLimit: UInt64(1_000_000)
            ),
            preVerificationGas: UInt64(500_000),
            gasFees: UserOperationBuilder.packGasFees(
                maxPriorityFeePerGas: priorityFee,
                maxFeePerGas: maxFee
            ),
            paymasterAndData: Data(),
            signature: Data()
        )
        
        // Sign with dummy signature first for gas estimation
        let dummySig = try await signUserOp(&userOp)
        userOp.signature = dummySig
        
        // ── AA23 Diagnostic: log pre-estimation state ──
        // The dummy signature must pass validateUserOp simulation. If AA23 occurs
        // here, the hybrid signature (ECDSA + ML-DSA-44) failed on-chain verification.
        let preQKeyHex = "0x" + (try await getPreQuantumKeyForFactory()).map { String(format: "%02x", $0) }.joined()
        SecureLogger.info(
            "PQ pre-estimation: preQuantumKey(EOA)=\(preQKeyHex.prefix(14))…, "
            + "dummySigLen=\(dummySig.count)B, sender=\(sender.prefix(14))…",
            category: .session
        )
        
        // Estimate gas — AA23 here means validateUserOp reverted on-chain
        // Pass sender address for stateOverride (fake high balance during simulation)
        // so AA21 doesn't fire for low-balance accounts. Real balance check is below.
        let gasEstimate: GasEstimate
        do {
            gasEstimate = try await bundler.estimateUserOperationGas(
                userOp: userOp,
                senderAddress: sender
            )
        } catch let error as BundlerError {
            // Enrich AA23/AA24 errors with diagnostic context
            let ctx = "sender=\(sender.prefix(14))…, deployed=\(deployed), nonce=\(nonce), initCode=\(initCode.count)B, sigLen=\(dummySig.count)B, VGL=\(estimationVGL)"
            SecureLogger.error("PQ gas estimation failed [\(ctx)]: \(error)", category: .session)
            throw PQTransactionError.bundlerRejected("Gas estimation failed: \(error.localizedDescription) [\(ctx)]")
        }
        
        // The bundler's estimateUserOperationGas typically SKIPS signature verification
        // during gas estimation (it replaces validateUserOp with a gas-measuring stub).
        // This means the returned VGL only covers non-verification overhead (nonce checks,
        // SLOADs, etc.) — NOT the cost of on-chain ML-DSA-44 signature verification.
        //
        // ML-DSA-44 verification on EVM (NTT transforms, modular arithmetic) costs
        // millions of gas. The kohaku reference implementation enforces a minimum VGL
        // of 9M (JS) / 13.5M (TS) and uses 20M in Foundry tests. The bundler has a
        // per-UserOp total gas cap (typically 15M on Pimlico).
        let baseVGL = gasEstimate.verificationGasLimit
        let safeCallGas = gasEstimate.callGasLimit * 6 / 5
        
        // PQ signature calldata (~2.6 KB) makes the bundler underestimate PVG.
        // Kohaku reference applies 4× multiplier with an 800K floor.
        let safePreVerificationGas = max(gasEstimate.preVerificationGas * 4, 800_000)
        
        // Bundler's per-UserOp gas cap. Pimlico enforces totalGas ≤ 15M.
        // maxVGL = cap − CGL − PVG − buffer so total stays under the cap.
        let bundlerMaxGasPerUserOp: UInt64 = 15_000_000
        let maxVGL = bundlerMaxGasPerUserOp - safeCallGas - safePreVerificationGas - 50_000
        
        // ML-DSA-44 on-chain verification always costs millions of gas. The bundler's
        // estimate (baseVGL ~111K) only covers non-verification overhead. Per kohaku
        // reference, enforce a 9M minimum VGL floor — skip useless low-gas attempts.
        let minVerificationGas: UInt64 = 9_000_000
        let vglAttempts: [UInt64] = [
            min(max(baseVGL * 3, minVerificationGas), maxVGL),  // floor 9M, cap at maxVGL
            maxVGL                                               // maximum (~13–14M)
        ]
        
        SecureLogger.info(
            "PQ gas estimate: vgl=\(baseVGL), cgl=\(gasEstimate.callGasLimit)→\(safeCallGas), pvg=\(gasEstimate.preVerificationGas)→\(safePreVerificationGas), attempts=\(vglAttempts.map { String($0) }.joined(separator: "/"))",
            category: .session
        )
        
        // Try each VGL level, re-signing at each step
        var lastError: Error?
        let ctx = "sender=\(sender.prefix(14))…, deployed=\(deployed), nonce=\(nonce)"
        
        for (attemptIndex, attemptVGL) in vglAttempts.enumerated() {
            // Update gas values
            userOp.accountGasLimits = UserOperationBuilder.packAccountGasLimits(
                verificationGasLimit: attemptVGL,
                callGasLimit: safeCallGas
            )
            userOp.preVerificationGas = PackedUserOperation.uint256Data(safePreVerificationGas)
            
            // Re-sign with updated gas values (changes the userOpHash)
            let sig = try await signUserOp(&userOp)
            userOp.signature = sig
            
            // Validate balance on first attempt — use MAX VGL for worst-case prefund
            if attemptIndex == 0 {
                // Cache gas values for offline fallback (use maxVGL for safety)
                saveGasCache(
                    baseGasPrice: baseGasPrice,
                    verificationGasLimit: maxVGL,
                    callGasLimit: safeCallGas,
                    preVerificationGas: safePreVerificationGas,
                    nonce: nonce
                )
                
                // Use maxVGL (not current attemptVGL) so we don't falsely reject
                // a send that would succeed at a higher VGL after AA23 retry
                let totalGas = maxVGL + safeCallGas + safePreVerificationGas
                let requiredPrefund = totalGas * maxFee
                let balanceHex = try await deployer.getBalance(address: sender)
                let senderBalance = Self.parseHexBalance(balanceHex)
                
                let totalRequired: UInt64
                if value > UInt64.max - requiredPrefund {
                    totalRequired = UInt64.max
                } else {
                    totalRequired = value + requiredPrefund
                }
                
                SecureLogger.info(
                    "PQ balance check: balance=\(senderBalance)wei, send=\(value)wei, gasPrefund=\(requiredPrefund)wei, total=\(totalRequired)wei",
                    category: .session
                )
                
                if senderBalance < totalRequired {
                    let balanceEth = Double(senderBalance) / 1e18
                    let gasCostEth = Double(requiredPrefund) / 1e18
                    let sendEth = Double(value) / 1e18
                    throw PQTransactionError.insufficientBalance(
                        balance: balanceEth,
                        sendAmount: sendEth,
                        gasCost: gasCostEth
                    )
                }
            }
            
            // Submit to bundler
            do {
                let userOpHash = try await bundler.sendUserOperation(userOp: userOp)
                SecureLogger.info("PQ UserOp submitted: \(userOpHash) (VGL=\(attemptVGL), attempt \(attemptIndex + 1)/\(vglAttempts.count))", category: .session)
                return userOpHash
            } catch let error as BundlerError {
                if case .rpcError(_, let msg) = error, msg.contains("AA23") {
                    SecureLogger.warning(
                        "PQ sendUserOp AA23 — VGL=\(attemptVGL) (est=\(baseVGL), attempt \(attemptIndex + 1)/\(vglAttempts.count)) [\(ctx)]",
                        category: .session
                    )
                    lastError = error
                    
                    // Check if the highest VGL can still be covered by the balance
                    if attemptIndex + 1 < vglAttempts.count {
                        let nextVGL = vglAttempts[attemptIndex + 1]
                        let nextTotalGas = nextVGL + safeCallGas + safePreVerificationGas
                        let nextPrefund = nextTotalGas * maxFee
                        let nextTotal = value + nextPrefund
                        let balHex = try? await deployer.getBalance(address: sender)
                        let bal = balHex.map { Self.parseHexBalance($0) } ?? 0
                        if bal < nextTotal {
                            SecureLogger.error(
                                "PQ AA23: can't retry with higher VGL=\(nextVGL) — balance \(bal)wei < needed \(nextTotal)wei [\(ctx)]",
                                category: .session
                            )
                            break
                        }
                        SecureLogger.info(
                            "PQ AA23: retrying with higher VGL=\(nextVGL) (attempt \(attemptIndex + 2)/\(vglAttempts.count)) [\(ctx)]",
                            category: .session
                        )
                    }
                    continue
                } else {
                    // ── AA24 Diagnostic: call each verifier individually to identify the failure ──
                    let diagHash = UserOperationBuilder.getUserOpHash(
                        userOp: userOp,
                        entryPoint: UserOperationBuilder.entryPointAddress,
                        chainId: chainId
                    )
                    await diagnoseVerifiersOnChain(
                        sender: sender,
                        userOpHash: diagHash,
                        hybridSig: userOp.signature
                    )
                    
                    SecureLogger.error("PQ sendUserOp failed [\(ctx)]: \(error)", category: .session)
                    throw PQTransactionError.bundlerRejected(
                        "Submit failed: \(error.localizedDescription) [\(ctx)]"
                    )
                }
            }
        }
        
        // All VGL attempts exhausted — this indicates the issue is NOT gas-related
        SecureLogger.error(
            "PQ sendUserOp failed all \(vglAttempts.count) VGL attempts [\(ctx)]. "
            + "Max VGL tried: \(vglAttempts.last ?? 0). This likely indicates an on-chain "
            + "contract issue (not gas). Check validateUserOp logic.",
            category: .session
        )
        throw PQTransactionError.bundlerRejected(
            "Submit failed after \(vglAttempts.count) VGL escalations (max=\(vglAttempts.last ?? 0)): "
            + "\(lastError?.localizedDescription ?? "AA23 reverted") [\(ctx)]"
        )
    }
    
    // MARK: - Offline Mesh Relay Support
    
    /// Build a fully signed UserOperation for relay via BLE mesh.
    /// Uses cached gas values from the last successful online transaction.
    /// The relay peer will submit this to the Pimlico bundler on our behalf.
    ///
    /// - Parameters:
    ///   - dest: Target address (hex with 0x prefix)
    ///   - value: ETH value in wei
    ///   - data: Calldata for target contract
    ///   - replyToPeerId: PeerID for confirmation routing
    /// - Returns: Serialized `TxUserOpPayload` ready for mesh transmission
    func buildSignedUserOpForRelay(
        dest: String,
        value: UInt64 = 0,
        data: Data = Data(),
        replyToPeerId: String
    ) async throws -> TxUserOpPayload {
        // Require cached account address (should be available if ever online)
        guard let sender = _accountAddress else {
            throw PQTransactionError.configurationError("PQ account address not available (never connected online)")
        }
        
        // Load cached gas values
        guard let gasCache = loadGasCache() else {
            throw PQTransactionError.configurationError("No cached gas values available. Send at least one PQ transaction while online first.")
        }
        
        // Build execute calldata
        let executeCalldata = ABIEncoder.encodeExecute(
            dest: dest,
            value: value,
            funcData: data
        )
        
        // Use cached nonce + 1 (assumes last cached tx was mined)
        // If the user queues multiple offline txs, each call increments from cache
        let offlineNonce = gasCache.lastNonce + 1
        
        // Apply safety multipliers to cached gas values for staleness
        let baseGasPrice = gasCache.baseGasPrice
        let priorityFee = max(baseGasPrice / 10, 100_000_000)
        let maxFee = baseGasPrice * 2 + priorityFee  // 2x base (extra buffer for offline)
        
        let verificationGasLimit = gasCache.verificationGasLimit * 3 / 2  // 1.5x buffer
        let callGasLimit = gasCache.callGasLimit * 3 / 2
        let preVerificationGas = gasCache.preVerificationGas * 3 / 2
        
        SecureLogger.info("PQ offline UserOp: nonce=\(offlineNonce), maxFee=\(maxFee / 1_000_000_000)gwei (cached)", category: .session)
        
        // Build UserOp with cached gas estimates (no RPC calls needed)
        var userOp = PackedUserOperation(
            sender: ABIEncoder.hexToData(String(sender.dropFirst(2))),
            nonce: offlineNonce,
            initCode: Data(), // Account must be deployed for offline sends
            callData: executeCalldata,
            accountGasLimits: UserOperationBuilder.packAccountGasLimits(
                verificationGasLimit: verificationGasLimit,
                callGasLimit: callGasLimit
            ),
            preVerificationGas: preVerificationGas,
            gasFees: UserOperationBuilder.packGasFees(
                maxPriorityFeePerGas: priorityFee,
                maxFeePerGas: maxFee
            ),
            paymasterAndData: Data(),
            signature: Data()
        )
        
        // Sign fully (ECDSA + ML-DSA-44 hybrid) — all local, no network needed
        let signature = try await signUserOp(&userOp)
        userOp.signature = signature
        
        // Update nonce cache so next offline tx uses nonce+2
        saveGasCache(
            baseGasPrice: baseGasPrice,
            verificationGasLimit: gasCache.verificationGasLimit,
            callGasLimit: gasCache.callGasLimit,
            preVerificationGas: gasCache.preVerificationGas,
            nonce: offlineNonce
        )
        
        // Serialize to mesh-compatible payload
        let senderHex = "0x" + userOp.sender.map { String(format: "%02x", $0) }.joined()
        
        let apiKey = await bundler.getAPIKey()
        
        return TxUserOpPayload(
            requestId: UUID().uuidString,
            chainId: chainId,
            pimlicoAPIKey: apiKey,
            sender: senderHex,
            nonce: dataToHex(userOp.nonce),
            callData: dataToHex(userOp.callData),
            signature: dataToHex(userOp.signature),
            verificationGasLimit: uint64ToHex(verificationGasLimit),
            callGasLimit: uint64ToHex(callGasLimit),
            preVerificationGas: uint64ToHex(preVerificationGas),
            maxPriorityFeePerGas: uint64ToHex(priorityFee),
            maxFeePerGas: uint64ToHex(maxFee),
            factory: nil,
            factoryData: nil,
            paymaster: nil,
            paymasterVerificationGasLimit: nil,
            paymasterPostOpGasLimit: nil,
            paymasterData: nil,
            signedAt: Date(),
            description: "PQ Transfer \(Self.formatWei(value)) to \(dest.prefix(10))…",
            toAddress: dest,
            fromAddress: sender,
            amount: value,
            replyToPeerId: replyToPeerId
        )
    }
    
    /// Expose chain ID for external use
    func getChainId() -> UInt64 { chainId }
    
    // MARK: - Hex Helpers
    
    private func dataToHex(_ data: Data) -> String {
        "0x" + data.map { String(format: "%02x", $0) }.joined()
    }
    
    private func uint64ToHex(_ value: UInt64) -> String {
        "0x" + String(value, radix: 16)
    }
    
    private static func formatWei(_ wei: UInt64) -> String {
        let eth = Double(wei) / 1e18
        return String(format: "%.6f ETH", eth)
    }
    
    /// Parse a 0x-prefixed hex balance string (from eth_getBalance) to UInt64.
    /// Clamps values exceeding UInt64.max.
    static func parseHexBalance(_ hexStr: String) -> UInt64 {
        let hex = hexStr.hasPrefix("0x") ? String(hexStr.dropFirst(2)) : hexStr
        // Use UInt64 directly — sufficient for up to ~18.4 ETH, which covers
        // testnet balances. Balances above UInt64.max are clamped.
        return UInt64(hex, radix: 16) ?? 0
    }
    
    /// Execute and wait for receipt
    func executeAndWait(
        dest: String,
        value: UInt64 = 0,
        data: Data = Data(),
        timeout: TimeInterval = 120
    ) async throws -> UserOpReceipt {
        let hash = try await executeTransaction(dest: dest, value: value, data: data)
        
        let receipt = try await bundler.waitForReceipt(
            userOpHash: hash,
            timeout: timeout
        )
        
        guard receipt.success else {
            throw PQTransactionError.executionReverted(hash)
        }
        
        return receipt
    }
    
    // MARK: - Deploy Account
    
    /// Deploy the PQ smart account via the bundler (ERC-4337).
    /// Sends a "no-op" UserOp with initCode to trigger deployment.
    func deployViaUserOp() async throws -> String {
        let sender = try await getAccountAddress()
        
        if try await deployer.isDeployed(address: sender) {
            throw DeployerError.accountAlreadyDeployed(sender)
        }
        
        // Deploy by sending a UserOp with initCode and empty callData
        return try await executeTransaction(dest: sender, value: 0, data: Data())
    }
    
    /// Deploy via direct EOA transaction (simpler, no bundler needed).
    func deployDirect() async throws -> String {
        let sender = try await getAccountAddress()
        
        if try await deployer.isDeployed(address: sender) {
            throw DeployerError.accountAlreadyDeployed(sender)
        }
        
        let preQKey = try await getPreQuantumKeyForFactory()
        let postQKey = try await getPostQuantumKeyForFactory()
        let eoaAddress = try await wallet.getAddress()
        let nonce = try await deployer.getNonce(address: eoaAddress)
        
        let signedTx = try await deployer.buildDeployTransaction(
            wallet: wallet,
            preQuantumPubKey: preQKey,
            postQuantumPubKey: postQKey,
            nonce: nonce
        )
        
        let txHash = try await deployer.sendRawTransaction(signedTx)
        SecureLogger.info("PQ account deploy tx: \(txHash)", category: .session)
        
        return txHash
    }
    
    // MARK: - Stealth Account Sweep
    
    /// Estimate the gas cost for sweeping a stealth PQ account.
    /// Returns the required gas prefund in wei (the amount that must stay in
    /// the account to pay the EntryPoint during `validateUserOp`).
    ///
    /// This uses the Pimlico bundler for a real gas estimate, factoring in
    /// deploy cost (if counterfactual) + ML-DSA-44 verification + transfer.
    ///
    /// - Parameters:
    ///   - stealthAccount: The stealth PQ account to estimate for
    ///   - stealthPrivateKey: Needed to produce a valid dummy signature for gas estimation
    ///   - destinationAddress: Where funds will be sent
    /// - Returns: `SweepGasEstimate` with gas cost and max sweepable amount
    func estimateSweepGasCost(
        stealthAccount: StealthPQAccount,
        stealthPrivateKey: Data,
        destinationAddress: String
    ) async throws -> SweepGasEstimate {
        let sender = stealthAccount.pqAccountAddress
        let deployed = stealthAccount.isDeployed
        
        // Get live balance
        let balanceHex = try await deployer.getBalance(address: sender)
        let balance = Self.parseHexBalance(balanceHex)
        
        // Build initCode if counterfactual (not deployed yet)
        var initCode = Data()
        if !deployed {
            let stealthSignerHex = stealthAccount.stealthSignerAddress
            let hex = stealthSignerHex.hasPrefix("0x") ? String(stealthSignerHex.dropFirst(2)) : stealthSignerHex
            let preQKey = ABIEncoder.hexToData(hex)
            let postQKey = try await getPostQuantumKeyForFactory()
            initCode = UserOperationBuilder.buildInitCode(
                factoryAddress: PQAccountDeployer.factoryAddress,
                preQuantumPubKey: preQKey,
                postQuantumPubKey: postQKey
            )
        }
        
        // Use a placeholder sweep amount (1 wei) — gas cost is independent of transfer value
        let placeholderCalldata = ABIEncoder.encodeExecute(
            dest: destinationAddress,
            value: 1,
            funcData: Data()
        )
        
        let nonce: UInt64 = deployed ? try await getEntryPointNonce(sender: sender) : 0
        let baseGasPrice = try await deployer.getGasPrice()
        let priorityFee = max(baseGasPrice / 10, 100_000_000)
        let maxFee = baseGasPrice * 3 / 2 + priorityFee
        
        var userOp = PackedUserOperation(
            sender: ABIEncoder.hexToData(String(sender.dropFirst(2))),
            nonce: nonce,
            initCode: initCode,
            callData: placeholderCalldata,
            accountGasLimits: UserOperationBuilder.packAccountGasLimits(
                verificationGasLimit: UInt64(deployed ? 15_000_000 : 20_000_000),
                callGasLimit: UInt64(1_000_000)
            ),
            preVerificationGas: UInt64(500_000),
            gasFees: UserOperationBuilder.packGasFees(
                maxPriorityFeePerGas: priorityFee,
                maxFeePerGas: maxFee
            ),
            paymasterAndData: Data(),
            signature: Data()
        )
        
        let dummySig = try await signStealthUserOp(&userOp, stealthPrivateKey: stealthPrivateKey)
        userOp.signature = dummySig
        
        let gasEstimate = try await bundler.estimateUserOperationGas(
            userOp: userOp,
            senderAddress: sender
        )
        
        // Apply 1.5x safety multiplier (higher than normal 1.2x because deployment
        // gas can vary more, and we'd rather over-reserve than fail with AA24)
        let safeVerificationGas = gasEstimate.verificationGasLimit * 3 / 2
        let safeCallGas = gasEstimate.callGasLimit * 3 / 2
        let safePreVerificationGas = gasEstimate.preVerificationGas * 3 / 2
        
        let totalGas = safeVerificationGas + safeCallGas + safePreVerificationGas
        let requiredPrefund = totalGas * maxFee
        
        // Max sweepable = balance - gas prefund (leave enough to pay EntryPoint)
        let maxSweepable: UInt64 = balance > requiredPrefund ? balance - requiredPrefund : 0
        
        SecureLogger.info(
            "Stealth sweep gas estimate: balance=\(balance)wei, gasCost=\(requiredPrefund)wei, maxSweep=\(maxSweepable)wei, deployed=\(deployed)",
            category: .session
        )
        
        return SweepGasEstimate(
            balance: balance,
            requiredGasPrefund: requiredPrefund,
            maxSweepableWei: maxSweepable,
            maxFeePerGas: maxFee,
            verificationGasLimit: safeVerificationGas,
            callGasLimit: safeCallGas,
            preVerificationGas: safePreVerificationGas,
            isDeployed: deployed
        )
    }
    
    /// Sweep a stealth PQ account by deploying it (if needed) and transferring its
    /// balance to the user's main PQ account in a single ERC-4337 UserOp.
    ///
    /// The sweep amount is **auto-computed** from the live on-chain balance minus
    /// the actual gas cost (estimated via the Pimlico bundler). This avoids the
    /// AA24 revert caused by insufficient gas prefund.
    ///
    /// The stealth private key is used for ECDSA signing (it owns the stealth signer EOA),
    /// while the master ML-DSA-44 key is used for PQ signing (shared across all accounts).
    ///
    /// - Parameters:
    ///   - stealthAccount: The stealth PQ account to sweep
    ///   - stealthPrivateKey: The 32-byte ECDSA private key for this stealth signer
    ///   - destinationAddress: Where to send the funds (usually main PQ account)
    /// - Returns: `SweepResult` with the UserOp hash and amounts
    func sweepStealthAccount(
        stealthAccount: StealthPQAccount,
        stealthPrivateKey: Data,
        destinationAddress: String
    ) async throws -> SweepResult {
        let sender = stealthAccount.pqAccountAddress
        let deployed = stealthAccount.isDeployed
        
        // Get live balance from chain
        let balanceHex = try await deployer.getBalance(address: sender)
        let balance = Self.parseHexBalance(balanceHex)
        
        guard balance > 0 else {
            throw PQTransactionError.insufficientBalance(
                balance: 0,
                sendAmount: 0,
                gasCost: 0
            )
        }
        
        // Build initCode if not deployed (deploy-on-sweep pattern)
        var initCode = Data()
        if !deployed {
            let stealthSignerHex = stealthAccount.stealthSignerAddress
            let hex = stealthSignerHex.hasPrefix("0x") ? String(stealthSignerHex.dropFirst(2)) : stealthSignerHex
            let preQKey = ABIEncoder.hexToData(hex)
            let postQKey = try await getPostQuantumKeyForFactory()
            
            initCode = UserOperationBuilder.buildInitCode(
                factoryAddress: PQAccountDeployer.factoryAddress,
                preQuantumPubKey: preQKey,
                postQuantumPubKey: postQKey
            )
        }
        
        // Nonce is 0 for first tx on a fresh stealth account
        let nonce: UInt64 = deployed ? try await getEntryPointNonce(sender: sender) : 0
        
        // Fetch gas prices
        let baseGasPrice = try await deployer.getGasPrice()
        let priorityFee = max(baseGasPrice / 10, 100_000_000)
        let maxFee = baseGasPrice * 3 / 2 + priorityFee
        
        // Phase 1: Estimate gas with a placeholder sweep amount (1 wei).
        // Gas cost is independent of the transfer value for a simple ETH send.
        let placeholderCalldata = ABIEncoder.encodeExecute(
            dest: destinationAddress,
            value: 1,
            funcData: Data()
        )
        
        var estimationOp = PackedUserOperation(
            sender: ABIEncoder.hexToData(String(sender.dropFirst(2))),
            nonce: nonce,
            initCode: initCode,
            callData: placeholderCalldata,
            accountGasLimits: UserOperationBuilder.packAccountGasLimits(
                verificationGasLimit: UInt64(deployed ? 15_000_000 : 20_000_000),
                callGasLimit: UInt64(1_000_000)
            ),
            preVerificationGas: UInt64(500_000),
            gasFees: UserOperationBuilder.packGasFees(
                maxPriorityFeePerGas: priorityFee,
                maxFeePerGas: maxFee
            ),
            paymasterAndData: Data(),
            signature: Data()
        )
        
        let dummySig = try await signStealthUserOp(&estimationOp, stealthPrivateKey: stealthPrivateKey)
        estimationOp.signature = dummySig
        
        let gasEstimate = try await bundler.estimateUserOperationGas(
            userOp: estimationOp,
            senderAddress: sender
        )
        
        // Apply 1.5x safety multiplier — deployment + ML-DSA-44 gas can vary more
        // than normal verification, so use a wider margin for counterfactual accounts.
        let safetyMultiplierNum: UInt64 = deployed ? 6 : 3  // 1.2x if deployed, 1.5x if counterfactual
        let safetyMultiplierDen: UInt64 = deployed ? 5 : 2
        let safeVerificationGas = gasEstimate.verificationGasLimit * safetyMultiplierNum / safetyMultiplierDen
        let safeCallGas = gasEstimate.callGasLimit * safetyMultiplierNum / safetyMultiplierDen
        let safePreVerificationGas = gasEstimate.preVerificationGas * safetyMultiplierNum / safetyMultiplierDen
        
        // Compute the actual gas cost (EntryPoint prefund) and max sweepable amount
        let totalGas = safeVerificationGas + safeCallGas + safePreVerificationGas
        let requiredPrefund = totalGas * maxFee
        
        guard balance > requiredPrefund else {
            let balanceEth = Double(balance) / 1e18
            let gasCostEth = Double(requiredPrefund) / 1e18
            throw PQTransactionError.insufficientBalance(
                balance: balanceEth,
                sendAmount: 0,
                gasCost: gasCostEth
            )
        }
        
        let sweepAmount = balance - requiredPrefund
        
        SecureLogger.info(
            "Stealth sweep: balance=\(balance)wei, gasCost=\(requiredPrefund)wei, sweep=\(sweepAmount)wei (\(String(format: "%.6f", Double(sweepAmount) / 1e18)) ETH), deployed=\(deployed)",
            category: .session
        )
        
        // Phase 2: Build the real UserOp with the computed sweep amount
        let realCalldata = ABIEncoder.encodeExecute(
            dest: destinationAddress,
            value: sweepAmount,
            funcData: Data()
        )
        
        var userOp = PackedUserOperation(
            sender: ABIEncoder.hexToData(String(sender.dropFirst(2))),
            nonce: nonce,
            initCode: initCode,
            callData: realCalldata,
            accountGasLimits: UserOperationBuilder.packAccountGasLimits(
                verificationGasLimit: safeVerificationGas,
                callGasLimit: safeCallGas
            ),
            preVerificationGas: safePreVerificationGas,
            gasFees: UserOperationBuilder.packGasFees(
                maxPriorityFeePerGas: priorityFee,
                maxFeePerGas: maxFee
            ),
            paymasterAndData: Data(),
            signature: Data()
        )
        
        // Sign with stealth private key (ECDSA) + master PQ key (ML-DSA-44)
        let finalSig = try await signStealthUserOp(&userOp, stealthPrivateKey: stealthPrivateKey)
        userOp.signature = finalSig
        
        // Submit
        let userOpHash = try await bundler.sendUserOperation(userOp: userOp)
        SecureLogger.info("Stealth sweep UserOp submitted: \(userOpHash), sweep=\(sweepAmount)wei", category: .session)
        
        return SweepResult(
            userOpHash: userOpHash,
            sweepAmountWei: sweepAmount,
            gasCostWei: requiredPrefund,
            balance: balance
        )
    }
    
    // MARK: - Signing
    
    /// Sign a UserOp with the stealth ECDSA key + master ML-DSA-44 key.
    private func signStealthUserOp(
        _ userOp: inout PackedUserOperation,
        stealthPrivateKey: Data
    ) async throws -> Data {
        let hash = UserOperationBuilder.getUserOpHash(
            userOp: userOp,
            entryPoint: UserOperationBuilder.entryPointAddress,
            chainId: chainId
        )
        
        return try await UserOperationBuilder.signHybridWithStealthKey(
            userOpHash: hash,
            stealthPrivateKey: stealthPrivateKey,
            pqKeyManager: pqKeyManager
        )
    }
    
    private func signUserOp(_ userOp: inout PackedUserOperation) async throws -> Data {
        let hash = UserOperationBuilder.getUserOpHash(
            userOp: userOp,
            entryPoint: UserOperationBuilder.entryPointAddress,
            chainId: chainId
        )
        
        // ── AA23 Diagnostic Logging ──
        let eoaAddress = try await wallet.getAddress()
        SecureLogger.info(
            "PQ signUserOp: userOpHash=0x\(hash.map { String(format: "%02x", $0) }.joined().prefix(16))…, "
            + "signer(EOA)=\(eoaAddress.prefix(14))…, chainId=\(chainId)",
            category: .session
        )
        
        // ── AA24 Diagnostic: verify our EOA matches the on-chain preQuantumPubKey ──
        let senderHex = "0x" + userOp.sender.map { String(format: "%02x", $0) }.joined()
        await verifyOnChainPreQuantumKey(sender: senderHex, currentEOA: eoaAddress)
        
        let hybridSig = try await UserOperationBuilder.signHybrid(
            userOpHash: hash,
            wallet: wallet,
            pqKeyManager: pqKeyManager
        )
        
        // Log signature component sizes for debugging AA23
        SecureLogger.info(
            "PQ signUserOp: hybridSigLen=\(hybridSig.count)B (expected: ABI-encoded 65B ECDSA + 2420B MLDSA)",
            category: .session
        )
        
        return hybridSig
    }
    
    // MARK: - On-Chain Key Verification
    
    /// Read the preQuantumPubKey from the smart account's storage and compare
    /// with our current wallet address. Logs match/mismatch to help debug AA24.
    ///
    /// Solidity storage layout of ZKNOX_ERC4337_account:
    ///   slot 0: _entryPoint (address)
    ///   slot 1: preQuantumPubKey (bytes) — 20-byte address, stored inline
    ///   slot 2: postQuantumPubKey (bytes) — 20-byte PKContract address
    ///   slot 3: preQuantumLogicContractAddress (address)
    ///   slot 4: postQuantumLogicContractAddress (address)
    private func verifyOnChainPreQuantumKey(sender: String, currentEOA: String) async {
        do {
            // Read storage slot 1 (preQuantumPubKey) from the smart account
            let slotData = try await ethGetStorageAt(address: sender, slot: "0x1")
            
            // For Solidity `bytes` of length < 32: data is left-aligned, last byte = 2 * length
            // preQuantumPubKey is 20 bytes, so last byte = 0x28 (40)
            guard slotData.count == 32 else {
                SecureLogger.warning("PQ DIAG: storage slot 1 unexpected size: \(slotData.count)", category: .session)
                return
            }
            
            let storedLength = Int(slotData[31]) / 2
            guard storedLength == 20 else {
                SecureLogger.warning(
                    "PQ DIAG: preQuantumPubKey stored length=\(storedLength), expected 20",
                    category: .session
                )
                return
            }
            
            let onChainAddress = "0x" + slotData.prefix(20).map { String(format: "%02x", $0) }.joined()
            let match = onChainAddress.lowercased() == currentEOA.lowercased()
            
            SecureLogger.info(
                "PQ DIAG: on-chain preQuantumPubKey=\(onChainAddress), "
                + "current wallet=\(currentEOA), match=\(match ? "✅" : "❌ MISMATCH")",
                category: .session
            )
            
            if !match {
                SecureLogger.error(
                    "PQ DIAG: ⚠️ ECDSA KEY MISMATCH — the wallet key was regenerated after account deployment! "
                    + "On-chain expects \(onChainAddress) but wallet is \(currentEOA). "
                    + "This WILL cause AA24.",
                    category: .session
                )
            }
            
            // Also read slot 2 (postQuantumPubKey — the PKContract address)
            let slot2Data = try await ethGetStorageAt(address: sender, slot: "0x2")
            if slot2Data.count == 32 {
                let pqKeyLen = Int(slot2Data[31]) / 2
                if pqKeyLen == 20 {
                    let pkContractAddr = "0x" + slot2Data.prefix(20).map { String(format: "%02x", $0) }.joined()
                    SecureLogger.info(
                        "PQ DIAG: on-chain postQuantumPubKey (PKContract)=\(pkContractAddr)",
                        category: .session
                    )
                }
            }
        } catch {
            SecureLogger.warning(
                "PQ DIAG: could not read on-chain keys (non-critical): \(error.localizedDescription)",
                category: .session
            )
        }
    }
    
    /// Read a storage slot from a contract via eth_getStorageAt.
    private func ethGetStorageAt(address: String, slot: String) async throws -> Data {
        let chain: PQAccountDeployer.Chain
        switch chainId {
        case 11_155_111: chain = .sepolia
        case 421_614: chain = .arbitrumSepolia
        default: chain = .sepolia
        }
        
        let body: [String: Any] = [
            "jsonrpc": "2.0",
            "id": 1,
            "method": "eth_getStorageAt",
            "params": [address, slot, "latest"]
        ]
        
        let allRPCs = [chain.rpcURL] + chain.fallbackRPCURLs
        let session = URLSession.shared // testnet — no need for Tor
        
        for rpcEndpoint in allRPCs {
            guard let url = URL(string: rpcEndpoint) else { continue }
            do {
                var request = URLRequest(url: url)
                request.httpMethod = "POST"
                request.setValue("application/json", forHTTPHeaderField: "Content-Type")
                request.httpBody = try JSONSerialization.data(withJSONObject: body)
                request.timeoutInterval = 15
                
                let (responseData, _) = try await session.data(for: request)
                guard let json = try JSONSerialization.jsonObject(with: responseData) as? [String: Any],
                      let hexResult = json["result"] as? String else {
                    continue
                }
                let hex = hexResult.hasPrefix("0x") ? String(hexResult.dropFirst(2)) : hexResult
                return ABIEncoder.hexToData(hex)
            } catch {
                continue
            }
        }
        throw PQTransactionError.rpcError("eth_getStorageAt failed for all RPCs")
    }
    
    // MARK: - On-Chain Verifier Diagnostics
    
    /// Call each signature verifier independently via eth_call to determine
    /// which verifier (ECDSA or ML-DSA) rejects the signature on-chain.
    /// This is the definitive AA24 diagnostic.
    private func diagnoseVerifiersOnChain(
        sender: String,
        userOpHash: Data,
        hybridSig: Data
    ) async {
        do {
            // ── Stale-address check ──
            // Compare the address we're transacting against with what the CURRENT
            // expansion code would produce. If different, the account was deployed
            // with an older key expansion (e.g., pre-NTT fix) and must be redeployed.
            do {
                let freshPreQ = try await getPreQuantumKeyForFactory()
                let freshPostQ = try await getPostQuantumKeyForFactory()
                let freshAddress = try await deployer.getAddress(
                    preQuantumPubKey: freshPreQ,
                    postQuantumPubKey: freshPostQ
                )
                let normalizedSender = sender.lowercased()
                let normalizedFresh = freshAddress.lowercased()
                if normalizedSender != normalizedFresh {
                    SecureLogger.error(
                        "PQ DIAG ⚠️ STALE DEPLOYMENT DETECTED: "
                        + "transacting against \(sender) but current key expansion "
                        + "produces \(freshAddress). The on-chain PKContract has stale data "
                        + "(likely pre-NTT-fix t1). Account MUST be redeployed. "
                        + "Call PQAccountViewModel.reset() then re-initialize.",
                        category: .session
                    )
                } else {
                    SecureLogger.info(
                        "PQ DIAG: address matches current expansion ✅ (\(freshAddress))",
                        category: .session
                    )
                }
            } catch {
                SecureLogger.warning(
                    "PQ DIAG: stale-address check failed: \(error.localizedDescription)",
                    category: .session
                )
            }

            // 1. Decode hybrid signature: abi.decode(sig, (bytes, bytes))
            guard hybridSig.count >= 128 else {
                SecureLogger.warning("PQ DIAG VERIFY: hybrid sig too short: \(hybridSig.count)B", category: .session)
                return
            }
            
            guard let offset1 = ABIEncoder.decodeUInt256(Data(hybridSig[0..<32])),
                  let offset2 = ABIEncoder.decodeUInt256(Data(hybridSig[32..<64])) else {
                SecureLogger.warning("PQ DIAG VERIFY: cannot decode offsets", category: .session)
                return
            }
            
            let off1 = Int(offset1), off2 = Int(offset2)
            guard off1 + 32 <= hybridSig.count, off2 + 32 <= hybridSig.count,
                  let len1 = ABIEncoder.decodeUInt256(Data(hybridSig[off1..<(off1 + 32)])),
                  let len2 = ABIEncoder.decodeUInt256(Data(hybridSig[off2..<(off2 + 32)])) else {
                SecureLogger.warning("PQ DIAG VERIFY: cannot decode sig lengths", category: .session)
                return
            }
            
            let ecdsaSig = Data(hybridSig[(off1 + 32)..<(off1 + 32 + Int(len1))])
            let mldsaSig = Data(hybridSig[(off2 + 32)..<(off2 + 32 + Int(len2))])
            
            SecureLogger.info(
                "PQ DIAG VERIFY: decoded hybrid → ECDSA=\(ecdsaSig.count)B, MLDSA=\(mldsaSig.count)B",
                category: .session
            )
            
            // 2. Read all 5 storage slots from the smart account
            let slot0 = try await ethGetStorageAt(address: sender, slot: "0x0")
            let slot1 = try await ethGetStorageAt(address: sender, slot: "0x1")
            let slot2 = try await ethGetStorageAt(address: sender, slot: "0x2")
            let slot3 = try await ethGetStorageAt(address: sender, slot: "0x3")
            let slot4 = try await ethGetStorageAt(address: sender, slot: "0x4")
            
            // Log raw slot values for debugging storage layout
            for (idx, slotVal) in [slot0, slot1, slot2, slot3, slot4].enumerated() {
                SecureLogger.info(
                    "PQ DIAG VERIFY: slot\(idx)=0x\(slotVal.map { String(format: "%02x", $0) }.joined())",
                    category: .session
                )
            }
            
            // Slot 0: _entryPoint (address, right-aligned in 32 bytes)
            let entryPointAddr = "0x" + slot0.suffix(20).map { String(format: "%02x", $0) }.joined()
            SecureLogger.info("PQ DIAG VERIFY: EntryPoint=\(entryPointAddr)", category: .session)
            
            // Slots 1,2: preQuantumPubKey / postQuantumPubKey (Solidity inline bytes)
            let preQPKLen = Int(slot1[31]) / 2
            let preQPK = Data(slot1.prefix(preQPKLen))
            let postQPKLen = Int(slot2[31]) / 2
            let postQPK = Data(slot2.prefix(postQPKLen))
            
            SecureLogger.info(
                "PQ DIAG VERIFY: preQPK(\(preQPKLen)B)=0x\(preQPK.map { String(format: "%02x", $0) }.joined()), "
                + "postQPK(\(postQPKLen)B)=0x\(postQPK.map { String(format: "%02x", $0) }.joined())",
                category: .session
            )
            
            // Slots 3,4: verifier contract addresses (address, right-aligned)
            let preQuantumVerifier = "0x" + slot3.suffix(20).map { String(format: "%02x", $0) }.joined()
            let postQuantumVerifier = "0x" + slot4.suffix(20).map { String(format: "%02x", $0) }.joined()
            
            SecureLogger.info(
                "PQ DIAG VERIFY: ECDSAk1=\(preQuantumVerifier), ZKNOX_dilithium=\(postQuantumVerifier)",
                category: .session
            )
            
            // 3. Compute verify(bytes,bytes32,bytes) selector
            let verifySelector = ABIEncoder.functionSelector("verify(bytes,bytes32,bytes)")
            let selectorHex = "0x" + verifySelector.map { String(format: "%02x", $0) }.joined()
            
            // 4a. Call ECDSAk1Verifier.verify(preQPK, userOpHash, ecdsaSig)
            let ecdsaParams = ABIEncoder.encode(
                types: [.bytes, .bytesFixed(32), .bytes],
                values: [.bytes(preQPK), .bytes(userOpHash), .bytes(ecdsaSig)]
            )
            let ecdsaCalldata = verifySelector + ecdsaParams
            
            SecureLogger.info(
                "PQ DIAG VERIFY: calling ECDSAk1.verify — pk=\(preQPK.count)B, hash=\(userOpHash.count)B, sig=\(ecdsaSig.count)B, calldata=\(ecdsaCalldata.count)B",
                category: .session
            )
            
            if let ecdsaResult = await diagEthCall(to: preQuantumVerifier, data: ecdsaCalldata) {
                let ecdsaReturn = Data(ecdsaResult.prefix(4))
                let ecdsaPass = ecdsaReturn == verifySelector
                SecureLogger.info(
                    "PQ DIAG VERIFY: ECDSAk1 → 0x\(ecdsaReturn.map { String(format: "%02x", $0) }.joined()) "
                    + "(expected \(selectorHex)) \(ecdsaPass ? "✅ PASS" : "❌ FAIL")",
                    category: .session
                )
            } else {
                SecureLogger.error("PQ DIAG VERIFY: ECDSAk1 → ❌ REVERTED", category: .session)
            }
            
            // 4b. Call ZKNOX_dilithium.verify(postQPK, userOpHash, mldsaSig)
            let mldsaParams = ABIEncoder.encode(
                types: [.bytes, .bytesFixed(32), .bytes],
                values: [.bytes(postQPK), .bytes(userOpHash), .bytes(mldsaSig)]
            )
            let mldsaCalldata = verifySelector + mldsaParams
            
            SecureLogger.info(
                "PQ DIAG VERIFY: calling ZKNOX_dilithium.verify — pk=\(postQPK.count)B, hash=\(userOpHash.count)B, sig=\(mldsaSig.count)B, calldata=\(mldsaCalldata.count)B",
                category: .session
            )
            
            if let mldsaResult = await diagEthCall(to: postQuantumVerifier, data: mldsaCalldata) {
                let mldsaReturn = Data(mldsaResult.prefix(4))
                let mldsaPass = mldsaReturn == verifySelector
                SecureLogger.info(
                    "PQ DIAG VERIFY: ZKNOX_dilithium → 0x\(mldsaReturn.map { String(format: "%02x", $0) }.joined()) "
                    + "(expected \(selectorHex)) \(mldsaPass ? "✅ PASS" : "❌ FAIL")",
                    category: .session
                )
            } else {
                SecureLogger.error("PQ DIAG VERIFY: ZKNOX_dilithium → ❌ REVERTED", category: .session)
            }
            
        } catch {
            SecureLogger.warning(
                "PQ DIAG VERIFY: on-chain verifier test error: \(error.localizedDescription)",
                category: .session
            )
        }
    }
    
    /// Generic eth_call for diagnostic purposes. Returns nil if the call reverts or fails.
    private func diagEthCall(to address: String, data calldata: Data) async -> Data? {
        let chain: PQAccountDeployer.Chain
        switch chainId {
        case 11_155_111: chain = .sepolia
        case 421_614: chain = .arbitrumSepolia
        default: chain = .sepolia
        }
        
        let dataHex = "0x" + calldata.map { String(format: "%02x", $0) }.joined()
        let body: [String: Any] = [
            "jsonrpc": "2.0",
            "id": 1,
            "method": "eth_call",
            "params": [
                ["to": address, "data": dataHex, "gas": "0x1E84800"],  // 32M gas for ML-DSA
                "latest"
            ]
        ]
        
        let allRPCs = [chain.rpcURL] + chain.fallbackRPCURLs
        let session = URLSession.shared
        
        for rpcEndpoint in allRPCs {
            guard let url = URL(string: rpcEndpoint) else { continue }
            do {
                var request = URLRequest(url: url)
                request.httpMethod = "POST"
                request.setValue("application/json", forHTTPHeaderField: "Content-Type")
                request.httpBody = try JSONSerialization.data(withJSONObject: body)
                request.timeoutInterval = 30
                
                let (responseData, _) = try await session.data(for: request)
                guard let json = try JSONSerialization.jsonObject(with: responseData) as? [String: Any] else {
                    continue
                }
                
                if let hexResult = json["result"] as? String {
                    let hex = hexResult.hasPrefix("0x") ? String(hexResult.dropFirst(2)) : hexResult
                    if hex.isEmpty { return Data() }
                    return ABIEncoder.hexToData(hex)
                }
                
                // eth_call reverted — log the error
                if let error = json["error"] as? [String: Any] {
                    let msg = error["message"] as? String ?? "unknown"
                    let errData = error["data"] as? String ?? ""
                    SecureLogger.warning(
                        "PQ DIAG VERIFY: eth_call to \(address.prefix(14))… reverted: \(msg) data=\(errData.prefix(60))",
                        category: .session
                    )
                    return nil
                }
                continue
            } catch {
                continue
            }
        }
        
        SecureLogger.warning("PQ DIAG VERIFY: all RPCs failed for eth_call to \(address.prefix(14))…", category: .session)
        return nil
    }
    
    // MARK: - EntryPoint Nonce
    
    /// Query the EntryPoint contract for the account's nonce.
    private func getEntryPointNonce(sender: String) async throws -> UInt64 {
        // getNonce(address,uint192) selector + ABI params
        // For key=0 (default validation), uint192 = 0
        let selector = ABIEncoder.functionSelector("getNonce(address,uint192)")
        
        let senderBytes = ABIEncoder.hexToData(
            sender.hasPrefix("0x") ? String(sender.dropFirst(2)) : sender
        )
        
        let params = ABIEncoder.encode(
            types: [.address, .uint256],
            values: [.addressData(senderBytes), .uint256(0)]
        )
        
        let calldata = selector + params
        
        // eth_call to EntryPoint
        let result = try await entryPointCall(data: calldata)
        guard let nonceValue = ABIEncoder.decodeUInt256(result) else {
            return 0 // Default to 0 if decode fails (first transaction)
        }
        return nonceValue
    }
    
    /// Generic eth_call to the EntryPoint via Helios (Sepolia) or the deployer's RPC.
    ///
    /// Tier 1: Helios verified ethCall (Sepolia only — Helios doesn't support Arb Sepolia).
    /// Tier 2: RPC over Tor (mainnet/Base) or direct (testnet).
    private func entryPointCall(data calldata: Data) async throws -> Data {
        let entryPoint = UserOperationBuilder.entryPointAddress
        let dataHex = "0x" + calldata.map { String(format: "%02x", $0) }.joined()

        // Tier 1: Helios for Sepolia
        if chainId == 11_155_111, await HeliosManager.shared.isRunning {
            do {
                let callObj: [String: String] = ["to": entryPoint, "data": dataHex]
                let callJSON = try String(data: JSONSerialization.data(withJSONObject: callObj), encoding: .utf8) ?? "{}"
                let hexResult = try await HeliosManager.shared.ethCall(callJSON)
                let hex = hexResult.hasPrefix("0x") ? String(hexResult.dropFirst(2)) : hexResult
                SecureLogger.debug("PQTransactionSigner: Helios-verified EntryPoint call", category: .network)
                return ABIEncoder.hexToData(hex)
            } catch {
                SecureLogger.warning("PQTransactionSigner: Helios ethCall failed, falling back to RPC: \(error)", category: .network)
            }
        }

        // Tier 2: RPC fallback
        let chain: PQAccountDeployer.Chain
        switch chainId {
        case 11_155_111:
            chain = .sepolia
        case 421_614:
            chain = .arbitrumSepolia
        default:
            chain = .sepolia
        }
        
        let body: [String: Any] = [
            "jsonrpc": "2.0",
            "id": 1,
            "method": "eth_call",
            "params": [
                ["to": entryPoint, "data": dataHex],
                "latest"
            ]
        ]
        
        let allRPCs = [chain.rpcURL] + chain.fallbackRPCURLs
        // Use Tor for non-testnet chains
        let session = (chainId == 1 || chainId == 8453) ? TorURLSession.shared.session : URLSession.shared
        
        for rpcEndpoint in allRPCs {
            guard let url = URL(string: rpcEndpoint) else { continue }
            
            do {
                var request = URLRequest(url: url)
                request.httpMethod = "POST"
                request.setValue("application/json", forHTTPHeaderField: "Content-Type")
                request.httpBody = try JSONSerialization.data(withJSONObject: body)
                request.timeoutInterval = 20
                
                let (responseData, _) = try await session.data(for: request)
                guard let json = try JSONSerialization.jsonObject(with: responseData) as? [String: Any],
                      let hexResult = json["result"] as? String else {
                    continue
                }
                
                let hex = hexResult.hasPrefix("0x") ? String(hexResult.dropFirst(2)) : hexResult
                return ABIEncoder.hexToData(hex)
            } catch {
                SecureLogger.warning("PQ EntryPoint call failed for \(rpcEndpoint), trying fallback...", category: .network)
                continue
            }
        }
        
        throw PQTransactionError.rpcError("Failed to get nonce from EntryPoint (all RPCs failed)")
    }
}

// MARK: - Sweep Types

/// Result of a gas estimation for a stealth PQ account sweep.
struct SweepGasEstimate {
    /// Current on-chain balance of the stealth account (wei)
    let balance: UInt64
    /// Gas prefund the EntryPoint will require during validateUserOp (wei)
    let requiredGasPrefund: UInt64
    /// Maximum amount that can be swept: balance - gasPrefund (wei)
    let maxSweepableWei: UInt64
    /// The maxFeePerGas used for the estimate
    let maxFeePerGas: UInt64
    /// Estimated gas limits with safety margin
    let verificationGasLimit: UInt64
    let callGasLimit: UInt64
    let preVerificationGas: UInt64
    /// Whether the account is already deployed
    let isDeployed: Bool
    
    /// Whether a sweep is viable (balance covers gas)
    var canSweep: Bool { maxSweepableWei > 0 }
    
    /// Gas cost as ETH (for display)
    var gasCostETH: Double { Double(requiredGasPrefund) / 1e18 }
    
    /// Max sweepable as ETH (for display)
    var maxSweepableETH: Double { Double(maxSweepableWei) / 1e18 }
    
    /// Balance as ETH (for display)
    var balanceETH: Double { Double(balance) / 1e18 }
    
    /// Sweep efficiency: what percentage of the balance is actually swept
    var sweepEfficiency: Double {
        guard balance > 0 else { return 0 }
        return Double(maxSweepableWei) / Double(balance) * 100
    }
}

/// Result of a successful stealth PQ account sweep.
struct SweepResult {
    /// The UserOp hash from the bundler (for receipt tracking)
    let userOpHash: String
    /// Amount actually swept to the destination (wei)
    let sweepAmountWei: UInt64
    /// Gas cost paid from the stealth balance (wei)
    let gasCostWei: UInt64
    /// Original balance before sweep (wei)
    let balance: UInt64
    
    var sweepAmountETH: Double { Double(sweepAmountWei) / 1e18 }
    var gasCostETH: Double { Double(gasCostWei) / 1e18 }
}

// MARK: - Errors

enum PQTransactionError: Error, LocalizedError {
    case executionReverted(String)
    case configurationError(String)
    case rpcError(String)
    case signingFailed(String)
    case insufficientBalance(balance: Double, sendAmount: Double, gasCost: Double)
    case bundlerRejected(String)
    
    var errorDescription: String? {
        switch self {
        case .executionReverted(let hash):
            return "PQ transaction reverted: \(hash)"
        case .configurationError(let msg):
            return "PQ configuration error: \(msg)"
        case .rpcError(let msg):
            return "PQ RPC error: \(msg)"
        case .signingFailed(let msg):
            return "PQ signing failed: \(msg)"
        case .insufficientBalance(let balance, let sendAmount, let gasCost):
            let shortfall = (sendAmount + gasCost) - balance
            return String(format: "Insufficient balance: you have %.6f ETH but need %.6f ETH to send + %.6f ETH gas for PQ signature verification (total %.6f ETH).\n\nYou need ~%.4f more ETH. Reduce the send amount or add funds.", balance, sendAmount, gasCost, sendAmount + gasCost, max(shortfall, 0))
        case .bundlerRejected(let msg):
            return "Bundler rejected: \(msg)"
        }
    }
}
