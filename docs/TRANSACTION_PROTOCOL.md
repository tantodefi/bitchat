# BitChat Transaction Protocol Design

This document describes the native transaction support for BitChat, integrating seamlessly with XMTP standards while enabling offline mesh network transactions.

## Overview

BitChat supports two transaction flows:

1. **Online (XMTP)** — Standard XMTP `WalletSendCalls` codec for requesting transactions in conversations
2. **Offline (BLE Mesh)** — Native Noise-encrypted transaction relay through mesh network

## XMTP Standard Codecs

### WalletSendCalls (Transaction Request)

Used to request a transaction from a conversation peer. Standard XMTP content type.

```
ContentTypeId {
    authority_id: "xmtp.org",
    type_id:      "walletSendCalls",
    version_major: 1,
    version_minor: 0,
}
```

**Structure:**
```swift
WalletSendCalls {
    version: String           // "1.0"
    chainId: String           // Hex chain ID, e.g., "0x1" (mainnet), "0xaa36a7" (sepolia)
    from: String              // Sender wallet address
    calls: [Call]             // Array of calls to execute
    capabilities: [String: String]  // Wallet capabilities to request
}

Call {
    to: String                // Destination address
    data: String              // Call data payload (hex)
    value: String             // Value to send (hex wei)
    gas: String               // Gas limit (hex)
    metadata: [String: String] // Display metadata
}
```

**Metadata fields:**
- `description`: Human-readable description
- `transactionType`: "transfer", "swap", "lend", "mint", etc.
- `currency`: Token symbol (ETH, USDC, etc.)
- `amount`: Numeric amount (in smallest unit)
- `decimals`: Token decimals
- `toAddress`: Recipient address
- `platform`: DeFi platform name
- `apy`: APY percentage (for lending)

### TransactionReference (Completed Transaction)

Used to share a completed transaction hash.

```
ContentTypeId {
    authority_id: "xmtp.org",
    type_id:      "transactionReference",
    version_major: 1,
    version_minor: 0,
}
```

**Structure:**
```swift
TransactionReference {
    namespace: String         // "eip155"
    networkId: UInt64         // Chain ID (1 = mainnet)
    reference: String         // Transaction hash
    metadata: TransactionMetadata
}
```

## Native Mesh Transaction Protocol

### Packet Types

| Type | Hex | Description |
|------|-----|-------------|
| `txRequest` | `0x50` | Request transaction relay |
| `txSigned` | `0x51` | Pre-signed transaction for broadcast |
| `txConfirm` | `0x52` | Transaction confirmation with hash |
| `txReject` | `0x53` | Transaction rejected by relay peer |

### Flow: Offline Transaction Relay

```
┌──────────────────┐                              ┌──────────────────┐
│  Offline Signer  │                              │  Online Relay    │
│  (has wallet)    │                              │  (has internet)  │
└────────┬─────────┘                              └────────┬─────────┘
         │                                                 │
         │  1. Sign transaction locally                    │
         │     (raw tx bytes, not a request)              │
         │                                                 │
         │  2. Send 0x51 (txSigned)                       │
         │  ─────────────────────────────────────────────▶│
         │     Noise-encrypted BLE packet                  │
         │     Contains: signed tx + chain ID + nonce      │
         │                                                 │
         │                        3. Validate tx format    │
         │                           Check gas, nonce      │
         │                                                 │
         │                        4. Broadcast to RPC      │
         │                           (Flashbots Protect)   │
         │                                                 │
         │  5. Receive 0x52 (txConfirm)                   │
         │◀─────────────────────────────────────────────── │
         │     Contains: tx hash + status                  │
         │                                                 │
```

### Packet Structure: TxSigned (0x51)

```
┌─────────────────────────────────────────────────────────┐
│ BitchatPacket (Noise-encrypted)                         │
├─────────────────────────────────────────────────────────┤
│ type: 0x51                                              │
│ ttl: 2 (limited hops for security)                      │
│ senderID: 8 bytes                                       │
│ payload: TxSignedPayload                                │
└─────────────────────────────────────────────────────────┘

TxSignedPayload (CBOR-encoded):
┌─────────────────────────────────────────────────────────┐
│ requestId: UUID (16 bytes)                              │
│ chainId: UInt64                                         │
│ signedTx: Data (RLP-encoded signed transaction)         │
│ nonce: UInt64                                           │
│ gasLimit: UInt64                                        │
│ maxFeePerGas: UInt64                                    │
│ maxPriorityFee: UInt64                                  │
│ metadata: TransactionMetadata (optional display info)   │
│ replyTo: PeerID (for confirmation delivery)             │
└─────────────────────────────────────────────────────────┘
```

### Packet Structure: TxConfirm (0x52)

```
TxConfirmPayload (CBOR-encoded):
┌─────────────────────────────────────────────────────────┐
│ requestId: UUID (matches TxSigned.requestId)            │
│ txHash: 32 bytes                                        │
│ status: UInt8 (0=pending, 1=confirmed, 2=failed)        │
│ blockNumber: UInt64? (if confirmed)                     │
│ gasUsed: UInt64? (if confirmed)                         │
│ errorMessage: String? (if failed)                       │
└─────────────────────────────────────────────────────────┘
```

### Security Considerations

1. **Noise Encryption**: All transaction packets are encrypted end-to-end via established Noise sessions
2. **TTL Limiting**: `ttl: 2` prevents transactions from propagating too far through the mesh
3. **Pre-signed**: The offline user signs the full transaction locally — relay peers cannot modify it
4. **Replay Protection**: `requestId` + `nonce` prevents replay attacks
5. **MEV Protection**: Relay peers SHOULD use Flashbots Protect or similar private mempools

