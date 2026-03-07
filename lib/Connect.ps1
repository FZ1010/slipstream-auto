# lib/Connect.ps1
# Manages the active slipstream connection with health monitoring and auto-reconnect
#
# Detection logic:
#   - "became unavailable" = connection lost (not just any WARN)
#   - Health checks verify actual internet connectivity through the SOCKS5 proxy

function Start-SlipstreamConnection {
    param(
        [Parameter(Mandatory)]
        [string]$Dns,
        [Parameter(Mandatory)]
        [int]$Port,
        [Parameter(Mandatory)]
        [hashtable]$Config,
        [Parameter(Mandatory)]
        [string]$ExePath
    )

    $arguments = @(
        "--domain", $Config.Domain,
        "--congestion-control", $Config.CongestionControl,
        "--keep-alive-interval", $Config.KeepAliveInterval,
        "--tcp-listen-port", $Port,
        "--resolver", $Dns
    )

    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = $ExePath
    $psi.Arguments = $arguments -join ' '
    $psi.UseShellExecute = $false
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $psi.CreateNoWindow = $true

    $process = [System.Diagnostics.Process]::Start($psi)

    # Wait for "Connection ready"
    $deadline = (Get-Date).AddSeconds($Config.Timeout + 2)
    $connected = $false

    while ((Get-Date) -lt $deadline -and -not $process.HasExited) {
        Start-Sleep -Milliseconds 100
        try {
            if ($process.StandardOutput.Peek() -ge 0) {
                $line = $process.StandardOutput.ReadLine()
                if ($line -match "Connection ready") { $connected = $true; break }
                if ($line -match "became unavailable") {
                    if (-not $process.HasExited) { try { $process.Kill() } catch {} }
                    $process.Dispose()
                    return $null
                }
            }
        } catch {}
        try {
            if ($process.StandardError.Peek() -ge 0) {
                $line = $process.StandardError.ReadLine()
                if ($line -match "Connection ready") { $connected = $true; break }
                if ($line -match "became unavailable") {
                    if (-not $process.HasExited) { try { $process.Kill() } catch {} }
                    $process.Dispose()
                    return $null
                }
            }
        } catch {}
    }

    if (-not $connected) {
        if (-not $process.HasExited) {
            try { $process.Kill() } catch {}
        }
        $process.Dispose()
        return $null
    }

    return $process
}

