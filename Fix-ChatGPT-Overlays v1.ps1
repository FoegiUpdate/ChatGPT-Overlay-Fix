# Temporary workaround for a ChatGPT overlay that cannot be clicked or moved.
#
# The script searches only top-level windows belonging to running ChatGPT
# processes that match the known overlay signature:
#   Chrome_WidgetWin_1 class + TopMost + ToolWindow + Layered
# For these windows, WS_EX_LAYERED is removed once and the non-client area is
# then refreshed. ChatGPT setting the flag again afterward is expected behavior
# and does not indicate that the workaround has failed.

[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'

Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
using System.Text;

public static class ChatGPTOverlayNativeMethods
{
    public delegate bool EnumWindowsProc(IntPtr hWnd, IntPtr lParam);

    [DllImport("user32.dll", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    public static extern bool EnumWindows(EnumWindowsProc callback, IntPtr lParam);

    [DllImport("user32.dll")]
    public static extern uint GetWindowThreadProcessId(IntPtr hWnd, out uint processId);

    [DllImport("user32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    public static extern int GetClassName(IntPtr hWnd, StringBuilder className, int maxCount);

    [DllImport("user32.dll", EntryPoint = "GetWindowLong", SetLastError = true)]
    private static extern int GetWindowLong32(IntPtr hWnd, int index);

    [DllImport("user32.dll", EntryPoint = "GetWindowLongPtr", SetLastError = true)]
    private static extern IntPtr GetWindowLongPtr64(IntPtr hWnd, int index);

    [DllImport("user32.dll", EntryPoint = "SetWindowLong", SetLastError = true)]
    private static extern int SetWindowLong32(IntPtr hWnd, int index, int newValue);

    [DllImport("user32.dll", EntryPoint = "SetWindowLongPtr", SetLastError = true)]
    private static extern IntPtr SetWindowLongPtr64(IntPtr hWnd, int index, IntPtr newValue);

    [DllImport("user32.dll", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    public static extern bool SetWindowPos(
        IntPtr hWnd,
        IntPtr hWndInsertAfter,
        int x,
        int y,
        int width,
        int height,
        uint flags);

    public static IntPtr GetWindowLongPtr(IntPtr hWnd, int index)
    {
        return IntPtr.Size == 8
            ? GetWindowLongPtr64(hWnd, index)
            : new IntPtr(GetWindowLong32(hWnd, index));
    }

    public static IntPtr SetWindowLongPtr(IntPtr hWnd, int index, IntPtr newValue)
    {
        return IntPtr.Size == 8
            ? SetWindowLongPtr64(hWnd, index, newValue)
            : new IntPtr(SetWindowLong32(hWnd, index, newValue.ToInt32()));
    }
}
'@

$GWL_EXSTYLE = -20
$WS_EX_TOPMOST = 0x00000008L
$WS_EX_TOOLWINDOW = 0x00000080L
$WS_EX_LAYERED = 0x00080000L
$OVERLAY_SIGNATURE = $WS_EX_TOPMOST -bor $WS_EX_TOOLWINDOW -bor $WS_EX_LAYERED

$SWP_NOSIZE = 0x0001
$SWP_NOMOVE = 0x0002
$SWP_NOZORDER = 0x0004
$SWP_NOACTIVATE = 0x0010
$SWP_FRAMECHANGED = 0x0020
$FRAME_REFRESH_FLAGS = $SWP_NOSIZE -bor $SWP_NOMOVE -bor $SWP_NOZORDER -bor $SWP_NOACTIVATE -bor $SWP_FRAMECHANGED

try {
    Write-Host 'Suche laufende ChatGPT-Prozesse ...'

    $chatGPTProcesses = @(Get-Process -Name 'ChatGPT' -ErrorAction SilentlyContinue)
    if ($chatGPTProcesses.Count -eq 0) {
        throw 'Kein laufender ChatGPT-Prozess gefunden. Bitte ChatGPT starten und das Skript erneut ausführen.'
    }

    $chatGPTProcessIds = [System.Collections.Generic.HashSet[uint32]]::new()
    foreach ($process in $chatGPTProcesses) {
        [void]$chatGPTProcessIds.Add([uint32]$process.Id)
    }

    Write-Host ("Gefunden: {0} ChatGPT-Prozess(e). Suche passendes Overlay ..." -f $chatGPTProcesses.Count)

    $topLevelWindows = [System.Collections.Generic.List[System.IntPtr]]::new()
    $enumCallback = [ChatGPTOverlayNativeMethods+EnumWindowsProc] {
        param([IntPtr]$windowHandle, [IntPtr]$unused)
        $topLevelWindows.Add($windowHandle)
        return $true
    }

    if (-not [ChatGPTOverlayNativeMethods]::EnumWindows($enumCallback, [IntPtr]::Zero)) {
        $errorCode = [Runtime.InteropServices.Marshal]::GetLastWin32Error()
        throw "Top-Level-Fenster konnten nicht aufgelistet werden (Win32-Fehler $errorCode)."
    }

    $overlayWindows = [System.Collections.Generic.List[System.IntPtr]]::new()

    foreach ($windowHandle in $topLevelWindows) {
        [uint32]$windowProcessId = 0
        [void][ChatGPTOverlayNativeMethods]::GetWindowThreadProcessId($windowHandle, [ref]$windowProcessId)

        if (-not $chatGPTProcessIds.Contains($windowProcessId)) {
            continue
        }

        $className = [Text.StringBuilder]::new(256)
        if ([ChatGPTOverlayNativeMethods]::GetClassName($windowHandle, $className, $className.Capacity) -eq 0) {
            continue
        }

        if ($className.ToString() -ne 'Chrome_WidgetWin_1') {
            continue
        }

        $extendedStyle = [ChatGPTOverlayNativeMethods]::GetWindowLongPtr($windowHandle, $GWL_EXSTYLE).ToInt64()
        if (($extendedStyle -band $OVERLAY_SIGNATURE) -eq $OVERLAY_SIGNATURE) {
            $overlayWindows.Add($windowHandle)
        }
    }

    if ($overlayWindows.Count -eq 0) {
        throw 'Kein passendes ChatGPT-Overlay gefunden. Es wurde nichts verändert.'
    }

    $fixedCount = 0
    $failures = [System.Collections.Generic.List[string]]::new()

    foreach ($windowHandle in $overlayWindows) {
        try {
            $extendedStyle = [ChatGPTOverlayNativeMethods]::GetWindowLongPtr($windowHandle, $GWL_EXSTYLE).ToInt64()

            # Check again immediately before making the change: the window may
            # have been closed or modified by ChatGPT in the meantime.
            if (($extendedStyle -band $OVERLAY_SIGNATURE) -ne $OVERLAY_SIGNATURE) {
                throw 'Die Overlay-Signatur ist nicht mehr vorhanden.'
            }

            $newExtendedStyle = $extendedStyle -band (-bnot $WS_EX_LAYERED)
            $previousStyle = [ChatGPTOverlayNativeMethods]::SetWindowLongPtr(
                $windowHandle,
                $GWL_EXSTYLE,
                [IntPtr]$newExtendedStyle)

            # According to the signature, the previous style contains several
            # set bits. A return value of 0 therefore clearly indicates an error.
            if ($previousStyle -eq [IntPtr]::Zero) {
                $errorCode = [Runtime.InteropServices.Marshal]::GetLastWin32Error()
                throw "WS_EX_LAYERED konnte nicht entfernt werden (Win32-Fehler $errorCode)."
            }

            if (-not [ChatGPTOverlayNativeMethods]::SetWindowPos(
                    $windowHandle,
                    [IntPtr]::Zero,
                    0,
                    0,
                    0,
                    0,
                    [uint32]$FRAME_REFRESH_FLAGS)) {
                $errorCode = [Runtime.InteropServices.Marshal]::GetLastWin32Error()
                throw "Der Frame-Refresh ist fehlgeschlagen (Win32-Fehler $errorCode)."
            }

            $fixedCount++
            Write-Host ("Overlay 0x{0:X}: Fix angewendet." -f $windowHandle.ToInt64()) -ForegroundColor Green
        }
        catch {
            $message = "Overlay 0x{0:X}: {1}" -f $windowHandle.ToInt64(), $_.Exception.Message
            $failures.Add($message)
            Write-Warning $message
        }
    }

    if ($fixedCount -eq 0) {
        throw 'Der Fix konnte auf kein erkanntes Overlay angewendet werden.'
    }

    Write-Host ''
    Write-Host ("Fix erfolgreich auf {0} Overlay(s) angewendet." -f $fixedCount) -ForegroundColor Green
    Write-Host 'Hinweis: ChatGPT darf WS_EX_LAYERED danach wieder selbst setzen; das ist erwartet.'

    if ($failures.Count -gt 0) {
        Write-Warning ("{0} weiteres/weitere Overlay(s) konnten nicht behandelt werden." -f $failures.Count)
        exit 2
    }
}
catch {
    Write-Error $_.Exception.Message
    exit 1
}
