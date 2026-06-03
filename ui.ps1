Add-Type -AssemblyName System.Windows.Forms,System.Drawing

# Cleanup leaked timers/jobs from prior UI runs in the same PowerShell session.
if ($global:CutVideoUiTimers) {
    foreach ($t in @($global:CutVideoUiTimers)) {
        try { $t.Stop() } catch { }
        try { $t.Dispose() } catch { }
    }
}
$global:CutVideoUiTimers = @()
Get-Job -Name 'Detection-*','Cutting-*' -ErrorAction SilentlyContinue | Remove-Job -Force -ErrorAction SilentlyContinue

$form = New-Object System.Windows.Forms.Form
$form.Text = 'Cut-video-at-image - Controller'    # plain ASCII title (avoid non-ASCII dashes
$form.Size = New-Object System.Drawing.Size(1120,720)
$form.StartPosition = 'CenterScreen'
$form.BackColor = [System.Drawing.Color]::FromArgb(26,26,26)
$form.ForeColor = [System.Drawing.Color]::Gainsboro
$form.Font = New-Object System.Drawing.Font('Segoe UI',9)

$panelTop = New-Object System.Windows.Forms.Panel -Property @{
    Location = New-Object System.Drawing.Point(0,0)
    Size = New-Object System.Drawing.Size(1120,46)
    BackColor = [System.Drawing.Color]::FromArgb(38,38,38)
}

# Buttons
$btnOpenReadme = New-Object System.Windows.Forms.Button -Property @{ Text='Open Readme'; Location = New-Object System.Drawing.Point(12,8); Size = New-Object System.Drawing.Size(110,30) }
$btnAutopilot = New-Object System.Windows.Forms.Button -Property @{ Text='Autopilot'; Location = New-Object System.Drawing.Point(142,8); Size = New-Object System.Drawing.Size(100,30) }
$btnDetect = New-Object System.Windows.Forms.Button -Property @{ Text='Run Detection'; Location = New-Object System.Drawing.Point(252,8); Size = New-Object System.Drawing.Size(120,30) }
$btnCut = New-Object System.Windows.Forms.Button -Property @{ Text='Run Cutting'; Location = New-Object System.Drawing.Point(380,8); Size = New-Object System.Drawing.Size(110,30) }
$btnConfig = New-Object System.Windows.Forms.Button -Property @{ Text='Edit config.json'; Location = New-Object System.Drawing.Point(520,8); Size = New-Object System.Drawing.Size(120,30) }
$btnOpenOut = New-Object System.Windows.Forms.Button -Property @{ Text='Open Outputs'; Location = New-Object System.Drawing.Point(648,8); Size = New-Object System.Drawing.Size(100,30) }
$btnOpenVideos = New-Object System.Windows.Forms.Button -Property @{ Text='Open Videos'; Location = New-Object System.Drawing.Point(754,8); Size = New-Object System.Drawing.Size(100,30) }
$btnOpenLogs = New-Object System.Windows.Forms.Button -Property @{ Text='Open Logs'; Location = New-Object System.Drawing.Point(860,8); Size = New-Object System.Drawing.Size(100,30) }
$lblStatus = New-Object System.Windows.Forms.Label -Property @{ Text='Idle'; Location = New-Object System.Drawing.Point(966,14); AutoSize=$true; ForeColor=[System.Drawing.Color]::Lime }
$lblProgress = New-Object System.Windows.Forms.Label -Property @{ Text='Progress: 0/0'; Location = New-Object System.Drawing.Point(12,50); AutoSize=$true; ForeColor=[System.Drawing.Color]::Silver }
$progressBar = New-Object System.Windows.Forms.ProgressBar -Property @{ Location = New-Object System.Drawing.Point(110,48); Size = New-Object System.Drawing.Size(992,16); Minimum = 0; Maximum = 100; Value = 0; Style = 'Continuous' }

