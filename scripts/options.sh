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
#                                                       →  edit_config
#                                                       →  custom_packages
#                                                       →  merge_packages
#                                                       →  confirm  →  run
#
#   *pick_addons fires only when at least one selected feature declares
#    II_OPTIONAL_GROUP. The Packages screen comes AFTER edit_config so
#    feature configs are known before any package decisions, and so the
#    "required by selected features" header on Packages reflects every
#    feature/addon's II_DEPS.
#
# Role-flow order (role declares REQUIRED / DEFAULT / OPTIONAL features):
#
#   pick_role  →  show_required*  →  pick_addons_required*  →  pick_optional*
#                                                           →  merge_role
#                                                           →  pick_addons*
#                                                           →  edit_config
#                                                           →  confirm  →  run
#
#   pick_addons_required fires the sub-menu for any REQUIRED parent
#   with an II_OPTIONAL_GROUP (e.g. webserver's apache/nginx/lighttpd/
#   caddy radio) BEFORE pick_optional, so mandatory-backend choices
#   land while the user is still on the "required setup" mental track.
#   pick_addons (post-merge_role) handles non-required parents only,
#   so motd's optional add-on checkboxes still come after the user has
#   confirmed motd is selected on the optional list.
#
#   No Custom packages screen — the role's features pull in their
#   package deps via II_DEPS automatically; the user doesn't see the
#   raw package picker.
#
# Stage glossary:
#   pick_role             single-select role picker (first stage)
#   custom_features       Custom: pick from features/ (II_CATEGORY="feature")
#   merge_features        internal: stage selected = features + (later) addons
#   show_required         Role: confirm the required features (info)
#   pick_addons_required  Role: sub-menu(s) for REQUIRED parents that
#                         declare II_OPTIONAL_GROUP (e.g. webserver radio)
#   pick_optional         Role: pick optional add-on features
#   merge_role            internal: stage selected = required + optional
#   pick_addons           sub-menu(s) for NON-required parents with
#                         II_OPTIONAL_GROUP (e.g. motd's checkbox children)
#   edit_config           surface II_EDITABLE_CONFIG / ROLE_EDITABLE_CONFIG values
#   custom_packages   Custom: pick from packages/ (II_CATEGORY="package");
#                     required-by-features auto-listed and excluded from picker
#   merge_packages    internal: append picked packages, exit if nothing at all
#   confirm           final yes/no
#   run               scheduler hand-off (terminal stage)
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

if [[ -z $FILE_LOG_INSTALLICIOUS ]]; then
  FILE_LOG_INSTALLER="$PATH_LOGS/installicious.log"
else
  FILE_LOG_INSTALLER="$PATH_LOGS/$FILE_LOG_INSTALLICIOUS"
fi
log_init "$II_TITLE" "$FILE_LOG_INSTALLER"

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

# State carried across stages.
role_id=""
role_path=""
role_title=""
role_required=""
role_default=""
role_optional=""
features_selected=""
packages_selected=""
optional_picked=""
# Whether the user has visited the optional checklist for this role yet.
# On the first visit we seed optional_picked from the role's DEFAULT list
# so those items are pre-checked; subsequent visits preserve the user's
# edits via optional_picked itself.
optional_visited=0
selected=""           # final list (parents + their picked add-ons)
selected_parents=""   # the user's category/role picks BEFORE add-ons get merged
declare -A addons_picked   # parent_id → space-separated add-on IDs the user picked

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

