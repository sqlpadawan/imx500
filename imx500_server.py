#!/usr/bin/env python3
"""
imx500_server.py — Always-on HTTP and WebSocket server for the IMX500 street monitor.

Runs as a standalone systemd service (imx500_server.service) that starts at boot
and stays up 24/7. Serves:
  - /               Live view page (WebSocket canvas)
  - /dashboard      Event log summary dashboard
  - /summary.json   Raw summary data
  - ws://:8080/     WebSocket frame stream

Frames arrive from imx500_capture.py via a Unix domain socket at
/tmp/imx500_frames.sock. When the capture script is not running the frame
buffer is empty and the live view shows "waiting for camera..." until sunrise.

Usage:
    Called by systemd — not intended for direct invocation.
    To test manually: ~/imx500_venv/bin/python3 imx500_server.py
"""

import asyncio
import socket
import struct
import threading
import time
from http.server import BaseHTTPRequestHandler, HTTPServer
from pathlib import Path

import websockets

# ── Config ────────────────────────────────────────────────────────────────────
WS_PORT        = 8080
HTTP_PORT      = 8081
FRAME_SOCKET   = Path("/tmp/imx500_frames.sock")
LOG_DIR        = Path("/var/log/imx500")

# ── Shared frame buffer ───────────────────────────────────────────────────────
_latest_jpeg      = None
_latest_jpeg_lock = threading.Lock()
_last_frame_time  = 0.0          # monotonic — used to detect camera offline


def set_frame(jpeg_bytes: bytes) -> None:
    global _latest_jpeg, _last_frame_time
    with _latest_jpeg_lock:
        _latest_jpeg      = jpeg_bytes
        _last_frame_time  = time.monotonic()


def get_frame() -> bytes | None:
    with _latest_jpeg_lock:
        return _latest_jpeg


def camera_is_live() -> bool:
    """True if a frame arrived within the last 5 seconds."""
    with _latest_jpeg_lock:
        return (time.monotonic() - _last_frame_time) < 5.0


# ── Unix socket frame receiver ────────────────────────────────────────────────
def _recv_exactly(conn: socket.socket, n: int) -> bytes | None:
    """Read exactly n bytes from a socket, or return None on EOF/error."""
    buf = b""
    while len(buf) < n:
        try:
            chunk = conn.recv(n - len(buf))
        except OSError:
            return None
        if not chunk:
            return None
        buf += chunk
    return buf


def frame_receiver() -> None:
    """
    Listens on FRAME_SOCKET for JPEG frames sent by imx500_capture.py.

    Wire format (little-endian):
        4 bytes  — uint32 payload length
        N bytes  — JPEG data
    """
    sock_path = str(FRAME_SOCKET)

    # Remove stale socket file if it exists from a previous run
    FRAME_SOCKET.unlink(missing_ok=True)

    server_sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    server_sock.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    server_sock.bind(sock_path)
    server_sock.listen(1)
    print(f"[server] Frame socket listening at {sock_path}")

    while True:
        try:
            conn, _ = server_sock.accept()
            print("[server] Capture script connected")
            with conn:
                while True:
                    header = _recv_exactly(conn, 4)
                    if header is None:
                        break
                    (length,) = struct.unpack("<I", header)
                    if length == 0 or length > 10_000_000:   # sanity check (10 MB max)
                        break
                    payload = _recv_exactly(conn, length)
                    if payload is None:
                        break
                    set_frame(payload)
            print("[server] Capture script disconnected")
        except OSError as e:
            print(f"[server] Frame socket error: {e}")
            time.sleep(1)


# ── HTML pages ────────────────────────────────────────────────────────────────
def _make_live_html(local_ip: str) -> bytes:
    return f"""<!DOCTYPE html>
<html>
<head>
  <title>IMX500 Live Stream</title>
  <style>
    body   {{ background:#111; display:flex; flex-direction:column;
             align-items:center; justify-content:center; height:100vh; margin:0; }}
    h2     {{ color:#eee; font-family:sans-serif; margin-bottom:12px; }}
    canvas {{ max-width:100%; border:2px solid #444; border-radius:6px; }}
    #status {{ color:#888; font-family:monospace; font-size:0.8em; margin-top:8px; }}
  </style>
</head>
<body>
  <h2>IMX500 &middot; Live Object Detection</h2>
  <canvas id="c"></canvas>
  <div id="status">connecting...</div>
  <script>
    const canvas = document.getElementById('c');
    const ctx    = canvas.getContext('2d');
    const status = document.getElementById('status');
    const ws     = new WebSocket('ws://{local_ip}:{WS_PORT}');
    ws.binaryType = 'blob';

    let frameCount = 0, lastTs = performance.now();

    ws.onopen  = () => status.textContent = 'connected — waiting for camera...';
    ws.onclose = () => status.textContent = 'disconnected — reload to reconnect';
    ws.onerror = () => status.textContent = 'connection error';

    ws.onmessage = (ev) => {{
      const url = URL.createObjectURL(ev.data);
      const img = new Image();
      img.onload = () => {{
        canvas.width  = img.width;
        canvas.height = img.height;
        ctx.drawImage(img, 0, 0);
        URL.revokeObjectURL(url);

        frameCount++;
        const now = performance.now();
        if (now - lastTs >= 1000) {{
          status.textContent = frameCount + ' fps';
          frameCount = 0;
          lastTs = now;
        }}
      }};
      img.src = url;
    }};
  </script>
</body>
</html>""".encode()


