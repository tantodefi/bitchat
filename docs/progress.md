bitchat fork — Progress Summary

Fork: permissionlesstech/bitchat from 21-DOT-DEV/bitchat
Period: January – February 2026
Commits since fork: 41
Lines added: ~20,400 across 55 Swift files, plus docs, configs, and tests


1. MESH TRANSACTION RELAY (OFFLINE BLE TRANSACTIONS)

Sign Ethereum transactions offline and broadcast them through the BLE mesh — nearby online peers relay to the network.

What was built:

MeshTransactionRelay.swift — full BLE relay engine (~768 lines added) with packet types 0x50 (TX_REQUEST), 0x51 (TX_SIGNED), 0x52 (TX_BROADCAST), 0x53 (TX_RECEIPT). MeshTransactionTypes.swift — CBOR-encoded payload structs for mesh relay. Offline signing flows into BLE relay which forwards to Flashbots eth_sendRawTransaction. Noise-encrypted relay between mesh peers — transactions are opaque to relay nodes. Integration in BLEService.swift for mesh tx packet handling. The online path uses XMTP WalletSendCalls codec (XIP-59) for in-conversation transaction requests.


2. POST-QUANTUM ERC-4337 SMART ACCOUNT

Hybrid ECDSA secp256k1 + ML-DSA-44 (FIPS 204) smart account via the ZKNOX factory — quantum-resistant on-chain wallet deployed on Arbitrum Sepolia.

What was built:

PQKeyManager.swift (191 lines) — ML-DSA-44 keypair generation and Keychain storage. MLDSAKeyExpander.swift (379 lines) — NIST FIPS 204 key expansion from seed to full signing key. PQAccountDeployer.swift (530 lines) — CREATE2 counterfactual address prediction and ZKNOX factory deployment. PQTransactionSigner.swift (965 lines) — hybrid dual-signature UserOp construction (ECDSA 65 bytes + ML-DSA 2420 bytes). PQAccountSigner.swift (108 lines) — UserOp hash computation per ERC-4337 v0.7 spec. UserOperationBuilder.swift (332 lines) — UserOp field packing, gas estimation, nonce management. PimlicoBundler.swift (309 lines) — Pimlico bundler integration for sponsoring and sending UserOperations. ABIEncoder.swift (332 lines) — ABI encoding for execute() and executeBatch() calls. PQAccountViewModel.swift (858 lines) — deploy, send, balance, and tx history UI state. PQAccountTests.swift (776 lines) — 21 unit tests covering key gen, signing, ABI encoding, UserOp construction.


3. STEALTH PQ ACCOUNTS (FLUIDKEY-STYLE PRIVACY)

Fluidkey-inspired stealth address system — but swapping the Safe 1/1 for a ZKNOX PQ Account. Rotate a fresh counterfactual address for every payment; deploy the smart account only when sweeping funds.

What was built:

StealthPQAccountManager.swift (595 lines) — HMAC-based stealth key derivation, offline CREATE2 address prediction, deploy-on-sweep via hybrid ERC-4337 UserOp. StealthAddressStore.swift (72 lines) — JSON persistence to App Group container. StealthPQAccountListView.swift (822 lines) — generate stealth address, scan balances, sweep UI. StealthAddressDetailView.swift — per-address detail view. ENS rotation: after sweep, NamestoneService auto-registers the next stealth address under *.pq.dstealth.eth. 3-tier balance verification for stealth addresses (Helios, then Merkle proof, then RPC). StealthPQAccountTests.swift (435 lines) — 21 tests across 6 suites.

Status: Fully implemented on Arbitrum Sepolia. All phases complete.


4. XMTP TRANSPORT LAYER

Added XMTP as a third transport alongside BLE mesh and Nostr — enabling MLS-encrypted group messaging, wallet-native identity, and an in-app CLI.

What was built:

XMTPClientService.swift (+482 lines) — XMTP v3 client initialization, conversation management, group creation. XMTPCLIEngine.swift (1,599 lines) — full CLI engine with /dm, /group-create, /group-invite, /group-message, /peer-info, /wallet-send, /balance, /ens-lookup, and more. XMTPJSBridge.swift (452 lines) — JavaScript bridge for XMTP frame-based commands. XMTPServiceContainer.swift (63 lines) — dependency injection container. XMTPPeerInfoSheet.swift (+1,196 lines) — peer info UI with ENS resolution, XMTP inbox ID, wallet address, send-tx shortcut. XMTPSettingsView.swift (33 lines) — settings panel for XMTP configuration. Disappearing messages support. Remote attachment handling for images and voice notes.


5. NAMESTONE ENS INTEGRATION

Gasless ENS subdomains for every bitchat user via Namestone's offchain resolver on dstealth.eth.

