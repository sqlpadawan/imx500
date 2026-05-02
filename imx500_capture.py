#!/usr/bin/env python3
"""
imx500_capture.py — Camera capture, AI inference, and event logging.

Runs sunrise-to-sunset under imx500_capture_wrapper.sh / imx500_capture.service.
Sends annotated JPEG frames to imx500_server.py via a Unix domain socket so the
always-on server can broadcast them to WebSocket clients.

Wire format sent to FRAME_SOCKET (little-endian):
    4 bytes  — uint32 payload length
    N bytes  — JPEG data

No HTTP or WebSocket server code lives here — that responsibility belongs
entirely to imx500_server.py.
"""

import argparse
import json
import logging
import socket
import struct
import sys
import threading
import time
from datetime import datetime, timezone
from functools import lru_cache
from logging.handlers import TimedRotatingFileHandler
from pathlib import Path

import cv2
from picamera2 import Picamera2
from picamera2.devices import IMX500
from picamera2.devices.imx500 import (NetworkIntrinsics,
                                       postprocess_nanodet_detection)

# ── Config ────────────────────────────────────────────────────────────────────
FRAME_SOCKET = Path("/tmp/imx500_frames.sock")
LOG_DIR      = Path("/var/log/imx500")
LOG_DIR.mkdir(exist_ok=True)

# Read max_log_files from config.json if present, default to 30
_config_path = Path(__file__).parent / "config.json"
try:
    with open(_config_path) as _f:
        _config = json.load(_f)
    MAX_LOG_FILES = int(_config.get("logging", {}).get("max_log_files", 30))
except Exception:
    MAX_LOG_FILES = 30

# ── Event logging ─────────────────────────────────────────────────────────────
_event_logger = logging.getLogger("imx500.events")
_event_logger.setLevel(logging.INFO)
_event_logger.propagate = False

_log_handler = TimedRotatingFileHandler(
    filename    = LOG_DIR / "events.jsonl",
    when        = "midnight",
    interval    = 1,
    backupCount = MAX_LOG_FILES,
    encoding    = "utf-8",
    utc         = False,
)
_log_handler.suffix = "%Y-%m-%d"
_event_logger.addHandler(_log_handler)

# ── Detection tracking state ──────────────────────────────────────────────────
# Proximity-based tracker: each object gets a UUID that persists as it moves
# across the frame, regardless of label flips between frames.
#
# Key design decisions:
#   - Confirmed tracks are matched by proximity ONLY (no label requirement).
#     A car/truck flip on the same moving object won't break the track.
#   - Pending candidates are matched by proximity + same label group, so two
#     genuinely different objects close together don't merge before confirmation.
#   - Raw model labels are normalized before use: "car" and "truck" both become
#     "vehicle" since SSD MobileNetV2 routinely confuses them on street scenes.
#
# Tuning parameters:
#   MAX_DIST        — max bbox-center distance (px) to match a detection to an
#                     existing track. Should comfortably exceed per-frame
#                     movement at street speed.
#   MIN_CONSECUTIVE — frames a new detection must appear before logging "enter"
#   MAX_MISSED      — frames a confirmed track can go unmatched before "exit"
#   COOLDOWN_S      — minimum seconds between "enter" events for the same label

import uuid as _uuid_mod

MAX_DIST          = 160   # px
MIN_CONSECUTIVE   = 2
MAX_MISSED        = 8     # frames grace for occlusion / model miss
COOLDOWN_S        = 10
SUPPRESSED_LABELS = {"airplane"}

# Labels collapsed to a single normalized name.
# Extend this dict for any other pairs the model confuses on your scene.
LABEL_NORMALIZE: dict[str, str] = {
    "car":   "vehicle",
    "truck": "vehicle",
}

# _tracked: track_id → {label, conf, cx, cy, bbox, enter_ts, missed}
# _pending: temp_id  → {label, conf, cx, cy, bbox, count}
_tracked:      dict = {}
_pending:      dict = {}
_cooldown:     dict = {}
_tracked_lock        = threading.Lock()


