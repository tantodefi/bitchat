//! helios-ios: FFI wrapper for the Helios Ethereum light client on iOS/macOS
//!
//! Provides a C-compatible interface for embedding Helios in iOS/macOS apps.
//! All upstream RPC requests are routed through a SOCKS5 proxy (Tor) for IP
//! privacy, while Helios provides cryptographic data integrity via consensus-
//! attested state roots (sync committee BLS signatures).
//!
//! Architecture follows the proven arti-bitchat pattern:
//!   Rust static library → xcframework → Swift @_silgen_name FFI bindings
//!
//! # Tor Integration
//!
//! When `socks_proxy_port > 0`, we set the `ALL_PROXY` and `HTTPS_PROXY`
//! environment variables before creating the Helios client. Reqwest (used
//! internally by Helios for both consensus and execution RPC) respects these
//! env vars when the `socks` feature is enabled. This routes ALL upstream
//! network requests through the Arti Tor SOCKS5 proxy on localhost.

use std::ffi::{c_char, c_int, CStr, CString};
use std::path::PathBuf;
use std::str::FromStr;
use std::sync::atomic::{AtomicBool, AtomicI32, Ordering};
use std::sync::Mutex;

use alloy::eips::BlockNumberOrTag;
use alloy::primitives::{Address, B256};
use alloy::rpc::types::{Filter, TransactionRequest};
use once_cell::sync::Lazy;
use tokio::runtime::Runtime;

use helios_ethereum::config::networks::Network;
use helios_ethereum::{EthereumClient, EthereumClientBuilder};

// ---------------------------------------------------------------------------
// Global State
// ---------------------------------------------------------------------------

/// Holds the tokio runtime and the Helios EthereumClient.
///
/// The client is built via `EthereumClientBuilder` and starts its consensus
/// sync loop immediately on `build()`. The `wait_synced()` method blocks
/// until the first sync committee update is verified.
struct HeliosState {
    /// Tokio runtime (owned, single instance)
    runtime: Runtime,
    /// The Helios Ethereum light client
    client: EthereumClient,
}

/// Resettable global state. Using `Mutex<Option<...>>` instead of `OnceCell`
/// so that `helios_shutdown()` can fully clear the state, allowing
/// `helios_init()` to be called again (e.g., after a sync failure or
/// network change) without requiring an app restart.
static HELIOS_STATE: Lazy<Mutex<Option<HeliosState>>> = Lazy::new(|| Mutex::new(None));
static IS_RUNNING: AtomicBool = AtomicBool::new(false);
static IS_SYNCED: AtomicBool = AtomicBool::new(false);
/// Sync progress: 0 = not started, 1-99 = syncing, 100 = synced, -1 = error
static SYNC_PROGRESS: AtomicI32 = AtomicI32::new(0);

// ---------------------------------------------------------------------------
// FFI: Initialization
// ---------------------------------------------------------------------------

