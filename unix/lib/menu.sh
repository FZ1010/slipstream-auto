#!/usr/bin/env bash
# lib/menu.sh
# Interactive launcher menu for SlipStream Auto Connector

MENU_INTERRUPTED=false

_menu_interrupt() {
    MENU_INTERRUPTED=true
    # Kill background worker processes
    if [[ ${#WORKER_PIDS[@]} -gt 0 ]]; then
        for pid in "${WORKER_PIDS[@]}"; do
            kill "$pid" 2>/dev/null || true
        done
        WORKER_PIDS=()
    fi
    # Kill active connection
    stop_active_connection
    echo ""
    log Warning "Interrupted. Returning to menu..."
}

show_main_menu() {
    echo ""
    echo -e "\033[36m╔══════════════════════════════════════╗"
    echo -e "║     SlipStream Auto Connector        ║"
    echo -e "╠══════════════════════════════════════╣"
    echo -e "║                                      ║"
    echo -e "║   \033[32m[1]\033[36m  Connect                       ║"
    echo -e "║   \033[32m[2]\033[36m  Test DNS                      ║"
    echo -e "║   \033[32m[3]\033[36m  Configure                     ║"
    echo -e "║   \033[32m[4]\033[36m  View Results                  ║"
    echo -e "║   \033[32m[5]\033[36m  Clear Results                 ║"
    echo -e "║   \033[32m[6]\033[36m  Help                          ║"
    echo -e "║   \033[32m[7]\033[36m  Exit                          ║"
    echo -e "║                                      ║"
    echo -e "╚══════════════════════════════════════╝\033[0m"
    echo ""
}

run_menu_loop() {
    while true; do
        MENU_INTERRUPTED=false
        trap '_menu_interrupt' INT
        show_main_menu
        read -rp "  Choose [1-7]: " choice
        case "$choice" in
            1) menu_connect ;;
            2) menu_test_dns ;;
            3) menu_configure ;;
            4) menu_view_results ;;
            5) menu_clear_results ;;
            6) menu_help ;;
            7) echo ""; log Info "Goodbye."; exit 0 ;;
            *) echo ""; log Warning "Invalid choice. Please enter 1-7." ;;
        esac
    done
}

menu_connect() {
    echo ""
    log Info "=== Connect ==="

    local working_path="$RESULTS_DIR/dns-working.txt"

    # Check for previously ranked best DNS
    if [[ -f "$working_path" && -s "$working_path" ]]; then
        local best_line
        best_line=$(head -1 "$working_path")
        local best_dns
        best_dns=$(echo "$best_line" | cut -d'|' -f1 | tr -d ' ')
        local best_score
        best_score=$(echo "$best_line" | cut -d'|' -f3 | tr -d ' ')

        if [[ -n "$best_dns" ]]; then
            log Info "Best DNS from last run: $best_dns (score: ${best_score:-?}s)"
            FOUND_DNS="$best_dns"
            FOUND_PORT=""
        fi
    fi

    # If no best DNS, run a full scan
    if [[ -z "$FOUND_DNS" ]]; then
        log Info "No previous results found. Running DNS scan first..."
        _menu_scan_all
    fi

    if [[ "$MENU_INTERRUPTED" == "true" ]]; then return; fi

    if [[ -z "$FOUND_DNS" ]]; then
        log Error "No working DNS found. Try 'Test DNS' first."
        echo ""
        read -rp "  Press Enter to return to menu..."
        return
    fi

    # Phase 2: Connect and maintain
    echo ""
    log Info "=== Establishing persistent connection ==="
    log Info "Press Ctrl+C to disconnect and return to menu."

    local reconnect_count=0

    while true; do
        if [[ "$MENU_INTERRUPTED" == "true" ]]; then break; fi

        if [[ ${CONFIG[MaxReconnectAttempts]} -gt 0 && $reconnect_count -ge ${CONFIG[MaxReconnectAttempts]} ]]; then
            log Error "Max reconnect attempts (${CONFIG[MaxReconnectAttempts]}) reached."
            break
        fi

        local port
        port=$(get_random_port)

        if [[ $reconnect_count -eq 0 ]]; then
            log Info "Connecting via $FOUND_DNS on port $port..."
        else
            echo ""
            log Warning "Reconnecting (attempt $reconnect_count) via $FOUND_DNS on port $port..."
        fi

        if start_slipstream_connection "$FOUND_DNS" "$port" "$EXE_PATH"; then
            sleep 0.5
            local status_code
            status_code=$(curl --proxy "socks5://127.0.0.1:$port" \
                --max-time "${CONFIG[ConnectivityTimeout]}" \
                -s -o /dev/null -w "%{http_code}" \
                "${CONFIG[ConnectivityUrl]}" 2>/dev/null) || true

            if [[ "$status_code" == "204" ]]; then
                local timestamp
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

        if [[ "$MENU_INTERRUPTED" == "true" ]]; then break; fi

        reconnect_count=$((reconnect_count + 1))
        echo ""
        log Warning "Connection lost. Re-scanning..."

        FOUND_DNS=""
        FOUND_PORT=""
        BEST_SCORE=999
        _menu_scan_all

        if [[ -z "$FOUND_DNS" ]]; then
            log Error "No working DNS found after re-scanning."
            break
        fi
    done
}

