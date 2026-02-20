# Helios Light Client Integration

> **Status:** Complete and verified on-device (Phase 1 ✅, Phase 2 ✅, Phase 3 ✅, Phase 4 ✅, Phase 5: Tx History ✅)  
> **Last Updated:** February 2026  
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

2. **`helios-ios/src/lib.rs`** — Full FFI implementation (1048 lines, 17 exported functions)
   - `helios_init()` — Creates `EthereumClientBuilder`, configures network with
     execution/consensus RPCs, sets Tor proxy via `ALL_PROXY` env var, builds client
   - `helios_wait_synced()` — Blocks until first consensus sync completes (takes state
     out of mutex during `block_on` to prevent poisoning)
   - `helios_get_balance()` — Verified balance query against consensus-attested state root
   - `helios_get_logs()` — Verified log query for stealth address scanning (EIP-5564)
   - `helios_eth_call()` — Verified contract call for ENS resolution, token reads
   - `helios_get_nonce()` — Verified transaction count at latest block
   - `helios_get_pending_nonce()` — Transaction count including pending pool
   - `helios_get_transaction_receipt()` — Verified receipt lookup by tx hash
   - `helios_get_block_by_number()` — Verified block data (with optional full txs)
   - `helios_estimate_gas()` — Gas estimation via verified state
   - `helios_send_raw_transaction()` — Submit signed transactions (routed via Tor)
   - `helios_gas_price()` — Current gas price from verified state
   - `helios_finalized_block()` — Latest finalized block number (i64)
   - `helios_is_synced()` / `helios_sync_progress()` — Sync status queries
   - `helios_shutdown()` — Graceful cleanup, clears global state for re-init
   - `helios_free_string()` — Memory management for returned CString pointers

3. **`HeliosManager.swift`** (app target, 886 lines) — Swift async wrapper
   - All FFI calls gated behind `#if HELIOS_FFI_AVAILABLE` (enabled in all 4 build configs)
   - `@_silgen_name` bindings for all 17 FFI functions
   - Auto-start after Tor ready (`.TorDidBecomeReady` notification observer)
   - Two-step start: `helios_init()` then `helios_wait_synced()` on serial background queue
   - Auto-retry with fallback consensus endpoint on first sync failure
   - Background DispatchQueue (`app.bitchat.helios`, `.userInitiated`) for FFI calls
   - Sync status polling every 12 seconds (~1 Ethereum slot)
   - Multi-source checkpoint fetching (beacon API format + lightclientdata.org format)
   - Supports mainnet and Sepolia networks (auto-detected from wallet preference)
   - Full transaction support: `sendRawTransaction`, `estimateGas`, `getGasPrice`

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

**Status: Verified on physical device (February 2026) ✅**

Helios has been tested and confirmed working on both iOS Simulator and physical iPhone devices.

### Observed Behavior

**Simulator (confirmed working):**
- Helios auto-starts after Tor ready notification
- First sync attempt may fail (code -2) with one consensus endpoint
- Auto-retry with fallback consensus endpoint succeeds within ~3-5 seconds
- Helios-verified balance queries return `.heliosVerified` status
- XMTP streams, BLE, and other services coexist without issues

**Physical Device (confirmed working February 2026):**
- Same auto-start and retry flow works on-device
- Sync times slightly longer than simulator due to Tor + cellular latency
- Successfully provides Helios-verified balance queries

### Performance Observations

| Metric | Target | Observed | Notes |
|--------|--------|----------|-------|
| Sync time (WiFi, direct) | < 5s | ~2s | Fast on simulator |
| Sync time (via Tor) | < 15s | ~5-12s | Depends on Tor circuit quality |
| Sync retry on failure | 1 retry | 1 retry | Fallback consensus endpoint used |
| Binary size per arch | < 20MB | ~15MB | With LTO fat + strip |
| xcframework total | — | ~45MB | 3 architectures |

---

## FFI Reference

### Functions

