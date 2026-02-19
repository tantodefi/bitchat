#ifndef HELIOS_H
#define HELIOS_H

#include <stdint.h>
#include <stdbool.h>

/**
 * Initialize the Helios light client.
 *
 * Builds an `EthereumClient` configured for mainnet with the given RPC
 * endpoints. If `socks_proxy_port > 0`, all upstream HTTP requests are
 * routed through the Tor SOCKS5 proxy at `127.0.0.1:<port>`.
 *
 * The client begins its consensus sync loop immediately. Call
 * `helios_wait_synced()` to block until the first sync completes, or
 * poll with `helios_is_synced()` / `helios_sync_progress()`.
 *
 * # Arguments
 * * `rpc_url` – Upstream execution-layer RPC (e.g. "https://rpc.flashbots.net")
 * * `consensus_rpc` – Beacon API endpoint (e.g. "https://www.lightclientdata.org")
 * * `checkpoint` – Weak subjectivity checkpoint (hex, 0x-prefixed, or empty for external fallback)
 * * `socks_proxy_port` – Tor SOCKS5 port (0 to disable proxy)
 *
 * # Returns
 * * 0 on success
 * * -1 if already running
 * * -2 if parameter parsing failed
 * * -3 if runtime initialization failed
 * * -4 if client build failed
 */
int helios_init(const char *rpc_url,
                const char *consensus_rpc,
                const char *checkpoint,
                uint16_t socks_proxy_port);

/**
 * Block until the Helios client has completed its first sync.
 *
 * This blocks the calling thread. Call from a background queue/thread.
 * After this returns 0, `helios_get_balance` etc. will return verified data.
 *
 * # Returns
 * * 0 on success (synced)
 * * -1 if not initialized
 * * -2 if sync failed
 */
int helios_wait_synced(void);

/**
 * Check if Helios has completed its initial sync.
 *
 * # Returns
 * * 1 if synced
 * * 0 if not synced
 */
int helios_is_synced(void);

/**
 * Get the sync progress.
 *
 * # Returns
 * * 0: not started
 * * 1-99: syncing
 * * 100: synced
 * * -1: error
 */
int helios_sync_progress(void);

/**
 * Get the verified balance for an address on the execution layer.
 *
 * The balance is verified against the consensus-attested state root
 * (sync committee BLS signatures). This is trustless verification —
 * the untrusted execution RPC cannot lie about the balance.
 *
 * # Arguments
 * * `address` – Hex Ethereum address (0x-prefixed)
 * * `result` – Out pointer: caller must free with `helios_free_string`
 *
 * # Returns
 * * 0 on success (balance hex string written to *result)
 * * -1 if not initialized
 * * -2 if address is invalid
 * * -3 if verification/query failed
 */
int helios_get_balance(const char *address, char **result);

/**
 * Get verified event logs matching a JSON filter.
 *
 * Used for stealth address scanning (EIP-5564 announcements).
 * Logs are verified against consensus-attested block roots, ensuring
 * a malicious RPC cannot omit or fabricate announcements.
 *
 * # Arguments
 * * `filter_json` – JSON-encoded log filter (address, topics, fromBlock, toBlock)
 * * `result` – Out pointer: JSON array of logs. Caller must free with `helios_free_string`
 *
 * # Returns
 * * 0 on success
 * * -1 if not initialized
 * * -2 if filter is invalid
 * * -3 if query/verification failed
 */
int helios_get_logs(const char *filter_json, char **result);

/**
 * Execute a verified eth_call.
 *
 * The call result is verified against the consensus-attested state root.
 * Used for ENS resolution, ERC-20 balanceOf, contract reads, etc.
 *
 * # Arguments
 * * `call_json` – JSON-encoded TransactionRequest (to, data, value, etc.)
 * * `result` – Out pointer: hex result data. Caller must free with `helios_free_string`
 *
 * # Returns
 * * 0 on success
 * * -1 if not initialized
 * * -2 if call params invalid
 * * -3 if execution/verification failed
 */
int helios_eth_call(const char *call_json, char **result);

