#!/bin/sh
url="https://www.tiktok.com/$1"
id=$(basename "$1")
fmt=$(yt-dlp -F "$url" 2>/dev/null | grep -E '^\S+-1 ' | grep h264 | head -1 | awk '{print $1}')
[ -z "$fmt" ] && fmt=$(yt-dlp -F "$url" 2>/dev/null | grep -E '^\S+-1 ' | head -1 | awk '{print $1}')
[ -z "$fmt" ] && exit 0
yt-dlp -q -f "$fmt" --no-warnings -o "$id.new.mp4" "$url" 2>/dev/null
ffmpeg -y -v error -i "$id.new.mp4" -ar 16000 -ac 1 "$id.wav" 2>/dev/null && mv -f "$id.new.mp4" "$id.mp4" || rm -f "$id.new.mp4"
