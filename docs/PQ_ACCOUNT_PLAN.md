# Post-Quantum (PQ) ERC-4337 Account — Implementation Plan

## Executive Summary

Integrate [kohaku pq-account](https://github.com/ethereum/kohaku/tree/master/examples/pq-account) into bitchat's iOS app, enabling users to create and operate a **quantum-resistant ERC-4337 smart account** on Sepolia directly from their phone. The PQ account uses a **hybrid dual-signature scheme** (ECDSA secp256k1 + ML-DSA-44) — both signatures are required for every UserOperation, providing security even if either scheme is broken.

All operations happen **locally on-device**. No deployment server is needed — the factory contracts are already deployed on Sepolia.

---

## Architecture Overview

```
┌──────────────────────────────────────────────┐
│                  bitchat iOS                 │
│                                              │
│  ┌─────────────┐    ┌─────────────────────┐  │
│  │ EOA Wallet  │    │  PQ Account Manager │  │
│  │ (secp256k1) │◄──►│  (ML-DSA-44 keys)   │  │
│  │ EmbeddedWal │    │  PQAccountService   │  │
│  └──────┬──────┘    └──────────┬──────────┘  │
│         │                      │             │
│         │    ┌─────────────────┘             │
│         ▼    ▼                               │
│  ┌────────────────┐   ┌──────────────────┐   │
│  │ UserOperation  │   │  ABI Encoder     │   │
│  │ Builder        │──►│  (calldata,      │   │
│  │ + Hybrid Signer│   │   signatures)    │   │
│  └───────┬────────┘   └──────────────────┘   │
│          │                                   │
└──────────┼───────────────────────────────────┘
           │
           ▼
    ┌──────────────┐      ┌─────────────────┐
    │   Pimlico    │      │   Sepolia RPC    │
    │   Bundler    │─────►│   (EntryPoint    │
    │   (ERC-4337) │      │    v0.7)         │
    └──────────────┘      └─────────────────┘
```

### Signing Flow

```
UserOperation
     │
     ├──► keccak256(packed fields) ──► userOpHash (32 bytes)
     │
     ├──► ECDSA sign(userOpHash, eoaPrivateKey) ──► preQuantumSig (65 bytes, r+s+v)
     │
     ├──► ML-DSA-44 sign(userOpHash, mldsaSecretKey) ──► postQuantumSig (2420 bytes)
     │
     └──► abi.encode(["bytes","bytes"], [preQuantumSig, postQuantumSig]) ──► hybridSignature
```

---

## Deployed Contract Addresses (Sepolia)

| Contract | Address | Notes |
|----------|---------|-------|
| EntryPoint v0.7 | `0x0000000071727De22E5E9d8BAf0edAc6f37da032` | Canonical ERC-4337 |
| MLDSA Verifier | `0x10c978aacef41c74e35fc30a4e203bf8d9a9e548` | Pure ML-DSA-44 |
| ECDSAK1 Verifier | `0xe2c354d06cce8f18fd0fd6e763a858b6963456d1` | secp256k1 ECDSA |
| MLDSA + K1 Factory | **Lookup from `deployments.json`** | `mldsa_k1` account mode |

> The factory address must be fetched from the kohaku repo's `packages/pq-account/deployments/deployments.json` at path `.sepolia.accounts.mldsa_k1.address`. Hardcode it once confirmed.

---

## Phase 1: Swift PQ Library Integration

### Selected Library: [SwiftDilithium](https://github.com/leif-ibsen/SwiftDilithium)

| Property | Value |
|----------|-------|
| Package | `leif-ibsen/SwiftDilithium` |
| Version | `3.5.0` |
| Standard | NIST FIPS 204 (ML-DSA) |
| Supported kinds | ML-DSA-44, ML-DSA-65, ML-DSA-87 |
| License | MIT |
| Platforms | iOS, macOS, watchOS, tvOS, visionOS |
| Swift version | 5.0+ |
| Dependencies | ASN1, BigInt, Digest (all from leif-ibsen) |
| Data race safety | Zero errors |

### Why SwiftDilithium

- **Only viable pure-Swift ML-DSA implementation** — all `liboqs-swift` variants returned 404 / are unmaintained
- NIST ACVP test vectors compliance (final spec, not draft)
- No C dependencies — pure Swift, App Store safe
- Supports deterministic and randomized signing
- PEM/ASN1 key serialization built in

### Other Libraries Evaluated

| Library | Status | Issue |
|---------|--------|-------|
| `nicklimmm/liboqs-swift` | 404 | Repository not found |
| `nicklimmm/SWIFTPQCRYPTO` | 404 | Repository not found |
| `nicklimmm/pq-crypto-swift` | 404 | Repository not found |
| `nicklimmm/swift-pq-crypto` | 404 | Repository not found |
| Apple CryptoKit | N/A | No ML-DSA support |
| OpenSSL | Complex | Would require C bridging, massive binary size |

### API Surface (SwiftDilithium)

```swift
import SwiftDilithium

// Key Generation (ML-DSA-44)
let (secretKey, publicKey) = Dilithium.GenerateKeyPair(kind: .d44)

// From seed (deterministic)
let secretKey = try SecretKey(kind: .d44, seed: seedBytes)  // 32-byte seed
let publicKey = secretKey.publicKey

// Signing
let signature: Bytes = secretKey.Sign(message: messageBytes)           // deterministic
let signature: Bytes = secretKey.Sign(message: messageBytes, randomize: true) // randomized

// Verification
let valid: Bool = publicKey.Verify(message: messageBytes, signature: signature)

// Serialization
let skBytes: Bytes = secretKey.keyBytes   // raw secret key bytes
let pkBytes: Bytes = publicKey.keyBytes   // raw public key bytes (1312 bytes for ML-DSA-44)

// PEM (for storage)
let skPem: String = secretKey.pem
let pkPem: String = publicKey.pem
let sk = try SecretKey(pem: pemString)
```

### Package.swift Changes

Add to existing `dependencies` array:
```swift
.package(url: "https://github.com/leif-ibsen/SwiftDilithium", from: "3.5.0"),
```

Add to target dependencies:
```swift
.product(name: "SwiftDilithium", package: "SwiftDilithium"),
```

> **Note**: SwiftDilithium transitively pulls in `ASN1`, `BigInt`, and `Digest` — all lightweight, pure Swift packages from the same author.

---

## Phase 2: PQ Key Management

### New File: `bitchat/Services/PQKeyManager.swift`

An `actor` (matching the `EmbeddedWallet` pattern) that manages ML-DSA-44 key lifecycle.

#### Key Generation Strategy

Two options — **recommend Option A**:

**Option A: Derived from EOA private key (deterministic)**
```
pqSeed = keccak256("bitchat-pq-v1" || eoaPrivateKey)
(secretKey, publicKey) = ML-DSA-44.keygen(pqSeed)
```
- Pros: No additional backup needed, PQ key is recoverable from EOA key
- Cons: PQ key is compromised if EOA key is compromised (but the hybrid scheme means an attacker still needs both)

**Option B: Independent random seed**
```
pqSeed = SecRandomCopyBytes(32)
(secretKey, publicKey) = ML-DSA-44.keygen(pqSeed)
```
- Pros: Independent security domain
- Cons: Requires separate backup/export

#### Keychain Storage

| Item | Keychain Key | Size |
|------|-------------|------|
| PQ Seed (32 bytes) | `bitchat.pq.seed` | 32 B |
| ML-DSA Secret Key | `bitchat.pq.secretkey` | ~2560 B (ML-DSA-44) |
| ML-DSA Public Key | `bitchat.pq.publickey` | 1312 B |
| PQ Account Address | `bitchat.pq.account.address` | 42 B (hex string) |

Store the **seed** in Keychain (compact), derive keys on launch. Cache secret/public keys in memory for the session.

#### Actor Interface

```swift
actor PQKeyManager {
    // Key lifecycle
    func getOrCreateKeys(from wallet: EmbeddedWallet) async throws -> (SecretKey, PublicKey)
    func getPublicKey() throws -> PublicKey
    func getSecretKey() throws -> SecretKey
    func keysExist() -> Bool
    func clearKeys()
    
    // Signing
    func sign(message: Data) throws -> Data  // Returns ML-DSA-44 signature (2420 bytes)
    
    // Account tracking
    func getAccountAddress() -> String?
    func setAccountAddress(_ address: String)
    
    // Export
    func exportSeed() throws -> Data
}
```

---

## Phase 3: ML-DSA Public Key Expansion (Critical)

### The Problem

The kohaku smart contracts expect the ML-DSA public key in an **expanded** form — not the raw 1312-byte FIPS 204 encoding. The expansion involves:

1. **Decode** the 1312-byte public key into `rho` (32 bytes) and `t1` (4 polynomials × 320 bytes)
2. **Recover `Â` matrix** from `rho` using SHAKE-128 (rejection sampling, 4×4 matrix of degree-256 polynomials)
3. **Compute `tr`** = SHAKE-256(publicKey, 64 bytes)
4. **Compact** the `Â` matrix and `t1` into 256-bit words
5. **ABI-encode** as `encode(["bytes","bytes","bytes"], [aHatEncoded, tr, t1Encoded])`

This is implemented in the kohaku JS reference as `to_expanded_encoded_bytes()` in `utils_mldsa.ts`.

### New File: `bitchat/Services/MLDSAKeyExpander.swift`

Port the following functions from `utils_mldsa.ts` to Swift:

| JS Function | Purpose | Swift Equivalent |
|-------------|---------|-----------------|
| `decodePublicKey(pk)` | Split raw pk into `rho`, `t1[]` | `decodePublicKey(_:)` |
| `RejectionSamplePoly(rho, i, j)` | SHAKE-128 XOF → polynomial coefficients | `rejectionSamplePoly(_:_:_:)` |
| `recoverAhat(rho, K, L)` | Build 4×4 matrix of polynomials | `recoverAHat(_:_:_:)` |
| `polyDecode10Bits(bytes)` | Decode 10-bit packed polynomial | `polyDecode10Bits(_:)` |
| `compact_module_256(data, m)` | Pack polynomial coefficients into uint256 words | `compactModule256(_:_:)` |
| `compact_poly_256(coeffs, m)` | Pack single polynomial | `compactPoly256(_:_:)` |
| `to_expanded_encoded_bytes(pk)` | Full pipeline → ABI-encoded bytes | `toExpandedEncodedBytes(_:)` |

#### SHAKE-128 Dependency

SwiftDilithium internally uses SHAKE-128/256 but doesn't export it. Options:
1. **Use the `Digest` package** (already a transitive dependency of SwiftDilithium) — check if it exposes SHAKE XOF
2. **Use CryptoKit** — `SHA3` is not available in CryptoKit; would need another approach
3. **Use CryptoSwift** (already in the project via CocoaPods) — has `SHA3` but not SHAKE XOF
4. **Add `swift-crypto`** from Apple — doesn't have SHAKE either
5. **Implement SHAKE-128 XOF manually** — the Keccak sponge is not complex but error-prone
6. **Best option: Use the `Digest` package directly** — it's already pulled in by SwiftDilithium and likely has SHAKE support

> **Investigation needed**: Check if `leif-ibsen/Digest` exposes `SHAKE128` XOF. If not, consider adding a lightweight SHAKE implementation or using CryptoSwift's Keccak with manual XOF.

#### ABI Encoding

Need a minimal Solidity ABI encoder in Swift for:
- `encode(["uint256[][][]"], [aHat])` — 3D array of uint256
- `encode(["uint256[][]"], [t1])` — 2D array of uint256
- `encode(["bytes","bytes","bytes"], [aHat, tr, t1])` — dynamic bytes tuple

### New File: `bitchat/Utils/ABIEncoder.swift`

Implement a minimal subset of Solidity ABI encoding:

```swift
struct ABIEncoder {
    static func encode(types: [ABIType], values: [ABIValue]) -> Data
    static func encodePacked(types: [ABIType], values: [ABIValue]) -> Data
    
    // Convenience for the PQ account
    static func encodeCreateAccount(preQuantumPubKey: Data, postQuantumPubKey: Data) -> Data
    static func encodeHybridSignature(preQuantumSig: Data, postQuantumSig: Data) -> Data
}
```

> The project already has hand-rolled RLP in `EmbeddedWallet`. ABI encoding is simpler — just fixed-size slots and dynamic offset pointers.

---

## Phase 4: ERC-4337 Infrastructure

### New File: `bitchat/Services/UserOperationBuilder.swift`

#### UserOperation Struct (ERC-4337 v0.7 "Packed")

```swift
struct PackedUserOperation {
    let sender: String              // PQ account address
    var nonce: BigUInt              // from account.getNonce()
    var initCode: Data             // empty after deployment
    var callData: Data             // account.execute(dest, value, func)
    var accountGasLimits: Data     // packed uint128(verificationGas, callGas)
    var preVerificationGas: BigUInt
    var gasFees: Data              // packed uint128(maxPriorityFee, maxFee)
    var paymasterAndData: Data     // empty (self-funded)
    var signature: Data            // hybrid ECDSA + ML-DSA
}
```

#### UserOperation Hash Computation

Port from `getUserOpHash()` in `userOperation.ts`:

```
1. Pack: encode([sender, nonce, keccak(initCode), keccak(callData), 
                  accountGasLimits, preVerificationGas, gasFees, keccak(paymasterAndData)])
2. Inner hash: keccak256(packed)
3. Final: keccak256(encode([innerHash, entryPointAddress, chainId]))
```

#### Hybrid Signature Construction

```swift
func signUserOpHybrid(
    userOp: PackedUserOperation,
    entryPointAddress: String,
    chainId: UInt64,
    eoaPrivateKey: Data,
    mldsaSecretKey: SecretKey
) throws -> Data {
    let userOpHash = getUserOpHash(userOp, entryPointAddress, chainId)
    
    // 1. ECDSA sign (secp256k1) — reuse EmbeddedWallet.signTransactionHash
    let ecdsaSig = try signWithRecovery(userOpHash, eoaPrivateKey) // r(32) + s(32) + v(1) = 65 bytes
    
    // 2. ML-DSA-44 sign
    let mldsaSig = mldsaSecretKey.Sign(message: Array(userOpHash)) // 2420 bytes
    
    // 3. ABI encode as (bytes, bytes)
    return ABIEncoder.encode(
        types: [.bytes, .bytes],
        values: [.bytes(ecdsaSig), .bytes(Data(mldsaSig))]
    )
}
```

### New File: `bitchat/Services/PimlicoBundler.swift`

JSON-RPC client for the Pimlico bundler:

```swift
actor PimlicoBundler {
    let apiKey: String
    let chainId: UInt64
    
    var bundlerURL: URL {
        URL(string: "https://api.pimlico.io/v2/\(chainId)/rpc?apikey=\(apiKey)")!
    }
    
    // Gas estimation
    func estimateUserOperationGas(_ userOp: PackedUserOperation) async throws -> GasEstimates
    
    // Submit UserOperation
    func sendUserOperation(_ userOp: PackedUserOperation, entryPoint: String) async throws -> String
    
    // Check receipt
    func getUserOperationReceipt(_ hash: String) async throws -> UserOperationReceipt?
}

struct GasEstimates {
    let verificationGasLimit: BigUInt
    let callGasLimit: BigUInt
    let preVerificationGas: BigUInt
}
```

---

## Phase 5: Account Deployment Flow

### How Account Creation Works

1. User's EOA funds gas on Sepolia
2. App derives `preQuantumPubKey` = EOA address (20 bytes, ABI-encoded)
3. App generates ML-DSA-44 keys, computes `postQuantumPubKey` = expanded encoded public key (~20KB)
4. App calls `factory.createAccount(preQuantumPubKey, postQuantumPubKey)` as a regular EOA transaction
5. Factory deploys a new `ZKNOX_ERC4337_account` via CREATE2
6. The account address is deterministic: `factory.getAddress(preQuantumPubKey, postQuantumPubKey)`

### New File: `bitchat/Services/PQAccountDeployer.swift`

```swift
actor PQAccountDeployer {
    let factoryAddress: String
    let rpcURL: String
    
    // Predict the account address without deploying
    func getAccountAddress(
        preQuantumPubKey: Data,
        postQuantumPubKey: Data
    ) async throws -> String
    
    // Deploy the account (sends EOA transaction to factory)
    func deployAccount(
        wallet: EmbeddedWallet,
        pqKeyManager: PQKeyManager,
        balanceService: EthereumBalanceService
    ) async throws -> DeploymentResult
    
    // Check if account is already deployed
    func isDeployed(address: String) async throws -> Bool
}

struct DeploymentResult {
    let success: Bool
    let address: String?
    let transactionHash: String?
    let gasUsed: String?
    let alreadyExists: Bool
}
```

#### Deployment Transaction Details

The deployment is a **regular EOA transaction** (not a UserOperation), since the PQ account doesn't exist yet:

```
to:       factoryAddress
value:    0
data:     factory.createAccount.encode(preQuantumPubKey, postQuantumPubKey)
gasLimit: ~5,000,000+ (estimate via eth_estimateGas — the expanded PK is ~20KB calldata)
```

> **Gas cost warning**: Deploying with the expanded public key on L1 Sepolia is very expensive (~5-15M gas). Consider recommending Arbitrum Sepolia for lower costs. The app should show a gas estimate before deployment.

---

## Phase 6: Transaction Sending via PQ Account

### Flow

1. Build `callData` = `account.execute(targetAddress, value, innerCalldata)`
2. Create `UserOperation` with the PQ account as `sender`
3. Sign with hybrid scheme (ECDSA + ML-DSA)
4. Estimate gas via Pimlico
5. Re-sign with final gas values
6. Submit via Pimlico bundler

### New File: `bitchat/Services/PQTransactionSigner.swift`

```swift
@MainActor
final class PQTransactionSigner {
    let wallet: EmbeddedWallet
    let pqKeyManager: PQKeyManager
    let bundler: PimlicoBundler
    let accountAddress: String
    
    func signAndSubmitTransfer(
        to: String,
        amountWei: BigUInt,
        description: String
    ) async throws -> String  // returns userOpHash
    
    func signAndSubmitContractCall(
        to: String,
        data: Data,
        value: BigUInt
    ) async throws -> String
}
```

---

## Phase 7: Settings UI

### Modified File: `bitchat/Views/WalletSettingsView.swift`

Add a new section between "Wallet" and "Stealth Addresses":

```swift
Section {
    Toggle("Enable Post-Quantum Security", isOn: $enablePQAccount)
    
    if enablePQAccount {
        // Pimlico API Key
        HStack {
            Text("Bundler API Key")
            Spacer()
            SecureField("Pimlico API Key", text: $pimlicoAPIKey)
                .multilineTextAlignment(.trailing)
        }
        
        // PQ Key Status
        HStack {
            Text("ML-DSA-44 Keys")
            Spacer()
            if pqKeysGenerated {
                Label("Generated", systemImage: "checkmark.shield.fill")
                    .foregroundColor(.green)
            } else {
                Button("Generate") { generatePQKeys() }
            }
        }
        
        // Account Deployment Status
        if pqKeysGenerated {
            HStack {
                Text("PQ Account")
                Spacer()
                if let address = pqAccountAddress {
                    Text(address.prefix(8) + "..." + address.suffix(4))
                        .font(.caption.monospaced())
                } else {
                    Button("Deploy") { deployPQAccount() }
                }
            }
            
            if isDeploying {
                HStack {
                    ProgressView()
                    Text("Deploying...")
                        .font(.caption)
                }
            }
            
            // Gas estimate
            if let gasEstimate = deploymentGasEstimate {
                Text("Est. gas: \(gasEstimate) ETH")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        }
        
        // Export PQ Seed
        Button("Export PQ Seed") { showPQSeedExport = true }
            .foregroundColor(.orange)
    }
} header: {
    Label("Post-Quantum Security", systemImage: "shield.checkered")
} footer: {
    Text("Hybrid ECDSA + ML-DSA-44 smart account (ERC-4337) on Sepolia. Requires Pimlico API key for transaction submission.")
}
```

#### New AppStorage Keys

```swift
@AppStorage("pq-account-enabled") private var enablePQAccount = false
@AppStorage("pq-pimlico-api-key") private var pimlicoAPIKey = ""
@AppStorage("pq-account-address") private var pqAccountAddress: String?
@AppStorage("pq-keys-generated") private var pqKeysGenerated = false
```

---

## Phase 8: Wallet View Toggle

### Modified File: `bitchat/Views/WalletView.swift`

Add a `Picker` at the top of the wallet view to switch between EOA and PQ account views:

```swift
// At the top of the body, before QR code section
if enablePQAccount && pqAccountAddress != nil {
    Picker("Account Mode", selection: $activeAccountMode) {
        Text("EOA").tag(AccountMode.eoa)
        Text("PQ Account").tag(AccountMode.pqAccount)
    }
    .pickerStyle(.segmented)
    .padding(.horizontal)
}
```

When `activeAccountMode == .pqAccount`:
- Show PQ account address instead of EOA address
- Show PQ account balance (fetch separately)
- Show "Send via PQ" button (builds UserOperation instead of raw tx)
- Show PQ transaction history (query bundler for UserOperation receipts)
- Display a shield icon / quantum-safe badge

```swift
enum AccountMode: String {
    case eoa = "eoa"
    case pqAccount = "pq"
}

@AppStorage("active-account-mode") private var activeAccountMode: AccountMode = .eoa
```

---

## Phase 9: Service Container Integration

### Modified File: `bitchat/Services/XMTPServiceContainer.swift` (or equivalent)

Add new services to the container:

```swift
// New properties
let pqKeyManager: PQKeyManager
let pqAccountDeployer: PQAccountDeployer
var pqBundler: PimlicoBundler?
var pqTransactionSigner: PQTransactionSigner?

// Initialize in init or lazy
func setupPQServices(apiKey: String) {
    self.pqBundler = PimlicoBundler(apiKey: apiKey, chainId: 11155111)
    if let address = pqKeyManager.getAccountAddress() {
        self.pqTransactionSigner = PQTransactionSigner(
            wallet: wallet,
            pqKeyManager: pqKeyManager,
            bundler: pqBundler!,
            accountAddress: address
        )
    }
}
```

---

## File Summary

### New Files (9)

| File | Purpose | Est. Lines |
|------|---------|------------|
| `bitchat/Services/PQKeyManager.swift` | ML-DSA-44 key lifecycle | ~200 |
| `bitchat/Services/MLDSAKeyExpander.swift` | Public key expansion (SHAKE-128, polynomial ops) | ~350 |
| `bitchat/Utils/ABIEncoder.swift` | Minimal Solidity ABI encoding | ~250 |
| `bitchat/Services/UserOperationBuilder.swift` | ERC-4337 UserOp construction + hash | ~200 |
| `bitchat/Services/PimlicoBundler.swift` | Pimlico JSON-RPC client | ~150 |
| `bitchat/Services/PQAccountDeployer.swift` | Factory interaction + deployment | ~200 |
| `bitchat/Services/PQTransactionSigner.swift` | Hybrid signing + submission orchestrator | ~150 |
| `bitchat/ViewModels/PQAccountViewModel.swift` | ObservableObject bridging PQ services to UI | ~200 |
| `bitchatTests/PQAccountTests.swift` | Unit tests for key expansion, ABI encoding, signing | ~300 |

### Modified Files (4)

| File | Changes |
|------|---------|
| `Package.swift` | Add SwiftDilithium dependency |
| `bitchat/Views/WalletSettingsView.swift` | Add "Post-Quantum Security" section |
| `bitchat/Views/WalletView.swift` | Add EOA/PQ segmented picker, conditional PQ display |
| `bitchat/Services/XMTPServiceContainer.swift` | Wire PQ services into container |

---

## Implementation Order

### Sprint 1: Foundation (Days 1-3)
1. Add SwiftDilithium to `Package.swift`, verify it builds
2. Implement `PQKeyManager` — keygen, Keychain storage, signing
3. Write unit tests for ML-DSA-44 keygen + sign + verify round-trip

### Sprint 2: Key Expansion (Days 4-7)
4. Implement `MLDSAKeyExpander` — port `utils_mldsa.ts` functions
5. Implement SHAKE-128 XOF (or find it in Digest dependency)
6. Implement `ABIEncoder` — `encode(types, values)` for dynamic bytes, uint256 arrays
7. **Cross-validate**: Generate a key pair, expand it, and compare output with the JS `to_expanded_encoded_bytes()` output for the same seed

### Sprint 3: ERC-4337 Core (Days 8-11)
8. Implement `UserOperationBuilder` — struct, hash computation
9. Implement `PimlicoBundler` — gas estimation, submission, receipt polling
10. Implement hybrid signing in `PQTransactionSigner`
11. **Cross-validate**: Compute `getUserOpHash` for a test UserOp and compare with JS output

### Sprint 4: Account Deployment (Days 12-14)
12. Implement `PQAccountDeployer` — calldata encoding, gas estimation, EOA tx to factory
13. Deploy a test PQ account on Sepolia from the iOS simulator
14. Verify with Etherscan that the deployed contract matches expected address

### Sprint 5: UI Integration (Days 15-18)
15. Add settings section to `WalletSettingsView`
16. Add account mode toggle to `WalletView`
17. Implement `PQAccountViewModel` connecting UI to services
18. Wire everything through `XMTPServiceContainer`

### Sprint 6: Transaction Sending (Days 19-21)
19. Implement send flow: build UserOp → sign hybrid → estimate gas → re-sign → submit
20. Test sending ETH from PQ account via Pimlico
21. Add transaction history / receipt tracking for UserOperations

### Sprint 7: Polish & Testing (Days 22-25)
22. Error handling: insufficient balance, bundler errors, gas estimation failures
23. Edge cases: wallet recovery, PQ key export/import, re-deployment detection
24. Integration tests with live Sepolia
25. Documentation and code review

---

## Risk Register

| Risk | Impact | Mitigation |
|------|--------|------------|
| SHAKE-128 XOF not available in Swift | High — blocks key expansion | Port from SwiftDilithium internals, or implement Keccak sponge XOF |
| SwiftDilithium ML-DSA-44 output incompatible with kohaku contracts | Critical | Cross-validate signatures against JS reference with identical seeds |
| Gas costs too high on L1 Sepolia (~20KB calldata for PK) | Medium | Recommend Arbitrum Sepolia, show gas estimate before deployment |
| ML-DSA signing performance on iPhone | Low | ML-DSA-44 is fast (~ms), but key expansion is CPU-heavy; do on background thread |
| Pimlico rate limits / API changes | Medium | Implement retry logic, rate limiting, error messages |
| ABI encoding bugs | High | Extensive cross-validation with ethers.js AbiCoder |
| `BigUInt` precision issues | Medium | Existing hand-rolled BigUInt in EthereumBalanceService may need extension for 256-bit ABI values |

---

## Cross-Validation Checkpoints

These are critical correctness gates — the Swift implementation must produce **byte-identical output** to the JS reference for the same inputs:

1. **ML-DSA-44 keygen**: Same seed → same public key bytes
2. **Public key expansion**: Same 1312-byte public key → same ABI-encoded expanded bytes
3. **SHAKE-128 rejection sampling**: Same `rho` → same `Â` matrix
4. **UserOperation hash**: Same UserOp fields → same 32-byte hash
5. **ECDSA signature**: Same private key + hash → same `r, s, v`
6. **ML-DSA signature**: Same secret key + message → same signature (deterministic mode)
7. **Hybrid ABI encoding**: Same two signatures → same encoded bytes

> **Recommendation**: Create a test fixture file with known inputs/outputs from the JS reference implementation and validate each step independently.

---

## Open Questions

1. **Factory address**: Need to pull the exact `mldsa_k1` factory address from `deployments.json` — the file wasn't accessible via GitHub raw URL. May need to clone the kohaku repo or check Etherscan directly.

2. **MLDSA vs MLDSAETH**: The kohaku contracts support both "MLDSA" (pure NIST FIPS 204) and "MLDSAETH" (an Ethereum-optimized variant). The example app uses `mldsa_k1` (NIST mode). Confirm which mode to target — NIST is simpler and matches SwiftDilithium's output directly.

3. **Pimlico API key management**: Where to store it? Currently the plan uses `@AppStorage` which is not encrypted. Consider Keychain for the API key.

4. **Key derivation path**: Should the PQ seed be derived from the EOA key (Option A) or independent (Option B)? Option A is simpler for users but couples security domains.

5. **Arbitrum Sepolia support**: Lower gas costs would make the experience much better. Adding a second testnet is a simple extension of the network enum.
