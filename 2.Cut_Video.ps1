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

	# Read and sort timestamps
	$times = Get-Content $cutFile.FullName | Where-Object { $_ -and ($_ -match '\d{1,2}:\d{2}:\d{2}') } | Sort-Object

	if ($times.Count -eq 0) {
		Write-Warning "No timestamps found in $($cutFile.FullName)"
		continue
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
			& $ffmpeg @ffmpegArgs 2>> $logFile
			if ($LASTEXITCODE -ne 0) {
				Write-Warning "ffmpeg exited with code $LASTEXITCODE for segment $outFile. See $logFile"
			}
		} catch {
			# Use formatted string to avoid parsing issues with drive letters / colons in paths
			Write-Warning ("Failed to run ffmpeg for {0}: {1}" -f $outFile, $_.Exception.Message)
		}
	}

	Write-Output "Cutting completed for $videoName -> logs: $logFile"
}

Write-Output "All cutting operations completed."
exit 0