# Log textbox
$txtLog = New-Object System.Windows.Forms.RichTextBox -Property @{
    ReadOnly = $true; ScrollBars = 'Both'
    Font = New-Object System.Drawing.Font('Consolas',9); Location = New-Object System.Drawing.Point(12,72)
    Size = New-Object System.Drawing.Size(1096,586); WordWrap = $false
    BackColor = [System.Drawing.Color]::Black
    ForeColor = [System.Drawing.Color]::Lime
    BorderStyle = 'FixedSingle'
}

$buttonBack = [System.Drawing.Color]::FromArgb(58,58,58)
$buttonFore = [System.Drawing.Color]::WhiteSmoke
foreach ($btn in @($btnDetect,$btnCut,$btnConfig,$btnOpenOut,$btnOpenVideos,$btnOpenLogs,$btnAutopilot,$btnOpenReadme)) {
    $btn.BackColor = $buttonBack
    $btn.ForeColor = $buttonFore
    $btn.FlatStyle = 'Flat'
    $btn.FlatAppearance.BorderColor = [System.Drawing.Color]::FromArgb(82,82,82)
}
$btnAutopilot.BackColor = [System.Drawing.Color]::FromArgb(38,78,92)
$btnAutopilot.ForeColor = [System.Drawing.Color]::WhiteSmoke
$btnAutopilot.FlatAppearance.BorderColor = [System.Drawing.Color]::FromArgb(72,132,152)

$panelTop.Controls.AddRange(@($btnOpenReadme,$btnAutopilot,$btnDetect,$btnCut,$btnConfig,$btnOpenOut,$btnOpenVideos,$btnOpenLogs,$lblStatus))
$form.Controls.AddRange(@($panelTop,$lblProgress,$progressBar,$txtLog))

$script:activeJob = $null
$script:activeTimer = $null
$script:activeLabel = ''
$script:activeLogPath = ''
$script:activeLogOffset = 0
$script:activeLogBase = ''
$script:activeElapsed = ''
$script:activeDuration = ''
$script:progressDone = 0
$script:progressTotal = 0
$script:autopilotEnabled = $false

function Set-UiState([bool]$isRunning, [string]$label) {
    if ($isRunning) {
        if ($label -eq 'Detection') {
            $btnDetect.Text = 'Stop Detection'
            $btnCut.Enabled = $false
        } elseif ($label -eq 'Cutting') {
            $btnCut.Text = 'Stop Cutting'
            $btnDetect.Enabled = $false
        }
    } else {
        $btnDetect.Text = 'Run Detection'
        $btnCut.Text = 'Run Cutting'
        $btnDetect.Enabled = $true
        $btnCut.Enabled = $true
    }
}

function Get-StatusAction([string]$label) {
    if ($label -eq 'Detection') { return 'Detecting' }
    if ($label -eq 'Cutting') { return 'Cutting' }
    return 'Running'
}

function Set-AutopilotState([bool]$enabled) {
    $script:autopilotEnabled = $enabled
    if ($enabled) {
        $btnAutopilot.Text = 'Stop Autopilot'
        $btnAutopilot.BackColor = [System.Drawing.Color]::FromArgb(118,54,54)
        $btnAutopilot.FlatAppearance.BorderColor = [System.Drawing.Color]::FromArgb(180,88,88)
        $btnAutopilot.ForeColor = [System.Drawing.Color]::WhiteSmoke
    } else {
        $btnAutopilot.Text = 'Autopilot'
        $btnAutopilot.BackColor = [System.Drawing.Color]::FromArgb(38,78,92)
        $btnAutopilot.FlatAppearance.BorderColor = [System.Drawing.Color]::FromArgb(72,132,152)
        $btnAutopilot.ForeColor = [System.Drawing.Color]::WhiteSmoke
    }
}

