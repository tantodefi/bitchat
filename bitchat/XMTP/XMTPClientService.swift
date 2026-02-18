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
    private var conversationStreamTask: Task<Void, Never>?
    
    @Published private(set) var isConnected = false
    @Published private(set) var inboxId: String?
    @Published private(set) var bootstrapProgress: Double = 0
    
    /// Whether the message stream is currently active (not nil and not cancelled)
    var isMessageStreamActive: Bool {
        guard let task = streamTask else { return false }
        return !task.isCancelled
    }
    
    /// Whether the conversation stream is currently active
    var isConversationStreamActive: Bool {
        guard let task = conversationStreamTask else { return false }
        return !task.isCancelled
    }
    
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
    
    // MARK: - Inbox ID Mapping
    
    /// Store a full inbox ID mapping for later lookup
    /// Call this when receiving messages from users to enable replying
    func storeInboxIdMapping(fullInboxId: String) {
        let truncated = String(fullInboxId.prefix(TransportConfig.nostrConvKeyPrefixLength))
        if inboxIdMap[truncated] == nil {
            inboxIdMap[truncated] = fullInboxId
            SecureLogger.debug("📇 Stored inbox ID mapping: \(truncated) → \(fullInboxId.prefix(20))…", category: .network)
        }
    }
    
    /// Resolve a full inbox ID from a truncated (16-char) prefix by scanning existing DMs.
    /// This is needed after app restart when the in-memory inboxIdMap is empty.
    func resolveFullInboxId(truncated: String) async -> String? {
        // Check map first
        if let cached = inboxIdMap[truncated] {
            return cached
        }
        
        guard let client = client else { return nil }
        
        // Scan all DMs (including denied) to find a matching peer inbox ID
        do {
            let dms = try client.conversations.listDms(consentStates: [.allowed, .unknown, .denied])
            for dm in dms {
                if let peerInbox = try? dm.peerInboxId {
                    let peerTruncated = String(peerInbox.prefix(TransportConfig.nostrConvKeyPrefixLength))
                    // Store mapping for future lookups
                    storeInboxIdMapping(fullInboxId: peerInbox)
                    if peerTruncated == truncated {
                        return peerInbox
                    }
                }
            }
        } catch {
            SecureLogger.debug("Failed to scan DMs for inbox ID resolution: \(error.localizedDescription)", category: .network)
        }
        
        return nil
    }
    
    // MARK: - Initialization
    
    init(keychain: KeychainManagerProtocol, wallet: EmbeddedWallet, identityBridge: XMTPIdentityBridge) {
        self.keychain = keychain
        self.wallet = wallet
        self.identityBridge = identityBridge
        loadSavedContacts()
    }
    
    deinit {
        streamTask?.cancel()
        conversationStreamTask?.cancel()
        periodicSyncTask?.cancel()
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
        
        // Register codecs for attachments, reactions, and read receipts before creating client
        Client.register(codec: AttachmentCodec())
        Client.register(codec: RemoteAttachmentCodec())
        Client.register(codec: ReadReceiptCodec())
        Client.register(codec: ReactionCodec())
        Client.register(codec: ReactionV2Codec())
        
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
        
        // Start message and conversation streaming
        startMessageStream()
        startConversationStream()
        startPeriodicSync()
    }
    
    /// Disconnect and cleanup
    func disconnect() {
        streamTask?.cancel()
        streamTask = nil
        conversationStreamTask?.cancel()
        conversationStreamTask = nil
        periodicSyncTask?.cancel()
        periodicSyncTask = nil
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
    
    /// Find or create a group conversation for location channels.
    ///
    /// **XMTP MLS Group Limitations**:
    /// - XMTP groups are invitation-based, not discovery-based
    /// - The `groupId` parameter is used for local matching only (stored in group name)
    /// - Groups cannot be "joined" by knowing their ID; members must be explicitly added
    /// - For true public location channels, consider using Nostr ephemeral events instead
    ///
    /// This implementation searches for existing groups by matching the name pattern,
    /// which allows reconnecting to previously created/joined groups.
    ///
    /// - Parameters:
    ///   - groupId: A deterministic identifier derived from the geohash (for matching)
    ///   - name: Human-readable group name
    /// - Returns: An existing or newly created Group
    func findOrCreateGroup(groupId: String, name: String) async throws -> Group {
        guard let client = client else {
            throw XMTPClientError.notConnected
        }
        
        // Try to find existing group by matching the group name
        // The name includes the geohash, so it serves as our discovery mechanism
        let groups = try await client.conversations.listGroups()
        for group in groups {
            // Match by name since XMTP group.id is an internal identifier
            // Names are formatted as "📍 Location: <geohash_prefix>"
            let groupName = try? group.name()
            if groupName == name {
                SecureLogger.debug("Found existing XMTP group for \(name)", category: .session)
                return group
            }
        }
        
        // Create new group with allMembers permission so any member can add others
        // This is crucial for open location-based groups
        SecureLogger.info("Creating new XMTP location group: \(name)", category: .session)
        return try await client.conversations.newGroup(
            with: [],
            permissions: .allMembers,  // Allow any member to add new members
            name: name
        )
    }
    
    /// Find a group by its XMTP internal ID
    /// Used when we know the exact group ID from a registry
    func findGroupById(_ groupId: String) async throws -> Group? {
        guard let client = client else {
            throw XMTPClientError.notConnected
        }
        
        let groups = try await client.conversations.listGroups()
        return groups.first { group in
            group.id == groupId
        }
    }
    
    /// Create a new open location group with allMembers permission
    /// - Parameters:
    ///   - name: Human-readable group name
    ///   - geohash: The geohash this group is for (stored in description)
    /// - Returns: The created Group and its ID
    func createOpenLocationGroup(name: String, geohash: String) async throws -> Group {
        guard let client = client else {
            throw XMTPClientError.notConnected
        }
        
        let description = "Open location channel for geohash: \(geohash)"
        
        // Create with allMembers permission - any member can add others
        let group = try await client.conversations.newGroup(
            with: [],
            permissions: .allMembers,
            name: name,
            description: description
        )
        
        SecureLogger.info("📍 Created open location group: \(name) (ID: \(group.id.prefix(16))…)", category: .session)
        return group
    }
    
    /// Add a member to a group by their inbox ID
    /// Requires appropriate permissions (allMembers or admin)
    func addMemberToGroup(_ group: Group, inboxId: String) async throws {
        _ = try await group.addMembers(inboxIds: [inboxId])
        let groupName = (try? group.name()) ?? "unnamed"
        SecureLogger.debug("Added member \(inboxId.prefix(12))... to group \(groupName)", category: .session)
    }
    
    /// List all groups the client is a member of
    func listGroups() async throws -> [Group] {
        guard let client = client else {
            throw XMTPClientError.notConnected
        }
        return try await client.conversations.listGroups()
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
        
        _ = try await dm.send(content: content)
        SecureLogger.debug("📤 Sent XMTP message to \(inboxId.prefix(8))…", category: .network)
    }
    
    /// Send a message to a DM conversation
    func sendMessage(_ content: String, to dm: Dm) async throws {
        _ = try await dm.send(content: content)
        SecureLogger.debug("📤 Sent XMTP message", category: .network)
    }
    
    /// Send a message to a conversation
    func sendMessage(_ content: String, to conversation: Conversation) async throws {
        _ = try await conversation.send(content: content)
        SecureLogger.debug("📤 Sent XMTP message", category: .network)
    }
    
    /// Send a BitChat packet as a custom content type
    func sendBitchatPacket(_ packet: Data, to dm: Dm) async throws {
        // Encode as base64 for text transport (custom codec will be added later)
        let encoded = "bitchat1:\(packet.base64EncodedString())"
        _ = try await dm.send(content: encoded)
        SecureLogger.debug("📤 Sent BitChat packet via XMTP", category: .network)
    }
    
    /// Send a transaction request
    func sendTransactionRequest(_ request: TransactionRequest, to dm: Dm) async throws {
        // Encode transaction request as JSON
        let encoder = JSONEncoder()
        let data = try encoder.encode(request)
        let content = "txreq:\(data.base64EncodedString())"
        _ = try await dm.send(content: content)
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
        _ = try await dm.send(
            content: remoteAttachment,
            options: .init(contentType: ContentTypeRemoteAttachment)
        )
        
        SecureLogger.debug("📤 Sent XMTP remote attachment: \(filename)", category: .network)
    }
    
    // MARK: - Message Streaming
    
    /// Maximum backoff delay for stream reconnection (60 seconds)
    private static let maxReconnectDelay: UInt64 = 60_000_000_000
    /// Periodic sync interval (90 seconds) to catch any missed messages
    private var periodicSyncTask: Task<Void, Never>?
    
    private func startMessageStream() {
        guard let client = client else { return }
        
        streamTask?.cancel()
        
        streamTask = Task { [weak self] in
            guard let self = self else { return }
            var backoff: UInt64 = 2_000_000_000 // Start at 2 seconds
            
            while !Task.isCancelled {
                do {
                    backoff = 2_000_000_000 // Reset backoff on successful connection
                    SecureLogger.debug("📡 XMTP message stream starting…", category: .network)
                    // Stream from both .allowed and .unknown so new inbound DMs are received
                    for try await message in await client.conversations.streamAllMessages(consentStates: [.allowed, .unknown]) {
                        await self.handleIncomingMessage(message)
                    }
                    // Stream ended cleanly (server closed) — reconnect
                    if !Task.isCancelled {
                        SecureLogger.info("📡 XMTP message stream ended, reconnecting…", category: .network)
                    }
                } catch {
                    if Task.isCancelled { return }
                    SecureLogger.error("XMTP stream error: \(error.localizedDescription) — retrying in \(backoff / 1_000_000_000)s", category: .network)
                    try? await Task.sleep(nanoseconds: backoff)
                    backoff = min(backoff * 2, Self.maxReconnectDelay)
                }
            }
        }
    }
    
    /// Stream new conversations and auto-allow incoming DMs so they appear in the conversation list
    private func startConversationStream() {
        guard let client = client else { return }
        
        conversationStreamTask?.cancel()
        
        conversationStreamTask = Task { [weak self] in
            guard let self = self else { return }
            var backoff: UInt64 = 2_000_000_000
            
            while !Task.isCancelled {
                do {
                    backoff = 2_000_000_000
                    SecureLogger.debug("📡 XMTP conversation stream starting…", category: .network)
                    for try await conversation in try await client.conversations.stream() {
                        // Auto-allow new incoming DMs so messages flow through the stream
                        if case .dm(let dm) = conversation {
                            let peerInboxId = try dm.peerInboxId
                            try? await client.preferences.setConsentState(
                                entries: [ConsentRecord(value: peerInboxId, entryType: .inbox_id, consentType: .allowed)]
                            )
                            SecureLogger.info("📬 New XMTP conversation auto-allowed: \(peerInboxId.prefix(8))…", category: .network)
                        }
                    }
                    if !Task.isCancelled {
                        SecureLogger.info("📡 XMTP conversation stream ended, reconnecting…", category: .network)
                    }
                } catch {
                    if Task.isCancelled { return }
                    SecureLogger.error("XMTP conversation stream error: \(error.localizedDescription) — retrying in \(backoff / 1_000_000_000)s", category: .network)
                    try? await Task.sleep(nanoseconds: backoff)
                    backoff = min(backoff * 2, Self.maxReconnectDelay)
                }
            }
        }
    }
    
    /// Start periodic sync to catch messages missed during stream drops
    private func startPeriodicSync() {
        periodicSyncTask?.cancel()
        
        periodicSyncTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 90_000_000_000) // 90 seconds
                guard !Task.isCancelled, let self = self else { return }
                do {
                    try await self.syncAll()
                } catch {
                    SecureLogger.debug("Periodic XMTP sync failed: \(error.localizedDescription)", category: .network)
                }
            }
        }
    }
    
    /// Restart message and conversation streams (callable from UI)
    func restartStreams() {
        SecureLogger.info("📡 Manually restarting XMTP streams", category: .network)
        startMessageStream()
        startConversationStream()
    }
    
    /// Get the conversation type and details for a given inbox ID
    /// Returns the conversation if found, nil otherwise
    func getConversationDetails(for inboxId: String) async throws -> Conversation? {
        guard let client = client else {
            throw XMTPClientError.notConnected
        }
        
        // Check DMs first — include .denied so consent changes are still reflected
        let dms = try client.conversations.listDms(consentStates: [.allowed, .unknown, .denied])
        for dm in dms {
            if let peerInbox = try? dm.peerInboxId, peerInbox == inboxId {
                return .dm(dm)
            }
        }
        
        // Check groups
        let groups = try await client.conversations.listGroups()
        for group in groups {
            let members = try await group.members
            if members.contains(where: { $0.inboxId == inboxId }) {
                return .group(group)
            }
        }
        
        return nil
    }
    
    private func handleIncomingMessage(_ message: DecodedMessage) async {
        // Filter out our own messages to prevent storing our own inbox ID in the map
        // This is critical - without it, replies would try to DM ourselves
        if let myInboxId = self.inboxId, message.senderInboxId == myInboxId {
            return
        }
        
        // Auto-allow the sender so future messages are streamed without issues
        // This handles the case where a message arrives with .unknown consent state
        if let client = self.client {
            try? await client.preferences.setConsentState(
                entries: [ConsentRecord(value: message.senderInboxId, entryType: .inbox_id, consentType: .allowed)]
            )
        }
        
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
            
            // Check for location_msg JSON format and extract just the content
            let displayContent = parseLocationMessageContent(textContent)
            
            // Regular text message
            delegate?.xmtpClient(self, didReceiveMessage: displayContent, from: message.senderInboxId, messageId: message.id)
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
            return
        }
        
        // Check for reaction content type
        if let reaction = try? message.content() as Reaction {
            let displayText: String
            switch reaction.action {
            case .added:
                displayText = "reacted \(reaction.content)"
            case .removed:
                displayText = "removed reaction \(reaction.content)"
            case .unknown:
                displayText = reaction.content
            }
            delegate?.xmtpClient(self, didReceiveMessage: displayText, from: message.senderInboxId, messageId: message.id)
            return
        }
        
        // Fallback: use the built-in fallback text for unknown content types
        if let fallbackText = try? message.fallback, !fallbackText.isEmpty {
            delegate?.xmtpClient(self, didReceiveMessage: fallbackText, from: message.senderInboxId, messageId: message.id)
            return
        }
        
        SecureLogger.debug("⚠️ Unhandled XMTP message content type from \(message.senderInboxId.prefix(8))…", category: .network)
    }
    
    /// Parse location message JSON format and extract just the content
    /// Returns original text if not a location message format
    private func parseLocationMessageContent(_ text: String) -> String {
        guard let data = text.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              json["type"] as? String == "location_msg",
              let content = json["content"] as? String else {
            return text
        }
        return content
    }
    
    // MARK: - Sync
    
    /// Sync all conversations and messages, then process any new messages
    func syncAll() async throws {
        guard let client = client else {
            throw XMTPClientError.notConnected
        }
        
        // Sync both allowed and unknown so new inbound conversations are discovered
        let summary = try await client.conversations.syncAllConversations(consentStates: [.allowed, .unknown])
        SecureLogger.debug("📥 Synced XMTP conversations: \(summary.numSynced)/\(summary.numEligible)", category: .network)
        
        // After syncing, process recent messages from all DMs
        // This catches messages that arrived while streams were disconnected
        do {
            let dms = try client.conversations.listDms(consentStates: [.allowed, .unknown])
            var totalNewMessages = 0
            
            for dm in dms {
                // Fetch the last few messages (limit 10 per convo) to process any missed ones
                let messages = try await dm.messages(
                    limit: 10,
                    direction: .descending
                )
                
                for message in messages {
                    // Only process messages from the last 5 minutes to avoid re-processing old ones
                    let fiveMinutesAgo = Date().addingTimeInterval(-300)
                    if message.sentAt > fiveMinutesAgo {
                        await handleIncomingMessage(message)
                        totalNewMessages += 1
                    }
                }
            }
            
            if totalNewMessages > 0 {
                SecureLogger.debug("📥 Processed \(totalNewMessages) recent messages after sync", category: .network)
            }
        } catch {
            SecureLogger.debug("📥 Error processing messages after sync: \(error.localizedDescription)", category: .network)
        }
        
        // Ensure streams are alive — restart if they were cancelled
        if streamTask == nil || streamTask?.isCancelled == true {
            SecureLogger.info("📡 Restarting message stream after sync", category: .network)
            startMessageStream()
        }
        if conversationStreamTask == nil || conversationStreamTask?.isCancelled == true {
            SecureLogger.info("📡 Restarting conversation stream after sync", category: .network)
            startConversationStream()
        }
    }
    
    // MARK: - User Consent
    
    /// Get wallet addresses associated with an inbox ID via XMTP identity lookup
    func getWalletAddresses(for inboxId: String) async throws -> [String] {
        guard let client = client else {
            throw XMTPClientError.notConnected
        }
        
        let states = try await client.inboxStatesForInboxIds(refreshFromNetwork: true, inboxIds: [inboxId])
        guard let state = states.first else { return [] }
        
        return state.identities.map { $0.identifier }
    }
    
    /// Resolve the ENS name for an inbox ID (checks .dstealth.eth, .base.eth, and .eth)
    func resolveDstealthName(for inboxId: String) async -> String? {
        do {
            let addresses = try await getWalletAddresses(for: inboxId)
            for address in addresses {
                // 1. Check Namestone for .dstealth.eth names
                if let records = try? await NamestoneService.shared.getNames(address: address),
                   let record = records.first {
                    return record.fullName
                }
                
                // 2. Check Basenames API for .base.eth reverse resolution
                if let baseName = try? await resolveBasename(for: address) {
                    return baseName
                }
                
                // 3. Check web3.bio for any ENS name (.eth)
                if let ensName = try? await resolveWeb3BioName(for: address) {
                    return ensName
                }
            }
        } catch {
            SecureLogger.debug("Failed to resolve ENS name for \(inboxId.prefix(8))…: \(error.localizedDescription)", category: .network)
        }
        return nil
    }
    
    /// Reverse resolve a .base.eth Basename from a wallet address
    private func resolveBasename(for address: String) async throws -> String? {
        guard let url = URL(string: "https://resolver-api.basename.app/address/\(address)") else {
            return nil
        }
        
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.addValue("application/json", forHTTPHeaderField: "Accept")
        request.timeoutInterval = 8
        
        let (data, response) = try await URLSession.shared.data(for: request)
        
        guard let httpResponse = response as? HTTPURLResponse,
              httpResponse.statusCode == 200 else {
            return nil
        }
        
        // Parse response - expects {"name": "something.base.eth"}
        if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let name = json["name"] as? String, !name.isEmpty {
            return name
        }
        
        return nil
    }
    
    /// Reverse resolve any ENS name from a wallet address via web3.bio
    private func resolveWeb3BioName(for address: String) async throws -> String? {
        guard let url = URL(string: "https://api.web3.bio/profile/\(address)") else {
            return nil
        }
        
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.addValue("application/json", forHTTPHeaderField: "Accept")
        request.timeoutInterval = 8
        
        let (data, response) = try await URLSession.shared.data(for: request)
        
        guard let httpResponse = response as? HTTPURLResponse,
              httpResponse.statusCode == 200 else {
            return nil
        }
        
        // Parse array of profiles and find first ENS identity
        if let profiles = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] {
            for profile in profiles {
                if let identity = profile["identity"] as? String,
                   identity.hasSuffix(".eth") {
                    return identity
                }
            }
        }
        
        return nil
    }
    
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
    
    // MARK: - CLI Parity Methods
    
    /// Check if one or more identities can receive XMTP messages
    /// Mirrors: `xmtp can-message <address>`
    func canMessage(identities: [PublicIdentity]) async throws -> [String: Bool] {
        guard let client = client else {
            throw XMTPClientError.notConnected
        }
        return try await client.canMessage(identities: identities)
    }
    
    /// Light sync — fetch new conversations without syncing all messages
    /// Mirrors: `xmtp conversations sync`
    func conversationsSync() async throws {
        guard let client = client else {
            throw XMTPClientError.notConnected
        }
        try await client.conversations.sync()
    }
    
    /// Find a conversation by its XMTP conversation ID (works for DMs and groups)
    /// Mirrors: `xmtp conversations get <id>`
    func findConversation(conversationId: String) async throws -> Conversation? {
        guard let client = client else {
            throw XMTPClientError.notConnected
        }
        return try await client.conversations.findConversation(conversationId: conversationId)
    }
    
    /// Remove a member from a group by their inbox ID
    /// Mirrors: `xmtp conversation remove-members`
    func removeMemberFromGroup(_ group: Group, inboxId: String) async throws {
        try await group.removeMembers(inboxIds: [inboxId])
        let groupName = (try? group.name()) ?? "unnamed"
        SecureLogger.debug("Removed member \(inboxId.prefix(12))... from group \(groupName)", category: .session)
    }
    
    /// Get inbox state for one or more inbox IDs (wallet addresses, installations, etc.)
    /// Mirrors: `xmtp preferences inbox-state`
    func getInboxStates(inboxIds: [String], refreshFromNetwork: Bool = true) async throws -> [InboxState] {
        guard let client = client else {
            throw XMTPClientError.notConnected
        }
        return try await client.inboxStatesForInboxIds(refreshFromNetwork: refreshFromNetwork, inboxIds: inboxIds)
    }
    
    /// Create a new group conversation with members specified by wallet addresses
    /// Mirrors: `xmtp conversations create-group <addr1> <addr2> --name "Name"`
    func createGroup(memberAddresses: [String], name: String? = nil, description: String? = nil, permissions: GroupPermissionPreconfiguration = .allMembers) async throws -> Group {
        guard let client = client else {
            throw XMTPClientError.notConnected
        }
        
        // Resolve wallet addresses to inbox IDs
        var memberInboxIds: [String] = []
        for address in memberAddresses {
            let identity = PublicIdentity(kind: .ethereum, identifier: address.lowercased())
            if let inboxId = try await client.inboxIdFromIdentity(identity: identity) {
                memberInboxIds.append(inboxId)
            } else {
                throw XMTPClientError.identityNotFound(address)
            }
        }
        
        let group = try await client.conversations.newGroup(
            with: memberInboxIds,
            permissions: permissions,
            name: name ?? "",
            description: description ?? ""
        )
        
        SecureLogger.info("Created group '\(name ?? "unnamed")' with \(memberInboxIds.count) members (ID: \(group.id.prefix(16))…)", category: .session)
        return group
    }
    
    /// Get consent state for an entity (inbox ID or conversation ID)
    /// Mirrors: `xmtp preferences get-consent`
    func getConsentState(entityType: EntryType, entity: String) async throws -> ConsentState {
        guard let client = client else {
            throw XMTPClientError.notConnected
        }
        switch entityType {
        case .inbox_id:
            return try await client.preferences.inboxIdState(inboxId: entity)
        case .conversation_id:
            return try await client.preferences.conversationState(conversationId: entity)
        }
    }
    
    /// Set consent state for an entity
    /// Mirrors: `xmtp preferences set-consent`
    func setConsentState(entityType: EntryType, entity: String, state: ConsentState) async throws {
        guard let client = client else {
            throw XMTPClientError.notConnected
        }
        try await client.preferences.setConsentState(
            entries: [ConsentRecord(value: entity, entryType: entityType, consentType: state)]
        )
    }
    
    /// Sync preferences (consent states, HMAC keys) from the network
    /// Mirrors: `xmtp preferences sync`
    func syncPreferences() async throws {
        guard let client = client else {
            throw XMTPClientError.notConnected
        }
        try await client.preferences.sync()
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
    
    // MARK: - Identity Lookup
    
    /// Look up an inbox ID from a wallet address or other identity
    /// - Parameter identity: The public identity (wallet address) to look up
    /// - Returns: The inbox ID if found, nil otherwise
    func getInboxIdFromIdentity(identity: PublicIdentity) async throws -> String? {
        guard let client = client else {
            throw XMTPClientError.notConnected
        }
        return try await client.inboxIdFromIdentity(identity: identity)
    }
    
    // MARK: - Read Receipts
    
    private static let readReceiptsKey = "enableReadReceipts"
    
    /// Enable or disable read receipts content type
    /// When disabled, the client won't send read receipt messages to conversation partners
    func setReadReceiptsEnabled(_ enabled: Bool) async {
        // Store the preference - this affects whether we send read receipts
        // The actual sending is controlled by the chat view when marking messages as read
        UserDefaults.standard.set(enabled, forKey: Self.readReceiptsKey)
        SecureLogger.info("XMTP: Read receipts \(enabled ? "enabled" : "disabled")", category: .network)
    }
    
    /// Check if read receipts are enabled (defaults to true if not set)
    /// This is nonisolated to allow checking from non-MainActor contexts (like XMTPTransport)
    nonisolated var readReceiptsEnabled: Bool {
        // If the key has never been set, default to true
        if UserDefaults.standard.object(forKey: Self.readReceiptsKey) == nil {
            return true
        }
        return UserDefaults.standard.bool(forKey: Self.readReceiptsKey)
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
    case identityNotFound(String)
    
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
        case .identityNotFound(let address):
            return "No XMTP identity found for \(address)"
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
        
        // If already saved, we can remove by matching truncated ID directly
        // This avoids the inboxIdMap lookup issue on app restart
        if let existing = savedContacts.first(where: { $0.truncatedId == truncated }) {
            removeContact(existing.id)
            return
        }
        
        // For adding: try inboxIdMap first, then extract from peerID.id
        if let fullId = inboxIdMap[truncated] {
            saveContact(fullId)
        } else {
            // PeerID.id is formatted as "xmtp_<fullInboxId>"
            let fullId = peerID.id.hasPrefix("xmtp_") ? String(peerID.id.dropFirst(5)) : peerID.id
            if !fullId.isEmpty {
                // Populate the map for future lookups
                storeInboxIdMapping(fullInboxId: fullId)
                saveContact(fullId)
            } else {
                SecureLogger.warning("Cannot toggle XMTP contact - inbox ID not resolvable: \(truncated)", category: .network)
            }
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
