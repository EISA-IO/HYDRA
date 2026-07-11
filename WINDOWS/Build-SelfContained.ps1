param(
    [string]$Output = (Join-Path $PSScriptRoot "Hydra-SelfContained.exe"),
    [string]$WorkDirectory = (Join-Path $env:TEMP "hydra-self-contained-build"),
    [switch]$KeepWorkDirectory
)

$ErrorActionPreference = "Stop"
$ProgressPreference = "SilentlyContinue"
$repo = Split-Path $PSScriptRoot -Parent
$payload = Join-Path $WorkDirectory "payload"
$bin = Join-Path $payload "bin"
$appPackages = Join-Path $payload "app"

function Get-Json([string]$Url) {
    Invoke-RestMethod -Uri $Url -Headers @{ "User-Agent" = "Hydra self-contained builder" }
}
function Download([string]$Url, [string]$Destination) {
    Write-Host "  download $Url"
    Invoke-WebRequest -Uri $Url -OutFile $Destination -UseBasicParsing
}
function Copy-Tree([string]$Source, [string]$Destination) {
    if (Test-Path $Destination) { Remove-Item $Destination -Recurse -Force }
    New-Item $Destination -ItemType Directory -Force | Out-Null
    Copy-Item (Join-Path $Source "*") $Destination -Recurse -Force
}

if (Test-Path $WorkDirectory) {
    Get-ChildItem $WorkDirectory -Recurse -Force -ErrorAction SilentlyContinue | ForEach-Object { try { $_.Attributes = "Normal" } catch { } }
    Remove-Item $WorkDirectory -Recurse -Force
}
New-Item $bin -ItemType Directory -Force | Out-Null

Write-Host "[1/6] Portable Node.js runtime"
$nodeIndex = Get-Json "https://nodejs.org/dist/index.json"
$nodeVersion = ($nodeIndex | Where-Object { $_.lts } | Select-Object -First 1).version
if (-not $nodeVersion) { throw "Could not resolve the current Node.js LTS release." }
$nodeZip = Join-Path $WorkDirectory "node.zip"
Download "https://nodejs.org/dist/$nodeVersion/node-$nodeVersion-win-x64.zip" $nodeZip
$nodeExtract = Join-Path $WorkDirectory "node"
Expand-Archive $nodeZip $nodeExtract
$nodeRoot = Get-ChildItem $nodeExtract -Directory | Select-Object -First 1
Copy-Item (Join-Path $nodeRoot.FullName "*") $bin -Recurse -Force

