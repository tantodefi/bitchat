//
// HeliosManager.swift
// bitchat
//
// Swift wrapper for the Helios Ethereum light client.
// Follows the TorManager pattern: once the Helios xcframework is built,
// FFI calls resolve at link time via @_silgen_name.
//
// Until the xcframework is compiled (Phase 2 of Helios plan), this manager
// reports `isRunning = false` and all queries return errors, causing the
// balance service to fall through to Phase 1 proof-consistent or unverified.
//
// # Tor Integration
//
// Helios auto-starts after Tor becomes ready (.TorDidBecomeReady notification).
// All upstream HTTP requests are routed through Tor's SOCKS5 proxy on port 39050.
// This ensures IP privacy while Helios provides cryptographic data integrity.
//
// This is free and unencumbered software released into the public domain.
// For more information, see <https://unlicense.org>
//

import BitLogger
import Foundation
import Tor

// MARK: - FFI Declarations (resolve when helios.xcframework is linked)
//
// These are defined but only called when HELIOS_FFI_AVAILABLE is set.
// Without the xcframework, the linker never sees these symbols.

#if HELIOS_FFI_AVAILABLE
@_silgen_name("helios_init")
private func _helios_init(
    _ rpcUrl: UnsafePointer<CChar>,
    _ consensusRpc: UnsafePointer<CChar>,
    _ checkpoint: UnsafePointer<CChar>,
    _ network: UnsafePointer<CChar>,
    _ socksProxyPort: UInt16
) -> Int32

@_silgen_name("helios_wait_synced")
private func _helios_wait_synced() -> Int32

@_silgen_name("helios_is_synced")
private func _helios_is_synced() -> Int32

@_silgen_name("helios_sync_progress")
private func _helios_sync_progress() -> Int32

@_silgen_name("helios_get_balance")
private func _helios_get_balance(
    _ address: UnsafePointer<CChar>,
    _ result: UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>
) -> Int32

@_silgen_name("helios_get_logs")
private func _helios_get_logs(
    _ filterJson: UnsafePointer<CChar>,
    _ result: UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>
) -> Int32

@_silgen_name("helios_eth_call")
private func _helios_eth_call(
    _ callJson: UnsafePointer<CChar>,
    _ result: UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>
) -> Int32

@_silgen_name("helios_get_nonce")
private func _helios_get_nonce(
    _ address: UnsafePointer<CChar>,
    _ result: UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>
) -> Int32

@_silgen_name("helios_get_pending_nonce")
private func _helios_get_pending_nonce(
    _ address: UnsafePointer<CChar>,
    _ result: UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>
) -> Int32

@_silgen_name("helios_get_transaction_receipt")
private func _helios_get_transaction_receipt(
    _ txHash: UnsafePointer<CChar>,
    _ result: UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>
) -> Int32

@_silgen_name("helios_get_block_by_number")
private func _helios_get_block_by_number(
    _ blockTag: UnsafePointer<CChar>,
    _ fullTxs: Int32,
    _ result: UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>
) -> Int32

@_silgen_name("helios_estimate_gas")
private func _helios_estimate_gas(
    _ callJson: UnsafePointer<CChar>,
    _ result: UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>
) -> Int32

@_silgen_name("helios_send_raw_transaction")
private func _helios_send_raw_transaction(
    _ rawTx: UnsafePointer<CChar>,
    _ result: UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>
) -> Int32

@_silgen_name("helios_gas_price")
private func _helios_gas_price(
    _ result: UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>
) -> Int32

@_silgen_name("helios_finalized_block")
private func _helios_finalized_block() -> Int64

@_silgen_name("helios_free_string")
private func _helios_free_string(_ ptr: UnsafeMutablePointer<CChar>?)

@_silgen_name("helios_shutdown")
private func _helios_shutdown() -> Int32
#endif

// MARK: - Tor Readiness Notification