function Set-ProgressState([int]$done, [int]$total) {
    $safeTotal = if ($total -gt 0) { $total } else { 1 }
    $safeDone = [Math]::Min([Math]::Max($done, 0), $safeTotal)
    $script:progressDone = $safeDone
    $script:progressTotal = $total

    $percent = [Math]::Floor(($safeDone * 100.0) / $safeTotal)
    $progressBar.Value = [Math]::Min([Math]::Max([int]$percent, 0), 100)
    if (-not [string]::IsNullOrWhiteSpace($script:activeElapsed) -and -not [string]::IsNullOrWhiteSpace($script:activeDuration)) {
        $lblProgress.Text = "Progress: $safeDone/$total  |  $($script:activeElapsed)/$($script:activeDuration)"
    } else {
        $lblProgress.Text = "Progress: $safeDone/$total"
    }
}

function Set-StatusTiming([string]$elapsed, [string]$duration) {
    $script:activeElapsed = $elapsed
    $script:activeDuration = $duration
    Set-ProgressState -done $script:progressDone -total $script:progressTotal
}

function Reset-ActiveLogState {
    $script:activeLogPath = ''
    $script:activeLogOffset = 0
    $script:activeLogBase = ''
    $script:activeElapsed = ''
    $script:activeDuration = ''
}

function Set-ActiveLogBase([string]$baseName) {
    if ([string]::IsNullOrWhiteSpace($baseName)) { return }
    if ($script:activeLogBase -ne $baseName) {
        $script:activeLogBase = $baseName
        $script:activeLogOffset = 0
        if ($script:activeLabel -eq 'Detection') {
            $script:activeLogPath = Join-Path $PSScriptRoot "Logs\detect-$baseName.log"
        } elseif ($script:activeLabel -eq 'Cutting') {
            $script:activeLogPath = Join-Path $PSScriptRoot "Logs\cut-$baseName.log"
        }
        $lblProgress.Text = "File: $baseName"
    }
}

function Read-NewLogText([string]$path) {
    if ([string]::IsNullOrWhiteSpace($path) -or -not (Test-Path $path)) { return $null }
    try {
        $fs = [System.IO.File]::Open($path, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::ReadWrite)
        try {
            if ($script:activeLogOffset -gt $fs.Length) { $script:activeLogOffset = 0 }
            $fs.Seek($script:activeLogOffset, [System.IO.SeekOrigin]::Begin) | Out-Null
            $reader = New-Object System.IO.StreamReader($fs, [System.Text.Encoding]::UTF8, $true, 1024, $true)
            $text = $reader.ReadToEnd()
            $script:activeLogOffset = $fs.Position
            return $text
        } finally {
            $fs.Dispose()
        }
    } catch {
        return $null
    }
}

function Update-StatusFromLogLine([string]$line) {
    if ([string]::IsNullOrWhiteSpace($line)) { return }
    if ($line -match 'Duration:\s*(\d{2}:\d{2}:\d{2}(?:\.\d+)?)') {
        Set-StatusTiming -elapsed $script:activeElapsed -duration $matches[1]
    }
    if ($line -match 'time=(\d{2}:\d{2}:\d{2}(?:\.\d+)?)') {
        Set-StatusTiming -elapsed $matches[1] -duration $script:activeDuration
    }
}

function Initialize-Progress([string]$label) {
    $total = 0
    try {
        $configPath = Join-Path $PSScriptRoot 'config.json'
        $config = Get-Content $configPath -Raw | ConvertFrom-Json
        if ($label -eq 'Detection') {
            $videosFolder = Join-Path $PSScriptRoot $config.videosFolder
            $exts = @($config.inputExtensions)
            if (-not $exts -or $exts.Count -eq 0) { $exts = @('mp4','mkv','mov','avi') }
            $exts = $exts | ForEach-Object { $_.ToString().TrimStart('.').ToLower() } | Sort-Object -Unique
            $files = Get-ChildItem -Path $videosFolder -File -ErrorAction SilentlyContinue
            $total = @($files | Where-Object { $exts -contains ($_.Extension.TrimStart('.').ToLower()) }).Count
        } elseif ($label -eq 'Cutting') {
            $cutLogsFolder = Join-Path $PSScriptRoot $config.cutLogsFolder
            $total = @(Get-ChildItem -Path $cutLogsFolder -Filter '*_cuts.txt' -File -ErrorAction SilentlyContinue).Count
        }
    } catch {
        $total = 0
    }
    Set-ProgressState -done 0 -total $total
}

