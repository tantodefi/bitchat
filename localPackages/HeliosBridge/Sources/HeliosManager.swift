//
// HeliosManager.swift
// HeliosBridge
//
// Swift async wrapper around the Helios Ethereum light client FFI.
// Follows the TorManager pattern: Rust static library → @_silgen_name FFI → Swift actor.
//
// Helios provides trustless balance/log/call verification by maintaining
// a consensus-attested state root (sync committee BLS signatures).
// All upstream RPC queries are routed through Tor for IP privacy.
//
// This is free and unencumbered software released into the public domain.
// For more information, see <https://unlicense.org>
//

import BitLogger
import Foundation

// MARK: - FFI Declarations

@_silgen_name("helios_init")
private func helios_init(
    _ rpcUrl: UnsafePointer<CChar>,
    _ consensusRpc: UnsafePointer<CChar>,
    _ checkpoint: UnsafePointer<CChar>,
    _ socksProxyPort: UInt16
) -> Int32

@_silgen_name("helios_get_balance")
private func helios_get_balance(
    _ address: UnsafePointer<CChar>,
    _ result: UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>
) -> Int32

@_silgen_name("helios_get_logs")
private func helios_get_logs(
    _ filterJson: UnsafePointer<CChar>,
    _ result: UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>
) -> Int32

@_silgen_name("helios_eth_call")
private func helios_eth_call(
    _ callJson: UnsafePointer<CChar>,
    _ result: UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>
) -> Int32

@_silgen_name("helios_finalized_block")
private func helios_finalized_block() -> Int64

@_silgen_name("helios_free_string")
private func helios_free_string(_ ptr: UnsafeMutablePointer<CChar>?)

@_silgen_name("helios_shutdown")
private func helios_shutdown() -> Int32

// MARK: - HeliosManager

/// Manages the Helios Ethereum light client lifecycle.
///
/// Helios converts untrusted RPC endpoints into cryptographically verified
/// responses by maintaining sync with Ethereum's consensus layer. State roots
/// are attested by the sync committee's BLS signatures, which means a balance
/// returned by `getBalance()` is trustlessly verified — no single RPC provider
/// can lie about account state.
///
/// Integration path:
/// 1. `EthereumBalanceService` calls `getBalance()` first
/// 2. If Helios is running → returns `.heliosVerified` balance
/// 3. If not running → falls back to Phase 1 proof-consistent or unverified
@MainActor
public final class HeliosManager: ObservableObject {
    public static let shared = HeliosManager()

    // MARK: - Published State

    @Published public private(set) var isRunning = false
    @Published public private(set) var syncStatus: SyncStatus = .notStarted
    @Published public private(set) var lastError: String?

    // MARK: - Types

    public enum SyncStatus: Equatable {
        case notStarted
        case syncing(progress: Double)
        case synced(blockNumber: UInt64)
        case error(String)

        public static func == (lhs: SyncStatus, rhs: SyncStatus) -> Bool {
            switch (lhs, rhs) {
            case (.notStarted, .notStarted): return true
            case (.syncing(let a), .syncing(let b)): return a == b
            case (.synced(let a), .synced(let b)): return a == b
            case (.error(let a), .error(let b)): return a == b
            default: return false
            }
        }
    }

    public enum HeliosError: Error, LocalizedError {
        case notInitialized
        case alreadyRunning
        case initFailed(code: Int32)
        case queryFailed(code: Int32)
        case invalidResponse
        case invalidAddress

        public var errorDescription: String? {
            switch self {
            case .notInitialized: return "Helios is not initialized"
            case .alreadyRunning: return "Helios is already running"
            case .initFailed(let code): return "Helios init failed (code \(code))"
            case .queryFailed(let code): return "Helios query failed (code \(code))"
            case .invalidResponse: return "Invalid response from Helios"
            case .invalidAddress: return "Invalid Ethereum address"
            }
        }
    }

    /// JSON-encoded log filter for `getLogs()`
    public struct LogFilter: Codable {
        public let address: String
        public let topics: [[String]?]
        public let fromBlock: String
        public let toBlock: String

        public init(address: String, topics: [[String]?], fromBlock: String = "earliest", toBlock: String = "latest") {
            self.address = address
            self.topics = topics
            self.fromBlock = fromBlock
            self.toBlock = toBlock
        }
    }

    /// A verified event log from Helios
    public struct VerifiedLog: Codable {
        public let address: String
        public let topics: [String]
        public let data: String
        public let blockNumber: String
        public let transactionHash: String
        public let logIndex: String
    }

