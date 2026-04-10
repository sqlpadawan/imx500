import os
os.environ["LIBCAMERA_LOG_LEVELS"] = "3"

import asyncio
import threading
import socket
import time
from http.server import BaseHTTPRequestHandler, HTTPServer
import cv2
import numpy as np
import libcamera
import websockets
from picamera2 import Picamera2
from picamera2.devices import IMX500
from picamera2.devices.imx500 import NetworkIntrinsics

# ── Config ────────────────────────────────────────────────────────────────────
WS_PORT              = 8080
HTTP_PORT            = 8081
CONFIDENCE_THRESHOLD = 0.20
MIN_CONSECUTIVE      = 1
KEY_BUCKET_DIVISOR   = 50
MODEL_PATH           = "/usr/share/imx500-models/imx500_network_ssd_mobilenetv2_fpnlite_320x320_pp.rpk"

# Vehicle-class labels collapsed to a single display label
VEHICLE_LABELS = {"car", "truck", "bus", "motorcycle", "train"}

# Other labels we care about
OTHER_LABELS   = {"person", "bicycle", "dog", "cat"}

# ── Shared frame buffer ───────────────────────────────────────────────────────
latest_jpeg      = None
latest_jpeg_lock = threading.Lock()

def set_frame(jpeg_bytes):
    global latest_jpeg
    with latest_jpeg_lock:
        latest_jpeg = jpeg_bytes

def get_frame():
    with latest_jpeg_lock:
        return latest_jpeg

# ── Detection stability filter ────────────────────────────────────────────────
detection_history = {}

def draw_and_encode(frame, detections):
    global detection_history
    h, w = frame.shape[:2]

    current_detections = {}

    for box, label, score in detections:
        x, y, bw, bh = box
        key = f"{label}_{int(x / KEY_BUCKET_DIVISOR)}_{int(y / KEY_BUCKET_DIVISOR)}"
        if key not in current_detections or score > current_detections[key][2]:
            current_detections[key] = (box, label, score)

    new_history = {}
    for key in current_detections:
        new_history[key] = detection_history.get(key, 0) + 1
    detection_history = new_history

    for key, count in detection_history.items():
        if count < MIN_CONSECUTIVE:
            continue
        if key not in current_detections:
            continue
        box, label, score = current_detections[key]
        x, y, bw, bh = box
        pt1 = (x, y)
        pt2 = (x + bw, y + bh)

        # Green for vehicles, blue for people/animals
        color = (0, 255, 0) if label == "vehicle" else (255, 128, 0)

        cv2.rectangle(frame, pt1, pt2, color, 2)
        cv2.putText(frame, f"{label} {score:.0%}",
                    (x, max(y - 8, 0)),
                    cv2.FONT_HERSHEY_SIMPLEX, 0.6, color, 2)

    # Rotation is now handled at ISP level — no software rotate needed
    bgr = cv2.cvtColor(frame, cv2.COLOR_RGB2BGR)
    ok, buf = cv2.imencode(".jpg", bgr, [cv2.IMWRITE_JPEG_QUALITY, 75])
    if ok:
        set_frame(buf.tobytes())

# ── HTML viewer ───────────────────────────────────────────────────────────────
def make_html(local_ip):
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

    ws.onopen  = () => status.textContent = 'connected';
    ws.onclose = () => status.textContent = 'disconnected - reload to reconnect';
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

_html_cache = None

class PageHandler(BaseHTTPRequestHandler):
    def log_message(self, fmt, *args):
        pass
    def do_GET(self):
        body = _html_cache or b"starting..."
        self.send_response(200)
        self.send_header("Content-Type", "text/html; charset=utf-8")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

def run_http_server(local_ip):
    global _html_cache
    _html_cache = make_html(local_ip)
    server = HTTPServer(("0.0.0.0", HTTP_PORT), PageHandler)
    server.serve_forever()

# ── WebSocket server ──────────────────────────────────────────────────────────
CLIENTS      = set()
CLIENTS_LOCK = asyncio.Lock()

