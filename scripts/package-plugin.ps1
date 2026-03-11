Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$repoRoot = Split-Path -Parent $PSScriptRoot
$pluginName = "annas.koplugin"
$distDir = Join-Path $repoRoot "dist"
$stageDir = Join-Path $distDir $pluginName
$zipPath = Join-Path $distDir "$pluginName.zip"

$includePaths = @(
    "_meta.lua",
    "main.lua",
    "messages.mo",
    "LICENSE",
    "README.md",
    "README.zh-CN.md",
    "annas",
    "src",
    "l10n"
)

if (Test-Path $stageDir) {
    Remove-Item $stageDir -Recurse -Force
}

if (Test-Path $zipPath) {
    Remove-Item $zipPath -Force
}

New-Item -ItemType Directory -Path $distDir | Out-Null
New-Item -ItemType Directory -Path $stageDir | Out-Null

foreach ($relativePath in $includePaths) {
    $sourcePath = Join-Path $repoRoot $relativePath
    if (-not (Test-Path $sourcePath)) {
        throw "Missing required package path: $relativePath"
    }

    $destinationPath = Join-Path $stageDir $relativePath
    $destinationParent = Split-Path -Parent $destinationPath
    if ($destinationParent -and -not (Test-Path $destinationParent)) {
        New-Item -ItemType Directory -Path $destinationParent -Force | Out-Null
    }

    Copy-Item $sourcePath $destinationPath -Recurse -Force
}

Compress-Archive -Path $stageDir -DestinationPath $zipPath -CompressionLevel Optimal -Force

Write-Host "Created package: $zipPath"
Write-Host "Archive root directory: $pluginName"