_menu_scan_all() {
    FOUND_DNS=""
    FOUND_PORT=""
    BEST_SCORE=999
    STOP_AFTER_FOUND=true

    # Phase 1a: Priority DNS
    if [[ $PRIORITY_COUNT -gt 0 ]]; then
        echo ""
        log Info "Testing $PRIORITY_COUNT priority DNS entries first..."
        DNS_LIST=("${FULL_DNS_LIST[@]:0:$PRIORITY_COUNT}")
        start_dns_testing "$EXE_PATH" "$RESULTS_DIR"
    fi

    # Skip remaining if we already found one (Connect mode stops early)
    if [[ -n "$FOUND_DNS" ]]; then
        echo ""
        log Success "Best DNS: $FOUND_DNS (score: ${BEST_SCORE}s)"
        return
    fi

    # Phase 1b: Remaining DNS
    local remaining_count=$(( ${#FULL_DNS_LIST[@]} - PRIORITY_COUNT ))
    if [[ $remaining_count -gt 0 ]]; then
        echo ""
        log Info "Scanning $remaining_count DNS entries..."
        DNS_LIST=("${FULL_DNS_LIST[@]:$PRIORITY_COUNT}")
        start_dns_testing "$EXE_PATH" "$RESULTS_DIR"
    fi

    if [[ -n "$FOUND_DNS" ]]; then
        echo ""
        log Success "Best DNS: $FOUND_DNS (score: ${BEST_SCORE}s)"
    fi
}

menu_test_dns() {
    echo ""
    log Info "=== Test DNS ==="
    log Info "Scanning all tiers. Press Ctrl+C to stop and keep results so far."
    echo ""

    FOUND_DNS=""
    FOUND_PORT=""
    BEST_SCORE=999
    STOP_AFTER_FOUND=false

    if [[ $PRIORITY_COUNT -gt 0 ]]; then
        log Info "Testing $PRIORITY_COUNT priority DNS entries (tier 0 + tier 1)..."
        DNS_LIST=("${FULL_DNS_LIST[@]:0:$PRIORITY_COUNT}")
        start_dns_testing "$EXE_PATH" "$RESULTS_DIR"
    fi

    local remaining_count=$(( ${#FULL_DNS_LIST[@]} - PRIORITY_COUNT ))
    if [[ $remaining_count -gt 0 ]]; then
        echo ""
        log Info "Testing remaining $remaining_count DNS entries (tier 2)..."
        log Info "Press Ctrl+C anytime to stop scanning."
        echo ""
        DNS_LIST=("${FULL_DNS_LIST[@]:$PRIORITY_COUNT}")
        start_dns_testing "$EXE_PATH" "$RESULTS_DIR"
    fi

    # Show results
    echo ""
    if [[ -n "$FOUND_DNS" ]]; then
        log Success "Best DNS: $FOUND_DNS (score: ${BEST_SCORE}s)"
    else
        log Warning "No working DNS found."
    fi

    _show_results_summary

    echo ""
    read -rp "  Press Enter to return to menu..."
}

menu_configure() {
    while true; do
        echo ""
        log Info "=== Configure ==="
        echo ""
        echo -e "  \033[32m[1]\033[0m Domain:                ${CONFIG[Domain]}"
        echo -e "  \033[32m[2]\033[0m Workers:               ${CONFIG[Workers]}"
        echo -e "  \033[32m[3]\033[0m Timeout:               ${CONFIG[Timeout]}s"
        echo -e "  \033[32m[4]\033[0m Health Check Interval:  ${CONFIG[HealthCheckInterval]}s"
        echo -e "  \033[32m[5]\033[0m Max Reconnect Attempts: ${CONFIG[MaxReconnectAttempts]}"
        echo -e "  \033[32m[6]\033[0m Prioritize Known Good:  ${CONFIG[PrioritizeKnownGood]}"
        echo -e "  \033[32m[7]\033[0m Skip Previously Failed: ${CONFIG[SkipPreviouslyFailed]}"
        echo -e "  \033[32m[8]\033[0m Back to main menu"
        echo ""
        read -rp "  Choose [1-8]: " choice

        local key=""
        case "$choice" in
            1) key="Domain" ;;
            2) key="Workers" ;;
            3) key="Timeout" ;;
            4) key="HealthCheckInterval" ;;
            5) key="MaxReconnectAttempts" ;;
            6) key="PrioritizeKnownGood" ;;
            7) key="SkipPreviouslyFailed" ;;
            8) return ;;
            *) log Warning "Invalid choice."; continue ;;
        esac

        echo ""
        read -rp "  New value for $key [${CONFIG[$key]}]: " new_value
        if [[ -z "$new_value" ]]; then
            log Info "No change."
            continue
        fi

        CONFIG[$key]="$new_value"
        _update_config_file "$key" "$new_value"
        log Success "Updated $key = $new_value"
    done
}

