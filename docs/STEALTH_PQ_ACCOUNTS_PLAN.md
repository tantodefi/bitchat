# Stealth PQ Accounts — Fluidkey-Style Privacy via ZKNOX Account Abstraction

> **Status**: ✅ **Fully implemented** on Arbitrum Sepolia. All phases complete.
>
> **Goal**: Replicate Fluidkey's stealth-Safe model — but swap the Safe 1/1 smart account for a **ZKNOX PQ Account** (hybrid ECDSA + ML-DSA-44, ERC-4337). Use Namestone's offchain resolver to serve fresh stealth PQ Account addresses under `*.pq.dstealth.eth`, deploying account contracts only when funds arrive.
>
> **Namespace**: `alice.dstealth.eth` → original embedded wallet EOA (identity/messaging, unchanged). `alice.pq.dstealth.eth` → rotating stealth PQ Account address (payments/receive).

---

## Implementation Status

| Component | Status | File(s) |
|-----------|--------|---------|
| **Stealth derivation (HMAC-based)** | ✅ Done | `StealthPQAccountManager.swift` (~591 lines) |
| **Offline CREATE2 prediction** | ✅ Done | `StealthPQAccountManager.predictAddress(for:)` + `PQAccountDeployer.predictAddressLocally()` |
| **Explicit generate-then-scan UX** | ✅ Done | `StealthPQAccountListView.swift` — Generate button + scan-only balance check |
| **3-tier balance verification** | ✅ Done | `EthereumBalanceService` (Helios → Merkle proof → RPC) with Tor routing |
| **Deploy-on-sweep via ERC-4337** | ✅ Done | `PQTransactionSigner.sweepStealthAccount()` — hybrid sig (ECDSA + ML-DSA-44) |
| **ENS on `pq.dstealth.eth`** | ✅ Done | `NamestoneService` — full CRUD + auto-rotation after sweep |
| **PQ ENS name editor** | ✅ Done | `PQENSSettingsView.swift` — edit label left of `.pq.dstealth.eth` |
| **Persistence** | ✅ Done | JSON to App Group container (fallback: Documents) + UserDefaults index |
| **WalletView integration** | ✅ Done | PQ stealth section + settings section with separate EOA/PQ ENS rows |
| **Test coverage** | ✅ Done | 21 tests across 6 suites (`StealthPQAccountTests.swift`) |

---

## 1. How Fluidkey Works (Reference Architecture)

```
┌──────────────────────────────────────────────────────────────────────────┐
│                         Fluidkey Architecture                           │
├──────────────────────────────────────────────────────────────────────────┤
│                                                                          │
│  1. User signs a message → derives (spendingKey, viewingKey) pair        │
│  2. Server has viewingKey node (BIP-32 m/5564'/0'/...)                   │
│  3. For each new payment:                                                │
│     a. Server increments nonce on viewing key node                       │
│     b. Derive ephemeralPrivKey from viewingKeyNode leaf                   │
│     c. Generate stealthAddress (EOA) via ECDH:                           │
│        sharedSecret = ephemeralPrivKey * spendingPubKey                   │
│        stealthAddr = pubToAddr(spendingPub * hash(S))                    │
│     d. Predict Safe address via CREATE2:                                 │
│        predictStealthSafeAddress(stealthAddr, SafeProxy, factory)        │
│     e. Return counterfactual Safe address — NOT YET DEPLOYED             │
│                                                                          │
│  4. Sender sends funds to the predicted Safe address                     │
│  5. User sweeps: deploy Safe + execute withdrawal in one UserOp          │
│                                                                          │
│  6. ENS: username.fkey.eth → offchain resolver → returns new stealth     │
│     Safe address on every query                                          │
└──────────────────────────────────────────────────────────────────────────┘
```

### Key Properties of Fluidkey's Design

| Property | How Fluidkey Does It |
|----------|---------------------|
| **Stealth signer derivation** | ECDH between ephemeral key (from viewing key BIP-32 node) and spending public key. Result is a stealth EOA. |
| **Smart account wrapping** | Safe 1/1 multisig with the stealth EOA as sole owner. Uses CREATE2 via Safe ProxyFactory. |
| **Counterfactual address prediction** | `predictStealthSafeAddressWithBytecode()` computes CREATE2 locally using Safe proxy bytecode + initializer hash + salt. No RPC needed. |
| **Deferred deployment** | Safe is NOT deployed until the user wants to withdraw. Funds sit at the predicted CREATE2 address. |
| **ENS integration** | Offchain CCIP-Read resolver returns a fresh stealth Safe address per query. Server-side uses viewing key to derive. |
| **Viewing/spending key split** | Viewing key shared with server (can generate addresses, cannot spend). Spending key stays client-only. |

---

## 2. Interface Comparison: Safe vs PQ Account

### Can We Do the Same Thing?

**Yes — with architectural adaptations.** The core pattern is identical:

1. Derive a stealth signer deterministically
2. Predict a smart account address controlled by that signer via CREATE2
3. Share the predicted address (funds can be sent before deployment)
4. Deploy + sweep in a single transaction when ready

Here's the detailed comparison:

| Dimension | Fluidkey (Safe) | bitchat (PQ Account) | Compatible? |
|-----------|----------------|---------------------|-------------|
| **Account type** | Safe 1/1 (Gnosis) | ZKNOX ERC-4337 (mldsa_k1) | ✅ Both are CREATE2-deployed smart accounts |
| **Signer(s)** | 1 stealth EOA (secp256k1) | 2 keys: EOA address (ECDSA) + ML-DSA-44 expanded pub key | ⚠️ Different — see Section 3 |
| **Factory** | Safe ProxyFactory | ZKNOX mldsa_k1 factory (`0xe28F...DDA0e5`) | ✅ Both use CREATE2 |
| **Address prediction** | Local CREATE2 compute or `eth_call` to factory | ✅ Offline CREATE2 first, RPC fallback | ✅ Done — `predictAddressLocally()` + RPC fallback |
| **Counterfactual deposits** | ✅ Send ETH/tokens to undeployed address | ✅ CREATE2 address is deterministic — same pattern works | ✅ |
| **UserOperations** | Safe supports ERC-4337 via module | PQ Account is natively ERC-4337 | ✅ Better — native support |
| **Gas sponsorship** | Via Safe Transaction Service / relay | Via Pimlico bundler + paymaster | ✅ |
| **Signature scheme** | ECDSA only | Hybrid ECDSA + ML-DSA-44 | ✅ Strictly stronger |
| **Quantum resistance** | ❌ None | ✅ Post-quantum via ML-DSA-44 | ✅ Advantage |
| **Deployment cost** | ~200K gas (Safe proxy) | ~5-15M gas (expanded PQ pubkey in calldata) | ⚠️ Much higher — see mitigations |
| **Key derivation for stealth** | BIP-32 viewing key → ephemeral key → ECDH | Need new derivation scheme — see Section 3 | ⚠️ Requires design |

### What UserOps/AA Features Are Available?

Both account types support the same ERC-4337 operations:

