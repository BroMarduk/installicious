#!/bin/bash

# Headless Pi task — minimal example to validate the task framework.
# Configures a console-login Pi with system updates, raspi-config defaults,
# and bash customizations. No optional add-ons.
#
# Useful as a sanity-check for new tasks: drop in a manifest, the menu
# auto-discovers it.

# === II_TASK_BEGIN ===
TASK_ID="headless"
TASK_TITLE="Headless Pi (minimal)"
TASK_DESCRIPTION="Console-login Pi: system updates + raspi-config + bash customizations. No software."
TASK_INSTALLERS_REQUIRED="pkupd rconf bash"
TASK_INSTALLERS_OPTIONAL=""
TASK_CONFIG=""
TASK_EDITABLE_CONFIG=""
# === II_TASK_END ===