extension Notification.Name {
    /// Posted by TorManager when the Tor SOCKS5 proxy is ready for connections.
    /// HeliosManager observes this to auto-start the light client.
    static let TorDidBecomeReady = Notification.Name("TorDidBecomeReady")
}

// MARK: - HeliosManager

/// Manages the Helios Ethereum light client lifecycle.
///
/// Helios converts untrusted RPC endpoints into cryptographically verified
/// responses by syncing with Ethereum's consensus layer. State roots are
/// attested by the sync committee's BLS signatures, meaning a balance
/// from `getBalance()` is trustlessly verified — no single RPC can lie.
///
/// **Tor Integration:** Helios auto-starts when Tor becomes ready. All
/// upstream requests (execution RPC + consensus RPC) are routed through
/// the Arti SOCKS5 proxy at `127.0.0.1:39050` for IP privacy. This is
/// configured via the `ALL_PROXY` env var in the Rust FFI layer.
///
/// **Integration hierarchy in EthereumBalanceService:**
/// 1. Helios (if running) → `.heliosVerified`
/// 2. Phase 1 eth_getProof → `.proofConsistent`
/// 3. Raw eth_getBalance → `.unverified`
@MainActor
public final class HeliosManager: ObservableObject {
    public static let shared = HeliosManager()

    // MARK: - Published State

    @Published public private(set) var isRunning = false
    @Published public private(set) var syncStatus: SyncStatus = .notStarted
    @Published public private(set) var lastError: String?
    @Published public private(set) var activeNetwork: EthereumNetwork = .mainnet

    // MARK: - Types

    /// The Ethereum network Helios should sync to.
    public enum EthereumNetwork: String {
        case mainnet
        case sepolia

        /// Default execution-layer RPC for this network
        public var defaultRpcUrl: String {
            switch self {
            case .mainnet: return "https://rpc.flashbots.net"
            case .sepolia: return "https://ethereum-sepolia-rpc.publicnode.com"
            }
        }

        /// Default consensus-layer (beacon) RPC for this network
        public var defaultConsensusRpc: String {
            switch self {
            case .mainnet: return "https://www.lightclientdata.org"
            case .sepolia: return "https://lodestar-sepolia.chainsafe.io"
            }
        }

        /// Checkpoint sources for fetching a fresh weak subjectivity checkpoint
        public var checkpointSources: [String] {
            switch self {
            case .mainnet:
                return [
                    "https://www.lightclientdata.org/mainnet/head",
                    "https://beaconcha.in/api/v1/epoch/finalized",
                ]
            case .sepolia:
                return [
                    "https://sepolia.beaconstate.info/eth/v1/beacon/headers/finalized",
                    "https://lodestar-sepolia.chainsafe.io/eth/v1/beacon/headers/finalized",
                ]
            }
        }

        /// FFI network string passed to the Rust layer
        public var ffiName: String { rawValue }
    }

    public enum SyncStatus: Equatable {
        case notStarted
        case syncing(progress: Double)
        case synced(blockNumber: UInt64)
        case error(String)
    }

    public enum HeliosError: Error, LocalizedError {
        case notInitialized
        case alreadyRunning
        case ffiNotAvailable
        case initFailed(code: Int32)
        case syncFailed(code: Int32)
        case queryFailed(code: Int32)
        case invalidResponse
        case invalidAddress

        public var errorDescription: String? {
            switch self {
            case .notInitialized: return "Helios is not initialized"
            case .alreadyRunning: return "Helios is already running"
            case .ffiNotAvailable: return "Helios xcframework not yet built"
            case .initFailed(let code): return "Helios init failed (code \(code))"
            case .syncFailed(let code): return "Helios sync failed (code \(code))"
            case .queryFailed(let code): return "Helios query failed (code \(code))"
            case .invalidResponse: return "Invalid response from Helios"
            case .invalidAddress: return "Invalid Ethereum address"
            }
        }
    }

    /// JSON-encoded log filter for stealth address scanning
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

    /// Observer for Tor readiness notification
    private var torReadyObserver: NSObjectProtocol?

