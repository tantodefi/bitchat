//
// XMTPClientService.swift
// bitchat
//
// XMTP client wrapper with Tor proxy support and local database encryption.
// Manages XMTP client lifecycle, conversations, and message streaming.
//
// This is free and unencumbered software released into the public domain.
// For more information, see <https://unlicense.org>
//

import BitLogger
import Combine
import CryptoKit
import Foundation
import XMTP

/// Manages the XMTP client lifecycle with Tor integration.
@MainActor
final class XMTPClientService: ObservableObject {
    // MARK: - Properties
    
    private let keychain: KeychainManagerProtocol
    private let wallet: EmbeddedWallet
    private let identityBridge: XMTPIdentityBridge
    
    private var client: Client?
    private var streamTask: Task<Void, Never>?
    
    @Published private(set) var isConnected = false
    @Published private(set) var inboxId: String?
    @Published private(set) var bootstrapProgress: Double = 0
    
    // Cache of active DMs by inbox ID
    private var dmCache: [String: Dm] = [:]
    
    /// Maps truncated inbox IDs (16 chars) to full inbox IDs
    private(set) var inboxIdMap: [String: String] = [:]
    
    /// Saved XMTP contacts (starred conversations)
    @Published private(set) var savedContacts: [XMTPContact] = []
    
    // Database encryption key storage
    private let dbKeyName = "xmtp-db-encryption-key"
    private let keychainService = "chat.bitchat.xmtp"
    private let savedContactsKey = "xmtp-saved-contacts"
    
    // Delegate for incoming messages
    weak var delegate: XMTPClientDelegate?
    
    // MARK: - Initialization
    
    init(keychain: KeychainManagerProtocol, wallet: EmbeddedWallet, identityBridge: XMTPIdentityBridge) {
        self.keychain = keychain
        self.wallet = wallet
        self.identityBridge = identityBridge
        loadSavedContacts()
    }
    
    deinit {
        streamTask?.cancel()
    }
    
    // MARK: - Client Lifecycle
    
    /// Initialize and connect the XMTP client
    func connect() async throws {
        guard client == nil else {
            SecureLogger.debug("XMTP client already connected", category: .network)
            return
        }
        
        SecureLogger.info("🔗 Initializing XMTP client...", category: .network)
        bootstrapProgress = 0.1
        
        // Create signer from embedded wallet
        let address = try await wallet.getAddress()
        let signer = EmbeddedWalletSigner(wallet: wallet, address: address)
        bootstrapProgress = 0.3
        
        // Get or create database encryption key
        let dbKey = try getOrCreateDbEncryptionKey()
        bootstrapProgress = 0.4
        
        // Register codecs for attachments before creating client
        Client.register(codec: AttachmentCodec())
        Client.register(codec: RemoteAttachmentCodec())
        
        // Create XMTP client with encryption
        let xmtpClient = try await Client.create(
            account: signer,
            options: ClientOptions(
                api: ClientOptions.Api(env: .production, isSecure: true),
                dbEncryptionKey: dbKey
            )
        )
        bootstrapProgress = 0.8
        
        self.client = xmtpClient
        self.inboxId = xmtpClient.inboxID
        self.isConnected = true
        bootstrapProgress = 1.0
        
        // Store inbox ID in bridge
        identityBridge.storeInboxId(xmtpClient.inboxID)
        
        SecureLogger.info("✅ XMTP client connected. Inbox: \(xmtpClient.inboxID.prefix(16))…", category: .network)
        
        // Start message streaming
        startMessageStream()
    }
    
    /// Disconnect and cleanup
    func disconnect() {
        streamTask?.cancel()
        streamTask = nil
        client = nil
        isConnected = false
        inboxId = nil
        
        SecureLogger.info("🔌 XMTP client disconnected", category: .network)
    }
    
    // MARK: - Conversations
    
