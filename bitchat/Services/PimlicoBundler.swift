//
// PimlicoBundler.swift
// bitchat
//
// JSON-RPC client for the Pimlico ERC-4337 bundler.
// Submits PackedUserOperations and queries receipts.
//
// This is free and unencumbered software released into the public domain.
// For more information, see <https://unlicense.org>
//

import BitLogger
import Foundation

// MARK: - Pimlico Bundler Client

/// Async JSON-RPC client for the Pimlico ERC-4337 v0.7 bundler.
actor PimlicoBundler {
    
    private let apiKey: String
    private let chainId: UInt64
    private let session: URLSession
    
    /// Base URL template for Pimlico
    private var rpcURL: URL {
        URL(string: "https://api.pimlico.io/v2/\(chainId)/rpc?apikey=\(apiKey)")!
    }
    
    init(apiKey: String, chainId: UInt64, session: URLSession = .shared) {
        self.apiKey = apiKey
        self.chainId = chainId
        self.session = session
    }
    
    /// Expose API key for mesh relay payloads (relay peer needs it to submit UserOps)
    func getAPIKey() -> String { apiKey }
    
    /// Expose chain ID for external use
    func getChainId() -> UInt64 { chainId }
    
    // MARK: - ERC-4337 Methods
    
    /// Estimate gas for a UserOperation
    /// Returns (preVerificationGas, verificationGasLimit, callGasLimit)
    func estimateUserOperationGas(
        userOp: PackedUserOperation
    ) async throws -> GasEstimate {
        let params: [Any] = [
            userOpToDict(userOp),
            UserOperationBuilder.entryPointV07
        ]
        
        let result = try await call(method: "eth_estimateUserOperationGas", params: params)
        
        guard let dict = result as? [String: Any] else {
            throw BundlerError.invalidResponse("Expected dictionary for gas estimate")
        }
        
        return GasEstimate(
            preVerificationGas: parseHexUInt64(dict["preVerificationGas"]) ?? 50_000,
            verificationGasLimit: parseHexUInt64(dict["verificationGasLimit"]) ?? 500_000,
            callGasLimit: parseHexUInt64(dict["callGasLimit"]) ?? 100_000,
            paymasterVerificationGasLimit: parseHexUInt64(dict["paymasterVerificationGasLimit"]),
            paymasterPostOpGasLimit: parseHexUInt64(dict["paymasterPostOpGasLimit"])
        )
    }
    
    /// Submit a signed UserOperation to the bundler
    /// Returns the UserOperation hash
    func sendUserOperation(
        userOp: PackedUserOperation
    ) async throws -> String {
        let params: [Any] = [
            userOpToDict(userOp),
            UserOperationBuilder.entryPointV07
        ]
        
        let result = try await call(method: "eth_sendUserOperation", params: params)
        
        guard let hash = result as? String else {
            throw BundlerError.invalidResponse("Expected string hash from sendUserOperation")
        }
        
        return hash
    }
    
    /// Get the receipt for a UserOperation
    func getUserOperationReceipt(
        userOpHash: String
    ) async throws -> UserOpReceipt? {
        let result = try await call(method: "eth_getUserOperationReceipt", params: [userOpHash])
        
        // null means not yet included
        if result is NSNull || result == nil {
            return nil
        }
        
        guard let dict = result as? [String: Any] else {
            throw BundlerError.invalidResponse("Expected dictionary for receipt")
        }
        
        return UserOpReceipt(
            userOpHash: dict["userOpHash"] as? String ?? "",
            success: dict["success"] as? Bool ?? false,
            actualGasCost: dict["actualGasCost"] as? String ?? "0",
            actualGasUsed: dict["actualGasUsed"] as? String ?? "0",
            receipt: dict["receipt"] as? [String: Any]
        )
    }
    
    /// Poll for a UserOperation receipt with timeout
    func waitForReceipt(
        userOpHash: String,
        timeout: TimeInterval = 60,
        pollInterval: TimeInterval = 2
    ) async throws -> UserOpReceipt {
        let deadline = Date().addingTimeInterval(timeout)
        
        while Date() < deadline {
            if let receipt = try await getUserOperationReceipt(userOpHash: userOpHash) {
                return receipt
            }
            try await Task.sleep(nanoseconds: UInt64(pollInterval * 1_000_000_000))
        }
        
        throw BundlerError.timeout(userOpHash)
    }
    
    /// Get supported entry points
    func supportedEntryPoints() async throws -> [String] {
        let result = try await call(method: "eth_supportedEntryPoints", params: [])
        guard let entryPoints = result as? [String] else {
            throw BundlerError.invalidResponse("Expected array of entry points")
        }
        return entryPoints
    }
    
    // MARK: - JSON-RPC Transport
    
    private func call(method: String, params: [Any]) async throws -> Any? {
        let body: [String: Any] = [
            "jsonrpc": "2.0",
            "id": 1,
            "method": method,
            "params": params
        ]
        
        guard JSONSerialization.isValidJSONObject(body) else {
            throw BundlerError.invalidRequest("Cannot serialize params to JSON")
        }
        
        var request = URLRequest(url: rpcURL)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        request.timeoutInterval = 30
        
        let (data, response) = try await session.data(for: request)
        
        guard let httpResponse = response as? HTTPURLResponse else {
            throw BundlerError.networkError("Non-HTTP response")
        }
        
        guard (200...299).contains(httpResponse.statusCode) else {
            let bodyStr = String(data: data, encoding: .utf8) ?? "<binary>"
            throw BundlerError.httpError(httpResponse.statusCode, bodyStr)
        }
        
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw BundlerError.invalidResponse("Cannot parse JSON response")
        }
        
        // Check for JSON-RPC error
        if let error = json["error"] as? [String: Any] {
            let code = error["code"] as? Int ?? -1
            let message = error["message"] as? String ?? "Unknown error"
            throw BundlerError.rpcError(code, message)
        }
        
        return json["result"]
    }
    
    // MARK: - Helpers
    
    /// Convert PackedUserOperation to a JSON-RPC compatible dictionary.
    ///
    /// ERC-4337 v0.7 uses a *packed* on-chain representation (gasFees, accountGasLimits,
    /// initCode, paymasterAndData) but the JSON-RPC API expects the *unpacked* individual
    /// fields (maxFeePerGas, maxPriorityFeePerGas, callGasLimit, verificationGasLimit,
    /// factory, factoryData, paymaster, etc.).
    private func userOpToDict(_ op: PackedUserOperation) -> [String: Any] {
        var dict: [String: Any] = [
            "sender": ABIEncoder.dataToHex(op.sender, prefixed: true),
            "nonce": unpackUInt256Hex(op.nonce),  // Minimal hex — bundler rejects padded uint256
            "callData": ABIEncoder.dataToHex(op.callData, prefixed: true),
            "signature": ABIEncoder.dataToHex(op.signature, prefixed: true),
        ]
        
        // Unpack accountGasLimits (32 bytes) → verificationGasLimit (upper 16) + callGasLimit (lower 16)
        if op.accountGasLimits.count == 32 {
            let vgl = unpackUInt256Hex(op.accountGasLimits.subdata(in: 0..<16))
            let cgl = unpackUInt256Hex(op.accountGasLimits.subdata(in: 16..<32))
            dict["verificationGasLimit"] = vgl
            dict["callGasLimit"] = cgl
        }
        
        // preVerificationGas as minimal hex string (strip leading zeros)
        dict["preVerificationGas"] = unpackUInt256Hex(op.preVerificationGas)
        
        // Unpack gasFees (32 bytes) → maxPriorityFeePerGas (upper 16) + maxFeePerGas (lower 16)
        if op.gasFees.count == 32 {
            let mpfpg = unpackUInt256Hex(op.gasFees.subdata(in: 0..<16))
            let mfpg = unpackUInt256Hex(op.gasFees.subdata(in: 16..<32))
            dict["maxPriorityFeePerGas"] = mpfpg
            dict["maxFeePerGas"] = mfpg
        }
        
        // Unpack initCode → factory (first 20 bytes) + factoryData (rest)
        if op.initCode.count >= 20 {
            let factory = "0x" + op.initCode.subdata(in: 0..<20).map { String(format: "%02x", $0) }.joined()
            let factoryData = "0x" + op.initCode.subdata(in: 20..<op.initCode.count).map { String(format: "%02x", $0) }.joined()
            dict["factory"] = factory
            dict["factoryData"] = factoryData
        } else if op.initCode.isEmpty {
            // No factory needed (account already deployed)
        } else {
            // Malformed initCode — pass as-is for debugging
            dict["factory"] = ABIEncoder.dataToHex(op.initCode, prefixed: true)
            dict["factoryData"] = "0x"
        }
        
        // Unpack paymasterAndData → paymaster (20) + paymasterVerificationGasLimit (16) + paymasterPostOpGasLimit (16) + paymasterData (rest)
        if op.paymasterAndData.count >= 52 {
            let paymaster = "0x" + op.paymasterAndData.subdata(in: 0..<20).map { String(format: "%02x", $0) }.joined()
            let pmVGL = unpackUInt256Hex(op.paymasterAndData.subdata(in: 20..<36))
            let pmPOGL = unpackUInt256Hex(op.paymasterAndData.subdata(in: 36..<52))
            let pmData = "0x" + op.paymasterAndData.subdata(in: 52..<op.paymasterAndData.count).map { String(format: "%02x", $0) }.joined()
            dict["paymaster"] = paymaster
            dict["paymasterVerificationGasLimit"] = pmVGL
            dict["paymasterPostOpGasLimit"] = pmPOGL
            dict["paymasterData"] = pmData
        } else if op.paymasterAndData.isEmpty {
            // No paymaster
        }
        
        return dict
    }
    
    /// Convert big-endian bytes (up to 16 bytes / 128-bit) to a 0x-prefixed hex uint256 string.
    /// Strips leading zeros for a clean minimal hex representation.
    private func unpackUInt256Hex(_ data: Data) -> String {
        let hex = data.map { String(format: "%02x", $0) }.joined()
        // Strip leading zeros but keep at least one digit
        let stripped = String(hex.drop(while: { $0 == "0" }))
        return "0x" + (stripped.isEmpty ? "0" : stripped)
    }
    
    private func parseHexUInt64(_ value: Any?) -> UInt64? {
        guard let str = value as? String else { return nil }
        let hex = str.hasPrefix("0x") ? String(str.dropFirst(2)) : str
        return UInt64(hex, radix: 16)
    }
}