| Function | Signature | Description |
|----------|-----------|-------------|
| `helios_init` | `(rpc, consensus, checkpoint, network, port) → i32` | Initialize client, start sync |
| `helios_wait_synced` | `() → i32` | Block until synced |
| `helios_is_synced` | `() → i32` | Check sync status (1/0) |
| `helios_sync_progress` | `() → i32` | Progress (0-100, -1=error) |
| `helios_get_balance` | `(address, &result) → i32` | Verified balance query |
| `helios_get_logs` | `(filter_json, &result) → i32` | Verified log query |
| `helios_eth_call` | `(call_json, &result) → i32` | Verified contract call |
| `helios_get_nonce` | `(address, &result) → i32` | Verified transaction count |
| `helios_get_pending_nonce` | `(address, &result) → i32` | Tx count including pending |
| `helios_get_transaction_receipt` | `(tx_hash, &result) → i32` | Verified receipt lookup |
| `helios_get_block_by_number` | `(block_tag, full_txs, &result) → i32` | Verified block data |
| `helios_estimate_gas` | `(call_json, &result) → i32` | Gas estimation |
| `helios_send_raw_transaction` | `(raw_tx, &result) → i32` | Submit signed transaction |
| `helios_gas_price` | `(&result) → i32` | Current gas price |
| `helios_finalized_block` | `() → i64` | Latest finalized block number |
| `helios_free_string` | `(ptr) → void` | Free returned CString pointers |
| `helios_shutdown` | `() → i32` | Graceful shutdown, clear state |

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

## Potential Issues

These are known areas that could cause problems — particularly on physical iOS devices — and should be monitored or addressed in future iterations.

### 1. `$HOME/.helios` Data Directory

**Risk: Medium** — May cause hangs or silent failures on some iOS versions.

The Rust FFI stores checkpoint data via Helios's `FileDB` in `$HOME/.helios/`:

```rust
let data_dir = PathBuf::from(
    std::env::var("HOME").unwrap_or_else(|_| "/tmp".to_string()),
).join(".helios");
```

- **Simulator:** `$HOME` resolves to a writable macOS path under `CoreSimulator/Devices/`. Works fine.
- **Physical device:** `$HOME` points to the app's sandbox container root. This is generally writable, but behaviour can vary across iOS versions. If `$HOME` is not set in the Rust environment, the fallback is `/tmp/.helios` which is also sandboxed.
- **Fix (if needed):** Pass a known-writable path from Swift (e.g. `FileManager.default.urls(for: .cachesDirectory)`) through the FFI as a `data_dir` parameter instead of relying on `$HOME`.

### 2. `helios_wait_synced()` Has No Timeout

**Risk: Medium** — Could permanently block the `heliosQueue` if sync never completes.

The `wait_synced()` FFI call does `runtime.block_on(client.wait_synced())` with no timeout. If the consensus RPC is unreachable (e.g. Tor circuit is stale, or the beacon endpoint is down), this blocks forever.

On the Swift side, the `heliosQueue` is a serial `.userInitiated` DispatchQueue. A permanently blocked `wait_synced()` means all subsequent Helios calls (queries, shutdown) also hang.

- **Current mitigation:** The Swift layer retries once with a fallback consensus endpoint; if both fail (sync returns -2), the FFI state is cleared and Helios is stopped.
- **Fix (if needed):** Add `tokio::time::timeout(Duration::from_secs(30), client.wait_synced())` in the Rust layer so sync failures are reported promptly rather than hanging.

### 3. Multi-Threaded Tokio Runtime — Thread Pressure on Device

**Risk: Low-Medium** — Could contribute to jetsam kills under heavy load.

`Runtime::new()` creates a multi-threaded tokio runtime with `num_cpus` worker threads. On a physical iPhone, the app is already running Tor (Arti), BLE, XMTP, and Nostr services — all spawning their own threads. iOS imposes stricter thread limits (~32-64) than the macOS simulator (effectively unlimited).

If the OS is under memory/thread pressure, the tokio worker threads could be killed by jetsam, causing the Helios runtime to silently fail.

- **Current status:** Working on device as of February 2026.
- **Fix (if needed):** Switch to `tokio::runtime::Builder::new_current_thread()` with `.enable_all()` to reduce thread count. This would use cooperative multitasking on a single thread rather than spawning worker threads.

### 4. `.load_external_fallback()` Network Call During `build()`

**Risk: Low-Medium** — Could cause `helios_init()` to hang if Tor is slow.

The `EthereumClientBuilder` is configured with `.load_external_fallback()`, which tells Helios to fetch a checkpoint from external sources **during `build()`** if the provided checkpoint is empty or stale. This is a synchronous network call that happens inside `helios_init()` on the `heliosQueue`.

