# features/feature-pkupd.choices.sh
#
# Per-feature helper consumed by lib/menu.sh's menu_edit_config. Renders
# PKUPD_UPGRADE_MODE as a two-option radio. PKUPD_SKIP_WINDOW_MIN stays a
# free-form inputbox — it's an arbitrary minute count, no fixed list.

_choices_PKUPD_UPGRADE_MODE() {
  printf 'dist-upgrade\tFull upgrade — pulls new packages incl. kernels (default)\n'
  printf 'upgrade\tIn-place upgrade only — never pulls a kernel jump\n'
}