# ── HTTP server ───────────────────────────────────────────────────────────────
_live_html_cache      = None
_dashboard_html_cache = None


class PageHandler(BaseHTTPRequestHandler):
    def log_message(self, fmt, *args):
        pass   # suppress per-request stdout noise

    def do_GET(self):
        path = self.path.split("?")[0]

        if path in ("/", "/index.html"):
            body  = _live_html_cache or b"starting..."
            ctype = "text/html; charset=utf-8"

        elif path in ("/dashboard", "/dashboard.html"):
            body  = _dashboard_html_cache or b"starting..."
            ctype = "text/html; charset=utf-8"

        elif path == "/summary.json":
            summary_path = LOG_DIR / "summary.json"
            try:
                body = summary_path.read_bytes()
            except OSError:
                body = b'{"days":[]}'
            ctype = "application/json"

        else:
            self.send_response(404)
            self.end_headers()
            return

        self.send_response(200)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)


def run_http_server(local_ip: str) -> None:
    global _live_html_cache, _dashboard_html_cache

    _live_html_cache = _make_live_html(local_ip)

    dashboard_path = Path(__file__).parent / "dashboard.html"
    try:
        _dashboard_html_cache = dashboard_path.read_bytes()
    except OSError:
        _dashboard_html_cache = b"<p>dashboard.html not found in repo directory</p>"

    print(f"[server] HTTP listening on port {HTTP_PORT}")
    server = HTTPServer(("0.0.0.0", HTTP_PORT), PageHandler)
    server.serve_forever()


# ── WebSocket server ──────────────────────────────────────────────────────────
_ws_clients      = set()
_ws_clients_lock = asyncio.Lock()


async def _serve_ws_client(websocket, *args):
    async with _ws_clients_lock:
        _ws_clients.add(websocket)
    try:
        await websocket.wait_closed()
    finally:
        async with _ws_clients_lock:
            _ws_clients.discard(websocket)


async def _broadcast_frames() -> None:
    while True:
        jpeg = get_frame()
        if jpeg and _ws_clients:
            async with _ws_clients_lock:
                targets = list(_ws_clients)
            results = await asyncio.gather(
                *[ws.send(jpeg) for ws in targets],
                return_exceptions=True,
            )
            async with _ws_clients_lock:
                for ws, result in zip(targets, results):
                    if isinstance(result, Exception):
                        _ws_clients.discard(ws)
        await asyncio.sleep(1 / 30)


async def _run_ws_server() -> None:
    print(f"[server] WebSocket listening on port {WS_PORT}")
    async with websockets.serve(_serve_ws_client, "0.0.0.0", WS_PORT):
        await _broadcast_frames()


def start_ws_thread() -> None:
    asyncio.run(_run_ws_server())


# ── Entry point ───────────────────────────────────────────────────────────────
if __name__ == "__main__":
    # Resolve local IP for embedding in the live view page
    s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    s.connect(("8.8.8.8", 80))
    local_ip = s.getsockname()[0]
    s.close()

    print(f"[server] Local IP: {local_ip}")
    print(f"[server] Live view:  http://{local_ip}:{HTTP_PORT}/")
    print(f"[server] Dashboard:  http://{local_ip}:{HTTP_PORT}/dashboard")
    print(f"[server] WebSocket:  ws://{local_ip}:{WS_PORT}/")

    # Frame receiver thread — listens for JPEG frames from capture script
    t_frames = threading.Thread(target=frame_receiver, daemon=True)
    t_frames.start()

    # HTTP server thread
    t_http = threading.Thread(target=run_http_server, args=(local_ip,), daemon=True)
    t_http.start()

    # WebSocket server (runs asyncio event loop — blocks main thread)
    start_ws_thread()
