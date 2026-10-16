#!/bin/bash
set -euo pipefail
project_root="$(cd "$(dirname "$0")/.." && pwd)"
app="${1:-$project_root/dist/RunningMan.app}"
output="${2:-$project_root/.local/screenshots}"
mkdir -p "$output"
# These four files are owned by this smoke test. Remove prior captures so a
# preview failure cannot accidentally pass using an earlier successful run.
for name in overview runners history overview-dark; do
  rm -f "$output/$name.png"
done
"$app/Contents/MacOS/RunningMan" --demo --snapshot-dir "$output"
for name in overview runners history overview-dark; do
  test -s "$output/$name.png"
done
echo "Captured four isolated RunningMan views in $output"
