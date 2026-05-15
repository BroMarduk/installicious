# features/feature-neowx-material.choices.sh
#
# Per-feature helper consumed by lib/menu.sh's menu_edit_config. Renders
# NEOWX_LANG as a radio of the 11 language codes the NeoWX Material skin
# ships. NEOWX_LOCALE and NEOWX_HTML_ROOT stay free-form text — locale
# strings and filesystem paths are too open-ended for a fixed list.

_choices_NEOWX_LANG() {
  printf 'en\tEnglish\n'
  printf 'ca\tCatalan (Catal\xc3\xa0)\n'
  printf 'de\tGerman (Deutsch)\n'
  printf 'es\tSpanish (Espa\xc3\xb1ol)\n'
  printf 'fi\tFinnish (Suomi)\n'
  printf 'fr\tFrench (Fran\xc3\xa7ais)\n'
  printf 'it\tItalian (Italiano)\n'
  printf 'nl\tDutch (Nederlands)\n'
  printf 'pl\tPolish (Polski)\n'
  printf 'se\tSwedish (Svenska)\n'
  printf 'sk\tSlovak (Sloven\xc4\x8dina)\n'
}