| ERC-4337 Feature | Safe + Module | PQ Account | Notes |
|-----------------|---------------|------------|-------|
| `execute(dest, value, data)` | ✅ | ✅ | Single call |
| `executeBatch(dests[], values[], datas[])` | ✅ | ✅ (if implemented) | Batch calls |
| `validateUserOp()` | ✅ | ✅ (hybrid sig check) | Signature validation |
| `initCode` (deploy-on-first-use) | ✅ | ✅ | Counterfactual deployment |
| Paymaster support | ✅ | ✅ | Gas sponsorship |
| Nonce management | ✅ | ✅ | EntryPoint nonces |
| `isValidSignature()` (ERC-1271) | ✅ | ✅ | On-chain sig verification |

**Conclusion**: The PQ Account interface is a strict superset of what Fluidkey needs from Safe. Every UserOp pattern Fluidkey uses can be replicated.

---

## 3. Stealth PQ Account Derivation Scheme

This is the core design challenge: how to derive **stealth PQ accounts** where each address is unique, unlinkable, and controlled by the same user.

### The Problem

Fluidkey derives a single stealth EOA per payment, then wraps it in a Safe. The Safe address is a function of `(stealthEOA, SafeSingleton, factory, salt)`.

For PQ accounts, the CREATE2 address is a function of `(preQuantumPubKey, postQuantumPubKey, factory, accountBytecode)`. We need **both keys to vary per stealth address** while remaining derivable from a master secret.

### Proposed Derivation

```
Master Keys (one-time setup, stored on device):
  spendingKey    = secp256k1 private key (from EmbeddedWallet)
  viewingKey     = keccak256(spendingKey || "stealth-viewing-key")  [already exists]
  pqMasterSecret = ML-DSA-44 secret key (from PQKeyManager)       [already exists]

Per-Stealth-Address (index = 0, 1, 2, ...):

  Step 1: Derive stealth ECDSA signer (same as existing stealth addresses)
    ephemeralKey[i] = HMAC-SHA256(viewingKey, "stealth-pq-ephemeral:" || i)
    R[i]            = ephemeralKey[i] * G
    sharedSecret[i] = ephemeralKey[i] * spendingPubKey
    stealthPrivKey[i] = spendingKey + keccak256(sharedSecret[i])   mod n
    stealthAddress[i] = ethAddress(stealthPrivKey[i])

  Step 2: Derive per-stealth ML-DSA-44 keypair
    Option A — Reuse master PQ key (simpler, less private):
      stealthPQPubKey[i] = pqMasterSecret.publicKey  (same for all stealth addrs)
      
    Option B — Derive per-index PQ key (maximum privacy, higher cost):
      pqSeed[i]         = HMAC-SHA256(pqMasterSecret.keyBytes[0..32], "stealth-pq-seed:" || i)
      (pqSK[i], pqPK[i]) = ML-DSA-44.keygen(pqSeed[i])  ← requires upstream SwiftDilithium change

  Step 3: Compute counterfactual PQ Account address
    preQuantumPubKey[i]  = stealthAddress[i]                    (20 bytes)
    postQuantumPubKey[i] = expandedEncode(pqPK[i])              (~22KB)
    stealthPQAccount[i]  = CREATE2(factory, salt(preQ[i], postQ[i]), accountBytecode)
```

### Recommended Approach: Option A (Shared PQ Key)

For the initial implementation, use **Option A** — all stealth PQ accounts share the same ML-DSA-44 public key but have different ECDSA stealth signers:

```
stealthPQAccount[i] = f(stealthAddress[i], masterPQPubKey)
```

**Why Option A first:**
1. SwiftDilithium has no seed-based keygen — Option B is blocked until upstream changes
2. The ECDSA stealth key already provides unlinkability (each stealth address is unique)
3. An observer seeing the same PQ pubkey across accounts can link them — but this is the same linkability Fluidkey accepts (their Safe singleton address is public)
4. The hybrid scheme still guarantees quantum resistance even with a shared PQ key
5. Option B can be added later when BIP39 PQ derivation is standardized (Stage 2)

**Privacy implication**: An adversary with access to the factory event logs could link stealth PQ accounts by their shared `postQuantumPubKey`. Mitigation: use a privacy-preserving deployment relay (Flashbots Protect) to avoid public mempool exposure of deploy transactions.

---

## 4. Counterfactual Address Prediction (Local CREATE2) ✅ Implemented

`PQAccountDeployer.predictAddressLocally()` handles offline prediction. `StealthPQAccountManager.predictStealthPQAccountAddress(at:)` combines stealth derivation + CREATE2 prediction with RPC fallback.

### New Function: `predictStealthPQAccountAddress()`

```swift
/// Predict a PQ Account address locally via CREATE2, no RPC needed.
/// This enables the offchain resolver to generate addresses without network calls.
static func predictStealthPQAccountAddress(
    preQuantumPubKey: Data,    // 20-byte stealth EOA address
    postQuantumPubKey: Data,   // ~22KB expanded ML-DSA-44 key
    factoryAddress: String,
    accountBytecode: Data      // ZKNOX account creation bytecode
) -> String {
    // 1. Build salt = keccak256(abi.encode(preQ, postQ))
    let encodedKeys = ABIEncoder.encode(
        types: [.bytes, .bytes],
        values: [.bytes(preQuantumPubKey), .bytes(postQuantumPubKey)]
    )
    let salt = keccak256(encodedKeys)
    
    // 2. Build initCodeHash = keccak256(accountBytecode ++ abi.encode(preQ, postQ))
    let constructorArgs = ABIEncoder.encode(
        types: [.bytes, .bytes],
        values: [.bytes(preQuantumPubKey), .bytes(postQuantumPubKey)]
    )
    let initCode = accountBytecode + constructorArgs
    let initCodeHash = keccak256(initCode)
    
    // 3. CREATE2: address = keccak256(0xff ++ factory ++ salt ++ initCodeHash)[12:]
    let packed = Data([0xff]) + factoryAddress.hexToData() + salt + initCodeHash
    let addressHash = keccak256(packed)
    return "0x" + addressHash.suffix(20).hexString
}
```

> **Dependency**: Need the exact `accountBytecode` (the contract creation code that the factory uses internally). Extract this from the factory's `createAccount` function or the deployed bytecode on Sepolia. This is a one-time extraction.

---

## 5. Namestone as Offchain Resolver for Stealth PQ Accounts ✅ Implemented

### Fluidkey's ENS Architecture

```
username.fkey.eth
    → CCIP-Read (EIP-3668) to Fluidkey's offchain resolver
    → Resolver calls Fluidkey backend
    → Backend uses viewing key to derive next stealth Safe address
    → Returns fresh address (never used before)
```

### Our Equivalent: `username.pq.dstealth.eth` → Stealth PQ Account

Namestone manages offchain resolution for `dstealth.eth` subdomains. We add a **second Namestone domain** — `pq.dstealth.eth` — for rotating stealth PQ Account addresses. This keeps the existing `*.dstealth.eth` flow (embedded wallet EOA for identity/messaging) completely untouched.

### Namespace Architecture

