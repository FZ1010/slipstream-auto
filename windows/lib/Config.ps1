# lib/Config.ps1
# Parses config.ini and loads/prepares the DNS list

function Read-Config {
    param(
        [Parameter(Mandatory)]
        [string]$Path
    )

    $config = @{
        # Defaults
        Domain              = "example.com"
        CongestionControl   = "bbr"
        KeepAliveInterval   = 2000
        Timeout             = 3
        Workers             = 5
        ConnectivityUrl     = "http://connectivitycheck.gstatic.com/generate_204"
        FallbackUrl         = "http://www.msftconnecttest.com/connecttest.txt"
        ConnectivityTimeout = 5
        HealthCheckInterval = 30
        MaxReconnectAttempts = 0
        ShuffleDns          = $true
        PrioritizeKnownGood = $true
        SkipPreviouslyFailed = $true
    }

    if (-not (Test-Path $Path)) {
        Write-Log -Message "Config file not found at $Path, using defaults" -Level Warning
        return $config
    }

    $content = Get-Content -Path $Path -Encoding UTF8
    foreach ($line in $content) {
        $line = $line.Trim()
        # Skip comments, section headers, empty lines
        if ($line -match '^\s*[#;]' -or $line -match '^\s*\[' -or $line -eq '') {
            continue
        }
        if ($line -match '^\s*(\w+)\s*=\s*(.+)$') {
            $key = $Matches[1].Trim()
            $value = ($Matches[2] -replace '\s*#.*$', '').Trim()

            if ($config.ContainsKey($key)) {
                $existing = $config[$key]
                if ($existing -is [int]) {
                    $config[$key] = [int]$value
                }
                elseif ($existing -is [bool]) {
                    $config[$key] = $value -eq 'true'
                }
                else {
                    $config[$key] = $value
                }
            }
        }
    }

    return $config
}

function Read-DnsList {
    param(
        [Parameter(Mandatory)]
        [string]$Path,
        [hashtable]$Config,
        [string]$ResultsDirectory
    )

    if (-not (Test-Path $Path)) {
        Write-Log -Message "DNS list not found at $Path" -Level Error
        return @()
    }

    # Load all DNS entries, trim whitespace, skip empty lines
    $allDns = @(Get-Content -Path $Path -Encoding UTF8 | ForEach-Object { $_.Trim() } | Where-Object { $_ -ne '' -and $_ -match '^\d' })
    Write-Log -Message "Loaded $($allDns.Count) DNS entries from list" -Level Info

    $knownGood = @()
    $knownBad = @{}

    # Load previously known-good DNS
    $workingPath = Join-Path $ResultsDirectory "working-dns.txt"
    if ($Config.PrioritizeKnownGood -and (Test-Path $workingPath)) {
        $knownGood = @(Get-Content -Path $workingPath -Encoding UTF8 |
            ForEach-Object { ($_ -split '\|')[0].Trim() } |
            Where-Object { $_ -ne '' })
        Write-Log -Message "Loaded $($knownGood.Count) previously working DNS entries" -Level Info
    }

    # Load previously failed DNS
    $failedPath = Join-Path $ResultsDirectory "failed-dns.txt"
    if ($Config.SkipPreviouslyFailed -and (Test-Path $failedPath)) {
        Get-Content -Path $failedPath -Encoding UTF8 |
            ForEach-Object { ($_ -split '\|')[0].Trim() } |
            Where-Object { $_ -ne '' } |
            ForEach-Object { $knownBad[$_] = $true }
        Write-Log -Message "Loaded $($knownBad.Count) previously failed DNS entries to skip" -Level Info
    }

    # Filter out known-bad
    $filtered = @($allDns | Where-Object { -not $knownBad.ContainsKey($_) })
    $skipped = $allDns.Count - $filtered.Count
    if ($skipped -gt 0) {
        Write-Log -Message "Skipping $skipped previously failed DNS entries" -Level Info
    }

    # Separate known-good from the rest
    $knownGoodSet = @{}
    $knownGood | ForEach-Object { $knownGoodSet[$_] = $true }

    $prioritized = @($filtered | Where-Object { $knownGoodSet.ContainsKey($_) })
    $rest = @($filtered | Where-Object { -not $knownGoodSet.ContainsKey($_) })

    # Shuffle the rest if configured
    if ($Config.ShuffleDns -and $rest.Count -gt 0) {
        $rest = $rest | Get-Random -Count $rest.Count
    }

    # Known-good first, then shuffled rest
    $final = @($prioritized) + @($rest)
    Write-Log -Message "DNS queue: $($prioritized.Count) prioritized + $($rest.Count) others = $($final.Count) total" -Level Info

    return $final
}