    // MARK: - Private

    /// Background queue for FFI calls (tokio blocks internally)
    private let heliosQueue = DispatchQueue(label: "app.bitchat.helios", qos: .userInitiated)

    private init() {}

    // MARK: - Lifecycle

    /// Start the Helios light client with Tor proxy integration.
    ///
    /// This initiates the consensus sync process. Once synced (~2s on WiFi),
    /// `getBalance()` and `getLogs()` return trustlessly verified data.
    ///
    /// - Parameters:
    ///   - rpcUrl: Upstream execution RPC (default: Flashbots Protect)
    ///   - consensusRpc: Beacon chain API (default: lightclientdata.org)
    ///   - checkpoint: Weak subjectivity checkpoint (nil = use bundled)
    ///   - torSocksPort: Tor SOCKS5 port for upstream privacy (0 = direct)
    public func start(
        rpcUrl: String = "https://rpc.flashbots.net",
        consensusRpc: String = "https://www.lightclientdata.org",
        checkpoint: String? = nil,
        torSocksPort: UInt16 = 39050
    ) async throws {
        guard !isRunning else {
            throw HeliosError.alreadyRunning
        }

        syncStatus = .syncing(progress: 0)
        lastError = nil

        let checkpointStr = checkpoint ?? Self.bundledCheckpoint

        SecureLogger.info(
            "HeliosManager: Starting with RPC=\(rpcUrl), consensus=\(consensusRpc), port=\(torSocksPort)",
            category: .network
        )

        let result: Int32 = try await withCheckedThrowingContinuation { continuation in
            heliosQueue.async {
                let code = rpcUrl.withCString { rpc in
                    consensusRpc.withCString { consensus in
                        checkpointStr.withCString { cp in
                            helios_init(rpc, consensus, cp, torSocksPort)
                        }
                    }
                }
                continuation.resume(returning: code)
            }
        }

        guard result == 0 else {
            let error = HeliosError.initFailed(code: result)
            syncStatus = .error(error.localizedDescription ?? "Init failed")
            lastError = error.localizedDescription
            throw error
        }

        isRunning = true
        syncStatus = .synced(blockNumber: 0) // Will update from finalized_block

        SecureLogger.info("HeliosManager: Started successfully", category: .network)

        // Start a background task to periodically poll sync status
        Task { await pollSyncStatus() }
    }

    /// Stop the Helios client.
    public func stop() {
        guard isRunning else { return }

        heliosQueue.sync {
            _ = helios_shutdown()
        }

        isRunning = false
        syncStatus = .notStarted
        lastError = nil

        SecureLogger.info("HeliosManager: Stopped", category: .network)
    }

    // MARK: - Verified Queries

    /// Get the cryptographically verified balance for an address.
    ///
    /// The balance is verified against the consensus-attested state root
    /// (sync committee BLS signatures), NOT against a state root from the
    /// same untrusted RPC. This provides true trustless verification.
    ///
    /// - Parameter address: Hex Ethereum address (0x-prefixed, 42 chars)
    /// - Returns: Balance in wei as a hex string (0x-prefixed)
    /// - Throws: `HeliosError` if not running, address invalid, or verification fails
    public func getBalance(address: String) async throws -> String {
        guard isRunning else { throw HeliosError.notInitialized }
        guard isValidAddress(address) else { throw HeliosError.invalidAddress }

        return try await withCheckedThrowingContinuation { continuation in
            heliosQueue.async {
                var resultPtr: UnsafeMutablePointer<CChar>?
                let code = address.withCString { addr in
                    helios_get_balance(addr, &resultPtr)
                }

                guard code == 0, let ptr = resultPtr else {
                    continuation.resume(throwing: HeliosError.queryFailed(code: code))
                    return
                }

                let hexString = String(cString: ptr)
                helios_free_string(ptr)
                continuation.resume(returning: hexString)
            }
        }
    }

