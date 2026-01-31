//
// XMTPTransport.swift
// bitchat
//
// XMTP transport conforming to the Transport protocol for seamless integration
// with BitChat's message routing infrastructure.
//
// This is free and unencumbered software released into the public domain.
// For more information, see <https://unlicense.org>
//

import BitLogger
import Combine
import Foundation
import XMTP

/// XMTP transport implementation conforming to the Transport protocol.
/// Routes messages to XMTP contacts while maintaining compatibility with BLE mesh.
final class XMTPTransport: Transport, @unchecked Sendable {
    // MARK: - Properties
    
    /// Short peer ID for BitChat packet embedding
    var senderPeerID = PeerID(str: "")
    
    private let keychain: KeychainManagerProtocol
    private let identityBridge: XMTPIdentityBridge
    private let clientService: XMTPClientService
    
    // Reachability cache (thread-safe)
    private var reachablePeers: Set<PeerID> = []
    private let queue = DispatchQueue(label: "xmtp.transport.state", attributes: .concurrent)
    
    // Read receipt throttling
    private struct QueuedRead {
        let receipt: ReadReceipt
        let peerID: PeerID
    }
    private var readQueue: [QueuedRead] = []
    private var isSendingReadAcks = false
    private let readAckInterval: TimeInterval = TransportConfig.nostrReadAckInterval
    
    // Conversation cache
    private var conversationCache: [String: Dm] = [:] // inboxId -> Dm
    
    // MARK: - Transport Protocol Properties
    
    weak var delegate: BitchatDelegate?
    weak var peerEventsDelegate: TransportPeerEventsDelegate?
    
    var peerSnapshotPublisher: AnyPublisher<[TransportPeerSnapshot], Never> {
        Just([]).eraseToAnyPublisher()
    }
    
    var myPeerID: PeerID { senderPeerID }
    var myNickname: String { "" }
    
    // MARK: - Initialization
    
    @MainActor
    init(keychain: KeychainManagerProtocol, identityBridge: XMTPIdentityBridge, clientService: XMTPClientService) {
        self.keychain = keychain
        self.identityBridge = identityBridge
        self.clientService = clientService
        
        setupObservers()
        refreshReachablePeers()
    }
    
    private func setupObservers() {
        NotificationCenter.default.addObserver(
            forName: .favoriteStatusChanged,
            object: nil,
            queue: nil
        ) { [weak self] _ in
            self?.refreshReachablePeers()
        }
    }
    
    private func refreshReachablePeers() {
        Task { @MainActor in
            let favorites = FavoritesPersistenceService.shared.favorites
            let reachable = favorites.values
                .filter { $0.peerXMTPInboxId != nil }
                .map { PeerID(publicKey: $0.peerNoisePublicKey) }
            
            self.queue.async(flags: .barrier) { [weak self] in
                self?.reachablePeers = Set(reachable)
            }
        }
    }
    
    // MARK: - Transport Protocol Methods
    
    func currentPeerSnapshots() -> [TransportPeerSnapshot] { [] }
    
    func setNickname(_ nickname: String) { /* not used for XMTP */ }
    
    func startServices() {
        Task { @MainActor in
            do {
                try await clientService.connect()
            } catch {
                SecureLogger.error("Failed to start XMTP: \(error.localizedDescription)", category: .network)
            }
        }
    }
    
    func stopServices() {
        Task { @MainActor in
            clientService.disconnect()
        }
    }
    
    func emergencyDisconnectAll() {
        Task { @MainActor in
            clientService.disconnect()
        }
    }
    
    func isPeerConnected(_ peerID: PeerID) -> Bool { false }
    
    func isPeerReachable(_ peerID: PeerID) -> Bool {
        queue.sync {
            if reachablePeers.contains(peerID) { return true }
            if peerID.isShort {
                return reachablePeers.contains(where: { $0.toShort() == peerID })
            }
            return false
        }
    }
    
    func peerNickname(peerID: PeerID) -> String? { nil }
    func getPeerNicknames() -> [PeerID: String] { [:] }
    
    func getFingerprint(for peerID: PeerID) -> String? { nil }
    func getNoiseSessionState(for peerID: PeerID) -> LazyHandshakeState { .none }
    func triggerHandshake(with peerID: PeerID) { /* no-op */ }
    
