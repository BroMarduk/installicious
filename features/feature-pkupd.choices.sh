# features/feature-pkupd.choices.sh
#
# Per-feature helpers consumed by lib/menu.sh's menu_edit_config. Render
# PKUPD_UPGRADE_MODE and PKUPD_AUTOREMOVE as radios. PKUPD_SKIP_WINDOW_MIN
# stays a free-form inputbox — it's an arbitrary minute count, no fixed list.

_choices_PKUPD_UPGRADE_MODE() {
  printf 'dist-upgrade\tFull upgrade — pulls new packages incl. kernels (default)\n'
  printf 'upgrade\tIn-place upgrade only — never pulls a kernel jump\n'
}

_choices_PKUPD_AUTOREMOVE() {
  printf 'true\tRun apt-get autoremove --purge after the upgrade (default)\n'
  printf 'false\tSkip autoremove — leave orphaned packages in place\n'
}
