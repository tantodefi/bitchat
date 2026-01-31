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
    
    var id: String { rawValue }
    
    var alias: String { "/" + rawValue }
    
    var placeholder: String? {
        switch self {
        case .block, .hug, .message, .slap, .unblock, .favorite, .unfavorite:
            return "<" + String(localized: "content.input.nickname_placeholder") + ">"
        case .dmWallet:
            return "<inbox_id>"
        case .clear, .who, .xmtp, .xmtpSync, .xmtpList:
            return nil
        }
    }
    
    var description: String {
        switch self {
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
        }
    }
    
    static func all(isGeoPublic: Bool, isGeoDM: Bool) -> [CommandInfo] {
        let baseCommands: [CommandInfo] = [.block, .unblock, .clear, .hug, .message, .slap, .who]
        let xmtpCommands: [CommandInfo] = [.xmtp, .dmWallet, .xmtpSync, .xmtpList]
        if isGeoPublic || isGeoDM {
            return baseCommands + [.favorite, .unfavorite] + xmtpCommands
        }
        return baseCommands + xmtpCommands
    }
}
