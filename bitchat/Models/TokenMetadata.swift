//
// TokenMetadata.swift
// bitchat
//
// Model for ERC-20 token metadata and persistent custom token storage.
// Loads default tokens from a bundled JSON file and supports user-added custom tokens.
//
// This is free and unencumbered software released into the public domain.
// For more information, see <https://unlicense.org>
//

import BitLogger
import Foundation
import Tor

// MARK: - Token Metadata

/// Represents metadata for an ERC-20 token across multiple chains.
struct TokenMetadata: Codable, Identifiable, Equatable, Hashable {
    let symbol: String
    let name: String
    let decimals: UInt8
    let iconName: String
    /// Optional remote logo image URL (e.g. from CoinGecko/TrustWallet).
    let logoURI: String?
    /// Chain ID → contract address mapping
    let deployments: [String: String]

    /// Coding keys with default for logoURI (backward compat).
    enum CodingKeys: String, CodingKey {
        case symbol, name, decimals, iconName, logoURI, deployments
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        symbol = try container.decode(String.self, forKey: .symbol)
        name = try container.decode(String.self, forKey: .name)
        decimals = try container.decode(UInt8.self, forKey: .decimals)
        iconName = try container.decode(String.self, forKey: .iconName)
        logoURI = try container.decodeIfPresent(String.self, forKey: .logoURI)
        deployments = try container.decode([String: String].self, forKey: .deployments)
    }

    init(symbol: String, name: String, decimals: UInt8, iconName: String, logoURI: String? = nil, deployments: [String: String]) {
        self.symbol = symbol
        self.name = name
        self.decimals = decimals
        self.iconName = iconName
        self.logoURI = logoURI
        self.deployments = deployments
    }

    var id: String { symbol }

    /// Returns the contract address for a given chain ID, or nil if not deployed.
    func address(onChainId chainId: Int) -> String? {
        deployments[String(chainId)]
    }

    /// Returns the contract address for a given network.
    func address(onNetwork network: EthereumBalanceService.Network) -> String? {
        address(onChainId: network.chainId)
    }

    /// All chain IDs where this token is deployed.
    var supportedChainIds: [Int] {
        deployments.keys.compactMap { Int($0) }
    }
}

// MARK: - Custom Token Entry

/// A user-added custom token (persisted locally).
struct CustomTokenEntry: Codable, Identifiable, Equatable, Hashable {
    let id: String  // UUID string
    let contractAddress: String
    let chainId: Int
    let symbol: String
    let name: String
    let decimals: UInt8
    let dateAdded: Date

    init(contractAddress: String, chainId: Int, symbol: String, name: String, decimals: UInt8) {
        self.id = UUID().uuidString
        self.contractAddress = contractAddress.lowercased()
        self.chainId = chainId
        self.symbol = symbol
        self.name = name
        self.decimals = decimals
        self.dateAdded = Date()
    }
}

// MARK: - Token Balance

/// A fetched token balance for a specific token on a specific chain.
struct TokenBalance: Identifiable, Equatable {
    let token: TokenMetadata
    let network: EthereumBalanceService.Network
    let rawBalance: BigUInt
    let lastUpdated: Date

    var id: String { "\(token.symbol)-\(network.chainId)" }

    /// Formatted balance in human-readable units (respecting token decimals).
    var formattedBalance: String {
        let divisor = BigUInt(10).power(Int(token.decimals))
        guard !divisor.isZero else { return "0" }
        let whole = rawBalance / divisor
        let fraction = rawBalance % divisor

        // Build fractional string with leading zeros
        let fracStr = String(describing: fraction)
        let paddedFrac = String(repeating: "0", count: max(0, Int(token.decimals) - fracStr.count)) + fracStr
        // Trim trailing zeros but keep at least 2 decimal places
        let trimmed = String(paddedFrac.prefix(max(2, Int(min(token.decimals, 6)))))
        let cleanTrimmed = trimmed.replacingOccurrences(of: "0+$", with: "", options: .regularExpression)
        let finalFrac = cleanTrimmed.isEmpty ? "00" : cleanTrimmed
        return "\(whole).\(finalFrac)"
    }

