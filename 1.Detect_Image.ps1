param()

# Read configuration
$configPath = Join-Path $PSScriptRoot 'config.json'
$config = Get-Content $configPath -Raw | ConvertFrom-Json

$ffmpeg = $config.ffmpegPath

# Resolve executable helper
function Resolve-Exec([string]$name) {
	try {
		$candidate = if ([IO.Path]::IsPathRooted($name)) { $name } else { Join-Path $PSScriptRoot $name }
		if (Test-Path $candidate) { return (Resolve-Path $candidate).Path }
		$cmd = Get-Command $name -ErrorAction SilentlyContinue
		if ($cmd) { return $cmd.Path }
		return $null
	} catch { return $null }
}

$ffmpegResolved = Resolve-Exec $ffmpeg
if (-not $ffmpegResolved) {
	Write-Error 'ffmpeg not found. Set ''ffmpegPath'' in config.json or ensure ffmpeg is in PATH.'
	exit 1
}
$ffmpeg = $ffmpegResolved

$ffprobe = Resolve-Exec 'ffprobe.exe'
if (-not $ffprobe) {
	$probeNext = Join-Path (Split-Path $ffmpeg) 'ffprobe.exe'
	if (Test-Path $probeNext) { $ffprobe = (Resolve-Path $probeNext).Path }
}
if (-not $ffprobe) { Write-Warning 'ffprobe not found. FPS detection may fail.' }

$videosFolder = Join-Path $PSScriptROOT $config.videosFolder
$outputsFolder = Join-Path $PSScriptROOT $config.outputsFolder
$imagesFolderName = if ($config.imagesFolder) { $config.imagesFolder } else { 'Input' }
$imagesFolder = Join-Path $PSScriptROOT $imagesFolderName
$logsFolder = Join-Path $PSScriptROOT $config.logsFolder
$cutLogsFolder = Join-Path $PSScriptROOT $config.cutLogsFolder

# Ensure folders exist
New-Item -ItemType Directory -Force -Path $videosFolder, $imagesFolder, $outputsFolder, $logsFolder, $cutLogsFolder | Out-Null
try { Add-Type -AssemblyName System.Windows.Forms } catch {}

# Global debug log for detection script runs (helps trace decision-store usage)
$globalDebugLog = Join-Path $logsFolder 'detect-script-debug.log'
try {
	$envPath = if ($env:CUT_VIDEO_DECISIONS_PATH) { $env:CUT_VIDEO_DECISIONS_PATH } else { '<unset>' }
	Add-Content -Path $globalDebugLog -Value ("==== Detect run at {0} ====" -f (Get-Date)) -Encoding utf8
	Add-Content -Path $globalDebugLog -Value ("DEBUG: env.CUT_VIDEO_DECISIONS_PATH={0}" -f $envPath) -Encoding utf8
	Add-Content -Path $globalDebugLog -Value ("DEBUG: PSScriptRoot={0}" -f $PSScriptRoot) -Encoding utf8
	try { Add-Content -Path $globalDebugLog -Value ("DEBUG: CWD={0}" -f (Get-Location).Path) -Encoding utf8 } catch {}
	# If a decisions file exists nearby, dump its path and contents for debugging
	try {
		$cand = if ($envPath -ne '<unset>' -and (Test-Path $envPath)) { $envPath } else { (Join-Path $PSScriptRoot '.user_decisions.json') }
		if ($cand -and (Test-Path $cand)) {
			Add-Content -Path $globalDebugLog -Value ("DEBUG: Found decisions file at {0}" -f $cand) -Encoding utf8
			$decContent = Get-Content -Path $cand -Raw -ErrorAction SilentlyContinue
			Add-Content -Path $globalDebugLog -Value ("DEBUG: decisions content: {0}" -f $decContent) -Encoding utf8
		} else {
			Add-Content -Path $globalDebugLog -Value "DEBUG: No decisions file found at default locations" -Encoding utf8
		}
	} catch {
		Add-Content -Path $globalDebugLog -Value ("DEBUG: Failed to inspect decisions file: {0}" -f $_.Exception.Message) -Encoding utf8
	}
} catch {
	# ignore debug log failures
}

