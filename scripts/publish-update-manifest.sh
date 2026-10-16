#!/usr/bin/env bash
#
# publish-update-manifest.sh — announce a GitHub Release of an Ajila app by writing
# <app-id>/latest.json into the public update-manifest repo
# (https://github.com/ajilach/ajila-tg-app-updates), which the installed apps read.
#
# Drop-in: the identical file lives in every Ajila app repo that announces releases;
# the canonical copy is scripts/publish-update-manifest.sh in ajila-tg-app-updates.
# Edit it there and copy it over, so all copies stay byte-identical.
#
# Usage:
#   publish-update-manifest.sh [--dry-run] <updates-checkout> <app-id> <tag>
#
#   <updates-checkout>  a clone of ajila-tg-app-updates whose `origin` accepts pushes
#                       (the release job checks it out with the publishing token).
#                       It is hard-reset to origin/main, so use a throwaway clone.
#   <app-id>            the manifest folder, e.g. save-aem-form
#   <tag>               the release tag, e.g. v1.4.0
#   --dry-run           do everything except commit and push; print the manifest
#
# Environment:
#   GITHUB_REPOSITORY     owner/repo whose release is announced (set by GitHub Actions)
#   GH_TOKEN              a token that can read that repo's releases (github.token)
#   PUBLISH_RELEASE_JSON  tests only: `gh release view --json` output to use instead
#                         of asking GitHub
#   PUBLISH_BACKOFF_SECONDS  tests only: retry backoff step (default 2)
#
# Rules (the contract is documented in the ajila-tg-app-updates README):
#   - Only plain vX.Y.Z tags are announced; others (v1.2.0-rc.1) are skipped.
#   - The release must exist and be neither a draft nor a prerelease.
#   - A manifest never moves backwards: re-running an older tag changes nothing.
#   - Each app only writes its own file. The change is rebuilt on the newest
#     origin/main before every push attempt, so concurrent releases all land.
#   - Anything that prevents publishing fails the job (exit 1, ::error::) — the
#     announcement must never silently not happen.
#
# Needs bash 3.2+, git, jq, and gh (unless PUBLISH_RELEASE_JSON is set); all are
# preinstalled on GitHub-hosted runners.
set -euo pipefail

TAG_RE='^v[0-9]+\.[0-9]+\.[0-9]+$'
APP_RE='^[a-z0-9][a-z0-9-]*$'
ATTEMPTS=5
BACKOFF=${PUBLISH_BACKOFF_SECONDS:-2}   # seconds per attempt between push retries; tests use 0

die()    { echo "::error::$*" >&2; exit 1; }
notice() { echo "::notice::$*"; }

usage() {
  echo "usage: publish-update-manifest.sh [--dry-run] <updates-checkout> <app-id> <tag>" >&2
  exit 2
}

