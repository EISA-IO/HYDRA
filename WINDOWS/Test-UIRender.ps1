param(
    [Parameter(Mandatory = $true)]
    [string]$Executable,
    [string]$Screenshot = (Join-Path $env:TEMP "hydra-windows-ui.png"),
    [ValidateRange(0, 4)]
    [int]$Tab = 0
)

$ErrorActionPreference = "Stop"
Remove-Item $Screenshot -Force -ErrorAction SilentlyContinue

$process = Start-Process -FilePath $Executable `
    -ArgumentList @("--screenshot", $Screenshot, "--tab", $Tab) `
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
$image = [System.Drawing.Bitmap]::FromFile($Screenshot)
try {
    if ($image.Width -lt 940 -or $image.Height -lt 640) {
        throw "Screenshot is $($image.Width)x$($image.Height); expected at least 940x640."
    }
    if ((Get-Item $Screenshot).Length -lt 10000) {
        throw "Screenshot is unexpectedly small and likely blank."
    }

    function Assert-PixelNear([string]$Name, [int]$X, [int]$Y, [int[]]$Expected, [int]$Tolerance = 8) {
        $pixel = $image.GetPixel($X, $Y)
        if ([Math]::Abs($pixel.R - $Expected[0]) -gt $Tolerance -or
            [Math]::Abs($pixel.G - $Expected[1]) -gt $Tolerance -or
            [Math]::Abs($pixel.B - $Expected[2]) -gt $Tolerance) {
            throw "$Name pixel at ($X,$Y) was $($pixel.R),$($pixel.G),$($pixel.B); expected near $($Expected -join ',')."
        }
    }

    function Assert-RegionHasInk([string]$Name, [int]$X, [int]$Y, [int]$Width, [int]$Height, [int]$Minimum = 20) {
        $ink = 0
        for ($px = $X; $px -lt ($X + $Width); $px += 2) {
            for ($py = $Y; $py -lt ($Y + $Height); $py += 2) {
                $pixel = $image.GetPixel($px, $py)
                if ([Math]::Max($pixel.R, [Math]::Max($pixel.G, $pixel.B)) -gt 75) { $ink++ }
            }
        }
        if ($ink -lt $Minimum) {
            throw "$Name contains only $ink bright samples; expected at least $Minimum rendered-text samples."
        }
    }

    Assert-PixelNear "sidebar" 4 500 @(16, 16, 18)
    Assert-PixelNear "content canvas" 200 40 @(22, 22, 25)
    Assert-PixelNear "active navigation accent" 8 (139 + 40 * $Tab) @(217, 119, 87) 12
    if ($Tab -eq 0) {
        Assert-PixelNear "project path field" 620 65 @(43, 43, 51) 12
        Assert-PixelNear "recent folders control" 755 65 @(40, 40, 45) 12
        Assert-PixelNear "terminal host" 500 300 @(16, 16, 18) 10
    }
    Assert-RegionHasInk "sidebar brand" 48 48 100 42 20
    Assert-RegionHasInk "Ollama action" 34 344 135 28 18
    Assert-RegionHasInk "sidebar footer" 14 618 164 46 15
    Write-Output "Hydra Windows tab $Tab rendered: $($image.Width)x$($image.Height), $((Get-Item $Screenshot).Length) bytes"
}
finally {
    $image.Dispose()
}
