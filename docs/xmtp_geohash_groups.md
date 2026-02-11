# XMTP Geohash Groups with Nostr Registry

## Overview

This document describes the implementation of open, location-based XMTP group chats using Nostr as a decentralized coordination layer. This extends the existing geohash-based presence system to support persistent group messaging via XMTP.

## Problem Statement

XMTP groups use the MLS (Messaging Layer Security) protocol, which are fundamentally **invitation-based**, not discovery-based. This creates challenges for public location channels:

1. **No public discovery**: Users can't search for or join existing groups by topic
2. **Invitation required**: New members must be explicitly added by existing members
3. **No shared group IDs**: Group identifiers are internal to XMTP and not predictable

### Original Implementation Issues

The initial implementation had several bugs:

1. **Per-device random seed**: `deriveGroupId()` used a device-specific random seed, causing users to derive different group IDs for the same geohash
2. **ID mismatch**: Code compared derived group IDs against XMTP's internal `group.id` (which never matched)
3. **Empty groups**: Groups were created with only the creator as a member, with no mechanism for others to join

## Solution Architecture

We use **Nostr as a decentralized database** to coordinate XMTP group discovery and membership. This enables truly open location groups:

```
┌─────────────┐     ┌─────────────┐     ┌─────────────┐
│   User A    │     │   Nostr     │     │   User B    │
│  (Creator)  │     │   Relays    │     │  (Joiner)   │
└──────┬──────┘     └──────┬──────┘     └──────┬──────┘
       │                   │                   │
       │ 1. Create XMTP    │                   │
       │    group for      │                   │
       │    geohash "9q8yy"│                   │
       │                   │                   │
       │ 2. Publish        │                   │
       │    mapping ──────►│                   │
       │    (kind 30078)   │                   │
       │                   │                   │
       │                   │◄── 3. Query       │
       │                   │    for "9q8yy"    │
       │                   │                   │
       │                   │    4. Return ────►│
       │                   │    group ID       │
       │                   │                   │
       │                   │◄── 5. Publish     │
       │                   │    join request   │
       │                   │    (kind 20002)   │
       │                   │                   │
       │◄── 6. See request │                   │
       │                   │                   │
       │ 7. Add User B     │                   │
       │    to XMTP group ─┼─────────────────►│
       │                   │                   │
       └───────────────────┴───────────────────┘
```

## Components

### 1. GeohashGroupRegistry (`bitchat/XMTP/GeohashGroupRegistry.swift`)

Central registry service that maps geohashes to XMTP group IDs using Nostr.

#### Nostr Event Types

| Kind | Purpose | Persistence |
|------|---------|-------------|
| 30078 | Geohash → Group ID mapping | Parameterized replaceable (permanent) |
| 20002 | Join requests | Ephemeral |

#### Registry Event Structure (Kind 30078)

```json
{
  "kind": 30078,
  "content": "{\"geohash\":\"9q8yy\",\"xmtp_group\":\"abc123...\",\"version\":\"1\"}",
  "tags": [
    ["d", "9q8yy"],
    ["t", "bitchat-geo-registry"],
    ["xmtp-group", "abc123..."],
    ["creator", "inbox_id_here"],
    ["g", "9q8yy"]
  ]
}
```

#### Join Request Event Structure (Kind 20002)

```json
{
  "kind": 20002,
  "content": "{\"type\":\"geo_join_request\",\"geohash\":\"9q8yy\",\"inbox_id\":\"xyz789...\"}",
  "tags": [
    ["t", "bitchat-geo-join"],
    ["g", "9q8yy"],
    ["inbox", "xyz789..."]
  ]
}
```

#### Key Methods

```swift
/// Look up XMTP group ID for a geohash (checks cache, then queries Nostr)
func lookupGroup(forGeohash: String) async -> GroupMapping?

/// Register a new geohash→group mapping on Nostr
func registerGroup(geohash: String, xmtpGroupId: String, creatorInboxId: String) async throws

/// Publish a join request for other members to see
func requestJoin(geohash: String, myInboxId: String) async throws
```