Write-Host "[2/6] Claude Code and ChatGPT/Codex CLIs"
& (Join-Path $bin "npm.cmd") install --prefix $appPackages --omit=dev --no-fund --no-audit `
    "@anthropic-ai/claude-code@latest" "@openai/codex@latest"
if ($LASTEXITCODE -ne 0) { throw "npm could not assemble the embedded CLIs." }
$claudePackage = Get-Content (Join-Path $appPackages "node_modules\@anthropic-ai\claude-code\package.json") -Raw | ConvertFrom-Json
$codexPackage = Get-Content (Join-Path $appPackages "node_modules\@openai\codex\package.json") -Raw | ConvertFrom-Json
$claudeEntry = if ($claudePackage.bin -is [string]) { $claudePackage.bin } else { $claudePackage.bin.claude }
$codexEntry = if ($codexPackage.bin -is [string]) { $codexPackage.bin } else { $codexPackage.bin.codex }
$claudeTarget = "%~dp0..\app\node_modules\@anthropic-ai\claude-code\$claudeEntry"
$codexTarget = "%~dp0..\app\node_modules\@openai\codex\$codexEntry"
$claudeCommand = if ($claudeEntry -match '\.exe$') { "`"$claudeTarget`" %*" } else { "`"%~dp0node.exe`" `"$claudeTarget`" %*" }
$codexCommand = if ($codexEntry -match '\.exe$') { "`"$codexTarget`" %*" } else { "`"%~dp0node.exe`" `"$codexTarget`" %*" }
@"
@echo off
$claudeCommand
"@ | Set-Content (Join-Path $bin "claude.cmd") -Encoding Ascii
@"
@echo off
$codexCommand
"@ | Set-Content (Join-Path $bin "codex.cmd") -Encoding Ascii

Write-Host "[3/6] Ollama local runtime"
$ollamaZip = Join-Path $WorkDirectory "ollama.zip"
Download "https://ollama.com/download/ollama-windows-amd64.zip" $ollamaZip
$ollamaDir = Join-Path $payload "ollama"
New-Item $ollamaDir -ItemType Directory -Force | Out-Null
Expand-Archive $ollamaZip $ollamaDir
$ollamaExe = Get-ChildItem $ollamaDir -Filter ollama.exe -Recurse | Select-Object -First 1
if (-not $ollamaExe) { throw "The Ollama archive did not contain ollama.exe." }
$ollamaTarget = Join-Path $ollamaDir "ollama.exe"
if (-not [string]::Equals([IO.Path]::GetFullPath($ollamaExe.FullName), [IO.Path]::GetFullPath($ollamaTarget), [StringComparison]::OrdinalIgnoreCase)) {
    Copy-Item $ollamaExe.FullName $ollamaTarget -Force
}

Write-Host "[4/6] RTK, plugins, and skills"
$toolsDestination = Join-Path $payload "tools"
Copy-Tree (Join-Path $repo "tools") $toolsDestination
$rtkSlot = Join-Path $toolsDestination "win-x64"
New-Item $rtkSlot -ItemType Directory -Force | Out-Null
if (-not (Test-Path (Join-Path $rtkSlot "rtk.exe"))) {
    $release = Get-Json "https://api.github.com/repos/rtk-ai/rtk/releases/latest"
    $asset = $release.assets | Where-Object { $_.name -match 'windows|win32|pc-windows' -and $_.name -match 'x86_64|x64' -and $_.name -match '\.(zip|exe)$' } | Select-Object -First 1
    if (-not $asset) { throw "Could not find an RTK Windows x64 release asset." }
    $rtkDownload = Join-Path $WorkDirectory $asset.name
    Download $asset.browser_download_url $rtkDownload
    if ($asset.name -match '\.exe$') { Copy-Item $rtkDownload (Join-Path $rtkSlot "rtk.exe") }
    else {
        $rtkExtract = Join-Path $WorkDirectory "rtk"
        Expand-Archive $rtkDownload $rtkExtract
        $rtkExe = Get-ChildItem $rtkExtract -Filter rtk.exe -Recurse | Select-Object -First 1
        if (-not $rtkExe) { throw "The RTK archive did not contain rtk.exe." }
        Copy-Item $rtkExe.FullName (Join-Path $rtkSlot "rtk.exe")
    }
}
Copy-Tree (Join-Path $repo "SKILLS-BACKUP") (Join-Path $payload "skills")

Write-Host "[5/6] Compress embedded runtime"
$runtimeZip = Join-Path $WorkDirectory "hydra-runtime.zip"
Compress-Archive -Path (Join-Path $payload "*") -DestinationPath $runtimeZip -CompressionLevel Optimal
$sha256 = [Security.Cryptography.SHA256]::Create()
try {
    $stream = [IO.File]::OpenRead($runtimeZip)
    try { $payloadVersion = ([BitConverter]::ToString($sha256.ComputeHash($stream))).Replace("-", "").ToLowerInvariant() }
    finally { $stream.Dispose() }
} finally { $sha256.Dispose() }
$versionFile = Join-Path $WorkDirectory "hydra-runtime-version.txt"
Set-Content $versionFile $payloadVersion -NoNewline -Encoding Ascii

Write-Host "[6/6] Compile the single-file EXE"
$csc = "$env:WINDIR\Microsoft.NET\Framework64\v4.0.30319\csc.exe"
if (-not (Test-Path $csc)) { $csc = "$env:WINDIR\Microsoft.NET\Framework\v4.0.30319\csc.exe" }
if (-not (Test-Path $csc)) { throw ".NET Framework C# compiler not found." }
$outputDirectory = Split-Path $Output -Parent
if ($outputDirectory) { New-Item $outputDirectory -ItemType Directory -Force | Out-Null }
& $csc /nologo /target:winexe "/out:$Output" "/win32icon:$PSScriptRoot\bot.ico" `
    "/resource:$PSScriptRoot\bot.ico,bot.ico" "/resource:$PSScriptRoot\bot.png,bot.png" `
    "/resource:$runtimeZip,hydra-runtime.zip" "/resource:$versionFile,hydra-runtime-version.txt" `
    /reference:System.dll /reference:System.Drawing.dll /reference:System.Windows.Forms.dll `
    /reference:System.IO.Compression.dll /reference:System.IO.Compression.FileSystem.dll `
    (Join-Path $PSScriptRoot "Hydra.cs")
if ($LASTEXITCODE -ne 0) { throw "Hydra compilation failed." }

$size = [Math]::Round((Get-Item $Output).Length / 1MB, 1)
Write-Host "Built $Output ($size MB)"
if (-not $KeepWorkDirectory) { Remove-Item $WorkDirectory -Recurse -Force }