```
┌──────────────────────────────────────────────────────────────────────────┐
│                    ENS Namespace Split                                    │
├──────────────────────────────────────────────────────────────────────────┤
│                                                                          │
│  alice.dstealth.eth        →  0xABC... (embedded wallet EOA)             │
│    ├─ Identity / messaging (XMTP inbox ID in text records)               │
│    ├─ Registered on first app launch (existing flow, UNCHANGED)          │
│    └─ Never rotates — this is Alice's stable identity                    │
│                                                                          │
│  alice.pq.dstealth.eth     →  0xDEF... (counterfactual PQ Account)       │
│    ├─ Payment address (rotating stealth PQ Account)                      │
│    ├─ Registered after PQ Account setup                                  │
│    ├─ Rotates to a new address after each funding event                  │
│    └─ text_records: stealth.index, stealth.pq=true                       │
│                                                                          │
│  Namestone config:                                                       │
│    Domain 1: "dstealth.eth"     → existing API key, existing flow        │
│    Domain 2: "pq.dstealth.eth"  → same API key, new stealth PQ flow      │
│                                                                          │
└──────────────────────────────────────────────────────────────────────────┘
```

### Required ENSResolver Change

The existing `ENSResolver.resolveViaNamestone()` strips `.dstealth.eth` from the name:

```swift
// CURRENT (breaks for pq.dstealth.eth):
let subdomain = name.replacingOccurrences(of: ".dstealth.eth", with: "")
// "alice.pq.dstealth.eth" → "alice.pq" → searches dstealth.eth for "alice.pq" ❌
```

**Fix**: Check for `.pq.dstealth.eth` **before** `.dstealth.eth` (since both match `hasSuffix`):

```swift
// UPDATED routing in ENSResolver.resolve():
if name.hasSuffix(".pq.dstealth.eth") {
    resolution = try await resolveViaNamestone(name, domain: "pq.dstealth.eth")
    // "alice.pq.dstealth.eth" → name="alice", domain="pq.dstealth.eth" ✅
} else if name.hasSuffix(".dstealth.eth") {
    resolution = try await resolveViaNamestone(name, domain: "dstealth.eth")
    // "alice.dstealth.eth" → name="alice", domain="dstealth.eth" ✅ (unchanged)
}
```

Alternatively, `NamestoneService.resolveName(fullName:)` already splits labels correctly — `alice.pq.dstealth.eth` → name=`alice`, domain=`pq.dstealth.eth`. The existing `resolveName` method can be reused as-is.

### Payment Resolution Flow

```
┌──────────────────────────────────────────────────────────────────────────┐
│              Stealth PQ Account ENS Resolution Flow                      │
├──────────────────────────────────────────────────────────────────────────┤
│                                                                          │
│  Sender wants to pay alice.pq.dstealth.eth                               │
│                                                                          │
│  1. ENS lookup → Namestone offchain resolver → returns current address   │
│  2. Sender sends funds to that address (undeployed PQ Account)           │
│                                                                          │
│  Meanwhile, on Alice's device (or a Cloudflare Worker):                  │
│  3. After each payment detected:                                         │
│     a. Increment stealth index                                           │
│     b. Derive next stealthAddress[i+1] + predict PQ Account address      │
│     c. Call Namestone set-name to update alice.pq.dstealth.eth → new addr│
│                                                                          │
│  When Alice wants to withdraw:                                           │
│  4. Build UserOp with initCode (deploys PQ Account) + withdraw call      │
│  5. Submit via Pimlico bundler                                           │
│  6. PQ Account deployed + funds swept in one transaction                 │
│                                                                          │
│  Alice's messaging identity (alice.dstealth.eth) is NEVER affected.      │
│                                                                          │
└──────────────────────────────────────────────────────────────────────────┘
```

### Why Namestone Works as a Quick Prototype

| Fluidkey (Custom CCIP-Read) | bitchat (Namestone) |
|----------------------------|---------------------|
| Custom offchain resolver contract + backend | Namestone's managed resolver (already deployed) |
| `username.fkey.eth` (single namespace) | `username.dstealth.eth` (identity) + `username.pq.dstealth.eth` (payments) |
| Returns new address per query via custom logic | We rotate addresses via `set-name` API calls on `pq.dstealth.eth` |
| Fully automated server-side derivation | Can be automated via Cloudflare Worker or on-device |
| Production-grade, decentralization planned | Good enough for prototype; can migrate to custom CCIP-Read later |

### Namestone API Flow

```
# Existing flow (UNCHANGED):
# alice.dstealth.eth → embedded wallet EOA, registered on first launch
POST https://namestone.com/api/public_v1/set-name
{
  "domain": "dstealth.eth",
  "name": "alice",
  "address": "0xABC..."  ← embedded wallet EOA
  "text_records": { "com.xmtp.inbox": "<xmtp_inbox_id>" }
}

# NEW flow: register stealth PQ Account address on pq.dstealth.eth
POST https://namestone.com/api/public_v1/set-name
{
  "domain": "pq.dstealth.eth",
  "name": "alice",
  "address": "<stealth_pq_account_address_0>",
  "text_records": {
    "com.bitchat.stealth.index": "0",
    "com.bitchat.stealth.pq": "true",
    "com.bitchat.stealth.meta": "st:eth:0x<spending_pub><viewing_pub>"
  }
}

# After payment detected, rotate to next address (pq.dstealth.eth only)
POST https://namestone.com/api/public_v1/set-name
{
  "domain": "pq.dstealth.eth",
  "name": "alice",
  "address": "<stealth_pq_account_address_1>",
  "text_records": {
    "com.bitchat.stealth.index": "1",
    ...same records...
  }
}
```

> **Note**: Both `dstealth.eth` and `pq.dstealth.eth` use the **same Namestone API key**. The dstealth.eth owner delegates the `pq` subdomain to Namestone's resolver. The existing `alice.dstealth.eth` registration is never modified by the stealth PQ flow.

### Text Records Schema

**`alice.dstealth.eth`** (identity — existing, unchanged):

| Key | Value | Purpose |
|-----|-------|---------|
| `com.xmtp.inbox` | 64-char hex inbox ID | XMTP messaging |

**`alice.pq.dstealth.eth`** (payments — new):

| Key | Value | Purpose |
|-----|-------|---------|
| `com.bitchat.stealth.index` | Integer | Current stealth derivation index |
| `com.bitchat.stealth.pq` | "true" | Indicates PQ Account (not plain EOA) |
| `com.bitchat.stealth.meta` | `st:eth:0x<P_spend><P_view>` | Stealth meta-address for advanced senders |
| `com.bitchat.pq.pubkey` | hex ML-DSA-44 public key hash | For PQ key verification |

---

## 6. Address Rotation Worker (Cloudflare)

Extend the existing faucet worker (from [faucet.md](faucet.md)) to also handle address rotation:

```
┌──────────────────────────────────────────────────────────────────┐
│                Cloudflare Worker (Stealth Rotator)                │
│              stealth-rotator.tantodefi.workers.dev                │
├──────────────────────────────────────────────────────────────────┤
│  Every 2 min (or webhook-triggered):                             │
│    1. GET namestone.com/api/public_v1/get-names                  │
│       ?domain=pq.dstealth.eth                                    │
│    2. For each user with stealth.pq=true:                        │
│       a. Check if current address has received funds              │
│          (eth_getBalance or eth_getTransactionCount)              │
│       b. If balance > 0:                                         │
│          - Increment stealth index                                │
│          - Derive next stealth PQ Account address                 │
│          - Update Namestone: alice.pq.dstealth.eth → new addr    │
│    3. Log rotation events to KV store                            │
│                                                                  │
│  Note: Only touches pq.dstealth.eth. Never modifies dstealth.eth │
└──────────────────────────────────────────────────────────────────┘
```

### Privacy Consideration

The rotation worker needs the **viewing key node** (not the spending key) to derive new stealth addresses. This mirrors Fluidkey's architecture exactly — the server can generate addresses but cannot spend funds.

**Worker secret**: `VIEWING_KEY_NODE` — a BIP-32 extended private key node that can derive ephemeral keys but NOT spending keys.

---

## 7. Deployment Flow: Counterfactual → Funded → Deployed

```
Timeline:

t=0  Alice registers on first app launch:
     → alice.dstealth.eth → 0xABC (embedded wallet EOA) — identity/messaging
     (existing flow, completely unchanged)

t=1  Alice sets up PQ Account, then registers stealth PQ:
     → alice.pq.dstealth.eth → stealthPQAccount[0] (predicted via CREATE2)
     → Account contract does NOT exist on-chain
     → Address is "empty" — no code, no balance

t=2  Bob resolves alice.pq.dstealth.eth → gets stealthPQAccount[0]
     → Bob sends 0.1 ETH to that address
     → Balance arrives at the predicted CREATE2 address
     → App (or worker) detects balance, rotates pq.dstealth.eth → stealthPQAccount[1]

t=3  Alice opens bitchat, sees "0.1 ETH received at stealth address #0"
     → Alice taps "Sweep to main wallet"
     → App builds UserOp:
        sender:   stealthPQAccount[0]
        initCode: factory.createAccount(stealthAddr[0], expandedPQPubKey)
        callData: execute(mainWallet, 0.1 ETH - gas, "")
        signature: hybrid(stealthPrivKey[0], pqMasterSecret)
     → Submit to Pimlico bundler
     → EntryPoint deploys PQ Account + executes sweep in ONE transaction

t=4  Carol resolves alice.pq.dstealth.eth → gets stealthPQAccount[1]
     → Different address, unlinkable to stealthPQAccount[0]
     → alice.dstealth.eth still resolves to 0xABC (unchanged, stable identity)
```

### Gas Optimization for Sweep

The PQ Account deployment is expensive (~5-15M gas) because the 22KB expanded ML-DSA-44 public key must be included in calldata. This is the dominant cost — the actual EVM execution is modest.

| Strategy | Impact | Complexity | Status |
|----------|--------|------------|--------|
| **Deploy on L2 (Arbitrum Sepolia)** | ~$0.10-1.00 per sweep (vs $50-150 on L1) | Low — factory already deployed | ✅ **Do this first** |
| **Self-pay from received funds** | 97%+ sweep efficiency on L2 | Low — calculate balance - gasCost | ✅ **Default strategy** |
| **Minimum balance threshold** | Prevents loss on tiny amounts | Low — `balance > 1.5x estimatedGas` | ✅ **Required** |
| **Paymaster sponsorship** (Pimlico) | 100% sweep efficiency, user pays nothing | Medium — add paymasterAndData | 🔜 Phase 2 |
| **ERC-20 fee token paymaster** | Pay gas in USDC/DAI on mainnet | Medium — Pimlico ERC-20 paymaster | 🔜 Mainnet |
| **Lazy deployment** | Only deploy when sweeping, not on receive | ✅ Already the design | ✅ Done |
| **Batch sweep** | Amortize deployment over multiple outputs | Medium — batch UserOp | ⏳ Later |
| **EIP-8051 precompile** | ~10K gas for ML-DSA verify (vs 5M+ today) | External dependency — would make PQ ≈ Safe cost | ⏳ Future |

**Fluidkey comparison:** Safe's `setup()` has built-in `InitializerExtraFields` (`paymentToken`, `payment`, `paymentReceiver`) that let the deployer pay fees in any ERC-20. PQ Accounts don't have this, but the ERC-4337 paymaster pattern provides the same capability via Pimlico.

---

## 8. Implementation Plan ✅ Phases 1-3, 5 Complete (Phase 4 Deferred)

### Phase 1: Local CREATE2 Prediction ✅ Complete

**Implemented**: `StealthPQAccountManager.swift` (~591 lines)

```swift
actor StealthPQAccountManager {
    // Actual implementation uses:
    //   - HMAC-SHA256 with "self-stealth-ephemeral:" prefix for key derivation
    //   - Option A: shared PQ key (masterPQPubKey) across all stealth accounts
    //   - Two-tier address prediction: offline CREATE2 first, RPC fallback
    
    func generateNextAccount() async throws -> StealthPQAccount  // Increments index + persists
    func predictStealthPQAccountAddress(at index: Int) async throws -> String
    func getStealthPQAccount(at index: Int) async throws -> StealthPQAccount
    func getStealthPrivateKey(at index: Int) async throws -> Data
    func buildStealthInitCode(at index: Int) async throws -> Data
    func scanBalances() async throws -> [StealthPQAccount]  // Scans existing accounts only
    
    var allAccounts: [StealthPQAccount]      // Computed, sorted by index
    var latestAccount: StealthPQAccount?     // Highest index
    var accountCount: Int
    var currentDerivationIndex: Int
}

struct StealthPQAccount: Codable, Identifiable {
    let index: Int
    let stealthSignerAddress: String
    let pqAccountAddress: String
    var balance: String
    let ephemeralPubKey: Data
    var isDeployed: Bool
    var lastChecked: Date?
}
```

**Changes made to existing**:
- `PQAccountDeployer`: Added `predictAddressLocally(preQ:, postQ:)` using CREATE2 formula
- Falls back to `factory.getAddress()` RPC if local prediction fails

### Phase 2: Namestone Stealth Rotation ✅ Complete

**Implemented in**: `NamestoneService.swift` (~502 lines)

All PQ-specific methods targeting `pq.dstealth.eth` are implemented:
```swift
extension NamestoneService {
    private var pqDomain: String { "pq.dstealth.eth" }
    
    // ✅ All implemented:
    func setStealthPQAccountName(name:, stealthPQAddress:, stealthIndex:, stealthMetaAddress:) async throws -> Bool
    func rotateStealthPQAddress(name:, newAddress:, newIndex:) async throws -> Bool
    func getStealthIndex(name:) async throws -> Int?
    func deleteStealthPQName(name:) async throws -> Bool
    func isPQNameAvailable(_:) async throws -> Bool
    func updatePQName(oldName:, newName:, pqAccountAddress:, stealthIndex:) async throws -> Bool
}
```

**Existing flow (UNCHANGED)**: `ChatViewModel.registerENSSubdomainForNewUser()` still registers `nickname.dstealth.eth` → embedded wallet EOA.

**New flow**: After PQ Account setup, registers `nickname.pq.dstealth.eth` → first stealth PQ Account address. Index stored in UserDefaults + Namestone text records.