### 2. XMTPClientService Extensions (`bitchat/XMTP/XMTPClientService.swift`)

New methods for open group management:

```swift
/// Create a location group with allMembers permission (anyone can add)
func createOpenLocationGroup(name: String, geohash: String) async throws -> Group

/// Add a member to an existing group by their XMTP inbox ID
func addMemberToGroup(_ group: Group, inboxId: String) async throws

/// Find a group by its XMTP group ID
func findGroupById(_ groupId: String) async throws -> Group?
```

#### Group Permissions

Groups are created with `.allMembers` permission preconfiguration:

```swift
let group = try await client?.conversations.newGroup(
    with: [],  // Empty initial members
    permissions: .allMembers,  // Any member can add others
    name: groupName
)
```

This is critical - without `allMembers` permission, only the admin could add new members.

### 3. XMTPLocationChannels Updates (`bitchat/XMTP/XMTPLocationChannels.swift`)

Registry integration and join request handling:

#### Join Flow

```swift
func findOrJoinLocationGroup(geohash: String, groupName: String) async throws -> Group {
    // 1. Check if already a member
    if let existingGroup = try await clientService.findGroupById(groupName) {
        return existingGroup
    }
    
    // 2. Query registry for existing group
    if let registry = registry {
        if let mapping = await registry.lookupGroup(forGeohash: geohash) {
            // Found! Check if we're a member
            if let group = try await clientService.findGroupById(mapping.xmtpGroupId) {
                return group
            }
            
            // Not a member - publish join request
            try await registry.requestJoin(geohash: geohash, myInboxId: myInboxId)
            
            // Wait briefly for someone to add us
            try await Task.sleep(nanoseconds: 2_000_000_000)
            
            if let group = try await clientService.findGroupById(mapping.xmtpGroupId) {
                return group
            }
        }
    }
    
    // 3. No existing group - create new one
    let group = try await clientService.createOpenLocationGroup(name: groupName, geohash: geohash)
    
    // Register with Nostr
    try? await registry?.registerGroup(geohash: geohash, xmtpGroupId: group.id, creatorInboxId: myInboxId)
    
    return group
}
```

#### Join Request Handler

```swift
func handleJoinRequest(geohash: String, requesterInboxId: String) async {
    guard let channel = activeChannels[geohash],
          channel.isJoined,
          let group = channel.group else {
        return  // Not our group to manage
    }
    
    // Check if already a member
    let members = try await group.members
    if members.map({ $0.inboxId }).contains(requesterInboxId) {
        return  // Already in group
    }
    
    // Add the requester
    try await clientService.addMemberToGroup(group, inboxId: requesterInboxId)
}
```

### 4. NostrRelayManager Extensions (`bitchat/Nostr/NostrRelayManager.swift`)

New methods for registry communication:

```swift
/// Query Nostr relays for events matching a filter
func queryEvents(filter: NostrFilter, timeout: TimeInterval) async throws -> [NostrEvent]

/// Publish a registry event (geohash mapping or join request)
func publishRegistryEvent(kind: UInt32, content: String, tags: [[String]]) async throws
```

### 5. NostrIdentityBridge Addition (`bitchat/Nostr/NostrIdentityBridge.swift`)

```swift
/// Get or create the app's main Nostr identity for registry operations
func getOrCreateAppIdentity() throws -> NostrIdentity
```

## Complete User Flow

### User A (First to Enter Geohash "9q8yy")

1. App detects location → computes geohash "9q8yy"
2. Query `GeohashGroupRegistry` for existing mapping → none found
3. Create new XMTP group with name "geo:9q8yy" and `.allMembers` permission
4. Publish Nostr event (kind 30078) mapping "9q8yy" → group ID
5. Start streaming messages from the group

### User B (Joining Later)

