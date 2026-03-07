# lib/Test-Dns.ps1
# Tests DNS resolvers by spawning slipstream-client.exe and verifying connectivity
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

    $workingPath = Join-Path $ResultsDirectory "working-dns.txt"
    $failedPath = Join-Path $ResultsDirectory "failed-dns.txt"

    if (-not (Test-Path $ResultsDirectory)) {
        New-Item -ItemType Directory -Path $ResultsDirectory -Force | Out-Null
    }

    $totalDns = $DnsList.Count
    $tested = 0
    $found = $null

    Write-Log -Message "Starting DNS testing with $($Config.Workers) parallel workers..." -Level Info
    Write-Log -Message "Testing $totalDns DNS entries (timeout: $($Config.Timeout)s per entry)" -Level Info
    Write-Host ""

    # Process in batches
    for ($i = 0; $i -lt $totalDns; $i += $Config.Workers) {
        if ($found) { break }

        $batchEnd = [Math]::Min($i + $Config.Workers - 1, $totalDns - 1)
        $batch = $DnsList[$i..$batchEnd]
        $jobs = @()

        foreach ($dns in $batch) {
            $jobs += Start-Job -ScriptBlock {
                param($Dns, $ConfigData, $ExePath)

                # Reconstruct config hashtable (serialization converts to PSObject)
                $Config = @{}
                $ConfigData.PSObject.Properties | ForEach-Object { $Config[$_.Name] = $_.Value }

                function Get-RandomPort {
                    $listener = [System.Net.Sockets.TcpListener]::new([System.Net.IPAddress]::Loopback, 0)
                    $listener.Start()
                    $port = $listener.LocalEndpoint.Port
                    $listener.Stop()
                    return $port
                }

                function Test-Connectivity {
                    param([int]$Port, [hashtable]$Config)
                    try {
                        $code = & curl.exe --proxy "socks5://127.0.0.1:$Port" `
                            --max-time $Config.ConnectivityTimeout `
                            -s -o NUL -w "%{http_code}" `
                            $Config.ConnectivityUrl 2>$null
                        if ($code -eq "204") { return $true }
                    } catch {}
                    try {
                        $body = & curl.exe --proxy "socks5://127.0.0.1:$Port" `
                            --max-time $Config.ConnectivityTimeout `
                            -s $Config.FallbackUrl 2>$null
                        if ($body -match "Microsoft Connect Test") { return $true }
                    } catch {}
                    return $false
                }

                $port = Get-RandomPort
                $result = @{ Dns = $Dns; Port = $port; Status = "Failed"; Detail = "" }

                $arguments = "--domain $($Config.Domain) --congestion-control $($Config.CongestionControl) --keep-alive-interval $($Config.KeepAliveInterval) --tcp-listen-port $port --resolver $Dns"
                $psi = New-Object System.Diagnostics.ProcessStartInfo
                $psi.FileName = $ExePath
                $psi.Arguments = $arguments
                $psi.UseShellExecute = $false
                $psi.RedirectStandardOutput = $true
                $psi.RedirectStandardError = $true
                $psi.CreateNoWindow = $true

                $process = $null
                try {
                    $process = [System.Diagnostics.Process]::Start($psi)
                    $deadline = (Get-Date).AddSeconds($Config.Timeout)
                    $connected = $false

                    while ((Get-Date) -lt $deadline -and -not $process.HasExited) {
                        Start-Sleep -Milliseconds 100

                        # Check stdout
                        try {
                            if ($process.StandardOutput.Peek() -ge 0) {
                                $line = $process.StandardOutput.ReadLine()
                                if ($line -match "Connection ready") {
                                    $connected = $true
                                    break
                                }
                                # Only "became unavailable" means resolver is dead
                                # Other WARNs (cert, etc.) are normal at startup
                                if ($line -match "became unavailable") {
                                    $result.Detail = "Resolver became unavailable"
                                    return $result
                                }
                            }
                        } catch {}

                        # Check stderr
                        try {
                            if ($process.StandardError.Peek() -ge 0) {
                                $line = $process.StandardError.ReadLine()
                                if ($line -match "Connection ready") {
                                    $connected = $true
                                    break
                                }
                                if ($line -match "became unavailable") {
                                    $result.Detail = "Resolver became unavailable"
                                    return $result
                                }
                            }
                        } catch {}
                    }

                    if (-not $connected) {
                        $result.Detail = "Timeout"
                        return $result
                    }

                    # Small delay to let proxy fully initialize
                    Start-Sleep -Milliseconds 500

                    if (Test-Connectivity -Port $port -Config $Config) {
                        $result.Status = "Working"
                        $result.Detail = "Internet verified"
                    }
                    else {
                        $result.Detail = "Tunnel up but no internet"
                    }
                }
                catch {
                    $result.Detail = "Error: $($_.Exception.Message)"
                }
                finally {
                    if ($process -and -not $process.HasExited) {
                        try { $process.Kill() } catch {}
                    }
                    if ($process) { $process.Dispose() }
                }

                return $result
            } -ArgumentList $dns, ([PSCustomObject]$Config), $ExePath
        }

        # Wait for batch with generous timeout
        $maxWait = $Config.Timeout + $Config.ConnectivityTimeout + 8
        $null = $jobs | Wait-Job -Timeout $maxWait

        foreach ($job in $jobs) {
            $tested++

            if ($job.State -eq 'Running') {
                # Job timed out
                Stop-Job -Job $job -ErrorAction SilentlyContinue
                Write-Log -Message "FAIL: $($batch[$jobs.IndexOf($job)]) - Job timeout" -Level Debug
            }
            else {
                $result = Receive-Job -Job $job -ErrorAction SilentlyContinue

                if ($result -and $result.Status -eq "Working") {
                    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
                    Write-Log -Message "FOUND working DNS: $($result.Dns)" -Level Success
                    Add-Content -Path $workingPath -Value "$($result.Dns) | $timestamp" -Encoding UTF8
                    $found = $result
                }
                elseif ($result) {
                    Write-Log -Message "FAIL: $($result.Dns) - $($result.Detail)" -Level Debug
                    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
                    Add-Content -Path $failedPath -Value "$($result.Dns) | $timestamp | $($result.Detail)" -Encoding UTF8
                }
            }

            Remove-Job -Job $job -Force -ErrorAction SilentlyContinue
        }

        # Stop remaining jobs if we found a working DNS
        if ($found) {
            $jobs | ForEach-Object {
                Stop-Job -Job $_ -ErrorAction SilentlyContinue
                Remove-Job -Job $_ -Force -ErrorAction SilentlyContinue
            }
            break
        }

        $percent = [Math]::Round(($tested / $totalDns) * 100, 1)
        Write-Log -Message "Progress: $tested / $totalDns ($percent%)" -Level Info
    }

    return $found
}
