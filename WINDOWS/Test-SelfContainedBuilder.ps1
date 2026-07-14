param()

$ErrorActionPreference = "Stop"
$repo = Split-Path $PSScriptRoot -Parent
$compiler = Join-Path $PSScriptRoot "Build-SelfContained-Builder.ps1"
$source = Join-Path $PSScriptRoot "SelfContainedBuilder.cs"

foreach ($required in @($compiler, $source, (Join-Path $PSScriptRoot "Build-SelfContained.ps1"))) {
    if (-not (Test-Path $required -PathType Leaf)) {
        throw "Required self-contained builder file is missing: $required"
    }
}

$testRoot = Join-Path $env:TEMP ("hydra-self-contained-builder-test-" + [Guid]::NewGuid().ToString("N"))
$builderDirectory = Join-Path $testRoot "dist"
$fixtureWindowsDirectory = Join-Path $testRoot "WINDOWS"
$builderExe = Join-Path $builderDirectory "Hydra-SelfContained-Builder.exe"
$hydraOutput = Join-Path $testRoot "output folder\Hydra-Windows-x64-SelfContained.exe"
$expectedOllama = Join-Path (Split-Path $hydraOutput -Parent) "Hydra-Windows-x64-Ollama-Offline-Pack.zip"
$workDirectory = Join-Path $testRoot "build work"
New-Item $testRoot -ItemType Directory -Force | Out-Null

try {
    & $compiler -Output $builderExe
    if ($LASTEXITCODE -ne 0 -or -not (Test-Path $builderExe -PathType Leaf)) {
        throw "The builder EXE did not compile."
    }

    New-Item $fixtureWindowsDirectory -ItemType Directory -Force | Out-Null
    @'
param(
    [string]$Output,
    [string]$OllamaPackOutput,
    [string]$WorkDirectory,
    [switch]$KeepWorkDirectory
)
$outputDirectory = Split-Path $Output -Parent
New-Item $outputDirectory -ItemType Directory -Force | Out-Null
Set-Content $Output "fixture Hydra EXE"
Set-Content $OllamaPackOutput "fixture Ollama pack"
@(
    "output=$Output"
    "ollama=$OllamaPackOutput"
    "work=$WorkDirectory"
    "keep=$($KeepWorkDirectory.IsPresent)"
) | Set-Content (Join-Path $outputDirectory "builder-arguments.txt")
'@ | Set-Content (Join-Path $fixtureWindowsDirectory "Build-SelfContained.ps1") -Encoding UTF8

    $dryRun = & $builderExe --dry-run --output $hydraOutput 2>&1 | Out-String
    if ($LASTEXITCODE -ne 0) { throw "Builder dry-run failed:`n$dryRun" }
    foreach ($expected in @(
        "Build-SelfContained.ps1",
        [IO.Path]::GetFullPath($hydraOutput),
        [IO.Path]::GetFullPath($expectedOllama),
        "Dry run: no files were built."
    )) {
        if (-not $dryRun.Contains($expected)) {
            throw "Builder dry-run did not report '$expected'. Output:`n$dryRun"
        }
    }

    $buildRun = & $builderExe --output $hydraOutput --work-directory $workDirectory --keep-work-directory 2>&1 | Out-String
    if ($LASTEXITCODE -ne 0) { throw "Builder fixture build failed:`n$buildRun" }
    if (-not (Test-Path $hydraOutput -PathType Leaf) -or -not (Test-Path $expectedOllama -PathType Leaf)) {
        throw "Builder did not create both required Windows package files."
    }
    $reportedArguments = Get-Content (Join-Path (Split-Path $hydraOutput -Parent) "builder-arguments.txt") -Raw
    foreach ($expected in @(
        "output=$([IO.Path]::GetFullPath($hydraOutput))",
        "ollama=$([IO.Path]::GetFullPath($expectedOllama))",
        "work=$([IO.Path]::GetFullPath($workDirectory))",
        "keep=True"
    )) {
        if (-not $reportedArguments.Contains($expected)) {
            throw "Builder did not forward '$expected'. Arguments:`n$reportedArguments"
        }
    }

    $help = & $builderExe --help 2>&1 | Out-String
    if ($LASTEXITCODE -ne 0 -or -not $help.Contains("--output <path>")) {
        throw "Builder help contract failed:`n$help"
    }

    $previousErrorAction = $ErrorActionPreference
    $ErrorActionPreference = "Continue"
    $invalid = & $builderExe --not-a-real-option 2>&1 | Out-String
    $invalidExitCode = $LASTEXITCODE
    $ErrorActionPreference = $previousErrorAction
    if ($invalidExitCode -eq 0 -or -not $invalid.Contains("Unknown option")) {
        throw "Builder must reject unknown options. Output:`n$invalid"
    }

    Write-Host "Windows self-contained builder EXE contract passed."
}
finally {
    if (Test-Path $testRoot) {
        Remove-Item $testRoot -Recurse -Force
    }
}

# The invalid-option assertion intentionally runs a native process that exits 2.
# PowerShell 7 otherwise propagates that stale native status after this test passes.
exit 0
