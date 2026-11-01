# macOS scroll profiling tools

Measurement harness for the macOS scroll path: it records the scroll events macOS actually
receives, then separates "the client stopped sending" from "Lumen stopped injecting".

Comments and output are Traditional Chinese, since these are operator-run tools.

| File | What it is for |
| --- | --- |
| `lumen-inertia.command` | The daily check. 20 seconds, one gesture, prints a verdict. Run this. |
| `lumen-scroll-profile.command` | The recorder. `native` / `lumen` / `rustdesk` / `selftest` / `post` modes. |
| `lumen-inertia.py` | The analysis behind `lumen-inertia.command`; also runnable on any saved CSV. |
| `lumen-scroll-trace.py` | Parses `macos_scroll trace` log lines: client packet rhythm, injection rhythm, per-frame latency, release handoff. Needs `macos_smooth_scrolling_diagnostics = trace`. |
| `lumen-scroll-census.py` | Parses the `Scroll census` log lines: packets seen at the input queue vs events handed to the platform. |
| `lumen-scroll-compare.command` / `.py` | Full smoothness report, and the only way to compare against a native or RustDesk baseline. |
| `../motion-test/` | Different question: a full-screen animated overlay so the encoder is never idle. |

## Running the daily check

Double-click `lumen-inertia.command`, or:

```sh
tools/scroll-prof/lumen-inertia.command          # 20s
```

Flick fast and release about every 3 seconds, letting each flick coast to a stop. The recorder
needs a GUI login session: an event tap created from a plain SSH session receives 0 events, and
Terminal must be listed in System Settings → Privacy & Security → Input Monitoring (Accessibility
as well, for the session-level tap).

Recordings land in `~/Desktop/scroll-data/`, newest first, and analysis defaults to that glob.
The recorder compiles a small Swift helper into `~/Library/Caches/lumen-scroll` on first run;
`CGEventCreateMouseEvent` is not exported from the Swift SDK bundle, which is why it shells out
to `osascript` for the mouse position instead of binding it.

## How to read the numbers

Every event is counted twice, at the HID tap and at the session tap, because a single tap
sometimes misses a level. The analyzer keeps whichever level saw more.

- **Displacement per event has no single unit.** The two delta fields disagree by source. For
  events Lumen injects, the point field is pixels and the fixed-point field is a tenth of that
  (`point=4 fixed=0.4`), because the fixed-point fields are line-scaled. For host-side native
  events the ratio measured 1.0, and an event built with one line reports `point=10 fixed=1.0`.
  `lumen-inertia.py` reads the point field, which is correct for Lumen's own events and wrong by
  10x for some native sources, so its distance column is indicative only. Any native comparison
  must go through `lumen-scroll-compare.py`, which calibrates the fixed-point scale per recording
  instead of assuming it.
- **Timestamps.** Use the event's own timestamp (`t_ms`), not the tap's receive time (`recv_ms`).
  The tap delivers events in batches, which fabricates 0-3ms "same instant" clusters that are not
  in the event stream.
- **Cadence, not `avg_output_interval`.** The mean gap is diluted by idle time between gestures —
  an idle gap inflated a real 40ms tail into a reported 245ms. Use the median gap of the coasting
  segment, plus the histogram of gaps.
- **Velocity per rendered frame, not per event.** A 0.5ms gap between two events divides a normal
  delta into a fake 21600px/s spike. Bucket displacement into display refresh windows instead.
- **Stalls must be attributed.** A "stuck in the middle of the gesture" is only a Lumen bug if the
  client kept sending. The `Scroll census` lines answer this directly: if `client max_gap` equals
  `injected max_gap` with `packets_per_event=1`, the pause came from the client.

## Related service requirement

The inertia loop runs on an 8ms schedule, so the LaunchAgent must declare
`ProcessType = Interactive` or macOS coalesces its timer wakeups and the loop silently drops to
~30Hz. See `docs/macos_migration.md`, section "Launch service timer quality". The boot log line
`macOS inertia timer calibration ... median_oversleep=2.0ms` is the check; over 10ms means the key
went missing.

## What this harness measured

Before and after the fixes in `src/platform/macos/smooth_scroll.mm`, measured with the drill above:

| | before | after |
| --- | --- | --- |
| inertia injection cadence | 32.8ms (~30Hz) | 8.0ms |
| sub-pixel events | 0% | 55% |
| release handoff (coast speed / packet tail speed) | 0.43x, braking in 10 of 13 releases | 0.80x, 0 of 6 |
| mid-coast velocity increases >25% | — | 0 of 2384 |
| 8ms timer oversleep | 26ms median | 2.0ms |

The remaining known gap is the 0.80x handoff, and 9.5% of gaps under 4ms, which sit at the
packet-to-coast handover (0.8-2ms apart, collapsed into one step by a single display refresh).
