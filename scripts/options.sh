#!/bin/bash

# scripts/options.sh - Main menu + scheduler entry point.
#
# Driven by a small stage state machine so the user can press BACK at any
# screen to return to the previous one. ESC behaves like BACK on every
# screen EXCEPT the splash (in installicious.sh) and the role picker
# below — at those two, ESC exits the installer.
#
# Custom-flow order (when the user picks the Custom role, or any role
# that doesn't yet declare REQUIRED/DEFAULT/OPTIONAL features):
#
#   pick_role  →  custom_features  →  merge_features  →  pick_addons*
#                                                       →  pick_packages*
#                                                       →  merge_packages
#                                                       →  edit_config*
#                                                       →  confirm  →  run
#
# Role-flow order (role declares REQUIRED / DEFAULT / OPTIONAL features):
#
#   pick_role  →  show_required*       →  pick_addons_required*
#              →  pick_role_specific*  →  pick_optional*
#                                      →  merge_role
#                                      →  pick_addons*
#                                      →  pick_packages*
#                                      →  merge_packages
#                                      →  edit_config*
#                                      →  confirm  →  run
#
#   Step ordering (role flow, mapped to Daisy's 7-step ask):
#     1. pick_role
#     2. show_required (info)
#     3. pick_addons_required (MANDATORY single-pick radios only —
#        e.g. webserver's apache/nginx/lighttpd/caddy chooser).
#     4a. pick_role_specific — items in the role's DEFAULT+OPTIONAL
#         tiers that declare II_RESTRICT_TO_ROLES naming this role
#         (e.g. weewx-webroot, weewx-site-ram, weewx-database-ram,
#         skyfield on the WeeWx role). Conflict-filtered.
#     4b. pick_optional — items in the role's DEFAULT+OPTIONAL tiers
#         that aren't role-specific (the cross-role / generic items:
#         locale, bash, motd, ram-logging, rconf, compressed-swap on
#         the WeeWx role). Conflict-filtered against everything from
#         steps 1-4a so a step-4a pick can naturally exclude a
#         step-4b row.
#     5. pick_addons — ALL in-queue parents' non-exclusive sub-features,
#        conflict-filtered (e.g. nginx's webserver-under-construction /
#        webserver-ssl get filtered when weewx-site-ram was picked at
#        step 4a).
#     6. pick_packages — packages picker: required (auto-installed via
#        II_DEPS) listed in header; remaining packages selectable, with
#        II_RESTRICT_TO_ROLES + II_CONFLICTS_WITH excluded.
#     6.5. edit_config — last-step-before-summary editor for
#          II_EDITABLE_CONFIG / ROLE_EDITABLE_CONFIG values.
#     7. confirm (summary).
#
# Stage glossary:
#   pick_role             single-select role picker (first stage)
#   custom_features       Custom: pick from features/ (II_CATEGORY="feature")
#   merge_features        internal: stage selected = features + (later) addons
#   show_required         Role: confirm the required features (info)
#   pick_addons_required  Role: sub-menu(s) for REQUIRED parents with an
#                         EXCLUSIVE II_OPTIONAL_GROUP (mandatory radio —
#                         e.g. webserver's backend chooser). Non-exclusive
#                         optional groups on required parents defer to
#                         pick_addons so the conflict filter has
#                         visibility into the step-4 picks.
#   pick_role_specific    Role: pick optional add-ons from the tier list
#                         that declare II_RESTRICT_TO_ROLES naming this
#                         role. Conflict-filtered. Auto-skipped when no
#                         role-specific items exist.
#   pick_optional         Role: pick the remaining (generic) optional
#                         add-ons — tier items WITHOUT a role restriction.
#                         Conflict-filtered against role_required +
#                         step-3 picks + step-4a picks.
#   merge_role            internal: stage selected = required + role-specific + generic
#   pick_addons           sub-menu(s) for ALL in-queue parents with a
#                         non-exclusive II_OPTIONAL_GROUP, conflict-filtered
#   pick_packages         pick from packages/ (II_CATEGORY="package");
#                         required-by-features auto-listed and excluded,
#                         conflict + role restriction also applied
#   merge_packages        internal: append picked packages, exit if nothing at all
#   edit_config           surface II_EDITABLE_CONFIG / ROLE_EDITABLE_CONFIG values
#   confirm               final yes/no
#   run                   scheduler hand-off (terminal stage)
#
# Invoked from installicious.sh after hardware/OS detection and the initial
# whiptail confirmation.

II_TITLE="Installicious Menu"
EXIT_REBOOT=255

source config/installicious.config || exit 1
source lib/log.sh
source lib/status.sh
source lib/state.sh
source lib/reboot.sh
source lib/manifest.sh
source lib/role.sh
source lib/menu.sh
source lib/scheduler.sh
source lib/post_install.sh

# Pre-warm the manifest registry in THIS shell. Every `$(manifest_get_field
# ...)` in the menu flow runs in a subshell that inherits — but cannot
# write back to — our cache arrays. Without a parent-process warm-up,
# each subshell's cache starts empty, re-scans every feature/package file
# from disk, populates the cache *inside the subshell*, and dies — so the
# next call repeats the full scan. On a Pi that meant ~30s between
# menu screens with ~100 subshell calls per render. Loading once here
# populates _MANIFEST_BLOCK / _MANIFEST_PATH in the parent so every
# downstream subshell starts warm. Disk IO drops to zero after this line.
_manifest_registry_load

if [[ -z $FILE_LOG_INSTALLICIOUS ]]; then
  FILE_LOG_INSTALLER="$PATH_LOGS/installicious.log"
else
  FILE_LOG_INSTALLER="$PATH_LOGS/$FILE_LOG_INSTALLICIOUS"
fi
log_init "$II_TITLE" "$FILE_LOG_INSTALLER"

# One-line record of which user config-override layers are in play, so a
# run's log shows whether overrides/configuration.override was picked up.
state_log_override_status

# Pull the OS / Pi-model detection results into scope so per-installer
# choices files (sourced by menu_edit_config) can gate their offerings on
# II_MODEL_NUM, II_CODENAME, II_IS_LITE, etc.
[[ -f "$PATH_STATUS/os.status" ]] && source "$PATH_STATUS/os.status"

# Fresh run: clear any stale post-install actions left over from a prior
# interrupted session. (Actions from a queue that included a reboot are still
# preserved across the reboot itself; this only fires on a brand-new run.)
post_install_clear

# Note: $PATH_STATE/menu-config.sh is intentionally NOT cleared here.
# It persists across runs so user edits (e.g. AccuWeather API key) survive
# without re-typing on every install. To force a reset, the user can:
#   sudo rm $PATH_STATE/menu-config.sh

CURRENTUSER=$(whoami)

# Last-run picker memory. Sources $PATH_STATE/selections.sh and populates
# LAST_* (role, features, role-specific picks, optional picks, packages,
# serialized addons map). Missing file = first run = all LAST_* unset.
# We seed each picker from the matching LAST_* when present, falling back
# to manifest defaults otherwise; and we rewrite the file on every picker
# advance so a Cancel-mid-flow still leaves the prior forward path in place.
state_load_selections || true

