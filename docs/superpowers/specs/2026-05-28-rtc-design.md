# RTC (Real-Time Clock) Feature — Design

**Date:** 2026-05-28
**Branch:** `ai-refactor`
**Status:** Approved (brainstorming complete; awaiting plan-writing)

**Scope note:** this spec covers two pieces of work that ship together
in a single implementation plan:

1. **`II_REQUIRES_*` manifest primitive** (Phase 0) — declarative
   hardware gating fields (Pi model, RAM, OS bit-width, GUI/Lite,
   internal RTC) consumed by the menu filter and an install-time
   pre-flight check. Small framework addition (~80 LOC + its own
   test file). Independently useful; the RTC feature is the first
   consumer.
2. **RTC feature** (Phases 1–N) — the parent + per-chip children
   described below. Consumes the new gating primitive for the
   Pi-5-builtin entry.

## Goal

Add an optional Real-Time Clock feature to installicious. The user can attach
it to any role (off by default). When toggled on, a radio sub-menu lets the
user pick a supported RTC chip — I²C, SPI, or (on Pi 5 only) the on-board
PCF85063A. The feature configures the appropriate device-tree overlay,
purges `fake-hwclock` (unless overridden), reboots, and on the post-reboot
resume cycle verifies the chip is present + syncs the system time to the RTC.

## Why

A correct hardware clock matters for any Pi that loses network or power.
WeeWX in particular records every observation with a timestamp, so a Pi
that boots to 1970-01-01 produces useless data until NTP catches up. The
project's target audience (Pi hobbyists running a weather station, web
server, Pi-hole, etc.) commonly buys a DS3231 or PCF8523 add-on board;
Pi 5 owners have a usable RTC on the board itself. This feature
standardizes the "drop the module on, run installicious, get a working
clock" path so users don't hand-edit `/boot/firmware/config.txt`.

## Non-goals

