//
// CommandProcessor.swift
// bitchat
//
// Handles command parsing and execution for BitChat
// This is free and unencumbered software released into the public domain.
//

import Foundation
import XMTP

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
        case "/tx":
            return handleTxStatus()
        case "/wallet":
            return handleWalletStatus()
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
        let input = args.trimmingCharacters(in: .whitespaces)
        
        guard !input.isEmpty else {
            return .error(message: """
                usage: /dm-wallet <inbox_id, wallet, or ens_name>
                
                Examples:
                  /dm-wallet alice.dstealth.eth
                  /dm-wallet vitalik.eth
                  /dm-wallet 0x1234...abcd (42 char wallet)
                  /dm-wallet 64charhexinboxid
                """)
        }
        
        guard XMTPServiceContainer.isConfigured, XMTPServiceContainer.shared.isInitialized else {
            return .error(message: "XMTP not connected. Check /xmtp status")
        }
        
        // Check if it's an ENS name
        if ENSResolver.looksLikeENSName(input) {
            return resolveENSAndStartDM(ensName: input)
        }
        
        // Check if it's a wallet address (0x...)
        if input.hasPrefix("0x") && input.count == 42 {
            return resolveWalletAndStartDM(walletAddress: input)
        }
        
        // Validate inbox ID format (64 char hex)
        guard input.count == 64, input.allSatisfy({ $0.isHexDigit }) else {
            return .error(message: "invalid input. Provide ENS (*.eth), wallet (0x...), or 64-char hex inbox ID")
        }
        
        // Start DM with inbox ID
        Task {
            await contextProvider?.startXMTPChat(with: input)
        }
        
        return .success(message: "opening XMTP DM with \(input.prefix(8))…")
    }
    
    private func resolveWalletAndStartDM(walletAddress: String) -> CommandResult {
        Task {
            do {
                let identity = PublicIdentity(kind: .ethereum, identifier: walletAddress.lowercased())
                if let inboxId = try await XMTPServiceContainer.shared.clientService.getInboxIdFromIdentity(identity: identity) {
                    await contextProvider?.startXMTPChat(with: inboxId)
                } else {
                    await MainActor.run {
                        contextProvider?.addPublicSystemMessage("⚠️ No XMTP identity found for wallet \(walletAddress.prefix(10))...")
                    }
                }
            } catch {
                await MainActor.run {
                    contextProvider?.addPublicSystemMessage("❌ Wallet lookup failed: \(error.localizedDescription)")
                }
            }
        }
        
        return .success(message: "looking up \(walletAddress.prefix(10))…")
    }
    
    private func resolveENSAndStartDM(ensName: String) -> CommandResult {
        Task {
            do {
                let resolution = try await ENSResolver.shared.resolve(ensName)
                
                if let inboxId = resolution.xmtpInboxId, !inboxId.isEmpty {
                    // Has XMTP inbox ID in ENS records - use that directly
                    await contextProvider?.startXMTPChat(with: inboxId)
                } else if !resolution.address.isEmpty {
                    // Has address but no inbox ID in records - try XMTP SDK lookup
                    let identity = PublicIdentity(kind: .ethereum, identifier: resolution.address.lowercased())
                    if let inboxId = try await XMTPServiceContainer.shared.clientService.getInboxIdFromIdentity(identity: identity) {
                        await contextProvider?.startXMTPChat(with: inboxId)
                    } else {
                        await MainActor.run {
                            contextProvider?.addPublicSystemMessage("⚠️ \(ensName) resolves to \(resolution.address.prefix(10))... but no XMTP identity found")
                        }
                    }
                } else {
                    await MainActor.run {
                        contextProvider?.addPublicSystemMessage("⚠️ \(ensName) has no address or XMTP inbox")
                    }
                }
            } catch {
                await MainActor.run {
                    contextProvider?.addPublicSystemMessage("❌ ENS resolution failed: \(error.localizedDescription)")
                }
            }
        }
        
        return .success(message: "resolving \(ensName)…")
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
    
    // MARK: - Transaction Commands
    
    private func handleTxStatus() -> CommandResult {
        guard XMTPServiceContainer.isConfigured, XMTPServiceContainer.shared.isInitialized else {
            return .error(message: "XMTP not connected. Enable XMTP in Settings first.")
        }
        
        let relay = XMTPServiceContainer.shared.meshTransactionRelay
        let pending = relay.pendingRelays
        
        if pending.isEmpty {
            return .success(message: "📋 No pending transactions.\nUse Wallet → Send to create a transaction.")
        }
        
        var status = "📋 Pending Transactions (\(pending.count)):\n"
        for (index, tx) in pending.prefix(5).enumerated() {
            let chainId = tx.payload.chainId
            let chainName = chainId == 1 ? "ETH" : (chainId == 11155111 ? "Sepolia" : "Chain \(chainId)")
            let desc = tx.payload.description ?? "Transaction"
            status += "  \(index + 1). \(desc) [\(chainName)]\n"
            status += "     Nonce: \(tx.payload.nonce), Gas: \(tx.payload.gasLimit), Status: \(tx.status.rawValue)\n"
        }
        if pending.count > 5 {
            status += "  … and \(pending.count - 5) more"
        }
        
        return .success(message: status)
    }
    
    private func handleWalletStatus() -> CommandResult {
        guard XMTPServiceContainer.isConfigured, XMTPServiceContainer.shared.isInitialized else {
            return .error(message: "XMTP/Wallet not connected. Enable XMTP in Settings first.")
        }
        
        let balance = XMTPServiceContainer.shared.balanceService
        let network = balance.useTestnet ? "Sepolia Testnet" : "Ethereum Mainnet"
        
        var status = "💰 Wallet Status\n"
        status += "  Network: \(network)\n"
        
        // Show balances
        let networks = balance.useTestnet ? EthereumBalanceService.Network.testnets : EthereumBalanceService.Network.mainnets
        for net in networks {
            if let bal = balance.balances[net] {
                status += "  \(net.rawValue): \(bal.formattedETH) ETH\n"
            }
        }
        
        status += "\nUse Wallet view to send/receive."
        
        return .success(message: status)
    }
    
}