### Phase 3: Sweep UserOps ✅ Complete

**Implemented in**: `PQTransactionSigner.swift`

Stealth sweep via `sweepStealthAccount()` is working:
```swift
extension PQTransactionSigner {
    /// ✅ Implemented — Deploy stealth PQ Account + sweep funds in one UserOp
    func sweepStealthAccount(
        stealthIndex: Int,
        stealthPrivateKey: Data,   // Per-index ECDSA key (stealth-derived)
        destinationAddress: String,
        amount: BigUInt
    ) async throws -> String  // Returns UserOp hash
}
```

Key detail: the ECDSA signer is the **stealth private key** (derived per-index), not the main wallet key. The ML-DSA-44 signer is the shared master PQ key. Both sign together for hybrid ECDSA + ML-DSA-44 verification.

### Phase 4: Cloudflare Rotation Worker ⏳ Not Yet Built

**Planned**: `workers/stealth-rotator/src/index.js`

On-device rotation is working (see Phase 5). Server-side rotation is deferred:
1. Poll Namestone for `pq.dstealth.eth` names with `stealth.pq=true`
2. Check balances of current stealth addresses
3. If funded, derive next address and update `pq.dstealth.eth` via Namestone
4. Requires viewing key node as a Worker secret
5. Never reads or writes `dstealth.eth` — only operates on the `pq.` subdomain

> **Current status**: On-device rotation covers the MVP. Worker needed for multi-device support.

### Phase 5: UI Integration ✅ Complete

**Implemented**:
- `StealthPQAccountListView.swift` (~730 lines) — View + embedded ViewModel with:
  - Generate button (explicit generate-then-scan pattern, matching EOA stealth UX)
  - Balance scanning (existing accounts only, 3-tier Helios → proof → RPC verification)
  - One-tap sweep + sweep-all
  - ENS registration + rotation after sweep
  - Account list with status badges (Empty / Funded / Sweepable / Swept)
- `PQENSSettingsView.swift` (~352 lines) — Edit `.pq.dstealth.eth` name:
  - TextField with `.pq.dstealth.eth` suffix display
  - Debounced availability check via `isPQNameAvailable()`
  - Format validation (lowercase, alphanumeric, 3-20 chars)
  - Purple-themed to match PQ visual identity
- `WalletView.swift` (~1289 lines) — PQ stealth integration:
  - `pqStealthSection`: shows latest address + account count + link to full list
  - `pqSettingsSection`: separate EOA identity row (`ensLabel.dstealth.eth`) and PQ identity row (`ensLabel.pq.dstealth.eth`)
  - Sheet presentations for `StealthPQAccountListView` and `PQENSSettingsView`

### Phase 6: Migration to Custom CCIP-Read (Future)

Replace Namestone polling with a proper EIP-3668 offchain resolver:
1. Deploy CCIP-Read resolver contract that points to our gateway
2. Gateway (Cloudflare Worker) derives fresh stealth PQ address per query
3. No more polling — address generation is on-demand
4. Fully EIP-3668 compliant

---

## 9. File Summary

### New Files

| File | Purpose | Est. Lines |
|------|---------|------------|
| `bitchat/Services/StealthPQAccountManager.swift` | Stealth PQ Account derivation + prediction | ~300 |
| `bitchat/Views/StealthPQAccountListView.swift` | UI for stealth PQ accounts | ~200 |
| `workers/stealth-rotator/src/index.js` | Cloudflare Worker for address rotation | ~250 |
| `bitchatTests/StealthPQAccountTests.swift` | Tests for derivation + CREATE2 prediction | ~200 |

### Modified Files

| File | Changes |
|------|---------|
| `bitchat/Services/PQAccountDeployer.swift` | Add `predictAddressLocally()` |
| `bitchat/Services/PQTransactionSigner.swift` | Add `sweepStealthAccount()` |
| `bitchat/Services/NamestoneService.swift` | Add `pq.dstealth.eth` stealth rotation methods |
| `bitchat/Services/ENSResolver.swift` | Add `.pq.dstealth.eth` routing to Namestone |
| `bitchat/Utils/ABIEncoder.swift` | Add CREATE2 helper |
| `bitchat/ViewModels/ChatViewModel.swift` | ❌ **No changes** — existing EOA flow untouched |
| `bitchat/ViewModels/PQAccountViewModel.swift` | Register `pq.dstealth.eth` after PQ setup |
| `bitchat/Views/WalletView.swift` | Add stealth PQ section |
| `bitchat/Views/WalletSettingsView.swift` | Add stealth PQ settings |

> **Note on `ChatViewModel.swift`**: The existing `registerENSSubdomainForNewUser()`, `ensName(_:matchesWalletAddress:)`, and `recoverENSSubdomain()` methods all reference `dstealth.eth` and are **not modified**. The stealth PQ flow lives entirely in `PQAccountViewModel` + `NamestoneService` targeting the separate `pq.dstealth.eth` domain.

---

## 10. Comparison Summary

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                    Fluidkey vs bitchat Stealth Accounts                      │
├─────────────────────┬──────────────────────┬────────────────────────────────┤
│                     │ Fluidkey (Safe)       │ bitchat (PQ Account)           │
├─────────────────────┼──────────────────────┼────────────────────────────────┤
│ Smart Account       │ Safe 1/1 Proxy       │ ZKNOX mldsa_k1 ERC-4337       │
│ Signature Scheme    │ ECDSA (secp256k1)    │ Hybrid ECDSA + ML-DSA-44      │
│ Quantum Resistant   │ ❌                    │ ✅                              │
│ Stealth Derivation  │ BIP-32 viewing node  │ HMAC-based viewing key         │
│ Address Prediction  │ Local CREATE2        │ Local CREATE2 (✅ done)        │
│ Counterfactual Dep. │ ✅ Deploy on sweep    │ ✅ Deploy on sweep              │
│ Cross-Chain Same Addr│ ✅ useDefaultAddress │ ✅ Same factory on all chains   │
│ ENS Resolver        │ Custom CCIP-Read     │ Namestone API (✅ working)     │
│ ENS Namespace       │ username.fkey.eth    │ username.pq.dstealth.eth       │
│ Identity ENS        │ (same as above)      │ username.dstealth.eth (separate)│
│ Address Rotation    │ Server-side, per-query│ On-device after sweep (✅ done) │
│ Deploy Cost (L1)    │ ~$0.50-2.00          │ ~$50-150 ❌ (not viable)       │
│ Deploy Cost (L2)    │ ~$0.001-0.01         │ ~$0.10-1.00 ✅ (viable)        │
│ Gas Strategy        │ InitializerExtraFields│ Self-pay / Pimlico paymaster  │
│ ERC-4337 Native     │ ❌ (needs module)     │ ✅ Native                       │
│ Viewing Key Split   │ ✅ BIP-32 node        │ ✅ Same pattern                 │
│ Open Source Kit     │ ✅ npm package         │ ✅ Swift (in-app)               │
│ Maturity            │ Production           │ Testnet (Sepolia)              │
└─────────────────────┴──────────────────────┴────────────────────────────────┘
```

---

## 11. Risks & Mitigations

| Risk | Impact | Mitigation |
|------|--------|------------|
| **PQ Account deploy cost** (~5-15M gas) | High on L1, moderate on L2 | Target Arbitrum Sepolia; future EIP-8051 precompile |
| **Shared PQ pubkey links stealth accounts** | Medium privacy reduction | Use Flashbots for deploy tx; implement per-index PQ keys in Stage 2 |
| **Namestone rate limits** | May throttle rotation | Implement local caching; batch rotations |
| **Worker needs viewing key** | Trust assumption | Viewing key can only generate addresses, not spend. Encrypt at rest in Worker secrets. |
| **CREATE2 salt may differ from factory internals** | Critical correctness | Cross-validate predicted addresses with `factory.getAddress()` RPC call |
| **SwiftDilithium no seed-based keygen** | Blocks per-index PQ keys | Use shared PQ key (Option A) initially |
| **Rotation latency** (polling vs on-demand) | Address reuse if sender is fast | Short poll interval (2 min); or implement CCIP-Read for on-demand |
| **Namestone domain setup** | `pq.dstealth.eth` must be delegated to Namestone | One-time setup by `dstealth.eth` owner; same API key works for both |

---

## 12. Implementation Priority (Revised)

```
Priority 1 — Session MVP ✅ Complete:
  ✅ Register pq.dstealth.eth as Namestone-managed domain (one-time setup)
  ✅ Extract accountCreationCode from factory (one-time bytecode extraction)
  ✅ predictAddressLocally() in PQAccountDeployer (offline CREATE2)
  ✅ StealthPQAccountManager with HMAC-based derivation + address prediction
  ✅ Namestone set-name on pq.dstealth.eth with stealth PQ address after PQ setup
  ✅ ENSResolver: add .pq.dstealth.eth routing to Namestone
  ✅ Cross-validate: assert predictLocal() == factory.getAddress()