    /// Balance as Double (may lose precision for very large values).
    var balanceDouble: Double {
        let divisor = BigUInt(10).power(Int(token.decimals))
        guard !divisor.isZero else { return 0 }
        let whole = rawBalance / divisor
        let fraction = rawBalance % divisor
        return whole.toDouble() + fraction.toDouble() / divisor.toDouble()
    }

    /// Whether this balance is non-zero.
    var hasBalance: Bool { !rawBalance.isZero }
}

// MARK: - Token Store

/// Persistent store for both default and custom tokens.
/// Loads defaults from the bundled `default_tokens.json` and
/// persists user-added custom tokens in App Group UserDefaults.
@MainActor
final class TokenStore: ObservableObject {
    static let shared = TokenStore()

    /// Default tokens loaded from the bundled JSON.
    @Published private(set) var defaultTokens: [TokenMetadata] = []

    /// User-added custom tokens.
    @Published private(set) var customTokens: [CustomTokenEntry] = []

    /// Token balances keyed by "SYMBOL-chainId".
    @Published private(set) var tokenBalances: [String: TokenBalance] = [:]

    /// Whether a balance fetch is in progress.
    @Published private(set) var isLoadingBalances = false

    /// Symbols of known tokens the user has disabled (won't appear in pickers/balances).
    @Published private(set) var disabledTokenSymbols: Set<String> = []

    private let customTokensKey = "wallet-custom-tokens"
    private let disabledTokensKey = "wallet-disabled-token-symbols"
    private let tokenBalanceCacheKey = "wallet-token-balance-cache"

    private var appGroupDefaults: UserDefaults {
        UserDefaults(suiteName: BitchatApp.groupID) ?? .standard
    }

    /// Tokens fetched from the remote Uniswap token list.
    @Published private(set) var remoteTokens: [TokenMetadata] = []

    /// Whether the remote token list has been loaded.
    @Published private(set) var isRemoteLoaded = false

    /// Combined default + remote tokens (de-duplicated, defaults take priority).
    var mergedDefaultTokens: [TokenMetadata] {
        var result = defaultTokens
        for remote in remoteTokens {
            if !result.contains(where: { $0.symbol.uppercased() == remote.symbol.uppercased() }) {
                result.append(remote)
            }
        }
        return result
    }

    private let remoteTokensCacheKey = "wallet-remote-token-list"
    private let remoteTokensTimestampKey = "wallet-remote-token-list-ts"
    /// Refresh the remote list at most once per 24 hours.
    private let remoteRefreshInterval: TimeInterval = 86400

    init() {
        loadDefaultTokens()
        loadCustomTokens()
        loadDisabledTokens()
        loadCachedRemoteTokens()
    }

    // MARK: - Default Tokens

    private func loadDefaultTokens() {
        guard let url = Bundle.main.url(forResource: "default_tokens", withExtension: "json") else {
            SecureLogger.warning("TokenStore: default_tokens.json not found in bundle", category: .network)
            return
        }
        do {
            let data = try Data(contentsOf: url)
            defaultTokens = try JSONDecoder().decode([TokenMetadata].self, from: data)
            SecureLogger.info("TokenStore: Loaded \(defaultTokens.count) default tokens", category: .network)
        } catch {
            SecureLogger.error("TokenStore: Failed to decode default_tokens.json: \(error)", category: .network)
        }
    }

    // MARK: - Custom Tokens

    private func loadCustomTokens() {
        guard let data = appGroupDefaults.data(forKey: customTokensKey),
              let tokens = try? JSONDecoder().decode([CustomTokenEntry].self, from: data) else {
            return
        }
        customTokens = tokens
        SecureLogger.info("TokenStore: Loaded \(customTokens.count) custom token(s)", category: .network)
    }

    private func saveCustomTokens() {
        if let data = try? JSONEncoder().encode(customTokens) {
            appGroupDefaults.set(data, forKey: customTokensKey)
        }
    }

    // MARK: - Disabled Tokens

    private func loadDisabledTokens() {
        if let array = appGroupDefaults.stringArray(forKey: disabledTokensKey) {
            disabledTokenSymbols = Set(array)
        }
    }

    private func saveDisabledTokens() {
        appGroupDefaults.set(Array(disabledTokenSymbols), forKey: disabledTokensKey)
    }

