# BitChat Bot Integration Guide

This document describes the available APIs, socket streams, and integration points for building bots that interact with BitChat.

## Overview

BitChat uses three transport layers:

| Transport | Protocol | Bot Accessibility |
|-----------|----------|-------------------|
| **Nostr** | WebSocket to public relays | ✅ Full external access |
| **XMTP** | Web3 messaging protocol | ⚠️ Requires XMTP SDK |
| **BLE Mesh** | Bluetooth Low Energy | ❌ Requires physical device |

**The Nostr layer is the recommended integration point for bots** — it uses standard WebSocket connections to public relays that any client can connect to.

---

## Architecture

```
┌─────────────────────────────────────────────────────────────────┐
│                        Nostr Relays                             │
│  wss://relay.damus.io  wss://nos.lol  wss://relay.primal.net   │
└──────────────────────────────┬──────────────────────────────────┘
                               │ WebSocket (NIP-01)
                               │
        ┌──────────────────────┼──────────────────────┐
        │                      │                      │
        ▼                      ▼                      ▼
   ┌─────────┐           ┌─────────┐           ┌─────────┐
   │ BitChat │           │ BitChat │           │  Your   │
   │  User A │           │  User B │           │   Bot   │
   └─────────┘           └─────────┘           └─────────┘
```

---

## Event Kinds Reference

BitChat uses standard Nostr event kinds plus custom ephemeral kinds:

| Kind | Name | Description | Encryption |
|------|------|-------------|------------|
| `0` | Metadata | User profile (name, about, picture) | None |
| `1` | Text Note | Persistent public notes | None |
| `13` | Seal | NIP-17 sealed inner event | NIP-44 |
| `14` | DM Rumor | NIP-17 direct message content | Wrapped in seal |
| `1059` | Gift Wrap | NIP-59 encrypted envelope for DMs | NIP-44 |
| `20000` | Ephemeral Event | Geohash public channel messages | None |
| `20001` | Geohash Presence | Presence heartbeat in location channel | None |

### Kind 1059: Gift Wrap (Encrypted DMs)

BitChat implements NIP-17 encrypted direct messages using NIP-59 gift wrapping:

```
Gift Wrap (kind 1059)
  └─► Seal (kind 13) - encrypted to recipient
       └─► Rumor (kind 14) - the actual DM content
```

**Structure:**
```json
{
  "id": "<event-id>",
  "pubkey": "<disposable-key>",
  "created_at": 1234567890,
  "kind": 1059,
  "tags": [["p", "<recipient-pubkey>"]],
  "content": "<nip44-encrypted-seal>",
  "sig": "<signature>"
}
```

### Kind 20000: Ephemeral Geohash Messages

Public messages in location-based channels. These are **not** stored long-term by relays.

**Structure:**
```json
{
  "id": "<event-id>",
  "pubkey": "<sender-pubkey>",
  "created_at": 1234567890,
  "kind": 20000,
  "tags": [
    ["g", "9q8yyz"],
    ["n", "username"],
    ["teleported", "false"]
  ],
  "content": "Hello from San Francisco!",
  "sig": "<signature>"
}
```

**Tags:**
- `g` — Geohash location (6 characters for ~1.2km precision)
- `n` — Sender nickname (optional)
- `teleported` — Whether user teleported to this location

### Kind 20001: Geohash Presence

Heartbeat events indicating a user is active in a geohash channel.

**Structure:**
```json
{
  "id": "<event-id>",
  "pubkey": "<sender-pubkey>",
  "created_at": 1234567890,
  "kind": 20001,
  "tags": [["g", "9q8yyz"]],
  "content": "",
  "sig": "<signature>"
}
```

### Kind 1: Text Notes (Persistent Location Notes)

Persistent public messages tied to a geohash location.

**Structure:**
```json
{
  "id": "<event-id>",
  "pubkey": "<sender-pubkey>",
  "created_at": 1234567890,
  "kind": 1,
  "tags": [
    ["g", "9q8yyz"],
    ["n", "username"]
  ],
  "content": "This note persists at this location",
  "sig": "<signature>"
}
```

---

## Default Relays

BitChat connects to these relays by default:

```
wss://relay.damus.io
wss://nos.lol
wss://relay.primal.net
wss://offchain.pub
wss://nostr21.com
```