/// Initialize the Helios light client.
///
/// Builds an `EthereumClient` configured for mainnet with the given RPC
/// endpoints. If `socks_proxy_port > 0`, all upstream HTTP requests are
/// routed through the Tor SOCKS5 proxy at `127.0.0.1:<port>`.
///
/// The client begins its consensus sync loop immediately. Call
/// `helios_wait_synced()` to block until the first sync completes, or
/// poll with `helios_is_synced()` / `helios_sync_progress()`.
///
/// # Arguments
/// * `rpc_url` – Upstream execution-layer RPC (e.g. "https://rpc.flashbots.net")
/// * `consensus_rpc` – Beacon API endpoint (e.g. "https://www.lightclientdata.org")
/// * `checkpoint` – Weak subjectivity checkpoint (hex, 0x-prefixed, or empty for external fallback)
/// * `network` – Network name: "mainnet" or "sepolia" (defaults to mainnet if unrecognised)
/// * `socks_proxy_port` – Tor SOCKS5 port (0 to disable proxy)
///
/// # Returns
/// * 0 on success
/// * -1 if already running
/// * -2 if parameter parsing failed
/// * -3 if runtime initialization failed
/// * -4 if client build failed
#[no_mangle]
pub extern "C" fn helios_init(
    rpc_url: *const c_char,
    consensus_rpc: *const c_char,
    checkpoint: *const c_char,
    network: *const c_char,
    socks_proxy_port: u16,
) -> c_int {
    if IS_RUNNING.load(Ordering::SeqCst) {
        return -1;
    }

    // Parse C strings
    let execution_rpc = match parse_cstr(rpc_url) {
        Some(s) => s,
        None => return -2,
    };
    let consensus = match parse_cstr(consensus_rpc) {
        Some(s) => s,
        None => return -2,
    };
    let checkpoint_str = match parse_cstr(checkpoint) {
        Some(s) => s,
        None => return -2,
    };
    let network_str = parse_cstr(network).unwrap_or_else(|| "mainnet".to_string());
    let net = match network_str.to_lowercase().as_str() {
        "sepolia" => Network::Sepolia,
        _ => Network::Mainnet,
    };
    tracing::info!("Helios network: {:?}", net);

    // Route all HTTP traffic through Tor SOCKS5 proxy.
    // Reqwest respects ALL_PROXY/HTTPS_PROXY when the "socks" feature is enabled.
    // Using socks5h:// to let the proxy handle DNS resolution (prevents DNS leaks).
    if socks_proxy_port > 0 {
        let proxy_url = format!("socks5h://127.0.0.1:{}", socks_proxy_port);
        // SAFETY: We are single-threaded at this point (called before client starts).
        // The env vars are read by reqwest when it creates new HTTP clients.
        unsafe {
            std::env::set_var("ALL_PROXY", &proxy_url);
            std::env::set_var("HTTPS_PROXY", &proxy_url);
        }
    }

    // Create tokio runtime
    let runtime = match Runtime::new() {
        Ok(rt) => rt,
        Err(e) => {
            tracing::error!("Failed to create tokio runtime: {}", e);
            return -3;
        }
    };

    // Enter the runtime context so that tokio::spawn (used inside
    // HeliosClient::new / Node::new) can find the current runtime handle.
    let _guard = runtime.enter();

    // Build the Helios Ethereum light client
    let client = match build_client(&execution_rpc, &consensus, &checkpoint_str, net) {
        Ok(c) => c,
        Err(e) => {
            tracing::error!("Failed to build Helios client: {}", e);
            return -4;
        }
    };

    // Store global state (replaces any previous state)
    let state = HeliosState { runtime, client };
    match HELIOS_STATE.lock() {
        Ok(mut guard) => {
            *guard = Some(state);
        }
        Err(_) => return -3,
    }

    IS_RUNNING.store(true, Ordering::SeqCst);
    SYNC_PROGRESS.store(10, Ordering::SeqCst);

    tracing::info!("Helios client initialized, consensus sync starting");
    0
}

/// Block until the Helios client has completed its first sync.
///
/// This blocks the calling thread. Call from a background queue/thread.
/// After this returns 0, `helios_get_balance` etc. will return verified data.
///
/// # Returns
/// * 0 on success (synced)
/// * -1 if not initialized
/// * -2 if sync failed
#[no_mangle]
pub extern "C" fn helios_wait_synced() -> c_int {
    if !IS_RUNNING.load(Ordering::SeqCst) {
        return -1;
    }

    let guard = match HELIOS_STATE.lock() {
        Ok(g) => g,
        Err(_) => return -1,
    };
    let state = match guard.as_ref() {
        Some(s) => s,
        None => return -1,
    };

    SYNC_PROGRESS.store(50, Ordering::SeqCst);

    match state.runtime.block_on(state.client.wait_synced()) {
        Ok(()) => {
            IS_SYNCED.store(true, Ordering::SeqCst);
            SYNC_PROGRESS.store(100, Ordering::SeqCst);
            tracing::info!("Helios synced successfully");
            0
        }
        Err(e) => {
            tracing::error!("Helios sync failed: {}", e);
            SYNC_PROGRESS.store(-1, Ordering::SeqCst);
            -2
        }
    }
}

/// Check if Helios has completed its initial sync.
///
/// # Returns
/// * 1 if synced
/// * 0 if not synced
#[no_mangle]
pub extern "C" fn helios_is_synced() -> c_int {
    if IS_SYNCED.load(Ordering::SeqCst) {
        1
    } else {
        0
    }
}

/// Get the sync progress.
///
/// # Returns
/// * 0: not started
/// * 1-99: syncing
/// * 100: synced
/// * -1: error
#[no_mangle]
pub extern "C" fn helios_sync_progress() -> c_int {
    SYNC_PROGRESS.load(Ordering::SeqCst)
}

