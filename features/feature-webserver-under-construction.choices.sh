# features/feature-webserver-under-construction.choices.sh
#
# Per-feature helper consumed by lib/menu.sh's menu_edit_config. Renders
# WEBSERVER_UC_TEMPLATE as a radio whose options are auto-discovered from
# every resources/html-index-*.html file present on disk — drop a new
# template in resources/ and it shows up in the editor without a code
# change. The value stored is the slug between "html-index-" and ".html"
# (e.g. "midnight-editor"); install_body composes the full path from it.

_choices_WEBSERVER_UC_TEMPLATE() {
  local dir="${PATH_RESOURCES:-resources}"
  local f base slug label
  # Sort by filename so the menu is alphabetical and stable across runs.
  for f in $(ls -1 "$dir"/html-index-*.html 2>/dev/null | sort); do
    base="${f##*/}"
    slug="${base#html-index-}"
    slug="${slug%.html}"
    # Slug -> "Title Case" label: replace dashes with spaces, then
    # capitalize the first letter of each word.
    label=$(echo "$slug" | sed 's/-/ /g' \
      | awk '{for(i=1;i<=NF;i++)$i=toupper(substr($i,1,1)) tolower(substr($i,2));}1')
    printf '%s\t%s\n' "$slug" "$label"
  done
}
