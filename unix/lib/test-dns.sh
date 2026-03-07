#!/usr/bin/env bash
# lib/test-dns.sh
# Tests DNS resolvers in parallel by spawning slipstream-client and verifying connectivity
#
# Strategy: redirect process output to temp files, poll the files.
#
# Detection logic:
#   - "Connection ready" = tunnel is up (proceed to connectivity check)
#   - "became unavailable" = resolver is dead (FAIL immediately)
#   - Other WARN lines (e.g. cert warnings at startup) are NORMAL and ignored

# Track child PIDs for cleanup
WORKER_PIDS=()

get_random_port() {
    # Find an available port using Python (most portable), or fallback to /dev/urandom
    if command -v python3 &>/dev/null; then
        python3 -c "
import socket
s = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
s.bind(('127.0.0.1', 0))
print(s.getsockname()[1])
s.close()
"
    elif command -v python &>/dev/null; then
        python -c "
import socket
s = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
s.bind(('127.0.0.1', 0))
print(s.getsockname()[1])
s.close()
"
    else
        # Fallback: random port in high range, hope it's free
        echo $(( (RANDOM % 16383) + 49152 ))
    fi
}

test_connectivity() {
    local port="$1"

    # Try primary URL (expect HTTP 204)
    local status_code
    status_code=$(curl --proxy "socks5://127.0.0.1:$port" \
        --max-time "${CONFIG[ConnectivityTimeout]}" \
        -s -o /dev/null -w "%{http_code}" \
        "${CONFIG[ConnectivityUrl]}" 2>/dev/null)

    if [[ "$status_code" == "204" ]]; then
        return 0
    fi

    # Try fallback URL
    local body
    body=$(curl --proxy "socks5://127.0.0.1:$port" \
        --max-time "${CONFIG[ConnectivityTimeout]}" \
        -s "${CONFIG[FallbackUrl]}" 2>/dev/null)

    if [[ "$body" == *"Microsoft Connect Test"* ]]; then
        return 0
    fi

    return 1
}

# Runs a single DNS test in a subshell, writes result to a result file
# This is called as a background process
_test_worker() {
    local dns="$1"
    local exe_path="$2"
    local result_file="$3"

    local port
    port=$(get_random_port)

    local out_file
    out_file=$(mktemp)

    # Start slipstream-client, merge stdout+stderr into temp file
    "$exe_path" \
        --domain "${CONFIG[Domain]}" \
        --congestion-control "${CONFIG[CongestionControl]}" \
        --keep-alive-interval "${CONFIG[KeepAliveInterval]}" \
        --tcp-listen-port "$port" \
        --resolver "$dns" \
        > "$out_file" 2>&1 &

    local slip_pid=$!
    local deadline=$(( $(date +%s) + CONFIG[Timeout] ))

    local connected=false
    while [[ $(date +%s) -lt $deadline ]]; do
        # Check if process died
        if ! kill -0 "$slip_pid" 2>/dev/null; then
            break
        fi

        local output
        output=$(cat "$out_file" 2>/dev/null)

        if [[ "$output" == *"became unavailable"* ]]; then
            kill "$slip_pid" 2>/dev/null; wait "$slip_pid" 2>/dev/null
            rm -f "$out_file"
            echo "FAIL|$dns|$port|Resolver became unavailable" > "$result_file"
            return
        fi

        if [[ "$output" == *"Connection ready"* ]]; then
            connected=true
            break
        fi

        sleep 0.2
    done

    if [[ "$connected" != "true" ]]; then
        kill "$slip_pid" 2>/dev/null; wait "$slip_pid" 2>/dev/null
        rm -f "$out_file"
        echo "FAIL|$dns|$port|Timeout" > "$result_file"
        return
    fi

    # Small delay for proxy to initialize
    sleep 0.5

    # Verify internet
    if test_connectivity "$port"; then
        echo "PASS|$dns|$port|Internet verified" > "$result_file"
    else
        echo "FAIL|$dns|$port|Tunnel up but no internet" > "$result_file"
    fi

    kill "$slip_pid" 2>/dev/null; wait "$slip_pid" 2>/dev/null
    rm -f "$out_file"
}

