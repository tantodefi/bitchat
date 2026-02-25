//
// MeshTransactionRelay.swift
// bitchat
//
// Handles offline transaction relay through BLE mesh network.
// Signs transactions locally and relays through peers with internet.
//
// This is free and unencumbered software released into the public domain.
// For more information, see <https://unlicense.org>
//

import BitLogger
import Combine
import Foundation
import Network
import Tor

/// Service for relaying signed transactions through BLE mesh
@MainActor
final class MeshTransactionRelay: ObservableObject {
    
    // MARK: - Properties
    
    /// Pending transactions awaiting confirmation
    @Published private(set) var pendingRelays: [PendingRelay] = []
    
    /// Recently confirmed transactions
    @Published private(set) var confirmedTransactions: [ConfirmedTransaction] = []
    
    /// Failed transactions with reasons (rejected by network, not network errors)
    @Published private(set) var failedTransactions: [FailedTransaction] = []
    
    /// Number of connected BLE peers (updated on retries and peer events)
    @Published private(set) var connectedPeerCount: Int = 0
    
    /// Last relay error for debugging (shown in settings UI)
    @Published private(set) var lastRelayError: String?
    
    /// Timestamp of last relay error
    @Published private(set) var lastRelayErrorAt: Date?
    
    /// Relay strategy setting
    @Published var allowMeshRelay: Bool {
        didSet {
            UserDefaults.standard.set(allowMeshRelay, forKey: "mesh-tx-relay-enabled")
        }
    }
    
    private let keychain: KeychainManagerProtocol
    private weak var bleService: BLEService?
    private let storageKey = "mesh-tx-pending-relays"
    private let confirmedStorageKey = "mesh-tx-confirmed-history"
    private let failedStorageKey = "mesh-tx-failed-history"
    private var retryTask: Task<Void, Never>?
    private var retryScheduled = false
    
    /// Network path monitor for detecting connectivity changes
    private let pathMonitor = NWPathMonitor()
    private let monitorQueue = DispatchQueue(label: "mesh-tx-network-monitor")
    
    /// Fast network status from NWPathMonitor (updated instantly, no HTTP overhead)
    private var networkPathSatisfied: Bool = false
    
    /// App Group UserDefaults for persistence across reinstalls
    private var appGroupDefaults: UserDefaults {
        UserDefaults(suiteName: BitchatApp.groupID) ?? .standard
    }
    
    // Retry configuration
    private let retryInterval: TimeInterval = 30 // Retry every 30 seconds
    private let maxRetryAge: TimeInterval = 24 * 60 * 60 // Give up after 24 hours
    
    // RPC endpoints for broadcasting (prefer MEV-protected)
    // Primary endpoints - use reliable RPCs
    private let rpcEndpoints: [UInt64: String] = [
        1: "https://rpc.flashbots.net",                      // Ethereum mainnet (Flashbots Protect)
        11155111: "https://sepolia.drpc.org",                 // Sepolia testnet (dRPC - reliable)
        421614: "https://sepolia-rollup.arbitrum.io/rpc",     // Arbitrum Sepolia testnet
        8453: "https://mainnet.base.org"                     // Base mainnet
    ]
    
    // Fallback RPC endpoints for reliability
    private let fallbackRPCs: [UInt64: [String]] = [
        1: ["https://eth.llamarpc.com", "https://rpc.ankr.com/eth"],
        11155111: ["https://rpc2.sepolia.org", "https://1rpc.io/sepolia"],
        421614: ["https://arbitrum-sepolia-rpc.publicnode.com"],
        8453: ["https://base.llamarpc.com", "https://rpc.ankr.com/base"]
    ]
    
    // MARK: - Types
    
    struct PendingRelay: Codable, Identifiable {
        let id: String
        let payload: TxSignedPayload
        let createdAt: Date
        var relayedVia: String?
        var status: RelayStatus
        var retryCount: Int = 0
        /// Timestamp of last status change (used for awaitingConfirmation timeout)
        var statusChangedAt: Date = Date()
        /// Serialized TxUserOpPayload for PQ UserOp relays (nil for standard EOA txs)
        var userOpPayloadData: Data? = nil
    }
    
    enum RelayStatus: String, Codable {
        case queued
        case relaying
        case awaitingConfirmation
        case confirmed
        case failed
    }
    
    struct ConfirmedTransaction: Codable, Identifiable {
        let id: String
        let txHash: String
        let chainId: UInt64
        let toAddress: String
        let fromAddress: String?
        let amount: UInt64?
        let currency: String?
        let confirmedAt: Date
        let blockNumber: UInt64?
    }
    
    /// Failed transaction record with reason
    struct FailedTransaction: Codable, Identifiable {
        let id: String
        let chainId: UInt64
        let toAddress: String
        let fromAddress: String?
        let amount: UInt64?
        let currency: String?
        let failedAt: Date
        let reason: String
    }
    
    // MARK: - Initialization
    
    /// Posted by BLEService when a new BLE mesh peer connects or reconnects.
    /// MeshTransactionRelay observes this to immediately attempt queued tx relay.
    static let peerConnectedNotification = Notification.Name("MeshTransactionRelay.peerConnected")
    
    init(keychain: KeychainManagerProtocol) {
        self.keychain = keychain
        // Default to true (enabled) on first launch so mesh relay works out of the box.
        // UserDefaults.bool(forKey:) returns false for missing keys, so check explicitly.
        if UserDefaults.standard.object(forKey: "mesh-tx-relay-enabled") != nil {
            self.allowMeshRelay = UserDefaults.standard.bool(forKey: "mesh-tx-relay-enabled")
        } else {
            self.allowMeshRelay = true
            UserDefaults.standard.set(true, forKey: "mesh-tx-relay-enabled")
        }
        migrateFromLegacyStorage()
        loadPendingRelays()
        loadConfirmedTransactions()
        loadFailedTransactions()
        
        // Start retry loop for any queued transactions
        if !pendingRelays.isEmpty {
            scheduleRetry()
        }
        
        // Monitor network connectivity changes to immediately retry queued txs
        startNetworkMonitor()
        
        // Monitor BLE peer connections to immediately retry via mesh
        startBLEPeerObserver()
    }
    
