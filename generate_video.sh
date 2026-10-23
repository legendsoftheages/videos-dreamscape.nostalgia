#!/bin/bash
set -e

# --- 1. CONFIGURATION ---
export TMP_DIR=$(mktemp -d)
OUTPUT_DIR="./output"
mkdir -p "$OUTPUT_DIR" "$TMP_DIR/audio"

# Folder IDs from your Google Drive setup
export WALLPAPER_FOLDER_ID="1xbZDP8HXOnfllya7t7120pnNccq5-7h7"
export AUDIO_FOLDER_ID="1cMseGL3iBVP6y28ouZBbyeVR6sWPtSid"
export MIN_DURATION=720  # 12 minutes
export MAX_DURATION=890  # 14 minutes 50 seconds (safe buffer under 15m)

echo "📥 Step 1: Fetching Oldest Wallpaper & Random Audio (<15m) with minimal API calls..."

# --- 2. PYTHON GOOGLE DRIVE FETCHER (MINIMAL API CALLS) ---
python3 - << 'EOF'
import os, json, random, subprocess
from google.oauth2 import service_account
from googleapiclient.discovery import build
from googleapiclient.http import MediaIoBaseDownload

tmp_dir = os.environ["TMP_DIR"]
wallpaper_folder = os.environ["WALLPAPER_FOLDER_ID"]
audio_folder = os.environ["AUDIO_FOLDER_ID"]
min_dur = float(os.environ["MIN_DURATION"])
max_dur = float(os.environ["MAX_DURATION"])

# Authenticate using GitHub Secret GDRIVE_SERVICE_ACCOUNT
sa_info = json.loads(os.environ["GDRIVE_SERVICE_ACCOUNT"])
creds = service_account.Credentials.from_service_account_info(
    sa_info, scopes=["https://www.googleapis.com/auth/drive.readonly"]
)
service = build("drive", "v3", credentials=creds)

def download_file(file_id, dest_path):
    request = service.files().get_media(fileId=file_id)
    with open(dest_path, "wb") as f:
        downloader = MediaIoBaseDownload(f, request)
        done = False
        while not done:
            _, done = downloader.next_chunk()

# API CALL 1: Get the single oldest wallpaper (createdTime asc)
wp_res = service.files().list(
    q=f"'{wallpaper_folder}' in parents and mimeType contains 'image/' and trashed=false",
    orderBy="createdTime asc",
    pageSize=1,
    fields="files(id, name)"
).execute()

wp_files = wp_res.get("files", [])
if not wp_files:
    raise RuntimeError("❌ No wallpaper found in Google Drive folder!")

wp = wp_files[0]
print(f"🖼️ Oldest Wallpaper: {wp['name']} ({wp['id']})")
wp_path = os.path.join(tmp_dir, "wallpaper.jpg")
download_file(wp["id"], wp_path)

with open(os.path.join(tmp_dir, "wp_name.txt"), "w") as f:
    f.write(os.path.splitext(wp["name"])[0])

# API CALL 2: List all audio files in ONE request
aud_res = service.files().list(
    q=f"'{audio_folder}' in parents and (mimeType contains 'audio/' or name contains '.mp3') and trashed=false",
    pageSize=200,
    fields="files(id, name)"
).execute()

audio_files = aud_res.get("files", [])
if not audio_files:
    raise RuntimeError("❌ No audio files found in Google Drive folder!")

# Shuffle in memory (0 extra API calls)
random.shuffle(audio_files)

total_duration = 0.0
selected_paths = []

