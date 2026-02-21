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
        
        // Build initial UserOp with placeholder gas limits (bundler will estimate)
        var userOp = PackedUserOperation(
            sender: ABIEncoder.hexToData(String(sender.dropFirst(2))),
            nonce: nonce,
            initCode: initCode,
            callData: executeCalldata,
            accountGasLimits: UserOperationBuilder.packAccountGasLimits(
                verificationGasLimit: UInt64(500_000),
                callGasLimit: UInt64(200_000)
            ),
            preVerificationGas: UInt64(100_000),
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
        
        // Estimate gas
        let gasEstimate = try await bundler.estimateUserOperationGas(userOp: userOp)
        
        // Update gas values
        userOp.accountGasLimits = UserOperationBuilder.packAccountGasLimits(
            verificationGasLimit: gasEstimate.verificationGasLimit,
            callGasLimit: gasEstimate.callGasLimit
        )
        userOp.preVerificationGas = PackedUserOperation.uint256Data(gasEstimate.preVerificationGas)
        
        // Re-sign with correct gas values
        let finalSig = try await signUserOp(&userOp)
        userOp.signature = finalSig
        
        // Cache gas values for offline fallback
        saveGasCache(
            baseGasPrice: baseGasPrice,
            verificationGasLimit: gasEstimate.verificationGasLimit,
            callGasLimit: gasEstimate.callGasLimit,
            preVerificationGas: gasEstimate.preVerificationGas,
            nonce: nonce
        )
        
        // Submit to bundler
        let userOpHash = try await bundler.sendUserOperation(userOp: userOp)
        SecureLogger.info("PQ UserOp submitted: \(userOpHash)", category: .session)
        
        return userOpHash
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
    
    /// Sweep a stealth PQ account by deploying it (if needed) and transferring its
    /// balance to the user's main PQ account in a single ERC-4337 UserOp.
    ///
    /// The stealth private key is used for ECDSA signing (it owns the stealth signer EOA),
    /// while the master ML-DSA-44 key is used for PQ signing (shared across all accounts).
    ///
    /// - Parameters:
    ///   - stealthAccount: The stealth PQ account to sweep
    ///   - stealthPrivateKey: The 32-byte ECDSA private key for this stealth signer
    ///   - destinationAddress: Where to send the funds (usually main PQ account)
    ///   - sweepAmountWei: Amount to sweep (leave some for gas if needed)
    /// - Returns: UserOp hash for tracking
    func sweepStealthAccount(
        stealthAccount: StealthPQAccount,
        stealthPrivateKey: Data,
        destinationAddress: String,
        sweepAmountWei: UInt64
    ) async throws -> String {
        let sender = stealthAccount.pqAccountAddress
        
        // Build execute calldata: transfer ETH to destination
        let executeCalldata = ABIEncoder.encodeExecute(
            dest: destinationAddress,
            value: sweepAmountWei,
            funcData: Data()
        )
        
        // Check if the stealth PQ account is deployed
        let deployed = stealthAccount.isDeployed
        
        // Build initCode if not deployed (deploy-on-sweep pattern)
        var initCode = Data()
        if !deployed {
            // Use stealth signer address as preQ key, master PQ key as postQ
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
        
        SecureLogger.info(
            "Stealth sweep UserOp: sender=\(sender.prefix(10))..., dest=\(destinationAddress.prefix(10))..., amount=\(sweepAmountWei)wei",
            category: .session
        )
        
        // Build UserOp
        var userOp = PackedUserOperation(
            sender: ABIEncoder.hexToData(String(sender.dropFirst(2))),
            nonce: nonce,
            initCode: initCode,
            callData: executeCalldata,
            accountGasLimits: UserOperationBuilder.packAccountGasLimits(
                verificationGasLimit: UInt64(600_000), // Higher for deploy+sweep
                callGasLimit: UInt64(200_000)
            ),
            preVerificationGas: UInt64(150_000),
            gasFees: UserOperationBuilder.packGasFees(
                maxPriorityFeePerGas: priorityFee,
                maxFeePerGas: maxFee
            ),
            paymasterAndData: Data(),
            signature: Data()
        )
        
        // Sign with stealth private key (ECDSA) + master PQ key (ML-DSA-44)
        let dummySig = try await signStealthUserOp(&userOp, stealthPrivateKey: stealthPrivateKey)
        userOp.signature = dummySig
        
        // Estimate gas
        let gasEstimate = try await bundler.estimateUserOperationGas(userOp: userOp)
        
        // Update gas values
        userOp.accountGasLimits = UserOperationBuilder.packAccountGasLimits(
            verificationGasLimit: gasEstimate.verificationGasLimit,
            callGasLimit: gasEstimate.callGasLimit
        )
        userOp.preVerificationGas = PackedUserOperation.uint256Data(gasEstimate.preVerificationGas)
        
        // Re-sign with correct gas values
        let finalSig = try await signStealthUserOp(&userOp, stealthPrivateKey: stealthPrivateKey)
        userOp.signature = finalSig
        
        // Submit
        let userOpHash = try await bundler.sendUserOperation(userOp: userOp)
        SecureLogger.info("Stealth sweep UserOp submitted: \(userOpHash)", category: .session)
        
        return userOpHash
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
        
        return try await UserOperationBuilder.signHybrid(
            userOpHash: hash,
            wallet: wallet,
            pqKeyManager: pqKeyManager
        )
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

// MARK: - Errors

enum PQTransactionError: Error, LocalizedError {
    case executionReverted(String)
    case configurationError(String)
    case rpcError(String)
    case signingFailed(String)
    
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
        }
    }
}
