# slipstream-connect.ps1
# Main orchestrator for SlipStream Auto Connector
# Finds a working DNS resolver, connects, and maintains the connection

[CmdletBinding()]
param(
    [string]$ConfigPath = "",
    [string]$DnsListPath = "",
    [string]$UserDnsPath = "",
    [int]$Workers = 0,
    [switch]$Connect,
    [switch]$Help
)

$ErrorActionPreference = "Stop"
$scriptRoot = $PSScriptRoot
if (-not $scriptRoot) { $scriptRoot = Split-Path -Parent $MyInvocation.MyCommand.Path }

# Load modules
. (Join-Path $scriptRoot "lib\Logger.ps1")
. (Join-Path $scriptRoot "lib\Config.ps1")
. (Join-Path $scriptRoot "lib\Test-Dns.ps1")
. (Join-Path $scriptRoot "lib\Connect.ps1")
. (Join-Path $scriptRoot "lib\Menu.ps1")

# Show help
if ($Help) {
    Write-Banner
    Write-Host @"
Automatically finds a working DNS resolver, connects via slipstream-client,
and maintains the connection with auto-reconnect.

USAGE:
  .\slipstream-connect.ps1 [options]
  .\start.bat [options]

OPTIONS:
  -ConfigPath <path>    Path to config.ini (default: .\config.ini)
  -DnsListPath <path>   Path to dns-list.txt (default: .\dns-list.txt)
  -UserDnsPath <path>   Path to your own DNS file (tested first, highest priority)
  -Workers <number>     Override parallel worker count (default: from config)
  -Connect              Skip menu, connect directly
  -Help                 Show this message

EXAMPLES:
  .\start.bat                              # Open interactive menu
  .\slipstream-connect.ps1 -Workers 10     # Bypass menu, connect with 10 workers
  .\slipstream-connect.ps1 -UserDnsPath "C:\my-dns.txt"
  .\slipstream-connect.ps1 -DnsListPath "C:\my-dns.txt"

"@
    exit 0
}

# Resolve paths — config/dns/results/exe are in the project root (one level up)
$projectRoot = Split-Path $scriptRoot -Parent
if (-not $ConfigPath) { $ConfigPath = Join-Path $projectRoot "config.ini" }
if (-not $DnsListPath) { $DnsListPath = Join-Path $projectRoot "dns-list.txt" }
if (-not $UserDnsPath) { $UserDnsPath = Join-Path $projectRoot "dns-custom.txt" }
$resultsDir = Join-Path $projectRoot "results"
$exePath = Join-Path $projectRoot "slipstream-client.exe"

# Store the resolved config path for menu usage
$ConfigPath_Resolved = $ConfigPath

# Initialize logger and show banner
Write-Banner
Initialize-Logger -LogDirectory $resultsDir

# ── Preflight checks ──

if (-not (Test-Path $exePath)) {
    Write-Log -Message "slipstream-client.exe not found!" -Level Error
    Write-Log -Message "Place it in: $scriptRoot" -Level Error
    Read-Host "Press Enter to exit"
    exit 1
}

if (-not (Get-Command curl.exe -ErrorAction SilentlyContinue)) {
    Write-Log -Message "curl.exe not found!" -Level Error
    Write-Log -Message "curl.exe ships with Windows 10+. If you're on an older system, get it from https://curl.se/windows/" -Level Error
    Read-Host "Press Enter to exit"
    exit 1
}

# ── Load configuration ──

$config = Read-Config -Path $ConfigPath
if ($Workers -gt 0) { $config.Workers = $Workers }

Write-Log -Message "Domain: $($config.Domain)" -Level Info
Write-Log -Message "Workers: $($config.Workers) | Timeout: $($config.Timeout)s | Health check: $($config.HealthCheckInterval)s" -Level Info
Write-Host ""

# ── Load DNS list ──

$dnsData = Read-DnsList -Path $DnsListPath -CustomPath $UserDnsPath -Config $config -ResultsDirectory $resultsDir
$dnsList = $dnsData.DnsList
$priorityCount = $dnsData.PriorityCount
if ($dnsList.Count -eq 0) {
    Write-Log -Message "No DNS entries to test! Check your dns-list.txt file." -Level Error
    Read-Host "Press Enter to exit"
    exit 1
}

# ── Initialize temp directory (clean stale files from previous runs) ──

Initialize-SlipstreamTempDir

# ── Decide: menu or direct connect ──

$hasOperationalArgs = $Connect -or $PSBoundParameters.ContainsKey('ConfigPath') -or $PSBoundParameters.ContainsKey('DnsListPath') -or $PSBoundParameters.ContainsKey('UserDnsPath') -or ($Workers -gt 0)

