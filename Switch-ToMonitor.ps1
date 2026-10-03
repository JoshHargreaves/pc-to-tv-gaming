#Requires -Version 5.1
<#
.SYNOPSIS
  Switch back to the PC monitor only, and exit the couch UI if needed.
#>
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
. "$PSScriptRoot\DisplaySwitchCommon.ps1"

try {
    $cfg = Get-DisplaySwitchConfig
    Write-SwitchLog '===== PC Monitor ====='
    Exit-TvShell -TvWidth $cfg.TvWidth -TvHeight $cfg.TvHeight
    Invoke-MonitorSwitch `
        -Match $cfg.MonitorMatch `
        -PreferWidth $cfg.MonitorWidth `
        -PreferHeight $cfg.MonitorHeight `
        -Label $cfg.MonitorLabel `
        -AlsoDisableMatch $cfg.TvMatch
    Write-SwitchLog 'Done.'
}
catch {
    Write-SwitchLog "ERROR: $($_.Exception.Message)"
    Write-Host ''
    Write-Host 'Press any key to close...'
    try { $null = $Host.UI.RawUI.ReadKey('NoEcho,IncludeKeyDown') } catch { Start-Sleep -Seconds 8 }
    exit 1
}
