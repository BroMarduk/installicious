# installicious — Session Handoff

> **Purpose:** snapshot of where this branch stands so a fresh Claude
> session can resume work without re-discovering everything. Pair this
> with the resume prompt at the bottom.

**Last updated:** 2026-05-26 — VERSION `2.7.21`, branch `ai-refactor`.

---

## Snapshot

- **Repo:** `c:/Source Files/Personal/Bash/installicious`
- **Branch:** `ai-refactor` (NOT yet merged to `main`)
- **VERSION:** `2.7.21` (last MINOR bump = `--verify` feature landing at `2.7.0`)
- **Test suite:** 15 files under `tests/test-*.sh`. **Always run via
  the parallel runner** — sequential takes ~8 min, parallel is ~2 min:
  ```bash
  bash tests/run.sh              # parallel (default)
  bash tests/run.sh --sequential # one at a time, only for debugging ordering issues
  bash tests/run.sh --verbose    # parallel, dump every test's output even on PASS
  ```
  Exit code 0 iff every test rc=0. Failing tests' captured logs are
  dumped at the end automatically. The legacy
  `for t in tests/test-*.sh; do bash "$t"; done` loop still works but
  takes ~4× longer; use only when debugging the runner itself.
- **Latest commits (top of `git log --oneline -25`):**
  ```
  cc5992d docs: sweep user-facing files for mysql/mariadb consolidation language
  5cbabe7 database: drop the redundant `mysql` leaf; consolidate to `MariaDB / MySQL`
  b55524e options: fix step-3 truncation that dropped role_required radios
  0b0321f options: pre-filter step-5 screens to exclude pure-skip parents
  fe0d2c3 feature-weewx-setup: pre-clear weewx schema on local MySQL/MariaDB
  b260f7c weewx role: database as REQUIRED + step 5 back-loop fix
  d4b442d installicious-shell: don't claim "complete" mid-reboot
  d6c7c80 resume: PID sentinel + weewx seed empty-row check
  a1551c7 feature-weewx-onedrive-backup: surface REMOTE_NAME + REMOTE_ROOT on the menu
  5bfc278 feature-weewx-onedrive-backup: rclone.conf.override seed + verify
  0a79a5b feature-skyfield: fix do_verify paths + extension name to match upstream
  8d47ede docs: surface OneDrive pre-install quick-start in setup walkthrough
  2c01327 verify: lib/verify.sh auto-loads lib/manifest.sh for forked subshells
  6289773 feature-weewx-setup: SQLite seed + menu radio for optional-parent picks
  8e6fb3d resume: make queue summary actually reach the user
  17ba027 tests: add parallel test runner (tests/run.sh)
  526cb91 manifest: pre-warm per-file II_ID cache in registry load (test perf)
  90e8ca0 options: pre-warm manifest registry in parent shell (perf)
  702a6ad gitattributes: force LF on all text files + renormalize repo
  c5dc147 manifest+role parsers: tolerate CRLF line endings
  e5d5182 test-roundtrip: stop mutating in-tree installicious.config
  ed73f66 verify: README "Verifying an install" + MINOR bump (2.6.10 -> 2.7.0)
  ```

---

## What's landed since `2.7.0`

22 commits, all PATCH bumps. Grouped by theme:

### Correctness fixes (menu state machine)

The menu's state machine had several latent bugs that surfaced when the
user actually exercised back-navigation across roles with non-trivial
conflict graphs. All four are fixed:

- **Step-3 truncation lost role_required radios** (`b55524e`). The
  post-pick code at pick_addons_required truncated `_screens` to
  `[0..current_idx]` then re-appended cascade items. With
  `role_required="pkupd webserver database"`, picking webserver
  silently dropped database from `_screens`, so the database radio
  never fired on a fresh run — the install used a stale
  `LAST_ADDONS_PICKED` value from `state/selections.sh` instead. Fix:
  snapshot the role_required-derived screens as `_role_required_screens`
  (immutable for the stage's duration) and rebuild `_screens` from the
  snapshot + current cascade after every pick.
- **Step-5 forwarded on back-from-pick_packages with empty screens**
  (`b260f7c`). My earlier fix only handled empty-at-build-time; this
  one handles "non-empty but all parents auto-skip via conflict
  filter."
- **Step-5 pre-filter for pure-skip parents** (`0b0321f`). Parents
  whose children would all conflict-out at runtime no longer occupy
  `_idx` slots — they're filtered out at `_screens` build time,
  preventing the "BACK lands on a pure-skip slot which forwards =
  loop" hang.
- **`pick_addons_optional_exclusive` stage** (`6289773`). New step
  between merge_role and pick_addons that fires exclusive radios for
  non-required parents. Solved the case where `database` was in
  `role_default` and its sqlite/mysql/mariadb radio never fired
  because step 3 only iterates `role_required`. Database has since
  moved to `role_required` (b260f7c) but the stage stays as the
  general fix for any future role-DEFAULT parent with an exclusive
  group.

### WeeWX MySQL install reliability (`fe0d2c3`)

WeeWX 5.3.1's `_initialize_day_tables` emits bare `CREATE TABLE`
(no `IF NOT EXISTS`). If a prior install left a complete or partial
schema in mariadb (data dir persists across reboots), the next weewx
start crashes with `(1050, "Table 'archive_day_altimeter' already
exists")`. Fix in `feature-weewx-setup.sh`:

- Wait up to 30s for mariadb's root socket to respond (apt-install's
  systemd "active" can lag the socket by a couple seconds).
