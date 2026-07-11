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
$btnClean = New-Object System.Windows.Forms.Button -Property @{ Text='Clean'; Location = New-Object System.Drawing.Point(968,8); Size = New-Object System.Drawing.Size(100,30) }
$lblStatus = New-Object System.Windows.Forms.Label -Property @{ Text='Idle'; Location = New-Object System.Drawing.Point(12,14); Size = New-Object System.Drawing.Size(240,16); AutoSize=$false; ForeColor=[System.Drawing.Color]::Lime }
$lblProgress = New-Object System.Windows.Forms.Label -Property @{ Text='Progress: 0/0'; Location = New-Object System.Drawing.Point(12,72); Size = New-Object System.Drawing.Size(340,16); AutoSize=$false; ForeColor=[System.Drawing.Color]::Silver }
$progressBar = New-Object System.Windows.Forms.ProgressBar -Property @{ Location = New-Object System.Drawing.Point(360,72); Size = New-Object System.Drawing.Size(708,16); Minimum = 0; Maximum = 100; Value = 0; Style = 'Continuous' }
$progressBar.Anchor = [System.Windows.Forms.AnchorStyles]::Top -bor [System.Windows.Forms.AnchorStyles]::Left -bor [System.Windows.Forms.AnchorStyles]::Right

# Log textbox
$txtLog = New-Object System.Windows.Forms.RichTextBox -Property @{
    ReadOnly = $true; ScrollBars = 'Both'
    Font = New-Object System.Drawing.Font('Consolas',9); Location = New-Object System.Drawing.Point(12,92)
    Size = New-Object System.Drawing.Size(1096,608); WordWrap = $false
    BackColor = [System.Drawing.Color]::Black
    ForeColor = [System.Drawing.Color]::Lime
    BorderStyle = 'FixedSingle'
}

$buttonBack = [System.Drawing.Color]::FromArgb(58,58,58)
$buttonFore = [System.Drawing.Color]::WhiteSmoke
foreach ($btn in @($btnDetect,$btnCut,$btnConfig,$btnOpenOut,$btnOpenVideos,$btnOpenLogs,$btnClean,$btnAutopilot,$btnOpenReadme)) {
    $btn.BackColor = $buttonBack
    $btn.ForeColor = $buttonFore
    $btn.FlatStyle = 'Flat'
    $btn.FlatAppearance.BorderColor = [System.Drawing.Color]::FromArgb(82,82,82)
}
$btnAutopilot.BackColor = [System.Drawing.Color]::FromArgb(38,78,92)
$btnAutopilot.ForeColor = [System.Drawing.Color]::WhiteSmoke
$btnAutopilot.FlatAppearance.BorderColor = [System.Drawing.Color]::FromArgb(72,132,152)

$panelTop.Controls.AddRange(@($btnOpenReadme,$btnAutopilot,$btnDetect,$btnCut,$btnConfig,$btnOpenOut,$btnOpenVideos,$btnOpenLogs,$btnClean,$lblStatus))
$form.Controls.AddRange(@($panelTop,$lblProgress,$progressBar,$txtLog))

$script:activeJob = $null
$script:activeTimer = $null
$script:activeLabel = ''
$script:activeLogPath = ''
$script:activeLogOffset = 0
$script:activeLogBase = ''
$script:activeElapsed = 0.0
$script:activeElapsedText = ''
$script:activeDuration = 0.0
$script:activeElapsedText = ''
$script:activeDuration = 0.0
$script:activeDurationText = ''
$script:progressDone = 0
$script:progressTotal = 0
$script:autopilotEnabled = $false
$script:completedDetectionVideos = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
$script:lastAppendedDetectLine = ''
$script:currentVideoIndex = 0
$script:currentVideoFrame = 0
$script:currentVideoTotalFrames = 0
$script:currentVideoBase = ''
$script:currentVideoDuration = 0.0
$script:currentVideoFps = 0.0
$script:activeCutIndex = 0
$script:activeCutTotal = 0
$script:activeCutDuration = 0.0
$script:activeCutDurationText = ''
$script:activeCutBase = ''
$script:activeCutStart = ''
$script:uiRootPath = $null

function Get-UiRootPath() {
    if ($script:uiRootPath) { return $script:uiRootPath }

    $candidate = $null
    try { if ($PSScriptRoot) { $candidate = $PSScriptRoot } } catch {}
    if (-not $candidate) {
        try { if ($PSCommandPath) { $candidate = Split-Path -Parent $PSCommandPath } } catch {}
    }
    if (-not $candidate) {
        try { if ($MyInvocation.MyCommand.Path) { $candidate = Split-Path -Parent $MyInvocation.MyCommand.Path } } catch {}
    }
    if (-not $candidate) {
        try { $candidate = (Get-Location).Path } catch {}
    }

    if ($candidate) { $script:uiRootPath = $candidate }
    return $candidate
}

