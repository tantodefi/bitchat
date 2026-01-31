//
// CommandProcessor.swift
// bitchat
//
// Handles command parsing and execution for BitChat
// This is free and unencumbered software released into the public domain.
//

import Foundation

/// Result of command processing
enum CommandResult {
    case success(message: String?)
    case error(message: String)
    case handled  // Command handled, no message needed
}

/// Simple struct for geo participant info used by CommandProcessor
struct CommandGeoParticipant {
    let id: String        // pubkey hex (lowercased)
    let displayName: String
}

/// Protocol defining what CommandProcessor needs from its context.
/// This breaks the circular dependency between CommandProcessor and ChatViewModel.
@MainActor
protocol CommandContextProvider: AnyObject {
    // MARK: - State Properties
    var nickname: String { get }
    var selectedPrivateChatPeer: PeerID? { get }
    var blockedUsers: Set<String> { get }
    var privateChats: [PeerID: [BitchatMessage]] { get set }
    var idBridge: NostrIdentityBridge { get }

    // MARK: - Peer Lookup
    func getPeerIDForNickname(_ nickname: String) -> PeerID?
    func getVisibleGeoParticipants() -> [CommandGeoParticipant]
    func nostrPubkeyForDisplayName(_ displayName: String) -> String?

    // MARK: - Chat Actions
    func startPrivateChat(with peerID: PeerID)
    func sendPrivateMessage(_ content: String, to peerID: PeerID)
    func clearCurrentPublicTimeline()
    func sendPublicRaw(_ content: String)

    // MARK: - System Messages
    func addLocalPrivateSystemMessage(_ content: String, to peerID: PeerID)
    func addPublicSystemMessage(_ content: String)

    // MARK: - Favorites
    func toggleFavorite(peerID: PeerID)
    func sendFavoriteNotification(to peerID: PeerID, isFavorite: Bool)
    
    // MARK: - XMTP Actions
    func startXMTPChat(with inboxId: String) async
}

/// Processes chat commands in a focused, efficient way
@MainActor
final class CommandProcessor {
    weak var contextProvider: CommandContextProvider?
    weak var meshService: Transport?
    private let identityManager: SecureIdentityStateManagerProtocol

    init(contextProvider: CommandContextProvider? = nil, meshService: Transport? = nil, identityManager: SecureIdentityStateManagerProtocol) {
        self.contextProvider = contextProvider
        self.meshService = meshService
        self.identityManager = identityManager
    }
    
    /// Process a command string
    @MainActor
    func process(_ command: String) -> CommandResult {
        let parts = command.split(separator: " ", maxSplits: 1, omittingEmptySubsequences: false)
        guard let cmd = parts.first else { return .error(message: "Invalid command") }
        let args = parts.count > 1 ? String(parts[1]) : ""
        
        // Geohash context: disable favoriting in public geohash or GeoDM
        let inGeoPublic: Bool = {
            switch LocationChannelManager.shared.selectedChannel {
            case .mesh: return false
            case .location: return true
            }
        }()
        let inGeoDM = contextProvider?.selectedPrivateChatPeer?.isGeoDM == true

        switch cmd {
        case "/m", "/msg":
            return handleMessage(args)
        case "/w", "/who":
            return handleWho()
        case "/clear":
            return handleClear()
        case "/hug":
            return handleEmote(args, command: "hug", action: "hugs", emoji: "🫂")
        case "/slap":
            return handleEmote(args, command: "slap", action: "slaps", emoji: "🐟", suffix: " around a bit with a large trout")
        case "/block":
            return handleBlock(args)
        case "/unblock":
            return handleUnblock(args)
        case "/fav":
            if inGeoPublic || inGeoDM { return .error(message: "favorites are only for mesh peers in #mesh") }
            return handleFavorite(args, add: true)
        case "/unfav":
            if inGeoPublic || inGeoDM { return .error(message: "favorites are only for mesh peers in #mesh") }
            return handleFavorite(args, add: false)
        case "/xmtp":
            return handleXMTPStatus()
        case "/dm-wallet":
            return handleDMWallet(args)
        case "/xmtp-sync":
            return handleXMTPSync()
        case "/xmtp-list":
            return handleXMTPList()
        default:
            return .error(message: "unknown command: \(cmd)")
        }
    }

    // MARK: - Command Handlers
    
