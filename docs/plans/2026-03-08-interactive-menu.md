# Interactive Menu Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Add a boxed launcher menu to SlipStream Auto so users can Connect, Test DNS, Configure, View Results, Clear Results, and get Help from one place.

**Architecture:** New `menu.sh` / `Menu.ps1` library files contain all menu rendering and option handlers. The orchestrators (`slipstream-connect.sh` / `slipstream-connect.ps1`) check for arguments — if none, show the menu loop; if args are present, run the existing flow directly. Menu handlers call into existing library functions (no code duplication).

**Tech Stack:** Bash (Linux/macOS), PowerShell (Windows), no external dependencies

---

### Task 1: Create bash menu library (`unix/lib/menu.sh`)

**Files:**
- Create: `unix/lib/menu.sh`

**Step 1: Create the menu rendering function**

```bash
#!/usr/bin/env bash
# lib/menu.sh
# Interactive launcher menu for SlipStream Auto Connector

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
```

**Step 2: Add the Connect handler**

Connect checks `dns-working.txt` for a previously ranked best DNS. If found, connects directly. If not, runs a full scan first.

```bash
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

    if [[ -z "$FOUND_DNS" ]]; then
        log Error "No working DNS found. Try 'Test DNS' first."
        echo ""
        read -rp "  Press Enter to return to menu..."
        return
    fi

    # Phase 2: Connect and maintain
    echo ""
    log Info "=== Establishing persistent connection ==="

    local reconnect_count=0

    while true; do
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

    echo ""
    read -rp "  Press Enter to return to menu..."
}
```

**Step 3: Add the internal `_menu_scan_all` helper**

Runs the full scan (all tiers) using existing `start_dns_testing`.

```bash
_menu_scan_all() {
    FOUND_DNS=""
    FOUND_PORT=""
    BEST_SCORE=999

    # Phase 1a: Priority DNS
    if [[ $PRIORITY_COUNT -gt 0 ]]; then
        echo ""
        log Info "Testing $PRIORITY_COUNT priority DNS entries first..."
        DNS_LIST=("${FULL_DNS_LIST[@]:0:$PRIORITY_COUNT}")
        start_dns_testing "$EXE_PATH" "$RESULTS_DIR"
    fi

    # Phase 1b: Remaining DNS
    local remaining_count=$(( ${#FULL_DNS_LIST[@]} - PRIORITY_COUNT ))
    if [[ $remaining_count -gt 0 ]]; then
        echo ""
        if [[ -n "$FOUND_DNS" ]]; then
            log Info "Scanning remaining $remaining_count DNS entries for a better match..."
        else
            log Info "Scanning remaining $remaining_count DNS entries..."
        fi
        DNS_LIST=("${FULL_DNS_LIST[@]:$PRIORITY_COUNT}")
        start_dns_testing "$EXE_PATH" "$RESULTS_DIR"
    fi

    if [[ -n "$FOUND_DNS" ]]; then
        echo ""
        log Success "Best DNS: $FOUND_DNS (score: ${BEST_SCORE}s)"
    fi
}
```

**Step 4: Add the Test DNS handler**

Scans tier by tier with a stop reminder. Shows results at end.

```bash
menu_test_dns() {
    echo ""
    log Info "=== Test DNS ==="
    log Info "Scanning all tiers. Press Ctrl+C to stop and keep results so far."
    echo ""

    FOUND_DNS=""
    FOUND_PORT=""
    BEST_SCORE=999

    # Tier 0: Custom DNS
    local tier0_count=0
    # We need to count tier0 separately — it's the custom entries
    # PRIORITY_COUNT = tier0 + tier1, but we don't have tier counts stored
    # Use the full list scanning approach
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
```

**Step 5: Add the Configure handler**

Sub-menu to edit config.ini values interactively.

```bash
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

    # Replace the line matching "key = ..." (preserving inline comments is not critical)
    if grep -q "^[[:space:]]*${key}[[:space:]]*=" "$CONFIG_PATH"; then
        sed -i "s|^[[:space:]]*${key}[[:space:]]*=.*|${key} = ${value}|" "$CONFIG_PATH"
    else
        # Key not in file, append it
        echo "${key} = ${value}" >> "$CONFIG_PATH"
    fi
}
```

