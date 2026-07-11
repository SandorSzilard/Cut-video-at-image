# Cut-video-at-image — AI Agent Guide

This repository provides an automated video splitting pipeline using PowerShell and ffmpeg.
It detects reference images in long videos, generates cut timestamps, and splits videos into segments.

## Purpose
- Provide a concise, agent-friendly summary of repository behavior.
- Describe the core scripts, UI controls, and cleanup options.
- Help automation tooling understand the project quickly.

## Core workflow
1. Ensure ffmpeg.exe and ffprobe.exe are available on PATH or configured in config.json.
2. Place source videos in Videos/.
3. Run 1.Detect_Image.ps1 to generate detection output and cut timestamps.
4. If a matching CutLogs/{video}_cuts.txt file already exists, the script prompts whether to keep the previous results or reprocess them; the choice is saved in .user_decisions.json.
5. Run 2.Cut_Video.ps1 to create segmented video files in Outputs/.
6. Optionally run ui.ps1 for a WinForms controller with live progress and cleanup.

## Main files
- 1.Detect_Image.ps1 — detection script that creates per-video cut timestamp files in CutLogs/.
- 2.Cut_Video.ps1 — cutting script that produces segments into Outputs/.
- ui.ps1 — UI controller with job orchestration and cleanup prompts.
- config.json — configuration for paths, ffmpeg, input/output folders, and feature flags.
- README_UI.md — UI-specific workflow guide.

## UI controls for automation
- Run Detection: start detection for configured input videos.
- Run Cutting: start cut processing from timestamp files.
- Autopilot: run detection then cutting automatically.
- Clean: prompts whether to preserve raw videos or delete videos too.
- Open Readme: display README_UI.md in the UI log window.

## Configuration overview
- ffmpegPath: path to ffmpeg.exe.
- videosFolder: input video folder.
- outputsFolder: output segment folder.
- logsFolder: generated logs folder.
- cutLogsFolder: timestamp file folder.
- imagesFolder: reference image storage folder.

## Privacy and cleanup
- The repo ignores media folders such as Input/, Videos/, and Outputs/.
- The Clean button offers two options:
  - preserve raw videos and remove generated logs, outputs, and input images
  - delete videos too

## Usage note
- Use README.md for full setup and troubleshooting.
- Use README_UI.md for UI-specific instructions.
- Use README_AI.md as a short, agent-friendly repository summary.
