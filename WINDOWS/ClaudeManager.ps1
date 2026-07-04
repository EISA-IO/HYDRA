#requires -version 5.1
# Claude Manager - pick any folder + model, launch a Claude CLI terminal there.
#   Model:         --model <alias|full-id>   (opus / sonnet / haiku / custom)
#   Defaults:      RTK (input) + Caveman (output) compression are global, so they apply
#                  to every session automatically. Headroom is OPTIONAL and off by default
#                  (it overlaps RTK on shell output); tick the box only if you want it.
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

$ErrorActionPreference = 'Stop'
$ProxyPort = 8787

# ---- persistence ----
$StateDir     = Join-Path $env:USERPROFILE '.claude-manager'
$RecentFile   = Join-Path $StateDir 'recent.txt'
$SettingsFile = Join-Path $StateDir 'settings.json'
if (-not (Test-Path $StateDir)) { New-Item -ItemType Directory -Path $StateDir | Out-Null }

function Get-Recent {
    if (Test-Path $RecentFile) {
        Get-Content $RecentFile | Where-Object { $_ -and (Test-Path $_) } | Select-Object -Unique
    }
}
function Save-Recent([string]$path) {
    $list = @($path) + @(Get-Recent | Where-Object { $_ -ne $path })
    $list | Select-Object -First 15 | Set-Content $RecentFile
}
function Load-Settings {
    if (Test-Path $SettingsFile) { try { Get-Content $SettingsFile -Raw | ConvertFrom-Json } catch { $null } }
}
function Save-Settings([string]$model, [bool]$hr) {
    [pscustomobject]@{ model = $model; headroom = $hr } | ConvertTo-Json | Set-Content $SettingsFile
}

# ---- Headroom proxy helpers ----
function Test-Port([int]$p) {
    try { $c = New-Object Net.Sockets.TcpClient; $c.Connect('127.0.0.1', $p); $c.Close(); $true }
    catch { $false }
}
function Ensure-HeadroomProxy {
    if (Test-Port $ProxyPort) { return $true }
    $hr = Get-Command headroom -ErrorAction SilentlyContinue
    if (-not $hr) {
        [System.Windows.Forms.MessageBox]::Show(
            "Headroom is not installed / not on PATH.`n`nInstall it, or uncheck 'Route through Headroom' to launch plain Claude.",
            'Claude Manager','OK','Warning') | Out-Null
        return $false
    }
    Start-Process $hr.Source -ArgumentList 'proxy' -WindowStyle Minimized | Out-Null
    for ($i = 0; $i -lt 20; $i++) {
        Start-Sleep -Milliseconds 500
        if (Test-Port $ProxyPort) { return $true }
    }
    [System.Windows.Forms.MessageBox]::Show(
        "Started 'headroom proxy' but port $ProxyPort did not come up in time.`nGive it a moment, then try again.",
        'Claude Manager','OK','Warning') | Out-Null
    return $false
}

