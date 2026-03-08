# DNS Ranking Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Rank DNS resolvers by speed (establishment time + connectivity latency) so the script picks the fastest working DNS, not just the first one found.

**Architecture:** Measure two timestamps already available in the test loop (tunnel establishment time, curl response time), combine into a score, scan all DNS without stopping early, track the best, and keep `dns-working.txt` sorted by score (best first). On next run, tier 1 loads them in best-first order automatically.

**Tech Stack:** Bash (Linux/macOS), PowerShell (Windows), curl `-w` for timing

---

### Task 1: Add timing to bash `_test_worker`

**Files:**
- Modify: `unix/lib/test-dns.sh` — `_test_worker` function (lines 62-128)

**Step 1: Record start time before spawning slipstream-client**

At line 68 (after `port=$(get_random_port)`), add:

```bash
local start_time=$(date +%s)
```

**Step 2: Compute establishment time when "Connection ready" is detected**

At line 101-103, after `connected=true`, add:

```bash
if [[ "$output" == *"Connection ready"* ]]; then
    connected=true
    local establish_time=$(( $(date +%s) - start_time ))
    break
fi
```

**Step 3: Timed connectivity check with curl latency**

Replace lines 119-123 (the `test_connectivity` call and result writing) with a timed curl that captures both HTTP status and response time:

```bash
local curl_result
curl_result=$(curl --proxy "socks5://127.0.0.1:$port" \
    --max-time "${CONFIG[ConnectivityTimeout]}" \
    -s -o /dev/null -w "%{http_code}|%{time_total}" \
    "${CONFIG[ConnectivityUrl]}" 2>/dev/null) || true

local curl_status="${curl_result%%|*}"
local curl_latency="${curl_result#*|}"

if [[ "$curl_status" == "204" ]]; then
    local score
    score=$(awk "BEGIN { printf \"%.1f\", $establish_time + $curl_latency }")
    echo "PASS|$dns|$port|$score" > "$result_file"
else
    # Try fallback URL
    local body
    body=$(curl --proxy "socks5://127.0.0.1:$port" \
        --max-time "${CONFIG[ConnectivityTimeout]}" \
        -s "${CONFIG[FallbackUrl]}" 2>/dev/null) || true
    if [[ "$body" == *"Microsoft Connect Test"* ]]; then
        local score
        score=$(awk "BEGIN { printf \"%.1f\", $establish_time + $curl_latency }")
        echo "PASS|$dns|$port|$score" > "$result_file"
    else
        echo "FAIL|$dns|$port|Tunnel up but no internet" > "$result_file"
    fi
fi
```