    /// Whether auto-start has been attempted this session
    private var autoStartAttempted = false

    /// Sync status polling task
    private var syncPollTask: Task<Void, Never>?

    private init() {
        setupTorAutoStart()
    }

    /// Whether the FFI symbols are available (xcframework linked)
    public var isFFIAvailable: Bool {
        #if HELIOS_FFI_AVAILABLE
        return true
        #else
        return false
        #endif
    }

    // MARK: - Tor Auto-Start

    /// Register for Tor readiness notification to auto-start Helios.
    ///
    /// When Tor becomes ready (SOCKS5 proxy available), Helios will
    /// automatically start with the Tor proxy configured. This ensures
    /// all upstream Helios requests are IP-private from the start.
    private func setupTorAutoStart() {
        #if HELIOS_FFI_AVAILABLE
        torReadyObserver = NotificationCenter.default.addObserver(
            forName: .TorDidBecomeReady,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            Task { @MainActor in
                await self.autoStartIfNeeded()
            }
        }
        #endif
    }

    /// Auto-start Helios after Tor is ready (called at most once per session).
    private func autoStartIfNeeded() async {
        guard !autoStartAttempted else { return }
        autoStartAttempted = true

        guard !isRunning else { return }
        guard isFFIAvailable else { return }

        // Detect testnet/mainnet from the user's wallet preference
        let useTestnet = UserDefaults.standard.object(forKey: "wallet-use-testnet") != nil
            ? UserDefaults.standard.bool(forKey: "wallet-use-testnet")
            : true  // Default to testnet for safety
        let network: EthereumNetwork = useTestnet ? .sepolia : .mainnet

        // Tor triggered this, so we know it's ready — pass the port explicitly
        let torPort: UInt16 = 39050
        SecureLogger.info("HeliosManager: Tor is ready, auto-starting Helios on \(network.rawValue) via Tor (:\(torPort))", category: .network)

        do {
            try await start(network: network, torSocksPort: torPort)
        } catch {
            SecureLogger.error("HeliosManager: Auto-start failed: \(error)", category: .network)
        }
    }

    deinit {
        if let observer = torReadyObserver {
            NotificationCenter.default.removeObserver(observer)
        }
        syncPollTask?.cancel()
    }

    // MARK: - Lifecycle