function Write-CompletionMarker([string]$logFilePath, [string]$marker, [string]$detail) {
	if ([string]::IsNullOrWhiteSpace($logFilePath)) { return }
	try {
		$line = if ([string]::IsNullOrWhiteSpace($detail)) { $marker } else { "{0} {1}" -f $marker, $detail }
		Add-Content -Path $logFilePath -Value $line -Encoding utf8
	} catch {
		# Ignore marker write issues.
	}
}

function Get-DetectionState([string]$baseName, [string]$logFilePath, [string]$cutFilePath) {
	$hasCompletedMarker = $false
	$hasCutTimestamps = $false
	$hasExistingArtifacts = $false
	$hasMeaningfulResults = $false
	$markerText = $null

	if (Test-Path $logFilePath) {
		$hasExistingArtifacts = $true
		try {
			$logLines = @(Get-Content -Path $logFilePath -ErrorAction SilentlyContinue)
			$hasCompletedMarker = ($logLines -match '__CUT_VIDEO_DETECTION_FINISHED__')
			if ($hasCompletedMarker) {
				$hasMeaningfulResults = $true
				$markerText = ($logLines | Where-Object { $_ -match '__CUT_VIDEO_DETECTION_FINISHED__' } | Select-Object -Last 1)
			}
		} catch {}
	}

	if (Test-Path $cutFilePath) {
		$hasExistingArtifacts = $true
		try {
			$cutLines = @(Get-Content -Path $cutFilePath -ErrorAction SilentlyContinue | Where-Object { $_ -match '^\d{1,2}:\d{2}:\d{2}(?:\.\d+)?$' })
			$hasCutTimestamps = ($cutLines.Count -gt 0)
			if ($hasCutTimestamps) { $hasMeaningfulResults = $true }
		} catch {}
	}

	return [PSCustomObject]@{
		HasCompletedMarker = $hasCompletedMarker
		HasCutTimestamps = $hasCutTimestamps
		HasExistingArtifacts = $hasExistingArtifacts
		HasMeaningfulResults = $hasMeaningfulResults
		MarkerText = $markerText
	}
}

