### Options __________________________________________________________________________________________________________
$ffmpeg = ".\ffmpeg.exe"            # Set path to your ffmpeg.exe
$folder = ".\Videos\*"              # Set path to your video folder; '\*' must be appended
$filter = @("*.mp4")                # Set which file extensions should be processed
$enable_cuda = $true                # Enable processing on GPU
$enable_scaling = $true;            # Enable downscaling of video (if applicable)

if ($enable_scaling) {             # !!! Only active when scaling is activated !!!!
  $max_width = 1920                 # Set the max width to scale to (if resolution of video is bigger), ex. 1920, 1080
  $ffprobe = ".\ffprobe.exe"       # Set path to your ffprobe.exe
}

### Main Program ______________________________________________________________________________________________________

foreach ($video in dir $folder -include $filter -exclude "*_???.*, .gitkeep, .gitignore" -r) {

  ### Set path to logfile
  $logfile = "$($video.FullName)_ffmpeg_cut.log"

  ### Read in all cutpoints from *_cutpoints.csv; concat to string e.g "00:03:23.014,00:06:32.289,..."  
  $cuts = Get-Content -Path "$(Split-Path $video.FullName -leaf)_cuts.txt" -Raw

  ### put together the correct new name, "%03d" is a generic number placeholder for ffmpeg
  $output = ".\Outputs\" + $video.basename + "_%03d" + $video.extension

  if ($enable_scaling) {
    $width_str = & $ffprobe -v error -select_streams v:0 -show_entries stream=width -of default=nw=1:nk=1 $video
    $width = [int]$width_str

    if ($width -gt $max_width) {
        & $ffmpeg -i $video -vf "scale=${max_width}:-2" -f segment -segment_times $cuts -c:v libx264 -preset slow -crf 18 -c:a copy -map 0 -reset_timestamps 1 $output 2> $logfile      
    }
    else {
      #regular conversion
      if ($enable_cuda) {
        & $ffmpeg -hwaccel cuda -i $video -f segment -segment_times $cuts -c copy -map 0 -reset_timestamps 1 $output 2> $logfile        
      }
      else {
        & $ffmpeg -i $video -f segment -segment_times $cuts -c copy -map 0 -reset_timestamps 1 $output 2> $logfile        
      }
    }

  }
  else {
    ### use ffmpeg to split current video in parts according to their cut points
    if ($enable_cuda) {
      & $ffmpeg -hwaccel cuda -i $video -f segment -segment_times $cuts -c copy -map 0 -reset_timestamps 1 $output 2> $logfile        
    }
    else {
      & $ffmpeg -i $video -f segment -segment_times $cuts -c copy -map 0 -reset_timestamps 1 $output 2> $logfile        
    }
  }
}

$Shell = New-Object -ComObject "WScript.Shell"
$Button = $Shell.Popup("Finished", 0, "Hello", 0)