$ErrorActionPreference = 'Stop'
$repoRoot = Split-Path -Parent $PSScriptRoot
$scripts = @(
    'Fix-ChatGPT-Overlays v2.1.ps1',
    'Watch-ChatGPT-Overlays.ps1',
    'Install-Watcher.ps1',
    'Uninstall-Watcher.ps1'
)

foreach ($scriptName in $scripts) {
    $path = Join-Path $repoRoot $scriptName
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
        throw "Missing script: $scriptName"
    }

    $tokens = $null
    $errors = $null
    [void][System.Management.Automation.Language.Parser]::ParseFile(
        $path,
        [ref]$tokens,
        [ref]$errors
    )
    if ($errors.Count -gt 0) {
        throw "PowerShell parse failure in $scriptName`: $($errors[0].Message)"
    }
}

$fixContent = Get-Content -Raw -LiteralPath (Join-Path $repoRoot 'Fix-ChatGPT-Overlays v2.1.ps1')
if ($fixContent -notmatch 'finally\s*\{') {
    throw 'The one-shot fix must restore the original style in a finally block.'
}
if ($fixContent -notmatch 'WS_EX_LAYERED') {
    throw 'The one-shot fix no longer contains the expected layered-style reset.'
}

$watcherContent = Get-Content -Raw -LiteralPath (Join-Path $repoRoot 'Watch-ChatGPT-Overlays.ps1')
if ($watcherContent -notmatch "Get-Process -Name 'ChatGPT'") {
    throw 'The watcher must scope candidate windows to ChatGPT processes.'
}
if ($watcherContent -notmatch 'StableSamples') {
    throw 'The watcher must wait for stable window samples before repair.'
}

$installContent = Get-Content -Raw -LiteralPath (Join-Path $repoRoot 'Install-Watcher.ps1')
if ($installContent -notmatch 'RunLevel Limited') {
    throw 'The scheduled task must run with limited current-user privileges.'
}

Write-Host 'All script contract tests passed.' -ForegroundColor Green
