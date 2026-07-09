# IMX500 Street Monitor — Camera Tuning Guide

This guide covers all the parameters available for tuning detection quality,
filtering noise, and controlling how events are logged. Changes are made
directly in `imx500_capture.py` unless noted otherwise. After any edit,
restart the capture service to apply:

```bash
imx500 restart imx500_capture.service
```

---

## How to Diagnose Before Tuning

Before changing any parameter, spend a day collecting logs and analyzing what
the model is actually seeing. This one-liner gives a useful starting point:

```bash
cat /var/log/imx500/events.jsonl | python3 -c "
import sys, json
from collections import defaultdict
label_conf = defaultdict(list)
for line in sys.stdin:
    line = line.strip()
    if not line: continue
    r = json.loads(line)
    if r.get('event') != 'enter': continue
    label_conf[r['label']].append(r['confidence'])
print(f\"{'Label':<20} {'Count':>6}  {'MinConf':>8}  {'AvgConf':>8}  {'MaxConf':>8}\")
print('-' * 60)
for label, confs in sorted(label_conf.items(), key=lambda x: -len(x[1])):
    print(f\"{label:<20} {len(confs):>6}  {min(confs):>8.3f}  {sum(confs)/len(confs):>8.3f}  {max(confs):>8.3f}\")
"
```

Look for:
- Labels that are impossible for your scene (boat, sheep, airplane on a street)
- Labels clustering at a narrow, low confidence band — this is the model's
  floor, not genuine detections
- Legitimate labels with very low average confidence — these may generate
  noisy or duplicate events

---

## Layer 1 — Confidence Threshold

**Where:** `imx500_capture.py`, argparse default — overridden at runtime via
the `--threshold` flag in the `imx500_capture.service` unit

```python
parser.add_argument("--threshold", type=float, default=0.40)
```

**What it does:** The model scores every detected object 0–1. Detections below
this threshold are discarded entirely before any other processing. This is the
primary and most powerful filter.

**Tuning guidance:**

- Raising the threshold reduces noise but can cause the model to miss
  lower-confidence but genuine detections (e.g. partially occluded vehicles,
  pedestrians at the edge of frame).
- A useful signal: if spurious labels are all clustering at nearly the same
  confidence value (e.g. all at `0.379`), that is the model's floor for that
  scene — raise the threshold just above it.
- Start with `0.42` for a residential street scene with SSD MobileNetV2.
  The legitimate vehicle detections typically average `0.48–0.55`, giving
  comfortable headroom above the noise floor.
- Test by running a full day and re-running the diagnostic query above.

**Current value:** `0.42`, passed via `--threshold` in the systemd service
unit. The code's own argparse default (`0.40`) is only used when running
`imx500_capture.py` manually without that flag — keep this in mind if you
ever test outside the service, since the untuned default will apply.

---

## Layer 2 — Suppressed Labels

**Where:** `imx500_capture.py`, module-level constant

```python
SUPPRESSED_LABELS = {"airplane", "boat", "sheep", "umbrella", "keyboard", "train"}
```

**What it does:** Any detection matching a label in this set is silently
discarded before tracking or logging, regardless of confidence. This is a
belt-and-suspenders filter for labels that are semantically impossible for
your scene.

**Tuning guidance:**

- Add any label that appears in your logs but can never occur on your street.
  Common culprits with SSD MobileNetV2 on residential scenes: boat, sheep,
  airplane, umbrella, keyboard, train.
- These labels typically appear near the model's confidence floor (around
  `0.379`) and represent the model misclassifying background elements —
  shadows, fences, parked cars at oblique angles, foliage.
- A label appearing only once or twice at low confidence is a candidate for
  suppression. A label appearing at high confidence may indicate a genuine
  detection that warrants investigation before suppressing.
- Suppression is a complement to the threshold, not a replacement. If a label
  is being suppressed, the underlying cause is usually a threshold that is
  too low.

**Current suppressed labels:** airplane, boat, sheep, umbrella, keyboard, train

---

## Layer 3 — Label Normalization

**Where:** `imx500_capture.py`, module-level dict

```python
LABEL_NORMALIZE: dict[str, str] = {
    "car":   "vehicle",
    "truck": "vehicle",
}
```

**What it does:** Maps raw model labels to normalized names before tracking
and logging. Detections matched to an existing track use proximity only (not
label), so a car/truck flip on the same moving object won't break the track.
Normalization ensures the event log uses consistent, meaningful labels.

**Tuning guidance:**

- Add entries for any label pair the model confuses on your scene.
  SSD MobileNetV2 reliably confuses `car` and `truck` — both are mapped to
  `vehicle`.
- If you see `bus` appearing in logs for what are clearly cars, add
  `"bus": "vehicle"` here.
- Normalization happens after suppression, so suppressed labels are never
  passed through this dict.

---

## Layer 4 — Bounding Box Size Filter

**Where:** `imx500_capture.py`, `update_tracking()` function