    /// Start the Helios light client with optional Tor proxy integration.
    ///
    /// 1. Checks if Tor is available; uses direct connection if not
    /// 2. Initializes the Rust FFI layer (creates EthereumClient)
    /// 3. Begins consensus sync in the background
    /// 4. Blocks until first sync completes (~2s on WiFi, ~10s via Tor)
    /// 5. Once synced, `getBalance()` and `getLogs()` return verified data
    ///
    /// If Tor is ready, upstream requests are routed through SOCKS5 for IP
    /// privacy. If Tor is not available, Helios connects directly — still
    /// providing cryptographic verification, just without IP privacy.
    public func start(
        network: EthereumNetwork = .mainnet,
        rpcUrl: String? = nil,
        consensusRpc: String? = nil,
        checkpoint: String? = nil,
        torSocksPort: UInt16? = nil
    ) async throws {
        #if HELIOS_FFI_AVAILABLE
        guard !isRunning else { throw HeliosError.alreadyRunning }

        let effectiveRpc = rpcUrl ?? network.defaultRpcUrl
        let effectiveConsensus = consensusRpc ?? network.defaultConsensusRpc

        // Resolve Tor port: use explicit value, or auto-detect from TorManager
        let resolvedTorPort: UInt16
        if let torSocksPort {
            resolvedTorPort = torSocksPort
        } else if TorManager.shared.isReady {
            resolvedTorPort = 39050 // Standard Arti SOCKS5 port
        } else {
            resolvedTorPort = 0 // Direct connection (no Tor)
        }

        syncStatus = .syncing(progress: 0)
        lastError = nil
        activeNetwork = network

        let checkpointStr: String
        if let checkpoint {
            checkpointStr = checkpoint
        } else {
            checkpointStr = await Self.fetchLatestCheckpoint(network: network)
        }

        let torLabel = resolvedTorPort > 0 ? "via Tor (:\(resolvedTorPort))" : "direct (no Tor)"
        SecureLogger.info(
            "HeliosManager: Starting \(network.rawValue) \(torLabel) with RPC=\(effectiveRpc), consensus=\(effectiveConsensus)",
            category: .network
        )

        // Step 1: Initialize the Helios client (non-blocking, starts sync loop)
        let initResult: Int32 = try await withCheckedThrowingContinuation { continuation in
            heliosQueue.async {
                let code = effectiveRpc.withCString { rpc in
                    effectiveConsensus.withCString { consensus in
                        checkpointStr.withCString { cp in
                            network.ffiName.withCString { net in
                                _helios_init(rpc, consensus, cp, net, resolvedTorPort)
                            }
                        }
                    }
                }
                continuation.resume(returning: code)
            }
        }

        guard initResult == 0 else {
            let err = HeliosError.initFailed(code: initResult)
            syncStatus = .error(err.localizedDescription ?? "Init failed")
            lastError = err.localizedDescription
            throw err
        }

        isRunning = true
        syncStatus = .syncing(progress: 0.1)
        SecureLogger.info("HeliosManager: Client initialized, waiting for sync...", category: .network)

        // Step 2: Wait for consensus sync to complete (blocks on background queue)
        let syncResult: Int32 = try await withCheckedThrowingContinuation { continuation in
            heliosQueue.async {
                let code = _helios_wait_synced()
                continuation.resume(returning: code)
            }
        }

        guard syncResult == 0 else {
            // Sync failed — shut down the FFI layer so it can be re-initialized
            heliosQueue.sync { _ = _helios_shutdown() }
            isRunning = false

            let torDetail = resolvedTorPort > 0
                ? " (Tor port \(resolvedTorPort) — is Tor actually running?)"
                : " (direct connection)"
            let err = HeliosError.syncFailed(code: syncResult)
            syncStatus = .error((err.localizedDescription ?? "Sync failed") + torDetail)
            lastError = (err.localizedDescription ?? "Sync failed") + torDetail
            SecureLogger.error(
                "HeliosManager: Sync failed (code \(syncResult))\(torDetail). FFI state cleared for retry.",
                category: .network
            )
            throw err
        }

        syncStatus = .synced(blockNumber: 0)
        SecureLogger.info("HeliosManager: Synced successfully, verified queries available", category: .network)

        // Step 3: Start polling for block number updates
        startSyncPolling()
        #else
        throw HeliosError.ffiNotAvailable
        #endif
    }

    /// Stop the Helios client and clear FFI state (allows re-initialization).
    public func stop() {
        syncPollTask?.cancel()
        syncPollTask = nil

        #if HELIOS_FFI_AVAILABLE
        if isRunning {
            heliosQueue.sync { _ = _helios_shutdown() }
        }
        #endif

        isRunning = false
        syncStatus = .notStarted
        lastError = nil
        autoStartAttempted = false  // Allow auto-start on next Tor ready
        SecureLogger.info("HeliosManager: Stopped, FFI state cleared", category: .network)
    }

    // MARK: - Verified Queries

    /// Get the cryptographically verified balance for an address.
    ///
    /// The balance is verified against the consensus-attested state root
    /// (sync committee BLS signatures), NOT against a state root from
    /// the same untrusted RPC. This is true trustless verification.
    ///
    /// - Parameter address: Hex Ethereum address (0x-prefixed)
    /// - Returns: Balance in wei as a hex string (0x-prefixed)
    public func getBalance(address: String) async throws -> String {
        #if HELIOS_FFI_AVAILABLE
        guard isRunning else { throw HeliosError.notInitialized }
        guard isValidAddress(address) else { throw HeliosError.invalidAddress }

        return try await withCheckedThrowingContinuation { continuation in
            heliosQueue.async {
                var resultPtr: UnsafeMutablePointer<CChar>?
                let code = address.withCString { addr in
                    _helios_get_balance(addr, &resultPtr)
                }

                guard code == 0, let ptr = resultPtr else {
                    continuation.resume(throwing: HeliosError.queryFailed(code: code))
                    return
                }

                let hexString = String(cString: ptr)
                _helios_free_string(ptr)
                continuation.resume(returning: hexString)
            }
        }
        #else
        throw HeliosError.ffiNotAvailable
        #endif
    }

