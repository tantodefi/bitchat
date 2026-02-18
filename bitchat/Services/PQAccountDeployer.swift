//
// PQAccountDeployer.swift
// bitchat
//
// Factory interaction for deploying and querying PQ smart accounts.
// Uses the mldsa_k1 factory deployed on Sepolia and Arbitrum Sepolia.
//
// This is free and unencumbered software released into the public domain.
// For more information, see <https://unlicense.org>
//

import BitLogger
import CryptoSwift
import Foundation

// MARK: - PQ Account Deployer

/// Manages PQ smart account deployment via the mldsa_k1 factory contract.
/// Supports both direct EOA deployment and ERC-4337 initCode-based deployment.
actor PQAccountDeployer {
    
    /// Factory contract address (deployed on Sepolia and Arbitrum Sepolia)
    static let factoryAddress = "0xe28F039653772C32b0eDB1db7c7A5FA250DDA0e5"
    
    /// Supported chain configurations
    enum Chain: CaseIterable, Equatable, Hashable {
        case sepolia
        case arbitrumSepolia
        
        var chainId: UInt64 {
            switch self {
            case .sepolia: return 11_155_111
            case .arbitrumSepolia: return 421_614
            }
        }
        
        var rpcURL: String {
            switch self {
            case .sepolia: return "https://ethereum-sepolia-rpc.publicnode.com"
            case .arbitrumSepolia: return "https://sepolia-rollup.arbitrum.io/rpc"
            }
        }
        
        var fallbackRPCURLs: [String] {
            switch self {
            case .sepolia: return ["https://sepolia.drpc.org", "https://rpc2.sepolia.org"]
            case .arbitrumSepolia: return ["https://arbitrum-sepolia-rpc.publicnode.com"]
            }
        }
        
        var name: String {
            switch self {
            case .sepolia: return "Sepolia"
            case .arbitrumSepolia: return "Arbitrum Sepolia"
            }
        }
    }
    
    private let chain: Chain
    private let session: URLSession
    
    init(chain: Chain = .sepolia, session: URLSession = .shared) {
        self.chain = chain
        self.session = session
    }
    
    // MARK: - Counterfactual Address
    
    /// Compute the counterfactual address for a PQ account before deployment.
    /// Calls factory.getAddress(preQuantumPubKey, postQuantumPubKey) via eth_call.
    func getAddress(
        preQuantumPubKey: Data,
        postQuantumPubKey: Data
    ) async throws -> String {
        let calldata = ABIEncoder.encodeGetAddress(
            preQuantumPubKey: preQuantumPubKey,
            postQuantumPubKey: postQuantumPubKey
        )
        
        let result = try await ethCall(
            to: Self.factoryAddress,
            data: calldata
        )
        
        // Result is ABI-encoded address (32 bytes, address in last 20)
        guard result.count >= 32 else {
            throw DeployerError.invalidResponse("getAddress returned \(result.count) bytes")
        }
        
        guard let address = ABIEncoder.decodeAddress(result) else {
            throw DeployerError.invalidResponse("Failed to decode address from response")
        }
        return address
    }
    
    /// Compute counterfactual address with expanded key
    func getAddressWithExpandedKey(
        preQuantumPubKey: Data,
        expandedPostQuantumPubKey: Data
    ) async throws -> String {
        // For the expanded key version, we need to call a different factory method
        // that accepts the pre-expanded key. For now, use the standard getAddress.
        return try await getAddress(
            preQuantumPubKey: preQuantumPubKey,
            postQuantumPubKey: expandedPostQuantumPubKey
        )
    }
    
    // MARK: - Deployment Check
    
    /// Check if a PQ account is already deployed at the given address.
    func isDeployed(address: String) async throws -> Bool {
        let code = try await ethGetCode(address: address)
        return code.count > 0
    }
    
    // MARK: - Build InitCode (for ERC-4337)
    
    /// Build the initCode for ERC-4337 account creation.
    /// Returns factory_address (20 bytes) + createAccount calldata.
    func buildInitCode(
        preQuantumPubKey: Data,
        postQuantumPubKey: Data
    ) -> Data {
        UserOperationBuilder.buildInitCode(
            factoryAddress: Self.factoryAddress,
            preQuantumPubKey: preQuantumPubKey,
            postQuantumPubKey: postQuantumPubKey
        )
    }
    
    // MARK: - Direct Deployment via EOA Transaction
    
    /// Deploy a PQ account via a direct EOA transaction to the factory.
    /// This is a simple alternative to ERC-4337 for initial deployment.
    /// - Parameters:
    ///   - wallet: The EOA wallet to send the deployment tx
    ///   - preQuantumPubKey: secp256k1 public key (uncompressed, 65 bytes)
    ///   - postQuantumPubKey: ML-DSA-44 public key (1312 bytes)
    ///   - nonce: EOA nonce
    ///   - gasParams: Gas parameters for the transaction
    /// - Returns: Signed transaction data ready for eth_sendRawTransaction
    func buildDeployTransaction(
        wallet: EmbeddedWallet,
        preQuantumPubKey: Data,
        postQuantumPubKey: Data,
        nonce: UInt64,
        maxPriorityFeePerGas: UInt64 = 2_000_000_000,  // 2 gwei
        maxFeePerGas: UInt64 = 50_000_000_000,          // 50 gwei
        gasLimit: UInt64 = 3_000_000                     // 3M gas for deployment
    ) async throws -> Data {
        let calldata = ABIEncoder.encodeCreateAccount(
            preQuantumPubKey: preQuantumPubKey,
            postQuantumPubKey: postQuantumPubKey
        )
        
        return try await wallet.signTransaction(
            chainId: chain.chainId,
            nonce: nonce,
            maxPriorityFeePerGas: maxPriorityFeePerGas,
            maxFeePerGas: maxFeePerGas,
            gasLimit: gasLimit,
            to: Self.factoryAddress,
            value: 0,
            data: calldata
        )
    }
    
    /// Send a raw signed transaction via eth_sendRawTransaction
    func sendRawTransaction(_ signedTx: Data) async throws -> String {
        let hexTx = "0x" + signedTx.map { String(format: "%02x", $0) }.joined()
        
        let result = try await rpcCall(
            method: "eth_sendRawTransaction",
            params: [hexTx]
        )
        
        guard let txHash = result as? String else {
            throw DeployerError.invalidResponse("Expected tx hash string")
        }
        
        return txHash
    }
    
    /// Get the current nonce for an address
    func getNonce(address: String) async throws -> UInt64 {
        let result = try await rpcCall(
            method: "eth_getTransactionCount",
            params: [address, "latest"]
        )
        
        guard let hexStr = result as? String else {
            throw DeployerError.invalidResponse("Expected hex nonce string")
        }
        
        let hex = hexStr.hasPrefix("0x") ? String(hexStr.dropFirst(2)) : hexStr
        return UInt64(hex, radix: 16) ?? 0
    }
    
    // MARK: - JSON-RPC
    
    private func ethCall(to: String, data: Data) async throws -> Data {
        let dataHex = "0x" + data.map { String(format: "%02x", $0) }.joined()
        
        let callObj: [String: String] = [
            "to": to,
            "data": dataHex
        ]
        
        let result = try await rpcCall(method: "eth_call", params: [callObj, "latest"])
        
        guard let hexResult = result as? String else {
            throw DeployerError.invalidResponse("eth_call returned non-string")
        }
        
        return ABIEncoder.hexToData(String(hexResult.dropFirst(2)))
    }
    
    private func ethGetCode(address: String) async throws -> Data {
        let result = try await rpcCall(method: "eth_getCode", params: [address, "latest"])
        
        guard let hexResult = result as? String else {
            throw DeployerError.invalidResponse("eth_getCode returned non-string")
        }
        
        let hex = hexResult.hasPrefix("0x") ? String(hexResult.dropFirst(2)) : hexResult
        if hex.isEmpty || hex == "0x" {
            return Data()
        }
        return ABIEncoder.hexToData(hex)
    }
    
    private func rpcCall(method: String, params: [Any]) async throws -> Any? {
        let body: [String: Any] = [
            "jsonrpc": "2.0",
            "id": 1,
            "method": method,
            "params": params
        ]
        
        guard JSONSerialization.isValidJSONObject(body) else {
            throw DeployerError.invalidRequest("Cannot serialize to JSON")
        }
        
        let allRPCs = [chain.rpcURL] + chain.fallbackRPCURLs
        var lastError: Error = DeployerError.networkError("No RPCs available")
        
        for rpcEndpoint in allRPCs {
            guard let rpcUrl = URL(string: rpcEndpoint) else { continue }
            
            do {
                var request = URLRequest(url: rpcUrl)
                request.httpMethod = "POST"
                request.setValue("application/json", forHTTPHeaderField: "Content-Type")
                request.httpBody = try JSONSerialization.data(withJSONObject: body)
                request.timeoutInterval = 20
                
                let (data, response) = try await session.data(for: request)
                
                guard let httpResponse = response as? HTTPURLResponse,
                      (200...299).contains(httpResponse.statusCode) else {
                    lastError = DeployerError.networkError("HTTP error from \(rpcEndpoint)")
                    continue
                }
                
                guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                    lastError = DeployerError.invalidResponse("Cannot parse JSON from \(rpcEndpoint)")
                    continue
                }
                
                if let error = json["error"] as? [String: Any] {
                    let code = error["code"] as? Int ?? -1
                    let message = error["message"] as? String ?? "Unknown"
                    throw DeployerError.rpcError(code, message)
                }
                
                return json["result"]
            } catch let error as DeployerError {
                // RPC-level errors (not network) should propagate immediately
                if case .rpcError = error { throw error }
                lastError = error
                SecureLogger.warning("PQ deployer RPC failed for \(rpcEndpoint), trying fallback...", category: .network)
            } catch {
                lastError = DeployerError.networkError("\(rpcEndpoint): \(error.localizedDescription)")
                SecureLogger.warning("PQ deployer RPC failed for \(rpcEndpoint), trying fallback...", category: .network)
            }
        }
        
        throw lastError
    }
}

// MARK: - Errors

enum DeployerError: Error, LocalizedError {
    case invalidRequest(String)
    case networkError(String)
    case rpcError(Int, String)
    case invalidResponse(String)
    case accountAlreadyDeployed(String)
    case deploymentFailed(String)
    
    var errorDescription: String? {
        switch self {
        case .invalidRequest(let msg):
            return "Invalid deployer request: \(msg)"
        case .networkError(let msg):
            return "Deployer network error: \(msg)"
        case .rpcError(let code, let msg):
            return "RPC error \(code): \(msg)"
        case .invalidResponse(let msg):
            return "Invalid deployer response: \(msg)"
        case .accountAlreadyDeployed(let addr):
            return "PQ account already deployed at \(addr)"
        case .deploymentFailed(let msg):
            return "PQ account deployment failed: \(msg)"
        }
    }
}