### Privacy Tradeoffs

| Strategy | Privacy | Speed | Notes |
|----------|---------|-------|-------|
| Queue locally | ⭐⭐⭐ | ❌ | Wait for direct internet |
| Relay via mesh | ⭐⭐ | ✅ | Relay peer sees tx metadata |
| XMTP request | ⭐ | ✅ | Recipient must approve |

## Integration with XMTP

### Hybrid Flow: Request via XMTP, Relay via Mesh

```
┌─────────────┐    XMTP (online)    ┌─────────────┐
│   Agent     │ ◀──────────────────▶│    User     │
│  (server)   │  WalletSendCalls    │  (mobile)   │
└─────────────┘                     └──────┬──────┘
                                           │
                                           │ User goes offline
                                           │ but wants to proceed
                                           ▼
                                    ┌─────────────┐
                                    │   User      │
                                    │  signs tx   │
                                    │  locally    │
                                    └──────┬──────┘
                                           │
                                           │ BLE Mesh (offline)
                                           ▼
                                    ┌─────────────┐
                                    │ Mesh Peer   │
                                    │ (has inet)  │──────▶ RPC
                                    └─────────────┘
```

### Codec Registration

```swift
// Register XMTP transaction codecs
Client.register(codec: WalletSendCallsCodec())
Client.register(codec: TransactionReferenceCodec())

// For receiving transaction requests from agents
func handleMessage(_ message: DecodedMessage) {
    if let walletSendCalls = try? message.content() as WalletSendCalls {
        // Show transaction approval UI
        showTransactionTray(walletSendCalls)
    }
    
    if let txRef = try? message.content() as TransactionReference {
        // Show completed transaction
        showTransactionConfirmation(txRef)
    }
}
```

## UI Components

### Transaction Tray

A slide-up UI for approving transactions requested via XMTP:

```
┌─────────────────────────────────────────┐
│ 🔄 Transaction Request                  │
├─────────────────────────────────────────┤
│                                         │
│ Send 0.1 ETH to vitalik.eth             │
│                                         │
│ ┌─────────────────────────────────────┐ │
│ │ From: 0x1234...5678                 │ │
│ │ To:   0xd8dA...6045                 │ │
│ │ Value: 0.1 ETH (~$250)              │ │
│ │ Gas:   ~0.002 ETH                   │ │
│ │ Chain: Ethereum Mainnet             │ │
│ └─────────────────────────────────────┘ │
│                                         │
│ Network Status: [🟢 Online] [📴 Mesh]   │
│                                         │
│ ┌─────────┐              ┌───────────┐  │
│ │ Reject  │              │  Approve  │  │
│ └─────────┘              └───────────┘  │
│                                         │
│ ☐ Allow mesh relay if offline           │
└─────────────────────────────────────────┘
```

### Transaction Status Card

In-conversation display of transaction state:

```
┌─────────────────────────────────────────┐
│ ✅ Transaction Confirmed                │
│                                         │
│ Sent 0.1 ETH to vitalik.eth             │
│ Tx: 0xabc...123 ↗                       │
│ Block: 19,234,567                       │
│ Gas used: 21,000                        │
│                                         │
│ 2 minutes ago                           │
└─────────────────────────────────────────┘
```

## Implementation Checklist

### XMTP Integration

- [x] Register `AttachmentCodec` in `XMTPClientService.connect()`
- [x] Register `RemoteAttachmentCodec` in `XMTPClientService.connect()`
- [ ] Register `WalletSendCallsCodec` (requires Swift SDK support verification)
- [ ] Register `TransactionReferenceCodec` (requires Swift SDK support verification)
- [x] Create `TransactionTrayView` SwiftUI component
- [x] Create `TransactionStatusCard` for in-chat display
- [ ] Add `handleWalletSendCalls()` message handler
- [ ] Send `TransactionReference` after successful broadcast

### Mesh Protocol

- [x] Define `TxPacketType` enum (0x50-0x53) in `MeshTransactionTypes.swift`
- [x] Create `TxSignedPayload` Codable struct
- [x] Create `TxConfirmPayload` Codable struct
- [x] Create `TxRejectPayload` Codable struct
- [x] Add packet types to `MessageType` enum in `BitchatProtocol.swift`
- [x] Add packet handlers to `BLEService` (`handleTxSigned`, `handleTxConfirm`, `handleTxReject`)
- [x] Implement `MeshTransactionRelay` service
- [x] Implement relay peer broadcast logic
- [x] Add RPC broadcast via Flashbots Protect

### Transaction Signing

- [x] Implement EIP-1559 transaction signing in `EmbeddedWallet`
- [x] Implement RLP encoding helpers
- [x] Create `TransactionSigner` high-level service

### Service Integration

- [x] Add `MeshTransactionRelay` to `XMTPServiceContainer`
- [x] Add `configureBLEService()` method to wire up BLE reference
- [x] Wire up in `BitchatApp.swift` during initialization
- [x] Create `TransactionSigner` convenience factory

## References

- [XIP-59: Trigger on-chain calls via wallet_sendCalls](https://community.xmtp.org/t/xip-59-trigger-on-chain-calls-via-wallet-sendcalls/889)
- [XMTP TransactionReference Content Type](https://github.com/xmtp/xmtp-ios/tree/main/Sources/XMTPiOS/Codecs)
- [EIP-5792: wallet_sendCalls](https://eips.ethereum.org/EIPS/eip-5792)
- [Flashbots Protect RPC](https://protect.flashbots.net)