    private static var cachedNoiseService: NoiseEncryptionService?
    func getNoiseService() -> NoiseEncryptionService {
        if let noiseService = Self.cachedNoiseService {
            return noiseService
        }
        let noiseService = NoiseEncryptionService(keychain: keychain)
        Self.cachedNoiseService = noiseService
        return noiseService
    }
    
    // MARK: - Messaging
    
    func sendMessage(_ content: String, mentions: [String]) {
        // Public broadcast not supported over XMTP
    }
    
    func sendPrivateMessage(_ content: String, to peerID: PeerID, recipientNickname: String, messageID: String) {
        Task { @MainActor in
            guard let recipientInboxId = resolveRecipientInboxId(for: peerID) else {
                SecureLogger.warning("XMTPTransport: No inbox ID for peer \(peerID.id.prefix(8))…", category: .session)
                return
            }
            
            SecureLogger.debug("XMTPTransport: preparing PM to \(recipientInboxId.prefix(16))… id=\(messageID.prefix(8))…", category: .session)
            
            // Encode as BitChat packet
            guard let embedded = XMTPEmbeddedBitChat.encodePM(
                content: content,
                messageID: messageID,
                recipientPeerID: peerID,
                senderPeerID: senderPeerID
            ) else {
                SecureLogger.error("XMTPTransport: failed to embed PM packet", category: .session)
                return
            }
            
            do {
                let conversation = try await getOrCreateConversation(with: recipientInboxId)
                try await clientService.sendMessage(embedded, to: conversation)
            } catch {
                SecureLogger.error("XMTPTransport: send failed: \(error.localizedDescription)", category: .session)
            }
        }
    }
    
    func sendReadReceipt(_ receipt: ReadReceipt, to peerID: PeerID) {
        queue.async(flags: .barrier) { [weak self] in
            self?.readQueue.append(QueuedRead(receipt: receipt, peerID: peerID))
            self?.processReadQueueIfNeeded()
        }
    }
    
    private func processReadQueueIfNeeded() {
        guard !isSendingReadAcks else { return }
        isSendingReadAcks = true
        
        DispatchQueue.main.asyncAfter(deadline: .now() + readAckInterval) { [weak self] in
            self?.flushReadQueue()
        }
    }
    
    private func flushReadQueue() {
        var pending: [QueuedRead] = []
        queue.sync(flags: .barrier) { [weak self] in
            pending = self?.readQueue ?? []
            self?.readQueue.removeAll()
            self?.isSendingReadAcks = false
        }
        
        for read in pending {
            Task { @MainActor in
                await self.sendReadReceiptInternal(read.receipt, to: read.peerID)
            }
        }
    }
    
    @MainActor
    private func sendReadReceiptInternal(_ receipt: ReadReceipt, to peerID: PeerID) async {
        guard let recipientInboxId = resolveRecipientInboxId(for: peerID) else { return }
        
        guard let embedded = XMTPEmbeddedBitChat.encodeAck(
            type: .readReceipt,
            messageID: receipt.originalMessageID,
            senderPeerID: senderPeerID
        ) else { return }
        
        do {
            let conversation = try await getOrCreateConversation(with: recipientInboxId)
            try await clientService.sendMessage(embedded, to: conversation)
        } catch {
            SecureLogger.debug("XMTPTransport: read receipt failed: \(error.localizedDescription)", category: .session)
        }
    }
    
    func sendFavoriteNotification(to peerID: PeerID, isFavorite: Bool) {
        Task { @MainActor in
            guard let recipientInboxId = resolveRecipientInboxId(for: peerID),
                  let myInboxId = clientService.inboxId else { return }
            
            let content = isFavorite ? "[FAVORITED]:\(myInboxId)" : "[UNFAVORITED]:\(myInboxId)"
            
            guard let embedded = XMTPEmbeddedBitChat.encodePM(
                content: content,
                messageID: UUID().uuidString,
                recipientPeerID: peerID,
                senderPeerID: senderPeerID
            ) else { return }
            
            do {
                let conversation = try await getOrCreateConversation(with: recipientInboxId)
                try await clientService.sendMessage(embedded, to: conversation)
            } catch {
                SecureLogger.error("XMTPTransport: favorite notification failed", category: .session)
            }
        }
    }
    