# State carried across stages.
role_id="${LAST_ROLE_ID:-}"
role_path=""
role_title=""
role_required=""
role_default=""
role_optional=""
# Split of the role's DEFAULT+OPTIONAL tiers into "role-specific" vs
# "generic", computed once when pick_role completes. Role-specific
# items are those with II_RESTRICT_TO_ROLES naming the current role
# (e.g. weewx-webroot, weewx-site-ram, weewx-database-ram, skyfield —
# all restricted to "weewx"). Generic items have no restriction. The
# two lists feed two separate pickers: pick_role_specific (step 4a)
# and pick_optional (step 4b, generic only).
role_specific_features=""
role_generic_features=""
features_selected="${LAST_FEATURES_SELECTED:-}"
packages_selected="${LAST_PACKAGES_SELECTED:-}"
role_specific_picked=""
optional_picked=""
# Per-stage "have I shown this screen yet?" flags. First visit seeds
# the picker from the LAST_* memory (or manifest tier defaults if no
# memory was loaded); later visits preserve whatever the user actually
# picked during this run.
role_specific_visited=0
optional_visited=0
selected=""           # final list (parents + their picked add-ons)
selected_parents=""   # the user's category/role picks BEFORE add-ons get merged
declare -A addons_picked   # parent_id → space-separated add-on IDs the user picked

# Seed addons_picked from the last-run serialization (parent:children-csv
# entries joined by `;`). On role-switch the whole map is cleared below.
_deserialize_addons_picked() {
  local serialized="$1" entry parent children
  local -a _entries
  IFS=';' read -ra _entries <<< "$serialized"
  for entry in "${_entries[@]}"; do
    [[ -z $entry ]] && continue
    parent="${entry%%:*}"
    children="${entry#*:}"
    children="${children//,/ }"
    addons_picked[$parent]="$children"
  done
}
_serialize_addons_picked() {
  local out="" parent
  for parent in "${!addons_picked[@]}"; do
    [[ -z ${addons_picked[$parent]:-} ]] && continue
    [[ -n $out ]] && out+=";"
    out+="${parent}:${addons_picked[$parent]// /,}"
  done
  echo "$out"
}
[[ -n ${LAST_ADDONS_PICKED:-} ]] && _deserialize_addons_picked "$LAST_ADDONS_PICKED"

# _persist_selections — single-call helper that snapshots the current
# in-memory picker state to $PATH_STATE/selections.sh. Called at the end
# of every forward-advancing stage so the on-disk file always reflects
# the last successful screen the user passed through.
_persist_selections() {
  state_save_selections \
    "$role_id" \
    "${features_selected//\"/}" \
    "${role_specific_picked//\"/}" \
    "${optional_picked//\"/}" \
    "${packages_selected//\"/}" \
    "$(_serialize_addons_picked)"
}

# Tracks the stage we just left, so stages that auto-advance on rc=2 (e.g.
# edit_config when no keys are editable) can detect a back-from-confirm
# bounce and rewind further instead of trapping the user on confirm.
prev_stage=""

# ---------------------------------------------------------------------------
# Stage state machine
# ---------------------------------------------------------------------------
# Helpers: figure out which stage precedes edit_config / confirm so BACK
# from the editor or confirm rewinds to the right place. Required parents
# fire their sub-menu in pick_addons_required (between show_required and
# pick_optional); non-required parents fire theirs in the regular
# pick_addons stage (between merge_role and edit_config). Each helper
# answers "does THAT stage have anything to render right now?".

_id_in_required() {
  local needle="$1" id
  for id in $role_required; do
    [[ "$id" == "$needle" ]] && return 0
  done
  return 1
}

_any_required_parent_has_addons() {
  local id ppath addons
  for id in $role_required; do
    ppath=$(manifest_path_for "$id" 2>/dev/null)
    [[ -z $ppath ]] && continue
    addons=$(manifest_get_field "$ppath" "II_OPTIONAL_GROUP")
    [[ -n $addons ]] && return 0
  done
  return 1
}

# rc=0 if any required parent declares an EXCLUSIVE II_OPTIONAL_GROUP
# (radio-list). Used by the radio-only sub-menu stage (step 3) and the
# BACK chain from pick_optional to know whether the radio screen exists.
# A non-exclusive (checklist) group on a required parent doesn't count
# here — those defer to pick_addons (step 5) so the conflict filter has
# visibility into the user's role-tier selections from step 4.
_any_required_parent_has_radios() {
  local id ppath addons mode
  for id in $role_required; do
    ppath=$(manifest_path_for "$id" 2>/dev/null)
    [[ -z $ppath ]] && continue
    addons=$(manifest_get_field "$ppath" "II_OPTIONAL_GROUP")
    [[ -z $addons ]] && continue
    mode=$(manifest_get_field "$ppath" "II_OPTIONAL_GROUP_MODE")
    [[ $mode == "exclusive" ]] && return 0
  done
  return 1
}

# Returns the unique package IDs that any selected feature (or its
# add-on) declares as a dependency (II_DEPS). The scheduler pulls these
# in via scheduler_resolve_deps regardless, but we surface them on the
# pick_packages screen so the user knows they'll be installed AND
# can't accidentally try to deselect them (we filter them out of the
# toggleable checklist via menu_select_category's exclude param).
#
# Reads from $selected (which by the time pick_packages runs contains
# features + their picked addons) so addon deps are accounted for too.
_required_packages_from_features() {
  local id deps dep fpath ppath cat
  declare -A seen=()
  for id in $selected; do
    [[ -z $id ]] && continue
    fpath=$(manifest_path_for "$id" 2>/dev/null)
    [[ -z $fpath ]] && continue
    deps=$(manifest_get_field "$fpath" "II_DEPS")
    for dep in $deps; do
      [[ -z $dep ]] && continue
      [[ -n ${seen[$dep]:-} ]] && continue
      ppath=$(manifest_path_for "$dep" 2>/dev/null)
      [[ -z $ppath ]] && continue
      cat=$(manifest_get_field "$ppath" "II_CATEGORY")
      if [[ $cat == "package" ]]; then
        seen[$dep]=1
        echo "$dep"
      fi
    done
  done
}
# True for the Custom role and any role that declares no required / optional
# features (the stubbed roles today: homeassistant, mediaserver, pihole).
# Both flow through the per-feature checklist (custom_features → pick_addons
# → pick_packages → edit_config → confirm) instead of
# show_required / pick_role_specific / pick_optional.
_role_uses_custom_flow() {
  [[ $role_id == "custom" ]] && return 0
  [[ -z $role_required && -z $role_default && -z $role_optional ]] && return 0
  return 1
}

# Splits the role's DEFAULT + OPTIONAL tiers into "role-specific"
# (II_RESTRICT_TO_ROLES contains $role_id) and "generic" (no restriction
# on this role). The split is what powers the new step-4a / step-4b
# distinction — role-specific items get their own picker first so the
# user thinks about the decisions only meaningful under THIS role,
# then a separate generic picker surfaces the cross-role choices.
#
# A feature whose II_RESTRICT_TO_ROLES is set BUT doesn't include the
# current role is a role-author error (the feature is on a tier list
# for a role that's not allowed to install it). We drop it from both
# lists here — the queue would refuse to install it anyway via
# manifest_is_visible_for_role at the install body level.
_compute_role_specific_features() {
  local out="" id ppath restrict r matched
  for id in $role_default $role_optional; do
    [[ -z $id ]] && continue
    ppath=$(manifest_path_for "$id" 2>/dev/null)
    [[ -z $ppath ]] && continue
    restrict=$(manifest_get_field "$ppath" "II_RESTRICT_TO_ROLES")
    [[ -z $restrict ]] && continue
    matched=0
    for r in $restrict; do [[ "$r" == "$role_id" ]] && matched=1 && break; done
    [[ $matched -eq 1 ]] && out+=" $id"
  done
  echo "$out" | tr -s ' ' | sed 's/^ //; s/ $//'
}