- Query `SELECT COUNT(*) FROM weewx.archive`. Empty/missing → DROP +
  CREATE the empty DB so weewx initializes the schema cleanly on
  restart. Any rows → preserve (real data — never wipe).
- Only fires when `_db_host_resolved` is local
  (`localhost`/`127.0.0.1`); never reaches into a remote DB.

### Resume / post-reboot UX

Three independent improvements to the chained-reboot install flow:

- **PID sentinel** (`d6c7c80`, refined to `/proc/$pid` in a later
  PATCH). `scripts/resume.sh` writes its own PID to
  `/etc/installicious/state/resume.pid` at startup; EXIT trap removes
  it. `installicious-shell.sh`'s live-tail loop now polls
  `[ -d /proc/$pid ]` (via `_installicious_resume_running()`) instead
  of the flaky `systemctl is-active`. Falls back to `systemctl
  is-active` only when the PID file is absent (legacy installs). The
  `/proc/$pid` existence check (instead of `kill -0 $pid`) lets
  non-root SSH'd users poll the root-owned resume PID without hitting
  EPERM — which previously made the live-tail loop bail one second in
  for any login other than root, so the SSH user only saw a banner
  flash before the prompt returned.
  Tail respawn on death (so OOM / SIGPIPE / tty hiccups don't
  silently end the watch).
- **Multi-reboot "Resume paused" banner** (`d4b442d`). Differentiates
  clean queue completion from interruption: queue.sh still present
  after the watch loop exits → "Resume paused — queue still has
  work." Otherwise "Installicious resume complete." Stops the
  confusing "complete" banner firing between each reboot of a
  multi-reboot install.
- **Queue summary visibility** (`8e6fb3d`). `post_install_apply` now
  tees the per-installer Succeeded / Failed / Skipped summary table
  to `FILE_LOG_INSTALLER` (color codes stripped) in addition to
  stdout. A post-mortem `cat installicious.log` shows the wrap-up
  alongside the per-installer log lines.

### Override files (drop-the-file pattern)

Two new override slots that pre-stage credentials/data on a fresh Pi:

- **`overrides/weewx.sdb.override`** (`6289773` + tightened in
  `d6c7c80`). Full SQLite archive file. On install (and only when
  the database radio resolved to SQLite), `feature-weewx-setup`
  copies it to `/var/lib/weewx/weewx.sdb` before WeeWX restarts.
  Guard: `sqlite3 SELECT COUNT(*) FROM archive` zero-rows check
  (semantic — schema-only ~512 KiB DB on Trixie isn't "real data");
  1 MiB fallback when `sqlite3` isn't on PATH.
- **`overrides/rclone.conf.override`** (`5bfc278`). Full rclone.conf
  file. `feature-weewx-onedrive-backup` copies it to
  `WEEWX_BACKUP_RCLONE_CONF` (default
  `/root/.config/rclone/rclone.conf`) as `root:root` mode `0600`
  during install — only when the live file doesn't exist (rclone
  refreshes its tokens into that file; overwriting would force
  re-auth). Force-recopy = `sudo rm` the live file and re-run.

### Other UX

- **`WEEWX_BACKUP_REMOTE_NAME` + `WEEWX_BACKUP_REMOTE_ROOT` surfaced
  on the in-menu Edit Configuration screen** (`a1551c7`). Previously
  config-file-only and a "where do I edit this?" trap.
- **Database picker consolidation** (`5cbabe7`). On Debian
  Bookworm/Trixie `default-mysql-server` resolves to mariadb-server,
  so the two-option radio was misleading. Single combined "MariaDB /
  MySQL" option. `feature-database-mysql.sh` deleted;
  `feature-database-mariadb.sh` retitled. Backward-compat preserved:
  `DATABASE_TYPE=mysql` still handled by feature-weewx-setup's
  overlay branch for installs whose `database.state` was written
  before this change.
