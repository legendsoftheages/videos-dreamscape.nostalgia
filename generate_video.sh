#!/bin/bash
set -e

# --- 1. CONFIGURATION ---
export TMP_DIR=$(mktemp -d)
OUTPUT_DIR="./output"
export ASSETS_DIR="./assets"
mkdir -p "$OUTPUT_DIR" "$ASSETS_DIR" "$TMP_DIR/audio"

# Folder IDs from your Google Drive setup
export WALLPAPER_FOLDER_ID="1-_AWfRgjAYYpILzhd3RyiEN-L7ZLc9Dg"
export ARCHIVE_FOLDER_ID="190G9vBYRwQb4VqHGfmGExdjhH0phgA4t" # <--- ADD YOUR NEW ARCHIVE FOLDER ID HERE
export AUDIO_FOLDER_ID="1cMseGL3iBVP6y28ouZBbyeVR6sWPtSid"
export SCRATCHES_FOLDER_ID="1KFVM3On0ELnMAqbpaJbNdlLeI12V9Ln0"
export SPOTIFY_FILE_ID="1fIcEuSGsSBaRWO9OsFZYCTcynhMs7XOh"
export MIN_DURATION=720  # 12 minutes
export MAX_DURATION=890  # 14 minutes 50 seconds

# --- 2. ASSET CHECK & RANDOM TITLE GENERATION ---
if [ ! -f "$ASSETS_DIR/titles.txt" ]; then
    echo "❌ Error: $ASSETS_DIR/titles.txt not found! Please create this file in your repository."
    exit 1
fi

SELECTED_TITLE=$(shuf -n 1 "$ASSETS_DIR/titles.txt")
export SAFE_TITLE=$(echo "$SELECTED_TITLE" | tr ' ' '_')
echo "🏷️ Selected Title: $SELECTED_TITLE -> $SAFE_TITLE.mp4"

if [ -f "$ASSETS_DIR/scratches.mp4" ]; then export NEED_SCRATCHES_DOWNLOAD="0"; else export NEED_SCRATCHES_DOWNLOAD="1"; fi
if [ -f "$ASSETS_DIR/spotify.png" ]; then export NEED_SPOTIFY_DOWNLOAD="0"; else export NEED_SPOTIFY_DOWNLOAD="1"; fi

echo "📥 Step 1: Fetching Oldest Wallpaper & Random Audio (<15m)..."

# --- 3. PYTHON GOOGLE DRIVE FETCHER ---
python3 - << 'EOF'
import os, json, random, subprocess
from google.oauth2 import service_account
from googleapiclient.discovery import build
from googleapiclient.http import MediaIoBaseDownload

tmp_dir = os.environ["TMP_DIR"]
assets_dir = os.environ["ASSETS_DIR"]
wallpaper_folder = os.environ["WALLPAPER_FOLDER_ID"]
audio_folder = os.environ["AUDIO_FOLDER_ID"]
scratches_folder = os.environ["SCRATCHES_FOLDER_ID"]
spotify_file_id = os.environ["SPOTIFY_FILE_ID"]
need_scratches = os.environ["NEED_SCRATCHES_DOWNLOAD"] == "1"
need_spotify = os.environ["NEED_SPOTIFY_DOWNLOAD"] == "1"
min_dur = float(os.environ["MIN_DURATION"])
max_dur = float(os.environ["MAX_DURATION"])

sa_info = json.loads(os.environ["GDRIVE_SERVICE_ACCOUNT"])
creds = service_account.Credentials.from_service_account_info(
    sa_info, scopes=["https://www.googleapis.com/auth/drive"]
)
service = build("drive", "v3", credentials=creds)

def download_file(file_id, dest_path):
    request = service.files().get_media(fileId=file_id)
    with open(dest_path, "wb") as f:
        downloader = MediaIoBaseDownload(f, request)
        done = False
        while not done:
            _, done = downloader.next_chunk()

# API CALL 1: Get the single oldest wallpaper
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
download_file(wp["id"], os.path.join(tmp_dir, "wallpaper.jpg"))

with open(os.path.join(tmp_dir, "wp_id.txt"), "w") as f:
    f.write(wp["id"])

# Cache scratches.mp4
if need_scratches:
    scr_files = []
    try:
        scr_res = service.files().list(
            q=f"'{scratches_folder}' in parents and name = 'scratches.mp4' and trashed=false",
            pageSize=1,
            fields="files(id, name)"
        ).execute()
        scr_files = scr_res.get("files", [])
    except Exception:
        pass
    if not scr_files:
        scr_res = service.files().list(
            q="name = 'scratches.mp4' and trashed=false",
            pageSize=1,
            fields="files(id, name)"
        ).execute()
        scr_files = scr_res.get("files", [])
    if scr_files:
        download_file(scr_files[0]["id"], os.path.join(assets_dir, "scratches.mp4"))