**Step 6: Add View Results, Clear Results, and Help handlers**

```bash
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
```

**Step 7: Verify** — Read the complete `menu.sh` file end-to-end, ensure all functions are present and reference existing globals (`CONFIG`, `FOUND_DNS`, `BEST_SCORE`, `FULL_DNS_LIST`, `PRIORITY_COUNT`, `DNS_LIST`, `RESULTS_DIR`, `EXE_PATH`, `CONFIG_PATH`).

---

### Task 2: Modify bash orchestrator to show menu when no args

**Files:**
- Modify: `unix/slipstream-connect.sh`

**Step 1: Add a `--connect` flag and source menu.sh**

After `source "$SCRIPT_DIR/lib/connect.sh"` (line 16), add:
```bash
source "$SCRIPT_DIR/lib/menu.sh"
```

**Step 2: Add `--connect` to argument parsing**

Add to the case block (after `--help`):
```bash
--connect)       FORCE_CONNECT=true; shift ;;
```

And initialize `FORCE_CONNECT=false` with the other arg vars.

**Step 3: Replace the existing Phase 1 + Phase 2 flow with a menu check**

After the DNS list is loaded and `FULL_DNS_LIST` is set, replace the current Phase 1 + Phase 2 code (from `# ── Phase 1: Find a working DNS ──` to the end) with:

```bash
# ── Decide: menu or direct connect ──

# If any operational args were passed, run existing flow directly
if [[ "$FORCE_CONNECT" == "true" || -n "$CONFIG_PATH_ARG" || -n "$DNS_LIST_PATH_ARG" || -n "$CUSTOM_DNS_PATH_ARG" || $WORKERS_OVERRIDE -gt 0 ]]; then
    # Existing Phase 1 + Phase 2 flow (moved into a function or kept inline)
    _run_connect_flow
else
    run_menu_loop
fi
```

**Step 4: Extract existing Phase 1 + Phase 2 into `_run_connect_flow`**

Move the current Phase 1 + Phase 2 code (lines 151–267 approximately) into a function:

```bash
_run_connect_flow() {
    FOUND_DNS=""
    FOUND_PORT=""
    BEST_SCORE=999

    echo ""
    log Info "=== Phase 1: Scanning for a working DNS ==="

    # Phase 1a
    if [[ $PRIORITY_COUNT -gt 0 ]]; then
        echo ""
        log Info "Testing $PRIORITY_COUNT priority DNS entries first..."
        DNS_LIST=("${FULL_DNS_LIST[@]:0:$PRIORITY_COUNT}")
        start_dns_testing "$EXE_PATH" "$RESULTS_DIR"
    fi

    # Phase 1b
    remaining_count=$(( ${#FULL_DNS_LIST[@]} - PRIORITY_COUNT ))
    if [[ $remaining_count -gt 0 ]]; then
        echo ""
        if [[ -n "$FOUND_DNS" ]]; then
            log Info "Scanning remaining $remaining_count DNS entries for a better match..."
        else
            log Info "Scanning remaining $remaining_count DNS entries..."
        fi
        DNS_LIST=("${FULL_DNS_LIST[@]:$PRIORITY_COUNT}")
        start_dns_testing "$EXE_PATH" "$RESULTS_DIR"
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

    echo ""
    log Success "Best DNS: $FOUND_DNS (score: ${BEST_SCORE}s)"

    # Phase 2 (existing code, unchanged)
    echo ""
    log Info "=== Phase 2: Establishing persistent connection ==="

    reconnect_count=0

    while true; do
        # ... (existing reconnect loop, unchanged)
    done

    echo ""
    log Warning "SlipStream Connector has stopped."
}
```

Note: The entire Phase 2 reconnect loop stays as-is inside `_run_connect_flow`. This is a move, not a rewrite.

**Step 5: Track whether args were user-provided**

Currently `CONFIG_PATH=""` is set but then overridden by defaults. We need to know if the user explicitly passed `-c`, `-d`, `-u`, or `-w`. Add tracking variables:

```bash
CONFIG_PATH_ARG=""
DNS_LIST_PATH_ARG=""
CUSTOM_DNS_PATH_ARG=""
```

And in the case block:
```bash
-c|--config)     CONFIG_PATH="$2"; CONFIG_PATH_ARG="$2"; shift 2 ;;
-d|--dns-list)   DNS_LIST_PATH="$2"; DNS_LIST_PATH_ARG="$2"; shift 2 ;;
-u|--user-dns)   CUSTOM_DNS_PATH="$2"; CUSTOM_DNS_PATH_ARG="$2"; shift 2 ;;
```

**Step 6: Verify** — Run `./start.sh` with no args → menu appears. Run `./start.sh -w 10` → old flow runs directly.

---

### Task 3: Create PowerShell menu library (`windows/lib/Menu.ps1`)

**Files:**
- Create: `windows/lib/Menu.ps1`

**Step 1: Create the menu rendering function**

```powershell
# lib/Menu.ps1
# Interactive launcher menu for SlipStream Auto Connector

function Show-MainMenu {
    Write-Host ""
    Write-Host "╔══════════════════════════════════════╗" -ForegroundColor Cyan
    Write-Host "║     SlipStream Auto Connector        ║" -ForegroundColor Cyan
    Write-Host "╠══════════════════════════════════════╣" -ForegroundColor Cyan
    Write-Host "║                                      ║" -ForegroundColor Cyan
    Write-Host "║   " -ForegroundColor Cyan -NoNewline
    Write-Host "[1]" -ForegroundColor Green -NoNewline
    Write-Host "  Connect                       ║" -ForegroundColor Cyan
    Write-Host "║   " -ForegroundColor Cyan -NoNewline
    Write-Host "[2]" -ForegroundColor Green -NoNewline
    Write-Host "  Test DNS                      ║" -ForegroundColor Cyan
    Write-Host "║   " -ForegroundColor Cyan -NoNewline
    Write-Host "[3]" -ForegroundColor Green -NoNewline
    Write-Host "  Configure                     ║" -ForegroundColor Cyan
    Write-Host "║   " -ForegroundColor Cyan -NoNewline
    Write-Host "[4]" -ForegroundColor Green -NoNewline
    Write-Host "  View Results                  ║" -ForegroundColor Cyan
    Write-Host "║   " -ForegroundColor Cyan -NoNewline
    Write-Host "[5]" -ForegroundColor Green -NoNewline
    Write-Host "  Clear Results                 ║" -ForegroundColor Cyan
    Write-Host "║   " -ForegroundColor Cyan -NoNewline
    Write-Host "[6]" -ForegroundColor Green -NoNewline
    Write-Host "  Help                          ║" -ForegroundColor Cyan
    Write-Host "║   " -ForegroundColor Cyan -NoNewline
    Write-Host "[7]" -ForegroundColor Green -NoNewline
    Write-Host "  Exit                          ║" -ForegroundColor Cyan
    Write-Host "║                                      ║" -ForegroundColor Cyan
    Write-Host "╚══════════════════════════════════════╝" -ForegroundColor Cyan
    Write-Host ""
}

function Start-MenuLoop {
    param(
        [hashtable]$Config,
        [string]$ConfigPath,
        [string[]]$DnsList,
        [int]$PriorityCount,
        [string]$ExePath,
        [string]$ResultsDirectory
    )

    while ($true) {
        Show-MainMenu
        $choice = Read-Host "  Choose [1-7]"
        switch ($choice) {
            "1" { Invoke-MenuConnect -Config $Config -DnsList $DnsList -PriorityCount $PriorityCount -ExePath $ExePath -ResultsDirectory $ResultsDirectory }
            "2" { Invoke-MenuTestDns -Config $Config -DnsList $DnsList -PriorityCount $PriorityCount -ExePath $ExePath -ResultsDirectory $ResultsDirectory }
            "3" { Invoke-MenuConfigure -Config $Config -ConfigPath $ConfigPath }
            "4" { Invoke-MenuViewResults -ResultsDirectory $ResultsDirectory }
            "5" { Invoke-MenuClearResults -ResultsDirectory $ResultsDirectory }
            "6" { Invoke-MenuHelp }
            "7" { Write-Host ""; Write-Log -Message "Goodbye." -Level Info; exit 0 }
            default { Write-Host ""; Write-Log -Message "Invalid choice. Please enter 1-7." -Level Warning }
        }
    }
}
```