For geohash-specific messages, BitChat also uses geographic relay routing via `GeoRelayDirectory` to find relays closest to the target location.

---

## Rate Limiting

**Bots MUST respect these rate limits to avoid relay bans and maintain compatibility:**

| Operation | Interval | Constant |
|-----------|----------|----------|
| Read receipts / Acks | 350ms minimum | `Constants.nostrReadAckInterval` |
| Presence heartbeats | 30s recommended | — |
| Message sends | No hard limit, but batch if possible | — |

**Additional considerations:**
- Relays may rate-limit connections that send too many events
- Gift-wrapped DMs require creating 3 events per message (rumor → seal → wrap)
- Use `EOSE` (End of Stored Events) signals before processing live events

---

## Approach 1: External Bot (Python/Node.js/Any Language)

Build a standalone bot that connects to the same Nostr relays as BitChat users.

### Prerequisites

- Nostr library with NIP-44 encryption support
- WebSocket client
- Schnorr signature support (secp256k1)

### Python Example (using `nostr-sdk` or `pynostr`)

```python
import asyncio
import json
import websockets
from secp256k1 import PrivateKey
import hashlib
import time

# Bot identity (generate once and store securely)
PRIVATE_KEY_HEX = "your-64-char-hex-private-key"
private_key = PrivateKey(bytes.fromhex(PRIVATE_KEY_HEX))
public_key_hex = private_key.pubkey.serialize().hex()[2:]  # Remove 02/03 prefix

RELAYS = [
    "wss://relay.damus.io",
    "wss://nos.lol",
    "wss://relay.primal.net"
]

async def connect_to_relay(url):
    async with websockets.connect(url) as ws:
        # Subscribe to DMs (gift wraps) addressed to bot
        dm_filter = {
            "kinds": [1059],
            "#p": [public_key_hex],
            "since": int(time.time()) - 3600  # Last hour
        }
        
        # Subscribe to geohash channel (e.g., San Francisco)
        geo_filter = {
            "kinds": [20000, 20001],
            "#g": ["9q8yy"],  # 5-char geohash prefix
            "since": int(time.time()) - 300  # Last 5 minutes
        }
        
        await ws.send(json.dumps(["REQ", "dm-sub", dm_filter]))
        await ws.send(json.dumps(["REQ", "geo-sub", geo_filter]))
        
        async for message in ws:
            data = json.loads(message)
            if data[0] == "EVENT":
                sub_id = data[1]
                event = data[2]
                await handle_event(ws, sub_id, event)
            elif data[0] == "EOSE":
                print(f"End of stored events for {data[1]}")

async def handle_event(ws, sub_id, event):
    kind = event["kind"]
    
    if kind == 1059:
        # Gift-wrapped DM - needs NIP-44 decryption
        # Decrypt seal, then decrypt rumor inside
        content = decrypt_gift_wrap(event)
        sender = get_sender_from_seal(event)
        print(f"DM from {sender}: {content}")
        
        # Auto-reply example
        if "hello" in content.lower():
            await send_dm(ws, sender, "Hey! What's up?")
            
    elif kind == 20000:
        # Public geohash message
        content = event["content"]
        sender = event["pubkey"]
        geohash = next((t[1] for t in event["tags"] if t[0] == "g"), None)
        nickname = next((t[1] for t in event["tags"] if t[0] == "n"), "anon")
        print(f"[{geohash}] {nickname}: {content}")
        
        # Auto-reply to public channel
        if "!help" in content:
            await send_geohash_message(ws, geohash, "Bot commands: !help, !time, !quote")

async def send_dm(ws, recipient_pubkey, content):
    """Send NIP-17 encrypted DM"""
    # 1. Create rumor (kind 14, unsigned)
    # 2. Encrypt rumor into seal (kind 13)
    # 3. Wrap seal in gift wrap (kind 1059)
    # Implementation requires NIP-44 encryption
    pass

async def send_geohash_message(ws, geohash, content):
    """Send ephemeral geohash message"""
    event = {
        "pubkey": public_key_hex,
        "created_at": int(time.time()),
        "kind": 20000,
        "tags": [
            ["g", geohash],
            ["n", "bitbot"]
        ],
        "content": content
    }
    event["id"] = compute_event_id(event)
    event["sig"] = sign_event(event)
    
    await ws.send(json.dumps(["EVENT", event]))

def compute_event_id(event):
    """Compute NIP-01 event ID"""
    serialized = json.dumps([
        0,
        event["pubkey"],
        event["created_at"],
        event["kind"],
        event["tags"],
        event["content"]
    ], separators=(',', ':'), ensure_ascii=False)
    return hashlib.sha256(serialized.encode()).hexdigest()

def sign_event(event):
    """Sign event with Schnorr signature"""
    msg = bytes.fromhex(event["id"])
    sig = private_key.schnorr_sign(msg, None, raw=True)
    return sig.hex()

# Run the bot
asyncio.run(connect_to_relay(RELAYS[0]))
```

