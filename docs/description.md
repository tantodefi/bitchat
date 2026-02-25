# bitchat

**Offline-first, decentralized messaging with a post-quantum ERC-4337 smart wallet — built for iOS and macOS, live on the App Store today.**

---

## Triple Transport Architecture

- **BLE Mesh** — Multi-hop Bluetooth relay (up to 7 hops) with `Noise_XX_25519_ChaChaPoly_SHA256` encryption. Zero infrastructure. Works in disasters, protests, off-grid.
- **Nostr** — Location-based geohash channels over 290+ global relays with NIP-17 gift-wrapped DMs and ephemeral per-channel identity.
- **XMTP** — MLS-encrypted wallet-to-wallet group messaging with WalletSendCalls (XIP-59) for in-chat DeFi transactions and bot/agent integration.

All internet traffic is **Tor-routed by default** (fail-closed). No accounts, no phone numbers, no servers.

---

## Post-Quantum Smart Wallet (Arbitrum)

Hybrid **ECDSA secp256k1 + ML-DSA-44** (FIPS 204) ERC-4337 account via ZKNOX factory contracts. Both signatures required for every UserOperation — secure even if either scheme is broken.

- **Stealth PQ addresses** (Fluidkey-style) with offline CREATE2 prediction, deploy-on-sweep, and auto-rotating ENS via Namestone (`alice.pq.dstealth.eth`)
- **Offline transaction signing** relayed through BLE mesh to online peers who broadcast via Flashbots Protect

**Trustless verification:** a16z's **Helios light client** compiled to iOS via Rust FFI provides consensus-verified balance queries — no RPC trust required. 3-tier fallback: Helios → Merkle proof → raw RPC.

---

## PQBeat — Stage 1 Wallet

> [github.com/ZKNoxHQ/PQbeat](https://github.com/ZKNoxHQ/PQbeat)

bitchat is one of the first mobile wallets with production PQ smart account support:

| PQBeat Criteria | bitchat |
|---|---|
| PQ Key Generation | ✅ ML-DSA-44 (SwiftDilithium, FIPS 204) |
| PQ Smart Account | ✅ ZKNOX `mldsa_k1` factory on Arbitrum |
| PQ Signing | ✅ Hybrid ECDSA + ML-DSA-44 for every UserOp |
| Chain Stage | Stage 1 (ERC-4337 + PQ signature verification via smart contract) |

Among wallets tracked by PQBeat, only ZKNOX's own reference implementation currently meets these criteria.

---

## Walletbeat — Evaluation Pillars

> [github.com/walletbeat/walletbeat](https://github.com/walletbeat/walletbeat)

bitchat targets top marks across all six walletbeat evaluation pillars:

| Pillar | How bitchat delivers |
|---|---|
| 🔒 **Security** | Hybrid PQ signatures, Noise Protocol forward secrecy, rate limiting, replay protection, PKCS#7 traffic analysis padding |
| 😎 **Privacy** | Tor-by-default, ephemeral keys per geohash, stealth addresses, zero persistent identifiers, triple-tap panic wipe |
| 🏰 **Self-sovereignty** | No accounts, no servers, no phone numbers, offline-capable, local-only key storage (Keychain), emergency data wipe |
| 🕵 **Transparency** | Public domain license, fully open source, no telemetry |
| 🌳 **Ecosystem** | ERC-4337, ERC-1271, Aave V3 DeFi integration (WIP), ENS subdomains, XMTP interop, Nostr interop |
| 🛠️ **Maintenance** | Active development, live on App Store, 21+ test suites |

---

## Stack

Swift/SwiftUI · Noise Protocol · Nostr · XMTP · SwiftDilithium (ML-DSA-44) · ERC-4337 v0.7 · Helios (Rust FFI) · Tor (Arti SOCKS5) · Arbitrum

---

📲 [App Store](https://apps.apple.com/us/app/bitchat-mesh/id6748219622) · 🔓 Public Domain · 🌐 [bitchat.free](http://bitchat.free)