**Step 2: Add the Connect handler**

```powershell
function Invoke-MenuConnect {
    param(
        [hashtable]$Config,
        [string[]]$DnsList,
        [int]$PriorityCount,
        [string]$ExePath,
        [string]$ResultsDirectory
    )

    Write-Host ""
    Write-Log -Message "=== Connect ===" -Level Info

    $workingPath = Join-Path $ResultsDirectory "dns-working.txt"
    $result = $null

    # Check for previously ranked best DNS
    if (Test-Path $workingPath) {
        $firstLine = Get-Content $workingPath -First 1 -Encoding UTF8
        if ($firstLine) {
            $parts = $firstLine -split '\|'
            $bestDns = $parts[0].Trim()
            $bestScore = if ($parts.Count -ge 3) { $parts[2].Trim() } else { "?" }
            if ($bestDns) {
                Write-Log -Message "Best DNS from last run: $bestDns (score: ${bestScore}s)" -Level Info
                $result = @{ Dns = $bestDns; Port = 0; Score = [double]$bestScore }
            }
        }
    }

    # If no best DNS, run a full scan
    if (-not $result) {
        Write-Log -Message "No previous results found. Running DNS scan first..." -Level Info
        $result = Invoke-FullScan -Config $Config -DnsList $DnsList -PriorityCount $PriorityCount -ExePath $ExePath -ResultsDirectory $ResultsDirectory
    }

    if (-not $result) {
        Write-Log -Message "No working DNS found. Try 'Test DNS' first." -Level Error
        Write-Host ""
        Read-Host "  Press Enter to return to menu"
        return
    }

    # Phase 2: Connect and maintain
    Write-Host ""
    Write-Log -Message "Best DNS: $($result.Dns) (score: $($result.Score)s)" -Level Success
    Write-Host ""
    Write-Log -Message "=== Establishing persistent connection ===" -Level Info

    $reconnectCount = 0
    $workingDns = $result.Dns

    while ($true) {
        if ($Config.MaxReconnectAttempts -gt 0 -and $reconnectCount -ge $Config.MaxReconnectAttempts) {
            Write-Log -Message "Max reconnect attempts ($($Config.MaxReconnectAttempts)) reached." -Level Error
            break
        }

        $port = Get-RandomPort

        if ($reconnectCount -eq 0) {
            Write-Log -Message "Connecting via $workingDns on port $port..." -Level Info
        } else {
            Write-Host ""
            Write-Log -Message "Reconnecting (attempt $reconnectCount) via $workingDns on port $port..." -Level Warning
        }

        $connection = Start-SlipstreamConnection -Dns $workingDns -Port $port -Config $Config -ExePath $ExePath

        if ($null -ne $connection) {
            Start-Sleep -Milliseconds 500
            $internetWorks = $false
            try {
                $statusCode = & curl.exe --proxy "socks5://127.0.0.1:$port" `
                    --max-time $Config.ConnectivityTimeout `
                    -s -o NUL -w "%{http_code}" `
                    $Config.ConnectivityUrl 2>$null
                if ($statusCode -eq "204") { $internetWorks = $true }
            } catch {}

            if ($internetWorks) {
                $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
                Add-Content -Path $workingPath -Value "$workingDns | $timestamp" -Encoding UTF8
                $stillAlive = Watch-Connection -Connection $connection -Port $port -Config $Config
                Stop-Connection -Connection $connection
            } else {
                Write-Log -Message "Tunnel up via $workingDns but no internet" -Level Warning
                Stop-Connection -Connection $connection
            }
        } else {
            Write-Log -Message "Failed to connect via $workingDns" -Level Warning
        }

        $reconnectCount++
        Write-Host ""
        Write-Log -Message "Connection lost. Re-scanning..." -Level Warning

        $result = Invoke-FullScan -Config $Config -DnsList $DnsList -PriorityCount $PriorityCount -ExePath $ExePath -ResultsDirectory $ResultsDirectory

        if (-not $result) {
            Write-Log -Message "No working DNS found after re-scanning." -Level Error
            break
        }

        $workingDns = $result.Dns
    }

    Write-Host ""
    Read-Host "  Press Enter to return to menu"
}
```

**Step 3: Add `Invoke-FullScan` helper**

```powershell
function Invoke-FullScan {
    param(
        [hashtable]$Config,
        [string[]]$DnsList,
        [int]$PriorityCount,
        [string]$ExePath,
        [string]$ResultsDirectory
    )

    $result = $null

    if ($PriorityCount -gt 0) {
        Write-Host ""
        Write-Log -Message "Testing $PriorityCount priority DNS entries first..." -Level Info
        $priorityList = @($DnsList[0..($PriorityCount - 1)])
        $result = Start-DnsTesting -DnsList $priorityList -Config $Config -ExePath $ExePath -ResultsDirectory $ResultsDirectory
    }

    $remainingCount = $DnsList.Count - $PriorityCount
    if ($remainingCount -gt 0) {
        Write-Host ""
        if ($result) {
            Write-Log -Message "Scanning remaining $remainingCount DNS entries for a better match..." -Level Info
        } else {
            Write-Log -Message "Scanning remaining $remainingCount DNS entries..." -Level Info
        }
        $remainingList = @($DnsList[$PriorityCount..($DnsList.Count - 1)])
        $newResult = Start-DnsTesting -DnsList $remainingList -Config $Config -ExePath $ExePath -ResultsDirectory $ResultsDirectory
        if ($newResult -and ($null -eq $result -or $newResult.Score -lt $result.Score)) {
            $result = $newResult
        }
    }

    return $result
}
```

**Step 4: Add Test DNS, Configure, View Results, Clear Results, Help handlers**

```powershell
function Invoke-MenuTestDns {
    param(
        [hashtable]$Config,
        [string[]]$DnsList,
        [int]$PriorityCount,
        [string]$ExePath,
        [string]$ResultsDirectory
    )

    Write-Host ""
    Write-Log -Message "=== Test DNS ===" -Level Info
    Write-Log -Message "Scanning all tiers. Press Ctrl+C to stop and keep results so far." -Level Info

    $result = Invoke-FullScan -Config $Config -DnsList $DnsList -PriorityCount $PriorityCount -ExePath $ExePath -ResultsDirectory $ResultsDirectory

    Write-Host ""
    if ($result) {
        Write-Log -Message "Best DNS: $($result.Dns) (score: $($result.Score)s)" -Level Success
    } else {
        Write-Log -Message "No working DNS found." -Level Warning
    }

    Show-ResultsSummary -ResultsDirectory $ResultsDirectory

    Write-Host ""
    Read-Host "  Press Enter to return to menu"
}

