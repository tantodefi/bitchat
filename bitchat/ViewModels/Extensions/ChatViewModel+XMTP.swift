// ChatViewModel+XMTP.swift
// Bitchat
//
// XMTP integration for ChatViewModel

import Foundation
import BitLogger
import XMTP

private func xmtpMediaFilesDirectoryURL() throws -> URL {
    let base = try FileManager.default.url(
        for: .applicationSupportDirectory,
        in: .userDomainMask,
        appropriateFor: nil,
        create: true
    )
    let filesDir = base.appendingPathComponent("files", isDirectory: true)
    try FileManager.default.createDirectory(at: filesDir, withIntermediateDirectories: true)
    return filesDir
}

// MARK: - XMTP Delegate

extension ChatViewModel: XMTPClientDelegate {
    
    /// Called when a text message is received via XMTP
    @MainActor
    func xmtpClient(_ client: XMTPClientService, didReceiveMessage content: String, from senderInboxId: String, messageId: String) {
        let peerID = PeerID(xmtp: senderInboxId)
        
        // IMMEDIATELY store the full inbox ID mapping so we can reply/star
        client.storeInboxIdMapping(fullInboxId: senderInboxId)
        
        // Also create/cache the DM conversation in background for faster replies
        Task {
            try? await XMTPServiceContainer.shared.clientService.findOrCreateDM(with: senderInboxId)
        }
        
        // Initialize private chat if needed
        if privateChats[peerID] == nil {
            privateChats[peerID] = []
        }
        
        // Check for duplicate messages
        if privateChats[peerID]?.contains(where: { $0.id == messageId }) == true {
            return
        }
        
        // Get display name from saved contacts if available
        let truncatedId = peerID.bare
        let senderDisplay: String = {
            if let contact = client.savedContacts.first(where: { $0.truncatedId == truncatedId }) {
                return contact.displayName
            }
            // Show short inbox ID
            return String(senderInboxId.prefix(8))
        }()
        
        // Create the message (incoming messages don't need delivery status)
        let message = BitchatMessage(
            id: messageId,
            sender: senderDisplay,
            content: content,
            timestamp: Date(),
            isRelay: false,
            isPrivate: true,
            recipientNickname: nickname,
            senderPeerID: peerID,
            deliveryStatus: nil
        )
        
        privateChats[peerID]?.append(message)
        
        // Mark as unread if not currently viewing this chat
        if selectedPrivateChatPeer != peerID {
            unreadPrivateMessages.insert(peerID)
        }
        
        objectWillChange.send()
        
        SecureLogger.debug("📥 XMTP message from \(senderInboxId.prefix(8))…", category: .network)
    }
    
    /// Called when a Bitchat packet is received via XMTP
    @MainActor
    func xmtpClient(_ client: XMTPClientService, didReceiveBitchatPacket packet: Data, from senderInboxId: String) {
        // Decode the BitChat packet
        guard let payload = try? JSONSerialization.jsonObject(with: packet) as? [String: Any] else {
            SecureLogger.debug("📦 XMTP Bitchat packet from \(senderInboxId.prefix(8))… (failed to decode)", category: .network)
            return
        }
        
        let type = payload["type"] as? String
        
        // Handle acknowledgment packets (delivered/read)
        if type == "ack", let ackType = payload["ackType"] as? String, let messageID = payload["messageID"] as? String {
            if ackType == "READ" {
                // Update message delivery status to read
                let readerNickname = (payload["senderNickname"] as? String) ?? String(senderInboxId.prefix(8))
                updateMessageDeliveryStatus(messageID, status: .read(by: readerNickname, at: Date()))
                SecureLogger.debug("📥 XMTP read receipt for \(messageID.prefix(8))… from \(senderInboxId.prefix(8))…", category: .network)
            } else if ackType == "DELIVERED" {
                // Update message delivery status to delivered
                let deliveredTo = (payload["senderNickname"] as? String) ?? String(senderInboxId.prefix(8))
                updateMessageDeliveryStatus(messageID, status: .delivered(to: deliveredTo, at: Date()))
                SecureLogger.debug("📥 XMTP delivered ack for \(messageID.prefix(8))… from \(senderInboxId.prefix(8))…", category: .network)
            }
            return
        }
        
        // Handle private message packets
        if type == "pm", let content = payload["content"] as? String {
            // This is handled by the main message delegate, but log for debugging
            SecureLogger.debug("📦 XMTP PM packet from \(senderInboxId.prefix(8))…: \(content.prefix(50))", category: .network)
            return
        }
        
        // Handle file/media packets
        if type == "file" {
            SecureLogger.debug("📦 XMTP file packet from \(senderInboxId.prefix(8))…", category: .network)
            // TODO: Handle file packets
            return
        }
        
        SecureLogger.debug("📦 XMTP Bitchat packet from \(senderInboxId.prefix(8))… (unknown type: \(type ?? "nil"))", category: .network)
    }
    