    private func handleMessage(_ args: String) -> CommandResult {
        let parts = args.split(separator: " ", maxSplits: 1, omittingEmptySubsequences: false)
        guard !parts.isEmpty else {
            return .error(message: "usage: /msg @nickname [message]")
        }
        
        let targetName = String(parts[0])
        let nickname = targetName.hasPrefix("@") ? String(targetName.dropFirst()) : targetName
        
        guard let peerID = contextProvider?.getPeerIDForNickname(nickname) else {
            return .error(message: "'\(nickname)' not found")
        }

        contextProvider?.startPrivateChat(with: peerID)

        if parts.count > 1 {
            let message = String(parts[1])
            contextProvider?.sendPrivateMessage(message, to: peerID)
        }
        
        return .success(message: "started private chat with \(nickname)")
    }
    
    private func handleWho() -> CommandResult {
        // Show geohash participants when in a geohash channel; otherwise mesh peers
        switch LocationChannelManager.shared.selectedChannel {
        case .location(let ch):
            // Geohash context: show visible geohash participants (exclude self)
            guard let vm = contextProvider else { return .success(message: "nobody around") }
            let myHex = (try? vm.idBridge.deriveIdentity(forGeohash: ch.geohash))?.publicKeyHex.lowercased()
            let people = vm.getVisibleGeoParticipants().filter { person in
                if let me = myHex { return person.id.lowercased() != me }
                return true
            }
            let names = people.map { $0.displayName }
            if names.isEmpty { return .success(message: "no one else is online right now") }
            return .success(message: "online: " + names.sorted().joined(separator: ", "))
        case .mesh:
            // Mesh context: show connected peer nicknames
            guard let peers = meshService?.getPeerNicknames(), !peers.isEmpty else {
                return .success(message: "no one else is online right now")
            }
            let onlineList = peers.values.sorted().joined(separator: ", ")
            return .success(message: "online: \(onlineList)")
        }
    }
    
    private func handleClear() -> CommandResult {
        if let peerID = contextProvider?.selectedPrivateChatPeer {
            contextProvider?.privateChats[peerID]?.removeAll()
        } else {
            contextProvider?.clearCurrentPublicTimeline()
        }
        return .handled
    }
    
    private func handleEmote(_ args: String, command: String, action: String, emoji: String, suffix: String = "") -> CommandResult {
        let targetName = args.trimmingCharacters(in: .whitespaces)
        guard !targetName.isEmpty else {
            return .error(message: "usage: /\(command) <nickname>")
        }
        
        let nickname = targetName.hasPrefix("@") ? String(targetName.dropFirst()) : targetName
        
        guard let targetPeerID = contextProvider?.getPeerIDForNickname(nickname),
              let myNickname = contextProvider?.nickname else {
            return .error(message: "cannot \(command) \(nickname): not found")
        }
        
        let emoteContent = "* \(emoji) \(myNickname) \(action) \(nickname)\(suffix) *"
        
        if contextProvider?.selectedPrivateChatPeer != nil {
            // In private chat
            if let peerNickname = meshService?.peerNickname(peerID: targetPeerID) {
                let personalMessage = "* \(emoji) \(myNickname) \(action) you\(suffix) *"
                meshService?.sendPrivateMessage(personalMessage, to: targetPeerID,
                                               recipientNickname: peerNickname,
                                               messageID: UUID().uuidString)
                // Also add a local system message so the sender sees a natural-language confirmation
                let pastAction: String = {
                    switch action {
                    case "hugs": return "hugged"
                    case "slaps": return "slapped"
                    default: return action.hasSuffix("e") ? action + "d" : action + "ed"
                    }
                }()
                let localText = "\(emoji) you \(pastAction) \(nickname)\(suffix)"
                contextProvider?.addLocalPrivateSystemMessage(localText, to: targetPeerID)
            }
        } else {
            // In public chat: send to active public channel (mesh or geohash)
            contextProvider?.sendPublicRaw(emoteContent)
            let publicEcho = "\(emoji) \(myNickname) \(action) \(nickname)\(suffix)"
            contextProvider?.addPublicSystemMessage(publicEcho)
        }
        
        return .handled
    }
    