async def serve_client(websocket, *args):
    async with CLIENTS_LOCK:
        CLIENTS.add(websocket)
    try:
        await websocket.wait_closed()
    finally:
        async with CLIENTS_LOCK:
            CLIENTS.discard(websocket)

async def broadcast_frames():
    while True:
        jpeg = get_frame()
        if jpeg and CLIENTS:
            async with CLIENTS_LOCK:
                targets = list(CLIENTS)
            results = await asyncio.gather(
                *[ws.send(jpeg) for ws in targets],
                return_exceptions=True,
            )
            async with CLIENTS_LOCK:
                for ws, result in zip(targets, results):
                    if isinstance(result, Exception):
                        CLIENTS.discard(ws)
        await asyncio.sleep(1 / 30)

async def run_ws_server():
    async with websockets.serve(serve_client, "0.0.0.0", WS_PORT):
        await broadcast_frames()

def start_ws_thread():
    asyncio.run(run_ws_server())

# ── Camera / inference ────────────────────────────────────────────────────────
imx500     = None
picam2     = None
intrinsics = None

def pre_callback(request):
    frame    = request.make_array("main")
    metadata = request.get_metadata()

    detections = []
    np_outputs = imx500.get_outputs(metadata, add_batch=True)
    if np_outputs is not None:
        labels  = intrinsics.labels
        boxes   = np_outputs[0][0]
        scores  = np_outputs[1][0]
        classes = np_outputs[2][0]
        for box, score, class_id in zip(boxes, scores, classes):
            if score < CONFIDENCE_THRESHOLD:
                continue
            raw_label = labels[int(class_id)] if int(class_id) < len(labels) else f"cls{int(class_id)}"

            if raw_label in VEHICLE_LABELS:
                display_label = "vehicle"
            elif raw_label in OTHER_LABELS:
                display_label = raw_label
            else:
                continue  # drop airplane, boat, bed, toilet, etc.

            coords = imx500.convert_inference_coords(box, metadata, picam2)
            detections.append((coords, display_label, float(score)))

    draw_and_encode(frame, detections)

def run_camera():
    global imx500, picam2, intrinsics

    imx500     = IMX500(MODEL_PATH)
    intrinsics = imx500.network_intrinsics or NetworkIntrinsics()
    intrinsics.update_with_defaults()

    print(f"Model:                {MODEL_PATH}")
    print(f"Model inference rate: {intrinsics.inference_rate}")
    print(f"Labels count:         {len(intrinsics.labels)}")
    print(f"First 10 labels:      {intrinsics.labels[:10]}")

    picam2 = Picamera2(imx500.camera_num)
    config = picam2.create_preview_configuration(
        main={"size": (1280, 720)},
        ##transform=libcamera.Transform(rotation=180),  # rotate at ISP level so inference sees correct orientation
        ##transform=libcamera.Transform(rotation=180),  # rotate at ISP level so inference sees correct orientation
        controls={"FrameRate": 30},
        buffer_count=6
    )
    picam2.pre_callback = pre_callback
    picam2.start(config, show_preview=False)
    print("Camera started — waiting for first frame...")

    try:
        while True:
            time.sleep(1)
    except KeyboardInterrupt:
        pass
    finally:
        picam2.stop()
        print("\nStopped.")

# ── Entry point ───────────────────────────────────────────────────────────────
if __name__ == "__main__":
    s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    s.connect(("8.8.8.8", 80))
    local_ip = s.getsockname()[0]
    s.close()

    t_http = threading.Thread(target=run_http_server, args=(local_ip,), daemon=True)
    t_http.start()

    t_ws = threading.Thread(target=start_ws_thread, daemon=True)
    t_ws.start()

    print(f"Viewer page:  http://{local_ip}:{HTTP_PORT}/")
    print(f"WebSocket:    ws://{local_ip}:{WS_PORT}/")

    time.sleep(0.5)
    run_camera()