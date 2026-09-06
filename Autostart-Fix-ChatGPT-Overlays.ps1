# Autostart-Fix-ChatGPT-Overlays.ps1
# Per-user installation and autostart management for ChatGPT Overlay Fix.
# PowerShell 5.1 compatible. No elevation or execution-policy changes are used.

[CmdletBinding()]
param(
    [switch]$Install,
    [ValidateSet('Task', 'Startup')][string]$Method = 'Task',
    [switch]$Status,
    [switch]$Remove
)

$script:PackageVersion = '3.1.0'
$ErrorActionPreference = 'Stop'
$script:InstallDirectory = Join-Path $env:LOCALAPPDATA 'ChatGPT-Overlay-Fix'
$script:TaskName = 'ChatGPT Overlay Fix Watcher'
$script:StartupLinkName = 'ChatGPT Overlay Fix Watcher.lnk'
$script:StopEventName = 'Local\ChatGPTOverlayFixWatcherStop'
$script:ScriptNames = @(
    'Fix-ChatGPT-Overlays.ps1',
    'Watch-ChatGPT-Overlays.ps1',
    'Autostart-Fix-ChatGPT-Overlays.ps1'
)

function Get-ScriptPackageVersion {
    param([Parameter(Mandatory = $true)][string]$Path)

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return $null }
    $match = [regex]::Match(
        (Get-Content -LiteralPath $Path -Raw),
        "(?m)^\s*\`$script:PackageVersion\s*=\s*'(?<Version>[^']+)'\s*$"
    )
    if ($match.Success) { return $match.Groups['Version'].Value }
    return $null
}

function Assert-Package {
    param([Parameter(Mandatory = $true)][string]$Directory)

    $versions = @{}
    foreach ($name in $script:ScriptNames) {
        $path = Join-Path $Directory $name
        if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
            throw "Required package file is missing: $path"
        }
        $version = Get-ScriptPackageVersion -Path $path
        if (-not $version) { throw "PackageVersion could not be read from: $path" }
        $versions[$name] = $version
    }

    $uniqueVersions = @($versions.Values | Select-Object -Unique)
    if ($uniqueVersions.Count -ne 1) {
        $details = ($versions.GetEnumerator() | Sort-Object Name | ForEach-Object { "$($_.Key)=$($_.Value)" }) -join ', '
        throw "The three scripts do not share one PackageVersion: $details"
    }
    if ($uniqueVersions[0] -ne $script:PackageVersion) {
        throw "Package version $($uniqueVersions[0]) does not match manager version $script:PackageVersion."
    }
    return $uniqueVersions[0]
}

function Get-InstalledWatcherPath {
    Join-Path $script:InstallDirectory 'Watch-ChatGPT-Overlays.ps1'
}

function Get-WatcherProcesses {
    $watcherPath = Get-InstalledWatcherPath
    try {
        @(Get-CimInstance Win32_Process -Filter "Name = 'powershell.exe'" -ErrorAction Stop | Where-Object {
            $_.ProcessId -ne $PID -and $_.CommandLine -and
            $_.CommandLine.IndexOf($watcherPath, [StringComparison]::OrdinalIgnoreCase) -ge 0
        })
    }
    catch { @() }
}

function Stop-InstalledWatcherForUpdate {
    param([Parameter(Mandatory = $true)][object[]]$Processes)

    if ($Processes.Count -eq 0) { return }
    try {
        $stopEvent = [System.Threading.EventWaitHandle]::OpenExisting($script:StopEventName)
        [void]$stopEvent.Set()
        $stopEvent.Dispose()
    }
    catch { }

    $deadline = (Get-Date).AddSeconds(8)
    do {
        Start-Sleep -Milliseconds 250
        $remaining = @(Get-WatcherProcesses)
    } while ($remaining.Count -gt 0 -and (Get-Date) -lt $deadline)

    if ($remaining.Count -gt 0) {
        foreach ($process in $remaining) {
            Stop-Process -Id ([int]$process.ProcessId) -Force -ErrorAction Stop
        }
    }
}

function Get-TaskAutostart {
    try {
        $task = Get-ScheduledTask -TaskName $script:TaskName -ErrorAction Stop
        $watcherPath = Get-InstalledWatcherPath
        $ours = @($task.Actions | Where-Object {
            $_.Execute -like '*powershell.exe' -and $_.Arguments -and
            $_.Arguments.IndexOf($watcherPath, [StringComparison]::OrdinalIgnoreCase) -ge 0
        }).Count -gt 0
        [pscustomobject]@{ Present = $true; Ours = $ours; Task = $task }
    }
    catch { [pscustomobject]@{ Present = $false; Ours = $false; Task = $null } }
}