// ---------------------------------------------------------------------------
// FFI: Verified Balance Query
// ---------------------------------------------------------------------------

/// Get the verified balance for an address on the execution layer.
///
/// The balance is verified against the consensus-attested state root
/// (sync committee BLS signatures). This is trustless verification —
/// the untrusted execution RPC cannot lie about the balance.
///
/// # Arguments
/// * `address` – Hex Ethereum address (0x-prefixed)
/// * `result` – Out pointer: caller must free with `helios_free_string`
///
/// # Returns
/// * 0 on success (balance hex string written to *result)
/// * -1 if not initialized
/// * -2 if address is invalid
/// * -3 if verification/query failed
#[no_mangle]
pub extern "C" fn helios_get_balance(
    address: *const c_char,
    result: *mut *mut c_char,
) -> c_int {
    if !IS_RUNNING.load(Ordering::SeqCst) {
        return -1;
    }

    let addr_str = match parse_cstr(address) {
        Some(s) => s,
        None => return -2,
    };

    let addr = match Address::from_str(&addr_str) {
        Ok(a) => a,
        Err(_) => return -2,
    };

    let guard = match HELIOS_STATE.lock() {
        Ok(g) => g,
        Err(_) => return -1,
    };
    let state = match guard.as_ref() {
        Some(s) => s,
        None => return -1,
    };

    let balance_result = state.runtime.block_on(async {
        state
            .client
            .get_balance(addr, BlockNumberOrTag::Latest.into())
            .await
    });

    match balance_result {
        Ok(balance) => {
            let hex = format!("0x{:x}", balance);
            write_result_string(hex, result)
        }
        Err(e) => {
            tracing::error!("helios_get_balance failed: {}", e);
            -3
        }
    }
}

// ---------------------------------------------------------------------------
// FFI: Verified Log Query
// ---------------------------------------------------------------------------

/// Get verified event logs matching a JSON filter.
///
/// Used for stealth address scanning (EIP-5564 announcements).
/// Logs are verified against consensus-attested block roots, ensuring
/// a malicious RPC cannot omit or fabricate announcements.
///
/// # Arguments
/// * `filter_json` – JSON-encoded log filter (address, topics, fromBlock, toBlock)
/// * `result` – Out pointer: JSON array of logs. Caller must free with `helios_free_string`
///
/// # Returns
/// * 0 on success
/// * -1 if not initialized
/// * -2 if filter is invalid
/// * -3 if query/verification failed
#[no_mangle]
pub extern "C" fn helios_get_logs(
    filter_json: *const c_char,
    result: *mut *mut c_char,
) -> c_int {
    if !IS_RUNNING.load(Ordering::SeqCst) {
        return -1;
    }

    let filter_str = match parse_cstr(filter_json) {
        Some(s) => s,
        None => return -2,
    };

    let filter: Filter = match serde_json::from_str(&filter_str) {
        Ok(f) => f,
        Err(e) => {
            tracing::error!("Invalid log filter JSON: {}", e);
            return -2;
        }
    };

    let guard = match HELIOS_STATE.lock() {
        Ok(g) => g,
        Err(_) => return -1,
    };
    let state = match guard.as_ref() {
        Some(s) => s,
        None => return -1,
    };

    let logs_result = state
        .runtime
        .block_on(async { state.client.get_logs(&filter).await });

    match logs_result {
        Ok(logs) => {
            let json = match serde_json::to_string(&logs) {
                Ok(j) => j,
                Err(e) => {
                    tracing::error!("Failed to serialize logs: {}", e);
                    return -3;
                }
            };
            write_result_string(json, result)
        }
        Err(e) => {
            tracing::error!("helios_get_logs failed: {}", e);
            -3
        }
    }
}

// ---------------------------------------------------------------------------
// FFI: Verified eth_call
// ---------------------------------------------------------------------------

