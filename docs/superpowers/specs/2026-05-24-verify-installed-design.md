# Design — `installicious --verify` (post-install validator)

**Status:** Approved 2026-05-24
**Author:** Dan Begallie (with Claude)
**Companion plan:** `docs/superpowers/plans/2026-05-24-verify-installed.md` (to be written)

## 1. Goal

Give the user an on-demand command that confirms every installer Installicious has touched on a given machine is currently installed AND running/listening as expected, and reports — for each item — one of three states: `OK`, `FAIL`, or `NOT INSTALLED`.

Non-goals: auto-running at the end of an install, JSON output, cross-host comparison, persisted history of verify results.

## 2. Operational shape

The command is `installicious --verify`, a top-level flag on the existing entry point. It mirrors the existing `--uninstall` flag (see `installicious.sh:129-177`).

| Invocation | Behavior |
|---|---|
| `installicious --verify` | Verify every installer with a status file (i.e. it's been touched at least once on this box). |
| `installicious --verify <id>...` | Verify only the named IDs. Each named ID is always shown — if it has no status file, it appears as `NOT INSTALLED`. |
| `installicious --verify --all` | Verify every installer in the manifest registry (`features/` + `packages/`). NOT INSTALLED rows for everything not on this box. |
| `installicious --verify --list` | Print the table of all known IDs + titles and exit 0 without running any checks. Same column widths as the verify rows so users can copy IDs out. |
| `installicious --verify --verbose` (or `-v`) | Add per-check command + result to each row. Off by default. |

Privilege: `--verify` does NOT require root. The existing `EUID -ne 0` gate at the top of `installicious.sh` is skipped when `--verify` is the first arg. Most checks are read-only (`dpkg-query`, `systemctl is-active`, `ss`); any check that needs root is the individual `do_verify`'s problem and it should `sudo -n` and treat a missing sudo as a FAIL reason.

## 3. Result model

Three states per item, mapped to exit codes the per-installer `--verify` mode returns to the dispatcher:

- **OK (0)** — every check passed.
- **FAIL (1)** — at least one check failed; the script prints one line per failed reason to stdout.
- **NOT INSTALLED (2)** — `status_state $II_ID` is not `completed`. The verifier doesn't run any checks; it reports the underlying state.

The dispatcher's overall exit code is `0` if zero items FAILed, `1` otherwise. Unknown IDs on the CLI (`--verify nosuchfeature`) exit `2` without running any verifications.

The number `2` therefore has two distinct meanings at two distinct layers: a *per-installer* `--verify` returning 2 means "this item is NOT INSTALLED"; the *dispatcher* exiting with 2 means "you passed an unknown ID on the CLI." They never overlap in practice — the dispatcher's overall exit code is only ever 0 or 1, and the per-script exit codes never reach the user directly.

## 4. Verifier contract

Each installer gains a `--verify` mode in its existing arg parser:

```bash
case "$1" in
  --install)   MODE="install" ;;
  --uninstall) MODE="uninstall" ;;
  --verify)    MODE="verify" ;;
  *) echo "Unknown argument: $1" >&2; exit 2 ;;
esac
...
if   [[ $MODE == "install" ]];   then do_install
elif [[ $MODE == "uninstall" ]]; then do_uninstall
else                                  do_verify
fi
exit $?
```

`do_verify` returns 0/1/2 as defined above, prints reason lines for any failed check (or the underlying state on NOT INSTALLED) to **stdout** (one line per reason, no badge prefix — the dispatcher adds the badge), and writes one `WARN` line per failed check to the installicious.log via `log_warn`. **`do_verify` is quiet on success** (no log line, no stdout) so the log keeps a history of past verify runs without exploding on green runs.

The contract for `do_verify` authors:

- The first thing `do_verify` must do is check `status_state $II_ID`. If it's not `completed`, print one reason line describing the state and return 2 — do not run any other checks. The helper `verify_require_completed_state <id>` in `lib/verify.sh` does this for you (returns 2 with the reason already echoed if not completed, returns 0 otherwise). `verify_generic` calls it internally; custom `do_verify` implementations must call it explicitly at the top.
- Reason lines go to stdout via plain `echo` or `printf`. Internal helpers (the primitives in `lib/verify.sh`) emit their diagnostics to stderr for the benefit of direct callers; `do_verify` is responsible for re-emitting to stdout when it wants the dispatcher to surface the reason. The simplest pattern is to capture and forward: `if ! verify_systemd_active nginx 2>&1; then ... return 1; fi`.

Installers without custom verification logic implement `do_verify` in one line:

```bash
do_verify() { verify_generic "$II_ID"; }
```

`verify_generic <id>` is provided by the new `lib/verify.sh` and does:

1. Status check — `status_state $id` must be `completed`, otherwise return 2.
2. For every package in `II_APT_PACKAGES` whose status-file pre-state is `false` (we own it), run `verify_dpkg_installed`.
3. If the manifest declares `II_SERVICE="<unit>"` (new optional field), run `verify_systemd_active`.
4. If steps 2 and 3 had nothing to check (no apt packages we own AND no II_SERVICE), print one stdout line `(no liveness checks declared)` and return 0. Honest about it being a trust-the-installer pass, encourages adding `do_verify` later, doesn't pollute the FAIL count.

## 5. Architecture & file layout

### New files

- **`lib/verify.sh`** — reusable primitives + the generic fallback. Each primitive returns 0/1 and prints one stderr diagnostic on failure.

  | Helper | Implementation |
  |---|---|
  | `verify_dpkg_installed <pkg>` | `dpkg-query -W -f='${Status}' $pkg \| grep -q "ok installed"` |
  | `verify_systemd_active <unit>` | `systemctl is-active --quiet $unit` |
  | `verify_port_listening <port> [tcp\|udp]` | `ss -lnt` / `ss -lnu` parse |
  | `verify_file_exists <path>` | `[[ -e $path ]]` |
  | `verify_require_completed_state <id>` | Reads `status_state $id`; if not `completed`, echoes the reason to stdout (`state=<x>` or `no status file`) and returns 2. Returns 0 silently otherwise. |
  | `verify_generic <id>` | See §4 |

- **`tests/test-verify.sh`** — table-tested coverage of the primitives, the generic fallback, the dispatcher's ID resolution, output formatting, and edge cases. Five test groups, detailed in §8.

### Modified files

- **`installicious.sh`** — a new `--verify` arg-handler block placed directly after the existing `--uninstall` block (around line 178). Bypasses the menu, the `state_exists` resume hand-off, and the whiptail dependency check (verify must work even on a half-broken box). Sources `lib/log.sh`, `lib/status.sh`, `lib/manifest.sh`, `lib/verify.sh`.

- **`lib/installer_apt.sh`** — `installer_apt_main` learns a `--verify` case in its arg parser and a `_installer_apt_do_verify` body that calls `verify_generic "$II_ID"`. One edit frees up every `package-*.sh` that uses `installer_apt_main` (currently every package script).

- **`lib/manifest.sh`** — no code change; the header comment documenting `II_*` fields gains a paragraph for the new optional `II_SERVICE`.

- **Every `feature-*.sh` (~22 files)** — a 2-line `--verify) MODE="verify" ;;` addition in the existing arg parser, plus an `if [[ $MODE == "verify" ]]` branch at the bottom. Features without custom verification just call `verify_generic "$II_ID"`. Features that need more (e.g. `nginx -t`, weewx web root content) add a `do_verify()` body opportunistically.

- **`README.md`** — new "Verifying an install" section per the README-currency rule.

### No changes to

Status files (schema unchanged — the verify dispatcher reads them but doesn't write to them), log format, state/queue files, manifest format (only adds an opt-in optional field).

## 6. Dispatcher flow

In `installicious.sh`, after detecting `--verify`:

1. Skip the root-privilege gate, the menu/resume bypass, and the whiptail dependency install.
2. Source `config/installicious.config`, `lib/log.sh`, `lib/status.sh`, `lib/manifest.sh`, `lib/verify.sh`.
3. Parse remaining args: `--list`, `--all`, `--verbose`/`-v`, positional IDs.
4. If `--list`: print the table of all `manifest_list_ids` entries with their `II_TITLE`, exit 0.
5. Resolve the target ID set:
   - `--all` → `manifest_list_ids` (every registry entry, in registry order).
   - positional IDs → validate each via `manifest_path_for`; unknown → print `unknown id: <foo>` and exit 2 without running any other verifications (matches `--uninstall` behavior at `installicious.sh:147`).
   - no args → glob `$PATH_STATUS/*.status`, strip `.status`, exclude `os.status`.
6. For each ID, in registry order:
   - Resolve script path via `manifest_path_for` → invoke `bash <script> --verify` (subprocess; matches `--install` / `--uninstall` isolation).
   - Capture stdout (the reason lines) and exit code (0/1/2/other).
   - Print the row (see §7); on FAIL or NOT INSTALLED, indent the captured reasons under it.
   - Increment the appropriate counter.
7. Print the summary block and `exit (fail_count > 0 ? 1 : 0)`.

## 7. Output format

Row format (fixed-width for scannability):

```
[  OK  ] <id padded to 22> — <title>
[ FAIL ] <id padded to 22> — <title>
           <reason line, indented 11>
           <reason line, indented 11>
[ NOT  ] <id padded to 22> — <title or state description>
```

- `<id>` left-padded to 22 chars (longest current ID is `weewx-onedrive-backup` = 21).
- `<title>` is `II_TITLE`; falls back to the bare ID if missing.
- For NOT INSTALLED rows, column 2 is the title; the underlying state reason (`state=uninstalled`, `state=reboot-pending`, `state=failed: <last-error>`, or `no status file`) goes on an indented cyan line below.

Colors (match the existing convention in `features/feature-nginx.sh:141`):

| State | Code |
|---|---|
| OK   | green  `\e[0;32m` |
| FAIL | red    `\e[0;31m` |
| NOT  | cyan   `\e[0;36m` |

Summary block:

```
============================================================
  Verify summary
============================================================
  OK:            12
  FAIL:           1
  NOT INSTALLED:  3
============================================================
```

Sample full output:

```
[  OK  ] nginx                  — nginx
[ FAIL ] mariadb                — MariaDB database server
           systemctl is-active mariadb: inactive
[ NOT  ] motd-weather           — MOTD weather panel
           state=uninstalled
============================================================
  Verify summary
============================================================
  OK:            12
  FAIL:           1
  NOT INSTALLED:  3
============================================================
```

## 8. Testing

`tests/test-verify.sh` follows the existing tempdir-isolated style of `tests/test-status.sh` / `tests/test-installer-apt.sh`. No real apt or systemd contact; the system binaries are stubbed via a tempdir at the front of `PATH`.

### 8.1 Primitives

Each of `verify_dpkg_installed`, `verify_systemd_active`, `verify_port_listening`, `verify_file_exists` is exercised against a stubbed binary that echoes a controlled response and exits with a controlled code. Assertions check rc + the diagnostic stderr line on failure. `verify_require_completed_state` is exercised with synthetic status files in a tempdir: `state=completed` → rc 0 silent, every other state → rc 2 with the expected stdout reason line.

### 8.2 Generic verifier

Synthetic installer in a tempdir with manifest declaring `II_APT_PACKAGES="foo bar"` and `II_SERVICE="foo"`, status file with `FOO_FW_PRE_INSTALLED=false` and `BAR_FW_PRE_INSTALLED=true`:

- All-green case → OK (rc 0).
- dpkg-stub says foo missing → FAIL (rc 1), reason mentions foo.
- systemctl-stub says foo inactive → FAIL (rc 1), reason mentions the unit.
- status state != completed → rc 2, no checks run.
- Pre-existing-only package (PRE_INSTALLED=true) is *not* checked.
- No apt packages we own AND no II_SERVICE → OK with `(no liveness checks declared)` stdout.

### 8.3 Dispatcher ID resolution

The dispatcher's main loop is extracted into a callable shell function (`verify_dispatch_main`) so tests don't have to fork `installicious.sh`. Against synthetic registries:

- `--all` walks the registry in order.
- No-args walks `*.status` only (excluding `os.status`).
- Explicit IDs are always shown even when no status file exists.
- Unknown ID → exit 2 without running any other verifications.

### 8.4 Output formatting

Capture dispatcher output, strip color codes, assert row format (badge, ID padding, em-dash, title), summary block contents, and the final exit code (0 with zero FAILs, 1 with any FAIL).

### 8.5 Edge cases

- Manifest exists, script file missing → FAIL with reason `installer script not found at <path>`.
- Script exits with unexpected code (3+) → FAIL with reason `verifier returned unexpected exit code N` + captured stdout.
- Verbose flag adds the per-check command + result to each row.

### Manual smoke test (not automated)

After each new `do_verify` block lands, run `installicious --verify --list` and `installicious --verify` on a real Pi to catch real-systemd / real-dpkg surprises the stubs can't model.

## 9. Rollout

The design supports incremental adoption. Order suggested for the implementation plan:

1. `lib/verify.sh` + `tests/test-verify.sh` primitives and `verify_generic` (§8.1–8.2).
2. Dispatcher in `installicious.sh` + dispatcher tests (§8.3–8.5).
3. `installer_apt_main` learns `--verify` (frees every `package-*.sh`).
4. Add `--verify` case to each `feature-*.sh` (mechanical; can be batched).
5. Hand-write `do_verify` bodies for features where the generic fallback isn't enough (nginx, apache, lighttpd, caddy, mariadb, mysql, sqlite, weewx-setup, weewx-*-ram, weewx-onedrive-backup). Each is opportunistic — the framework works without them.
6. README "Verifying an install" section.

Step 1 alone delivers no user-visible feature; the first user-visible step is 3 (every package script becomes verifiable after one edit). Steps 4–5 deepen coverage over time and don't have to land in one commit.