_update_config_file() {
    local key="$1"
    local value="$2"

    if [[ ! -f "$CONFIG_PATH" ]]; then
        log Warning "Config file not found, cannot save."
        return
    fi

    # Replace the line matching "key = ..."
    if grep -q "^[[:space:]]*${key}[[:space:]]*=" "$CONFIG_PATH"; then
        sed -i "s|^[[:space:]]*${key}[[:space:]]*=.*|${key} = ${value}|" "$CONFIG_PATH"
    else
        # Key not in file, append it
        echo "${key} = ${value}" >> "$CONFIG_PATH"
    fi
}

_show_results_summary() {
    local working_path="$RESULTS_DIR/dns-working.txt"
    local failed_path="$RESULTS_DIR/dns-failed.txt"

    if [[ -f "$working_path" && -s "$working_path" ]]; then
        echo ""
        log Info "Top working DNS (by score):"
        echo ""
        local count=0
        while IFS='|' read -r dns timestamp score; do
            dns=$(echo "$dns" | tr -d ' ')
            score=$(echo "$score" | tr -d ' ')
            timestamp=$(echo "$timestamp" | tr -d ' ')
            count=$((count + 1))
            printf "  \033[32m%2d.\033[0m %-20s  score: %ss  (%s)\n" "$count" "$dns" "$score" "$timestamp"
            [[ $count -ge 10 ]] && break
        done < "$working_path"

        local total_working
        total_working=$(wc -l < "$working_path")
        if [[ $total_working -gt 10 ]]; then
            echo "  ... and $((total_working - 10)) more"
        fi
    else
        echo ""
        log Info "No working DNS results yet. Run 'Test DNS' first."
    fi

    if [[ -f "$failed_path" ]]; then
        local total_failed
        total_failed=$(wc -l < "$failed_path")
        echo ""
        log Info "Failed DNS entries: $total_failed"
    fi
}

menu_view_results() {
    echo ""
    log Info "=== Results ==="
    _show_results_summary

    # Last session info
    local log_path="$RESULTS_DIR/session.log"
    if [[ -f "$log_path" ]]; then
        local first_line
        first_line=$(head -1 "$log_path")
        echo ""
        log Info "Last session: $first_line"
    fi

    echo ""
    read -rp "  Press Enter to return to menu..."
}

menu_clear_results() {
    echo ""
    log Warning "This will delete dns-working.txt and dns-failed.txt."
    read -rp "  Are you sure? (y/n): " confirm
    if [[ "${confirm,,}" == "y" ]]; then
        rm -f "$RESULTS_DIR/dns-working.txt" "$RESULTS_DIR/dns-failed.txt"
        log Success "Results cleared."
    else
        log Info "Cancelled."
    fi
    echo ""
    read -rp "  Press Enter to return to menu..."
}

menu_help() {
    echo ""
    cat << 'HELP'
  SlipStream Auto Connector - Help

  MENU OPTIONS:
    Connect          Connect using best known DNS, or scan first if none
    Test DNS         Scan all DNS tiers and rank by speed
    Configure        Edit config.ini settings interactively
    View Results     Show top working DNS and failed counts
    Clear Results    Delete dns-working.txt and dns-failed.txt
    Help             This message
    Exit             Quit

  CLI FLAGS (bypass menu):
    -c, --config <path>     Path to config.ini
    -d, --dns-list <path>   Path to dns-list.txt
    -u, --user-dns <path>   Path to your own DNS file
    -w, --workers <number>  Override parallel worker count
    -h, --help              Show CLI help

  EXAMPLES:
    ./start.sh                  Open interactive menu
    ./start.sh -w 10            Bypass menu, connect with 10 workers
    ./start.sh -u my-dns.txt    Bypass menu, use custom DNS list

HELP
    read -rp "  Press Enter to return to menu..."
}