# Cache spotify.png
if need_spotify:
    spotify_dest = os.path.join(assets_dir, "spotify.png")
    try:
        download_file(spotify_file_id, spotify_dest)
    except Exception:
        sp_res = service.files().list(
            q="name contains 'spotify' and mimeType contains 'image/' and trashed=false",
            pageSize=1,
            fields="files(id, name)"
        ).execute()
        sp_files = sp_res.get("files", [])
        if sp_files:
            download_file(sp_files[0]["id"], spotify_dest)

# API CALL 2: Get Audio files
aud_res = service.files().list(
    q=f"'{audio_folder}' in parents and (mimeType contains 'audio/' or name contains '.mp3') and trashed=false",
    pageSize=200,
    fields="files(id, name)"
).execute()

audio_files = aud_res.get("files", [])
if not audio_files:
    raise RuntimeError("❌ No audio files found in Google Drive folder!")

random.shuffle(audio_files)
total_duration = 0.0
selected_paths = []

for idx, aud in enumerate(audio_files):
    local_aud = os.path.join(tmp_dir, "audio", f"track_{idx}.mp3")
    download_file(aud["id"], local_aud)

    probe = subprocess.run(
        ["ffprobe", "-v", "error", "-show_entries", "format=duration", "-of", "csv=p=0", local_aud],
        capture_output=True, text=True
    )
    try:
        dur = float(probe.stdout.strip())
    except ValueError:
        os.remove(local_aud)
        continue

    if total_duration + dur <= max_dur:
        selected_paths.append(local_aud)
        total_duration += dur
        print(f"🎵 Added: {aud['name']} ({dur:.1f}s) | Running Total: {total_duration/60:.2f} mins")
        if total_duration >= min_dur:
            break
    else:
        os.remove(local_aud)
        if total_duration >= min_dur:
            break

with open(os.path.join(tmp_dir, "audio_list.txt"), "w") as list_file:
    for p in selected_paths:
        list_file.write(f"file '{p}'\n")
EOF

# --- 4. MERGE AUDIO ---
echo "🔊 Step 2: Merging audio tracks..."
RAW_AUDIO="$TMP_DIR/raw_audio.m4a"
MERGED_AUDIO="$TMP_DIR/merged_audio.m4a"

ffmpeg -f concat -safe 0 -i "$TMP_DIR/audio_list.txt" \
  -vn -ar 44100 -ac 2 -c:a aac -b:a 128k "$RAW_AUDIO" -y -loglevel error

DURATION=$(ffprobe -v error -show_entries format=duration -of csv=p=0 "$RAW_AUDIO")
AUDIO_FADE_START=$(awk -v d="$DURATION" 'BEGIN { printf "%.2f", (d > 2) ? d - 2 : 0 }')

ffmpeg -i "$RAW_AUDIO" \
  -af "afade=t=in:st=0:d=2,afade=t=out:st=${AUDIO_FADE_START}:d=2" \
  -c:a aac -b:a 128k "$MERGED_AUDIO" -y -loglevel error