### Node.js Example

```javascript
const WebSocket = require('ws');
const { schnorr } = require('@noble/curves/secp256k1');
const { sha256 } = require('@noble/hashes/sha256');
const { bytesToHex, hexToBytes } = require('@noble/hashes/utils');

const PRIVATE_KEY = 'your-64-char-hex-private-key';
const PUBLIC_KEY = bytesToHex(schnorr.getPublicKey(PRIVATE_KEY));

const RELAYS = [
  'wss://relay.damus.io',
  'wss://nos.lol',
  'wss://relay.primal.net'
];

function connectToRelay(url) {
  const ws = new WebSocket(url);
  
  ws.on('open', () => {
    console.log(`Connected to ${url}`);
    
    // Subscribe to DMs
    const dmFilter = {
      kinds: [1059],
      '#p': [PUBLIC_KEY],
      since: Math.floor(Date.now() / 1000) - 3600
    };
    
    // Subscribe to geohash channel
    const geoFilter = {
      kinds: [20000, 20001],
      '#g': ['9q8yy'],
      since: Math.floor(Date.now() / 1000) - 300
    };
    
    ws.send(JSON.stringify(['REQ', 'dm-sub', dmFilter]));
    ws.send(JSON.stringify(['REQ', 'geo-sub', geoFilter]));
  });
  
  ws.on('message', (data) => {
    const msg = JSON.parse(data);
    
    if (msg[0] === 'EVENT') {
      const event = msg[2];
      handleEvent(ws, event);
    }
  });
}

function handleEvent(ws, event) {
  if (event.kind === 20000) {
    const geohash = event.tags.find(t => t[0] === 'g')?.[1];
    const nickname = event.tags.find(t => t[0] === 'n')?.[1] || 'anon';
    console.log(`[${geohash}] ${nickname}: ${event.content}`);
    
    // Respond to triggers
    if (event.content.includes('!ping')) {
      sendGeohashMessage(ws, geohash, 'pong!');
    }
  }
}

function sendGeohashMessage(ws, geohash, content) {
  const event = {
    pubkey: PUBLIC_KEY,
    created_at: Math.floor(Date.now() / 1000),
    kind: 20000,
    tags: [['g', geohash], ['n', 'bitbot']],
    content: content
  };
  
  // Compute ID
  const serialized = JSON.stringify([
    0, event.pubkey, event.created_at, 
    event.kind, event.tags, event.content
  ]);
  event.id = bytesToHex(sha256(new TextEncoder().encode(serialized)));
  
  // Sign
  event.sig = bytesToHex(schnorr.sign(event.id, PRIVATE_KEY));
  
  ws.send(JSON.stringify(['EVENT', event]));
}

// Connect to all relays
RELAYS.forEach(connectToRelay);
```

---

## Approach 2: Internal Bot (Swift Integration)

Integrate bot logic directly into the BitChat codebase or a Swift-based companion app.

### Key Classes

| Class | Purpose | File |
|-------|---------|------|
| `NostrRelayManager` | WebSocket connections | `bitchat/Nostr/NostrRelayManager.swift` |
| `NostrProtocol` | Event creation/decryption | `bitchat/Nostr/NostrProtocol.swift` |
| `NostrIdentity` | Key management | `bitchat/Identity/NostrIdentity.swift` |
| `NostrFilter` | Subscription filters | `bitchat/Nostr/NostrFilter.swift` |
| `GeoRelayDirectory` | Geographic relay routing | `bitchat/Nostr/GeoRelayDirectory.swift` |

### Swift Bot Example