- **`weewx-database-ram` + `weewx-onedrive-backup` declare
  `II_CONFLICTS_WITH="database-mariadb"`** so they vanish from the
  menu entirely when the user picks the MariaDB / MySQL option
  (instead of just self-skipping at install time). The conflict
  filter at pick_role_specific / pick_optional handles the rest.
- **WeeWX role: `database` is REQUIRED, not DEFAULT** (`b260f7c`).
  The radio fires in step 3 alongside webserver, BEFORE the optional
  pickers — which is what lets the conflict filter drop ram/onedrive
  before the user even sees them on non-SQLite backends.

### Robustness / infra

- **CRLF tolerance in manifest + role parsers** (`c5dc147`). The
  `_*_parse_field` helpers strip a trailing `\r` per line, so a
  Windows-checked-out feature/role file parses identically to a
  Unix one. Defensive against future CRLF intrusion regardless of
  source-side normalization.
- **`.gitattributes` + repo-wide LF renormalize** (`702a6ad`).
  Source-side fix to the same CRLF problem. `* text=auto eol=lf`
  + `git add --renormalize .` turned 41 CRLF files into LF in the
  index in a single commit.
- **Manifest registry pre-warm in `scripts/options.sh`** (`90e8ca0`).
  Calls `_manifest_registry_load` once at the top of the menu so the
  subshell-invoked `$(manifest_get_field ...)` calls find a warm
  cache instead of re-scanning all features per call. ~10×
  perf improvement on menu transitions.
- **`_manifest_registry_load` seeds `_MANIFEST_FIELDS[file|II_ID]`
  per-file** (`526cb91`). Same defect for test-manifest.sh's
  explicit-dir lookups. Cut test-manifest.sh wall clock from ~260s
  to ~73s.
- **`tests/run.sh` parallel runner** (`17ba027`). Each test file is
  self-contained (its own tempdir, no shared state) so they run
  concurrently via `&` + `wait`. Wall clock: ~500s → ~131s on this
  Windows Bash.
- **`test-roundtrip.sh` stops mutating the in-tree config** (`e5d5182`).
  Previously the test did `sed -i` on
  `config/installicious.config` and restored via an EXIT trap; if
  the test was interrupted, the trap missed and the file stayed
  dirty across sessions. Now uses `${VAR:-default}` env-var-override
  pattern in `installicious.config` so the test exports
  `PATH_STATUS`/`PATH_BACKUP` to tempdirs instead of mutating.

---

## Repo conventions a new Claude session MUST follow

- **VERSION bump per commit.** `/VERSION` PATCH-bumps with every commit. MINOR bumps are reserved for feature-complete landings (the user explicitly approves these). Started at `2.0.0` on 2026-05-05.
- **Commit trailer:** every commit message ends with
  ```
  Co-Authored-By: Claude Opus 4.7 <noreply@anthropic.com>
  ```
  Pass commit messages via single-quoted HEREDOC (`git commit -F- <<'MSG' ... MSG`).
- **Never** `git commit --amend` unless the user explicitly asks.
- **Never** `--no-verify` / `git push --force` unless the user explicitly asks.
- **`git push` after committing** is the default (rule rescinded
  2026-05-26 — see `memory/feedback-push-default.md`). Destructive
  remote ops (`git push --force`, force-push to `main`, branch deletes
  on origin) still require explicit user permission.
- **Use dedicated tools:** `Edit` / `Write` / `Glob` / `Grep` over `sed` / `grep` / `cat`. Reserve `Bash` for shell-only ops.
- **OS support:** Debian / Raspberry Pi OS **Bookworm + Trixie**. Forky/Duke forward-compat in code. Bullseye and earlier dropped.
- **README + override-example currency:** update `README.md` and `overrides/configuration.override.example` whenever a feature's user-visible behavior or editable config changes — they're the user-facing catalog.

## Test pattern (for any new tests)

