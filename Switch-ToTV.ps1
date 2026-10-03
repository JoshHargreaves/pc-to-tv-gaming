#Requires -Version 5.1
<#
.SYNOPSIS
  Switch to the TV only, then launch the configured couch UI (Xbox mode or Steam Big Picture).

.NOTES
  Turn the TV on and set it to the PC HDMI input before running.
  Display ids, resolutions, and TvMode come from display-switch.config.ps1.
#>
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
. "$PSScriptRoot\DisplaySwitchCommon.ps1"

try {
    $cfg = Get-DisplaySwitchConfig
    $shellName = if ($cfg.TvMode -eq 'BigPicture') { 'Steam Big Picture' } else { 'Xbox Mode' }
    Write-SwitchLog ('===== {0} + {1} =====' -f $cfg.TvLabel, $shellName)

    Invoke-MonitorSwitch `
        -Match $cfg.TvMatch `
        -PreferWidth $cfg.TvWidth `
        -PreferHeight $cfg.TvHeight `
        -Label $cfg.TvLabel

    if ([int]$cfg.ModeDelaySeconds -gt 0) {
        Start-Sleep -Seconds ([int]$cfg.ModeDelaySeconds)
    }

    Enter-TvShell -Mode $cfg.TvMode
    Write-SwitchLog 'Done.'
}
catch {
    Write-SwitchLog "ERROR: $($_.Exception.Message)"
    Write-Host ''
    Write-Host 'Press any key to close...'
    try { $null = $Host.UI.RawUI.ReadKey('NoEcho,IncludeKeyDown') } catch { Start-Sleep -Seconds 8 }
    exit 1
}