function Set-UiState([bool]$isRunning, [string]$label) {
    if ($isRunning) {
        # Keep autopilot interactive only when autopilot itself is active.
        $btnAutopilot.Enabled = $script:autopilotEnabled
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
        $btnAutopilot.Enabled = $true
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

    $displayIndex = if ($script:progressDone -lt $safeTotal) {
        $script:progressDone + 1
    } else {
        $safeTotal
    }

    $progressText = "Video $displayIndex/$total"
    $videoFraction = 0.0
    $useMarquee = $false
    $showTime = ($script:activeDuration -gt 0.0) -or ($script:activeElapsed -gt 0.0) -or -not [string]::IsNullOrWhiteSpace($script:activeDurationText)

    if ($showTime) {
        $timeText = if (-not [string]::IsNullOrWhiteSpace($script:activeElapsedText)) { $script:activeElapsedText } else { "00:00:00" }
        if ($script:activeDuration -gt 0.0 -and -not [string]::IsNullOrWhiteSpace($script:activeDurationText)) {
            $durationText = $script:activeDurationText
            $progressText += "  |  time: $timeText/$durationText"
            if ($script:activeDuration -gt 0.0) {
                $videoFraction = [Math]::Min(1.0, $script:activeElapsed / $script:activeDuration)
            }
        } elseif ($script:activeDuration -gt 0.0) {
            $durationText = ([TimeSpan]::FromSeconds($script:activeDuration)).ToString('hh\:mm\:ss')
            $progressText += "  |  time: $timeText/$durationText"
            $videoFraction = [Math]::Min(1.0, $script:activeElapsed / $script:activeDuration)
        } else {
            $progressText += "  |  time: $timeText"
            $useMarquee = $true
        }

        if ($script:activeLabel -eq 'Cutting' -and $script:activeCutTotal -gt 0) {
            $currentCut = if ($script:activeCutIndex -gt 0) { $script:activeCutIndex } else { 1 }
            $progressText += "  |  Cuts: $currentCut/$($script:activeCutTotal)"
        }
    }

    if ($useMarquee) {
        $progressBar.Style = [System.Windows.Forms.ProgressBarStyle]::Marquee
        $progressBar.MarqueeAnimationSpeed = 30
    } else {
        $progressBar.Style = [System.Windows.Forms.ProgressBarStyle]::Continuous
        $percent = [Math]::Floor($videoFraction * 100.0)
        $progressBar.Value = [Math]::Min([Math]::Max([int]$percent, 0), 100)
    }

    $lblProgress.Text = $progressText
}

function Resolve-VideoPath([string]$videoPath) {
    if ([string]::IsNullOrWhiteSpace($videoPath)) { return $null }
    if ([IO.Path]::IsPathRooted($videoPath)) {
        if (Test-Path $videoPath) { return (Resolve-Path $videoPath).Path }
        return $null
    }

    $candidates = @($videoPath)
    try {
        $config = Get-Content (Join-Path $PSScriptRoot 'config.json') -Raw | ConvertFrom-Json
        if ($config -and $config.videosFolder) {
            $candidates += (Join-Path $PSScriptRoot $config.videosFolder)
            $candidates += (Join-Path (Join-Path $PSScriptRoot $config.videosFolder) $videoPath)
        }
    } catch {
        $candidates += (Join-Path $PSScriptRoot 'Videos')
    }
    $candidates += (Join-Path $PSScriptRoot $videoPath)
    $candidates += (Join-Path $PSScriptRoot ("Videos\{0}" -f $videoPath))

    foreach ($candidate in $candidates) {
        if ([string]::IsNullOrWhiteSpace($candidate)) { continue }
        if (Test-Path $candidate) {
            try { return (Resolve-Path $candidate).Path } catch { return $candidate }
        }
    }

    return $null
}

function Set-CurrentVideoProgress([string]$videoPath) {
    $script:currentVideoFrame = 0
    $script:currentVideoTotalFrames = 0
    $script:currentVideoBase = ''

    if ([string]::IsNullOrWhiteSpace($videoPath)) { return }

    $resolvedVideoPath = Resolve-VideoPath $videoPath
    if (-not $resolvedVideoPath) { return }

    $normalizedResolved = ([IO.Path]::GetFullPath($resolvedVideoPath)).TrimEnd([IO.Path]::DirectorySeparatorChar, [IO.Path]::AltDirectorySeparatorChar)
    $normalizedCurrent = if ([string]::IsNullOrWhiteSpace($script:currentVideoBase)) { '' } else { ([IO.Path]::GetFullPath($script:currentVideoBase)).TrimEnd([IO.Path]::DirectorySeparatorChar, [IO.Path]::AltDirectorySeparatorChar) }

    if (-not [string]::Equals($normalizedCurrent, $normalizedResolved, [System.StringComparison]::OrdinalIgnoreCase)) {
        if ($script:currentVideoIndex -eq 0) {
            $script:currentVideoIndex = 1
        } else {
            $script:currentVideoIndex += 1
        }
        $script:currentVideoBase = $normalizedResolved
    }

    $ffprobePath = $null
    $candidate = Join-Path $PSScriptRoot 'ffprobe.exe'
    if (Test-Path $candidate) {
        $ffprobePath = (Resolve-Path $candidate).Path
    }
    if (-not $ffprobePath) {
        try { $ffprobePath = (Get-Command 'ffprobe.exe' -ErrorAction SilentlyContinue).Path } catch { $ffprobePath = $null }
    }
    if (-not $ffprobePath) { return }

    # Try to get duration from ffprobe and populate active duration for the UI immediately.
    try {
        $dur = Get-VideoDuration $videoPath
        if ($dur -gt 0.0) {
            $script:activeDuration = [double]$dur
            $script:activeDurationText = ([TimeSpan]::FromSeconds($dur)).ToString('hh\:mm\:ss')
        }
    } catch {}

    try {
        $nbFrames = & $ffprobePath -v error -select_streams v:0 -show_entries stream=nb_frames -of default=nw=1:nk=1 $resolvedVideoPath 2>$null
        if ($LASTEXITCODE -eq 0 -and -not [string]::IsNullOrWhiteSpace($nbFrames)) {
            $nbFrames = $nbFrames.Trim()
            if ($nbFrames -match '^(\d+)$') {
                $script:currentVideoTotalFrames = [int]$matches[1]
                return
            }
        }

        $duration = & $ffprobePath -v error -select_streams v:0 -show_entries stream=duration -of default=nw=1:nk=1 $resolvedVideoPath 2>$null
        $fps = & $ffprobePath -v error -select_streams v:0 -show_entries stream=r_frame_rate -of default=nw=1:nk=1 $resolvedVideoPath 2>$null
        if ($LASTEXITCODE -eq 0) {
            $durationText = ($duration | Select-Object -First 1).ToString().Trim()
            $fpsText = ($fps | Select-Object -First 1).ToString().Trim()
            if ($durationText -match '^[0-9.]+$' -and $fpsText -match '^(\d+)(?:/(\d+))?$') {
                $fpsValue = if ($matches[2]) { [double]$matches[1] / [double]$matches[2] } else { [double]$matches[1] }
                $script:currentVideoTotalFrames = [int][Math]::Ceiling([double]$durationText * $fpsValue)
                return
            }
        }
    } catch {
        $script:currentVideoTotalFrames = 0
    }
}

function Update-FrameProgressFromLine([string]$line, [string]$label) {
    if ($label -ne 'Detection' -or [string]::IsNullOrWhiteSpace($line)) { return }
    $frameMatches = [regex]::Matches($line, '(?i)frame\s*(?:=|:)\s*(\d+)')
    if ($frameMatches.Count -gt 0) {
        $frameValue = [int]$frameMatches[$frameMatches.Count - 1].Groups[1].Value
        $script:currentVideoFrame = $frameValue
        Set-ProgressState -done $script:progressDone -total $script:progressTotal
    }
}

function Update-ProgressFromLogFile([string]$label) {
    if ([string]::IsNullOrWhiteSpace($script:activeLogPath) -or -not (Test-Path $script:activeLogPath)) { return }
    try {
        $lines = Get-Content -Path $script:activeLogPath -Tail 200 -ErrorAction SilentlyContinue
        for ($i = $lines.Count - 1; $i -ge 0; $i--) {
            $line = $lines[$i]
            if ([string]::IsNullOrWhiteSpace($line)) { continue }
            if ($line -match '(?i)time=\d{2}:\d{2}:\d{2}(?:\.\d+)?' -or $line -match '(?i)Duration:\s*\d{2}:\d{2}:\d{2}(?:\.\d+)?') {
                Update-StatusFromLogLine -line $line -label $label
                Update-ProgressFromLine -line $line -label $label
                return
            }
            if ($label -eq 'Detection' -and $line -match 'Detecting occurrences in (.+?) using') {
                $videoPath = $matches[1]
                Set-ActiveLogBase ([IO.Path]::GetFileNameWithoutExtension($videoPath))
                Set-CurrentVideoProgress -videoPath $videoPath
                return
            }
        }
    } catch {
        # ignore file-read issues
    }
}

function Convert-TimecodeToSeconds([string]$timecode) {
    if ([string]::IsNullOrWhiteSpace($timecode)) { return 0.0 }
    $timecode = $timecode.Trim()
    if ($timecode -match '^[0-9]+(?:\.[0-9]+)?$') {
        return [double]$timecode
    }
    $parts = $timecode.Split(':')
    if ($parts.Count -ne 3) { return 0.0 }
    $hours = [double]$parts[0]
    $minutes = [double]$parts[1]
    $seconds = [double]$parts[2]
    return ($hours * 3600.0) + ($minutes * 60.0) + $seconds
}

function TrySetCurrentVideoTotalFramesFromMetadata() {
    if ($script:currentVideoTotalFrames -gt 0) { return }
    if ($script:currentVideoDuration -gt 0.0 -and $script:currentVideoFps -gt 0.0) {
        $script:currentVideoTotalFrames = [int][Math]::Ceiling($script:currentVideoDuration * $script:currentVideoFps)
    }
}

function Set-StatusTiming([string]$elapsed, $duration) {
    if (-not [string]::IsNullOrWhiteSpace($elapsed)) {
        $script:activeElapsedText = $elapsed.Trim()
        $script:activeElapsed = [double](Convert-TimecodeToSeconds $elapsed)
    }
    if ($null -ne $duration) {
        if ($duration -is [string]) {
            $durationText = $duration.Trim()
            if (-not [string]::IsNullOrWhiteSpace($durationText)) {
                if ($durationText -match '^[0-9]+(?:\.[0-9]+)?$') {
                    $script:activeDuration = [double]$durationText
                } else {
                    $script:activeDurationText = $durationText
                    $script:activeDuration = [double](Convert-TimecodeToSeconds $durationText)
                }
            }
        } else {
            $script:activeDuration = [double]$duration
        }
    }
    Set-ProgressState -done $script:progressDone -total $script:progressTotal
}

function Reset-ActiveLogState {
    $script:activeLogPath = ''
    $script:activeLogOffset = 0
    $script:activeLogBase = ''
    $script:activeElapsed = 0.0
    $script:activeElapsedText = ''
    $script:activeDuration = 0.0
    $script:activeDurationText = ''
    $script:currentVideoDuration = 0.0
    $script:currentVideoFps = 0.0
    $script:activeCutIndex = 0
    $script:activeCutTotal = 0
    $script:activeCutDuration = 0.0
    $script:activeCutDurationText = ''
    $script:activeCutBase = ''
    $script:activeCutStart = ''
}

function Update-InitialDurationFromLog() {
    if ([string]::IsNullOrWhiteSpace($script:activeLogPath) -or -not (Test-Path $script:activeLogPath)) { return }
    try {
        $lines = Get-Content -Path $script:activeLogPath -First 200 -ErrorAction SilentlyContinue
        foreach ($line in $lines) {
            if ([string]::IsNullOrWhiteSpace($line)) { continue }
            if ($line -match '(?i)Duration:\s*(\d{2}:\d{2}:\d{2}(?:\.\d+)?)') {
                $duration = $matches[1].Trim()
                if (-not [string]::IsNullOrWhiteSpace($duration)) {
                    $script:activeDurationText = $duration
                    $script:activeDuration = [double](Convert-TimecodeToSeconds $duration)
                    return
                }
            }
        }
    } catch {
        # ignore file-read issues
    }
}

function Get-CutTimestamps([string]$baseName) {
    if ([string]::IsNullOrWhiteSpace($baseName)) { return @() }
    try {
        $config = Get-Content (Join-Path $PSScriptRoot 'config.json') -Raw | ConvertFrom-Json
        $cutLogsFolder = Join-Path $PSScriptRoot $config.cutLogsFolder
        $cutFile = Join-Path $cutLogsFolder ("${baseName}_cuts.txt")
        if (-not (Test-Path $cutFile)) { return @() }
        return @(Get-Content $cutFile -ErrorAction SilentlyContinue | ForEach-Object { $_.ToString().Trim() } | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
    } catch {
        return @()
    }
}

function Get-VideoDuration([string]$videoName) {
    if ([string]::IsNullOrWhiteSpace($videoName)) { return 0.0 }
    try {
        $videoPath = Resolve-VideoPath $videoName
        if (-not $videoPath) { return 0.0 }
        $ffprobePath = $null
        $candidate = Join-Path $PSScriptRoot 'ffprobe.exe'
        if (Test-Path $candidate) { $ffprobePath = (Resolve-Path $candidate).Path }
        if (-not $ffprobePath) {
            try { $ffprobePath = (Get-Command 'ffprobe.exe' -ErrorAction SilentlyContinue).Path } catch { $ffprobePath = $null }
        }
        if (-not $ffprobePath) { return 0.0 }
        $duration = & $ffprobePath -v error -select_streams v:0 -show_entries format=duration -of default=nw=1:nk=1 $videoPath 2>$null
        if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($duration)) { return 0.0 }
        return [double]([string]$duration).Trim()
    } catch {
        return 0.0
    }
}

function Set-ActiveCutSegment([string]$baseName, [string]$startTime, [string]$videoName) {
    if ([string]::IsNullOrWhiteSpace($baseName) -or [string]::IsNullOrWhiteSpace($startTime)) { return }
    $timestamps = Get-CutTimestamps $baseName
    if ($timestamps.Count -le 1) { return }
    $startIndex = $timestamps.IndexOf($startTime)
    if ($startIndex -lt 0) { return }

    $segmentCount = $timestamps.Count - 1
    $script:activeCutIndex = $startIndex + 1
    $script:activeCutTotal = $segmentCount
    $script:activeCutBase = $baseName
    $script:activeCutStart = $startTime

    if ($startIndex -lt ($timestamps.Count - 1)) {
        $startSeconds = Convert-TimecodeToSeconds $startTime
        $endSeconds = Convert-TimecodeToSeconds $timestamps[$startIndex + 1]
        $durationSeconds = [Math]::Max(0.0, $endSeconds - $startSeconds)
    } else {
        $durationSeconds = Get-VideoDuration $videoName
        if ($durationSeconds -le 0.0) {
            $durationSeconds = 0.0
        }
        $endSeconds = $durationSeconds
        $durationSeconds = [Math]::Max(0.0, $durationSeconds - (Convert-TimecodeToSeconds $startTime))
    }

    $script:activeCutDuration = $durationSeconds
    $script:activeCutDurationText = ([TimeSpan]::FromSeconds($durationSeconds)).ToString('hh\:mm\:ss')
    $script:activeDuration = $script:activeCutDuration
    $script:activeDurationText = $script:activeCutDurationText
}

function Set-ActiveLogBase([string]$baseName) {
    if ([string]::IsNullOrWhiteSpace($baseName)) { return }
    if ($script:activeLogBase -ne $baseName) {
        $script:activeLogBase = $baseName
        $script:activeLogOffset = 0
        # Reset timing/duration state when switching to a new active log so stale values don't persist.
        $script:activeElapsed = 0.0
        $script:activeElapsedText = ''
        $script:activeDuration = 0.0
        $script:activeDurationText = ''
        if ($script:activeLabel -eq 'Detection') {
            $script:activeLogPath = Join-Path $PSScriptRoot "Logs\detect-$baseName.log"
        } elseif ($script:activeLabel -eq 'Cutting') {
            $script:activeLogPath = Join-Path $PSScriptRoot "Logs\cut-$baseName.log"
            $script:activeCutIndex = 0
            $script:activeCutTotal = 0
            $script:activeCutDuration = 0.0
            $script:activeCutDurationText = ''
        }
        $lblProgress.Text = "File: $baseName"
        # Always try to populate duration immediately from the log, and also try to resolve a source video
        try {
            Update-InitialDurationFromLog
        } catch {}
        try {
            # Attempt to find the source video file by base name so Set-CurrentVideoProgress can fetch duration via ffprobe
            $cfg = Get-Content (Join-Path $PSScriptRoot 'config.json') -Raw | ConvertFrom-Json
            $videosFolder = Join-Path $PSScriptRoot $cfg.videosFolder
            if (Test-Path $videosFolder) {
                $candidate = Get-ChildItem -Path $videosFolder -File -ErrorAction SilentlyContinue | Where-Object { [IO.Path]::GetFileNameWithoutExtension($_.Name) -ieq $baseName } | Select-Object -First 1
                if ($candidate) {
                    Set-CurrentVideoProgress -videoPath $candidate.FullName
                }
            }
        } catch {}
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

function Update-StatusFromLogLine([string]$line, [string]$label) {
    if ([string]::IsNullOrWhiteSpace($line)) { return }

    # ffmpeg can flush multiple progress chunks in one read; use the last token on the line.
    if ($label -ne 'Cutting') {
        $durationMatches = [regex]::Matches($line, 'Duration:\s*(\d{2}:\d{2}:\d{2}(?:\.\d+)?)')
        if ($durationMatches.Count -gt 0) {
            $duration = $durationMatches[$durationMatches.Count - 1].Groups[1].Value
            if (-not [string]::IsNullOrWhiteSpace($duration)) {
                Set-StatusTiming -elapsed $script:activeElapsed -duration $duration
                if ($script:currentVideoTotalFrames -eq 0) {
                    $script:currentVideoDuration = & Convert-TimecodeToSeconds $duration
                    & TrySetCurrentVideoTotalFramesFromMetadata
                }
            }
        }

        $fpsMatches = [regex]::Matches($line, '(?i)(\d+(?:\.\d+)?)\s*fps')
        if ($fpsMatches.Count -gt 0 -and $script:currentVideoTotalFrames -eq 0) {
            $script:currentVideoFps = [double]$fpsMatches[$fpsMatches.Count - 1].Groups[1].Value
            & TrySetCurrentVideoTotalFramesFromMetadata
        }
    }

    $createSegmentMatch = [regex]::Match($line, 'Creating segment .* from (.+?) \(start=(\d{1,2}:\d{2}:\d{2}(?:\.\d+)?)\)')
    if ($label -eq 'Cutting' -and $createSegmentMatch.Success) {
        $videoName = $createSegmentMatch.Groups[1].Value.Trim()
        $startTime = $createSegmentMatch.Groups[2].Value.Trim()
        Set-ActiveLogBase ([IO.Path]::GetFileNameWithoutExtension($videoName))
        Set-ActiveCutSegment $script:activeLogBase $startTime $videoName
    }

    $timeMatches = [regex]::Matches($line, 'time=(\d{2}:\d{2}:\d{2}(?:\.\d+)?)')
    if ($timeMatches.Count -gt 0) {
        $elapsed = $timeMatches[$timeMatches.Count - 1].Groups[1].Value
        Set-StatusTiming -elapsed $elapsed -duration $script:activeDuration
    } else {
        $tMatches = [regex]::Matches($line, 't=(\d+(?:\.\d+)?)')
        if ($tMatches.Count -gt 0) {
            $script:activeElapsed = [double]$tMatches[$tMatches.Count - 1].Groups[1].Value
            Set-ProgressState -done $script:progressDone -total $script:progressTotal
        }
    }

    Update-FrameProgressFromLine -line $line -label $label
}

function Initialize-Progress([string]$label) {
    $script:currentVideoIndex = 0
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
    if ($label -eq 'Detection' -and $line -match '(?i)\bDetection completed for\b') {
        $videoName = $null
        if ($line -match '(?i)\bDetection completed for\b\s+(.+?)(?:\s+->|$)') {
            $videoName = $matches[1].Trim()
        }
        if (-not [string]::IsNullOrWhiteSpace($videoName)) {
            $wasNew = $script:completedDetectionVideos.Add($videoName)
            if ($wasNew) {
                $script:currentVideoFrame = 0
                $script:currentVideoTotalFrames = 0
                $script:currentVideoBase = ''
                $nextDone = $script:progressDone + 1
                Set-ProgressState -done $nextDone -total $script:progressTotal
            }
        }
    } elseif ($label -eq 'Cutting' -and $line -match '(?i)\bCutting completed for\b') {
        $nextDone = $script:progressDone + 1
        Set-ProgressState -done $nextDone -total $script:progressTotal
    } elseif ($label -eq 'Detection' -and $line -match '(?i)\bSkipping .*previous detection results\b') {
        # Treat skips as completed items for progress tracking
        if ($line -match '(?i)Skipping\s+(.+?)\s+because') {
            $videoName = $matches[1].Trim()
            if (-not [string]::IsNullOrWhiteSpace($videoName)) {
                $wasNew = $script:completedDetectionVideos.Add($videoName)
                if ($wasNew) {
                    $script:currentVideoFrame = 0
                    $script:currentVideoTotalFrames = 0
                    $script:currentVideoBase = ''
                    $nextDone = $script:progressDone + 1
                    Set-ProgressState -done $nextDone -total $script:progressTotal
                }
            }
        }
    } elseif ($label -eq 'Cutting' -and $line -match '(?i)\bSkipping .*previous cutting results\b') {
        $nextDone = $script:progressDone + 1
        Set-ProgressState -done $nextDone -total $script:progressTotal
    }
}

function Reset-RunState([string]$status = 'Idle') {
    $script:lastAppendedDetectLine = ''
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
    $script:completedDetectionVideos.Clear()
    $script:currentVideoIndex = 0
    $script:currentVideoFrame = 0
    $script:currentVideoTotalFrames = 0
    $script:currentVideoBase = ''
    $script:currentVideoDuration = 0.0
    $script:currentVideoFps = 0.0
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

function Should-AppendLogLine([string]$line) {
    if ([string]::IsNullOrWhiteSpace($line)) { return $false }
    if ($line -match '(?i)\bframe=|\bframe:\b') { return $false }
    if ($line -match '(?i)^Detecting occurrences in .* using') {
        if ($script:lastAppendedDetectLine -eq $line) { return $false }
        $script:lastAppendedDetectLine = $line
        return $true
    }
    if ($line -match '(?i)\b(Detection completed for|Creating segment|Autopilot|started at|finished at|Skipping|Error|failed|exception)\b') { return $true }
    return $false
}

function Append-Log([string]$text) {
    if (-not [string]::IsNullOrWhiteSpace($text)) {
        if ($text -like "UI monitor error:*Cannot bind argument to parameter 'Job' because it is null.*") {
            return
        }
        if (-not (Should-AppendLogLine $text)) {
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
        if ($txtLog.Lines.Count -gt 120) {
            $startIdx = $txtLog.Lines.Count - 120
            $txtLog.Lines = $txtLog.Lines[$startIdx..($txtLog.Lines.Count - 1)]
        }
        $txtLog.SelectionColor = [System.Drawing.Color]::Lime
        $txtLog.SelectionStart = $txtLog.Text.Length
        $txtLog.ScrollToCaret()
    }
}

function Trim-LogBuffer([int]$maxLines) {
    if ($maxLines -lt 1) { return }
    if ($txtLog.Lines.Count -le $maxLines) { return }
    $startIdx = $txtLog.Lines.Count - $maxLines
    $txtLog.Lines = $txtLog.Lines[$startIdx..($txtLog.Lines.Count - 1)]
}

function Prepare-DetectionDecisionsForUi([string]$decisionsPath) {
    if ([string]::IsNullOrWhiteSpace($decisionsPath)) { return }
    try {
        $rootPath = Get-UiRootPath
        if ([string]::IsNullOrWhiteSpace($rootPath)) { return }

        $configPath = Join-Path $rootPath 'config.json'
        $config = Get-Content $configPath -Raw | ConvertFrom-Json
        $videosFolder = Join-Path $rootPath $config.videosFolder
        $cutLogsFolder = Join-Path $rootPath $config.cutLogsFolder
        if (-not (Test-Path $cutLogsFolder)) { New-Item -ItemType Directory -Force -Path $cutLogsFolder | Out-Null }

        $exts = @($config.inputExtensions)
        if (-not $exts -or $exts.Count -eq 0) { $exts = @('mp4','mkv','mov','avi') }
        $exts = $exts | ForEach-Object { $_.ToString().TrimStart('.').ToLower() } | Sort-Object -Unique
        $files = @(Get-ChildItem -Path $videosFolder -File -ErrorAction SilentlyContinue | Where-Object { $exts -contains ($_.Extension.TrimStart('.').ToLower()) })

        $map = @{}
        if (Test-Path $decisionsPath) {
            try {
                $raw = Get-Content -Path $decisionsPath -Raw -ErrorAction Stop
                if (-not [string]::IsNullOrWhiteSpace($raw)) {
                    $obj = $raw | ConvertFrom-Json -ErrorAction Stop
                    if ($null -ne $obj) {
                        foreach ($p in $obj.PSObject.Properties) { $map[$p.Name] = $p.Value }
                    }
                }
            } catch {}
        }

        foreach ($videoFile in $files) {
            $base = [IO.Path]::GetFileNameWithoutExtension($videoFile.Name)
            $cutFile = Join-Path $cutLogsFolder ("{0}_cuts.txt" -f $base)
            if (-not (Test-Path $cutFile)) { continue }

            $entryKey = "detection:{0}" -f $base
            if ($map.ContainsKey($entryKey)) { continue }

            $message = "Previous detection results were found for '$($videoFile.Name)'. Re-run detection and replace them?"
            $decision = 'keep'
            try {
                $result = [System.Windows.Forms.MessageBox]::Show($message, 'Detection already completed', [System.Windows.Forms.MessageBoxButtons]::YesNo, [System.Windows.Forms.MessageBoxIcon]::Question)
                if ($result -eq [System.Windows.Forms.DialogResult]::Yes) {
                    $decision = 'reprocess'
                }
            } catch {
                $decision = 'keep'
            }
            $map[$entryKey] = $decision
        }

        if ($map.Count -gt 0) {
            $parentDir = Split-Path -Parent $decisionsPath
            if ($parentDir -and -not (Test-Path $parentDir)) {
                New-Item -ItemType Directory -Force -Path $parentDir | Out-Null
            }
            $json = $map | ConvertTo-Json -Depth 5
            Set-Content -Path $decisionsPath -Value $json -Encoding utf8
        }
    } catch {
        Append-Log ("UI preflight warning: {0}" -f $_.Exception.Message)
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
    $rootPath = Get-UiRootPath
    $decisionsPath = if ($rootPath) { Join-Path $rootPath '.user_decisions.json' } else { Join-Path (Get-Location).Path '.user_decisions.json' }

    $lblStatus.Text = "$($label): starting"
    Reset-ActiveLogState
    # Clear completed-video tracking from any prior run so progress prompts/counts reset.
    try { $script:completedDetectionVideos.Clear() } catch {}
    if ($label -eq 'Detection') {
        try { Prepare-DetectionDecisionsForUi -decisionsPath $decisionsPath } catch {}
    }
    Initialize-Progress $label
    Append-Log ("")
    Append-Log (("=== {0} started at {1} ===" -f $label, (Get-Date)))

    $jobName = ("{0}-{1}" -f $label, (Get-Date).ToString('yyyyMMddHHmmss'))
    $job = Start-Job -Name $jobName -ArgumentList $scriptPath, $scriptDir, $decisionsPath -ScriptBlock {
        param($childScript, $childDir, $decisionsPath)
        Set-Location -LiteralPath $childDir
        if ($decisionsPath) { $env:CUT_VIDEO_DECISIONS_PATH = $decisionsPath }
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
    $timer.Interval = 1000
    $timer.Add_Tick({
        param($timerRef, $eventArgs)
        try {
            $jobRef = $script:activeJob
            $currentLabel = $script:activeLabel
            if ($null -eq $jobRef) {
                if ($timerRef -and $timerRef.Enabled) { $timerRef.Stop() }
                return
            }

            if (-not (Get-Job -Id $jobRef.Id -ErrorAction SilentlyContinue)) {
                Reset-RunState 'Idle'
                return
            }

            $messages = @(& { Receive-Job -Job $jobRef *>&1 })
            foreach ($m in $messages) {
                if ($null -ne $m) {
                    $line = $m.ToString()
                    Update-StatusFromLogLine -line $line -label $currentLabel
                    Append-Log $line
                    if ($line -match 'Detecting occurrences in .* using blend\+difference\+blackframe\.\.\.' -and $line -match 'Detecting occurrences in (.+?) using') {
                        $videoPath = $matches[1]
                        Set-ActiveLogBase ([IO.Path]::GetFileNameWithoutExtension($videoPath))
                        Set-CurrentVideoProgress -videoPath $videoPath
                    }
                    if ($line -match 'Creating segment .* from (.+?) \(start=') {
                        Set-ActiveLogBase ([IO.Path]::GetFileNameWithoutExtension($matches[1]))
                    }
                    Update-ProgressFromLine -line $line -label $currentLabel
                }
            }

            if (-not [string]::IsNullOrWhiteSpace($script:activeLogPath)) {
                Update-ProgressFromLogFile -label $currentLabel
            }

            if ($jobRef.State -ne 'Running') {
                $final = @(& { Receive-Job -Job $jobRef *>&1 })
                foreach ($line in $final) {
                    if ($null -ne $line) {
                        $text = $line.ToString()
                        if ($text -match '(?i)\bframe\s*(?:=|:)\s*\d+') {
                            Update-StatusFromLogLine -line $text -label $currentLabel
                            Update-ProgressFromLine -line $text -label $currentLabel
                            continue
                        }
                        Append-Log $text
                        Update-StatusFromLogLine -line $text -label $currentLabel
                        Update-ProgressFromLine -line $text -label $currentLabel
                    }
                }
                Update-ProgressFromLogFile -label $currentLabel

                $shouldStartCutting = ($currentLabel -eq 'Detection' -and $script:autopilotEnabled)
                $shouldFinishAutopilot = ($currentLabel -eq 'Cutting' -and $script:autopilotEnabled)

                if ($script:progressTotal -gt 0) {
                    Set-ProgressState -done $script:progressTotal -total $script:progressTotal
                }
                Append-Log (("=== {0} finished at {1} (state={2}) ===" -f $currentLabel, (Get-Date), $jobRef.State))
                Trim-LogBuffer 80
                Reset-RunState 'Idle'

                if ($shouldStartCutting) {
                    Append-Log 'Autopilot: detection finished, starting cutting...'
                    Start-ScriptJob 'Cutting' (Join-Path $PSScriptRoot '2.Cut_Video.ps1')
                    return
                }

                if ($shouldFinishAutopilot) {
                    Append-Log 'Autopilot: cutting finished.'
                    Set-AutopilotState $false
                }
            } else {
                $lblStatus.Text = "$(Get-StatusAction $currentLabel)"
            }
        } catch {
                    if ($timerRef -and $timerRef.Enabled) { $timerRef.Stop() }
            Append-Log (("UI monitor error: {0}" -f $_.Exception.Message))
            Trim-LogBuffer 120
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
    if ($script:autopilotEnabled -and -not $script:activeJob) {
        Set-AutopilotState $false
        Append-Log 'Autopilot stopped by user.'
        return
    }

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
$btnClean.Add_Click({
    if ($script:activeJob -and $script:activeJob.State -eq 'Running') {
        [System.Windows.Forms.MessageBox]::Show('Cannot clean while a job is running. Stop the task first.','Busy')
        return
    }
    $prompt = 'Delete generated logs, cut logs, outputs, and input images while preserving raw videos?'
    $prompt += "`r`n`r`n"
    $prompt += 'Yes = preserve videos, No = delete videos too, Cancel = abort.'
    $confirm = [System.Windows.Forms.MessageBox]::Show($prompt,'Confirm cleanup',[System.Windows.Forms.MessageBoxButtons]::YesNoCancel,[System.Windows.Forms.MessageBoxIcon]::Question)
    if ($confirm -eq [System.Windows.Forms.DialogResult]::Cancel) { return }
    $preserveVideos = ($confirm -eq [System.Windows.Forms.DialogResult]::Yes)
    try {
        $config = Get-Content (Join-Path $PSScriptRoot 'config.json') -Raw | ConvertFrom-Json
        $deleteFolders = @($config.logsFolder, $config.cutLogsFolder, $config.outputsFolder, $config.imagesFolder)
        if (-not $preserveVideos -and -not [string]::IsNullOrWhiteSpace($config.videosFolder)) {
            $deleteFolders += $config.videosFolder
        }
        foreach ($folder in $deleteFolders) {
            if ([string]::IsNullOrWhiteSpace($folder)) { continue }
            $path = Join-Path $PSScriptRoot $folder
            if (Test-Path $path) {
                Get-ChildItem -Path $path -Force -Recurse -ErrorAction SilentlyContinue | Remove-Item -Force -Recurse -ErrorAction SilentlyContinue
            }
        }
        # Also remove persistent decision store if present so Clean fully resets state.
        $decisionsPath = Join-Path $PSScriptRoot '.user_decisions.json'
        if (Test-Path $decisionsPath) { Remove-Item -LiteralPath $decisionsPath -Force -ErrorAction SilentlyContinue }
        $lblStatus.Text = 'Cleanup completed'
        if ($preserveVideos) {
            Append-Log 'Cleanup completed: logs, cut logs, outputs, input images removed; raw videos preserved.'
        } else {
            Append-Log 'Cleanup completed: logs, cut logs, outputs, input images, and videos removed.'
        }
        Set-ProgressState -done 0 -total 0
    } catch {
        Append-Log ("Cleanup failed: {0}" -f $_.Exception.Message)
    }
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
