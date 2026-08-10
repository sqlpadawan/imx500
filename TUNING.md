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
SUPPRESSED_LABELS = {"airplane", "boat", "sheep", "umbrella", "keyboard", "train", "cow"}
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

**Current suppressed labels:** airplane, boat, sheep, umbrella, keyboard, train, cow

`cow` was added 2026-08-09: 3 occurrences over a full day, all at confidence 0.438 (the established noise floor), all during evening/night hours, with bbox dimensions similar to vehicle detections — consistent with nighttime vehicle shapes being misclassified, the same pattern that put the other entries on this list.

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
whether a track of the **same label** exited within that label's cooldown
window **and** within `MAX_DIST` pixels of the new detection's position. If
so, the `enter` is suppressed. This is meant to catch a single physical
object whose track briefly flickered — lost for a frame or two (e.g. a
missed detection, momentary occlusion) and then re-promoted as a new
synthetic track ID — without treating it as a second, distinct object.

As of 2026-08-09, this is **per-label**, not a single global value:

```python
COOLDOWN_S          = 10          # default / vehicle
COOLDOWN_S_BY_LABEL = {
    "person": 0.5,
}
```

`10` seconds remains the value for `vehicle` (and anything not otherwise
listed). `person` was tightened to `0.5` seconds. Both values, and the
decision to split them by label at all, came from a full day of
`suppression_debug.jsonl` — see below for the analysis and how to redo it.

Earlier versions of this project used a simpler global per-label cooldown
(no position check at all), which had a more severe version of this same
problem — dropping a second vehicle's `enter` regardless of position. Adding
the `MAX_DIST` position check narrowed the problem but, as the analysis
below shows, did not eliminate it for every label.

Since this changes what counts as a duplicate, treat it like any other
tracking parameter change: adjust one variable, review `events.jsonl` for a
day or two, then move on to the next change.

#### Diagnosing and tuning the cooldown window (resolved 2026-08-09)

**Instrumentation:** every suppressed `enter` is logged to a separate file,
`/var/log/imx500/suppression_debug.jsonl` — deliberately *not* mixed into
`events.jsonl`, so it doesn't affect `build_summary.py` or any downstream
tooling. Each line records:

| Field | Description |
|---|---|
| `ts` | Timestamp of the suppression decision |
| `label` | Normalized label |
| `distance_px` | Distance from the new detection to the matched recent exit |
| `time_gap_s` | Seconds since that exit |
| `prior_dwell_s` | How long the *earlier* track was confirmed before it exited |

**Known side effect:** a suppressed `enter` still leaves its track alive in
`_tracked`, so that track goes on to log a normal `exit` later — with no
matching `enter` in the log. If you're spot-checking `events.jsonl` and see
an `exit` whose `track_key` never appeared on an `enter`, this is why. It
doesn't affect `build_summary.py` (which only counts `enter` events), but
`enter` and `exit` counts will not fully balance as a result. This is a
known, currently-accepted side effect of the suppression design, not a bug
in the log — it hasn't been changed since it doesn't affect the summary
dashboard, and revisiting it (skipping the exit log for a suppressed track)
is a separate, small change if it's ever needed.

**What a partial day (2026-08-08 evening only) initially suggested:**
distance and prior dwell looked plausible as separators, with a hand-picked
example showing tight distance (~20-30px) and short prior dwell (~0.3-0.9s)
for what looked like genuine flicker. That didn't hold up against more data.

**What a full day (2026-08-09, 120 suppression events) actually showed:**
`distance_px` alone spread continuously from ~1px to ~159px for both labels
— no clean gap to threshold on. Splitting suppressions into a strict
"tight flicker" bucket (`distance_px < 30` and `time_gap_s < 1.5`) found
only 10-17% of events qualified for either label, but a more targeted check
— `distance_px > 50` **and** `time_gap_s > 2` (the profile most likely to
be a genuinely distinct object rather than one flickering track) — showed
a sharp asymmetry:

