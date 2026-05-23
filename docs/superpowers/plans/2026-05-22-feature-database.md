# feature-database Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Implement the generic `feature-database` (sqlite/mysql/mariadb radio) for installicious per [docs/superpowers/specs/2026-05-22-feature-database-design.md](../specs/2026-05-22-feature-database-design.md).

**Architecture:** Parent + three hidden children mirroring `feature-webserver`'s `II_OPTIONAL_GROUP` radio. State written to `/etc/installicious/state/database.state` (+ `database.creds`). `feature-weewx-setup` overlays `weewx.conf` for non-SQLite. `feature-weewx-database-ram` + `feature-weewx-onedrive-backup` self-skip when DB type is not sqlite.

**Tech Stack:** Bash 5 (installicious is Bash); apt (mariadb-server / mysql-server / python3-pymysql); SQLite/MySQL/MariaDB; systemd timers; rclone (existing); configobj via `resources/weewx-merge-overrides.py` (existing). Test framework: per-file inline `ok`/`fail`/`chkeq`/`chkrc` helpers — see [tests/test-manifest.sh:13-16](../../../tests/test-manifest.sh#L13-L16).

**Branch:** `ai-refactor`. Spec committed at `976c7fa`; VERSION currently `2.5.1`.

---

## Pre-flight checklist (read once before Phase 1)

- All work happens on the `ai-refactor` branch. No worktree needed — the prior session has been working directly on `ai-refactor` throughout.
- After each phase: run the full test suite (`for t in tests/test-*.sh; do bash "$t"; done`), confirm all 13 files rc=0, then commit. The codebase has 13 test files; each prints `=== Done ===` at the end (test-bash-match.sh is the lone exception — last line is a stub `alias`).
- Per-commit PATCH bump per [memory: installicious-version-bump](../../../). Final phase MINOR bumps `2.5.1` → `2.6.0` to mark the feature landing.
- The repo's commit convention: end every commit with the trailer `Co-Authored-By: Claude Opus 4.7 <noreply@anthropic.com>` (the existing trailer string used on recent commits in this repo). Pass commit messages via single-quoted HEREDOC.
- Use the existing dedicated tools: `Edit`/`Write` over `sed`, `Grep` over `grep`. Never `git commit --no-verify`.
- The "no choices file" pattern for free-form keys + the `_applies_/_choices_/_default_` helper convention live in [features/feature-pkupd.choices.sh](../../../features/feature-pkupd.choices.sh) (the model file for radio choices) and [features/feature-webserver.choices.sh](../../../features/feature-webserver.choices.sh) (the model file for `_default_` helpers).

---

## File structure

### New files
| Path | Purpose |
|---|---|
| `features/feature-database.sh` | Parent grouping feature — declares `II_OPTIONAL_GROUP` and the editable keys. No install work. |
| `features/feature-database.choices.sh` | `_applies_DATABASE_*` helpers (gate keys when SQLite picked); `_choices_DATABASE_INNODB_TUNE` (off/on radio). |
| `features/feature-database-sqlite.sh` | No-op leaf — writes `database.state` with `DATABASE_TYPE="sqlite"`. |
| `features/feature-database-mysql.sh` | Thin shell that delegates to `lib/database.sh` with `mysql-server` as the package. |
| `features/feature-database-mariadb.sh` | Same shell, `mariadb-server`. |
| `config/database.config` | Generic defaults (HOST=SELF, NAME=AUTO, USER=AUTO, PASS=AUTO, PORT, INNODB_TUNE=off, INNODB knobs). |
| `config/database-weewx.config` | WeeWx-specific defaults (`DATABASE_DEFAULT_NAME=weewx` + per-DB Python pkg lists). |
| `lib/database.sh` | Shared install/uninstall/provisioning helpers for the MySQL-family children. |
| `lib/pi-tier.sh` | Pi-RAM-tier detection helper used by the InnoDB buffer-pool auto-sizing (and reusable by `feature-ram-logging` / `feature-compressed-swap` later). |
| `tests/test-database.sh` | Unit tests for `lib/database.sh` helpers (AUTO resolution, remote-DB rule, applicability). |

### Modified files
| Path | Change |
|---|---|
| `roles/role-weewx.sh` | Add `database` to `ROLE_FEATURES_DEFAULT`; update planning comment. |
| `features/feature-weewx-setup.sh` | Add `II_DEPS+=" database"`; source `database.state`; generate weewx.conf overlay for non-SQLite. |
| `features/feature-weewx-database-ram.sh` | Self-skip when `DATABASE_TYPE != sqlite`. |
| `features/feature-weewx-onedrive-backup.sh` | Same self-skip in `do_install` AND the embedded runtime script. |
| `tests/test-manifest.sh` | Add `database`, `database-sqlite`, `database-mysql`, `database-mariadb` to the roster strings (Test 7 line 109; Test 10 line 229). |
| `tests/test-role.sh` | Update WeeWx `ROLE_FEATURES_DEFAULT` assertion. |
| `tests/test-scheduler.sh` | Add a case proving `weewx-setup` orders after `database`. |
| `README.md` | New "Database" section + role table update. |
| `overrides/configuration.override.example` | New section for the 5 editable DATABASE_* keys. |
| `VERSION` | PATCH bumps per phase; MINOR bump on phase 7 (→ `2.6.0`). |

---

## Phase 1 — Framework + SQLite + role wiring (→ VERSION 2.5.2)

The user-visible deliverable: running installicious with the WeeWx role surfaces a `database` row in DEFAULT; the radio fires; only `sqlite` is pickable (the only child); the picked child writes `database.state`. Five of the editable keys are hidden because the only pick is SQLite. No other behavior change.

### Task 1.1: Create the parent `feature-database.sh`

**Files:**
- Create: `features/feature-database.sh`

- [ ] **Step 1: Write `features/feature-database.sh`**

```bash
#!/bin/bash

# Module:      Database (parent grouping feature)
# Description: Pure grouping shell. Selecting "database" triggers a
#              single-select sub-menu (II_OPTIONAL_GROUP_MODE="exclusive")
#              where the user picks ONE of sqlite / mysql / mariadb.
#              The chosen child writes /etc/installicious/state/database.state
#              so downstream features (feature-weewx-setup, the WeeWX
#              backup runtime script, etc.) can read DATABASE_TYPE and
#              wire WeeWX (or any future role's consumer) at install
#              time.
#
#              Five editable keys live on this parent (II_EDITABLE_CONFIG):
#                  DATABASE_HOST       SELF | <IP>
#                  DATABASE_NAME       AUTO | <name>
#                  DATABASE_USER       AUTO | <user>
#                  DATABASE_PASS       AUTO | <password>
#                  DATABASE_INNODB_TUNE off  | on
#              All five are HIDDEN on the Edit Configuration screen when
#              the picked child is database-sqlite (none of them apply to
#              SQLite). The gating is implemented by _applies_DATABASE_*
#              helpers in feature-database.choices.sh.
#
#              The body is intentionally a no-op apart from status
#              bookkeeping — all real install work happens in the chosen
#              child feature.

# === II_MANIFEST_BEGIN ===
II_ID="database"
II_TITLE="Database"
II_CATEGORY="feature"
II_VERSION="1"
II_DEPS=""
II_REQUIRES_REBOOT="never"
II_DEFAULT_SELECTED="on"
II_EDITABLE_CONFIG="DATABASE_HOST DATABASE_NAME DATABASE_USER DATABASE_PASS DATABASE_INNODB_TUNE"
II_OPTIONAL_GROUP="database-sqlite database-mysql database-mariadb"
II_OPTIONAL_GROUP_MODE="exclusive"
II_RESTRICT_TO_ROLES=""
# === II_MANIFEST_END ===

source config/installicious.config || exit 1
source lib/log.sh
source lib/status.sh

MODE="install"
while [[ $# -gt 0 ]]; do
  case "$1" in
    --install)   MODE="install" ;;
    --uninstall) MODE="uninstall" ;;
    *) echo "Unknown argument: $1" >&2; exit 2 ;;
  esac
  shift
done

if [[ -z $FILE_LOG_INSTALLICIOUS ]]; then
  FILE_LOG_INSTALLER="$PATH_LOGS/installicious.log"
else
  FILE_LOG_INSTALLER="$PATH_LOGS/$FILE_LOG_INSTALLICIOUS"
fi
log_init "$II_TITLE" "$FILE_LOG_INSTALLER"

if [[ $MODE == "install" ]]; then
  if status_should_skip "$II_ID" "$II_VERSION"; then
    log_info "Database (parent) already recorded at version $II_VERSION. Skipping."
    exit 0
  fi
  status_mark_started "$II_ID"
  status_mark_complete "$II_ID" "$II_VERSION"
  log_ok "Database parent recorded; backend (sqlite/mysql/mariadb) handles install."
  exit 0
fi

# --uninstall: nothing to revert here; the chosen backend's own
# --uninstall reverts apt + config + state. Mark uninstalled so
# re-running install is not blocked by a stale 'completed' record.
status_mark_uninstalled "$II_ID"
log_ok "Database parent record cleared."
exit 0
```

- [ ] **Step 2: Syntax-check**

Run: `bash -n features/feature-database.sh && echo OK`
Expected: `OK`

### Task 1.2: Create `feature-database.choices.sh`

**Files:**
- Create: `features/feature-database.choices.sh`

- [ ] **Step 1: Write `features/feature-database.choices.sh`**

```bash
# features/feature-database.choices.sh
#
# Per-feature helpers consumed by lib/menu.sh's menu_edit_config.
#
# DATABASE_TYPE is NOT a normal editable key — the radio sub-menu
# (II_OPTIONAL_GROUP on the parent feature-database) IS the type
# selector. Its pick is in the framework's selections.sh as
# LAST_ADDONS_PICKED ("database:mysql" etc.). The five DATABASE_* keys
# below are all hidden when SQLite is picked, since none of them apply.
#
# DATABASE_INNODB_TUNE gets a radio (off/on). The other four keys
# (HOST, NAME, USER, PASS) stay as free-form inputboxes with AUTO/SELF
# defaults seeded from config/database.config.

# _database_picked_type — echo one of sqlite | mysql | mariadb (or
# empty if no pick recorded yet). The applicability helpers below all
# defer to this. Reads the framework's selections.sh ($PATH_STATE owned
# by config/installicious.config) — at menu_edit_config time, the radio
# pick has already been committed there.
_database_picked_type() {
  local sfile="${PATH_STATE:-state}/selections.sh"
  [[ -f $sfile ]] || return 0
  # Source in a subshell so LAST_ADDONS_PICKED does not leak back into
  # the menu's environment.
  local picked
  picked=$( # shellcheck disable=SC1090
           source "$sfile" 2>/dev/null
           printf '%s' "${LAST_ADDONS_PICKED:-}"
         )
  case "$picked" in
    *database:sqlite*)  echo sqlite  ;;
    *database:mysql*)   echo mysql   ;;
    *database:mariadb*) echo mariadb ;;
  esac
}

# Shared body — true (rc=0) only when picked DB is mysql or mariadb.
_database_key_visible_for_mysql_family() {
  local t; t=$(_database_picked_type)
  [[ $t == mysql || $t == mariadb ]]
}

_applies_DATABASE_HOST()         { _database_key_visible_for_mysql_family; }
_applies_DATABASE_NAME()         { _database_key_visible_for_mysql_family; }
_applies_DATABASE_USER()         { _database_key_visible_for_mysql_family; }
_applies_DATABASE_PASS()         { _database_key_visible_for_mysql_family; }
_applies_DATABASE_INNODB_TUNE()  { _database_key_visible_for_mysql_family; }

# DATABASE_INNODB_TUNE renders as a 2-row radio.
_choices_DATABASE_INNODB_TUNE() {
  printf 'off\tUse stock Debian mysql/mariadb defaults (no SD-wear tuning)\n'
  printf 'on\tWrite /etc/mysql/conf.d/installicious-pi.cnf with flush=2 + auto-tuned buffer pool\n'
}
```

- [ ] **Step 2: Syntax-check**

Run: `bash -n features/feature-database.choices.sh && echo OK`
Expected: `OK`

### Task 1.3: Create `config/database.config` and `config/database-weewx.config`

**Files:**
- Create: `config/database.config`
- Create: `config/database-weewx.config`

- [ ] **Step 1: Write `config/database.config`**

```bash
# config/database.config — defaults for feature-database (parent +
# sqlite/mysql/mariadb children).
#
# Editable keys (DATABASE_HOST, DATABASE_NAME, DATABASE_USER,
# DATABASE_PASS, DATABASE_INNODB_TUNE) surface on the in-menu Edit
# Configuration screen via the parent's II_EDITABLE_CONFIG — and are
# HIDDEN automatically when the picked child is database-sqlite (see
# feature-database.choices.sh). The remaining keys are config-file-only:
# override them here or in overrides/configuration.override.

# Where the database lives. SELF = install + run the server locally on
# this Pi; anything else (an IP / hostname) = the database is remote and
# the local install just installs Python bindings, never the server. AUTO
# credentials are rejected when DATABASE_HOST is remote (we cannot
# CREATE USER on a database we don't own).
DATABASE_HOST="SELF"

# WeeWx-style AUTO resolution. The mysql/mariadb child resolves AUTO at
# install time:
#   DATABASE_NAME=AUTO  -> ${DATABASE_DEFAULT_NAME} from the active
#                          role's sidecar config (e.g.
#                          config/database-weewx.config sets it to
#                          "weewx"). Falls back to "weewx" if no
#                          per-role config is present.
#   DATABASE_USER=AUTO  -> same as the resolved DATABASE_NAME.
#   DATABASE_PASS=AUTO  -> first run: generate 24 random chars via
#                          `openssl rand -base64 18 | tr -dc 'A-Za-z0-9' |
#                          head -c 24` and persist root-readable at
#                          /etc/installicious/state/database.creds (mode
#                          0600). Subsequent runs: REUSE the stored
#                          value — re-running installicious must never
#                          regenerate the password and break a working
#                          WeeWX.
DATABASE_NAME="AUTO"
DATABASE_USER="AUTO"
DATABASE_PASS="AUTO"

# MySQL/MariaDB convention. Editable via configuration.override only;
# not surfaced on the in-menu editor.
DATABASE_PORT="3306"

# Pi-friendly InnoDB tuning. When ON (and the picked child is
# mysql/mariadb AND DATABASE_HOST=SELF), the child writes
# /etc/mysql/conf.d/installicious-pi.cnf with the two knobs below and
# restarts the server.
#
#   - innodb_flush_log_at_trx_commit = 2: flush the redo log to disk
#     once per second instead of on every commit. Up to ~1 sec of
#     just-committed transactions may be lost on power loss; for a
#     5-min-archive WeeWx station that's a non-issue.
#   - innodb_buffer_pool_size = <Pi tier>: cache table data + indexes in
#     RAM, fewer SD reads. AUTO sizes per Pi RAM tier (Pi 5/8GB Pi 4 ->
#     512M, Pi 4 4GB -> 256M, Pi 3/Pi 4 2GB -> 128M, Pi Zero 2/<=1GB ->
#     64M).
#
# Override either underlying knob in configuration.override if you want
# strict ACID (set INNODB_FLUSH_LOG_AT_TRX_COMMIT=1) or to pin the
# buffer pool (set INNODB_BUFFER_POOL_SIZE=256M etc.).
DATABASE_INNODB_TUNE="off"
DATABASE_INNODB_FLUSH_LOG_AT_TRX_COMMIT="2"
DATABASE_INNODB_BUFFER_POOL_SIZE="AUTO"
```

- [ ] **Step 2: Write `config/database-weewx.config`**

```bash
# config/database-weewx.config — WeeWx-specific defaults consumed by
# feature-database-mysql / -mariadb children when LAST_ROLE_ID=weewx.
# Sourced AFTER config/database.config, so values here win.

# AUTO -> this name. WeeWX 5's default archive table layout works with
# any database name; "weewx" is the documented convention.
DATABASE_DEFAULT_NAME="weewx"

# Python packages installed on the Pi so WeeWX's weedb.mysql backend
# can talk to MySQL/MariaDB. Both share the wire protocol, so the same
# pymysql client works for either backend. SQLite needs no extra
# packages — the weewx apt package already depends on the sqlite3
# Python module.
DATABASE_SQLITE_PYTHON_PACKAGES=""
DATABASE_MYSQL_PYTHON_PACKAGES="python3-pymysql"
DATABASE_MARIADB_PYTHON_PACKAGES="python3-pymysql"
```

- [ ] **Step 3: Syntax-check both**

Run: `bash -n config/database.config && bash -n config/database-weewx.config && echo OK`
Expected: `OK`

### Task 1.4: Create `feature-database-sqlite.sh`

**Files:**
- Create: `features/feature-database-sqlite.sh`

- [ ] **Step 1: Write `features/feature-database-sqlite.sh`**

```bash
#!/bin/bash

# Module:      Database — SQLite (hidden child of feature-database)
# Description: No-op leaf. The weewx apt package ships with SQLite as
#              its default backend, so picking this means "do nothing
#              extra." The body writes /etc/installicious/state/database.state
#              with DATABASE_TYPE="sqlite" so downstream consumers
#              (feature-weewx-setup, the WeeWX backup runtime, etc.)
#              can see a uniform DATABASE_TYPE value.
#
#              Hidden behind II_RESTRICT_TO_ROLES — only visible via
#              the parent feature-database's radio sub-menu.

# === II_MANIFEST_BEGIN ===
II_ID="database-sqlite"
II_TITLE="SQLite (default)"
II_CATEGORY="feature"
II_VERSION="1"
II_DEPS=""
II_REQUIRES_REBOOT="never"
II_DEFAULT_SELECTED="on"
II_RESTRICT_TO_ROLES="weewx"
# === II_MANIFEST_END ===

source config/installicious.config || exit 1
source lib/log.sh
source lib/status.sh

DATABASE_STATE_FILE="${PATH_STATE:-/etc/installicious/state}/database.state"
DATABASE_CREDS_FILE="${PATH_STATE:-/etc/installicious/state}/database.creds"

MODE="install"
while [[ $# -gt 0 ]]; do
  case "$1" in
    --install)   MODE="install" ;;
    --uninstall) MODE="uninstall" ;;
    *) echo "Unknown argument: $1" >&2; exit 2 ;;
  esac
  shift
