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
                Add-Content -Path $workingPath -Value ("$workingDns | $timestamp") -Encoding UTF8
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
    $helpText = @'

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

'@
    Write-Host $helpText
    Read-Host "  Press Enter to return to menu"
}
