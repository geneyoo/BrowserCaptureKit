#!/bin/bash
set -euo pipefail

action="${1:-test}"
if [[ $# -gt 0 ]]; then
  shift
fi
destination="${BCK_DESTINATION:-}"

if [[ -z "$destination" ]]; then
  destination="$(./scripts/ios-destination.sh simulator)"
fi

exec xcodebuild \
  -scheme BrowserCaptureKit \
  -destination "$destination" \
  -derivedDataPath .build/xcode-derived \
  "$action" \
  CODE_SIGNING_ALLOWED=NO \
  "$@"