function Confirm-DetectionReprocess([string]$videoName, [string]$logFilePath, [string]$cutFilePath) {
	# Persistent decisions file: store user choices to keep or reprocess specific videos across runs.
	function Get-DetectionDecisionsPath() {
		if ($env:CUT_VIDEO_DECISIONS_PATH) { return $env:CUT_VIDEO_DECISIONS_PATH }
		$candidates = @()
		if ($PSScriptRoot) { $candidates += (Join-Path $PSScriptRoot '.user_decisions.json') }
		try { $cwd = (Get-Location).Path ; if ($cwd) { $candidates += (Join-Path $cwd '.user_decisions.json') } } catch {}
		foreach ($p in $candidates) { if (Test-Path $p) { return $p } }
		if ($PSScriptRoot) { return (Join-Path $PSScriptRoot '.user_decisions.json') }
		return '.user_decisions.json'
	}
	function Get-DetectionDecisions() {
		$path = Get-DetectionDecisionsPath
		$map = @{}
		try {
			if (-not (Test-Path $path)) { return $map }
			$j = Get-Content -Path $path -Raw -ErrorAction Stop
			if (-not [string]::IsNullOrWhiteSpace($j)) {
				$obj = $j | ConvertFrom-Json -ErrorAction Stop
				if ($null -ne $obj) {
					foreach ($p in $obj.PSObject.Properties) { $map[$p.Name] = $p.Value }
				}
			}
			try { Add-Content -Path $logFilePath -Value ("DEBUG: Get-DetectionDecisions used path={0}" -f $path) -Encoding utf8 } catch {}
		} catch {
			try { Add-Content -Path $logFilePath -Value ("DEBUG: Get-DetectionDecisions failed reading {0}: {1}" -f $path, $_.Exception.Message) -Encoding utf8 } catch {}
		}
		return $map
	}
	function Set-DetectionDecisions([hashtable]$map) {
		$path = Get-DetectionDecisionsPath
		try {
			$json = $map | ConvertTo-Json -Depth 5
			Set-Content -Path $path -Value $json -Encoding utf8
			try { Add-Content -Path $logFilePath -Value ("DEBUG: Set-DetectionDecisions wrote to {0}" -f $path) -Encoding utf8 } catch {}
		} catch {
			try { Add-Content -Path $logFilePath -Value ("DEBUG: Set-DetectionDecisions failed writing {0}: {1}" -f $path, $_.Exception.Message) -Encoding utf8 } catch {}
		}
	}

	try { Add-Content -Path $logFilePath -Value ("DEBUG: Confirm-DetectionReprocess enter env.CUT_VIDEO_DECISIONS_PATH={0} PSScriptRoot={1} CWD={2}" -f $env:CUT_VIDEO_DECISIONS_PATH, $PSScriptRoot, (Get-Location).Path) -Encoding utf8 } catch {}

	$state = Get-DetectionState -baseName ([IO.Path]::GetFileNameWithoutExtension($videoName)) -logFilePath $logFilePath -cutFilePath $cutFilePath
	$cutLogExists = (Test-Path $cutFilePath)
	if (-not $cutLogExists) { return $true }

	# Check persistent decision store first (honour previous 'keep' even if the prior detection run did not finish)
	try {
		$base = [IO.Path]::GetFileNameWithoutExtension($videoName)
		$decisions = Get-DetectionDecisions
		$key = ("detection:{0}" -f $base)
		if ($decisions.ContainsKey($key)) {
			if ($decisions[$key] -eq 'keep') {
				Write-Output (("Skipping {0} because previous detection results were kept (decision store)." -f $videoName))
				try { Add-Content -Path $logFilePath -Value ("PROMPT_RESPONSE: detection reprocess=AUTOSKIP_FROM_STORE video={0}" -f $videoName) -Encoding utf8 } catch {}
				return $false
			}
			if ($decisions[$key] -eq 'reprocess') {
				try { Add-Content -Path $logFilePath -Value ("PROMPT_RESPONSE: detection reprocess=REPROCESS_FROM_STORE video={0}" -f $videoName) -Encoding utf8 } catch {}
				return $true
			}
		}
	} catch {}

	$detail = if ($state.HasCutTimestamps) { 'existing cut timestamps' } elseif ($state.HasCompletedMarker) { 'completed detection marker' } else { 'existing cut-log file' }
	$message = "Previous detection results were found for '$videoName' ($detail). Re-run detection and replace them?"
	$isUiMode = ($env:CUT_VIDEO_UI_MODE -eq '1')
	$isInteractive = [Environment]::UserInteractive -and -not $isUiMode
	if ($isInteractive) {
		$response = Read-Host $message
		if ($response -notmatch '^(?i:y|yes)$') {
			Write-Output ("Skipping {0} because previous detection results were kept." -f $videoName)
			try { Add-Content -Path $logFilePath -Value ("PROMPT_RESPONSE: detection reprocess=NO video={0}" -f $videoName) -Encoding utf8 } catch {}
			# persist decision to avoid re-prompting across restarts
			try {
				$base = [IO.Path]::GetFileNameWithoutExtension($videoName)
				$decisions = Get-DetectionDecisions
				$decisions[("detection:{0}" -f $base)] = 'keep'
				Set-DetectionDecisions -map $decisions
			} catch {}
			return $false
		}
		try { Add-Content -Path $logFilePath -Value ("PROMPT_RESPONSE: detection reprocess=YES video={0}" -f $videoName) -Encoding utf8 } catch {}
		# persist affirmative decision
		try {
			$base = [IO.Path]::GetFileNameWithoutExtension($videoName)
			$decisions = Get-DetectionDecisions
			$decisions[("detection:{0}" -f $base)] = 'reprocess'
			Set-DetectionDecisions -map $decisions
		} catch {}
		return $true
	}

	if ($isUiMode) {
		try {
			Write-Output ("Prompting for {0} because a prior cut-log exists." -f $videoName)
			$result = [System.Windows.Forms.MessageBox]::Show($message, 'Detection already completed', [System.Windows.Forms.MessageBoxButtons]::YesNo, [System.Windows.Forms.MessageBoxIcon]::Question)
			if ($result -ne [System.Windows.Forms.DialogResult]::Yes) {
				Write-Output ("Skipping {0} because previous detection results were kept." -f $videoName)
				try { Add-Content -Path $logFilePath -Value ("PROMPT_RESPONSE: detection reprocess=NO video={0}" -f $videoName) -Encoding utf8 } catch {}
				try {
					$base = [IO.Path]::GetFileNameWithoutExtension($videoName)
					$decisions = Get-DetectionDecisions
					$decisions[("detection:{0}" -f $base)] = 'keep'
					Set-DetectionDecisions -map $decisions
				} catch {}
				return $false
			}
			try { Add-Content -Path $logFilePath -Value ("PROMPT_RESPONSE: detection reprocess=YES video={0}" -f $videoName) -Encoding utf8 } catch {}
			try {
				$base = [IO.Path]::GetFileNameWithoutExtension($videoName)
				$decisions = Get-DetectionDecisions
				$decisions[("detection:{0}" -f $base)] = 'reprocess'
				Set-DetectionDecisions -map $decisions
			} catch {}
			return $true
		} catch {
			Write-Output ("Skipping {0} because previous detection results were found." -f $videoName)
			try { Add-Content -Path $logFilePath -Value ("PROMPT_RESPONSE: detection reprocess=ERROR video={0}" -f $videoName) -Encoding utf8 } catch {}
			return $false
		}
	}

	if (-not [Environment]::UserInteractive) {
		Write-Output ("Skipping {0} because previous detection results were found." -f $videoName)
		try { Add-Content -Path $logFilePath -Value ("PROMPT_RESPONSE: detection reprocess=AUTOSKIP_UI video={0}" -f $videoName) -Encoding utf8 } catch {}
		try {
			$base = [IO.Path]::GetFileNameWithoutExtension($videoName)
			$decisions = Get-DetectionDecisions
			$decisions[("detection:{0}" -f $base)] = 'keep'
			Set-DetectionDecisions -map $decisions
		} catch {}
		return $false
	}

	Write-Output ("Skipping {0} because previous detection results were found." -f $videoName)
	try { Add-Content -Path $logFilePath -Value ("PROMPT_RESPONSE: detection reprocess=AUTOSKIP video={0}" -f $videoName) -Encoding utf8 } catch {}
	return $false
}

