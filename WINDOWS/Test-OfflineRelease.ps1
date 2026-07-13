param(
    [string]$PayloadRoot,
    [string]$RepositoryRoot = (Split-Path $PSScriptRoot -Parent),
    [switch]$SkipCommandChecks
)

$ErrorActionPreference = "Stop"

function Assert-Contains([string]$Text, [string]$Pattern, [string]$Message) {
    if ($Text -notmatch $Pattern) { throw $Message }
}

function Assert-NotContains([string]$Text, [string]$Pattern, [string]$Message) {
    if ($Text -match $Pattern) { throw $Message }
}

function Assert-File([string]$Path) {
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        throw "Offline payload is missing: $Path"
    }
}

function Invoke-Version([string]$Command, [string[]]$Arguments = @("--version")) {
    & $Command @Arguments
    if ($LASTEXITCODE -ne 0) { throw "$Command failed with exit code $LASTEXITCODE" }
}

$source = Get-Content (Join-Path $RepositoryRoot "WINDOWS\Hydra.cs") -Raw
$builder = Get-Content (Join-Path $RepositoryRoot "WINDOWS\Build-SelfContained.ps1") -Raw

$provision = [regex]::Match(
    $source,
    'void ProvisionNativeToolchain\(\)(?<body>[\s\S]*?)\n    string FindSkillsSource\(\)'
)
if (-not $provision.Success) { throw "Could not locate ProvisionNativeToolchain()." }
Assert-NotContains $provision.Groups["body"].Value `
    '(ClaudeInstallCmd|CodexInstallCmd|RtkDownloadScript|Invoke-WebRequest|https?://)' `
    "Normal Windows startup still contains an online installer fallback."

$hermesRepair = [regex]::Match(
    $source,
    'void InstallHermes\(\)(?<body>[\s\S]*?)\n    void CheckHermesUpdate\(\)'
)
if (-not $hermesRepair.Success) { throw "Could not locate InstallHermes()." }
Assert-NotContains $hermesRepair.Groups["body"].Value `
    '(irm |Invoke-RestMethod|curl |https?://)' `
    "Windows Hermes repair still downloads and executes a remote installer."
Assert-Contains $source 'Hydra-Windows-x64-Ollama-Offline-Pack\.zip' `
    "Windows does not provision the verified local Ollama sidecar."

$cliRepairs = [regex]::Match(
    $source,
    'void InstallClaudeCli\(\)(?<body>[\s\S]*?)\n    void InstallHermes\(\)'
)
if (-not $cliRepairs.Success) { throw "Could not locate Windows CLI repair actions." }
Assert-NotContains $cliRepairs.Groups["body"].Value `
    '(ClaudeInstallCmd|CodexInstallCmd|Invoke-WebRequest|npm install|https?://)' `
    "A Windows CLI repair action still invokes an online installer."

$ollamaRepair = [regex]::Match(
    $source,
    'void InstallOllama\(\)(?<body>[\s\S]*?)\n    static string OllamaPortableScript\(\)'
)
if (-not $ollamaRepair.Success) { throw "Could not locate Windows Ollama repair." }
Assert-NotContains $ollamaRepair.Groups["body"].Value `
    '(Download|Invoke-WebRequest|https?://)' `
    "Windows Ollama repair still downloads a runtime."

$allRepair = [regex]::Match(
    $source,
    'void InstallEverything\(\)(?<body>[\s\S]*?)\n    void UpdateCore\(\)'
)
if (-not $allRepair.Success) { throw "Could not locate Windows bundled-tool repair." }
Assert-NotContains $allRepair.Groups["body"].Value `
    '(ClaudeInstallCmd|CodexInstallCmd|RtkDownloadScript|Invoke-WebRequest|npm install|https?://)' `
    "Windows bundled-tool repair still invokes an online installer."

foreach ($requiredBuildMarker in @(
    'hermes.cmd',
    'securityOverridesPath',
    'python.exe',
    'bash.exe',
    'git.exe',
    'rg.exe',
    'ffmpeg.exe'
)) {
    Assert-Contains $builder ([regex]::Escape($requiredBuildMarker)) `
        "Windows self-contained builder does not assemble $requiredBuildMarker."
}

if (-not $PayloadRoot) {
    Write-Host "Windows zero-network source contract passed."
    exit 0
}

$PayloadRoot = [IO.Path]::GetFullPath($PayloadRoot)
$bin = Join-Path $PayloadRoot "bin"
$requiredFiles = @(
    (Join-Path $bin "node.exe"),
    (Join-Path $bin "claude.cmd"),
    (Join-Path $bin "codex.cmd"),
    (Join-Path $bin "hermes.cmd"),
    (Join-Path $bin "python.cmd"),
    (Join-Path $PayloadRoot "python\python.exe"),
    (Join-Path $PayloadRoot "git\bin\bash.exe"),
    (Join-Path $PayloadRoot "git\cmd\git.exe"),
    (Join-Path $bin "rg.exe"),
    (Join-Path $bin "ffmpeg.exe"),
    (Join-Path $PayloadRoot "ollama\ollama.exe"),
    (Join-Path $PayloadRoot "tools\win-x64\rtk.exe")
)
foreach ($file in $requiredFiles) { Assert-File $file }

if (-not $SkipCommandChecks) {
    $oldPath = $env:PATH
    $oldHome = $env:USERPROFILE
    $testHome = Join-Path ([IO.Path]::GetTempPath()) ("hydra-offline-home-" + [Guid]::NewGuid().ToString("N"))
    try {
        New-Item $testHome -ItemType Directory -Force | Out-Null
        $env:USERPROFILE = $testHome
        $env:HOME = $testHome
        $env:PATH = "$bin;$env:WINDIR\System32;$env:WINDIR"
        $env:UV_OFFLINE = "1"
        $env:PIP_NO_INDEX = "1"
        $env:npm_config_offline = "true"
        Invoke-Version (Join-Path $bin "node.exe")
        Invoke-Version (Join-Path $bin "claude.cmd")
        Invoke-Version (Join-Path $bin "codex.cmd")
        Invoke-Version (Join-Path $bin "hermes.cmd")
        Invoke-Version (Join-Path $bin "python.cmd")
        Invoke-Version (Join-Path $PayloadRoot "git\cmd\git.exe")
        Invoke-Version (Join-Path $bin "rg.exe")
        Invoke-Version (Join-Path $bin "ffmpeg.exe") @("-version")
        Invoke-Version (Join-Path $PayloadRoot "ollama\ollama.exe")
        Invoke-Version (Join-Path $PayloadRoot "tools\win-x64\rtk.exe")
    }
    finally {
        $env:PATH = $oldPath
        $env:USERPROFILE = $oldHome
        Remove-Item -LiteralPath $testHome -Recurse -Force -ErrorAction SilentlyContinue
    }
}

Write-Host "Windows zero-network payload contract passed."
