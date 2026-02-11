# Stealth Addresses & EIL Integration Plan

## Overview

This document describes the implementation of EIP-5564 stealth addresses and EIL (Ethereum Interop Layer) cross-chain swaps using EIP-7702 for the bitchat embedded wallet.

## Phase 1: EIP-5564 Stealth Addresses ✅

### Summary

Stealth addresses allow receivers to publish a single "meta-address" that senders use to derive unique one-time addresses. Only the receiver can detect and spend from these addresses.

### Key Components

1. **StealthAddressManager.swift** - Core cryptographic operations
   - Key derivation: `viewingKey = keccak256(spendingKey || "stealth-viewing-key")`
   - `generateStealthAddress(for:)` - Sender generates stealth address
   - `checkStealthAddress(ephemeralPubKey:viewTag:announcedAddress:)` - Recipient scans
   - `computeStealthKey(ephemeralPubKey:)` - Derive private key for owned address
   - `getStealthMetaAddress()` - Returns `st:eth:0x<P_spend><P_view>`
   - `generateSelfStealthAddress(derivationIndex:)` - Generate deterministic self-controlled addresses

2. **StealthAddressStore.swift** - Persistence layer
   - Stores discovered addresses with labels, balances, ephemeral keys
   - Tracks scan progress per chain
   - Supports multiple chains
   - Tracks self-generated vs discovered addresses via `isSelfGenerated` flag
   - Maintains `derivationIndex` for self-generated address ordering

3. **UI Components**
   - `StealthAddressListView.swift` - List of discovered addresses with self-generation UI
   - `StealthAddressDetailView.swift` - Single address details, sweep functionality
   - Integration in `WalletView.swift` - Quick access card

### Technical Details

- **ERC5564Announcer**: `0x55649E01B5Df198D18D95b5cc5051630cfD45564`
- **Scheme ID**: 1 (SECP256k1 with view tags)
- **View Tag**: First byte of `keccak256(shared_secret)` - filters 99.6% of non-matching announcements
- **Meta-address format**: `st:eth:0x<33-byte P_spend><33-byte P_view>`

### Stealth Address Formula

```
Sender:
  r = random scalar
  R = r * G (ephemeral public key)
  S = r * P_view (shared secret via ECDH)
  view_tag = keccak256(S)[0]
  P_stealth = P_spend + keccak256(S) * G

Recipient:
  S = viewing_key * R (shared secret via ECDH)
  if view_tag matches:
    P_stealth = P_spend + keccak256(S) * G
    stealth_key = spending_key + keccak256(S)
```

### Self-Generated Stealth Addresses ✅

Users can generate their own stealth addresses deterministically for receiving payments. This allows users to create multiple unique addresses all controlled by the same spending key.

#### Purpose

- Generate fresh receiving addresses without third-party involvement
- Each address is deterministically derived, ensuring recoverability from seed
- Display all generated addresses with their respective balances in one view
- Fund via atomic swaps, exchanges, or DEXs for enhanced privacy

#### Derivation Formula

```
Self-Generated Stealth Address:
  index = 0, 1, 2, ... (sequential derivation index)
  ephemeral_key = HMAC-SHA256(viewing_private_key, "self-stealth-ephemeral:" || index)
  R = ephemeral_key * G (ephemeral public key)
  S = ephemeral_key * P_view (shared secret - same as ECDH with self)
  view_tag = keccak256(S)[0]
  P_stealth = P_spend + keccak256(S) * G
  
  // To spend:
  stealth_private_key = spending_key + keccak256(S)
```

#### Key Properties

1. **Deterministic**: Same index always yields same address
2. **Recoverable**: All addresses can be regenerated from seed + index
3. **Unlinkable**: Each address appears random to outside observers
4. **Self-controllable**: No sender interaction needed to generate

## Phase 2: EIP-7702 Transaction Support ✅

### Summary

EIP-7702 "Set Code" transactions allow EOAs to temporarily delegate to smart contract code, enabling account abstraction features without deploying a separate smart wallet.

### Implementation

Added to `EmbeddedWallet.swift`:
- `EIP7702Authorization` struct for authorization parameters
- `signAuthorization(_:)` - Signs authorization tuples
- `signEIP7702Transaction(...)` - Signs type 0x04 transactions

### Transaction Structure

```
Type 0x04 RLP([
  chain_id, nonce, max_priority_fee_per_gas, max_fee_per_gas,
  gas_limit, to, value, data, access_list,
  authorization_list,  // New in EIP-7702
  y_parity, r, s
])
```

### Authorization Structure

```
Authorization RLP([
  chain_id, address, nonce, y_parity, r, s
])
```

Authorization signing: `keccak256(0x05 || rlp([chain_id, address, nonce]))`

