param(
    [Parameter(Mandatory = $true)]
    [string]$Executable,
    [string]$Screenshot = (Join-Path $env:TEMP "hydra-windows-ui.png"),
    [ValidateRange(0, 6)]
    [int]$Tab = 0,
    [switch]$DemoLaunch,
    [switch]$DemoHermes,
    [switch]$FreshTerminalInput,
    [ValidateRange(5, 600)]
    [int]$TimeoutSeconds = 15
)

$ErrorActionPreference = "Stop"
Remove-Item $Screenshot -Force -ErrorAction SilentlyContinue

if ($FreshTerminalInput) {
    $sentinel = Join-Path $env:TEMP ("hydrafreshinput" + [Guid]::NewGuid().ToString("N"))
    try {
        $process = Start-Process -FilePath $Executable `
            -ArgumentList @("--test-fresh-input", $sentinel) `
            -PassThru
        if (-not $process.WaitForExit($TimeoutSeconds * 1000)) {
            Stop-Process -Id $process.Id -Force -ErrorAction SilentlyContinue
            throw "Hydra did not finish the fresh-terminal input test within $TimeoutSeconds seconds."
        }
        if ($process.ExitCode -ne 0) {
            $diagnostic = if (Test-Path ($sentinel + ".diag")) { Get-Content -Raw ($sentinel + ".diag") } else { "no focus diagnostic" }
            throw "Hydra fresh-terminal input test exited with code $($process.ExitCode). $diagnostic"
        }
        if (-not (Test-Path $sentinel -PathType Container)) {
            throw "The first embedded terminal did not receive normal keyboard input."
        }
        Write-Output "Hydra first embedded terminal accepted keyboard input."
        return
    }
    finally {
        Remove-Item $sentinel -Force -ErrorAction SilentlyContinue
        Remove-Item ($sentinel + ".diag") -Force -ErrorAction SilentlyContinue
    }
}

$arguments = @("--screenshot", $Screenshot, "--tab", $Tab)
if ($DemoLaunch) { $arguments += "--demolaunch" }
if ($DemoHermes) { $arguments += "--demohermes" }
$process = Start-Process -FilePath $Executable `
    -ArgumentList $arguments `
    -PassThru

if (-not $process.WaitForExit($TimeoutSeconds * 1000)) {
    Stop-Process -Id $process.Id -Force -ErrorAction SilentlyContinue
    throw "Hydra did not finish screenshot mode within $TimeoutSeconds seconds."
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

    # Majority-color check for regions that contain text: single-pixel asserts break on
    # ClearType glyph fringes that land differently per machine (font metrics, user name).
    function Assert-RegionMostly([string]$Name, [int]$X, [int]$Y, [int]$Width, [int]$Height, [int[]]$Expected, [int]$Tolerance = 12, [double]$MinFraction = 0.5) {
        $match = 0; $total = 0
        for ($px = $X; $px -lt ($X + $Width); $px += 2) {
            for ($py = $Y; $py -lt ($Y + $Height); $py += 2) {
                $pixel = $image.GetPixel($px, $py); $total++
                if ([Math]::Abs($pixel.R - $Expected[0]) -le $Tolerance -and
                    [Math]::Abs($pixel.G - $Expected[1]) -le $Tolerance -and
                    [Math]::Abs($pixel.B - $Expected[2]) -le $Tolerance) { $match++ }
            }
        }
        if ($total -eq 0 -or ($match / $total) -lt $MinFraction) {
            throw "$Name region ($X,$Y ${Width}x$Height) had $match/$total pixels near $($Expected -join ','); expected at least $($MinFraction * 100)%."
        }
    }

    function Assert-RegionHasInk([string]$Name, [int]$X, [int]$Y, [int]$Width, [int]$Height, [int]$Minimum = 20) {
        $ink = 0
        for ($px = $X; $px -lt ($X + $Width); $px += 2) {
            for ($py = $Y; $py -lt ($Y + $Height); $py += 2) {
                $pixel = $image.GetPixel($px, $py)
                if ($pixel.A -gt 240 -and [Math]::Max($pixel.R, [Math]::Max($pixel.G, $pixel.B)) -gt 75) { $ink++ }
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
        if ($DemoLaunch -or $DemoHermes) {
            Assert-RegionHasInk "new terminal tab" 210 100 500 65 30
        } else {
            Assert-RegionMostly "project path field" 545 57 130 18 @(43, 43, 51)
            Assert-RegionHasInk "toolbar controls" 700 55 320 24 25
            Assert-PixelNear "terminal host" 500 300 @(16, 16, 18) 10
        }
    }
    if ($Tab -eq 1) { Assert-RegionHasInk "Settings section navigation" 210 108 500 40 30 }
    if ($Tab -eq 2) { Assert-RegionMostly "SaaS dropdown" 905 129 28 12 @(43, 43, 51) }
    Assert-RegionHasInk "sidebar brand" 48 48 100 42 20
    Assert-RegionHasInk "Ollama action" 34 408 135 24 18
    if (-not $DemoLaunch -and -not $DemoHermes) { Assert-RegionHasInk "sidebar footer" 14 655 164 52 15 }
    Write-Output "Hydra Windows tab $Tab rendered: $($image.Width)x$($image.Height), $((Get-Item $Screenshot).Length) bytes"
}
finally {
    $image.Dispose()
}