_compute_role_generic_features() {
  local out="" id ppath restrict
  for id in $role_default $role_optional; do
    [[ -z $id ]] && continue
    ppath=$(manifest_path_for "$id" 2>/dev/null)
    [[ -z $ppath ]] && continue
    restrict=$(manifest_get_field "$ppath" "II_RESTRICT_TO_ROLES")
    [[ -z $restrict ]] && out+=" $id"
    # Items with a non-empty restriction that includes $role_id are
    # role-specific (see _compute_role_specific_features); ones with a
    # restriction excluding $role_id are dropped (role-author error).
  done
  echo "$out" | tr -s ' ' | sed 's/^ //; s/ $//'
}

# Filter a feature list to the role_default subset (those that should
# be pre-checked on first visit). Used to seed role_specific_picked
# and optional_picked from the right defaults.
_intersect_with_role_default() {
  local out="" id d
  for id in $1; do
    for d in $role_default; do
      [[ "$id" == "$d" ]] && out+=" $id" && break
    done
  done
  echo "$out" | tr -s ' ' | sed 's/^ //; s/ $//'
}

# What pick_addons (non-required parents) rewinds to. Same idea as
# before but now the chain runs through pick_optional (generic) →
# pick_role_specific (role-curated) → pick_addons_required (radios) →
# show_required → pick_role, with each stage skipped when its data
# set is empty.
_pre_addons_stage() {
  if _role_uses_custom_flow; then
    echo "custom_features"
  elif [[ -n $role_generic_features ]]; then
    echo "pick_optional"
  elif [[ -n $role_specific_features ]]; then
    echo "pick_role_specific"
  elif _any_required_parent_has_radios; then
    echo "pick_addons_required"
  elif [[ -n $role_required ]]; then
    echo "show_required"
  else
    echo "pick_role"
  fi
}
# Where BACK from pick_optional goes (step 4b → step 4a or earlier).
_pre_optional_stage() {
  if [[ -n $role_specific_features ]]; then
    echo "pick_role_specific"
  elif _any_required_parent_has_radios; then
    echo "pick_addons_required"
  elif [[ -n $role_required ]]; then
    echo "show_required"
  else
    echo "pick_role"
  fi
}
# Where BACK from pick_role_specific goes (step 4a → step 3 or earlier).
_pre_role_specific_stage() {
  if _any_required_parent_has_radios; then
    echo "pick_addons_required"
  elif [[ -n $role_required ]]; then
    echo "show_required"
  else
    echo "pick_role"
  fi
}
# What pick_addons_required rewinds to.
_pre_addons_required_stage() {
  if [[ -n $role_required ]]; then
    echo "show_required"
  else
    echo "pick_role"
  fi
}
# Returns the space-separated list of features that are already locked
# in for the queue at pick_optional time: role_required plus whatever
# the user picked in pick_addons_required (e.g. the nginx selection
# from the webserver radio). Used to compose the "auto-selected (will
# install automatically)" header on the optional-features screen, the
# same way pick_packages surfaces required-by-features packages.
_auto_selected_for_optional() {
  local out=""
  local id
  for id in $role_required; do
    out+=" $id"
  done
  for id in $role_required; do
    [[ -n ${addons_picked[$id]:-} ]] && out+=" ${addons_picked[$id]}"
  done
  echo "$out" | tr -s ' ' | sed 's/^ //; s/ $//'
}

# Where confirm BACK rewinds to: always edit_config, which is the last
# user-facing stage before the summary in both flows now.
_pre_confirm_stage() {
  if _role_uses_custom_flow; then
    echo "edit_config"
  else
    echo "edit_config"
  fi
}