function Invoke-MenuConfigure {
    param(
        [hashtable]$Config,
        [string]$ConfigPath
    )

    while ($true) {
        Write-Host ""
        Write-Log -Message "=== Configure ===" -Level Info
        Write-Host ""
        Write-Host "  " -NoNewline; Write-Host "[1]" -ForegroundColor Green -NoNewline; Write-Host " Domain:                $($Config.Domain)"
        Write-Host "  " -NoNewline; Write-Host "[2]" -ForegroundColor Green -NoNewline; Write-Host " Workers:               $($Config.Workers)"
        Write-Host "  " -NoNewline; Write-Host "[3]" -ForegroundColor Green -NoNewline; Write-Host " Timeout:               $($Config.Timeout)s"
        Write-Host "  " -NoNewline; Write-Host "[4]" -ForegroundColor Green -NoNewline; Write-Host " Health Check Interval:  $($Config.HealthCheckInterval)s"
        Write-Host "  " -NoNewline; Write-Host "[5]" -ForegroundColor Green -NoNewline; Write-Host " Max Reconnect Attempts: $($Config.MaxReconnectAttempts)"
        Write-Host "  " -NoNewline; Write-Host "[6]" -ForegroundColor Green -NoNewline; Write-Host " Prioritize Known Good:  $($Config.PrioritizeKnownGood)"
        Write-Host "  " -NoNewline; Write-Host "[7]" -ForegroundColor Green -NoNewline; Write-Host " Skip Previously Failed: $($Config.SkipPreviouslyFailed)"
        Write-Host "  " -NoNewline; Write-Host "[8]" -ForegroundColor Green -NoNewline; Write-Host " Back to main menu"
        Write-Host ""
        $choice = Read-Host "  Choose [1-8]"

        $key = switch ($choice) {
            "1" { "Domain" }
            "2" { "Workers" }
            "3" { "Timeout" }
            "4" { "HealthCheckInterval" }
            "5" { "MaxReconnectAttempts" }
            "6" { "PrioritizeKnownGood" }
            "7" { "SkipPreviouslyFailed" }
            "8" { return }
            default { Write-Log -Message "Invalid choice." -Level Warning; continue }
        }

        Write-Host ""
        $newValue = Read-Host "  New value for $key [$($Config[$key])]"
        if ([string]::IsNullOrWhiteSpace($newValue)) {
            Write-Log -Message "No change." -Level Info
            continue
        }

        # Update in-memory config
        $existing = $Config[$key]
        if ($existing -is [int]) { $Config[$key] = [int]$newValue }
        elseif ($existing -is [bool]) { $Config[$key] = $newValue -eq 'true' }
        else { $Config[$key] = $newValue }

        # Update config file
        Update-ConfigFile -ConfigPath $ConfigPath -Key $key -Value $newValue
        Write-Log -Message "Updated $key = $newValue" -Level Success
    }
}