function Get-ExistingVideoArtifacts([string]$baseName, [string]$logFilePath, [string]$cutFilePath) {
	$artifactPaths = New-Object 'System.Collections.Generic.List[string]'
	foreach ($candidate in @($logFilePath, $cutFilePath, (Join-Path $imagesFolder ("${baseName}_ref.png")))) {
		if ([string]::IsNullOrWhiteSpace($candidate)) { continue }
		if (Test-Path $candidate) {
			try { $artifactPaths.Add((Resolve-Path $candidate).Path) } catch { $artifactPaths.Add($candidate) }
		}
	}

	if (Test-Path $outputsFolder) {
		try {
			$outputFiles = Get-ChildItem -Path $outputsFolder -File -ErrorAction SilentlyContinue | Where-Object { $_.Name -like "${baseName}_*" }
			foreach ($outputFile in $outputFiles) {
				$artifactPaths.Add($outputFile.FullName)
			}
		} catch {
			# Ignore output folder lookup issues and continue.
		}
	}

	return @($artifactPaths | Sort-Object -Unique)
}

function Remove-ExistingVideoArtifacts([string]$baseName, [string]$logFilePath, [string]$cutFilePath) {
	$artifacts = @(Get-ExistingVideoArtifacts -baseName $baseName -logFilePath $logFilePath -cutFilePath $cutFilePath)
	# Defensive guard: re-check persistent decision store right before deleting artifacts.
	try {
		$decisionsPath = if ($env:CUT_VIDEO_DECISIONS_PATH) { $env:CUT_VIDEO_DECISIONS_PATH } else { 
			$cands = @()
			if ($PSScriptRoot) { $cands += (Join-Path $PSScriptRoot '.user_decisions.json') }
			try { $cwd = (Get-Location).Path ; if ($cwd) { $cands += (Join-Path $cwd '.user_decisions.json') } } catch {}
			foreach ($p in $cands) { if (Test-Path $p) { $decisionsPath = $p ; break } }
			if (-not $decisionsPath -and $PSScriptRoot) { $decisionsPath = (Join-Path $PSScriptRoot '.user_decisions.json') }
		}
		if ($decisionsPath -and (Test-Path $decisionsPath)) {
			try {
				$j = Get-Content -Path $decisionsPath -Raw -ErrorAction Stop
				if (-not [string]::IsNullOrWhiteSpace($j)) {
					$obj = $j | ConvertFrom-Json -ErrorAction Stop
					$key = ("detection:{0}" -f $baseName)
					if ($obj.PSObject.Properties.Name -contains $key) {
						if ($obj.$key -eq 'keep') {
							try { Add-Content -Path $logFilePath -Value ("DEBUG: Remove-ExistingVideoArtifacts skipped due to decision store key={0} path={1}" -f $key, $decisionsPath) -Encoding utf8 } catch {}
							return
						}
					}
				}
			} catch {
				try { Add-Content -Path $logFilePath -Value ("DEBUG: Remove-ExistingVideoArtifacts failed reading decisions {0}: {1}" -f $decisionsPath, $_.Exception.Message) -Encoding utf8 } catch {}
			}
		}
	} catch {}
	foreach ($artifact in $artifacts) {
		try { Remove-Item -LiteralPath $artifact -Force -ErrorAction SilentlyContinue } catch { }
	}
}