    /// Called when a transaction request is received via XMTP
    @MainActor
    func xmtpClient(_ client: XMTPClientService, didReceiveTransactionRequest request: TransactionRequest, from senderInboxId: String) {
        // TODO: Handle transaction requests (e.g., Bitcoin payments)
        SecureLogger.debug("💰 XMTP transaction request from \(senderInboxId.prefix(8))…", category: .network)
    }
    
    /// Called when a remote attachment is received via XMTP
    @MainActor
    func xmtpClient(_ client: XMTPClientService, didReceiveRemoteAttachment attachment: RemoteAttachment, from senderInboxId: String, messageId: String) {
        let peerID = PeerID(xmtp: senderInboxId)
        
        // IMMEDIATELY store the full inbox ID mapping so we can reply/star
        client.storeInboxIdMapping(fullInboxId: senderInboxId)
        
        // Also create/cache the DM conversation in background for faster replies
        Task {
            try? await XMTPServiceContainer.shared.clientService.findOrCreateDM(with: senderInboxId)
        }
        
        // Initialize private chat if needed
        if privateChats[peerID] == nil {
            privateChats[peerID] = []
        }
        
        // Check for duplicate messages
        if privateChats[peerID]?.contains(where: { $0.id == messageId }) == true {
            return
        }
        
        // Determine message content based on attachment type
        let filename = attachment.filename ?? "attachment"
        let isImage = filename.lowercased().hasSuffix(".jpg") || filename.lowercased().hasSuffix(".jpeg") || filename.lowercased().hasSuffix(".png")
        let isVoice = filename.lowercased().hasSuffix(".m4a") || filename.lowercased().hasSuffix(".mp3") || filename.lowercased().hasSuffix(".wav")
        
        let contentPrefix = isImage ? "[image]" : (isVoice ? "[voice]" : "[attachment]")
        
        // Create the message
        let message = BitchatMessage(
            id: messageId,
            sender: "XMTP:\(senderInboxId.prefix(8))…",
            content: "\(contentPrefix) \(filename)",
            timestamp: Date(),
            isRelay: false,
            isPrivate: true,
            recipientNickname: nickname,
            senderPeerID: peerID,
            deliveryStatus: nil
        )
        
        privateChats[peerID]?.append(message)
        
        // Mark as unread if not currently viewing this chat
        if selectedPrivateChatPeer != peerID {
            unreadPrivateMessages.insert(peerID)
        }
        
        objectWillChange.send()
        
        // Download and save the attachment in background
        Task {
            await downloadAndSaveRemoteAttachment(attachment, messageId: messageId, peerID: peerID)
        }
        
        SecureLogger.debug("📥 XMTP remote attachment from \(senderInboxId.prefix(8))…: \(filename)", category: .network)
    }
    
    /// Download and save a remote attachment to local storage
    private func downloadAndSaveRemoteAttachment(_ attachment: RemoteAttachment, messageId: String, peerID: PeerID) async {
        do {
            // Fetch and decrypt the attachment
            let encodedContent = try await attachment.content()
            let decodedAttachment = try AttachmentCodec().decode(content: encodedContent)
            
            // Determine storage directory
            let filename = decodedAttachment.filename
            let isImage = decodedAttachment.mimeType.hasPrefix("image/")
            let isVoice = decodedAttachment.mimeType.hasPrefix("audio/")
            
            let subdir = isImage ? "images/incoming" : (isVoice ? "voicenotes/incoming" : "files/incoming")
            let filesDir = try xmtpMediaFilesDirectoryURL()
            let saveDir = filesDir.appendingPathComponent(subdir, isDirectory: true)
            try FileManager.default.createDirectory(at: saveDir, withIntermediateDirectories: true)
            
            let fileURL = saveDir.appendingPathComponent(filename)
            try decodedAttachment.data.write(to: fileURL)
            
            SecureLogger.debug("📥 Saved XMTP attachment: \(filename)", category: .network)
            
        } catch {
            SecureLogger.error("Failed to download XMTP attachment: \(error)", category: .network)
        }
    }
}

// MARK: - XMTP Setup

extension ChatViewModel {

    /// Set up XMTP delegate when the service becomes available
    /// Call this after XMTPServiceContainer is initialized
    @MainActor
    func setupXMTPDelegate() {
        guard XMTPServiceContainer.isConfigured, XMTPServiceContainer.shared.isInitialized else {
            return
        }
        
        XMTPServiceContainer.shared.clientService.delegate = self
        SecureLogger.debug("📱 XMTP delegate set on ChatViewModel", category: .network)
    }
}

// MARK: - XMTP Media Sending

extension ChatViewModel {
    