```swift
import Foundation

class BitBot {
    let identity: NostrIdentity
    let relayManager = NostrRelayManager.shared
    
    init() throws {
        // Generate new identity or load existing
        self.identity = try NostrIdentity.generate()
        print("Bot pubkey: \(identity.publicKeyHex)")
    }
    
    func start() {
        // Connect to relays
        relayManager.connect()
        
        // Subscribe to DMs addressed to bot
        let dmFilter = NostrFilter.giftWrapsFor(
            pubkey: identity.publicKeyHex,
            since: Date().addingTimeInterval(-3600)
        )
        
        relayManager.subscribe(
            filter: dmFilter,
            id: "bot-dm-subscription"
        ) { [weak self] event in
            self?.handleDM(event)
        }
        
        // Subscribe to geohash channel
        let geoFilter = NostrFilter.geohashEphemeral(
            "9q8yy",
            since: Date().addingTimeInterval(-300),
            limit: 50
        )
        
        relayManager.subscribe(
            filter: geoFilter,
            id: "bot-geo-subscription"
        ) { [weak self] event in
            self?.handleGeohashMessage(event)
        }
    }
    
    private func handleDM(_ giftWrap: NostrEvent) {
        do {
            let (content, senderPubkey, _) = try NostrProtocol.decryptPrivateMessage(
                giftWrap: giftWrap,
                recipientIdentity: identity
            )
            
            print("DM from \(senderPubkey.prefix(8)): \(content)")
            
            // Auto-reply logic
            if content.lowercased().contains("hello") {
                sendDM(to: senderPubkey, content: "Hey! What's up?")
            }
            
        } catch {
            print("Failed to decrypt DM: \(error)")
        }
    }
    
    private func handleGeohashMessage(_ event: NostrEvent) {
        let geohash = event.tags.first { $0.first == "g" }?[safe: 1] ?? "unknown"
        let nickname = event.tags.first { $0.first == "n" }?[safe: 1] ?? "anon"
        
        print("[\(geohash)] \(nickname): \(event.content)")
        
        // Respond to triggers
        if event.content.contains("!help") {
            // Rate limit check
            sendGeohashMessage(
                geohash: geohash,
                content: "Bot commands: !help, !time, !quote"
            )
        }
    }
    
    private func sendDM(to recipientPubkey: String, content: String) {
        do {
            let event = try NostrProtocol.createPrivateMessage(
                content: content,
                recipientPubkey: recipientPubkey,
                senderIdentity: identity
            )
            relayManager.sendEvent(event)
        } catch {
            print("Failed to send DM: \(error)")
        }
    }
    
    private func sendGeohashMessage(geohash: String, content: String) {
        do {
            let event = try NostrProtocol.createEphemeralGeohashEvent(
                content: content,
                geohash: geohash,
                senderIdentity: identity,
                nickname: "bitbot",
                teleported: false
            )
            
            // Route to geographic relays
            let relays = GeoRelayDirectory.shared.closestRelays(
                toGeohash: geohash,
                count: 5
            )
            relayManager.sendEvent(event, to: relays)
            
        } catch {
            print("Failed to send geohash message: \(error)")
        }
    }
}
```

### Using Transport Protocol

For deeper integration, implement or use the `Transport` protocol:

```swift
// From bitchat/Protocols/Transport.swift
protocol Transport: AnyObject {
    var myPeerID: PeerID { get }
    var myNickname: String { get }
    
    func sendMessage(_ content: String, mentions: [String])
    func sendPrivateMessage(_ content: String, to peerID: PeerID, 
                           recipientNickname: String, messageID: String)
    func sendReadReceipt(_ receipt: ReadReceipt, to peerID: PeerID)
    func sendDeliveryAck(for messageID: String, to peerID: PeerID)
    
    func startServices()
    func stopServices()
}
```

### BitChat Packet Embedding

For full compatibility with BitChat's packet format, use `NostrEmbeddedBitChat`:

```swift
// Encode a private message with BitChat packet format
let encoded = NostrEmbeddedBitChat.encodePMForNostr(
    content: "Hello!",
    messageID: UUID().uuidString,
    recipientPeerID: recipientPeerID,
    senderPeerID: myPeerID
)
// Result: "bitchat1:<base64url-encoded-packet>"

// Encode delivery acknowledgment
let ackEncoded = NostrEmbeddedBitChat.encodeAckForNostr(
    type: .deliveryAck,
    messageID: originalMessageID,
    recipientPeerID: recipientPeerID,
    senderPeerID: myPeerID
)
```