## Phase 3: EIL Cross-Chain Integration ✅

### Summary

The Ethereum Interop Layer enables trustless cross-chain swaps through XLP (Cross-chain Liquidity Provider) networks.

### Key Components

1. **EILCrossChainManager.swift** - Swap orchestration
   - Quote generation
   - Voucher request creation
   - Swap execution with EIP-7702 authorization
   - Request tracking

2. **CrossChainSwapView.swift** - Swap UI
   - Chain selection (source/destination)
   - Amount input with balance display
   - Quote display with fee breakdown
   - Slippage tolerance configuration
   - Swap status tracking

### Supported Chains

| Chain | ID | Status |
|-------|-----|--------|
| Ethereum | 1 | Pending contract deployment |
| Optimism | 10 | Pending contract deployment |
| Base | 8453 | Pending contract deployment |
| Arbitrum | 42161 | Pending contract deployment |
| Sepolia | 11155111 | Pending contract deployment |

### Swap Flow

1. User selects source chain, destination chain, amount
2. System queries XLP network for liquidity
3. User reviews quote (destination amount, fees, time estimate)
4. User confirms → EIP-7702 authorization signed
5. Swap transaction submitted to source chain
6. XLP fulfills on destination chain
7. User receives funds at destination address

### VoucherRequest Lifecycle

```
pending → sourcing → matched → submitted → confirming → bridging → completing → completed
                                                                              → failed
                                                                              → expired
```

## Settings Integration ✅

Added to `XMTPSettingsView.swift`:
- **Stealth Scanning Toggle** - Enable/disable background scanning
- **Scan Interval Picker** - 30s, 1min, 5min, 15min options
- **EIL Swaps Toggle** - Enable/disable cross-chain features

## Files Created

| File | Purpose |
|------|---------|
| `bitchat/XMTP/StealthAddressManager.swift` | EIP-5564 cryptographic operations |
| `bitchat/XMTP/StealthAddressStore.swift` | Persistence for stealth addresses |
| `bitchat/XMTP/EILCrossChainManager.swift` | EIL cross-chain swap manager |
| `bitchat/Views/StealthAddressListView.swift` | List UI for stealth addresses |
| `bitchat/Views/StealthAddressDetailView.swift` | Detail view for single address |
| `bitchat/Views/CrossChainSwapView.swift` | Cross-chain swap UI |

## Files Modified

| File | Changes |
|------|---------|
| `bitchat/XMTP/EmbeddedWallet.swift` | Added EIP-7702 authorization and type 0x04 transactions |
| `bitchat/Views/WalletView.swift` | Added stealth and cross-chain sections |
| `bitchat/Views/XMTPSettingsView.swift` | Added stealth and EIL settings |

## Future Work

### Stealth Addresses
- [x] Self-generated stealth addresses with deterministic derivation
- [x] UI for generating and viewing self-generated addresses with balances
- [ ] Implement background scanning service
- [ ] Add announcement event indexer integration
- [ ] Support token transfers (not just ETH)
- [ ] ENS stealth meta-address resolution

### EIP-7702
- [ ] Batch authorization signing
- [ ] Authorization revocation tracking
- [ ] Gas estimation for delegated calls

### EIL Cross-Chain
- [ ] Real XLP network integration (pending contract deployments)
- [ ] Multi-hop routing for better rates
- [ ] Historical swap tracking
- [ ] Push notifications for swap completion

## Security Considerations

1. **Stealth Key Derivation**: Viewing key derived deterministically from spending key reduces backup complexity but requires spending key protection.

2. **View Tag Privacy**: View tags leak 1 bit of information per announcement but dramatically reduce scanning cost.

3. **EIP-7702 Authorizations**: Authorizations are chain-specific and nonce-bound, preventing replay across chains or transactions.

4. **EIL Slippage**: User-configurable slippage protection prevents front-running on destination chain.

## Testing

### Unit Tests Needed
- [ ] Stealth address generation/verification round-trip
- [ ] EIP-7702 transaction encoding
- [ ] Authorization signature verification
- [ ] Quote calculation logic

### Integration Tests Needed
- [ ] Full stealth payment flow (generate → announce → scan → sweep)
- [ ] Cross-chain swap end-to-end (when testnet contracts available)

## References

- [EIP-5564: Stealth Addresses](https://eips.ethereum.org/EIPS/eip-5564)
- [EIP-7702: Set Code Transaction](https://eips.ethereum.org/EIPS/eip-7702)
- [EIL Specification](https://github.com/eth-infinitism/eil-contracts)
- [ERC5564Announcer](https://etherscan.io/address/0x55649E01B5Df198D18D95b5cc5051630cfD45564)
