# Watch-ChatGPT-Overlays.ps1
# Hidden per-user tray watcher for the ChatGPT overlay workaround.
# PowerShell 5.1 compatible.

[CmdletBinding()]
param([switch]$Hidden)

$script:PackageVersion = '3.1.0'
$ErrorActionPreference = 'Stop'
$script:AppDirectory = Join-Path $env:LOCALAPPDATA 'ChatGPT-Overlay-Fix'
$script:FixPath = Join-Path $PSScriptRoot 'Fix-ChatGPT-Overlays.ps1'
$script:LogPath = Join-Path $script:AppDirectory 'Watcher.log'
$script:StatePath = Join-Path $script:AppDirectory 'state.json'
$script:TaskName = 'ChatGPT Overlay Fix Watcher'
$script:StartupLinkName = 'ChatGPT Overlay Fix Watcher.lnk'
$script:MutexName = 'Local\ChatGPTOverlayFixWatcherV3'
$script:StopEventName = 'Local\ChatGPTOverlayFixWatcherStop'
$script:CurrentSession = $null
$script:CurrentChatGPTVersion = $null
$script:AutomaticAttempts = 0
$script:SessionFixed = $false
$script:WatcherState = 'Waiting for ChatGPT'
$script:ExitRequested = $false

if (-not $Hidden) {
    $powerShellExe = Join-Path $PSHOME 'powershell.exe'
    Start-Process -FilePath $powerShellExe -ArgumentList @(
        '-NoProfile', '-WindowStyle', 'Hidden', '-File', ('"{0}"' -f $PSCommandPath), '-Hidden'
    ) -WindowStyle Hidden
    exit 0
}

if (-not [Environment]::UserInteractive -or -not $env:LOCALAPPDATA) { exit 1 }
New-Item -ItemType Directory -Path $script:AppDirectory -Force | Out-Null

function Write-WatcherLog {
    param([Parameter(Mandatory = $true)][string]$Message)

    try {
        if ((Test-Path -LiteralPath $script:LogPath) -and
            (Get-Item -LiteralPath $script:LogPath).Length -ge 1MB) {
            $archive = "$script:LogPath.old"
            Move-Item -LiteralPath $script:LogPath -Destination $archive -Force
        }
        Add-Content -LiteralPath $script:LogPath -Encoding UTF8 -Value (
            '{0} [{1}] {2}' -f (Get-Date).ToString('yyyy-MM-dd HH:mm:ss'), $script:WatcherState, $Message
        )
    }
    catch { }
}

function New-DefaultState {
    [ordered]@{
        SchemaVersion = 1
        PackageVersion = $script:PackageVersion
        LastChatGPTVersion = $null
        LastChatGPTVersionChange = $null
        LastSuccessfulFix = $null
        LastSuccessfulFixChatGPTVersion = $null
    }
}

function Read-State {
    $state = New-DefaultState
    if (-not (Test-Path -LiteralPath $script:StatePath)) { return $state }

    try {
        $loaded = Get-Content -LiteralPath $script:StatePath -Raw -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop
        foreach ($name in @($state.Keys)) {
            if ($loaded.PSObject.Properties.Name -contains $name) { $state[$name] = $loaded.$name }
        }
    }
    catch {
        Write-WatcherLog "Ignoring invalid state.json: $($_.Exception.Message)"
    }
    $state.PackageVersion = $script:PackageVersion
    return $state
}

function Write-State {
    param([Parameter(Mandatory = $true)]$State)

    $clean = [ordered]@{
        SchemaVersion = 1
        PackageVersion = $script:PackageVersion
        LastChatGPTVersion = $State.LastChatGPTVersion
        LastChatGPTVersionChange = $State.LastChatGPTVersionChange
        LastSuccessfulFix = $State.LastSuccessfulFix
        LastSuccessfulFixChatGPTVersion = $State.LastSuccessfulFixChatGPTVersion
    }
    $temporaryPath = "$script:StatePath.$([Guid]::NewGuid().ToString('N')).tmp"
    try {
        $clean | ConvertTo-Json | Set-Content -LiteralPath $temporaryPath -Encoding UTF8
        Move-Item -LiteralPath $temporaryPath -Destination $script:StatePath -Force
    }
    catch {
        Remove-Item -LiteralPath $temporaryPath -Force -ErrorAction SilentlyContinue
        Write-WatcherLog "Could not write state.json: $($_.Exception.Message)"
    }
}

