### Options __________________________________________________________________________________________________________
param()

# Read configuration
$configPath = Join-Path $PSScriptRoot 'config.json'
$config = Get-Content $configPath -Raw | ConvertFrom-Json

$ffmpeg = $config.ffmpegPath

# Resolve executable helper (tries configured path relative to script, then PATH)
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
	Write-Error "ffmpeg not found. Set 'ffmpegPath' in config.json to the ffmpeg executable (e.g. .\\ffmpeg.exe) or ensure ffmpeg is in PATH."
	exit 1
}
$ffmpeg = $ffmpegResolved

# resolve ffprobe similarly (used by Get-Resolution)
$ffprobe = Resolve-Exec 'ffprobe.exe'
if (-not $ffprobe) {
	$probeNext = Join-Path (Split-Path $ffmpeg) 'ffprobe.exe'
	if (Test-Path $probeNext) { $ffprobe = (Resolve-Path $probeNext).Path }
}
if (-not $ffprobe) {
	Write-Warning "ffprobe not found. Resolution detection may fail but cutting can continue (stream-copy mode)."
}

$videosFolder = Join-Path $PSScriptRoot $config.videosFolder
$outputsFolder = Join-Path $PSScriptRoot $config.outputsFolder
$logsFolder = Join-Path $PSScriptRoot $config.logsFolder
$cutLogsFolder = Join-Path $PSScriptRoot $config.cutLogsFolder

try { Add-Type -AssemblyName System.Windows.Forms } catch {}

function Write-CuttingMarker([string]$logFilePath, [string]$marker, [string]$detail) {
	if ([string]::IsNullOrWhiteSpace($logFilePath)) { return }
	try {
		$line = if ([string]::IsNullOrWhiteSpace($detail)) { $marker } else { "{0} {1}" -f $marker, $detail }
		Add-Content -Path $logFilePath -Value $line -Encoding utf8
	} catch {
		# Ignore marker write issues.
	}
}

function Get-CuttingState([string]$baseName, [string]$logFilePath, [string]$cutFilePath, [string]$outputsFolder) {
	$hasCompletedMarker = $false
	$hasExistingOutputs = $false
	$hasExistingArtifacts = $false
	$hasMeaningfulResults = $false
	$markerText = $null
	$existingOutputs = @()

	if (Test-Path $logFilePath) {
		$hasExistingArtifacts = $true
		try {
			$logLines = @(Get-Content -Path $logFilePath -ErrorAction SilentlyContinue)
			$hasCompletedMarker = ($logLines -match '__CUT_VIDEO_CUTTING_FINISHED__')
			if ($hasCompletedMarker) {
				$hasMeaningfulResults = $true
				$markerText = ($logLines | Where-Object { $_ -match '__CUT_VIDEO_CUTTING_FINISHED__' } | Select-Object -Last 1)
			}
		} catch {}
	}

	if (Test-Path $outputsFolder) {
		try {
			$existingOutputs = @(Get-ChildItem -Path $outputsFolder -File -ErrorAction SilentlyContinue | Where-Object { $_.Name -like "${baseName}_*" })
			$hasExistingOutputs = ($existingOutputs.Count -gt 0)
			if ($hasExistingOutputs) { $hasMeaningfulResults = $true; $hasExistingArtifacts = $true }
		} catch {}
	}

	return [PSCustomObject]@{
		HasCompletedMarker = $hasCompletedMarker
		HasExistingOutputs = $hasExistingOutputs
		HasExistingArtifacts = $hasExistingArtifacts
		HasMeaningfulResults = $hasMeaningfulResults
		ExistingOutputs = $existingOutputs
		MarkerText = $markerText
	}
}

