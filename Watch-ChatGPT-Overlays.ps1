# Watch-ChatGPT-Overlays.ps1
# Watches for newly created ChatGPT overlay windows and runs the one-shot fix once
# after each window has reached a stable native state.

[CmdletBinding()]
param(
    [ValidateRange(500, 10000)]
    [int]$PollIntervalMs = 1500,

    [ValidateRange(1, 10)]
    [int]$StableSamples = 3,

    [ValidateRange(0, 60)]
    [int]$StartupDelaySeconds = 3,

    [ValidateRange(64, 10240)]
    [int]$MaxLogSizeKB = 1024,

    [switch]$RunOnce,

    [switch]$NoLog
)

$ErrorActionPreference = 'Stop'
$fixScript = Join-Path $PSScriptRoot 'Fix-ChatGPT-Overlays v2.1.ps1'
$logDirectory = Join-Path $env:LOCALAPPDATA 'ChatGPTOverlayFix'
$logPath = Join-Path $logDirectory 'watcher.log'

if (-not (Test-Path -LiteralPath $fixScript -PathType Leaf)) {
    throw "The one-shot fix script was not found: $fixScript"
}

function Write-WatcherLog {
    param([Parameter(Mandatory = $true)][string]$Message)

    $line = '{0:yyyy-MM-dd HH:mm:ss.fff} {1}' -f (Get-Date), $Message
    if (-not $NoLog) {
        if (-not (Test-Path -LiteralPath $logDirectory -PathType Container)) {
            [void](New-Item -ItemType Directory -Path $logDirectory -Force)
        }
        if ((Test-Path -LiteralPath $logPath -PathType Leaf) -and
            (Get-Item -LiteralPath $logPath).Length -ge ($MaxLogSizeKB * 1KB)) {
            $previousLogPath = Join-Path $logDirectory 'watcher.previous.log'
            Move-Item -LiteralPath $logPath -Destination $previousLogPath -Force
        }
        Add-Content -LiteralPath $logPath -Value $line -Encoding UTF8
    }
    if ($Host.Name -ne 'Default Host') {
        Write-Host $line
    }
}

if (-not ('ChatGPTOverlayWatcherWin32V1' -as [type])) {
    Add-Type @"
using System;
using System.Runtime.InteropServices;
using System.Text;

public static class ChatGPTOverlayWatcherWin32V1
{
    public delegate bool EnumWindowsProc(IntPtr hWnd, IntPtr lParam);
    public const int GWL_EXSTYLE = -20;
    public const long WS_EX_TOPMOST = 0x00000008L;
    public const long WS_EX_TOOLWINDOW = 0x00000080L;
    public const long WS_EX_LAYERED = 0x00080000L;

    [DllImport("user32.dll")]
    public static extern bool EnumWindows(EnumWindowsProc callback, IntPtr lParam);

    [DllImport("user32.dll")]
    public static extern bool IsWindowVisible(IntPtr hWnd);

    [DllImport("user32.dll")]
    public static extern uint GetWindowThreadProcessId(IntPtr hWnd, out uint processId);

    [DllImport("user32.dll", CharSet = CharSet.Auto)]
    public static extern int GetClassName(IntPtr hWnd, StringBuilder className, int maxCount);

    [DllImport("user32.dll", SetLastError = true, EntryPoint = "GetWindowLongPtr")]
    public static extern IntPtr GetWindowLongPtr(IntPtr hWnd, int index);

    [DllImport("user32.dll", SetLastError = true)]
    public static extern bool GetWindowRect(IntPtr hWnd, out RECT rect);

    public struct RECT
    {
        public int Left;
        public int Top;
        public int Right;
        public int Bottom;
    }
}
"@
}