```python
if w * h < 400:   # skip implausibly small detections
    continue
if w > 400 or h > 300:  # too large — background element
    continue
```

**What it does:** Discards detections whose bounding box is either too small
(probably noise) or too large (probably a background or whole-frame
misclassification). This runs before tracking, so these detections never
enter the pending or confirmed track pools.

**Tuning guidance:**

- The minimum area (`w * h < 400`) corresponds roughly to a 20×20 pixel box.
  Objects smaller than this are unlikely to be meaningful at street scale.
- The maximum size limits (`w > 400`, `h > 300`) are calibrated for the
  320×320 model input scaled to the camera's output resolution. If you see
  detections covering most of the frame with a plausible label, tighten these.
- Adjust these if your camera is mounted closer to the street or uses a
  different lens focal length.

---

## Layer 5 — Tracking Parameters

**Where:** `imx500_capture.py`, module-level constants

```python
MAX_DIST        = 160   # px — proximity radius for matching detections to tracks
MIN_CONSECUTIVE = 2     # frames a detection must appear before logging "enter"
MAX_MISSED      = 8     # frames a track can go unmatched before logging "exit"
COOLDOWN_S      = 10    # suppression window (s) for a re-"enter" near a recent exit
```

**What each does and how to tune:**

### MAX_DIST
The maximum pixel distance between a detection's bounding box center and an
existing track's last known center for them to be considered the same object.
Too small causes fast-moving objects to spawn duplicate tracks. Too large
causes unrelated objects to merge into a single track.

At 160px, a vehicle moving at normal street speed across the frame in about
3 seconds will stay matched between frames at typical inference rates.

### MIN_CONSECUTIVE
A detection must appear in this many consecutive frames before it is promoted
from "pending candidate" to a confirmed track and an `enter` event is logged.
Setting this to `1` logs every single detection, including single-frame
spurious hits. Setting it to `3` or higher adds latency before an event is
logged and may miss fast-moving objects.

`2` is a good default for street traffic — it filters single-frame noise
without significantly delaying detection of moving vehicles.

### MAX_MISSED
A confirmed track is allowed to go unmatched for this many consecutive frames
before an `exit` event is logged and the track is closed. This provides
tolerance for momentary occlusion, model misses, or lower inference rates.

`8` frames at typical inference rates represents about 1–2 seconds of grace.
If you see premature `exit` events for objects that are still in frame,
increase this value.

### COOLDOWN_S
When a track is confirmed and about to log an `enter` event, this checks
whether a track of the **same label** exited within the last `COOLDOWN_S`
seconds **and** within `MAX_DIST` pixels of the new detection's position. If
so, the `enter` is suppressed. This is meant to catch a single physical
object whose track briefly flickered — lost for a frame or two (e.g. a
missed detection, momentary occlusion) and then re-promoted as a new
synthetic track ID — without treating it as a second, distinct object.

This is *not* a blanket per-label throttle. Two genuinely different vehicles
of the same label passing through different parts of the frame within the
same 10-second window will each still log their own `enter`/`exit` pair,
since they won't be spatially close to a recent exit. (Earlier versions of
this project used a simpler global per-label cooldown, which had the side
effect of dropping the second vehicle's `enter` event entirely in that case
— fixed as of the track-position-aware version.)

`10` seconds is appropriate for a residential street where vehicles pass
through the frame in 3–10 seconds. For a wider scene where vehicles may be
visible for longer, increase this. Note that the exit-matching radius is
currently reused from `MAX_DIST`, which was originally tuned for
frame-to-frame movement rather than "is this the same spot a vehicle exited
from a few seconds ago" — if you see flickered tracks slipping through as
duplicate `enter` events, or conversely two genuinely distinct vehicles
being incorrectly merged, consider giving this its own dedicated radius
constant instead of sharing `MAX_DIST`.

Since this changes what counts as a duplicate, treat it like any other
tracking parameter change: adjust one variable, review `events.jsonl` for a
day or two, then move on to the next change.

---

## Layer 6 — Log Retention

**Where:** `config.json`

```json
"logging": {
  "max_log_files": 30
}
```

**What it does:** Controls how many daily `events.jsonl.YYYY-MM-DD` rotated
log files are kept in `/var/log/imx500/`. The active log is always
`events.jsonl`. Rotation happens at the start of each day when the capture
script starts up at sunrise.

Change the value and restart the capture service to apply:

```bash
imx500 restart imx500_capture.service
```

---

## Recommended Tuning Workflow

1. Run the system for a full day with the current settings.
2. Run the diagnostic query above against the log file.
3. Identify noise: labels that are impossible, labels clustering at a low
   narrow confidence band.
4. If noise labels are all below a clear threshold, raise `--threshold` just
   above that band.
5. Add any semantically impossible labels to `SUPPRESSED_LABELS` as a
   secondary guard.
6. Restart the service and observe for another full day.
7. Repeat until the label distribution reflects only what your scene
   actually contains.

Avoid changing multiple parameters at once — one change per day makes it easy
to attribute any improvement or regression to a specific adjustment.