function Confirm-CuttingReprocess([string]$videoName, [string]$logFilePath, [string]$cutFilePath, [string]$outputsFolder) {
	# Persistent decisions file: store user choices to keep or reprocess specific videos across runs.
	function Get-DecisionsPath() {
		if ($env:CUT_VIDEO_DECISIONS_PATH) { return $env:CUT_VIDEO_DECISIONS_PATH }
		$candidates = @()
		if ($PSScriptRoot) { $candidates += (Join-Path $PSScriptRoot '.user_decisions.json') }
		try { $cwd = (Get-Location).Path ; if ($cwd) { $candidates += (Join-Path $cwd '.user_decisions.json') } } catch {}
		foreach ($p in $candidates) { if (Test-Path $p) { return $p } }
		if ($PSScriptRoot) { return (Join-Path $PSScriptRoot '.user_decisions.json') }
		return '.user_decisions.json'
	}
	function Load-Decisions() {
		$path = Get-DecisionsPath
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
			try { Add-Content -Path $logFilePath -Value ("DEBUG: Load-Decisions used path={0}" -f $path) -Encoding utf8 } catch {}
		} catch {
			try { Add-Content -Path $logFilePath -Value ("DEBUG: Load-Decisions failed reading {0}: {1}" -f $path, $_.Exception.Message) -Encoding utf8 } catch {}
		}
		return $map
	}
	function Save-Decisions([hashtable]$map) {
		$path = Get-DecisionsPath
		try {
			$json = $map | ConvertTo-Json -Depth 5
			Set-Content -Path $path -Value $json -Encoding utf8
			try { Add-Content -Path $logFilePath -Value ("DEBUG: Save-Decisions wrote to {0}" -f $path) -Encoding utf8 } catch {}
		} catch {
			try { Add-Content -Path $logFilePath -Value ("DEBUG: Save-Decisions failed writing {0}: {1}" -f $path, $_.Exception.Message) -Encoding utf8 } catch {}
		}
	}

	$state = Get-CuttingState -baseName ([IO.Path]::GetFileNameWithoutExtension($videoName)) -logFilePath $logFilePath -cutFilePath $cutFilePath -outputsFolder $outputsFolder

	# Check persistent decision store first (honour previous 'keep' even if prior cutting run did not finish)
	try {
		$base = [IO.Path]::GetFileNameWithoutExtension($videoName)
		$decisions = Load-Decisions
		$key = ("cutting:{0}" -f $base)
		if ($decisions.ContainsKey($key)) {
			if ($decisions[$key] -eq 'keep') {
				Write-Output (("Skipping {0} because previous cutting results were kept (decision store)." -f $videoName))
				try { Add-Content -Path $logFilePath -Value ("PROMPT_RESPONSE: cutting reprocess=AUTOSKIP_FROM_STORE video={0}" -f $videoName) -Encoding utf8 } catch {}
				return $false
			}
			if ($decisions[$key] -eq 'reprocess') {
				try { Add-Content -Path $logFilePath -Value ("PROMPT_RESPONSE: cutting reprocess=REPROCESS_FROM_STORE video={0}" -f $videoName) -Encoding utf8 } catch {}
				return $true
			}
		}
	} catch {}

	if (-not $state.HasMeaningfulResults) { return $true }

	$message = "Previous cutting results were found for '$videoName'. Re-run cutting and replace them?"
	$isUiMode = ($env:CUT_VIDEO_UI_MODE -eq '1')
	$isInteractive = [Environment]::UserInteractive -and -not $isUiMode
	if ($isInteractive) {
		$response = Read-Host $message
		if ($response -notmatch '^(?i:y|yes)$') {
			Write-Output ("Skipping {0} because previous cutting results were kept." -f $videoName)
			try { Add-Content -Path $logFilePath -Value ("PROMPT_RESPONSE: cutting reprocess=NO video={0}" -f $videoName) -Encoding utf8 } catch {}
			# persist decision
			try {
				$base = [IO.Path]::GetFileNameWithoutExtension($videoName)
				$decisions = Load-Decisions
				$decisions[("cutting:{0}" -f $base)] = 'keep'
				Save-Decisions $decisions
			} catch {}
			return $false
		}
		try { Add-Content -Path $logFilePath -Value ("PROMPT_RESPONSE: cutting reprocess=YES video={0}" -f $videoName) -Encoding utf8 } catch {}
		try {
			$base = [IO.Path]::GetFileNameWithoutExtension($videoName)
			$decisions = Load-Decisions
			$decisions[("cutting:{0}" -f $base)] = 'reprocess'
			Save-Decisions $decisions
		} catch {}
		return $true
	}

	if ($isUiMode) {
		try {
			$result = [System.Windows.Forms.MessageBox]::Show($message, 'Cutting already completed', [System.Windows.Forms.MessageBoxButtons]::YesNo, [System.Windows.Forms.MessageBoxIcon]::Question)
			if ($result -ne [System.Windows.Forms.DialogResult]::Yes) {
				Write-Output ("Skipping {0} because previous cutting results were kept." -f $videoName)
				try { Add-Content -Path $logFilePath -Value ("PROMPT_RESPONSE: cutting reprocess=NO video={0}" -f $videoName) -Encoding utf8 } catch {}
				try {
					$base = [IO.Path]::GetFileNameWithoutExtension($videoName)
					$decisions = Load-Decisions
					$decisions[("cutting:{0}" -f $base)] = 'keep'
					Save-Decisions $decisions
				} catch {}
				return $false
			}
			try { Add-Content -Path $logFilePath -Value ("PROMPT_RESPONSE: cutting reprocess=YES video={0}" -f $videoName) -Encoding utf8 } catch {}
			try {
				$base = [IO.Path]::GetFileNameWithoutExtension($videoName)
				$decisions = Load-Decisions
				$decisions[("cutting:{0}" -f $base)] = 'reprocess'
				Save-Decisions $decisions
			} catch {}
			return $true
		} catch {
			try { Add-Content -Path $logFilePath -Value ("PROMPT_RESPONSE: cutting reprocess=ERROR video={0}" -f $videoName) -Encoding utf8 } catch {}
			Write-Output ("Skipping {0} because previous cutting results were found." -f $videoName)
			return $false
		}
	}

	try { Add-Content -Path $logFilePath -Value ("PROMPT_RESPONSE: cutting reprocess=AUTOSKIP video={0}" -f $videoName) -Encoding utf8 } catch {}
	Write-Output ("Skipping {0} because previous cutting results were found." -f $videoName)
	return $false
}

