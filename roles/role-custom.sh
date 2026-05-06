#!/bin/bash

# Custom role — escape hatch for "I want to pick features individually,
# not run a predefined Pi role". When the menu sees ROLE_ID="custom" it
# falls through to the legacy per-installer picker (option + software
# whiptail menus) instead of the required/optional flow.
#
# This file deliberately has no required or optional features; the picker
# decides everything.

# === II_ROLE_BEGIN ===
ROLE_ID="custom"
ROLE_TITLE="Custom — pick features individually"
ROLE_DESCRIPTION="Bypass the role list and pick from all available features (option + software categories)."
ROLE_FEATURES_REQUIRED=""
ROLE_FEATURES_OPTIONAL=""
ROLE_CONFIG=""
ROLE_EDITABLE_CONFIG=""
# === II_ROLE_END ===
