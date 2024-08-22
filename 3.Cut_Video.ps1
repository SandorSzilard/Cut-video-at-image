### Options __________________________________________________________________________________________________________
$ffmpeg = ".\ffmpeg.exe"            # Set path to your ffmpeg.exe; Build Version: git-45581ed (2014-02-16)
$folder = ".\Videos\*"              # Set path to your video folder; '\*' must be appended
$filter = @("*.mp4")        # Set which file extensions should be processed

### Main Program ______________________________________________________________________________________________________

foreach ($video in dir $folder -include $filter -exclude "*_???.*" -r){

  ### Set path to logfile
  $logfile = "$($video.FullName)_ffmpeg.log"

  ### Read in all cutpoints from *_cutpoints.csv; concat to string e.g "00:03:23.014,00:06:32.289,..."  
  $cuts =  Get-Content -Path "$(Split-Path $video.FullName -leaf)_cuts.txt" -Raw

  ### put together the correct new name, "%03d" is a generic number placeholder for ffmpeg
  $output = ".\Outputs\" + $video.basename + "_%03d" + $video.extension

  ### use ffmpeg to split current video in parts according to their cut points
  & $ffmpeg -i $video -f segment -segment_times $cuts -c copy -map 0 -reset_timestamps 1 $output 2> $logfile        
}