# New config shortcuts
$outputScale = $config.outputScale
$preferStreamCopy = ($null -ne $config.preferStreamCopy -and [bool]$config.preferStreamCopy)

# helper: get numeric resolution for a file (returns @{Width=..;Height=..} or $null)
function Get-Resolution($path) {
	try {
		$info = & $ffprobe -v error -select_streams v:0 -show_entries stream=width,height -of csv=p=0:s=x $path 2>$null
		if (-not $info) { return $null }
		$info = $info.Trim()
		if ($info -match '^(\d+)x(\d+)$') {
			return @{ Width = [int]$matches[1]; Height = [int]$matches[2] }
		}
		return $null
	} catch {
		return $null
	}
}

New-Item -ItemType Directory -Force -Path $outputsFolder, $logsFolder, $cutLogsFolder | Out-Null

# Find per-video cut files
$cutFiles = Get-ChildItem -Path $cutLogsFolder -Filter "*_cuts.txt" -File -ErrorAction SilentlyContinue
if (-not $cutFiles -or $cutFiles.Count -eq 0) {
	Write-Output "No per-video cuts files found in $cutLogsFolder. Run detection first."
	exit 1
}

foreach ($cutFile in $cutFiles) {
	# derive base video name from filename: "<base>_cuts.txt"
	$base = ($cutFile.BaseName -replace '_cuts$','')
	# find the source video matching base (any extension)
	$source = Get-ChildItem -Path $videosFolder -File | Where-Object { [IO.Path]::GetFileNameWithoutExtension($_.Name) -eq $base } | Select-Object -First 1
	if (-not $source) {
		Write-Warning "No source video found for cuts file $($cutFile.Name) (expected base: $base)"
		continue
	}
	$videoName = $source.Name
	$sourcePath = $source.FullName
	$logFile = Join-Path $logsFolder ("cut-$base.log")
	$shouldReprocess = Confirm-CuttingReprocess -videoName $videoName -logFilePath $logFile -cutFilePath $cutFile.FullName -outputsFolder $outputsFolder
	if (-not $shouldReprocess) {
		continue
	}
	if (Test-Path $logFile) { Remove-Item $logFile -Force -ErrorAction SilentlyContinue }
	# Ensure the per-video log file exists and is UTF-8 encoded so UI can read it reliably.
	Set-Content -Path $logFile -Value '' -Encoding utf8
	$existingOutputFiles = @(Get-ChildItem -Path $outputsFolder -File -ErrorAction SilentlyContinue | Where-Object { $_.Name -like "${base}_*" })
	# Defensive guard: consult persistent decision store and skip deleting outputs if user chose to keep.
	try {
		$decisionsPath = if ($env:CUT_VIDEO_DECISIONS_PATH) { $env:CUT_VIDEO_DECISIONS_PATH } else { 
			$cands = @()
			if ($PSScriptRoot) { $cands += (Join-Path $PSScriptRoot '.user_decisions.json') }
			try { $cwd = (Get-Location).Path ; if ($cwd) { $cands += (Join-Path $cwd '.user_decisions.json') } } catch {}
			foreach ($p in $cands) { if (Test-Path $p) { $decisionsPath = $p ; break } }
			if (-not $decisionsPath -and $PSScriptRoot) { $decisionsPath = (Join-Path $PSScriptRoot '.user_decisions.json') }
		}
		$skipDelete = $false
		if ($decisionsPath -and (Test-Path $decisionsPath)) {
			try {
				$j = Get-Content -Path $decisionsPath -Raw -ErrorAction Stop
				if (-not [string]::IsNullOrWhiteSpace($j)) {
					$obj = $j | ConvertFrom-Json -ErrorAction Stop
					$key = ("cutting:{0}" -f $base)
					if ($obj.PSObject.Properties.Name -contains $key) {
						if ($obj.$key -eq 'keep') {
							try { Add-Content -Path $logFile -Value ("DEBUG: Skipping deletion of existing outputs due to decision store key={0} path={1}" -f $key, $decisionsPath) -Encoding utf8 } catch {}
							$skipDelete = $true
						}
					}
				}
			} catch {
				try { Add-Content -Path $logFile -Value ("DEBUG: Failed reading decisions {0}: {1}" -f $decisionsPath, $_.Exception.Message) -Encoding utf8 } catch {}
			}
		}
		if (-not $skipDelete) {
			foreach ($outputFile in $existingOutputFiles) {
				try { Remove-Item -LiteralPath $outputFile.FullName -Force -ErrorAction SilentlyContinue } catch {}
			}
		}
	} catch {}

	# Read and sort timestamps. Force array semantics so single-line files do not become char-by-char strings.
	$times = @(Get-Content $cutFile.FullName | ForEach-Object { $_.ToString().Trim() } | Where-Object { $_ -match '^\d{1,2}:\d{2}:\d{2}(?:\.\d+)?$' } | Sort-Object)

	if ($times.Count -eq 0) {
		Write-Warning "No timestamps found in $($cutFile.FullName)"
		continue
	}

	# If detection produced only a starting marker, treat it as "no cut points" and keep a single full-length output.
	if ($times.Count -eq 1 -and $times[0] -match '^0{1,2}:00:00(?:\.0+)?$') {
		Write-Output "No cut points found for $videoName. Creating one output file for the full video."
	}

	# get source resolution once
	$srcRes = Get-Resolution $sourcePath

	for ($i=0; $i -lt $times.Count; $i++) {
		$start = $times[$i].Trim()
		if ($i -lt $times.Count - 1) {
			$end = $times[$i+1].Trim()
			$startTime = [TimeSpan]::Parse($start)
			$endTime = [TimeSpan]::Parse($end)
			$duration = $endTime - $startTime
			if ($duration.TotalSeconds -le 0) {
				Write-Warning "Skipping zero/negative duration segment for $base (start=$start end=$end)"
				continue
			}
			$endArg = $end
		} else {
			$endArg = $null
		}

		$ext = $source.Extension
		# If outputScale is provided, decide per-file whether to scale (only downscale)
		$willScale = $false
		$targetW = $null; $targetH = $null
		if (-not [string]::IsNullOrWhiteSpace($outputScale) -and $outputScale -match '^\s*(\d+)\s*:\s*(\d+)\s*$') {
			$targetW = [int]$matches[1]
			$targetH = [int]$matches[2]
			# only scale if source resolution is larger than target (avoid upscaling)
			if ($srcRes) {
				if ($srcRes.Width -gt $targetW -or $srcRes.Height -gt $targetH) { $willScale = $true }
			} else {
				# if we can't detect source resolution, default to scaling (safer)
				$willScale = $true
			}
		}

		$useStreamCopy = (-not $willScale) -and $preferStreamCopy
		if ($useStreamCopy) {
			# Compatibility mode: keep original codec/container by stream-copy.
			# This is fast but seeking can be less smooth when source GOPs are long.
			$outFile = Join-Path $outputsFolder ("${base}_$($i+1)$ext")
			$ffmpegArgs = @("-y", "-i", $sourcePath, "-ss", $start)
			if ($endArg) { $ffmpegArgs += @("-to", $endArg) }
			$ffmpegArgs += @("-c", "copy", $outFile)
			$ffmpegArgs = $ffmpegArgs | Where-Object { $_ -ne "" }
		} else {
			# Default mode: re-encode with regular keyframe cadence for smoother skipping.
			$outFile = Join-Path $outputsFolder ("${base}_$($i+1).mp4")
			if ($config.useCudaForCut) {
				$videoEncoder = "h264_nvenc"
				$presetArgs = @("-preset", "p7")
				$hwArgs = @("-hwaccel", "cuda")
			} else {
				$videoEncoder = "libx264"
				$presetArgs = @("-preset", "medium")
				$hwArgs = @()
			}

			$ffmpegArgs = @("-y") + $hwArgs + @("-i", $sourcePath, "-ss", $start)
			if ($endArg) { $ffmpegArgs += @("-to", $endArg) }
			if ($willScale) {
				# Use subexpression expansion so PowerShell does not parse ':' as part of a variable name.
				$vf = "scale=$($targetW):$($targetH):force_original_aspect_ratio=decrease"
				$ffmpegArgs += @("-vf", $vf)
			}
			$ffmpegArgs += @(
				"-c:v", $videoEncoder
			) + $presetArgs + @(
				"-g", "48",
				"-keyint_min", "48",
				"-sc_threshold", "0",
				"-pix_fmt", "yuv420p",
				"-movflags", "+faststart",
				"-c:a", "aac",
				"-b:a", "192k",
				$outFile
			)
			$ffmpegArgs = $ffmpegArgs | Where-Object { $_ -ne "" }
		}

		Write-Output "Creating segment $outFile from $videoName (start=$start) (scaleRequested='$outputScale' willScale=$willScale streamCopy=$useStreamCopy)"
		# run ffmpeg and capture any errors to the per-video log
		try {
			& $ffmpeg @ffmpegArgs 2>&1 | ForEach-Object { Add-Content -Path $logFile -Value $_ -Encoding utf8 }
			if ($LASTEXITCODE -ne 0) {
				Write-Warning "ffmpeg exited with code $LASTEXITCODE for segment $outFile. See $logFile"
			}
		} catch {
			# Use formatted string to avoid parsing issues with drive letters / colons in paths
			Write-Warning ("Failed to run ffmpeg for {0}: {1}" -f $outFile, $_.Exception.Message)
		}
	}

	Write-CuttingMarker -logFilePath $logFile -marker '__CUT_VIDEO_CUTTING_FINISHED__' -detail ("video={0} segments={1}" -f $base, $times.Count)
	Write-Output "Cutting completed for $videoName -> logs: $logFile"
}

Write-Output "All cutting operations completed."
exit 0
