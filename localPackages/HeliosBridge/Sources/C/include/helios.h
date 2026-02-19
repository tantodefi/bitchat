#ifndef HELIOS_H
#define HELIOS_H

#include <stdint.h>
#include <stdbool.h>

#ifdef __cplusplus
extern "C" {
#endif

/**
 * Initialize the Helios light client.
 *
 * Builds an EthereumClient configured for mainnet. If socks_proxy_port > 0,
 * all upstream HTTP requests are routed through Tor at 127.0.0.1:<port>.
 * The client begins consensus sync immediately. Use helios_wait_synced()
 * to block until ready, or poll with helios_is_synced().
 *
 * @param rpc_url Upstream execution RPC URL (C string)
 * @param consensus_rpc Beacon API endpoint (C string)
 * @param checkpoint Weak subjectivity checkpoint hex (C string, or empty)
 * @param socks_proxy_port Tor SOCKS5 port (0 to disable)
 * @return 0 on success, -1 already running, -2 bad params, -3 runtime error, -4 build error
 */
int32_t helios_init(
    const char *rpc_url,
    const char *consensus_rpc,
    const char *checkpoint,
    uint16_t socks_proxy_port
);

/**
 * Block until the Helios client completes its first consensus sync.
 *
 * Call from a background thread. After this returns 0, verified queries work.
 *
 * @return 0 on success, -1 not initialized, -2 sync failed
 */
int32_t helios_wait_synced(void);

/**
 * Check if Helios has completed its initial sync.
 *
 * @return 1 if synced, 0 if not
 */
int32_t helios_is_synced(void);

/**
 * Get the sync progress.
 *
 * @return 0 not started, 1-99 syncing, 100 synced, -1 error
 */
int32_t helios_sync_progress(void);

/**
 * Get verified balance for an Ethereum address.
 *
 * Balance is verified against the consensus-attested state root
 * (sync committee BLS signatures). Caller must free the result
 * string with helios_free_string().
 *
 * @param address Hex Ethereum address (0x-prefixed)
 * @param result Out pointer for balance hex string
 * @return 0 on success, -1 not init, -2 bad address, -3 query failed
 */
int32_t helios_get_balance(
    const char *address,
    char **result
);

/**
 * Get verified event logs matching a filter.
 *
 * Used for stealth address scanning (EIP-5564).
 * Caller must free the result string with helios_free_string().
 *
 * @param filter_json JSON-encoded log filter
 * @param result Out pointer for JSON array of logs
 * @return 0 on success, -1 not init, -2 bad filter, -3 query failed
 */
int32_t helios_get_logs(
    const char *filter_json,
    char **result
);

/**
 * Execute a verified eth_call.
 *
 * Result verified against consensus-attested state root.
 * Caller must free the result string with helios_free_string().
 *
 * @param call_json JSON-encoded TransactionRequest
 * @param result Out pointer for hex result data
 * @return 0 on success, -1 not init, -2 bad params, -3 call failed
 */
int32_t helios_eth_call(
    const char *call_json,
    char **result
);

/**
 * Get the last block number known to Helios.
 *
 * @return Block number on success, -1 if not initialized
 */
int64_t helios_finalized_block(void);

/**
 * Free a string returned by helios_get_balance, helios_get_logs, etc.
 *
 * @param ptr Pointer to free (null is a safe no-op)
 */
void helios_free_string(char *ptr);

/**
 * Shut down the Helios client gracefully.
 *
 * @return 0 on success, -1 if not running
 */
int32_t helios_shutdown(void);

#ifdef __cplusplus
}
#endif

#endif /* HELIOS_H */