    /// Start NWPathMonitor to detect when device regains connectivity.
    /// Immediately triggers `retryNow()` when the path becomes satisfied.
    private func startNetworkMonitor() {
        pathMonitor.pathUpdateHandler = { [weak self] path in
            Task { @MainActor [weak self] in
                self?.networkPathSatisfied = (path.status == .satisfied)
            }
            guard path.status == .satisfied else { return }
            // Device just got connectivity — immediately retry queued transactions
            Task { @MainActor [weak self] in
                guard let self = self else { return }
                
                // Force-unstick relays that were waiting for a BLE peer —
                // now that we have internet, we can broadcast them directly.
                let stuckRelays = self.pendingRelays.filter {
                    $0.status == .relaying || $0.status == .awaitingConfirmation
                }
                for stuck in stuckRelays {
                    SecureLogger.info("📶 Network restored — requeuing stuck relay \(stuck.id.prefix(8))… (was \(stuck.status.rawValue))", category: .session)
                    self.updateRelayStatus(stuck.id, status: .queued, relayedVia: nil)
                }
                
                let queued = self.pendingRelays.filter { $0.status == .queued }
                if !queued.isEmpty {
                    SecureLogger.info("📶 Network restored — retrying \(queued.count) queued tx(s) immediately", category: .session)
                    self.retryNow()
                }
            }
        }
        pathMonitor.start(queue: monitorQueue)
    }
    
    /// Observe BLE peer connections. When a new peer appears on the mesh,
    /// immediately attempt to relay any queued transactions through them.
    private var peerObserver: NSObjectProtocol?
    
    private func startBLEPeerObserver() {
        peerObserver = NotificationCenter.default.addObserver(
            forName: Self.peerConnectedNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            guard let self = self else { return }
            
            // Update peer count immediately when a peer connects
            self.refreshPeerCount()
            
            // Force-unstick relays that are stuck in .relaying or .awaitingConfirmation.
            // When a NEW peer connects, any relay stuck with a PREVIOUS peer should be
            // immediately retried with the new peer — don't wait for the 15s/30s timeout
            // in retryQueuedTransactions(). Without this, retryNow() only processes
            // .queued relays and the stuck ones sit idle despite a fresh peer.
            let stuckRelays = self.pendingRelays.filter {
                $0.status == .relaying || $0.status == .awaitingConfirmation
            }
            for stuck in stuckRelays {
                SecureLogger.info("📡 Force-requeuing stuck relay \(stuck.id.prefix(8))… (was \(stuck.status.rawValue)) for new BLE peer", category: .session)
                self.updateRelayStatus(stuck.id, status: .queued, relayedVia: nil)
            }
            
            let retriable = self.pendingRelays.filter { $0.status == .queued }
            guard !retriable.isEmpty else { return }
            SecureLogger.info("📡 BLE peer connected — retrying \(retriable.count) pending tx(s) via mesh", category: .session)
            self.retryNow()
        }
    }
    
    func configure(bleService: BLEService?) {
        self.bleService = bleService
    }
    
    // MARK: - Queue Management
    
    /// Queue a signed transaction for mesh relay
    func queueTransaction(_ payload: TxSignedPayload) {
        let relay = PendingRelay(
            id: payload.requestId,
            payload: payload,
            createdAt: Date(),
            relayedVia: nil,
            status: .queued,
            retryCount: 0
        )
        
        pendingRelays.append(relay)
        savePendingRelays()
        
        SecureLogger.info("📤 Queued tx for mesh relay: \(payload.requestId.prefix(8))…", category: .session)
        
        // Try to relay immediately
        Task {
            await attemptRelay(relay)
        }
    }
    
    /// Attempt to relay a pending transaction.
    /// Uses NWPathMonitor for instant offline detection — never blocks on HTTP when offline.
    private func attemptRelay(_ relay: PendingRelay) async {
        // Fast path: NWPathMonitor says we have network — try direct broadcast
        if networkPathSatisfied {
            // Verify with actual RPC call (path monitor can be optimistic)
            if await hasInternetConnectivity() {
                SecureLogger.debug("Internet available, broadcasting tx directly", category: .session)
                await broadcastTransaction(relay)
                return
            }
            // Path monitor said satisfied but RPC failed — fall through to BLE
        }
        
        // No internet (or RPC unreachable) — try mesh relay via BLE first
        if allowMeshRelay, let peerWithInternet = findRelayPeer() {
            SecureLogger.debug("📡 No internet, relaying tx via BLE peer \(peerWithInternet.id.prefix(8))…", category: .session)
            await relayViaMesh(relay, to: peerWithInternet)
            return
        }
        
        // No BLE peer either — keep in queue
        if !allowMeshRelay {
            SecureLogger.debug("No internet and mesh relay disabled, keeping tx in queue for later", category: .session)
        } else {
            SecureLogger.debug("No relay peer available for tx \(relay.id.prefix(8))…", category: .session)
        }
        scheduleRetry()
    }
    
    /// Send transaction to a relay peer via BLE
    private func relayViaMesh(_ relay: PendingRelay, to peerID: PeerID) async {
        guard let bleService = bleService else { return }
        
        // Update status
        updateRelayStatus(relay.id, status: .relaying, relayedVia: peerID.id)
        
        guard let payloadData = relay.payload.encode() else {
            SecureLogger.error("Failed to encode tx payload for relay", category: .session)
            return
        }
        
        // Create BitChat packet
        let packet = BitchatPacket(
            type: MessageType.txSigned.rawValue,
            ttl: 2, // Limit hops for security
            senderID: bleService.myPeerID,
            payload: payloadData,
            isRSR: false
        )
        
        // Send via BLEService
        bleService.sendPacket(to: peerID, packet: packet)
        
        updateRelayStatus(relay.id, status: .awaitingConfirmation, relayedVia: peerID.id)
        SecureLogger.info("🔀 Relayed tx via \(peerID.id.prefix(8))…: \(relay.id.prefix(8))…", category: .session)
    }
    
    // MARK: - Incoming Packet Handling
    
    /// Handle incoming signed transaction (we are the relay peer)
    func handleIncomingTxSigned(_ data: Data, from senderPeerID: PeerID) async {
        guard let payload = TxSignedPayload.decode(data) else {
            SecureLogger.warning("Invalid TxSigned packet from \(senderPeerID.id.prefix(8))…", category: .session)
            return
        }
        
        SecureLogger.info("📥 Received tx relay request: \(payload.requestId.prefix(8))…", category: .session)
        
        // Validate we support this chain
        guard rpcEndpoints[payload.chainId] != nil else {
            await sendTxReject(to: senderPeerID, requestId: payload.requestId, reason: .unsupportedChain)
            return
        }
        
        // Check if we have internet
        guard await hasInternetConnectivity() else {
            await sendTxReject(to: senderPeerID, requestId: payload.requestId, reason: .noInternet)
            return
        }
        
        // Broadcast the transaction
        do {
            let txHash = try await broadcastToRPC(payload)
            await sendTxConfirm(to: senderPeerID, requestId: payload.requestId, txHash: txHash, status: .pending)
        } catch {
            SecureLogger.error("Tx broadcast failed: \(error.localizedDescription)", category: .session)
            await sendTxReject(to: senderPeerID, requestId: payload.requestId, reason: .invalidTx, message: error.localizedDescription)
        }
    }
    
