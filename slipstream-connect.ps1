# slipstream-connect.ps1
# Main orchestrator for SlipStream Auto Connector
# Finds a working DNS resolver, connects, and maintains the connection

param(
    [string]$ConfigPath = "",
    [string]$DnsListPath = "",
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
  -Workers <number>     Override parallel worker count (default: from config)
  -Help                 Show this message

EXAMPLES:
  .\start.bat                              # Just double-click and go
  .\slipstream-connect.ps1 -Workers 10     # Test 10 DNS at once
  .\slipstream-connect.ps1 -DnsListPath "C:\my-dns.txt"

"@
    exit 0
}

# Resolve paths
if (-not $ConfigPath) { $ConfigPath = Join-Path $scriptRoot "config.ini" }
if (-not $DnsListPath) { $DnsListPath = Join-Path $scriptRoot "dns-list.txt" }
$resultsDir = Join-Path $scriptRoot "results"
$exePath = Join-Path $scriptRoot "slipstream-client.exe"

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

$dnsList = Read-DnsList -Path $DnsListPath -Config $config -ResultsDirectory $resultsDir
if ($dnsList.Count -eq 0) {
    Write-Log -Message "No DNS entries to test! Check your dns-list.txt file." -Level Error
    Read-Host "Press Enter to exit"
    exit 1
}

# ── Phase 1: Find a working DNS ──

Write-Host ""
Write-Log -Message "=== Phase 1: Scanning for a working DNS ===" -Level Info
Write-Host ""

$result = Start-DnsTesting -DnsList $dnsList -Config $config -ExePath $exePath -ResultsDirectory $resultsDir

if (-not $result) {
    Write-Host ""
    Write-Log -Message "No working DNS found after testing all entries." -Level Error
    Write-Log -Message "Things to try:" -Level Info
    Write-Log -Message "  1. Update your dns-list.txt with fresh DNS entries" -Level Info
    Write-Log -Message "  2. Delete results\failed-dns.txt to re-test previously failed ones" -Level Info
    Write-Log -Message "  3. Increase Workers in config.ini for faster scanning" -Level Info
    Write-Log -Message "  4. Try again later - some DNS resolvers are intermittent" -Level Info
    Read-Host "Press Enter to exit"
    exit 1
}

# ── Phase 2: Connect and maintain ──

Write-Host ""
Write-Log -Message "=== Phase 2: Establishing persistent connection ===" -Level Info

# Start connection loop from the next DNS after the one we found
$startIndex = 0
for ($j = 0; $j -lt $dnsList.Count; $j++) {
    if ($dnsList[$j] -eq $result.Dns) {
        $startIndex = $j
        break
    }
}

Start-ConnectionLoop -DnsList $dnsList -StartIndex $startIndex -Config $config -ExePath $exePath -ResultsDirectory $resultsDir

Write-Host ""
Write-Log -Message "SlipStream Connector has stopped." -Level Warning
Read-Host "Press Enter to exit"