stage="pick_role"
_entry_stage=""
while true; do
  prev_stage="$_entry_stage"
  _entry_stage="$stage"
  case "$stage" in

    pick_role)
      log_info "Rendering role picker."
      role_id=$(menu_select_role "Installicious" \
        "Pick the role for this Pi. Choose Custom to pick features individually." \
        "$role_id")
      rc=$?
      case $rc in
        0) ;;
        2)
          log_warn "No roles defined under \$PATH_ROLES; nothing to pick from."
          exit 0
          ;;
        *)
          log_info "User $CURRENTUSER exited at the role picker."
          exit 0
          ;;
      esac
      log_info "User $CURRENTUSER picked role: $role_id."

      # Role switched from the previous run? Drop the prior role's
      # picker memory so the new role starts from its own manifest
      # defaults — addons-of-A wouldn't make sense restored under B,
      # and a tier item only valid under role A would silently no-op
      # under B. LAST_ROLE_ID gets re-set so the clear only fires once
      # per role-switch event (and not on every revisit of pick_role
      # within the same role).
      if [[ -n ${LAST_ROLE_ID:-} && "$role_id" != "$LAST_ROLE_ID" ]]; then
        log_info "Role changed from $LAST_ROLE_ID to $role_id; clearing stale per-role selections."
        features_selected=""
        role_specific_picked=""
        optional_picked=""
        packages_selected=""
        addons_picked=()
        role_specific_visited=0
        optional_visited=0
        LAST_FEATURES_SELECTED=""
        LAST_ROLE_SPECIFIC_PICKED=""
        LAST_OPTIONAL_PICKED=""
        LAST_PACKAGES_SELECTED=""
        LAST_ADDONS_PICKED=""
        LAST_ROLE_ID="$role_id"
      fi
      _persist_selections

      if [[ $role_id == "custom" ]]; then
        role_path=""
        role_title="Custom"
        role_required=""
        role_default=""
        role_optional=""
        stage="custom_features"
      else
        role_path=$(role_path_for "$role_id")
        role_title=$(role_get_field "$role_path" "ROLE_TITLE")
        role_required=$(role_get_field "$role_path" "ROLE_FEATURES_REQUIRED")
        role_default=$(role_get_field "$role_path" "ROLE_FEATURES_DEFAULT")
        role_optional=$(role_get_field "$role_path" "ROLE_FEATURES_OPTIONAL")
        # Classify the tier list into role-specific (II_RESTRICT_TO_ROLES
        # contains $role_id) and generic (no restriction). Each gets its
        # own picker — step 4a + step 4b — so role-curated decisions
        # land before the cross-role ones.
        role_specific_features=$(_compute_role_specific_features)
        role_generic_features=$(_compute_role_generic_features)
        if [[ -n $role_required ]]; then
          stage="show_required"
        elif [[ -n $role_specific_features ]]; then
          stage="pick_role_specific"
        elif [[ -n $role_generic_features ]]; then
          stage="pick_optional"
        else
          # Role with no features in any tier — the stubbed roles today
          # (homeassistant, mediaserver, pihole) take this branch. Behave
          # like Custom: drop into the per-feature picker so the user can
          # still build a queue. Once a stub populates any of REQUIRED /
          # DEFAULT / OPTIONAL it'll route through one of the role-driven
          # stages above.
          log_info "Role $role_id has no required/default/optional features defined; routing to per-feature picker."
          stage="custom_features"
        fi
      fi
      ;;

    custom_features)
      log_info "Rendering features checklist."
      # Compute the role-restriction exclude list: any feature whose
      # II_RESTRICT_TO_ROLES is non-empty and doesn't include the
      # currently-picked role gets dropped from the checklist. Skyfield
      # with II_RESTRICT_TO_ROLES="weewx" stays hidden under custom /
      # pihole / homeassistant / mediaserver — only visible in the
      # weewx role's flow (which doesn't even reach this stage once
      # WeeWx's tiers are populated).
      restricted_excludes=""
      while IFS= read -r _fid; do
        if ! manifest_is_visible_for_role "$_fid" "$role_id"; then
          restricted_excludes="$restricted_excludes $_fid"
        fi
      done < <(manifest_filter_by_category "feature")
      features_selected=$(menu_select_category "feature" \
        "Installicious Features" \
        "Select features to install or configure." \
        "${features_selected//\"/}" \
        "$restricted_excludes")
      rc=$?
      case $rc in
        0)     _persist_selections; stage="merge_features" ;;
        1|255) stage="pick_role" ;;          # BACK or ESC → previous stage
        2)     features_selected=""; stage="merge_features" ;;
      esac
      ;;

    merge_features)
      # Pre-packages merge: $selected holds features (and, after
      # pick_addons, their addons too). Don't exit on empty here —
      # the user may still pick packages on pick_packages.
      selected="${features_selected//\"/}"
      selected=$(echo "$selected" | tr -s ' ' | sed 's/^ //; s/ $//')
      selected_parents="$selected"
      # Always route through pick_addons. When no parent has children,
      # pick_addons is a no-op render-wise but its trailing merge folds
      # any addons_picked entries (set in pick_addons_required for role
      # flows) into the final $selected list.
      stage="pick_addons"
      ;;

    show_required)
      log_info "Rendering required-features confirmation for role $role_id."
      # shellcheck disable=SC2086
      menu_show_required "$role_title" $role_required
      rc=$?
      case $rc in
        0)
          # Always route to pick_addons_required next; that stage will
          # auto-advance if no required parent declares II_OPTIONAL_GROUP.
          stage="pick_addons_required"
          ;;
        1|255) stage="pick_role" ;;          # BACK or ESC → role picker
      esac
      ;;

    pick_addons_required)
      log_info "Rendering required-feature radio sub-menus (step 3)."
      # Step 3 of the role flow: only the MANDATORY single-pick (radio /
      # exclusive II_OPTIONAL_GROUP) sub-menus for required parents fire
      # here. Non-exclusive (checklist) sub-menus — even on required
      # parents — defer to pick_addons (step 5) so the conflict filter
      # there has visibility into what the user picked on pick_optional
      # (step 4). Concretely: webserver's apache/nginx/lighttpd/caddy
      # radio fires here; the chosen backend's under-construction / ssl
      # checklist does NOT fire here.
      _rewind=0
      declare -a _screens=()
      for parent_id in $role_required; do
        [[ -z $parent_id ]] && continue
        ppath=$(manifest_path_for "$parent_id" 2>/dev/null)
        [[ -z $ppath ]] && continue
        pchildren=$(manifest_get_field "$ppath" "II_OPTIONAL_GROUP")
        [[ -z $pchildren ]] && continue
        pmode=$(manifest_get_field "$ppath" "II_OPTIONAL_GROUP_MODE")
        [[ $pmode != "exclusive" ]] && continue
        _screens+=("$parent_id")
      done
      # Immutable snapshot of the role_required-derived screens — the
      # rc=0 post-pick rebuild reuses this so legitimate next-parents
      # (e.g. `database` after `webserver`) survive each pick. The
      # earlier in-place truncation lost them.
      declare -a _role_required_screens=("${_screens[@]}")

      # Resume at the last screen when re-entered via BACK from any
      # stage forward of this one (pick_role_specific, pick_optional,
      # merge_role). Otherwise start at the first screen.
      _idx=0
      case "$prev_stage" in
        pick_role_specific|pick_optional|merge_role|pick_addons|pick_packages|edit_config|confirm|merge_packages)
          [[ ${#_screens[@]} -gt 0 ]] && _idx=$(( ${#_screens[@]} - 1 ))
          ;;
      esac
      while [[ $_idx -lt ${#_screens[@]} ]]; do
        parent_id="${_screens[$_idx]}"
        ppath=$(manifest_path_for "$parent_id" 2>/dev/null)
        pchildren=$(manifest_get_field "$ppath" "II_OPTIONAL_GROUP")
        ptitle=$(manifest_get_field "$ppath" "II_TITLE")

        # Capture into a temp so a BACK (rc=1|255) within the BFS doesn't
        # overwrite addons_picked[$parent_id] with whatever whiptail
        # emitted on Cancel. Only commit on rc=0.
        # shellcheck disable=SC2086
        _picked=$(menu_pick_one_optional "$ptitle" \
          --previously "${addons_picked[$parent_id]:-}" \
          $pchildren)
        rc=$?
        case $rc in
          0)
            addons_picked[$parent_id]="${_picked//\"/}"
            _persist_selections
            # Rebuild _screens from the role_required snapshot + cascade
            # children whose own exclusive groups should fire next. The
            # OLD code truncated _screens to [0..current_idx] then
            # appended cascade — that dropped legitimate next-parents
            # past the current index (e.g. with role_required="pkupd
            # webserver database", after the webserver pick _screens
            # became [webserver] and `database`'s radio never fired —
            # the install used whatever was in addons_picked[database]
            # from a prior run's selections.sh, silently). Rebuilding
            # keeps the role_required screens intact AND re-derives
            # cascade from current addons_picked, so re-picks don't
            # leave stale cascade entries behind either.
            _screens=("${_role_required_screens[@]}")
            for _r in "${_role_required_screens[@]}"; do
              _pick_for_r="${addons_picked[$_r]:-}"
              [[ -z $_pick_for_r ]] && continue
              _pp=$(manifest_path_for "$_pick_for_r" 2>/dev/null)
              [[ -z $_pp ]] && continue
              _pc=$(manifest_get_field "$_pp" "II_OPTIONAL_GROUP")
              [[ -z $_pc ]] && continue
              _pm=$(manifest_get_field "$_pp" "II_OPTIONAL_GROUP_MODE")
              [[ $_pm != "exclusive" ]] && continue
              _dup=0
              for _s in "${_screens[@]}"; do [[ "$_s" == "$_pick_for_r" ]] && _dup=1 && break; done
              [[ $_dup -eq 1 ]] && continue
              _screens+=("$_pick_for_r")
            done
            _idx=$((_idx + 1))
            ;;
          1|255)
            if [[ $_idx -gt 0 ]]; then
              _idx=$((_idx - 1))
            else
              _rewind=1
              break
            fi
            ;;
          2) _idx=$((_idx + 1)) ;;
        esac
      done

      if [[ $_rewind -eq 1 ]]; then
        stage=$(_pre_addons_required_stage)
        continue
      fi

      # Forward: pick_role_specific (step 4a) if the role has any
      # role-specific items, else pick_optional (step 4b) if any generic
      # items, else straight to merge_role. (No work shown if _screens
      # stayed empty — no required parent had an exclusive group.)
      if [[ ${#_screens[@]} -eq 0 ]]; then
        log_info "No required parents have exclusive II_OPTIONAL_GROUP; auto-advancing past step 3."
      fi
      if [[ -n $role_specific_features ]]; then
        stage="pick_role_specific"
      elif [[ -n $role_generic_features ]]; then
        stage="pick_optional"
      else
        stage="merge_role"
      fi
      ;;

    pick_role_specific)
      log_info "Rendering role-specific picker for role $role_id (step 4a)."
      # Step 4a: items in the role's DEFAULT+OPTIONAL tiers that are
      # restricted to THIS role (II_RESTRICT_TO_ROLES contains $role_id).
      # The split is automatic — role authors don't add a new tier, they
      # just set II_RESTRICT_TO_ROLES on their role-specific features.
      # Defaults follow tier membership: items also in role_default are
      # pre-checked, items only in role_optional start off.
      if [[ -z $role_specific_features ]]; then
        log_info "No role-specific features for $role_id; auto-advancing."
        if [[ -n $role_generic_features ]]; then
          stage="pick_optional"
        else
          stage="merge_role"
        fi
        continue
      fi

      if [[ $role_specific_visited -eq 0 ]]; then
        # Prefer the last-run picks (LAST_ROLE_SPECIFIC_PICKED) so a
        # rerun keeps whatever the user checked last time; fall back to
        # the role's DEFAULT tier intersection on a true first run.
        if [[ -n ${LAST_ROLE_SPECIFIC_PICKED:-} ]]; then
          role_specific_picked="$LAST_ROLE_SPECIFIC_PICKED"
        else
          role_specific_picked=$(_intersect_with_role_default "$role_specific_features")
        fi
        role_specific_visited=1
      fi

      # Conflict-filter the visible items against the locked-in queue
      # (role_required + step-3 addons_picked values).
      _rs_queue_snapshot="$role_required"
      for _akey in "${!addons_picked[@]}"; do _rs_queue_snapshot+=" ${addons_picked[$_akey]}"; done
      _rs_filtered=""
      for _id in $role_specific_features; do
        # shellcheck disable=SC2086
        if manifest_is_in_conflict_with "$_id" $_rs_queue_snapshot; then
          log_info "  filter: $_id (role-specific tier) — conflicts with the locked-in queue."
          continue
        fi
        _rs_filtered+=" $_id"
      done
      _rs_filtered=$(echo "$_rs_filtered" | tr -s ' ' | sed 's/^ //; s/ $//')

      auto_selected=$(_auto_selected_for_optional)
      if [[ -n $auto_selected ]]; then
        rs_desc="Auto-selected (will install automatically):\n  $auto_selected\n\nRole-specific add-ons below — these only make sense under the $role_title role. Default-on rows are pre-checked; toggle as needed."
      else
        rs_desc="Role-specific add-ons (under the $role_title role)."
      fi

      # Capture into a temp so a BACK (rc=1|255) doesn't overwrite
      # role_specific_picked with whatever whiptail emitted on Cancel.
      # (whiptail behavior on Cancel varies across builds — some emit
      # the current selection, some emit empty; either way a BACK shouldn't
      # mutate our persistent state). Only commit the temp on rc=0.
      # shellcheck disable=SC2086
      _picked=$(menu_pick_optionals "$role_title - Role-specific" \
        --desc "$rs_desc" \
        --previously "${role_specific_picked//\"/}" \
        $_rs_filtered)
      rc=$?
      case $rc in
        0)
          role_specific_picked="$_picked"
          _persist_selections
          if [[ -n $role_generic_features ]]; then
            stage="pick_optional"
          else
            stage="merge_role"
          fi
          ;;
        1|255) stage=$(_pre_role_specific_stage) ;;
        2)
          # Nothing to render here either (whole list got conflict-filtered).
          role_specific_picked=""
          if [[ -n $role_generic_features ]]; then
            stage="pick_optional"
          else
            stage="merge_role"
          fi
          ;;
      esac
      ;;

    pick_optional)
      log_info "Rendering generic optional-features picker for role $role_id (step 4b)."
      # Step 4b: items in the role's DEFAULT+OPTIONAL tiers that are NOT
      # restricted to this role (the cross-role-available features:
      # locale, bash, motd, ram-logging, rconf, compressed-swap on the
      # WeeWx role). Filtered against the same conflict snapshot as
      # step 4a plus role_specific_picked, so generic items that conflict
      # with role-specific picks drop out here.
      if [[ -z $role_generic_features ]]; then
        log_info "No generic optional features for $role_id; auto-advancing."
        stage="merge_role"
        continue
      fi
      # First visit: prefer LAST_OPTIONAL_PICKED (so a rerun preserves
      # whatever the user checked last time, e.g. compressed-swap toggled
      # on under WeeWx); fall back to the DEFAULT-tier intersection.
      if [[ $optional_visited -eq 0 ]]; then
        if [[ -n ${LAST_OPTIONAL_PICKED:-} ]]; then
          optional_picked="$LAST_OPTIONAL_PICKED"
        else
          optional_picked=$(_intersect_with_role_default "$role_generic_features")
        fi
        optional_visited=1
      fi
      # Compose the screen description so the user sees what's already
      # locked in (role_required + step-3 picks + step-4a picks).
      auto_selected=$(_auto_selected_for_optional)
      _rs_for_header="${role_specific_picked//\"/}"
      [[ -n $_rs_for_header ]] && auto_selected="$auto_selected $_rs_for_header"
      auto_selected=$(echo "$auto_selected" | tr -s ' ' | sed 's/^ //; s/ $//')
      if [[ -n $auto_selected ]]; then
        optional_desc="Auto-selected (will install automatically):\n  $auto_selected\n\nGeneric optional add-ons below. Default-on rows are pre-checked; toggle as needed."
      else
        optional_desc="Generic optional add-ons (default off; pick any you want)."
      fi

      # Conflict filter: snapshot includes role_required + step-3 picks +
      # step-4a (role_specific_picked) so any generic item that conflicts
      # with the user's role-specific selections is dropped here.
      _opt_queue_snapshot="$role_required ${role_specific_picked//\"/}"
      for _akey in "${!addons_picked[@]}"; do _opt_queue_snapshot+=" ${addons_picked[$_akey]}"; done
      _opt_filtered=""
      for _id in $role_generic_features; do
        # shellcheck disable=SC2086
        if manifest_is_in_conflict_with "$_id" $_opt_queue_snapshot; then
          log_info "  filter: $_id (generic tier) — conflicts with the locked-in queue."
          continue
        fi
        _opt_filtered+=" $_id"
      done
      _opt_filtered=$(echo "$_opt_filtered" | tr -s ' ' | sed 's/^ //; s/ $//')

      # BACK-preserves-selection: see the matching pattern in
      # pick_role_specific. _picked is the temp; commit on rc=0 only.
      # shellcheck disable=SC2086
      _picked=$(menu_pick_optionals "$role_title" \
        --desc "$optional_desc" \
        --previously "${optional_picked//\"/}" \
        $_opt_filtered)
      rc=$?
      case $rc in
        0)     optional_picked="$_picked"; _persist_selections; stage="merge_role" ;;
        1|255) stage=$(_pre_optional_stage) ;;
        2)     optional_picked=""; stage="merge_role" ;;
      esac
      ;;

    merge_role)
      selected="$role_required ${role_specific_picked//\"/} ${optional_picked//\"/}"
      selected=$(echo "$selected" | tr -s ' ' | sed 's/^ //; s/ $//')
      if [[ -z $selected ]]; then
        log_info "User $CURRENTUSER continued without selecting any features; nothing to do."
        exit 0
      fi
      selected_parents="$selected"
      # Route through pick_addons_optional_exclusive first so any parent
      # the user picked in step 4a/4b that owns an EXCLUSIVE radio (e.g.
      # the `database` parent's sqlite/mysql/mariadb sub-menu) gets a
      # chance to fire its radio before pick_addons (step 5) handles the
      # non-exclusive checklists. Required-parent radios already fired
      # in pick_addons_required (step 3); this is the optional-parent
      # analog. If no optional parent has an exclusive group, the new
      # stage is a no-op pass-through.
      stage="pick_addons_optional_exclusive"
      ;;

    pick_addons_optional_exclusive)
      # Step 4c (between merge_role and pick_addons): fires the exclusive
      # (radio) sub-menu for each non-required parent the user selected
      # in step 4a/4b that declares an exclusive II_OPTIONAL_GROUP.
      # Without this stage, a non-required exclusive parent (e.g.
      # `database` under the WeeWX role's DEFAULT tier) silently fell
      # back to the manifest's II_DEFAULT_SELECTED leaf — so the user
      # never saw the radio prompt and the install always picked the
      # default child. Required-parent radios still fire in step 3.
      log_info "Rendering optional-parent radio sub-menus (step 4c)."
      _rewind=0
      declare -a _opt_excl_screens=()
      for parent_id in $selected_parents; do
        [[ -z $parent_id ]] && continue
        # Skip required parents — their exclusive radios already fired
        # in pick_addons_required (step 3); we don't want to re-prompt.
        if _id_in_required "$parent_id"; then continue; fi
        ppath=$(manifest_path_for "$parent_id" 2>/dev/null)
        [[ -z $ppath ]] && continue
        pchildren=$(manifest_get_field "$ppath" "II_OPTIONAL_GROUP")
        [[ -z $pchildren ]] && continue
        pmode=$(manifest_get_field "$ppath" "II_OPTIONAL_GROUP_MODE")
        [[ $pmode != "exclusive" ]] && continue
        _opt_excl_screens+=("$parent_id")
      done

      # Nothing to prompt: pass through. Forward on forward-entry, back
      # on back-entry — so a BACK from pick_addons doesn't trap the user
      # on an empty screen. The back-entry path skips merge_role (which
      # always forwards) and lands directly on whichever stage populated
      # selected_parents, otherwise a BACK from pick_addons → us → merge_role
      # → us would loop forever.
      if [[ ${#_opt_excl_screens[@]} -eq 0 ]]; then
        log_info "No optional parents have exclusive II_OPTIONAL_GROUP; auto-advancing past step 4c."
        if [[ $prev_stage == "pick_addons" ]]; then
          if [[ -n $role_generic_features ]]; then
            stage="pick_optional"
          elif [[ -n $role_specific_features ]]; then
            stage="pick_role_specific"
          else
            stage=$(_pre_addons_stage)
          fi
        else
          stage="pick_addons"
        fi
        continue
      fi

      # Resume at the last screen when re-entered via BACK from pick_addons
      # (or any later stage). Otherwise start at the first.
      _idx=0
      case "$prev_stage" in
        pick_addons|pick_packages|edit_config|confirm|merge_packages)
          _idx=$(( ${#_opt_excl_screens[@]} - 1 ))
          ;;
      esac
      while [[ $_idx -lt ${#_opt_excl_screens[@]} ]]; do
        parent_id="${_opt_excl_screens[$_idx]}"
        ppath=$(manifest_path_for "$parent_id" 2>/dev/null)
        pchildren=$(manifest_get_field "$ppath" "II_OPTIONAL_GROUP")
        ptitle=$(manifest_get_field "$ppath" "II_TITLE")

        # Capture into a temp so a BACK (rc=1|255) doesn't overwrite
        # addons_picked[$parent_id] with whatever whiptail emitted on
        # Cancel. Only commit on rc=0.
        # shellcheck disable=SC2086
        _picked=$(menu_pick_one_optional "$ptitle" \
          --previously "${addons_picked[$parent_id]:-}" \
          $pchildren)
        rc=$?
        case $rc in
          0)
            addons_picked[$parent_id]="${_picked//\"/}"
            _persist_selections
            _idx=$((_idx + 1))
            ;;
          1|255)
            if [[ $_idx -gt 0 ]]; then
              _idx=$((_idx - 1))
            else
              _rewind=1
              break
            fi
            ;;
          2) _idx=$((_idx + 1)) ;;
        esac
      done

      if [[ $_rewind -eq 1 ]]; then
        # BACK from the first screen → rewind to merge_role's predecessor
        # so the user can re-pick their optional-features set. Going to
        # merge_role itself would just re-route forward to here again.
        stage="merge_role"
        # But merge_role doesn't prompt — re-route to whatever populated
        # selected_parents (pick_optional / pick_role_specific / earlier).
        if [[ -n $role_generic_features ]]; then
          stage="pick_optional"
        elif [[ -n $role_specific_features ]]; then
          stage="pick_role_specific"
        else
          stage=$(_pre_addons_stage)
        fi
        continue
      fi

      stage="pick_addons"
      ;;

    pick_addons)
      log_info "Rendering all-parents add-on sub-menus (step 5)."
      # Step 5 of the role flow: every parent in the queue (required +
      # role-picked-in-step-3 + role-optional-from-step-4) that declares
      # a NON-EXCLUSIVE II_OPTIONAL_GROUP fires its checklist here.
      # Exclusive (radio) sub-menus already fired in pick_addons_required
      # (step 3), so they're skipped. Each child is filtered against
      # II_CONFLICTS_WITH the already-locked-in queue snapshot so e.g.
      # webserver-under-construction is dropped from nginx's sub-menu
      # when weewx-site-ram was picked at step 4.
      _rewind=0

      # Candidate parents = role_required ∪ selected_parents ∪ values in
      # addons_picked (the radio-stage backend pick lands here as e.g.
      # addons_picked[webserver]="nginx"; nginx becomes a candidate so
      # its own non-exclusive children — under-construction / ssl —
      # render in step 5).
      declare -A _cand_seen=()
      declare -a _candidates=()
      _push_candidate() {
        local _id="$1"
        [[ -z $_id || -n ${_cand_seen[$_id]:-} ]] && return 0
        _cand_seen[$_id]=1
        _candidates+=("$_id")
      }
      for parent_id in $role_required; do _push_candidate "$parent_id"; done
      for parent_id in $selected_parents; do _push_candidate "$parent_id"; done
      for _akey in "${!addons_picked[@]}"; do
        for parent_id in ${addons_picked[$_akey]}; do _push_candidate "$parent_id"; done
      done
      unset -f _push_candidate

      # Queue snapshot used by the conflict filter — IDs locked in
      # before any step-5 picks. Newly-picked children at step 5
      # extend this set so later screens in the same stage also see
      # the live queue.
      _queue_snapshot=""
      for _qid in "${!_cand_seen[@]}"; do _queue_snapshot+=" $_qid"; done
      _queue_snapshot=$(echo "$_queue_snapshot" | tr -s ' ' | sed 's/^ //; s/ $//')

      # Filter candidates to those with a non-exclusive optional group
      # AND at least one child surviving the conflict filter. Without
      # the second check, a parent whose children ALL conflict-out at
      # runtime still gets a slot in _screens — and the inner loop's
      # "no add-ons left; skipping; _idx++" path silently advances past
      # it. That's fine on FORWARD entry, but on BACK-entry from
      # pick_packages we set _idx to the last _screens slot, hoping
      # to re-prompt — if that slot is a pure-skip, we fall straight
      # back to pick_packages and the user's BACK is eaten. So:
      # parents that would auto-skip don't belong in the navigable
      # screen list. The inner conflict-filter stays as a defensive
      # second pass for queue extensions mid-loop, but should now be
      # a rare no-op.
      declare -a _screens=()
      for parent_id in "${_candidates[@]}"; do
        ppath=$(manifest_path_for "$parent_id" 2>/dev/null)
        [[ -z $ppath ]] && continue
        pchildren=$(manifest_get_field "$ppath" "II_OPTIONAL_GROUP")
        [[ -z $pchildren ]] && continue
        pmode=$(manifest_get_field "$ppath" "II_OPTIONAL_GROUP_MODE")
        [[ $pmode == "exclusive" ]] && continue
        # Would ANY child of this parent survive the conflict filter?
        # If not, skip the parent entirely.
        _has_unfiltered=0
        for _ch in $pchildren; do
          # shellcheck disable=SC2086
          if ! manifest_is_in_conflict_with "$_ch" $_queue_snapshot; then
            _has_unfiltered=1
            break
          fi
        done
        if [[ $_has_unfiltered -eq 0 ]]; then
          log_info "  pre-filter: $parent_id — all children conflict with the locked-in queue; not adding to step-5 screen list."
          continue
        fi
        _screens+=("$parent_id")
      done

      # Resume at the last screen if the user came back into this stage
      # via BACK from the immediately-following stage (pick_packages).
      # Otherwise (forward entry from merge_role) start at the first
      # screen. Without this, BACK from pick_packages would land on the
      # FIRST sub-screen (e.g. motd's) and the user would have to NEXT
      # through it to get back to the screen they actually wanted to
      # edit (e.g. nginx's, where webserver-ssl lives).
      #
      # Empty-screens-on-back: if there's nothing to prompt AND we're
      # entering from a BACK, set _rewind=1 so the loop body skips and
      # the rewind branch below sends us back to pick_addons_optional_exclusive.
      # Otherwise we'd just forward to pick_packages again — the
      # infinite-loop bug the user keeps hitting.
      _idx=0
      if [[ $prev_stage == "pick_packages" ]]; then
        if [[ ${#_screens[@]} -gt 0 ]]; then
          _idx=$(( ${#_screens[@]} - 1 ))
        else
          _rewind=1
        fi
      fi
      while [[ $_idx -lt ${#_screens[@]} ]]; do
        parent_id="${_screens[$_idx]}"
        ppath=$(manifest_path_for "$parent_id" 2>/dev/null)
        pchildren=$(manifest_get_field "$ppath" "II_OPTIONAL_GROUP")
        ptitle=$(manifest_get_field "$ppath" "II_TITLE")

        # Drop children that conflict with anything currently queued.
        _filtered=""
        for _ch in $pchildren; do
          # shellcheck disable=SC2086
          if manifest_is_in_conflict_with "$_ch" $_queue_snapshot; then
            log_info "  filter: $_ch (under $parent_id) — conflicts with the locked-in queue."
            continue
          fi
          _filtered+=" $_ch"
        done
        _filtered=$(echo "$_filtered" | tr -s ' ' | sed 's/^ //; s/ $//')

        if [[ -z $_filtered ]]; then
          log_info "  $parent_id: no add-ons left after conflict filter; skipping."
          _idx=$((_idx + 1))
          continue
        fi

        # Capture into a temp so a BACK (rc=1|255) within the BFS doesn't
        # overwrite addons_picked[$parent_id] with whatever whiptail
        # emitted on Cancel. Only commit on rc=0.
        # shellcheck disable=SC2086
        _picked=$(menu_pick_optionals "$ptitle" \
          --previously "${addons_picked[$parent_id]:-}" \
          $_filtered)
        rc=$?
        case $rc in
          0)
            addons_picked[$parent_id]="${_picked//\"/}"
            _persist_selections
            picked="$_picked"   # local alias for the cascade walk below
            # NO truncation here. _screens was pre-seeded up front with
            # ALL queue parents that declare a non-exclusive group, in
            # discovery order. Truncating at $_idx (the old BFS pattern,
            # inherited from pick_addons_required where _screens grew
            # via cascade from a single root) would drop pre-seeded
            # parents that haven't been visited yet — that's how
            # picking nginx then advancing past motd's sub-screen used
            # to silently swallow nginx's sub-screen (and with it the
            # webserver-ssl row). Cascade entries (a child whose own
            # II_OPTIONAL_GROUP fires its own screen) are appended
            # below; on a stale re-pick they linger but are harmless to
            # NEXT through.
            for _pid in ${picked//\"/}; do
              [[ -z $_pid ]] && continue
              # Extend the queue snapshot with newly-picked IDs so the
              # next screen's conflict filter sees them.
              _queue_snapshot+=" $_pid"
              _dup=0
              for _s in "${_screens[@]}"; do [[ "$_s" == "$_pid" ]] && _dup=1 && break; done
              [[ $_dup -eq 1 ]] && continue
              _pp=$(manifest_path_for "$_pid" 2>/dev/null)
              [[ -z $_pp ]] && continue
              _pc=$(manifest_get_field "$_pp" "II_OPTIONAL_GROUP")
              [[ -z $_pc ]] && continue
              _pm=$(manifest_get_field "$_pp" "II_OPTIONAL_GROUP_MODE")
              [[ $_pm == "exclusive" ]] && continue
              _screens+=("$_pid")
            done
            _idx=$((_idx + 1))
            ;;
          1|255)
            if [[ $_idx -gt 0 ]]; then
              _idx=$((_idx - 1))
            else
              _rewind=1
              break
            fi
            ;;
          2) _idx=$((_idx + 1)) ;;
        esac
      done

      if [[ $_rewind -eq 1 ]]; then
        # Step 5 BACK lands on step 4c (optional-parent radios), which
        # passes through to merge_role's predecessor when it has nothing
        # to show. Without the 4c hop, a BACK here jumped over the radio
        # picks and a user couldn't re-pick e.g. the database backend.
        stage="pick_addons_optional_exclusive"
        continue
      fi

      # Rebuild `selected` from `selected_parents` + ALL transitively-
      # picked add-ons (BFS-follow addons_picked chains). Always start
      # from selected_parents so a back-and-forward trip never carries
      # over add-ons of a since-deselected parent — stale addons_picked
      # entries for unreachable IDs are ignored here. dedup with an
      # associative array.
      _merged="$selected_parents"
      declare -A _merge_seen=()
      for _mid in $selected_parents; do _merge_seen[$_mid]=1; done
      _mwl="$selected_parents"
      while [[ -n $_mwl ]]; do
        _mnext=""
        for _mid in $_mwl; do
          children="${addons_picked[$_mid]:-}"
          for _mchild in $children; do
            [[ -z $_mchild ]] && continue
            [[ -n ${_merge_seen[$_mchild]:-} ]] && continue
            _merge_seen[$_mchild]=1
            _merged+=" $_mchild"
            _mnext+=" $_mchild"
          done
        done
        _mwl=$(echo "$_mnext" | tr -s ' ' | sed 's/^ //; s/ $//')
      done
      selected=$(echo "$_merged" | tr -s ' ' | sed 's/^ //; s/ $//')
      log_info "User $CURRENTUSER add-ons merged: $selected."
      stage="pick_packages"
      ;;

    pick_packages)
      log_info "Rendering packages picker (step 6)."
      # Surface packages that selected features pull in via II_DEPS so
      # the user sees them but can't fight the scheduler by trying to
      # uncheck them. List them in the header and exclude them from the
      # toggleable checklist below.
      #
      # Additional exclude filters (applied to the picker rows, not to
      # the required-list header):
      #   - II_RESTRICT_TO_ROLES: a package can pin itself to certain
      #     roles via the same gate features use. Today no package sets
      #     this, but the filter respects it for future authors.
      #   - II_CONFLICTS_WITH: drop packages that conflict with anything
      #     currently in the queue (the merged $selected at this point
      #     includes features + addons; packages get added on the next
      #     stage).
      required_packages=$(_required_packages_from_features | tr '\n' ' ' | sed 's/[[:space:]]*$//')
      pkg_excludes="$required_packages"
      while IFS= read -r _pkg_id; do
        [[ -z $_pkg_id ]] && continue
        # Skip if already in the required-by-features list.
        case " $required_packages " in *" $_pkg_id "*) continue ;; esac
        # Role-restriction filter.
        if ! manifest_is_visible_for_role "$_pkg_id" "$role_id"; then
          pkg_excludes="$pkg_excludes $_pkg_id"
          log_info "  filter: package $_pkg_id — restricted away from role $role_id."
          continue
        fi
        # Conflict filter.
        # shellcheck disable=SC2086
        if manifest_is_in_conflict_with "$_pkg_id" $selected; then
          pkg_excludes="$pkg_excludes $_pkg_id"
          log_info "  filter: package $_pkg_id — conflicts with the queue."
          continue
        fi
      done < <(manifest_filter_by_category "package")
      pkg_excludes=$(echo "$pkg_excludes" | tr -s ' ' | sed 's/^ //; s/ $//')

      if [[ -n $required_packages ]]; then
        packages_desc="Required by selected features (auto-installed):\n  $required_packages\n\nOptional apt packages below. Most users skip this."
      else
        packages_desc="Optional apt packages. Most users skip this; required ones are auto-installed."
      fi
      packages_selected=$(menu_select_category "package" \
        "Installicious Packages" \
        "$packages_desc" \
        "${packages_selected//\"/}" \
        "$pkg_excludes")
      rc=$?
      case $rc in
        0)     _persist_selections; stage="merge_packages" ;;
        1|255) stage="pick_addons" ;;            # BACK → previous picker
        2)     packages_selected=""; stage="merge_packages" ;;
      esac
      ;;

    merge_packages)
      # Append packages_selected to the features+addons list (which
      # pick_addons already rebuilt cleanly from selected_parents +
      # addons_picked). Dedupe so a BACK-from-edit_config → forward-from-
      # pick_packages round trip doesn't double the package IDs — the
      # earlier version appended unconditionally, so every revisit grew
      # `selected` by another copy of packages_selected.
      declare -A _mp_seen=()
      for _id in $selected; do _mp_seen[$_id]=1; done
      for _pid in ${packages_selected//\"/}; do
        [[ -z $_pid ]] && continue
        [[ -n ${_mp_seen[$_pid]:-} ]] && continue
        _mp_seen[$_pid]=1
        selected+=" $_pid"
      done
      unset _mp_seen
      selected=$(echo "$selected" | tr -s ' ' | sed 's/^ //; s/ $//')
      if [[ -z $selected ]]; then
        log_info "User $CURRENTUSER continued without selecting any features or packages; nothing to do."
        exit 0
      fi
      log_info "merge_packages: queue = $selected"
      stage="edit_config"
      ;;

    edit_config)
      log_info "User $CURRENTUSER selected: $selected."
      # shellcheck disable=SC2086
      menu_edit_config "$role_id" $selected
      rc=$?
      # menu_edit_config translates ESC to rc=1 internally (with edits
      # persisted, same as the BACK button), so the explicit 255 case is
      # only there as belt-and-suspenders if a future helper change leaks
      # 255 through.
      case $rc in
        0)     stage="confirm" ;;               # Always the last picker — confirm next.
        1|255) stage="pick_packages" ;;         # BACK → packages screen.
        2)
          # No editable keys for the current selection. Auto-advance —
          # but if the user just pressed BACK on confirm, going forward
          # again would bounce them right back. Rewind further in that
          # case (skip the empty editor + skip back to the picker before
          # it).
          case "$prev_stage" in
            confirm) stage="pick_packages" ;;
            *)       stage="confirm" ;;
          esac
          ;;
      esac
      ;;

    confirm)
      log_info "Rendering install confirmation."
      confirm_msg="The following features will run, in dependency order:\n\n  $selected\n\nProceed?"
      menu_confirm "Confirm Install" "$confirm_msg"
      rc=$?
      case $rc in
        0)     stage="run" ;;
        1|255) stage="edit_config" ;;           # BACK → last picker before summary.
      esac
      ;;

    run)
      break
      ;;

    *)
      log_warn "Unknown stage: $stage; aborting."
      exit 1
      ;;
  esac
