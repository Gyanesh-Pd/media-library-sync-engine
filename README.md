# Media Library Sync Engine

An automated, idempotent PowerShell synchronization and two-way pruning engine for managing multi-playlist local audio libraries. Driven by a centralized JSON configuration, it automates directory provisioning, high-fidelity audio extraction, metadata embedding, and local cleanup of tracks removed from upstream playlists.

---

## Key Features

* **Centralized Toggleable Configuration:** Manage dozens of playlists from a single `playlists.json` file with per-entry `enabled` flags to selectively run or skip collections without removing URLs.
* **Automated Directory Provisioning:** Dynamically creates target folders and enforces Windows-safe directory and file naming sanitization.
* **Two-Way State Reconciliation & Pruning:** Maintains isolated `track_map.json` (Track ID -> Filename) and `archive.txt` state files per folder. Automatically removes orphaned local files and updates state records when tracks are deleted from an upstream playlist.
* **Interruption & Crash Resilience:** Performs incremental JSON serialization after every processed track so `Ctrl+C` interruptions never desync state files, paired with automatic cleanup of leftover `.part` and `.ytdl` fragments.
* **High-Fidelity Audio & Metadata Pipeline:** Extracts best-available audio streams into VBR V0 MP3s (`--audio-quality 0`) with embedded ID3 tags, chapter markers, and compressed JPG cover art.
* **Duration & Content Filtering:** Filters out short-form clips and oversized mixes using configurable duration rules (`110s–700s`).
* **OS-Level Power Management:** Uses Win32 API P/Invoke (`kernel32.dll` `SetThreadExecutionState`) inside a `try/finally` block to prevent system sleep during long batch runs and guarantee power-state restoration on exit or abort.
* **Structured Observability:** Streams live color-coded progress to the console, appends full execution logs to `master_sync_log.txt`, and outputs an end-of-session summary scorecard.

---

## Repository Structure

```text
Media-Library-Sync-Engine/
├── Sync-AllPlaylists.ps1      # Main batch synchronization and two-way pruning engine
├── playlists.example.json     # Template configuration file
├── .gitignore                 # Excludes personal configs, state files, logs, and media
└── README.md                  # Project documentation
```

---

## Prerequisites

* **OS:** Windows 10 / Windows 11 (PowerShell 5.1+)
* **CLI Tools** (must be available in system `PATH`):
  * `yt-dlp` (media stream extraction)
  * `FFmpeg` (audio transcoding and ID3/artwork embedding)

Install dependencies on Windows via `winget`:
```powershell
winget install --id yt-dlp.yt-dlp
winget install --id Gyan.FFmpeg
```

---

## Quick Start

1. **Clone the repository:**
   ```powershell
   git clone [https://github.com/](https://github.com/)<your-username>/Media-Library-Sync-Engine.git
   cd Media-Library-Sync-Engine
   ```

2. **Create your local configuration:**
   Copy the example template to `playlists.json` and add your target playlist URLs:
   ```powershell
   Copy-Item playlists.example.json playlists.json
   ```
   ```json
   {
     "Deep House Mix": {
       "url": "[https://example.com/playlist?list=PLAYLIST_ID_1](https://example.com/playlist?list=PLAYLIST_ID_1)",
       "enabled": true
     },
     "Ambient Sessions": {
       "url": "[https://example.com/playlist?list=PLAYLIST_ID_2](https://example.com/playlist?list=PLAYLIST_ID_2)",
       "enabled": false
     }
   }
   ```

3. **Run the sync engine:**
   *(Ensure your browser is closed if cookie-based session authentication is enabled).*
   ```powershell
   .\Sync-AllPlaylists.ps1
   ```
   *(If local script execution is restricted on your system, run `Set-ExecutionPolicy -Scope CurrentUser RemoteSigned` once beforehand).*
