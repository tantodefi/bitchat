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
        case "/help":
            return handleHelp(args)
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
        // XMTP commands (bitchat originals — kept for backward compat)
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
        // ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
        // Unified XMTP CLI — full parity with @xmtp/cli via JSCore bridge
        // Usage: /xmtp <topic> <command> [args] [--flags]
        // Examples:
        //   /xmtp client info --json
        //   /xmtp conversations create-dm 0xABC
        //   /xmtp conversation send-text <id> "Hello!"
        //   /xmtp can-message 0xABC 0xDEF
        //   /xmtp conversations list --type dm --limit 10
        // ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
        case "/xmtp":
            return handleUnifiedXMTPCLI(args)
        // Legacy dash-separated aliases → route through unified engine
        case "/xmtp-can-message":
            return handleUnifiedXMTPCLI("can-message \(args)")
        case "/xmtp-client-info":
            return handleUnifiedXMTPCLI("client info \(args)")
        case "/xmtp-conversations-list":
            return handleUnifiedXMTPCLI("conversations list \(args)")
        case "/xmtp-conversations-create-dm":
            return handleUnifiedXMTPCLI("conversations create-dm \(args)")
        case "/xmtp-conversations-create-group":
            return handleUnifiedXMTPCLI("conversations create-group \(args)")
        case "/xmtp-conversations-get":
            return handleUnifiedXMTPCLI("conversations get \(args)")
        case "/xmtp-conversations-get-dm":
            return handleUnifiedXMTPCLI("conversations get-dm \(args)")
        case "/xmtp-conversations-get-message":
            return handleUnifiedXMTPCLI("conversations get-message \(args)")
        case "/xmtp-conversations-sync":
            return handleUnifiedXMTPCLI("conversations sync \(args)")
        case "/xmtp-conversations-sync-all":
            return handleXMTPSync()
        case "/xmtp-conversations-stream":
            return handleUnifiedXMTPCLI("conversations stream \(args)")
        case "/xmtp-conversations-stream-all-messages":
            return handleUnifiedXMTPCLI("conversations stream-all-messages \(args)")
        case "/xmtp-conversation-send-text":
            return handleUnifiedXMTPCLI("conversation send-text \(args)")
        case "/xmtp-conversation-send-markdown":
            return handleUnifiedXMTPCLI("conversation send-markdown \(args)")
        case "/xmtp-conversation-send-reply":
            return handleUnifiedXMTPCLI("conversation send-reply \(args)")
        case "/xmtp-conversation-send-reaction":
            return handleUnifiedXMTPCLI("conversation send-reaction \(args)")
        case "/xmtp-conversation-messages":
            return handleUnifiedXMTPCLI("conversation messages \(args)")
        case "/xmtp-conversation-count-messages":
            return handleUnifiedXMTPCLI("conversation count-messages \(args)")
        case "/xmtp-conversation-members":
            return handleUnifiedXMTPCLI("conversation members \(args)")
        case "/xmtp-conversation-add-members":
            return handleUnifiedXMTPCLI("conversation add-members \(args)")
        case "/xmtp-conversation-remove-members":
            return handleUnifiedXMTPCLI("conversation remove-members \(args)")
        case "/xmtp-conversation-consent-state":
            return handleUnifiedXMTPCLI("conversation consent-state \(args)")
        case "/xmtp-conversation-update-consent":
            return handleUnifiedXMTPCLI("conversation update-consent \(args)")
        case "/xmtp-conversation-stream":
            return handleUnifiedXMTPCLI("conversation stream \(args)")
        case "/xmtp-conversation-sync":
            return handleUnifiedXMTPCLI("conversation sync \(args)")
        case "/xmtp-conversation-publish-messages":
            return handleUnifiedXMTPCLI("conversation publish-messages \(args)")
        case "/xmtp-conversation-debug-info":
            return handleUnifiedXMTPCLI("conversation debug-info \(args)")
        case "/xmtp-conversation-permissions":
            return handleUnifiedXMTPCLI("conversation permissions \(args)")
        case "/xmtp-conversation-leave":
            return handleUnifiedXMTPCLI("conversation leave \(args)")
        case "/xmtp-conversation-update-name":
            return handleUnifiedXMTPCLI("conversation update-name \(args)")
        case "/xmtp-conversation-update-description":
            return handleUnifiedXMTPCLI("conversation update-description \(args)")
        case "/xmtp-conversation-update-image-url":
            return handleUnifiedXMTPCLI("conversation update-image-url \(args)")
        case "/xmtp-conversation-update-pinned-frame-url":
            return handleUnifiedXMTPCLI("conversation update-pinned-frame-url \(args)")
        case "/xmtp-preferences-get-consent":
            return handleUnifiedXMTPCLI("preferences get-consent \(args)")
        case "/xmtp-preferences-set-consent":
            return handleUnifiedXMTPCLI("preferences set-consent \(args)")
        case "/xmtp-preferences-inbox-state":
            return handleUnifiedXMTPCLI("preferences inbox-state \(args)")
        case "/xmtp-preferences-sync":
            return handleUnifiedXMTPCLI("preferences sync \(args)")
        case "/xmtp-preferences-stream":
            return handleUnifiedXMTPCLI("preferences stream \(args)")
        case "/xmtp-preferences-hmac-keys":
            return handleUnifiedXMTPCLI("preferences hmac-keys \(args)")
        case "/xmtp-client-sign":
            return handleUnifiedXMTPCLI("client sign \(args)")
        case "/xmtp-client-verify-signature":
            return handleUnifiedXMTPCLI("client verify-signature \(args)")
        default:
            return .error(message: "unknown command: \(cmd)\nType /help to see all commands.")
        }
    }

    // MARK: - Command Handlers

    private func handleHelp(_ args: String) -> CommandResult {
        let topic = args.trimmingCharacters(in: .whitespaces).lowercased()
            .replacingOccurrences(of: "/", with: "")

        // Per-command detailed help
        if !topic.isEmpty {
            return helpForCommand(topic)
        }

        // First-time tutorial / general help
        let tutorial = """
        👋 Welcome to bitchat!

        ━━ Quick Start ━━━━━━━━━━━━━━━━━━━━

        💬 Try messaging someone via XMTP:
          /dm-wallet anon3728.dstealth.eth
          /dm-wallet bankr.base.eth
          /dm-wallet xmtp-docs.eth

        💰 Check your wallet:
          /wallet

        👀 See who's around:
          /who

        ━━ Mesh Commands ━━━━━━━━━━━━━━━━━━

        /help [command]    show this help
        /dm  <nickname>    private message a mesh peer
        /who               list online peers
        /block <nickname>  block a peer
        /unblock <nick>    unblock a peer
        /fav <nickname>    add to favorites
        /unfav <nickname>  remove from favorites
        /hug <nickname>    hug someone 🫂
        /slap <nickname>   slap with a trout 🐟
        /clear             clear current chat

        ━━ XMTP Commands ━━━━━━━━━━━━━━━━━━

        /dm-wallet <addr>                  DM via ENS/wallet/inbox
        /xmtp                              XMTP CLI (full @xmtp/cli parity)
        /xmtp-list                         list conversations
        /xmtp-sync                         sync all conversations
        /wallet                            wallet balances
        /tx                                pending transactions

        ━━ XMTP CLI (via /xmtp <command>) ━━━

        /xmtp client info                  show identity & status
        /xmtp client sign <msg>            sign a message
        /xmtp can-message <addr>           check reachability
        /xmtp conversations list           list conversations
        /xmtp conversations create-dm      create a DM
        /xmtp conversations create-group   create a group
        /xmtp conversations get <id>       conversation details
        /xmtp conversations get-dm <addr>  find DM by address
        /xmtp conversations sync           sync conversations
        /xmtp conversation send-text       send text message
        /xmtp conversation send-markdown   send markdown message
        /xmtp conversation send-reply      reply to a message
        /xmtp conversation send-reaction   react to a message
        /xmtp conversation messages <id>   read messages
        /xmtp conversation count-messages  count messages
        /xmtp conversation members <id>    list members
        /xmtp conversation add-members     add to group
        /xmtp conversation remove-members  remove from group
        /xmtp conversation consent-state   get consent
        /xmtp conversation update-consent  set consent
        /xmtp conversation sync <id>       sync single conversation
        /xmtp conversation leave <id>      leave a group
        /xmtp conversation update-name     update group name
        /xmtp conversation permissions     view group permissions
        /xmtp preferences get-consent      get consent by entity
        /xmtp preferences set-consent      set consent by entity
        /xmtp preferences inbox-state      inbox details
        /xmtp preferences sync             sync preferences

        All /xmtp commands support --json for machine output.

        ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
        Tip: /help <command> for details.
        """
        return .success(message: tutorial)
    }

    private func helpForCommand(_ topic: String) -> CommandResult {
        switch topic {
        case "dm-wallet":
            return .success(message: """
            📖 /dm-wallet — Start an XMTP DM

            Send encrypted messages to anyone with an XMTP identity,
            using their ENS name, wallet address, or raw inbox ID.

            Usage:
              /dm-wallet alice.dstealth.eth   (ENS name)
              /dm-wallet vitalik.eth          (ENS name)
              /dm-wallet 0x1234…abcd          (42-char wallet)
              /dm-wallet <64-char-hex>        (inbox ID)

            Try it now:
              /dm-wallet anon3728.dstealth.eth
              /dm-wallet bankr.base.eth
              /dm-wallet xmtp-docs.eth

            Requires XMTP to be enabled in Settings.
            """)
        case "wallet":
            return .success(message: """
            📖 /wallet — Wallet Status

            Shows your wallet balances across all configured networks
            (Ethereum, Base, Arbitrum, or testnets).

            Usage:
              /wallet

            Use the Wallet view to send/receive funds.
            """)
        case "tx":
            return .success(message: """
            📖 /tx — Pending Transactions

            Lists transactions waiting to be confirmed or relayed.

            Usage:
              /tx
            """)
        case "dm", "msg", "m", "message":
            return .success(message: """
            📖 /dm — Private Mesh Message

            Start a private chat with a nearby mesh peer, or send
            a message directly.

            Usage:
              /dm @nickname            open private chat
              /dm @nickname hey there  send & open chat

            Also works as /msg or /m.
            """)
        case "who", "w":
            return .success(message: """
            📖 /who — Online Peers

            Lists peers currently visible on your mesh network
            or in the active geohash channel.

            Usage:
              /who

            Also works as /w.
            """)
        case "block":
            return .success(message: """
            📖 /block — Block a Peer

            Blocks a user so you no longer see their messages.
            Works for both mesh and geohash peers.

            Usage:
              /block @nickname   block a peer
              /block             list currently blocked peers
            """)
        case "unblock":
            return .success(message: """
            📖 /unblock — Unblock a Peer

            Removes a block so you can see their messages again.

            Usage:
              /unblock @nickname
            """)
        case "fav", "favorite":
            return .success(message: """
            📖 /fav — Favorite a Peer

            Adds a mesh peer to your favorites list. They'll get
            a notification and appear with a ⭐ indicator.

            Usage:
              /fav @nickname

            Only works for mesh peers in #mesh.
            """)
        case "unfav", "unfavorite":
            return .success(message: """
            📖 /unfav — Remove Favorite

            Removes a peer from your favorites list.

            Usage:
              /unfav @nickname
            """)
        case "hug":
            return .success(message: """
            📖 /hug — Hug Someone 🫂

            Send a hug emote to a peer in chat.

            Usage:
              /hug @nickname
            """)
        case "slap":
            return .success(message: """
            📖 /slap — Slap with a Trout 🐟

            The classic IRC move. Slaps a peer with a large trout.

            Usage:
              /slap @nickname
            """)
        case "clear":
            return .success(message: """
            📖 /clear — Clear Chat

            Clears messages in the current chat view (public
            timeline or active private chat).

            Usage:
              /clear
            """)
        case "xmtp":
            return .success(message: """
            📖 /xmtp — XMTP CLI (full @xmtp/cli parity)

            Unified XMTP command interface matching the official
            @xmtp/cli. Run subcommands with spaces, not dashes.

            Topics:
              client         identity & signing
              conversations  list, create, sync
              conversation   send, read, manage
              preferences    consent & inbox state

            Examples:
              /xmtp client info
              /xmtp can-message alice.eth
              /xmtp conversations list --type dm
              /xmtp conversations create-group --name "Team" 0xAddr
              /xmtp conversation send-text <id> Hello!
              /xmtp conversation messages <id> --limit 20
              /xmtp preferences inbox-state <inbox-id>

            All commands support --json for machine-readable output.
            Use /xmtp help for the full built-in command list.

            Legacy dash-separated aliases still work:
              /xmtp-can-message, /xmtp-conversations-list, etc.
            """)
        case "xmtp-sync":
            return .success(message: """
            📖 /xmtp-sync — Sync Conversations

            Forces a sync of all XMTP conversations from the
            network. Useful after reconnecting.

            Usage:
              /xmtp-sync
            """)
        case "xmtp-list":
            return .success(message: """
            📖 /xmtp-list — List Conversations

            Lists your active XMTP conversations with peer
            inbox IDs.

            Usage:
              /xmtp-list
            """)
        case "help":
            return .success(message: """
            📖 /help — Help & Tutorial

            Shows all available commands and a quick-start guide.
            Use /help <command> for detailed info on any command.

            Usage:
              /help            show all commands
              /help dm-wallet  learn about /dm-wallet
              /help wallet     learn about /wallet
            """)
        // ━━ XMTP CLI-compatible help entries ━━
        case "xmtp-can-message":
            return .success(message: """
            📖 /xmtp-can-message — Check Reachability

            Checks whether one or more addresses are reachable
            over XMTP (have registered identities).

            Usage:
              /xmtp-can-message 0x1234…abcd
              /xmtp-can-message alice.eth bob.eth
            """)
        case "xmtp-client-info":
            return .success(message: """
            📖 /xmtp-client-info — Client Info

            Alias for /xmtp. Shows wallet, inbox ID, and
            connection status.

            Usage:
              /xmtp-client-info
            """)
        case "xmtp-conversations-list":
            return .success(message: """
            📖 /xmtp-conversations-list — List Conversations

            Alias for /xmtp-list. Lists active XMTP conversations.

            Usage:
              /xmtp-conversations-list
            """)
        case "xmtp-conversations-create-dm":
            return .success(message: """
            📖 /xmtp-conversations-create-dm — Create DM

            Alias for /dm-wallet. Start a 1:1 XMTP DM.

            Usage:
              /xmtp-conversations-create-dm alice.eth
              /xmtp-conversations-create-dm 0x1234…abcd
            """)
        case "xmtp-conversations-create-group":
            return .success(message: """
            📖 /xmtp-conversations-create-group — Create Group

            Creates a new XMTP group conversation with one or
            more members (wallet addresses or ENS names).

            Usage:
              /xmtp-conversations-create-group 0xAddr1 0xAddr2
              /xmtp-conversations-create-group --name "Team" 0xAddr1

            Options:
              --name "Group Name"       set group name
              --description "About"     set group description
              --permissions admin       admin-only permissions
            """)
        case "xmtp-conversations-get":
            return .success(message: """
            📖 /xmtp-conversations-get — Get Conversation

            Looks up a conversation by its ID and shows details
            (type, members, consent state).

            Usage:
              /xmtp-conversations-get <conversation-id>
            """)
        case "xmtp-conversations-sync":
            return .success(message: """
            📖 /xmtp-conversations-sync — Light Sync

            Performs a light sync of conversations (metadata only).
            Use /xmtp-conversations-sync-all for a full sync.

            Usage:
              /xmtp-conversations-sync
            """)
        case "xmtp-conversations-sync-all":
            return .success(message: """
            📖 /xmtp-conversations-sync-all — Full Sync

            Alias for /xmtp-sync. Performs a full sync of all
            XMTP conversations and messages.

            Usage:
              /xmtp-conversations-sync-all
            """)
        case "xmtp-conversation-send-text":
            return .success(message: """
            📖 /xmtp-conversation-send-text — Send Message

            Sends a text message to a conversation by its ID.

            Usage:
              /xmtp-conversation-send-text <conv-id> <message>
            """)
        case "xmtp-conversation-messages":
            return .success(message: """
            📖 /xmtp-conversation-messages — Read Messages

            Lists recent messages in a conversation.

            Usage:
              /xmtp-conversation-messages <conv-id>
              /xmtp-conversation-messages <conv-id> --limit 20
            """)
        case "xmtp-conversation-members":
            return .success(message: """
            📖 /xmtp-conversation-members — List Members

            Shows members of a conversation (inbox IDs, permissions).

            Usage:
              /xmtp-conversation-members <conv-id>
            """)
        case "xmtp-conversation-add-members":
            return .success(message: """
            📖 /xmtp-conversation-add-members — Add Members

            Adds members to a group conversation by wallet address.

            Usage:
              /xmtp-conversation-add-members <conv-id> 0xAddr1 0xAddr2
            """)
        case "xmtp-conversation-remove-members":
            return .success(message: """
            📖 /xmtp-conversation-remove-members — Remove Members

            Removes members from a group by inbox ID.

            Usage:
              /xmtp-conversation-remove-members <conv-id> <inbox-id>
            """)
        case "xmtp-conversation-consent-state":
            return .success(message: """
            📖 /xmtp-conversation-consent-state — Get Consent

            Shows the consent state of a conversation (allowed,
            denied, or unknown).

            Usage:
              /xmtp-conversation-consent-state <conv-id>
            """)
        case "xmtp-conversation-update-consent":
            return .success(message: """
            📖 /xmtp-conversation-update-consent — Set Consent

            Updates consent state for a conversation.

            Usage:
              /xmtp-conversation-update-consent <conv-id> allowed
              /xmtp-conversation-update-consent <conv-id> denied
            """)
        case "xmtp-preferences-get-consent":
            return .success(message: """
            📖 /xmtp-preferences-get-consent — Get Consent by Entity

            Gets the consent state for an inbox ID or conversation ID.

            Usage:
              /xmtp-preferences-get-consent inbox <inbox-id>
              /xmtp-preferences-get-consent conversation <conv-id>
            """)
        case "xmtp-preferences-set-consent":
            return .success(message: """
            📖 /xmtp-preferences-set-consent — Set Consent by Entity

            Sets consent state for an inbox ID or conversation ID.

            Usage:
              /xmtp-preferences-set-consent inbox <id> allowed
              /xmtp-preferences-set-consent conversation <id> denied
            """)
        case "xmtp-preferences-inbox-state":
            return .success(message: """
            📖 /xmtp-preferences-inbox-state — Inbox State

            Shows detailed inbox state for one or more inbox IDs,
            including identities and installations.

            Usage:
              /xmtp-preferences-inbox-state <inbox-id>
              /xmtp-preferences-inbox-state <id1> <id2>
            """)
        case "xmtp-preferences-sync":
            return .success(message: """
            📖 /xmtp-preferences-sync — Sync Preferences

            Syncs XMTP consent/preference state from the network.

            Usage:
              /xmtp-preferences-sync
            """)
        default:
            return .error(message: "unknown command: /\(topic)\nType /help to see all commands.")
        }
    }

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
    
    // MARK: - Unified XMTP CLI (JavaScriptCore Bridge)
    
    /// Routes through the XMTPCLIEngine which uses JavaScriptCore for
    /// command parsing and JSON formatting, matching the official @xmtp/cli.
    /// The actual XMTP operations run against the native Swift SDK.
    private func handleUnifiedXMTPCLI(_ args: String) -> CommandResult {
        let input = args.trimmingCharacters(in: .whitespaces)
        
        // No args → show help
        if input.isEmpty {
            let help = XMTPCLIEngine.shared.helpText()
            return .success(message: help)
        }
        
        // Execute via the JSCore-backed engine
        Task {
            let output = await XMTPCLIEngine.shared.execute(input)
            
            // Check if --json was requested
            let isJSON = input.contains("--json")
            let message = isJSON ? output.json : output.human
            
            await MainActor.run {
                contextProvider?.addPublicSystemMessage(message)
            }
        }
        
        return .handled
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
    
    // MARK: - XMTP CLI-Compatible Handlers
    
    private func handleCanMessage(_ args: String) -> CommandResult {
        let input = args.trimmingCharacters(in: .whitespaces)
        guard !input.isEmpty else {
            return .error(message: "usage: /xmtp-can-message <address> [address2 …]")
        }
        guard XMTPServiceContainer.isConfigured, XMTPServiceContainer.shared.isInitialized else {
            return .error(message: "XMTP not connected")
        }
        
        let addresses = input.split(separator: " ").map(String.init)
        
        Task {
            do {
                let identities = addresses.map { PublicIdentity(kind: .ethereum, identifier: $0.lowercased()) }
                let results = try await XMTPServiceContainer.shared.clientService.canMessage(identities: identities)
                var output = "📡 Can-message results:\n"
                for addr in addresses {
                    let key = addr.lowercased()
                    let reachable = results[key] ?? false
                    output += "  \(addr.prefix(10))… → \(reachable ? "✅ reachable" : "❌ not on XMTP")\n"
                }
                await MainActor.run {
                    contextProvider?.addPublicSystemMessage(output)
                }
            } catch {
                await MainActor.run {
                    contextProvider?.addPublicSystemMessage("❌ can-message failed: \(error.localizedDescription)")
                }
            }
        }
        
        return .handled
    }
    
    private func handleCreateGroup(_ args: String) -> CommandResult {
        guard XMTPServiceContainer.isConfigured, XMTPServiceContainer.shared.isInitialized else {
            return .error(message: "XMTP not connected")
        }
        
        let input = args.trimmingCharacters(in: .whitespaces)
        guard !input.isEmpty else {
            return .error(message: "usage: /xmtp-conversations-create-group [--name \"N\"] [--description \"D\"] [--permissions admin] <addr1> [addr2 …]")
        }
        
        // Parse optional flags
        var tokens = input.components(separatedBy: " ")
        var name: String?
        var desc: String?
        var permissions: GroupPermissionPreconfiguration = .allMembers
        var addresses: [String] = []
        
        var i = 0
        while i < tokens.count {
            let t = tokens[i]
            if t == "--name", i + 1 < tokens.count {
                i += 1
                name = tokens[i].trimmingCharacters(in: CharacterSet(charactersIn: "\""))
            } else if t == "--description", i + 1 < tokens.count {
                i += 1
                desc = tokens[i].trimmingCharacters(in: CharacterSet(charactersIn: "\""))
            } else if t == "--permissions", i + 1 < tokens.count {
                i += 1
                if tokens[i].lowercased() == "admin" { permissions = .adminOnly }
            } else if !t.isEmpty {
                addresses.append(t)
            }
            i += 1
        }
        
        guard !addresses.isEmpty else {
            return .error(message: "provide at least one member address")
        }
        
        Task {
            do {
                let group = try await XMTPServiceContainer.shared.clientService.createGroup(
                    memberAddresses: addresses,
                    name: name,
                    description: desc,
                    permissions: permissions
                )
                let groupName = (try? group.name()) ?? "Unnamed"
                let label = groupName.isEmpty ? group.id.prefix(12) : Substring(groupName)
                await MainActor.run {
                    contextProvider?.addPublicSystemMessage("✅ Group created: \(label)\n  ID: \(group.id)")
                }
            } catch {
                await MainActor.run {
                    contextProvider?.addPublicSystemMessage("❌ Create group failed: \(error.localizedDescription)")
                }
            }
        }
        
        return .handled
    }
    
    private func handleConversationsGet(_ args: String) -> CommandResult {
        let convId = args.trimmingCharacters(in: .whitespaces)
        guard !convId.isEmpty else {
            return .error(message: "usage: /xmtp-conversations-get <conversation-id>")
        }
        guard XMTPServiceContainer.isConfigured, XMTPServiceContainer.shared.isInitialized else {
            return .error(message: "XMTP not connected")
        }
        
        Task {
            do {
                guard let conv = try await XMTPServiceContainer.shared.clientService.findConversation(conversationId: convId) else {
                    await MainActor.run {
                        contextProvider?.addPublicSystemMessage("⚠️ No conversation found for ID: \(convId.prefix(12))…")
                    }
                    return
                }
                
                let typeStr: String
                let detail: String
                switch conv {
                case .dm(let dm):
                    typeStr = "DM"
                    let peer = (try? dm.peerInboxId) ?? "unknown"
                    detail = "Peer: \(peer.prefix(12))…"
                case .group(let group):
                    typeStr = "Group"
                    let groupName = (try? group.name()) ?? "Unnamed"
                    let memberCount = (try? await group.members.count) ?? 0
                    detail = "Name: \(groupName.isEmpty ? "(none)" : groupName), Members: \(memberCount)"
                }
                let consent = (try? conv.consentState().rawValue) ?? "unknown"
                let output = "📋 Conversation \(convId.prefix(12))…\n  Type: \(typeStr)\n  \(detail)\n  Consent: \(consent)"
                
                await MainActor.run {
                    contextProvider?.addPublicSystemMessage(output)
                }
            } catch {
                await MainActor.run {
                    contextProvider?.addPublicSystemMessage("❌ Get conversation failed: \(error.localizedDescription)")
                }
            }
        }
        
        return .handled
    }
    
    private func handleConversationsLightSync() -> CommandResult {
        guard XMTPServiceContainer.isConfigured, XMTPServiceContainer.shared.isInitialized else {
            return .error(message: "XMTP not connected")
        }
        
        Task {
            do {
                try await XMTPServiceContainer.shared.clientService.conversationsSync()
                await MainActor.run {
                    contextProvider?.addPublicSystemMessage("✅ Conversations light sync complete")
                }
            } catch {
                await MainActor.run {
                    contextProvider?.addPublicSystemMessage("❌ Conversations sync failed: \(error.localizedDescription)")
                }
            }
        }
        
        return .handled
    }
    
    private func handleConversationSendText(_ args: String) -> CommandResult {
        let parts = args.split(separator: " ", maxSplits: 1, omittingEmptySubsequences: true)
        guard parts.count == 2 else {
            return .error(message: "usage: /xmtp-conversation-send-text <conversation-id> <message>")
        }
        let convId = String(parts[0])
        let text = String(parts[1])
        
        guard XMTPServiceContainer.isConfigured, XMTPServiceContainer.shared.isInitialized else {
            return .error(message: "XMTP not connected")
        }
        
        Task {
            do {
                guard let conv = try await XMTPServiceContainer.shared.clientService.findConversation(conversationId: convId) else {
                    await MainActor.run {
                        contextProvider?.addPublicSystemMessage("⚠️ Conversation not found: \(convId.prefix(12))…")
                    }
                    return
                }
                _ = try await conv.send(text: text)
                await MainActor.run {
                    contextProvider?.addPublicSystemMessage("✅ Sent to \(convId.prefix(12))…")
                }
            } catch {
                await MainActor.run {
                    contextProvider?.addPublicSystemMessage("❌ Send failed: \(error.localizedDescription)")
                }
            }
        }
        
        return .handled
    }
    
    private func handleConversationMessages(_ args: String) -> CommandResult {
        let tokens = args.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
        guard !tokens.isEmpty else {
            return .error(message: "usage: /xmtp-conversation-messages <conversation-id> [--limit N]")
        }
        let convId = tokens[0]
        var limit = 10
        if let idx = tokens.firstIndex(of: "--limit"), idx + 1 < tokens.count,
           let n = Int(tokens[idx + 1]) {
            limit = min(n, 50)
        }
        
        guard XMTPServiceContainer.isConfigured, XMTPServiceContainer.shared.isInitialized else {
            return .error(message: "XMTP not connected")
        }
        
        Task {
            do {
                guard let conv = try await XMTPServiceContainer.shared.clientService.findConversation(conversationId: convId) else {
                    await MainActor.run {
                        contextProvider?.addPublicSystemMessage("⚠️ Conversation not found: \(convId.prefix(12))…")
                    }
                    return
                }
                let msgs = try await conv.messages(limit: limit, direction: .descending)
                if msgs.isEmpty {
                    await MainActor.run {
                        contextProvider?.addPublicSystemMessage("📭 No messages in \(convId.prefix(12))…")
                    }
                    return
                }
                var output = "📨 Messages in \(convId.prefix(12))… (last \(msgs.count)):\n"
                for msg in msgs.reversed() {
                    let time = DateFormatter.localizedString(from: msg.sentAt, dateStyle: .none, timeStyle: .short)
                    let sender = String(msg.senderInboxId.prefix(8))
                    let body = (try? msg.body) ?? "(non-text)"
                    let preview = body.count > 80 ? String(body.prefix(80)) + "…" : body
                    output += "  [\(time)] \(sender)…: \(preview)\n"
                }
                await MainActor.run {
                    contextProvider?.addPublicSystemMessage(output)
                }
            } catch {
                await MainActor.run {
                    contextProvider?.addPublicSystemMessage("❌ Messages failed: \(error.localizedDescription)")
                }
            }
        }
        
        return .handled
    }
    
    private func handleConversationMembers(_ args: String) -> CommandResult {
        let convId = args.trimmingCharacters(in: .whitespaces)
        guard !convId.isEmpty else {
            return .error(message: "usage: /xmtp-conversation-members <conversation-id>")
        }
        guard XMTPServiceContainer.isConfigured, XMTPServiceContainer.shared.isInitialized else {
            return .error(message: "XMTP not connected")
        }
        
        Task {
            do {
                guard let conv = try await XMTPServiceContainer.shared.clientService.findConversation(conversationId: convId) else {
                    await MainActor.run {
                        contextProvider?.addPublicSystemMessage("⚠️ Conversation not found: \(convId.prefix(12))…")
                    }
                    return
                }
                let members = try await conv.members()
                var output = "👥 Members of \(convId.prefix(12))… (\(members.count)):\n"
                for member in members {
                    let permission: String
                    switch member.permissionLevel {
                    case .Member: permission = "member"
                    case .Admin: permission = "admin"
                    case .SuperAdmin: permission = "super-admin"
                    }
                    output += "  • \(member.inboxId.prefix(12))… [\(permission)]\n"
                }
                await MainActor.run {
                    contextProvider?.addPublicSystemMessage(output)
                }
            } catch {
                await MainActor.run {
                    contextProvider?.addPublicSystemMessage("❌ Members failed: \(error.localizedDescription)")
                }
            }
        }
        
        return .handled
    }
    
    private func handleConversationAddMembers(_ args: String) -> CommandResult {
        let tokens = args.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
        guard tokens.count >= 2 else {
            return .error(message: "usage: /xmtp-conversation-add-members <conversation-id> <addr1> [addr2 …]")
        }
        let convId = tokens[0]
        let addresses = Array(tokens.dropFirst())
        
        guard XMTPServiceContainer.isConfigured, XMTPServiceContainer.shared.isInitialized else {
            return .error(message: "XMTP not connected")
        }
        
        Task {
            do {
                guard let conv = try await XMTPServiceContainer.shared.clientService.findConversation(conversationId: convId) else {
                    await MainActor.run {
                        contextProvider?.addPublicSystemMessage("⚠️ Conversation not found: \(convId.prefix(12))…")
                    }
                    return
                }
                guard case .group(let group) = conv else {
                    await MainActor.run {
                        contextProvider?.addPublicSystemMessage("⚠️ add-members only works on group conversations")
                    }
                    return
                }
                let identities = addresses.map { PublicIdentity(kind: .ethereum, identifier: $0.lowercased()) }
                _ = try await group.addMembersByIdentity(identities: identities)
                await MainActor.run {
                    contextProvider?.addPublicSystemMessage("✅ Added \(addresses.count) member(s) to group \(convId.prefix(12))…")
                }
            } catch {
                await MainActor.run {
                    contextProvider?.addPublicSystemMessage("❌ Add members failed: \(error.localizedDescription)")
                }
            }
        }
        
        return .handled
    }
    
    private func handleConversationRemoveMembers(_ args: String) -> CommandResult {
        let tokens = args.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
        guard tokens.count >= 2 else {
            return .error(message: "usage: /xmtp-conversation-remove-members <conversation-id> <inbox-id> [inbox-id2 …]")
        }
        let convId = tokens[0]
        let inboxIds = Array(tokens.dropFirst())
        
        guard XMTPServiceContainer.isConfigured, XMTPServiceContainer.shared.isInitialized else {
            return .error(message: "XMTP not connected")
        }
        
        Task {
            do {
                guard let conv = try await XMTPServiceContainer.shared.clientService.findConversation(conversationId: convId) else {
                    await MainActor.run {
                        contextProvider?.addPublicSystemMessage("⚠️ Conversation not found: \(convId.prefix(12))…")
                    }
                    return
                }
                guard case .group(let group) = conv else {
                    await MainActor.run {
                        contextProvider?.addPublicSystemMessage("⚠️ remove-members only works on group conversations")
                    }
                    return
                }
                try await group.removeMembers(inboxIds: inboxIds)
                await MainActor.run {
                    contextProvider?.addPublicSystemMessage("✅ Removed \(inboxIds.count) member(s) from group \(convId.prefix(12))…")
                }
            } catch {
                await MainActor.run {
                    contextProvider?.addPublicSystemMessage("❌ Remove members failed: \(error.localizedDescription)")
                }
            }
        }
        
        return .handled
    }
    
    private func handleConversationConsentState(_ args: String) -> CommandResult {
        let convId = args.trimmingCharacters(in: .whitespaces)
        guard !convId.isEmpty else {
            return .error(message: "usage: /xmtp-conversation-consent-state <conversation-id>")
        }
        guard XMTPServiceContainer.isConfigured, XMTPServiceContainer.shared.isInitialized else {
            return .error(message: "XMTP not connected")
        }
        
        Task {
            do {
                guard let conv = try await XMTPServiceContainer.shared.clientService.findConversation(conversationId: convId) else {
                    await MainActor.run {
                        contextProvider?.addPublicSystemMessage("⚠️ Conversation not found: \(convId.prefix(12))…")
                    }
                    return
                }
                let state = try conv.consentState()
                await MainActor.run {
                    contextProvider?.addPublicSystemMessage("🔒 Consent for \(convId.prefix(12))…: \(state.rawValue)")
                }
            } catch {
                await MainActor.run {
                    contextProvider?.addPublicSystemMessage("❌ Consent state failed: \(error.localizedDescription)")
                }
            }
        }
        
        return .handled
    }
    
    private func handleConversationUpdateConsent(_ args: String) -> CommandResult {
        let tokens = args.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
        guard tokens.count == 2 else {
            return .error(message: "usage: /xmtp-conversation-update-consent <conversation-id> <allowed|denied|unknown>")
        }
        let convId = tokens[0]
        guard let state = parseConsentState(tokens[1]) else {
            return .error(message: "invalid consent state: \(tokens[1]). Use: allowed, denied, or unknown")
        }
        guard XMTPServiceContainer.isConfigured, XMTPServiceContainer.shared.isInitialized else {
            return .error(message: "XMTP not connected")
        }
        
        Task {
            do {
                guard let conv = try await XMTPServiceContainer.shared.clientService.findConversation(conversationId: convId) else {
                    await MainActor.run {
                        contextProvider?.addPublicSystemMessage("⚠️ Conversation not found: \(convId.prefix(12))…")
                    }
                    return
                }
                try await conv.updateConsentState(state: state)
                await MainActor.run {
                    contextProvider?.addPublicSystemMessage("✅ Consent updated to \(state.rawValue) for \(convId.prefix(12))…")
                }
            } catch {
                await MainActor.run {
                    contextProvider?.addPublicSystemMessage("❌ Update consent failed: \(error.localizedDescription)")
                }
            }
        }
        
        return .handled
    }
    
    private func handlePreferencesGetConsent(_ args: String) -> CommandResult {
        let tokens = args.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
        guard tokens.count == 2 else {
            return .error(message: "usage: /xmtp-preferences-get-consent <inbox|conversation> <id>")
        }
        guard let entityType = parseEntryType(tokens[0]) else {
            return .error(message: "invalid type: \(tokens[0]). Use: inbox or conversation")
        }
        let entityId = tokens[1]
        
        guard XMTPServiceContainer.isConfigured, XMTPServiceContainer.shared.isInitialized else {
            return .error(message: "XMTP not connected")
        }
        
        Task {
            do {
                let state = try await XMTPServiceContainer.shared.clientService.getConsentState(entityType: entityType, entity: entityId)
                await MainActor.run {
                    contextProvider?.addPublicSystemMessage("🔒 Consent for \(tokens[0]) \(entityId.prefix(12))…: \(state.rawValue)")
                }
            } catch {
                await MainActor.run {
                    contextProvider?.addPublicSystemMessage("❌ Get consent failed: \(error.localizedDescription)")
                }
            }
        }
        
        return .handled
    }
    
    private func handlePreferencesSetConsent(_ args: String) -> CommandResult {
        let tokens = args.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
        guard tokens.count == 3 else {
            return .error(message: "usage: /xmtp-preferences-set-consent <inbox|conversation> <id> <allowed|denied|unknown>")
        }
        guard let entityType = parseEntryType(tokens[0]) else {
            return .error(message: "invalid type: \(tokens[0]). Use: inbox or conversation")
        }
        let entityId = tokens[1]
        guard let state = parseConsentState(tokens[2]) else {
            return .error(message: "invalid consent state: \(tokens[2]). Use: allowed, denied, or unknown")
        }
        
        guard XMTPServiceContainer.isConfigured, XMTPServiceContainer.shared.isInitialized else {
            return .error(message: "XMTP not connected")
        }
        
        Task {
            do {
                try await XMTPServiceContainer.shared.clientService.setConsentState(entityType: entityType, entity: entityId, state: state)
                await MainActor.run {
                    contextProvider?.addPublicSystemMessage("✅ Consent set to \(state.rawValue) for \(tokens[0]) \(entityId.prefix(12))…")
                }
            } catch {
                await MainActor.run {
                    contextProvider?.addPublicSystemMessage("❌ Set consent failed: \(error.localizedDescription)")
                }
            }
        }
        
        return .handled
    }
    
    private func handlePreferencesInboxState(_ args: String) -> CommandResult {
        let input = args.trimmingCharacters(in: .whitespaces)
        guard !input.isEmpty else {
            return .error(message: "usage: /xmtp-preferences-inbox-state <inbox-id> [inbox-id2 …]")
        }
        let inboxIds = input.split(separator: " ").map(String.init)
        
        guard XMTPServiceContainer.isConfigured, XMTPServiceContainer.shared.isInitialized else {
            return .error(message: "XMTP not connected")
        }
        
        Task {
            do {
                let states = try await XMTPServiceContainer.shared.clientService.getInboxStates(inboxIds: inboxIds)
                if states.isEmpty {
                    await MainActor.run {
                        contextProvider?.addPublicSystemMessage("⚠️ No inbox states found")
                    }
                    return
                }
                var output = "📋 Inbox States (\(states.count)):\n"
                for state in states {
                    output += "  • Inbox: \(state.inboxId.prefix(12))…\n"
                    output += "    Identities: \(state.identities.count), Installations: \(state.installations.count)\n"
                    output += "    Recovery: \(state.recoveryIdentity.identifier.prefix(12))…\n"
                }
                await MainActor.run {
                    contextProvider?.addPublicSystemMessage(output)
                }
            } catch {
                await MainActor.run {
                    contextProvider?.addPublicSystemMessage("❌ Inbox state failed: \(error.localizedDescription)")
                }
            }
        }
        
        return .handled
    }
    
    private func handlePreferencesSync() -> CommandResult {
        guard XMTPServiceContainer.isConfigured, XMTPServiceContainer.shared.isInitialized else {
            return .error(message: "XMTP not connected")
        }
        
        Task {
            do {
                try await XMTPServiceContainer.shared.clientService.syncPreferences()
                await MainActor.run {
                    contextProvider?.addPublicSystemMessage("✅ Preferences synced")
                }
            } catch {
                await MainActor.run {
                    contextProvider?.addPublicSystemMessage("❌ Preferences sync failed: \(error.localizedDescription)")
                }
            }
        }
        
        return .handled
    }
    
    // MARK: - Consent / Entry Type Helpers
    
    private func parseConsentState(_ value: String) -> ConsentState? {
        switch value.lowercased() {
        case "allowed": return .allowed
        case "denied": return .denied
        case "unknown": return .unknown
        default: return nil
        }
    }
    
    private func parseEntryType(_ value: String) -> EntryType? {
        switch value.lowercased() {
        case "inbox", "inbox_id": return .inbox_id
        case "conversation", "conversation_id": return .conversation_id
        default: return nil
        }
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
        let network = balance.useTestnet ? "Sepolia & Arbitrum Sepolia Testnets" : "Ethereum, Base & Arbitrum Mainnet"
        
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