    /// Find or create a DM conversation with an inbox ID
    func findOrCreateDM(with recipientInboxId: String) async throws -> Dm {
        guard let client = client else {
            throw XMTPClientError.notConnected
        }
        
        let dm = try await client.conversations.findOrCreateDm(with: recipientInboxId)
        
        // Allow the contact so we receive their messages in the stream
        try? await client.preferences.setConsentState(
            entries: [ConsentRecord(value: recipientInboxId, entryType: .inbox_id, consentType: .allowed)]
        )
        
        // Cache the DM and store full inbox ID mapping
        dmCache[recipientInboxId] = dm
        let truncatedId = String(recipientInboxId.prefix(TransportConfig.nostrConvKeyPrefixLength))
        inboxIdMap[truncatedId] = recipientInboxId
        
        return dm
    }
    
    /// Create or join a group conversation
    func findOrCreateGroup(groupId: String, name: String) async throws -> Group {
        guard let client = client else {
            throw XMTPClientError.notConnected
        }
        
        // Try to find existing group first
        let groups = try await client.conversations.listGroups()
        for group in groups {
            if group.id == groupId {
                return group
            }
        }
        
        // Create new group (empty members, will be joined by others)
        return try await client.conversations.newGroup(with: [], name: name)
    }
    
    /// List all conversations
    func listConversations() async throws -> [Conversation] {
        guard let client = client else {
            throw XMTPClientError.notConnected
        }
        
        return try await client.conversations.list()
    }
    
    // MARK: - Messaging
    
    /// Send a message to an inbox ID, caching the DM for future use
    func sendMessage(_ content: String, toInboxId inboxId: String) async throws {
        // Get or create DM
        let dm: Dm
        if let cached = dmCache[inboxId] {
            dm = cached
        } else {
            dm = try await findOrCreateDM(with: inboxId)
            dmCache[inboxId] = dm
        }
        
        try await dm.send(content: content)
        SecureLogger.debug("📤 Sent XMTP message to \(inboxId.prefix(8))…", category: .network)
    }
    
    /// Send a message to a DM conversation
    func sendMessage(_ content: String, to dm: Dm) async throws {
        try await dm.send(content: content)
        SecureLogger.debug("📤 Sent XMTP message", category: .network)
    }
    
    /// Send a message to a conversation
    func sendMessage(_ content: String, to conversation: Conversation) async throws {
        try await conversation.send(content: content)
        SecureLogger.debug("📤 Sent XMTP message", category: .network)
    }
    
    /// Send a BitChat packet as a custom content type
    func sendBitchatPacket(_ packet: Data, to dm: Dm) async throws {
        // Encode as base64 for text transport (custom codec will be added later)
        let encoded = "bitchat1:\(packet.base64EncodedString())"
        try await dm.send(content: encoded)
        SecureLogger.debug("📤 Sent BitChat packet via XMTP", category: .network)
    }
    
    /// Send a transaction request
    func sendTransactionRequest(_ request: TransactionRequest, to dm: Dm) async throws {
        // Encode transaction request as JSON
        let encoder = JSONEncoder()
        let data = try encoder.encode(request)
        let content = "txreq:\(data.base64EncodedString())"
        try await dm.send(content: content)
        SecureLogger.debug("📤 Sent transaction request via XMTP", category: .network)
    }
    
    /// Send a remote attachment (image, voice note, etc.) to an inbox ID
    /// - Parameters:
    ///   - data: The file data to send
    ///   - filename: The filename
    ///   - mimeType: The MIME type (e.g., "image/jpeg", "audio/m4a")
    ///   - inboxId: The recipient inbox ID
    func sendRemoteAttachment(_ data: Data, filename: String, mimeType: String, toInboxId inboxId: String) async throws {
        // Get or create DM
        let dm: Dm
        if let cached = dmCache[inboxId] {
            dm = cached
        } else {
            dm = try await findOrCreateDM(with: inboxId)
            dmCache[inboxId] = dm
        }
        
        try await sendRemoteAttachment(data, filename: filename, mimeType: mimeType, to: dm)
    }
    
