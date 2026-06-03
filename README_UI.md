# UI Guide

## Before running
- Put `ffmpeg.exe`, `ffprobe.exe`, and optionally `ffplay.exe` in the project root or make them available on PATH.
- Put your source videos in the `Videos/` folder.
- Edit `config.json` if needed:
  - `ffmpegPath` should point to `ffmpeg.exe` if it is not on PATH.
  - `imagesFolder`, `outputScale`, and `preferStreamCopy` are optional.

## Buttons
- `Run Detection`: runs the detection script for the videos in `Videos/`.
- `Run Cutting`: runs the cutting script using the timestamp files in `CutLogs/`.
- `Autopilot`: runs detection first and then starts cutting automatically when detection finishes.
- `Open Readme`: shows this UI guide in the status/log window.
- `Edit config.json`: opens the configuration file in Notepad.
- `Open Outputs`: opens the output folder.
- `Open Logs`: opens the logs folder.

## Status area
- The bottom window shows live ffmpeg output.
- Error lines are shown in red.
- While a job is running, the status bar shows the current file and `HH:MM:SS/HH:MM:SS` timing when available.
- The progress bar shows the current batch progress.
- `Run Detection` / `Run Cutting` change to `Stop Detection` / `Stop Cutting` while active.

## Notes
- If there are no input videos, Autopilot will not start.
- The standalone scripts still work without the UI.
