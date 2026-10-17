#!/bin/bash
set -euo pipefail
project_root="$(cd "$(dirname "$0")/.." && pwd)"
app="${1:-$project_root/dist/RunningMan.app}"
output="${2:-$project_root/.local/screenshots}"
# A capture normally finishes in under 15 seconds. The bound turns a stalled
# launch into a failure instead of holding the job until its own timeout.
timeout_seconds=120
mkdir -p "$output"
# These eight files are owned by this smoke test. Remove prior captures so a
# preview failure cannot accidentally pass using an earlier successful run.
for name in overview runners workload history cleanup overview-dark workload-dark cleanup-dark; do
  rm -f "$output/$name.png"
done
# The directory is passed through the environment, not as an argument: a bare
# path on the command line stops the main window from opening at launch.
RUNNINGMAN_SNAPSHOT_DIR="$output" "$app/Contents/MacOS/RunningMan" --demo &
pid=$!
deadline=$((SECONDS + timeout_seconds))
while kill -0 "$pid" 2>/dev/null; do
  if ((SECONDS >= deadline)); then
    kill "$pid" 2>/dev/null || true
    wait "$pid" 2>/dev/null || true
    echo "RunningMan did not finish the preview captures within ${timeout_seconds}s." >&2
    exit 1
  fi
  sleep 1
done
wait "$pid"
captures=()
for name in overview runners workload history cleanup overview-dark workload-dark cleanup-dark; do
  test -s "$output/$name.png"
  captures+=("$output/$name.png")
done
# A capture that only shows the toolbar is still a non-empty PNG.
swift "$project_root/scripts/check-screenshots.swift" "${captures[@]}"
echo "Captured eight isolated RunningMan views in $output"