    /// Get verified event logs for stealth address scanning.
    ///
    /// Logs are verified against consensus-attested block roots,
    /// ensuring EIP-5564 announcements cannot be omitted by a malicious RPC.
    public func getLogs(filter: LogFilter) async throws -> [VerifiedLog] {
        #if HELIOS_FFI_AVAILABLE
        guard isRunning else { throw HeliosError.notInitialized }

        let filterData = try JSONEncoder().encode(filter)
        guard let filterString = String(data: filterData, encoding: .utf8) else {
            throw HeliosError.invalidResponse
        }

        let jsonResult: String = try await withCheckedThrowingContinuation { continuation in
            heliosQueue.async {
                var resultPtr: UnsafeMutablePointer<CChar>?
                let code = filterString.withCString { f in
                    _helios_get_logs(f, &resultPtr)
                }

                guard code == 0, let ptr = resultPtr else {
                    continuation.resume(throwing: HeliosError.queryFailed(code: code))
                    return
                }

                let result = String(cString: ptr)
                _helios_free_string(ptr)
                continuation.resume(returning: result)
            }
        }

        guard let data = jsonResult.data(using: .utf8) else {
            throw HeliosError.invalidResponse
        }

        return try JSONDecoder().decode([VerifiedLog].self, from: data)
        #else
        throw HeliosError.ffiNotAvailable
        #endif
    }

    /// Execute a verified eth_call (ENS resolution, contract reads, etc.)
    public func ethCall(_ callJSON: String) async throws -> String {
        #if HELIOS_FFI_AVAILABLE
        guard isRunning else { throw HeliosError.notInitialized }

        return try await withCheckedThrowingContinuation { continuation in
            heliosQueue.async {
                var resultPtr: UnsafeMutablePointer<CChar>?
                let code = callJSON.withCString { call in
                    _helios_eth_call(call, &resultPtr)
                }

                guard code == 0, let ptr = resultPtr else {
                    continuation.resume(throwing: HeliosError.queryFailed(code: code))
                    return
                }

                let result = String(cString: ptr)
                _helios_free_string(ptr)
                continuation.resume(returning: result)
            }
        }
        #else
        throw HeliosError.ffiNotAvailable
        #endif
    }

    /// Get the verified nonce (transaction count) for an address.
    public func getNonce(address: String, pending: Bool = false) async throws -> UInt64 {
        #if HELIOS_FFI_AVAILABLE
        guard isRunning else { throw HeliosError.notInitialized }
        guard isValidAddress(address) else { throw HeliosError.invalidAddress }

        let hexResult: String = try await withCheckedThrowingContinuation { continuation in
            heliosQueue.async {
                var resultPtr: UnsafeMutablePointer<CChar>?
                let code = address.withCString { addr in
                    pending ? _helios_get_pending_nonce(addr, &resultPtr)
                            : _helios_get_nonce(addr, &resultPtr)
                }

                guard code == 0, let ptr = resultPtr else {
                    continuation.resume(throwing: HeliosError.queryFailed(code: code))
                    return
                }

                let result = String(cString: ptr)
                _helios_free_string(ptr)
                continuation.resume(returning: result)
            }
        }

        let hex = hexResult.hasPrefix("0x") ? String(hexResult.dropFirst(2)) : hexResult
        return UInt64(hex, radix: 16) ?? 0
        #else
        throw HeliosError.ffiNotAvailable
        #endif
    }

