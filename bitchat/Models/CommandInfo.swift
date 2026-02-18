//
// CommandsInfo.swift
// bitchat
//
// This is free and unencumbered software released into the public domain.
// For more information, see <https://unlicense.org>
//

import Foundation

// MARK: - CommandInfo Enum

enum CommandInfo: String, Identifiable {
    case help
    case block
    case clear
    case hug
    case message = "dm"
    case slap
    case unblock
    case who
    case favorite
    case unfavorite
    // XMTP commands
    case xmtp
    case dmWallet = "dm-wallet"
    case xmtpSync = "xmtp-sync"
    case xmtpList = "xmtp-list"
    // Wallet commands
    case tx
    case wallet
    // XMTP CLI-compatible commands
    case xmtpCanMessage = "xmtp-can-message"
    case xmtpClientInfo = "xmtp-client-info"
    case xmtpConversationsList = "xmtp-conversations-list"
    case xmtpConversationsCreateDm = "xmtp-conversations-create-dm"
    case xmtpConversationsCreateGroup = "xmtp-conversations-create-group"
    case xmtpConversationsGet = "xmtp-conversations-get"
    case xmtpConversationsSync = "xmtp-conversations-sync"
    case xmtpConversationsSyncAll = "xmtp-conversations-sync-all"
    case xmtpConversationSendText = "xmtp-conversation-send-text"
    case xmtpConversationMessages = "xmtp-conversation-messages"
    case xmtpConversationMembers = "xmtp-conversation-members"
    case xmtpConversationAddMembers = "xmtp-conversation-add-members"
    case xmtpConversationRemoveMembers = "xmtp-conversation-remove-members"
    case xmtpConversationConsentState = "xmtp-conversation-consent-state"
    case xmtpConversationUpdateConsent = "xmtp-conversation-update-consent"
    case xmtpPreferencesGetConsent = "xmtp-preferences-get-consent"
    case xmtpPreferencesSetConsent = "xmtp-preferences-set-consent"
    case xmtpPreferencesInboxState = "xmtp-preferences-inbox-state"
    case xmtpPreferencesSync = "xmtp-preferences-sync"
    
    var id: String { rawValue }
    
    var alias: String { "/" + rawValue }
    
    var placeholder: String? {
        switch self {
        case .block, .hug, .message, .slap, .unblock, .favorite, .unfavorite:
            return "<" + String(localized: "content.input.nickname_placeholder") + ">"
        case .dmWallet, .xmtpConversationsCreateDm:
            return "<inbox_id>"
        case .help:
            return "[command]"
        case .xmtpCanMessage:
            return "<address>"
        case .xmtpConversationsCreateGroup:
            return "<addr1> [addr2 …]"
        case .xmtpConversationsGet, .xmtpConversationMessages,
             .xmtpConversationMembers, .xmtpConversationConsentState:
            return "<conversation-id>"
        case .xmtpConversationSendText:
            return "<conv-id> <message>"
        case .xmtpConversationAddMembers:
            return "<conv-id> <addr>"
        case .xmtpConversationRemoveMembers:
            return "<conv-id> <inbox-id>"
        case .xmtpConversationUpdateConsent:
            return "<conv-id> <allowed|denied>"
        case .xmtpPreferencesGetConsent:
            return "<inbox|conversation> <id>"
        case .xmtpPreferencesSetConsent:
            return "<inbox|conversation> <id> <state>"
        case .xmtpPreferencesInboxState:
            return "<inbox-id>"
        case .clear, .who, .xmtp, .xmtpSync, .xmtpList, .tx, .wallet,
             .xmtpClientInfo, .xmtpConversationsList, .xmtpConversationsSync,
             .xmtpConversationsSyncAll, .xmtpPreferencesSync:
            return nil
        }
    }
    