    /// Handle incoming transaction confirmation
    func handleIncomingTxConfirm(_ data: Data, from senderPeerID: PeerID) {
        guard let confirm = TxConfirmPayload.decode(data) else {
            SecureLogger.warning("Invalid TxConfirm packet from \(senderPeerID.id.prefix(8))…", category: .session)
            return
        }
        
        SecureLogger.info("✅ Tx confirmed: \(confirm.requestId.prefix(8))… hash=\(confirm.txHash.prefix(16))…", category: .session)
        
        // Update pending relay
        if let idx = pendingRelays.firstIndex(where: { $0.id == confirm.requestId }) {
            let relay = pendingRelays[idx]
            
            // Add to confirmed
            let confirmed = ConfirmedTransaction(
                id: confirm.requestId,
                txHash: confirm.txHash,
                chainId: relay.payload.chainId,
                toAddress: relay.payload.toAddress,
                fromAddress: relay.payload.fromAddress,
                amount: relay.payload.amount,
                currency: relay.payload.currency,
                confirmedAt: Date(),
                blockNumber: confirm.blockNumber
            )
            confirmedTransactions.append(confirmed)
            saveConfirmedTransactions()

            // Persist to TransactionStore for durable history
            Task { @MainActor in
                TransactionStore.shared.record(
                    CachedTransaction(
                        id: confirmed.txHash,
                        txHash: confirmed.txHash,
                        from: (confirmed.fromAddress ?? "").lowercased(),
                        to: confirmed.toAddress.lowercased(),
                        value: confirmed.amount.map { String(format: "0x%llx", $0) } ?? "0x0",
                        timestamp: confirmed.confirmedAt,
                        blockNumber: confirmed.blockNumber,
                        chainId: UInt64(confirmed.chainId),
                        source: .meshRelay
                    ),
                    for: (confirmed.fromAddress ?? "").lowercased()
                )
            }
            
            // Remove from pending
            pendingRelays.remove(at: idx)
            savePendingRelays()
            
            // Update nonce cache so next offline TX uses correct nonce (nonce + 1).
            // Without this, the sender reuses the same cached nonce → "nonce too low".
            if let fromAddr = relay.payload.fromAddress?.lowercased() {
                let nextNonce = relay.payload.nonce + 1
                let nonceKey = "wallet-nonce-cache-\(fromAddr)-\(relay.payload.chainId)"
                appGroupDefaults.set(Int(nextNonce), forKey: nonceKey)
                appGroupDefaults.set(Date().timeIntervalSince1970, forKey: nonceKey + "-ts")
                SecureLogger.info("🔢 Updated nonce cache for \(fromAddr.prefix(10))… chain \(relay.payload.chainId): \(relay.payload.nonce) → \(nextNonce)", category: .session)
            }
        }
    }
    
    /// Handle incoming transaction rejection
    func handleIncomingTxReject(_ data: Data, from senderPeerID: PeerID) {
        guard let reject = TxRejectPayload.decode(data) else {
            SecureLogger.warning("Invalid TxReject packet from \(senderPeerID.id.prefix(8))…", category: .session)
            return
        }
        
        SecureLogger.warning("❌ Tx rejected: \(reject.requestId.prefix(8))… reason=\(reject.reason.rawValue)", category: .session)
        
        // Mark as failed, will retry with different peer
        updateRelayStatus(reject.requestId, status: .queued, relayedVia: nil)
    }
    
    // MARK: - ERC-4337 UserOp Relay (PQ Accounts)
    
    /// Queue a signed UserOperation for mesh relay (PQ account transactions).
    /// Tries direct bundler submission first, falls back to BLE mesh relay.
    func queueUserOp(_ payload: TxUserOpPayload) {
        // Encode the full UserOp payload so it survives persistence for retries
        let userOpData = try? JSONEncoder().encode(payload)
        
        let relay = PendingRelay(
            id: payload.requestId,
            payload: TxSignedPayload(
                signedTx: Data(), // Not used for UserOps — payload is in userOpPayloadData
                chainId: payload.chainId,
                nonce: 0,
                gasLimit: 0,
                maxFeePerGas: 0,
                maxPriorityFee: 0,
                toAddress: payload.toAddress,
                replyToPeerId: payload.replyToPeerId,
                fromAddress: payload.fromAddress,
                description: payload.description,
                transactionType: "pq-userop",
                currency: "ETH",
                amount: payload.amount,
                decimals: 18
            ),
            createdAt: Date(),
            relayedVia: nil,
            status: .queued,
            retryCount: 0,
            userOpPayloadData: userOpData
        )
        
        pendingRelays.append(relay)
        savePendingRelays()
        
        SecureLogger.info("📤 Queued PQ UserOp for mesh relay: \(payload.requestId.prefix(8))…", category: .session)
        
        // Try to submit/relay immediately
        Task {
            await attemptUserOpRelay(payload)
        }
    }
    
    /// Attempt to submit a UserOp — direct to bundler if online, BLE mesh if offline.
    /// Uses NWPathMonitor for instant offline detection — never blocks on HTTP when offline.
    private func attemptUserOpRelay(_ payload: TxUserOpPayload) async {
        // Fast path: NWPathMonitor says we have network — try direct bundler submission
        if networkPathSatisfied {
            // Verify with actual connectivity check (path monitor can be optimistic)
            if await hasInternetConnectivity() {
                SecureLogger.debug("Internet available, submitting UserOp directly to bundler", category: .session)
                await submitUserOpToBundler(payload)
                return
            }
            // Path monitor said satisfied but RPC failed — fall through to BLE
        }
        
        // No internet (or RPC unreachable) — try mesh relay via BLE first
        if allowMeshRelay, let peerWithInternet = findRelayPeer() {
            SecureLogger.debug("📡 No internet, relaying UserOp via BLE peer \(peerWithInternet.id.prefix(8))…", category: .session)
            await relayUserOpViaMesh(payload, to: peerWithInternet)
            return
        }
        
        // No BLE peer either — keep in queue
        if !allowMeshRelay {
            SecureLogger.debug("No internet and mesh relay disabled, keeping UserOp in queue", category: .session)
        } else {
            SecureLogger.debug("No relay peer available for UserOp \(payload.requestId.prefix(8))…", category: .session)
        }
        scheduleRetry()
    }
    
    /// Send UserOp to a relay peer via BLE
    private func relayUserOpViaMesh(_ payload: TxUserOpPayload, to peerID: PeerID) async {
        guard let bleService = bleService else { return }
        
        updateRelayStatus(payload.requestId, status: .relaying, relayedVia: peerID.id)
        
        guard let payloadData = payload.encode() else {
            SecureLogger.error("Failed to encode UserOp payload for relay", category: .session)
            return
        }
        
        let packet = BitchatPacket(
            type: MessageType.txUserOp.rawValue,
            ttl: 2, // Limit hops for security
            senderID: bleService.myPeerID,
            payload: payloadData,
            isRSR: false
        )
        
        bleService.sendPacket(to: peerID, packet: packet)
        
        updateRelayStatus(payload.requestId, status: .awaitingConfirmation, relayedVia: peerID.id)
        SecureLogger.info("🔀 Relayed PQ UserOp via \(peerID.id.prefix(8))…: \(payload.requestId.prefix(8))…", category: .session)
    }
    