function Set-WatcherState {
    param([Parameter(Mandatory = $true)][ValidateSet('Waiting for ChatGPT', 'Waiting for overlay', 'Watching', 'Error')][string]$State)

    if ($script:WatcherState -ne $State) {
        $script:WatcherState = $State
        Write-WatcherLog "State changed to: $State"
    }
    if ($script:NotifyIcon) {
        $script:NotifyIcon.Text = "ChatGPT Overlay Fix - $State"
    }
}

function Get-MainChatGPTProcess {
    $processes = @(Get-Process -Name 'ChatGPT' -ErrorAction SilentlyContinue)
    if (-not $processes) { return $null }

    $candidates = foreach ($process in $processes) {
        try {
            [pscustomobject]@{
                Process = $process
                HasMainWindow = ($process.MainWindowHandle -ne [IntPtr]::Zero)
                StartTime = $process.StartTime
            }
        }
        catch { }
    }
    $selected = $candidates | Sort-Object @{ Expression = 'HasMainWindow'; Descending = $true }, StartTime | Select-Object -First 1
    if (-not $selected) { return $null }
    return $selected.Process
}

function Get-ProcessIdentity {
    param([Parameter(Mandatory = $true)]$Process)
    try { return '{0}|{1}' -f $Process.Id, $Process.StartTime.ToUniversalTime().Ticks }
    catch { return $null }
}

function Get-ChatGPTVersion {
    param([Parameter(Mandatory = $true)]$Process)
    try {
        $versionInfo = $Process.MainModule.FileVersionInfo
        if ($versionInfo.FileVersion) { return [string]$versionInfo.FileVersion }
        if ($versionInfo.ProductVersion) { return [string]$versionInfo.ProductVersion }
    }
    catch { Write-WatcherLog "Could not read ChatGPT version: $($_.Exception.Message)" }
    return 'Unknown'
}

if (-not ('ChatGPTOverlayPrecheckV3' -as [type])) {
    Add-Type @"
using System;
using System.Runtime.InteropServices;
using System.Text;
public static class ChatGPTOverlayPrecheckV3
{
    public delegate bool EnumWindowsProc(IntPtr hWnd, IntPtr lParam);
    public const int GWL_EXSTYLE = -20;
    public const long WS_EX_TOPMOST = 0x00000008L;
    public const long WS_EX_TOOLWINDOW = 0x00000080L;
    public const long WS_EX_LAYERED = 0x00080000L;
    [DllImport("user32.dll")] public static extern bool EnumWindows(EnumWindowsProc callback, IntPtr parameter);
    [DllImport("user32.dll")] public static extern bool IsWindowVisible(IntPtr hWnd);
    [DllImport("user32.dll")] public static extern uint GetWindowThreadProcessId(IntPtr hWnd, out uint processId);
    [DllImport("user32.dll", CharSet = CharSet.Auto)] public static extern int GetClassName(IntPtr hWnd, StringBuilder value, int capacity);
    [DllImport("user32.dll", EntryPoint = "GetWindowLongPtr")] public static extern IntPtr GetWindowLongPtr(IntPtr hWnd, int index);
}
"@
}