function Get-InputVideoCount {
    try {
        $config = Get-Content (Join-Path $PSScriptRoot 'config.json') -Raw | ConvertFrom-Json
        $videosFolder = Join-Path $PSScriptRoot $config.videosFolder
        $exts = @($config.inputExtensions)
        if (-not $exts -or $exts.Count -eq 0) { $exts = @('mp4','mkv','mov','avi') }
        $exts = $exts | ForEach-Object { $_.ToString().TrimStart('.').ToLower() } | Sort-Object -Unique
        $files = Get-ChildItem -Path $videosFolder -File -ErrorAction SilentlyContinue
        return @($files | Where-Object { $exts -contains ($_.Extension.TrimStart('.').ToLower()) }).Count
    } catch {
        return 0
    }
}

function Show-ReadmeInStatusWindow {
    $readmePath = Join-Path $PSScriptRoot 'README_UI.md'
    if (-not (Test-Path $readmePath)) {
        Append-Log 'README_UI.md not found.'
        return
    }

    try {
        $content = Get-Content $readmePath -Raw
        $txtLog.Clear()
        $txtLog.SelectionColor = [System.Drawing.Color]::Lime
        $txtLog.AppendText("README_UI.md`r`n")
        $txtLog.AppendText(("=" * 70) + "`r`n")
        $txtLog.AppendText($content)
        $txtLog.SelectionStart = $txtLog.TextLength
        $txtLog.ScrollToCaret()
        $lblStatus.Text = 'UI guide loaded'
    } catch {
        Append-Log ("Failed to load README_UI.md: {0}" -f $_.Exception.Message)
    }
}

function Update-ProgressFromLine([string]$line, [string]$label) {
    if ([string]::IsNullOrWhiteSpace($line)) { return }
    if ($label -eq 'Detection' -and $line -like 'Detection completed for *') {
        Set-ProgressState -done ($script:progressDone + 1) -total $script:progressTotal
    } elseif ($label -eq 'Cutting' -and $line -like 'Cutting completed for *') {
        Set-ProgressState -done ($script:progressDone + 1) -total $script:progressTotal
    }
}

function Reset-RunState([string]$status = 'Idle') {
    if ($script:activeTimer) {
        $script:activeTimer.Stop()
        $script:activeTimer.Dispose()
        $global:CutVideoUiTimers = @($global:CutVideoUiTimers | Where-Object { $_ -ne $script:activeTimer })
    }
    if ($script:activeJob) {
        Remove-Job -Job $script:activeJob -Force -ErrorAction SilentlyContinue
    }
    $script:activeTimer = $null
    $script:activeJob = $null
    $script:activeLabel = ''
    Reset-ActiveLogState
    $lblStatus.Text = $status
    Set-UiState -isRunning $false -label ''
    Set-ProgressState -done 0 -total $script:progressTotal
}

function Stop-ActiveJob([string]$reason = 'Stopped by user.') {
    if (-not $script:activeJob) { return }
    try {
        Stop-Job -Job $script:activeJob -ErrorAction SilentlyContinue
    } catch { }
    Append-Log $reason
    Set-AutopilotState $false
    Reset-RunState 'Idle'
}

function Append-Log([string]$text) {
    if (-not [string]::IsNullOrWhiteSpace($text)) {
        if ($text -like "UI monitor error:*Cannot bind argument to parameter 'Job' because it is null.*") {
            return
        }
        $isError = $text -match '(?i)(\berror\b|\bfailed\b|\bexception\b)'
        $txtLog.SelectionStart = $txtLog.TextLength
        $txtLog.SelectionLength = 0
        if ($isError) {
            $txtLog.SelectionColor = [System.Drawing.Color]::Tomato
            $lblStatus.Text = 'Error (see log)'
        } else {
            $txtLog.SelectionColor = [System.Drawing.Color]::Lime
        }
        $txtLog.AppendText($text + "`r`n")
        $txtLog.SelectionColor = [System.Drawing.Color]::Lime
        $txtLog.SelectionStart = $txtLog.Text.Length
        $txtLog.ScrollToCaret()
    }
}