if (-not $hasOperationalArgs) {
    # Show interactive menu
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
    # ── Ctrl+C cleanup handler ──
    $cleanupBlock = {
        Write-Host ""
        Write-Host "Shutting down... killing slipstream-client processes..." -ForegroundColor Yellow
        Get-Process -Name "slipstream-client" -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
        Remove-SlipstreamTempDir
        Write-Host "Goodbye." -ForegroundColor Cyan
    }

    $null = Register-EngineEvent -SourceIdentifier PowerShell.Exiting -Action $cleanupBlock -ErrorAction SilentlyContinue

    trap {
        & $cleanupBlock
        break
    }

    try {
        # ── Phase 1: Find a working DNS ──

        Write-Host ""
        Write-Log -Message "=== Phase 1: Scanning for a working DNS ===" -Level Info

        $result = $null

        # Phase 1a: Test priority DNS first (tier 0 + tier 1)
        if ($priorityCount -gt 0) {
            Write-Host ""
            Write-Log -Message "Testing $priorityCount priority DNS entries first..." -Level Info
            $priorityList = @($dnsList[0..($priorityCount - 1)])
            $result = Start-DnsTesting -DnsList $priorityList -Config $config -ExePath $exePath -ResultsDirectory $resultsDir -StopAfterFound
        }

        # Phase 1b: Test remaining DNS (skip if already found)
        if (-not $result) {
            $remainingCount = $dnsList.Count - $priorityCount
            if ($remainingCount -gt 0) {
                Write-Host ""
                Write-Log -Message "Scanning $remainingCount DNS entries..." -Level Info
                $remainingList = @($dnsList[$priorityCount..($dnsList.Count - 1)])
                $result = Start-DnsTesting -DnsList $remainingList -Config $config -ExePath $exePath -ResultsDirectory $resultsDir -StopAfterFound
            }
        }

        if (-not $result) {
            Write-Host ""
            Write-Log -Message "No working DNS found after testing all entries." -Level Error
            Write-Log -Message "Things to try:" -Level Info
            Write-Log -Message "  1. Update your dns-list.txt with fresh DNS entries" -Level Info
            Write-Log -Message "  2. Delete results\dns-failed.txt to re-test previously failed ones" -Level Info
            Write-Log -Message "  3. Increase Workers in config.ini for faster scanning" -Level Info
            Write-Log -Message "  4. Try again later - some DNS resolvers are intermittent" -Level Info
            Read-Host "Press Enter to exit"
            exit 1
        }

        Write-Host ""
        Write-Log -Message "Best DNS: $($result.Dns) (score: $($result.Score)s)" -Level Success

        # ── Phase 2: Connect and maintain ──

        Write-Host ""
        Write-Log -Message "=== Phase 2: Establishing persistent connection ===" -Level Info

        $reconnectCount = 0
        $workingDns = $result.Dns
        $workingPath = Join-Path $resultsDir "dns-working.txt"

        while ($true) {
            if ($config.MaxReconnectAttempts -gt 0 -and $reconnectCount -ge $config.MaxReconnectAttempts) {
                Write-Log -Message "Max reconnect attempts ($($config.MaxReconnectAttempts)) reached. Stopping." -Level Error
                break
            }

            $port = Get-RandomPort

            if ($reconnectCount -eq 0) {
                Write-Log -Message "Connecting via $workingDns on port $port..." -Level Info
            } else {
                Write-Host ""
                Write-Log -Message "Reconnecting (attempt $reconnectCount) via $workingDns on port $port..." -Level Warning
            }

            $connection = Start-SlipstreamConnection -Dns $workingDns -Port $port -Config $config -ExePath $exePath

            if ($null -ne $connection) {
                Start-Sleep -Milliseconds 500
                $internetWorks = $false
                try {
                    $statusCode = & curl.exe --proxy "socks5://127.0.0.1:$port" `
                        --max-time $config.ConnectivityTimeout `
                        -s -o NUL -w "%{http_code}" `
                        $config.ConnectivityUrl 2>$null
                    if ($statusCode -eq "204") { $internetWorks = $true }
                } catch {}

                if ($internetWorks) {
                    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
                    Add-Content -Path $workingPath -Value "$workingDns | $timestamp" -Encoding UTF8

                    $stillAlive = Watch-Connection -Connection $connection -Port $port -Config $config
                    Stop-Connection -Connection $connection
                } else {
                    Write-Log -Message "Tunnel up via $workingDns but no internet" -Level Warning
                    Stop-Connection -Connection $connection
                }
            } else {
                Write-Log -Message "Failed to connect via $workingDns" -Level Warning
            }

            # Connection failed or dropped — re-scan for working DNS
            $reconnectCount++
            Write-Host ""
            Write-Log -Message "Re-scanning for a working DNS..." -Level Warning

            $result = $null

            if ($priorityCount -gt 0) {
                $priorityList = @($dnsList[0..($priorityCount - 1)])
                $result = Start-DnsTesting -DnsList $priorityList -Config $config -ExePath $exePath -ResultsDirectory $resultsDir -StopAfterFound
            }

            if (-not $result) {
                $remainingCount = $dnsList.Count - $priorityCount
                if ($remainingCount -gt 0) {
                    $remainingList = @($dnsList[$priorityCount..($dnsList.Count - 1)])
                    $result = Start-DnsTesting -DnsList $remainingList -Config $config -ExePath $exePath -ResultsDirectory $resultsDir -StopAfterFound
                }
            }

            if (-not $result) {
                Write-Host ""
                Write-Log -Message "No working DNS found after re-scanning." -Level Error
                Write-Log -Message "Things to try:" -Level Info
                Write-Log -Message "  1. Update your dns-list.txt with fresh DNS entries" -Level Info
                Write-Log -Message "  2. Delete results\dns-failed.txt to re-test previously failed ones" -Level Info
                Write-Log -Message "  3. Increase Workers in config.ini for faster scanning" -Level Info
                break
            }

            $workingDns = $result.Dns
        }
    }
    finally {
        # Always clean up on exit
        Get-Process -Name "slipstream-client" -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
        Remove-SlipstreamTempDir
    }

    Write-Host ""
    Write-Log -Message "SlipStream Connector has stopped." -Level Warning
    Read-Host "Press Enter to exit"
}
