# Helios Light Client Integration Plan

> **Status:** Planning  
> **Last Updated:** February 2026  
> **Repository:** https://github.com/a16z/helios

## Overview

[Helios](https://github.com/a16z/helios) is a trustless, efficient, and portable multichain Ethereum light client written in Rust by a16z. It converts untrusted centralized RPC endpoints into cryptographically verified local RPC responses—eliminating the need to trust third-party providers like Infura, Alchemy, or even Flashbots.

### Why Helios for bitchat?

bitchat currently routes all Ethereum RPC calls through Tor for IP privacy, but still **trusts** the RPC provider to return honest data. This creates a gap in our privacy/security model:

| Layer | Current State | With Helios |
|-------|--------------|-------------|
| **Network Privacy** | ✅ Tor-routed (IP hidden) | ✅ Tor-routed (IP hidden) |
| **Data Integrity** | ❌ Trust RPC provider | ✅ Cryptographically verified |
| **Censorship Resistance** | ⚠️ Provider can omit data | ✅ Merkle proofs ensure completeness |

Helios would complete bitchat's trustless stack, ensuring that balance queries, transaction confirmations, and stealth address scanning are all verified against Ethereum's consensus.

---

## Helios Capabilities

### Core Features

- **Instant Sync** — Syncs in ~2 seconds using light client protocols
- **Minimal Storage** — Only ~32 bytes for checkpoint caching
- **Small Binary** — ~13MB compiled (WASM), estimated 15-25MB for iOS
- **Trustless Verification** — All data verified via Merkle proofs against consensus-attested state roots
- **Local RPC Server** — Exposes standard `http://127.0.0.1:8545` JSON-RPC interface

### Supported Networks

| Network | Support Level | Priority for bitchat |
|---------|--------------|---------------------|
| Ethereum Mainnet | ✅ Full | **Phase 1** |
| Base (OP Stack) | ✅ Full | Phase 2 |
| Optimism | ✅ Full | Future |
| Linea | ✅ Full | Future |
| Sepolia | ✅ Testnet | Development |

### Verified RPC Methods

Helios verifies these methods against consensus:

```
eth_getBalance          eth_getCode             eth_getStorageAt
eth_call                eth_estimateGas         eth_getTransactionByHash
eth_getTransactionReceipt                       eth_getBlockByNumber
eth_getProof            eth_getLogs             eth_chainId
eth_blockNumber         eth_newFilter           eth_getFilterLogs
```

---

## Features Unlocked for bitchat

### 1. Trustless Balance Verification

**Current:** `EthereumBalanceService` trusts Flashbots RPC response
```swift
// Current flow (trusted)
let response = try await urlSession.data(for: request)  // Trust this?
```

**With Helios:** Balance verified against state root attested by Ethereum consensus
```
[Flashbots RPC] → [Helios] → [Merkle Proof Verification] → [Verified Balance]
```

### 2. Trustless Stealth Address Scanning

**Current:** `StealthAddressManager` trusts `eth_getLogs` results from RPC  
**Risk:** Malicious RPC could hide incoming stealth payments

**With Helios:** Event logs verified with inclusion proofs
- Announcements cryptographically proven to exist in blocks
- Cannot omit or fabricate stealth address announcements
- Critical for EIP-5564 privacy guarantees

### 3. Trustless Transaction Confirmation

**Current:** Trust RPC when checking if transaction was included  
**With Helios:** Merkle proof confirms transaction in finalized block

### 4. Trustless Contract Calls

**Current:** `eth_call` results trusted from RPC (e.g., ENS resolution)  
**With Helios:** Call results verified against state root

### 5. Cross-Chain Swap Verification (EIL)

For future EIL (stealth_address_EIL.md) cross-chain swaps:
- Verify source chain lock transaction
- Verify destination chain claim
- Trustless atomic swap completion

---

## Integration Architecture

### Existing Pattern: Arti (Tor) Bridge

bitchat already integrates Rust code via the Arti Tor client. This provides a proven template:

```
localPackages/ArtiBridge/
├── arti-bridge-ffi/
│   ├── Cargo.toml
│   └── src/lib.rs          # C FFI exports
├── build-ios.sh            # Cross-compilation script
├── arti.xcframework/       # Built iOS framework
└── Sources/ArtiBridge/
    └── TorManager.swift    # Swift wrapper
```

**Rust FFI Pattern:**
```rust
// arti-bridge-ffi/src/lib.rs
#[no_mangle]
pub extern "C" fn arti_start(
    data_dir: *const c_char,
    socks_port: u16
) -> c_int {
    // Start Tor client...
}
```

**Swift Binding Pattern:**
```swift
// TorManager.swift
@_silgen_name("arti_start")
private func arti_start(
    _ dataDir: UnsafePointer<CChar>,
    _ socksPort: UInt16
) -> Int32
```

### Proposed: Helios Bridge

```
localPackages/HeliosBridge/
├── helios-ios/
│   ├── Cargo.toml
│   └── src/lib.rs          # C FFI exports for Helios
├── build-ios.sh            # Cross-compilation for iOS
├── helios.xcframework/     # Built iOS framework
└── Sources/HeliosBridge/
    └── HeliosManager.swift # Swift async wrapper
```

---

## Implementation Plan

### Phase 1: Swift-Native Proof Verification (Weeks 1-4)

**Goal:** Verify `eth_getProof` Merkle proofs locally without full Helios

Before committing to full Helios integration, implement lightweight proof verification:

1. **Create `ProofVerifier.swift`**
   - Implement Merkle-Patricia trie verification
   - Verify account proofs (balance, nonce, codeHash, storageRoot)
   - Verify storage proofs for contract state

2. **Modify `EthereumBalanceService`**
   - Call `eth_getProof` instead of `eth_getBalance`
   - Verify proof against known block root
   - Requires trusted block root source (limitation)

3. **Benefits:**
   - No binary size increase
   - No Rust compilation complexity
   - Validates proof verification logic before full integration

### Phase 2: Fork and Port Helios to iOS (Weeks 5-12)

**Goal:** Create `helios-ios` crate with iOS compilation support

#### Step 2.1: Fork Helios Repository

```bash
git clone https://github.com/a16z/helios.git
cd helios
git checkout -b ios-support
```

#### Step 2.2: Add iOS Targets to Cargo.toml

```toml
# helios-ios/Cargo.toml
[lib]
name = "helios_ios"
crate-type = ["staticlib"]

[dependencies]
helios-core = { path = "../core" }
helios-ethereum = { path = "../ethereum" }

# iOS-specific
libc = "0.2"

[target.'cfg(target_os = "ios")'.dependencies]
# iOS-specific deps if needed
```

#### Step 2.3: Create FFI Layer

```rust
// helios-ios/src/lib.rs
use std::ffi::{c_char, c_int, CStr};
use std::sync::Mutex;
use once_cell::sync::Lazy;

static CLIENT: Lazy<Mutex<Option<HeliosClient>>> = Lazy::new(|| Mutex::new(None));

/// Initialize Helios client with upstream RPC
/// Returns 0 on success, negative on error
#[no_mangle]
pub extern "C" fn helios_init(
    rpc_url: *const c_char,
    consensus_rpc: *const c_char,
    checkpoint: *const c_char,
    socks_proxy_port: u16,  // For Tor integration
) -> c_int {
    // Initialize with Tor SOCKS proxy for upstream requests
    // ...
}

/// Get verified balance for address
/// Returns balance in wei as hex string, caller must free
#[no_mangle]
pub extern "C" fn helios_get_balance(
    address: *const c_char,
    result: *mut *mut c_char,
) -> c_int {
    // Return cryptographically verified balance
    // ...
}

/// Verify and return logs matching filter
#[no_mangle]
pub extern "C" fn helios_get_logs(
    filter_json: *const c_char,
    result: *mut *mut c_char,
) -> c_int {
    // For stealth address scanning
    // ...
}

/// Perform verified eth_call
#[no_mangle]
pub extern "C" fn helios_eth_call(
    call_json: *const c_char,
    result: *mut *mut c_char,
) -> c_int {
    // Verified contract call
    // ...
}

/// Free string allocated by Helios
#[no_mangle]
pub extern "C" fn helios_free_string(ptr: *mut c_char) {
    if !ptr.is_null() {
        unsafe { drop(CStr::from_ptr(ptr)); }
    }
}

/// Shutdown client
#[no_mangle]
pub extern "C" fn helios_shutdown() -> c_int {
    // Clean shutdown
    // ...
}
```

#### Step 2.4: Create Build Script

```bash
#!/bin/bash
# localPackages/HeliosBridge/build-ios.sh

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HELIOS_DIR="$SCRIPT_DIR/helios-ios"
OUT_DIR="$SCRIPT_DIR/helios.xcframework"

# iOS device
rustup target add aarch64-apple-ios
cargo build --manifest-path "$HELIOS_DIR/Cargo.toml" \
    --target aarch64-apple-ios \
    --release

# iOS simulator (Apple Silicon)
rustup target add aarch64-apple-ios-sim
cargo build --manifest-path "$HELIOS_DIR/Cargo.toml" \
    --target aarch64-apple-ios-sim \
    --release

# macOS (for macOS app target)
cargo build --manifest-path "$HELIOS_DIR/Cargo.toml" \
    --target aarch64-apple-darwin \
    --release

# Create xcframework
xcodebuild -create-xcframework \
    -library target/aarch64-apple-ios/release/libhelios_ios.a \
    -library target/aarch64-apple-ios-sim/release/libhelios_ios.a \
    -library target/aarch64-apple-darwin/release/libhelios_ios.a \
    -output "$OUT_DIR"

echo "✅ Built helios.xcframework"
```

### Phase 3: Swift Integration (Weeks 13-16)

#### Step 3.1: Create HeliosManager.swift

```swift
// Sources/HeliosBridge/HeliosManager.swift

import Foundation

// MARK: - FFI Declarations
@_silgen_name("helios_init")
private func helios_init(
    _ rpcUrl: UnsafePointer<CChar>,
    _ consensusRpc: UnsafePointer<CChar>,
    _ checkpoint: UnsafePointer<CChar>,
    _ socksProxyPort: UInt16
) -> Int32

@_silgen_name("helios_get_balance")
private func helios_get_balance(
    _ address: UnsafePointer<CChar>,
    _ result: UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>
) -> Int32

@_silgen_name("helios_get_logs")
private func helios_get_logs(
    _ filterJson: UnsafePointer<CChar>,
    _ result: UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>
) -> Int32

@_silgen_name("helios_eth_call")
private func helios_eth_call(
    _ callJson: UnsafePointer<CChar>,
    _ result: UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>
) -> Int32

@_silgen_name("helios_free_string")
private func helios_free_string(_ ptr: UnsafeMutablePointer<CChar>?)

@_silgen_name("helios_shutdown")
private func helios_shutdown() -> Int32

// MARK: - HeliosManager

@MainActor
public final class HeliosManager: ObservableObject {
    public static let shared = HeliosManager()
    
    @Published public private(set) var isRunning = false
    @Published public private(set) var syncStatus: SyncStatus = .notStarted
    
    public enum SyncStatus {
        case notStarted
        case syncing(progress: Double)
        case synced(blockNumber: UInt64)
        case error(String)
    }
    
    public enum HeliosError: Error {
        case notInitialized
        case initFailed(code: Int32)
        case queryFailed(code: Int32)
        case invalidResponse
    }
    
    private init() {}
    
    /// Initialize Helios with Tor proxy integration
    public func start(
        rpcUrl: String = "https://rpc.flashbots.net",
        consensusRpc: String = "https://www.lightclientdata.org",
        checkpoint: String? = nil,
        torSocksPort: UInt16 = 9050
    ) async throws {
        let checkpointStr = checkpoint ?? latestHardcodedCheckpoint()
        
        let result = rpcUrl.withCString { rpc in
            consensusRpc.withCString { consensus in
                checkpointStr.withCString { cp in
                    helios_init(rpc, consensus, cp, torSocksPort)
                }
            }
        }
        
        guard result == 0 else {
            throw HeliosError.initFailed(code: result)
        }
        
        isRunning = true
        syncStatus = .synced(blockNumber: 0) // Update with actual block
    }
    
    /// Get cryptographically verified balance
    public func getBalance(address: String) async throws -> BigUInt {
        guard isRunning else { throw HeliosError.notInitialized }
        
        var resultPtr: UnsafeMutablePointer<CChar>?
        let code = address.withCString { addr in
            helios_get_balance(addr, &resultPtr)
        }
        
        guard code == 0, let ptr = resultPtr else {
            throw HeliosError.queryFailed(code: code)
        }
        
        defer { helios_free_string(ptr) }
        
        let hexString = String(cString: ptr)
        guard let balance = BigUInt(hexString.dropFirst(2), radix: 16) else {
            throw HeliosError.invalidResponse
        }
        
        return balance
    }
    
    /// Get verified logs for stealth address scanning
    public func getLogs(filter: LogFilter) async throws -> [Log] {
        guard isRunning else { throw HeliosError.notInitialized }
        
        let filterJson = try JSONEncoder().encode(filter)
        let filterString = String(data: filterJson, encoding: .utf8)!
        
        var resultPtr: UnsafeMutablePointer<CChar>?
        let code = filterString.withCString { f in
            helios_get_logs(f, &resultPtr)
        }
        
        guard code == 0, let ptr = resultPtr else {
            throw HeliosError.queryFailed(code: code)
        }
        
        defer { helios_free_string(ptr) }
        
        let logsJson = String(cString: ptr)
        return try JSONDecoder().decode([Log].self, from: logsJson.data(using: .utf8)!)
    }
    
    /// Shutdown Helios client
    public func stop() {
        _ = helios_shutdown()
        isRunning = false
        syncStatus = .notStarted
    }
    
    /// Hardcoded recent checkpoint (update periodically)
    private func latestHardcodedCheckpoint() -> String {
        // This should be updated with each app release
        // Or fetched from a trusted source on first launch
        "0x..." // Recent finalized block root
    }
}
```

#### Step 3.2: Integrate with EthereumBalanceService

```swift
// Modify EthereumBalanceService.swift

public func fetchBalance(for address: String, chain: Chain) async throws -> BigUInt {
    // Try verified balance first (Ethereum mainnet only in Phase 1)
    if chain == .ethereum && HeliosManager.shared.isRunning {
        do {
            return try await HeliosManager.shared.getBalance(address: address)
        } catch {
            Logger.wallet.warning("Helios verification failed, falling back to RPC: \(error)")
        }
    }
    
    // Fallback to existing RPC (still Tor-routed)
    return try await fetchBalanceViaRPC(for: address, chain: chain)
}
```

#### Step 3.3: Integrate with StealthAddressManager

```swift
// Modify StealthAddressManager.swift

public func scanForAnnouncements() async throws -> [StealthAnnouncement] {
    let filter = LogFilter(
        address: EIP5564_ANNOUNCER_ADDRESS,
        topics: [ANNOUNCEMENT_TOPIC, nil, viewTagTopic],
        fromBlock: lastScannedBlock
    )
    
    // Use verified logs if Helios is running
    let logs: [Log]
    if HeliosManager.shared.isRunning {
        logs = try await HeliosManager.shared.getLogs(filter: filter)
    } else {
        logs = try await fetchLogsViaRPC(filter: filter)
    }
    
    return try parseAnnouncements(from: logs)
}
```

### Phase 4: Testing & Optimization (Weeks 17-20)

1. **Unit Tests**
   - Proof verification correctness
   - FFI memory safety
   - Error handling edge cases

2. **Integration Tests**
   - Helios + Tor proxy interaction
   - Balance verification against known values
   - Stealth address scanning accuracy

3. **Performance Optimization**
   - Measure sync time on cellular
   - Memory usage profiling
   - Battery impact assessment

4. **Security Audit**
   - FFI boundary review
   - Checkpoint trust model review
   - Upstream RPC selection

---

## Technical Challenges & Mitigations

### Challenge 1: No Existing iOS Target

**Problem:** Helios is designed for WASM (browsers), not native iOS

**Mitigation:**
- Fork repository and add iOS targets
- Follow proven Arti integration pattern
- Contribute upstream if successful

**Risk Level:** Medium — requires Rust expertise but pattern exists

### Challenge 2: Async Runtime Bridging

**Problem:** Helios uses tokio; Swift uses structured concurrency

**Selected Approach:** Background thread with async wrapper

```swift
// Run tokio runtime on dedicated thread
private let heliosQueue = DispatchQueue(label: "helios.runtime", qos: .userInitiated)

public func getBalance(address: String) async throws -> BigUInt {
    try await withCheckedThrowingContinuation { continuation in
        heliosQueue.async {
            // Call FFI synchronously (tokio blocks internally)
            let result = self.getBalanceSync(address: address)
            continuation.resume(with: result)
        }
    }
}
```

**Rationale:** Most reliable pattern, used by Arti integration. Avoids experimental Swift-Rust async bridges.

### Challenge 3: Binary Size Impact

**Problem:** Helios + dependencies could add 15-25MB to app size

**Mitigation Strategy:**
1. **Phase 1:** Swift-only proof verification (0MB increase)
2. **Phase 2:** Minimal Helios build with aggressive LTO
3. **Future:** On-demand download of Helios framework

**Build Optimizations:**
```toml
# Cargo.toml
[profile.release]
lto = true
codegen-units = 1
panic = "abort"
strip = true
opt-level = "z"  # Optimize for size
```

**Estimated Final Size:** 12-18MB with optimizations

### Challenge 4: Network Layer (Tor Integration)

**Problem:** Helios expects direct HTTP; bitchat routes through Tor

**Selected Approach:** Custom HTTP client with SOCKS5 proxy

```rust
// In helios-ios FFI layer
use reqwest::Proxy;

fn create_http_client(socks_port: u16) -> reqwest::Client {
    let proxy = Proxy::all(format!("socks5h://127.0.0.1:{}", socks_port))
        .expect("Invalid proxy URL");
    
    reqwest::Client::builder()
        .proxy(proxy)
        .build()
        .expect("Failed to build client")
}
```

**Rationale:** Maintains IP privacy for upstream RPC queries. All Helios requests routed through existing Tor circuit.

### Challenge 5: Checkpoint Trust Model

**Problem:** Helios requires weak subjectivity checkpoint (~2 weeks old max)

**Selected Approach:** Hybrid checkpoint sourcing

1. **Default:** Hardcoded checkpoint in app bundle (updated each release)
2. **Refresh:** Fetch from multiple sources on launch:
   - `lightclientdata.org` (a16z operated)
   - `beaconcha.in` API
   - Self-hosted beacon node (future)
3. **Fallback:** Use bundled if network unavailable

```swift
func getCheckpoint() async -> String {
    // Try multiple sources
    let sources = [
        "https://www.lightclientdata.org/mainnet/head",
        "https://beaconcha.in/api/v1/sync/committees/finalized",
    ]
    
    for source in sources {
        if let checkpoint = try? await fetchCheckpoint(from: source) {
            return checkpoint
        }
    }
    
    // Fallback to bundled
    return bundledCheckpoint
}
```

**Rationale:** Balances security (multiple sources) with availability (bundled fallback). Users with stale checkpoints can still sync, just with more initial verification.

---

## Multi-Chain Support Strategy

### Phase 1: Ethereum Mainnet Only

**Scope:**
- Balance verification
- Stealth address scanning (EIP-5564)
- Transaction confirmation
- ENS resolution via verified `eth_call`

**Rationale:** Primary chain for stealth addresses and largest TVL

### Phase 2: Add Base (OP Stack)

**Scope:**
- All Phase 1 features on Base
- EIL cross-chain swap verification

**Implementation:**
```swift
public enum VerifiedChain: String {
    case ethereum = "mainnet"
    case base = "base"
}

public func getBalance(address: String, chain: VerifiedChain) async throws -> BigUInt {
    // Helios supports OP Stack natively
}
```

### Future: Additional OP Stack Chains

- Optimism mainnet
- Custom OP Stack rollups

---

## Timeline Summary

| Phase | Weeks | Deliverable |
|-------|-------|-------------|
| **1** | 1-4 | Swift-native proof verification (no Helios) |
| **2** | 5-12 | Helios iOS fork, FFI layer, xcframework |
| **3** | 13-16 | HeliosManager, service integration |
| **4** | 17-20 | Testing, optimization, security review |

**Total Estimated Effort:** 20 weeks (5 months)

---

## Success Criteria

1. **Trustless Balance Queries**
   - [ ] Balance matches on-chain state via independent verification
   - [ ] No single point of RPC trust

2. **Trustless Stealth Scanning**
   - [ ] Announcements verified with inclusion proofs
   - [ ] Cannot be censored by RPC provider

3. **Performance Targets**
   - [ ] Sync time < 5 seconds on WiFi
   - [ ] Sync time < 15 seconds on cellular
   - [ ] Memory usage < 50MB during operation

4. **Reliability**
   - [ ] Graceful fallback to RPC if Helios fails
   - [ ] No user-facing errors from verification layer

---

## References

- [Helios Repository](https://github.com/a16z/helios)
- [Helios Architecture Blog Post](https://a16zcrypto.com/posts/article/building-helios-ethereum-light-client/)
- [EIP-5564: Stealth Addresses](https://eips.ethereum.org/EIPS/eip-5564)
- [Ethereum Light Client Sync Protocol](https://github.com/ethereum/annotated-spec/blob/master/altair/sync-protocol.md)
- [bitchat Arti Integration](../localPackages/ArtiBridge/) — reference implementation

---

## Appendix: Decision Log

| Decision | Options Considered | Selected | Rationale |
|----------|-------------------|----------|-----------|
| Async bridging | Callbacks, Sync wrapper, Swift-Rust async | **Sync wrapper on background queue** | Proven pattern from Arti, most stable |
| Binary size | Full build, Minimal build, On-demand | **Minimal build with LTO** | Balance functionality vs size |
| Multi-chain scope | All chains, Ethereum only, Ethereum + Base | **Ethereum first, Base in Phase 2** | Focus on stealth address use case |
| Checkpoint source | Hardcoded, Fetched, User config | **Hybrid (bundled + multi-source fetch)** | Security + availability balance |
| Integration approach | Native FFI, WASM in WebView, Server-side | **Native FFI** | Best performance, follows Arti pattern |
