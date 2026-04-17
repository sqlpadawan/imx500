import argparse
import asyncio
import json
import logging
import os
import sys
import threading
import socket
import time
from datetime import datetime, timezone
from functools import lru_cache
from http.server import BaseHTTPRequestHandler, HTTPServer
from logging.handlers import TimedRotatingFileHandler
from pathlib import Path

import cv2
import websockets
from picamera2 import Picamera2
from picamera2.devices import IMX500
from picamera2.devices.imx500 import (NetworkIntrinsics,
                                       postprocess_nanodet_detection)

# ── Streaming config ──────────────────────────────────────────────────────────
WS_PORT   = 8080
HTTP_PORT = 8081

# ── Event logging setup ───────────────────────────────────────────────────────
LOG_DIR = Path("/var/log/imx500")
LOG_DIR.mkdir(exist_ok=True)

_event_logger = logging.getLogger("imx500.events")
_event_logger.setLevel(logging.INFO)
_event_logger.propagate = False

_log_handler = TimedRotatingFileHandler(
    filename    = LOG_DIR / "events.jsonl",
    when        = "midnight",   # rotate at midnight local time
    interval    = 1,
    backupCount = 30,           # keep 30 days of rotated files
    encoding    = "utf-8",
    utc         = False,
)
_log_handler.suffix = "%Y-%m-%d"   # e.g. events.jsonl.2026-04-15
_event_logger.addHandler(_log_handler)

# Tracking state: label seen in current/previous frame sets
# key   → bucketed bbox string  e.g. "213_045"
# value → {"label", "conf", "bbox", "enter_ts", "active"}
_tracked: dict = {}
_tracked_lock = threading.Lock()

MIN_CONSECUTIVE   = 5                  # frames a detection must persist before logging "enter"
COOLDOWN_S        = 10                 # seconds before the same label+zone can log another "enter"
SUPPRESSED_LABELS = {"airplane"}       # labels to ignore entirely
_pending: dict    = {}                 # key → {"label", "conf", "bbox", "count"}
_cooldown: dict   = {}                 # (label, track_key) → monotonic time of last "enter" log


def _log_event(event: str, label: str, confidence: float,
               bbox: tuple, track_key: str, dwell_s: float = None):
    # Suppress duplicate "enter" events for the same label+zone within COOLDOWN_S
    if event == "enter":
        cooldown_key = (label, track_key)
        last = _cooldown.get(cooldown_key, 0)
        if time.monotonic() - last < COOLDOWN_S:
            return
        _cooldown[cooldown_key] = time.monotonic()

    record = {
        "ts":         datetime.now(timezone.utc).isoformat(timespec="milliseconds"),
        "event":      event,
        "label":      label,
        "confidence": round(float(confidence), 3),
        "bbox":       [int(v) for v in bbox],
        "track_key":  track_key,
    }
    if dwell_s is not None:
        record["dwell_s"] = round(dwell_s, 1)
    _event_logger.info(json.dumps(record))


def _bucket_key(x, y, divisor=6):
    """Coarse-grain bbox origin so small jitter doesn't break tracking."""
    return f"{int(x) // divisor * divisor:04d}_{int(y) // divisor * divisor:04d}"


