import io
import subprocess
import sys
import threading
import wave
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

audio = io.BytesIO()
with wave.open(audio, "wb") as writer:
    writer.setnchannels(1)
    writer.setsampwidth(2)
    writer.setframerate(8000)
    writer.writeframes(b"\x00\x00" * 8000)
payload = audio.getvalue()
requests = []


class Handler(BaseHTTPRequestHandler):
    def log_message(self, *args):
        pass

    def do_HEAD(self):
        self.respond(False)

    def do_GET(self):
        self.respond(True)

    def respond(self, body):
        browser = "Safari/605.1.15" in self.headers.get("User-Agent", "")
        cookie = "moyu-network-check=fixture" in self.headers.get("Cookie", "")
        no_referrer = not self.headers.get("Referer")
        allowed = browser and cookie and no_referrer
        requests.append((browser, cookie, no_referrer, allowed))
        if not allowed:
            self.send_response(403)
            self.send_header("Content-Length", "0")
            self.end_headers()
            return
        path = self.path.split("?", 1)[0]
        content = payload
        content_type = "audio/wav"
        if path == "/web.html":
            content = b'<iframe src="/web-frame.html"></iframe>'
            content_type = "text/html"
        elif path == "/web-frame.html":
            content = b'<script>setTimeout(() => {document.cookie="moyu-web-check=fresh; Path=/"; fetch("/fresh.m3u8?token=web%2Bsignature").catch(() => {});}, 200)</script>'
            content_type = "text/html"
        elif path == "/fresh.m3u8":
            content = b"#EXTM3U\n#EXT-X-ENDLIST\n"
            content_type = "application/vnd.apple.mpegurl"
        elif path == "/play.html":
            content = f'<script>var player_aaaa={{"encrypt":0,"url":"http://127.0.0.1:{self.server.server_port}/denied.m3u8"}}</script>'.encode()
            content_type = "text/html"
        elif path == "/denied.m3u8":
            self.send_response(403)
            self.send_header("Content-Length", "0")
            self.end_headers()
            return
        elif path == "/master.m3u8":
            content = b'#EXTM3U\n#EXT-X-STREAM-INF:BANDWIDTH=800000\nredirect/variant.m3u8?token=fixture-token\n'
            content_type = "application/vnd.apple.mpegurl"
        elif path == "/redirect/variant.m3u8":
            self.send_response(302)
            self.send_header("Location", "/hls/variant.m3u8?token=fixture-token")
            self.send_header("Content-Length", "0")
            self.end_headers()
            return
        elif path == "/hls/variant.m3u8":
            content = b'#EXTM3U\n#EXT-X-KEY:METHOD=AES-128,URI="key.bin?token=fixture-token"\n#EXT-X-MAP:URI="init.mp4?token=fixture-token"\n#EXTINF:1,\nsegment.ts?token=fixture-token\n#EXT-X-ENDLIST\n'
            content_type = "application/vnd.apple.mpegurl"
        elif path in ("/hls/key.bin", "/hls/init.mp4", "/hls/segment.ts"):
            assert "token=fixture-token" in self.path, "Upstream signed query lost"
            content = b"0123456789"
            content_type = "application/octet-stream"
        elif path != "/audio.wav":
            self.send_response(404)
            self.send_header("Content-Length", "0")
            self.end_headers()
            return
        start, end = 0, len(content) - 1
        byte_range = self.headers.get("Range", "")
        if byte_range.startswith("bytes="):
            lower, upper = byte_range[6:].split("-", 1)
            start = int(lower) if lower else 0
            end = min(end, int(upper)) if upper else end
        self.send_response(206 if byte_range else 200)
        self.send_header("Content-Type", content_type)
        self.send_header("Referrer-Policy", "no-referrer")
        self.send_header("Accept-Ranges", "bytes")
        self.send_header("Content-Length", str(end - start + 1))
        if byte_range:
            self.send_header("Content-Range", f"bytes {start}-{end}/{len(content)}")
        self.end_headers()
        if body:
            self.wfile.write(content[start:end + 1])


server = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
worker = threading.Thread(target=server.serve_forever, daemon=True)
worker.start()
try:
    result = subprocess.run([sys.argv[1], f"http://127.0.0.1:{server.server_port}/audio.wav"], timeout=90)
    assert result.returncode == 0, "Media HTTP fixture failed"
    assert any(not row[3] for row in requests), "Missing rejected baseline request"
    assert any(all(row) for row in requests), "Missing browser-compatible request without Referer"
    print("PASS: baseline rejected; configured request accepted, no Referer")
finally:
    server.shutdown()
    server.server_close()
