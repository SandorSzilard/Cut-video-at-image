 ### Options __________________________________________________________________________________________________________
$ffmpeg = ".\ffmpeg.exe"            # Set path to your ffmpeg.exe; Build Version: git-45581ed (2014-02-16)
$folder = ".\Videos\*"              # Set path to your video folder; '\*' must be appended
$filter = @("*.mp4")                # Set which file extensions should be processed
$image_base = ".\Input\test.png"    # For custom image (don't forget extension/name)

### Main Program ______________________________________________________________________________________________________

foreach ($video in dir $folder -include $filter -exclude "*_???.*, .gitkeep, .gitignore" -r){

  ### Set path to logfile
  $logfile = "$($video.FullName)_ffmpeg.log"

  # ---------- Comment this 2 lines if using custom image --------------------
  $image_output = ".\Input\" + $video.basename + ".png"
  & $ffmpeg -i $video -vf "select=eq(n\,10)" -vframes 1 $image_output >> $logfile

  # ------------------ uncomment this line if using custom image ---------------------------
  $image_output = $image_base
  
  ### analyse each video with ffmpeg and search for image
  & $ffmpeg -i $video -i $image_output -filter_complex "blend=difference:shortest=0,blackframe=99:32" -an -f null - 2>> $logfile

  ### Use regex to extract timings from logfile
  $text = @()
  Select-String 'frame:.*t:.*last_keyframe' $logfile | % { 
    $img          = "" | Select  frame, time, lastKf
    
    # extract start time of black scene
    $img.frame     = $_.line -match '(?<=frame:)\S*(?= pblack:)'    | % {$matches[0]}
    
    # extract duration of black scene
    $img.time       = $_.line -match '(?<=t:)\S*(?= type:)' | % {$matches[0]}

    $img.lastKf       = $_.line -match '(?<=last_keyframe:)\S*' | % {$matches[0]}    
    
    $text += $img

  }
  "videoName = '$(Split-Path $video.FullName -leaf)'" > ".\Scripts\js.js"

  "data =" >> ".\Scripts\js.js"

  $text | ConvertTo-Json >> ".\Scripts\js.js"

  ### Write start time, duration and the cut point for each black scene to a seperate CSV
  $text | Export-Csv -path "$($video.FullName)_cutpoints.csv" -NoTypeInformation
  

Invoke-Item "./index.html"

$Shell = New-Object -ComObject "WScript.Shell"
$Button = $Shell.Popup("SAve the output.txt in application root. After that press OK", 0, "Hello", 0)

}
powershell -executionpolicy bypass -File ./3.Cut_Video.ps1

$Shell = New-Object -ComObject "WScript.Shell"
$Button = $Shell.Popup("Press OK for next Video", 0, "Hello", 0)
