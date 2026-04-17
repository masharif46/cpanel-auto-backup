# Contributing

Thanks for considering a contribution. This project is small on purpose — most bug fixes are a dozen lines — so contributing should be quick.

## Contents

- [Scope](#scope)
- [Getting set up](#getting-set-up)
- [Code style](#code-style)
- [Testing](#testing)
- [Submitting a PR](#submitting-a-pr)
- [Filing a bug report](#filing-a-bug-report)
- [Release process](#release-process)

## Scope

In-scope:

- Bug fixes for existing features.
- Making the script more robust (better pre-flight checks, clearer errors).
- Support for new S3-compatible providers / upload drivers.
- Documentation improvements.
- CI / ShellCheck cleanup.

Out-of-scope (for now):

- Rewrites in another language.
- Features that require a daemon, background process, or web UI.
- Incremental / deduplicating backup modes — use `restic` alongside instead.

If you're not sure, open a discussion or issue first.

## Getting set up

```bash
git clone https://github.com/masharif46/cpanel-auto-backup.git
cd cpanel-auto-backup

# Run ShellCheck locally (same command CI uses):
shellcheck -S warning backup-cpanel.sh lib/*.sh scripts/*.sh

# Syntax-check every script:
for f in backup-cpanel.sh lib/*.sh scripts/*.sh; do bash -n "$f" || echo "FAIL: $f"; done
```

You don't need a cPanel server for most changes — ShellCheck + `--dry-run` cover a lot. For anything that touches `pkgacct`, `restorepkg`, or MySQL, a test VM with cPanel trial is the only way to verify end-to-end.

## Code style

Bash style rules:

- `set -Eeuo pipefail` + `IFS=$'\n\t'` at the top of every top-level script.
- Library files (`lib/*.sh`) are **sourced**, not executed — don't set the above there.
- Use the existing `log_info` / `log_warn` / `log_error` / `log_debug` — do NOT write to stdout/stderr directly.
- Prefer `run_cmd` / `safe_cmd` over raw `eval` so dry-run mode is respected.
- Quote variables (`"${foo}"`, not `$foo`).
- Use `[[ ... ]]` over `[ ... ]`.
- Avoid unnecessary subshells (`$(cmd)` is fine; deep nesting is not).
- Comments: explain **why**, not what. The code shows what.

Shell version target: Bash 4.2+ (available on RHEL 7+). Don't use `${var,,}` then-new-in-5.x things without a guard.

## Testing

There's no automated test suite — it's a tool that runs on live systems, and cleanly mocking `pkgacct` / `mysqldump` / `rsync` costs more than it earns. Instead:

1. **ShellCheck** gates merges at `warning` severity. CI runs it on every `.sh` file.
2. **`--dry-run --verbose` must succeed** on a real cPanel server after any non-trivial change. Attach the dry-run log to your PR.
3. For changes that affect a specific phase, run that phase in isolation:
   ```bash
   sudo ./backup-cpanel.sh --system-only --verbose        # tar + manifest
   sudo ./backup-cpanel.sh --databases-only --verbose     # mysqldump
   sudo ./backup-cpanel.sh --accounts-only --no-upload    # pkgacct
   ```

## Submitting a PR

1. Fork, branch off `main`. Branch name: `fix/something` or `feat/something-short`.
2. One logical change per PR. "refactor + new feature" → two PRs.
3. Commit messages: Conventional Commits prefix (`fix:`, `feat:`, `docs:`, `chore:`, `ci:`). First line ≤ 72 chars.
4. Update [CHANGELOG.md](../CHANGELOG.md) under `[Unreleased]`.
5. If you added a config option, document it in [CONFIG.md](CONFIG.md) **and** in `config/backup.conf.example`.
6. If you added a remote driver, document it in [REMOTE.md](REMOTE.md) and add a troubleshooting entry to [TROUBLESHOOTING.md](TROUBLESHOOTING.md).

## Filing a bug report

A good report has:

- Version: `cpanel-auto-backup --version`.
- OS / cPanel version.
- Relevant section of `backup.conf` with credentials redacted.
- The last 50 lines of `/var/log/cpanel-auto-backup/backup-<latest>.log`.
- What you expected vs. what happened.

See [TROUBLESHOOTING → Collecting a support bundle](TROUBLESHOOTING.md#collecting-a-support-bundle).

## Release process

1. Merge everything destined for the release into `main`.
2. Bump `SCRIPT_VERSION` in `backup-cpanel.sh`.
3. Move `[Unreleased]` entries in `CHANGELOG.md` under a new `[X.Y.Z] - YYYY-MM-DD` heading.
4. Commit: `chore: release vX.Y.Z`.
5. Tag (annotated): `git tag -a vX.Y.Z -m "vX.Y.Z — one-line summary"`.
6. `git push && git push --tags`.
7. On GitHub, **Releases → Draft a new release**, pick the tag, paste the changelog section.

Semver:

- **patch** — bug fixes, docs, internal refactors.
- **minor** — new feature, new config option, new remote driver. Existing configs still work.
- **major** — breaking config change, removed CLI flag, renamed file paths.
