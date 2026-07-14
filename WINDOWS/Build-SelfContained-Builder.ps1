param(
    [string]$Output = (Join-Path $PSScriptRoot "Hydra-SelfContained-Builder.exe")
)

$ErrorActionPreference = "Stop"
$source = Join-Path $PSScriptRoot "SelfContainedBuilder.cs"
if (-not (Test-Path $source -PathType Leaf)) {
    throw "Self-contained builder source is missing: $source"
}

$csc = "$env:WINDIR\Microsoft.NET\Framework64\v4.0.30319\csc.exe"
if (-not (Test-Path $csc -PathType Leaf)) {
    $csc = "$env:WINDIR\Microsoft.NET\Framework\v4.0.30319\csc.exe"
}
if (-not (Test-Path $csc -PathType Leaf)) {
    throw ".NET Framework C# compiler not found."
}

$outputDirectory = Split-Path $Output -Parent
if ($outputDirectory) { New-Item $outputDirectory -ItemType Directory -Force | Out-Null }
$iconArgument = if (Test-Path (Join-Path $PSScriptRoot "bot.ico") -PathType Leaf) {
    "/win32icon:$PSScriptRoot\bot.ico"
} else { $null }

$compilerArguments = @(
    "/nologo",
    "/target:exe",
    "/platform:anycpu",
    "/optimize+",
    "/out:$Output"
)
if ($iconArgument) { $compilerArguments += $iconArgument }
$compilerArguments += "/reference:System.dll"
$compilerArguments += $source

& $csc @compilerArguments
if ($LASTEXITCODE -ne 0) { throw "Self-contained builder EXE compilation failed." }
Write-Host "Built $Output"