def _normalize_label(raw: str) -> str:
    return LABEL_NORMALIZE.get(raw, raw)


def _bbox_center(x, y, w, h) -> tuple[float, float]:
    return x + w / 2, y + h / 2


def _center_dist(cx1, cy1, cx2, cy2) -> float:
    return ((cx1 - cx2) ** 2 + (cy1 - cy2) ** 2) ** 0.5


def _find_nearest_any(pool: dict, cx: float, cy: float) -> str | None:
    """Nearest entry regardless of label — used for confirmed track matching."""
    best_key  = None
    best_dist = MAX_DIST
    for key, obj in pool.items():
        d = _center_dist(cx, cy, obj["cx"], obj["cy"])
        if d < best_dist:
            best_dist = d
            best_key  = key
    return best_key


def _find_nearest_same_label(pool: dict, label: str, cx: float, cy: float) -> str | None:
    """Nearest same-label entry — used for pending candidate matching."""
    best_key  = None
    best_dist = MAX_DIST
    for key, obj in pool.items():
        if obj["label"] != label:
            continue
        d = _center_dist(cx, cy, obj["cx"], obj["cy"])
        if d < best_dist:
            best_dist = d
            best_key  = key
    return best_key


def _log_event(event: str, label: str, confidence: float,
               bbox: tuple, track_key: str, dwell_s: float = None) -> None:
    if event == "enter":
        last = _cooldown.get(label, 0)
        if time.monotonic() - last < COOLDOWN_S:
            return
        _cooldown[label] = time.monotonic()

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


def update_tracking(detections, labels) -> None:
    """Match detections to existing tracks by proximity, log enter/exit events."""
    with _tracked_lock:
        matched_track_ids   = set()
        matched_pending_ids = set()

        for det in detections:
            x, y, w, h = det.box
            if w * h < 400:   # skip implausibly small detections
                continue
            if w > 400 or h > 300:  # too large — background element
                continue
            raw_label = labels[int(det.category)]
            if raw_label in SUPPRESSED_LABELS:
                continue
            label  = _normalize_label(raw_label)
            cx, cy = _bbox_center(x, y, w, h)

            # 1. Try to match to a confirmed track (label-agnostic)
            tid = _find_nearest_any(_tracked, cx, cy)
            if tid is not None:
                _tracked[tid].update(conf=det.conf, cx=cx, cy=cy,
                                     bbox=(x, y, w, h), missed=0)
                matched_track_ids.add(tid)
                continue

            # 2. Try to match to a pending candidate (same normalized label)
            pid = _find_nearest_same_label(_pending, label, cx, cy)
            if pid is not None:
                _pending[pid].update(conf=det.conf, cx=cx, cy=cy,
                                     bbox=(x, y, w, h))
                _pending[pid]["count"] += 1
                matched_pending_ids.add(pid)
            else:
                # 3. New candidate
                pid = str(_uuid_mod.uuid4())[:8]
                _pending[pid] = {"label": label, "conf": det.conf,
                                 "cx": cx, "cy": cy, "bbox": (x, y, w, h),
                                 "count": 1}
                matched_pending_ids.add(pid)

            # Promote pending → confirmed after MIN_CONSECUTIVE frames
            if pid in _pending and _pending[pid]["count"] >= MIN_CONSECUTIVE:
                obj = _pending.pop(pid)
                tid = str(_uuid_mod.uuid4())[:8]
                _tracked[tid] = {
                    "label":    obj["label"],
                    "conf":     obj["conf"],
                    "cx":       obj["cx"],
                    "cy":       obj["cy"],
                    "bbox":     obj["bbox"],
                    "enter_ts": time.monotonic(),
                    "missed":   0,
                }
                _log_event("enter", obj["label"], obj["conf"], obj["bbox"], tid)
                matched_track_ids.add(tid)

        # Increment missed counter for unmatched confirmed tracks
        for tid in list(_tracked):
            if tid not in matched_track_ids:
                _tracked[tid]["missed"] += 1
                if _tracked[tid]["missed"] > MAX_MISSED:
                    t = _tracked.pop(tid)
                    dwell = time.monotonic() - t["enter_ts"]
                    _log_event("exit", t["label"], t["conf"], t["bbox"],
                               tid, dwell_s=dwell)

        # Drop stale pending candidates that weren't seen this frame
        for pid in list(_pending):
            if pid not in matched_pending_ids:
                del _pending[pid]


