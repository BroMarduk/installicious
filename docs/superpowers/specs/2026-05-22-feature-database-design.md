# feature-database — design

**Status:** brainstormed + approved 2026-05-22
**Branch:** ai-refactor
**Author:** Dan + Claude (brainstorming skill)

## Goal

Add a generic `feature-database` to installicious that lets a role offer a
choice of SQLite (default), MySQL, or MariaDB. Generic enough that future
roles (HomeAssistant, etc.) can reuse it. For the WeeWx role today: present
the radio after the webserver pick, install the right server + role-specific
Python bindings, and **wire WeeWX to actually use the picked DB** by
overlaying `weewx.conf` (no data migration).

## Non-goals (deferred follow-ups)

- **Data migration** SQLite → MySQL on a switch (`weectl database
  --transfer-database` wrapper). Switching mid-history starts a fresh DB.
- **Cross-DB swap automation** (mariadb → mysql in one re-run). Today the
  operator uninstalls the old child first or starts from a clean DB.
- **MySQL backup branch** in `feature-weewx-onedrive-backup` (`mysqldump`
  variant). The existing `sqlite3 .backup` path no-ops for non-SQLite.
- **Full mysql-in-RAM feature** parallel to `feature-weewx-database-ram`.
  Server lifecycle + transaction-aware shutdown make this its own design;
  the InnoDB tuning drop-in covers the SD-wear angle for now.
- **Database picker for other roles.** This design lands the framework + the
  WeeWx wiring. Other roles pick it up later by declaring a
  `config/database-<role>.config` and listing `database` in their tier.

## Architecture overview — mirrors `feature-webserver`

```
features/
  feature-database.sh                # parent grouping feature; no-op recorder
  feature-database.choices.sh        # _choices_/_applies_ for radio + creds
  feature-database-sqlite.sh         # no-op leaf (weewx pkg ships SQLite)
  feature-database-mysql.sh          # installs mysql-server + provisions
  feature-database-mariadb.sh        # installs mariadb-server + provisions
config/
  database.config                    # generic defaults (HOST, NAME, USER, PASS,
                                     # PORT, INNODB_TUNE + underlying knobs)
  database-weewx.config              # WeeWx-specific Python-package matrix
                                     # per DB type, + AUTO default name/user.
roles/
  role-weewx.sh                      # adds `database` to ROLE_FEATURES_DEFAULT
                                     # at the front (right after the
                                     # REQUIRED webserver radio)
```

The parent declares `II_OPTIONAL_GROUP="database-sqlite database-mysql
database-mariadb"` + `II_OPTIONAL_GROUP_MODE="exclusive"` — exactly the radio
sub-menu mechanism `feature-webserver` already uses. The three children
declare `II_RESTRICT_TO_ROLES="weewx"` (initially) so they only surface via
the parent's radio, never as standalone rows. The default radio pick is
`database-sqlite` (`II_DEFAULT_SELECTED="on"` on the SQLite child only).

## Config keys

### Editable (parent's `II_EDITABLE_CONFIG`)

| Key | Default | Notes |
|---|---|---|
| `DATABASE_HOST` | `SELF` | `SELF` = install + run locally; an IP = remote (no server install). Hidden when SQLite picked. |
| `DATABASE_NAME` | `AUTO` | `AUTO` resolves to `DATABASE_DEFAULT_NAME` from `config/database-<role>.config` (WeeWx: `weewx`). Hidden when SQLite. |
| `DATABASE_USER` | `AUTO` | `AUTO` → same as the resolved `DATABASE_NAME`. Hidden when SQLite. |
| `DATABASE_PASS` | `AUTO` | `AUTO` → 24-char random, persisted root-readable (see below). Hidden when SQLite. |
| `DATABASE_INNODB_TUNE` | `off` | `off`/`on`. When `on` AND DB is mysql/mariadb AND HOST=SELF, ship the Pi-tuning drop-in. Hidden when SQLite. |

There is deliberately **no** `DATABASE_TYPE` editable key — the radio
sub-menu's pick is the type selector. Its value lives in the framework's
`LAST_ADDONS_PICKED` map (`database:mysql` etc.) and is materialized into a
runtime state file at install time (see "State files").

### Config-file-only (in `config/database.config`)

