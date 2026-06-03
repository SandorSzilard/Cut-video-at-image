# Cut-video-at-image

A small automated pipeline (PowerShell + ffmpeg) that finds a reference image (logo/intro frame) inside long videos and splits each video at those points.

## Table of contents
- [Prerequisites](#prerequisites)
- [Quick start](#quick-start)
- [Configuration (config.json)](#configuration-configjson)
- [Detection (1.Detect_Image.ps1)](#detection-1detect_imagesps1)
- [Cutting (2.Cut_Video.ps1)](#cutting-2cut_videops1)
- [UI controller (ui.ps1)](#ui-controller-uips1)
- [Outputs and logs](#outputs-and-logs)
- [Troubleshooting](#troubleshooting)
- [Notes & contributing](#notes--contributing)

## Prerequisites
- Windows PowerShell (5+ / PowerShell 7 recommended).
- ffmpeg (and ffprobe) installed. Download builds at: https://ffmpeg.org/ or https://www.gyan.dev/ffmpeg/builds/ and place ffmpeg.exe/ffprobe.exe on PATH or set the full path in config.json.
- Put your source videos in the configured videosFolder (default: Videos/).

## Quick start (few steps)
1. Put videos into the Videos/ folder.
2. Edit config.json:
   - Set ffmpegPath (e.g. "ffmpeg.exe" if on PATH, or "C:\\path\\to\\ffmpeg.exe").
   - Optionally set imagesFolder (where per-video reference images are saved), outputScale, and CUDA toggles.
   - If you keep ffmpeg local in the project root, place `ffmpeg.exe`, `ffprobe.exe`, and optionally `ffplay.exe` there too.
3. Run detection:
   - Open PowerShell in the repo root and run:
     ```powershell
     .\1.Detect_Image.ps1
     ```
   - The script extracts (or uses) a reference image per video and runs detection. Per-video cut lists are written to CutLogs/{video}_cuts.txt.
4. After detection finishes you will be prompted to start cutting. Press ENTER to continue (or run .\2.Cut_Video.ps1 manually).
5. Check Outputs/ for created segments and Logs/ for per-operation logs.

## UI controller (ui.ps1)
- Run `.\ui.ps1` to open the WinForms controller.
- The top row is grouped by function: Readme, Automation, and Files.
- `Autopilot` runs detection first and then starts cutting automatically when detection finishes.
- The status area shows live ffmpeg log output, error lines in red, and a `HH:MM:SS/HH:MM:SS` progress-style time display while jobs are running.
- The progress bar tracks the current folder/file batch as detection and cutting move through the queue.
- `Open Readme` loads `README_UI.md` into the status/log window so you can review only the UI workflow and setup checklist without leaving the UI.
- The UI guide loads automatically when the window opens.
- `Open Videos` opens the configured raw videos folder.
- The `Run Detection` and `Run Cutting` buttons toggle to `Stop Detection` / `Stop Cutting` while a task is active.

## Configuration (config.json)
Key options you will commonly use:
- `ffmpegPath`: path to ffmpeg executable (required).
- `imagesFolder`: where extracted/used reference images are stored (default "Input").
- `videosFolder`: where input videos live (default "Videos").
- `outputsFolder`: where segments are written (default "Outputs").
- `logsFolder`: detection/cutting logs (default "Logs").
- `cutLogsFolder`: per-video timestamp files (default "CutLogs").
- `inputExtensions`: array of extensions to process (["mp4","mkv","mov","avi"]).
- `outputScale`: optional "W:H" (width:height) to downscale output. Example: `"1920:1080"`. Empty = keep source resolution.
- `preferStreamCopy`: optional boolean (default `false`). When `false`, cuts are re-encoded to seek-friendly MP4 output for smoother playback/forward skipping. Set `true` to restore fast stream-copy behavior.
- `useCudaForCut`: true to use NVENC when re-encoding (ensure your GPU supports it).
- `detectSsimThreshold`: legacy Structural Similarity Index (SSIM) threshold — used only if you enable SSIM-based detection. The current default detection uses blend+difference + blackframe, so this value is kept for backward compatibility.

## Detection (1.Detect_Image.ps1)
- Extracts a reference image (or uses config.referenceImage) and runs ffmpeg with blend=difference + blackframe to detect frames similar/identical to the reference.
- Produces per-video cut lists in CutLogs/{base}_cuts.txt (one timestamp per line, hh:mm:ss[.ms]).
- Saves per-video reference images in imagesFolder and per-video ffmpeg stderr logs to Logs/detect-{base}.log.

### UI notes
- The UI reads live ffmpeg logs from the per-video files above and reflects the current file and elapsed/duration time in the status bar.
- Autopilot is a UI-only orchestration feature; it does not change the standalone detection or cutting scripts.
- If no input videos are found, Autopilot will not start and the UI will report that there is nothing to process.

## Cutting (2.Cut_Video.ps1)
- Reads CutLogs/{base}_cuts.txt and creates segments for each interval between timestamps.
- Filenames are created as {base}_{index}.mp4 by default (index starts at 1).
- Default behavior re-encodes to H.264/AAC MP4 with regular keyframes for smoother seeking during playback.
- If `preferStreamCopy` is `true` and no scaling is needed, output uses fast stream-copy as {base}_{index}{ext}.
- Per-video cutting logs are in Logs/cut-{base}.log.

## Outputs and logs
- `Outputs/` — segmented video files.
- `CutLogs/` — per-video timestamp files used by the cutter.
- `Logs/` — ffmpeg stderr output for detection (detect-*.log) and cutting (cut-*.log).
- Input images are in the imagesFolder you configure.

## Troubleshooting
- ffmpeg not found: set config.ffmpegPath to the full path to ffmpeg.exe or put ffmpeg on PATH.
- No cut files created: check Logs/detect-{base}.log for ffmpeg output and verify the reference image in imagesFolder.
- "Unrecognized option 't ...'": ensure CutLogs timestamps are plain hh:mm:ss[.ms] and not embedded into one single string in the script; use the provided scripts unchanged.
- If using CUDA/NVENC, ensure drivers and ffmpeg build support it; otherwise set useCudaForCut = false.

## Tips & customization
- If logos vary slightly, you can adjust detection logic. The repo currently uses blackframe thresholding — ask to switch to SSIM or to tune thresholds.
- Add minimum segment duration, padding, or overlap in 2.Cut_Video.ps1 if you need finer control.
- To process subfolders recursively, modify Get-ChildItem calls with -Recurse.

## Contributing
- Fixes and improvements are welcome. Please fork the repository, create a feature branch, commit your changes, push to your fork, and open a pull request (PR) with a short description of the change.
- When submitting a PR:
  - Describe the problem and your fix.
  - Include relevant logs or small test cases when possible.
  - Update README or script comments if behavior changes.
  - Keep logs/output patterns stable unless intentionally changed.