    /// Send a remote attachment to a DM
    func sendRemoteAttachment(_ data: Data, filename: String, mimeType: String, to dm: Dm) async throws {
        // Create attachment
        let attachment = Attachment(filename: filename, mimeType: mimeType, data: data)
        
        // Encrypt the attachment
        let encryptedContent = try RemoteAttachment.encodeEncrypted(content: attachment, codec: AttachmentCodec())
        
        // Upload to IPFS
        let url = try await IPFSUploadService.shared.upload(encryptedContent.payload, filename: filename)
        
        // Create remote attachment
        var remoteAttachment = try RemoteAttachment(url: url, encryptedEncodedContent: encryptedContent)
        remoteAttachment.contentLength = data.count
        remoteAttachment.filename = filename
        
        // Send via XMTP
        try await dm.send(
            content: remoteAttachment,
            options: .init(contentType: ContentTypeRemoteAttachment)
        )
        
        SecureLogger.debug("📤 Sent XMTP remote attachment: \(filename)", category: .network)
    }
    
    // MARK: - Message Streaming
    
    private func startMessageStream() {
        guard let client = client else { return }
        
        streamTask?.cancel()
        
        streamTask = Task { [weak self] in
            guard let self = self else { return }
            
            do {
                for try await message in await client.conversations.streamAllMessages(consentStates: [.allowed]) {
                    await self.handleIncomingMessage(message)
                }
            } catch {
                if !Task.isCancelled {
                    SecureLogger.error("XMTP stream error: \(error.localizedDescription)", category: .network)
                }
            }
        }
    }
    
    private func handleIncomingMessage(_ message: DecodedMessage) async {
        // Check if it's a BitChat packet
        if let textContent = try? message.content() as String? {
            if textContent.hasPrefix("bitchat1:") {
                // Decode BitChat packet
                let base64 = String(textContent.dropFirst(9))
                if let packetData = Data(base64Encoded: base64) {
                    delegate?.xmtpClient(self, didReceiveBitchatPacket: packetData, from: message.senderInboxId)
                    return
                }
            } else if textContent.hasPrefix("txreq:") {
                // Decode transaction request
                let base64 = String(textContent.dropFirst(6))
                if let data = Data(base64Encoded: base64),
                   let request = try? JSONDecoder().decode(TransactionRequest.self, from: data) {
                    delegate?.xmtpClient(self, didReceiveTransactionRequest: request, from: message.senderInboxId)
                    return
                }
            }
            
            // Regular text message
            delegate?.xmtpClient(self, didReceiveMessage: textContent, from: message.senderInboxId, messageId: message.id)
            return
        }
        
        // Check for remote attachment
        if let remoteAttachment = try? message.content() as RemoteAttachment {
            delegate?.xmtpClient(self, didReceiveRemoteAttachment: remoteAttachment, from: message.senderInboxId, messageId: message.id)
            return
        }
        
        // Check for inline attachment
        if let attachment = try? message.content() as Attachment {
            // Convert inline attachment to a "virtual" remote attachment for unified handling
            // Save to temp file and create a local URL
            SecureLogger.debug("📥 Received inline attachment: \(attachment.filename)", category: .network)
            // For now, just notify with a text message
            delegate?.xmtpClient(self, didReceiveMessage: "[attachment] \(attachment.filename)", from: message.senderInboxId, messageId: message.id)
        }
    }
    
    // MARK: - Sync
    
    /// Sync all conversations and messages
    func syncAll() async throws {
        guard let client = client else {
            throw XMTPClientError.notConnected
        }
        
        _ = try await client.conversations.syncAllConversations()
        SecureLogger.debug("📥 Synced all XMTP conversations", category: .network)
    }
    
    // MARK: - User Consent
    
    /// Allow a contact
    func allowContact(_ inboxId: String) async throws {
        guard let client = client else {
            throw XMTPClientError.notConnected
        }
        
        try await client.preferences.setConsentState(
            entries: [ConsentRecord(value: inboxId, entryType: .inbox_id, consentType: .allowed)]
        )
    }
    
    /// Block a contact
    func blockContact(_ inboxId: String) async throws {
        guard let client = client else {
            throw XMTPClientError.notConnected
        }
        
        try await client.preferences.setConsentState(
            entries: [ConsentRecord(value: inboxId, entryType: .inbox_id, consentType: .denied)]
        )
    }
    
