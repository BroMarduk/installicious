#!/usr/bin/env python3
# resources/weewx-merge-overrides.py
#
# Deep-merge a partial weewx.conf (the user's overrides/weewx.conf) onto the
# live /etc/weewx/weewx.conf. Invoked by feature-weewx-setup AFTER the apt
# install + `weectl station reconfigure` pass, so the override file gets the
# final word on anything it mentions.
#
# Usage:
#   weewx-merge-overrides.py <base-weewx.conf> <override-file>
#
# Both files are ConfigObj/INI format (weewx's native config format).
# ConfigObj.merge() recurses through nested sections ([[...]], [[[...]]]),
# so the override file only needs to list the keys it wants to change —
# everything else is left exactly as the base had it.
#
# Exit codes:
#   0  merged + written (or override file was empty/all-comments — no-op)
#   1  bad arguments
#   2  base file missing or unreadable
#   3  configobj not importable (should never happen — it's a weewx dep)
#   4  parse/merge/write error

import sys


def main() -> int:
    if len(sys.argv) != 3:
        sys.stderr.write(
            "usage: weewx-merge-overrides.py <base-weewx.conf> <override-file>\n"
        )
        return 1

    base_path, override_path = sys.argv[1], sys.argv[2]

    try:
        from configobj import ConfigObj
    except ImportError:
        sys.stderr.write(
            "weewx-merge-overrides: python3 'configobj' module not found "
            "(it ships as a weewx dependency — is weewx installed?)\n"
        )
        return 3

    import os

    if not os.path.isfile(base_path):
        sys.stderr.write(f"weewx-merge-overrides: base file not found: {base_path}\n")
        return 2

    # An absent override file is a legitimate no-op (feature-weewx-setup
    # also guards this, but be defensive).
    if not os.path.isfile(override_path):
        sys.stdout.write(
            f"weewx-merge-overrides: no override file at {override_path}; nothing to merge.\n"
        )
        return 0

    try:
        overrides = ConfigObj(override_path, file_error=True, encoding="utf-8")
    except Exception as exc:  # noqa: BLE001 — surface any parse error verbatim
        sys.stderr.write(f"weewx-merge-overrides: cannot parse {override_path}: {exc}\n")
        return 4

    # An override file that's all comments parses to an empty ConfigObj —
    # treat that as a no-op so we don't rewrite weewx.conf for nothing
    # (rewriting would also strip weewx.conf's own inline comments, so
    # skipping when there's nothing to do is the safe path).
    if not overrides:
        sys.stdout.write(
            f"weewx-merge-overrides: {override_path} has no keys; nothing to merge.\n"
        )
        return 0

    try:
        base = ConfigObj(base_path, file_error=True, encoding="utf-8")
        base.merge(overrides)
        base.write()
    except Exception as exc:  # noqa: BLE001
        sys.stderr.write(
            f"weewx-merge-overrides: merge/write failed on {base_path}: {exc}\n"
        )
        return 4

    # Report what top-level sections/keys the override touched — handy in
    # the install log for after-the-fact "what did this change?" checks.
    touched = ", ".join(sorted(overrides.keys()))
    sys.stdout.write(
        f"weewx-merge-overrides: merged {override_path} into {base_path} "
        f"(top-level sections touched: {touched})\n"
    )
    return 0


if __name__ == "__main__":
    sys.exit(main())