What was built:

NamestoneService.swift (+178 lines) — full CRUD: set-name, get-names-for-address, get-name, delete-name. Auto-registration on first launch: anon<N>.dstealth.eth pointing to wallet address plus com.xmtp.inbox text record. Custom name support — users can change their subdomain at any time. ENSResolver.swift (362 lines refactored) — app-wide ENS resolution updated to support both mainnet and offchain names. Storage migration from flat UserDefaults to App Group-scoped UserDefaults.


6. pq.dstealth.eth ENS NAMESPACE

Dedicated subdomain namespace for stealth PQ account addresses — the receiving counterpart to dstealth.eth identity names.

What was built:

PQENSSettingsView.swift (351 lines) — editor for the label left of .pq.dstealth.eth. NamestoneService extended with PQ-specific CRUD: register, update, and delete on the pq.dstealth.eth domain. Auto-rotation after sweep: once a stealth address is swept, the next fresh counterfactual address is registered under the same name. WalletSettingsView.swift (+560 lines) — separate rows for EOA ENS (alice.dstealth.eth) and PQ ENS (alice.pq.dstealth.eth). WalletView.swift (+652 lines) — PQ stealth section, balance display, settings entry points.


7. HELIOS LIGHT CLIENT (TRUSTLESS VERIFICATION)

a16z's Rust Ethereum light client compiled to an iOS xcframework — turns untrusted Tor-routed RPC into consensus-verified responses.

What was built:

HeliosManager.swift (1,036 lines) — Rust FFI bridge, lifecycle management (start/stop/restart), consensus sync monitoring. localPackages/HeliosBridge/ — standalone Swift Package wrapping the Rust xcframework (472 lines plus Package.swift). ProofVerifier.swift (708 lines) — eth_getProof Merkle-Patricia trie verification as Phase 1 fallback. EthereumBalanceService.swift (+547 lines) — 3-tier verification: Helios (consensus-verified), then Merkle proof (proof-consistent), then raw RPC (unverified). TransactionHistoryService.swift (1,213 lines) — tx history fetched and verified through Helios. TransactionHistoryView.swift (+830 lines) — verified tx history UI with shield indicators. ProofVerifierTests.swift (445 lines) — comprehensive test suite for Merkle proof verification. All Helios upstream traffic (execution and consensus RPC) Tor-routed via Arti SOCKS5.

Status: Complete — Phase 1 through 5 all verified on-device.


8. ADDITIONAL CHANGES

Tor (Arti SOCKS5 — Fail-Closed): All internet traffic Tor-routed by default. Replaced legacy C Tor with Rust Arti (smaller binary, better iOS lifecycle). Fail-closed: if Tor is down, network requests block rather than leak clearnet. The Tor replacement landed before the fork in PRs #957–#958, but XMTP and Helios traffic routing is new work.

XMTP CLI Command Engine: CommandProcessor.swift expanded by +1,202 lines — unified slash-command engine supporting both Nostr and XMTP contexts. Commands include /dm, /group, /wallet-send, /balance, /ens, /peer-info, and more.

Send Transaction View: SendTransactionView.swift (+406 lines) — supports sending from both EOA wallet and PQ smart account, gas estimation, Tor-routed broadcast, and offline mesh relay fallback.

Transaction Store: TransactionStore.swift (179 lines) — local persistence for pending, relayed, and confirmed transactions.

Secure Config: SecureConfig.swift (39 lines) — centralized secure configuration for API keys and RPC endpoints, loaded from Keychain.

App Info and UI: AppInfoView.swift displays Helios status, PQ account status, and Tor circuit info. ContentView.swift integrates PQ wallet and Helios into the main navigation. LocationChannelsSheet.swift adds geohash channel UI improvements. MeshPeerList.swift shows mesh peer display with relay capability indicators. CommandSuggestionsView.swift updated for the expanded command set.


SUMMARY

Mesh Tx Relay — 3 files, ~870 lines added
PQ Smart Account — 10 files, ~4,900 lines added, 21 tests
Stealth PQ Accounts — 3 files, ~1,490 lines added, 21 tests
XMTP Transport — 6 files, ~3,830 lines added
Namestone ENS — 2 files, ~540 lines added
pq.dstealth.eth — 3 files, ~1,560 lines added
Helios Light Client — 6 files, ~4,030 lines added, 445 lines of tests
Other (CLI, Views, etc.) — 12+ files, ~3,500 lines added

Total: 55 files changed, ~20,400 lines added, 42+ tests

All Ethereum operations are Tor-routed and (where Helios is running) consensus-verified. All PQ signatures use the hybrid ECDSA + ML-DSA-44 scheme — quantum-resistant today, classical-secure as fallback.