    // MARK: - Private Helpers
    
    private func getOrCreateDbEncryptionKey() throws -> Data {
        if let existingKey = keychain.load(key: dbKeyName, service: keychainService) {
            return existingKey
        }
        
        // Generate 32-byte encryption key
        var key = Data(count: 32)
        let result = key.withUnsafeMutableBytes { ptr in
            SecRandomCopyBytes(kSecRandomDefault, 32, ptr.baseAddress!)
        }
        
        guard result == errSecSuccess else {
            throw XMTPClientError.keyGenerationFailed
        }
        
        keychain.save(
            key: dbKeyName,
            data: key,
            service: keychainService,
            accessible: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        )
        
        return key
    }
    
    /// Clear any corrupted XMTP databases from Documents directory
    /// This handles cases where a database was created with different encryption settings
    /// or where initialization failed previously
    private func clearCorruptedDatabasesIfNeeded() {
        let forceClearKey = "xmtp-force-db-clear"
        let shouldForceClear = UserDefaults.standard.bool(forKey: forceClearKey)
        
        guard shouldForceClear else {
            return
        }
        
        let fileManager = FileManager.default
        let documentsURL = fileManager.urls(for: .documentDirectory, in: .userDomainMask).first
        
        guard let documentsPath = documentsURL?.path else {
            SecureLogger.warning("XMTP: Could not find Documents directory", category: .network)
            return
        }
        
        do {
            let files = try fileManager.contentsOfDirectory(atPath: documentsPath)
            
            // Look for XMTP database files (they have pattern xmtp-*.db3 or contain "xmtp" and end with .db3)
            let xmtpFiles = files.filter { 
                ($0.hasPrefix("xmtp-") || $0.contains("xmtp")) && $0.hasSuffix(".db3")
            }
            
            for file in xmtpFiles {
                let filePath = (documentsPath as NSString).appendingPathComponent(file)
                do {
                    try fileManager.removeItem(atPath: filePath)
                    SecureLogger.info("XMTP: Cleared database: \(file)", category: .network)
                } catch {
                    SecureLogger.warning("XMTP: Failed to remove database \(file): \(error.localizedDescription)", category: .network)
                }
            }
            
            // Clear force clear flag
            UserDefaults.standard.removeObject(forKey: forceClearKey)
            
            // Also clear any existing encryption key so we generate fresh
            if !xmtpFiles.isEmpty {
                keychain.delete(key: dbKeyName, service: keychainService)
                SecureLogger.info("XMTP: Cleared encryption key for fresh start", category: .network)
            }
        } catch {
            SecureLogger.warning("XMTP: Failed to enumerate Documents directory: \(error.localizedDescription)", category: .network)
        }
    }
    
    /// Force a database reset on next connect (call this if XMTP fails to initialize)
    func forceResetDatabase() {
        UserDefaults.standard.set(true, forKey: "xmtp-force-db-clear")
        SecureLogger.info("XMTP: Scheduled database reset for next connect", category: .network)
    }
}

// MARK: - Delegate Protocol

@MainActor
protocol XMTPClientDelegate: AnyObject {
    func xmtpClient(_ client: XMTPClientService, didReceiveMessage content: String, from senderInboxId: String, messageId: String)
    func xmtpClient(_ client: XMTPClientService, didReceiveBitchatPacket packet: Data, from senderInboxId: String)
    func xmtpClient(_ client: XMTPClientService, didReceiveTransactionRequest request: TransactionRequest, from senderInboxId: String)
    func xmtpClient(_ client: XMTPClientService, didReceiveRemoteAttachment attachment: RemoteAttachment, from senderInboxId: String, messageId: String)
}

// MARK: - Errors

enum XMTPClientError: Error, LocalizedError {
    case notConnected
    case keyGenerationFailed
    case conversationNotFound
    case invalidMessage
    
    var errorDescription: String? {
        switch self {
        case .notConnected:
            return "XMTP client is not connected"
        case .keyGenerationFailed:
            return "Failed to generate database encryption key"
        case .conversationNotFound:
            return "Conversation not found"
        case .invalidMessage:
            return "Invalid message format"
        }
    }
}

