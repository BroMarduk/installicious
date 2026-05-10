#!/bin/bash

# Pi-Hole role — network-wide DNS sinkhole / ad blocker.
#
# Stub: behaves like Custom for now (empty required/optional). Will be
# fleshed out as the features tier lands; expected to require a feature
# that runs the upstream pihole installer and offer an optional unbound
# recursive resolver add-on.

# === II_ROLE_BEGIN ===
ROLE_ID="pihole"
ROLE_TITLE="Pi-Hole - DNS sinkhole / ad blocker"
ROLE_DESCRIPTION="Network-wide DNS-level ad blocking. (Stub - currently behaves like Custom.)"
ROLE_FEATURES_REQUIRED=""
ROLE_FEATURES_DEFAULT=""
ROLE_FEATURES_OPTIONAL=""
ROLE_CONFIG=""
ROLE_EDITABLE_CONFIG=""
# === II_ROLE_END ===