    /// Send an image via XMTP to the current XMTP conversation
    @MainActor
    func sendXMTPImage(from sourceURL: URL, to peerID: PeerID) {
        guard XMTPServiceContainer.isConfigured, XMTPServiceContainer.shared.isInitialized else {
            addSystemMessage("❌ XMTP not connected")
            return
        }
        
        let truncatedId = peerID.bare
        guard let fullInboxId = XMTPServiceContainer.shared.clientService.inboxIdMap[truncatedId] else {
            addSystemMessage("❌ XMTP inbox ID not found")
            return
        }
        
        let messageID = UUID().uuidString
        
        // Create local message placeholder
        let message = BitchatMessage(
            id: messageID,
            sender: nickname,
            content: "[image] sending…",
            timestamp: Date(),
            isRelay: false,
            isPrivate: true,
            recipientNickname: "XMTP:\(truncatedId.prefix(8))…",
            senderPeerID: meshService.myPeerID,
            deliveryStatus: .sending
        )
        
        if privateChats[peerID] == nil {
            privateChats[peerID] = []
        }
        privateChats[peerID]?.append(message)
        objectWillChange.send()
        
        Task.detached(priority: .userInitiated) { [weak self] in
            guard let self = self else { return }
            
            do {
                // Process the image
                let processedURL = try ImageUtils.processImage(at: sourceURL)
                let data = try Data(contentsOf: processedURL)
                let filename = processedURL.lastPathComponent
                // `ImageUtils.processImage` already writes into Application Support/files/images/outgoing.
                // Keep this file for local chat rendering after upload.
                
                // Send via XMTP
                try await XMTPServiceContainer.shared.clientService.sendRemoteAttachment(
                    data,
                    filename: filename,
                    mimeType: "image/jpeg",
                    toInboxId: fullInboxId
                )
                
                // Update message status
                await MainActor.run {
                    if let idx = self.privateChats[peerID]?.firstIndex(where: { $0.id == messageID }) {
                        if let existing = self.privateChats[peerID]?[idx] {
                            let updated = BitchatMessage(
                                id: existing.id,
                                sender: existing.sender,
                                content: "[image] \(filename)",
                                timestamp: existing.timestamp,
                                isRelay: existing.isRelay,
                                originalSender: existing.originalSender,
                                isPrivate: existing.isPrivate,
                                recipientNickname: existing.recipientNickname,
                                senderPeerID: existing.senderPeerID,
                                mentions: existing.mentions,
                                deliveryStatus: .sent
                            )
                            self.privateChats[peerID]?[idx] = updated
                        }
                    }
                    self.objectWillChange.send()
                }
                
            } catch {
                await MainActor.run {
                    if let idx = self.privateChats[peerID]?.firstIndex(where: { $0.id == messageID }) {
                        self.privateChats[peerID]?[idx].deliveryStatus = .failed(reason: error.localizedDescription)
                    }
                    self.objectWillChange.send()
                }
                SecureLogger.error("XMTP image send failed: \(error)", category: .network)
            }
        }
    }
    
    /// Send a voice note via XMTP to the current XMTP conversation
    @MainActor
    func sendXMTPVoiceNote(from sourceURL: URL, to peerID: PeerID) {
        let minimumVoiceBytes = 1024
        guard XMTPServiceContainer.isConfigured, XMTPServiceContainer.shared.isInitialized else {
            addSystemMessage("❌ XMTP not connected")
            return
        }
        
        let truncatedId = peerID.bare
        guard let fullInboxId = XMTPServiceContainer.shared.clientService.inboxIdMap[truncatedId] else {
            addSystemMessage("❌ XMTP inbox ID not found")
            return
        }
        
        let messageID = UUID().uuidString
        let filename = sourceURL.lastPathComponent
        
        // Create local message placeholder
        let message = BitchatMessage(
            id: messageID,
            sender: nickname,
            content: "[voice] sending…",
            timestamp: Date(),
            isRelay: false,
            isPrivate: true,
            recipientNickname: "XMTP:\(truncatedId.prefix(8))…",
            senderPeerID: meshService.myPeerID,
            deliveryStatus: .sending
        )
        
        if privateChats[peerID] == nil {
            privateChats[peerID] = []
        }
        privateChats[peerID]?.append(message)
        objectWillChange.send()
        
        Task.detached(priority: .userInitiated) { [weak self] in
            guard let self = self else { return }
            
            do {
                let data = try Data(contentsOf: sourceURL)
                guard data.count >= minimumVoiceBytes else {
                    throw NSError(
                        domain: "chat.bitchat.xmtp",
                        code: 1001,
                        userInfo: [NSLocalizedDescriptionKey: "Voice note is empty or too short"]
                    )
                }
                
                // Save to canonical app files folder for local display
                let filesDir = try xmtpMediaFilesDirectoryURL()
                let saveDir = filesDir.appendingPathComponent("voicenotes/outgoing", isDirectory: true)
                try FileManager.default.createDirectory(at: saveDir, withIntermediateDirectories: true)
                let saveURL = saveDir.appendingPathComponent(filename)
                try data.write(to: saveURL)
                
                // Send via XMTP
                try await XMTPServiceContainer.shared.clientService.sendRemoteAttachment(
                    data,
                    filename: filename,
                    mimeType: "audio/m4a",
                    toInboxId: fullInboxId
                )
                
                // Update message status
                await MainActor.run {
                    if let idx = self.privateChats[peerID]?.firstIndex(where: { $0.id == messageID }) {
                        if let existing = self.privateChats[peerID]?[idx] {
                            let updated = BitchatMessage(
                                id: existing.id,
                                sender: existing.sender,
                                content: "[voice] \(filename)",
                                timestamp: existing.timestamp,
                                isRelay: existing.isRelay,
                                originalSender: existing.originalSender,
                                isPrivate: existing.isPrivate,
                                recipientNickname: existing.recipientNickname,
                                senderPeerID: existing.senderPeerID,
                                mentions: existing.mentions,
                                deliveryStatus: .sent
                            )
                            self.privateChats[peerID]?[idx] = updated
                        }
                    }
                    self.objectWillChange.send()
                }
                
            } catch {
                await MainActor.run {
                    if let idx = self.privateChats[peerID]?.firstIndex(where: { $0.id == messageID }) {
                        self.privateChats[peerID]?[idx].deliveryStatus = .failed(reason: error.localizedDescription)
                    }
                    self.objectWillChange.send()
                }
                SecureLogger.error("XMTP voice note send failed: \(error)", category: .network)
            }
        }
    }
}