# version_gt A B — succeeds when dotted numeric version A is strictly newer than B.
version_gt() {
  local IFS=.
  local -a a b
  read -r -a a <<<"$1"
  read -r -a b <<<"$2"
  local i n=${#a[@]} x y
  if (( ${#b[@]} > n )); then n=${#b[@]}; fi
  for (( i = 0; i < n; i++ )); do
    x=$(( 10#${a[i]:-0} ))
    y=$(( 10#${b[i]:-0} ))
    if (( x > y )); then return 0; fi
    if (( x < y )); then return 1; fi
  done
  return 1
}

# --- Arguments --------------------------------------------------------------------------
DRY_RUN=0
ARGS=()
for arg in "$@"; do
  case "$arg" in
    --dry-run) DRY_RUN=1 ;;
    -h|--help) usage ;;
    -*)        usage ;;
    *)         ARGS+=("$arg") ;;
  esac
done
[[ ${#ARGS[@]} -eq 3 ]] || usage
CHECKOUT=${ARGS[0]}
APP=${ARGS[1]}
TAG=${ARGS[2]}
FILE="$APP/latest.json"

[[ "$APP" =~ $APP_RE ]] || die "app id '$APP' must be lowercase letters, digits and dashes"
if [[ ! "$TAG" =~ $TAG_RE ]]; then
  notice "$TAG is not a plain vX.Y.Z release tag; $FILE left unchanged."
  exit 0
fi
[[ -d "$CHECKOUT/.git" ]] || die "$CHECKOUT is not a git checkout of the update-manifest repo"
REPO=${GITHUB_REPOSITORY:-}
[[ -n "$REPO" ]] || die "GITHUB_REPOSITORY (owner/repo of the released app) is not set"

# --- The release being announced --------------------------------------------------------
if [[ -n "${PUBLISH_RELEASE_JSON:-}" ]]; then
  RELEASE=$PUBLISH_RELEASE_JSON
else
  RELEASE=$(gh release view "$TAG" --repo "$REPO" \
    --json tagName,name,url,publishedAt,isDraft,isPrerelease) \
    || die "could not read release $TAG of $REPO"
fi
jq -e 'type == "object"' >/dev/null 2>&1 <<<"$RELEASE" || die "release data for $TAG is not a JSON object"

if [[ "$(jq -r '.isDraft' <<<"$RELEASE")" == "true" ]]; then
  notice "release $TAG is still a draft; $FILE left unchanged."
  exit 0
fi
if [[ "$(jq -r '.isPrerelease' <<<"$RELEASE")" == "true" ]]; then
  notice "release $TAG is a prerelease; $FILE left unchanged."
  exit 0
fi

RELEASE_TAG=$(jq -r '.tagName // empty' <<<"$RELEASE")
URL=$(jq -r '.url // empty' <<<"$RELEASE")
NAME=$(jq -r '.name // empty' <<<"$RELEASE")
PUBLISHED=$(jq -r '.publishedAt // empty' <<<"$RELEASE")
[[ "$RELEASE_TAG" == "$TAG" ]] || die "release data is for '${RELEASE_TAG:-?}', not $TAG"
[[ "$URL" == "https://github.com/$REPO/releases/tag/$TAG" ]] \
  || die "release URL '${URL:-?}' is not https://github.com/$REPO/releases/tag/$TAG"
[[ -n "$PUBLISHED" ]] || die "release $TAG has no publish date"
NAME=${NAME:-$TAG}

write_manifest() {
  jq -n --arg tag "$TAG" --arg name "$NAME" --arg url "$URL" --arg published "$PUBLISHED" \
    '{tag_name: $tag, name: $name, html_url: $url, published_at: $published,
      draft: false, prerelease: false}'
}

# --- Publish ------------------------------------------------------------------------------
cd "$CHECKOUT"
git config user.name "github-actions[bot]"
git config user.email "41898282+github-actions[bot]@users.noreply.github.com"

for (( attempt = 1; attempt <= ATTEMPTS; attempt++ )); do
  # Always rebuild the change on the newest main: other apps may have published since.
  git fetch --quiet origin "+refs/heads/main:refs/remotes/origin/main" \
    || die "could not fetch main of the update-manifest repo"
  git reset --quiet --hard refs/remotes/origin/main

  if [[ -f "$FILE" ]]; then
    CURRENT=$(jq -r '.tag_name // empty' "$FILE" 2>/dev/null || true)
    if [[ "$CURRENT" =~ $TAG_RE ]] && version_gt "${CURRENT#v}" "${TAG#v}"; then
      notice "$FILE already announces $CURRENT, which is newer than $TAG; left unchanged."
      exit 0
    fi
  fi

  mkdir -p "$APP"
  write_manifest >"$FILE"
  git add -- "$FILE"
  if git diff --cached --quiet; then
    echo "$FILE already announces $TAG; nothing to publish."
    exit 0
  fi

  if (( DRY_RUN )); then
    echo "dry run: would publish $FILE:"
    cat "$FILE"
    git reset --quiet --hard refs/remotes/origin/main
    exit 0
  fi

  git commit --quiet -m "$APP $TAG"
  if git push --quiet origin HEAD:refs/heads/main; then
    echo "published $FILE = $TAG ($URL)"
    if [[ -n "${GITHUB_STEP_SUMMARY:-}" ]]; then
      echo "Update manifest \`$FILE\` now announces [$TAG]($URL)." >>"$GITHUB_STEP_SUMMARY"
    fi
    exit 0
  fi

  echo "push attempt $attempt of $ATTEMPTS was rejected" >&2
  if (( attempt < ATTEMPTS )); then
    sleep $(( attempt * BACKOFF + RANDOM % (BACKOFF + 1) ))
  fi
done

die "could not push $FILE after $ATTEMPTS attempts"
