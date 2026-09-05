# Uninstall-Watcher.ps1
# Removes only the scheduled task created by Install-Watcher.ps1.

[CmdletBinding()]
param(
    [string]$TaskName = 'ChatGPT Overlay Fix Watcher',
    [switch]$RemoveLog
)

$ErrorActionPreference = 'Stop'
$task = Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue

if ($null -ne $task) {
    Stop-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
    Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false
    Write-Host "Removed scheduled task: $TaskName" -ForegroundColor Green
}
else {
    Write-Host "Scheduled task was not installed: $TaskName" -ForegroundColor Yellow
}

if ($RemoveLog) {
    $logDirectory = Join-Path $env:LOCALAPPDATA 'ChatGPTOverlayFix'
    if (Test-Path -LiteralPath $logDirectory -PathType Container) {
        Remove-Item -LiteralPath $logDirectory -Recurse -Force
        Write-Host "Removed log directory: $logDirectory"
    }
}

