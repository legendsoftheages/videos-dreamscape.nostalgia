#!/bin/bash
set -e

# --- 1. CONFIGURATION ---
export TMP_DIR=$(mktemp -d)
OUTPUT_DIR="./output"
export ASSETS_DIR="./assets"
mkdir -p "$OUTPUT_DIR" "$ASSETS_DIR" "$TMP_DIR/audio"

# Folder & File IDs from your Google Drive setup
export WALLPAPER_FOLDER_ID="1xbZDP8HXOnfllya7t7120pnNccq5-7h7"
export AUDIO_FOLDER_ID="1cMseGL3iBVP6y28ouZBbyeVR6sWPtSid"
export SCRATCHES_FOLDER_ID="1TcLn9ukWAdLCml0aYyPrtUcog3UnKnmn"
export SPOTIFY_FILE_ID="1fIcEuSGsSBaRWO9OsFZYCTcynhMs7XOh"
export MIN_DURATION=720  # 12 minutes
export MAX_DURATION=890  # 14 minutes 50 seconds (safe buffer under 15m)

# Check if scratches.mp4 is already saved in the GitHub repo
if [ -f "$ASSETS_DIR/scratches.mp4" ]; then
    echo "✅ Using cached $ASSETS_DIR/scratches.mp4 from repo (0 API calls)"
    export NEED_SCRATCHES_DOWNLOAD="0"
elif [ -f "./scratches/scratches.mp4" ]; then
    echo "✅ Using local ./scratches/scratches.mp4 from repo (0 API calls)"
    cp "./scratches/scratches.mp4" "$ASSETS_DIR/scratches.mp4"
    export NEED_SCRATCHES_DOWNLOAD="0"
else
    echo "☁️ Will fetch scratches.mp4 from Google Drive and save to $ASSETS_DIR/..."
    export NEED_SCRATCHES_DOWNLOAD="1"
fi

# Check if spotify.png is already saved in the GitHub repo
if [ -f "$ASSETS_DIR/spotify.png" ]; then
    echo "✅ Using cached $ASSETS_DIR/spotify.png from repo (0 API calls)"
    export NEED_SPOTIFY_DOWNLOAD="0"
else
    echo "☁️ Will fetch spotify.png from Google Drive and save to $ASSETS_DIR/..."
    export NEED_SPOTIFY_DOWNLOAD="1"
fi

echo "📥 Step 1: Fetching Oldest Wallpaper, Assets & Random Audio (<15m)..."

# --- 2. PYTHON GOOGLE DRIVE FETCHER (MINIMAL API CALLS) ---
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
download_file(wp["id"], os.path.join(tmp_dir, "wallpaper.jpg"))

with open(os.path.join(tmp_dir, "wp_name.txt"), "w") as f:
    f.write(os.path.splitext(wp["name"])[0])

# ONE-TIME DOWNLOAD: Save scratches.mp4 into ./assets/scratches.mp4
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

    if not scr_files:
        raise RuntimeError("❌ scratches.mp4 not found in Google Drive!")

    print(f"🎞️ Downloading scratches.mp4 ({scr_files[0]['id']}) to ./assets/scratches.mp4...")
    download_file(scr_files[0]["id"], os.path.join(assets_dir, "scratches.mp4"))

# ONE-TIME DOWNLOAD: Save spotify.png into ./assets/spotify.png
if need_spotify:
    spotify_dest = os.path.join(assets_dir, "spotify.png")
    downloaded_spotify = False
    try:
        print(f"🟢 Downloading spotify.png ({spotify_file_id}) to ./assets/spotify.png...")
        download_file(spotify_file_id, spotify_dest)
        downloaded_spotify = True
    except Exception:
        pass

    if not downloaded_spotify:
        sp_res = service.files().list(
            q="name contains 'spotify' and mimeType contains 'image/' and trashed=false",
            pageSize=1,
            fields="files(id, name)"
        ).execute()
        sp_files = sp_res.get("files", [])
        if not sp_files:
            raise RuntimeError("❌ spotify.png not found in Google Drive! Upload spotify.png to ./assets/spotify.png or share it in Drive.")
        print(f"🟢 Downloading {sp_files[0]['name']} ({sp_files[0]['id']}) to ./assets/spotify.png...")
        download_file(sp_files[0]["id"], spotify_dest)

# API CALL 2: List all audio files in ONE request
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
            print("✅ Reached target window (12–15 mins). Stopping downloads.")
            break
    else:
        os.remove(local_aud)
        if total_duration >= min_dur:
            break

if not selected_paths:
    raise RuntimeError("❌ Could not assemble audio tracks under 15 minutes.")

with open(os.path.join(tmp_dir, "audio_list.txt"), "w") as list_file:
    for p in selected_paths:
        list_file.write(f"file '{p}'\n")
EOF

# --- 3. MERGE AUDIO & ADD 2s AUDIO FADE IN/OUT ---
echo "🔊 Step 2: Merging selected audio tracks..."
RAW_AUDIO="$TMP_DIR/raw_audio.m4a"
MERGED_AUDIO="$TMP_DIR/merged_audio.m4a"

ffmpeg -f concat -safe 0 -i "$TMP_DIR/audio_list.txt" \
  -vn -ar 44100 -ac 2 -c:a aac -b:a 128k "$RAW_AUDIO" -y -loglevel error

DURATION=$(ffprobe -v error -show_entries format=duration -of csv=p=0 "$RAW_AUDIO")
AUDIO_FADE_START=$(awk -v d="$DURATION" 'BEGIN { printf "%.2f", (d > 2) ? d - 2 : 0 }')