/// Execute a verified eth_call.
///
/// The call result is verified against the consensus-attested state root.
/// Used for ENS resolution, ERC-20 balanceOf, contract reads, etc.
///
/// # Arguments
/// * `call_json` – JSON-encoded TransactionRequest (to, data, value, etc.)
/// * `result` – Out pointer: hex result data. Caller must free with `helios_free_string`
///
/// # Returns
/// * 0 on success
/// * -1 if not initialized
/// * -2 if call params invalid
/// * -3 if execution/verification failed
#[no_mangle]
pub extern "C" fn helios_eth_call(
    call_json: *const c_char,
    result: *mut *mut c_char,
) -> c_int {
    if !IS_RUNNING.load(Ordering::SeqCst) {
        return -1;
    }

    let call_str = match parse_cstr(call_json) {
        Some(s) => s,
        None => return -2,
    };

    let tx: TransactionRequest = match serde_json::from_str(&call_str) {
        Ok(t) => t,
        Err(e) => {
            tracing::error!("Invalid eth_call JSON: {}", e);
            return -2;
        }
    };

    let guard = match HELIOS_STATE.lock() {
        Ok(g) => g,
        Err(_) => return -1,
    };
    let state = match guard.as_ref() {
        Some(s) => s,
        None => return -1,
    };

    let call_result = state.runtime.block_on(async {
        state
            .client
            .call(&tx, BlockNumberOrTag::Latest.into(), None)
            .await
    });

    match call_result {
        Ok(bytes) => {
            let hex = format!("0x{}", hex::encode(bytes.as_ref()));
            write_result_string(hex, result)
        }
        Err(e) => {
            tracing::error!("helios_eth_call failed: {}", e);
            -3
        }
    }
}

// ---------------------------------------------------------------------------
// FFI: Transaction Queries
// ---------------------------------------------------------------------------

/// Get the transaction count (nonce) for an address.
///
/// Verified against the consensus-attested state root, so no RPC can
/// lie about the nonce value.
///
/// # Arguments
/// * `address` – Hex Ethereum address (0x-prefixed)
/// * `result` – Out pointer: hex nonce. Caller must free with `helios_free_string`
///
/// # Returns
/// * 0 on success
/// * -1 if not initialized
/// * -2 if address is invalid
/// * -3 if query failed
#[no_mangle]
pub extern "C" fn helios_get_nonce(
    address: *const c_char,
    result: *mut *mut c_char,
) -> c_int {
    if !IS_RUNNING.load(Ordering::SeqCst) {
        return -1;
    }

    let addr_str = match parse_cstr(address) {
        Some(s) => s,
        None => return -2,
    };

    let addr = match Address::from_str(&addr_str) {
        Ok(a) => a,
        Err(_) => return -2,
    };

    let guard = match HELIOS_STATE.lock() {
        Ok(g) => g,
        Err(_) => return -1,
    };
    let state = match guard.as_ref() {
        Some(s) => s,
        None => return -1,
    };

    let nonce_result = state.runtime.block_on(async {
        state
            .client
            .get_nonce(addr, BlockNumberOrTag::Latest.into())
            .await
    });

    match nonce_result {
        Ok(nonce) => {
            let hex = format!("0x{:x}", nonce);
            write_result_string(hex, result)
        }
        Err(e) => {
            tracing::error!("helios_get_nonce failed: {}", e);
            -3
        }
    }
}

/// Get the transaction receipt by hash, verified against consensus.
///
/// Returns a JSON-encoded receipt including status, gasUsed, blockNumber,
/// logs, etc. Used for tx history and confirmation tracking.
///
/// # Arguments
/// * `tx_hash` – Transaction hash (0x-prefixed, 66 chars)
/// * `result` – Out pointer: JSON receipt. Caller must free with `helios_free_string`
///
/// # Returns
/// * 0 on success (receipt found)
/// * -1 if not initialized
/// * -2 if hash is invalid
/// * -3 if query failed or receipt not found
#[no_mangle]
pub extern "C" fn helios_get_transaction_receipt(
    tx_hash: *const c_char,
    result: *mut *mut c_char,
) -> c_int {
    if !IS_RUNNING.load(Ordering::SeqCst) {
        return -1;
    }

    let hash_str = match parse_cstr(tx_hash) {
        Some(s) => s,
        None => return -2,
    };

    let hash = match B256::from_str(&hash_str) {
        Ok(h) => h,
        Err(_) => return -2,
    };

    let guard = match HELIOS_STATE.lock() {
        Ok(g) => g,
        Err(_) => return -1,
    };
    let state = match guard.as_ref() {
        Some(s) => s,
        None => return -1,
    };

    let receipt_result = state
        .runtime
        .block_on(async { state.client.get_transaction_receipt(hash).await });

    match receipt_result {
        Ok(Some(receipt)) => {
            let json = match serde_json::to_string(&receipt) {
                Ok(j) => j,
                Err(e) => {
                    tracing::error!("Failed to serialize receipt: {}", e);
                    return -3;
                }
            };
            write_result_string(json, result)
        }
        Ok(None) => -3, // Receipt not found (tx pending or non-existent)
        Err(e) => {
            tracing::error!("helios_get_transaction_receipt failed: {}", e);
            -3
        }
    }
}