    /// Whether a known token is enabled (will appear in pickers and balances).
    func isTokenEnabled(_ symbol: String) -> Bool {
        !disabledTokenSymbols.contains(symbol.uppercased())
    }

    /// Enable or disable a known token.
    func setTokenEnabled(_ symbol: String, enabled: Bool) {
        let key = symbol.uppercased()
        if enabled {
            disabledTokenSymbols.remove(key)
        } else {
            disabledTokenSymbols.insert(key)
        }
        saveDisabledTokens()
    }

    /// Add a user-defined custom token.
    func addCustomToken(_ entry: CustomTokenEntry) {
        // Prevent duplicates (same address + chain)
        guard !customTokens.contains(where: {
            $0.contractAddress == entry.contractAddress.lowercased() && $0.chainId == entry.chainId
        }) else { return }
        customTokens.append(entry)
        saveCustomTokens()
    }

    /// Remove a custom token by ID.
    func removeCustomToken(id: String) {
        customTokens.removeAll { $0.id == id }
        saveCustomTokens()
    }

    // MARK: - All Tokens for a Network

    /// Returns all enabled tokens deployed on the given chain ID.
    func tokens(forChainId chainId: Int) -> [TokenMetadata] {
        if let network = EthereumBalanceService.Network.from(chainId: chainId) {
            return tokens(for: network)
        }
        // Fallback for chains not in EthereumBalanceService.Network (e.g. Optimism)
        var results: [TokenMetadata] = []
        for token in mergedDefaultTokens {
            if token.address(onChainId: chainId) != nil,
               isTokenEnabled(token.symbol) {
                results.append(token)
            }
        }
        for custom in customTokens where custom.chainId == chainId {
            let meta = TokenMetadata(
                symbol: custom.symbol,
                name: custom.name,
                decimals: custom.decimals,
                iconName: "circle.fill",
                logoURI: nil,
                deployments: [String(custom.chainId): custom.contractAddress]
            )
            if !results.contains(where: { $0.symbol == meta.symbol }) {
                results.append(meta)
            }
        }
        return results
    }

    /// Returns all tokens (default + custom) that are deployed on the given network.
    func tokens(for network: EthereumBalanceService.Network) -> [TokenMetadata] {
        let chainId = network.chainId
        var results: [TokenMetadata] = []

        // Default + remote tokens deployed on this chain (skip disabled)
        for token in mergedDefaultTokens {
            if token.address(onChainId: chainId) != nil,
               isTokenEnabled(token.symbol) {
                results.append(token)
            }
        }

        // Custom tokens on this chain (convert to TokenMetadata for uniform interface)
        for custom in customTokens where custom.chainId == chainId {
            let meta = TokenMetadata(
                symbol: custom.symbol,
                name: custom.name,
                decimals: custom.decimals,
                iconName: "circle.fill",
                logoURI: nil,
                deployments: [String(custom.chainId): custom.contractAddress]
            )
            // Don't add if there's already a default token with the same symbol on this chain
            if !results.contains(where: { $0.symbol == meta.symbol }) {
                results.append(meta)
            }
        }

        return results
    }

    /// Look up a token by symbol (searches defaults first, then custom).
    func token(symbol: String) -> TokenMetadata? {
        // Check remote tokens too
        let allDefaults = mergedDefaultTokens
        if let found = allDefaults.first(where: { $0.symbol.uppercased() == symbol.uppercased() }) {
            return found
        }
        if let custom = customTokens.first(where: { $0.symbol.uppercased() == symbol.uppercased() }) {
            return TokenMetadata(
                symbol: custom.symbol,
                name: custom.name,
                decimals: custom.decimals,
                iconName: "circle.fill",
                logoURI: nil,
                deployments: [String(custom.chainId): custom.contractAddress]
            )
        }
        return nil
    }

    /// Check if a given address is already known (default or custom) on a chain.
    func isKnownToken(address: String, chainId: Int) -> Bool {
        let lower = address.lowercased()
        let chainStr = String(chainId)

        if mergedDefaultTokens.contains(where: {
            $0.deployments[chainStr]?.lowercased() == lower
        }) {
            return true
        }
        if customTokens.contains(where: {
            $0.contractAddress == lower && $0.chainId == chainId
        }) {
            return true
        }
        return false
    }