- **Multiple simultaneous RTC chips** — exclusive radio; one chip wins.
- **Manual RTC charging-circuit configuration** — chip-specific battery /
  supercap charging knobs (e.g., PCF8523's BLF) are advanced; leave at
  driver defaults. Power-user can override via `overrides/configuration.override`.
- **PPS / GPS-disciplined RTC** — out of scope; this is a plain hwclock
  layer, not a stratum-1 source.
- **Custom kernel modules** — only chips supported by the stock Pi OS
  `i2c-rtc` / `spi-rtc` overlays are exposed.

## File layout

New files:

```
features/feature-rtc.sh              parent (exclusive-group host); body is no-op
features/feature-rtc-ds3231.sh       DS3231 chip-child (curated)
features/feature-rtc-pcf8523.sh      PCF8523 chip-child (curated)
features/feature-rtc-pcf2127.sh      PCF2127 chip-child (curated)
features/feature-rtc-pcf8563.sh      PCF8563 chip-child (curated)
features/feature-rtc-ds1307.sh       DS1307 chip-child (curated)
features/feature-rtc-pi5-builtin.sh  Pi 5 on-board PCF85063A (Pi-5-only)
features/feature-rtc-extended.sh     "More chips..." gateway (extended-set picker)
config/rtc.config                    shared defaults
lib/boot-config.sh                   shared /boot/firmware/config.txt manager
lib/rtc.sh                           shared RTC install/uninstall/verify
tests/test-boot-config.sh            boot-config helper unit tests
tests/test-rtc.sh                    chip→overlay mapping + state-machine tests
```

Edits to existing files:

```
roles/role-webserver.sh         add 'rtc' to ROLE_FEATURES_OPTIONAL
roles/role-weewx.sh             add 'rtc' to ROLE_FEATURES_OPTIONAL
roles/role-homeassistant.sh     add 'rtc' to ROLE_FEATURES_OPTIONAL
roles/role-mediaserver.sh       add 'rtc' to ROLE_FEATURES_OPTIONAL
roles/role-pihole.sh            add 'rtc' to ROLE_FEATURES_OPTIONAL
lib/detect.sh                   add detect_pi_has_internal_rtc helper
lib/manifest.sh                 add II_REQUIRES_* parsing + matcher (Phase 0)
lib/menu.sh                     wire manifest_requires_match into pick_* filters (Phase 0)
overrides/configuration.override.example
                                 document new RTC_* keys
README.md                       add an RTC row to the feature catalog;
                                document II_REQUIRES_* in the manifest reference
docs/HANDOFF.md                 (optional) mention the feature when next
                                 updating handoff
```

Phase 0 also adds:
```
tests/test-manifest-requires.sh  matcher + menu-filter integration tests
```

`roles/role-custom.sh` is intentionally not edited — its required/default/
optional lists are empty by design and the legacy per-installer picker
discovers all features automatically.

## Phase 0: `II_REQUIRES_*` framework primitive

A new manifest contract for declarative hardware gating. Ships before
the RTC feature itself because feature-rtc-pi5-builtin consumes it.
Independently useful; future Pi-5-only / RAM-tier-only / 64-bit-only
features can all use it.

### Manifest fields

All fields are optional. Empty string (or unset) means "no requirement
on this dimension". The matcher returns rc=0 iff every set field's
expression is true on the current hardware.

```bash
II_REQUIRES_PI_MODEL=""        # e.g. ">=5" | "==4" | "<3" | bare "5" (== implied)
II_REQUIRES_RAM_MB=""          # e.g. ">=2048"
II_REQUIRES_OS_BITS=""         # e.g. "==64" or just "64"
II_REQUIRES_LITE=""            # "==true" | "==false" (or just "true"/"false")
II_REQUIRES_PIZERO=""          # "==true" | "==false"
II_REQUIRES_INTERNAL_RTC=""    # "==true" | "==false" (uses detect_pi_has_internal_rtc)
```

**Operators:** `>=`, `<=`, `==`, `!=`, `>`, `<` for numeric dimensions
(PI_MODEL, RAM_MB, OS_BITS); `==`, `!=` for boolean (LITE, PIZERO,
INTERNAL_RTC). A bare value with no operator means `==`.

**PI_MODEL** uses the numeric model returned by `detect_pi_model`
(0/1/2/3/4/5/99) — `>=5` is "Pi 5 or newer"; `<3` excludes Pi 3 and
younger. `RAM_MB` reads `II_MEMORY` from `state/os.status` (already
populated). `OS_BITS` reads `II_OS_BITS`. `LITE` reads `II_IS_LITE`.
`PIZERO` reads `II_IS_PIZERO`.

`INTERNAL_RTC` is the only field that invokes a detection helper
(`detect_pi_has_internal_rtc` from `lib/detect.sh`) at check time
rather than reading a static os.status field. Done this way because
the underlying signal is multi-source (device-tree model + sysfs
device path for forward-compat) and not worth pre-baking into os.status
for what's currently a Pi-5-only fact.

### Matcher helper

New function in `lib/manifest.sh`:

```bash
# manifest_requires_match <file>
#
# Reads II_REQUIRES_* fields from the file's manifest, evaluates each
# against current hardware (from state/os.status + detect_* helpers).
# Returns rc=0 if every set requirement passes; rc=1 if any fail.
#
# On rc=1, logs an INFO line naming the failed dimension + actual value.
# Used by:
#   - lib/menu.sh's pick_* stages: filter out non-matching features.
#   - The framework's pre-do_install gate: belt-and-suspenders fail-fast.
#
# Side-effect-free.
manifest_requires_match() { ... }
```

### Menu-filter integration

`lib/menu.sh`'s `pick_addons`, `pick_optional`, and
`pick_addons_optional_exclusive` stages each call
`manifest_requires_match` per candidate feature before adding it to
the whiptail entry list. Failing features are silently filtered (no
"this would have shown but...") — consistent with existing
`II_RESTRICT_TO_ROLES` filtering behavior.

For optional-group exclusive radios: if filtering drops all children,
the parent is also filtered (no point showing a parent whose radio
would be empty).

### Install-time pre-flight

The scheduler / installer-dispatch layer (in `lib/scheduler.sh`'s
`scheduler_run_queue` or the feature's wrapper) calls
`manifest_requires_match` one more time before invoking the
installer's `do_install`. Rare-case safety net for:
- Selections persisted on a different Pi (SD card moved).
- Manual queue.sh edits.
- A feature being toggled on via override file without going through
  the menu filter.

On failure: `log_warn` + skip (move queue cursor past it). Does not
fail the queue.

### `os.status` extension (one new key)

`installicious.sh` already writes `II_MODEL_NUM`, `II_MEMORY`,
`II_OS_BITS`, `II_IS_LITE`, `II_IS_PIZERO` to `$FILE_STATUS_OS`. We
add one:

```bash
II_HAS_INTERNAL_RTC="true|false"
```

Populated by calling `detect_pi_has_internal_rtc` at status-file
write time. Cached so the matcher doesn't re-shell-out per
candidate-feature during a menu render. The detector helper itself
stays the canonical source for any non-menu code path.

### Testing

`tests/test-manifest-requires.sh` (new, ~150 lines):

1. Operator parsing: bare value, `>=`, `<=`, `==`, `!=`, `>`, `<`,
   plus malformed expressions (rejected via log_warn, fail-closed).
2. Each dimension's check (PI_MODEL, RAM_MB, OS_BITS, LITE, PIZERO,
   INTERNAL_RTC) with stubbed os.status + stubbed detector.
3. Empty / unset = no-requirement (passes).
4. Multi-dimension AND: all set requirements must pass for rc=0.
5. Menu-filter integration (lighter): synthetic manifest with
   II_REQUIRES_PI_MODEL=">=5" and II_MODEL_NUM=3 → filtered out;
   II_MODEL_NUM=5 → included.
6. Install-time pre-flight: scheduler-level test confirming a feature
   whose II_REQUIRES fails gets cursor-advanced past, queue continues.

## Architecture: parent + per-chip children

`feature-rtc.sh` is a no-op parent that exists only as the host of the
exclusive optional-group. Toggling it on in `pick_optional` triggers
`pick_addons_optional_exclusive`, which fires a whiptail radio listing
the children. The child the user picks runs the actual installer.

Rationale for the parent-children pattern over a single feature with an
editable-config key (Approach A in brainstorming):

1. **Per-chip `II_DEPS` flow through the scheduler's dep resolution
   natively.** Single-feature approach would need runtime
   `apt_ensure_installed` calls inside `do_install`.
2. **Per-chip conflicts are declarative.** A future I²C sensor feature
   that uses bus 1 can declare
   `II_CONFLICTS_WITH="rtc-ds3231 rtc-ds1307 rtc-pcf8523 rtc-pcf2127 rtc-pcf8563"`
   and the menu filter does the right thing. Single-feature parent
   would block ALL chips even when only the I²C ones collide.
3. **Per-chip editable knobs.** Pi-5 built-in needs zero knobs; DS3231
   needs `RTC_I2C_BUS`; SPI chips need `RTC_SPI_CS_PIN`. Per-child
   `II_EDITABLE_CONFIG` makes the editor screen show only the relevant
   keys for the selected chip, without per-key `_applies_*` chains
   that introspect a global RTC_CHIP variable.
4. **Per-chip `do_verify` is natural.** DS3231 exposes a temp register;
   PCF8523 has a battery-status bit; Pi-5 built-in has different sysfs
   paths. Each child has space for chip-specific verify logic.

Cost: +6 child `.sh` files of ~30–50 lines each, mostly manifest +
delegation to `lib/rtc.sh`. Total ~400 LOC vs ~250 for Approach A.
Approved by the user 2026-05-28 on the basis that downstream
extensibility outweighs the file-count cost.

### Parent manifest

```bash
# === II_MANIFEST_BEGIN ===
II_ID="rtc"
II_TITLE="Real-Time Clock (RTC)"
II_CATEGORY="feature"
II_VERSION="1"
II_DEFAULT_SELECTED="off"
II_OPTIONAL_GROUP="rtc"
II_OPTIONAL_GROUP_MODE="exclusive"
II_REQUIRES_REBOOT="never"
# === II_MANIFEST_END ===
```

The body returns 0 for `--install`, `--uninstall`, and `--verify` — the
picked child does all the real work.

### Chip-child shape

```bash
# === II_MANIFEST_BEGIN ===
II_ID="rtc-ds3231"
II_TITLE="DS3231 (I2C, temp-compensated, most common)"
II_CATEGORY="feature"
II_VERSION="1"
II_DEPS="i2c-tools"
II_OPTIONAL_GROUP="rtc"
II_DEFAULT_SELECTED="on"            # this curated chip wins by default
II_REQUIRES_REBOOT="always"
II_EDITABLE_CONFIG="RTC_I2C_BUS RTC_PURGE_FAKE_HWCLOCK"
# === II_MANIFEST_END ===

source lib/rtc.sh
RTC_CHIP="ds3231"
RTC_BUS="i2c"
RTC_OVERLAY_NAME="ds3231"

case "${1:-}" in
  --install)   rtc_install   "$RTC_CHIP" "$RTC_BUS" ;;
  --uninstall) rtc_uninstall "$RTC_CHIP" "$RTC_BUS" ;;
  --verify)    rtc_verify    "$RTC_CHIP" ;;
esac
```

Per-chip vars on the other curated children:

| File | RTC_CHIP | RTC_BUS | RTC_OVERLAY_NAME | II_DEPS |
|---|---|---|---|---|
| feature-rtc-ds3231.sh | ds3231 | i2c | ds3231 | i2c-tools |
| feature-rtc-pcf8523.sh | pcf8523 | i2c | pcf8523 | i2c-tools |
| feature-rtc-pcf2127.sh | pcf2127 | i2c | pcf2127 | i2c-tools |
| feature-rtc-pcf8563.sh | pcf8563 | i2c | pcf8563 | i2c-tools |
| feature-rtc-ds1307.sh | ds1307 | i2c | ds1307 | i2c-tools |
| feature-rtc-pi5-builtin.sh* | pcf85063a | pi5-builtin | (none) | (none) |

*`II_TITLE="Pi 5 built-in (PCF85063A)"`; manifest declares
`II_REQUIRES_INTERNAL_RTC="==true"` so the entry is hidden on
non-Pi-5 hardware via Phase-0 menu filtering.

The Pi-5-builtin child declares `II_REQUIRES_INTERNAL_RTC="==true"`
in its manifest. Phase 0's matcher (consumed by `pick_addons_optional_exclusive`)
filters it out of the radio entirely on non-Pi-5 hardware. See
"Pi-5 gating" section.

### Extended-chip escape hatch

`feature-rtc-extended.sh` lives in the curated radio as the last
entry ("More chips..."). When picked, its install body fires a
**second** whiptail radio listing the kernel-supported chips not in
the curated set:

- I²C: PCF85063, ABx80x, RV1805, RV3028, RV3032, MCP7940x, M41T62
- SPI: PCF2123, MAX6902, DS3232 (in SPI mode)

The user's pick is persisted to `state/rtc.state` (alongside the
derived `RTC_BUS_TYPE` and `RTC_OVERLAY_NAME`), and the installer
delegates to `rtc_install` exactly like a curated child.