    func sendBroadcastAnnounce() { /* no-op for XMTP */ }
    
    func sendDeliveryAck(for messageID: String, to peerID: PeerID) {
        Task { @MainActor in
            guard let recipientInboxId = resolveRecipientInboxId(for: peerID) else { return }
            
            guard let embedded = XMTPEmbeddedBitChat.encodeAck(
                type: .delivered,
                messageID: messageID,
                senderPeerID: senderPeerID
            ) else { return }
            
            do {
                let conversation = try await getOrCreateConversation(with: recipientInboxId)
                try await clientService.sendMessage(embedded, to: conversation)
            } catch {
                SecureLogger.debug("XMTPTransport: delivery ack failed", category: .session)
            }
        }
    }
    
    // MARK: - File Transfer
    
    func sendFileBroadcast(_ packet: BitchatFilePacket, transferId: String) {
        // XMTP doesn't support broadcasts - would need to send to all known peers
        // For now, log and skip. Location channels could handle this differently.
        SecureLogger.debug("XMTPTransport: broadcast file not supported, use sendFilePrivate", category: .session)
    }
    
    func sendFilePrivate(_ packet: BitchatFilePacket, to peerID: PeerID, transferId: String) {
        Task { @MainActor in
            guard let recipientInboxId = resolveRecipientInboxId(for: peerID) else {
                SecureLogger.warning("XMTPTransport: No inbox ID for file recipient \(peerID.id.prefix(8))…", category: .session)
                return
            }
            
            // Determine file type from mime type or filename
            let fileType = determineFileType(packet: packet)
            
            SecureLogger.debug("XMTPTransport: sending \(fileType.rawValue) to \(recipientInboxId.prefix(16))… id=\(transferId.prefix(8))…", category: .session)
            
            guard let embedded = XMTPEmbeddedBitChat.encodeFile(
                packet: packet,
                fileType: fileType,
                transferId: transferId,
                recipientPeerID: peerID,
                senderPeerID: senderPeerID
            ) else {
                SecureLogger.error("XMTPTransport: failed to encode file packet", category: .session)
                return
            }
            
            do {
                let conversation = try await getOrCreateConversation(with: recipientInboxId)
                try await clientService.sendMessage(embedded, to: conversation)
                SecureLogger.debug("XMTPTransport: file sent successfully, id=\(transferId.prefix(8))…", category: .session)
            } catch {
                SecureLogger.error("XMTPTransport: file send failed: \(error.localizedDescription)", category: .session)
            }
        }
    }
    
    func cancelTransfer(_ transferId: String) {
        // XMTP messages can't be cancelled once sent
        SecureLogger.debug("XMTPTransport: cancelTransfer not supported for XMTP", category: .session)
    }
    
    private func determineFileType(packet: BitchatFilePacket) -> XMTPEmbeddedBitChat.FileType {
        // Check mime type first
        if let mimeType = packet.mimeType?.lowercased() {
            if mimeType.hasPrefix("audio/") || mimeType.contains("m4a") || mimeType.contains("aac") {
                return .voice
            }
            if mimeType.hasPrefix("image/") {
                return .image
            }
        }
        
        // Check filename extension
        if let fileName = packet.fileName?.lowercased() {
            if fileName.hasSuffix(".m4a") || fileName.hasSuffix(".aac") || fileName.hasSuffix(".mp3") {
                return .voice
            }
            if fileName.hasSuffix(".jpg") || fileName.hasSuffix(".jpeg") || fileName.hasSuffix(".png") || fileName.hasSuffix(".gif") {
                return .image
            }
        }
        
        return .file
    }
    
    // MARK: - Private Helpers
    
    @MainActor
    private func resolveRecipientInboxId(for peerID: PeerID) -> String? {
        // Try to get from favorites
        if let fav = FavoritesPersistenceService.shared.getFavoriteStatus(forPeerID: peerID) {
            return fav.peerXMTPInboxId
        }
        
        // Try identity bridge
        if let noiseKey = peerID.noiseKey {
            return identityBridge.getXMTPInboxId(for: noiseKey)
        }
        
        return nil
    }
    
