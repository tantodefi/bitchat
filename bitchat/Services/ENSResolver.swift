//
// ENSResolver.swift
// bitchat
//
// Unified ENS resolution supporting multiple domains:
// - .dstealth.eth (via Namestone)
// - .eth (via ENS public resolver)
// - .base.eth (via Base L2)
//
// This is free and unencumbered software released into the public domain.
// For more information, see <https://unlicense.org>
//

import Foundation
import Tor

/// Unified ENS resolver supporting multiple domain types
actor ENSResolver {
    
    // MARK: - Singleton
    
    static let shared = ENSResolver()
    
    // MARK: - Configuration
    
    /// Cache for resolved names (TTL: 5 minutes)
    private var cache: [String: CachedResolution] = [:]
    private let cacheTTL: TimeInterval = 300
    
    // MARK: - Initialization
    
    private init() {}
    
    // MARK: - Public API
    
    /// Resolve any ENS name to address and optional XMTP inbox ID
    /// - Parameter ensName: Full ENS name (e.g., "alice.dstealth.eth", "vitalik.eth")
    /// - Returns: Resolution containing address and optional inbox ID
    func resolve(_ ensName: String) async throws -> ENSResolution {
        let name = ensName.lowercased().trimmingCharacters(in: .whitespaces)
        
        // Check cache first
        if let cached = cache[name], !cached.isExpired {
            return cached.resolution
        }
        
        // Route based on domain
        let resolution: ENSResolution

        if name.hasSuffix(".dstealth.eth") {
            resolution = try await resolveViaNamestone(name)
        } else if name.hasSuffix(".base.eth") {
            resolution = try await resolveViaAnyETH(name, includeBasenameProvider: true)
        } else if name.hasSuffix(".eth") {
            resolution = try await resolveViaAnyETH(name, includeBasenameProvider: false)
        } else {
            throw ENSError.unsupportedDomain
        }
        
        // Cache the result
        cache[name] = CachedResolution(resolution: resolution, timestamp: Date())
        
        return resolution
    }
    
    /// Clear the resolution cache
    func clearCache() {
        cache.removeAll()
    }
    
    /// Check if a name can be resolved (for validation)
    func canResolve(_ ensName: String) -> Bool {
        let name = ensName.lowercased()
        return name.hasSuffix(".dstealth.eth") ||
               name.hasSuffix(".base.eth") ||
               name.hasSuffix(".eth")
    }

    /// Nonisolated helper for quick ENS input validation from UI/commands
    nonisolated static func looksLikeENSName(_ input: String) -> Bool {
        input.lowercased().trimmingCharacters(in: .whitespacesAndNewlines).hasSuffix(".eth")
    }

    // MARK: - Generic ETH Name Resolution

    /// Resolve any *.eth name and merge Namestone XMTP records with address providers.
    private func resolveViaAnyETH(_ name: String, includeBasenameProvider: Bool) async throws -> ENSResolution {
        var namestoneRecord: NamestoneRecord?
        do {
            namestoneRecord = try await NamestoneService.shared.resolveName(fullName: name)
        } catch {
            // Optional provider; ignore and continue with onchain/public resolution.
        }

        let providerResolution = try await resolveAddressProviders(
            name,
            includeBasenameProvider: includeBasenameProvider
        )

        let resolvedAddress = providerResolution?.address ?? namestoneRecord?.address
        guard let address = resolvedAddress, !address.isEmpty else {
            throw ENSError.notFound
        }

        let resolvedInbox = namestoneRecord?.xmtpInboxId ?? providerResolution?.xmtpInboxId

        return ENSResolution(
            address: address,
            xmtpInboxId: resolvedInbox,
            fullName: name
        )
    }

    /// Attempt address resolution from multiple providers.
    private func resolveAddressProviders(
        _ name: String,
        includeBasenameProvider: Bool
    ) async throws -> ENSResolution? {
        var firstError: Error?

        if includeBasenameProvider {
            do {
                return try await resolveViaBasename(name)
            } catch {
                firstError = firstError ?? error
            }
        }

        do {
            return try await resolveViaENSIdeas(name)
        } catch {
            firstError = firstError ?? error
        }

        do {
            return try await resolveViaWeb3Bio(name)
        } catch {
            firstError = firstError ?? error
        }

        if let firstError {
            if let ensError = firstError as? ENSError {
                throw ensError
            }
            throw ENSError.networkError
        }

        return nil
    }
    
    // MARK: - Namestone Resolution (.dstealth.eth)
    
    private func resolveViaNamestone(_ name: String) async throws -> ENSResolution {
        let subdomain = name.replacingOccurrences(of: ".dstealth.eth", with: "")
        
        let records = try await NamestoneService.shared.searchName(
            name: subdomain,
            exactMatch: true
        )
        
        guard let record = records.first else {
            throw ENSError.notFound
        }
        
        return ENSResolution(
            address: record.address,
            xmtpInboxId: record.xmtpInboxId,
            fullName: record.fullName
        )
    }
    
    // MARK: - Basename Resolution (.base.eth)
    
    private func resolveViaBasename(_ name: String) async throws -> ENSResolution {
        // Base L2 ENS resolution via Basenames API
        // https://docs.base.org/docs/tools/basenames-faq
        
        let encodedName = name.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? name
        
        // Use Base's official resolver API
        guard let url = URL(string: "https://resolver-api.basename.app/name/\(encodedName)") else {
            throw ENSError.invalidRequest
        }
        
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.addValue("application/json", forHTTPHeaderField: "Accept")
        
        let (data, response) = try await TorURLSession.shared.session.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw ENSError.networkError
        }

        if httpResponse.statusCode == 404 {
            throw ENSError.notFound
        }

        guard httpResponse.statusCode == 200 else {
            throw ENSError.networkError
        }

        let result = try JSONDecoder().decode(BasenameResponse.self, from: data)

        guard let address = result.address, !address.isEmpty else {
            throw ENSError.notFound
        }

        return ENSResolution(
            address: address,
            xmtpInboxId: result.textRecords?["com.xmtp.inbox"],
            fullName: name
        )
    }
    
    // MARK: - Standard ENS Resolution (.eth)
    
    private func resolveViaENS(_ name: String) async throws -> ENSResolution {
        // Maintained for compatibility with older call sites.
        return try await resolveViaAnyETH(name, includeBasenameProvider: false)
    }
    
    // MARK: - Resolution Providers
    
    /// Resolve via ENS Ideas API
    private func resolveViaENSIdeas(_ name: String) async throws -> ENSResolution {
        let encodedName = name.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? name
        
        guard let url = URL(string: "https://api.ensideas.com/ens/resolve/\(encodedName)") else {
            throw ENSError.invalidRequest
        }
        
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = 10
        
        let (data, response) = try await TorURLSession.shared.session.data(for: request)
        
        guard let httpResponse = response as? HTTPURLResponse,
              httpResponse.statusCode == 200 else {
            throw ENSError.networkError
        }
        
        let result = try JSONDecoder().decode(ENSIdeasResponse.self, from: data)
        
        guard let address = result.address, !address.isEmpty else {
            throw ENSError.notFound
        }
        
        return ENSResolution(
            address: address,
            xmtpInboxId: nil, // ENS Ideas doesn't return text records
            fullName: name
        )
    }

    /// Resolve via web3.bio profile API (supports ENS + Basenames)
    private func resolveViaWeb3Bio(_ name: String) async throws -> ENSResolution {
        let encodedName = name.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? name

        guard let url = URL(string: "https://api.web3.bio/profile/\(encodedName)") else {
            throw ENSError.invalidRequest
        }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = 10
        request.addValue("application/json", forHTTPHeaderField: "Accept")

        let (data, response) = try await TorURLSession.shared.session.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse,
              httpResponse.statusCode == 200 else {
            throw ENSError.networkError
        }

        let profiles = try JSONDecoder().decode([Web3BioProfile].self, from: data)

        if let exact = profiles.first(where: { profile in
            profile.identity.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == name
        }), !exact.address.isEmpty {
            return ENSResolution(
                address: exact.address,
                xmtpInboxId: nil,
                fullName: name
            )
        }

        if let first = profiles.first(where: { !$0.address.isEmpty }) {
            return ENSResolution(
                address: first.address,
                xmtpInboxId: nil,
                fullName: name
            )
        }

        throw ENSError.notFound
    }
    
    /// Resolve via Cloudflare ENS gateway (using eth.limo)
    private func resolveViaCloudflare(_ name: String) async throws -> ENSResolution {
        // Use eth.limo for CCIP-read resolution
        // Format: https://name.eth.limo/.well-known/walletconnect.txt or similar
        
        let encodedName = name.replacingOccurrences(of: ".eth", with: "")
            .addingPercentEncoding(withAllowedCharacters: .urlHostAllowed) ?? name
        
        guard let url = URL(string: "https://\(encodedName).eth.limo/") else {
            throw ENSError.invalidRequest
        }
        
        var request = URLRequest(url: url)
        request.httpMethod = "HEAD" // Just check if it resolves
        request.timeoutInterval = 5
        
        let (_, response) = try await TorURLSession.shared.session.data(for: request)
        
        // If we get a response, the name exists - but eth.limo doesn't give us the address
        // So this is mostly a validation step
        guard (response as? HTTPURLResponse)?.statusCode != 404 else {
            throw ENSError.notFound
        }
        
        // Fall back to other method for actual address
        throw ENSError.networkError
    }
    
    /// Resolve via 1RPC (Ethereum RPC with ENS support)
    private func resolveVia1RPC(_ name: String) async throws -> ENSResolution {
        // Using 1RPC which supports ENS resolution
        guard let url = URL(string: "https://1rpc.io/eth") else {
            throw ENSError.invalidRequest
        }
        
        // Prepare ENS resolver call
        // This uses eth_call to the ENS resolver contract
        let resolverData = encodeENSResolve(name: name)
        
        let body: [String: Any] = [
            "jsonrpc": "2.0",
            "method": "eth_call",
            "params": [
                [
                    "to": "0x4976fb03C32e5B8cfe2b6cCB31c09Ba78EBaBa41", // ENS Public Resolver 2
                    "data": resolverData
                ],
                "latest"
            ],
            "id": 1
        ]
        
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.addValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        request.timeoutInterval = 10
        
        let (data, response) = try await TorURLSession.shared.session.data(for: request)
        
        guard let httpResponse = response as? HTTPURLResponse,
              httpResponse.statusCode == 200 else {
            throw ENSError.networkError
        }
        
        let result = try JSONDecoder().decode(RPCResponse.self, from: data)
        
        guard let hexResult = result.result,
              hexResult.count >= 42 else {
            throw ENSError.notFound
        }
        
        // Extract address from result (last 40 hex chars + 0x prefix)
        let address = "0x" + hexResult.suffix(40)
        
        // Validate address
        guard address.count == 42 else {
            throw ENSError.notFound
        }
        
        return ENSResolution(
            address: address,
            xmtpInboxId: nil,
            fullName: name
        )
    }
    
    /// Encode ENS name for resolver lookup
    private func encodeENSResolve(name: String) -> String {
        // Simplified: For production, use proper ENS namehash encoding
        // This returns the addr(bytes32) function signature + namehash
        // Function selector for addr(bytes32): 0x3b3b57de
        
        let namehash = computeNamehash(name)
        return "0x3b3b57de" + namehash
    }
    
    /// Compute ENS namehash (simplified)
    private func computeNamehash(_ name: String) -> String {
        // ENS namehash algorithm
        var node = Data(repeating: 0, count: 32)
        
        let labels = name.split(separator: ".").reversed()
        for label in labels {
            let labelHash = sha3Keccak256(String(label).lowercased())
            var combined = Data()
            combined.append(node)
            combined.append(labelHash)
            node = sha3Keccak256(combined)
        }
        
        return node.hexString
    }
    
    /// SHA3 Keccak-256 hash (simplified implementation)
    private func sha3Keccak256(_ input: String) -> Data {
        sha3Keccak256(Data(input.utf8))
    }
    
    private func sha3Keccak256(_ input: Data) -> Data {
        // Use CommonCrypto or CryptoKit for actual implementation
        // For now, this is a placeholder that should be replaced with proper Keccak
        // In production, use a proper keccak256 implementation
        
        // Placeholder: Return SHA256 (NOT correct for ENS, but compiles)
        // TODO: Replace with actual Keccak-256
        var hash = [UInt8](repeating: 0, count: 32)
        input.withUnsafeBytes { ptr in
            _ = CC_SHA256(ptr.baseAddress, CC_LONG(input.count), &hash)
        }
        return Data(hash)
    }
}