function Test-OverlayPresent {
    param([Parameter(Mandatory = $true)][int[]]$ProcessIds)

    $found = [System.Collections.Generic.List[bool]]::new()
    [void][ChatGPTOverlayPrecheckV3]::EnumWindows({
        param($handle, $parameter)
        $pidValue = [uint32]0
        [void][ChatGPTOverlayPrecheckV3]::GetWindowThreadProcessId($handle, [ref]$pidValue)
        if (($ProcessIds -contains [int]$pidValue) -and [ChatGPTOverlayPrecheckV3]::IsWindowVisible($handle)) {
            $class = New-Object System.Text.StringBuilder 256
            [void][ChatGPTOverlayPrecheckV3]::GetClassName($handle, $class, $class.Capacity)
            $style = [ChatGPTOverlayPrecheckV3]::GetWindowLongPtr($handle, [ChatGPTOverlayPrecheckV3]::GWL_EXSTYLE).ToInt64()
            if (($class.ToString() -eq 'Chrome_WidgetWin_1') -and
                ($style -band [ChatGPTOverlayPrecheckV3]::WS_EX_LAYERED) -and
                (($style -band [ChatGPTOverlayPrecheckV3]::WS_EX_TOPMOST) -or ($style -band [ChatGPTOverlayPrecheckV3]::WS_EX_TOOLWINDOW))) {
                $found.Add($true)
                return $false
            }
        }
        return $true
    }, [IntPtr]::Zero)
    return ($found.Count -gt 0)
}

function Get-OurAutostartDetails {
    $watcherPath = Join-Path $script:AppDirectory 'Watch-ChatGPT-Overlays.ps1'
    $taskPresent = $false
    try {
        $task = Get-ScheduledTask -TaskName $script:TaskName -ErrorAction Stop
        $taskPresent = @($task.Actions | Where-Object {
            $_.Arguments -and $_.Arguments.IndexOf($watcherPath, [StringComparison]::OrdinalIgnoreCase) -ge 0
        }).Count -gt 0
    }
    catch { }

    $startupPath = Join-Path ([Environment]::GetFolderPath('Startup')) $script:StartupLinkName
    $startupPresent = $false
    if (Test-Path -LiteralPath $startupPath -PathType Leaf) {
        try {
            $shortcut = (New-Object -ComObject WScript.Shell).CreateShortcut($startupPath)
            $startupPresent = $shortcut.TargetPath -like '*powershell.exe' -and
                $shortcut.Arguments.IndexOf($watcherPath, [StringComparison]::OrdinalIgnoreCase) -ge 0
        }
        catch { }
    }
    [pscustomobject]@{ Task = $taskPresent; Startup = $startupPresent; StartupPath = $startupPath }
}

function Test-OurAutostart {
    $details = Get-OurAutostartDetails
    return ($details.Task -or $details.Startup)
}

function Remove-OurAutostart {
    $details = Get-OurAutostartDetails
    if ($details.Task) {
        try { Unregister-ScheduledTask -TaskName $script:TaskName -Confirm:$false -ErrorAction Stop } catch { }
    }
    if ($details.Startup) {
        Remove-Item -LiteralPath $details.StartupPath -Force -ErrorAction SilentlyContinue
    }
    Write-WatcherLog 'Autostart removed from the tray menu.'
}

function Show-Notification {
    param([string]$Title, [string]$Text, $Icon)
    if ($null -eq $Icon) { $Icon = [System.Windows.Forms.ToolTipIcon]::Info }
    $script:NotifyIcon.BalloonTipTitle = $Title
    $script:NotifyIcon.BalloonTipText = $Text
    $script:NotifyIcon.BalloonTipIcon = $Icon
    $script:NotifyIcon.ShowBalloonTip(5000)
}

