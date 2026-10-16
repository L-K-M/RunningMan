# Release workspace cleanup

The canonical helper is `scripts/release-job.swift`. Participating repositories
vendor the same file so a release does not download or execute a moving script
from another repository. It requires the Swift toolchain already used to build
the Mac apps; it has no Python or other package dependency.

## Workflow integration

After checkout, run `prepare` on the self-hosted Mac. It makes a unique private
directory immediately under `RUNNER_TEMP`, clones only committed source and Git
history into it without hard links, and exports these entries through
`GITHUB_ENV`:

- `RELEASE_JOB_ROOT`: the owned temporary directory.
- `RELEASE_JOB_WORKSPACE`: its isolated source checkout.
- `RELEASE_CLEANUP_RECEIPT`: the private report outside the temporary directory.

Run build, package and release-upload commands with the isolated checkout as
their working directory. Explicitly pin any supported output-directory override
there too. Temporary staging can use `RELEASE_JOB_ROOT/tmp` for that command,
but do not export `TMPDIR` for the entire job: action post hooks run later.
Asset-upload actions need the corresponding absolute paths in this workspace.
Do not fall back to old checkout artifacts if preparation failed.

The last ordinary step, after all release and diagnostic upload attempts, is:

```yaml
- name: Clean job-owned release workspace
  if: always() && env.RELEASE_JOB_ROOT != ''
  continue-on-error: true
  run: swift "$GITHUB_WORKSPACE/scripts/release-job.swift" cleanup
```

The helper path points to the original checkout, not the directory being removed.
Cleanup failure remains visible through its failed step and report, but does not
invalidate an uploaded release or block its update announcement. A successful
cleanup says nothing about whether the upload itself succeeded.

Cache actions that save job-local build trees in a post hook cannot target a
directory removed by this ordinary final step. The local translation release
therefore uses disposable compiled outputs without that Rust cache action.
Shared installed tools and package-download caches remain outside this cleanup.
GitHub-hosted fallback jobs keep their existing ephemeral-machine behavior.

## Ownership and limits

Cleanup requires a matching UUID marker, original temporary parent, repository,
run, attempt, job and receipt. It refuses a replacement symlink or an unmarked
directory, and removes only the marked workspace. It never prunes global caches,
runner settings, diagnostic logs, development checkouts or older build folders.
Copies of source and local Git objects inside the temporary workspace are removed
along with its generated build files.

The original checkout and the release tag must include the helper. Older tags
without it do not gain cleanup retroactively; use a newer release commit or the
hosted fallback. No existing runner installation is changed to install a cleanup
hook.

Normal failure and cancellation can reach the final step. Power loss, a killed
runner or failure to prepare the workspace can prevent it. A missing or pending
report is unconfirmed cleanup, never inferred success. Remaining owned scratch
is preserved when its ownership cannot be verified.

## RunningMan reports

Reports are private JSON files in `<runner work directory>/.runningman-cleanup/`.
They contain the workflow identity, timestamps, result, workspace path and counts
of logical bytes and files removed. They do not contain tokens or raw build logs.
File sizes are estimates and do not measure recovered capacity on APFS.

RunningMan discovers the public GitHub runner work-directory setting, reads
bounded reports in the background, and shows the latest 100 per runner. It never
executes a report path or deletes anything through this view. Legacy releases and
Forgejo jobs without this reporting integration have no cleanup evidence.

When changing the format or helper, update the Core reader and fixture tests in
the same change, then copy the canonical helper byte for byte into participating
repositories.
