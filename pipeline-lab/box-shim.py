#!/usr/bin/env python3
"""Minimal model-box shim for the simulator demo: the one endpoint the app's
"Keep offline" needs. Production equivalent lives on the model box next to
Whisper/chat — TikTok blocks all pure-in-app stream downloads (no JS handshake
= blank playAddr; CDN 403s cookie-replayed URLs; CORS blocks in-page fetch),
so the box's yt-dlp does the fetching.

  GET /v1/tiktok/download/<video_id>  ->  video/mp4 bytes (or 502)

Run:  ./box-shim.py   (listens on 127.0.0.1:8765; simulator reaches it directly)
"""
import re
import subprocess
import tempfile
import os
from http.server import BaseHTTPRequestHandler, HTTPServer


class Handler(BaseHTTPRequestHandler):
    def do_GET(self):
        m = re.match(r"^/v1/tiktok/download/(\d{5,})$", self.path)
        if not m:
            self.send_error(404)
            return
        vid = m.group(1)
        with tempfile.TemporaryDirectory() as td:
            out = os.path.join(td, f"{vid}.mp4")
            r = subprocess.run(
                ["yt-dlp", "-q", "-f", "mp4", "-o", out, "--no-warnings",
                 f"https://www.tiktok.com/@/video/{vid}"],
                capture_output=True, timeout=120)
            if r.returncode != 0 or not os.path.exists(out):
                self.send_error(502, "yt-dlp failed")
                return
            data = open(out, "rb").read()
        self.send_response(200)
        self.send_header("Content-Type", "video/mp4")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def log_message(self, fmt, *args):
        print(f"[shim] {fmt % args}", flush=True)


if __name__ == "__main__":
    print("box-shim on http://127.0.0.1:8765 (GET /v1/tiktok/download/<id>)", flush=True)
    HTTPServer(("127.0.0.1", 8765), Handler).serve_forever()