1. App detects location → computes geohash "9q8yy"
2. Query `GeohashGroupRegistry` for existing mapping → found!
3. Check if already member of group → no
4. Publish join request (kind 20002) to Nostr
5. Wait for existing member to add us
6. Retry group lookup → now a member!
7. Start streaming messages

### User A (Handling Join Request)

1. Receive Nostr event (kind 20002) for geohash "9q8yy"
2. Check if we have an active group for this geohash → yes
3. Check if requester already in group → no
4. Call `group.addMembersByInboxId([requesterInboxId])`
5. User B can now access the group

## Files Created/Modified

### New Files

| File | Purpose |
|------|---------|
| `bitchat/XMTP/GeohashGroupRegistry.swift` | Nostr-based geohash→group registry |

### Modified Files

| File | Changes |
|------|---------|
| `bitchat/XMTP/XMTPClientService.swift` | Added `createOpenLocationGroup()`, `addMemberToGroup()`, `findGroupById()` |
| `bitchat/XMTP/XMTPLocationChannels.swift` | Integrated registry, added `findOrJoinLocationGroup()`, `handleJoinRequest()` |
| `bitchat/XMTP/XMTPIdentityBridge.swift` | Fixed `deriveGroupId()` to use public seed |
| `bitchat/XMTP/XMTPServiceContainer.swift` | Wired up `GeohashGroupRegistry` |
| `bitchat/Nostr/NostrRelayManager.swift` | Added `queryEvents()`, `publishRegistryEvent()` |
| `bitchat/Nostr/NostrIdentityBridge.swift` | Added `getOrCreateAppIdentity()` |

## Configuration

### Service Container Setup

```swift
// In XMTPServiceContainer
let geohashGroupRegistry = GeohashGroupRegistry(clientService: clientService)
geohashGroupRegistry.setNostrManager(nostrManager)
locationChannels.setRegistry(geohashGroupRegistry)
```

## Limitations & Future Work

### Current Limitations

1. **Join latency**: New users must wait for an existing member to add them (2+ seconds)
2. **Offline members**: If no group members are online, join requests may be missed
3. **Race conditions**: Multiple users creating groups simultaneously could create duplicates

### Future Improvements

- [ ] Subscribe to join requests continuously (not just when active in geohash)
- [ ] Implement join request queuing and retry logic
- [ ] Add conflict resolution for duplicate group registrations
- [ ] Support group metadata updates (member count, last activity)
- [ ] Add group moderation features (admin roles, banning)
- [ ] Implement group expiration for inactive geohashes

## Security Considerations

1. **Public registry**: Geohash→group mappings are public on Nostr. Anyone can see which geohashes have active groups.

2. **Spam potential**: Malicious actors could flood join requests. Consider rate limiting.

3. **Group permissions**: Using `.allMembers` means any member can add (or potentially remove) others. Consider admin-only permissions for sensitive locations.

4. **Nostr identity**: Registry events are signed with the app's Nostr identity, providing accountability.

## Related Documentation

- [GeohashPresenceSpec.md](GeohashPresenceSpec.md) - Geohash presence system using Nostr ephemeral events
- [XMTP SDK Documentation](https://xmtp.org/docs)
- [Nostr Protocol Specification](https://github.com/nostr-protocol/nips)
- [NIP-78: Arbitrary Custom App Data](https://github.com/nostr-protocol/nips/blob/master/78.md) (kind 30078)

## Testing

### Manual Testing Steps

1. User A enters geohash area → verify group creation
2. Check Nostr relay for kind 30078 event with correct tags
3. User B enters same geohash → verify registry lookup
4. Verify join request (kind 20002) published
5. Verify User A receives and processes join request
6. Verify User B now receives messages from the group

### Automated Tests Needed

- [ ] `GeohashGroupRegistry` unit tests (lookup, register, join request)
- [ ] `XMTPLocationChannels` integration tests with mock registry
- [ ] End-to-end test with two XMTP clients
