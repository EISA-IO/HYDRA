param(
    [Parameter(Mandatory = $true)]
    [string]$Executable,
    [string]$Screenshot = (Join-Path $env:TEMP "hydra-windows-ui.png")
)

$ErrorActionPreference = "Stop"
Remove-Item $Screenshot -Force -ErrorAction SilentlyContinue

$process = Start-Process -FilePath $Executable `
    -ArgumentList @("--screenshot", $Screenshot) `
    -PassThru

if (-not $process.WaitForExit(15000)) {
    Stop-Process -Id $process.Id -Force -ErrorAction SilentlyContinue
    throw "Hydra did not finish screenshot mode within 15 seconds."
}
if ($process.ExitCode -ne 0) {
    throw "Hydra screenshot mode exited with code $($process.ExitCode)."
}
if (-not (Test-Path $Screenshot)) {
    throw "Hydra did not create the expected screenshot: $Screenshot"
}

Add-Type -AssemblyName System.Drawing
$image = [System.Drawing.Image]::FromFile($Screenshot)
try {
    if ($image.Width -lt 940 -or $image.Height -lt 640) {
        throw "Screenshot is $($image.Width)x$($image.Height); expected at least 940x640."
    }
    if ((Get-Item $Screenshot).Length -lt 10000) {
        throw "Screenshot is unexpectedly small and likely blank."
    }
    Write-Output "Hydra Windows UI rendered: $($image.Width)x$($image.Height), $((Get-Item $Screenshot).Length) bytes"
}
finally {
    $image.Dispose()
}