Each `tests/test-*.sh` is self-contained: defines its own `ok` / `fail` /
`chkeq` / `chkrc` helpers, uses a tempdir-isolated env, no shared
fixtures. Stub external binaries via a `$TEST_TMPDIR/bin` directory
prepended to `PATH` (**do not** name the variable `TMPDIR` — that
shadows `mktemp`'s env var). Reference shapes:
- `tests/test-manifest.sh` (the canonical helper-set layout)
- `tests/test-database.sh` (PATH_STATE/CONFIG/STATUS tempdir env pattern)
- `tests/test-verify.sh` (stub-binary `PATH` injection pattern)

## Skill workflow that's been working

When taking on a non-trivial new feature:

1. **`superpowers:brainstorming`** — explore intent + design space, settle approach + scope, save spec to `docs/superpowers/specs/YYYY-MM-DD-<feature>-design.md`, commit it.
2. **`superpowers:writing-plans`** — convert the spec to a phased plan at `docs/superpowers/plans/YYYY-MM-DD-<feature>.md`. Each phase = one commit-sized chunk + a PATCH bump; final phase MINOR-bumps.
3. **`superpowers:subagent-driven-development`** — dispatch ONE implementer subagent per phase (full plan-phase text inline; agents don't read files). Each phase gets a spec-compliance review + a code-quality review. Address minor issues with a fixup commit (PATCH bump, shifts subsequent phases by 1).

For small follow-ups (one or two files, <30 lines), skip the skill flow and just do them inline with a PATCH-bump commit. Most of tonight's 22 commits took this path.

---

## Memory system

Persistent memory lives at
`C:\Users\begal\.claude\projects\c--Source-Files-Personal-Bash-installicious\memory\`.
A new session auto-loads `MEMORY.md` from there and reads individual
memory files as needed. Highlights worth knowing about already in
memory:

- VERSION-bump policy (PATCH per commit, ask before MINOR/MAJOR)
- README maintenance rule
- `configuration.override.example` maintenance rule
- Autonomous-continuation guideline (don't gate on permission for routine commits after a plan is approved)
- Project state notes about the 6-pillar refactor + OS scope

Don't dump new memories about the work just landed — the spec / plan
files already capture the decisions, and `git log` covers the history.

---

## Open follow-ups (none blocking)

- **Cloud restore from OneDrive backup** — the user proposed adding a
  feature to restore weewx.sdb (and possibly other overrides) from a
  prior OneDrive backup on a fresh install. We started brainstorming
  (scope: which files; trigger model; security of credentialed
  overrides). User said "let's hold off on this for now." Pick up
  there if they raise it again.
- **Step-3 UX: two back-to-back radios in quick succession.** The
  webserver radio and database radio both fire in step 3. Visually
  similar whiptail dialogs — the database one is easy to miss if the
  user blasts through with Enter. User said this is acceptable
  ("I'm fine with the two back to back radios.") but flagged that
  the database radio should ALWAYS fire after the webserver one
  (which is what `b55524e` fixed). Could revisit by making the
  whiptail title more distinct ("MariaDB / MySQL — Pick One" feels
  unmistakeable) or by inserting a brief msgbox between radios. Not
  pressing.
- **Refactor existing Pi-tier callers** — `feature-ram-logging` and
  `feature-compressed-swap` still use inline Pi-tier detection. The
  shared `lib/pi-tier.sh` (added by feature-database Phase 4) could
  replace those loops in a small refactor. Carried over from the
  previous handoff.
- **The `verify_dpkg_installed` substring match** is documented in a
  comment; no action needed.

---

## Suggested next steps (if/when the user wants to keep going)

- **End-to-end Pi smoke** with VERSION 2.7.21 — fresh image, weewx
  role with MariaDB picked, drop weewx.sdb.override + rclone.conf.override
  in place pre-install, watch the multi-reboot resume cycle, confirm
  the summary table prints at end-of-queue, verify the website shows
  up at `https://<pi-ip>/`.
- **Push + open a PR** for `ai-refactor` → `main`. The branch has 50+
  commits of substantive work since `main` and is in a clean,
  all-tests-green state.
- **Refactor existing Pi-tier callers** to use `lib/pi-tier.sh`.

---

## Resume prompt (paste this into a fresh Claude session)

```
I'm continuing work on installicious — a Bash framework for setting up
Raspberry Pi devices. The repo is at `c:/Source Files/Personal/Bash/installicious`
on branch `ai-refactor`. VERSION is currently 2.7.21.

Before doing anything else, please:

1. Read `docs/HANDOFF.md` — it's the session-handoff snapshot covering
   what's landed (22 commits of menu-flow correctness, WeeWX install
   reliability, resume UX, override-file features, perf/robustness),
   repo conventions, the skill workflow we use, the memory system,
   and a list of open follow-ups.

2. Confirm the test suite is green — use the PARALLEL runner so this
   takes ~2 minutes instead of ~8:
     bash tests/run.sh
   Exit 0 means every test passed. (Legacy `for t in tests/test-*.sh`
   loop still works but is ~4× slower; use only for debugging.)

3. Skim `git log --oneline -25` so you have the recent-work context.

After that, tell me where you think we should pick up next — or ask
me what I want to work on. Standard repo conventions apply:
- PATCH bump VERSION every commit (MINOR only on explicit approval).
- Commit trailer "Co-Authored-By: Claude Opus 4.7 <noreply@anthropic.com>".
- No git push / no --amend / no --no-verify without my explicit ask.
- Use Edit/Write/Glob/Grep over sed/grep/cat.
```