    private func handleBlock(_ args: String) -> CommandResult {
        let targetName = args.trimmingCharacters(in: .whitespaces)
        
        if targetName.isEmpty {
            // List blocked users (mesh) and geohash (Nostr) blocks
            let meshBlocked = contextProvider?.blockedUsers ?? []
            var blockedNicknames: [String] = []
            if let peers = meshService?.getPeerNicknames() {
                for (peerID, nickname) in peers {
                    if let fingerprint = meshService?.getFingerprint(for: peerID),
                       meshBlocked.contains(fingerprint) {
                        blockedNicknames.append(nickname)
                    }
                }
            }

            // Geohash blocked names (prefer visible display names; fallback to #suffix)
            let geoBlocked = Array(identityManager.getBlockedNostrPubkeys())
            var geoNames: [String] = []
            if let vm = contextProvider {
                let visible = vm.getVisibleGeoParticipants()
                let visibleIndex = Dictionary(uniqueKeysWithValues: visible.map { ($0.id.lowercased(), $0.displayName) })
                for pk in geoBlocked {
                    if let name = visibleIndex[pk.lowercased()] {
                        geoNames.append(name)
                    } else {
                        let suffix = String(pk.suffix(4))
                        geoNames.append("anon#\(suffix)")
                    }
                }
            }

            let meshList = blockedNicknames.isEmpty ? "none" : blockedNicknames.sorted().joined(separator: ", ")
            let geoList = geoNames.isEmpty ? "none" : geoNames.sorted().joined(separator: ", ")
            return .success(message: "blocked peers: \(meshList) | geohash blocks: \(geoList)")
        }
        
        let nickname = targetName.hasPrefix("@") ? String(targetName.dropFirst()) : targetName
        
        if let peerID = contextProvider?.getPeerIDForNickname(nickname),
           let fingerprint = meshService?.getFingerprint(for: peerID) {
            if identityManager.isBlocked(fingerprint: fingerprint) {
                return .success(message: "\(nickname) is already blocked")
            }
            // Block the user (mesh/noise identity)
            if var identity = identityManager.getSocialIdentity(for: fingerprint) {
                identity.isBlocked = true
                identity.isFavorite = false
                identityManager.updateSocialIdentity(identity)
            } else {
                let blockedIdentity = SocialIdentity(
                    fingerprint: fingerprint,
                    localPetname: nil,
                    claimedNickname: nickname,
                    trustLevel: .unknown,
                    isFavorite: false,
                    isBlocked: true,
                    notes: nil
                )
                identityManager.updateSocialIdentity(blockedIdentity)
            }
            return .success(message: "blocked \(nickname). you will no longer receive messages from them")
        }
        // Mesh lookup failed; try geohash (Nostr) participant by display name
        if let pub = contextProvider?.nostrPubkeyForDisplayName(nickname) {
            if identityManager.isNostrBlocked(pubkeyHexLowercased: pub) {
                return .success(message: "\(nickname) is already blocked")
            }
            identityManager.setNostrBlocked(pub, isBlocked: true)
            return .success(message: "blocked \(nickname) in geohash chats")
        }
        
        return .error(message: "cannot block \(nickname): not found or unable to verify identity")
    }
    
    private func handleUnblock(_ args: String) -> CommandResult {
        let targetName = args.trimmingCharacters(in: .whitespaces)
        guard !targetName.isEmpty else {
            return .error(message: "usage: /unblock <nickname>")
        }
        
        let nickname = targetName.hasPrefix("@") ? String(targetName.dropFirst()) : targetName
        
        if let peerID = contextProvider?.getPeerIDForNickname(nickname),
           let fingerprint = meshService?.getFingerprint(for: peerID) {
            if !identityManager.isBlocked(fingerprint: fingerprint) {
                return .success(message: "\(nickname) is not blocked")
            }
            identityManager.setBlocked(fingerprint, isBlocked: false)
            return .success(message: "unblocked \(nickname)")
        }
        // Try geohash unblock
        if let pub = contextProvider?.nostrPubkeyForDisplayName(nickname) {
            if !identityManager.isNostrBlocked(pubkeyHexLowercased: pub) {
                return .success(message: "\(nickname) is not blocked")
            }
            identityManager.setNostrBlocked(pub, isBlocked: false)
            return .success(message: "unblocked \(nickname) in geohash chats")
        }
        return .error(message: "cannot unblock \(nickname): not found")
    }
    
    private func handleFavorite(_ args: String, add: Bool) -> CommandResult {
        let targetName = args.trimmingCharacters(in: .whitespaces)
        guard !targetName.isEmpty else {
            return .error(message: "usage: /\(add ? "fav" : "unfav") <nickname>")
        }
        
        let nickname = targetName.hasPrefix("@") ? String(targetName.dropFirst()) : targetName
        
        guard let peerID = contextProvider?.getPeerIDForNickname(nickname),
              let noisePublicKey = Data(hexString: peerID.id) else {
            return .error(message: "can't find peer: \(nickname)")
        }
        
        if add {
            let existingFavorite = FavoritesPersistenceService.shared.getFavoriteStatus(for: noisePublicKey)
            FavoritesPersistenceService.shared.addFavorite(
                peerNoisePublicKey: noisePublicKey,
                peerNostrPublicKey: existingFavorite?.peerNostrPublicKey,
                peerNickname: nickname
            )
            
            contextProvider?.toggleFavorite(peerID: peerID)
            contextProvider?.sendFavoriteNotification(to: peerID, isFavorite: true)
            
            return .success(message: "added \(nickname) to favorites")
        } else {
            FavoritesPersistenceService.shared.removeFavorite(peerNoisePublicKey: noisePublicKey)
            
            contextProvider?.toggleFavorite(peerID: peerID)
            contextProvider?.sendFavoriteNotification(to: peerID, isFavorite: false)
            
            return .success(message: "removed \(nickname) from favorites")
        }
    }
    
