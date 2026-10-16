# Working on RunningMan

Read README.md and docs/architecture.md. This is an independent native macOS app in the personal L-K-M/RunningMan repository.

- Keep RunningManCore Foundation-only. Keep SwiftUI/AppKit in the app target and subprocess/GitHub integration in RunningManServices.
- Discovery and app launch are read-only toward runner installations. Never execute discovered binaries merely to identify them.
- Start, stop, enable/disable and login startup are separate operations. Preserve startup policy when stopping. Never restart a job because a checkbox changed.
- Busy or uncertain state must block interruption unless the UI's explicit confirmation supplies force.
- Validate per-user service ownership and paths before changing launchd state. Never use sudo, broad pkill, or modify system LaunchDaemons.
- Never read runner credential files or extract a permanent GitHub CLI token. Keep registration/removal tokens ephemeral, out of argv and logs.
- Verify the official runner asset digest and extraction paths. Preserve existing directories and incomplete registration evidence. Removal preserves files unless explicitly moving the selected installation to Trash.
- Keep log work off the UI actor, reads and history bounded, incremental offsets robust to rotation, and exported/displayed credentials redacted.
- Tests use synthetic data, fake executors and temporary home directories. Do not mutate installed runners or GitHub registrations to test code.
- Demo mode must not modify live runners, preferences or imported-directory settings. Keep demo data fictional; no company names, credentials, user paths or actual job logs in tracked files.
- Run swift test, the applicable build and preview smoke test. Inspect rendered light/dark screenshots after UI changes.
- Preserve the existing LICENSE and ignored IDE files.
