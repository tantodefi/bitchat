# Aave V3 DeFi Integration via PQ ERC-4337 Account

## Overview

Integrate Aave V3 (Sepolia) into bitchat's post-quantum ERC-4337 smart account, enabling users to **supply USDC and earn yield** with quantum-safe keys — directly from their phone.

**Reference demo**: [zknox Aave demo](https://visionary-nougat-217eaa.netlify.app/) — built by the ZKNOX/Kohaku team, same factory contracts we already use.

### What the Demo Does

1. Connect with PQ-enabled signer (ECDSA + ML-DSA)
2. Hybrid signature verification via modular verifier
3. Supply USDC to Aave V3 (Sepolia)
4. Earn yield with quantum-safe keys

### Flow

```
Sign (ECDSA + ML-DSA) → Bundler (UserOp) → Hybrid Verify → Aave supply() → aUSDC (yield)
```

### Stack

- ERC-4337 smart account (same ZKNOX factory as bitchat)
- Modular hybrid verifier
- Pure Solidity PQ verification
- Standard Aave V3 interaction
- No protocol modification needed

---

## Current State (~65-70% Complete)

### ✅ Fully Implemented (matches zknox demo)

| Component | File | Notes |
|-----------|------|-------|
| PQ account creation (ECDSA + ML-DSA hybrid) | `PQAccountDeployer.swift` | Same ZKNOX `mldsa_k1` factory |
| Send ETH via UserOperation | `PQTransactionSigner.swift` | Pimlico bundler integration |
| Hybrid signing (secp256k1 + ML-DSA-44) | `PQKeyManager.swift` | FIPS 204 compliant |
| ERC-4337 v0.7 packed UserOps + hash | `UserOperationBuilder.swift` | Generic — works for any calldata |
| Pimlico bundler client | `PimlicoBundler.swift` | Submits any UserOp to Sepolia |
| Counterfactual addresses / CREATE2 | `PQAccountDeployer.swift` | Offline prediction supported |
| Wallet UI with EOA ↔ PQ toggle | `WalletView.swift` | Segmented picker + PQ badge |
| ABI encoder (core primitives) | `ABIEncoder.swift` | `encode(types:values:)`, `functionSelector()` |
| Stealth PQ accounts + sweep | `StealthPQAccountManager.swift` | Advanced privacy feature |

### Key Insight

`PQTransactionSigner.executeTransaction(dest:value:data:)` already accepts **arbitrary calldata**. All Aave interactions are just different `data` payloads passed to that same function. The hard part (PQ crypto, 4337 infra, hybrid signing) is done.

---

## ❌ What's Missing (Application Layer Only)

### 1. ABI Encoding for DeFi Functions (~50 lines)

**File**: `bitchat/Utils/ABIEncoder.swift` (extend existing)

Add convenience encoders following existing `encodeExecute` / `encodeCreateAccount` patterns:

```swift
// ERC-20
static func encodeApprove(spender: String, amount: Data) -> Data
static func encodeTransfer(to: String, amount: Data) -> Data
static func encodeBalanceOf(account: String) -> Data

// Aave V3 Pool
static func encodeAaveSupply(asset: String, amount: Data, onBehalfOf: String, referralCode: UInt16) -> Data
static func encodeAaveWithdraw(asset: String, amount: Data, to: String) -> Data
static func encodeGetUserAccountData(user: String) -> Data
```

**Solidity signatures**:
- `approve(address,uint256)` → selector `0x095ea7b3`
- `balanceOf(address)` → selector `0x70a08231`
- `supply(address,uint256,address,uint16)` → selector `0x617ba037`
- `withdraw(address,uint256,address)` → selector `0x69328dec`
- `getUserAccountData(address)` → selector `0xbf92857c`

### 2. Aave V3 Contract Addresses (Sepolia)

```swift
enum AaveV3Sepolia {
    static let pool        = "0x6Ae43d3271ff6888e7Fc43Fd7321a503ff738951"
    static let usdc        = "0x94a9D9AC8a22534E3FaCa9F4e7F2E2cf85d5E4C8"  // Aave faucet USDC
    static let aUsdc       = "0x..."  // from getReserveData()
    static let poolDataProvider = "0x..."
}
```

> **Note**: Verify these addresses against https://docs.aave.com/developers/deployed-contracts/v3-testnet-addresses

### 3. ERC-20 Token Balance Service (~150 lines)

**New file**: `bitchat/Services/ERC20BalanceService.swift`

- `balanceOf(token:account:)` → `eth_call` to token contract
- `allowance(token:owner:spender:)` → check existing approvals
- Decimal formatting (USDC = 6 decimals, ETH = 18)
- Caching with TTL

### 4. Aave V3 Service (~300 lines)

**New file**: `bitchat/Services/AaveV3Service.swift`

```swift
actor AaveV3Service {
    // Read operations (eth_call)
    func getUserAccountData(user: String) async throws -> AavePosition
    func getReserveData(asset: String) async throws -> ReserveData

    // Write operations (returns calldata for UserOp)
    func buildSupplyCalldata(asset: String, amount: BigUInt, onBehalfOf: String) -> Data
    func buildWithdrawCalldata(asset: String, amount: BigUInt, to: String) -> Data
    func buildApproveCalldata(asset: String, spender: String, amount: BigUInt) -> Data
}

struct AavePosition {
    let totalCollateralBase: BigUInt    // USD value, 8 decimals
    let totalDebtBase: BigUInt
    let availableBorrowsBase: BigUInt
    let currentLiquidationThreshold: BigUInt
    let ltv: BigUInt
    let healthFactor: BigUInt           // 1e18 = 1.0
}
```

### 5. Multi-Step Transaction Orchestration (~100 lines)

Supplying USDC to Aave requires **two sequential UserOperations**:

1. **Approve**: `USDC.approve(aavePool, amount)` → wait for receipt
2. **Supply**: `AavePool.supply(usdc, amount, pqAccount, 0)` → wait for receipt

**Add to**: `bitchat/ViewModels/PQAccountViewModel.swift`

```swift
func supplyToAave(asset: String, amount: BigUInt) async throws {
    // Step 1: Approve
    let approveData = aaveService.buildApproveCalldata(...)
    let approveTxHash = try await txSigner.executeTransaction(dest: asset, data: approveData)
    try await waitForReceipt(approveTxHash)

    // Step 2: Supply
    let supplyData = aaveService.buildSupplyCalldata(...)
    let supplyTxHash = try await txSigner.executeTransaction(dest: aavePool, data: supplyData)
    try await waitForReceipt(supplyTxHash)
}
```

### 6. DeFi UI (~400 lines)

**New file**: `bitchat/Views/DeFiView.swift`

- Token balance list (USDC, aUSDC, ETH)
- "Supply to Aave" button with amount input
- "Withdraw from Aave" button
- Aave position card (total supplied, total borrowed, health factor)
- Progress indicator for multi-step flows (Approving… → Supplying…)

**New file**: `bitchat/Views/TokenBalanceView.swift`

- Reusable token balance row (icon, symbol, balance, USD value)

### 7. Wallet View Updates (~50 lines)

**Modify**: `bitchat/Views/WalletView.swift`

- Add "DeFi" section/button when in PQ account mode
- Show token balances alongside ETH balance
- Navigation to DeFi view

---

## File Summary

| File | Action | Est. Lines |
|------|--------|------------|
| `bitchat/Utils/ABIEncoder.swift` | Extend | +50 |
| `bitchat/Services/ERC20BalanceService.swift` | New | ~150 |
| `bitchat/Services/AaveV3Service.swift` | New | ~300 |
| `bitchat/Views/DeFiView.swift` | New | ~400 |
| `bitchat/Views/TokenBalanceView.swift` | New | ~150 |
| `bitchat/ViewModels/DeFiViewModel.swift` | New | ~250 |
| `bitchat/ViewModels/PQAccountViewModel.swift` | Extend | +100 |
| `bitchat/Views/WalletView.swift` | Extend | +50 |
| `bitchat/Services/EthereumBalanceService.swift` | Extend | +30 |
| **Total** | | **~1,480** |

---

## Implementation Order

1. **ABIEncoder extensions** — add `encodeApprove`, `encodeSupply`, `encodeBalanceOf`, etc.
2. **ERC20BalanceService** — read token balances via `eth_call`
3. **AaveV3Service** — build Aave calldata + read positions
4. **DeFiViewModel** — orchestrate approve → supply flow
5. **DeFiView + TokenBalanceView** — UI for supply/withdraw
6. **WalletView updates** — integrate DeFi entry point
7. **End-to-end test** — supply testnet USDC on Sepolia, verify aUSDC received

## Testing Strategy

1. **Unit tests**: ABI encoding for each DeFi function selector + params
2. **Integration test**: Supply 1 USDC on Sepolia via PQ account, verify aUSDC balance increases
3. **UI test**: Full supply flow with progress states

## Risk Register

| Risk | Mitigation |
|------|------------|
| Aave Sepolia USDC faucet may be rate-limited | Use Aave faucet UI or mint via contract |
| Gas estimation for approve+supply may be high | Show gas estimate before confirming |
| UserOp may fail between approve and supply | Retry logic; approve is idempotent |
| Aave contract addresses may change on Sepolia | Pin addresses in config; add fallback lookup |

---

## Estimated Effort

**3-5 days** for full feature parity with the zknox Aave demo tab.

The quantum-resistant cryptography, ERC-4337 infrastructure, bundler integration, and hybrid signing are all complete. This is purely application-layer DeFi integration work.
