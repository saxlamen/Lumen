#!/bin/bash
# Harvest the seven agreed P0+P1 metrics from Lumen's logs.
LOGS="$HOME/.config/sunshine/sunshine.log"
for pat in \
  "Video: sample queue delivery" \
  "Video: skipped" \
  "Frame processing latency" \
  "Audio: consumer wait" \
  "samples discarded since the last report" \
  "Audio: aggregate device granted buffer size" \
  "Audio: aggregate device buffer frame size range" \
  "Audio: aggregate device latency" \
  "Audio: aggregate device safety offset" \
  "stale wakeups" \
  "converter failures total" \
  "Encoder did not produce IDR" ; do
  echo "== $pat =="
  grep -F "$pat" $LOGS* 2>/dev/null | tail -4 | sed 's/^[^:]*:[0-9]*://' | sed 's/^/  /'
  c=$(cat $LOGS* 2>/dev/null | grep -cF "$pat")
  echo "  total_lines=$c"
done
echo "== crash reports =="
ls -1 $HOME/Library/Logs/DiagnosticReports/lumen-*.ips 2>/dev/null | tail -3 || echo "  none"
echo "== session markers =="
grep -hE "CLIENT CONNECTED|Client has exited|Reinitializing audio" $LOGS* 2>/dev/null | tail -4
