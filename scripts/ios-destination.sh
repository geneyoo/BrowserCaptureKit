#!/bin/bash
set -euo pipefail

mode="${1:-simulator}"

if [[ "$mode" == "simulator" ]]; then
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

  if [[ -n "$simulator_id" ]]; then
    echo "platform=iOS Simulator,id=$simulator_id"
    exit 0
  fi

  echo "No available iOS Simulator destination was found." >&2
  echo "$available_devices" >&2
  exit 1
fi

if [[ "$mode" == "device" ]]; then
  devices="$(xcrun xcdevice list --timeout 5)"
  index=0
  while identifier="$(plutil -extract "$index.identifier" raw -o - - 2>/dev/null <<< "$devices")"; do
    simulator="$(plutil -extract "$index.simulator" raw -o - - 2>/dev/null <<< "$devices" || true)"
    available="$(plutil -extract "$index.available" raw -o - - 2>/dev/null <<< "$devices" || true)"
    platform="$(plutil -extract "$index.platform" raw -o - - 2>/dev/null <<< "$devices" || true)"
    if [[ "$simulator" == false && "$available" == true &&
      "$platform" == "com.apple.platform.iphoneos" ]]; then
      echo "platform=iOS,id=$identifier"
      exit 0
    fi
    index=$((index + 1))
  done

  echo "No available physical iPhone destination was found." >&2
  exit 1
fi

echo "Usage: $0 [simulator|device]" >&2
exit 64