# ---- launch a Claude terminal ----
function Start-Claude([string]$folder, [string]$model, [bool]$useHeadroom) {
    if (-not (Test-Path $folder)) {
        [System.Windows.Forms.MessageBox]::Show("Folder not found:`n$folder",'Claude Manager','OK','Warning') | Out-Null
        return
    }
    $envset = ''
    if ($useHeadroom) {
        if (-not (Ensure-HeadroomProxy)) { return }
        $envset = "set `"ANTHROPIC_BASE_URL=http://127.0.0.1:$ProxyPort`" && "
    }
    $cmd = 'claude'
    $model = ($model).Trim()
    if ($model -and $model -ne 'Default') { $cmd += " --model $model" }
    $cmd += ' --dangerously-skip-permissions'

    $full = "cd /d `"$folder`" && $envset$cmd"
    if (Get-Command wt -ErrorAction SilentlyContinue) {
        Start-Process wt.exe -ArgumentList @('-d', $folder, 'cmd', '/k', "$envset$cmd")
    } else {
        Start-Process cmd.exe -ArgumentList @('/k', $full)
    }
    Save-Recent $folder
    Save-Settings $model $useHeadroom
    Refresh-Recent
    Update-ProxyStatus
}

# ---- UI ----
$form               = New-Object System.Windows.Forms.Form
$form.Text          = 'Claude Manager'
$form.Size          = New-Object System.Drawing.Size(560, 560)
$form.StartPosition = 'CenterScreen'
$form.MinimumSize   = New-Object System.Drawing.Size(480, 500)
$form.BackColor     = [System.Drawing.Color]::FromArgb(24,24,27)
$form.ForeColor     = [System.Drawing.Color]::White
$form.Font          = New-Object System.Drawing.Font('Segoe UI', 10)

$title            = New-Object System.Windows.Forms.Label
$title.Text       = 'Claude Manager'
$title.Font       = New-Object System.Drawing.Font('Segoe UI', 15, [System.Drawing.FontStyle]::Bold)
$title.AutoSize   = $true
$title.Location   = New-Object System.Drawing.Point(18, 14)
$form.Controls.Add($title)

$subtitle          = New-Object System.Windows.Forms.Label
$subtitle.Text     = 'Pick a folder + model and start Claude. RTK + Caveman compression are on by default.'
$subtitle.AutoSize = $true
$subtitle.ForeColor= [System.Drawing.Color]::FromArgb(160,160,170)
$subtitle.Location = New-Object System.Drawing.Point(20, 46)
$form.Controls.Add($subtitle)

# folder row
$pathBox            = New-Object System.Windows.Forms.TextBox
$pathBox.Location   = New-Object System.Drawing.Point(20, 76)
$pathBox.Size       = New-Object System.Drawing.Size(400, 26)
$pathBox.Anchor     = 'Top,Left,Right'
$pathBox.BackColor  = [System.Drawing.Color]::FromArgb(39,39,42)
$pathBox.ForeColor  = [System.Drawing.Color]::White
$pathBox.Text       = [System.Environment]::GetFolderPath('UserProfile')
$form.Controls.Add($pathBox)

$browseBtn          = New-Object System.Windows.Forms.Button
$browseBtn.Text     = 'Browse...'
$browseBtn.Location = New-Object System.Drawing.Point(430, 75)
$browseBtn.Size     = New-Object System.Drawing.Size(96, 28)
$browseBtn.Anchor   = 'Top,Right'
$browseBtn.FlatStyle= 'Flat'
$browseBtn.BackColor= [System.Drawing.Color]::FromArgb(63,63,70)
$form.Controls.Add($browseBtn)

# model row
$modelLbl          = New-Object System.Windows.Forms.Label
$modelLbl.Text     = 'Model:'
$modelLbl.AutoSize = $true
$modelLbl.Location = New-Object System.Drawing.Point(20, 118)
$form.Controls.Add($modelLbl)

$modelCombo            = New-Object System.Windows.Forms.ComboBox
$modelCombo.Location   = New-Object System.Drawing.Point(78, 114)
$modelCombo.Size       = New-Object System.Drawing.Size(448, 26)
$modelCombo.Anchor     = 'Top,Left,Right'
$modelCombo.DropDownStyle = 'DropDown'   # editable: type a custom model id too
$modelCombo.BackColor  = [System.Drawing.Color]::FromArgb(39,39,42)
$modelCombo.ForeColor  = [System.Drawing.Color]::White
[void]$modelCombo.Items.AddRange(@('Default','opus','sonnet','haiku','claude-opus-4-8','claude-sonnet-4-6','claude-haiku-4-5'))
$modelCombo.Text = 'Default'
$form.Controls.Add($modelCombo)

$modelHint          = New-Object System.Windows.Forms.Label
$modelHint.Text     = 'Alias (opus/sonnet/haiku), a full model id, or Default. Editable.'
$modelHint.AutoSize = $true
$modelHint.ForeColor= [System.Drawing.Color]::FromArgb(140,140,150)
$modelHint.Location = New-Object System.Drawing.Point(78, 144)
$form.Controls.Add($modelHint)

# headroom
$hrCheck            = New-Object System.Windows.Forms.CheckBox
$hrCheck.Text       = 'Also route through Headroom (optional - RTK already covers input)'
$hrCheck.Checked    = $false
$hrCheck.AutoSize   = $true
$hrCheck.Location   = New-Object System.Drawing.Point(20, 176)
$form.Controls.Add($hrCheck)

$hrStatus           = New-Object System.Windows.Forms.Label
$hrStatus.AutoSize  = $true
$hrStatus.Location  = New-Object System.Drawing.Point(20, 202)
$form.Controls.Add($hrStatus)

# launch
$launchBtn          = New-Object System.Windows.Forms.Button
$launchBtn.Text     = 'Launch Claude'
$launchBtn.Location = New-Object System.Drawing.Point(20, 228)
$launchBtn.Size     = New-Object System.Drawing.Size(506, 44)
$launchBtn.Anchor   = 'Top,Left,Right'
$launchBtn.FlatStyle= 'Flat'
$launchBtn.BackColor= [System.Drawing.Color]::FromArgb(217,119,87)
$launchBtn.ForeColor= [System.Drawing.Color]::Black
$launchBtn.Font     = New-Object System.Drawing.Font('Segoe UI', 11, [System.Drawing.FontStyle]::Bold)
$form.Controls.Add($launchBtn)

# recents
$recentLbl          = New-Object System.Windows.Forms.Label
$recentLbl.Text     = 'Recent folders (double-click to launch):'
$recentLbl.AutoSize = $true
$recentLbl.Location = New-Object System.Drawing.Point(20, 286)
$recentLbl.ForeColor= [System.Drawing.Color]::FromArgb(160,160,170)
$form.Controls.Add($recentLbl)

$recentList         = New-Object System.Windows.Forms.ListBox
$recentList.Location= New-Object System.Drawing.Point(20, 312)
$recentList.Size    = New-Object System.Drawing.Size(506, 188)
$recentList.Anchor  = 'Top,Left,Right,Bottom'
$recentList.BackColor= [System.Drawing.Color]::FromArgb(39,39,42)
$recentList.ForeColor= [System.Drawing.Color]::White
$recentList.BorderStyle = 'FixedSingle'
$form.Controls.Add($recentList)

function Refresh-Recent {
    $recentList.Items.Clear()
    foreach ($r in Get-Recent) { [void]$recentList.Items.Add($r) }
}
function Update-ProxyStatus {
    if (Test-Port $ProxyPort) {
        $hrStatus.Text = "Headroom proxy: RUNNING on 127.0.0.1:$ProxyPort"
        $hrStatus.ForeColor = [System.Drawing.Color]::FromArgb(120,200,120)
    } else {
        $hrStatus.Text = "Headroom proxy: not running (will auto-start on launch)"
        $hrStatus.ForeColor = [System.Drawing.Color]::FromArgb(200,180,110)
    }
}
function Update-LaunchText {
    $m = $modelCombo.Text.Trim(); if (-not $m) { $m = 'Default' }
    $suffix = if ($hrCheck.Checked) { ' + Headroom' } else { '' }
    $launchBtn.Text = "Launch Claude ($m)$suffix"
}

# apply saved settings
$cfg = Load-Settings
if ($cfg) {
    if ($cfg.model)   { $modelCombo.Text = [string]$cfg.model }
    if ($null -ne $cfg.headroom) { $hrCheck.Checked = [bool]$cfg.headroom }
}
Refresh-Recent
Update-ProxyStatus
Update-LaunchText

# ---- events ----
$browseBtn.Add_Click({
    $dlg = New-Object System.Windows.Forms.FolderBrowserDialog
    $dlg.Description = 'Pick a folder to launch Claude in'
    $dlg.ShowNewFolderButton = $true
    if (Test-Path $pathBox.Text) { $dlg.SelectedPath = $pathBox.Text }
    if ($dlg.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK) { $pathBox.Text = $dlg.SelectedPath }
})
$launchBtn.Add_Click({ Start-Claude $pathBox.Text $modelCombo.Text $hrCheck.Checked })
$recentList.Add_DoubleClick({
    if ($recentList.SelectedItem) { Start-Claude ([string]$recentList.SelectedItem) $modelCombo.Text $hrCheck.Checked }
})
$recentList.Add_SelectedIndexChanged({
    if ($recentList.SelectedItem) { $pathBox.Text = [string]$recentList.SelectedItem }
})
$hrCheck.Add_CheckedChanged({ Update-LaunchText })
$modelCombo.Add_TextChanged({ Update-LaunchText })

[void]$form.ShowDialog()
