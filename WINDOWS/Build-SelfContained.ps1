param(
    [string]$Output = (Join-Path $PSScriptRoot "Hydra-SelfContained.exe"),
    [string]$WorkDirectory = (Join-Path $env:TEMP "hydra-self-contained-build"),
    [string]$OllamaPackOutput,
    [switch]$KeepWorkDirectory,
    [switch]$SkipOllama
)

$ErrorActionPreference = "Stop"
$ProgressPreference = "SilentlyContinue"
$repo = Split-Path $PSScriptRoot -Parent
$payload = Join-Path $WorkDirectory "payload"
$bin = Join-Path $payload "bin"
$appPackages = Join-Path $payload "app"
$lockFile = Join-Path $repo "runtime\runtime-lock.json"
$lock = Get-Content $lockFile -Raw | ConvertFrom-Json
if (-not $OllamaPackOutput) {
    $outputParent = Split-Path $Output -Parent
    if (-not $outputParent) { $outputParent = "." }
    $OllamaPackOutput = Join-Path $outputParent "Hydra-Windows-x64-Ollama-Offline-Pack.zip"
}

function Get-Sha256([string]$Path) {
    $sha256 = [Security.Cryptography.SHA256]::Create()
    try {
        $stream = [IO.File]::OpenRead($Path)
        try { $actual = ([BitConverter]::ToString($sha256.ComputeHash($stream))).Replace("-", "").ToLowerInvariant() }
        finally { $stream.Dispose() }
    } finally { $sha256.Dispose() }
    return $actual
}
function Get-NormalizedTextSha256([string]$Path) {
    $text = [IO.File]::ReadAllText($Path).Replace("`r`n", "`n").Replace("`r", "`n")
    $bytes = (New-Object Text.UTF8Encoding($false)).GetBytes($text)
    $sha256 = [Security.Cryptography.SHA256]::Create()
    try { return ([BitConverter]::ToString($sha256.ComputeHash($bytes))).Replace("-", "").ToLowerInvariant() }
    finally { $sha256.Dispose() }
}
function Download-Verified([string]$Url, [string]$Destination, [string]$ExpectedSha256) {
    Write-Host "  download $Url"
    Invoke-WebRequest -Uri $Url -OutFile $Destination -UseBasicParsing
    $actual = Get-Sha256 $Destination
    if ($actual -ne $ExpectedSha256.ToLowerInvariant()) {
        throw "SHA-256 mismatch for $Url. Expected $ExpectedSha256, received $actual."
    }
}
function Invoke-Checked([string]$Command, [string[]]$Arguments = @("--version")) {
    & $Command @Arguments
    if ($LASTEXITCODE -ne 0) { throw "$Command failed with exit code $LASTEXITCODE." }
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

if (-not (Get-Command uv -ErrorAction SilentlyContinue)) {
    throw "The pinned uv $($lock.uv) build dependency is required. Install uv on the build machine; target PCs do not need it."
}
$uvVersion = (& uv --version) -replace '^uv\s+', '' -replace '\s+\(.*$', ''
if ($uvVersion -ne $lock.uv) { throw "Expected uv $($lock.uv), found $uvVersion." }

Write-Host "[1/8] Portable Node.js runtime"
$node = $lock.node.'windows-x64'
$nodeZip = Join-Path $WorkDirectory "node.zip"
Download-Verified $node.url $nodeZip $node.sha256
$nodeExtract = Join-Path $WorkDirectory "node"
Expand-Archive $nodeZip $nodeExtract
$nodeRoot = Get-ChildItem $nodeExtract -Directory | Select-Object -First 1
Copy-Item (Join-Path $nodeRoot.FullName "*") $bin -Recurse -Force

Write-Host "[2/8] Pinned Claude Code and ChatGPT/Codex CLIs"
New-Item $appPackages -ItemType Directory -Force | Out-Null
Copy-Item (Join-Path $repo "runtime\package.json") $appPackages
Copy-Item (Join-Path $repo "runtime\package-lock.json") $appPackages
& (Join-Path $bin "npm.cmd") ci --prefix $appPackages --omit=dev --no-fund --no-audit
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
set "CLAUDE_CODE_GIT_BASH_PATH=%~dp0..\git\bin\bash.exe"
$claudeCommand
"@ | Set-Content (Join-Path $bin "claude.cmd") -Encoding Ascii
@"
@echo off
$codexCommand
"@ | Set-Content (Join-Path $bin "codex.cmd") -Encoding Ascii

Write-Host "[3/8] Portable Hermes Python runtime"
$pythonInstall = Join-Path $WorkDirectory "python-install"
& uv python install $lock.python --install-dir $pythonInstall --no-bin --no-registry
if ($LASTEXITCODE -ne 0) { throw "uv could not assemble the managed Python runtime." }
$pythonSource = Get-ChildItem $pythonInstall -Directory | Where-Object { $_.Name -match '^cpython-\d+\.\d+\.\d+-windows-x86_64-none$' } | Select-Object -First 1
if (-not $pythonSource) { throw "The managed Python runtime directory was not found." }
$pythonRoot = Join-Path $payload "python"
Copy-Tree $pythonSource.FullName $pythonRoot
$pythonExe = Join-Path $pythonRoot "python.exe"
$sitePackages = Join-Path $pythonRoot "Lib\site-packages"

$hermesSourceArchive = Join-Path $WorkDirectory "hermes-agent.tar.gz"
Download-Verified $lock.hermes.sdistUrl $hermesSourceArchive $lock.hermes.sdistSha256
$hermesSourceParent = Join-Path $WorkDirectory "hermes-source"
New-Item $hermesSourceParent -ItemType Directory -Force | Out-Null
& tar -xzf $hermesSourceArchive -C $hermesSourceParent
if ($LASTEXITCODE -ne 0) { throw "Could not extract the Hermes source metadata." }
$hermesSource = Get-ChildItem $hermesSourceParent -Directory | Select-Object -First 1
if (-not $hermesSource) { throw "The Hermes source metadata directory was not found." }
Download-Verified $lock.hermes.uvLockUrl (Join-Path $hermesSource.FullName "uv.lock") $lock.hermes.uvLockSha256
$hermesRequirements = Join-Path $WorkDirectory "hermes-requirements.txt"
& uv export --project $hermesSource.FullName --frozen --extra all --no-dev --no-emit-project --output-file $hermesRequirements | Out-Null
if ($LASTEXITCODE -ne 0) { throw "Could not export Hermes' locked dependencies." }
& uv pip install --python $pythonExe --target $sitePackages --require-hashes --requirements $hermesRequirements
if ($LASTEXITCODE -ne 0) { throw "Could not install Hermes' locked dependencies." }
$hermesWheel = Join-Path $WorkDirectory "hermes_agent-0.18.2-py3-none-any.whl"
Download-Verified $lock.hermes.wheelUrl $hermesWheel $lock.hermes.wheelSha256
& uv pip install --python $pythonExe --target $sitePackages --no-deps $hermesWheel
if ($LASTEXITCODE -ne 0) { throw "Could not install the pinned Hermes wheel." }
$securityOverrides = Join-Path $repo ($lock.hermes.securityOverridesPath -replace '/', '\')
$securityOverridesHash = Get-NormalizedTextSha256 $securityOverrides
if ($securityOverridesHash -ne $lock.hermes.securityOverridesSha256) {
    throw "Hermes security override hash mismatch. Expected $($lock.hermes.securityOverridesSha256), received $securityOverridesHash."
}
& uv pip install --python $pythonExe --target $sitePackages --upgrade --no-deps --require-hashes --only-binary :all: --requirements $securityOverrides
if ($LASTEXITCODE -ne 0) { throw "Could not apply Hermes' hashed security overrides." }

$ffmpegWheel = Join-Path $WorkDirectory "imageio_ffmpeg-0.6.0-py3-none-win_amd64.whl"
$ffmpeg = $lock.ffmpeg.'windows-x64'
Download-Verified $ffmpeg.url $ffmpegWheel $ffmpeg.sha256
& uv pip install --python $pythonExe --target $sitePackages --no-deps $ffmpegWheel
if ($LASTEXITCODE -ne 0) { throw "Could not install the pinned FFmpeg wheel." }
$ffmpegExe = Get-ChildItem (Join-Path $sitePackages "imageio_ffmpeg\binaries") -Filter "ffmpeg-*.exe" | Select-Object -First 1
if (-not $ffmpegExe) { throw "The FFmpeg wheel did not contain ffmpeg.exe." }
Copy-Item $ffmpegExe.FullName (Join-Path $bin "ffmpeg.exe") -Force

@"
@echo off
"%~dp0..\python\python.exe" %*
"@ | Set-Content (Join-Path $bin "python.cmd") -Encoding Ascii
@"
@echo off
set "PATH=%~dp0;%~dp0..\git\cmd;%~dp0..\git\bin;%~dp0..\git\usr\bin;%PATH%"
"%~dp0..\python\python.exe" -m hermes_cli.main %*
"@ | Set-Content (Join-Path $bin "hermes.cmd") -Encoding Ascii

Write-Host "[4/8] Portable Git Bash and ripgrep"
$gitArchive = Join-Path $WorkDirectory "portable-git.7z.exe"
$git = $lock.git.'windows-x64'
Download-Verified $git.url $gitArchive $git.sha256
$gitRoot = Join-Path $payload "git"
New-Item $gitRoot -ItemType Directory -Force | Out-Null
$gitExtraction = Start-Process -FilePath $gitArchive -ArgumentList @("-y", "-o`"$gitRoot`"") -Wait -PassThru -WindowStyle Hidden
if ($gitExtraction.ExitCode -ne 0) { throw "Could not extract the verified PortableGit archive (exit $($gitExtraction.ExitCode))." }
if (-not (Test-Path (Join-Path $gitRoot "bin\bash.exe")) -or -not (Test-Path (Join-Path $gitRoot "cmd\git.exe"))) {
    throw "The PortableGit archive did not contain Git Bash and git.exe."
}

$rgArchive = Join-Path $WorkDirectory "ripgrep.zip"
$ripgrep = $lock.ripgrep.'windows-x64'
Download-Verified $ripgrep.url $rgArchive $ripgrep.sha256
$rgExtract = Join-Path $WorkDirectory "ripgrep"
Expand-Archive $rgArchive $rgExtract
$rgExe = Get-ChildItem $rgExtract -Filter rg.exe -Recurse | Select-Object -First 1
if (-not $rgExe) { throw "The ripgrep archive did not contain rg.exe." }
Copy-Item $rgExe.FullName (Join-Path $bin "rg.exe") -Force

Write-Host "[5/8] Ollama local runtime"
$ollamaExpectedHash = Join-Path $WorkDirectory "hydra-ollama-sidecar.sha256"
$ollama = $lock.ollama.'windows-x64'
Set-Content $ollamaExpectedHash $ollama.sha256 -NoNewline -Encoding Ascii
if (-not $SkipOllama) {
    $ollamaOutputDirectory = Split-Path $OllamaPackOutput -Parent
    if ($ollamaOutputDirectory) { New-Item $ollamaOutputDirectory -ItemType Directory -Force | Out-Null }
    Download-Verified $ollama.url $OllamaPackOutput $ollama.sha256
} else {
    Write-Warning "Skipping the adjacent Ollama pack creates a developer-only artifact that does not meet the complete offline release contract."
}

Write-Host "[6/8] RTK, plugins, and skills"
$toolsDestination = Join-Path $payload "tools"
Copy-Tree (Join-Path $repo "tools") $toolsDestination
$rtkSlot = Join-Path $toolsDestination "win-x64"
New-Item $rtkSlot -ItemType Directory -Force | Out-Null
if (-not (Test-Path (Join-Path $rtkSlot "rtk.exe"))) {
    $rtkDownload = Join-Path $WorkDirectory "rtk.zip"
    $rtk = $lock.rtk.'windows-x64'
    Download-Verified $rtk.url $rtkDownload $rtk.sha256
    $rtkExtract = Join-Path $WorkDirectory "rtk"
    Expand-Archive $rtkDownload $rtkExtract
    $rtkExe = Get-ChildItem $rtkExtract -Filter rtk.exe -Recurse | Select-Object -First 1
    if (-not $rtkExe) { throw "The RTK archive did not contain rtk.exe." }
    Copy-Item $rtkExe.FullName (Join-Path $rtkSlot "rtk.exe")
}
Copy-Tree (Join-Path $repo "SKILLS-BACKUP") (Join-Path $payload "skills")
Copy-Item (Join-Path $repo "THIRD-PARTY-NOTICES.md") (Join-Path $payload "THIRD-PARTY-NOTICES.md")

Write-Host "[7/8] Verify and compress embedded runtime"
Invoke-Checked (Join-Path $bin "node.exe")
Invoke-Checked (Join-Path $bin "claude.cmd")
Invoke-Checked (Join-Path $bin "codex.cmd")
Invoke-Checked (Join-Path $bin "hermes.cmd")
Invoke-Checked (Join-Path $bin "python.cmd")
Invoke-Checked (Join-Path $gitRoot "cmd\git.exe")
Invoke-Checked (Join-Path $bin "rg.exe")
Invoke-Checked (Join-Path $bin "ffmpeg.exe") @("-version")
Invoke-Checked (Join-Path $rtkSlot "rtk.exe")
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

Write-Host "[8/8] Compile the single-file EXE"
$csc = "$env:WINDIR\Microsoft.NET\Framework64\v4.0.30319\csc.exe"
if (-not (Test-Path $csc)) { $csc = "$env:WINDIR\Microsoft.NET\Framework\v4.0.30319\csc.exe" }
if (-not (Test-Path $csc)) { throw ".NET Framework C# compiler not found." }
$outputDirectory = Split-Path $Output -Parent
if ($outputDirectory) { New-Item $outputDirectory -ItemType Directory -Force | Out-Null }
& $csc /nologo /target:winexe "/out:$Output" "/win32icon:$PSScriptRoot\bot.ico" `
    "/resource:$PSScriptRoot\bot.ico,bot.ico" "/resource:$PSScriptRoot\bot.png,bot.png" `
    "/resource:$runtimeZip,hydra-runtime.zip" "/resource:$versionFile,hydra-runtime-version.txt" `
    "/resource:$ollamaExpectedHash,hydra-ollama-sidecar.sha256" `
    /reference:System.dll /reference:System.Drawing.dll /reference:System.Windows.Forms.dll `
    /reference:System.IO.Compression.dll /reference:System.IO.Compression.FileSystem.dll `
    (Join-Path $PSScriptRoot "Hydra.cs")
if ($LASTEXITCODE -ne 0) { throw "Hydra compilation failed." }

$size = [Math]::Round((Get-Item $Output).Length / 1MB, 1)
Write-Host "Built $Output ($size MB)"
if (-not $SkipOllama) {
    $ollamaSize = [Math]::Round((Get-Item $OllamaPackOutput).Length / 1MB, 1)
    Write-Host "Built $OllamaPackOutput ($ollamaSize MB); keep it next to the EXE for zero-network Ollama setup."
}
if (-not $KeepWorkDirectory) { Remove-Item $WorkDirectory -Recurse -Force }