done

if [[ -z $FILE_LOG_INSTALLICIOUS ]]; then
  FILE_LOG_INSTALLER="$PATH_LOGS/installicious.log"
else
  FILE_LOG_INSTALLER="$PATH_LOGS/$FILE_LOG_INSTALLICIOUS"
fi
log_init "$II_TITLE" "$FILE_LOG_INSTALLER"

if [[ $MODE == "install" ]]; then
  if status_should_skip "$II_ID" "$II_VERSION"; then
    log_info "database-sqlite already recorded at version $II_VERSION. Skipping."
    exit 0
  fi
  status_mark_started "$II_ID"

  log_info "Writing $DATABASE_STATE_FILE (DATABASE_TYPE=sqlite)."
  sudo mkdir -p "$(dirname "$DATABASE_STATE_FILE")"
  sudo tee "$DATABASE_STATE_FILE" >/dev/null <<'STATE'
# /etc/installicious/state/database.state — written by feature-database-sqlite.
# Downstream consumers source this to learn the active DB backend.
DATABASE_TYPE="sqlite"
DATABASE_HOST=""
DATABASE_NAME=""
DATABASE_USER=""
DATABASE_PORT=""
STATE
  sudo chmod 0644 "$DATABASE_STATE_FILE"

  status_mark_complete "$II_ID" "$II_VERSION"
  log_ok "database-sqlite recorded — WeeWX will use its default SQLite backend."
  echo -e "[  \e[0;32mOK\e[0m  ] Database backend: SQLite (default)."
  exit 0
fi

