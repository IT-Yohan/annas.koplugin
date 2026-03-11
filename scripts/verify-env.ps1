Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$userPath = [Environment]::GetEnvironmentVariable("Path", "User")
$machinePath = [Environment]::GetEnvironmentVariable("Path", "Machine")
$env:Path = "$userPath;$machinePath"

$checks = @(
    @{ Name = "git"; Command = "git.exe"; Args = @("--version") },
    @{ Name = "curl"; Command = "curl.exe"; Args = @("--version") },
    @{ Name = "tar"; Command = "tar.exe"; Args = @("--version") },
    @{ Name = "lua"; Command = "lua.exe"; Args = @("-v") },
    @{ Name = "luajit"; Command = "luajit.exe"; Args = @("-v") },
    @{ Name = "luarocks"; Command = "luarocks.exe"; Args = @("--version") },
    @{ Name = "lua-language-server"; Command = "lua-language-server.exe"; Args = @("--version") }
)

$results = foreach ($check in $checks) {
    $command = Get-Command $check.Command -ErrorAction SilentlyContinue
    if (-not $command) {
        [PSCustomObject]@{
            Name = $check.Name
            Status = "missing"
            Path = ""
            Version = ""
        }
        continue
    }

    $commandPath = if ($command.PSObject.Properties.Match("Path").Count -gt 0 -and $command.Path) {
        $command.Path
    } elseif ($command.PSObject.Properties.Match("Source").Count -gt 0 -and $command.Source) {
        $command.Source
    } else {
        $command.Definition
    }

    $output = & $check.Command @($check.Args) 2>&1 | Select-Object -First 1
    [PSCustomObject]@{
        Name = $check.Name
        Status = "ok"
        Path = $commandPath
        Version = ($output | Out-String).Trim()
    }
}

$results | Format-Table -AutoSize

$nativeBuildCompiler = Get-Command x86_64-w64-mingw32-gcc,gcc,cl -ErrorAction SilentlyContinue | Select-Object -First 1
if ($nativeBuildCompiler) {
    Write-Host "Native compiler detected: $($nativeBuildCompiler.Name)"
} else {
    Write-Warning "No native C compiler detected. Pure-Lua LuaRocks packages should work, but native modules may fail to build on Windows."
}

$missing = $results | Where-Object { $_.Status -ne "ok" }
if ($missing) {
    Write-Error "Missing required commands: $($missing.Name -join ', ')"
}