# lib/Test-Dns.ps1
# Tests DNS resolvers by spawning slipstream-client.exe and verifying connectivity
#
# Strategy: redirect process output to temp files, poll the files.
# This avoids the classic .NET deadlock with Peek()/ReadLine() on redirected streams.
#
# Detection logic:
#   - "Connection ready" = tunnel is up (proceed to connectivity check)
#   - "became unavailable" = resolver is dead (FAIL immediately)
#   - Other WARN lines (e.g. cert warnings at startup) are NORMAL and ignored

function Get-RandomPort {
    $listener = [System.Net.Sockets.TcpListener]::new([System.Net.IPAddress]::Loopback, 0)
    $listener.Start()
    $port = $listener.LocalEndpoint.Port
    $listener.Stop()
    return $port
}

function Test-Connectivity {
    param(
        [Parameter(Mandatory)]
        [int]$Port,
        [Parameter(Mandatory)]
        [hashtable]$Config
    )

    # Try primary URL (expect HTTP 204)
    try {
        $statusCode = & curl.exe --proxy "socks5://127.0.0.1:$Port" `
            --max-time $Config.ConnectivityTimeout `
            -s -o NUL -w "%{http_code}" `
            $Config.ConnectivityUrl 2>$null

        if ($statusCode -eq "204") {
            return $true
        }
    }
    catch {}

    # Try fallback URL (expect "Microsoft Connect Test" in body)
    try {
        $body = & curl.exe --proxy "socks5://127.0.0.1:$Port" `
            --max-time $Config.ConnectivityTimeout `
            -s $Config.FallbackUrl 2>$null

        if ($body -match "Microsoft Connect Test") {
            return $true
        }
    }
    catch {}

    return $false
}

function Test-SingleDnsViaFile {
    <#
    .SYNOPSIS
        Starts slipstream-client for a single DNS, redirects output to a temp file,
        and returns the process + metadata so the caller can poll the file.
    #>
    param(
        [Parameter(Mandatory)]
        [string]$Dns,
        [Parameter(Mandatory)]
        [hashtable]$Config,
        [Parameter(Mandatory)]
        [string]$ExePath
    )

    $port = Get-RandomPort
    $tempFile = [System.IO.Path]::GetTempFileName()

    $arguments = "--domain $($Config.Domain) --congestion-control $($Config.CongestionControl) --keep-alive-interval $($Config.KeepAliveInterval) --tcp-listen-port $port --resolver $Dns"

    # Start process with stdout+stderr merged into one temp file
    $process = Start-Process -FilePath $ExePath `
        -ArgumentList $arguments `
        -WindowStyle Hidden `
        -RedirectStandardOutput $tempFile `
        -RedirectStandardError "$tempFile.err" `
        -PassThru

    return @{
        Dns      = $Dns
        Port     = $port
        Process  = $process
        OutFile  = $tempFile
        ErrFile  = "$tempFile.err"
        Started  = Get-Date
    }
}

function Read-ProcessOutput {
    <#
    .SYNOPSIS
        Reads both stdout and stderr temp files and returns combined content.
    #>
    param(
        [string]$OutFile,
        [string]$ErrFile
    )
    $content = ""
    try {
        if (Test-Path $OutFile) {
            # Use FileStream with sharing so we can read while process writes
            $fs = [System.IO.FileStream]::new($OutFile, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::ReadWrite)
            $reader = [System.IO.StreamReader]::new($fs)
            $content += $reader.ReadToEnd()
            $reader.Close()
            $fs.Close()
        }
    } catch {}
    try {
        if (Test-Path $ErrFile) {
            $fs = [System.IO.FileStream]::new($ErrFile, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::ReadWrite)
            $reader = [System.IO.StreamReader]::new($fs)
            $content += $reader.ReadToEnd()
            $reader.Close()
            $fs.Close()
        }
    } catch {}
    return $content
}

function Stop-TestWorker {
    param($Worker)
    try {
        if ($Worker.Process -and -not $Worker.Process.HasExited) {
            $Worker.Process.Kill()
        }
    } catch {}
    # Clean up temp files
    try { if (Test-Path $Worker.OutFile) { Remove-Item $Worker.OutFile -Force } } catch {}
    try { if (Test-Path $Worker.ErrFile) { Remove-Item $Worker.ErrFile -Force } } catch {}
}

function Start-DnsTesting {
    param(
        [Parameter(Mandatory)]
        [string[]]$DnsList,
        [Parameter(Mandatory)]
        [hashtable]$Config,
        [Parameter(Mandatory)]
        [string]$ExePath,
        [Parameter(Mandatory)]
        [string]$ResultsDirectory
    )

    $workingPath = Join-Path $ResultsDirectory "dns-working.txt"
    $failedPath = Join-Path $ResultsDirectory "dns-failed.txt"

    if (-not (Test-Path $ResultsDirectory)) {
        New-Item -ItemType Directory -Path $ResultsDirectory -Force | Out-Null
    }

    $totalDns = $DnsList.Count
    $tested = 0
    $found = $null
    $dnsIndex = 0

    Write-Log -Message "Starting DNS testing with $($Config.Workers) parallel workers..." -Level Info
    Write-Log -Message "Testing $totalDns DNS entries (timeout: $($Config.Timeout)s per entry)" -Level Info
    Write-Host ""

    # Active workers pool
    $workers = @()

    try {
        while ($dnsIndex -lt $totalDns -or $workers.Count -gt 0) {
            if ($found) { break }

            # Fill worker pool up to max
            while ($workers.Count -lt $Config.Workers -and $dnsIndex -lt $totalDns) {
                $dns = $DnsList[$dnsIndex]
                $dnsIndex++
                try {
                    $worker = Test-SingleDnsViaFile -Dns $dns -Config $Config -ExePath $ExePath
                    $workers += $worker
                } catch {
                    Write-Log -Message "FAIL: $dns - Could not start process" -Level Debug
                    $tested++
                }
            }

            # Poll all active workers
            $stillActive = @()
            foreach ($w in $workers) {
                $elapsed = ((Get-Date) - $w.Started).TotalSeconds
                $output = Read-ProcessOutput -OutFile $w.OutFile -ErrFile $w.ErrFile

                # Check for resolver dead
                if ($output -match "became unavailable") {
                    Write-Log -Message "FAIL: $($w.Dns) - Resolver became unavailable" -Level Debug
                    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
                    Add-Content -Path $failedPath -Value "$($w.Dns) | $timestamp | Resolver became unavailable" -Encoding UTF8
                    Stop-TestWorker -Worker $w
                    $tested++
                    continue
                }

                # Check for connection ready
                if ($output -match "Connection ready") {
                    Write-Log -Message "Tunnel up for $($w.Dns), verifying internet..." -Level Info

                    # Small delay for proxy to initialize
                    Start-Sleep -Milliseconds 500

                    if (Test-Connectivity -Port $w.Port -Config $Config) {
                        Write-Log -Message "FOUND working DNS: $($w.Dns)" -Level Success
                        $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
                        Add-Content -Path $workingPath -Value "$($w.Dns) | $timestamp" -Encoding UTF8
                        $found = @{ Dns = $w.Dns; Port = $w.Port }
                        Stop-TestWorker -Worker $w
                        $tested++
                        break
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

                # Check for timeout
                if ($elapsed -ge $Config.Timeout) {
                    Write-Log -Message "FAIL: $($w.Dns) - Timeout" -Level Debug
                    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
                    Add-Content -Path $failedPath -Value "$($w.Dns) | $timestamp | Timeout" -Encoding UTF8
                    Stop-TestWorker -Worker $w
                    $tested++
                    continue
                }

                # Check if process crashed
                if ($w.Process.HasExited) {
                    Write-Log -Message "FAIL: $($w.Dns) - Process exited" -Level Debug
                    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
                    Add-Content -Path $failedPath -Value "$($w.Dns) | $timestamp | Process exited" -Encoding UTF8
                    Stop-TestWorker -Worker $w
                    $tested++
                    continue
                }

                # Still waiting
                $stillActive += $w
            }
            $workers = $stillActive

            if (-not $found) {
                Start-Sleep -Milliseconds 200
            }

            # Progress update every batch
            if ($tested -gt 0 -and $tested % $Config.Workers -eq 0) {
                $percent = [Math]::Round(($tested / $totalDns) * 100, 1)
                Write-Log -Message "Progress: $tested / $totalDns ($percent%)" -Level Info
            }
        }
    }
    finally {
        # Clean up any remaining workers
        foreach ($w in $workers) {
            Stop-TestWorker -Worker $w
        }
    }

    if (-not $found -and $tested -gt 0) {
        Write-Log -Message "Tested $tested DNS entries, none worked." -Level Warning
    }

    return $found
}