    // MARK: - XMTP Commands
    
    private func handleXMTPStatus() -> CommandResult {
        guard XMTPServiceContainer.isConfigured else {
            return .error(message: "XMTP not configured")
        }
        
        let container = XMTPServiceContainer.shared
        
        guard container.isInitialized else {
            return .error(message: "XMTP not connected")
        }
        
        let inboxId = container.clientService.inboxId ?? "unknown"
        let isConnected = container.clientService.isConnected
        
        // Get wallet address asynchronously - we need to return sync, so fetch cached if available
        Task {
            if let address = try? await container.wallet.getAddress() {
                await MainActor.run {
                    contextProvider?.addPublicSystemMessage("📮 XMTP Status:\n• Wallet: \(address)\n• Inbox: \(inboxId.prefix(16))…\n• Connected: \(isConnected ? "✅" : "❌")")
                }
            }
        }
        
        return .handled
    }
    
    private func handleDMWallet(_ args: String) -> CommandResult {
        let inboxId = args.trimmingCharacters(in: .whitespaces)
        
        guard !inboxId.isEmpty else {
            return .error(message: "usage: /dm-wallet <inbox_id>\nGet inbox ID from recipient's /xmtp command")
        }
        
        // Validate inbox ID format (64 char hex)
        guard inboxId.count == 64, inboxId.allSatisfy({ $0.isHexDigit }) else {
            return .error(message: "invalid inbox ID format. Must be 64 hex characters")
        }
        
        guard XMTPServiceContainer.isConfigured, XMTPServiceContainer.shared.isInitialized else {
            return .error(message: "XMTP not connected. Check /xmtp status")
        }
        
        // Start DM asynchronously
        Task {
            await contextProvider?.startXMTPChat(with: inboxId)
        }
        
        return .success(message: "opening XMTP DM with \(inboxId.prefix(8))…")
    }
    
    private func handleXMTPSync() -> CommandResult {
        guard XMTPServiceContainer.isConfigured, XMTPServiceContainer.shared.isInitialized else {
            return .error(message: "XMTP not connected")
        }
        
        Task {
            do {
                try await XMTPServiceContainer.shared.clientService.syncAll()
                await MainActor.run {
                    contextProvider?.addPublicSystemMessage("✅ XMTP sync complete")
                }
            } catch {
                await MainActor.run {
                    contextProvider?.addPublicSystemMessage("❌ XMTP sync failed: \(error.localizedDescription)")
                }
            }
        }
        
        return .handled
    }
    
    private func handleXMTPList() -> CommandResult {
        guard XMTPServiceContainer.isConfigured, XMTPServiceContainer.shared.isInitialized else {
            return .error(message: "XMTP not connected")
        }
        
        Task {
            do {
                let conversations = try await XMTPServiceContainer.shared.clientService.listConversations()
                
                if conversations.isEmpty {
                    await MainActor.run {
                        contextProvider?.addPublicSystemMessage("📭 No XMTP conversations yet")
                    }
                } else {
                    var list = "📬 XMTP Conversations (\(conversations.count)):\n"
                    for (index, conv) in conversations.prefix(10).enumerated() {
                        let peerDisplay: String
                        if case .dm(let dm) = conv {
                            if let inboxId = try? dm.peerInboxId {
                                peerDisplay = "\(inboxId.prefix(8))…"
                            } else {
                                peerDisplay = "DM (unknown peer)"
                            }
                        } else if case .group(let group) = conv {
                            let groupName = (try? group.name()) ?? "Unnamed"
                            peerDisplay = groupName.isEmpty ? "Group \(group.id.prefix(8))…" : groupName
                        } else {
                            peerDisplay = "unknown"
                        }
                        list += "  \(index + 1). \(peerDisplay)\n"
                    }
                    if conversations.count > 10 {
                        list += "  … and \(conversations.count - 10) more"
                    }
                    await MainActor.run {
                        contextProvider?.addPublicSystemMessage(list)
                    }
                }
            } catch {
                await MainActor.run {
                    contextProvider?.addPublicSystemMessage("❌ Failed to list conversations: \(error.localizedDescription)")
                }
            }
        }
        
        return .handled
    }
    
}