# ── Unix socket frame sender ──────────────────────────────────────────────────
_sock_conn      = None
_sock_conn_lock = threading.Lock()


def _connect_to_server() -> socket.socket | None:
    """Try to connect to the server's frame socket. Returns socket or None."""
    try:
        sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        sock.connect(str(FRAME_SOCKET))
        print(f"[capture] Connected to frame socket at {FRAME_SOCKET}")
        return sock
    except OSError as e:
        print(f"[capture] Could not connect to frame socket: {e} — retrying...")
        return None


def send_frame(jpeg_bytes: bytes) -> None:
    """Send a JPEG frame to the server via the Unix socket."""
    global _sock_conn
    with _sock_conn_lock:
        if _sock_conn is None:
            _sock_conn = _connect_to_server()
        if _sock_conn is None:
            return   # server not up yet — drop frame silently
        try:
            header = struct.pack("<I", len(jpeg_bytes))
            _sock_conn.sendall(header + jpeg_bytes)
        except OSError:
            print("[capture] Frame socket send failed — reconnecting next frame")
            try:
                _sock_conn.close()
            except OSError:
                pass
            _sock_conn = None


def _socket_connect_loop() -> None:
    """Background thread: keep trying to connect until the server socket appears."""
    global _sock_conn
    while True:
        with _sock_conn_lock:
            if _sock_conn is not None:
                break
            conn = _connect_to_server()
            if conn is not None:
                _sock_conn = conn
                break
        time.sleep(2)


# ── Detection parsing ─────────────────────────────────────────────────────────
last_detections = []


class Detection:
    def __init__(self, coords, category, conf, metadata):
        self.category = category
        self.conf     = conf
        self.box      = imx500.convert_inference_coords(coords, metadata, picam2)


def parse_detections(metadata: dict):
    global last_detections
    bbox_normalization = intrinsics.bbox_normalization
    bbox_order         = intrinsics.bbox_order
    threshold          = args.threshold
    iou                = args.iou
    max_detections     = args.max_detections

    np_outputs = imx500.get_outputs(metadata, add_batch=True)
    input_w, input_h = imx500.get_input_size()
    if np_outputs is None:
        return last_detections

    if intrinsics.postprocess == "nanodet":
        boxes, scores, classes = \
            postprocess_nanodet_detection(outputs=np_outputs[0], conf=threshold,
                                          iou_thres=iou, max_out_dets=max_detections)[0]
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


