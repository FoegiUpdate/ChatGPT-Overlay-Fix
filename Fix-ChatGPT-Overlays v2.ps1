# Fix-ChatGPT-Overlays v2.ps1
# Temporary runtime workaround for ChatGPT Desktop overlays (Pet / Voice widget)
# Resets WS_EX_LAYERED on relevant ChatGPT top-level overlay windows and restores the original style.
# PowerShell 5.1 compatible. No persistent changes are made.

$ErrorActionPreference = 'Stop'

Add-Type @"
using System;
using System.Collections.Generic;
using System.Runtime.InteropServices;
using System.Text;

public static class ChatGPTOverlayWin32
{
    public delegate bool EnumWindowsProc(IntPtr hWnd, IntPtr lParam);

    public const int GWL_EXSTYLE = -20;
    public const long WS_EX_TRANSPARENT = 0x00000020L;
    public const long WS_EX_TOPMOST     = 0x00000008L;
    public const long WS_EX_TOOLWINDOW  = 0x00000080L;
    public const long WS_EX_LAYERED     = 0x00080000L;

    public const uint SWP_NOSIZE       = 0x0001;
    public const uint SWP_NOMOVE       = 0x0002;
    public const uint SWP_NOZORDER     = 0x0004;
    public const uint SWP_NOACTIVATE   = 0x0010;
    public const uint SWP_FRAMECHANGED = 0x0020;

    [DllImport("user32.dll")]
    public static extern bool EnumWindows(EnumWindowsProc lpEnumFunc, IntPtr lParam);

    [DllImport("user32.dll")]
    public static extern bool EnumChildWindows(IntPtr hWndParent, EnumWindowsProc lpEnumFunc, IntPtr lParam);

    [DllImport("user32.dll")]
    public static extern uint GetWindowThreadProcessId(IntPtr hWnd, out uint lpdwProcessId);

    [DllImport("user32.dll", CharSet = CharSet.Auto)]
    public static extern int GetClassName(IntPtr hWnd, StringBuilder lpClassName, int nMaxCount);

    [DllImport("user32.dll", CharSet = CharSet.Auto)]
    public static extern int GetWindowText(IntPtr hWnd, StringBuilder lpString, int nMaxCount);

    [DllImport("user32.dll", EntryPoint = "GetWindowLongPtr")]
    public static extern IntPtr GetWindowLongPtr(IntPtr hWnd, int nIndex);

    [DllImport("user32.dll", EntryPoint = "SetWindowLongPtr", SetLastError = true)]
    public static extern IntPtr SetWindowLongPtr(IntPtr hWnd, int nIndex, IntPtr dwNewLong);

    [DllImport("user32.dll", SetLastError = true)]
    public static extern bool SetWindowPos(
        IntPtr hWnd,
        IntPtr hWndInsertAfter,
        int X,
        int Y,
        int cx,
        int cy,
        uint uFlags
    );
}
"@

function Get-WindowInfo {
    param(
        [Parameter(Mandatory = $true)]
        [IntPtr]$Handle
    )

    $processId = [uint32]0
    [void][ChatGPTOverlayWin32]::GetWindowThreadProcessId($Handle, [ref]$processId)

    $class = New-Object System.Text.StringBuilder 512
    $title = New-Object System.Text.StringBuilder 512
    [void][ChatGPTOverlayWin32]::GetClassName($Handle, $class, $class.Capacity)
    [void][ChatGPTOverlayWin32]::GetWindowText($Handle, $title, $title.Capacity)

    $exStyle = [ChatGPTOverlayWin32]::GetWindowLongPtr(
        $Handle,
        [ChatGPTOverlayWin32]::GWL_EXSTYLE
    ).ToInt64()

    [pscustomobject]@{
        Handle      = $Handle
        HandleHex   = ('0x{0:X}' -f $Handle.ToInt64())
        PID         = $processId
        Class       = $class.ToString()
        Title       = $title.ToString()
        ExStyleRaw  = $exStyle
        ExStyle     = ('0x{0:X8}' -f $exStyle)
        Transparent = [bool]($exStyle -band [ChatGPTOverlayWin32]::WS_EX_TRANSPARENT)
        TopMost     = [bool]($exStyle -band [ChatGPTOverlayWin32]::WS_EX_TOPMOST)
        ToolWindow  = [bool]($exStyle -band [ChatGPTOverlayWin32]::WS_EX_TOOLWINDOW)
        Layered     = [bool]($exStyle -band [ChatGPTOverlayWin32]::WS_EX_LAYERED)
    }
}

function Set-ExtendedWindowStyle {
    param(
        [Parameter(Mandatory = $true)]
        [IntPtr]$Handle,

        [Parameter(Mandatory = $true)]
        [Int64]$ExStyle
    )

    $previousStyle = [ChatGPTOverlayWin32]::SetWindowLongPtr(
        $Handle,
        [ChatGPTOverlayWin32]::GWL_EXSTYLE,
        [IntPtr]$ExStyle
    )

    if ($previousStyle -eq [IntPtr]::Zero) {
        $errorCode = [Runtime.InteropServices.Marshal]::GetLastWin32Error()
        throw "SetWindowLongPtr failed (Win32 error $errorCode)."
    }
}