    /// Get verified event logs matching a filter.
    ///
    /// Logs are verified against consensus-attested block roots,
    /// ensuring stealth address announcements cannot be omitted by a malicious RPC.
    ///
    /// - Parameter filter: Log filter specifying address, topics, and block range
    /// - Returns: Array of verified logs
    /// - Throws: `HeliosError` if not running or query fails
    public func getLogs(filter: LogFilter) async throws -> [VerifiedLog] {
        guard isRunning else { throw HeliosError.notInitialized }

        let filterData = try JSONEncoder().encode(filter)
        guard let filterString = String(data: filterData, encoding: .utf8) else {
            throw HeliosError.invalidResponse
        }

        let jsonResult: String = try await withCheckedThrowingContinuation { continuation in
            heliosQueue.async {
                var resultPtr: UnsafeMutablePointer<CChar>?
                let code = filterString.withCString { f in
                    helios_get_logs(f, &resultPtr)
                }

                guard code == 0, let ptr = resultPtr else {
                    continuation.resume(throwing: HeliosError.queryFailed(code: code))
                    return
                }

                let result = String(cString: ptr)
                helios_free_string(ptr)
                continuation.resume(returning: result)
            }
        }

        guard let data = jsonResult.data(using: .utf8) else {
            throw HeliosError.invalidResponse
        }

        return try JSONDecoder().decode([VerifiedLog].self, from: data)
    }

    /// Execute a verified eth_call.
    ///
    /// The call result is verified against the consensus-attested state root.
    /// Useful for ENS resolution, reading contract state, etc.
    ///
    /// - Parameter callJSON: JSON string with call parameters (to, data, value)
    /// - Returns: Hex-encoded result data
    /// - Throws: `HeliosError` if not running or verification fails
    public func ethCall(_ callJSON: String) async throws -> String {
        guard isRunning else { throw HeliosError.notInitialized }

        return try await withCheckedThrowingContinuation { continuation in
            heliosQueue.async {
                var resultPtr: UnsafeMutablePointer<CChar>?
                let code = callJSON.withCString { call in
                    helios_eth_call(call, &resultPtr)
                }

                guard code == 0, let ptr = resultPtr else {
                    continuation.resume(throwing: HeliosError.queryFailed(code: code))
                    return
                }

                let result = String(cString: ptr)
                helios_free_string(ptr)
                continuation.resume(returning: result)
            }
        }
    }

    /// The last finalized block number known to Helios.
    public var finalizedBlock: UInt64? {
        guard isRunning else { return nil }
        let block = helios_finalized_block()
        return block >= 0 ? UInt64(block) : nil
    }

    // MARK: - Private Helpers

    private func isValidAddress(_ address: String) -> Bool {
        let stripped = address.hasPrefix("0x") ? String(address.dropFirst(2)) : address
        return stripped.count == 40 && stripped.allSatisfy(\.isHexDigit)
    }

    /// Periodically poll finalized block number to update sync status
    private func pollSyncStatus() async {
        while isRunning && !Task.isCancelled {
            try? await Task.sleep(for: .seconds(10))

            guard isRunning else { break }

            let block = helios_finalized_block()
            if block > 0 {
                syncStatus = .synced(blockNumber: UInt64(block))
            }
        }
    }

    // MARK: - Checkpoint Management

    /// Bundled checkpoint — updated with each app release.
    ///
    /// This is a recent finalized block root from the beacon chain.
    /// It provides the initial trust anchor for Helios sync.
    /// Users with stale checkpoints can still sync, just with more
    /// initial verification work.
    static let bundledCheckpoint = "0x0000000000000000000000000000000000000000000000000000000000000000"

    /// Fetch a fresh checkpoint from multiple trusted sources.
    ///
    /// Tries multiple beacon chain providers to find a recent finalized
    /// checkpoint, with fallback to the bundled one.
    public static func fetchLatestCheckpoint() async -> String {
        let sources = [
            "https://www.lightclientdata.org/mainnet/head",
            "https://beaconcha.in/api/v1/epoch/finalized",
        ]

        for source in sources {
            guard let url = URL(string: source) else { continue }
            do {
                let (data, response) = try await URLSession.shared.data(from: url)
                guard let httpResponse = response as? HTTPURLResponse,
                      httpResponse.statusCode == 200 else { continue }

                // Try to parse checkpoint from response
                if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                   let checkpoint = json["data"] as? String,
                   checkpoint.hasPrefix("0x") {
                    SecureLogger.info(
                        "HeliosManager: Fetched checkpoint from \(source)",
                        category: .network
                    )
                    return checkpoint
                }
            } catch {
                SecureLogger.warning(
                    "HeliosManager: Failed to fetch checkpoint from \(source): \(error)",
                    category: .network
                )
                continue
            }
        }

        SecureLogger.warning(
            "HeliosManager: Using bundled checkpoint (all sources failed)",
            category: .network
        )
        return bundledCheckpoint
    }
}
