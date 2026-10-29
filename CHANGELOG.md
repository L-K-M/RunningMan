# Changelog

All notable changes to this project are documented here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/); release tags are
`vX.Y.Z` cut by `scripts/release.sh` (see AGENTS.md → Releases).

## [Unreleased]

### Added
- Small and medium desktop widgets for runner availability and recorded job results.
- Background mode: open RunningMan at login in the menu bar, without its window or
  Dock icon. With automatic refresh on, the menu bar and desktop widgets stay current.
- Step-by-step job log for GitHub runners (#23)
- Canonical `CLAUDE.md`, `CHANGELOG.md`, Dependabot for Actions, and the
  two-tier Z.ai review workflow. Bundle id moved to `ch.lkmc.RunningMan`;
  Forgejo services installed under the legacy `io.github.l-k-m` label prefix
  remain managed.

### Fixed
- The desktop widgets shipped in 1.3.0 and 1.4.0 never appeared in the widget
  gallery: their extension started at SwiftPM's `main` and trapped in
  ExtensionFoundation. It now starts at `NSExtensionMain` like Xcode-built
  extensions, and `build-app.sh` refuses a build that does not.

## [1.0.0] - 2026-10

### Added
- Monitor Forgejo runners run as system daemons (#4)
- LLM disclosure in the README; `ANALYSIS.md` roadmap

### Fixed
- Preview smoke test no longer stalls before capture; CI preview step is
  blocking again

## [0.2.0] - 2026-10

### Added
- RunningMan app: discover and control self-hosted GitHub Actions and Forgejo
  runners — queues, utilisation, recent activity, start/stop/enable,
  start-at-login
- Release cleanup results surfaced in the UI (#3)
- Retro action artwork app icon (#2)
- Release tooling, once-a-day update alerts, and main-branch CI

### Fixed
- `lipo` argument order in the architecture checks
- Bound the preview smoke step on hosted runners
