//
// XMTPLocationChannels.swift
// bitchat
//
// XMTP group-based location channels using geohash-derived group IDs.
// Replaces Nostr ephemeral events with persistent XMTP groups.
//
// This is free and unencumbered software released into the public domain.
// For more information, see <https://unlicense.org>
//

import BitLogger
import Combine
import Foundation
import XMTP

/// Manages XMTP-based location channels (geographic chat rooms)
@MainActor
final class XMTPLocationChannels: ObservableObject {
    // MARK: - Properties
    
    private let identityBridge: XMTPIdentityBridge
    private let clientService: XMTPClientService
    
    // Active location channel subscriptions
    @Published private(set) var activeChannels: [String: LocationChannel] = [:] // geohash -> channel
    @Published private(set) var currentGeohash: String?
    
    // Message stream tasks
    private var streamTasks: [String: Task<Void, Never>] = [:]
    
    // Delegate for incoming messages
    weak var delegate: XMTPLocationChannelsDelegate?
    
    // MARK: - Models
    
    struct LocationChannel {
        let geohash: String
        let groupId: String
        let group: Group?
        let precision: Int
        var lastActivity: Date
        var memberCount: Int
        var isJoined: Bool
    }
    
    struct LocationMessage: Identifiable {
        let id: String
        let content: String
        let senderInboxId: String
        let senderNickname: String?
        let timestamp: Date
        let geohash: String
    }
    
    // MARK: - Initialization
    
    init(identityBridge: XMTPIdentityBridge, clientService: XMTPClientService) {
        self.identityBridge = identityBridge
        self.clientService = clientService
    }
    
    deinit {
        for task in streamTasks.values {
            task.cancel()
        }
    }
    
    // MARK: - Channel Management
    
    /// Join a location channel for the given geohash
    func joinChannel(geohash: String) async throws {
        guard clientService.isConnected else {
            throw LocationChannelError.notConnected
        }
        
        // Check if already in this channel
        if activeChannels[geohash]?.isJoined == true {
            SecureLogger.debug("Already in location channel: \(geohash)", category: .session)
            return
        }
        
        let groupId = identityBridge.deriveGroupId(forGeohash: geohash)
        let groupName = identityBridge.groupName(forGeohash: geohash)
        
        SecureLogger.info("📍 Joining location channel: \(geohash) (group: \(groupId.prefix(16))…)", category: .session)
        
        // Find or create the XMTP group
        let group = try await clientService.findOrCreateGroup(groupId: groupId, name: groupName)
        
        let channel = LocationChannel(
            geohash: geohash,
            groupId: groupId,
            group: group,
            precision: geohash.count,
            lastActivity: Date(),
            memberCount: try await group.members.count,
            isJoined: true
        )
        
        activeChannels[geohash] = channel
        currentGeohash = geohash
        
        // Start streaming messages for this channel
        startMessageStream(for: geohash, group: group)
        
        SecureLogger.info("✅ Joined location channel: \(geohash) (\(channel.memberCount) members)", category: .session)
    }
    
    /// Leave a location channel
    func leaveChannel(geohash: String) {
        // Cancel stream task
        streamTasks[geohash]?.cancel()
        streamTasks.removeValue(forKey: geohash)
        
        // Mark as not joined but keep in cache for quick rejoin
        if var channel = activeChannels[geohash] {
            channel.isJoined = false
            activeChannels[geohash] = channel
        }
        
        if currentGeohash == geohash {
            currentGeohash = nil
        }
        
        SecureLogger.info("📍 Left location channel: \(geohash)", category: .session)
    }
    
    /// Leave all channels (e.g., when going offline)
    func leaveAllChannels() {
        for geohash in activeChannels.keys {
            leaveChannel(geohash: geohash)
        }
    }
    
    /// Update location and switch channels if needed
    func updateLocation(latitude: Double, longitude: Double, precision: Int = 5) async throws {
        let newGeohash = encodeGeohash(latitude: latitude, longitude: longitude, precision: precision)
        
        // If geohash changed, switch channels
        if newGeohash != currentGeohash {
            if let current = currentGeohash {
                leaveChannel(geohash: current)
            }
            try await joinChannel(geohash: newGeohash)
        }
    }
    
    // MARK: - Messaging
    
    /// Send a message to a location channel
    func sendMessage(_ content: String, to geohash: String) async throws {
        guard let channel = activeChannels[geohash], channel.isJoined,
              let group = channel.group else {
            throw LocationChannelError.channelNotJoined
        }
        
        // Encode as location message with metadata
        let messageId = UUID().uuidString
        let payload: [String: Any] = [
            "type": "location_msg",
            "content": content,
            "messageId": messageId,
            "geohash": geohash,
            "timestamp": Date().timeIntervalSince1970
        ]
        
        guard let data = try? JSONSerialization.data(withJSONObject: payload),
              let encoded = String(data: data, encoding: .utf8) else {
            throw LocationChannelError.encodingFailed
        }
        
        _ = try await group.send(content: encoded)
        SecureLogger.debug("📍 Sent to location channel \(geohash): \(content.prefix(50))…", category: .session)
    }
    
    /// Send to current location channel
    func sendToCurrentChannel(_ content: String) async throws {
        guard let geohash = currentGeohash else {
            throw LocationChannelError.noActiveChannel
        }
        try await sendMessage(content, to: geohash)
    }
    