function Update-ConfigFile {
    param(
        [string]$ConfigPath,
        [string]$Key,
        [string]$Value
    )

    if (-not (Test-Path $ConfigPath)) {
        Write-Log -Message "Config file not found, cannot save." -Level Warning
        return
    }

    $lines = Get-Content $ConfigPath -Encoding UTF8
    $found = $false
    $newLines = @()
    foreach ($line in $lines) {
        if ($line -match "^\s*$Key\s*=") {
            $newLines += "$Key = $Value"
            $found = $true
        } else {
            $newLines += $line
        }
    }
    if (-not $found) {
        $newLines += "$Key = $Value"
    }
    $newLines | Set-Content $ConfigPath -Encoding UTF8
}

function Show-ResultsSummary {
    param([string]$ResultsDirectory)

    $workingPath = Join-Path $ResultsDirectory "dns-working.txt"
    $failedPath = Join-Path $ResultsDirectory "dns-failed.txt"

    if (Test-Path $workingPath) {
        $lines = @(Get-Content $workingPath -Encoding UTF8 | Where-Object { $_.Trim() -ne '' })
        if ($lines.Count -gt 0) {
            Write-Host ""
            Write-Log -Message "Top working DNS (by score):" -Level Info
            Write-Host ""
            $count = 0
            foreach ($line in $lines) {
                $parts = $line -split '\|'
                $dns = $parts[0].Trim()
                $timestamp = if ($parts.Count -ge 2) { $parts[1].Trim() } else { "" }
                $score = if ($parts.Count -ge 3) { $parts[2].Trim() } else { "?" }
                $count++
                Write-Host ("  {0,2}. {1,-20}  score: {2}s  ({3})" -f $count, $dns, $score, $timestamp)
                if ($count -ge 10) { break }
            }
            if ($lines.Count -gt 10) {
                Write-Host "  ... and $($lines.Count - 10) more"
            }
        }
    } else {
        Write-Host ""
        Write-Log -Message "No working DNS results yet. Run 'Test DNS' first." -Level Info
    }

    if (Test-Path $failedPath) {
        $failedCount = @(Get-Content $failedPath -Encoding UTF8 | Where-Object { $_.Trim() -ne '' }).Count
        Write-Host ""
        Write-Log -Message "Failed DNS entries: $failedCount" -Level Info
    }
}