def draw_detections(request, stream="main") -> None:
    """Draw bounding boxes, update tracking, send frame to server."""
    detections = last_results
    if detections is None:
        return
    labels = get_labels()
    frame  = request.make_array(stream)

    for detection in detections:
        x, y, w, h = detection.box
        label = f"{labels[int(detection.category)]} ({detection.conf:.2f})"

        (text_width, text_height), baseline = cv2.getTextSize(
            label, cv2.FONT_HERSHEY_SIMPLEX, 0.5, 1)
        text_x = x + 5
        text_y = y + 15

        overlay = frame.copy()
        cv2.rectangle(overlay,
                      (text_x, text_y - text_height),
                      (text_x + text_width, text_y + baseline),
                      (255, 255, 255), cv2.FILLED)
        cv2.addWeighted(overlay, 0.30, frame, 0.70, 0, frame)
        cv2.putText(frame, label, (text_x, text_y),
                    cv2.FONT_HERSHEY_SIMPLEX, 0.5, (0, 0, 255), 1)
        cv2.rectangle(frame, (x, y), (x + w, y + h), (0, 255, 0, 0), thickness=2)

    if intrinsics.preserve_aspect_ratio:
        b_x, b_y, b_w, b_h = imx500.get_roi_scaled(request)
        cv2.putText(frame, "ROI", (b_x + 5, b_y + 15),
                    cv2.FONT_HERSHEY_SIMPLEX, 0.5, (255, 0, 0), 1)
        cv2.rectangle(frame, (b_x, b_y), (b_x + b_w, b_y + b_h), (255, 0, 0, 0))

    # Update event tracking and log enter/exit transitions
    update_tracking(detections, labels)

    # Encode and send to server
    ok, buf = cv2.imencode(".jpg", frame, [cv2.IMWRITE_JPEG_QUALITY, 75])
    if ok:
        send_frame(buf.tobytes())


# ── Argument parsing ──────────────────────────────────────────────────────────
def get_args():
    parser = argparse.ArgumentParser()
    parser.add_argument("--model", type=str,
                        default="/usr/share/imx500-models/imx500_network_ssd_mobilenetv2_fpnlite_320x320_pp.rpk")
    parser.add_argument("--fps", type=int)
    parser.add_argument("--bbox-normalization", action=argparse.BooleanOptionalAction)
    parser.add_argument("--bbox-order", choices=["yx", "xy"], default="yx")
    parser.add_argument("--threshold", type=float, default=0.35)
    parser.add_argument("--iou", type=float, default=0.65)
    parser.add_argument("--max-detections", type=int, default=10)
    parser.add_argument("--ignore-dash-labels", action=argparse.BooleanOptionalAction)
    parser.add_argument("--postprocess", choices=["", "nanodet"], default=None)
    parser.add_argument("-r", "--preserve-aspect-ratio", action=argparse.BooleanOptionalAction)
    parser.add_argument("--labels", type=str)
    parser.add_argument("--print-intrinsics", action="store_true")
    return parser.parse_args()


# ── Entry point ───────────────────────────────────────────────────────────────
if __name__ == "__main__":
    args = get_args()

    imx500 = IMX500(args.model)
    intrinsics = imx500.network_intrinsics
    if not intrinsics:
        intrinsics = NetworkIntrinsics()
        intrinsics.task = "object detection"
    elif intrinsics.task != "object detection":
        print("Network is not an object detection task", file=sys.stderr)
        exit()

    for key, value in vars(args).items():
        if key == "labels" and value is not None:
            with open(value, "r") as f:
                intrinsics.labels = f.read().splitlines()
        elif hasattr(intrinsics, key) and value is not None:
            setattr(intrinsics, key, value)

    if intrinsics.labels is None:
        with open("assets/coco_labels.txt", "r") as f:
            intrinsics.labels = f.read().splitlines()
    intrinsics.update_with_defaults()

    if args.print_intrinsics:
        print(intrinsics)
        exit()

    # Start background thread to connect to server frame socket
    threading.Thread(target=_socket_connect_loop, daemon=True).start()

    print(f"[capture] Event log: {LOG_DIR / 'events.jsonl'}")
    print(f"[capture] Sending frames to {FRAME_SOCKET}")

    picam2 = Picamera2(imx500.camera_num)
    config = picam2.create_preview_configuration(
        controls={"FrameRate": intrinsics.inference_rate, "AwbMode": 5},
        buffer_count=12,
    )

    imx500.show_network_fw_progress_bar()
    picam2.start(config, show_preview=False)

    if intrinsics.preserve_aspect_ratio:
        imx500.set_auto_aspect_ratio()

    last_results = None
    picam2.pre_callback = draw_detections
    while True:
        last_results = parse_detections(picam2.capture_metadata())
