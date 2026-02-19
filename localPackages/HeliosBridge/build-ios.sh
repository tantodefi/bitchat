#!/bin/bash
#
# Build helios-ios for iOS/macOS with aggressive size optimization
#
# Output: Frameworks/helios.xcframework containing static libraries for:
#   - aarch64-apple-ios (iOS device)
#   - aarch64-apple-ios-sim (iOS simulator, Apple Silicon)
#   - aarch64-apple-darwin (macOS)
#
# Usage:
#   ./build-ios.sh          # Full build
#   ./build-ios.sh --skip-build  # Only regenerate xcframework from cached artifacts
#
set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

# Configuration
CRATE_NAME="helios-ios"
LIB_NAME="libhelios_ios.a"
FRAMEWORK_NAME="helios"
OUTPUT_DIR="$SCRIPT_DIR/Frameworks"

# Targets to build
TARGETS=(
    "aarch64-apple-ios"           # iOS device
    "aarch64-apple-ios-sim"       # iOS simulator (Apple Silicon)
    "aarch64-apple-darwin"        # macOS
)

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

log_info() { echo -e "${GREEN}[INFO]${NC} $1"; }
log_warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }
log_error() { echo -e "${RED}[ERROR]${NC} $1"; }

# Check prerequisites
check_prerequisites() {
    log_info "Checking prerequisites..."

    if ! command -v rustc &> /dev/null; then
        log_error "Rust is not installed. Please install via rustup."
        exit 1
    fi

    if ! command -v cargo &> /dev/null; then
        log_error "Cargo is not installed. Please install via rustup."
        exit 1
    fi

    # Check/install targets
    for target in "${TARGETS[@]}"; do
        if ! rustup target list --installed | grep -q "$target"; then
            log_info "Installing target: $target"
            rustup target add "$target"
        fi
    done

    # Install cbindgen if needed
    if ! command -v cbindgen &> /dev/null; then
        log_info "Installing cbindgen..."
        cargo install cbindgen
    fi

    log_info "Prerequisites OK"
}

# Set up aggressive size optimization flags and deployment targets
setup_rustflags() {
    local target="$1"

    # Base flags for size optimization
    export RUSTFLAGS="-C opt-level=z -C lto=fat -C codegen-units=1 -C panic=abort -C strip=symbols"

    # Set deployment targets to suppress linker warnings
    case "$target" in
        *-apple-ios-sim*)
            export IPHONEOS_DEPLOYMENT_TARGET="16.0"
            ;;
        *-apple-ios*)
            export IPHONEOS_DEPLOYMENT_TARGET="16.0"
            ;;
        *-apple-darwin*)
            export MACOSX_DEPLOYMENT_TARGET="13.0"
            ;;
    esac

    log_info "RUSTFLAGS: $RUSTFLAGS"
}

# Build for a single target
build_target() {
    local target="$1"
    log_info "Building for target: $target"

    setup_rustflags "$target"

    # Build release
    cargo build --release --target "$target" -p "$CRATE_NAME"

    # Check output
    local lib_path="target/$target/release/$LIB_NAME"
    if [[ -f "$lib_path" ]]; then
        local size=$(du -h "$lib_path" | cut -f1)
        log_info "Built $lib_path ($size)"
    else
        log_error "Build failed: $lib_path not found"
        exit 1
    fi
}

# Generate C header using cbindgen
generate_header() {
    log_info "Generating C header..."

    local header_dir="$OUTPUT_DIR/include"
    local header_path="$header_dir/helios.h"

    mkdir -p "$header_dir"

    # Try cbindgen first
    if command -v cbindgen &> /dev/null; then
        cbindgen --config "$CRATE_NAME/cbindgen.toml" \
                 --crate "$CRATE_NAME" \
                 --output "$header_path" 2>/dev/null && {
            log_info "Generated $header_path via cbindgen"
            return
        }
    fi

    # Fallback: create header manually
    log_warn "cbindgen failed, creating manual header..."
    cat > "$header_path" << 'EOF'
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
 * @param rpc_url Upstream execution RPC URL (C string)
 * @param consensus_rpc Beacon API endpoint (C string)
 * @param checkpoint Weak subjectivity checkpoint hex (C string)
 * @param socks_proxy_port Tor SOCKS5 port (0 to disable)
 * @return 0 on success, negative on error
 */
int32_t helios_init(
    const char *rpc_url,
    const char *consensus_rpc,
    const char *checkpoint,
    uint16_t socks_proxy_port
);

/**
 * Get verified balance for an Ethereum address.
 *
 * Balance is verified against the consensus-attested state root.
 * Caller must free the result string with helios_free_string().
 *
 * @param address Hex Ethereum address (0x-prefixed)
 * @param result Out pointer for balance hex string
 * @return 0 on success, negative on error
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
 * @return 0 on success, negative on error
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
 * @param call_json JSON-encoded call object
 * @param result Out pointer for hex result data
 * @return 0 on success, negative on error
 */
int32_t helios_eth_call(
    const char *call_json,
    char **result
);

/**
 * Get the last finalized block number known to Helios.
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
EOF
    log_info "Created manual header at $header_path"
}

# Create xcframework from built libraries
create_xcframework() {
    log_info "Creating xcframework..."

    local xcframework_path="$OUTPUT_DIR/$FRAMEWORK_NAME.xcframework"

    # Remove existing xcframework
    rm -rf "$xcframework_path"
    mkdir -p "$OUTPUT_DIR"

    # Build the xcodebuild command
    local cmd="xcodebuild -create-xcframework"

    for target in "${TARGETS[@]}"; do
        local lib_path="$SCRIPT_DIR/target/$target/release/$LIB_NAME"
        if [[ -f "$lib_path" ]]; then
            # Strip the library for additional size reduction
            log_info "Stripping $target library..."
            strip -x "$lib_path" 2>/dev/null || true

            cmd="$cmd -library $lib_path"

            # Add headers if they exist
            local header_dir="$OUTPUT_DIR/include"
            if [[ -d "$header_dir" ]]; then
                cmd="$cmd -headers $header_dir"
            fi
        else
            log_warn "Skipping missing library: $lib_path"
        fi
    done

    cmd="$cmd -output $xcframework_path"

    log_info "Running: $cmd"
    eval "$cmd"

    if [[ -d "$xcframework_path" ]]; then
        local size=$(du -sh "$xcframework_path" | cut -f1)
        log_info "Created $xcframework_path ($size)"
    else
        log_error "Failed to create xcframework"
        exit 1
    fi
}

# Print size report
print_size_report() {
    log_info "=== Size Report ==="
    for target in "${TARGETS[@]}"; do
        local lib_path="$SCRIPT_DIR/target/$target/release/$LIB_NAME"
        if [[ -f "$lib_path" ]]; then
            local size=$(du -h "$lib_path" | cut -f1)
            echo "  $target: $size"
        fi
    done

    local xcframework_path="$OUTPUT_DIR/$FRAMEWORK_NAME.xcframework"
    if [[ -d "$xcframework_path" ]]; then
        local total_size=$(du -sh "$xcframework_path" | cut -f1)
        echo "  xcframework total: $total_size"
    fi
}

# Main
main() {
    log_info "Building helios-ios for iOS/macOS"
    log_info "================================="

    check_prerequisites
    generate_header

    if [[ "$1" != "--skip-build" ]]; then
        for target in "${TARGETS[@]}"; do
            build_target "$target"
        done
    fi

    create_xcframework
    print_size_report

    log_info "Build complete!"
    log_info "xcframework: $OUTPUT_DIR/$FRAMEWORK_NAME.xcframework"
}

# Run
main "$@"