---

## Subscription Filters

### NostrFilter Builders

```swift
// DMs (gift wraps) for a specific pubkey
NostrFilter.giftWrapsFor(pubkey: "hex...", since: Date())

// Ephemeral geohash messages (kind 20000)
NostrFilter.geohashEphemeral("9q8yy", since: Date(), limit: 100)

// Persistent geohash notes (kind 1)
NostrFilter.geohashNotes("9q8yy", since: Date(), limit: 50)

// Presence heartbeats (kind 20001)
NostrFilter(kinds: [20001], tags: ["#g": ["9q8yy"]], since: Date())
```

### Raw Filter JSON

```json
{
  "kinds": [1059],
  "#p": ["<recipient-pubkey>"],
  "since": 1707350400,
  "limit": 100
}
```

```json
{
  "kinds": [20000, 20001],
  "#g": ["9q8yy"],
  "since": 1707350400,
  "limit": 50
}
```

---

## NIP-44 Encryption (Required for DMs)

Gift-wrapped DMs use NIP-44 encryption. Key libraries:

| Language | Library |
|----------|---------|
| Python | `nostr-sdk`, `pynostr` |
| JavaScript | `@noble/ciphers`, `nostr-tools` |
| Swift | Built into BitChat (`NostrProtocol.swift`) |
| Rust | `nostr-sdk` |

### Encryption Flow

1. **Create rumor** (kind 14) — unsigned event with DM content
2. **Seal rumor** (kind 13) — encrypt rumor with NIP-44 to recipient, sign with sender key
3. **Gift wrap seal** (kind 1059) — encrypt seal with NIP-44, sign with disposable key

### Decryption Flow

1. **Unwrap gift** — decrypt kind 1059 content to get seal
2. **Open seal** — decrypt kind 13 content to get rumor
3. **Read rumor** — extract kind 14 content (the actual message)

---

## Best Practices

### Do's

- ✅ Generate a dedicated keypair for your bot
- ✅ Store private keys securely (keychain, env vars, secrets manager)
- ✅ Respect rate limits (350ms between acks, reasonable message frequency)
- ✅ Handle `EOSE` before processing live events
- ✅ Reconnect on WebSocket disconnection with exponential backoff
- ✅ Use multiple relays for redundancy
- ✅ Include a recognizable nickname in geohash messages

### Don'ts

- ❌ Spam relays with rapid-fire messages
- ❌ Send read receipts for every message instantly (batch them)
- ❌ Hardcode relay URLs without fallbacks
- ❌ Ignore signature verification on received events
- ❌ Store private keys in plaintext

---

## Debugging

### Monitor Relay Traffic

Use `websocat` to inspect relay traffic:

```bash
# Install
brew install websocat

# Connect and subscribe
echo '["REQ", "debug", {"kinds": [20000], "#g": ["9q8yy"], "limit": 10}]' | \
  websocat wss://relay.damus.io
```

### Verify Event Signatures

```python
from secp256k1 import PublicKey

def verify_event(event):
    pubkey = PublicKey(bytes.fromhex("02" + event["pubkey"]), raw=True)
    msg = bytes.fromhex(event["id"])
    sig = bytes.fromhex(event["sig"])
    return pubkey.schnorr_verify(msg, sig, None, raw=True)
```

---

## Related Files

| File | Description |
|------|-------------|
| `bitchat/Nostr/NostrRelayManager.swift` | Relay connection management |
| `bitchat/Nostr/NostrProtocol.swift` | Event creation and encryption |
| `bitchat/Nostr/NostrFilter.swift` | Subscription filter builders |
| `bitchat/Nostr/NostrEvent.swift` | Event data structure |
| `bitchat/Nostr/GeoRelayDirectory.swift` | Geographic relay routing |
| `bitchat/Identity/NostrIdentity.swift` | Key generation and management |
| `bitchat/Nostr/NostrEmbeddedBitChat.swift` | BitChat packet encoding |
| `bitchat/Utils/Constants.swift` | Rate limits and configuration |
| `bitchat/Protocols/Transport.swift` | Abstract transport interface |