    private func getOrCreateConversation(with inboxId: String) async throws -> Dm {
        if let cached = conversationCache[inboxId] {
            return cached
        }
        
        let conversation = try await clientService.findOrCreateDM(with: inboxId)
        conversationCache[inboxId] = conversation
        return conversation
    }
}

// MARK: - BitChat Packet Encoding for XMTP

enum XMTPEmbeddedBitChat {
    enum AckType: String {
        case delivered = "DELIVERED"
        case readReceipt = "READ"
    }
    
    enum FileType: String {
        case voice = "voice"
        case image = "image"
        case file = "file"
    }
    
    /// Encode a private message for XMTP transport
    static func encodePM(content: String, messageID: String, recipientPeerID: PeerID, senderPeerID: PeerID) -> String? {
        let payload: [String: Any] = [
            "type": "pm",
            "content": content,
            "messageID": messageID,
            "recipient": recipientPeerID.id,
            "sender": senderPeerID.id,
            "timestamp": Date().timeIntervalSince1970
        ]
        
        guard let data = try? JSONSerialization.data(withJSONObject: payload),
              let base64 = data.base64EncodedString().addingPercentEncoding(withAllowedCharacters: .urlSafeBase64) else {
            return nil
        }
        
        return "bitchat1:\(base64)"
    }
    
    /// Encode an acknowledgment for XMTP transport
    static func encodeAck(type: AckType, messageID: String, senderPeerID: PeerID) -> String? {
        let payload: [String: Any] = [
            "type": "ack",
            "ackType": type.rawValue,
            "messageID": messageID,
            "sender": senderPeerID.id,
            "timestamp": Date().timeIntervalSince1970
        ]
        
        guard let data = try? JSONSerialization.data(withJSONObject: payload),
              let base64 = data.base64EncodedString().addingPercentEncoding(withAllowedCharacters: .urlSafeBase64) else {
            return nil
        }
        
        return "bitchat1:\(base64)"
    }
    
    /// Encode a file (voice note, image, or generic file) for XMTP transport
    static func encodeFile(
        packet: BitchatFilePacket,
        fileType: FileType,
        transferId: String,
        recipientPeerID: PeerID?,
        senderPeerID: PeerID
    ) -> String? {
        // Base64 encode the file content
        let contentBase64 = packet.content.base64EncodedString()
        
        var payload: [String: Any] = [
            "type": "file",
            "fileType": fileType.rawValue,
            "content": contentBase64,
            "transferId": transferId,
            "sender": senderPeerID.id,
            "timestamp": Date().timeIntervalSince1970
        ]
        
        if let fileName = packet.fileName {
            payload["fileName"] = fileName
        }
        if let mimeType = packet.mimeType {
            payload["mimeType"] = mimeType
        }
        if let fileSize = packet.fileSize {
            payload["fileSize"] = fileSize
        }
        if let recipient = recipientPeerID {
            payload["recipient"] = recipient.id
        }
        
        guard let data = try? JSONSerialization.data(withJSONObject: payload),
              let base64 = data.base64EncodedString().addingPercentEncoding(withAllowedCharacters: .urlSafeBase64) else {
            return nil
        }
        
        return "bitchat1:\(base64)"
    }
    
    /// Decode a BitChat packet from XMTP message
    static func decode(_ content: String) -> [String: Any]? {
        guard content.hasPrefix("bitchat1:") else { return nil }
        
        let base64 = String(content.dropFirst(9))
        guard let decoded = base64.removingPercentEncoding,
              let data = Data(base64Encoded: decoded),
              let payload = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        
        return payload
    }
    
    /// Decode file content from a decoded payload
    static func decodeFilePacket(from payload: [String: Any]) -> BitchatFilePacket? {
        guard payload["type"] as? String == "file",
              let contentBase64 = payload["content"] as? String,
              let content = Data(base64Encoded: contentBase64) else {
            return nil
        }
        
        return BitchatFilePacket(
            fileName: payload["fileName"] as? String,
            fileSize: (payload["fileSize"] as? UInt64) ?? UInt64(content.count),
            mimeType: payload["mimeType"] as? String,
            content: content
        )
    }
}

// MARK: - Character Set Extension

extension CharacterSet {
    static let urlSafeBase64 = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_=")
}