function Invoke-MenuViewResults {
    param([string]$ResultsDirectory)

    Write-Host ""
    Write-Log -Message "=== Results ===" -Level Info
    Show-ResultsSummary -ResultsDirectory $ResultsDirectory

    $logPath = Join-Path $ResultsDirectory "session.log"
    if (Test-Path $logPath) {
        $firstLine = Get-Content $logPath -First 1 -Encoding UTF8
        Write-Host ""
        Write-Log -Message "Last session: $firstLine" -Level Info
    }

    Write-Host ""
    Read-Host "  Press Enter to return to menu"
}

function Invoke-MenuClearResults {
    param([string]$ResultsDirectory)

    Write-Host ""
    Write-Log -Message "This will delete dns-working.txt and dns-failed.txt." -Level Warning
    $confirm = Read-Host "  Are you sure? (y/n)"
    if ($confirm -eq 'y') {
        Remove-Item (Join-Path $ResultsDirectory "dns-working.txt") -Force -ErrorAction SilentlyContinue
        Remove-Item (Join-Path $ResultsDirectory "dns-failed.txt") -Force -ErrorAction SilentlyContinue
        Write-Log -Message "Results cleared." -Level Success
    } else {
        Write-Log -Message "Cancelled." -Level Info
    }

    Write-Host ""
    Read-Host "  Press Enter to return to menu"
}

function Invoke-MenuHelp {
    Write-Host @"

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
    -ConfigPath <path>    Path to config.ini
    -DnsListPath <path>   Path to dns-list.txt
    -UserDnsPath <path>   Path to your own DNS file
    -Workers <number>     Override parallel worker count
    -Help                 Show CLI help

  EXAMPLES:
    .\start.bat                  Open interactive menu
    .\start.bat -Workers 10      Bypass menu, connect with 10 workers

"@
    Read-Host "  Press Enter to return to menu"
}
```

**Step 5: Verify** — Read complete `Menu.ps1`, ensure all functions present and reference correct parameter names.

---

### Task 4: Modify PowerShell orchestrator to show menu when no args

**Files:**
- Modify: `windows/slipstream-connect.ps1`

**Step 1: Source Menu.ps1**

After `. (Join-Path $scriptRoot "lib\Connect.ps1")` (line 22), add:
```powershell
. (Join-Path $scriptRoot "lib\Menu.ps1")
```

**Step 2: Add `--connect` switch and detect if args were passed**

Add to the param block:
```powershell
[switch]$Connect
```

**Step 3: After DNS list loading, decide menu or direct flow**

Replace everything from `# ── Initialize temp directory` to the end with a conditional:

```powershell
# ── Initialize temp directory (clean stale files from previous runs) ──
Initialize-SlipstreamTempDir

# ── Decide: menu or direct connect ──
$hasOperationalArgs = $Connect -or $ConfigPath -or $DnsListPath -or $UserDnsPath -or ($Workers -gt 0)

if (-not $hasOperationalArgs) {
    # Show interactive menu
    # Set up cleanup for Ctrl+C
    $cleanupBlock = {
        Write-Host ""
        Write-Host "Shutting down..." -ForegroundColor Yellow
        Get-Process -Name "slipstream-client" -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
        Remove-SlipstreamTempDir
        Write-Host "Goodbye." -ForegroundColor Cyan
    }
    $null = Register-EngineEvent -SourceIdentifier PowerShell.Exiting -Action $cleanupBlock -ErrorAction SilentlyContinue
    trap { & $cleanupBlock; break }

    try {
        Start-MenuLoop -Config $config -ConfigPath $ConfigPath_Resolved -DnsList $dnsList -PriorityCount $priorityCount -ExePath $exePath -ResultsDirectory $resultsDir
    }
    finally {
        Get-Process -Name "slipstream-client" -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
        Remove-SlipstreamTempDir
    }
} else {
    # Existing direct connect flow (current code)
    ...
}
```

