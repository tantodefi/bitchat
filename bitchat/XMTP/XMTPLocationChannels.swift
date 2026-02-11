//
// XMTPLocationChannels.swift
// bitchat
//
// XMTP group-based location channels using geohash-derived group IDs.
//
// **Open Group Architecture (with GeohashGroupRegistry)**:
// When the GeohashGroupRegistry is configured, this enables truly open location groups:
// 1. Nostr is used as a decentralized database to store geohash→XMTP group mappings
// 2. First user to enter a geohash creates the XMTP group with "allMembers" permissions
// 3. The group ID is published to Nostr so other users can discover it
// 4. Users joining later query Nostr for the group ID and publish join requests
// 5. Existing members (any member, due to allMembers permission) add newcomers
//
// **Fallback Mode (without registry)**:
// Without the registry, each user creates their own group and messages aren't shared.
// This is still useful for testing or when Nostr is unavailable.
//
// For maximum compatibility, Nostr ephemeral events (kind 20000) remain the
// recommended transport for public location channels. XMTP groups are better
// suited when persistent message history is desired.
//
// This is free and unencumbered software released into the public domain.
// For more information, see <https://unlicense.org>
//

import BitLogger
import Combine
import Foundation
import XMTP

/// Manages XMTP-based location channels (geographic chat rooms)
///
/// **Limitations**: Due to XMTP's MLS architecture, these are effectively private groups.
/// For public location channels, prefer the Nostr transport option in settings.
@MainActor
final class XMTPLocationChannels: ObservableObject {
    // MARK: - Properties
    
    private let identityBridge: XMTPIdentityBridge
    private let clientService: XMTPClientService
    
    /// Optional registry for open group discovery
    /// When set, enables cross-user group discovery via Nostr
    private var registry: GeohashGroupRegistry?
    
    // Active location channel subscriptions
    @Published private(set) var activeChannels: [String: LocationChannel] = [:] // geohash -> channel
    @Published private(set) var currentGeohash: String?
    
    // Message stream tasks
    private var streamTasks: [String: Task<Void, Never>] = [:]
    
    // Join request listener task
    private var joinRequestTask: Task<Void, Never>?
    
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
    
    // MARK: - Registry Integration
    
    /// Set the geohash group registry for open group support
    func setRegistry(_ registry: GeohashGroupRegistry) {
        self.registry = registry
    }
    
    // MARK: - Channel Management
    
    /// Join a location channel for the given geohash
    /// 
    /// Flow with registry (open groups):
    /// 1. Check if we're already a member of a group for this geohash
    /// 2. Query registry for existing group
    /// 3. If found, check if we're a member; if not, request to join
    /// 4. If not found, create new group and register it
    func joinChannel(geohash: String) async throws {
        guard clientService.isConnected else {
            throw LocationChannelError.notConnected
        }
        
        // Check if already in this channel
        if activeChannels[geohash]?.isJoined == true {
            SecureLogger.debug("Already in location channel: \(geohash)", category: .session)
            return
        }
        
        let groupName = identityBridge.groupName(forGeohash: geohash)
        
        SecureLogger.info("📍 Joining location channel: \(geohash)", category: .session)
        
        // Try to find or create the group using the registry-aware approach
        let group = try await findOrJoinLocationGroup(geohash: geohash, groupName: groupName)
        
        let channel = LocationChannel(
            geohash: geohash,
            groupId: group.id,
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
    
    /// Find or join a location group, using registry if available
    private func findOrJoinLocationGroup(geohash: String, groupName: String) async throws -> Group {
        // Step 1: Check if we're already a member of a group with this name
        if let existingGroup = try await clientService.findGroupById(groupName) {
            return existingGroup
        }
        
        // Also check by name match
        let groups = try await clientService.listGroups()
        if let matchingGroup = groups.first(where: { (try? $0.name()) == groupName }) {
            return matchingGroup
        }
        
        // Step 2: If registry is available, use it for open group discovery
        if let registry = registry {
            // Query registry for existing group
            if let mapping = await registry.lookupGroup(forGeohash: geohash) {
                SecureLogger.debug("📍 Found registered group for \(geohash): \(mapping.xmtpGroupId.prefix(16))…", category: .session)
                
                // Check if we're already a member
                if let group = try await clientService.findGroupById(mapping.xmtpGroupId) {
                    return group
                }
                
                // We're not a member yet - publish join request
                // Other members listening will add us
                if let myInboxId = clientService.inboxId {
                    try await registry.requestJoin(geohash: geohash, myInboxId: myInboxId)
                    
                    // Wait briefly for someone to add us, then check again
                    try await Task.sleep(nanoseconds: 2_000_000_000) // 2 seconds
                    
                    if let group = try await clientService.findGroupById(mapping.xmtpGroupId) {
                        registry.completeJoin(geohash: geohash)
                        return group
                    }
                }
                
                // Still not added - we may need to wait or create our own
                SecureLogger.warning("📍 Join request sent but not yet added to group for \(geohash)", category: .session)
            }
        }
        
        // Step 3: No existing group found - create a new one
        let group = try await clientService.createOpenLocationGroup(name: groupName, geohash: geohash)
        
        // Register the new group if registry is available
        if let registry = registry, let myInboxId = clientService.inboxId {
            try? await registry.registerGroup(
                geohash: geohash,
                xmtpGroupId: group.id,
                creatorInboxId: myInboxId
            )
        }
        
        return group
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
        joinRequestTask?.cancel()
        joinRequestTask = nil
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
    
    // MARK: - Join Request Handling
    
    /// Handle an incoming join request from another user
    /// This is called when we receive a Nostr event requesting to join a geohash group
    func handleJoinRequest(geohash: String, requesterInboxId: String) async {
        // Check if we have a group for this geohash
        guard let channel = activeChannels[geohash],
              channel.isJoined,
              let group = channel.group else {
            SecureLogger.debug("📍 Ignoring join request for \(geohash) - not our group", category: .session)
            return
        }
        
        // Check if requester is already a member
        do {
            let members = try await group.members
            let memberInboxIds = members.map { $0.inboxId }
            
            if memberInboxIds.contains(requesterInboxId) {
                SecureLogger.debug("📍 Requester \(requesterInboxId.prefix(12))… already in group", category: .session)
                return
            }
            
            // Add the requester to the group
            try await clientService.addMemberToGroup(group, inboxId: requesterInboxId)
            SecureLogger.info("📍 Added \(requesterInboxId.prefix(12))… to location channel \(geohash)", category: .session)
            
        } catch {
            SecureLogger.error("📍 Failed to add member to group: \(error.localizedDescription)", category: .session)
        }
    }
    
    // MARK: - Member Info
    
    /// Get the members of a location channel
    /// Returns array of tuples with (inboxId, nickname if known)
    func getMembers(for geohash: String) async -> [(inboxId: String, nickname: String?)] {
        guard let channel = activeChannels[geohash],
              channel.isJoined,
              let group = channel.group else {
            return []
        }
        
        do {
            let members = try await group.members
            return members.map { member in
                // Try to find a saved nickname for this member
                let nickname = clientService.savedContacts.first { 
                    $0.truncatedId == String(member.inboxId.prefix(16))
                }?.displayName
                return (inboxId: member.inboxId, nickname: nickname)
            }
        } catch {
            SecureLogger.error("📍 Failed to get members: \(error.localizedDescription)", category: .session)
            return []
        }
    }
    
    /// Get member count for a location channel
    func getMemberCount(for geohash: String) -> Int {
        return activeChannels[geohash]?.memberCount ?? 0
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
