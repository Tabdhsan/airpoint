#!/bin/bash
# Installs AirPoint on a connected Android TV device and turns its accessibility service on.
# Usage: ./install.sh [adb-serial]   e.g. ./install.sh 192.168.1.50:5555
set -euo pipefail
cd "$(dirname "$0")"

SERIAL="${1:-${ANDROID_SERIAL:-}}"
ADB=(adb)
[ -n "$SERIAL" ] && ADB=(adb -s "$SERIAL")

COMPONENT="com.bitbyteco.airpoint/com.bitbyteco.airpoint.AirPointService"

"${ADB[@]}" install -r build/AirPoint.apk

current="$("${ADB[@]}" shell settings get secure enabled_accessibility_services | tr -d '\r')"
if [ "$current" = "null" ] || [ -z "$current" ]; then
  updated="$COMPONENT"
elif [[ ":$current:" == *":$COMPONENT:"* ]]; then
  updated="$current"
else
  updated="$current:$COMPONENT"
fi

# If AirPoint was already on, switch it off for a moment so the system rebinds the new build.
if [ "$updated" = "$current" ]; then
  without="$(echo "$current" | tr ':' '\n' | grep -vxF "$COMPONENT" | paste -sd: - || true)"
  if [ -z "$without" ]; then
    "${ADB[@]}" shell settings delete secure enabled_accessibility_services >/dev/null
  else
    "${ADB[@]}" shell settings put secure enabled_accessibility_services "$without"
  fi
  sleep 1
fi
"${ADB[@]}" shell settings put secure enabled_accessibility_services "$updated"
"${ADB[@]}" shell settings put secure accessibility_enabled 1

echo "Enabled: $("${ADB[@]}" shell settings get secure enabled_accessibility_services | tr -d '\r')"