_any_optional_parent_has_addons() {
  local id ppath addons
  for id in $selected_parents; do
    _id_in_required "$id" && continue
    ppath=$(manifest_path_for "$id" 2>/dev/null)
    [[ -z $ppath ]] && continue
    addons=$(manifest_get_field "$ppath" "II_OPTIONAL_GROUP")
    [[ -n $addons ]] && return 0
  done
  return 1
}
# Returns the unique package IDs that any selected feature (or its
# add-on) declares as a dependency (II_DEPS). The scheduler pulls these
# in via scheduler_resolve_deps regardless, but we surface them on the
# custom_packages screen so the user knows they'll be installed AND
# can't accidentally try to deselect them (we filter them out of the
# toggleable checklist via menu_select_category's exclude param).
#
# Reads from $selected (which by the time custom_packages runs in the
# new flow contains features + their picked addons) so addon deps are
# accounted for too.
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
# features (the stubbed roles today: homeassistant, mediaserver, pihole,
# weewx). Both flow through the per-feature checklist (custom_features →
# edit_config → custom_packages → confirm) instead of
# show_required / pick_optional.
_role_uses_custom_flow() {
  [[ $role_id == "custom" ]] && return 0
  [[ -z $role_required && -z $role_default && -z $role_optional ]] && return 0
  return 1
}
# Returns the stage that BACK from edit_config rewinds to. Doesn't
# include packages or confirm — those come AFTER edit_config in the
# new flow (features → addons → edit_config → packages → confirm).
prev_selection_stage() {
  if _any_optional_parent_has_addons; then
    echo "pick_addons"
  elif _role_uses_custom_flow; then
    echo "custom_features"
  elif [[ -n $role_default || -n $role_optional ]]; then
    echo "pick_optional"
  elif _any_required_parent_has_addons; then
    echo "pick_addons_required"
  elif [[ -n $role_required ]]; then
    echo "show_required"
  else
    echo "pick_role"
  fi
}
# What pick_addons (non-required parents) rewinds to.
_pre_addons_stage() {
  if _role_uses_custom_flow; then
    echo "custom_features"
  elif [[ -n $role_default || -n $role_optional ]]; then
    echo "pick_optional"
  elif _any_required_parent_has_radios; then
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
# same way custom_packages surfaces required-by-features packages.
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

# Where confirm BACK rewinds to: in Custom flow it's the Packages
# screen, in Role flow there's no Packages screen so it goes to the
# config editor.
_pre_confirm_stage() {
  if _role_uses_custom_flow; then
    echo "custom_packages"
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
        if [[ -n $role_required ]]; then
          stage="show_required"
        elif [[ -n $role_default || -n $role_optional ]]; then
          stage="pick_optional"
        else
          # Role with no features in any tier — the stubbed roles today
          # (homeassistant, mediaserver, pihole, weewx) take this branch.
          # Behave like Custom: drop into the per-feature picker so the
          # user can still build a queue. Once a stub populates any of
          # REQUIRED / DEFAULT / OPTIONAL it'll route through one of the
          # role-driven stages above.
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
        0)     stage="merge_features" ;;
        1|255) stage="pick_role" ;;          # BACK or ESC → previous stage
        2)     features_selected=""; stage="merge_features" ;;
      esac
      ;;

    merge_features)
      # Pre-packages merge: $selected holds features (and, after
      # pick_addons, their addons too). Don't exit on empty here —
      # the user may still pick packages on custom_packages.
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

      _idx=0
      while [[ $_idx -lt ${#_screens[@]} ]]; do
        parent_id="${_screens[$_idx]}"
        ppath=$(manifest_path_for "$parent_id" 2>/dev/null)
        pchildren=$(manifest_get_field "$ppath" "II_OPTIONAL_GROUP")
        ptitle=$(manifest_get_field "$ppath" "II_TITLE")

        # shellcheck disable=SC2086
        picked=$(menu_pick_one_optional "$ptitle" \
          --previously "${addons_picked[$parent_id]:-}" \
          $pchildren)
        rc=$?
        case $rc in
          0)
            addons_picked[$parent_id]="${picked//\"/}"
            # Append picked children with their OWN exclusive groups (a
            # cascade of radios; rare but possible) so they fire as the
            # next screen. Non-exclusive children land in step 5.
            _screens=("${_screens[@]:0:$((_idx+1))}")
            for _pid in ${picked//\"/}; do
              [[ -z $_pid ]] && continue
              _dup=0
              for _s in "${_screens[@]}"; do [[ "$_s" == "$_pid" ]] && _dup=1 && break; done
              [[ $_dup -eq 1 ]] && continue
              _pp=$(manifest_path_for "$_pid" 2>/dev/null)
              [[ -z $_pp ]] && continue
              _pc=$(manifest_get_field "$_pp" "II_OPTIONAL_GROUP")
              [[ -z $_pc ]] && continue
              _pm=$(manifest_get_field "$_pp" "II_OPTIONAL_GROUP_MODE")
              [[ $_pm != "exclusive" ]] && continue
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
        stage=$(_pre_addons_required_stage)
        continue
      fi

      # Forward: pick_optional if the role offers any default/optional
      # features, otherwise straight to merge_role. (No work shown if
      # _screens stayed empty — no required parent had an exclusive group.)
      if [[ ${#_screens[@]} -eq 0 ]]; then
        log_info "No required parents have exclusive II_OPTIONAL_GROUP; auto-advancing past step 3."
      fi
      if [[ -n $role_default || -n $role_optional ]]; then
        stage="pick_optional"
      else
        stage="merge_role"
      fi
      ;;

    pick_optional)
      log_info "Rendering optional-features picker for role $role_id (step 4)."
      # First visit for this role: seed user's selection with the role's
      # DEFAULT list so those items are pre-checked. Items in
      # ROLE_FEATURES_OPTIONAL stay unchecked until the user toggles them.
      if [[ $optional_visited -eq 0 ]]; then
        optional_picked="$role_default"
        optional_visited=1
      fi
      # Compose the screen description so the user sees what's already
      # locked in (role_required + the radio backend picked in
      # pick_addons_required), mirroring how custom_packages shows
      # auto-installed required packages above its checklist.
      auto_selected=$(_auto_selected_for_optional)
      if [[ -n $auto_selected ]]; then
        optional_desc="Auto-selected (will install automatically):\n  $auto_selected\n\nOptional add-ons below. Default-on rows are pre-checked; toggle as needed."
      else
        optional_desc="Optional add-ons (default off; pick any you want)."
      fi

      # Apply the II_CONFLICTS_WITH filter: drop any role-tier item that
      # conflicts with the locked-in queue (role_required + step-3 picks).
      # Today no real conflict pair lives across this boundary (the canonical
      # pair, weewx-site-ram ↔ webserver-under-construction, sits at the
      # role-tier vs nginx-sub-feature boundary which is caught in step 5),
      # but the filter is in place for future role authors who put
      # conflicting items in the tier list.
      _opt_queue_snapshot="$role_required"
      for _akey in "${!addons_picked[@]}"; do _opt_queue_snapshot+=" ${addons_picked[$_akey]}"; done
      _opt_default_filtered=""
      _opt_optional_filtered=""
      for _id in $role_default; do
        # shellcheck disable=SC2086
        if manifest_is_in_conflict_with "$_id" $_opt_queue_snapshot; then
          log_info "  filter: $_id (default tier) — conflicts with the locked-in queue."
          continue
        fi
        _opt_default_filtered+=" $_id"
      done
      for _id in $role_optional; do
        # shellcheck disable=SC2086
        if manifest_is_in_conflict_with "$_id" $_opt_queue_snapshot; then
          log_info "  filter: $_id (optional tier) — conflicts with the locked-in queue."
          continue
        fi
        _opt_optional_filtered+=" $_id"
      done
      _opt_default_filtered=$(echo "$_opt_default_filtered" | tr -s ' ' | sed 's/^ //; s/ $//')
      _opt_optional_filtered=$(echo "$_opt_optional_filtered" | tr -s ' ' | sed 's/^ //; s/ $//')

      # shellcheck disable=SC2086
      optional_picked=$(menu_pick_optionals "$role_title" \
        --desc "$optional_desc" \
        --previously "${optional_picked//\"/}" \
        $_opt_default_filtered $_opt_optional_filtered)
      rc=$?
      case $rc in
        0)     stage="merge_role" ;;
        1|255)
          # BACK from pick_optional rewinds to whichever stage rendered
          # something just before us: pick_addons_required (radios) if
          # any required parent had an exclusive sub-menu, else
          # show_required, else pick_role for roles with no required tier.
          if _any_required_parent_has_radios; then
            stage="pick_addons_required"
          elif [[ -n $role_required ]]; then
            stage="show_required"
          else
            stage="pick_role"
          fi
          ;;
        2)     optional_picked=""; stage="merge_role" ;;
      esac
      ;;

    merge_role)
      selected="$role_required ${optional_picked//\"/}"
      selected=$(echo "$selected" | tr -s ' ' | sed 's/^ //; s/ $//')
      if [[ -z $selected ]]; then
        log_info "User $CURRENTUSER continued without selecting any features; nothing to do."
        exit 0
      fi
      selected_parents="$selected"
      # Always route through pick_addons. Its trailing merge folds the
      # required-parent addons (set earlier in pick_addons_required) into
      # the final $selected list even when no NON-required parent has
      # children to prompt about.
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

      # Filter candidates to those with a non-exclusive optional group.
      declare -a _screens=()
      for parent_id in "${_candidates[@]}"; do
        ppath=$(manifest_path_for "$parent_id" 2>/dev/null)
        [[ -z $ppath ]] && continue
        pchildren=$(manifest_get_field "$ppath" "II_OPTIONAL_GROUP")
        [[ -z $pchildren ]] && continue
        pmode=$(manifest_get_field "$ppath" "II_OPTIONAL_GROUP_MODE")
        [[ $pmode == "exclusive" ]] && continue
        _screens+=("$parent_id")
      done

      # Queue snapshot used by the conflict filter — IDs locked in
      # before any step-5 picks. Newly-picked children at step 5
      # extend this set so later screens in the same stage also see
      # the live queue.
      _queue_snapshot=""
      for _qid in "${!_cand_seen[@]}"; do _queue_snapshot+=" $_qid"; done
      _queue_snapshot=$(echo "$_queue_snapshot" | tr -s ' ' | sed 's/^ //; s/ $//')

      _idx=0
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

        # shellcheck disable=SC2086
        picked=$(menu_pick_optionals "$ptitle" \
          --previously "${addons_picked[$parent_id]:-}" \
          $_filtered)
        rc=$?
        case $rc in
          0)
            addons_picked[$parent_id]="${picked//\"/}"
            _screens=("${_screens[@]:0:$((_idx+1))}")
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
        stage=$(_pre_addons_stage)
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
      stage="edit_config"
      ;;

    edit_config)
      log_info "User $CURRENTUSER selected: $selected."
      # shellcheck disable=SC2086
      menu_edit_config "$role_id" $selected
      rc=$?
      # menu_edit_config now translates ESC to rc=1 internally (with edits
      # persisted, same as the BACK button), so the explicit 255 case is
      # only there as belt-and-suspenders if a future helper change leaks
      # 255 through.
      case $rc in
        0)
          # Custom flow: advance to packages screen so the user can pick
          # additional apt packages with full knowledge of the feature
          # configs they just edited (and so the packages screen knows
          # which packages are required by feature II_DEPS).
          # Role flow: no packages screen — go straight to confirm.
          if _role_uses_custom_flow; then
            stage="custom_packages"
          else
            stage="confirm"
          fi
          ;;
        1|255) stage=$(prev_selection_stage) ;;
        2)
          # No editable keys for the current selection. Auto-advance — but
          # if the user just pressed BACK on confirm or custom_packages,
          # going forward again would bounce them right back. Rewind
          # further in that case instead.
          case "$prev_stage" in
            confirm|custom_packages)
              stage=$(prev_selection_stage)
              ;;
            *)
              if _role_uses_custom_flow; then
                stage="custom_packages"
              else
                stage="confirm"
              fi
              ;;
          esac
          ;;
      esac
      ;;

    custom_packages)
      log_info "Rendering packages checklist."
      # Surface packages that selected features pull in via II_DEPS so
      # the user sees them but can't fight the scheduler by trying to
      # uncheck them. We list them in the description and exclude them
      # from the toggleable checklist below.
      required_packages=$(_required_packages_from_features | tr '\n' ' ' | sed 's/[[:space:]]*$//')
      if [[ -n $required_packages ]]; then
        packages_desc="Required by selected features (auto-installed):\n  $required_packages\n\nOptional apt packages below. Most users skip this."
      else
        packages_desc="Optional apt packages. Most users skip this; required ones are auto-installed."
      fi
      packages_selected=$(menu_select_category "package" \
        "Installicious Packages" \
        "$packages_desc" \
        "${packages_selected//\"/}" \
        "$required_packages")
      rc=$?
      case $rc in
        0)     stage="merge_packages" ;;
        1|255) stage="edit_config" ;;        # BACK or ESC → editor
        2)     packages_selected=""; stage="merge_packages" ;;
      esac
      ;;

    merge_packages)
      # Append packages to the already-selected features+addons. This
      # is where we make the final "did the user pick anything at all"
      # decision — features alone, packages alone, or any combination
      # is fine. Empty everything means "nothing to do" → exit.
      selected="$selected ${packages_selected//\"/}"
      selected=$(echo "$selected" | tr -s ' ' | sed 's/^ //; s/ $//')
      if [[ -z $selected ]]; then
        log_info "User $CURRENTUSER continued without selecting any features or packages; nothing to do."
        exit 0
      fi
      stage="confirm"
      ;;

    confirm)
      log_info "Rendering install confirmation."
      confirm_msg="The following features will run, in dependency order:\n\n  $selected\n\nProceed?"
      menu_confirm "Confirm Install" "$confirm_msg"
      rc=$?
      case $rc in
        0)     stage="run" ;;
        1|255) stage=$(_pre_confirm_stage) ;;  # Custom: → custom_packages; Role: → edit_config
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