/**
 * Get the transaction count (nonce) for an address.
 *
 * Verified against the consensus-attested state root, so no RPC can
 * lie about the nonce value.
 *
 * # Arguments
 * * `address` – Hex Ethereum address (0x-prefixed)
 * * `result` – Out pointer: hex nonce. Caller must free with `helios_free_string`
 *
 * # Returns
 * * 0 on success
 * * -1 if not initialized
 * * -2 if address is invalid
 * * -3 if query failed
 */
int helios_get_nonce(const char *address, char **result);

/**
 * Get the transaction receipt by hash, verified against consensus.
 *
 * Returns a JSON-encoded receipt including status, gasUsed, blockNumber,
 * logs, etc. Used for tx history and confirmation tracking.
 *
 * # Arguments
 * * `tx_hash` – Transaction hash (0x-prefixed, 66 chars)
 * * `result` – Out pointer: JSON receipt. Caller must free with `helios_free_string`
 *
 * # Returns
 * * 0 on success (receipt found)
 * * -1 if not initialized
 * * -2 if hash is invalid
 * * -3 if query failed or receipt not found
 */
int helios_get_transaction_receipt(const char *tx_hash, char **result);

/**
 * Get a block by number, verified against consensus.
 *
 * Returns JSON-encoded block data including transactions list.
 * When `full_txs` is true, returns full transaction objects;
 * when false, returns only transaction hashes.
 *
 * # Arguments
 * * `block_tag` – Block number as hex (0x-prefixed) or "latest"/"finalized"
 * * `full_txs` – 1 for full transaction objects, 0 for hashes only
 * * `result` – Out pointer: JSON block. Caller must free with `helios_free_string`
 *
 * # Returns
 * * 0 on success
 * * -1 if not initialized
 * * -2 if block_tag is invalid
 * * -3 if query failed
 */
int helios_get_block_by_number(const char *block_tag, int full_txs, char **result);

/**
 * Estimate gas for a transaction, verified against consensus.
 *
 * # Arguments
 * * `call_json` – JSON-encoded TransactionRequest (from, to, data, value)
 * * `result` – Out pointer: hex gas estimate. Caller must free with `helios_free_string`
 *
 * # Returns
 * * 0 on success
 * * -1 if not initialized
 * * -2 if call params invalid
 * * -3 if estimation failed
 */
int helios_estimate_gas(const char *call_json, char **result);

/**
 * Send a raw signed transaction through Helios (which routes via Tor).
 *
 * # Arguments
 * * `raw_tx` – Hex-encoded signed transaction (0x-prefixed)
 * * `result` – Out pointer: tx hash. Caller must free with `helios_free_string`
 *
 * # Returns
 * * 0 on success
 * * -1 if not initialized
 * * -2 if raw_tx is invalid
 * * -3 if broadcast failed
 */
int helios_send_raw_transaction(const char *raw_tx, char **result);

/**
 * Get the gas price from the execution layer, verified via consensus.
 *
 * # Arguments
 * * `result` – Out pointer: hex gas price in wei. Caller must free with `helios_free_string`
 *
 * # Returns
 * * 0 on success
 * * -1 if not initialized
 * * -3 if query failed
 */
int helios_gas_price(char **result);

/**
 * Get the transaction count for an address at the "pending" tag.
 * Used for getting the next nonce to use for a new transaction.
 *
 * # Arguments
 * * `address` – Hex Ethereum address (0x-prefixed)
 * * `result` – Out pointer: hex nonce. Caller must free with `helios_free_string`
 *
 * # Returns
 * * 0 on success
 * * -1 if not initialized
 * * -2 if address invalid
 * * -3 if query failed
 */
int helios_get_pending_nonce(const char *address, char **result);

/**
 * Get the last block number known to Helios.
 *
 * # Returns
 * * Block number (positive) on success
 * * -1 if not initialized or query failed
 */
int64_t helios_finalized_block(void);

/**
 * Free a string previously returned by helios_get_balance, helios_get_logs, etc.
 *
 * # Safety
 * `ptr` must be a valid pointer returned by one of the helios_* functions,
 * or null (which is a no-op).
 */
void helios_free_string(char *ptr);

/**
 * Gracefully shut down the Helios client.
 *
 * # Returns
 * * 0 on success
 * * -1 if not running
 */
int helios_shutdown(void);

#endif  /* HELIOS_H */