    // MARK: - Message Streaming
    
    private func startMessageStream(for geohash: String, group: Group) {
        // Cancel any existing stream
        streamTasks[geohash]?.cancel()
        
        streamTasks[geohash] = Task { [weak self] in
            do {
                for try await message in group.streamMessages() {
                    self?.handleIncomingMessage(message, geohash: geohash)
                }
            } catch {
                SecureLogger.error("Location channel stream error for \(geohash): \(error.localizedDescription)", category: .network)
            }
        }
    }
    
    private func handleIncomingMessage(_ message: DecodedMessage, geohash: String) {
        guard let textContent = try? message.content() as String? else { return }
        
        // Try to decode as location message
        if let data = textContent.data(using: .utf8),
           let payload = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           payload["type"] as? String == "location_msg" {
            
            let locationMessage = LocationMessage(
                id: payload["messageId"] as? String ?? message.id,
                content: payload["content"] as? String ?? "",
                senderInboxId: message.senderInboxId,
                senderNickname: nil, // Can be resolved from identity
                timestamp: message.sentAt,
                geohash: geohash
            )
            
            delegate?.locationChannels(self, didReceiveMessage: locationMessage)
        } else {
            // Plain text message (backwards compatibility)
            let locationMessage = LocationMessage(
                id: message.id,
                content: textContent,
                senderInboxId: message.senderInboxId,
                senderNickname: nil,
                timestamp: message.sentAt,
                geohash: geohash
            )
            
            delegate?.locationChannels(self, didReceiveMessage: locationMessage)
        }
        
        // Update last activity
        if var channel = activeChannels[geohash] {
            channel.lastActivity = Date()
            activeChannels[geohash] = channel
        }
    }
    
    // MARK: - Channel Discovery
    
    /// Get nearby channels (geohashes at various precision levels)
    func getNearbyChannels(latitude: Double, longitude: Double) -> [String] {
        var channels: [String] = []
        
        // Generate geohashes at different precision levels (3-6)
        for precision in 3...6 {
            let geohash = encodeGeohash(latitude: latitude, longitude: longitude, precision: precision)
            channels.append(geohash)
        }
        
        return channels
    }
    
    /// Get adjacent geohashes for the current location
    func getAdjacentChannels() -> [String] {
        guard let current = currentGeohash else { return [] }
        return getNeighbors(geohash: current)
    }
    
    // MARK: - Geohash Helpers
    
    private let base32 = Array("0123456789bcdefghjkmnpqrstuvwxyz")
    
    private func encodeGeohash(latitude: Double, longitude: Double, precision: Int) -> String {
        var latRange = (-90.0, 90.0)
        var lonRange = (-180.0, 180.0)
        var geohash = ""
        var bit = 0
        var ch = 0
        var isEven = true
        
        while geohash.count < precision {
            if isEven {
                let mid = (lonRange.0 + lonRange.1) / 2
                if longitude >= mid {
                    ch |= (1 << (4 - bit))
                    lonRange.0 = mid
                } else {
                    lonRange.1 = mid
                }
            } else {
                let mid = (latRange.0 + latRange.1) / 2
                if latitude >= mid {
                    ch |= (1 << (4 - bit))
                    latRange.0 = mid
                } else {
                    latRange.1 = mid
                }
            }
            isEven.toggle()
            
            if bit < 4 {
                bit += 1
            } else {
                geohash.append(base32[ch])
                bit = 0
                ch = 0
            }
        }
        
        return geohash
    }
    
    private func getNeighbors(geohash: String) -> [String] {
        // Simplified neighbor calculation
        // In production, use proper geohash neighbor algorithm
        guard !geohash.isEmpty else { return [] }
        
        let neighbors = [
            "n", "ne", "e", "se", "s", "sw", "w", "nw"
        ]
        
        // For now, return the geohash with modified last character
        // This is a placeholder - proper implementation needed
        return neighbors.compactMap { direction in
            guard let lastChar = geohash.last,
                  let index = base32.firstIndex(of: lastChar) else { return nil }
            
            let offset: Int
            switch direction {
            case "n", "ne", "nw": offset = 8
            case "s", "se", "sw": offset = -8
            case "e": offset = 1
            case "w": offset = -1
            default: offset = 0
            }
            
            let newIndex = (index + offset + base32.count) % base32.count
            return String(geohash.dropLast()) + String(base32[newIndex])
        }
    }
}

// MARK: - Delegate Protocol

@MainActor
protocol XMTPLocationChannelsDelegate: AnyObject {
    func locationChannels(_ service: XMTPLocationChannels, didReceiveMessage message: XMTPLocationChannels.LocationMessage)
    func locationChannels(_ service: XMTPLocationChannels, didUpdateChannel channel: XMTPLocationChannels.LocationChannel)
}

// MARK: - Errors

enum LocationChannelError: Error, LocalizedError {
    case notConnected
    case channelNotJoined
    case noActiveChannel
    case encodingFailed
    case groupCreationFailed
    
    var errorDescription: String? {
        switch self {
        case .notConnected:
            return "XMTP client is not connected"
        case .channelNotJoined:
            return "Not joined to this location channel"
        case .noActiveChannel:
            return "No active location channel"
        case .encodingFailed:
            return "Failed to encode message"
        case .groupCreationFailed:
            return "Failed to create location group"
        }
    }
}