function Invoke-FrameRefresh {
    param(
        [Parameter(Mandatory = $true)]
        [IntPtr]$Handle
    )

    $flags = [ChatGPTOverlayWin32]::SWP_NOSIZE -bor `
             [ChatGPTOverlayWin32]::SWP_NOMOVE -bor `
             [ChatGPTOverlayWin32]::SWP_NOZORDER -bor `
             [ChatGPTOverlayWin32]::SWP_NOACTIVATE -bor `
             [ChatGPTOverlayWin32]::SWP_FRAMECHANGED

    $succeeded = [ChatGPTOverlayWin32]::SetWindowPos(
        $Handle,
        [IntPtr]::Zero,
        0,
        0,
        0,
        0,
        $flags
    )

    if (-not $succeeded) {
        $errorCode = [Runtime.InteropServices.Marshal]::GetLastWin32Error()
        throw "SetWindowPos failed (Win32 error $errorCode)."
    }
}

function Reset-LayeredStyle {
    param(
        [Parameter(Mandatory = $true)]
        [IntPtr]$Handle,

        [Parameter(Mandatory = $true)]
        [string]$Kind
    )

    $before = Get-WindowInfo -Handle $Handle
    $originalStyle = $before.ExStyleRaw
    $styleWithoutLayered = $originalStyle -band (-bnot [ChatGPTOverlayWin32]::WS_EX_LAYERED)
    $layeredCleared = $false
    $restored = $false
    $errorMessage = $null

    try {
        Set-ExtendedWindowStyle -Handle $Handle -ExStyle $styleWithoutLayered
        Invoke-FrameRefresh -Handle $Handle

        $duringReset = Get-WindowInfo -Handle $Handle
        if ($duringReset.Layered) {
            throw 'WS_EX_LAYERED could not be cleared.'
        }

        $layeredCleared = $true
        Start-Sleep -Seconds 3
    }
    catch {
        $errorMessage = $_.Exception.Message
    }
    finally {
        try {
            Set-ExtendedWindowStyle -Handle $Handle -ExStyle $originalStyle
            Invoke-FrameRefresh -Handle $Handle

            $afterRestore = Get-WindowInfo -Handle $Handle
            $restored = ($afterRestore.ExStyleRaw -eq $originalStyle)

            if (-not $restored) {
                throw "The original ExStyle $($before.ExStyle) was not fully restored."
            }
        }
        catch {
            if ($errorMessage) {
                $errorMessage = "$errorMessage Restore error: $($_.Exception.Message)"
            }
            else {
                $errorMessage = "Restore error: $($_.Exception.Message)"
            }
        }
    }

    $after = Get-WindowInfo -Handle $Handle

    [pscustomobject]@{
        Kind              = $Kind
        Handle            = $after.HandleHex
        Class             = $after.Class
        Title             = $after.Title
        Before            = $before.ExStyle
        After             = $after.ExStyle
        LayeredCleared    = $layeredCleared
        Restored          = $restored
        Success           = ($layeredCleared -and $restored -and -not $errorMessage)
        Error             = $errorMessage
    }
}

# Find ChatGPT process IDs first.
$chatGPTProcesses = @(Get-Process -Name 'ChatGPT' -ErrorAction SilentlyContinue)

if (-not $chatGPTProcesses) {
    Write-Warning 'No running ChatGPT process was found. Start the ChatGPT app and run the script again.'
    exit 1
}

$chatGPTPids = @($chatGPTProcesses | Select-Object -ExpandProperty Id)

$topWindows = New-Object System.Collections.Generic.List[object]

[void][ChatGPTOverlayWin32]::EnumWindows({
    param($hWnd, $lParam)

    $processId = [uint32]0
    [void][ChatGPTOverlayWin32]::GetWindowThreadProcessId($hWnd, [ref]$processId)

    if ($chatGPTPids -contains [int]$processId) {
        $topWindows.Add((Get-WindowInfo -Handle $hWnd))
    }

    return $true
}, [IntPtr]::Zero)

if ($topWindows.Count -eq 0) {
    Write-Warning 'ChatGPT is running, but no top-level windows were found.'
    exit 1
}

# Only target the known ChatGPT top-level overlay window shape. The normal app
# window is not a tool window and is therefore excluded.
$overlayParents = @(
    $topWindows | Where-Object {
        $_.Class -eq 'Chrome_WidgetWin_1' -and
        $_.TopMost -and
        $_.ToolWindow -and
        $_.Layered
    }
)

if ($overlayParents.Count -eq 0) {
    Write-Host 'No matching ChatGPT overlay windows were found.' -ForegroundColor Yellow
    Write-Host 'Detected ChatGPT windows:'
    $topWindows |
        Select-Object HandleHex, Class, Title, ExStyle, Transparent, TopMost, ToolWindow, Layered |
        Format-Table -AutoSize
    exit 0
}

$results = New-Object System.Collections.Generic.List[object]

foreach ($parent in $overlayParents) {
    $results.Add((Reset-LayeredStyle -Handle $parent.Handle -Kind 'OverlayParent'))
}

Write-Host ''
Write-Host 'ChatGPT overlay fix:' -ForegroundColor Cyan
$results |
    Select-Object Kind, Handle, Class, Before, After, LayeredCleared, Restored, Success, Error |
    Format-Table -AutoSize

$failed = @($results | Where-Object { -not $_.Success })

Write-Host ''
if ($failed.Count -eq 0) {
    Write-Host 'Done. WS_EX_LAYERED was temporarily cleared and the original ExStyle was restored.' -ForegroundColor Green
    Write-Host 'The pet and voice widget should now be clickable and draggable again.'
}
else {
    Write-Warning 'The layered-style reset could not be completed for at least one overlay.'
}

Write-Host 'Note: This change only applies to the current ChatGPT session. Run the script again after restarting the app.'