function Invoke-FixProcess {
    param([switch]$Manual)

    if ($Manual) {
        $mainProcess = Get-MainChatGPTProcess
        if ($mainProcess) {
            $identity = Get-ProcessIdentity $mainProcess
            if ($identity -and $identity -ne $script:CurrentSession) {
                $script:CurrentSession = $identity
                $script:CurrentChatGPTVersion = Get-ChatGPTVersion $mainProcess
                $script:AutomaticAttempts = 0
                $script:SessionFixed = $false
            }
        }
    }

    if (-not (Test-Path -LiteralPath $script:FixPath -PathType Leaf)) {
        Set-WatcherState 'Error'
        Write-WatcherLog "Fix script is missing: $script:FixPath"
        if ($Manual) { Show-Notification 'ChatGPT Overlay Fix' 'Fix-ChatGPT-Overlays.ps1 is missing.' ([System.Windows.Forms.ToolTipIcon]::Error) }
        return
    }

    try {
        $startInfo = New-Object System.Diagnostics.ProcessStartInfo
        $startInfo.FileName = Join-Path $PSHOME 'powershell.exe'
        $startInfo.Arguments = '-NoProfile -File "{0}"' -f $script:FixPath
        $startInfo.UseShellExecute = $false
        $startInfo.CreateNoWindow = $true
        $startInfo.RedirectStandardOutput = $true
        $startInfo.RedirectStandardError = $true
        $process = [System.Diagnostics.Process]::Start($startInfo)
        $standardOutput = $process.StandardOutput.ReadToEnd()
        $standardError = $process.StandardError.ReadToEnd()
        $process.WaitForExit()

        if ($process.ExitCode -eq 0) {
            $script:SessionFixed = $true
            $state = Read-State
            $state.LastSuccessfulFix = (Get-Date).ToUniversalTime().ToString('o')
            $state.LastSuccessfulFixChatGPTVersion = $script:CurrentChatGPTVersion
            Write-State $state
            Set-WatcherState 'Watching'
            Write-WatcherLog 'Overlay fix completed successfully.'
            if ($Manual) { Show-Notification 'ChatGPT Overlay Fix' 'Fix completed successfully.' }
        }
        elseif ($process.ExitCode -eq 2) {
            if (Get-MainChatGPTProcess) { Set-WatcherState 'Waiting for overlay' }
            else { Set-WatcherState 'Waiting for ChatGPT' }
            Write-WatcherLog 'Fix returned exit code 2: no matching overlay.'
            if ($Manual) { Show-Notification 'ChatGPT Overlay Fix' 'No matching overlay is currently available.' }
        }
        else {
            Set-WatcherState 'Error'
            Write-WatcherLog "Fix failed with exit code $($process.ExitCode). stdout: $standardOutput stderr: $standardError"
            if ($Manual) { Show-Notification 'ChatGPT Overlay Fix' 'The fix failed. Open the log for details.' ([System.Windows.Forms.ToolTipIcon]::Error) }
        }
    }
    catch {
        Set-WatcherState 'Error'
        Write-WatcherLog "Could not launch the fix: $($_.Exception.Message)"
        if ($Manual) { Show-Notification 'ChatGPT Overlay Fix' 'The fix could not be started.' ([System.Windows.Forms.ToolTipIcon]::Error) }
    }
}

function Update-ChatGPTSession {
    $mainProcess = Get-MainChatGPTProcess
    if (-not $mainProcess) {
        if ($script:CurrentSession) { Write-WatcherLog 'ChatGPT session ended.' }
        $script:CurrentSession = $null
        $script:CurrentChatGPTVersion = $null
        $script:AutomaticAttempts = 0
        $script:SessionFixed = $false
        Set-WatcherState 'Waiting for ChatGPT'
        return
    }

    $identity = Get-ProcessIdentity $mainProcess
    if (-not $identity) { return }
    if ($identity -ne $script:CurrentSession) {
        $script:CurrentSession = $identity
        $script:AutomaticAttempts = 0
        $script:SessionFixed = $false
        $script:CurrentChatGPTVersion = Get-ChatGPTVersion $mainProcess
        Write-WatcherLog "New ChatGPT session: $identity, version $script:CurrentChatGPTVersion"

        $state = Read-State
        if ($state.LastChatGPTVersion -and $state.LastChatGPTVersion -ne $script:CurrentChatGPTVersion) {
            $oldVersion = $state.LastChatGPTVersion
            $state.LastChatGPTVersionChange = (Get-Date).ToUniversalTime().ToString('o')
            Show-Notification 'ChatGPT version changed' "ChatGPT changed from $oldVersion to $script:CurrentChatGPTVersion. The workaround remains enabled."
        }
        $state.LastChatGPTVersion = $script:CurrentChatGPTVersion
        Write-State $state
        Set-WatcherState 'Waiting for overlay'
    }

    if ($script:SessionFixed) {
        Set-WatcherState 'Watching'
        return
    }
    if ($script:AutomaticAttempts -ge 3) {
        Set-WatcherState 'Error'
        return
    }

    $allPids = @(Get-Process -Name 'ChatGPT' -ErrorAction SilentlyContinue | Select-Object -ExpandProperty Id)
    if ($allPids.Count -gt 0 -and (Test-OverlayPresent -ProcessIds $allPids)) {
        $script:AutomaticAttempts++
        Write-WatcherLog "Starting automatic fix attempt $script:AutomaticAttempts of 3."
        Invoke-FixProcess
    }
    else {
        Set-WatcherState 'Waiting for overlay'
    }
}