// MARK: - Transaction Request Model

/// Represents an onchain transaction request (wallet_sendCalls)
struct TransactionRequest: Codable, Identifiable {
    let id: String
    let version: String
    let chainId: String
    let from: String
    let calls: [TransactionCall]
    let createdAt: Date
    
    init(chainId: String, from: String, calls: [TransactionCall]) {
        self.id = UUID().uuidString
        self.version = "1.0"
        self.chainId = chainId
        self.from = from
        self.calls = calls
        self.createdAt = Date()
    }
}

struct TransactionCall: Codable {
    let to: String
    let value: String?
    let data: String?
    let metadata: TransactionMetadata?
}

struct TransactionMetadata: Codable {
    let description: String?
    let transactionType: String?
    let currency: String?
    let amount: UInt64?
    let decimals: Int?
    let toAddress: String?
}

// MARK: - XMTP Contact Model

/// Represents a saved XMTP contact
struct XMTPContact: Codable, Identifiable, Equatable {
    let id: String  // Full inbox ID
    var nickname: String?
    let addedAt: Date
    
    var truncatedId: String {
        String(id.prefix(16))
    }
    
    var displayName: String {
        nickname ?? "XMTP:\(id.prefix(8))…"
    }
    
    var peerID: PeerID {
        PeerID(xmtp: id)
    }
}

// MARK: - XMTP Contact Management

extension XMTPClientService {
    
    /// Check if an inbox ID is saved as a contact
    func isContactSaved(_ inboxId: String) -> Bool {
        savedContacts.contains { $0.id == inboxId }
    }
    
    /// Check if a peer ID represents a saved contact
    func isContactSaved(peerID: PeerID) -> Bool {
        guard peerID.isXMTPDM else { return false }
        let truncated = peerID.bare
        return savedContacts.contains { $0.truncatedId == truncated }
    }
    
    /// Add a contact to saved list
    func saveContact(_ inboxId: String, nickname: String? = nil) {
        guard !isContactSaved(inboxId) else { return }
        
        let contact = XMTPContact(
            id: inboxId,
            nickname: nickname,
            addedAt: Date()
        )
        savedContacts.append(contact)
        persistSavedContacts()
        
        SecureLogger.info("⭐ Saved XMTP contact: \(inboxId.prefix(8))…", category: .network)
    }
    
    /// Remove a contact from saved list
    func removeContact(_ inboxId: String) {
        savedContacts.removeAll { $0.id == inboxId }
        persistSavedContacts()
        
        SecureLogger.info("⭐ Removed XMTP contact: \(inboxId.prefix(8))…", category: .network)
    }
    
    /// Toggle contact saved status
    func toggleContact(_ inboxId: String, nickname: String? = nil) {
        if isContactSaved(inboxId) {
            removeContact(inboxId)
        } else {
            saveContact(inboxId, nickname: nickname)
        }
    }
    
    /// Toggle contact by peer ID
    func toggleContact(peerID: PeerID) {
        guard peerID.isXMTPDM else { return }
        let truncated = peerID.bare
        
        // Look up full inbox ID
        if let fullId = inboxIdMap[truncated] {
            toggleContact(fullId)
        } else {
            SecureLogger.warning("Cannot toggle XMTP contact - inbox ID not in map: \(truncated)", category: .network)
        }
    }
    
    /// Update nickname for a contact
    func updateContactNickname(_ inboxId: String, nickname: String?) {
        if let idx = savedContacts.firstIndex(where: { $0.id == inboxId }) {
            savedContacts[idx].nickname = nickname
            persistSavedContacts()
        }
    }
    
    // MARK: - Persistence
    
    private func loadSavedContacts() {
        guard let data = UserDefaults.standard.data(forKey: savedContactsKey),
              let contacts = try? JSONDecoder().decode([XMTPContact].self, from: data) else {
            return
        }
        savedContacts = contacts
    }
    
    private func persistSavedContacts() {
        guard let data = try? JSONEncoder().encode(savedContacts) else { return }
        UserDefaults.standard.set(data, forKey: savedContactsKey)
    }
}