Priority 2 — Sweep + Rotate ✅ Complete:
  ✅ sweepStealthAccount() in PQTransactionSigner (deploy + transfer in one UserOp)
  ✅ Self-pay gas: balance - estimatedGas → main wallet
  ✅ Minimum balance threshold enforcement
  ✅ On-device address rotation after successful sweep
  ✅ Namestone set-name on pq.dstealth.eth to rotate to next stealth address

Priority 3 — UI ✅ Complete:
  ✅ StealthPQAccountListView with balances + sweep status
  ✅ Balance polling with 3-tier verification (Helios → proof → RPC)
  ✅ Sweep flow in UI (one-tap + sweep-all)
  ✅ WalletView integration (stealth section + settings section)
  ✅ PQENSSettingsView for editing .pq.dstealth.eth names
  ✅ Generate-then-scan UX pattern (matching EOA stealth)
  ✅ Persistence via App Group container + Documents fallback
  ✅ 21 tests across 6 suites

Priority 4 — Production Hardening (remaining):
  ○ Pimlico paymaster sponsorship (gasless sweeps)
  ○ Cloudflare Worker for rotation (multi-device support)
  ○ Custom CCIP-Read resolver (replace Namestone polling)
  ○ Per-index PQ key derivation (when SwiftDilithium supports seeds)
  ○ Mainnet deployment (Arbitrum/Base, when ZKNOX deploys)
  ○ ERC-20 fee token paymaster for stablecoin flows
```

---

## 13. Quick Start: Namestone Prototype ✅ Complete

All steps have been implemented:

1. ✅ Registered `pq.dstealth.eth` as a Namestone-managed domain (same API key as `dstealth.eth`)
2. ✅ Implemented `StealthPQAccountManager` — derive stealth signers, predict CREATE2 addresses
3. ✅ Added `setStealthPQAccountName()` + 5 more PQ methods to NamestoneService targeting `pq.dstealth.eth`
4. ⏳ Cloudflare Worker deferred — on-device rotation covers MVP
5. ✅ Added `sweepStealthAccount()` to `PQTransactionSigner`
6. ✅ Built `StealthPQAccountListView` + `PQENSSettingsView` for viewing, sweeping, and editing stealth PQ accounts

**Result**:
- `alice.dstealth.eth` → stable identity (embedded wallet EOA, XMTP inbox) — **unchanged**
- `alice.pq.dstealth.eth` → fresh, quantum-resistant smart account address that rotates on every sweep

---

## 14. Practical Approach for bitchat (Session Plan) ✅ Complete

### Core Insight: L2-First, Paymaster-Backed, Lazy Deploy

After analyzing Fluidkey's cross-chain deployment mechanics and the gas economics of PQ accounts, here is the **concrete, practical plan** for bitchat.

---

### 14.1. Cross-Chain Counterfactual Deployment

**How Fluidkey gets the same Safe address on every chain:**

Fluidkey's `predictStealthSafeAddressWithBytecode()` uses `useDefaultAddress: true`, which internally forces `chainId = 1` regardless of the actual chain. This works because Safe's singleton, ProxyFactory, and fallback handler contracts are deployed at **identical addresses** on all major EVM chains (via the Safe team's deterministic deployment). The CREATE2 salt is simply `keccak256(keccak256(initializer), saltNonce=0)`.

**Our equivalent:**

The ZKNOX `mldsa_k1` factory is at `0xe28F039653772C32b0eDB1db7c7A5FA250DDA0e5` on both Sepolia and Arbitrum Sepolia. The CREATE2 address for a PQ Account is:

```
address = keccak256(0xff ++ factory ++ salt ++ keccak256(initCode))[12:]

where:
  factory  = 0xe28F039653772C32b0eDB1db7c7A5FA250DDA0e5
  salt     = keccak256(abi.encode(preQuantumPubKey, postQuantumPubKey, saltNonce=0))
  initCode = accountCreationCode ++ abi.encode(preQuantumPubKey, postQuantumPubKey)