function Get-OverlayCandidates {
    $processes = @(Get-Process -Name 'ChatGPT' -ErrorAction SilentlyContinue)
    if ($processes.Count -eq 0) {
        return @()
    }

    $processIds = @($processes | Select-Object -ExpandProperty Id)
    $windows = New-Object System.Collections.Generic.List[object]

    [void][ChatGPTOverlayWatcherWin32V1]::EnumWindows({
        param($handle, $lParam)

        $processId = [uint32]0
        [void][ChatGPTOverlayWatcherWin32V1]::GetWindowThreadProcessId($handle, [ref]$processId)
        if ($processIds -notcontains [int]$processId) {
            return $true
        }

        if (-not [ChatGPTOverlayWatcherWin32V1]::IsWindowVisible($handle)) {
            return $true
        }

        $className = New-Object System.Text.StringBuilder 256
        [void][ChatGPTOverlayWatcherWin32V1]::GetClassName($handle, $className, $className.Capacity)
        if ($className.ToString() -ne 'Chrome_WidgetWin_1') {
            return $true
        }

        $style = [ChatGPTOverlayWatcherWin32V1]::GetWindowLongPtr(
            $handle,
            [ChatGPTOverlayWatcherWin32V1]::GWL_EXSTYLE
        ).ToInt64()

        $isLayered = [bool]($style -band [ChatGPTOverlayWatcherWin32V1]::WS_EX_LAYERED)
        $isOverlayLike = [bool](
            ($style -band [ChatGPTOverlayWatcherWin32V1]::WS_EX_TOPMOST) -or
            ($style -band [ChatGPTOverlayWatcherWin32V1]::WS_EX_TOOLWINDOW)
        )
        if (-not ($isLayered -and $isOverlayLike)) {
            return $true
        }

        $rect = New-Object ChatGPTOverlayWatcherWin32V1+RECT
        $width = 0
        $height = 0
        if ([ChatGPTOverlayWatcherWin32V1]::GetWindowRect($handle, [ref]$rect)) {
            $width = $rect.Right - $rect.Left
            $height = $rect.Bottom - $rect.Top
        }

        $handleValue = $handle.ToInt64()
        $windows.Add([pscustomobject]@{
            Key       = ('{0}:{1}' -f $processId, $handleValue)
            PID       = [int]$processId
            Handle    = $handleValue
            HandleHex = '0x{0:X}' -f $handleValue
            Signature = ('{0}x{1}:0x{2:X}' -f $width, $height, $style)
        })

        return $true
    }, [IntPtr]::Zero)

    return @($windows | ForEach-Object { $_ })
}

function Invoke-OneShotFix {
    param([Parameter(Mandatory = $true)]$Candidate)

    Write-WatcherLog "Repairing PID $($Candidate.PID), handle $($Candidate.HandleHex), state $($Candidate.Signature)."
    $output = & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $fixScript 2>&1
    $exitCode = $LASTEXITCODE
    $outputText = ($output | Out-String).Trim()

    if ($outputText) {
        Write-WatcherLog ($outputText -replace "`r?`n", ' | ')
    }

    $success = ($exitCode -eq 0) -and ($outputText -match 'Result\s+: Success')
    if ($success) {
        Write-WatcherLog "Repair succeeded for $($Candidate.HandleHex)."
    }
    else {
        Write-WatcherLog "Repair did not report success for $($Candidate.HandleHex); it will be retried."
    }
    return $success
}

$pending = @{}
$handled = @{}
$nextAttempt = @{}

Write-WatcherLog "Watcher started. PollIntervalMs=$PollIntervalMs StableSamples=$StableSamples MaxLogSizeKB=$MaxLogSizeKB RunOnce=$RunOnce"
if ($StartupDelaySeconds -gt 0) {
    Start-Sleep -Seconds $StartupDelaySeconds
}

try {
    do {
        $candidates = @(Get-OverlayCandidates)
        $activeKeys = @($candidates | Select-Object -ExpandProperty Key)

        foreach ($knownKey in @($pending.Keys) + @($handled.Keys) + @($nextAttempt.Keys)) {
            if ($activeKeys -notcontains $knownKey) {
                $pending.Remove($knownKey)
                $handled.Remove($knownKey)
                $nextAttempt.Remove($knownKey)
            }
        }

        foreach ($candidate in $candidates) {
            if ($handled[$candidate.Key] -eq $candidate.Signature) {
                continue
            }

            if ($nextAttempt.ContainsKey($candidate.Key) -and (Get-Date) -lt $nextAttempt[$candidate.Key]) {
                continue
            }

            $state = $pending[$candidate.Key]
            if ($null -eq $state -or $state.Signature -ne $candidate.Signature) {
                $state = [pscustomobject]@{
                    Signature = $candidate.Signature
                    Samples = 1
                }
                $pending[$candidate.Key] = $state
            }
            else {
                $state.Samples++
            }
            if ($state.Samples -lt $StableSamples) {
                continue
            }

            $pending.Remove($candidate.Key)
            if (Invoke-OneShotFix -Candidate $candidate) {
                $handled[$candidate.Key] = $candidate.Signature
                $nextAttempt.Remove($candidate.Key)
            }
            else {
                $nextAttempt[$candidate.Key] = (Get-Date).AddSeconds(30)
            }
        }

        if (-not $RunOnce) {
            Start-Sleep -Milliseconds $PollIntervalMs
        }
    } while (-not $RunOnce)
}
catch {
    Write-WatcherLog "Watcher stopped by error: $($_.Exception.Message)"
    throw
}
finally {
    Write-WatcherLog 'Watcher stopped.'
}
