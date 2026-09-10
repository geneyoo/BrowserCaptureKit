#!/bin/bash
# Runs an app-hosted XCTest bundle on the simulator or an attached iPhone.
# Usage: hosted-test.sh <project> <scheme> <tests-dir> <derived-data-name> [simulator|device]
set -euo pipefail

project="$1"
scheme="$2"
tests_dir="$3"
derived_name="$4"
mode="${5:-simulator}"
destination="${BCK_CONFORMANCE_DESTINATION:-}"

if [[ "$mode" != "simulator" && "$mode" != "device" ]]; then
  echo "Usage: $0 <project> <scheme> <tests-dir> <derived-data-name> [simulator|device]" >&2
  exit 64
fi

if grep -R -E '\bXCTSkip(If|Unless)?\b' "$tests_dir" >/dev/null; then
  echo "Hosted tests must fail rather than skip." >&2
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
    echo "Unlock the selected iPhone before running the hosted tests." >&2
    exit 1
  fi
fi

arguments=(
  -project "$project"
  -scheme "$scheme"
  -configuration Debug
  -destination "$destination"
  -derivedDataPath ".build/$derived_name-$mode"
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
