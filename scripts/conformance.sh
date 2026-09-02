#!/bin/bash
set -euo pipefail

mode="${1:-simulator}"
project="Conformance/BrowserCaptureKitConformance.xcodeproj"
scheme="BrowserCaptureKitConformance"
destination="${BCK_CONFORMANCE_DESTINATION:-}"

if [[ "$mode" != "simulator" && "$mode" != "device" ]]; then
  echo "Usage: $0 [simulator|device]" >&2
  exit 64
fi

if grep -R -E '\bXCTSkip(If|Unless)?\b' Conformance/Tests >/dev/null; then
  echo "Conformance tests must fail rather than skip." >&2
  exit 1
fi

if [[ -z "$destination" ]]; then
  destination="$(./scripts/ios-destination.sh "$mode")"
fi

if [[ "$mode" == "device" && "$destination" =~ (^|,)id=([^,]+) ]]; then
  device_id="${BASH_REMATCH[2]}"
  lock_state="$(
    xcrun devicectl device info lockState \
      --device "$device_id" \
      --timeout 5 2>/dev/null || true
  )"
  if [[ "$lock_state" == *"passcodeRequired: true"* ]]; then
    echo "Unlock the selected iPhone before running the conformance gate." >&2
    exit 1
  fi
fi

arguments=(
  -project "$project"
  -scheme "$scheme"
  -configuration Debug
  -destination "$destination"
  -derivedDataPath ".build/conformance-hosted-$mode"
  test
)

if [[ "$mode" == "simulator" ]]; then
  arguments+=(CODE_SIGNING_ALLOWED=NO)
else
  arguments+=(
    'CODE_SIGN_IDENTITY=Apple Development'
    "DEVELOPMENT_TEAM=${BCK_DEVELOPMENT_TEAM:-H32EKFDL92}"
  )
fi

exec xcodebuild "${arguments[@]}"