    /// Handle incoming UserOp relay request (we are the relay peer with internet)
    func handleIncomingTxUserOp(_ data: Data, from senderPeerID: PeerID) async {
        guard let payload = TxUserOpPayload.decode(data) else {
            SecureLogger.warning("Invalid TxUserOp packet from \(senderPeerID.id.prefix(8))…", category: .session)
            return
        }
        
        SecureLogger.info("📥 Received PQ UserOp relay request: \(payload.requestId.prefix(8))…", category: .session)
        
        // Check if we have internet
        guard await hasInternetConnectivity() else {
            await sendTxReject(to: senderPeerID, requestId: payload.requestId, reason: .noInternet)
            return
        }
        
        // Submit UserOp to bundler on behalf of the sender
        do {
            let userOpHash = try await submitUserOpToBundlerRPC(payload)
            await sendTxConfirm(to: senderPeerID, requestId: payload.requestId, txHash: userOpHash, status: .pending)
            SecureLogger.info("✅ Relayed PQ UserOp to bundler: \(userOpHash.prefix(16))…", category: .session)
        } catch {
            SecureLogger.error("PQ UserOp bundler submission failed: \(error.localizedDescription)", category: .session)
            await sendTxReject(to: senderPeerID, requestId: payload.requestId, reason: .bundlerRejected, message: error.localizedDescription)
        }
    }
    
    /// Submit a UserOp directly to the Pimlico bundler (when we have internet)
    private func submitUserOpToBundler(_ payload: TxUserOpPayload) async {
        updateRelayStatus(payload.requestId, status: .relaying, relayedVia: nil)
        
        do {
            let userOpHash = try await submitUserOpToBundlerRPC(payload)
            
            SecureLogger.info("📡 PQ UserOp accepted by bundler: \(userOpHash.prefix(16))…", category: .session)
            
            // Move to confirmed (bundler accepted — it will handle inclusion)
            let confirmed = ConfirmedTransaction(
                id: payload.requestId,
                txHash: userOpHash,
                chainId: payload.chainId,
                toAddress: payload.toAddress,
                fromAddress: payload.fromAddress,
                amount: payload.amount,
                currency: "ETH",
                confirmedAt: Date(),
                blockNumber: nil
            )
            confirmedTransactions.append(confirmed)
            saveConfirmedTransactions()
            
            // Persist to TransactionStore
            Task { @MainActor in
                TransactionStore.shared.record(
                    CachedTransaction(
                        id: userOpHash,
                        txHash: userOpHash,
                        from: (payload.fromAddress ?? "").lowercased(),
                        to: payload.toAddress.lowercased(),
                        value: payload.amount.map { String(format: "0x%llx", $0) } ?? "0x0",
                        timestamp: Date(),
                        blockNumber: nil,
                        chainId: UInt64(payload.chainId),
                        source: .pqAccount
                    ),
                    for: (payload.fromAddress ?? "").lowercased()
                )
            }
            
            pendingRelays.removeAll { $0.id == payload.requestId }
            savePendingRelays()
            
        } catch {
            // Network error — keep queued for retry
            updateRelayStatus(payload.requestId, status: .queued, relayedVia: nil)
            lastRelayError = "UserOp submission failed: \(error.localizedDescription)"
            lastRelayErrorAt = Date()
            SecureLogger.warning("📶 UserOp bundler submission failed (will retry): \(error.localizedDescription)", category: .session)
            scheduleRetry()
        }
    }
    
    /// Raw JSON-RPC call to submit UserOp to Pimlico bundler.
    /// Routes through Tor for IP privacy, with clearnet fallback.
    private func submitUserOpToBundlerRPC(_ payload: TxUserOpPayload) async throws -> String {
        let url = URL(string: "https://api.pimlico.io/v2/\(payload.chainId)/rpc?apikey=\(payload.pimlicoAPIKey)")!
        
        let userOpDict = payload.toBundlerDict()
        
        let body: [String: Any] = [
            "jsonrpc": "2.0",
            "id": 1,
            "method": "eth_sendUserOperation",
            "params": [userOpDict, UserOperationBuilder.entryPointV07]
        ]
        
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        request.timeoutInterval = 30
        
        // Try Tor first for IP privacy, fall back to direct if Tor unavailable
        let sessions: [URLSession] = TorManager.shared.isReady
            ? [TorURLSession.shared.session, URLSession.shared]
            : [URLSession.shared]
        
        var lastError: Error = TransactionError.rpcFailed
        for session in sessions {
            do {
                let (data, response) = try await session.data(for: request)
                return try parseUserOpResponse(data: data, response: response)
            } catch {
                lastError = error
                SecureLogger.debug("UserOp bundler attempt failed (\(session === URLSession.shared ? "direct" : "Tor")): \(error.localizedDescription)", category: .session)
                continue
            }
        }
        throw lastError
    }
    
    /// Parse the JSON-RPC response from a UserOp bundler submission
    private func parseUserOpResponse(data: Data, response: URLResponse) throws -> String {
        guard let httpResponse = response as? HTTPURLResponse,
              (200...299).contains(httpResponse.statusCode) else {
            let bodyStr = String(data: data, encoding: .utf8) ?? ""
            throw TransactionError.rpcError("Bundler HTTP error: \(bodyStr.prefix(200))")
        }
        
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw TransactionError.invalidResponse
        }
        
        if let error = json["error"] as? [String: Any],
           let message = error["message"] as? String {
            throw TransactionError.rpcError("Bundler: \(message)")
        }
        
        guard let hash = json["result"] as? String else {
            throw TransactionError.invalidResponse
        }
        
