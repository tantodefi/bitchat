// ChatViewModel+XMTP.swift
// Bitchat
//
// XMTP integration for ChatViewModel

import Foundation
import BitLogger
import XMTP

// MARK: - XMTP Delegate

extension ChatViewModel: XMTPClientDelegate {
    
    /// Called when a text message is received via XMTP
    @MainActor
    func xmtpClient(_ client: XMTPClientService, didReceiveMessage content: String, from senderInboxId: String, messageId: String) {
        let peerID = PeerID(xmtp: senderInboxId)
        
        // Store the full inbox ID mapping so we can reply
        let truncatedId = peerID.bare
        if client.inboxIdMap[truncatedId] == nil {
            // Update the map via a Task since inboxIdMap is internal(set)
            Task {
                try? await XMTPServiceContainer.shared.clientService.findOrCreateDM(with: senderInboxId)
            }
        }
        
        // Initialize private chat if needed
        if privateChats[peerID] == nil {
            privateChats[peerID] = []
        }
        
        // Check for duplicate messages
        if privateChats[peerID]?.contains(where: { $0.id == messageId }) == true {
            return
        }
        
        // Create the message (incoming messages don't need delivery status)
        let message = BitchatMessage(
            id: messageId,
            sender: "XMTP:\(senderInboxId.prefix(8))…",
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
        // TODO: Handle Bitchat-specific packets (e.g., voice, media, encrypted payloads)
        SecureLogger.debug("📦 XMTP Bitchat packet from \(senderInboxId.prefix(8))… (\(packet.count) bytes)", category: .network)
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
        
        // Store the full inbox ID mapping so we can reply
        let truncatedId = peerID.bare
        if client.inboxIdMap[truncatedId] == nil {
            Task {
                try? await XMTPServiceContainer.shared.clientService.findOrCreateDM(with: senderInboxId)
            }
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
            
            let subdir = isImage ? "images/incoming" : (isVoice ? "voice/incoming" : "files/incoming")
            
            guard let baseDir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first else {
                SecureLogger.error("Failed to get documents directory", category: .session)
                return
            }
            
            let saveDir = baseDir.appendingPathComponent(subdir, isDirectory: true)
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
                
                // Save to outgoing folder for local display
                if let baseDir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first {
                    let saveDir = baseDir.appendingPathComponent("images/outgoing", isDirectory: true)
                    try? FileManager.default.createDirectory(at: saveDir, withIntermediateDirectories: true)
                    let saveURL = saveDir.appendingPathComponent(filename)
                    try? data.write(to: saveURL)
                }
                
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
                        self.privateChats[peerID]?[idx].deliveryStatus = .sent
                    }
                    self.objectWillChange.send()
                }
                
                // Cleanup processed file
                try? FileManager.default.removeItem(at: processedURL)
                
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
                
                // Save to outgoing folder for local display
                if let baseDir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first {
                    let saveDir = baseDir.appendingPathComponent("voice/outgoing", isDirectory: true)
                    try? FileManager.default.createDirectory(at: saveDir, withIntermediateDirectories: true)
                    let saveURL = saveDir.appendingPathComponent(filename)
                    try? data.write(to: saveURL)
                }
                
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
                        self.privateChats[peerID]?[idx].deliveryStatus = .sent
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