# helper: get numeric fps for a file
function Get-Fps($path) {
	try {
		if (-not $ffprobe) { return $null }
		$r = & $ffprobe -v 0 -select_streams v:0 -show_entries stream=r_frame_rate -of default=nw=1:nk=1 $path 2>$null
		if (-not $r) { return $null }
		$r = $r.Trim()
		if ($r -match '/') {
			$parts = $r -split '/'
			return [double]($parts[0]) / [double]($parts[1])
		} else {
			return [double]$r
		}
	} catch {
		return $null
	}
}

# Gather videos by configured extensions
$exts = @()
try { $exts = @($config.inputExtensions) } catch { $exts = @() }
if ($exts.Count -eq 0) { $exts = @('mp4','mkv','mov') }
$exts = $exts | ForEach-Object { $_.ToString().TrimStart('.').ToLower() } | Sort-Object -Unique
$allFiles = Get-ChildItem -Path $videosFolder -File -ErrorAction SilentlyContinue
$videos = $allFiles | Where-Object { $exts -contains ($_.Extension.TrimStart('.').ToLower()) }
Write-Output ("Found {0} input video(s) in {1} (extensions: {2})" -f $videos.Count, $videosFolder, ($exts -join ','))
if ($videos.Count -eq 0) {
	Write-Warning ("No input videos found in {0}. Add files to the folder and run detection again." -f $videosFolder)
	exit 0
}