def update_tracking(detections, labels):
    """
    Compare current detections against tracked state.
    Emit 'enter' when a new stable object appears, 'exit' when it disappears.
    """
    global _pending, _tracked

    current_keys = set()

    for det in detections:
        x, y, w, h = det.box
        label = labels[int(det.category)]
        if label in SUPPRESSED_LABELS:
            continue
        key   = _bucket_key(x, y)
        current_keys.add(key)

        with _tracked_lock:
            if key in _tracked:
                # already confirmed — just keep it alive
                _tracked[key]["conf"] = det.conf
            else:
                # accumulate pending count
                if key not in _pending:
                    _pending[key] = {"label": label, "conf": det.conf,
                                     "bbox": (x, y, w, h), "count": 0}
                _pending[key]["count"] += 1

                if _pending[key]["count"] >= MIN_CONSECUTIVE:
                    # promote to tracked → log "enter"
                    _tracked[key] = {
                        "label":    label,
                        "conf":     det.conf,
                        "bbox":     (x, y, w, h),
                        "enter_ts": time.monotonic(),
                    }
                    _log_event("enter", label, det.conf, (x, y, w, h), key)
                    del _pending[key]

    # keys that were tracked but are gone → log "exit"
    with _tracked_lock:
        gone = [k for k in _tracked if k not in current_keys]
        for key in gone:
            t = _tracked.pop(key)
            dwell = time.monotonic() - t["enter_ts"]
            _log_event("exit", t["label"], t["conf"], t["bbox"], key, dwell_s=dwell)

        # also drop pending entries that disappeared without confirming
        stale_pending = [k for k in _pending if k not in current_keys]
        for key in stale_pending:
            del _pending[key]


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

# ── Original demo code (unchanged) ───────────────────────────────────────────
last_detections = []


class Detection:
    def __init__(self, coords, category, conf, metadata):
        """Create a Detection object, recording the bounding box, category and confidence."""
        self.category = category
        self.conf = conf
        self.box = imx500.convert_inference_coords(coords, metadata, picam2)


def parse_detections(metadata: dict):
    """Parse the output tensor into a number of detected objects, scaled to the ISP output."""
    global last_detections
    bbox_normalization = intrinsics.bbox_normalization
    bbox_order = intrinsics.bbox_order
    threshold = args.threshold
    iou = args.iou
    max_detections = args.max_detections

    np_outputs = imx500.get_outputs(metadata, add_batch=True)
    input_w, input_h = imx500.get_input_size()
    if np_outputs is None:
        return last_detections
    if intrinsics.postprocess == "nanodet":
        boxes, scores, classes = \
            postprocess_nanodet_detection(outputs=np_outputs[0], conf=threshold, iou_thres=iou,
                                          max_out_dets=max_detections)[0]
        from picamera2.devices.imx500.postprocess import scale_boxes
        boxes = scale_boxes(boxes, 1, 1, input_h, input_w, False, False)
    else:
        boxes, scores, classes = np_outputs[0][0], np_outputs[1][0], np_outputs[2][0]
        if bbox_normalization:
            boxes = boxes / input_h

        if bbox_order == "xy":
            boxes = boxes[:, [1, 0, 3, 2]]

    last_detections = [
        Detection(box, category, score, metadata)
        for box, score, category in zip(boxes, scores, classes)
        if score > threshold
    ]
    return last_detections


@lru_cache
def get_labels():
    labels = intrinsics.labels

    if intrinsics.ignore_dash_labels:
        labels = [label for label in labels if label and label != "-"]
    return labels


def draw_detections(request, stream="main"):
    """Draw the detections for this request onto the ISP output, then stream via WebSocket."""
    detections = last_results
    if detections is None:
        return
    labels = get_labels()

    frame = request.make_array(stream)

    for detection in detections:
        x, y, w, h = detection.box
        label = f"{labels[int(detection.category)]} ({detection.conf:.2f})"

        (text_width, text_height), baseline = cv2.getTextSize(label, cv2.FONT_HERSHEY_SIMPLEX, 0.5, 1)
        text_x = x + 5
        text_y = y + 15

        overlay = frame.copy()
        cv2.rectangle(overlay,
                      (text_x, text_y - text_height),
                      (text_x + text_width, text_y + baseline),
                      (255, 255, 255),
                      cv2.FILLED)
        alpha = 0.30
        cv2.addWeighted(overlay, alpha, frame, 1 - alpha, 0, frame)

        cv2.putText(frame, label, (text_x, text_y),
                    cv2.FONT_HERSHEY_SIMPLEX, 0.5, (0, 0, 255), 1)

        cv2.rectangle(frame, (x, y), (x + w, y + h), (0, 255, 0, 0), thickness=2)

    if intrinsics.preserve_aspect_ratio:
        b_x, b_y, b_w, b_h = imx500.get_roi_scaled(request)
        cv2.putText(frame, "ROI", (b_x + 5, b_y + 15), cv2.FONT_HERSHEY_SIMPLEX, 0.5, (255, 0, 0), 1)
        cv2.rectangle(frame, (b_x, b_y), (b_x + b_w, b_y + b_h), (255, 0, 0, 0))

    # Update event tracking and log enter/exit transitions
    update_tracking(detections, labels)

    # Encode and push to WebSocket clients
    ok, buf = cv2.imencode(".jpg", frame, [cv2.IMWRITE_JPEG_QUALITY, 75])
    if ok:
        set_frame(buf.tobytes())


