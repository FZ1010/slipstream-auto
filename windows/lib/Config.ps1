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
        [string]$CustomPath,
        [hashtable]$Config,
        [string]$ResultsDirectory
    )

    # ── Load known-bad DNS ──
    $knownBad = @{}
    $failedPath = Join-Path $ResultsDirectory "dns-failed.txt"
    if ($Config.SkipPreviouslyFailed -and (Test-Path $failedPath)) {
        Get-Content -Path $failedPath -Encoding UTF8 |
            ForEach-Object { ($_ -split '\|')[0].Trim() } |
            Where-Object { $_ -ne '' } |
            ForEach-Object { $knownBad[$_] = $true }
        Write-Log -Message "Loaded $($knownBad.Count) previously failed DNS entries to skip" -Level Debug
    }

    # Track seen DNS to avoid duplicates across tiers
    $seen = @{}

    # ── Tier 0: User's custom DNS file ──
    $tier0 = @()
    if ($CustomPath -and (Test-Path $CustomPath)) {
        $tier0 = @(Get-Content -Path $CustomPath -Encoding UTF8 |
            ForEach-Object { $_.Trim() } |
            Where-Object { $_ -ne '' -and $_ -match '^\d' -and -not $knownBad.ContainsKey($_) -and -not $seen.ContainsKey($_) } |
            ForEach-Object { $seen[$_] = $true; $_ })
        Write-Log -Message "Tier 0 (dns-custom.txt): $($tier0.Count) entries" -Level Debug
    }

    # ── Tier 1: Previously working DNS ──
    $tier1 = @()
    $workingPath = Join-Path $ResultsDirectory "dns-working.txt"
    if ($Config.PrioritizeKnownGood -and (Test-Path $workingPath)) {
        $tier1 = @(Get-Content -Path $workingPath -Encoding UTF8 |
            ForEach-Object { ($_ -split '\|')[0].Trim() } |
            Where-Object { $_ -ne '' -and -not $knownBad.ContainsKey($_) -and -not $seen.ContainsKey($_) } |
            ForEach-Object { $seen[$_] = $true; $_ })
    }
    Write-Log -Message "Tier 1 (previously working): $($tier1.Count) entries" -Level Debug

    # ── Tier 2: DNS list ──
    $tier2 = @()
    if (Test-Path $Path) {
        $tier2 = @(Get-Content -Path $Path -Encoding UTF8 |
            ForEach-Object { $_.Trim() } |
            Where-Object { $_ -ne '' -and $_ -match '^\d' -and -not $knownBad.ContainsKey($_) -and -not $seen.ContainsKey($_) } |
            ForEach-Object { $seen[$_] = $true; $_ })
    } else {
        Write-Log -Message "DNS list not found at $Path" -Level Warning
    }
    Write-Log -Message "Tier 2 (dns-list.txt): $($tier2.Count) entries" -Level Debug

    # ── Combine: tier0 -> tier1 -> tier2 ──
    $final = @($tier0) + @($tier1) + @($tier2)
    $priorityCount = $tier0.Count + $tier1.Count
    Write-Log -Message "DNS queue: $($final.Count) total (custom: $($tier0.Count), working: $($tier1.Count), list: $($tier2.Count))" -Level Debug

    return @{
        DnsList = $final
        PriorityCount = $priorityCount
        Tier0Count = $tier0.Count
        Tier1Count = $tier1.Count
        Tier2Count = $tier2.Count
        SkippedCount = $knownBad.Count
    }
}
