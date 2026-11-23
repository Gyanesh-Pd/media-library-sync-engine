# ==============================================================================
# Master Media Library Sync & Prune Engine (v1.0)
# ==============================================================================
# - Centralized JSON playlist configuration with toggleable enabled/disabled flags
# - Automatic folder creation and Windows-safe folder/file naming sanitization
# - Maximum-fidelity MP3 extraction (VBR V0) via Firefox cookies & multi-client APIs
# - Embedded ID3 metadata, chapters, and compressed JPG album cover art
# - Automated filtering to skip Shorts and tracks outside 110s–700s duration
# - Isolated archive.txt and track_map.json per playlist with instant Ctrl+C save protection
# - Two-way playlist pruning: auto-deletes local MP3s removed from online playlists
# - Automatic cleanup of orphaned .part and .ytdl fragments before each playlist run
# - Built-in Windows sleep prevention during execution with automatic power state restoration
# - Live terminal progress output, master_sync_log.txt logging, and end-of-run scorecard
# ==============================================================================

# Load Windows Kernel32 API to prevent system sleep during execution
$SleepControl = Add-Type -MemberDefinition @"
[DllImport("kernel32.dll", CharSet = CharSet.Auto, SetLastError = true)]
public static extern uint SetThreadExecutionState(uint esFlags);
"@ -Name "Win32Sleep" -Namespace "PowerUtils" -PassThru

$ES_CONTINUOUS       = [uint32]"0x80000000"
$ES_SYSTEM_REQUIRED  = [uint32]"0x00000001"

$BaseDir = $PSScriptRoot
if ([string]::IsNullOrWhiteSpace($BaseDir)) { $BaseDir = Get-Location }

$ConfigFile = Join-Path $BaseDir "playlists.json"
$MasterLog  = Join-Path $BaseDir "master_sync_log.txt"

function Write-Log {
    param([string]$Message, [string]$Color = "White")
    $Timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $Formatted = "[$Timestamp] $Message"
    Write-Host $Formatted -ForegroundColor $Color
    Add-Content -Path $MasterLog -Value $Formatted -Encoding UTF8
}

function Save-TrackMap {
    param([hashtable]$Map, [string]$Path)
    if ($Map.Count -eq 0) {
        Set-Content -Path $Path -Value "{}" -Encoding UTF8
    } else {
        $Map | ConvertTo-Json -Depth 2 | Set-Content -Path $Path -Encoding UTF8
    }
}

if (-not (Test-Path $ConfigFile)) {
    Write-Log "ERROR: playlists.json not found in $BaseDir" "Red"
    exit 1
}

try {
    $Playlists = Get-Content -Path $ConfigFile -Raw -Encoding UTF8 | ConvertFrom-Json
} catch {
    Write-Log "ERROR: Invalid JSON syntax in playlists.json. Check for missing/extra commas." "Red"
    exit 1
}

$Stats = @{
    ProcessedPlaylists = 0
    SkippedPlaylists   = 0
    FailedPlaylists    = 0
    NewDownloads       = 0
    PrunedTracks       = 0
}