# --uninstall — remove the state file so a subsequent run starts fresh.
# Leave the creds file (no SQLite secrets stored) and the actual weewx
# SQLite DB alone — that is WeeWX's data, not ours to delete.
log_info "Removing $DATABASE_STATE_FILE."
sudo rm -f "$DATABASE_STATE_FILE"
status_mark_uninstalled "$II_ID"
log_ok "database-sqlite uninstalled (state cleared)."
exit 0
```

- [ ] **Step 2: Syntax-check**

Run: `bash -n features/feature-database-sqlite.sh && echo OK`
Expected: `OK`

### Task 1.5: Update test rosters (manifest + role)

**Files:**
- Modify: `tests/test-manifest.sh` (Test 7 line 109; Test 10 line 229)
- Modify: `tests/test-role.sh` (Weewx DEFAULT assertion)

- [ ] **Step 1: Update both roster strings in `tests/test-manifest.sh`**

The two strings on lines 109 and 229 currently contain `...,weewx,weewx-database-ram,weewx-onedrive-backup,weewx-setup,...`. We need to insert `database,database-mariadb,database-mysql,database-sqlite,` so they keep sort order. Sorted, the four new IDs sit right after `compressed-swap` and before `git`.

Replace (both occurrences via `replace_all`):

Old:
```
"apache,bash,caddy,compressed-swap,git,jshon,lighttpd,locale,log2ram,motd,motd-updates,motd-weather,neowx-material,nginx,pip,pkupd,ram-logging,rconf,skyfield,webserver,webserver-ssl,webserver-under-construction,weewx,weewx-database-ram,weewx-onedrive-backup,weewx-setup,weewx-site-ram,weewx-webroot,zram,"
```

New:
```
"apache,bash,caddy,compressed-swap,database,database-mariadb,database-mysql,database-sqlite,git,jshon,lighttpd,locale,log2ram,motd,motd-updates,motd-weather,neowx-material,nginx,pip,pkupd,ram-logging,rconf,skyfield,webserver,webserver-ssl,webserver-under-construction,weewx,weewx-database-ram,weewx-onedrive-backup,weewx-setup,weewx-site-ram,weewx-webroot,zram,"
```

Use `Edit` with `replace_all: true` on `tests/test-manifest.sh`.

> **NOTE:** This step adds all four IDs (parent + three children) to the roster string up-front, but the mysql/mariadb files don't get created until Phases 2 and 3. The test WILL FAIL after this step until those files exist. That's fine — we will fail the test now, get the framework files in, and run a final clean test pass at the END of Phase 3. If you'd rather keep tests green between phases, only add `database` and `database-sqlite` here, and add `database-mariadb` + `database-mysql` to the roster string in Phases 2 and 3 respectively.
>
> **Recommended:** add only the two parent + sqlite IDs now to keep tests green; add the others incrementally.

So actually use this safer replacement for Phase 1 (with `replace_all: true`):

Old:
```
"apache,bash,caddy,compressed-swap,git,jshon,lighttpd,locale,log2ram,motd,motd-updates,motd-weather,neowx-material,nginx,pip,pkupd,ram-logging,rconf,skyfield,webserver,webserver-ssl,webserver-under-construction,weewx,weewx-database-ram,weewx-onedrive-backup,weewx-setup,weewx-site-ram,weewx-webroot,zram,"
```

New (Phase 1 — only parent + sqlite child):
```
"apache,bash,caddy,compressed-swap,database,database-sqlite,git,jshon,lighttpd,locale,log2ram,motd,motd-updates,motd-weather,neowx-material,nginx,pip,pkupd,ram-logging,rconf,skyfield,webserver,webserver-ssl,webserver-under-construction,weewx,weewx-database-ram,weewx-onedrive-backup,weewx-setup,weewx-site-ram,weewx-webroot,zram,"
```

- [ ] **Step 2: Update WeeWx `ROLE_FEATURES_DEFAULT` assertion in `tests/test-role.sh`**

Around line 153 today the assertion reads:
```bash
chkeq "weewx default"  "$weewx_def" "weewx-setup weewx-webroot weewx-site-ram weewx-database-ram neowx-material locale bash motd skyfield ram-logging"
```

Replace with:
```bash
chkeq "weewx default"  "$weewx_def" "database weewx-setup weewx-webroot weewx-site-ram weewx-database-ram neowx-material locale bash motd skyfield ram-logging"
```

(`database` prepended.)

### Task 1.6: Wire `database` into `role-weewx.sh`

**Files:**
- Modify: `roles/role-weewx.sh`

- [ ] **Step 1: Read the current planning comment + tier block**

Run: `Grep` for `ROLE_FEATURES_DEFAULT` in `roles/role-weewx.sh` to find the block. The string ends with `... ram-logging`.

- [ ] **Step 2: Update `ROLE_FEATURES_DEFAULT`**

Edit the assignment to prepend `database`:

Old:
```bash
ROLE_FEATURES_DEFAULT="weewx-setup weewx-webroot weewx-site-ram weewx-database-ram neowx-material locale bash motd skyfield ram-logging"
```

New:
```bash
ROLE_FEATURES_DEFAULT="database weewx-setup weewx-webroot weewx-site-ram weewx-database-ram neowx-material locale bash motd skyfield ram-logging"
```

- [ ] **Step 3: Update the planning comment to mention `database`**

In the same file, find the existing comment block that describes the DEFAULT tier (above `ROLE_FEATURES_DEFAULT=`). Add one sentence near the top of that block describing `database` — that it fires the sqlite/mysql/mariadb radio after the webserver pick, defaults to SQLite, and that `weewx-database-ram` + `weewx-onedrive-backup` self-skip when DATABASE_TYPE != sqlite. Keep wording terse — one paragraph.

Sample addition (insert before the first existing DEFAULT-tier comment line):

```bash
# DEFAULT now leads with `database` (the sqlite/mysql/mariadb radio
# parent) so the DB-backend choice is recorded before weewx-setup
# writes weewx.conf. Default radio pick is sqlite, which is a no-op
# leaf — weewx ships with SQLite already. The five DATABASE_* editable
# keys only surface on the Edit Configuration screen when MySQL or
# MariaDB is picked (gated by feature-database.choices.sh).
# weewx-database-ram and weewx-onedrive-backup both self-skip when
# DATABASE_TYPE != sqlite, so they can stay in DEFAULT without
# footguns.
```

### Task 1.7: Run the full test suite and commit Phase 1

- [ ] **Step 1: Run all tests**

Run:
```bash
cd "c:/Source Files/Personal/Bash/installicious"
for t in tests/test-*.sh; do
  out=$(bash "$t" 2>&1); rc=$?
  if [[ $rc -ne 0 ]] || echo "$out" | grep -qE '(^|[^A-Za-z])(FAIL|✗)([^A-Za-z]|$)'; then
    echo "FAILED: $t (rc=$rc)"
    echo "$out" | tail -40
    break
  fi
  echo "  OK  $(basename "$t") rc=$rc"
done
```

Expected: 13 lines `OK test-X.sh rc=0`, no FAILED.

If a test fails, read its output and fix before committing. Most likely sources of failure in this phase:
- `tests/test-manifest.sh` Test 7 / Test 10: roster string mismatch — confirm the sorted insertion of `database,database-sqlite,` between `compressed-swap,` and `git,`.
- `tests/test-role.sh` "weewx default" assertion: confirm `database ` prefix added.

- [ ] **Step 2: Bump VERSION**

Write `2.5.2\n` to `VERSION`.

- [ ] **Step 3: Stage + commit**

```bash
git add VERSION features/feature-database.sh features/feature-database.choices.sh features/feature-database-sqlite.sh config/database.config config/database-weewx.config roles/role-weewx.sh tests/test-manifest.sh tests/test-role.sh
git commit -F- <<'MSG'
feature-database: parent + sqlite leaf + role wiring (skeleton)

Lands the framework half of feature-database per
docs/superpowers/specs/2026-05-22-feature-database-design.md:

- feature-database (parent grouping feature; II_OPTIONAL_GROUP with
  three children; five editable keys).
- feature-database.choices.sh (applicability helpers hiding the four
  DATABASE_* keys + INNODB_TUNE when SQLite is picked; off/on radio
  for INNODB_TUNE).
- feature-database-sqlite (no-op leaf — writes database.state).
- config/database.config and config/database-weewx.config (defaults +
  per-role Python pkg matrix).
- role-weewx.sh: `database` prepended to ROLE_FEATURES_DEFAULT.
- Test rosters updated (manifest + role).

mysql + mariadb children, weewx-setup overlay, conflict handling for
ramdisk/backup, and README/example updates land in follow-up phases.
VERSION 2.5.1 -> 2.5.2.

Co-Authored-By: Claude Opus 4.7 <noreply@anthropic.com>
MSG
```

---

## Phase 2 — lib/database.sh + MySQL child (→ VERSION 2.5.3)

The deliverable: picking `mysql` in the radio actually installs `mysql-server`, provisions `weewx`/`<user>`/<persisted-password>` via socket auth, writes `database.state` + `database.creds`, installs Python bindings. Uninstall drops the user + database. AUTO + remote = hard error before any apt work.

### Task 2.1: Create `lib/database.sh` with the shared provisioning helpers

**Files:**
- Create: `lib/database.sh`

- [ ] **Step 1: Write `lib/database.sh`**

