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
