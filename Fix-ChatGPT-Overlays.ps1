# Fix-ChatGPT-Overlays.ps1
# One-shot runtime workaround for ChatGPT Desktop overlays (Pet / Voice widget).
# PowerShell 5.1 compatible. No persistent system changes are made.

$script:PackageVersion = '3.0.0'
$ErrorActionPreference = 'Stop'

if (-not ('ChatGPTOverlayWin32V3' -as [type])) {
    Add-Type @"
using System;
using System.Runtime.InteropServices;
using System.Text;

public static class ChatGPTOverlayWin32V3
{
    public delegate bool EnumWindowsProc(IntPtr hWnd, IntPtr lParam);
    public const int GWL_EXSTYLE = -20;
    public const long WS_EX_TRANSPARENT = 0x00000020L;
    public const long WS_EX_TOPMOST = 0x00000008L;
    public const long WS_EX_TOOLWINDOW = 0x00000080L;
    public const long WS_EX_LAYERED = 0x00080000L;
    public const uint SWP_NOSIZE = 0x0001;
    public const uint SWP_NOMOVE = 0x0002;
    public const uint SWP_NOZORDER = 0x0004;
    public const uint SWP_NOACTIVATE = 0x0010;
    public const uint SWP_FRAMECHANGED = 0x0020;

    [DllImport("user32.dll")]
    public static extern bool EnumWindows(EnumWindowsProc lpEnumFunc, IntPtr lParam);
    [DllImport("user32.dll")]
    public static extern bool IsWindowVisible(IntPtr hWnd);
    [DllImport("user32.dll")]
    public static extern uint GetWindowThreadProcessId(IntPtr hWnd, out uint lpdwProcessId);
    [DllImport("user32.dll", CharSet = CharSet.Auto)]
    public static extern int GetClassName(IntPtr hWnd, StringBuilder lpClassName, int nMaxCount);
    [DllImport("user32.dll", CharSet = CharSet.Auto)]
    public static extern int GetWindowText(IntPtr hWnd, StringBuilder lpString, int nMaxCount);
    [DllImport("user32.dll", SetLastError = true, EntryPoint = "GetWindowLongPtr")]
    public static extern IntPtr GetWindowLongPtr(IntPtr hWnd, int nIndex);
    [DllImport("user32.dll", SetLastError = true, EntryPoint = "SetWindowLongPtr")]
    public static extern IntPtr SetWindowLongPtr(IntPtr hWnd, int nIndex, IntPtr dwNewLong);
    [DllImport("user32.dll", SetLastError = true)]
    public static extern bool GetWindowRect(IntPtr hWnd, out RECT lpRect);
    [DllImport("user32.dll", SetLastError = true)]
    public static extern bool SetWindowPos(IntPtr hWnd, IntPtr hWndInsertAfter, int X, int Y, int cx, int cy, uint uFlags);
    [DllImport("kernel32.dll")]
    public static extern void SetLastError(uint dwErrCode);

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

function Get-WindowInfo {
    param([Parameter(Mandatory = $true)][IntPtr]$Handle)

    $processId = [uint32]0
    [void][ChatGPTOverlayWin32V3]::GetWindowThreadProcessId($Handle, [ref]$processId)
    $class = New-Object System.Text.StringBuilder 512
    $title = New-Object System.Text.StringBuilder 512
    [void][ChatGPTOverlayWin32V3]::GetClassName($Handle, $class, $class.Capacity)
    [void][ChatGPTOverlayWin32V3]::GetWindowText($Handle, $title, $title.Capacity)

    [ChatGPTOverlayWin32V3]::SetLastError(0)
    $exStylePointer = [ChatGPTOverlayWin32V3]::GetWindowLongPtr($Handle, [ChatGPTOverlayWin32V3]::GWL_EXSTYLE)
    $errorCode = [Runtime.InteropServices.Marshal]::GetLastWin32Error()
    if (($exStylePointer -eq [IntPtr]::Zero) -and ($errorCode -ne 0)) {
        throw "GetWindowLongPtr failed for handle $('0x{0:X}' -f $Handle.ToInt64()) (Win32 error $errorCode)."
    }

    $exStyle = $exStylePointer.ToInt64()
    $rect = New-Object ChatGPTOverlayWin32V3+RECT
    $width = 0
    $height = 0
    if ([ChatGPTOverlayWin32V3]::GetWindowRect($Handle, [ref]$rect)) {
        $width = $rect.Right - $rect.Left
        $height = $rect.Bottom - $rect.Top
    }

    [pscustomobject]@{
        Handle = $Handle
        HandleHex = ('0x{0:X}' -f $Handle.ToInt64())
        PID = $processId
        Class = $class.ToString()
        Title = $title.ToString()
        Width = $width
        Height = $height
        Visible = [bool][ChatGPTOverlayWin32V3]::IsWindowVisible($Handle)
        ExStyleRaw = $exStyle
        ExStyle = ('0x{0:X8}' -f $exStyle)
        Transparent = [bool]($exStyle -band [ChatGPTOverlayWin32V3]::WS_EX_TRANSPARENT)
        TopMost = [bool]($exStyle -band [ChatGPTOverlayWin32V3]::WS_EX_TOPMOST)
        ToolWindow = [bool]($exStyle -band [ChatGPTOverlayWin32V3]::WS_EX_TOOLWINDOW)
        Layered = [bool]($exStyle -band [ChatGPTOverlayWin32V3]::WS_EX_LAYERED)
    }
}

function Set-ExtendedWindowStyle {
    param(
        [Parameter(Mandatory = $true)][IntPtr]$Handle,
        [Parameter(Mandatory = $true)][Int64]$ExStyle
    )

    [ChatGPTOverlayWin32V3]::SetLastError(0)
    $previousStyle = [ChatGPTOverlayWin32V3]::SetWindowLongPtr(
        $Handle,
        [ChatGPTOverlayWin32V3]::GWL_EXSTYLE,
        [IntPtr]$ExStyle
    )
    $errorCode = [Runtime.InteropServices.Marshal]::GetLastWin32Error()
    if (($previousStyle -eq [IntPtr]::Zero) -and ($errorCode -ne 0)) {
        throw "SetWindowLongPtr failed (Win32 error $errorCode)."
    }
}

function Invoke-FrameRefresh {
    param([Parameter(Mandatory = $true)][IntPtr]$Handle)

    $flags = [ChatGPTOverlayWin32V3]::SWP_NOSIZE -bor
             [ChatGPTOverlayWin32V3]::SWP_NOMOVE -bor
             [ChatGPTOverlayWin32V3]::SWP_NOZORDER -bor
             [ChatGPTOverlayWin32V3]::SWP_NOACTIVATE -bor
             [ChatGPTOverlayWin32V3]::SWP_FRAMECHANGED

    if (-not [ChatGPTOverlayWin32V3]::SetWindowPos($Handle, [IntPtr]::Zero, 0, 0, 0, 0, $flags)) {
        $errorCode = [Runtime.InteropServices.Marshal]::GetLastWin32Error()
        throw "SetWindowPos failed (Win32 error $errorCode)."
    }
}

function Reset-LayeredStyle {
    param(
        [Parameter(Mandatory = $true)][IntPtr]$Handle,
        [Parameter(Mandatory = $true)][int]$Index
    )

    $before = Get-WindowInfo -Handle $Handle
    $originalStyle = $before.ExStyleRaw
    $styleWithoutLayered = $originalStyle -band (-bnot [ChatGPTOverlayWin32V3]::WS_EX_LAYERED)
    $temporaryStyleHex = ('0x{0:X8}' -f $styleWithoutLayered)
    $layeredCleared = $false
    $restored = $false
    $errorMessage = $null

    Write-Host ''
    Write-Host "Overlay $Index" -ForegroundColor Cyan
    Write-Host "  Handle    : $($before.HandleHex)"
    Write-Host "  Class     : $($before.Class)"
    Write-Host "  Title     : $($before.Title)"
    Write-Host "  Size      : $($before.Width) x $($before.Height)"
    Write-Host "  Original  : $($before.ExStyle)"
    Write-Host "  Temporary : $temporaryStyleHex"
    Write-Host '  Recovery  : Clearing WS_EX_LAYERED and refreshing native frame state...'

    try {
        Set-ExtendedWindowStyle -Handle $Handle -ExStyle $styleWithoutLayered
        Invoke-FrameRefresh -Handle $Handle
        if ((Get-WindowInfo -Handle $Handle).Layered) {
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
            $restored = ((Get-WindowInfo -Handle $Handle).ExStyleRaw -eq $originalStyle)
            if (-not $restored) {
                throw "The original ExStyle $($before.ExStyle) was not fully restored."
            }
        }
        catch {
            $restoreMessage = "Restore error: $($_.Exception.Message)"
            $errorMessage = if ($errorMessage) { "$errorMessage $restoreMessage" } else { $restoreMessage }
        }
    }

    $after = Get-WindowInfo -Handle $Handle
    $success = ($layeredCleared -and $restored -and -not $errorMessage)
    Write-Host "  Restored  : $($after.ExStyle)"
    if ($success) {
        Write-Host '  Result    : Success' -ForegroundColor Green
    }
    else {
        Write-Host '  Result    : Failed' -ForegroundColor Red
        if ($errorMessage) { Write-Host "  Error     : $errorMessage" -ForegroundColor Red }
    }

    [pscustomobject]@{
        Handle = $after.HandleHex
        Success = $success
        Error = $errorMessage
    }
}

try {
    Write-Host ''
    Write-Host "ChatGPT Overlay Fix $script:PackageVersion" -ForegroundColor Cyan
    Write-Host '------------------------- ' -ForegroundColor Cyan

    $chatGPTProcesses = @(Get-Process -Name 'ChatGPT' -ErrorAction SilentlyContinue)
    if (-not $chatGPTProcesses) {
        Write-Warning 'No running ChatGPT process was found.'
        exit 2
    }

    $chatGPTPids = @($chatGPTProcesses | Select-Object -ExpandProperty Id)
    $topWindows = New-Object System.Collections.Generic.List[object]
    [void][ChatGPTOverlayWin32V3]::EnumWindows({
        param($hWnd, $lParam)
        $processId = [uint32]0
        [void][ChatGPTOverlayWin32V3]::GetWindowThreadProcessId($hWnd, [ref]$processId)
        if ($chatGPTPids -contains [int]$processId) {
            $topWindows.Add((Get-WindowInfo -Handle $hWnd))
        }
        return $true
    }, [IntPtr]::Zero)

    $overlayParents = @($topWindows | Where-Object {
        $_.Visible -and $_.Class -eq 'Chrome_WidgetWin_1' -and $_.Layered -and ($_.TopMost -or $_.ToolWindow)
    })

    if ($overlayParents.Count -eq 0) {
        Write-Host 'No matching ChatGPT overlay windows were found.' -ForegroundColor Yellow
        if ($topWindows.Count -gt 0) {
            $topWindows |
                Select-Object HandleHex, Class, Title, Width, Height, ExStyle, Visible, Transparent, TopMost, ToolWindow, Layered |
                Format-Table -AutoSize
        }
        exit 2
    }

    Write-Host "Found $($overlayParents.Count) matching overlay window(s)."
    $results = New-Object System.Collections.Generic.List[object]
    $index = 0
    foreach ($parent in $overlayParents) {
        $index++
        $results.Add((Reset-LayeredStyle -Handle $parent.Handle -Index $index))
    }

    $failed = @($results | Where-Object { -not $_.Success })
    Write-Host ''
    if ($failed.Count -gt 0) {
        Write-Warning 'The layered-style reset could not be completed for at least one overlay.'
        exit 1
    }

    Write-Host 'Recovery completed successfully.' -ForegroundColor Green
    Write-Host 'The pet and voice widget should now be clickable and draggable again.'
    exit 0
}
catch {
    Write-Error "Overlay fix failed: $($_.Exception.Message)"
    exit 1
}
