#testing

import os
os.environ["LIBCAMERA_LOG_LEVELS"] = "3"

import asyncio
import threading
import socket
import time
from http.server import BaseHTTPRequestHandler, HTTPServer
import cv2
import numpy as np
import websockets
from picamera2 import Picamera2
from picamera2.devices import IMX500
from picamera2.devices.imx500 import NetworkIntrinsics

# ── Config ────────────────────────────────────────────────────────────────────
WS_PORT              = 8080   # WebSocket frames
HTTP_PORT            = 8081   # HTML viewer page
CONFIDENCE_THRESHOLD = 0.20
MIN_CONSECUTIVE      = 2        # lower = less filtering; set to 1 to disable
KEY_BUCKET_DIVISOR   = 6        # coarser grid tolerates ~15% position drift
MODEL_PATH           = "/usr/share/imx500-models/imx500_network_ssd_mobilenetv2_fpnlite_320x320_pp.rpk"
ALLOWED_LABELS       = {"person", "bicycle", "car", "motorbike", "bus", "truck", "dog", "cat"}

COCO_LABELS = [
    "person", "bicycle", "car", "motorbike", "aeroplane", "bus", "train",
    "truck", "boat", "traffic light", "fire hydrant", "stop sign",
    "parking meter", "bench", "bird", "cat", "dog", "horse", "sheep",
    "cow", "elephant", "bear", "zebra", "giraffe", "backpack", "umbrella",
    "handbag", "tie", "suitcase", "frisbee", "skis", "snowboard",
    "sports ball", "kite", "baseball bat", "baseball glove", "skateboard",
    "surfboard", "tennis racket", "bottle", "wine glass", "cup", "fork",
    "knife", "spoon", "bowl", "banana", "apple", "sandwich", "orange",
    "broccoli", "carrot", "hot dog", "pizza", "donut", "cake", "chair",
    "sofa", "pottedplant", "bed", "diningtable", "toilet", "tvmonitor",
    "laptop", "mouse", "remote", "keyboard", "cell phone", "microwave",
    "oven", "toaster", "sink", "refrigerator", "book", "clock", "vase",
    "scissors", "teddy bear", "hair drier", "toothbrush"
]

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

def draw_and_encode(frame, outputs):
    global detection_history
    h, w = frame.shape[:2]

    current_detections = {}

    if outputs is not None:
        boxes, scores, classes, _ = outputs
        for i in range(len(scores)):
            score = float(scores[i])
            if score < CONFIDENCE_THRESHOLD:
                continue
            class_id = int(classes[i])
            label    = COCO_LABELS[class_id] if class_id < len(COCO_LABELS) else f"cls{class_id}"
            if label not in ALLOWED_LABELS:
                continue
            y0, x0, y1, x1 = boxes[i]
            key = f"{label}_{int(x0 * KEY_BUCKET_DIVISOR)}_{int(y0 * KEY_BUCKET_DIVISOR)}"
            if key not in current_detections or score > current_detections[key][1]:
                current_detections[key] = (label, score, boxes[i])

    new_history = {}
    for key in current_detections:
        new_history[key] = detection_history.get(key, 0) + 1
    detection_history = new_history

    for key, count in detection_history.items():
        if count < MIN_CONSECUTIVE:
            continue
        if key not in current_detections:
            continue
        label, score, box = current_detections[key]
        y0, x0, y1, x1 = box
        pt1 = (int(x0 * w), int(y0 * h))
        pt2 = (int(x1 * w), int(y1 * h))
        cv2.rectangle(frame, pt1, pt2, (0, 255, 0), 2)
        cv2.putText(frame, f"{label} {score:.0%}",
                    (pt1[0], max(pt1[1] - 8, 0)),
                    cv2.FONT_HERSHEY_SIMPLEX, 0.6, (0, 255, 0), 2)

    bgr = cv2.cvtColor(frame, cv2.COLOR_RGB2BGR)
    ok, buf = cv2.imencode(".jpg", bgr, [cv2.IMWRITE_JPEG_QUALITY, 75])
    if ok:
        set_frame(buf.tobytes())

# ── HTML viewer (plain HTTP on port 8081) ─────────────────────────────────────
# Kept separate from the WebSocket port to avoid process_request compatibility
# issues across websockets library versions on Pi OS.

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

# ── WebSocket server (port 8080) ──────────────────────────────────────────────
CLIENTS      = set()
CLIENTS_LOCK = asyncio.Lock()

async def serve_client(websocket, *args):
    """Register client; compatible with websockets legacy and modern call signatures."""
    async with CLIENTS_LOCK:
        CLIENTS.add(websocket)
    try:
        await websocket.wait_closed()
    finally:
        async with CLIENTS_LOCK:
            CLIENTS.discard(websocket)

async def broadcast_frames():
    """Push the latest JPEG to every connected client at ~30 fps."""
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
imx500 = None
picam2 = None

def pre_callback(request):
    frame    = request.make_array("main")
    metadata = request.get_metadata()
    outputs  = imx500.get_outputs(metadata)
    draw_and_encode(frame, outputs)

def run_camera():
    global imx500, picam2

    imx500     = IMX500(MODEL_PATH)
    intrinsics = imx500.network_intrinsics or NetworkIntrinsics()
    intrinsics.update_with_defaults()

    print(f"Model inference rate: {intrinsics.inference_rate}")

    picam2 = Picamera2(imx500.camera_num)
    config = picam2.create_preview_configuration(
        main={"size": (1280, 720)},
        controls={"FrameRate": 15},
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
    # Get local IP once at startup so both servers can use it
    s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    s.connect(("8.8.8.8", 80))
    local_ip = s.getsockname()[0]
    s.close()

    # HTML viewer page
    t_http = threading.Thread(target=run_http_server, args=(local_ip,), daemon=True)
    t_http.start()

    # WebSocket frame broadcaster
    t_ws = threading.Thread(target=start_ws_thread, daemon=True)
    t_ws.start()

    print(f"Viewer page:  http://{local_ip}:{HTTP_PORT}/")
    print(f"WebSocket:    ws://{local_ip}:{WS_PORT}/")

    time.sleep(0.5)
    run_camera()