```bash
#!/bin/bash

# lib/database.sh — shared install/uninstall/provisioning helpers for
# the feature-database-mysql / feature-database-mariadb children.
#
# Both children are thin shells that source this lib and call:
#   database_install_mysql_family "$II_ID" "$II_APT_PACKAGES" "$DB_TYPE"
#       "$SERVICE" "$STATUS_FILE"
#   database_uninstall_mysql_family ... (same args)
#
# Where DB_TYPE is "mysql" or "mariadb" and SERVICE is the systemd unit
# (e.g. "mariadb" or "mysql"). The children supply only the differences
# (package list + service name); the rest is shared.
#
# This lib expects the caller to have already sourced:
#   lib/log.sh lib/status.sh lib/state.sh lib/apt.sh lib/installer_apt.sh
#   config/installicious.config
# and to have done log_init + status_mark_started.

DATABASE_STATE_FILE="${PATH_STATE:-/etc/installicious/state}/database.state"
DATABASE_CREDS_FILE="${PATH_STATE:-/etc/installicious/state}/database.creds"

# database_load_role_sidecar — source ${PATH_CONFIG}/database-${role}.config
# if present. Caller sets LAST_ROLE_ID (read from selections.sh).
database_load_role_sidecar() {
  local role="$1"
  [[ -z $role ]] && return 0
  local f="${PATH_CONFIG:-config}/database-${role}.config"
  if [[ -f $f ]]; then
    # shellcheck disable=SC1090
    source "$f"
    log_info "Sourced per-role sidecar: $f"
  fi
}

# database_active_role — echo LAST_ROLE_ID from the picker selections
# file, or empty if unknown.
database_active_role() {
  local sfile="${PATH_STATE:-state}/selections.sh"
  [[ -f $sfile ]] || return 0
  ( # shellcheck disable=SC1090
    source "$sfile" 2>/dev/null
    printf '%s' "${LAST_ROLE_ID:-}"
  )
}

# database_is_local — rc=0 if DATABASE_HOST is SELF / empty / localhost,
# rc=1 otherwise (remote).
database_is_local() {
  case "${DATABASE_HOST:-SELF}" in
    SELF|self|localhost|127.0.0.1|"") return 0 ;;
    *) return 1 ;;
  esac
}

# database_generate_password — print a 24-char alnum password to stdout.
database_generate_password() {
  openssl rand -base64 18 | tr -dc 'A-Za-z0-9' | head -c 24
}

# database_persist_password "<pw>" — write DATABASE_PASS=<pw> to
# /etc/installicious/state/database.creds (mode 0600, root-owned).
database_persist_password() {
  local pw="$1"
  sudo mkdir -p "$(dirname "$DATABASE_CREDS_FILE")"
  printf 'DATABASE_PASS="%s"\n' "$pw" | sudo tee "$DATABASE_CREDS_FILE" >/dev/null
  sudo chmod 0600 "$DATABASE_CREDS_FILE"
  sudo chown root:root "$DATABASE_CREDS_FILE" 2>/dev/null || true
}

# database_load_persisted_password — echo the stored DATABASE_PASS from
# database.creds (or empty if no file / no value).
database_load_persisted_password() {
  [[ -f $DATABASE_CREDS_FILE ]] || return 0
  ( # shellcheck disable=SC1090
    source "$DATABASE_CREDS_FILE" 2>/dev/null
    printf '%s' "${DATABASE_PASS:-}"
  )
}

# database_resolve_credentials — turn AUTO sentinels into concrete values.
# Reads the globals DATABASE_NAME / DATABASE_USER / DATABASE_PASS;
# overwrites them in place. Requires DATABASE_DEFAULT_NAME (from the
# per-role sidecar) for AUTO name resolution, fallback "weewx".
#
# Returns rc=0 on success, rc=1 if remote-DB + AUTO creds (caller
# should fail with the documented error message).
database_resolve_credentials() {
  local default_name="${DATABASE_DEFAULT_NAME:-weewx}"

  if ! database_is_local; then
    # Remote DB — AUTO USER or PASS is a hard error.
    if [[ "${DATABASE_USER:-AUTO}" == "AUTO" || "${DATABASE_PASS:-AUTO}" == "AUTO" ]]; then
      return 1
    fi
    # DATABASE_NAME=AUTO is fine for remote; default it here.
    [[ "${DATABASE_NAME:-AUTO}" == "AUTO" ]] && DATABASE_NAME="$default_name"
    return 0
  fi

  # Local DB — AUTO resolves as documented.
  [[ "${DATABASE_NAME:-AUTO}" == "AUTO" ]] && DATABASE_NAME="$default_name"
  [[ "${DATABASE_USER:-AUTO}" == "AUTO" ]] && DATABASE_USER="$DATABASE_NAME"
  if [[ "${DATABASE_PASS:-AUTO}" == "AUTO" ]]; then
    local stored; stored=$(database_load_persisted_password)
    if [[ -n $stored ]]; then
      DATABASE_PASS="$stored"
      log_info "Reusing persisted password from $DATABASE_CREDS_FILE."
    else
      DATABASE_PASS=$(database_generate_password)
      database_persist_password "$DATABASE_PASS"
      log_info "Generated new password and persisted to $DATABASE_CREDS_FILE."
    fi
  fi
  return 0
}

# database_provision_local — CREATE DATABASE/USER/GRANT via root socket
# auth on a fresh Debian mariadb-server/mysql-server install. Idempotent
# (IF NOT EXISTS). Returns rc=0 on success, rc=2 if socket auth is
# unavailable (caller should fail with a clear pointer to the manual
# provisioning path).
database_provision_local() {
  local sql
  sql=$(printf '%s\n' \
    "CREATE DATABASE IF NOT EXISTS \`${DATABASE_NAME}\`;" \
    "CREATE USER IF NOT EXISTS '${DATABASE_USER}'@'localhost' IDENTIFIED BY '${DATABASE_PASS}';" \
    "ALTER USER '${DATABASE_USER}'@'localhost' IDENTIFIED BY '${DATABASE_PASS}';" \
    "GRANT ALL PRIVILEGES ON \`${DATABASE_NAME}\`.* TO '${DATABASE_USER}'@'localhost';" \
    "FLUSH PRIVILEGES;")
  log_info "Provisioning database \`${DATABASE_NAME}\` and user '${DATABASE_USER}'@'localhost' (idempotent CREATE IF NOT EXISTS)."
  if ! sudo mysql -u root <<< "$sql" 2>&1 | tee -a "$FILE_LOG_INSTALLER" >/dev/null; then
    log_fail "Root socket auth into mysql/mariadb failed."
    return 2
  fi
  return 0
}

# database_install_python_bindings — install the role-specific Python
# packages for the picked DB type. Reads DATABASE_<TYPE>_PYTHON_PACKAGES
# from the per-role sidecar (set by database_load_role_sidecar above).
# Empty list is a no-op (SQLite case).
database_install_python_bindings() {
  local db_type="$1" status_file="$2" varname pkgs
  varname="DATABASE_$(echo "$db_type" | tr 'a-z' 'A-Z')_PYTHON_PACKAGES"
  pkgs="${!varname:-}"
  if [[ -z $pkgs ]]; then
    log_info "No Python bindings configured for DB type '$db_type' under role '$(database_active_role)' — skipping."
    return 0
  fi
  log_info "Installing Python bindings for '$db_type': $pkgs"
  # shellcheck disable=SC2086
  installer_apt_record_install "$status_file" $pkgs
}

# database_write_state_file — emit /etc/installicious/state/database.state
# with the resolved (post-AUTO) values for downstream consumers.
database_write_state_file() {
  local db_type="$1"
  log_info "Writing $DATABASE_STATE_FILE."
  sudo mkdir -p "$(dirname "$DATABASE_STATE_FILE")"
  sudo tee "$DATABASE_STATE_FILE" >/dev/null <<STATE
# /etc/installicious/state/database.state — written by feature-database-${db_type}.
# Downstream consumers source this to learn the active DB backend.
DATABASE_TYPE="${db_type}"
DATABASE_HOST="${DATABASE_HOST}"
DATABASE_NAME="${DATABASE_NAME}"
DATABASE_USER="${DATABASE_USER}"
DATABASE_PORT="${DATABASE_PORT:-3306}"
STATE
  sudo chmod 0644 "$DATABASE_STATE_FILE"
}

# database_install_mysql_family <id> <apt_packages> <db_type> <service> <status_file>
# Top-level helper called by both feature-database-mysql and -mariadb.
database_install_mysql_family() {
  local id="$1" apt_packages="$2" db_type="$3" service="$4" status_file="$5"
  local role rc

  role=$(database_active_role)
  database_load_role_sidecar "$role"

  # Defaults if config files left things unset.
  : "${DATABASE_HOST:=SELF}"
  : "${DATABASE_NAME:=AUTO}"
  : "${DATABASE_USER:=AUTO}"
  : "${DATABASE_PASS:=AUTO}"
  : "${DATABASE_PORT:=3306}"

  database_resolve_credentials
  rc=$?
  if [[ $rc -ne 0 ]]; then
    log_fail "DATABASE_HOST=${DATABASE_HOST} is remote but DATABASE_USER or DATABASE_PASS is AUTO."
    status_mark_failed "$id" "remote DB requires explicit USER + PASS"
    echo -e "[ \e[0;31mFAIL\e[0m ] Remote DATABASE_HOST requires explicit DATABASE_USER and DATABASE_PASS (cannot create a user on a database we do not own). Set both via the in-menu editor or overrides/configuration.override."
    return 1
  fi

  if database_is_local; then
    # Install the server.
    log_info "Installing local DB server: $apt_packages"
    # shellcheck disable=SC2086
    installer_apt_record_install "$status_file" $apt_packages
    rc=$?
    if [[ $rc -ne 0 ]]; then
      status_mark_failed "$id" "apt install failed (code $rc)"
      echo -e "[ \e[0;31mFAIL\e[0m ] Installicious could not install $apt_packages. Error Code: $rc."
      return $rc
    fi

    log_info "Enabling + starting $service."
    sudo systemctl enable --now "$service" 2>&1 | tee -a "$FILE_LOG_INSTALLER" \
      || log_warn "enable $service returned non-zero."

    if ! database_provision_local; then
      status_mark_failed "$id" "provisioning failed (root socket auth)"
      echo -e "[ \e[0;31mFAIL\e[0m ] Could not provision via 'sudo mysql -u root'. Re-enable socket auth (ALTER USER 'root'@'localhost' IDENTIFIED VIA unix_socket;) or provision the WeeWx DB + user by hand and re-run."
      return 1
    fi
  else
    log_info "DATABASE_HOST=${DATABASE_HOST} — remote DB; skipping server install + provisioning."
  fi

  database_install_python_bindings "$db_type" "$status_file"
  rc=$?
  if [[ $rc -ne 0 ]]; then
    status_mark_failed "$id" "Python bindings install failed (code $rc)"
    echo -e "[ \e[0;31mFAIL\e[0m ] Installicious could not install Python bindings. Error Code: $rc."
    return $rc
  fi

  database_write_state_file "$db_type"
  return 0
}

# database_uninstall_mysql_family <id> <apt_packages> <db_type> <service> <status_file>
# Reverses install. Drops the WeeWx DB + user IF we created them, removes
# the InnoDB tuning drop-in (Phase 4 lands the write side), removes
# state + creds files.
database_uninstall_mysql_family() {
  local id="$1" apt_packages="$2" db_type="$3" service="$4" status_file="$5"

  if database_is_local && systemctl is-active --quiet "$service" 2>/dev/null; then
    log_info "Dropping database \`${DATABASE_NAME:-weewx}\` and user '${DATABASE_USER:-weewx}'@'localhost' — DATA WILL BE DESTROYED."
    local sql
    sql=$(printf '%s\n' \
      "DROP DATABASE IF EXISTS \`${DATABASE_NAME:-weewx}\`;" \
      "DROP USER IF EXISTS '${DATABASE_USER:-weewx}'@'localhost';" \
      "FLUSH PRIVILEGES;")
    sudo mysql -u root <<< "$sql" 2>&1 | tee -a "$FILE_LOG_INSTALLER" >/dev/null \
      || log_warn "DROP DATABASE/USER returned non-zero (continuing uninstall)."

    log_info "Stopping $service."
    sudo systemctl stop "$service" 2>/dev/null || true
  fi

  # InnoDB tuning drop-in: removed unconditionally if present (Phase 4
  # is the writer; uninstall here is forward-compatible).
  if [[ -f /etc/mysql/conf.d/installicious-pi.cnf ]]; then
    log_info "Removing /etc/mysql/conf.d/installicious-pi.cnf."
    sudo rm -f /etc/mysql/conf.d/installicious-pi.cnf
  fi

  # shellcheck disable=SC2086
  installer_apt_revert "$status_file" $apt_packages

  log_info "Removing state files."
  sudo rm -f "$DATABASE_STATE_FILE" "$DATABASE_CREDS_FILE"
  return 0
}
```

- [ ] **Step 2: Syntax-check**

Run: `bash -n lib/database.sh && echo OK`
Expected: `OK`

### Task 2.2: Create `feature-database-mysql.sh`

**Files:**
- Create: `features/feature-database-mysql.sh`

- [ ] **Step 1: Write `features/feature-database-mysql.sh`**

```bash
#!/bin/bash

# Module:      Database — MySQL (hidden child of feature-database)
# Description: Installs mysql-server when DATABASE_HOST=SELF (or empty),
#              provisions the WeeWx DB + user via root socket auth,
#              installs the role-specific Python bindings, and writes
#              /etc/installicious/state/database.state. When
#              DATABASE_HOST is a remote IP, skips the server install +
#              provisioning and just installs Python bindings.
#
#              Thin shell — all logic in lib/database.sh.
#
#              Note on mysql-server availability: Debian Bookworm /
#              Trixie ship the `default-mysql-server` virtual package
#              that resolves to mariadb-server. For a TRUE Oracle MySQL
#              install you'd add the Oracle repo separately; on
#              Bookworm/Trixie out of the box, picking "mysql" via this
#              feature gets you mariadb-server under the hood. The
#              feature is preserved as a separate child so future
#              installs from Oracle's repo can land cleanly without
#              breaking the menu shape.

# === II_MANIFEST_BEGIN ===
II_ID="database-mysql"
II_TITLE="MySQL"
II_CATEGORY="feature"
II_VERSION="1"
II_DEPS=""
II_REQUIRES_REBOOT="never"
II_DEFAULT_SELECTED="off"
II_RESTRICT_TO_ROLES="weewx"
II_APT_PACKAGES="default-mysql-server"
# === II_MANIFEST_END ===

source config/installicious.config || exit 1
source lib/log.sh
source lib/status.sh
source lib/state.sh
source lib/apt.sh
source lib/installer_apt.sh
source lib/database.sh

FILE_CONFIG_DB="${PATH_CONFIG:-config}/database.config"
[[ -f $FILE_CONFIG_DB ]] && source "$FILE_CONFIG_DB"
state_apply_menu_overrides

SERVICE="mariadb"   # default-mysql-server pulls mariadb-server on Bookworm/Trixie

MODE="install"
while [[ $# -gt 0 ]]; do
  case "$1" in
    --install)   MODE="install" ;;
    --uninstall) MODE="uninstall" ;;
    *) echo "Unknown argument: $1" >&2; exit 2 ;;
  esac
  shift
done

if [[ -z $FILE_LOG_INSTALLICIOUS ]]; then
  FILE_LOG_INSTALLER="$PATH_LOGS/installicious.log"
else
  FILE_LOG_INSTALLER="$PATH_LOGS/$FILE_LOG_INSTALLICIOUS"
fi
log_init "$II_TITLE" "$FILE_LOG_INSTALLER"

STATUS_FILE=$(status_file_for "$II_ID")

if [[ $MODE == "install" ]]; then
  if status_should_skip "$II_ID" "$II_VERSION" "$FILE_CONFIG_DB"; then
    log_info "database-mysql already installed at recorded version + config. Skipping."
    exit 0
  fi
  status_mark_started "$II_ID"

  if database_install_mysql_family "$II_ID" "$II_APT_PACKAGES" "mysql" "$SERVICE" "$STATUS_FILE"; then
    status_mark_complete "$II_ID" "$II_VERSION" "$FILE_CONFIG_DB"
    log_ok "database-mysql installed."
    echo -e "[  \e[0;32mOK\e[0m  ] Database backend: MySQL (mariadb-server backed on Debian)."
    exit 0
  fi
  exit 1
fi

# --uninstall
case "$(status_state "$II_ID")" in
  uninstalled)
    log_info "database-mysql already uninstalled."
    echo -e "[  \e[0;32mOK\e[0m  ] database-mysql is already uninstalled."
    exit 0
    ;;
  "")
    log_warn "No install record for database-mysql; nothing to revert."
    status_mark_uninstalled "$II_ID"
    exit 0
    ;;
esac

# Resolve creds from current config + database.creds so uninstall knows
# which user/db to drop. Don't fail if AUTO is unresolvable — fall back
# to documented defaults.
database_load_role_sidecar "$(database_active_role)"
: "${DATABASE_NAME:=AUTO}"
: "${DATABASE_USER:=AUTO}"
[[ "$DATABASE_NAME" == "AUTO" ]] && DATABASE_NAME="${DATABASE_DEFAULT_NAME:-weewx}"
[[ "$DATABASE_USER" == "AUTO" ]] && DATABASE_USER="$DATABASE_NAME"

database_uninstall_mysql_family "$II_ID" "$II_APT_PACKAGES" "mysql" "$SERVICE" "$STATUS_FILE"
status_mark_uninstalled "$II_ID"
log_ok "database-mysql uninstalled."
echo -e "[  \e[0;32mOK\e[0m  ] database-mysql uninstalled (server + DB + user dropped)."
exit 0
```

