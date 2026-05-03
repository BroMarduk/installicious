#!/usr/bin/env bash
set -euo pipefail

# -----------------------------
# Configuration
# -----------------------------
LOCATION_KEY="%%MOTD_WEATHER_LOC_CODE%%"

API_BASE_URL="https://dataservice.accuweather.com/currentconditions/v1"
API_URL="${API_BASE_URL}/${LOCATION_KEY}?format=json&language=en-us&details=true&getPhotos=false"

AUTH_HEADER="Authorization: Bearer %%MOTD_WEATHER_API_KEY%%"

OUT_DIR="/etc/motd.d/%%MOTD_NAME%%"
OUT_WEATHER="${OUT_DIR}/results-weather"
OUT_DATE="${OUT_DIR}/results-weather-date"

mkdir -p "${OUT_DIR}"

# -----------------------------
# Dependencies
# -----------------------------
command -v jshon >/dev/null 2>&1 || {
  echo "jshon not found" >&2
  exit 1
}

# -----------------------------
# Fetch JSON
# -----------------------------
JSON="$(curl -fsS -H "${AUTH_HEADER}" "${API_URL}")"

# -----------------------------
# Extract values (jshon)
# -----------------------------
WEATHER_TEXT="$(
  printf '%s' "${JSON}" |
  jshon -e 0 -e WeatherText -u
)"

TEMP_F="$(
  printf '%s' "${JSON}" |
  jshon -e 0 -e Temperature -e Imperial -e Value -u |
  awk '{ printf "%.0f\n", $1 }'
)"

REALFEEL_F="$(
  printf '%s' "${JSON}" |
  jshon -e 0 -e RealFeelTemperature -e Imperial -e Value -u |
  awk '{ printf "%.0f\n", $1 }'
)"

OBS_TIME_RAW="$(
  printf '%s' "${JSON}" |
  jshon -e 0 -e LocalObservationDateTime -u
)"
# -----------------------------
# Abbreviate WeatherText
# -----------------------------
WEATHER_TEXT="$(
  printf '%s' "${WEATHER_TEXT}" |
  sed -E 's/\b[Tt]hunderstorms\b/T-Storms/g; s/\b[Tt]hunderstorm\b/T-Storm/g; s/\b[Aa]nd\b/ \& /g; s/[[:space:]]+/ /g'
)"

# -----------------------------
# Format date
# -----------------------------
FORMATTED_DATE="$(date -d "${OBS_TIME_RAW}" '+%m/%d/%y %I:%M %p')"

# -----------------------------
# Safety fallbacks
# -----------------------------
WEATHER_TEXT="${WEATHER_TEXT:-Unknown}"
TEMP_F="${TEMP_F:-?}"
REALFEEL_F="${REALFEEL_F:-?}"

# -----------------------------
# Write output
# -----------------------------
echo "${WEATHER_TEXT}, ${TEMP_F}°F (${REALFEEL_F}°F)" > "${OUT_WEATHER}"
echo "${FORMATTED_DATE}" > "${OUT_DATE}"

chmod 644 "${OUT_WEATHER}" "${OUT_DATE}"

