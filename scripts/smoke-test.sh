#!/bin/bash
set -euo pipefail
project_root="$(cd "$(dirname "$0")/.." && pwd)"
app="${1:-$project_root/dist/RunningMan.app}"
output="${2:-$project_root/.local/screenshots}"
mkdir -p "$output"
# These eight files are owned by this smoke test. Remove prior captures so a
# preview failure cannot accidentally pass using an earlier successful run.
for name in overview runners workload history cleanup overview-dark workload-dark cleanup-dark; do
  rm -f "$output/$name.png"
done
"$app/Contents/MacOS/RunningMan" --demo --snapshot-dir "$output"
for name in overview runners workload history cleanup overview-dark workload-dark cleanup-dark; do
  test -s "$output/$name.png"
done
echo "Captured eight isolated RunningMan views in $output"