If the `ALL_PROXY` env var is set (routing through Tor) and Tor's SOCKS5 proxy is slow or not fully bootstrapped, this HTTP request can hang — meaning `helios_init()` never returns.

- **Current mitigation:** The Swift `HeliosManager` fetches a fresh checkpoint from beacon API endpoints *before* calling `helios_init()`, so a valid checkpoint is usually provided. The external fallback is only triggered if the pre-fetched checkpoint is all zeros.
- **Fix (if needed):** Only call `.load_external_fallback()` when `socks_proxy_port == 0` (direct connection), or skip it entirely when a valid checkpoint is provided from Swift.

---

## Phase 5: Transaction History Reconstruction ✅

**Status: Complete (February 2026)**

The transaction history view was not showing any data despite both the EOA wallet and PQ account having on-chain transactions. The root cause was a combination of:
1. Native ETH block scanning was limited to only 100 blocks (~20 min) — far too narrow
2. PQ account (ERC-4337) transactions were not being scanned at all
3. Transaction hashes were not persisted — history was lost on app restart
4. No receipt-based reconstruction for known transaction hashes

### What was built

1. **`TransactionStore.swift`** — Persistent cache of known tx hashes + metadata
   - Stored in App Group UserDefaults, keyed per address
   - Survives app restarts — once a tx hash is known, it's never lost
   - Fed by MeshTransactionRelay confirmations, PQ account txs, and on-chain scanning

2. **Multi-strategy `TransactionHistoryService`** — 7 data sources merged:
   - **Persistent cache** → instant load of previously discovered tx hashes
   - **MeshTransactionRelay** → pending, confirmed, failed local txs
   - **Receipt-based enrichment** → Helios `getTransactionReceipt` for all known hashes
   - **ERC-20 event logs** → `getLogs` Transfer/Approval events (~7 day window)
   - **ERC-4337 UserOperationEvent** → PQ smart account tx scanning via EntryPoint v0.7
   - **Native ETH block scanning** → adaptive range 500–5000 blocks with concurrent batch fetching
   - **Nonce gap detection** → compares on-chain nonce vs known sent count, expands scan range

3. **PQ transaction persistence** — `PQAccountViewModel` now records tx hashes to `TransactionStore` on:
   - `executeTransaction()` — UserOp submission
   - `executeAndWait()` — UserOp with receipt polling
   - `deployDirect()` — PQ account deployment tx

4. **MeshTransactionRelay persistence** — both mesh relay and direct broadcast confirmation paths now record to `TransactionStore`

### Privacy preservation

All data sources maintain bitchat's privacy model:
- **Helios** → cryptographically verified via consensus BLS signatures (`.heliosVerified`)
- **Tor** → all RPC fallbacks route through Arti SOCKS5 proxy for IP privacy
- **No Etherscan** → no centralized indexer or API key needed
- **No external services** → `TransactionStore` is purely local on-device storage
- **Progress UI** → loading view shows current scanning stage for transparency

### Architecture

```
TransactionHistoryService.fetchHistory()
├── 1. TransactionStore.allTransactions()     ← instant, local cache
├── 2. MeshTransactionRelay state              ← pending/confirmed/failed
├── 3. fetchReceiptsForKnownHashes()           ← Helios getTransactionReceipt
│   └── Concurrent batches of 10
├── 4. fetchOnChainHistory()
│   ├── ERC-20 Transfer logs (getLogs)         ← ~7 day window
│   ├── ERC-4337 UserOperationEvent logs       ← PQ account txs
│   ├── Nonce gap detection                    ← getNonce vs known count
│   └── Native ETH block scan                  ← adaptive 500-5000 blocks
│       └── Concurrent batches of 20
├── 5. Deduplicate + sort by timestamp
└── 6. Cache newly discovered txs → TransactionStore
```

---

## References

- [Helios Repository](https://github.com/a16z/helios)
- [Helios Architecture Blog](https://a16zcrypto.com/posts/article/building-helios-ethereum-light-client/)
- [EIP-5564: Stealth Addresses](https://eips.ethereum.org/EIPS/eip-5564)
- [Ethereum Light Client Sync Protocol](https://github.com/ethereum/annotated-spec/blob/master/altair/sync-protocol.md)
- [bitchat Arti Integration](../localPackages/Arti/) — reference FFI pattern