- [ ] **Step 2: Syntax-check**

Run: `bash -n features/feature-database-mysql.sh && echo OK`
Expected: `OK`

### Task 2.3: Update test rosters to include `database-mysql`

**Files:**
- Modify: `tests/test-manifest.sh` (both roster strings)

- [ ] **Step 1: Update both roster strings via `replace_all: true`**

Old:
```
"apache,bash,caddy,compressed-swap,database,database-sqlite,git,...
```

New:
```
"apache,bash,caddy,compressed-swap,database,database-mysql,database-sqlite,git,...
```

The change is inserting `database-mysql,` between `database,` and `database-sqlite,`. Use `Edit` with `replace_all: true`. (Only the substring around those three IDs differs — keep the rest of each string identical.)

### Task 2.4: Create `tests/test-database.sh`

**Files:**
- Create: `tests/test-database.sh`

This file unit-tests the helper functions in `lib/database.sh` using synthetic env so it does NOT require an actual mysql install.

- [ ] **Step 1: Write `tests/test-database.sh`**

```bash
#!/bin/bash
# Tests for lib/database.sh — AUTO resolution, remote-DB rule, applicability.

cd "$(dirname "${BASH_SOURCE[0]}")/.." || exit 1

source lib/log.sh
log_init "test-database" "/tmp/test-database.log"

# Pull in PATH_* so DATABASE_STATE_FILE / CREDS_FILE resolve to the
# tempdir we control below (NOT /etc/installicious).
TMPDIR=$(mktemp -d)
trap "rm -rf $TMPDIR" EXIT
export PATH_STATE="$TMPDIR/state"
export PATH_CONFIG="$TMPDIR/config"
mkdir -p "$PATH_STATE" "$PATH_CONFIG"

source lib/database.sh

ok()    { echo "  OK $1"; }
fail()  { echo "  FAIL $1"; }
chkeq() { [[ "$2" == "$3" ]] && ok "$1" || fail "$1 (got '$2', want '$3')"; }
chkrc() { [[ $2 -eq $3 ]] && ok "$1" || fail "$1 (rc=$2, want $3)"; }

# ============================================================================
echo "=== Test 1: database_is_local ==="
DATABASE_HOST="SELF";        database_is_local; chkrc "SELF is local"      $? 0
DATABASE_HOST="";            database_is_local; chkrc "empty is local"     $? 0
DATABASE_HOST="localhost";   database_is_local; chkrc "localhost is local" $? 0
DATABASE_HOST="127.0.0.1";   database_is_local; chkrc "127.0.0.1 is local" $? 0
DATABASE_HOST="10.0.0.5";    database_is_local; chkrc "10.0.0.5 is remote" $? 1
DATABASE_HOST="db.lan";      database_is_local; chkrc "db.lan is remote"   $? 1

# ============================================================================
echo "=== Test 2: database_resolve_credentials (local + AUTO) ==="
DATABASE_HOST="SELF"; DATABASE_NAME="AUTO"; DATABASE_USER="AUTO"; DATABASE_PASS="AUTO"
DATABASE_DEFAULT_NAME="weewx"
rm -f "$DATABASE_CREDS_FILE"
database_resolve_credentials; chkrc "local+AUTO resolves rc=0" $? 0
chkeq "AUTO NAME -> weewx" "$DATABASE_NAME" "weewx"
chkeq "AUTO USER -> weewx" "$DATABASE_USER" "weewx"
[[ ${#DATABASE_PASS} -eq 24 ]] && ok "AUTO PASS is 24 chars" || fail "AUTO PASS is ${#DATABASE_PASS} chars (want 24)"
[[ -f "$DATABASE_CREDS_FILE" ]] && ok "creds file written" || fail "creds file missing at $DATABASE_CREDS_FILE"

# ============================================================================
echo "=== Test 3: database_resolve_credentials reuses persisted password ==="
FIRST_PASS="$DATABASE_PASS"
DATABASE_HOST="SELF"; DATABASE_NAME="AUTO"; DATABASE_USER="AUTO"; DATABASE_PASS="AUTO"
database_resolve_credentials
chkeq "second run reuses pass" "$DATABASE_PASS" "$FIRST_PASS"

# ============================================================================
echo "=== Test 4: database_resolve_credentials (remote + AUTO = rc=1) ==="
DATABASE_HOST="10.0.0.5"; DATABASE_USER="AUTO"; DATABASE_PASS="AUTO"
database_resolve_credentials; chkrc "remote+AUTO fails" $? 1

# ============================================================================
echo "=== Test 5: database_resolve_credentials (remote + explicit = rc=0) ==="
DATABASE_HOST="10.0.0.5"; DATABASE_NAME="weewx_prod"; DATABASE_USER="weewx"; DATABASE_PASS="hunter2"
database_resolve_credentials; chkrc "remote+explicit OK" $? 0
chkeq "remote NAME preserved" "$DATABASE_NAME" "weewx_prod"
chkeq "remote USER preserved" "$DATABASE_USER" "weewx"
chkeq "remote PASS preserved" "$DATABASE_PASS" "hunter2"

# ============================================================================
echo "=== Test 6: database_resolve_credentials (remote + NAME=AUTO is OK) ==="
DATABASE_HOST="10.0.0.5"; DATABASE_NAME="AUTO"; DATABASE_USER="weewx"; DATABASE_PASS="hunter2"
DATABASE_DEFAULT_NAME="weewx"
database_resolve_credentials; chkrc "remote+NAME=AUTO+explicit creds OK" $? 0
chkeq "remote NAME=AUTO resolves" "$DATABASE_NAME" "weewx"

# ============================================================================
echo "=== Test 7: database_load_role_sidecar ==="
mkdir -p "$PATH_CONFIG"
cat > "$PATH_CONFIG/database-weewx.config" <<EOF
DATABASE_DEFAULT_NAME="weewx_test"
DATABASE_MYSQL_PYTHON_PACKAGES="python3-pymysql"
EOF
unset DATABASE_DEFAULT_NAME DATABASE_MYSQL_PYTHON_PACKAGES
database_load_role_sidecar "weewx"
chkeq "sidecar sets DEFAULT_NAME"     "$DATABASE_DEFAULT_NAME"          "weewx_test"
chkeq "sidecar sets PYTHON_PACKAGES"  "$DATABASE_MYSQL_PYTHON_PACKAGES" "python3-pymysql"
database_load_role_sidecar "nonexistent" 2>/dev/null  # must not error
ok "missing sidecar is a no-op"

# ============================================================================
echo
echo "=== Done ==="
```

- [ ] **Step 2: Make the test executable and run it**

```bash
chmod +x tests/test-database.sh
bash tests/test-database.sh
```

Expected: every `OK ...` line, no `FAIL`, `=== Done ===` at the end.

### Task 2.5: Run the full test suite and commit Phase 2

- [ ] **Step 1: Run all 14 tests** (one new file, `test-database.sh`)

Run the same loop as Phase 1, but expect 14 OK lines now.

- [ ] **Step 2: Bump VERSION to `2.5.3`** + **Step 3: Stage + commit**

```bash
git add VERSION features/feature-database-mysql.sh lib/database.sh tests/test-database.sh tests/test-manifest.sh
git commit -F- <<'MSG'
feature-database-mysql: thin shell over lib/database.sh

Lands the MySQL child of feature-database. Apt package is
default-mysql-server (resolves to mariadb-server on Bookworm/Trixie;
preserved as a separate child for future Oracle MySQL repo
installs). lib/database.sh holds the shared install/uninstall/
provisioning helpers — AUTO -> concrete credential resolution
(with password persistence + reuse), local CREATE DATABASE/USER
provisioning via root socket auth, remote-DB hard-error gate,
state-file writes.

tests/test-database.sh covers the helpers in isolation (7 sections,
no actual mysql required). Roster updated for the new child.

VERSION 2.5.2 -> 2.5.3.

Co-Authored-By: Claude Opus 4.7 <noreply@anthropic.com>
MSG
```

---

## Phase 3 — MariaDB child (→ VERSION 2.5.3 → 2.5.4)

Trivially small phase: a thin shell mirroring `feature-database-mysql.sh` but with `mariadb-server` as the package. Reuses `lib/database.sh` entirely.

### Task 3.1: Create `feature-database-mariadb.sh`

**Files:**
- Create: `features/feature-database-mariadb.sh`

- [ ] **Step 1: Write the file**

It's structurally identical to `feature-database-mysql.sh`. Copy that file and change three things:
1. `II_ID="database-mariadb"`
2. `II_TITLE="MariaDB"`
3. `II_APT_PACKAGES="mariadb-server"`
4. Update the module-header description block to say "MariaDB" everywhere.
5. The body call: `database_install_mysql_family "$II_ID" "$II_APT_PACKAGES" "mariadb" "$SERVICE" "$STATUS_FILE"` (the third argument is the DB type — change `mysql` → `mariadb`).
6. The echo lines: replace "MySQL" with "MariaDB", `database-mysql` with `database-mariadb`.

`SERVICE="mariadb"` stays the same (mariadb-server uses the `mariadb` systemd unit).

Drop the Bookworm/Trixie "default-mysql-server resolves to mariadb-server" caveat from the header — it's only relevant for the MySQL child.

- [ ] **Step 2: Syntax-check**

Run: `bash -n features/feature-database-mariadb.sh && echo OK`
Expected: `OK`

### Task 3.2: Update test rosters

**Files:**
- Modify: `tests/test-manifest.sh`

- [ ] **Step 1: Update both roster strings via `replace_all: true`**

Old:
```
,database,database-mysql,database-sqlite,
```

New:
```
,database,database-mariadb,database-mysql,database-sqlite,
```

### Task 3.3: Run tests + commit

- [ ] **Step 1: Run all 14 tests** — expect all OK.

- [ ] **Step 2: Bump VERSION to `2.5.4`** + **Step 3: Commit**

```bash
git add VERSION features/feature-database-mariadb.sh tests/test-manifest.sh
git commit -F- <<'MSG'
feature-database-mariadb: MariaDB child (mirror of mysql)

Same shell pattern as feature-database-mysql but with mariadb-server
as the package. All shared logic comes from lib/database.sh.

VERSION 2.5.3 -> 2.5.4.

Co-Authored-By: Claude Opus 4.7 <noreply@anthropic.com>
MSG
```

---

## Phase 4 — InnoDB tuning drop-in + Pi-tier helper (→ VERSION 2.5.5)

When `DATABASE_INNODB_TUNE=on` AND DB is mysql/mariadb AND `DATABASE_HOST=SELF`, write `/etc/mysql/conf.d/installicious-pi.cnf` with `innodb_flush_log_at_trx_commit = ${...}` and `innodb_buffer_pool_size = <Pi-tier-auto>`. Restart the active service. When `DATABASE_INNODB_TUNE=off` AND the drop-in exists, remove it and restart (self-healing on flip-off).

