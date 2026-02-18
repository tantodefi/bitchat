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
    
    // MARK: - Account Address
    
    /// Get or compute the PQ account address (counterfactual if not deployed).
    func getAccountAddress() async throws -> String {
        if let cached = _accountAddress {
            return cached
        }
        
        // Get ECDSA public key from wallet
        let ecdsaPubKey = try await wallet.getPublicKey()
        
        // Get ML-DSA-44 public key
        let pqPubKey = try await pqKeyManager.getPublicKey()
        
        // Compute counterfactual address
        let address = try await deployer.getAddress(
            preQuantumPubKey: ecdsaPubKey,
            postQuantumPubKey: Data(pqPubKey.keyBytes)
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
            let ecdsaPubKey = try await wallet.getPublicKey()
            let pqPubKey = try await pqKeyManager.getPublicKey()
            initCode = await deployer.buildInitCode(
                preQuantumPubKey: ecdsaPubKey,
                postQuantumPubKey: Data(pqPubKey.keyBytes)
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
        
        // Submit to bundler
        let userOpHash = try await bundler.sendUserOperation(userOp: userOp)
        SecureLogger.info("PQ UserOp submitted: \(userOpHash)", category: .session)
        
        return userOpHash
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
        
        let ecdsaPubKey = try await wallet.getPublicKey()
        let pqPubKey = try await pqKeyManager.getPublicKey()
        let eoaAddress = try await wallet.getAddress()
        let nonce = try await deployer.getNonce(address: eoaAddress)
        
        let signedTx = try await deployer.buildDeployTransaction(
            wallet: wallet,
            preQuantumPubKey: ecdsaPubKey,
            postQuantumPubKey: Data(pqPubKey.keyBytes),
            nonce: nonce
        )
        
        let txHash = try await deployer.sendRawTransaction(signedTx)
        SecureLogger.info("PQ account deploy tx: \(txHash)", category: .session)
        
        return txHash
    }
    
    // MARK: - Signing
    
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
    
    /// Generic eth_call to the EntryPoint via the deployer's RPC.
    private func entryPointCall(data calldata: Data) async throws -> Data {
        let entryPoint = UserOperationBuilder.entryPointAddress
        let dataHex = "0x" + calldata.map { String(format: "%02x", $0) }.joined()
        
        // Reuse the deployer's RPC by calling its ethCall indirectly.
        // We do a lightweight JSON-RPC call here, using the chain's RPC URL
        // from the deployer via a static lookup based on chainId.
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
        
        for rpcEndpoint in allRPCs {
            guard let url = URL(string: rpcEndpoint) else { continue }
            
            do {
                var request = URLRequest(url: url)
                request.httpMethod = "POST"
                request.setValue("application/json", forHTTPHeaderField: "Content-Type")
                request.httpBody = try JSONSerialization.data(withJSONObject: body)
                request.timeoutInterval = 20
                
                let (responseData, _) = try await URLSession.shared.data(for: request)
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