/// Get a block by number, verified against consensus.
///
/// Returns JSON-encoded block data including transactions list.
/// When `full_txs` is true, returns full transaction objects;
/// when false, returns only transaction hashes.
///
/// # Arguments
/// * `block_tag` – Block number as hex (0x-prefixed) or "latest"/"finalized"
/// * `full_txs` – 1 for full transaction objects, 0 for hashes only
/// * `result` – Out pointer: JSON block. Caller must free with `helios_free_string`
///
/// # Returns
/// * 0 on success
/// * -1 if not initialized
/// * -2 if block_tag is invalid
/// * -3 if query failed
#[no_mangle]
pub extern "C" fn helios_get_block_by_number(
    block_tag: *const c_char,
    full_txs: c_int,
    result: *mut *mut c_char,
) -> c_int {
    if !IS_RUNNING.load(Ordering::SeqCst) {
        return -1;
    }

    let tag_str = match parse_cstr(block_tag) {
        Some(s) => s,
        None => return -2,
    };

    let block_id: BlockNumberOrTag = match tag_str.as_str() {
        "latest" => BlockNumberOrTag::Latest,
        "finalized" => BlockNumberOrTag::Finalized,
        "pending" => BlockNumberOrTag::Pending,
        "earliest" => BlockNumberOrTag::Earliest,
        s => {
            // Parse hex block number
            let stripped = s.strip_prefix("0x").unwrap_or(s);
            match u64::from_str_radix(stripped, 16) {
                Ok(n) => BlockNumberOrTag::Number(n),
                Err(_) => return -2,
            }
        }
    };

    let guard = match HELIOS_STATE.lock() {
        Ok(g) => g,
        Err(_) => return -1,
    };
    let state = match guard.as_ref() {
        Some(s) => s,
        None => return -1,
    };

    let include_txs = full_txs != 0;

    let block_result = state.runtime.block_on(async {
        state
            .client
            .get_block(block_id.into(), include_txs)
            .await
    });

    match block_result {
        Ok(Some(block)) => {
            let json = match serde_json::to_string(&block) {
                Ok(j) => j,
                Err(e) => {
                    tracing::error!("Failed to serialize block: {}", e);
                    return -3;
                }
            };
            write_result_string(json, result)
        }
        Ok(None) => -3,
        Err(e) => {
            tracing::error!("helios_get_block_by_number failed: {}", e);
            -3
        }
    }
}

/// Estimate gas for a transaction, verified against consensus.
///
/// # Arguments
/// * `call_json` – JSON-encoded TransactionRequest (from, to, data, value)
/// * `result` – Out pointer: hex gas estimate. Caller must free with `helios_free_string`
///
/// # Returns
/// * 0 on success
/// * -1 if not initialized
/// * -2 if call params invalid
/// * -3 if estimation failed
#[no_mangle]
pub extern "C" fn helios_estimate_gas(
    call_json: *const c_char,
    result: *mut *mut c_char,
) -> c_int {
    if !IS_RUNNING.load(Ordering::SeqCst) {
        return -1;
    }

    let call_str = match parse_cstr(call_json) {
        Some(s) => s,
        None => return -2,
    };

    let tx: TransactionRequest = match serde_json::from_str(&call_str) {
        Ok(t) => t,
        Err(e) => {
            tracing::error!("Invalid estimate_gas JSON: {}", e);
            return -2;
        }
    };

    let guard = match HELIOS_STATE.lock() {
        Ok(g) => g,
        Err(_) => return -1,
    };
    let state = match guard.as_ref() {
        Some(s) => s,
        None => return -1,
    };

    let estimate_result = state.runtime.block_on(async {
        state.client.estimate_gas(&tx, None, None).await
    });

    match estimate_result {
        Ok(gas) => {
            let hex = format!("0x{:x}", gas);
            write_result_string(hex, result)
        }
        Err(e) => {
            tracing::error!("helios_estimate_gas failed: {}", e);
            -3
        }
    }
}