| Key | Default | Notes |
|---|---|---|
| `DATABASE_PORT` | `3306` | MySQL/MariaDB convention. Editable via `configuration.override` only. |
| `DATABASE_INNODB_BUFFER_POOL_SIZE` | `AUTO` | `AUTO` = auto-tuned per Pi RAM tier (see InnoDB tuning section). |
| `DATABASE_INNODB_FLUSH_LOG_AT_TRX_COMMIT` | `2` | `1` = strict ACID, more SD writes. `0` = riskiest. |

### Per-role (in `config/database-weewx.config`)

```bash
# WeeWx-specific defaults consumed by feature-database-* children when
# LAST_ROLE_ID=weewx.
DATABASE_DEFAULT_NAME="weewx"                       # AUTO -> this
DATABASE_SQLITE_PYTHON_PACKAGES=""                  # weewx ships SQLite
DATABASE_MYSQL_PYTHON_PACKAGES="python3-pymysql"    # weedb.mysql backend
DATABASE_MARIADB_PYTHON_PACKAGES="python3-pymysql"  # same wire protocol
```

## Applicability rules (`feature-database.choices.sh`)

Five `_applies_DATABASE_*` functions share one helper:

```bash
_database_picked_type() {
  # Read LAST_ADDONS_PICKED from the framework's selections.sh; echo
  # one of: sqlite | mysql | mariadb | "" (nothing picked yet).
  source "${PATH_STATE:-state}/selections.sh" 2>/dev/null || return 0
  case "${LAST_ADDONS_PICKED:-}" in
    *database:sqlite*)  echo sqlite ;;
    *database:mysql*)   echo mysql ;;
    *database:mariadb*) echo mariadb ;;
  esac
}

_applies_DATABASE_HOST() {
  local t; t=$(_database_picked_type)
  [[ $t == mysql || $t == mariadb ]]
}
# _applies_DATABASE_NAME / _USER / _PASS / _INNODB_TUNE: same body.
```

Free-form inputbox seeded with the current value for HOST / NAME / USER /
PASS. `_choices_DATABASE_INNODB_TUNE` is a 2-row radio (`off`/`on`).

## AUTO resolution at install time

In `feature-database-mysql.sh` / `feature-database-mariadb.sh` (NOT in the
SQLite child — it has nothing to resolve):

1. Source the active role's sidecar: `${PATH_CONFIG}/database-${LAST_ROLE_ID}.config`
   (silently skipped if absent — generic fallback to `weewx` for NAME).
2. `DATABASE_NAME=AUTO` → `${DATABASE_DEFAULT_NAME:-weewx}`.
3. `DATABASE_USER=AUTO` → same as resolved `DATABASE_NAME`.
4. `DATABASE_PASS=AUTO` → if `/etc/installicious/state/database.creds`
   already has `DATABASE_PASS=<value>` (a non-empty value), **reuse it**.
   Otherwise generate 24 chars:
   ```bash
   openssl rand -base64 18 | tr -dc 'A-Za-z0-9' | head -c 24
   ```
   and persist to `/etc/installicious/state/database.creds` (mode 0600).

The reuse step is critical for idempotence — re-running installicious must
not regenerate the password and break a working WeeWX.

## Remote-DB rules (`DATABASE_HOST` != `SELF` / `localhost` / empty)

- mysql/mariadb child **skips** the server `apt install`.
- mysql/mariadb child **skips** the local CREATE USER / CREATE DATABASE /
  GRANT (no root socket on a remote machine).
- mysql/mariadb child **still installs** the role-specific Python bindings
  (we need them locally to connect).
- mysql/mariadb child **skips** the InnoDB tuning drop-in (not our config).
- **AUTO + remote is a hard error.** If `DATABASE_HOST != SELF` AND
  (`DATABASE_USER == AUTO` OR `DATABASE_PASS == AUTO`), install fails with:
  ```
  Remote DATABASE_HOST requires explicit DATABASE_USER and DATABASE_PASS
  (cannot create a user on a database we do not own). Set both via the
  in-menu editor or overrides/configuration.override.
  ```
  `DATABASE_NAME=AUTO` is allowed for remote — it's just a default name,
  not a credential.
- weewx-setup uses the resolved HOST / PORT / USER / PASS to write the
  remote pointer into `weewx.conf` (see WeeWX wiring section).

## State files (written by the picked child after install)

### `/etc/installicious/state/database.state` (0644, sourceable bash)