    /// Get verified transaction receipt by hash.
    /// Returns raw JSON string (caller decodes as needed).
    public func getTransactionReceipt(txHash: String) async throws -> String {
        #if HELIOS_FFI_AVAILABLE
        guard isRunning else { throw HeliosError.notInitialized }

        return try await withCheckedThrowingContinuation { continuation in
            heliosQueue.async {
                var resultPtr: UnsafeMutablePointer<CChar>?
                let code = txHash.withCString { hash in
                    _helios_get_transaction_receipt(hash, &resultPtr)
                }

                guard code == 0, let ptr = resultPtr else {
                    continuation.resume(throwing: HeliosError.queryFailed(code: code))
                    return
                }

                let result = String(cString: ptr)
                _helios_free_string(ptr)
                continuation.resume(returning: result)
            }
        }
        #else
        throw HeliosError.ffiNotAvailable
        #endif
    }

    /// Get a verified block by number. Returns raw JSON.
    /// - Parameters:
    ///   - blockTag: "latest", "finalized", or hex block number
    ///   - fullTransactions: Whether to include full tx objects or just hashes
    public func getBlockByNumber(blockTag: String, fullTransactions: Bool = false) async throws -> String {
        #if HELIOS_FFI_AVAILABLE
        guard isRunning else { throw HeliosError.notInitialized }

        return try await withCheckedThrowingContinuation { continuation in
            heliosQueue.async {
                var resultPtr: UnsafeMutablePointer<CChar>?
                let code = blockTag.withCString { tag in
                    _helios_get_block_by_number(tag, fullTransactions ? 1 : 0, &resultPtr)
                }

                guard code == 0, let ptr = resultPtr else {
                    continuation.resume(throwing: HeliosError.queryFailed(code: code))
                    return
                }

                let result = String(cString: ptr)
                _helios_free_string(ptr)
                continuation.resume(returning: result)
            }
        }
        #else
        throw HeliosError.ffiNotAvailable
        #endif
    }

    /// Estimate gas for a transaction via Helios (verified).
    public func estimateGas(callJSON: String) async throws -> UInt64 {
        #if HELIOS_FFI_AVAILABLE
        guard isRunning else { throw HeliosError.notInitialized }

        let hexResult: String = try await withCheckedThrowingContinuation { continuation in
            heliosQueue.async {
                var resultPtr: UnsafeMutablePointer<CChar>?
                let code = callJSON.withCString { call in
                    _helios_estimate_gas(call, &resultPtr)
                }

                guard code == 0, let ptr = resultPtr else {
                    continuation.resume(throwing: HeliosError.queryFailed(code: code))
                    return
                }

                let result = String(cString: ptr)
                _helios_free_string(ptr)
                continuation.resume(returning: result)
            }
        }

        let hex = hexResult.hasPrefix("0x") ? String(hexResult.dropFirst(2)) : hexResult
        return UInt64(hex, radix: 16) ?? 21000
        #else
        throw HeliosError.ffiNotAvailable
        #endif
    }

    /// Send a raw signed transaction through Helios (routed via Tor).
    public func sendRawTransaction(rawTxHex: String) async throws -> String {
        #if HELIOS_FFI_AVAILABLE
        guard isRunning else { throw HeliosError.notInitialized }

        return try await withCheckedThrowingContinuation { continuation in
            heliosQueue.async {
                var resultPtr: UnsafeMutablePointer<CChar>?
                let code = rawTxHex.withCString { tx in
                    _helios_send_raw_transaction(tx, &resultPtr)
                }

                guard code == 0, let ptr = resultPtr else {
                    continuation.resume(throwing: HeliosError.queryFailed(code: code))
                    return
                }

                let result = String(cString: ptr)
                _helios_free_string(ptr)
                continuation.resume(returning: result)
            }
        }
        #else
        throw HeliosError.ffiNotAvailable
        #endif
    }