/// Send a raw signed transaction through Helios (which routes via Tor).
///
/// # Arguments
/// * `raw_tx` – Hex-encoded signed transaction (0x-prefixed)
/// * `result` – Out pointer: tx hash. Caller must free with `helios_free_string`
///
/// # Returns
/// * 0 on success
/// * -1 if not initialized
/// * -2 if raw_tx is invalid
/// * -3 if broadcast failed
#[no_mangle]
pub extern "C" fn helios_send_raw_transaction(
    raw_tx: *const c_char,
    result: *mut *mut c_char,
) -> c_int {
    if !IS_RUNNING.load(Ordering::SeqCst) {
        return -1;
    }

    let tx_str = match parse_cstr(raw_tx) {
        Some(s) => s,
        None => return -2,
    };

    let stripped = tx_str.strip_prefix("0x").unwrap_or(&tx_str);
    let tx_bytes = match hex::decode(stripped) {
        Ok(b) => b,
        Err(_) => return -2,
    };

    let guard = match HELIOS_STATE.lock() {
        Ok(g) => g,
        Err(_) => return -1,
    };
    let state = match guard.as_ref() {
        Some(s) => s,
        None => return -1,
    };

    let send_result = state.runtime.block_on(async {
        state.client.send_raw_transaction(&tx_bytes).await
    });

    match send_result {
        Ok(hash) => {
            let hex = format!("0x{:x}", hash);
            write_result_string(hex, result)
        }
        Err(e) => {
            tracing::error!("helios_send_raw_transaction failed: {}", e);
            -3
        }
    }
}

/// Get the gas price from the execution layer, verified via consensus.
///
/// # Arguments
/// * `result` – Out pointer: hex gas price in wei. Caller must free with `helios_free_string`
///
/// # Returns
/// * 0 on success
/// * -1 if not initialized
/// * -3 if query failed
#[no_mangle]
pub extern "C" fn helios_gas_price(
    result: *mut *mut c_char,
) -> c_int {
    if !IS_RUNNING.load(Ordering::SeqCst) {
        return -1;
    }

    let guard = match HELIOS_STATE.lock() {
        Ok(g) => g,
        Err(_) => return -1,
    };
    let state = match guard.as_ref() {
        Some(s) => s,
        None => return -1,
    };

    let gas_result = state.runtime.block_on(async {
        state.client.get_gas_price().await
    });

    match gas_result {
        Ok(price) => {
            let hex = format!("0x{:x}", price);
            write_result_string(hex, result)
        }
        Err(e) => {
            tracing::error!("helios_gas_price failed: {}", e);
            -3
        }
    }
}

/// Get the transaction count for an address at the "pending" tag.
/// Used for getting the next nonce to use for a new transaction.
///
/// # Arguments
/// * `address` – Hex Ethereum address (0x-prefixed)
/// * `result` – Out pointer: hex nonce. Caller must free with `helios_free_string`
///
/// # Returns
/// * 0 on success
/// * -1 if not initialized
/// * -2 if address invalid
/// * -3 if query failed
#[no_mangle]
pub extern "C" fn helios_get_pending_nonce(
    address: *const c_char,
    result: *mut *mut c_char,
) -> c_int {
    if !IS_RUNNING.load(Ordering::SeqCst) {
        return -1;
    }

    let addr_str = match parse_cstr(address) {
        Some(s) => s,
        None => return -2,
    };

    let addr = match Address::from_str(&addr_str) {
        Ok(a) => a,
        Err(_) => return -2,
    };

    let guard = match HELIOS_STATE.lock() {
        Ok(g) => g,
        Err(_) => return -1,
    };
    let state = match guard.as_ref() {
        Some(s) => s,
        None => return -1,
    };

    let nonce_result = state.runtime.block_on(async {
        state
            .client
            .get_nonce(addr, BlockNumberOrTag::Pending.into())
            .await
    });

    match nonce_result {
        Ok(nonce) => {
            let hex = format!("0x{:x}", nonce);
            write_result_string(hex, result)
        }
        Err(e) => {
            tracing::error!("helios_get_pending_nonce failed: {}", e);
            -3
        }
    }
}

// ---------------------------------------------------------------------------
// FFI: Status Queries
// ---------------------------------------------------------------------------

