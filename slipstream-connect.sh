#!/usr/bin/env bash
# slipstream-connect.sh
# Main orchestrator for SlipStream Auto Connector (Linux/macOS)
# Finds a working DNS resolver, connects, and maintains the connection

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Load modules
source "$SCRIPT_DIR/lib/logger.sh"
source "$SCRIPT_DIR/lib/config.sh"
source "$SCRIPT_DIR/lib/test-dns.sh"
source "$SCRIPT_DIR/lib/connect.sh"

# ── Parse arguments ──

CONFIG_PATH=""
DNS_LIST_PATH=""
WORKERS_OVERRIDE=0
SHOW_HELP=false

while [[ $# -gt 0 ]]; do
    case "$1" in
        -c|--config)     CONFIG_PATH="$2"; shift 2 ;;
        -d|--dns-list)   DNS_LIST_PATH="$2"; shift 2 ;;
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
  -w, --workers <number>  Override parallel worker count (default: from config)
  -h, --help              Show this message

EXAMPLES:
  ./start.sh                                   # Just run and go
  ./slipstream-connect.sh -w 10                # Test 10 DNS at once
  ./slipstream-connect.sh -d /path/to/dns.txt

HELP
    exit 0
fi

# Resolve paths
[[ -z "$CONFIG_PATH" ]] && CONFIG_PATH="$SCRIPT_DIR/config.ini"
[[ -z "$DNS_LIST_PATH" ]] && DNS_LIST_PATH="$SCRIPT_DIR/dns-list.txt"
RESULTS_DIR="$SCRIPT_DIR/results"
EXE_PATH="$SCRIPT_DIR/slipstream-client"

# Banner + logger
print_banner
init_logger "$RESULTS_DIR"

# ── Preflight checks ──

if [[ ! -f "$EXE_PATH" ]]; then
    log Error "slipstream-client not found!"
    log Error "Place it in: $SCRIPT_DIR"
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
read_dns_list "$DNS_LIST_PATH" "$RESULTS_DIR"

if [[ ${#DNS_LIST[@]} -eq 0 ]]; then
    log Error "No DNS entries to test! Check your dns-list.txt file."
    exit 1
fi

# ── Cleanup on exit (Ctrl+C, kill, etc.) ──

cleanup() {
    echo ""
    log Warning "Shutting down..."

    # Kill worker processes
    for pid in "${WORKER_PIDS[@]}"; do
        kill "$pid" 2>/dev/null
    done

    # Kill active connection
    stop_active_connection

    # Kill any remaining slipstream-client processes we spawned
    pkill -P $$ slipstream-client 2>/dev/null || true

    log Info "Goodbye."
    exit 0
}

trap cleanup INT TERM EXIT

# ── Phase 1: Find a working DNS ──

echo ""
log Info "=== Phase 1: Scanning for a working DNS ==="
echo ""

start_dns_testing "$EXE_PATH" "$RESULTS_DIR"

if [[ -z "$FOUND_DNS" ]]; then
    echo ""
    log Error "No working DNS found after testing all entries."
    log Info "Things to try:"
    log Info "  1. Update your dns-list.txt with fresh DNS entries"
    log Info "  2. Delete results/failed-dns.txt to re-test previously failed ones"
    log Info "  3. Increase Workers in config.ini for faster scanning"
    log Info "  4. Try again later - some DNS resolvers are intermittent"
    exit 1
fi

# ── Phase 2: Connect and maintain ──

echo ""
log Info "=== Phase 2: Establishing persistent connection ==="

# Find start index
start_index=0
for i in "${!DNS_LIST[@]}"; do
    if [[ "${DNS_LIST[$i]}" == "$FOUND_DNS" ]]; then
        start_index=$i
        break
    fi
done

start_connection_loop "$start_index" "$EXE_PATH" "$RESULTS_DIR"

echo ""
log Warning "SlipStream Connector has stopped."
