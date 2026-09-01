#!/bin/bash
set -euo pipefail

action="${1:-test}"
if [[ $# -gt 0 ]]; then
  shift
fi
destination="${BCK_DESTINATION:-}"

if [[ -z "$destination" ]]; then
  available_devices="$(xcrun simctl list devices available)"
  simulator_id=""
  in_ios_runtime=false
  selected_in_runtime=false
  while IFS= read -r line; do
    case "$line" in
      "-- iOS "*)
        in_ios_runtime=true
        selected_in_runtime=false
        ;;
      "-- "*)
        in_ios_runtime=false
        ;;
      *)
        if [[ "$in_ios_runtime" == true && "$selected_in_runtime" == false &&
          "$line" =~ \(([[:xdigit:]-]{36})\)[[:space:]]+\((Booted|Shutdown)\) ]]; then
          simulator_id="${BASH_REMATCH[1]}"
          selected_in_runtime=true
        fi
        ;;
    esac
  done <<< "$available_devices"
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