Note: We need to store the resolved config path before the menu check since `$ConfigPath` from the param block may be empty. Add after config is loaded:
```powershell
$ConfigPath_Resolved = $ConfigPath
if (-not $ConfigPath_Resolved) { $ConfigPath_Resolved = Join-Path $projectRoot "config.ini" }
```

Wait — looking at the current code, `$ConfigPath` is set to `""` by default, then resolved at line 54: `if (-not $ConfigPath) { $ConfigPath = Join-Path $projectRoot "config.ini" }`. So `$ConfigPath` is always populated after line 54. But to detect whether the user passed it, we need to check before the default is applied. Best approach: check `$PSBoundParameters`:

```powershell
$hasOperationalArgs = $Connect -or $PSBoundParameters.ContainsKey('ConfigPath') -or $PSBoundParameters.ContainsKey('DnsListPath') -or $PSBoundParameters.ContainsKey('UserDnsPath') -or ($Workers -gt 0)
```

This correctly detects whether the user explicitly passed flags.

**Step 4: Verify** — Run `start.bat` with no args → menu appears. Run `start.bat -Workers 10` → old flow runs directly.

---

### Task 5: Build and test Windows release package

**Step 1: Kill any running processes**
```bash
taskkill //F //IM slipstream-client.exe 2>/dev/null
```

**Step 2: Build release package**
```bash
rm -rf dist && mkdir -p dist/slipstream-auto-windows/lib
cp windows/start.bat windows/slipstream-connect.ps1 dist/slipstream-auto-windows/
cp windows/lib/*.ps1 dist/slipstream-auto-windows/lib/
cp config.ini dns-list.txt dist/slipstream-auto-windows/
cp slipstream-client.exe dist/slipstream-auto-windows/slipstream-client.exe
sed -i 's|Split-Path $scriptRoot -Parent|$scriptRoot|' dist/slipstream-auto-windows/slipstream-connect.ps1
sed -i 's/Domain = example.com/Domain = s.begaraftim.shop/' dist/slipstream-auto-windows/config.ini
```

**Step 3: Launch start.bat**
```bash
explorer.exe "C:\Users\Ali\Downloads\VPN\dist\slipstream-auto-windows\start.bat"
```

**Step 4: Verify menu appears** — Ask user to confirm they see the boxed menu.

**Step 5: Test each option**
- Select 4 (View Results) — should show results or "no results"
- Select 3 (Configure) — should show settings, change Domain back
- Select 6 (Help) — should show help text
- Select 2 (Test DNS) — should scan and show results
- Select 1 (Connect) — should connect using best DNS
- Select 5 (Clear Results) — should prompt and clear
- Select 7 (Exit) — should exit

---

### Task 6: Test bash in WSL

**Step 1: Fix line endings**
```bash
wsl bash -c "cd /mnt/c/Users/Ali/Downloads/VPN && sed -i 's/\r$//' unix/lib/menu.sh unix/lib/test-dns.sh unix/lib/logger.sh unix/lib/config.sh unix/lib/connect.sh unix/slipstream-connect.sh unix/start.sh && chmod +x unix/*.sh unix/lib/*.sh slipstream-client"
```

**Step 2: Set domain for testing**
```bash
sed -i 's/Domain = example.com/Domain = s.begaraftim.shop/' config.ini
```

**Step 3: Run start.sh with no args**
```bash
wsl bash -c "cd /mnt/c/Users/Ali/Downloads/VPN && bash unix/start.sh"
```

**Step 4: Verify menu appears and test options** — Same as Task 5 verification.

**Step 5: Restore domain**
```bash
sed -i 's/Domain = s.begaraftim.shop/Domain = example.com/' config.ini
```

---

### Task 7: Commit and create PR

**Step 1: Stage files**
```bash
git add unix/lib/menu.sh windows/lib/Menu.ps1 unix/slipstream-connect.sh windows/slipstream-connect.ps1
```

**Step 2: Commit**
```bash
git commit -m "feat: add interactive launcher menu with Connect, Test DNS, Configure, View Results"
```

**Step 3: Push and create PR**
```bash
git push origin feature/dns-ranking
gh pr create --title "feat: interactive launcher menu" --body "..."
```
