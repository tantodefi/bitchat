# Helios Light Client Integration

> **Status:** Complete (Phase 1 ✅, Phase 2 ✅, Phase 3 ✅)  
> **Last Updated:** July 2025  
> **Repository:** https://github.com/a16z/helios

## Overview

[Helios](https://github.com/a16z/helios) is a trustless, efficient, and portable multichain Ethereum light client written in Rust by a16z. It converts untrusted centralized RPC endpoints into cryptographically verified local RPC responses—eliminating the need to trust third-party providers like Infura, Alchemy, or even Flashbots.

### Why Helios for bitchat?

bitchat routes all Ethereum RPC calls through Tor for IP privacy, but still **trusts** the RPC provider to return honest data. Helios closes this gap:

| Layer | Without Helios | With Helios |
|-------|---------------|-------------|
| **Network Privacy** | ✅ Tor-routed (IP hidden) | ✅ Tor-routed (IP hidden) |
| **Data Integrity** | ⚠️ Phase 1 proof checks | ✅ Full consensus verification |
| **Censorship Resistance** | ⚠️ Provider can omit data | ✅ Merkle proofs ensure completeness |

---

## Current Architecture

### Verification Hierarchy

`EthereumBalanceService` uses a 3-tier verification hierarchy:

```
┌─────────────────────────────────────────────┐
│  Tier 1: Helios (consensus-verified)        │  ← .heliosVerified (green shield)
│  Full light client, BLS-attested state root │
├─────────────────────────────────────────────┤
│  Tier 2: Phase 1 eth_getProof              │  ← .proofConsistent (yellow shield)
│  Merkle-Patricia trie proof verification    │
├─────────────────────────────────────────────┤
│  Tier 3: Raw eth_getBalance                │  ← .unverified (no shield)
│  Trust the RPC provider                     │
└─────────────────────────────────────────────┘
```

Fallback is automatic: if Helios isn't running, Phase 1 is tried. If that fails, unverified balance is used.

### Tor Integration

All Helios upstream requests (execution RPC + consensus RPC) are routed through Tor:

```
┌──────────────┐     ┌──────────────┐     ┌────────────────┐     ┌──────────┐
│ HeliosManager│────▸│ helios-ios   │────▸│ Arti SOCKS5    │────▸│ Internet │
│   (Swift)    │ FFI │   (Rust)     │ ENV │ 127.0.0.1:39050│ Tor │          │
└──────────────┘     └──────────────┘     └────────────────┘     └──────────┘
```

**How it works:**
1. `HeliosManager` observes `.TorDidBecomeReady` notification
2. When Tor is ready, Helios auto-starts via `helios_init()`
3. The Rust FFI sets `ALL_PROXY=socks5h://127.0.0.1:39050` env var
4. Reqwest (used internally by Helios) respects this and routes all HTTP through Tor
5. `socks5h://` prefix ensures DNS resolution happens through Tor (no DNS leaks)

### Package Structure

```
localPackages/HeliosBridge/
├── Cargo.toml                     # Rust workspace
├── Package.swift                  # SPM package (HeliosFFI binary target + Helios library)
├── build-ios.sh                   # Cross-compilation → xcframework
├── helios-ios/
│   ├── Cargo.toml                 # Depends on helios-ethereum (master), alloy 1.0, reqwest+socks
│   └── src/lib.rs                 # C FFI: helios_init, get_balance, get_logs, eth_call
├── Sources/
│   ├── C/include/
│   │   ├── helios.h               # C header declarations
│   │   └── module.modulemap       # Clang module for Swift interop
│   └── HeliosManager.swift        # Package-level manager (standalone version)
└── Frameworks/
    └── helios.xcframework/        # 45MB, 3 architectures
        ├── ios-arm64/             # Device (aarch64-apple-ios)
        ├── ios-arm64-simulator/   # Simulator (aarch64-apple-ios-sim)
        └── macos-arm64/           # macOS (aarch64-apple-darwin)
```

### Swift Integration

```
bitchat/XMTP/
├── HeliosManager.swift            # Swift async wrapper, Tor auto-start
├── EthereumBalanceService.swift   # 3-tier verification hierarchy
└── ProofVerifier.swift            # Phase 1 RLP/MPT proof verification
```

---

## Phase 1: Swift-Native Proof Verification ✅

**Status: Complete**

Implemented lightweight Merkle-Patricia trie proof verification directly in Swift, without requiring Helios:

### What was built

1. **`ProofVerifier.swift`** (709 lines)
   - RLP decoder for Ethereum's Recursive Length Prefix encoding
   - Merkle-Patricia trie node parsing (branch, extension, leaf)
   - Account proof verification against state root
   - Storage proof verification for contract state
   - `verifyBalance()` convenience method
   - 25+ unit tests passing

2. **`EthereumBalanceService` integration**
   - `fetchBalanceWithProof()` calls `eth_getProof` from RPC
   - Verifies the Merkle proof against the block's state root
   - Returns `.proofConsistent` verification level
   - Automatic fallback to unverified if proof fails

3. **`VerificationLevel` enum**
   - `.heliosVerified` → green shield (full consensus verification)
   - `.proofConsistent` → yellow half-shield (proof valid, but state root trusted)
   - `.unverified` → no shield indicator

### Limitations

Phase 1 verifies proofs are **internally consistent** but still trusts the RPC for the state root. A malicious RPC could provide a valid proof for a *different* state root. Phase 2 (Helios) eliminates this by providing consensus-attested state roots.

---

## Phase 2: Helios Rust FFI Integration ✅

**Status: Complete — xcframework built, linked, and HELIOS_FFI_AVAILABLE enabled**

### What was built

1. **`helios-ios/Cargo.toml`** — Rust crate configuration
   - Depends on `helios-ethereum` from git (a16z/helios **master** branch)
   - Uses `alloy 1.0` for Ethereum types (Address, U256, Filter, TransactionRequest)
   - `reqwest` 0.12 with `socks` + `rustls-tls` features for Tor SOCKS5 proxy support
   - `eyre` for error handling, `serde`/`serde_json` for JSON serialization
   - `staticlib` crate type for iOS/macOS linking

2. **`helios-ios/src/lib.rs`** — Full FFI implementation (no stubs)
   - `helios_init()` — Creates `EthereumClientBuilder`, configures mainnet with
     execution/consensus RPCs, sets Tor proxy via `ALL_PROXY` env var, builds client
   - `helios_wait_synced()` — Blocks until first consensus sync completes
   - `helios_get_balance()` — Calls `client.get_balance()` (verified via Helios)
   - `helios_get_logs()` — Calls `client.get_logs()` for stealth address scanning
   - `helios_eth_call()` — Calls `client.call()` for ENS resolution, contract reads
   - `helios_finalized_block()` — Returns latest block number from Helios (U256→u64 cast)
   - `helios_is_synced()` / `helios_sync_progress()` — Sync status queries
   - `helios_shutdown()` — Graceful cleanup
   - `helios_free_string()` — Memory management for returned strings

3. **`HeliosManager.swift`** (app target) — Swift async wrapper
   - All FFI calls gated behind `#if HELIOS_FFI_AVAILABLE` (now enabled)
   - `@_silgen_name` bindings for all 10 FFI functions
   - Auto-start after Tor ready (`.TorDidBecomeReady` notification observer)
   - Two-step start: `helios_init()` then `helios_wait_synced()`
   - Background DispatchQueue for FFI calls (tokio blocks internally)
   - Sync status polling every 12 seconds (~1 Ethereum slot)
   - Checkpoint fetching from `lightclientdata.org` and `beaconcha.in`

4. **`build-ios.sh`** — Cross-compilation script
   - Targets: `aarch64-apple-ios`, `aarch64-apple-ios-sim`, `aarch64-apple-darwin`
   - Aggressive size optimization: `opt-level=z`, LTO, `codegen-units=1`, `strip=symbols`
   - Creates `helios.xcframework` from static libraries
   - Follows the proven Arti (Tor) build pattern

5. **`helios.xcframework`** — 45MB cross-platform binary
   - Built from Helios v0.11.0 (commit 582fda31)
   - Three architectures: ios-arm64, ios-arm64-simulator, macos-arm64
   - ~15MB per architecture (release, optimized)
   - Linked to app via SPM `binaryTarget` + `HeliosFFI` product

6. **Xcode integration**
   - `HELIOS_FFI_AVAILABLE` added to `SWIFT_ACTIVE_COMPILATION_CONDITIONS` for
     all 4 configs (iOS Debug/Release, macOS Debug/Release)
   - HeliosBridge local SPM package added to project `packageReferences`
   - `HeliosFFI` product dependency linked to both `bitchat_iOS` and `bitchat_macOS` targets

### Build instructions

```bash
# Prerequisites: Rust toolchain with iOS targets
rustup target add aarch64-apple-ios aarch64-apple-ios-sim

# Build all 3 architectures
cd localPackages/HeliosBridge/helios-ios
cargo build --release --target aarch64-apple-ios -p helios-ios
cargo build --release --target aarch64-apple-ios-sim -p helios-ios
cargo build --release --target aarch64-apple-darwin -p helios-ios

# Create xcframework
xcodebuild -create-xcframework \
  -library target/aarch64-apple-ios/release/libhelios_ios.a -headers ../Frameworks/include \
  -library target/aarch64-apple-ios-sim/release/libhelios_ios.a -headers ../Frameworks/include \
  -library target/aarch64-apple-darwin/release/libhelios_ios.a -headers ../Frameworks/include \
  -output ../Frameworks/helios.xcframework
```

### Key build issues resolved

| Issue | Root Cause | Fix |
|-------|-----------|-----|
| Git fetch failed | Helios uses `master` not `main` | Changed `branch = "master"` in Cargo.toml |
| `alloy::primitives` not found | Helios uses alloy 1.0, not 0.14 | Changed to `alloy = "1.0"` with `rpc-types`, `consensus`, `network` features |
| `get_block_number()` type mismatch | Returns `U256` in alloy 1.0, not `u64` | Added `.to::<u64>()` cast |
| Async autoclosure error | `await` in `??` operator | Extracted into explicit `if let` |

### Tor Proxy Technical Details

The Tor integration uses a lightweight approach that doesn't require forking Helios:

```rust
// In helios_init(), before building the Helios client:
if socks_proxy_port > 0 {
    std::env::set_var("ALL_PROXY", format!("socks5h://127.0.0.1:{}", socks_proxy_port));
    std::env::set_var("HTTPS_PROXY", format!("socks5h://127.0.0.1:{}", socks_proxy_port));
}
```

**Why this works:**
- Helios uses `reqwest` internally for all HTTP requests (consensus + execution RPCs)
- Reqwest respects `ALL_PROXY` and `HTTPS_PROXY` environment variables
- The `socks` feature (enabled via Cargo feature unification) adds SOCKS5 support
- `socks5h://` prefix means DNS resolution happens through the proxy (Tor), preventing leaks

**Alternative approach (if needed):**
If a future Helios version disables proxy env vars, we would need to fork Helios to accept
a custom `reqwest::Client` with an explicit `Proxy::all()` configuration.

---

## Phase 3: App Integration ✅

### EthereumBalanceService Integration

The 3-tier verification hierarchy is already wired in `EthereumBalanceService.fetchBalance()`:

```swift
func fetchBalance(for address: String) async throws -> (BigUInt, VerificationLevel) {
    // Tier 1: Try Helios if running (full consensus verification)
    if heliosAvailableForNetwork() {
        if let result = try? await fetchBalanceViaHelios(address) {
            return result  // (.heliosVerified)
        }
    }
    
    // Tier 2: Try Phase 1 proof verification
    if let result = try? await fetchBalanceWithProof(address) {
        return result  // (.proofConsistent)
    }
    
    // Tier 3: Fall back to unverified
    return try await fetchBalanceUnverified(address)  // (.unverified)
}
```

### WalletView UI Integration

- Green shield icon → `.heliosVerified` (Tier 1, full light client)
- Yellow half-shield → `.proofConsistent` (Tier 2, MPT proof)
- No indicator → `.unverified` (Tier 3, raw RPC)

### WalletSettingsView

- "Merkle Proof Checking" toggle (Phase 1, yellow tint)
- Helios status row showing sync state and block number

### Auto-Start Flow

```
App Launch
    │
    ▼
TorManager.start()
    │
    ▼ (async bootstrap ~5-15s)
.TorDidBecomeReady notification
    │
    ▼
HeliosManager.autoStartIfNeeded()
    │
    ├── helios_init(rpc, consensus, checkpoint, torSocksPort=39050)
    │       └── Sets ALL_PROXY env var, builds EthereumClient
    │
    ├── helios_wait_synced()
    │       └── Blocks until consensus sync completes (~2-10s)
    │
    └── isRunning = true
        └── EthereumBalanceService now uses Tier 1 (Helios)
```

---

## Phase 4: Testing & Optimization

**Status: Pending on-device testing**

### Planned Tests

1. **Unit Tests** — Proof verification correctness, FFI memory safety
2. **Integration Tests** — Helios + Tor proxy interaction, balance verification
3. **Performance** — Sync time (WiFi vs cellular vs Tor), memory usage, battery impact
4. **Security** — FFI boundary review, checkpoint trust model, DNS leak prevention

### Performance Targets

| Metric | Target | Notes |
|--------|--------|-------|
| Sync time (WiFi) | < 5s | Beacon committee update |
| Sync time (Tor) | < 15s | Additional Tor latency |
| Memory usage | < 50MB | During steady-state operation |
| Binary size | < 20MB | With LTO + strip |

---

## FFI Reference

### Functions

| Function | Signature | Description |
|----------|-----------|-------------|
| `helios_init` | `(rpc, consensus, checkpoint, port) → i32` | Initialize client, start sync |
| `helios_wait_synced` | `() → i32` | Block until synced |
| `helios_is_synced` | `() → i32` | Check sync status (1/0) |
| `helios_sync_progress` | `() → i32` | Progress (0-100, -1=error) |
| `helios_get_balance` | `(address, &result) → i32` | Verified balance query |
| `helios_get_logs` | `(filter_json, &result) → i32` | Verified log query |
| `helios_eth_call` | `(call_json, &result) → i32` | Verified contract call |
| `helios_finalized_block` | `() → i64` | Latest block number |
| `helios_free_string` | `(ptr) → void` | Free returned strings |
| `helios_shutdown` | `() → i32` | Graceful shutdown |

### Error Codes

| Code | Meaning |
|------|---------|
| 0 | Success |
| -1 | Not initialized / already running |
| -2 | Invalid parameters |
| -3 | Runtime / query error |
| -4 | Client build failed |

---

## Technical Decisions

| Decision | Selected | Rationale |
|----------|----------|-----------|
| Async bridging | Background DispatchQueue + block_on | Proven Arti pattern, most stable |
| Helios dependency | `helios-ethereum` from git (master) | Avoids pulling opstack/linea |
| Alloy version | 1.0.37 | Matches Helios workspace, not 0.14 |
| Tor routing | `ALL_PROXY` env var | No Helios fork needed, reqwest respects it |
| Binary optimization | LTO fat + opt-level z + strip | ~15MB per architecture |
| Checkpoint source | Multi-source fetch + bundled fallback | Security + availability |
| FFI gating | `#if HELIOS_FFI_AVAILABLE` | Enabled via SWIFT_ACTIVE_COMPILATION_CONDITIONS |
| SPM linking | `HeliosFFI` product (binary only) | Avoids duplicate HeliosManager symbols |

---

## References

- [Helios Repository](https://github.com/a16z/helios)
- [Helios Architecture Blog](https://a16zcrypto.com/posts/article/building-helios-ethereum-light-client/)
- [EIP-5564: Stealth Addresses](https://eips.ethereum.org/EIPS/eip-5564)
- [Ethereum Light Client Sync Protocol](https://github.com/ethereum/annotated-spec/blob/master/altair/sync-protocol.md)
- [bitchat Arti Integration](../localPackages/Arti/) — reference FFI pattern