function Get-StartupAutostart {
    $path = Join-Path ([Environment]::GetFolderPath('Startup')) $script:StartupLinkName
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
        return [pscustomobject]@{ Present = $false; Ours = $false; Path = $path }
    }

    $ours = $false
    try {
        $shortcut = (New-Object -ComObject WScript.Shell).CreateShortcut($path)
        $watcherPath = Get-InstalledWatcherPath
        $ours = $shortcut.TargetPath -like '*powershell.exe' -and
                $shortcut.Arguments.IndexOf($watcherPath, [StringComparison]::OrdinalIgnoreCase) -ge 0
    }
    catch { }
    [pscustomobject]@{ Present = $true; Ours = $ours; Path = $path }
}

function Remove-AutostartEntries {
    $task = Get-TaskAutostart
    if ($task.Ours) { Unregister-ScheduledTask -TaskName $script:TaskName -Confirm:$false -ErrorAction Stop }

    $startup = Get-StartupAutostart
    if ($startup.Ours) { Remove-Item -LiteralPath $startup.Path -Force -ErrorAction Stop }
}

function Register-TaskAutostart {
    $powerShellExe = Join-Path $PSHOME 'powershell.exe'
    $watcherPath = Get-InstalledWatcherPath
    $currentUser = [Security.Principal.WindowsIdentity]::GetCurrent().Name
    $action = New-ScheduledTaskAction -Execute $powerShellExe -Argument (
        '-NoProfile -WindowStyle Hidden -File "{0}" -Hidden' -f $watcherPath
    )
    $trigger = New-ScheduledTaskTrigger -AtLogOn -User $currentUser
    $principal = New-ScheduledTaskPrincipal -UserId $currentUser -LogonType Interactive -RunLevel Limited
    $settings = New-ScheduledTaskSettingsSet `
        -AllowStartIfOnBatteries `
        -DontStopIfGoingOnBatteries `
        -ExecutionTimeLimit ([TimeSpan]::Zero) `
        -MultipleInstances IgnoreNew

    Register-ScheduledTask -TaskName $script:TaskName -Action $action -Trigger $trigger `
        -Principal $principal -Settings $settings -Description 'Starts the ChatGPT Overlay Fix watcher for the current user.' | Out-Null
}

function Register-StartupAutostart {
    $startup = Get-StartupAutostart
    $powerShellExe = Join-Path $PSHOME 'powershell.exe'
    $watcherPath = Get-InstalledWatcherPath
    $shortcut = (New-Object -ComObject WScript.Shell).CreateShortcut($startup.Path)
    $shortcut.TargetPath = $powerShellExe
    $shortcut.Arguments = '-NoProfile -WindowStyle Hidden -File "{0}" -Hidden' -f $watcherPath
    $shortcut.WorkingDirectory = $script:InstallDirectory
    $shortcut.WindowStyle = 7
    $shortcut.Description = 'ChatGPT Overlay Fix Watcher'
    $shortcut.Save()
}

function Start-InstalledWatcher {
    $powerShellExe = Join-Path $PSHOME 'powershell.exe'
    $watcherPath = Get-InstalledWatcherPath
    Start-Process -FilePath $powerShellExe -ArgumentList @(
        '-NoProfile', '-WindowStyle', 'Hidden', '-File', ('"{0}"' -f $watcherPath), '-Hidden'
    ) -WindowStyle Hidden
}

function Show-Status {
    Write-Host ''
    Write-Host "ChatGPT Overlay Fix $script:PackageVersion" -ForegroundColor Cyan
    Write-Host "Install path : $script:InstallDirectory"

    $installed = @($script:ScriptNames | Where-Object {
        Test-Path -LiteralPath (Join-Path $script:InstallDirectory $_) -PathType Leaf
    }).Count -eq $script:ScriptNames.Count
    Write-Host "Complete package: $installed"
    foreach ($name in $script:ScriptNames) {
        $path = Join-Path $script:InstallDirectory $name
        $version = Get-ScriptPackageVersion -Path $path
        if ($version) { Write-Host "  $name : $version" }
        else { Write-Host "  $name : missing or invalid" -ForegroundColor Yellow }
    }

    $task = Get-TaskAutostart
    $startup = Get-StartupAutostart
    Write-Host "Task autostart   : $(if ($task.Ours) { 'Installed' } elseif ($task.Present) { 'Name conflict' } else { 'Not installed' })"
    Write-Host "Startup autostart: $(if ($startup.Ours) { 'Installed' } elseif ($startup.Present) { 'Name conflict' } else { 'Not installed' })"
    Write-Host "Watcher running  : $(@(Get-WatcherProcesses).Count -gt 0)"
}

function Read-MenuSelection {
    param([switch]$SelectionOnly)

    if (-not $SelectionOnly) {
        Write-Host ''
        Write-Host "ChatGPT Overlay Fix $script:PackageVersion" -ForegroundColor Cyan
        Write-Host ''
        Write-Host 'Select an action:'
        Write-Host ''
        Write-Host '  [1] Install using Scheduled Task (recommended)'
        Write-Host '  [2] Install using Startup folder'
        Write-Host '  [3] Show status'
        Write-Host '  [4] Remove autostart'
        Write-Host '  [5] Cancel'
        Write-Host ''
    }
    Write-Host 'Selection [1-5]: ' -NoNewline

    # Console hosts accept one key; hosts without ReadKey support use Enter.
    $useReadKey = $true
    while ($true) {
        if ($useReadKey) {
            try {
                $key = $Host.UI.RawUI.ReadKey('NoEcho,IncludeKeyDown')
                $selection = [string]$key.Character
            }
            catch {
                $useReadKey = $false
                Write-Host ''
                continue
            }
        }
        else {
            $selection = Read-Host 'Selection [1-5] (press Enter)'
        }

        if ($selection -match '^[1-5]$') {
            if ($useReadKey) { Write-Host $selection }
            return [int]$selection
        }
        if (-not $useReadKey) { Write-Host 'Please select a number from 1 to 5.' -ForegroundColor Yellow }
    }
}

$interactiveMode = ($PSBoundParameters.Count -eq 0)

try {
    $operationCount = [int][bool]$Install + [int][bool]$Status + [int][bool]$Remove
    if ($operationCount -gt 1) { throw 'Use only one operation: -Install, -Status, or -Remove.' }
    if (-not $Install -and $PSBoundParameters.ContainsKey('Method')) {
        throw '-Method can only be used together with -Install.'
    }

    # Interactive mode and -Status share the menu; other parameters run directly.
    if ($interactiveMode -or $Status) {
        if ($Status) {
            Show-Status
            $Status = $false
            $interactiveMode = $true
        }
        $selectionOnly = $false
        do {
            $selection = Read-MenuSelection -SelectionOnly:$selectionOnly
            if ($selection -eq 3) {
                Show-Status
                Write-Host ''
                $selectionOnly = $true
            }
        } while ($selection -eq 3)

        switch ($selection) {
            1 { $Install = $true; $Method = 'Task' }
            2 { $Install = $true; $Method = 'Startup' }
            4 { $Remove = $true }
            5 { exit 0 }
        }
    }

    if (-not $Install -and -not $Status -and -not $Remove) {
        Show-Status
        exit 0
    }

    if ($Remove) {
        Remove-AutostartEntries
        Show-Status
        if ($interactiveMode) {
            Write-Host 'Autostart was removed. Installed files and a running watcher were left unchanged.' -ForegroundColor Green
            $answer = Read-Host 'Open the install folder now? [y/N]'
            if ($answer -match '(?i)^y(es)?$') { Start-Process -FilePath 'explorer.exe' -ArgumentList ('"{0}"' -f $script:InstallDirectory) }
        }
        exit 0
    }

    $sourceVersion = Assert-Package -Directory $PSScriptRoot
    $runningProcesses = @(Get-WatcherProcesses)
    $watcherWasRunning = ($runningProcesses.Count -gt 0)
    if ($watcherWasRunning) { Stop-InstalledWatcherForUpdate -Processes $runningProcesses }

    New-Item -ItemType Directory -Path $script:InstallDirectory -Force | Out-Null
    foreach ($name in $script:ScriptNames) {
        $sourcePath = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot $name))
        $destinationPath = [IO.Path]::GetFullPath((Join-Path $script:InstallDirectory $name))
        if (-not $sourcePath.Equals($destinationPath, [StringComparison]::OrdinalIgnoreCase)) {
            Copy-Item -LiteralPath $sourcePath -Destination $destinationPath -Force
        }
    }
    foreach ($name in $script:ScriptNames) {
        Unblock-File -LiteralPath (Join-Path $script:InstallDirectory $name) -ErrorAction Stop
    }

    [void](Assert-Package -Directory $script:InstallDirectory)
    $taskBefore = Get-TaskAutostart
    $startupBefore = Get-StartupAutostart
    if ($Method -eq 'Task' -and $taskBefore.Present -and -not $taskBefore.Ours) {
        throw "A different scheduled task already uses the name '$script:TaskName'."
    }
    if ($Method -eq 'Startup' -and $startupBefore.Present -and -not $startupBefore.Ours) {
        throw "A different Startup shortcut already uses the name '$script:StartupLinkName'."
    }
    Remove-AutostartEntries
    if ($Method -eq 'Task') { Register-TaskAutostart }
    else { Register-StartupAutostart }

    Start-InstalledWatcher
    if ($interactiveMode) {
        Write-Host "ChatGPT Overlay Fix $sourceVersion was installed using the $Method autostart method." -ForegroundColor Green
    }
    Show-Status
    exit 0
}
catch {
    Write-Error $_.Exception.Message
    exit 1
}