### Task 4.1: Create `lib/pi-tier.sh`

**Files:**
- Create: `lib/pi-tier.sh`

- [ ] **Step 1: Write `lib/pi-tier.sh`**

```bash
#!/bin/bash

# lib/pi-tier.sh — Pi-RAM-tier detection.
#
# pi_tier_size_for "<small> <mid> <large> <xl>" — echo the tier value
# matching the detected Pi:
#   small  : Pi Zero / Pi Zero 2 / <= 1 GB total RAM
#   mid    : Pi 3 / Pi 4 (2GB) / 1-3 GB
#   large  : Pi 4 (4GB) / 3-6 GB
#   xl     : Pi 5 / Pi 4 (8GB) / > 6 GB
#
# Caller passes a space-separated list of four values mapped to those
# tiers, e.g.:
#   pi_tier_size_for "64M 128M 256M 512M"
#
# Detection: prefer /proc/device-tree/model when present (Pi-specific
# string); fall back to total RAM from /proc/meminfo (works on
# non-Pi hardware too).

pi_tier_size_for() {
  local sizes="$1"
  read -r small mid large xl <<< "$sizes"

  local model=""
  if [[ -r /proc/device-tree/model ]]; then
    model=$(tr -d '\0' < /proc/device-tree/model 2>/dev/null || true)
  fi

  case "$model" in
    *"Pi 5"*)       echo "$xl"; return ;;
    *"Pi Zero 2"*)  echo "$small"; return ;;
    *"Pi Zero"*)    echo "$small"; return ;;
  esac

  # Pi 4 ambiguity (1/2/4/8 GB variants) + everything else: use total RAM.
  local mem_kb mem_mb
  mem_kb=$(awk '/^MemTotal:/ {print $2; exit}' /proc/meminfo 2>/dev/null || echo 0)
  mem_mb=$(( mem_kb / 1024 ))

  if   (( mem_mb >= 6144 )); then echo "$xl"
  elif (( mem_mb >= 3072 )); then echo "$large"
  elif (( mem_mb >= 1280 )); then echo "$mid"
  else echo "$small"
  fi
}
```

- [ ] **Step 2: Syntax-check**

Run: `bash -n lib/pi-tier.sh && echo OK`
Expected: `OK`

### Task 4.2: Add the InnoDB tuning helpers to `lib/database.sh`

**Files:**
- Modify: `lib/database.sh`

- [ ] **Step 1: Add helper functions to the end of `lib/database.sh`**

