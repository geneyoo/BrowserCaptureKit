#!/bin/bash
set -euo pipefail

action="${1:-test}"
if [[ $# -gt 0 ]]; then
  shift
fi
destination="${BCK_DESTINATION:-}"

if [[ -z "$destination" ]]; then
  destinations="$(xcodebuild -scheme BrowserCaptureKit -showdestinations 2>/dev/null || true)"
  simulator_id="$(sed -nE \
    '/platform:iOS Simulator/!d; /dvtdevice/d; s/.*id:([^,]+),.*/\1/; s/^[[:space:]]+//; s/[[:space:]]+$//; p; q' \
    <<< "$destinations")"
  if [[ -z "$simulator_id" ]]; then
    echo "No available iOS Simulator destination was found." >&2
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