function Start-ScriptJob($label, $scriptFile) {
    if (-not (Test-Path $scriptFile)) { [System.Windows.Forms.MessageBox]::Show("$scriptFile not found","Error") ; return }
    if ($script:activeJob -and $script:activeJob.State -eq 'Running') {
        [System.Windows.Forms.MessageBox]::Show('Another operation is already running. Wait until it finishes.','Busy')
        return
    }

    $scriptPath = (Resolve-Path $scriptFile).Path
    $scriptDir = Split-Path -Path $scriptPath -Parent

    $lblStatus.Text = "$($label): starting"
    Reset-ActiveLogState
    Initialize-Progress $label
    Append-Log ("")
    Append-Log (("=== {0} started at {1} ===" -f $label, (Get-Date)))

    $jobName = ("{0}-{1}" -f $label, (Get-Date).ToString('yyyyMMddHHmmss'))
    $job = Start-Job -Name $jobName -ArgumentList $scriptPath, $scriptDir -ScriptBlock {
        param($childScript, $childDir)
        Set-Location -LiteralPath $childDir
        $env:CUT_VIDEO_UI_MODE = '1'
        & $childScript *>&1
    }

    if (-not $job) {
        $lblStatus.Text = 'Idle'
        Append-Log ("Failed to start job for {0}." -f $label)
        return
    }

    $script:activeJob = $job
    $script:activeLabel = $label
    Set-UiState -isRunning $true -label $label

    $timer = New-Object System.Windows.Forms.Timer
    $timer.Interval = 700
    $timer.Add_Tick({
        try {
            $jobRef = $script:activeJob
            if ($null -eq $jobRef) {
                if ($timer.Enabled) { $timer.Stop() }
                return
            }

            if (-not (Get-Job -Id $jobRef.Id -ErrorAction SilentlyContinue)) {
                Reset-RunState 'Idle'
                return
            }

            $messages = @(& { Receive-Job -Job $jobRef -Keep *>&1 })
            foreach ($m in $messages) {
                if ($null -ne $m) {
                    $line = $m.ToString()
                    Append-Log $line
                    if ($line -match 'Detecting occurrences in .* using blend\+difference\+blackframe\.\.\.' -and $line -match 'Detecting occurrences in (.+?) using') {
                        Set-ActiveLogBase ([IO.Path]::GetFileNameWithoutExtension($matches[1]))
                    }
                    if ($line -match 'Creating segment .* from (.+?) \(start=') {
                        Set-ActiveLogBase ([IO.Path]::GetFileNameWithoutExtension($matches[1]))
                    }
                    Update-ProgressFromLine -line $line -label $label
                }
            }

            if (-not [string]::IsNullOrWhiteSpace($script:activeLogPath)) {
                $newText = Read-NewLogText $script:activeLogPath
                if (-not [string]::IsNullOrWhiteSpace($newText)) {
                    foreach ($line in ($newText -split "`r?`n")) {
                        if ([string]::IsNullOrWhiteSpace($line)) { continue }
                        Append-Log $line
                        Update-StatusFromLogLine $line
                    }
                }
            }

            if ($jobRef.State -ne 'Running') {
                $final = @(& { Receive-Job -Job $jobRef *>&1 })
                foreach ($line in $final) {
                    if ($null -ne $line) {
                        $text = $line.ToString()
                        Append-Log $text
                        Update-ProgressFromLine -line $text -label $label
                    }
                }

                if ($script:progressTotal -gt 0) {
                    Set-ProgressState -done $script:progressTotal -total $script:progressTotal
                }
                Append-Log (("=== {0} finished at {1} (state={2}) ===" -f $label, (Get-Date), $jobRef.State))
                Reset-RunState 'Idle'

                if ($label -eq 'Detection' -and $script:autopilotEnabled) {
                    Append-Log 'Autopilot: detection finished, starting cutting...'
                    Start-ScriptJob 'Cutting' (Join-Path $PSScriptRoot '2.Cut_Video.ps1')
                    return
                }

                if ($label -eq 'Cutting' -and $script:autopilotEnabled) {
                    Append-Log 'Autopilot: cutting finished.'
                    Set-AutopilotState $false
                }
            } else {
                $lblStatus.Text = "$(Get-StatusAction $label)"
            }
        } catch {
            if ($timer.Enabled) { $timer.Stop() }
            Append-Log (("UI monitor error: {0}" -f $_.Exception.Message))
            Reset-RunState 'Idle'
        }
    })
    $script:activeTimer = $timer
    $global:CutVideoUiTimers += $timer
    $timer.Start()
}

