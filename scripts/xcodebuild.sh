#!/bin/bash
set -euo pipefail

action="${1:-test}"
if [[ $# -gt 0 ]]; then
  shift
fi
destination="${BCK_DESTINATION:-}"

if [[ -z "$destination" ]]; then
  simulator_id="$({
    xcodebuild -scheme BrowserCaptureKit -showdestinations 2>/dev/null || true
  } | sed -nE 's/.*platform:iOS Simulator.*id:([^,]+),.*/\1/p' | grep -v dvtdevice | head -1 | xargs)"
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