Note: This replaces the `test_connectivity` call with inline curl so we can capture timing. The `test_connectivity` function is no longer used by `_test_worker` (still used elsewhere, so don't delete it).

**Step 4: Verify** — Read the modified function end-to-end, ensure result format is `PASS|dns|port|score` or `FAIL|dns|port|reason`.

---

### Task 2: Add `_save_working_dns` helper to bash `test-dns.sh`

**Files:**
- Modify: `unix/lib/test-dns.sh` — add helper function before `start_dns_testing`

**Step 1: Add the helper function**

Add before `start_dns_testing()`:

```bash
_save_working_dns() {
    local dns="$1"
    local score="$2"
    local working_path="$3"

    local timestamp
    timestamp=$(date "+%Y-%m-%d %H:%M:%S")

    # Remove existing entry for this DNS (if any)
    if [[ -f "$working_path" ]]; then
        grep -v "^${dns} |" "$working_path" > "${working_path}.tmp" 2>/dev/null || true
        mv "${working_path}.tmp" "$working_path"
    fi

    # Append new entry
    echo "$dns | $timestamp | $score" >> "$working_path"

    # Sort by score (3rd field, numeric ascending = best first)
    sort -t'|' -k3 -g "$working_path" -o "$working_path"
}
```

---

### Task 3: Modify bash `start_dns_testing` to rank instead of stop early

**Files:**
- Modify: `unix/lib/test-dns.sh` — `start_dns_testing` function (lines 130-255)

**Step 1: Remove FOUND_DNS/FOUND_PORT reset**

Remove lines 150-151:
```bash
FOUND_DNS=""
FOUND_PORT=""
```

The caller now controls initialization. This allows accumulation across Phase 1a and 1b.

**Step 2: Replace the PASS handler (lines 195-203)**

Replace the current PASS block:
```bash
if [[ "$status" == "PASS" ]]; then
    log Success "FOUND working DNS: $r_dns"
    local timestamp
    timestamp=$(date "+%Y-%m-%d %H:%M:%S")
    echo "$r_dns | $timestamp" >> "$working_path"
    FOUND_DNS="$r_dns"
    FOUND_PORT="$r_port"
    rm -f "$rfile"
    break 2
```

With ranking logic (no `break 2` — continues scanning):
```bash
if [[ "$status" == "PASS" ]]; then
    local r_score="$r_detail"
    _save_working_dns "$r_dns" "$r_score" "$working_path"

    if [[ -z "$FOUND_DNS" ]]; then
        log Success "FOUND working DNS: $r_dns (score: ${r_score}s)"
        FOUND_DNS="$r_dns"
        FOUND_PORT="$r_port"
        BEST_SCORE="$r_score"
    elif awk "BEGIN { exit ($r_score < $BEST_SCORE) ? 0 : 1 }"; then
        log Success "FOUND better DNS: $r_dns (score: ${r_score}s, was: ${BEST_SCORE}s)"
        FOUND_DNS="$r_dns"
        FOUND_PORT="$r_port"
        BEST_SCORE="$r_score"
    else
        log Info "Found working DNS: $r_dns (score: ${r_score}s, best: ${BEST_SCORE}s)"
    fi
```

Note: `r_detail` now contains the score (from Task 1's new result format). The `awk` comparison handles floating-point comparison portably.

**Step 3: Update the "none worked" message**

Change the final check (line 252-254) from:
```bash
if [[ -z "$FOUND_DNS" && $tested -gt 0 ]]; then
```
This stays the same — it only triggers if zero DNS passed.

---

### Task 4: Update bash orchestrator to scan all DNS

**Files:**
- Modify: `unix/slipstream-connect.sh` — Phase 1 section (lines 144-180)

**Step 1: Initialize BEST_SCORE before Phase 1**

After `FOUND_PORT=""` (line 147), add:
```bash
BEST_SCORE=999
```

**Step 2: Always run Phase 1b (remove the early-exit guard)**

Change Phase 1b from:
```bash
if [[ -z "$FOUND_DNS" ]]; then
    remaining_count=$(( ${#FULL_DNS_LIST[@]} - PRIORITY_COUNT ))
    if [[ $remaining_count -gt 0 ]]; then
        echo ""
        log Info "Scanning remaining $remaining_count DNS entries..."
        DNS_LIST=("${FULL_DNS_LIST[@]:$PRIORITY_COUNT}")
        start_dns_testing "$EXE_PATH" "$RESULTS_DIR"
    fi
fi
```

To (always run, adjust message based on whether we already have one):
```bash
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
```

**Step 3: Add summary before Phase 2**

After the "no working DNS found" error block (line 180), add:
```bash
echo ""
log Success "Best DNS: $FOUND_DNS (score: ${BEST_SCORE}s)"
```

**Step 4: Update Phase 2 reconnect re-scan**

In the reconnect loop (lines 230-231), reset BEST_SCORE too:
```bash
FOUND_DNS=""
FOUND_PORT=""
BEST_SCORE=999
```

---

### Task 5: Add timing to PowerShell `Start-DnsTesting`

**Files:**
- Modify: `windows/lib/Test-Dns.ps1` — `Start-DnsTesting` function

**Step 1: Remove `$found` early break**

Remove line 171:
```powershell
if ($found) { break }
```

**Step 2: Add ranking variables at the top of the function**

After `$dnsIndex = 0` (line 160), add:
```powershell
$bestDns = $null
$bestScore = 999.0
```

**Step 3: Replace the "Connection ready" PASS handler (lines 203-226)**

Replace with timed connectivity check and ranking:
```powershell
if ($output -match "Connection ready") {
    $establishTime = ((Get-Date) - $w.Started).TotalSeconds

    Start-Sleep -Milliseconds 500

    $curlStart = Get-Date
    $connected = Test-Connectivity -Port $w.Port -Config $Config
    $curlLatency = ((Get-Date) - $curlStart).TotalSeconds
    $score = [Math]::Round($establishTime + $curlLatency, 1)

    if ($connected) {
        Save-WorkingDns -Dns $w.Dns -Score $score -Path $workingPath

        if ($null -eq $bestDns) {
            Write-Log -Message "FOUND working DNS: $($w.Dns) (score: ${score}s)" -Level Success
            $bestDns = @{ Dns = $w.Dns; Port = $w.Port; Score = $score }
            $bestScore = $score
        } elseif ($score -lt $bestScore) {
            Write-Log -Message "FOUND better DNS: $($w.Dns) (score: ${score}s, was: ${bestScore}s)" -Level Success
            $bestDns = @{ Dns = $w.Dns; Port = $w.Port; Score = $score }
            $bestScore = $score
        } else {
            Write-Log -Message "Found working DNS: $($w.Dns) (score: ${score}s, best: ${bestScore}s)" -Level Info
        }

        Stop-TestWorker -Worker $w
        $tested++
        continue
    }
    else {
        Write-Log -Message "FAIL: $($w.Dns) - Tunnel up but no internet" -Level Debug
        $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
        Add-Content -Path $failedPath -Value "$($w.Dns) | $timestamp | Tunnel up but no internet" -Encoding UTF8
        Stop-TestWorker -Worker $w
        $tested++
        continue
    }
}
```

**Step 4: Change return value**

Replace `return $found` (line 275) with:
```powershell
return $bestDns
```

---

### Task 6: Add `Save-WorkingDns` helper to PowerShell

**Files:**
- Modify: `windows/lib/Test-Dns.ps1` — add function before `Start-DnsTesting`

```powershell
function Save-WorkingDns {
    param(
        [Parameter(Mandatory)]
        [string]$Dns,
        [Parameter(Mandatory)]
        [double]$Score,
        [Parameter(Mandatory)]
        [string]$Path
    )

    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $newLine = "$Dns | $timestamp | $Score"

    # Read existing entries, remove duplicate for this DNS
    $lines = @()
    if (Test-Path $Path) {
        $lines = @(Get-Content $Path -Encoding UTF8 | Where-Object {
            $_ -notmatch "^\s*$([regex]::Escape($Dns))\s*\|"
        })
    }
    $lines += $newLine

    # Sort by score (3rd field, ascending = best first)
    $sorted = $lines | Where-Object { $_.Trim() -ne '' } | Sort-Object {
        $parts = $_ -split '\|'
        if ($parts.Count -ge 3) { [double]$parts[2].Trim() } else { 999 }
    }

    $sorted | Set-Content $Path -Encoding UTF8
}
```

---

### Task 7: Update PowerShell orchestrator to scan all DNS

**Files:**
- Modify: `windows/slipstream-connect.ps1` — Phase 1 section (lines 118-155)

**Step 1: Always run Phase 1b**

Change Phase 1b from:
```powershell
if (-not $result) {
    ...
}
```

To:
```powershell
$remainingCount = $dnsList.Count - $priorityCount
if ($remainingCount -gt 0) {
    Write-Host ""
    if ($result) {
        Write-Log -Message "Scanning remaining $remainingCount DNS entries for a better match..." -Level Info
    } else {
        Write-Log -Message "Scanning remaining $remainingCount DNS entries..." -Level Info
    }
    $remainingList = @($dnsList[$priorityCount..($dnsList.Count - 1)])
    $newResult = Start-DnsTesting -DnsList $remainingList -Config $config -ExePath $exePath -ResultsDirectory $resultsDir
    if ($newResult -and ($null -eq $result -or $newResult.Score -lt $result.Score)) {
        $result = $newResult
    }
}
```

**Step 2: Add summary before Phase 2**

After the "no working DNS found" error block, before Phase 2:
```powershell
Write-Host ""
Write-Log -Message "Best DNS: $($result.Dns) (score: $($result.Score)s)" -Level Success
```

**Step 3: Update Phase 2 reconnect to pass score through**

Update `$workingDns = $result.Dns` to also track score through reconnect cycles.

---

### Task 8: Update `dns-working.txt` parsing in tier 1 loading

**Files:**
- Modify: `unix/lib/config.sh` — `read_dns_list` function, tier 1 section
- Modify: `windows/lib/Config.ps1` — `Read-DnsList` function, tier 1 section

No changes needed — both already parse only the first field:
- Bash: `while IFS='|' read -r dns _rest` — `_rest` absorbs timestamp and score
- PowerShell: `($_ -split '\|')[0].Trim()` — only takes the DNS IP

The file is sorted best-first, so tier 1 naturally loads them in best-to-worst order. **No code changes required.**

---

### Task 9: Commit and create PR

**Step 1: Create branch**
```bash
git checkout master && git pull
git checkout -b feature/dns-ranking
```

**Step 2: Stage and commit**
```bash
git add unix/lib/test-dns.sh windows/lib/Test-Dns.ps1 unix/slipstream-connect.sh windows/slipstream-connect.ps1
git commit -m "feat: rank DNS resolvers by speed and sort dns-working.txt"
```

**Step 3: Push and create PR**
```bash
git push -u origin feature/dns-ranking
gh pr create --title "feat: rank DNS by speed" --body "..."
```
