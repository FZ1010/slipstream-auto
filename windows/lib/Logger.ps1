# lib/Logger.ps1
# Provides colored console output and file logging for SlipStream Connector

$script:LogFile = $null

function Initialize-Logger {
    param(
        [string]$LogDirectory
    )
    if (-not (Test-Path $LogDirectory)) {
        New-Item -ItemType Directory -Path $LogDirectory -Force | Out-Null
    }
    $script:LogFile = Join-Path $LogDirectory "session.log"
    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    Set-Content -Path $script:LogFile -Value "=== SlipStream Connector Session - $timestamp ===" -Encoding UTF8
}

function Write-Log {
    param(
        [Parameter(Mandatory)]
        [string]$Message,
        [ValidateSet("Info", "Success", "Warning", "Error", "Debug")]
        [string]$Level = "Info"
    )

    $timestamp = Get-Date -Format "HH:mm:ss"
    $prefix = switch ($Level) {
        "Info"    { "[*]" }
        "Success" { "[+]" }
        "Warning" { "[!]" }
        "Error"   { "[-]" }
        "Debug"   { "[.]" }
    }
    $color = switch ($Level) {
        "Info"    { "Cyan" }
        "Success" { "Green" }
        "Warning" { "Yellow" }
        "Error"   { "Red" }
        "Debug"   { "DarkGray" }
    }

    $line = "$timestamp $prefix $Message"
    Write-Host $line -ForegroundColor $color

    if ($script:LogFile) {
        Add-Content -Path $script:LogFile -Value $line -Encoding UTF8
    }
}

function Show-ConfigSummary {
    param(
        [hashtable]$Config,
        [int]$Tier0Count = 0,
        [int]$Tier1Count = 0,
        [int]$Tier2Count = 0,
        [int]$SkippedCount = 0,
        [int]$TotalCount = 0
    )

    Write-Host ""
    Write-Host "  -- Configuration ------------------------------------------" -ForegroundColor Cyan
    Write-Host ("     {0,-18} " -f "Domain:") -NoNewline; Write-Host $Config.Domain -ForegroundColor Green
    Write-Host ("     {0,-18} " -f "Workers:") -NoNewline; Write-Host $Config.Workers -ForegroundColor Green
    Write-Host ("     {0,-18} " -f "Timeout:") -NoNewline; Write-Host "$($Config.Timeout)s" -ForegroundColor Green
    Write-Host ("     {0,-18} " -f "Health Check:") -NoNewline; Write-Host "$($Config.HealthCheckInterval)s" -ForegroundColor Green
    $reconnectDisplay = if ($Config.MaxReconnectAttempts -eq 0) { "unlimited" } else { "$($Config.MaxReconnectAttempts)" }
    Write-Host ("     {0,-18} " -f "Max Reconnects:") -NoNewline; Write-Host $reconnectDisplay -ForegroundColor Green
    Write-Host ""
    Write-Host "  -- DNS Queue -----------------------------------------------" -ForegroundColor Cyan
    Write-Host ("     {0,-18} " -f "Custom:") -NoNewline; Write-Host $Tier0Count -ForegroundColor Green
    Write-Host ("     {0,-18} " -f "Working:") -NoNewline; Write-Host $Tier1Count -ForegroundColor Green
    Write-Host ("     {0,-18} " -f "DNS List:") -NoNewline; Write-Host $Tier2Count -ForegroundColor Green
    Write-Host ("     {0,-18} " -f "Skipped:") -NoNewline; Write-Host $SkippedCount -ForegroundColor Yellow
    Write-Host "     ------------------------------" -ForegroundColor DarkGray
    Write-Host ("     {0,-18} " -f "Total:") -NoNewline; Write-Host $TotalCount -ForegroundColor Cyan
    Write-Host ""
}

function Write-Banner {
    $banner = @"

  ____  _ _       ____  _
 / ___|| (_)_ __ / ___|| |_ _ __ ___  __ _ _ __ ___
 \___ \| | | '_ \\___ \| __| '__/ _ \/ _`` | '_ `` _ \
  ___) | | | |_) |___) | |_| | |  __/ (_| | | | | | |
 |____/|_|_| .__/|____/ \__|_|  \___|\__,_|_| |_| |_|
            |_|        Auto Connector v1.0

"@
    Write-Host $banner -ForegroundColor Cyan
}