// MARK: - XMTP Location Channels Delegate

extension ChatViewModel: XMTPLocationChannelsDelegate {
    
    /// Called when a message is received on an XMTP location channel
    @MainActor
    func locationChannels(_ service: XMTPLocationChannels, didReceiveMessage message: XMTPLocationChannels.LocationMessage) {
        // Ignore our own messages
        if let myInboxId = XMTPServiceContainer.shared.clientService.inboxId,
           message.senderInboxId == myInboxId {
            return
        }
        
        // Find the matching geohash channel
        guard let channel = LocationChannelManager.shared.availableChannels.first(where: { $0.geohash == message.geohash }) else {
            SecureLogger.debug("XMTP geo: received message for unknown geohash \(message.geohash)", category: .network)
            return
        }
        
        // Check for duplicates
        if deduplicationService.hasProcessedXMTPMessage(message.id) {
            return
        }
        deduplicationService.recordXMTPMessage(message.id)
        
        // IMMEDIATELY store the full inbox ID mapping so we can DM/star this sender
        // This must happen synchronously before any UI interaction
        XMTPServiceContainer.shared.clientService.storeInboxIdMapping(fullInboxId: message.senderInboxId)
        
        // Also create/cache the DM conversation in background for faster replies
        Task {
            try? await XMTPServiceContainer.shared.clientService.findOrCreateDM(with: message.senderInboxId)
        }
        
        // Create sender display name - use nickname if provided, otherwise shortened inbox ID
        let truncatedId = String(message.senderInboxId.prefix(16))
        let senderDisplay: String = {
            if let nickname = message.senderNickname, !nickname.isEmpty {
                return nickname
            }
            // Check if we have this contact saved with a nickname
            if let contact = XMTPServiceContainer.shared.clientService.savedContacts.first(where: { $0.truncatedId == truncatedId }) {
                return contact.displayName
            }
            return String(message.senderInboxId.prefix(8))
        }()
        let senderPeerID = PeerID(xmtp: message.senderInboxId)
        
        // Create BitchatMessage
        let bitchatMessage = BitchatMessage(
            id: message.id,
            sender: senderDisplay,
            content: message.content,
            timestamp: message.timestamp,
            isRelay: false,
            senderPeerID: senderPeerID
        )
        
        // Add to timeline
        let channelID = ChannelID.location(channel)
        timelineStore.append(bitchatMessage, to: channelID)
        
        // Update visible messages if this is the active channel
        if activeChannel == channelID {
            refreshVisibleMessages(from: channelID)
        }
        
        // Track participant
        participantTracker.recordXMTPParticipant(inboxId: message.senderInboxId, nickname: message.senderNickname)
        
        SecureLogger.debug("📍 XMTP geo message in \(message.geohash): \(message.content.prefix(30))…", category: .network)
    }
    
    /// Called when an XMTP location channel is updated
    @MainActor
    func locationChannels(_ service: XMTPLocationChannels, didUpdateChannel channel: XMTPLocationChannels.LocationChannel) {
        SecureLogger.debug("📍 XMTP geo channel updated: \(channel.geohash) (\(channel.memberCount) members)", category: .session)
    }
}
