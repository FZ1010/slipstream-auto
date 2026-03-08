# lib/Connect.ps1
# Manages the active slipstream connection with health monitoring and auto-reconnect
#
# Uses temp file redirection instead of Peek()/ReadLine() to avoid .NET stream deadlocks.
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

    $outFile = [System.IO.Path]::GetTempFileName()
    $errFile = "$outFile.err"

    $arguments = "--domain $($Config.Domain) --congestion-control $($Config.CongestionControl) --keep-alive-interval $($Config.KeepAliveInterval) --tcp-listen-port $Port --resolver $Dns"

    $process = Start-Process -FilePath $ExePath `
        -ArgumentList $arguments `
        -WindowStyle Hidden `
        -RedirectStandardOutput $outFile `
        -RedirectStandardError $errFile `
        -PassThru

    # Wait for "Connection ready"
    $deadline = (Get-Date).AddSeconds($Config.Timeout + 2)
    $connected = $false

    while ((Get-Date) -lt $deadline -and -not $process.HasExited) {
        Start-Sleep -Milliseconds 200
        $output = Read-ProcessOutput -OutFile $outFile -ErrFile $errFile

        if ($output -match "became unavailable") {
            try { if (-not $process.HasExited) { $process.Kill() } } catch {}
            try { Remove-Item $outFile -Force } catch {}
            try { Remove-Item $errFile -Force } catch {}
            return $null
        }

        if ($output -match "Connection ready") {
            $connected = $true
            break
        }
    }

    if (-not $connected) {
        try { if (-not $process.HasExited) { $process.Kill() } } catch {}
        try { Remove-Item $outFile -Force } catch {}
        try { Remove-Item $errFile -Force } catch {}
        return $null
    }

    return @{
        Process = $process
        OutFile = $outFile
        ErrFile = $errFile
    }
}

function Watch-Connection {
    param(
        [Parameter(Mandatory)]
        [hashtable]$Connection,
        [Parameter(Mandatory)]
        [int]$Port,
        [Parameter(Mandatory)]
        [hashtable]$Config
    )

    $process = $Connection.Process

    Write-Host ""
    Write-Log -Message "============================================" -Level Success
    Write-Log -Message "  CONNECTED! You are now online." -Level Success
    Write-Log -Message "  SOCKS5 Proxy: 127.0.0.1:$Port" -Level Success
    Write-Log -Message "============================================" -Level Success
    Write-Host ""
    Write-Log -Message "Set your browser/system proxy to SOCKS5 127.0.0.1:$Port" -Level Info
    Write-Log -Message "Health checks every $($Config.HealthCheckInterval)s. Press Ctrl+C to stop." -Level Info
    Write-Host ""

    $failCount = 0
    $maxConsecutiveFails = 3

    while (-not $process.HasExited) {
        Start-Sleep -Seconds $Config.HealthCheckInterval

        # Check output for "became unavailable"
        $output = Read-ProcessOutput -OutFile $Connection.OutFile -ErrFile $Connection.ErrFile
        if ($output -match "became unavailable") {
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

function Stop-Connection {
    param([hashtable]$Connection)
    if ($null -eq $Connection) { return }
    try { if ($Connection.Process -and -not $Connection.Process.HasExited) { $Connection.Process.Kill() } } catch {}
    try { if (Test-Path $Connection.OutFile) { Remove-Item $Connection.OutFile -Force } } catch {}
    try { if (Test-Path $Connection.ErrFile) { Remove-Item $Connection.ErrFile -Force } } catch {}
}

