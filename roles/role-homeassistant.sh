#!/bin/bash

# Home Assistant role — open-source home automation hub.
#
# Stub: behaves like Custom for now (empty required/optional). Will be
# fleshed out as the features tier lands; expected to require a feature
# that installs Home Assistant Supervised / Container along with the
# usual baseline (pkupd, rconf, bash) and offer optional add-ons like
# Mosquitto, Z-Wave / Zigbee adapters, etc.
#
# Hardware note (future): Home Assistant is happiest with ≥2 GB RAM and
# real storage. The role-level pre-flight check should warn on Pi Zero
# and original Pi 1/2/3, but for now no hardware gating is enforced.

# === II_ROLE_BEGIN ===
ROLE_ID="homeassistant"
ROLE_TITLE="Home Assistant"
ROLE_DESCRIPTION="Open-source home automation. (Stub.)"
ROLE_FEATURES_REQUIRED=""
ROLE_FEATURES_DEFAULT=""
ROLE_FEATURES_OPTIONAL=""
ROLE_CONFIG=""
ROLE_EDITABLE_CONFIG=""
# === II_ROLE_END ===