ffmpeg -i "$RAW_AUDIO" \
  -af "afade=t=in:st=0:d=2,afade=t=out:st=${AUDIO_FADE_START}:d=2" \
  -c:a aac -b:a 128k "$MERGED_AUDIO" -y -loglevel error

echo "⏱️ Final Merged Audio Duration: ${DURATION}s"

# --- 4. RENDER 16:9 WALLPAPER + SCRATCHES + SPOTIFY LOGO + FADE IN/OUT ---
echo "🎬 Step 3: Blending 16:9 wallpaper, scratches.mp4, top-left Spotify logo & fades..."

# Intro is 8s so it covers the 2s video fade-in AND the Spotify logo (1s to 7s)
read INTRO_DUR MID_DUR NUM_MIDS OUTRO_DUR OUTRO_FADE_START <<< $(python3 -c "
dur = float('$DURATION')
intro = 8.0
mid = 10.0
num_mids = int((dur - intro - 4.0) // mid)
outro = round(dur - intro - (num_mids * mid), 2)
fade_start = round(max(0.1, outro - 2.0), 2)
print(f'{intro} {mid} {num_mids} {outro} {fade_start}')
")

# Pre-render 15s of 16:9 cropped wallpaper blended with scratches.mp4 (0.2 opacity)
BLENDED_MASTER="$TMP_DIR/blended_master.mp4"
ffmpeg -loop 1 -framerate 24 -i "$TMP_DIR/wallpaper.jpg" \
  -stream_loop -1 -i "$ASSETS_DIR/scratches.mp4" -t 15 \
  -filter_complex "\
    [0:v]scale=1920:1080:force_original_aspect_ratio=increase,crop=1920:1080,setsar=1,fps=24,format=yuv420p[bg];\
    [1:v]scale=1920:1080:force_original_aspect_ratio=increase,crop=1920:1080,setsar=1,fps=24,format=yuv420p[scr];\
    [bg][scr]blend=all_mode=overlay:all_opacity=0.2,format=yuv420p[v]" \
  -map "[v]" -c:v libx264 -preset veryfast -crf 20 -an "$BLENDED_MASTER" -y -loglevel error

ENC_FLAGS="-c:v libx264 -profile:v high -level:v 4.0 -preset veryfast -crf 26 -maxrate 450k -bufsize 900k -r 24 -pix_fmt yuv420p -video_track_timescale 12288 -an"

# 1. Intro segment (8s: 2s video fade-in + top-left Spotify logo fade-in at 1s and fade-out at 6s)
ffmpeg -i "$BLENDED_MASTER" -loop 1 -framerate 24 -i "$ASSETS_DIR/spotify.png" \
  -filter_complex "\
    [0:v]fade=t=in:st=0:d=2[base];\
    [1:v]scale=180:-1,format=rgba,fade=t=in:st=1:d=1:alpha=1,fade=t=out:st=6:d=1:alpha=1[logo];\
    [base][logo]overlay=x=30:y=30:enable='between(t,1,7)',format=yuv420p[outv]" \
  -map "[outv]" -t "$INTRO_DUR" $ENC_FLAGS "$TMP_DIR/intro.mp4" -y -loglevel error

# 2. Middle loop segment (10s clean blended loop)
ffmpeg -i "$BLENDED_MASTER" -t "$MID_DUR" \
  $ENC_FLAGS "$TMP_DIR/middle.mp4" -y -loglevel error

# 3. Outro segment (with 2s fade-out at the very end)
ffmpeg -i "$BLENDED_MASTER" -t "$OUTRO_DUR" \
  -vf "fade=t=out:st=${OUTRO_FADE_START}:d=2" $ENC_FLAGS "$TMP_DIR/outro.mp4" -y -loglevel error

# Build concat list for the full video duration
VIDEO_LIST="$TMP_DIR/video_list.txt"
echo "file '$TMP_DIR/intro.mp4'" > "$VIDEO_LIST"
for ((i=1; i<=NUM_MIDS; i++)); do
    echo "file '$TMP_DIR/middle.mp4'" >> "$VIDEO_LIST"
done
echo "file '$TMP_DIR/outro.mp4'" >> "$VIDEO_LIST"

WP_BASE=$(cat "$TMP_DIR/wp_name.txt" | tr -cd '[:alnum:]_-' | cut -c1-40)
OUT_FILENAME="${WP_BASE:-ambient_video}.mp4"
OUT_FILE="$OUTPUT_DIR/$OUT_FILENAME"

# Stitch video segments + merged audio without re-encoding
ffmpeg -f concat -safe 0 -i "$VIDEO_LIST" -i "$MERGED_AUDIO" \
  -map 0:v:0 -map 1:a:0 -c:v copy -c:a copy -t "$DURATION" \
  -movflags +faststart "$OUT_FILE" -y -loglevel warning

echo "✅ Video created: $OUT_FILE ($(du -h "$OUT_FILE" | cut -f1))"

# --- 5. SAVE TO GITHUB ./output AND ./assets FOLDERS ---
if [ -f "$OUT_FILE" ]; then
    echo "📤 Step 4: Saving ./assets and ./output to GitHub..."

    find "$OUTPUT_DIR" -type f ! -name "$OUT_FILENAME" -delete

    if [ -n "$GITHUB_ACTIONS" ]; then
        git config --global user.name "github-actions[bot]"
        git config --global user.email "github-actions[bot]@users.noreply.github.com"

        CURRENT_BRANCH=$(git rev-parse --abbrev-ref HEAD)
        git add "$ASSETS_DIR" "$OUTPUT_DIR"
        git commit -m "Update output video with Spotify logo & cache assets: $OUT_FILENAME" || git commit --amend --no-edit
        git push origin "$CURRENT_BRANCH" --force
    fi
fi

rm -rf "$TMP_DIR"
echo "✨ Step 3 Complete!"