```bash
DATABASE_TYPE="mysql"        # sqlite | mysql | mariadb
DATABASE_HOST="SELF"         # SELF, "localhost", or an IP
DATABASE_NAME="weewx"        # AUTO-resolved
DATABASE_USER="weewx"        # AUTO-resolved
DATABASE_PORT="3306"
```

Downstream features (`weewx-setup`, future `weewx-onedrive-backup` MySQL
branch, etc.) source this to learn what was picked. World-readable because
it carries no secrets.

### `/etc/installicious/state/database.creds` (0600, sourceable bash)

```bash
DATABASE_PASS="<resolved>"
```

Separated because the password is the only secret. Mode 0600, root-owned.

Both files are excluded from `setup.sh`'s rsync (they live under
`/etc/installicious/state/`, which is already system-wide and never touched
by the repo's rsync). Removed on uninstall (see Uninstall section).

## Install bodies

### `feature-database.sh` (parent)

Pure recorder. `status_should_skip` / `status_mark_started` /
`status_mark_complete`. No work — the picked child does it.

### `feature-database-sqlite.sh` (leaf)

- `II_DEFAULT_SELECTED="on"` (this is the radio's default pick).
- `II_RESTRICT_TO_ROLES="weewx"`.
- `do_install`: writes `database.state` with `DATABASE_TYPE="sqlite"` and
  empty values for HOST/NAME/USER/PORT (downstream consumers will read
  these as "use WeeWX's defaults"). status_mark_complete.
- `do_uninstall`: removes `database.state`, status_mark_uninstalled. The
  SQLite DB file itself is owned by WeeWX, not by this feature.

### `feature-database-mysql.sh` / `feature-database-mariadb.sh`

Same structure; only `II_APT_PACKAGES` differs (`mysql-server` vs
`mariadb-server`). Pseudocode:

```text
do_install:
  status_should_skip / status_mark_started

  load_per_role_config_if_present     # config/database-<LAST_ROLE_ID>.config
  resolve_HOST_NAME_USER_PASS         # AUTO -> concrete values
                                       # (skip cred CREATE if HOST != SELF)

  if HOST == SELF or empty:
      installer_apt_record_install $II_APT_PACKAGES   # mariadb-server / mysql-server
      systemctl enable --now mariadb (or mysql)
      provision_db_and_user            # CREATE IF NOT EXISTS, idempotent
      maybe_apply_innodb_tune          # if DATABASE_INNODB_TUNE=on
  else:
      log_info "Remote DATABASE_HOST=$HOST — skipping server install + provisioning"

  install_python_bindings              # from DATABASE_<TYPE>_PYTHON_PACKAGES

  write_state_file                     # database.state + database.creds
  status_mark_complete
```

**Provisioning details (local SELF only):**
- Issued via `sudo mysql -u root` (default socket auth on a fresh Debian
  install of either server).
- Idempotent SQL:
  ```sql
  CREATE DATABASE IF NOT EXISTS <name>;
  CREATE USER IF NOT EXISTS '<user>'@'localhost' IDENTIFIED BY '<pass>';
  GRANT ALL PRIVILEGES ON <name>.* TO '<user>'@'localhost';
  FLUSH PRIVILEGES;
  ```
- If socket-auth has been disabled (e.g. someone changed root to use
  password auth), install fails with: "Cannot connect via root socket
  auth. Either re-enable socket auth (`ALTER USER 'root'@'localhost'
  IDENTIFIED VIA unix_socket;`) or provision the WeeWx DB + user
  manually and re-run."

**Schema/charset note:** WeeWX 5 expects `utf8` (3-byte) for compatibility
with older MySQL clients; we'll use the server defaults at provisioning
time and let WeeWX's own `weectl database --create` handle schema. The
provisioned DB is empty when WeeWX first connects; WeeWX creates its
tables on first archive write.

### Uninstall (mysql/mariadb child)

Reverses in opposite order:

1. Stop the server (`systemctl stop mariadb`).
2. **Drop the WeeWX DB + user** (if we created them — recorded by
   provisioning step). This destroys WeeWX's archive data. **Logged loudly
   before doing it.** The user accepted this by running `--uninstall` on the
   DB feature.
3. Remove the InnoDB tuning drop-in (`/etc/mysql/conf.d/installicious-pi.cnf`).
4. `installer_apt_revert` on `$II_APT_PACKAGES` (mariadb-server etc.) and
   the per-role Python bindings.
5. Remove `/etc/installicious/state/database.state` and `database.creds`.
6. status_mark_uninstalled.

For the **remote** case (HOST != SELF), uninstall just removes the Python
bindings + state files; nothing to do on the remote.

## InnoDB tuning drop-in

Triggered when ALL of:
- Picked child is `database-mysql` or `database-mariadb`.
- `DATABASE_INNODB_TUNE` (editable, default `off`) = `on`.
- `DATABASE_HOST` = `SELF` (or empty / `localhost`).

Writes `/etc/mysql/conf.d/installicious-pi.cnf` (both servers read all
`/etc/mysql/conf.d/*.cnf`):

```ini
# /etc/mysql/conf.d/installicious-pi.cnf
# Generated by feature-database-mysql / -mariadb when DATABASE_INNODB_TUNE=on.
# Delete this file and restart mariadb/mysql to revert; or set
# DATABASE_INNODB_TUNE=off and re-run installicious.

[mysqld]
# Flush the InnoDB redo log to disk once per second instead of on every
# commit -- big SD-write reduction. Up to ~1 sec of just-committed
# transactions can be lost on power loss; for a WeeWx station with 5-min
# archive intervals that's a non-issue.
innodb_flush_log_at_trx_commit = ${DATABASE_INNODB_FLUSH_LOG_AT_TRX_COMMIT}

# Cache more table data + indexes in RAM, fewer SD reads. AUTO sizes per
# Pi RAM tier (auto-detected via /proc/device-tree/model + total RAM,
# same approach as feature-ram-logging / feature-compressed-swap):
#   Pi 5 / 8GB Pi 4         -> 512M
#   Pi 4 4GB                 -> 256M
#   Pi 3 / 2GB Pi 4          -> 128M
#   Pi Zero 2 / 1GB and less -> 64M
innodb_buffer_pool_size = ${DATABASE_INNODB_BUFFER_POOL_SIZE_RESOLVED}
```

After writing, `systemctl restart` the active server to apply.

**Revert on flip-off.** Every install run of the mysql/mariadb child also
checks the **inverse** case: if `/etc/mysql/conf.d/installicious-pi.cnf`
exists AND `DATABASE_INNODB_TUNE=off`, the child removes the drop-in and
restarts the server. That makes flipping `on -> off` via the in-menu editor
self-healing on re-run, with no manual cleanup.

**Pi-tier detection** is shared with `feature-ram-logging` and
`feature-compressed-swap`. The resolution helper lives at `lib/pi-tier.sh`
(new) — extracted from whichever existing feature has the most complete
detection today, and called from all three. Out of scope to refactor the
existing two callers in this design, but they continue to work; the new
helper is additive. (If extraction proves too invasive during plan, the
mysql/mariadb child can inline its own detection — matching the existing
features' patterns.)

## WeeWX wiring (`feature-weewx-setup.sh`)

- Add `II_DEPS+=" database"` so the scheduler queues `database` (and its
  picked child) ahead of `weewx-setup`.
- After the existing `weectl station reconfigure` pass, source
  `/etc/installicious/state/database.state` and `/etc/installicious/state/database.creds`.
- Branch on `DATABASE_TYPE`:
  - **`sqlite` or empty/missing:** do nothing extra. WeeWX's shipped
    defaults point at `archive_sqlite`. Backwards-compatible with every
    existing install.
  - **`mysql` or `mariadb`:** generate a runtime overlay snippet (below)
    and deep-merge it onto `/etc/weewx/weewx.conf` via the existing
    `resources/weewx-merge-overrides.py` helper (configobj).

```ini
# Generated overlay for /etc/weewx/weewx.conf when DATABASE_TYPE=mysql or mariadb.
[DataBindings]
    [[wx_binding]]
        database = archive_mysql
[Databases]
    [[archive_mysql]]
        database_name = ${DATABASE_NAME}
        database_type = MySQL
[DatabaseTypes]
    [[MySQL]]
        host     = ${DATABASE_HOST_OR_LOCALHOST}
        port     = ${DATABASE_PORT}
        user     = ${DATABASE_USER}
        password = ${DATABASE_PASS}
        driver   = weedb.mysql
```

Notes:
- `${DATABASE_HOST_OR_LOCALHOST}` resolves `SELF` → `localhost` at overlay
  time; explicit IPs pass through.
- Both `mysql` and `mariadb` use weewx's `weedb.mysql` driver — they share
  the wire protocol. The `[Databases][[archive_mysql]]` section name +
  `database_type = MySQL` are weewx's stock conventions (already present
  in shipped weewx.conf as commented-out examples).
- weewx-setup's existing pre-install snapshot + uninstall-restore cycle
  covers reverting the overlay when weewx-setup itself is uninstalled.
- The overlay only writes the keys above; everything else in weewx.conf
  (station coords, units, RESTful, skins) is untouched.

**DB-switch revert.** Switching DB types between runs (e.g. mysql ->
sqlite, or mariadb -> mysql with different creds) requires the prior
overlay to be cleared from weewx.conf BEFORE the new state is merged on
top. weewx-setup gets `II_DEPS+=" database"`, so it re-runs whenever the
database child re-runs; its `do_install` must therefore:

1. Restore `weewx.conf` from the original pre-install snapshot (so any
   stale `[DataBindings]/[Databases]/[DatabaseTypes]` from a prior run is
   gone).
2. Re-run `weectl station reconfigure` (unchanged).
3. Re-apply the override-merge from `overrides/weewx.conf` (unchanged).
4. Apply the DB overlay above ONLY if `DATABASE_TYPE` is mysql or mariadb.

The "always restore-from-snapshot-then-rebuild" pattern is the cleanest
way to make every re-run idempotent without tracking deltas. The plan
should verify weewx-setup's current re-run path matches this; if it
doesn't, that's part of the work.

## Conflict handling — `weewx-database-ram` and `weewx-onedrive-backup`

Both are SQLite-specific and don't apply to mysql/mariadb. Both source
`/etc/installicious/state/database.state` at the top of their `do_install`
(and the runtime backup script does the same per-run check):

```bash
[[ -f /etc/installicious/state/database.state ]] && \
  source /etc/installicious/state/database.state
case "${DATABASE_TYPE:-sqlite}" in
  ""|sqlite)
    : # proceed normally
    ;;
  *)
    log_info "Not applicable when DATABASE_TYPE=$DATABASE_TYPE — skipping."
    status_mark_complete "$II_ID" "$II_VERSION"
    exit 0
    ;;
esac
```

- No menu plumbing changes — both features stay visible. If a user picks
  mysql AND keeps `weewx-database-ram` checked, the latter installs and
  immediately self-skips with a clear log line. No `FAIL`, no zombie zram
  device.
- `feature-weewx-onedrive-backup`'s **runtime script** does the same check
  per backup run, not just at install time — so swapping the DB type later
  without re-installing the backup feature still does the right thing.
- The `WEEWX_BACKUP_DB_PATH` key added in the prior commit only makes
  sense for SQLite; the runtime skip handles non-SQLite cleanly, so the
  key stays as-is.

## Role wiring — `roles/role-weewx.sh`

Diff:

```bash
# BEFORE
ROLE_FEATURES_DEFAULT="weewx-setup weewx-webroot weewx-site-ram weewx-database-ram neowx-material locale bash motd skyfield ram-logging"

# AFTER
ROLE_FEATURES_DEFAULT="database weewx-setup weewx-webroot weewx-site-ram weewx-database-ram neowx-material locale bash motd skyfield ram-logging"
```

The role's planning comment is updated to explain that `database` fires
the radio + Edit Configuration keys after the webserver pick, and that
`weewx-database-ram` + `weewx-onedrive-backup` self-skip when a non-SQLite
DB is picked (so they can stay in DEFAULT without footguns).

## Menu flow

Reading from top to bottom of one installicious run with the WeeWx role:

1. Role picker → user picks **WeeWx**.
2. REQUIRED tier → `pkupd` + `webserver`. Webserver radio fires —
   pick nginx/apache/lighttpd/caddy.
3. DEFAULT tier checklist → `database` is on by default plus the other
   weewx defaults.
4. `database` radio fires — pick `sqlite` (default), `mysql`, or `mariadb`.
5. OPTIONAL tier → `rconf`, `compressed-swap`, `weewx-onedrive-backup`.
6. **Edit Configuration** screen shows (for mysql/mariadb picks):
   `DATABASE_HOST`, `DATABASE_NAME`, `DATABASE_USER`, `DATABASE_PASS`,
   `DATABASE_INNODB_TUNE`. For SQLite, all five are hidden.
7. Confirm + install. The picked DB child runs before `weewx-setup`
   (via `II_DEPS+=" database"`).

## Test plan

- `tests/test-manifest.sh` Test 7 roster: add `database`, `database-sqlite`,
  `database-mysql`, `database-mariadb` to the expected sorted ID list.
- `tests/test-role.sh`: update the WeeWx `ROLE_FEATURES_DEFAULT` assertion
  to include `database` at the front.
- `tests/test-menu-config.sh`: extend a case to exercise the new
  `_applies_DATABASE_*` gating — SQLite-picked → all 5 keys hidden;
  MySQL-picked → all 5 visible.
- `tests/test-scheduler.sh`: add a case proving `feature-weewx-setup`'s new
  `II_DEPS+=" database"` orders correctly (database picked-child runs
  before weewx-setup).
- New `tests/test-database.sh` (optional): unit-test the AUTO-resolution
  helpers and the remote-DB hard-error path with synthetic env (no
  actual mysql install).

End-to-end on a Pi (not automated):
1. Fresh Pi, WeeWx role, SQLite default → confirm `database.state` says
   `sqlite` and WeeWX runs as before.
2. Fresh Pi, WeeWx role, pick MariaDB, leave creds AUTO → mariadb-server
   installs, DB+user provisioned, password persisted at
   `/etc/installicious/state/database.creds`, weewx.conf overlay written,
   `sudo systemctl status weewx` running clean.
3. Same Pi, re-run installicious → password is reused (not regenerated),
   provisioning is no-op via `IF NOT EXISTS`, weewx keeps running.
4. Pi with DATABASE_HOST set to a remote IP, AUTO creds → install fails
   with the "remote requires explicit creds" message.
5. WeeWx + MariaDB + `weewx-database-ram` checked → ramdisk install
   self-skips with a clear log line; weewx-onedrive-backup runtime self-skips
   per run.
6. `DATABASE_INNODB_TUNE=on` → drop-in file appears at
   `/etc/mysql/conf.d/installicious-pi.cnf`; `SHOW VARIABLES LIKE
   'innodb_flush_log_at_trx_commit'` returns 2; `innodb_buffer_pool_size`
   matches the Pi tier.

## VERSION

This is a new feature → MINOR bump. After the prior `2.5.0`, this design
implies `2.6.0` on the commit that lands the full feature.

## Open questions for the implementation plan

- **Charset on provisioning.** WeeWX 5 is tolerant of both `utf8mb3`
  (`utf8` in MySQL/MariaDB lingo) and `utf8mb4`. Stock `mariadb-server` on
  Bookworm/Trixie defaults to `utf8mb4`, which WeeWX handles. The plan
  should confirm WeeWX creates its tables without complaint; if it
  doesn't, add `CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci` to the
  CREATE DATABASE statement.
- **`DATABASE_PASS` reuse across changing `DATABASE_USER`.** The
  persisted `database.creds` holds only `DATABASE_PASS`. If the operator
  changes `DATABASE_USER` between runs, the new user is created with the
  reused password; the old user keeps that same password and is left in
  the DB (we don't auto-drop). Documented behavior; the plan should
  surface it in the feature's module-header comment so re-readers
  understand the contract.
- **`lib/pi-tier.sh` extraction vs inline detection.** The InnoDB tuning
  drop-in needs Pi-tier detection that `feature-ram-logging` and
  `feature-compressed-swap` already have. The plan should decide: extract
  to a shared helper (cleanest, slightly more churn) or copy the detection
  inline in mysql/mariadb (least invasive). Defer to plan.
- **MySQL-vs-MariaDB packaging.** Debian Bookworm/Trixie ships
  `mariadb-server` natively; `mysql-server` may need `default-mysql-server`
  or come from Oracle's repo. Plan should verify availability on Bookworm
  + Trixie and document the install path for both. (If `mysql-server` ends
  up needing a non-stock repo, we either add it like `package-weewx.sh`
  does or document that MariaDB is the practical Pi pick.)
- **`installer_apt_record_install` + custom restart logic.** The mysql /
  mariadb server needs `systemctl enable --now` separately from the apt
  install. Plan should check whether the apt postinst already enables +
  starts the service on Debian (it does), and whether re-runs are
  idempotent.
