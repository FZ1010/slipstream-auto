#!/usr/bin/env bash
# lib/connect.sh
# Manages the active slipstream connection with health monitoring and auto-reconnect
#
# Detection logic:
#   - "became unavailable" = connection lost (not just any WARN)
#   - Health checks verify actual internet connectivity through the SOCKS5 proxy

ACTIVE_PID=""
ACTIVE_OUT_FILE=""

start_slipstream_connection() {
    local dns="$1"
    local port="$2"
    local exe_path="$3"

    ACTIVE_OUT_FILE=$(mktemp "$SLIPSTREAM_TEMP_DIR/conn.XXXXXX")

    "$exe_path" \
        --domain "${CONFIG[Domain]}" \
        --congestion-control "${CONFIG[CongestionControl]}" \
        --keep-alive-interval "${CONFIG[KeepAliveInterval]}" \
        --tcp-listen-port "$port" \
        --resolver "$dns" \
        > "$ACTIVE_OUT_FILE" 2>&1 &

    ACTIVE_PID=$!

    local timeout=$(( ${CONFIG[Timeout]} + 2 ))
    local deadline=$(( $(date +%s) + timeout ))
    local connected=false

    while [[ $(date +%s) -lt $deadline ]]; do
        if ! kill -0 "$ACTIVE_PID" 2>/dev/null; then
            break
        fi

        local output
        output=$(cat "$ACTIVE_OUT_FILE" 2>/dev/null) || true

        if [[ "$output" == *"became unavailable"* ]]; then
            stop_active_connection
            return 1
        fi

        if [[ "$output" == *"Connection ready"* ]]; then
            connected=true
            break
        fi

        sleep 0.2
    done

    if [[ "$connected" != "true" ]]; then
        stop_active_connection
        return 1
    fi

    return 0
}

watch_connection() {
    local port="$1"

    echo ""
    log Success "============================================"
    log Success "  CONNECTED! You are now online."
    log Success "  SOCKS5 Proxy: 127.0.0.1:$port"
    log Success "============================================"
    echo ""
    log Info "Set your browser/system proxy to SOCKS5 127.0.0.1:$port"
    log Info "Health checks every ${CONFIG[HealthCheckInterval]}s. Press Ctrl+C to stop."
    echo ""

    local fail_count=0
    local max_fails=3

    while kill -0 "$ACTIVE_PID" 2>/dev/null; do
        sleep "${CONFIG[HealthCheckInterval]}"

        local output
        output=$(cat "$ACTIVE_OUT_FILE" 2>/dev/null) || true
        if [[ "$output" == *"became unavailable"* ]]; then
            log Error "Resolver became unavailable - connection lost"
            return 1
        fi

        local healthy=false
        local status_code
        status_code=$(curl --proxy "socks5://127.0.0.1:$port" \
            --max-time "${CONFIG[ConnectivityTimeout]}" \
            -s -o /dev/null -w "%{http_code}" \
            "${CONFIG[ConnectivityUrl]}" 2>/dev/null) || true

        if [[ "$status_code" == "204" ]]; then
            healthy=true
        fi

        if [[ "$healthy" == "true" ]]; then
            if [[ $fail_count -gt 0 ]]; then
                log Success "Connection recovered"
            fi
            fail_count=0
        else
            fail_count=$((fail_count + 1))
            log Warning "Health check failed ($fail_count/$max_fails)"
            if [[ $fail_count -ge $max_fails ]]; then
                log Error "Connection lost after $max_fails consecutive failed health checks"
                return 1
            fi
        fi
    done

    log Error "slipstream-client process exited unexpectedly"
    return 1
}

stop_active_connection() {
    if [[ -n "$ACTIVE_PID" ]]; then
        kill "$ACTIVE_PID" 2>/dev/null || true
        wait "$ACTIVE_PID" 2>/dev/null || true
        ACTIVE_PID=""
    fi
    if [[ -n "$ACTIVE_OUT_FILE" && -f "$ACTIVE_OUT_FILE" ]]; then
        rm -f "$ACTIVE_OUT_FILE"
        ACTIVE_OUT_FILE=""
    fi
}