    // MARK: - Balance Fetching

    /// Generation counter — bumped on every new fetch cycle so stale
    /// concurrent fetches discard their results instead of overwriting.
    private var tokenFetchGeneration: Int = 0

    /// Fetch ERC-20 balances for all tokens on the given network for the given address.
    func fetchTokenBalances(
        for address: String,
        network: EthereumBalanceService.Network
    ) async {
        let allTokens = tokens(for: network)
        guard !allTokens.isEmpty else { return }

        // Skip if the parent task is already cancelled (e.g. view disappeared)
        guard !Task.isCancelled else { return }

        let myGeneration = tokenFetchGeneration
        isLoadingBalances = true

        await withTaskGroup(of: (String, TokenBalance?).self) { group in
            for token in allTokens {
                guard let contractAddress = token.address(onNetwork: network) else { continue }
                let key = "\(token.symbol)-\(network.chainId)"
                group.addTask {
                    let balance = await self.fetchERC20Balance(
                        tokenAddress: contractAddress,
                        ownerAddress: address,
                        network: network,
                        token: token
                    )
                    return (key, balance)
                }
            }

            for await (key, balance) in group {
                // Discard results if a newer fetch cycle has started
                guard myGeneration == tokenFetchGeneration else {
                    group.cancelAll()
                    break
                }
                if let balance = balance {
                    tokenBalances[key] = balance
                }
            }
        }

        // Only clear loading flag if we're still the active fetch
        if myGeneration == tokenFetchGeneration {
            isLoadingBalances = false
        }
    }

    /// Fetch ERC-20 balances across all active networks.
    func fetchAllTokenBalances(
        for address: String,
        useTestnet: Bool
    ) async {
        let networks = useTestnet
            ? EthereumBalanceService.Network.testnets
            : EthereumBalanceService.Network.mainnets

        // Bump generation so any in-flight concurrent fetch discards its results
        tokenFetchGeneration += 1
        isLoadingBalances = true

        for network in networks {
            await fetchTokenBalances(for: address, network: network)
        }

        isLoadingBalances = false
    }

    /// Clear all cached token balances.
    func clearBalances() {
        tokenBalances.removeAll()
    }

    /// Get the balance for a specific token on a specific network.
    func balance(for token: TokenMetadata, on network: EthereumBalanceService.Network) -> TokenBalance? {
        tokenBalances["\(token.symbol)-\(network.chainId)"]
    }

    // MARK: - ERC-20 RPC Call

    /// Fetch a single ERC-20 token balance via `balanceOf(address)` RPC call.
    private func fetchERC20Balance(
        tokenAddress: String,
        ownerAddress: String,
        network: EthereumBalanceService.Network,
        token: TokenMetadata
    ) async -> TokenBalance? {
        // Encode balanceOf(address) call
        let calldata = ABIEncoder.encodeBalanceOf(owner: ownerAddress)
        let calldataHex = ABIEncoder.dataToHex(calldata)

        let payload: [String: Any] = [
            "jsonrpc": "2.0",
            "method": "eth_call",
            "params": [
                ["to": tokenAddress, "data": calldataHex],
                "latest"
            ],
            "id": 1
        ]

        guard let jsonData = try? JSONSerialization.data(withJSONObject: payload) else {
            return nil
        }

        let torReady = TorManager.shared.isReady
        let session = (!network.isTestnet && torReady) ? TorURLSession.shared.session : URLSession.shared
        let allRPCs = [network.rpcURL] + network.fallbackRPCs

        for rpcURL in allRPCs {
            var request = URLRequest(url: rpcURL)
            request.httpMethod = "POST"
            request.httpBody = jsonData
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.timeoutInterval = 15

            do {
                // Use callback-based URLSession API wrapped in a continuation
                // so that parent Task cancellation (e.g. SwiftUI view lifecycle)
                // does NOT kill the in-flight HTTP request mid-flight.
                // The async `session.data(for:)` API cooperatively cancels,
                // which causes spurious "All RPCs failed" when the WalletView
                // re-renders or the user navigates away briefly.
                let (data, response) = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<(Data, URLResponse), Error>) in
                    let dataTask = session.dataTask(with: request) { data, response, error in
                        if let error = error {
                            continuation.resume(throwing: error)
                        } else if let data = data, let response = response {
                            continuation.resume(returning: (data, response))
                        } else {
                            continuation.resume(throwing: URLError(.unknown))
                        }
                    }
                    dataTask.resume()
                }

                guard let httpResponse = response as? HTTPURLResponse,
                      httpResponse.statusCode == 200 else {
                    let code = (response as? HTTPURLResponse)?.statusCode ?? -1
                    SecureLogger.debug("TokenStore: HTTP \(code) fetching \(token.symbol) on \(network.rawValue) via \(rpcURL.host ?? "?")", category: .network)
                    continue
                }

                guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                    continue
                }

