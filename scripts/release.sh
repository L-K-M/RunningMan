#!/usr/bin/env bash
# Cuts a RunningMan release: points the marked download link in README.md at
# the new version's zip, commits it on main, tags v<version> and pushes the
# commit and tag together. The push starts .github/workflows/release.yml,
# which runs the tests, builds the universal app (scripts/build-app.sh
# --universal --zip, with RUNNINGMAN_VERSION from the tag), creates the GitHub
# Release with RunningMan-v<version>.zip plus its .sha256, then publishes the
# update manifest that installed apps check once a day (runningman/latest.json
# in ajilach/ajila-tg-app-updates). This script never writes the manifest.
#
#   scripts/release.sh 1.2.0            release 1.2.0 (tag v1.2.0)
#   scripts/release.sh 1.2.0 --dry-run  run the checks, create and push nothing
#
# Self-contained like build-app.sh: needs only git, plutil and POSIX tools
# (macOS bash 3.2 OK), no gh or Xcode. There is no version to bump in sources:
# the tag is the marketing version; the bundle's build number is the commit
# count (see build-app.sh).
set -euo pipefail

cd "$(dirname "$0")/.."

usage() { echo "usage: scripts/release.sh <version> [--dry-run]   (version like 1.2.0)" >&2; exit 2; }

VERSION=""
DRY=0
for arg in "$@"; do
  case "$arg" in
    --dry-run) DRY=1 ;;
    --push) ;; # accepted for muscle memory from other repos; the tag is always pushed
    -*) usage ;;
    *) [ -z "$VERSION" ] || usage; VERSION="${arg#v}" ;;
  esac
done
[ -n "$VERSION" ] || usage
[[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || { echo "the version must look like 1.2.0, not '$VERSION'" >&2; exit 2; }
TAG="v$VERSION"

fail() { echo "$1" >&2; exit 1; }

# $1 is strictly newer than $2, comparing dotted versions piece by piece.
newer_than() {
  local IFS=.
  local a=($1) b=($2) i
  for i in 0 1 2; do
    if (( 10#${a[i]:-0} > 10#${b[i]:-0} )); then return 0; fi
    if (( 10#${a[i]:-0} < 10#${b[i]:-0} )); then return 1; fi
  done
  return 1
}

# Preconditions: on main, clean, in sync with origin, tag unused, version newer
# than every existing release tag.
BRANCH=$(git rev-parse --abbrev-ref HEAD)
[ "$BRANCH" = main ] || fail "releases are cut from main, not '$BRANCH'"
[ -z "$(git status --porcelain)" ] || fail "the working tree has changes; commit or stash them first"
git fetch -q origin main --tags
[ "$(git rev-parse HEAD)" = "$(git rev-parse origin/main)" ] || fail "main is not at origin/main; pull or push first"
if git rev-parse -q --verify "refs/tags/$TAG" >/dev/null; then fail "$TAG already exists"; fi

LATEST=$(git tag -l 'v[0-9]*' | sort -t. -k1.2n -k2n -k3n | tail -1)
if [ -n "$LATEST" ]; then
  newer_than "$VERSION" "${LATEST#v}" || fail "$VERSION is not newer than the latest release $LATEST"
fi

REMOTE=$(git remote get-url origin)
SLUG=$(printf '%s\n' "$REMOTE" | sed -n -E 's#^.*github\.com[:/]([^/]+/[^/]+)$#\1#p' | sed -E 's#\.git$##')
SLUG=${SLUG:-L-K-M/RunningMan}

# Point the marked README link at the new version's zip. The marker pair stays
# on one line; the inner content never contains '<'.
ZIP="RunningMan-$TAG.zip"
LINE="[$ZIP](https://github.com/$SLUG/releases/download/$TAG/$ZIP)"
grep -q '<!-- latest-release -->' README.md || fail "README.md has no <!-- latest-release --> marker"
awk -v repl="<!-- latest-release -->$LINE<!-- /latest-release -->" \
  'sub(/<!-- latest-release -->[^<]*<!-- \/latest-release -->/, repl) { found=1 } { print } END { exit !found }' \
  README.md > README.md.tmp && mv README.md.tmp README.md \
  || { rm -f README.md.tmp; fail "could not update the README download link"; }

echo "RunningMan $VERSION, tag $TAG on $SLUG (previous: ${LATEST:-none})"
echo "the tag marks $(git rev-parse --short HEAD): $(git log -1 --format=%s) plus the README link"
git --no-pager diff -U0 README.md | grep -E '^[+-]' | grep -vE '^(\+\+\+|---) ' || true

if [ "$DRY" = 1 ]; then
  git checkout -q -- README.md
  echo "dry run: README.md reverted, no tag created, nothing pushed"
  exit 0
fi

git commit -q -m "Release $VERSION" README.md
git tag -a "$TAG" -m "RunningMan $VERSION"
if ! git push -q --atomic origin main "$TAG"; then
  echo "push failed; retry with: git push --atomic origin main $TAG" >&2
  echo "or undo locally with: git tag -d $TAG && git reset --keep origin/main" >&2
  exit 1
fi
echo "pushed main and $TAG"
echo "the release workflow now builds RunningMan-$TAG.zip (a few minutes): https://github.com/$SLUG/actions/workflows/release.yml"
echo "download, once it is done: https://github.com/$SLUG/releases/tag/$TAG"
echo "its last job publishes the update manifest; installed apps notice $TAG within a day: https://github.com/ajilach/ajila-tg-app-updates/blob/main/runningman/latest.json"