# --- 5. RENDER VIDEO ---
echo "🎬 Step 3: Blending visuals..."
read INTRO_DUR MID_DUR NUM_MIDS OUTRO_DUR OUTRO_FADE_START <<< $(python3 -c "
dur = float('$DURATION')
intro = 8.0
mid = 10.0
num_mids = int((dur - intro - 4.0) // mid)
outro = round(dur - intro - (num_mids * mid), 2)
fade_start = round(max(0.1, outro - 2.0), 2)
print(f'{intro} {mid} {num_mids} {outro} {fade_start}')
")

BLENDED_MASTER="$TMP_DIR/blended_master.mp4"
ffmpeg -loop 1 -framerate 24 -i "$TMP_DIR/wallpaper.jpg" \
  -stream_loop -1 -i "$ASSETS_DIR/scratches.mp4" -t 15 \
  -filter_complex "\
    [0:v]scale=1920:1080:force_original_aspect_ratio=increase,crop=1920:1080,setsar=1,fps=24,format=yuv420p[bg];\
    [1:v]scale=1920:1080:force_original_aspect_ratio=increase,crop=1920:1080,setsar=1,fps=24,format=yuv420p[scr];\
    [bg][scr]blend=all_mode=overlay:all_opacity=0.2,format=yuv420p[v]" \
  -map "[v]" -c:v libx264 -preset veryfast -crf 20 -an "$BLENDED_MASTER" -y -loglevel error

ENC_FLAGS="-c:v libx264 -profile:v high -level:v 4.0 -preset veryfast -crf 26 -maxrate 450k -bufsize 900k -r 24 -pix_fmt yuv420p -video_track_timescale 12288 -an"

ffmpeg -i "$BLENDED_MASTER" -loop 1 -framerate 24 -i "$ASSETS_DIR/spotify.png" \
  -filter_complex "\
    [0:v]fade=t=in:st=0:d=2[base];\
    [1:v]scale=180:-1,format=rgba,fade=t=in:st=1:d=1:alpha=1,fade=t=out:st=6:d=1:alpha=1[logo];\
    [base][logo]overlay=x=30:y=30:enable='between(t,1,7)',format=yuv420p[outv]" \
  -map "[outv]" -t "$INTRO_DUR" $ENC_FLAGS "$TMP_DIR/intro.mp4" -y -loglevel error

ffmpeg -i "$BLENDED_MASTER" -t "$MID_DUR" $ENC_FLAGS "$TMP_DIR/middle.mp4" -y -loglevel error
ffmpeg -i "$BLENDED_MASTER" -t "$OUTRO_DUR" -vf "fade=t=out:st=${OUTRO_FADE_START}:d=2" $ENC_FLAGS "$TMP_DIR/outro.mp4" -y -loglevel error

VIDEO_LIST="$TMP_DIR/video_list.txt"
echo "file '$TMP_DIR/intro.mp4'" > "$VIDEO_LIST"
for ((i=1; i<=NUM_MIDS; i++)); do
    echo "file '$TMP_DIR/middle.mp4'" >> "$VIDEO_LIST"
done
echo "file '$TMP_DIR/outro.mp4'" >> "$VIDEO_LIST"

OUT_FILENAME="${SAFE_TITLE}.mp4"
OUT_FILE="$OUTPUT_DIR/$OUT_FILENAME"

ffmpeg -f concat -safe 0 -i "$VIDEO_LIST" -i "$MERGED_AUDIO" \
  -map 0:v:0 -map 1:a:0 -c:v copy -c:a copy -t "$DURATION" \
  -movflags +faststart "$OUT_FILE" -y -loglevel warning

echo "✅ Video created: $OUT_FILE ($(du -h "$OUT_FILE" | cut -f1))"

# --- 6. SAVE TO GITHUB, ARCHIVE WALLPAPER, & TRIGGER WEBHOOK ---
if [ -f "$OUT_FILE" ]; then
    echo "📤 Step 4: Saving to GitHub..."
    find "$OUTPUT_DIR" -type f ! -name "$OUT_FILENAME" -delete

    CURRENT_BRANCH=$(git rev-parse --abbrev-ref HEAD)

    if [ -n "$GITHUB_ACTIONS" ]; then
        git config --global user.name "github-actions[bot]"
        git config --global user.email "github-actions[bot]@users.noreply.github.com"
        git add "$ASSETS_DIR" "$OUTPUT_DIR"
        git commit -m "Generated video: $SELECTED_TITLE" || git commit --amend --no-edit
        git push origin "$CURRENT_BRANCH" --force
    fi

    # MOVE TO ARCHIVE INSTEAD OF TRASH
    echo "📦 Moving used wallpaper to Archive Folder..."
    python3 - << 'EOF2'
import os, json
from google.oauth2 import service_account
from googleapiclient.discovery import build

wp_id = open(os.path.join(os.environ["TMP_DIR"], "wp_id.txt")).read().strip()
archive_folder = os.environ["ARCHIVE_FOLDER_ID"]
wallpaper_folder = os.environ["WALLPAPER_FOLDER_ID"]

sa_info = json.loads(os.environ["GDRIVE_SERVICE_ACCOUNT"])
creds = service_account.Credentials.from_service_account_info(sa_info, scopes=["https://www.googleapis.com/auth/drive"])
service = build("drive", "v3", credentials=creds)

service.files().update(
    fileId=wp_id,
    addParents=archive_folder,
    removeParents=wallpaper_folder,
    fields='id, parents'
).execute()
print("✅ Wallpaper archived successfully.")
EOF2

    # Give GitHub's raw CDN 15 seconds to sync the new file before hitting Apps Script
    echo "⏳ Waiting 15 seconds for GitHub CDN to sync..."
    sleep 15

    if [ -n "$WEBHOOK_URL" ]; then
        echo "📡 Sending Webhook..."
        RAW_URL="https://raw.githubusercontent.com/${GITHUB_REPOSITORY}/${CURRENT_BRANCH}/output/${OUT_FILENAME}"
        PAYLOAD=$(cat <<EOF3
{
  "fileUrl": "$RAW_URL",
  "fileName": "$SELECTED_TITLE.mp4"
}
EOF3
)
        curl -L -X POST -H "Content-Type: application/json" -d "$PAYLOAD" "$WEBHOOK_URL"
        echo -e "\n✅ Webhook Sent!"
    fi
fi

rm -rf "$TMP_DIR"
