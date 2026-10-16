#!/bin/bash
# Front door for RunningMan builds: runs the tests, then assembles
# dist/RunningMan.app through scripts/build-app.sh.
#
#   scripts/build.sh              swift test + release app build (native arch)
#   scripts/build.sh --debug      debug build instead of release
#   scripts/build.sh --universal  arm64 + x86_64 (what CI and releases ship)
#   scripts/build.sh --zip        also dist/RunningMan.zip + .sha256
#   scripts/build.sh --run        open the app afterwards
#   scripts/build.sh --install    replace /Applications/RunningMan.app
#   scripts/build.sh --clean      remove dist/ and the SwiftPM build dir first
#
# Tests are skipped only with --no-test (iteration on a broken suite).
set -euo pipefail

cd "$(dirname "$0")/.."

usage() {
  echo "usage: scripts/build.sh [--debug] [--universal] [--zip] [--run] [--install] [--clean] [--no-test]" >&2
  exit 2
}

CLEAN=0 RUN=0 INSTALL=0 TEST=1
APP_ARGS=()
for arg in "$@"; do
  case "$arg" in
    --clean)   CLEAN=1 ;;
    --run)     RUN=1 ;;
    --install) INSTALL=1 ;;
    --no-test) TEST=0 ;;
    --debug|--universal|--zip) APP_ARGS+=("$arg") ;;
    *) usage ;;
  esac
done

if (( CLEAN )); then
  rm -rf dist .build
fi

if (( TEST )); then
  swift test
fi

scripts/build-app.sh "${APP_ARGS[@]+"${APP_ARGS[@]}"}"

if (( INSTALL )); then
  rm -rf "/Applications/RunningMan.app"
  ditto dist/RunningMan.app "/Applications/RunningMan.app"
  xattr -dr com.apple.quarantine "/Applications/RunningMan.app" 2>/dev/null || true
  echo "installed -> /Applications/RunningMan.app"
fi

if (( RUN )); then
  open dist/RunningMan.app
fi