for idx, aud in enumerate(audio_files):
    local_aud = os.path.join(tmp_dir, "audio", f"track_{idx}.mp3")
    download_file(aud["id"], local_aud)

    # Probe track duration locally
    probe = subprocess.run(
        ["ffprobe", "-v", "error", "-show_entries", "format=duration", "-of", "csv=p=0", local_aud],
        capture_output=True, text=True
    )
    try:
        dur = float(probe.stdout.strip())
    except ValueError:
        os.remove(local_aud)
        continue

    # Check if adding this track stays under 14m50s (890s)
    if total_duration + dur <= max_dur:
        selected_paths.append(local_aud)
        total_duration += dur
        print(f"🎵 Added: {aud['name']} ({dur:.1f}s) | Running Total: {total_duration/60:.2f} mins")
        if total_duration >= min_dur:
            print("✅ Reached target window (12–15 mins). Stopping downloads.")
            break
    else:
        os.remove(local_aud)
        if total_duration >= min_dur:
            break

if not selected_paths:
    raise RuntimeError("❌ Could not assemble audio tracks under 15 minutes.")

# Write normalized audio concat list
with open(os.path.join(tmp_dir, "audio_list.txt"), "w") as list_file:
    for p in selected_paths:
        list_file.write(f"file '{p}'\n")
EOF

# --- 3. MERGE AUDIO & NORMALIZE ---
echo "🔊 Step 2: Merging selected audio tracks..."
MERGED_AUDIO="$TMP_DIR/merged_audio.m4a"

ffmpeg -f concat -safe 0 -i "$TMP_DIR/audio_list.txt" \
  -vn -ar 44100 -ac 2 -c:a aac -b:a 192k "$MERGED_AUDIO" -y -loglevel error

DURATION=$(ffprobe -v error -show_entries format=duration -of csv=p=0 "$MERGED_AUDIO")
echo "⏱️ Final Merged Audio Duration: ${DURATION}s"

# --- 4. ULTRA-FAST 16:9 VIDEO RENDER (2-SECOND BASE LOOP + STREAM COPY) ---
echo "🎬 Step 3: Auto-cropping wallpaper to 16:9 & muxing video..."
BASE_LOOP="$TMP_DIR/base_loop.mp4"

# Encode only 2 seconds of 16:9 1080p video from the static wallpaper
ffmpeg -loop 1 -framerate 1 -i "$TMP_DIR/wallpaper.jpg" -t 2 \
  -vf "scale=1920:1080:force_original_aspect_ratio=increase,crop=1920:1080,setsar=1,format=yuv420p" \
  -c:v libx264 -preset veryfast -tune stillimage -crf 24 -g 1 -an "$BASE_LOOP" -y -loglevel error

WP_BASE=$(cat "$TMP_DIR/wp_name.txt" | tr -cd '[:alnum:]_-' | cut -c1-40)
OUT_FILENAME="${WP_BASE:-ambient_video}.mp4"
OUT_FILE="$OUTPUT_DIR/$OUT_FILENAME"

# Stream-copy the 2-second video loop across the entire audio length (completes in ~2 seconds)
ffmpeg -stream_loop -1 -i "$BASE_LOOP" -i "$MERGED_AUDIO" \
  -map 0:v:0 -map 1:a:0 -c:v copy -c:a copy -t "$DURATION" \
  -movflags +faststart "$OUT_FILE" -y -loglevel warning

echo "✅ Video created: $OUT_FILE ($(du -h "$OUT_FILE" | cut -f1))"

# --- 5. SAVE TO GITHUB ./output FOLDER ---
if [ -f "$OUT_FILE" ]; then
    echo "📤 Step 4: Saving to GitHub ./output folder..."

    # Remove old videos in ./output so repo stays small
    find "$OUTPUT_DIR" -type f ! -name "$OUT_FILENAME" -delete

    if [ -n "$GITHUB_ACTIONS" ]; then
        git config --global user.name "github-actions[bot]"
        git config --global user.email "github-actions[bot]@users.noreply.github.com"

        CURRENT_BRANCH=$(git rev-parse --abbrev-ref HEAD)
        git add "$OUTPUT_DIR"
        git commit -m "Update output video: $OUT_FILENAME" || git commit --amend --no-edit
        git push origin "$CURRENT_BRANCH" --force
    fi
fi

rm -rf "$TMP_DIR"
echo "✨ Step 1 Test Complete!"
