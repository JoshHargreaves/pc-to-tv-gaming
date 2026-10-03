#Requires -Version 5.1
<#
.SYNOPSIS
  List connected displays and the ids to put in display-switch.config.ps1.
#>
$ErrorActionPreference = 'Stop'
. "$PSScriptRoot\DisplaySwitchCommon.ps1"

Write-Host ''
Write-Host 'Connected display paths (use a short unique piece of DeviceId in your config):'
Write-Host ''

[MonitorSwap]::ListMonitors() | ForEach-Object {
    $idShort = $null
    if ($_.DeviceId -match 'MONITOR\\([A-Z0-9]+)\\') { $idShort = $Matches[1] }
    $res = if ($_.CurrentWidth -gt 0) { '{0}x{1}' -f $_.CurrentWidth, $_.CurrentHeight } else { 'n/a' }
    Write-Host ("  {0}" -f $_.FriendlyName)
    Write-Host ("    Path:     {0}  (mon #{1})" -f $_.DeviceName, $_.MonitorIndex)
    Write-Host ("    DeviceId: {0}" -f $_.DeviceId)
    if ($idShort) {
        Write-Host ("    Config:   '{0}'" -f $idShort) -ForegroundColor Cyan
    }
    Write-Host ("    Active:   attached={0} primary={1} resolution={2}" -f $_.Attached, $_.Primary, $res)
    Write-Host ''
}

Write-Host 'Next: copy display-switch.config.example.ps1 to display-switch.config.ps1'
Write-Host '      and set MonitorMatch / TvMatch to the Config values above.'
Write-Host ''