$createdNew = $false
$script:Mutex = New-Object System.Threading.Mutex($true, $script:MutexName, [ref]$createdNew)
if (-not $createdNew) {
    $script:Mutex.Dispose()
    exit 0
}
$script:StopEvent = New-Object System.Threading.EventWaitHandle($false, [System.Threading.EventResetMode]::AutoReset, $script:StopEventName)

try {
    Add-Type -AssemblyName System.Windows.Forms
    Add-Type -AssemblyName System.Drawing

    $script:NotifyIcon = New-Object System.Windows.Forms.NotifyIcon
    $script:NotifyIcon.Icon = [System.Drawing.SystemIcons]::Application
    $script:NotifyIcon.Visible = $true

    $menu = New-Object System.Windows.Forms.ContextMenuStrip
    $fixNowItem = $menu.Items.Add('Fix now')
    $openLocationItem = $menu.Items.Add('Open script location')
    $removeAutostartItem = $menu.Items.Add('Remove autostart...')
    $openLogItem = $menu.Items.Add('Open log')
    [void]$menu.Items.Add((New-Object System.Windows.Forms.ToolStripSeparator))
    $exitItem = $menu.Items.Add('Exit watcher')
    $script:NotifyIcon.ContextMenuStrip = $menu

    $fixNowItem.Add_Click({ Invoke-FixProcess -Manual })
    $openLocationItem.Add_Click({ Start-Process -FilePath 'explorer.exe' -ArgumentList ('"{0}"' -f $PSScriptRoot) })
    $removeAutostartItem.Add_Click({
        Remove-OurAutostart
        $removeAutostartItem.Visible = $false
        Show-Notification 'ChatGPT Overlay Fix' 'Autostart was removed. The watcher remains running.'
    })
    $openLogItem.Add_Click({ if (Test-Path -LiteralPath $script:LogPath) { Start-Process -FilePath $script:LogPath } })
    $exitItem.Add_Click({ $script:ExitRequested = $true })
    $menu.Add_Opening({
        $removeAutostartItem.Visible = Test-OurAutostart
        $openLogItem.Visible = Test-Path -LiteralPath $script:LogPath
    })

    Set-WatcherState 'Waiting for ChatGPT'
    Write-WatcherLog "Watcher $script:PackageVersion started."
    $nextPoll = [DateTime]::MinValue
    while (-not $script:ExitRequested) {
        [System.Windows.Forms.Application]::DoEvents()
        if ($script:StopEvent.WaitOne(100)) {
            Write-WatcherLog 'Named stop event received.'
            break
        }
        if ([DateTime]::UtcNow -ge $nextPoll) {
            try { Update-ChatGPTSession }
            catch {
                Set-WatcherState 'Error'
                Write-WatcherLog "Watcher cycle failed: $($_.Exception.Message)"
            }
            $nextPoll = [DateTime]::UtcNow.AddSeconds(2)
        }
    }
}
catch {
    Write-WatcherLog "Watcher stopped because of an error: $($_.Exception.Message)"
    exit 1
}
finally {
    if ($script:NotifyIcon) {
        $script:NotifyIcon.Visible = $false
        $script:NotifyIcon.Dispose()
    }
    if ($script:StopEvent) { $script:StopEvent.Dispose() }
    if ($script:Mutex) {
        try { $script:Mutex.ReleaseMutex() } catch { }
        $script:Mutex.Dispose()
    }
}

exit 0
