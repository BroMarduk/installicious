#!/bin/bash

# Custom task — escape hatch for "I want to pick installers individually,
# not run a predefined Pi role". When the menu sees TASK_ID="custom" it
# falls through to the legacy per-installer picker (option + software
# whiptail menus) instead of the required/optional flow.
#
# This file deliberately has no required or optional installers; the picker
# decides everything.

# === II_TASK_BEGIN ===
TASK_ID="custom"
TASK_TITLE="Custom — pick installers individually"
TASK_DESCRIPTION="Bypass the task list and pick from all available installers (option + software categories)."
TASK_INSTALLERS_REQUIRED=""
TASK_INSTALLERS_OPTIONAL=""
TASK_CONFIG=""
TASK_EDITABLE_CONFIG=""
# === II_TASK_END ===
