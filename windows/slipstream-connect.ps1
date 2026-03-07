# slipstream-connect.ps1
# Main orchestrator for SlipStream Auto Connector
# Finds a working DNS resolver, connects, and maintains the connection

[CmdletBinding()]
param(
    [string]$ConfigPath = "",
    [string]$DnsListPath = "",
    [string]$UserDnsPath = "",
    [int]$Workers = 0,
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
  -Help                 Show this message

EXAMPLES:
  .\start.bat                              # Just double-click and go
  .\slipstream-connect.ps1 -Workers 10     # Test 10 DNS at once
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
$resolversPath = Join-Path $projectRoot "dns-resolvers.txt"
$resultsDir = Join-Path $projectRoot "results"
$exePath = Join-Path $projectRoot "slipstream-client.exe"

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

$dnsData = Read-DnsList -Path $DnsListPath -ResolversPath $resolversPath -CustomPath $UserDnsPath -Config $config -ResultsDirectory $resultsDir
$dnsList = $dnsData.DnsList
$priorityCount = $dnsData.PriorityCount
if ($dnsList.Count -eq 0) {
    Write-Log -Message "No DNS entries to test! Check your dns-list.txt file." -Level Error
    Read-Host "Press Enter to exit"
    exit 1
}

# ── Ctrl+C cleanup handler ──
# Ensure all slipstream-client processes we spawned get killed on exit

$cleanupBlock = {
    Write-Host ""
    Write-Host "Shutting down... killing slipstream-client processes..." -ForegroundColor Yellow
    Get-Process -Name "slipstream-client" -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
    Write-Host "Goodbye." -ForegroundColor Cyan
}

$null = Register-EngineEvent -SourceIdentifier PowerShell.Exiting -Action $cleanupBlock -ErrorAction SilentlyContinue

# Also handle Ctrl+C via trap
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
        $result = Start-DnsTesting -DnsList $priorityList -Config $config -ExePath $exePath -ResultsDirectory $resultsDir
    }

    # Phase 1b: If no priority DNS worked, test the rest
    if (-not $result) {
        $remainingCount = $dnsList.Count - $priorityCount
        if ($remainingCount -gt 0) {
            Write-Host ""
            Write-Log -Message "Scanning remaining $remainingCount DNS entries..." -Level Info
            $remainingList = @($dnsList[$priorityCount..($dnsList.Count - 1)])
            $result = Start-DnsTesting -DnsList $remainingList -Config $config -ExePath $exePath -ResultsDirectory $resultsDir
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

    # ── Phase 2: Connect and maintain ──

    Write-Host ""
    Write-Log -Message "=== Phase 2: Establishing persistent connection ===" -Level Info

    $startIndex = 0
    for ($j = 0; $j -lt $dnsList.Count; $j++) {
        if ($dnsList[$j] -eq $result.Dns) {
            $startIndex = $j
            break
        }
    }

    Start-ConnectionLoop -DnsList $dnsList -StartIndex $startIndex -Config $config -ExePath $exePath -ResultsDirectory $resultsDir
}
finally {
    # Always clean up on exit
    Get-Process -Name "slipstream-client" -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
}

Write-Host ""
Write-Log -Message "SlipStream Connector has stopped." -Level Warning
Read-Host "Press Enter to exit"