# Button events
$btnDetect.Add_Click({
    if ($script:activeJob -and $script:activeLabel -eq 'Detection') {
        Stop-ActiveJob 'Detection aborted by user.'
        return
    }
    $script = Join-Path $PSScriptRoot '1.Detect_Image.ps1'
    Start-ScriptJob 'Detection' $script
})
$btnCut.Add_Click({
    if ($script:activeJob -and $script:activeLabel -eq 'Cutting') {
        Stop-ActiveJob 'Cutting aborted by user.'
        return
    }
    $script = Join-Path $PSScriptRoot '2.Cut_Video.ps1'
    Start-ScriptJob 'Cutting' $script
})
$btnAutopilot.Add_Click({
    if ($script:activeJob) {
        if ($script:autopilotEnabled) {
            Stop-ActiveJob 'Autopilot aborted by user.'
        } else {
            [System.Windows.Forms.MessageBox]::Show('Wait for the current task to finish, or stop it from its own button first.','Busy')
        }
        return
    }

    if ((Get-InputVideoCount) -le 0) {
        Set-AutopilotState $false
        Append-Log 'Autopilot not started: no input videos found in Videos folder.'
        [System.Windows.Forms.MessageBox]::Show('No input videos found. Autopilot was not started.','Nothing to do')
        return
    }

    Set-AutopilotState $true
    Append-Log 'Autopilot started: running detection, then cutting automatically.'
    Start-ScriptJob 'Detection' (Join-Path $PSScriptRoot '1.Detect_Image.ps1')
})
$btnOpenReadme.Add_Click({
    Show-ReadmeInStatusWindow
})
$btnConfig.Add_Click({
    $cfg = Join-Path $PSScriptRoot 'config.json'
    if (-not (Test-Path $cfg)) { New-Item -Path $cfg -ItemType File -Force | Out-Null }
    Start-Process notepad.exe $cfg
})
$btnOpenOut.Add_Click({
    $dir = Join-Path $PSScriptRoot ( (Get-Content (Join-Path $PSScriptRoot 'config.json') -Raw | ConvertFrom-Json).outputsFolder )
    if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
    Start-Process explorer.exe $dir
})
$btnOpenVideos.Add_Click({
    $dir = Join-Path $PSScriptRoot ( (Get-Content (Join-Path $PSScriptRoot 'config.json') -Raw | ConvertFrom-Json).videosFolder )
    if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
    Start-Process explorer.exe $dir
})
$btnOpenLogs.Add_Click({
    $dir = Join-Path $PSScriptRoot ( (Get-Content (Join-Path $PSScriptRoot 'config.json') -Raw | ConvertFrom-Json).logsFolder )
    if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
    Start-Process explorer.exe $dir
})

# Close on Esc
$form.KeyPreview = $true
$form.Add_KeyDown({ if ($_.KeyCode -eq 'Escape') { $form.Close() } })
$form.Add_FormClosing({
    if ($script:activeJob) {
        Stop-ActiveJob 'UI closing: active task stopped.'
    }
})

Show-ReadmeInStatusWindow
[void]$form.ShowDialog()
