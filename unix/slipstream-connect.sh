#!/usr/bin/env bash
# slipstream-connect.sh
# Main orchestrator for SlipStream Auto Connector (Linux/macOS)
# Finds a working DNS resolver, connects, and maintains the connection

set -uo pipefail
# NOTE: -e is intentionally omitted. Arithmetic like ((x++)) returns 1 when x=0,
# which would kill the script under -e. We handle errors explicitly.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Load modules
source "$SCRIPT_DIR/lib/logger.sh"
source "$SCRIPT_DIR/lib/config.sh"
source "$SCRIPT_DIR/lib/test-dns.sh"
source "$SCRIPT_DIR/lib/connect.sh"

# ── Parse arguments ──

CONFIG_PATH=""
DNS_LIST_PATH=""
CUSTOM_DNS_PATH=""
WORKERS_OVERRIDE=0
SHOW_HELP=false

while [[ $# -gt 0 ]]; do
    case "$1" in
        -c|--config)     CONFIG_PATH="$2"; shift 2 ;;
        -d|--dns-list)   DNS_LIST_PATH="$2"; shift 2 ;;
        -u|--user-dns)   CUSTOM_DNS_PATH="$2"; shift 2 ;;
        -w|--workers)    WORKERS_OVERRIDE="$2"; shift 2 ;;
        -h|--help)       SHOW_HELP=true; shift ;;
        *)               echo "Unknown option: $1"; exit 1 ;;
    esac
done

if [[ "$SHOW_HELP" == "true" ]]; then
    print_banner
    cat << 'HELP'
Automatically finds a working DNS resolver, connects via slipstream-client,
and maintains the connection with auto-reconnect.

USAGE:
  ./slipstream-connect.sh [options]
  ./start.sh [options]

OPTIONS:
  -c, --config <path>     Path to config.ini (default: ./config.ini)
  -d, --dns-list <path>   Path to dns-list.txt (default: ./dns-list.txt)
  -u, --user-dns <path>   Path to your own DNS file (tested first, highest priority)
  -w, --workers <number>  Override parallel worker count (default: from config)
  -h, --help              Show this message

EXAMPLES:
  ./start.sh                                   # Just run and go
  ./slipstream-connect.sh -w 10                # Test 10 DNS at once
  ./slipstream-connect.sh -u my-dns.txt        # Use your own DNS list first
  ./slipstream-connect.sh -d /path/to/dns.txt

HELP
    exit 0
fi

# Resolve paths — config/dns/results/exe are in the project root (one level up)
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"
[[ -z "$CONFIG_PATH" ]] && CONFIG_PATH="$PROJECT_ROOT/config.ini"
[[ -z "$DNS_LIST_PATH" ]] && DNS_LIST_PATH="$PROJECT_ROOT/dns-list.txt"
[[ -z "$CUSTOM_DNS_PATH" ]] && CUSTOM_DNS_PATH="$PROJECT_ROOT/dns-custom.txt"
RESULTS_DIR="$PROJECT_ROOT/results"
EXE_PATH="$PROJECT_ROOT/slipstream-client"

# Banner + logger
print_banner
init_logger "$RESULTS_DIR"

# ── Preflight checks ──

if [[ ! -f "$EXE_PATH" ]]; then
    log Error "slipstream-client not found!"
    log Error "Place it in: $PROJECT_ROOT"
    log Info "Make sure it's executable: chmod +x slipstream-client"
    exit 1
fi

if [[ ! -x "$EXE_PATH" ]]; then
    log Warning "slipstream-client is not executable, fixing..."
    chmod +x "$EXE_PATH"
fi

if ! command -v curl &>/dev/null; then
    log Error "curl not found!"
    log Error "Install it: sudo apt install curl  (or your distro's equivalent)"
    exit 1
fi

# ── Load configuration ──

read_config "$CONFIG_PATH"
[[ $WORKERS_OVERRIDE -gt 0 ]] && CONFIG[Workers]="$WORKERS_OVERRIDE"

log Info "Domain: ${CONFIG[Domain]}"
log Info "Workers: ${CONFIG[Workers]} | Timeout: ${CONFIG[Timeout]}s | Health check: ${CONFIG[HealthCheckInterval]}s"
echo ""

# ── Load DNS list ──

DNS_LIST=()
PRIORITY_COUNT=0
read_dns_list "$CUSTOM_DNS_PATH" "$DNS_LIST_PATH" "$RESULTS_DIR"

