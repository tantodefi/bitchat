//
// GeohashGroupRegistry.swift
// bitchat
//
// Registry for mapping geohashes to XMTP group IDs using Nostr as a decentralized database.
// This enables open location-based groups where any user can discover and join.
//
// Architecture:
// - Nostr notes (kind 30078, parameterized replaceable) store geohash→groupId mappings
// - First user to enter a geohash creates the XMTP group and publishes the mapping
// - Subsequent users query Nostr for the group ID and request to be added
// - Groups use "allMembers" permission so any member can add newcomers
//
// This is free and unencumbered software released into the public domain.
// For more information, see <https://unlicense.org>
//

import BitLogger
import Foundation
import XMTP

/// Registry for geohash → XMTP group mappings stored on Nostr
@MainActor
final class GeohashGroupRegistry: ObservableObject {
    
    // MARK: - Constants
    
    /// Nostr kind for geohash group registry (parameterized replaceable event)
    /// Using kind 30078 (application-specific data)
    static let nostrKind: UInt32 = 30078
    
    /// Tag identifier for geohash
    static let geohashTag = "g"
    
    /// Tag identifier for XMTP group ID
    static let groupIdTag = "xmtp-group"
    
    /// App identifier tag
    static let appTag = "bitchat-geo-registry"
    
    // MARK: - Properties
    
    private let clientService: XMTPClientService
    private weak var nostrManager: NostrRelayManager?
    
    /// Local cache of geohash → XMTP group ID mappings
    @Published private(set) var groupMappings: [String: GroupMapping] = [:]
    
    /// Pending join requests (geohash → our inbox ID)
    @Published private(set) var pendingJoins: Set<String> = []
    
    // MARK: - Models
    
    struct GroupMapping: Codable, Equatable {
        let geohash: String
        let xmtpGroupId: String
        let creatorInboxId: String
        let createdAt: Date
        let nostrEventId: String?
    }
    
    // MARK: - Initialization
    
    init(clientService: XMTPClientService) {
        self.clientService = clientService
    }
    
    func setNostrManager(_ manager: NostrRelayManager) {
        self.nostrManager = manager
    }
    
    // MARK: - Group Discovery
    
    /// Look up the XMTP group ID for a geohash
    /// First checks local cache, then queries Nostr
    func lookupGroup(forGeohash geohash: String) async -> GroupMapping? {
        // Check local cache first
        if let cached = groupMappings[geohash] {
            return cached
        }
        
        // Query Nostr for existing mapping
        guard let nostrManager = nostrManager else {
            SecureLogger.warning("NostrManager not set, cannot query geohash registry", category: .network)
            return nil
        }
        
        // Create filter for geohash registry events
        // Looking for kind 30078 events with our app tag and the specific geohash
        do {
            let mapping = try await queryNostrForMapping(geohash: geohash, manager: nostrManager)
            if let mapping = mapping {
                groupMappings[geohash] = mapping
            }
            return mapping
        } catch {
            SecureLogger.error("Failed to query geohash registry: \(error.localizedDescription)", category: .network)
            return nil
        }
    }
    
    /// Query Nostr relays for a geohash→group mapping
    private func queryNostrForMapping(geohash: String, manager: NostrRelayManager) async throws -> GroupMapping? {
        // Build filter for parameterized replaceable events
        // d tag = geohash, kind = 30078
        let filter = NostrFilter.geohashRegistry(
            geohash: geohash,
            appTag: Self.appTag,
            kind: Int(Self.nostrKind)
        )
        
        // Query and wait for response
        let events = try await manager.queryEvents(filter: filter, timeout: 5.0)
        
        // Parse the most recent event
        guard let event = events.first else {
            return nil
        }
        
        // Extract group ID from tags
        guard let groupIdTag = event.tags.first(where: { $0.first == Self.groupIdTag }),
              groupIdTag.count >= 2 else {
            SecureLogger.warning("Geohash registry event missing group ID tag", category: .network)
            return nil
        }
        
        let groupId = groupIdTag[1]
        
        // Extract creator inbox ID
        let creatorInboxId = event.tags.first(where: { $0.first == "creator" })?[safe: 1] ?? event.pubkey
        
        return GroupMapping(
            geohash: geohash,
            xmtpGroupId: groupId,
            creatorInboxId: creatorInboxId,
            createdAt: Date(timeIntervalSince1970: TimeInterval(event.created_at)),
            nostrEventId: event.id
        )
    }
    