                // Check for RPC error response (e.g. execution reverted for non-existent contracts)
                if let errorObj = json["error"] as? [String: Any] {
                    let msg = errorObj["message"] as? String ?? "unknown"
                    SecureLogger.debug("TokenStore: RPC error for \(token.symbol) on \(network.rawValue): \(msg)", category: .network)
                    return nil // Don't retry other RPCs for contract-level errors
                }

                guard let resultHex = json["result"] as? String else {
                    continue
                }

                // "0x" or empty means zero balance (contract exists but balance is 0)
                let trimmed = resultHex.hasPrefix("0x") ? String(resultHex.dropFirst(2)) : resultHex
                if trimmed.isEmpty || trimmed.allSatisfy({ $0 == "0" }) {
                    return TokenBalance(
                        token: token,
                        network: network,
                        rawBalance: BigUInt(0),
                        lastUpdated: Date()
                    )
                }

                // result is a 32-byte ABI-encoded uint256
                guard let wei = BigUInt(hexString: resultHex) else {
                    continue
                }

                return TokenBalance(
                    token: token,
                    network: network,
                    rawBalance: wei,
                    lastUpdated: Date()
                )
            } catch {
                SecureLogger.debug("TokenStore: Network error fetching \(token.symbol) on \(network.rawValue) via \(rpcURL.host ?? "?"): \(error.localizedDescription)", category: .network)
                continue
            }
        }

        SecureLogger.debug("TokenStore: All RPCs failed for \(token.symbol) on \(network.rawValue)", category: .network)
        return nil
    }

    // MARK: - On-chain Token Discovery

    /// Query the ERC-20 `symbol()` and `decimals()` for an unknown contract address.
    /// Returns nil if the contract is not a valid ERC-20 or the calls fail.
    func discoverTokenMetadata(
        contractAddress: String,
        network: EthereumBalanceService.Network
    ) async -> (symbol: String, decimals: UInt8)? {
        let torReady = TorManager.shared.isReady
        let session = (!network.isTestnet && torReady) ? TorURLSession.shared.session : URLSession.shared
        let rpcURL = network.rpcURL

        // Fetch symbol()
        let symbolSelector = ABIEncoder.functionSelector("symbol()")
        let symbolPayload: [String: Any] = [
            "jsonrpc": "2.0",
            "method": "eth_call",
            "params": [
                ["to": contractAddress, "data": ABIEncoder.dataToHex(symbolSelector)],
                "latest"
            ],
            "id": 1
        ]

        // Fetch decimals()
        let decimalsSelector = ABIEncoder.functionSelector("decimals()")
        let decimalsPayload: [String: Any] = [
            "jsonrpc": "2.0",
            "method": "eth_call",
            "params": [
                ["to": contractAddress, "data": ABIEncoder.dataToHex(decimalsSelector)],
                "latest"
            ],
            "id": 2
        ]

        var symbol: String?
        var decimals: UInt8?

        // Fetch symbol
        if let jsonData = try? JSONSerialization.data(withJSONObject: symbolPayload) {
            var request = URLRequest(url: rpcURL)
            request.httpMethod = "POST"
            request.httpBody = jsonData
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.timeoutInterval = 10

            if let (data, _) = try? await session.data(for: request),
               let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let resultHex = json["result"] as? String {
                symbol = decodeStringFromABI(resultHex)
            }
        }

        // Fetch decimals
        if let jsonData = try? JSONSerialization.data(withJSONObject: decimalsPayload) {
            var request = URLRequest(url: rpcURL)
            request.httpMethod = "POST"
            request.httpBody = jsonData
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.timeoutInterval = 10

            if let (data, _) = try? await session.data(for: request),
               let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let resultHex = json["result"] as? String,
               let decVal = ABIEncoder.decodeUInt256(ABIEncoder.hexToData(resultHex)) {
                decimals = UInt8(min(decVal, 255))
            }
        }

        guard let sym = symbol, let dec = decimals else { return nil }
        return (sym, dec)
    }

    /// Decode a Solidity ABI-encoded string return value.
    private func decodeStringFromABI(_ hex: String) -> String? {
        let data = ABIEncoder.hexToData(hex)
        // Could be ABI-encoded dynamic string or short bytes32 string
        if data.count >= 64 {
            // Dynamic string: offset (32) + length (32) + data
            guard let offset = ABIEncoder.decodeUInt256(Data(data[0..<32])) else { return nil }
            let off = Int(offset)
            guard data.count >= off + 32 else { return nil }
            guard let length = ABIEncoder.decodeUInt256(Data(data[off..<(off + 32)])) else { return nil }
            let len = Int(length)
            guard len > 0, data.count >= off + 32 + len else { return nil }
            return String(data: Data(data[(off + 32)..<(off + 32 + len)]), encoding: .utf8)
        } else if data.count == 32 {
            // bytes32 encoding — trim trailing null bytes
            let trimmed = data.prefix(while: { $0 != 0 })
            return String(data: trimmed, encoding: .utf8)
        }
        return nil
    }

    // MARK: - Remote Token List (Uniswap)

    /// Load cached remote tokens from UserDefaults.
    private func loadCachedRemoteTokens() {
        guard let data = appGroupDefaults.data(forKey: remoteTokensCacheKey),
              let tokens = try? JSONDecoder().decode([TokenMetadata].self, from: data) else {
            return
        }
        remoteTokens = tokens
        isRemoteLoaded = true
        SecureLogger.info("TokenStore: Loaded \(tokens.count) cached remote tokens", category: .network)
    }

    /// Save remote tokens to UserDefaults cache.
    private func saveCachedRemoteTokens(_ tokens: [TokenMetadata]) {
        if let data = try? JSONEncoder().encode(tokens) {
            appGroupDefaults.set(data, forKey: remoteTokensCacheKey)
            appGroupDefaults.set(Date().timeIntervalSince1970, forKey: remoteTokensTimestampKey)
        }
    }

    /// Whether the cached remote list is stale (older than 24h or missing).
    var isRemoteCacheStale: Bool {
        let ts = appGroupDefaults.double(forKey: remoteTokensTimestampKey)
        guard ts > 0 else { return true }
        return Date().timeIntervalSince1970 - ts > remoteRefreshInterval
    }

    /// Fetch the Uniswap default token list from the network if the cache is stale.
    /// Filters to only our supported chains, then merges cross-chain deployments.
    func refreshRemoteTokenListIfNeeded() async {
        guard isRemoteCacheStale else { return }
        await fetchRemoteTokenList()
    }

    /// Force-fetch the remote Uniswap token list regardless of cache age.
    func fetchRemoteTokenList() async {
        do {
            let tokens = try await UniswapTokenListService.fetchAndMap()
            remoteTokens = tokens
            isRemoteLoaded = true
            saveCachedRemoteTokens(tokens)
            SecureLogger.info("TokenStore: Fetched \(tokens.count) remote tokens from Uniswap list", category: .network)
        } catch {
            SecureLogger.warning("TokenStore: Failed to fetch remote token list: \(error)", category: .network)
        }
    }
}