    /// Get the current gas price via Helios (verified).
    public func getGasPrice() async throws -> UInt64 {
        #if HELIOS_FFI_AVAILABLE
        guard isRunning else { throw HeliosError.notInitialized }

        let hexResult: String = try await withCheckedThrowingContinuation { continuation in
            heliosQueue.async {
                var resultPtr: UnsafeMutablePointer<CChar>?
                let code = _helios_gas_price(&resultPtr)

                guard code == 0, let ptr = resultPtr else {
                    continuation.resume(throwing: HeliosError.queryFailed(code: code))
                    return
                }

                let result = String(cString: ptr)
                _helios_free_string(ptr)
                continuation.resume(returning: result)
            }
        }

        let hex = hexResult.hasPrefix("0x") ? String(hexResult.dropFirst(2)) : hexResult
        return UInt64(hex, radix: 16) ?? 1_000_000_000
        #else
        throw HeliosError.ffiNotAvailable
        #endif
    }

    /// Last block number known to Helios.
    public var finalizedBlock: UInt64? {
        #if HELIOS_FFI_AVAILABLE
        guard isRunning else { return nil }
        let block = _helios_finalized_block()
        return block >= 0 ? UInt64(block) : nil
        #else
        return nil
        #endif
    }

    /// Current sync progress (0-100, or -1 for error)
    public var currentSyncProgress: Int {
        #if HELIOS_FFI_AVAILABLE
        return Int(_helios_sync_progress())
        #else
        return 0
        #endif
    }

    // MARK: - Private

    private func isValidAddress(_ address: String) -> Bool {
        let stripped = address.hasPrefix("0x") ? String(address.dropFirst(2)) : address
        return stripped.count == 40 && stripped.allSatisfy(\.isHexDigit)
    }

    /// Periodically poll finalized block number to update UI
    private func startSyncPolling() {
        syncPollTask?.cancel()
        syncPollTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(12)) // ~1 Ethereum slot
                guard let self, self.isRunning, !Task.isCancelled else { break }

                #if HELIOS_FFI_AVAILABLE
                let block = _helios_finalized_block()
                if block > 0 {
                    await MainActor.run {
                        self.syncStatus = .synced(blockNumber: UInt64(block))
                    }
                }
                #endif
            }
        }
    }

    // MARK: - Checkpoint Management

    /// Bundled checkpoint — updated with each app release.
    /// This provides a trust anchor for initial sync. If stale (>2 weeks),
    /// Helios falls back to external checkpoint sources.
    static let bundledCheckpoint = "0x0000000000000000000000000000000000000000000000000000000000000000"

    /// Fetch a fresh checkpoint from multiple trusted sources.
    ///
    /// Sources are queried in order; the first valid response wins.
    /// Falls back to the bundled checkpoint if all sources fail.
    public static func fetchLatestCheckpoint(network: EthereumNetwork = .mainnet) async -> String {
        let sources = network.checkpointSources

        for source in sources {
            guard let url = URL(string: source) else { continue }
            do {
                let (data, response) = try await URLSession.shared.data(from: url)
                guard let httpResponse = response as? HTTPURLResponse,
                      httpResponse.statusCode == 200 else { continue }

                // Try standard beacon API response format: {"data":{"root":"0x..."}}
                if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                    // Format 1: lightclientdata.org style {"data": "0x..."}
                    if let checkpoint = json["data"] as? String, checkpoint.hasPrefix("0x") {
                        SecureLogger.info("HeliosManager: Got \(network.rawValue) checkpoint from \(source)", category: .network)
                        return checkpoint
                    }
                    // Format 2: Beacon API style {"data":{"root":"0x..."}}
                    if let dataObj = json["data"] as? [String: Any],
                       let root = dataObj["root"] as? String,
                       root.hasPrefix("0x") {
                        SecureLogger.info("HeliosManager: Got \(network.rawValue) checkpoint from \(source)", category: .network)
                        return root
                    }
                }
            } catch {
                continue
            }
        }

        SecureLogger.info("HeliosManager: Using bundled checkpoint for \(network.rawValue) (external sources failed)", category: .network)
        return bundledCheckpoint
    }
}