```

**Same address on any chain where the factory is deployed.** No chain-specific logic needed. Just like Fluidkey, we predict the address once and it's valid everywhere.

**Action item:** Extract the exact `accountCreationCode` bytecode from the deployed factory on Sepolia (one-time). Store it as a constant in `PQAccountDeployer.swift`. This is the only piece we need for offline CREATE2 prediction.

---

### 14.2. Gas Economics: The Honest Numbers

```
┌────────────────────────────────────────────────────────────────────────────┐
│                    Gas Cost Comparison: Deploy + Sweep                      │
├─────────────────────┬───────────────┬──────────────────────────────────────┤
│                     │ Safe (Fluidkey)│ PQ Account (bitchat)                │
├─────────────────────┼───────────────┼──────────────────────────────────────┤
│ Deploy gas          │ ~240K          │ ~5-15M (22KB ML-DSA-44 pubkey)      │
│ Sweep tx gas        │ ~40K           │ ~40K (execute() call)               │
│ Total gas           │ ~280K          │ ~5-15M                              │
├─────────────────────┼───────────────┼──────────────────────────────────────┤
│ L1 Ethereum ($)     │ ~$0.50-2.00    │ ~$50-150 ❌ (not viable)            │
│ Arbitrum ($)        │ ~$0.001-0.01   │ ~$0.10-1.00 ✅ (viable)             │
│ Base ($)            │ ~$0.001-0.01   │ ~$0.05-0.50 ✅ (viable)             │
│ OP Mainnet ($)      │ ~$0.001-0.01   │ ~$0.05-0.50 ✅ (viable)             │
├─────────────────────┼───────────────┼──────────────────────────────────────┤
│ Future (EIP-8051)   │ N/A            │ ~10K gas for ML-DSA verify 🎯       │
│                     │                │ Total would drop to ~250K (~= Safe) │
└─────────────────────┴───────────────┴──────────────────────────────────────┘
```

**Key takeaway:** PQ stealth accounts are **only viable on L2s** today. On Arbitrum Sepolia, a deploy+sweep costs ~$0.10-1.00, which is acceptable for a testnet/alpha product. On L1, the 22KB calldata makes it prohibitively expensive until EIP-8051 precompiles land.

---

### 14.3. Three Gas Payment Strategies

Fluidkey's Safe has `InitializerExtraFields` baked into the contract's `setup()` function, allowing deployment fees to be paid in any ERC-20 token to a relayer. PQ Accounts don't have this built-in, so we need alternatives:

#### Strategy 1: Self-Pay from Received Funds (Simplest)

```
Received 0.1 ETH at stealth PQ Account
  → Deploy PQ Account:    costs ~0.003 ETH on Arbitrum
  → Sweep remaining:      0.097 ETH → main wallet
  → Net received:         0.097 ETH (97% efficiency)
```

**Minimum balance threshold**: Only allow sweep when `balance > estimatedDeployGas * 1.5`. This prevents users from losing money to gas on tiny amounts.

```swift
// In StealthPQAccountManager
let minimumSweepBalance: BigUInt = 5_000_000_000_000_000  // 0.005 ETH on Arbitrum
// OR dynamically: let threshold = estimateGas() * gasPrice * 150 / 100
```

**This is the recommended default for bitchat.** Simple, no external dependencies, works today.

#### Strategy 2: Pimlico Paymaster Sponsorship (Best UX)

```
Received 0.1 ETH at stealth PQ Account
  → Paymaster sponsors deploy + sweep gas
  → Full 0.1 ETH swept to main wallet
  → Net received: 0.1 ETH (100% efficiency)
```

Pimlico's verifying paymaster can sponsor UserOps. We already use Pimlico as our bundler. Adding paymaster sponsorship requires:

1. Get a Pimlico paymaster policy (testnet = free, mainnet = deposit-based)
2. Add `paymasterAndData` to the PackedUserOperation before signing
3. The paymaster verifies the UserOp and co-signs it

```swift
// In UserOperationBuilder
func addPaymasterSponsorship(
    to userOp: inout PackedUserOperation,
    paymasterUrl: String
) async throws {
    // 1. Call pm_sponsorUserOperation on Pimlico
    // 2. Set userOp.paymasterAndData = response.paymasterAndData
    // 3. Re-estimate gas limits with paymaster overhead
}
```

**Use for: testnet demos, onboarding new users, small amounts where self-pay would eat too much.**

#### Strategy 3: ERC-20 Fee Token via Paymaster (Advanced)

For mainnet, let users pay gas in USDC/USDT/DAI:

```
Received 100 USDC + 0 ETH at stealth PQ Account
  → Paymaster accepts 0.50 USDC as gas payment
  → Deploy + sweep in one tx
  → Net received: 99.50 USDC
```

This mirrors Fluidkey's `InitializerExtraFields` (paymentToken, payment, paymentReceiver) but uses the ERC-4337 paymaster pattern instead. Pimlico supports ERC-20 paymasters natively.

**Use for: mainnet, when users receive stablecoins at stealth addresses.**

---

### 14.4. What to Build in the Session

#### Session Goal ✅ Achieved

**End state:** Alice registers `alice.pq.dstealth.eth`. Bob sends ETH to that ENS name. Alice sees the incoming funds in bitchat and sweeps them to her main wallet in one tap. The address rotates so the next sender gets a fresh address. A separate `PQENSSettingsView` lets Alice edit her `.pq.dstealth.eth` label.

#### Session Workplan — All Blocks ✅ Complete

```
┌────────────────────────────────────────────────────────────────────────────┐
│  BLOCK 1: CREATE2 Prediction ✅ Complete                                   │
│  ──────────────────────────────────────────────────────────────────────────│
│  Implemented: StealthPQAccountManager.predictStealthPQAccountAddress()     │
│  Uses PQAccountDeployer.predictAddressLocally() with RPC fallback.         │
│  Tested: StealthPQAccountTests (CREATE2 prediction suite, 3 tests)        │
├────────────────────────────────────────────────────────────────────────────┤
│  BLOCK 2: Stealth PQ Account Manager ✅ Complete                           │
│  ──────────────────────────────────────────────────────────────────────────│
│  Implemented: StealthPQAccountManager.swift (~591 lines)                   │
│  HMAC-SHA256 derivation with "self-stealth-ephemeral:" prefix.             │
│  Option A (shared PQ key). Persistence via App Group + Documents fallback. │
│  Generate-then-scan UX: generateNextAccount() is explicit, separate from   │
│  scanBalances() which only checks existing accounts.                       │
├────────────────────────────────────────────────────────────────────────────┤
│  BLOCK 3: Namestone Registration on pq.dstealth.eth ✅ Complete            │
│  ──────────────────────────────────────────────────────────────────────────│
│  Implemented: 6 methods in NamestoneService.swift targeting pqDomain.      │
│  set, rotate, delete, getIndex, isPQNameAvailable, updatePQName.           │
│  All requests routed via Tor on mainnet. alice.dstealth.eth untouched.     │
├────────────────────────────────────────────────────────────────────────────┤
│  BLOCK 4: Sweep UserOp ✅ Complete                                         │
│  ──────────────────────────────────────────────────────────────────────────│
│  Implemented: PQTransactionSigner.sweepStealthAccount()                    │
│  Hybrid signature: stealth ECDSA key + master ML-DSA-44 key.              │
│  Self-pay gas from received balance. Deploy + sweep in single UserOp.      │
├────────────────────────────────────────────────────────────────────────────┤
│  BLOCK 5: Rotation + UI ✅ Complete                                        │
│  ──────────────────────────────────────────────────────────────────────────│
│  Implemented:                                                              │
│  - StealthPQAccountListView (~730 lines) with embedded ViewModel           │
│  - PQENSSettingsView (~352 lines) for editing .pq.dstealth.eth names       │
│  - WalletView: pqStealthSection + pqSettingsSection with separate          │
│    EOA/PQ ENS rows (ensLabel extraction avoids duplicate domain)           │
│  - On-device rotation after sweep via Namestone API                        │
│  - 3-tier balance verification: Helios → Merkle proof → RPC               │
│  - 21 tests across 6 suites                                               │
└────────────────────────────────────────────────────────────────────────────┘
```

---

### 14.5. What NOT Built Yet (Deferred)

| Feature | Why Deferred | When to Add |
|---------|--------------|-------------|
| **Per-index PQ key derivation (Option B)** | SwiftDilithium has no seed-based keygen | When upstream adds it, or when BIP39-PQ is standardized |
| **Custom CCIP-Read resolver** | Namestone set-name API on `pq.dstealth.eth` is working | When polling latency becomes a problem |
| **L1 Ethereum deployment** | Too expensive ($50-150 per sweep) | When EIP-8051 precompile ships |
| **ERC-20 fee token paymaster** | Only needed for mainnet stablecoin flows | After mainnet launch |
| **Auto-earn module** (Fluidkey's auto-DeFi) | Out of scope for messaging app | Never (different product) |
| **Cloudflare rotation worker** | ✅ On-device rotation is working (MVP) | When multi-device sync needed |
| **Batch sweep** (multiple stealth accounts in one UserOp) | Adds complexity, marginal savings on L2 | When users accumulate many small deposits |
| **Pimlico paymaster sponsorship** | Self-pay gas from received balance works on L2 | When gasless UX is required |

> **Note**: On-device rotation, balance scanning, and ENS editing were originally listed as "skip" items but were implemented during development because they were essential to the UX.

---

### 14.6. Target Chain & Network Config

```swift
// StealthPQAccountConfig.swift
enum StealthPQAccountConfig {
    // Primary: Arbitrum Sepolia (gas-viable for PQ accounts)
    static let chainId: UInt64 = 421614
    static let rpcUrl = "https://sepolia-rollup.arbitrum.io/rpc"
    static let entryPoint = "0x0000000071727De22E5E9d8BAf0edAc6f37da032"
    static let pqFactory = "0xe28F039653772C32b0eDB1db7c7A5FA250DDA0e5"
    