// MARK: - Uniswap Token List Service

/// Fetches the Uniswap default token list (`https://tokens.uniswap.org`),
/// filters for the chains bitchat supports, and maps each token into
/// our `TokenMetadata` format (merging cross-chain bridge info).
enum UniswapTokenListService {

    /// The canonical Uniswap default token list URL.
    static let tokenListURL = URL(string: "https://tokens.uniswap.org")!

    /// Chains that bitchat supports (Ethereum, Arbitrum, Base, Sepolia, Arb Sepolia).
    static let supportedChainIds: Set<Int> = [1, 42161, 8453, 11155111, 421614]

    // MARK: - JSON models (match Token Lists standard)

    struct TokenListResponse: Decodable {
        let name: String?
        let tokens: [TokenListEntry]
    }

    struct TokenListEntry: Decodable {
        let chainId: Int
        let address: String
        let name: String
        let symbol: String
        let decimals: Int
        let logoURI: String?
        let extensions: TokenExtensions?
    }

    struct TokenExtensions: Decodable {
        let bridgeInfo: [String: BridgeEntry]?
    }

    struct BridgeEntry: Decodable {
        let tokenAddress: String?
    }

    // MARK: - Fetch & Map

    /// Fetch the Uniswap token list, filter for supported chains, and merge
    /// cross-chain deployments into `TokenMetadata` objects.
    /// Routes through Tor for IP privacy when available, falls back to direct.
    static func fetchAndMap() async throws -> [TokenMetadata] {
        var request = URLRequest(url: tokenListURL)
        request.timeoutInterval = 20
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        // Try Tor first for IP privacy, fall back to direct if Tor unavailable
        let torReady = await TorManager.shared.isReady
        let sessions: [URLSession] = torReady
            ? [TorURLSession.shared.session, URLSession.shared]
            : [URLSession.shared]

        var lastError: Error = URLError(.badServerResponse)
        var fetchedData: Data?

        for session in sessions {
            do {
                let (data, response) = try await session.data(for: request)
                guard let httpResp = response as? HTTPURLResponse,
                      httpResp.statusCode == 200 else {
                    lastError = URLError(.badServerResponse)
                    continue
                }
                fetchedData = data
                break
            } catch {
                lastError = error
                continue
            }
        }

        guard let data = fetchedData else {
            throw lastError
        }

        let list = try JSONDecoder().decode(TokenListResponse.self, from: data)

        // Step 1: Collect all entries on supported chains, keyed by uppercase symbol.
        // For each symbol we accumulate chain→address and pick the best metadata (logo, name).
        var symbolMap: [String: MergedTokenBuilder] = [:]

        for entry in list.tokens {
            // Direct deployment on a supported chain
            if supportedChainIds.contains(entry.chainId) {
                let key = entry.symbol.uppercased()
                var builder = symbolMap[key] ?? MergedTokenBuilder(
                    symbol: entry.symbol,
                    name: entry.name,
                    decimals: UInt8(entry.decimals),
                    logoURI: entry.logoURI
                )
                builder.deployments[String(entry.chainId)] = entry.address
                // Prefer the mainnet logo
                if entry.chainId == 1, let logo = entry.logoURI {
                    builder.logoURI = logo
                }
                symbolMap[key] = builder
            }

            // Also check bridgeInfo for cross-chain addresses
            if let bridges = entry.extensions?.bridgeInfo {
                for (chainStr, bridge) in bridges {
                    guard let chainId = Int(chainStr),
                          supportedChainIds.contains(chainId),
                          let addr = bridge.tokenAddress, !addr.isEmpty else { continue }
                    let key = entry.symbol.uppercased()
                    var builder = symbolMap[key] ?? MergedTokenBuilder(
                        symbol: entry.symbol,
                        name: entry.name,
                        decimals: UInt8(entry.decimals),
                        logoURI: entry.logoURI
                    )
                    // Only set if not already known (direct entry takes precedence)
                    if builder.deployments[String(chainId)] == nil {
                        builder.deployments[String(chainId)] = addr
                    }
                    symbolMap[key] = builder
                }
            }
        }

        // Step 2: Convert builders to TokenMetadata
        return symbolMap.values.map { builder in
            TokenMetadata(
                symbol: builder.symbol,
                name: builder.name,
                decimals: builder.decimals,
                iconName: Self.sfSymbolFallback(for: builder.symbol),
                logoURI: builder.logoURI,
                deployments: builder.deployments
            )
        }
        .sorted { $0.symbol < $1.symbol }
    }

    /// Intermediate accumulator for merging a token across chains.
    private struct MergedTokenBuilder {
        let symbol: String
        let name: String
        let decimals: UInt8
        var logoURI: String?
        var deployments: [String: String] = [:]
    }

    /// Best-effort SF Symbol fallback based on first letter.
    private static func sfSymbolFallback(for symbol: String) -> String {
        guard let first = symbol.lowercased().first else { return "circle.fill" }
        return "\(first).circle.fill"
    }
}