    // MARK: - Group Registration
    
    /// Register a new XMTP group for a geohash
    /// Called when we're the first to create a group for this location
    func registerGroup(geohash: String, xmtpGroupId: String, creatorInboxId: String) async throws {
        guard let nostrManager = nostrManager else {
            throw GeohashRegistryError.nostrNotAvailable
        }
        
        // Create Nostr event to publish the mapping
        // Using parameterized replaceable event (kind 30078) so updates replace old entries
        let content = """
        {"geohash":"\(geohash)","xmtp_group":"\(xmtpGroupId)","version":"1"}
        """
        
        let tags: [[String]] = [
            ["d", geohash],  // Parameterized replaceable identifier
            ["t", Self.appTag],
            [Self.groupIdTag, xmtpGroupId],
            ["creator", creatorInboxId],
            [Self.geohashTag, geohash]
        ]
        
        // Sign and publish via Nostr
        // Using the app's identity (not per-geohash identity for registry events)
        try await nostrManager.publishRegistryEvent(
            kind: Self.nostrKind,
            content: content,
            tags: tags
        )
        
        // Update local cache
        let mapping = GroupMapping(
            geohash: geohash,
            xmtpGroupId: xmtpGroupId,
            creatorInboxId: creatorInboxId,
            createdAt: Date(),
            nostrEventId: nil
        )
        groupMappings[geohash] = mapping
        
        SecureLogger.info("📍 Registered geohash group: \(geohash) → \(xmtpGroupId.prefix(16))…", category: .session)
    }
    
    // MARK: - Join Requests
    
    /// Request to join an existing geohash group
    /// This publishes a join request that group members can see and approve
    func requestJoin(geohash: String, myInboxId: String) async throws {
        guard let nostrManager = nostrManager else {
            throw GeohashRegistryError.nostrNotAvailable
        }
        
        pendingJoins.insert(geohash)
        
        // Publish a join request event (ephemeral, kind 20000 range)
        let content = """
        {"type":"geo_join_request","geohash":"\(geohash)","inbox_id":"\(myInboxId)"}
        """
        
        let tags: [[String]] = [
            ["t", "bitchat-geo-join"],
            [Self.geohashTag, geohash],
            ["inbox", myInboxId]
        ]
        
        try await nostrManager.publishRegistryEvent(
            kind: 20002,  // Ephemeral join request
            content: content,
            tags: tags
        )
        
        SecureLogger.info("📍 Published join request for geohash: \(geohash)", category: .session)
    }
    
    /// Mark a join request as completed
    func completeJoin(geohash: String) {
        pendingJoins.remove(geohash)
    }
    
    // MARK: - Cache Management
    
    /// Clear cached mappings (e.g., on logout)
    func clearCache() {
        groupMappings.removeAll()
        pendingJoins.removeAll()
    }
}

// MARK: - Errors

enum GeohashRegistryError: Error, LocalizedError {
    case nostrNotAvailable
    case groupNotFound
    case registrationFailed
    case joinRequestFailed
    
    var errorDescription: String? {
        switch self {
        case .nostrNotAvailable:
            return "Nostr relay manager not available"
        case .groupNotFound:
            return "No XMTP group found for this geohash"
        case .registrationFailed:
            return "Failed to register geohash group"
        case .joinRequestFailed:
            return "Failed to request group join"
        }
    }
}

// MARK: - Array Extension

private extension Array {
    subscript(safe index: Index) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
