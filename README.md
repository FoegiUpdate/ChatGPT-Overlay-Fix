# ChatGPT Overlay Fix

A PowerShell workaround for restoring mouse interaction with floating overlays in the ChatGPT/Codex desktop app on Windows.

The workaround has been tested with the floating **Pet** and **Voice widget** when they become visible but no longer respond correctly to mouse input.

## Problem

The ChatGPT/Codex desktop app on Windows can enter a state where floating overlay windows stop receiving mouse input correctly.

Typical symptoms include:

* The Pet is visible and animated but cannot be clicked or dragged.
* Mouse clicks may pass through the Pet to the application underneath.
* The Voice widget may also become impossible to drag.
* Restarting the ChatGPT app can cause the problem to return.

The underlying Pet issue is tracked upstream as:

**openai/codex#41513 — `[Windows][Pets] Built-in and custom floating pets become click-through and cannot be dragged`**

Relevant testing and workaround discussion can also be found in **issue comment 5538221946** in that issue.

The upstream diagnostics indicate that the affected overlay can remain in an incorrect native Windows input state involving extended window styles.

## Workaround

This script applies a temporary runtime workaround to matching ChatGPT overlay windows.

It does **not** permanently remove window styles or modify the ChatGPT installation.

For each detected overlay, the script:

1. Locates the running `ChatGPT` process.
2. Enumerates its top-level overlay windows.
3. Identifies matching visible `Chrome_WidgetWin_1` layered windows.
4. Saves the complete original extended window style.
5. Temporarily clears only `WS_EX_LAYERED`.
6. Calls `SetWindowPos()` with `SWP_FRAMECHANGED` to force Windows to refresh the native window state.
7. Waits three seconds.
8. Restores the exact original extended window style.
9. Calls `SWP_FRAMECHANGED` again.
10. Verifies that the original style was successfully restored.

On affected systems, this appears to re-synchronize the native overlay/input state and restores mouse interaction.

## Requirements

* Windows
* ChatGPT/Codex desktop app running
* Windows PowerShell 5.1 or compatible PowerShell on Windows
* `Fix-ChatGPT-Overlays v2.1.ps1`

No additional modules are required.

## Usage

Download the script and start the ChatGPT desktop app.

Open PowerShell in the directory containing the script and run:

```powershell
.\Fix-ChatGPT-Overlays v2.1.ps1
```

If script execution is blocked by your local PowerShell execution policy, you can run it for the current PowerShell process with:

```powershell
Set-ExecutionPolicy -Scope Process -ExecutionPolicy Bypass
.\Fix-ChatGPT-Overlays v2.1.ps1
```

The execution-policy change above applies only to the current PowerShell process.

## Example output

```text
ChatGPT Overlay Fix
-------------------
Found 1 matching overlay window(s).

Overlay 1
  Handle    : 0x123456
  Class     : Chrome_WidgetWin_1
  Title     : ChatGPT
  Size      : 288 x 288
  Original  : 0x08080188
  Temporary : 0x08000188
  Recovery  : Clearing WS_EX_LAYERED and refreshing native frame state...
  Restored  : 0x08080188
  Result    : Success

Recovery completed successfully.
The pet and voice widget should now be clickable and draggable again.
Note: This change only applies to the current ChatGPT session. Run the script again after restarting the app.
```

Actual handles, dimensions and extended window styles can differ between systems and app versions.

## Why `WS_EX_LAYERED`?

The upstream issue contains diagnostics involving `WS_EX_TRANSPARENT`, which can directly cause mouse input to pass through a window.

During additional testing, however, it was found that permanently changing the final extended window style is not required for this workaround.

Temporarily clearing `WS_EX_LAYERED` together with `SWP_FRAMECHANGED`, then restoring the original style, appears to force Windows and/or the application to rebuild or re-synchronize the native overlay/input state.

The important part is therefore not that `WS_EX_LAYERED` remains disabled — it does not.

The script restores the complete original extended window style after the temporary reset.

## Safety

The script intentionally makes only a temporary runtime change.

It:

* does not modify ChatGPT application files,
* does not modify the registry,
* does not install software,
* does not permanently change the overlay style,
* preserves all extended-style bits except for the temporary `WS_EX_LAYERED` reset,
* restores the complete original style in a `finally` block,
* verifies the restored style after the operation.

The script also resolves the actual `ChatGPT` process IDs before touching any windows, reducing the chance of affecting unrelated Chromium/Electron applications.

## Limitations

This is a **workaround**, not a permanent fix for the underlying application bug.

The workaround:

* only affects the currently running ChatGPT session,
* may need to be run again after restarting ChatGPT,
* depends on the current native overlay implementation,
* may stop working if the ChatGPT/Codex desktop app changes how its overlay windows are implemented.

Ultimately, the underlying issue should be fixed in the application itself.

## Troubleshooting

If no matching overlay window is found, the script prints the detected ChatGPT top-level windows and their relevant properties.

Make sure:

1. The ChatGPT desktop app is running.
2. The affected Pet or Voice overlay is currently visible.
3. You are running the script in the same Windows user session as ChatGPT.

If the script reports that the original style could not be restored, restart the ChatGPT desktop app before performing further testing.

## Related upstream issue

**openai/codex#41513**

`[Windows][Pets] Built-in and custom floating pets become click-through and cannot be dragged`

Relevant workaround discussion: **issue comment 5538221946**

## Disclaimer

This is an unofficial community workaround and is not affiliated with or endorsed by OpenAI.

Use it at your own risk.