/// Get the last block number known to Helios.
///
/// # Returns
/// * Block number (positive) on success
/// * -1 if not initialized or query failed
#[no_mangle]
pub extern "C" fn helios_finalized_block() -> i64 {
    if !IS_RUNNING.load(Ordering::SeqCst) {
        return -1;
    }

    let guard = match HELIOS_STATE.lock() {
        Ok(g) => g,
        Err(_) => return -1,
    };
    let state = match guard.as_ref() {
        Some(s) => s,
        None => return -1,
    };

    match state
        .runtime
        .block_on(async { state.client.get_block_number().await })
    {
        Ok(n) => {
            // U256 → i64: block numbers fit in i64 for the foreseeable future
            let lo: u64 = n.to::<u64>();
            lo as i64
        }
        Err(_) => -1,
    }
}

// ---------------------------------------------------------------------------
// FFI: Memory Management & Shutdown
// ---------------------------------------------------------------------------

/// Free a string previously returned by helios_get_balance, helios_get_logs, etc.
///
/// # Safety
/// `ptr` must be a valid pointer returned by one of the helios_* functions,
/// or null (which is a no-op).
#[no_mangle]
pub extern "C" fn helios_free_string(ptr: *mut c_char) {
    if !ptr.is_null() {
        unsafe {
            drop(CString::from_raw(ptr));
        }
    }
}

/// Gracefully shut down the Helios client.
///
/// # Returns
/// * 0 on success
/// * -1 if not running
#[no_mangle]
pub extern "C" fn helios_shutdown() -> c_int {
    if !IS_RUNNING.load(Ordering::SeqCst) {
        return -1;
    }

    IS_RUNNING.store(false, Ordering::SeqCst);
    IS_SYNCED.store(false, Ordering::SeqCst);
    SYNC_PROGRESS.store(0, Ordering::SeqCst);

    // Clear Tor proxy env vars
    unsafe {
        std::env::remove_var("ALL_PROXY");
        std::env::remove_var("HTTPS_PROXY");
    }

    // Drop the client and runtime so helios_init() can be called again
    if let Ok(mut guard) = HELIOS_STATE.lock() {
        *guard = None;
    }

    tracing::info!("Helios client shut down");
    0
}

// ---------------------------------------------------------------------------
// Internal: Client Builder
// ---------------------------------------------------------------------------

/// Build the Helios EthereumClient with the given configuration.
///
/// Uses FileDB for checkpoint persistence and external fallback for
/// initial checkpoint sourcing if no valid checkpoint is provided.
fn build_client(
    execution_rpc: &str,
    consensus_rpc: &str,
    checkpoint: &str,
    network: Network,
) -> eyre::Result<EthereumClient> {
    // Use a sensible data directory for checkpoint caching
    let data_dir = PathBuf::from(
        std::env::var("HOME").unwrap_or_else(|_| "/tmp".to_string()),
    )
    .join(".helios");

    let mut builder = EthereumClientBuilder::new()
        .network(network)
        .consensus_rpc(consensus_rpc)?
        .execution_rpc(execution_rpc)?
        .load_external_fallback()
        .data_dir(data_dir)
        .with_file_db();

    // Set checkpoint if a valid 32-byte hex value was provided
    let stripped = checkpoint
        .strip_prefix("0x")
        .unwrap_or(checkpoint);
    if !stripped.is_empty() && !stripped.chars().all(|c| c == '0') {
        if let Ok(cp) = B256::from_str(&format!("0x{}", stripped)) {
            builder = builder.checkpoint(cp);
            tracing::info!("Using provided checkpoint: 0x{}", stripped);
        }
    } else {
        tracing::info!("No checkpoint provided, using external fallback");
    }

    let client = builder.build()?;
    Ok(client)
}

// ---------------------------------------------------------------------------
// Internal: Helpers
// ---------------------------------------------------------------------------

/// Parse a C string pointer into a Rust String.
fn parse_cstr(ptr: *const c_char) -> Option<String> {
    if ptr.is_null() {
        return None;
    }
    unsafe { CStr::from_ptr(ptr) }
        .to_str()
        .ok()
        .map(|s| s.to_string())
}

/// Write a string result to the FFI out pointer.
///
/// Returns 0 on success, -3 on failure.
fn write_result_string(value: String, result: *mut *mut c_char) -> c_int {
    match CString::new(value) {
        Ok(cs) => {
            unsafe { *result = cs.into_raw() };
            0
        }
        Err(_) => -3,
    }
}