done

# ---------------------------------------------------------------------------
# Run via scheduler
# ---------------------------------------------------------------------------
# shellcheck disable=SC2086
scheduler_run_resolved $selected
rc=$?
# menu-config.sh is intentionally preserved across runs so the user's edits
# (API keys, hostnames, etc.) don't have to be re-typed every install. Reset
# manually with `sudo rm $PATH_STATE/menu-config.sh` if desired.
case $rc in
  0)
    log_ok "Queue completed."
    post_install_apply
    exit 0
    ;;
  3)
    # Pre-flight validation rejected the queue (missing dep installer or
    # similar). No state was changed; surface to the user and exit cleanly.
    msg="${SCHEDULER_LAST_ERROR:-Pre-flight validation failed.}\n\nNothing was installed. Aborting."
    whiptail --title "Installicious - Cannot start queue" --msgbox "$msg" 14 78
    exit 3
    ;;
  $EXIT_REBOOT)
    # Don't apply yet — resume.sh runs queued commands and emits notes after
    # the queue actually finishes across the reboot. menu-config.sh is kept
    # in place so the resumed installers see the same edits.
    log_info "Queue halted for reboot."
    exit $EXIT_REBOOT
    ;;
  *)
    log_warn "Queue completed with errors." "$rc"
    post_install_apply
    exit "$rc"
    ;;
esac
