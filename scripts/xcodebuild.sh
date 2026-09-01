#!/bin/bash
set -euo pipefail

action="${1:-test}"
if [[ $# -gt 0 ]]; then
  shift
fi
destination="${BCK_DESTINATION:-}"

if [[ -z "$destination" ]]; then
  available_devices="$(xcrun simctl list devices available)"
  simulator_ids="$(sed -nE \
    's/.*\(([[:xdigit:]-]{36})\) \((Booted|Shutdown)\)[[:space:]]*$/\1/p' \
    <<< "$available_devices")"
  simulator_id="${simulator_ids%%$'\n'*}"
  if [[ -z "$simulator_id" ]]; then
    echo "No available iOS Simulator destination was found." >&2
    echo "$available_devices" >&2
    exit 1
  fi
  destination="platform=iOS Simulator,id=$simulator_id"
fi

exec xcodebuild \
  -scheme BrowserCaptureKit \
  -destination "$destination" \
  -derivedDataPath .build/xcode-derived \
  "$action" \
  CODE_SIGNING_ALLOWED=NO \
  "$@"