foreach ($video in $videos) {
	$base = [IO.Path]::GetFileNameWithoutExtension($video.Name)
	$logFile = Join-Path $logsFolder ("detect-$base.log")
	$cutFile = Join-Path $cutLogsFolder ("${base}_cuts.txt")
	$refImage = $null

	# Early decisions check: consult persistent decision store before doing any work.
	$shouldReprocess = $true
	try {
		$decisionsPath = if ($env:CUT_VIDEO_DECISIONS_PATH) { $env:CUT_VIDEO_DECISIONS_PATH } else {
			$cands = @()
			if ($PSScriptRoot) { $cands += (Join-Path $PSScriptRoot '.user_decisions.json') }
			try { $cwd = (Get-Location).Path ; if ($cwd) { $cands += (Join-Path $cwd '.user_decisions.json') } } catch {}
			foreach ($p in $cands) { if (Test-Path $p) { $decisionsPath = $p ; break } }
			if (-not $decisionsPath -and $PSScriptRoot) { $decisionsPath = (Join-Path $PSScriptRoot '.user_decisions.json') }
		}
		if ($decisionsPath -and (Test-Path $decisionsPath)) {
			try {
				$j = Get-Content -Path $decisionsPath -Raw -ErrorAction Stop
				if (-not [string]::IsNullOrWhiteSpace($j)) {
					$obj = $j | ConvertFrom-Json -ErrorAction Stop
					$key = ("detection:{0}" -f $base)
					if ($obj.PSObject.Properties.Name -contains $key) {
						if ($obj.$key -eq 'keep') {
							try { Add-Content -Path $logFile -Value ("PROMPT_RESPONSE: detection reprocess=AUTOSKIP_FROM_STORE_EARLY video={0}" -f $video.Name) -Encoding utf8 } catch {}
							Write-Output ("Skipping {0} due to persistent decision 'keep'." -f $video.Name)
							$shouldReprocess = $false
							continue
						} elseif ($obj.$key -eq 'reprocess') {
							$shouldReprocess = $true
						}
					}
				}
			} catch {
				try { Add-Content -Path $logFile -Value ("DEBUG: Early Load-Decisions failed reading {0}: {1}" -f $decisionsPath, $_.Exception.Message) -Encoding utf8 } catch {}
			}
		}
	} catch {}

	$existingArtifacts = @(Get-ExistingVideoArtifacts -baseName $base -logFilePath $logFile -cutFilePath $cutFile)
	$hasExistingArtifacts = ($existingArtifacts.Count -gt 0)
	if ((Test-Path $cutFile) -or $hasExistingArtifacts -or (Test-Path $logFile)) {
		$shouldReprocess = Confirm-DetectionReprocess -videoName $video.Name -logFilePath $logFile -cutFilePath $cutFile
	}
	if (-not $shouldReprocess) {
		continue
	}
	if ($hasExistingArtifacts) {
		try { Add-Content -Path $logFile -Value ("DEBUG: About to Remove-ExistingVideoArtifacts base={0} shouldReprocess={1} decisionsPath={2}" -f $base, $shouldReprocess, $env:CUT_VIDEO_DECISIONS_PATH) -Encoding utf8 } catch {}
		Remove-ExistingVideoArtifacts -baseName $base -logFilePath $logFile -cutFilePath $cutFile
	}

	# Prepare reference image (custom or extracted)
	if ([string]::IsNullOrWhiteSpace($config.referenceImage)) {
		$frameNum = [int]$config.referenceFrameNumber
		# save per-video reference image in imagesFolder
		$refImage = Join-Path $imagesFolder ("${base}_ref.png")
		$extractArgs = @(
			"-y",
			"-i", $video.FullName,
			"-vf", "select=eq(n\,$frameNum)",
			"-frames:v", "1",
			"-update", "1",
			$refImage
		)
		Write-Output ("Extracting reference frame {0} from {1}" -f $frameNum, $video.Name)
		& $ffmpeg @extractArgs 2>&1 | ForEach-Object { Add-Content -Path $logFile -Value $_ -Encoding utf8 }
		if ($LASTEXITCODE -ne 0 -or -not (Test-Path $refImage)) {
			Write-Error ("Failed to extract reference frame for {0}. See {1}" -f $video.Name, $logFile)
			continue
		}
	} else {
		$refImage = if ([IO.Path]::IsPathRooted($config.referenceImage)) { $config.referenceImage } else { Join-Path $PSScriptRoot $config.referenceImage }
	}

	if (-not (Test-Path $refImage)) {
		Write-Warning ("Reference image not found for {0}: {1}. Skipping." -f $video.Name, $refImage)
		continue
	}

	# Reset the per-video detection log before each run so the marker reflects the latest pass.
	if (Test-Path $logFile) {
		Remove-Item -LiteralPath $logFile -Force -ErrorAction SilentlyContinue
	}
	Set-Content -Path $logFile -Value '' -Encoding utf8

	# Detection: blend difference + blackframe (parse stderr)
	$blackThreshold = 99
	# filter: [0] video, [1] looped ref image -> scale ref to video, difference blend, blackframe -> label [out]
	$fpsFilter = '[0:v][1:v]scale2ref[vid][ref];[vid][ref]blend=difference:shortest=1[diff];[diff]blackframe=99:32[out]'

	Write-Output ("Detecting occurrences in {0} using blend+difference+blackframe..." -f $video.Name)
	$detectArgs = @(
		"-y",
		"-i", $video.FullName,
		"-loop", "1", "-i", $refImage,
		"-filter_complex", $fpsFilter,
		"-map", "[out]",
		"-an",
		"-vsync", "0",
		"-f", "null", "-"
	)
	Write-Output ("Running ffmpeg detection for {0}: {1}" -f $video.Name, ($detectArgs -join ' '))
	& $ffmpeg @detectArgs 2>&1 | ForEach-Object { Add-Content -Path $logFile -Value $_ -Encoding utf8 }
	if ($LASTEXITCODE -ne 0) {
		Write-Error ("ffmpeg detection failed for {0}. See {1}" -f $video.Name, $logFile)
		continue
	}

	# Parse detect log for blackframe entries
	$found = @()
	$logLines = Get-Content $logFile -ErrorAction SilentlyContinue
	if ($logLines) {
		foreach ($ln in $logLines) {
			if ($ln -match 'blackframe') {
				$rx = [regex]'frame:\s*([0-9]+).*black:\s*([0-9]+)'
				$m = $rx.Match($ln)
				if ($m.Success) {
					$frameIndex = [int]$m.Groups[1].Value
					$blackVal = [int]$m.Groups[2].Value
					if ($blackVal -ge $blackThreshold) {
						$found += [PSCustomObject]@{ Frame = $frameIndex; Score = $blackVal; Line = $ln }
					}
				}
			}
		}
	}

	Write-Output ("Detection parsed: total log lines={0}, matched frames={1}" -f ($logLines.Count), $found.Count)

	# Collapse contiguous frames into groups
	$groups = @()
	$current = $null
	$prev = -9999
	foreach ($f in $found | Sort-Object Frame) {
		if ($f.Frame -gt ($prev + 1)) {
			if ($null -ne $current) { $groups += $current }
			$current = @{ Start = $f.Frame; End = $f.Frame }
		} else {
			if ($null -ne $current) { $current.End = $f.Frame }
		}
		$prev = $f.Frame
	}
	if ($null -ne $current) { $groups += $current }

	# Write cut timestamps
	$fps = Get-Fps $video.FullName
	if (-not $fps) {
		Write-Warning ("Unable to detect FPS for {0}. Skipping timestamp conversion." -f $video.Name)
		continue
	}

	Write-Output ("Found {0} logo occurrence group(s) in {1}" -f $groups.Count, $video.Name)
	for ($gi = 0; $gi -lt $groups.Count; $gi++) {
		$g = $groups[$gi]
		$seconds = $g.Start / $fps
		$ts = [TimeSpan]::FromSeconds([double]$seconds)
		$tsStr = $ts.ToString('hh\:mm\:ss\.fff')
		$tsStr | Out-File -FilePath $cutFile -Append -Encoding utf8
		Write-Output ("  Group {0}: frames {1}-{2} -> {3}" -f ($gi+1), $g.Start, $g.End, $tsStr)
	}

	Write-CompletionMarker -logFilePath $logFile -marker '__CUT_VIDEO_DETECTION_FINISHED__' -detail ("video={0} groups={1}" -f $base, $groups.Count)
	Write-Output ("Detection completed for {0} -> cuts: {1} ; log: {2}" -f $video.Name, $cutFile, $logFile)
}

# All videos processed. Single notification and optional automatic cutting start:
Write-Output ("Detection finished for all videos. Per-video cut files are in: {0}" -f $cutLogsFolder)
$isUiMode = ($env:CUT_VIDEO_UI_MODE -eq '1')
if ($isUiMode -or -not [Environment]::UserInteractive) {
	Write-Output 'Non-interactive mode detected; skipping prompt and automatic cutting handoff.'
	exit 0
}
$answer = Read-Host "Press ENTER to start cutting now, or type 'n' then ENTER to abort"
if ($answer -eq 'n') {
	Write-Output 'Aborting before cutting as requested.'
	exit 0
}

# Launch cutter (script must be in same folder)
$cutScript = Join-Path $PSScriptRoot '2.Cut_Video.ps1'
if (Test-Path $cutScript) {
	Write-Output 'Starting cutting step...'
	& powershell -NoProfile -ExecutionPolicy Bypass -File $cutScript
} else {
	Write-Warning ("Cut script not found: {0}. Run it manually when ready." -f $cutScript)
}