    var description: String {
        switch self {
        case .help:         "show commands & tutorial"
        case .block:        String(localized: "content.commands.block")
        case .clear:        String(localized: "content.commands.clear")
        case .hug:          String(localized: "content.commands.hug")
        case .message:      String(localized: "content.commands.message")
        case .slap:         String(localized: "content.commands.slap")
        case .unblock:      String(localized: "content.commands.unblock")
        case .who:          String(localized: "content.commands.who")
        case .favorite:     String(localized: "content.commands.favorite")
        case .unfavorite:   String(localized: "content.commands.unfavorite")
        case .xmtp:         "show XMTP wallet status"
        case .dmWallet:     "start XMTP DM with inbox"
        case .xmtpSync:     "sync XMTP conversations"
        case .xmtpList:     "list XMTP conversations"
        case .tx:           "show pending transactions"
        case .wallet:       "show wallet status"
        // CLI-compatible descriptions
        case .xmtpCanMessage:                "check XMTP reachability"
        case .xmtpClientInfo:                "XMTP client info"
        case .xmtpConversationsList:         "list conversations"
        case .xmtpConversationsCreateDm:     "create a DM"
        case .xmtpConversationsCreateGroup:  "create a group"
        case .xmtpConversationsGet:          "get conversation details"
        case .xmtpConversationsSync:         "light sync conversations"
        case .xmtpConversationsSyncAll:      "full sync all conversations"
        case .xmtpConversationSendText:      "send text to conversation"
        case .xmtpConversationMessages:      "read conversation messages"
        case .xmtpConversationMembers:       "list conversation members"
        case .xmtpConversationAddMembers:    "add members to group"
        case .xmtpConversationRemoveMembers: "remove members from group"
        case .xmtpConversationConsentState:  "get conversation consent"
        case .xmtpConversationUpdateConsent: "set conversation consent"
        case .xmtpPreferencesGetConsent:     "get consent by entity"
        case .xmtpPreferencesSetConsent:     "set consent by entity"
        case .xmtpPreferencesInboxState:     "show inbox state"
        case .xmtpPreferencesSync:           "sync preferences"
        }
    }
    
    /// Whether this is an XMTP CLI-level command (hidden from default menu)
    var isCliCommand: Bool {
        switch self {
        case .xmtpCanMessage, .xmtpClientInfo,
             .xmtpConversationsList, .xmtpConversationsCreateDm, .xmtpConversationsCreateGroup,
             .xmtpConversationsGet, .xmtpConversationsSync, .xmtpConversationsSyncAll,
             .xmtpConversationSendText, .xmtpConversationMessages, .xmtpConversationMembers,
             .xmtpConversationAddMembers, .xmtpConversationRemoveMembers,
             .xmtpConversationConsentState, .xmtpConversationUpdateConsent,
             .xmtpPreferencesGetConsent, .xmtpPreferencesSetConsent,
             .xmtpPreferencesInboxState, .xmtpPreferencesSync:
            return true
        default:
            return false
        }
    }

    /// Primary commands shown in the default `/` menu (excludes CLI commands)
    static func all(isGeoPublic: Bool, isGeoDM: Bool) -> [CommandInfo] {
        let baseCommands: [CommandInfo] = [.help, .block, .unblock, .clear, .hug, .message, .slap, .who]
        let xmtpCommands: [CommandInfo] = [.xmtp, .dmWallet, .xmtpSync, .xmtpList, .tx, .wallet]
        if isGeoPublic || isGeoDM {
            return baseCommands + [.favorite, .unfavorite] + xmtpCommands
        }
        return baseCommands + xmtpCommands
    }

    /// XMTP CLI commands — shown only when user types `/xmtp-`
    static let cliCommands: [CommandInfo] = [
        .xmtpCanMessage, .xmtpClientInfo,
        .xmtpConversationsList, .xmtpConversationsCreateDm, .xmtpConversationsCreateGroup,
        .xmtpConversationsGet, .xmtpConversationsSync, .xmtpConversationsSyncAll,
        .xmtpConversationSendText, .xmtpConversationMessages, .xmtpConversationMembers,
        .xmtpConversationAddMembers, .xmtpConversationRemoveMembers,
        .xmtpConversationConsentState, .xmtpConversationUpdateConsent,
        .xmtpPreferencesGetConsent, .xmtpPreferencesSetConsent,
        .xmtpPreferencesInboxState, .xmtpPreferencesSync
    ]
}