## Shared helpers

### `lib/boot-config.sh` (new)

First non-`raspi-config` writer of `/boot/firmware/config.txt`.
Designed for reuse by any future overlay-driven feature.

**API:**

```bash
boot_config_path
    # echoes /boot/firmware/config.txt or /boot/config.txt (legacy fallback).

boot_config_backup_once
    # snapshot to /etc/installicious/backup/boot-config/<timestamp>/config.txt;
    # one snapshot per installicious run (subsequent calls are no-ops).

boot_config_dtparam_set <key> <value>
    # idempotent: leaves an existing-and-correct line alone, uncomments a
    # commented one, replaces a wrong-value one.

boot_config_dtparam_unset <key>
    # comments out the line (preserves for rollback). Does not delete.

boot_config_overlay_add <owner> <line>
    # add fenced block:
    #   # === installicious:<owner> begin ===
    #   <line>
    #   # === installicious:<owner> end ===
    # Idempotent: if block exists with same content, no-op. If content
    # differs, rewrite in place between the same fences.

boot_config_overlay_remove <owner>
    # remove the entire fenced block for <owner>. Other owners' blocks
    # are untouched.

boot_config_overlay_has <owner>
    # rc=0 if owner's block is currently present.
```

**Implementation notes:**

- Atomic writes via `mktemp` + `mv` in the same directory (mirrors
  `lib/state.sh`'s `_state_write_pairs`).
- CRLF-tolerant input parsing (per the project's CRLF-tolerance memory
  from the manifest+role-parser change in `c5dc147`).
- All operations require root; helpers `sudo` themselves where needed
  rather than assuming caller already has it.
- Per-owner fences use `# === installicious:<owner> begin ===` /
  `... end ===` markers so multiple installicious features can coexist
  in `config.txt` without stepping on each other (e.g., a future
  `feature-camera` adding `dtoverlay=imx708` doesn't conflict with the
  RTC's block).
- Test hook: `BOOT_CONFIG_PATH_OVERRIDE` env var overrides the path
  auto-detection for tests; production code uses auto-detect.

### `lib/rtc.sh` (new)

**API:**

```bash
rtc_install   <chip> <bus_type> [<bus_extra>]
rtc_uninstall <chip> <bus_type>
rtc_verify    <chip>
```

`<bus_type>` ∈ `i2c | spi | pi5-builtin`. `<bus_extra>` is reserved
for chip-specific extras (currently unused; placeholder for SPI's
bus/CS pin if later chips need explicit override).

**`rtc_install` flow (first cycle, no state file):**

1. Read `RTC_PURGE_FAKE_HWCLOCK`, `RTC_I2C_BUS` etc. from config/menu-config.
2. Pre-install gates (see "Error handling" below).
3. `boot_config_backup_once`.
4. If `bus_type=i2c`: `boot_config_dtparam_set i2c_arm on`.
   If `bus_type=spi`: `boot_config_dtparam_set spi on`.
   If `bus_type=pi5-builtin`: neither (internal bus is permanent).
5. If overlay needed (i2c/spi): `boot_config_overlay_add rtc "dtoverlay=<overlay_family>,<chip>"`.
6. If `RTC_PURGE_FAKE_HWCLOCK=yes`: apt-purge fake-hwclock, record in state.
7. Write `state/rtc.state` with `RTC_PHASE=staged`.
8. `request_reboot "RTC overlay requires reboot to load"`.
9. Exit 255 (`EXIT_REBOOT`).

**`rtc_install` flow (post-reboot, RTC_PHASE=staged):**

1. Probe `/sys/class/rtc/rtc0/name`. If absent → log_fail with actionable
   wiring/pull-up message, exit non-zero. State stays `staged`.
2. Verify chip name matches expected (e.g., `rtc-ds3231` or `rtc-pcf85063`).
3. Wait for `systemd-time-sync.target` AND
   `timedatectl show -p NTPSynchronized` to report `yes`. Polling, up to 60s.
4. If NTP converged: `hwclock --systohc`. Log INFO.
   If NTP did NOT converge in 60s: log_warn (NOT a hard fail), do not
   touch RTC. State stays `staged`; user can re-run later.
5. On successful sync: write `RTC_PHASE=verified` to state.
6. Exit 0.

**`rtc_install` flow (RTC_PHASE=verified, e.g., re-run):**

1. Confirm hardware is still present + healthy.
2. No config.txt writes, no reboot.
3. Exit 0.

**`rtc_uninstall` flow:**

1. Read state file for what was actually done.
2. `hwclock --hctosys` once (preserve real time in system clock before
   removing the RTC source).
3. If fake-hwclock was purged at install: reinstall + enable.
4. If a foreign overlay line was commented out at install: uncomment it.
5. `boot_config_overlay_remove rtc`.
6. By default LEAVE `dtparam=i2c_arm=on` (it enables a bus; removing
   could break other features). Configurable via
   `RTC_UNINSTALL_DISABLE_I2C_BUS="yes"` if the user wants a strict
   revert.
7. Remove `state/rtc.state`.
8. `request_reboot "RTC overlay removed; reboot to apply"`.

**`rtc_verify` flow:**

1. Check `/sys/class/rtc/rtc0` exists.
2. Check chip name in `/sys/class/rtc/rtc0/name` matches expected.
3. Check `hwclock -r` returns 0 and the time looks sane (year ≥ 2026).
4. Cross-check `dtoverlay=<chip>` line is still in `config.txt`'s
   `installicious:rtc` fenced block (catches manual deletion).

## Data flow (end to end)

```
1. options.sh main flow
   ↓
2. pick_optional: user toggles 'rtc' on (parent, off-by-default)
   ↓
3. pick_addons_optional_exclusive: rtc has II_OPTIONAL_GROUP_MODE="exclusive"
   and non-empty children → fire whiptail radio
   ↓
4. Radio renders curated chips first (DS3231 has II_DEFAULT_SELECTED="on"
   so it's preselected globally), then "More chips...". Pi-5-builtin
   entry is filtered out via Phase-0 II_REQUIRES_INTERNAL_RTC on
   non-Pi-5 hardware; visible (and preselected if no other default
   wins) on Pi 5.
   ↓
5a. User picks curated chip → state/selections.sh records
    LAST_ADDONS_PICKED="rtc-<chip>"
   ↓
5b. User picks "More chips..." → state/selections.sh records
    LAST_ADDONS_PICKED="rtc-extended"
   ↓
6. Edit Configuration screen fires for the SELECTED child's
   II_EDITABLE_CONFIG (chip-specific, may be empty for Pi-5-builtin).
   User confirms / adjusts knobs.
   ↓
7. Queue runs.
   ↓
8a. Curated child: rtc_install → write state, apply config.txt changes,
    purge fake-hwclock, request_reboot, exit 255.
   ↓
8b. Extended child: second whiptail radio → persist pick to rtc.state
    → delegate to rtc_install → same as 8a.
   ↓
9. Reboot. Kernel loads new overlay; /dev/rtc0 appears.
   ↓
10. Resume cycle: rtc-<chip> is at the cursor. Installer re-runs, reads
    rtc.state, sees RTC_PHASE=staged, takes post-reboot path: verify
    hardware, wait for NTP, hwclock --systohc, advance phase to
    'verified', exit 0.
   ↓
11. Queue continues with the next item.
```

## `state/rtc.state` shape

Shell-sourceable file, written by `_state_write_pairs`-style atomic
rewrite (consistent with `state/queue.sh`).

```bash
RTC_CHIP="ds3231"
RTC_BUS_TYPE="i2c"               # i2c | spi | pi5-builtin
RTC_OVERLAY_NAME="ds3231"        # empty for pi5-builtin
RTC_I2C_BUS="1"                  # default; only meaningful when bus=i2c
RTC_SPI_CS_PIN=""                # only meaningful when bus=spi
RTC_PHASE="staged"               # staged | verified
RTC_PURGED_FAKE_HWCLOCK="yes"    # for clean --uninstall
RTC_COMMENTED_FOREIGN_OVERLAY="" # path-line tag if we commented one out
```

## Pi-5 gating

Uses the Phase-0 `II_REQUIRES_INTERNAL_RTC` field. The Pi-5-builtin
child's manifest:

```bash
II_REQUIRES_INTERNAL_RTC="==true"
```

On a Pi 5 (or any forward-compat Pi whose device-tree exposes an
internal RTC), `manifest_requires_match` returns rc=0, the menu
shows the entry, and install proceeds normally. On a Pi 3/4/Zero/etc.,
the entry is **filtered out entirely** — never appears in the radio.

Belt-and-suspenders: if somehow the feature still gets queued (SD card
moved between Pis, manual queue.sh edit), the scheduler's pre-flight
check re-runs `manifest_requires_match`, sees the mismatch, log_warns,
and advances the cursor past it without invoking the installer.

Add to `lib/detect.sh`:

```bash
# rc=0 iff this Pi has the on-board PCF85063A RTC. Pi 5 today;
# forward-compat for any Pi whose device-tree exposes an internal RTC.
detect_pi_has_internal_rtc() {
  [[ -r /proc/device-tree/model ]] || return 1
  local model
  model=$(tr -d '\0' < /proc/device-tree/model 2>/dev/null)
  case "$model" in
    *"Pi 5"*) return 0 ;;
  esac
  # Forward-compat: any RTC at the Pi 5's internal device-tree path counts.
  [[ -e /sys/bus/i2c/devices/1f00071000.rtc ]] && return 0
  return 1
}
```

This helper is invoked at `installicious.sh` startup to populate
`II_HAS_INTERNAL_RTC` in `state/os.status` so the matcher doesn't
re-shell-out per candidate-feature during menu render.

### Title note

The Pi-5-builtin entry's title is just `"Pi 5 built-in (PCF85063A)"`
— no "Pi 5 only" disambiguator needed, since the entry only appears
on Pi 5s. Cleaner UX.

## Editable config keys

Defaults in `config/rtc.config`:

```bash
# Chosen RTC chip. Auto-set by the radio pick; user can override here
# (Power-user override for unsupported chips: set to any kernel-supported
# i2c-rtc / spi-rtc overlay suffix).
RTC_CHIP="${RTC_CHIP:-ds3231}"

# Bus type derived from chip. Set by the installer; surfaced here so the
# editor screen shows it as read-only context.
RTC_BUS_TYPE="${RTC_BUS_TYPE:-i2c}"

# I²C bus number. Pi 3/4/Zero use 1; Pi 5 has additional buses available.
RTC_I2C_BUS="${RTC_I2C_BUS:-1}"

# SPI CS pin. Only meaningful for SPI chips.
RTC_SPI_CS_PIN="${RTC_SPI_CS_PIN:-0}"

# Purge fake-hwclock at install? Strongly recommended (fake-hwclock can
# show stale shutdown-time while RTC has the real time).
RTC_PURGE_FAKE_HWCLOCK="${RTC_PURGE_FAKE_HWCLOCK:-yes}"

# Disable dtparam=i2c_arm=on at uninstall? Default no — bus is shared.
RTC_UNINSTALL_DISABLE_I2C_BUS="${RTC_UNINSTALL_DISABLE_I2C_BUS:-no}"
```

`overrides/configuration.override.example` documents the same keys with
inline commentary so a user dropping an override file pre-install gets
the same picture.

## Error handling

### Pre-install gates

1. `/boot/firmware/config.txt` exists & is writable. Missing →
   `log_fail`, exit 1.
2. The chosen overlay's `.dtbo` is present in `/boot/firmware/overlays/`.
   Missing → fail with "kernel doesn't ship the overlay for `<chip>`;
   check `dpkg -l raspberrypi-kernel`".
3. No conflicting RTC already configured by hand. Scan `config.txt`
   for any pre-existing `dtoverlay=i2c-rtc,` / `dtoverlay=spi-rtc,`
   outside our fenced block. If found → whiptail msgbox:
   "Existing RTC overlay detected at line N: `<line>`. Continue and
   let installicious own RTC management? [Yes/No]". Yes → comment out
   the foreign line (record in state for `--uninstall` restore);
   No → exit 1.
4. Best-effort I²C probe via `i2cdetect -y <bus>`. Pre-reboot the
   overlay isn't loaded, so this is informational only — log INFO if
   chip address responds, WARN if not. Never fatal pre-reboot.

### Idempotence

- `lib/boot-config.sh` is the single insertion point. All operations
  are idempotent by design.
- `rtc.state`'s `RTC_PHASE` is the resume-cycle marker. Cases:
  - No state file: first install, write `staged`, apply config, reboot.
  - `RTC_PHASE=staged`: post-reboot — verify hardware, sync time,
    advance to `verified`.
  - `RTC_PHASE=verified`: re-run on a good system — confirm hardware,
    no writes, exit 0.
- `status_should_skip` (framework's standard skip helper) is checked
  AFTER the state-file read, so an unchanged-config skip still hits
  the post-reboot path on first re-run.

### Resume/reboot edge cases

- **Reboot lost between phases.** User manually reboots before
  `RTC_PHASE=staged` is written. Harmless — config.txt has the
  change; next installicious run sees no state file and re-applies
  (idempotent).
- **Hardware mismatch post-reboot** (chosen chip not detected). State
  stays at `staged`. `log_fail` with actionable message:
  `"DS3231 expected at I²C bus 1 addr 0x68 but i2cdetect shows no
  device — check wiring/pull-ups and re-run installicious --verify rtc-ds3231"`.
  User fixes wiring, re-runs; no undo needed.
- **NTP never converges in 60s.** Skip `hwclock --systohc` to avoid
  writing garbage. `log_warn`. State stays at `staged`. Re-run later
  (or just `sudo hwclock --systohc` manually).
- **Power cycle mid-queue.** `rtc.state` survives. `queue.sh` resumes
  from cursor; rtc-`<chip>` re-fires, sees `RTC_PHASE=staged`, takes
  post-reboot path.

### `--uninstall` reverse order

1. Read `state/rtc.state`.
2. `hwclock --hctosys` (preserve real time in system clock).
3. Reinstall + enable fake-hwclock (if purged at install).
4. Uncomment the foreign overlay line (if commented at install).
5. `boot_config_overlay_remove rtc`.
6. Leave `dtparam=i2c_arm=on` by default (bus is shared). Strict
   revert requires `RTC_UNINSTALL_DISABLE_I2C_BUS=yes`.
7. Remove `state/rtc.state`.
8. `request_reboot "RTC overlay removed; reboot to apply"`.

`--uninstall --restore-backup` is the explicit alias; same behavior
since the uninstall is fundamentally a backup-restore.

## Testing strategy

### `tests/test-boot-config.sh` (new)

Tempdir-isolated. `BOOT_CONFIG_PATH_OVERRIDE` points the helper at a
synthetic file. Cases (13 total):

1. Cold start: empty config → `boot_config_dtparam_set i2c_arm on`
   produces one line.
2. Idempotent set: run twice, byte-for-byte identical.
3. Uncomment: pre-seeded `#dtparam=i2c_arm=on` becomes uncommented.
4. Replace differing value: `off` → `on`.
5. Fenced-block add inserts marker pair + content at end of file.
6. Fenced-block idempotent: same content twice = no change.
7. Fenced-block content change: rewrites in place, fences stay.
8. Fenced-block remove: marker pair + content gone, rest intact.
9. Multiple owners coexist: add `rtc`, add `sensor`, remove `rtc`,
   `sensor` block still present.
10. CRLF tolerance: pre-seeded CRLF file, operations work, output LF.
11. Concurrent-write safety: simulated interrupt mid-write leaves
    file consistent (old OR new, never half).
12. Legacy `/boot/config.txt` fallback when `/boot/firmware/` absent.
13. `boot_config_backup_once` produces one snapshot per run.

### `tests/test-rtc.sh` (new)

Tempdir-isolated. Stubs `/sys/class/rtc/`, `hwclock`, `timedatectl`,
`apt-get`, `dpkg`, `i2cdetect` via `$TEST_TMPDIR/bin` prepended to
`PATH`. Cases (12 total):

1. Chip→overlay mapping: each curated chip + each extended chip
   yields the expected `dtoverlay=` line.
2. Pi-5-builtin path: writes NO overlay line; fake-hwclock purge
   still runs (if configured).
3. First install (no state file): state advances to `staged`,
   config.txt fenced block written, `request_reboot` invoked
   (verify via stub).
4. Post-reboot resume + stubbed `/sys/class/rtc/rtc0` + NTP synced:
   `hwclock --systohc` invoked once, state advances to `verified`.
5. Post-reboot resume + NTP NOT synced for 60s: skip
   `hwclock --systohc`, state stays `staged`, log_warn emitted.
6. Hardware mismatch post-reboot (stubbed chip name disagrees):
   state stays `staged`, log_fail, exit non-zero.
7. Re-run on `RTC_PHASE=verified`: no config.txt writes, no reboot.
8. `RTC_PURGE_FAKE_HWCLOCK=no`: stub apt-get call log is empty for
   purge.
9. Uninstall full reverse: hwclock --hctosys, fake-hwclock
   reinstalled+enabled, overlay block removed, state file deleted.
10. Uninstall partial reverse (fake-hwclock NOT purged, foreign
    overlay was commented): skip fake-hwclock reinstall, restore
    the foreign line.
11. Idempotent rerun: two back-to-back `rtc_install` calls produce
    identical state file + config.txt.
12. Extended-chip flow: stub the second whiptail radio → record
    pick to `rtc.state` → delegate to `rtc_install` with picked
    chip.

### Existing test impact

- `tests/test-manifest.sh` — picks up new feature files automatically
  via dir scan. Phase 0 adds II_REQUIRES_* fields; the existing
  manifest-parser tests should still pass since the parser is generic
  (treats unknown II_* fields as regular fields). Add one positive
  case asserting the new fields are extractable.
- `tests/test-menu-applicability.sh` — already exists; gets new cases
  for II_REQUIRES_* filtering of pick_* candidates.
- `tests/test-scheduler.sh` — Phase 0's install-time pre-flight
  affects scheduler_run_queue. Add a case: a feature with
  II_REQUIRES failing → cursor advanced past it, queue continues,
  no installer invocation.
- `tests/test-role.sh` — already verifies each role parses; new
  `rtc` entries in `ROLE_FEATURES_OPTIONAL` should land in the
  existing assertions.
- `tests/test-verify.sh` — `--verify rtc-<chip>` routes through the
  manifest-driven verify dispatcher; per-chip `do_verify` hits the
  existing test patterns.
- `tests/test-roundtrip.sh` — end-to-end queue round-trip will
  exercise the menu radio for the rtc parent. Needs an env-var
  bypass for the actual `dtoverlay` write (no `/boot/firmware/` on
  the Windows test host): `RTC_SKIP_BOOT_CONFIG_WRITE=true`,
  mirroring `feature-compressed-swap`'s `ZRAM_SKIP_LIVE_VERIFY`.

Expected wall-clock impact on the parallel runner: +30-40s (Phase 0
test ~10s; RTC tests ~20-30s).

## VERSION bump policy

Per `installicious-version-bump` memory note: PATCH bump per commit.
Phase commits PATCH-bump; the final landing-the-feature commit
MINOR-bumps (e.g., 2.8.x → 2.9.0).

## README / overrides-example updates

Per `feedback-readme-maintenance` memory note: when the RTC feature
lands, README.md gets a new row in the feature catalog (table around
README line 100–125) covering the parent + the radio behavior. Per
`feedback-configuration-example-maintenance`, the six new
`RTC_*` keys land in `overrides/configuration.override.example`
with the same docstring as in `config/rtc.config`.

## Open follow-ups (deferred, not blocking)

- **DS3231 temperature exposure.** DS3231 has an on-die temperature
  sensor accessible via `/sys/bus/i2c/devices/1-0068/temp_input`.
  Surface as an optional companion (`feature-rtc-ds3231-temp`?). Out
  of scope for v1.
- **PPS / chrony integration.** A few RTCs (PCF2127, RV3032) have
  PPS outputs that can discipline NTP. Specialized; defer.
- **rtc-set-after-ntp systemd unit.** Right now we sync once on the
  post-reboot resume. Could install a systemd unit that runs
  `hwclock --systohc` after every `time-sync.target` so the RTC
  tracks the freshest NTP value. Useful but increases SD/RTC writes;
  defer pending user request.