// MARK: - Resolution Result

/// Result of ENS resolution
struct ENSResolution {
    /// Ethereum address (0x...)
    let address: String
    
    /// XMTP inbox ID if available in text records
    let xmtpInboxId: String?
    
    /// Full resolved name
    let fullName: String
    
    /// Whether this resolution includes XMTP inbox for direct messaging
    var hasXMTPInbox: Bool { xmtpInboxId != nil && !xmtpInboxId!.isEmpty }
}

// MARK: - Cache

private struct CachedResolution {
    let resolution: ENSResolution
    let timestamp: Date
    
    var isExpired: Bool {
        Date().timeIntervalSince(timestamp) > 300 // 5 minutes
    }
}

// MARK: - API Response Models

private struct BasenameResponse: Codable {
    let address: String?
    let textRecords: [String: String]?
    
    enum CodingKeys: String, CodingKey {
        case address
        case textRecords = "text_records"
    }
}

private struct ENSIdeasResponse: Codable {
    let address: String?
    let name: String?
    let displayName: String?
    let avatar: String?
}

private struct RPCResponse: Codable {
    let jsonrpc: String?
    let id: Int?
    let result: String?
    let error: RPCError?
}

private struct RPCError: Codable {
    let code: Int?
    let message: String?
}

private struct Web3BioProfile: Codable {
    let address: String
    let identity: String
}

// MARK: - Errors

enum ENSError: Error, LocalizedError {
    case notFound
    case unsupportedDomain
    case networkError
    case invalidRequest
    case invalidResponse
    
    var errorDescription: String? {
        switch self {
        case .notFound:
            return "ENS name not found"
        case .unsupportedDomain:
            return "Unsupported ENS domain. Supported: .eth, .base.eth, .dstealth.eth"
        case .networkError:
            return "Network error during resolution"
        case .invalidRequest:
            return "Invalid ENS request"
        case .invalidResponse:
            return "Invalid response from resolver"
        }
    }
}

// MARK: - Data Extensions

private extension Data {
    var hexString: String {
        map { String(format: "%02x", $0) }.joined()
    }
}

// MARK: - CommonCrypto Import

import CommonCrypto
