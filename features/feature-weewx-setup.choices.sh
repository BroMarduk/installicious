# features/feature-weewx-setup.choices.sh
#
# Per-feature helpers consumed by lib/menu.sh's menu_edit_config. These
# turn the enumerable WEEWX_STATION_* keys into radio pickers so the user
# selects from a list instead of typing a free-form value. The remaining
# keys (location, lat, lon, altitude, station URL) stay free-form text.

_choices_WEEWX_ALTITUDE_UNITS() {
  printf 'foot\tFeet\n'
  printf 'meter\tMeters\n'
}

_choices_WEEWX_UNITS() {
  printf 'us\tU.S. customary (°F, inHg, mph, in)\n'
  printf 'metric\tMetric (°C, mbar, km/h, cm)\n'
  printf 'metricwx\tMetric WX (°C, mbar, m/s, mm)\n'
}

_choices_WEEWX_REGISTER_STATION() {
  printf 'false\tKeep this station private (default)\n'
  printf 'true\tPublish to the weewx.com station registry\n'
}

_choices_WEEWX_STATION_TYPE() {
  # Friendly names — feature-weewx-setup's _driver_module() maps each to
  # the weewx driver module path. "Simulator" is weewx's built-in fake
  # station; pick it for a first boot before real hardware is wired up.
  printf 'Simulator\tSimulator (built-in fake station)\n'
  printf 'Vantage\tDavis Vantage (Pro2, Vue, etc.)\n'
  printf 'AcuRite\tAcuRite 5-in-1 / bridge\n'
  printf 'FineOffsetUSB\tFine Offset USB (Ambient, Elecsa, ...)\n'
  printf 'TE923\tHideki TE923 family\n'
  printf 'Ultimeter\tPeet Bros Ultimeter\n'
  printf 'WMR100\tOregon Scientific WMR100/200\n'
  printf 'WMR300\tOregon Scientific WMR300\n'
  printf 'WMR9x8\tOregon Scientific WMR9x8\n'
  printf 'WS1\tADS WS1\n'
  printf 'WS23xx\tLa Crosse WS23xx\n'
  printf 'WS28xx\tLa Crosse WS28xx\n'
}