        return hash
    }
    
    // MARK: - RPC Broadcasting
    
    /// Broadcast signed transaction to RPC endpoint with fallback support.
    /// Uses Helios over Tor for Ethereum mainnet, Tor-proxied RPC for other chains.
    private func broadcastToRPC(_ payload: TxSignedPayload) async throws -> String {
        let txHex = "0x" + payload.signedTx.map { String(format: "%02x", $0) }.joined()

        // Tier 1: Try Helios broadcast (Ethereum mainnet — routes via Tor internally)
        if payload.chainId == 1, await HeliosManager.shared.isRunning {
            do {
                let txHash = try await HeliosManager.shared.sendRawTransaction(rawTxHex: txHex)
                SecureLogger.info("📡 Broadcast tx via Helios (Tor): \(txHash.prefix(16))…", category: .network)
                return txHash
            } catch {
                SecureLogger.warning("Helios broadcast failed, falling back to RPC: \(error)", category: .network)
            }
        }

        // Tier 2: Tor-proxied (mainnet) or direct (testnet) RPC
        guard let primaryRPC = rpcEndpoints[payload.chainId] else {
            throw TransactionError.unsupportedChain
        }
        
        var rpcsToTry = [primaryRPC]
        if let fallbacks = fallbackRPCs[payload.chainId] {
            rpcsToTry.append(contentsOf: fallbacks)
        }
        
        let requestBody: [String: Any] = [
            "jsonrpc": "2.0",
            "id": 1,
            "method": "eth_sendRawTransaction",
            "params": [txHex]
        ]
        
        // Use Tor for mainnet chains, direct for testnets
        let isMainnet = payload.chainId == 1 || payload.chainId == 8453
        let session = isMainnet ? TorURLSession.shared.session : URLSession.shared

        var lastError: Error = TransactionError.rpcFailed
        
        for rpcURL in rpcsToTry {
            guard let url = URL(string: rpcURL) else { continue }
            
            do {
                var request = URLRequest(url: url)
                request.httpMethod = "POST"
                request.setValue("application/json", forHTTPHeaderField: "Content-Type")
                request.httpBody = try JSONSerialization.data(withJSONObject: requestBody)
                request.timeoutInterval = 15
                
                let (data, response) = try await session.data(for: request)
                
                guard let httpResponse = response as? HTTPURLResponse,
                      httpResponse.statusCode == 200 else {
                    SecureLogger.debug("RPC \(url.host ?? "unknown") returned non-200", category: .network)
                    continue
                }
                
                guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                    continue
                }
                
                if let error = json["error"] as? [String: Any],
                   let message = error["message"] as? String {
                    throw TransactionError.rpcError(message)
                }
                
                guard let txHash = json["result"] as? String else {
                    continue
                }
                
                SecureLogger.info("📡 Broadcast tx to RPC (\(url.host ?? "unknown")): \(txHash.prefix(16))…", category: .network)
                return txHash
                
            } catch let error as TransactionError {
                throw error
            } catch {
                SecureLogger.debug("RPC \(url.host ?? "unknown") failed: \(error.localizedDescription)", category: .network)
                lastError = error
                continue
            }
        }
        
        throw lastError
    }
    
    /// Broadcast our own pending transaction
    private func broadcastTransaction(_ relay: PendingRelay) async {
        updateRelayStatus(relay.id, status: .relaying, relayedVia: nil)
        
        // Log transaction details for debugging
        let txHex = "0x" + relay.payload.signedTx.map { String(format: "%02x", $0) }.joined()
        // Use print for unredacted logging during debug
        print("📍 [TX DEBUG] Broadcasting to: \(relay.payload.toAddress), chain: \(relay.payload.chainId), nonce: \(relay.payload.nonce)")
        print("📍 [TX DEBUG] Raw tx hex: \(txHex)")
        SecureLogger.debug("📡 Broadcasting tx to \(relay.payload.toAddress), chain \(relay.payload.chainId), nonce \(relay.payload.nonce)", category: .session)
        SecureLogger.debug("📡 Raw tx (first 100 chars): \(String(txHex.prefix(100)))...", category: .session)
        
        do {
            let txHash = try await broadcastToRPC(relay.payload)
            
            SecureLogger.info("📡 Broadcast accepted, polling receipt: \(txHash.prefix(16))…", category: .session)
            updateRelayStatus(relay.id, status: .awaitingConfirmation, relayedVia: nil)
            
            // Poll for receipt to verify the tx actually succeeded on-chain.
            // A tx accepted into the mempool can still revert (e.g. out-of-gas
            // when sending to a smart contract wallet like a PQ account).
            let receipt = await pollForReceipt(txHash: txHash, chainId: relay.payload.chainId)
            
            if let receipt = receipt, !receipt.succeeded {
                // Transaction was mined but REVERTED on-chain
                let reason = receipt.revertReason ?? "Transaction reverted on-chain (status: 0x0)"
                moveToFailedHistory(relay, reason: reason)
                SecureLogger.error("❌ Transaction reverted on-chain: \(reason)", category: .session)
            } else {
                // Receipt shows success, or we couldn't get receipt (treat as confirmed)
                let blockNum = receipt?.blockNumber
                let confirmed = ConfirmedTransaction(
                    id: relay.id,
                    txHash: txHash,
                    chainId: relay.payload.chainId,
                    toAddress: relay.payload.toAddress,
                    fromAddress: relay.payload.fromAddress,
                    amount: relay.payload.amount,
                    currency: relay.payload.currency,
                    confirmedAt: Date(),
                    blockNumber: blockNum
                )
                confirmedTransactions.append(confirmed)
                saveConfirmedTransactions()

                // Persist to TransactionStore for durable history
                Task { @MainActor in
                    TransactionStore.shared.record(
                        CachedTransaction(
                            id: confirmed.txHash,
                            txHash: confirmed.txHash,
                            from: (confirmed.fromAddress ?? "").lowercased(),
                            to: confirmed.toAddress.lowercased(),
                            value: confirmed.amount.map { String(format: "0x%llx", $0) } ?? "0x0",
                            timestamp: confirmed.confirmedAt,
                            blockNumber: confirmed.blockNumber,
                            chainId: UInt64(confirmed.chainId),
                            source: .meshRelay
                        ),
                        for: (confirmed.fromAddress ?? "").lowercased()
                    )
                }
                
                // Remove from pending
                pendingRelays.removeAll { $0.id == relay.id }
                savePendingRelays()
                
                // Update nonce cache so next offline TX uses correct nonce
                if let fromAddr = relay.payload.fromAddress?.lowercased() {
                    let nextNonce = relay.payload.nonce + 1
                    let nonceKey = "wallet-nonce-cache-\(fromAddr)-\(relay.payload.chainId)"
                    appGroupDefaults.set(Int(nextNonce), forKey: nonceKey)
                    appGroupDefaults.set(Date().timeIntervalSince1970, forKey: nonceKey + "-ts")
                    SecureLogger.info("🔢 Updated nonce cache: \(relay.payload.nonce) → \(nextNonce)", category: .session)
                }
                
                if receipt != nil {
                    SecureLogger.info("✅ Transaction confirmed on-chain: \(txHash.prefix(16))… block=\(blockNum.map { String($0) } ?? "?")", category: .session)
                } else {
                    SecureLogger.info("✅ Direct broadcast tx (receipt pending): \(txHash.prefix(16))…", category: .session)
                }
            }
        } catch let error as TransactionError {
            // Check if it's a real transaction error vs network error
            switch error {
            case .rpcError(let message):
                // Real blockchain error - move to failed history (invalid nonce, insufficient funds, etc.)
                moveToFailedHistory(relay, reason: message)
                lastRelayError = "TX rejected: \(message)"
                lastRelayErrorAt = Date()
                SecureLogger.error("❌ Transaction rejected by network: \(message)", category: .session)
            default:
                // Network/connectivity error - keep queued for retry
                updateRelayStatus(relay.id, status: .queued, relayedVia: nil)
                lastRelayError = "Broadcast failed (will retry): \(error.localizedDescription)"
                lastRelayErrorAt = Date()
                SecureLogger.warning("📶 Broadcast failed (will retry): \(error.localizedDescription)", category: .session)
                scheduleRetry()
            }
        } catch {
            // Network error (timeout, no connection) - keep queued for retry
            updateRelayStatus(relay.id, status: .queued, relayedVia: nil)
            lastRelayError = "Network error (will retry): \(error.localizedDescription)"
            lastRelayErrorAt = Date()
            SecureLogger.warning("📶 Broadcast failed (will retry): \(error.localizedDescription)", category: .session)
            scheduleRetry()
        }
    }
    
    // MARK: - Receipt Polling
    
    /// Result of polling for a transaction receipt
    struct TxReceiptResult {
        let succeeded: Bool
        let blockNumber: UInt64?
        let revertReason: String?
    }
    
    /// Poll for a transaction receipt to verify on-chain success/failure.
    ///
    /// Tier 1: Helios verified receipt (Ethereum mainnet).
    /// Tier 2: RPC over Tor (mainnet) or direct (testnet).
    ///
    /// - Returns: Receipt result, or nil if receipt not available after timeout.
    private func pollForReceipt(txHash: String, chainId: UInt64, maxAttempts: Int = 15, intervalSeconds: UInt64 = 4) async -> TxReceiptResult? {
        // Use Tor session for mainnet chains
        let isMainnet = chainId == 1 || chainId == 8453
        let session = isMainnet ? TorURLSession.shared.session : URLSession.shared

        guard let primaryRPC = rpcEndpoints[chainId] else { return nil }
        
        var rpcsToTry = [primaryRPC]
        if let fallbacks = fallbackRPCs[chainId] {
            rpcsToTry.append(contentsOf: fallbacks)
        }
        
        let requestBody: [String: Any] = [
            "jsonrpc": "2.0",
            "id": 1,
            "method": "eth_getTransactionReceipt",
            "params": [txHash]
        ]
        
        for attempt in 0..<maxAttempts {
            if attempt > 0 {
                try? await Task.sleep(nanoseconds: intervalSeconds * 1_000_000_000)
            }

            // Tier 1: Try Helios verified receipt for Ethereum mainnet
            if chainId == 1, await HeliosManager.shared.isRunning {
                do {
                    let receiptJSON = try await HeliosManager.shared.getTransactionReceipt(txHash: txHash)
                    if let data = receiptJSON.data(using: .utf8),
                       let result = try JSONSerialization.jsonObject(with: data) as? [String: Any] {
                        let statusHex = result["status"] as? String ?? "0x1"
                        let succeeded = statusHex != "0x0"
                        var blockNumber: UInt64?
                        if let blockHex = result["blockNumber"] as? String {
                            let hex = blockHex.hasPrefix("0x") ? String(blockHex.dropFirst(2)) : blockHex
                            blockNumber = UInt64(hex, radix: 16)
                        }
                        var revertReason: String?
                        if !succeeded {
                            if let gasUsedHex = result["gasUsed"] as? String,
                               let gasUsed = UInt64(gasUsedHex.hasPrefix("0x") ? String(gasUsedHex.dropFirst(2)) : gasUsedHex, radix: 16) {
                                revertReason = "Transaction reverted (gas used: \(gasUsed))."
                            } else {
                                revertReason = "Transaction reverted on-chain (status: 0x0)"
                            }
                        }
                        return TxReceiptResult(succeeded: succeeded, blockNumber: blockNumber, revertReason: revertReason)
                    }
                } catch {
                    // Receipt not yet available via Helios — fall through to RPC
                }
            }

            // Tier 2: RPC over Tor/direct
            for rpcURL in rpcsToTry {
                guard let url = URL(string: rpcURL) else { continue }
                
                do {
                    var request = URLRequest(url: url)
                    request.httpMethod = "POST"
                    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
                    request.httpBody = try JSONSerialization.data(withJSONObject: requestBody)
                    request.timeoutInterval = 10
                    
                    let (data, response) = try await session.data(for: request)
                    
                    guard let httpResponse = response as? HTTPURLResponse,
                          httpResponse.statusCode == 200 else {
                        continue
                    }
                    
                    guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                        continue
                    }
                    
                    // result is null when tx is still pending
                    guard let result = json["result"] as? [String: Any] else {
                        break // Not yet mined, wait and retry
                    }
                    
                    // Parse status: "0x1" = success, "0x0" = reverted
                    let statusHex = result["status"] as? String ?? "0x1"
                    let succeeded = statusHex != "0x0"
                    
                    // Parse block number
                    var blockNumber: UInt64?
                    if let blockHex = result["blockNumber"] as? String {
                        let hex = blockHex.hasPrefix("0x") ? String(blockHex.dropFirst(2)) : blockHex
                        blockNumber = UInt64(hex, radix: 16)
                    }
                    
                    // Try to extract revert reason if failed
                    var revertReason: String?
                    if !succeeded {
                        // Check gasUsed vs gasLimit for out-of-gas detection
                        if let gasUsedHex = result["gasUsed"] as? String,
                           let gasUsed = UInt64(gasUsedHex.hasPrefix("0x") ? String(gasUsedHex.dropFirst(2)) : gasUsedHex, radix: 16) {
                            revertReason = "Transaction reverted (gas used: \(gasUsed)). The recipient may be a smart contract wallet requiring more gas."
                        } else {
                            revertReason = "Transaction reverted on-chain (status: 0x0)"
                        }
                    }
                    
                    return TxReceiptResult(
                        succeeded: succeeded,
                        blockNumber: blockNumber,
                        revertReason: revertReason
                    )
                    
                } catch {
                    continue
                }
            }
        }
        
        // Couldn't get receipt after all attempts — treat as indeterminate
        SecureLogger.warning("⏱ Receipt polling timed out for \(txHash.prefix(16))…", category: .session)
        return nil
    }
    
    // MARK: - Response Sending
    
    private func sendTxConfirm(to peerID: PeerID, requestId: String, txHash: String, status: TxStatus) async {
        guard let bleService = bleService else { return }
        
        let confirm = TxConfirmPayload(requestId: requestId, txHash: txHash, status: status)
        guard let payloadData = confirm.encode() else { return }
        
        let packet = BitchatPacket(
            type: MessageType.txConfirm.rawValue,
            ttl: 2,
            senderID: bleService.myPeerID,
            payload: payloadData,
            isRSR: false
        )
        
        bleService.sendPacket(to: peerID, packet: packet)
    }
    
    private func sendTxReject(to peerID: PeerID, requestId: String, reason: TxRejectReason, message: String? = nil) async {
        guard let bleService = bleService else { return }
        
        let reject = TxRejectPayload(requestId: requestId, reason: reason, message: message)
        guard let payloadData = reject.encode() else { return }
        
        let packet = BitchatPacket(
            type: MessageType.txReject.rawValue,
            ttl: 2,
            senderID: bleService.myPeerID,
            payload: payloadData,
            isRSR: false
        )
        
        bleService.sendPacket(to: peerID, packet: packet)
    }
    
    // MARK: - Helpers
    
    private func findRelayPeer() -> PeerID? {
        guard let bleService = bleService else {
            connectedPeerCount = 0
            return nil
        }
        let peers = bleService.currentPeerSnapshots()
        let connectedPeers = peers.filter { $0.isConnected }
        connectedPeerCount = connectedPeers.count
        guard !connectedPeers.isEmpty else { return nil }
        // Randomise which peer we relay through to distribute load
        // and avoid repeatedly hitting a peer that might be offline
        return connectedPeers.randomElement()?.peerID
    }
    
    /// Refresh the connected peer count from BLE service
    func refreshPeerCount() {
        guard let bleService = bleService else {
            connectedPeerCount = 0
            return
        }
        let peers = bleService.currentPeerSnapshots()
        connectedPeerCount = peers.filter { $0.isConnected }.count
    }
    
    /// Whether the relay has a BLE service configured
    var isBLEConfigured: Bool {
        bleService != nil
    }
    
    /// Manual retry triggered from UI — bypasses debounce
    func manualRetry() {
        lastRelayError = nil
        lastRelayErrorAt = nil
        refreshPeerCount()
        
        let retriable = pendingRelays.filter {
            $0.status == .queued || $0.status == .relaying || $0.status == .awaitingConfirmation
        }
        guard !retriable.isEmpty else {
            lastRelayError = "No pending transactions to retry"
            lastRelayErrorAt = Date()
            return
        }
        
        SecureLogger.info("🔄 Manual retry triggered for \(retriable.count) tx(s), \(connectedPeerCount) BLE peer(s) connected", category: .session)
        
        // Force reset debounce
        lastRetryAt = .distantPast
        retryNow()
    }
    
    private func hasInternetConnectivity() async -> Bool {
        // Quick connectivity check with aggressive timeout.
        // Uses a task group so ALL checks race concurrently — first success wins.
        // Overall 4s cap prevents blocking the BLE relay path when WiFi is connected
        // but has no actual internet (NWPathMonitor says "satisfied" optimistically).
        let checkURLs = [
            "https://sepolia.drpc.org",     // Fast, reliable public endpoint
            "https://rpc.flashbots.net"     // Fallback
        ]
        
        return await withTaskGroup(of: Bool.self) { group in
            // Race all checks concurrently (both sessions × both URLs)
            for session in [URLSession.shared, TorURLSession.shared.session] {
                for urlString in checkURLs {
                    group.addTask {
                        guard let url = URL(string: urlString) else { return false }
                        var request = URLRequest(url: url)
                        request.httpMethod = "POST"
                        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
                        request.httpBody = try? JSONSerialization.data(withJSONObject: [
                            "jsonrpc": "2.0",
                            "id": 1,
                            "method": "eth_chainId",
                            "params": []
                        ])
                        request.timeoutInterval = 4
                        
                        do {
                            let (_, response) = try await session.data(for: request)
                            return (response as? HTTPURLResponse)?.statusCode == 200
                        } catch {
                            return false
                        }
                    }
                }
            }
            
            // Return true as soon as ANY check succeeds
            for await result in group {
                if result {
                    group.cancelAll()
                    return true
                }
            }
            return false
        }
    }
    
    private func updateRelayStatus(_ id: String, status: RelayStatus, relayedVia: String?) {
        if let idx = pendingRelays.firstIndex(where: { $0.id == id }) {
            pendingRelays[idx].status = status
            pendingRelays[idx].relayedVia = relayedVia
            pendingRelays[idx].statusChangedAt = Date()
            if status == .queued {
                pendingRelays[idx].retryCount += 1
            }
            savePendingRelays()
        }
    }
    
    // MARK: - Retry Logic
    
    /// Schedule a retry for queued transactions
    private func scheduleRetry() {
        guard !retryScheduled else { return }
        retryScheduled = true
        
        retryTask?.cancel()
        retryTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(30 * 1_000_000_000)) // 30 seconds
            guard !Task.isCancelled else { return }
            await self?.retryQueuedTransactions()
        }
    }
    
    /// Retry all queued transactions
    private func retryQueuedTransactions() async {
        retryScheduled = false
        
        // ── Unstick relays stuck in awaitingConfirmation for too long ──
        // If the confirm/reject BLE packet never arrives (disconnect, packet drop),
        // the relay would be stuck forever. Requeue after 30 seconds for retry.
        let now = Date()
        let staleConfirmations = pendingRelays.filter {
            $0.status == .awaitingConfirmation &&
            now.timeIntervalSince($0.statusChangedAt) > 30
        }
        for stale in staleConfirmations {
            SecureLogger.warning("⏳ Relay \(stale.id.prefix(8))… stuck in awaitingConfirmation for >30s — requeuing", category: .session)
            updateRelayStatus(stale.id, status: .queued, relayedVia: nil)
        }
        
        // Also unstick relays stuck in .relaying (BLE send started but never progressed).
        // Reduced from 60s to 15s — BLE sends complete in <2s; if stuck longer, the peer
        // likely disconnected or the packet was lost.
        let staleRelaying = pendingRelays.filter {
            $0.status == .relaying &&
            now.timeIntervalSince($0.statusChangedAt) > 15
        }
        for stale in staleRelaying {
            SecureLogger.warning("⏳ Relay \(stale.id.prefix(8))… stuck in relaying for >15s — requeuing", category: .session)
            updateRelayStatus(stale.id, status: .queued, relayedVia: nil)
        }
        
        let queuedRelays = pendingRelays.filter { $0.status == .queued }
        guard !queuedRelays.isEmpty else { return }
        
        SecureLogger.info("🔄 Retrying \(queuedRelays.count) queued transaction(s)...", category: .session)
        
        // Check for stale transactions (older than maxRetryAge)
        for relay in queuedRelays {
            if now.timeIntervalSince(relay.createdAt) > maxRetryAge {
                SecureLogger.warning("⏰ Transaction \(relay.id.prefix(8))… expired after 24h", category: .session)
                moveToFailedHistory(relay, reason: "Expired after 24 hours without successful broadcast")
                continue
            }
            
            // Check if this is a PQ UserOp relay
            if relay.payload.transactionType == "pq-userop" {
                if let opData = relay.userOpPayloadData,
                   let userOpPayload = try? JSONDecoder().decode(TxUserOpPayload.self, from: opData) {
                    await attemptUserOpRelay(userOpPayload)
                } else {
                    SecureLogger.error("❌ Cannot retry UserOp \(relay.id.prefix(8))… — missing payload data", category: .session)
                    moveToFailedHistory(relay, reason: "UserOp payload data lost, cannot retry")
                }
                continue
            }
            
            // Standard EOA transaction relay
            // Use NWPathMonitor for instant offline check — avoids 20s HTTP timeout when offline
            if networkPathSatisfied, await hasInternetConnectivity() {
                await broadcastTransaction(relay)
            } else if allowMeshRelay, let peer = findRelayPeer() {
                // No internet (or path unsatisfied) — relay via BLE mesh
                await relayViaMesh(relay, to: peer)
            }
            // If no internet and no BLE peer, just keep in queue for next retry
        }
        
        // Schedule another retry if there are still queued or stuck transactions
        let needsRetry = pendingRelays.contains {
            $0.status == .queued || $0.status == .awaitingConfirmation || $0.status == .relaying
        }
        if needsRetry {
            scheduleRetry()
        }
    }
    
    /// Track last retry to debounce rapid-fire triggers (peer connect + network restore)
    private var lastRetryAt: Date = .distantPast
    private let retryDebounceInterval: TimeInterval = 3 // At most one retry every 3 seconds
    
    /// Manually trigger retry (e.g., when network becomes available or BLE peer connects).
    /// Debounced to avoid concurrent retries from overlapping triggers.
    func retryNow() {
        let now = Date()
        guard now.timeIntervalSince(lastRetryAt) >= retryDebounceInterval else {
            SecureLogger.debug("🔄 Retry debounced (last retry \(String(format: "%.1f", now.timeIntervalSince(lastRetryAt)))s ago)", category: .session)
            return
        }
        lastRetryAt = now
        Task {
            await retryQueuedTransactions()
        }
    }
    
    /// Get count of transactions awaiting broadcast
    var queuedCount: Int {
        pendingRelays.filter { $0.status == .queued }.count
    }
    
    /// Clear all pending relays (panic mode)
    func clearAll() {
        pendingRelays.removeAll()
        savePendingRelays()
        SecureLogger.warning("🧹 Cleared all pending mesh relays", category: .session)
    }
    
    // MARK: - Persistence
    
    /// Migrate data from standard UserDefaults to App Group
    private func migrateFromLegacyStorage() {
        let legacy = UserDefaults.standard
        let appGroup = appGroupDefaults
        
        // Migrate pending relays
        if let data = legacy.data(forKey: storageKey), appGroup.data(forKey: storageKey) == nil {
            appGroup.set(data, forKey: storageKey)
            legacy.removeObject(forKey: storageKey)
            SecureLogger.info("📦 Migrated pending relays to App Group", category: .session)
        }
        
        // Migrate confirmed transactions
        if let data = legacy.data(forKey: confirmedStorageKey), appGroup.data(forKey: confirmedStorageKey) == nil {
            appGroup.set(data, forKey: confirmedStorageKey)
            legacy.removeObject(forKey: confirmedStorageKey)
            SecureLogger.info("📦 Migrated confirmed transactions to App Group", category: .session)
        }
        
        // Migrate failed transactions
        if let data = legacy.data(forKey: failedStorageKey), appGroup.data(forKey: failedStorageKey) == nil {
            appGroup.set(data, forKey: failedStorageKey)
            legacy.removeObject(forKey: failedStorageKey)
            SecureLogger.info("📦 Migrated failed transactions to App Group", category: .session)
        }
    }
    
    private func loadPendingRelays() {
        guard let data = appGroupDefaults.data(forKey: storageKey),
              let relays = try? JSONDecoder().decode([PendingRelay].self, from: data) else {
            return
        }
        pendingRelays = relays
    }
    
    private func savePendingRelays() {
        if let data = try? JSONEncoder().encode(pendingRelays) {
            appGroupDefaults.set(data, forKey: storageKey)
        }
    }
    
    private func loadConfirmedTransactions() {
        guard let data = appGroupDefaults.data(forKey: confirmedStorageKey),
              let confirmed = try? JSONDecoder().decode([ConfirmedTransaction].self, from: data) else {
            return
        }
        confirmedTransactions = confirmed
    }
    
    private func saveConfirmedTransactions() {
        if let data = try? JSONEncoder().encode(confirmedTransactions) {
            appGroupDefaults.set(data, forKey: confirmedStorageKey)
        }
    }
    
    private func loadFailedTransactions() {
        guard let data = appGroupDefaults.data(forKey: failedStorageKey),
              let failed = try? JSONDecoder().decode([FailedTransaction].self, from: data) else {
            return
        }
        failedTransactions = failed
    }
    
    private func saveFailedTransactions() {
        if let data = try? JSONEncoder().encode(failedTransactions) {
            appGroupDefaults.set(data, forKey: failedStorageKey)
        }
    }
    
    /// Move a relay to failed history with a reason
    private func moveToFailedHistory(_ relay: PendingRelay, reason: String) {
        // Create failed transaction record
        let failed = FailedTransaction(
            id: relay.id,
            chainId: relay.payload.chainId,
            toAddress: relay.payload.toAddress,
            fromAddress: relay.payload.fromAddress,
            amount: relay.payload.amount,
            currency: relay.payload.currency,
            failedAt: Date(),
            reason: reason
        )
        failedTransactions.append(failed)
        saveFailedTransactions()
        
        // Remove from pending
        pendingRelays.removeAll { $0.id == relay.id }
        savePendingRelays()
        
        SecureLogger.info("📋 Moved tx \(relay.id.prefix(8))… to failed history: \(reason)", category: .session)
    }
    
    /// Clear failed transaction history
    func clearFailedHistory() {
        failedTransactions.removeAll()
        saveFailedTransactions()
        SecureLogger.info("🧹 Cleared failed transaction history", category: .session)
    }
}

// MARK: - Errors

enum TransactionError: Error, LocalizedError {
    case unsupportedChain
    case rpcFailed
    case invalidResponse
    case rpcError(String)
    case signingFailed
    
    var errorDescription: String? {
        switch self {
        case .unsupportedChain: return "Unsupported chain"
        case .rpcFailed: return "RPC request failed"
        case .invalidResponse: return "Invalid RPC response"
        case .rpcError(let msg): return "RPC error: \(msg)"
        case .signingFailed: return "Transaction signing failed"
        }
    }
}