try {
    # Prevent laptop from sleeping while script runs (display can still turn off to save battery/screen)
    [void]$SleepControl::SetThreadExecutionState($ES_CONTINUOUS -bor $ES_SYSTEM_REQUIRED)
    Write-Log "System sleep temporarily disabled for sync session." "DarkGray"

    Write-Log "======================================================================" "Cyan"
    Write-Log "Starting Master Playlist Sync Session" "Cyan"
    Write-Log "======================================================================" "Cyan"

    foreach ($Property in $Playlists.PSObject.Properties) {
        $RawFolderName = $Property.Name.Trim()
        $FolderName    = $RawFolderName -replace '[\\/:*?"<>|]', '_'
        $Entry         = $Property.Value
        $Url           = $Entry.url
        $Enabled       = $Entry.enabled

        if (-not $Enabled) {
            Write-Log "SKIPPING [$FolderName] (enabled = false)" "DarkGray"
            $Stats.SkippedPlaylists++
            continue
        }

        if ([string]::IsNullOrWhiteSpace($Url)) {
            Write-Log "WARNING: Empty URL for [$FolderName]. Skipping." "Yellow"
            $Stats.FailedPlaylists++
            continue
        }

        Write-Log "`n>>> Processing Playlist: [$FolderName]" "Green"

        # 1. Create or verify target subfolder & clean leftover partial downloads
        $TargetDir = Join-Path $BaseDir $FolderName
        if (-not (Test-Path $TargetDir)) {
            New-Item -ItemType Directory -Path $TargetDir | Out-Null
            Write-Log "Created new folder: $TargetDir" "Cyan"
        }

        Get-ChildItem -Path $TargetDir -Include *.part, *.ytdl -File -ErrorAction SilentlyContinue | Remove-Item -Force -ErrorAction SilentlyContinue

        $ArchiveFile  = Join-Path $TargetDir "archive.txt"
        $TrackMapFile = Join-Path $TargetDir "track_map.json"
        $OutputTpl    = Join-Path $TargetDir "%(title)s.%(ext)s"

        # Load existing VideoID -> Filename mapping
        $TrackMap = @{}
        if (Test-Path $TrackMapFile) {
            try {
                $LoadedJson = Get-Content -Path $TrackMapFile -Raw -Encoding UTF8 | ConvertFrom-Json
                if ($null -ne $LoadedJson) {
                    foreach ($p in $LoadedJson.PSObject.Properties) {
                        $TrackMap[$p.Name] = $p.Value
                    }
                }
            } catch {
                Write-Log "Warning: Could not parse existing track_map.json in [$FolderName]. Rebuilding map." "Yellow"
            }
        }

        # 2. Fetch unique live Video IDs from the playlist
        Write-Log "Fetching live tracklist from YouTube..." "Gray"
        $LiveIdsRaw = & yt-dlp --cookies-from-browser firefox `
                               --flat-playlist `
                               --ignore-errors `
                               --no-warnings `
                               --print id `
                               "$Url" 2>$null

        $LiveIds = @($LiveIdsRaw | Where-Object { $_ -match '^[a-zA-Z0-9_-]{11}$' } | Select-Object -Unique)

        if ($LiveIds.Count -eq 0) {
            Write-Log "WARNING: Could not retrieve live track IDs for [$FolderName] (network issue, private playlist, or cookie lock). Skipping prune & download for safety." "Yellow"
            $Stats.FailedPlaylists++
            continue
        }

        Write-Log "Found $($LiveIds.Count) active tracks in online playlist." "Gray"

        # 3. Run full production yt-dlp download & save ID -> File mapping incrementally
        Write-Log "Syncing new tracks..." "Cyan"
        $PrintHook = "after_move:TRACKMAP|%(id)s|%(filepath)s"

        & yt-dlp --cookies-from-browser firefox `
                 --extractor-args "youtube:player_client=web_safari,web_embedded,-tv_downgraded" `
                 -f "ba/b" `
                 -x `
                 --audio-format mp3 `
                 --audio-quality 0 `
                 --embed-metadata `
                 --embed-thumbnail `
                 --convert-thumbnails jpg `
                 --embed-chapters `
                 --windows-filenames `
                 --no-overwrites `
                 --ignore-errors `
                 --retries 5 `
                 --fragment-retries 10 `
                 --sleep-interval 2 `
                 --match-filters "original_url!*=/shorts/ & duration >= 110 & duration <= 700" `
                 --download-archive "$ArchiveFile" `
                 --print "$PrintHook" `
                 -o "$OutputTpl" `
                 "$Url" 2>&1 | ForEach-Object {
                     $Line = $_.ToString()
                     if ($Line -match '^TRACKMAP\|([a-zA-Z0-9_-]{11})\|(.+)$') {
                         $VidId    = $Matches[1]
                         $FullPath = $Matches[2]
                         $FileName = Split-Path -Path $FullPath -Leaf
                         $TrackMap[$VidId] = $FileName

                         Save-TrackMap -Map $TrackMap -Path $TrackMapFile

                         $Stats.NewDownloads++
                         Write-Log "Mapped & Saved: [$VidId] -> $FileName" "DarkCyan"
                     } else {
                         Write-Host $Line
                         Add-Content -Path $MasterLog -Value $Line -Encoding UTF8
                     }
                 }

        # 4. Prune local tracks that were removed from the YouTube playlist
        $RemovedIds = @()
        foreach ($TrackedId in @($TrackMap.Keys)) {
            if ($LiveIds -notcontains $TrackedId) {
                $RemovedIds += $TrackedId
            }
        }

        if ($RemovedIds.Count -gt 0) {
            Write-Log "Detected $($RemovedIds.Count) track(s) removed from online playlist. Pruning locally..." "Yellow"
            foreach ($DeadId in $RemovedIds) {
                $DeadFileName = $TrackMap[$DeadId]
                $DeadFilePath = Join-Path $TargetDir $DeadFileName

                if (Test-Path -LiteralPath $DeadFilePath) {
                    Remove-Item -LiteralPath $DeadFilePath -Force
                    $Stats.PrunedTracks++
                    Write-Log "DELETED local file: $DeadFileName" "Red"
                } else {
                    Write-Log "File already missing on disk: $DeadFileName" "DarkGray"
                }

                if (Test-Path $ArchiveFile) {
                    $ArchiveLines = Get-Content -Path $ArchiveFile | Where-Object { $_ -notmatch "\b$DeadId\b" }
                    Set-Content -Path $ArchiveFile -Value $ArchiveLines -Encoding UTF8
                }

                $TrackMap.Remove($DeadId)
            }
        } else {
            Write-Log "No tracks removed since last sync." "Gray"
        }

        # Final save of track_map.json for this playlist
        Save-TrackMap -Map $TrackMap -Path $TrackMapFile
        $Stats.ProcessedPlaylists++
        Write-Log "<<< Finished [$FolderName]" "Green"
    }

    Write-Log "`n======================================================================" "Cyan"
    Write-Log "SYNC COMPLETE SUMMARY" "Cyan"
    Write-Log "Playlists Processed : $($Stats.ProcessedPlaylists)" "Green"
    Write-Log "Playlists Skipped   : $($Stats.SkippedPlaylists)" "DarkGray"
    Write-Log "Playlists Failed    : $($Stats.FailedPlaylists)" $(if ($Stats.FailedPlaylists -gt 0) { "Yellow" } else { "Gray" })
    Write-Log "New Tracks Added    : $($Stats.NewDownloads)" "Cyan"
    Write-Log "Removed Tracks Cut  : $($Stats.PrunedTracks)" $(if ($Stats.PrunedTracks -gt 0) { "Red" } else { "Gray" })
    Write-Log "======================================================================" "Cyan"
}
finally {
    # Always restore normal Windows sleep settings when script ends or is cancelled
    [void]$SleepControl::SetThreadExecutionState($ES_CONTINUOUS)
    Write-Log "Normal Windows sleep settings restored." "DarkGray"
}