def get_args():
    parser = argparse.ArgumentParser()
    parser.add_argument("--model", type=str, help="Path of the model",
                        default="/usr/share/imx500-models/imx500_network_ssd_mobilenetv2_fpnlite_320x320_pp.rpk")
    parser.add_argument("--fps", type=int, help="Frames per second")
    parser.add_argument("--bbox-normalization", action=argparse.BooleanOptionalAction, help="Normalize bbox")
    parser.add_argument("--bbox-order", choices=["yx", "xy"], default="yx",
                        help="Set bbox order yx -> (y0, x0, y1, x1) xy -> (x0, y0, x1, y1)")
    parser.add_argument("--threshold", type=float, default=0.55, help="Detection threshold")
    parser.add_argument("--iou", type=float, default=0.65, help="Set iou threshold")
    parser.add_argument("--max-detections", type=int, default=10, help="Set max detections")
    parser.add_argument("--ignore-dash-labels", action=argparse.BooleanOptionalAction, help="Remove '-' labels ")
    parser.add_argument("--postprocess", choices=["", "nanodet"],
                        default=None, help="Run post process of type")
    parser.add_argument("-r", "--preserve-aspect-ratio", action=argparse.BooleanOptionalAction,
                        help="preserve the pixel aspect ratio of the input tensor")
    parser.add_argument("--labels", type=str,
                        help="Path to the labels file")
    parser.add_argument("--print-intrinsics", action="store_true",
                        help="Print JSON network_intrinsics then exit")
    return parser.parse_args()


if __name__ == "__main__":
    args = get_args()

    # This must be called before instantiation of Picamera2
    imx500 = IMX500(args.model)
    intrinsics = imx500.network_intrinsics
    if not intrinsics:
        intrinsics = NetworkIntrinsics()
        intrinsics.task = "object detection"
    elif intrinsics.task != "object detection":
        print("Network is not an object detection task", file=sys.stderr)
        exit()

    # Override intrinsics from args
    for key, value in vars(args).items():
        if key == 'labels' and value is not None:
            with open(value, 'r') as f:
                intrinsics.labels = f.read().splitlines()
        elif hasattr(intrinsics, key) and value is not None:
            setattr(intrinsics, key, value)

    # Defaults
    if intrinsics.labels is None:
        with open("assets/coco_labels.txt", "r") as f:
            intrinsics.labels = f.read().splitlines()
    intrinsics.update_with_defaults()

    if args.print_intrinsics:
        print(intrinsics)
        exit()

    # Get local IP and start HTTP + WebSocket servers
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
    print(f"Event log:    {LOG_DIR / 'events.jsonl'}")

    picam2 = Picamera2(imx500.camera_num)
    config = picam2.create_preview_configuration(controls={"FrameRate": intrinsics.inference_rate, "AwbMode": 5}, buffer_count=12)

    imx500.show_network_fw_progress_bar()
    picam2.start(config, show_preview=False)  # headless — no display needed

    if intrinsics.preserve_aspect_ratio:
        imx500.set_auto_aspect_ratio()

    last_results = None
    picam2.pre_callback = draw_detections
    while True:
        last_results = parse_detections(picam2.capture_metadata())
    