if [[ ${#DNS_LIST[@]} -eq 0 ]]; then
    log Error "No DNS entries to test! Check your dns-list.txt file."
    exit 1
fi

# Save full list for reconnection loop
FULL_DNS_LIST=("${DNS_LIST[@]}")

# ── Initialize temp directory (clean on startup for crash leftovers) ──

init_slipstream_temp_dir

# ── Cleanup on exit (Ctrl+C, kill, etc.) ──

cleanup() {
    echo ""
    log Warning "Shutting down..."

    # Kill worker processes
    if [[ ${#WORKER_PIDS[@]} -gt 0 ]]; then
        for pid in "${WORKER_PIDS[@]}"; do
            kill "$pid" 2>/dev/null || true
        done
    fi

    # Kill active connection
    stop_active_connection

    # Kill any remaining slipstream-client processes we spawned
    pkill -P $$ slipstream-client 2>/dev/null || true

    # Clean up temp directory
    cleanup_slipstream_temp_dir

    log Info "Goodbye."
    exit 0
}

trap cleanup INT TERM EXIT

# ── Phase 1: Find a working DNS ──

FOUND_DNS=""
FOUND_PORT=""

echo ""
log Info "=== Phase 1: Scanning for a working DNS ==="

# Phase 1a: Test priority DNS first (tier 0 + tier 1)
if [[ $PRIORITY_COUNT -gt 0 ]]; then
    echo ""
    log Info "Testing $PRIORITY_COUNT priority DNS entries first..."
    DNS_LIST=("${FULL_DNS_LIST[@]:0:$PRIORITY_COUNT}")
    start_dns_testing "$EXE_PATH" "$RESULTS_DIR"
fi

# Phase 1b: If no priority DNS worked, test the rest
if [[ -z "$FOUND_DNS" ]]; then
    remaining_count=$(( ${#FULL_DNS_LIST[@]} - PRIORITY_COUNT ))
    if [[ $remaining_count -gt 0 ]]; then
        echo ""
        log Info "Scanning remaining $remaining_count DNS entries..."
        DNS_LIST=("${FULL_DNS_LIST[@]:$PRIORITY_COUNT}")
        start_dns_testing "$EXE_PATH" "$RESULTS_DIR"
    fi
fi

if [[ -z "$FOUND_DNS" ]]; then
    echo ""
    log Error "No working DNS found after testing all entries."
    log Info "Things to try:"
    log Info "  1. Update your dns-list.txt with fresh DNS entries"
    log Info "  2. Delete results/dns-failed.txt to re-test previously failed ones"
    log Info "  3. Increase Workers in config.ini for faster scanning"
    log Info "  4. Try again later - some DNS resolvers are intermittent"
    exit 1
fi

# ── Phase 2: Connect and maintain ──

echo ""
log Info "=== Phase 2: Establishing persistent connection ==="

reconnect_count=0

while true; do
    if [[ ${CONFIG[MaxReconnectAttempts]} -gt 0 && $reconnect_count -ge ${CONFIG[MaxReconnectAttempts]} ]]; then
        log Error "Max reconnect attempts (${CONFIG[MaxReconnectAttempts]}) reached. Stopping."
        break
    fi

    port=$(get_random_port)

    if [[ $reconnect_count -eq 0 ]]; then
        log Info "Connecting via $FOUND_DNS on port $port..."
    else
        echo ""
        log Warning "Reconnecting (attempt $reconnect_count) via $FOUND_DNS on port $port..."
    fi

    if start_slipstream_connection "$FOUND_DNS" "$port" "$EXE_PATH"; then
        sleep 0.5
        status_code=$(curl --proxy "socks5://127.0.0.1:$port" \
            --max-time "${CONFIG[ConnectivityTimeout]}" \
            -s -o /dev/null -w "%{http_code}" \
            "${CONFIG[ConnectivityUrl]}" 2>/dev/null) || true

        if [[ "$status_code" == "204" ]]; then
            timestamp=$(date "+%Y-%m-%d %H:%M:%S")
            echo "$FOUND_DNS | $timestamp" >> "$RESULTS_DIR/dns-working.txt"

            watch_connection "$port"
            stop_active_connection
        else
            log Warning "Tunnel up via $FOUND_DNS but no internet"
            stop_active_connection
        fi
    else
        log Warning "Failed to connect via $FOUND_DNS"
    fi

    # Connection failed or dropped — re-scan for working DNS
    reconnect_count=$((reconnect_count + 1))
    echo ""
    log Warning "Re-scanning for a working DNS..."

    FOUND_DNS=""
    FOUND_PORT=""

    if [[ $PRIORITY_COUNT -gt 0 ]]; then
        DNS_LIST=("${FULL_DNS_LIST[@]:0:$PRIORITY_COUNT}")
        start_dns_testing "$EXE_PATH" "$RESULTS_DIR"
    fi

    if [[ -z "$FOUND_DNS" ]]; then
        remaining_count=$(( ${#FULL_DNS_LIST[@]} - PRIORITY_COUNT ))
        if [[ $remaining_count -gt 0 ]]; then
            DNS_LIST=("${FULL_DNS_LIST[@]:$PRIORITY_COUNT}")
            start_dns_testing "$EXE_PATH" "$RESULTS_DIR"
        fi
    fi

    if [[ -z "$FOUND_DNS" ]]; then
        echo ""
        log Error "No working DNS found after re-scanning."
        log Info "Things to try:"
        log Info "  1. Update your dns-list.txt with fresh DNS entries"
        log Info "  2. Delete results/dns-failed.txt to re-test previously failed ones"
        log Info "  3. Increase Workers in config.ini for faster scanning"
        break
    fi
done

echo ""
log Warning "SlipStream Connector has stopped."