| Label | Total suppressed | Likely-distinct-object profile |
|---|---|---|
| vehicle | 62 | 1 (2%) |
| person | 58 | 26 (45%) |

Sorting each label's events by `time_gap_s` (rather than `distance_px`)
explained why. **Person** showed a genuinely clean split: below a ~0.4s
gap, `distance_px` stayed tightly bounded (5-33px, physically consistent
with a single-frame miss); the moment the gap crossed ~0.4s, distance
scattered across the full range with no coherent single-object pattern —
consistent with a second, distinct pedestrian. **Vehicle** showed the
*opposite* shape: short gaps (<1.2s) had large, scattered distances (up to
~140px, consistent with bbox-position jitter on a real moving car, not
actual teleportation), while longer gaps (2-9s) consistently settled into
small distances (mostly <35px) — consistent with a vehicle that
legitimately stopped or idled and briefly dropped out of detection. A
single distance or time cutoff shared across labels can't fit both shapes
at once, which is why this became a per-label `COOLDOWN_S` change rather
than a shared `EXIT_COOLDOWN_DIST`. `MAX_DIST` (the distance check) was
left shared and unchanged — for `person`, the short 0.5s window already
does the real filtering, since a pedestrian can't move far in half a
second regardless of position.

**To redo this analysis** (e.g. after further changes, or to sanity-check
the current values): pull `suppression_debug.jsonl`, split by label, and
sort each label's events by `time_gap_s` — look for the point at which
`distance_px` stops being tightly bounded and starts scattering. That point
is a reasonable candidate for that label's `COOLDOWN_S`. Confirm afterward
with the standard enter/exit balance check from the diagnostic query above
— `person` enter/exit counts moving closer together, without vehicle
regressing, is the signal the change worked as intended.

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

## Event Log Schema

Each line in `events.jsonl` is a JSON record with the following fields:

| Field | Present on | Description |
|---|---|---|
| `ts` | all | ISO-8601 UTC timestamp, millisecond precision |
| `event` | all | `"enter"` or `"exit"` |
| `label` | all | Normalized label (see Layer 3) |
| `confidence` | all | Detection confidence at time of event (0–1) |
| `bbox` | all | `[x, y, w, h]` at time of event |
| `track_key` | all | 8-character UUID identifying the track. Generated once when a pending candidate is promoted to a confirmed track (see Layer 5, `MIN_CONSECUTIVE`), and reused on the corresponding `exit`. One `enter`/`exit` pair per `track_key` — track identity is proximity-based, not label-based, so a car/truck label flip on the same physical object keeps the same `track_key`. |
| `dwell_s` | `exit` only | Seconds the track was confirmed, from promotion to exit |

Because `track_key` is assigned once per confirmed track and each track logs exactly one `enter`, downstream counting (`build_summary.py`) can simply count `enter` events directly — no additional deduplication is needed. This wasn't always true; see the note below.

**Note:** `enter` and `exit` counts in `events.jsonl` will not fully balance — some `exit` events reference a `track_key` that never got an `enter` logged, because that `enter` was suppressed by the cooldown check but the track itself lived on to exit normally. This is a known, accepted side effect of the suppression design (see Layer 5, `COOLDOWN_S`), not a bug — it doesn't affect `build_summary.py`, which only counts `enter` events. Suppression decisions themselves are logged separately to `/var/log/imx500/suppression_debug.jsonl`, not to `events.jsonl` — see Layer 5 for details.

### Note: `reprocess_summary.py` is legacy

`reprocess_summary.py` predates the `track_key`-based tracker documented above. It was written to work around an earlier bug where a bucket divisor of 6px caused a single vehicle to generate many separate `enter` events as its bbox origin drifted — it clusters raw `enter` events by bbox-origin proximity (`SPATIAL_THRESHOLD`) and a time window (`TIME_WINDOW_S`) to collapse duplicates before counting.

