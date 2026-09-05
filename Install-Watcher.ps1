# Install-Watcher.ps1
# Installs the overlay watcher as a current-user scheduled task.

[CmdletBinding()]
param(
    [string]$TaskName = 'ChatGPT Overlay Fix Watcher',
    [switch]$DoNotStart
)

$ErrorActionPreference = 'Stop'
$watcherPath = Join-Path $PSScriptRoot 'Watch-ChatGPT-Overlays.ps1'

if (-not (Test-Path -LiteralPath $watcherPath -PathType Leaf)) {
    throw "The watcher script was not found: $watcherPath"
}

$powerShellPath = (Get-Command powershell.exe -ErrorAction Stop).Source
$arguments = '-NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File "{0}"' -f $watcherPath
$userId = '{0}\{1}' -f $env:USERDOMAIN, $env:USERNAME

$action = New-ScheduledTaskAction -Execute $powerShellPath -Argument $arguments
$trigger = New-ScheduledTaskTrigger -AtLogOn -User $userId
$principal = New-ScheduledTaskPrincipal -UserId $userId -LogonType Interactive -RunLevel Limited
$settings = New-ScheduledTaskSettingsSet `
    -AllowStartIfOnBatteries `
    -DontStopIfGoingOnBatteries `
    -ExecutionTimeLimit ([TimeSpan]::Zero) `
    -MultipleInstances IgnoreNew `
    -RestartCount 3 `
    -RestartInterval (New-TimeSpan -Minutes 1)

$task = New-ScheduledTask `
    -Action $action `
    -Trigger $trigger `
    -Principal $principal `
    -Settings $settings `
    -Description 'Automatically refreshes newly created ChatGPT/Codex Pet and Voice overlay windows.'

[void](Register-ScheduledTask -TaskName $TaskName -InputObject $task -Force)

if (-not $DoNotStart) {
    Start-ScheduledTask -TaskName $TaskName
}

Write-Host "Installed scheduled task: $TaskName" -ForegroundColor Green
Write-Host "Watcher script: $watcherPath"
Write-Host "Log file: $env:LOCALAPPDATA\ChatGPTOverlayFix\watcher.log"
Write-Host 'Run Uninstall-Watcher.ps1 to remove the scheduled task.'