start_dns_testing() {
    local exe_path="$1"
    local results_dir="$2"

    local working_path="$results_dir/working-dns.txt"
    local failed_path="$results_dir/failed-dns.txt"
    mkdir -p "$results_dir"

    local total=${#DNS_LIST[@]}
    local tested=0
    local dns_index=0
    local max_workers=${CONFIG[Workers]}

    log Info "Starting DNS testing with $max_workers parallel workers..."
    log Info "Testing $total DNS entries (timeout: ${CONFIG[Timeout]}s per entry)"
    echo ""

    # Result temp dir
    local result_dir
    result_dir=$(mktemp -d)

    FOUND_DNS=""
    FOUND_PORT=""

    local -a active_pids=()
    local -a active_result_files=()
    local -a active_dns_names=()

    while [[ $dns_index -lt $total || ${#active_pids[@]} -gt 0 ]]; do
        # Fill worker pool
        while [[ ${#active_pids[@]} -lt $max_workers && $dns_index -lt $total ]]; do
            local dns="${DNS_LIST[$dns_index]}"
            ((dns_index++))

            local result_file="$result_dir/result_${dns_index}.txt"

            _test_worker "$dns" "$exe_path" "$result_file" &
            local wpid=$!
            active_pids+=("$wpid")
            active_result_files+=("$result_file")
            active_dns_names+=("$dns")
            WORKER_PIDS+=("$wpid")
        done

        # Poll active workers
        local -a new_pids=()
        local -a new_files=()
        local -a new_names=()

        for i in "${!active_pids[@]}"; do
            local pid="${active_pids[$i]}"
            local rfile="${active_result_files[$i]}"
            local dname="${active_dns_names[$i]}"

            if [[ -f "$rfile" && -s "$rfile" ]]; then
                # Result is ready
                local result_line
                result_line=$(cat "$rfile")
                local status="${result_line%%|*}"
                local rest="${result_line#*|}"
                local r_dns="${rest%%|*}"; rest="${rest#*|}"
                local r_port="${rest%%|*}"; rest="${rest#*|}"
                local r_detail="$rest"

                wait "$pid" 2>/dev/null
                ((tested++))

                if [[ "$status" == "PASS" ]]; then
                    log Success "FOUND working DNS: $r_dns"
                    local timestamp
                    timestamp=$(date "+%Y-%m-%d %H:%M:%S")
                    echo "$r_dns | $timestamp" >> "$working_path"
                    FOUND_DNS="$r_dns"
                    FOUND_PORT="$r_port"
                    rm -f "$rfile"
                    break 2  # break out of both loops
                else
                    log Debug "FAIL: $r_dns - $r_detail"
                    local timestamp
                    timestamp=$(date "+%Y-%m-%d %H:%M:%S")
                    echo "$r_dns | $timestamp | $r_detail" >> "$failed_path"
                fi

                rm -f "$rfile"
            elif ! kill -0 "$pid" 2>/dev/null; then
                # Process died without writing result
                wait "$pid" 2>/dev/null
                ((tested++))
                log Debug "FAIL: $dname - Process exited"
                rm -f "$rfile"
            else
                # Still running
                new_pids+=("$pid")
                new_files+=("$rfile")
                new_names+=("$dname")
            fi
        done

        active_pids=("${new_pids[@]}")
        active_result_files=("${new_files[@]}")
        active_dns_names=("${new_names[@]}")

        sleep 0.2

        # Progress update
        if [[ $tested -gt 0 && $((tested % max_workers)) -eq 0 ]]; then
            local percent
            percent=$(awk "BEGIN { printf \"%.1f\", ($tested / $total) * 100 }")
            log Info "Progress: $tested / $total ($percent%)"
        fi
    done

    # Cleanup remaining workers
    for pid in "${active_pids[@]}"; do
        kill "$pid" 2>/dev/null
        wait "$pid" 2>/dev/null
    done

    rm -rf "$result_dir"
    WORKER_PIDS=()

    if [[ -z "$FOUND_DNS" && $tested -gt 0 ]]; then
        log Warning "Tested $tested DNS entries, none worked."
    fi
}