Append the following functions (BEFORE `database_install_mysql_family` is fine, or at the bottom — the order in Bash doesn't matter for sourced files):

```bash
# database_apply_innodb_tune <service>
# When DATABASE_INNODB_TUNE=on AND we're local, write the drop-in and
# restart. When DATABASE_INNODB_TUNE=off AND the drop-in exists, remove
# it and restart (self-healing on flip-off).
database_apply_innodb_tune() {
  local service="$1"
  local conf="/etc/mysql/conf.d/installicious-pi.cnf"

  if ! database_is_local; then
    log_info "Skipping InnoDB tune — DATABASE_HOST=${DATABASE_HOST} is remote."
    return 0
  fi

  if [[ "${DATABASE_INNODB_TUNE:-off}" != "on" ]]; then
    if [[ -f $conf ]]; then
      log_info "DATABASE_INNODB_TUNE=off but $conf exists — removing and restarting $service."
      sudo rm -f "$conf"
      sudo systemctl restart "$service" 2>&1 | tee -a "$FILE_LOG_INSTALLER" \
        || log_warn "restart $service after tune-off returned non-zero."
    fi
    return 0
  fi

  source lib/pi-tier.sh
  local pool_size flush
  flush="${DATABASE_INNODB_FLUSH_LOG_AT_TRX_COMMIT:-2}"
  if [[ "${DATABASE_INNODB_BUFFER_POOL_SIZE:-AUTO}" == "AUTO" ]]; then
    pool_size=$(pi_tier_size_for "64M 128M 256M 512M")
  else
    pool_size="$DATABASE_INNODB_BUFFER_POOL_SIZE"
  fi

  log_info "Writing $conf (innodb_flush_log_at_trx_commit=$flush, innodb_buffer_pool_size=$pool_size)."
  sudo tee "$conf" >/dev/null <<CONF
# /etc/mysql/conf.d/installicious-pi.cnf
# Generated by feature-database-mysql / -mariadb when DATABASE_INNODB_TUNE=on.
# Delete this file (or set DATABASE_INNODB_TUNE=off and re-run installicious)
# and restart the server to revert.
[mysqld]
# Flush the InnoDB redo log to disk once per second instead of on every
# commit -- big SD-write reduction. Up to ~1 sec of just-committed
# transactions can be lost on power loss; for a WeeWx station with 5-min
# archive intervals that's a non-issue.
innodb_flush_log_at_trx_commit = ${flush}

# Cache more table data + indexes in RAM, fewer SD reads. Auto-sized
# per Pi RAM tier; override via DATABASE_INNODB_BUFFER_POOL_SIZE in
# configuration.override.
innodb_buffer_pool_size = ${pool_size}
CONF
  sudo chmod 0644 "$conf"

  log_info "Restarting $service to apply tune."
  sudo systemctl restart "$service" 2>&1 | tee -a "$FILE_LOG_INSTALLER" \
    || log_warn "restart $service returned non-zero."
}
```

- [ ] **Step 2: Call `database_apply_innodb_tune` from `database_install_mysql_family`**

In `database_install_mysql_family`, after the `database_provision_local` block and BEFORE the Python bindings install, add:

```bash
    database_apply_innodb_tune "$service"
```

Locate the existing block:
```bash
    if ! database_provision_local; then
      status_mark_failed "$id" "provisioning failed (root socket auth)"
      echo -e "[ \e[0;31mFAIL\e[0m ] Could not provision via 'sudo mysql -u root'. Re-enable socket auth (ALTER USER 'root'@'localhost' IDENTIFIED VIA unix_socket;) or provision the WeeWx DB + user by hand and re-run."
      return 1
    fi
  else
```

Insert the call between the `fi` (closing `database_provision_local`) and the `else` (closing `if database_is_local`):

```bash
    if ! database_provision_local; then
      status_mark_failed "$id" "provisioning failed (root socket auth)"
      echo -e "[ \e[0;31mFAIL\e[0m ] Could not provision via 'sudo mysql -u root'. Re-enable socket auth (ALTER USER 'root'@'localhost' IDENTIFIED VIA unix_socket;) or provision the WeeWx DB + user by hand and re-run."
      return 1
    fi
    database_apply_innodb_tune "$service"
  else
```

- [ ] **Step 3: Syntax-check**

Run: `bash -n lib/database.sh && echo OK`
Expected: `OK`

### Task 4.3: Extend `tests/test-database.sh`

**Files:**
- Modify: `tests/test-database.sh`

- [ ] **Step 1: Add two test sections at the end (before `=== Done ===`)**

```bash
# ============================================================================
echo "=== Test 8: pi_tier_size_for ==="
source lib/pi-tier.sh
# We don't know which Pi (or non-Pi) the test runs on — just verify the
# helper returns ONE of the four sizes when called with our actual
# argument shape.
val=$(pi_tier_size_for "64M 128M 256M 512M")
case "$val" in
  64M|128M|256M|512M) ok "pi_tier_size_for returns one of {64M,128M,256M,512M}: $val" ;;
  *) fail "pi_tier_size_for unexpected value: '$val'" ;;
esac

# ============================================================================
echo "=== Test 9: InnoDB tune off + missing file -> no-op ==="
# We cannot exercise the actual `sudo tee` path in tests, but we can
# verify the helper short-circuits when DATABASE_INNODB_TUNE=off and
# there's no existing drop-in. (When the file exists and TUNE=off, the
# helper would try to `sudo rm` it; we skip exercising that here.)
DATABASE_INNODB_TUNE="off"
DATABASE_HOST="SELF"
# Replace sudo + systemctl with no-ops so the helper can run.
sudo() { "$@"; }
systemctl() { :; }
rm_path=/tmp/installicious-pi-test-noexist.cnf
[[ ! -f $rm_path ]] && ok "drop-in absent precondition met" || rm -f "$rm_path"
# database_apply_innodb_tune writes /etc/mysql/conf.d/installicious-pi.cnf
# unconditionally on a real system; we just confirm the early-return on
# TUNE=off doesn't blow up.
database_apply_innodb_tune mariadb >/dev/null 2>&1
chkrc "TUNE=off rc=0" $? 0
```

- [ ] **Step 2: Run the test**

Run: `bash tests/test-database.sh`
Expected: all OK including new Test 8 + 9, `=== Done ===` at the end.

### Task 4.4: Run full suite + commit

- [ ] **Step 1: Run all 14 tests** — expect all OK.

- [ ] **Step 2: Bump VERSION to `2.5.5`** + **Step 3: Commit**

```bash
git add VERSION lib/database.sh lib/pi-tier.sh tests/test-database.sh
git commit -F- <<'MSG'
feature-database: InnoDB Pi-tuning drop-in (off by default)

Adds the optional /etc/mysql/conf.d/installicious-pi.cnf drop-in
that ships sane Pi defaults for mysql/mariadb when
DATABASE_INNODB_TUNE=on. Two knobs:
- innodb_flush_log_at_trx_commit = 2 (configurable via
  DATABASE_INNODB_FLUSH_LOG_AT_TRX_COMMIT; defaults to 2 = once/sec
  redo-log flush, big SD-write savings).
- innodb_buffer_pool_size auto-tuned per Pi RAM tier via the new
  shared lib/pi-tier.sh helper (64M / 128M / 256M / 512M).

When TUNE=off AND the drop-in exists, the helper removes it and
restarts the server -- self-healing on flip-off. Remote DB skips
the tune entirely (not our config to manage).

VERSION 2.5.4 -> 2.5.5.

Co-Authored-By: Claude Opus 4.7 <noreply@anthropic.com>
MSG
```

---

## Phase 5 — weewx-setup wiring (→ VERSION 2.5.6)

Make `feature-weewx-setup` aware of `database.state`: when `DATABASE_TYPE=mysql` or `mariadb`, overlay the `[DataBindings]/[Databases]/[DatabaseTypes]` sections onto `weewx.conf` via the existing `resources/weewx-merge-overrides.py` helper. Add `II_DEPS+=" database"` so the scheduler orders the picked DB child before weewx-setup. Verify weewx-setup's existing re-run path restores the pre-install snapshot before re-applying — that's what makes a DB-type switch revert cleanly. If it doesn't, fix that too.

### Task 5.1: Inspect `feature-weewx-setup.sh`'s re-run / snapshot handling

**Files:**
- Read-only: `features/feature-weewx-setup.sh`, `lib/backup.sh`

- [ ] **Step 1: Read `features/feature-weewx-setup.sh` end-to-end**

Read the whole file. Identify:
- Where `II_DEPS` is set (so you can edit it).
- The `do_install` (or top-level install body) — specifically where weewx.conf is modified.
- Whether `backup_create` is called for `/etc/weewx/weewx.conf` BEFORE the existing weectl reconfigure / override-merge pass.
- Whether re-runs **restore from snapshot first**, or just re-apply on top of the previous run's output.

- [ ] **Step 2: Decide the wiring approach**

Two cases:

**Case A — existing path already restores-from-snapshot on every re-run.** Then the overlay just needs to be the LAST step (after the existing override-merge). Easy: add a `database.state` read + overlay-emit step at the end of the install body.

**Case B — existing path does NOT restore-from-snapshot.** Then re-running weewx-setup after switching DB types leaves stale MySQL config in weewx.conf. The plan must add a `backup_restore_or_remove` (or similar) call near the top of `do_install` so weewx.conf is reset to its pre-installer state before each re-run.

Note which case applies (write a one-line note in the commit message). The work changes accordingly:
- Case A: only adds the overlay-emit step.
- Case B: adds the restore-first step too.

### Task 5.2: Add `II_DEPS+=" database"` to weewx-setup

**Files:**
- Modify: `features/feature-weewx-setup.sh`

- [ ] **Step 1: Update the manifest**

Find the manifest block (look for `# === II_MANIFEST_BEGIN ===`). Change:

Old:
```bash
II_DEPS="weewx"
```

New:
```bash
II_DEPS="weewx database"
```

(Space-separated. `database` is the parent — the scheduler will resolve its picked child via the radio.)

### Task 5.3: Add the weewx.conf overlay step

**Files:**
- Modify: `features/feature-weewx-setup.sh`

- [ ] **Step 1: Locate the end of the existing install body**

Find the part of `do_install` that comes RIGHT AFTER the existing `resources/weewx-merge-overrides.py` invocation and BEFORE `status_mark_complete`. We're appending the DB overlay step there.

- [ ] **Step 2: Add the DB-state sourcing + overlay emission**

Insert a code block like this (adjust variable names if they differ in the actual file):

```bash
# --- Database overlay -----------------------------------------------------
# Sourced from /etc/installicious/state/database.state (written by the
# feature-database-* child that just ran). When DATABASE_TYPE is mysql
# or mariadb, write a small weewx.conf overlay pointing the wx_binding
# at the MySQL backend; SQLite (the weewx pkg default) needs no overlay.
DATABASE_STATE_FILE="${PATH_STATE:-/etc/installicious/state}/database.state"
DATABASE_CREDS_FILE="${PATH_STATE:-/etc/installicious/state}/database.creds"
if [[ -f $DATABASE_STATE_FILE ]]; then
  # shellcheck disable=SC1090
  source "$DATABASE_STATE_FILE"
  [[ -f $DATABASE_CREDS_FILE ]] && source "$DATABASE_CREDS_FILE"
fi

case "${DATABASE_TYPE:-sqlite}" in
  ""|sqlite)
    log_info "DATABASE_TYPE=sqlite (or unset) — no weewx.conf overlay needed."
    ;;
  mysql|mariadb)
    local host_resolved="$DATABASE_HOST"
    case "$host_resolved" in SELF|self|"") host_resolved="localhost" ;; esac

    local overlay
    overlay=$(mktemp)
    cat > "$overlay" <<INI
# Auto-generated overlay (DATABASE_TYPE=$DATABASE_TYPE)
[DataBindings]
    [[wx_binding]]
        database = archive_mysql
[Databases]
    [[archive_mysql]]
        database_name = $DATABASE_NAME
        database_type = MySQL
[DatabaseTypes]
    [[MySQL]]
        host     = $host_resolved
        port     = ${DATABASE_PORT:-3306}
        user     = $DATABASE_USER
        password = $DATABASE_PASS
        driver   = weedb.mysql
INI
    log_info "Merging DB overlay onto /etc/weewx/weewx.conf (host=$host_resolved type=$DATABASE_TYPE)."
    sudo python3 resources/weewx-merge-overrides.py \
      --target /etc/weewx/weewx.conf \
      --override "$overlay" 2>&1 | tee -a "$FILE_LOG_INSTALLER" \
      || log_warn "weewx-merge-overrides.py returned non-zero for the DB overlay."
    rm -f "$overlay"
    ;;
  *)
    log_warn "Unknown DATABASE_TYPE='$DATABASE_TYPE' — no overlay."
    ;;
esac
```

> If your inspection in Task 5.1 revealed Case B (no restore-on-rerun), also add a `backup_restore_or_remove` call BEFORE the existing weectl reconfigure block, so each re-run starts from the pristine weewx.conf snapshot and the overlay is freshly applied. Pattern (refer to other features that do this — `feature-neowx-material.sh` is a good model):
>
> ```bash
> # Restore the pristine pre-install weewx.conf before reapplying any
> # overlay, so a DB-type switch between runs doesn't leave stale
> # [DataBindings] / [Databases] / [DatabaseTypes] sections behind.
> local snap; snap=$(backup_latest "$II_ID" /etc/weewx/weewx.conf)
> [[ -n $snap ]] && sudo cp -p "$snap" /etc/weewx/weewx.conf
> ```
>
> (Exact API depends on what `lib/backup.sh` exposes — confirm with a Grep when implementing.)

- [ ] **Step 3: Syntax-check**

Run: `bash -n features/feature-weewx-setup.sh && echo OK`
Expected: `OK`

### Task 5.4: Add a scheduler test for the new dep ordering

**Files:**
- Modify: `tests/test-scheduler.sh`

- [ ] **Step 1: Append a new test section before the existing `=== Done ===`**

Find the last numbered test in `tests/test-scheduler.sh` (probably Test 16 — `skyfield → weewx dep resolves cleanly`). Add Test N+1 right after it, using the same synthetic-feature pattern (`mk_installer`).

```bash
# ===========================================================================
echo
echo "=== Test 17: weewx-setup -> database dep resolves cleanly ==="
# weewx-setup gets `II_DEPS="weewx database"` in Phase 5. Confirm the
# scheduler orders database (and its picked child via II_OPTIONAL_GROUP)
# ahead of weewx-setup when both are requested.
mk_installer database-fake ""
mk_installer weewx-setup-fake "database-fake"
got=$(scheduler_resolve_deps weewx-setup-fake | sort | tr "\n" ",")
chkeq "weewx-setup-fake -> database-fake,weewx-setup-fake" "$got" "database-fake,weewx-setup-fake,"
```

- [ ] **Step 2: Run the scheduler test**

Run: `bash tests/test-scheduler.sh`
Expected: all OK including the new Test 17, `=== Done ===`.

### Task 5.5: Run full suite + commit

- [ ] **Step 1: Run all 14 tests** — expect all OK.

- [ ] **Step 2: Bump VERSION to `2.5.6`** + **Step 3: Commit**

```bash
git add VERSION features/feature-weewx-setup.sh tests/test-scheduler.sh
git commit -F- <<'MSG'
feature-weewx-setup: overlay weewx.conf for mysql/mariadb backend

When /etc/installicious/state/database.state reports DATABASE_TYPE=
mysql or mariadb, generate a weewx.conf overlay binding wx_binding to
archive_mysql and pointing the MySQL DatabaseType at the resolved
host/port/user/pass. SQLite is unchanged (weewx ships SQLite as its
default; no overlay needed).

II_DEPS gains "database" so the scheduler queues the picked DB
child (sqlite/mysql/mariadb) ahead of weewx-setup. New
tests/test-scheduler.sh Test 17 covers the dep ordering.

[NOTE: include a one-line about Case A vs Case B from Task 5.1 here]

VERSION 2.5.5 -> 2.5.6.

Co-Authored-By: Claude Opus 4.7 <noreply@anthropic.com>
MSG
```

---

## Phase 6 — Conflict handling for ramdisk + onedrive backup (→ VERSION 2.5.7)

`feature-weewx-database-ram` and `feature-weewx-onedrive-backup` are SQLite-specific. Both self-skip cleanly when DATABASE_TYPE != sqlite — no FAIL, no work, status_mark_complete.

### Task 6.1: Self-skip in `feature-weewx-database-ram.sh`

**Files:**
- Modify: `features/feature-weewx-database-ram.sh`

- [ ] **Step 1: Locate `do_install` (or top-of-install block)**

Find the line right after `status_mark_started` and before any actual install work.

- [ ] **Step 2: Insert the self-skip block**

```bash
  # --- DB-type self-skip --------------------------------------------------
  # weewx-database-ram is SQLite-specific (it manages the .sdb file on
  # zram). If feature-database recorded a non-SQLite backend, this
  # feature has nothing meaningful to do. Mark complete and exit so the
  # user doesn't see a FAIL or a half-built ramdisk.
  local _db_state="${PATH_STATE:-/etc/installicious/state}/database.state"
  if [[ -f $_db_state ]]; then
    # shellcheck disable=SC1090
    _db_type=$(source "$_db_state" 2>/dev/null; printf '%s' "${DATABASE_TYPE:-}")
    case "$_db_type" in
      ""|sqlite)
        : # proceed
        ;;
      *)
        log_info "DATABASE_TYPE=$_db_type — weewx-database-ram is SQLite-only, skipping."
        status_mark_complete "$II_ID" "$II_VERSION"
        echo -e "[  \e[0;32mOK\e[0m  ] weewx-database-ram: not applicable for DATABASE_TYPE=$_db_type (skipped)."
        return 0
        ;;
    esac
  fi
```

(If the file uses a top-level `if` instead of a `do_install` function, replace `return 0` with `exit 0` and remove the `local` keyword.)

### Task 6.2: Self-skip in `feature-weewx-onedrive-backup.sh` install body

**Files:**
- Modify: `features/feature-weewx-onedrive-backup.sh`

- [ ] **Step 1: Apply the same self-skip block** at the top of `do_install`, right after `status_mark_started`. Use the same code as Task 6.1 but with `weewx-onedrive-backup` in the messages.

### Task 6.3: Self-skip in the EMBEDDED runtime backup script

**Files:**
- Modify: `features/feature-weewx-onedrive-backup.sh` (the heredoc'd runtime script)

This is critical: the runtime script runs nightly under systemd, NOT through installicious. It must do the check itself per run so adding/removing a non-sqlite database later (without re-installing the backup feature) Does The Right Thing.

- [ ] **Step 1: Add a self-skip block inside the runtime script**

Find the `<<'ONEDRIVE_BACKUP_EOF'` heredoc body. Near the top, right after `source /etc/weewx-onedrive-backup.conf`, add:

```bash
# Per-run DB-type self-skip: this script reads SQLite files via
# `sqlite3 .backup`. If the WeeWX backend is mysql/mariadb (per
# feature-database), there's nothing for us to do here today (a
# mysqldump branch is a planned follow-up).
if [[ -f /etc/installicious/state/database.state ]]; then
  # shellcheck disable=SC1091
  source /etc/installicious/state/database.state
  case "${DATABASE_TYPE:-sqlite}" in
    ""|sqlite) : ;;
    *)
      logger -t weewx-onedrive "[$TIER] DATABASE_TYPE=$DATABASE_TYPE -- SQLite-only backup, skipping."
      exit 0 ;;
  esac
fi
```

> **Where to put it:** between the `source /etc/weewx-onedrive-backup.conf` line and the `case "$TIER" in` block — i.e., before TIER is parsed, BUT after the conf is sourced (so the logger tag still works). Actually `TIER` is used in the logger message above — move this block to AFTER the `case "$TIER" in ... esac` block so `$TIER` is set when we log the skip.

- [ ] **Step 2: Bump `II_VERSION` of `feature-weewx-onedrive-backup.sh` from `1` to `2`**

The runtime script changed → the install must re-run → bump II_VERSION:

Old:
```bash
II_VERSION="1"
```

New:
```bash
II_VERSION="2"
```

- [ ] **Step 3: Syntax-check both modified features**

Run: `bash -n features/feature-weewx-database-ram.sh && bash -n features/feature-weewx-onedrive-backup.sh && echo OK`
Expected: `OK`

Then extract the embedded runtime script and syntax-check it:

```bash
sed -n "/<<'ONEDRIVE_BACKUP_EOF'/,/^ONEDRIVE_BACKUP_EOF/p" features/feature-weewx-onedrive-backup.sh \
  | sed '1d;$d' > /tmp/rt-check.sh && bash -n /tmp/rt-check.sh && echo OK
rm /tmp/rt-check.sh
```

Expected: `OK`.

### Task 6.4: Run full suite + commit

- [ ] **Step 1: Run all 14 tests** — expect all OK.

- [ ] **Step 2: Bump VERSION to `2.5.7`** + **Step 3: Commit**

```bash
git add VERSION features/feature-weewx-database-ram.sh features/feature-weewx-onedrive-backup.sh
git commit -F- <<'MSG'
weewx-database-ram + weewx-onedrive-backup: self-skip when DB != sqlite

Both features (and the embedded onedrive-backup runtime script) read
/etc/installicious/state/database.state at install time / per run and
exit 0 with status_mark_complete + a clear log line when
DATABASE_TYPE is mysql or mariadb. No menu plumbing -- both features
stay in DEFAULT and self-heal whichever backend is active.

weewx-onedrive-backup II_VERSION bumped 1 -> 2 to force a re-install
that picks up the new runtime script.

VERSION 2.5.6 -> 2.5.7.

Co-Authored-By: Claude Opus 4.7 <noreply@anthropic.com>
MSG
```

---

## Phase 7 — Docs + MINOR bump (→ VERSION 2.6.0)

Final phase. Updates the user-facing docs to reflect the landed feature, then bumps to `2.6.0` to mark the MINOR-version release.

### Task 7.1: Update `overrides/configuration.override.example`

**Files:**
- Modify: `overrides/configuration.override.example`

- [ ] **Step 1: Insert a new section for the DATABASE_* editable keys**

Find a logical place — between the existing `# WeeWX OneDrive backup ...` section and the next one. Insert:

```
# ----------------------------------------------------------------------------
# Database backend — feature-database (sqlite/mysql/mariadb radio)
# (DATABASE_TYPE itself is the radio pick, not an editable key. The five
#  keys below appear on the in-menu Edit Configuration screen ONLY when
#  MySQL or MariaDB is picked.)
# ----------------------------------------------------------------------------
#DATABASE_HOST="SELF"                       # SELF = install + run locally on this Pi; an IP = remote (no server install)
#DATABASE_NAME="AUTO"                       # AUTO -> per-role default ("weewx" under the WeeWx role)
#DATABASE_USER="AUTO"                       # AUTO -> same as resolved DATABASE_NAME
#DATABASE_PASS="AUTO"                       # AUTO -> 24-char random, persisted root-readable
#DATABASE_INNODB_TUNE="off"                 # on = drop /etc/mysql/conf.d/installicious-pi.cnf (flush=2 + Pi-tier buffer pool)
```

### Task 7.2: Update `README.md`

**Files:**
- Modify: `README.md`

- [ ] **Step 1: Update the WeeWx section's tier description**

Find the WeeWx section's "DEFAULT" list (around the existing text mentioning "weewx-setup weewx-webroot ..." or the table listing the weewx-role-only features). Add `database` to the appropriate spots so the documented role tier matches the new `ROLE_FEATURES_DEFAULT`.

- [ ] **Step 2: Add a new feature section / bullet for `database`**

In the same WeeWx region (next to the existing `weewx-onedrive-backup` bullet), add:

```markdown
- **database** — sqlite/mysql/mariadb radio. SQLite is the default (no-op
  leaf — `weewx` ships with SQLite already). Picking **MySQL** or
  **MariaDB** triggers a real install:
  - Installs the server (`default-mysql-server` or `mariadb-server`) when
    `DATABASE_HOST=SELF`; skips the server install when `DATABASE_HOST`
    is a remote IP.
  - Provisions `${DATABASE_NAME}` + `${DATABASE_USER}@localhost` with a
    persisted random password (`/etc/installicious/state/database.creds`,
    mode 0600). AUTO sentinels resolve to `weewx`/`weewx`/random. AUTO
    creds + remote `DATABASE_HOST` is a hard error.
  - Installs the role-specific Python bindings
    (`python3-pymysql` under the WeeWx role).
  - Optional InnoDB Pi-tuning: `DATABASE_INNODB_TUNE=on` writes
    `/etc/mysql/conf.d/installicious-pi.cnf` with
    `innodb_flush_log_at_trx_commit=2` and a Pi-RAM-tier-sized
    `innodb_buffer_pool_size`. `off` removes the drop-in on re-run.
  - Writes `/etc/installicious/state/database.state` for downstream
    features. `feature-weewx-setup` reads it and overlays
    `weewx.conf`'s `[DataBindings]/[Databases]/[DatabaseTypes]` to point
    WeeWX at the picked backend.
  - `feature-weewx-database-ram` and `feature-weewx-onedrive-backup`
    self-skip cleanly when `DATABASE_TYPE != sqlite` (they're
    SQLite-only).
  - Uninstall drops the DB + user, removes the server packages and the
    tune drop-in. **Existing data is destroyed** — logged loudly.
```

Update the WeeWx tier description sentence at the top of the section to mention `database` as the first DEFAULT feature.

### Task 7.3: Run full suite + commit + MINOR bump

- [ ] **Step 1: Run all 14 tests** — expect all OK.

- [ ] **Step 2: Bump VERSION to `2.6.0`** (MINOR bump — feature lands)

- [ ] **Step 3: Stage + commit**

```bash
git add VERSION README.md overrides/configuration.override.example
git commit -F- <<'MSG'
feature-database: docs + MINOR bump (2.5.7 -> 2.6.0)

Final phase of the feature-database landing per
docs/superpowers/specs/2026-05-22-feature-database-design.md:

- README WeeWx section gains a `database` bullet documenting the
  radio, AUTO-credential resolution, remote-DB handling, InnoDB
  Pi-tuning drop-in, weewx.conf overlay wiring, and conflict
  self-skip in weewx-database-ram + weewx-onedrive-backup.
- overrides/configuration.override.example gains the five
  DATABASE_* editable keys.

MINOR bump 2.5.7 -> 2.6.0 marks the feature complete.

Co-Authored-By: Claude Opus 4.7 <noreply@anthropic.com>
MSG
```

---

## Post-implementation manual verification (on a real Pi)

These are NOT automated tests — they exercise the full menu + apt + systemd flow that the test suite can't reach. Run them after Phase 7 against a fresh Pi (or three).

1. **Fresh Pi, WeeWx role, default radio (SQLite):**
   - Run installicious, pick WeeWx, accept defaults (SQLite stays picked).
   - Confirm `/etc/installicious/state/database.state` shows `DATABASE_TYPE="sqlite"`.
   - Confirm `sudo systemctl status weewx` is active.
   - Confirm the WeeWx web page renders.

2. **Fresh Pi, WeeWx role, pick MariaDB, accept all AUTO creds:**
   - Run installicious, pick WeeWx, flip the database radio to MariaDB.
   - Don't change the AUTO defaults on the editor screen.
   - Confirm `dpkg -l | grep mariadb-server` returns installed.
   - Confirm `/etc/installicious/state/database.state` shows `DATABASE_TYPE="mariadb"`, `DATABASE_NAME="weewx"`.
   - Confirm `/etc/installicious/state/database.creds` is mode 0600.
   - Run `sudo mysql -u root -e "SHOW DATABASES;"` → see `weewx`.
   - Run `sudo mysql -u root -e "SELECT user, host FROM mysql.user WHERE user='weewx';"` → see `weewx@localhost`.
   - Confirm `/etc/weewx/weewx.conf` `[DataBindings]/[wx_binding]/database = archive_mysql` and the matching `[Databases]/[[archive_mysql]]` block points at localhost.
   - Confirm `sudo systemctl status weewx` is active and the WeeWx web page renders.

3. **Same Pi, re-run installicious unchanged:**
   - `/etc/installicious/state/database.creds` password is the SAME (not regenerated).
   - WeeWX still running.

4. **Pi with `DATABASE_HOST` set to a remote IP, AUTO creds:**
   - Edit `overrides/configuration.override` to set `DATABASE_HOST="192.168.1.50"` (or any IP).
   - Pick MariaDB, leave USER + PASS as AUTO.
   - Install fails with the "Remote DATABASE_HOST requires explicit DATABASE_USER and DATABASE_PASS" message. No mariadb-server is installed.

5. **Pi with MariaDB + `weewx-database-ram` checked:**
   - WeeWX role, pick MariaDB, also keep `weewx-database-ram` checked in DEFAULT.
   - `weewx-database-ram` install logs `DATABASE_TYPE=mariadb — weewx-database-ram is SQLite-only, skipping.` and exits OK.
   - No zram device created.

6. **Pi with MariaDB + `weewx-onedrive-backup` enabled:**
   - Run `sudo systemctl start weewx-onedrive-backup-daily.service` manually.
   - `journalctl -t weewx-onedrive` shows `DATABASE_TYPE=mariadb -- SQLite-only backup, skipping.`
   - No file uploaded to OneDrive.

7. **Switch MariaDB → SQLite on a working Pi:**
   - Run installicious again, flip the database radio to SQLite.
   - `weewx-setup` re-runs. `/etc/weewx/weewx.conf` `[DataBindings]/[wx_binding]/database` reverts to `archive_sqlite` (no leftover `archive_mysql`).
   - WeeWX still runs (no `weectl database --transfer-database` — fresh SQLite start, no migration).

8. **`DATABASE_INNODB_TUNE=on` toggle:**
   - With MariaDB picked, set `DATABASE_INNODB_TUNE=on` via the in-menu editor. Re-run.
   - `cat /etc/mysql/conf.d/installicious-pi.cnf` shows the two knobs.
   - `sudo mysql -u root -e "SHOW VARIABLES LIKE 'innodb_flush_log_at_trx_commit';"` → `2`.
   - `sudo mysql -u root -e "SHOW VARIABLES LIKE 'innodb_buffer_pool_size';"` matches the Pi-tier expectation.
   - Flip `DATABASE_INNODB_TUNE=off`, re-run. `installicious-pi.cnf` is removed; defaults are restored after the server restart.

9. **`--uninstall database-mariadb`:**
   - `sudo bash installicious.sh --uninstall database-mariadb`.
   - `weewx` database + user dropped (`SHOW DATABASES` no longer lists `weewx`).
   - `dpkg -l | grep mariadb-server` shows the package removed.
   - `/etc/installicious/state/database.state` and `database.creds` are gone.

---

## Self-review checklist (run after writing — already complete)

- **Spec coverage:** every section of the spec maps to a phase + tasks above. ✓
- **Placeholders:** every step has either a complete code block or an exact command. The two `Inspect feature-weewx-setup.sh` steps (Task 5.1, Task 5.3 NOTE) are explicit "read the code and decide" steps with both branches detailed — not placeholders. ✓
- **Type consistency:** function names (`database_resolve_credentials`, `database_install_mysql_family`, etc.) are used consistently in `lib/database.sh`, the child features, and the tests. State-file paths (`/etc/installicious/state/database.state` and `database.creds`) match across all references. Editable key set (HOST/NAME/USER/PASS/INNODB_TUNE) is consistent. ✓
- **VERSION ladder:** 2.5.1 (start) → 2.5.2 → 2.5.3 → 2.5.4 → 2.5.5 → 2.5.6 → 2.5.7 → 2.6.0. Seven phase bumps, the last being MINOR. ✓
