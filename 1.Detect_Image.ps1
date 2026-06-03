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

$ssimThreshold = if ($null -ne $config.detectSsimThreshold) { [double]$config.detectSsimThreshold } else { 1.0 }

# Ensure folders exist
New-Item -ItemType Directory -Force -Path $videosFolder, $imagesFolder, $outputsFolder, $logsFolder, $cutLogsFolder | Out-Null

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

foreach ($video in $videos) {
	$base = [IO.Path]::GetFileNameWithoutExtension($video.Name)
	$logFile = Join-Path $logsFolder ("detect-$base.log")
	$refImage = $null

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
		& $ffmpeg @extractArgs 2>> $logFile
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
	& $ffmpeg @detectArgs 2>> $logFile
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
			if ($current -ne $null) { $groups += $current }
			$current = @{ Start = $f.Frame; End = $f.Frame }
		} else {
			if ($current -ne $null) { $current.End = $f.Frame }
		}
		$prev = $f.Frame
	}
	if ($current -ne $null) { $groups += $current }

	# Write cut timestamps
	$fps = Get-Fps $video.FullName
	if (-not $fps) {
		Write-Warning ("Unable to detect FPS for {0}. Skipping timestamp conversion." -f $video.Name)
		continue
	}

	$cutFile = Join-Path $cutLogsFolder ("${base}_cuts.txt")
	if (Test-Path $cutFile) { Remove-Item $cutFile -Force }

	Write-Output ("Found {0} logo occurrence group(s) in {1}" -f $groups.Count, $video.Name)
	for ($gi = 0; $gi -lt $groups.Count; $gi++) {
		$g = $groups[$gi]
		$seconds = $g.Start / $fps
		$ts = [TimeSpan]::FromSeconds([double]$seconds)
		$tsStr = $ts.ToString('hh\:mm\:ss\.fff')
		$tsStr | Out-File -FilePath $cutFile -Append -Encoding utf8
		Write-Output ("  Group {0}: frames {1}-{2} -> {3}" -f ($gi+1), $g.Start, $g.End, $tsStr)
	}

	Write-Output ("Detection completed for {0} -> cuts: {1} ; log: {2}" -f $video.Name, $cutFile, $logFile)
}

# All videos processed. Single notification and optional automatic cutting start:
Write-Output ("Detection finished for all videos. Per-video cut files are in: {0}" -f $cutLogsFolder)
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

