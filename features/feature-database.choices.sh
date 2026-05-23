# features/feature-database.choices.sh
#
# Per-feature helpers consumed by lib/menu.sh's menu_edit_config.
#
# DATABASE_TYPE is NOT a normal editable key — the radio sub-menu
# (II_OPTIONAL_GROUP on the parent feature-database) IS the type
# selector. Its pick is in the framework's selections.sh as
# LAST_ADDONS_PICKED ("database:mysql" etc.). The five DATABASE_* keys
# below are all hidden when SQLite is picked, since none of them apply.
#
# DATABASE_INNODB_TUNE gets a radio (off/on). The other four keys
# (HOST, NAME, USER, PASS) stay as free-form inputboxes with AUTO/SELF
# defaults seeded from config/database.config.

# _database_picked_type — echo one of sqlite | mysql | mariadb (or
# empty if no pick recorded yet). The applicability helpers below all
# defer to this. Reads the framework's selections.sh ($PATH_STATE owned
# by config/installicious.config) — at menu_edit_config time, the radio
# pick has already been committed there.
_database_picked_type() {
  local sfile="${PATH_STATE:-state}/selections.sh"
  [[ -f $sfile ]] || return 0
  # Source in a subshell so LAST_ADDONS_PICKED does not leak back into
  # the menu's environment.
  local picked
  picked=$( # shellcheck disable=SC1090
           source "$sfile" 2>/dev/null
           printf '%s' "${LAST_ADDONS_PICKED:-}"
         )
  case "$picked" in
    *database:sqlite*)  echo sqlite  ;;
    *database:mysql*)   echo mysql   ;;
    *database:mariadb*) echo mariadb ;;
  esac
}

# Shared body — true (rc=0) only when picked DB is mysql or mariadb.
_database_key_visible_for_mysql_family() {
  local t; t=$(_database_picked_type)
  [[ $t == mysql || $t == mariadb ]]
}

_applies_DATABASE_HOST()         { _database_key_visible_for_mysql_family; }
_applies_DATABASE_NAME()         { _database_key_visible_for_mysql_family; }
_applies_DATABASE_USER()         { _database_key_visible_for_mysql_family; }
_applies_DATABASE_PASS()         { _database_key_visible_for_mysql_family; }
_applies_DATABASE_INNODB_TUNE()  { _database_key_visible_for_mysql_family; }

# DATABASE_INNODB_TUNE renders as a 2-row radio.
_choices_DATABASE_INNODB_TUNE() {
  printf 'off\tUse stock Debian mysql/mariadb defaults (no SD-wear tuning)\n'
  printf 'on\tWrite /etc/mysql/conf.d/installicious-pi.cnf with flush=2 + auto-tuned buffer pool\n'
}