// MARK: - Types

struct GasEstimate {
    let preVerificationGas: UInt64
    let verificationGasLimit: UInt64
    let callGasLimit: UInt64
    let paymasterVerificationGasLimit: UInt64?
    let paymasterPostOpGasLimit: UInt64?
}

struct UserOpReceipt {
    let userOpHash: String
    let success: Bool
    let actualGasCost: String
    let actualGasUsed: String
    let receipt: [String: Any]?
}

// MARK: - Errors

enum BundlerError: Error, LocalizedError {
    case invalidRequest(String)
    case networkError(String)
    case httpError(Int, String)
    case rpcError(Int, String)
    case invalidResponse(String)
    case timeout(String)
    
    var errorDescription: String? {
        switch self {
        case .invalidRequest(let msg):
            return "Invalid bundler request: \(msg)"
        case .networkError(let msg):
            return "Bundler network error: \(msg)"
        case .httpError(let code, let body):
            return "Bundler HTTP \(code): \(body.prefix(200))"
        case .rpcError(let code, let msg):
            return "Bundler RPC error \(code): \(msg)"
        case .invalidResponse(let msg):
            return "Invalid bundler response: \(msg)"
        case .timeout(let hash):
            return "Timeout waiting for UserOp receipt: \(hash)"
        }
    }
}
