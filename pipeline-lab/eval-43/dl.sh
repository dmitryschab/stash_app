#!/bin/sh
url="https://www.tiktok.com/$1"
id=$(basename "$1")
yt-dlp -q -f mp4 -o "$id.mp4" --no-warnings "$url" 2>/dev/null && ffmpeg -y -v error -i "$id.mp4" -ar 16000 -ac 1 "$id.wav" 2>/dev/null