That bug no longer exists. The current tracker (Layer 5) assigns one `track_key` per confirmed track and logs exactly one `enter` per track, so logs written by the current code need no post-hoc deduplication — `build_summary.py` counting raw `enter` events directly is already correct.

`reprocess_summary.py` is kept in the repo only for reprocessing old logs captured before this fix. It should **not** be run against current-format logs: its bbox-origin clustering has no awareness of `track_key` and could incorrectly merge two distinct objects of the same label that happen to pass through close positions within its 15-second window. This is a one-time historical tool, not part of the daily processing pipeline (`build_summary.py` is), so no code change was made to it — this note is the resolution.

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

---

## Appendix: Camera Fails to Start — dmaHeap / CMA Allocation Errors

This isn't a tuning parameter, but it's a boot-configuration issue that can
block capture entirely, discovered during a Pi Zero 2W reflash — documented
here so it doesn't need re-diagnosing from scratch next time.

**Symptom:** `imx500_capture.service` crash-loops immediately after start.
`wrapper.log` shows repeated `Capture PID: N` / `Capture script exited
unexpectedly — restarting in 10s` cycles every ~5 seconds. The traceback
(visible via `imx500 status imx500_capture.service` or
`/var/log/imx500/wrapper.log`) ends in one of:

```
OSError: [Errno 12] Cannot allocate memory
```
or, after a partial fix:
```
RuntimeError: Could not open any dmaHeap device
```

**Root cause (two layered issues):**

1. **CMA pool too small.** The Raspberry Pi's default CMA (contiguous
   memory) reservation — 64 MiB — isn't enough for the IMX500 camera
   stack's buffer requirements. `dmesg | grep -i cma` shows a failed
   allocation (`cma: __cma_alloc: linux,cma: alloc failed`) with a heavily
   fragmented free-page list.

2. **Device node naming.** picamera2's Python `DmaHeap` allocator
   (`dma_heap.py`) has a hardcoded, non-fallback heap name list:
   `["/dev/dma_heap/vidbuf_cached", "/dev/dma_heap/linux,cma"]`. If the CMA
   pool is resized via the kernel `cma=` cmdline.txt parameter, the kernel
   exposes the heap under a different devtmpfs name (`reserved` or
   `default_cma_region`) instead of `linux,cma` — and picamera2 has no
   fallback for that naming scheme, so it fails to open any heap even
   though a correctly-sized pool exists right next to it.

**Fix:** Size the CMA pool via a `dtoverlay` parameter in `config.txt`
instead of the `cma=` cmdline.txt parameter — this preserves the DT-bound
`linux,cma` device name that picamera2 expects:

```
dtoverlay=vc4-kms-v3d,cma-128
```

This is now provisioned automatically by `imx500pi_provision.sh` (added
alongside `gpu_mem=128` and `dtoverlay=imx500`), so a fresh reflash should
not hit this. If it recurs — e.g. after manually editing `config.txt`, or
if a future sensor/resolution change needs more buffer headroom — verify
with:

```bash
grep -E "gpu_mem|dtoverlay=imx500|dtoverlay=vc4-kms-v3d" /boot/firmware/config.txt
ls -la /dev/dma_heap/    # should list "linux,cma" (and a "vidbuf_cached" symlink)
```

Note this adds the `vc4-kms-v3d` KMS graphics driver, which is heavier than
strictly needed on a headless, display-less Pi — there is currently no
lighter-weight overlay that resizes the DT-bound CMA heap without it (per
Raspberry Pi engineering guidance, DT-based CMA sizing is only wired into
the KMS/FKMS overlays). The alternative — patching picamera2's
`heapNames` list to add a `reserved` fallback — avoids the extra driver but
lives in an apt-managed file that would be silently reverted by a future
`python3-picamera2` upgrade, so it wasn't used here.

128 MiB was sufficient on this Pi Zero 2W (512MB total RAM). Increase only
if needed, and conservatively — CMA size is drawn from the same ~352MB pool
available to Linux after `gpu_mem=128`.