function Watch-Connection {
    param(
        [Parameter(Mandatory)]
        [System.Diagnostics.Process]$Process,
        [Parameter(Mandatory)]
        [int]$Port,
        [Parameter(Mandatory)]
        [hashtable]$Config
    )

    Write-Host ""
    Write-Log -Message "============================================" -Level Success
    Write-Log -Message "  CONNECTED! You are now online." -Level Success
    Write-Log -Message "  SOCKS5 Proxy: 127.0.0.1:$Port" -Level Success
    Write-Log -Message "============================================" -Level Success
    Write-Host ""
    Write-Log -Message "Set your browser/system proxy to SOCKS5 127.0.0.1:$Port" -Level Info
    Write-Log -Message "Health checks running every $($Config.HealthCheckInterval)s. Press Ctrl+C to stop." -Level Info
    Write-Host ""

    $failCount = 0
    $maxConsecutiveFails = 3

    while (-not $Process.HasExited) {
        Start-Sleep -Seconds $Config.HealthCheckInterval

        # Drain process output, check for "became unavailable"
        $resolverDead = $false
        try {
            while ($Process.StandardOutput.Peek() -ge 0) {
                $line = $Process.StandardOutput.ReadLine()
                if ($line -match "became unavailable") { $resolverDead = $true }
            }
        } catch {}
        try {
            while ($Process.StandardError.Peek() -ge 0) {
                $line = $Process.StandardError.ReadLine()
                if ($line -match "became unavailable") { $resolverDead = $true }
            }
        } catch {}

        if ($resolverDead) {
            Write-Log -Message "Resolver became unavailable - connection lost" -Level Error
            return $false
        }

        # Connectivity health check
        $healthy = $false
        try {
            $statusCode = & curl.exe --proxy "socks5://127.0.0.1:$Port" `
                --max-time $Config.ConnectivityTimeout `
                -s -o NUL -w "%{http_code}" `
                $Config.ConnectivityUrl 2>$null
            if ($statusCode -eq "204") { $healthy = $true }
        } catch {}

        if ($healthy) {
            if ($failCount -gt 0) {
                Write-Log -Message "Connection recovered" -Level Success
            }
            $failCount = 0
        }
        else {
            $failCount++
            Write-Log -Message "Health check failed ($failCount/$maxConsecutiveFails)" -Level Warning
            if ($failCount -ge $maxConsecutiveFails) {
                Write-Log -Message "Connection lost after $maxConsecutiveFails consecutive failed health checks" -Level Error
                return $false
            }
        }
    }

    Write-Log -Message "slipstream-client process exited unexpectedly" -Level Error
    return $false
}

function Start-ConnectionLoop {
    param(
        [Parameter(Mandatory)]
        [string[]]$DnsList,
        [Parameter(Mandatory)]
        [int]$StartIndex,
        [Parameter(Mandatory)]
        [hashtable]$Config,
        [Parameter(Mandatory)]
        [string]$ExePath,
        [Parameter(Mandatory)]
        [string]$ResultsDirectory
    )

    $workingPath = Join-Path $ResultsDirectory "working-dns.txt"
    $reconnectCount = 0
    $currentIndex = $StartIndex

    while ($true) {
        if ($Config.MaxReconnectAttempts -gt 0 -and $reconnectCount -ge $Config.MaxReconnectAttempts) {
            Write-Log -Message "Max reconnect attempts ($($Config.MaxReconnectAttempts)) reached. Stopping." -Level Error
            return
        }

        if ($currentIndex -ge $DnsList.Count) {
            Write-Log -Message "Exhausted all DNS entries. Restarting from the beginning..." -Level Warning
            $currentIndex = 0
        }

        $dns = $DnsList[$currentIndex]
        $port = Get-RandomPort

        if ($reconnectCount -gt 0) {
            Write-Host ""
            Write-Log -Message "Reconnecting (attempt $reconnectCount) with DNS: $dns" -Level Warning
        }
        else {
            Write-Log -Message "Establishing connection via $dns on port $port..." -Level Info
        }

        $process = Start-SlipstreamConnection -Dns $dns -Port $port -Config $Config -ExePath $ExePath

        if ($null -eq $process) {
            Write-Log -Message "Failed to connect via $dns" -Level Warning
            $currentIndex++
            $reconnectCount++
            continue
        }

        # Verify actual internet connectivity
        Start-Sleep -Milliseconds 500
        $internetWorks = $false
        try {
            $statusCode = & curl.exe --proxy "socks5://127.0.0.1:$port" `
                --max-time $Config.ConnectivityTimeout `
                -s -o NUL -w "%{http_code}" `
                $Config.ConnectivityUrl 2>$null
            if ($statusCode -eq "204") { $internetWorks = $true }
        } catch {}

        if (-not $internetWorks) {
            Write-Log -Message "Tunnel up via $dns but no internet, trying next..." -Level Warning
            if (-not $process.HasExited) {
                try { $process.Kill() } catch {}
            }
            $process.Dispose()
            $currentIndex++
            $reconnectCount++
            continue
        }

        # Save working DNS
        $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
        Add-Content -Path $workingPath -Value "$dns | $timestamp" -Encoding UTF8

        # Monitor the connection
        $stillAlive = Watch-Connection -Process $process -Port $port -Config $Config

        # Clean up
        if (-not $process.HasExited) {
            try { $process.Kill() } catch {}
        }
        $process.Dispose()

        if (-not $stillAlive) {
            Write-Log -Message "Connection dropped. Searching for new DNS..." -Level Warning
            $currentIndex++
            $reconnectCount++
        }
    }
}