    // Gas thresholds (Arbitrum Sepolia)
    static let estimatedDeployGas: UInt64 = 8_000_000     // ~8M gas for PQ deploy
    static let estimatedSweepGas: UInt64 = 100_000        // ~100K for execute()
    static let minimumSweepBalanceWei = "5000000000000000" // 0.005 ETH
    
    // Mainnet targets (when factory is deployed)
    // static let arbitrumChainId: UInt64 = 42161
    // static let baseChainId: UInt64 = 8453
}
```

---

### 14.7. End-to-End Demo Script

```
1. Alice opens bitchat → existing flow:
   → Generates embedded wallet EOA (0xABC...)
   → Registers alice.dstealth.eth → 0xABC (identity/messaging)
   → Creates XMTP inbox, stores inbox ID in text records
   (This is the EXISTING flow. Nothing changes here.)

2. Alice enables PQ Account (Wallet Settings):
   → Creates PQ Account on Arbitrum Sepolia (existing PQ flow)
   → App predicts stealthPQAccount[0] via CREATE2
   → Registers alice.pq.dstealth.eth → stealthPQAccount[0]
   → text_records: { stealth.pq: true, stealth.index: 0 }

3. Bob (any wallet) resolves alice.pq.dstealth.eth via ENS
   → Gets stealthPQAccount[0] (a counterfactual address, no code on-chain)
   → Bob sends 0.05 ETH to that address on Arbitrum Sepolia

4. Alice's app polls balance of stealthPQAccount[0]
   → Detects 0.05 ETH
   → Shows: "Stealth Account #0: 0.05 ETH — Sweep available"

5. Alice taps "Sweep"
   → App builds UserOp:
     sender: stealthPQAccount[0]
     initCode: factory.createAccount(stealthSigner[0], masterPQPubKey)
     callData: execute(aliceMainWallet, 0.047 ETH, "")  // minus gas
     signature: hybrid(stealthPrivKey[0], pqMasterSecret)
   → Submits to Pimlico on Arbitrum Sepolia
   → One tx: deploys PQ Account + sweeps funds

6. After sweep, app rotates:
   → Predicts stealthPQAccount[1]
   → Updates Namestone: alice.pq.dstealth.eth → stealthPQAccount[1]
   → Increments stealth.index to 1
   → alice.dstealth.eth is UNCHANGED (still 0xABC, still the messaging identity)

7. Carol sends ETH to alice.pq.dstealth.eth
   → Gets stealthPQAccount[1] (completely different address)
   → Carol and Bob cannot link their payments to the same recipient
   → Alice's messaging identity (alice.dstealth.eth) remains stable and unlinkable
      to her payment addresses
```

---

### 14.8. Decision Log

| Decision | Rationale |
|----------|-----------|
| **`pq.dstealth.eth` namespace (not `dstealth.eth`)** | Existing app registers `nick.dstealth.eth` → embedded wallet EOA on first launch. Reusing that domain would break the identity/messaging flow. Separate `pq.dstealth.eth` domain lets payments rotate without touching the stable identity. Same Namestone API key manages both. |
| **L2-first (Arbitrum Sepolia)** | PQ Account deploy costs ~$0.10-1.00 on L2 vs ~$50-150 on L1. Only viable path today. |
| **Self-pay gas (Strategy 1)** | Simplest implementation. 97%+ sweep efficiency on L2. No paymaster dependency. |
| **Option A (shared PQ key)** | SwiftDilithium blocks Option B. Shared key still gives quantum resistance. Privacy trade-off is acceptable — same as Fluidkey's public Safe singleton. |
| **On-device rotation (not Worker)** | MVP simplicity. App rotates after sweep. No viewing key leaves device. |
| **Arbitrum Sepolia over Base Sepolia** | Factory already deployed there. Both are equally viable for gas costs. |
| **Namestone polling (not CCIP-Read)** | 10x faster to ship. Can migrate later. Fluidkey started with a simple backend too. |
| **Minimum balance threshold** | Prevents users from losing money. 0.005 ETH on Arbitrum covers ~1.5x deploy cost with margin. |
| **Generate-then-scan UX** | Matches EOA stealth address pattern. User explicitly taps "Generate" to create new accounts, then "Scan" to check balances on existing accounts. Avoids creating unbounded accounts during background scans. |
| **`ensLabel` computed property** | `ensSubdomain` stores full name (`"alice.dstealth.eth"`). Naively appending `.pq.dstealth.eth` caused duplicate domain (`alice.dstealth.eth.pq.dstealth.eth`). `ensLabel` strips `.dstealth.eth`/`.pq.dstealth.eth` suffixes to extract just the label (`"alice"`). |
| **Separate EOA/PQ ENS rows in WalletView** | EOA identity row (`alice.dstealth.eth` → `ENSSettingsView`) and PQ stealth identity row (`alice.pq.dstealth.eth` → `PQENSSettingsView`) are independent. Each row uses `ensLabel` to avoid duplicate domain display. |
| **App Group + Documents fallback for persistence** | `StealthPQAccountManager` persists JSON to App Group container (`BitchatApp.groupID`). Falls back to Documents directory when App Group is unavailable (e.g., Simulator). Matches `StealthAddressStore` pattern. |
| **3-tier balance verification** | `EthereumBalanceService` verifies via: (1) Helios light client, (2) `eth_getProof` Merkle proof, (3) unverified RPC. Returns `VerificationLevel` enum so UI can display trust level. |
| **ViewModel `manager`/`namestoneService` accessibility** | Changed from `private` to internal access so `PQENSSettingsView` and `WalletView` can access them for ENS operations without duplicating service instances. |
