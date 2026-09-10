#!/bin/bash
# Simulator end-to-end gate: relay + signed PhoneBrowser build + controlled
# counter workflow driven through the agent API.
#
# Usage: scripts/phone-browser-e2e.sh [simulator]
# Env:   BCK_DESTINATION (xcodebuild destination), PORT (relay port, default 8787)
set -euo pipefail

mode="${1:-simulator}"
if [[ "$mode" != "simulator" ]]; then
  echo "Only the simulator mode is automated; see docs/PHONE_BROWSER_RUNBOOK.md for a physical iPhone." >&2
  exit 64
fi

port="${PORT:-8787}"
agent_token="e2e-$(uuidgen | tr -d '-')"
work_dir="$(mktemp -d)"
destination="${BCK_DESTINATION:-$(./scripts/ios-destination.sh simulator)}"
simulator_id="${destination##*id=}"
bundle_id="com.geneyoo.phonebrowser"
app_path=".build/phone-browser-e2e/Build/Products/Debug-iphonesimulator/PhoneBrowser.app"
relay_pid=""

cleanup() {
  local status=$?
  if [[ $status -ne 0 && -f "$work_dir/relay.log" ]]; then
    echo "== relay log" >&2
    tail -20 "$work_dir/relay.log" >&2
    echo "== devices" >&2
    curl -s -H "Authorization: Bearer $agent_token" "http://127.0.0.1:$port/v1/devices" >&2 || true
    echo >&2
  fi
  xcrun simctl terminate "$simulator_id" "$bundle_id" >/dev/null 2>&1 || true
  if [[ -n "$relay_pid" ]]; then
    kill "$relay_pid" >/dev/null 2>&1 || true
  fi
  rm -rf "$work_dir"
}
trap cleanup EXIT

echo "== building signed PhoneBrowser (Keychain needs entitlements)"
xcodebuild \
  -project PhoneBrowser/PhoneBrowser.xcodeproj \
  -scheme PhoneBrowser \
  -configuration Debug \
  -destination "$destination" \
  -derivedDataPath .build/phone-browser-e2e \
  build -quiet

echo "== starting relay on 127.0.0.1:$port"
(cd Relay && npm ci --no-audit --no-fund --silent)
AGENT_TOKEN="$agent_token" PORT="$port" HOST=127.0.0.1 DATA_DIR="$work_dir/relay" \
  node Relay/src/server.mjs >"$work_dir/relay.log" 2>&1 &
relay_pid=$!
until curl -sf -o /dev/null -H "Authorization: Bearer $agent_token" "http://127.0.0.1:$port/v1/devices"; do
  if ! kill -0 "$relay_pid" 2>/dev/null; then
    cat "$work_dir/relay.log" >&2
    echo "relay exited" >&2
    exit 1
  fi
  sleep 0.2
done

code="$(curl -sf -X POST -H "Authorization: Bearer $agent_token" "http://127.0.0.1:$port/v1/pairings" \
  | node -e 'let d="";process.stdin.on("data",c=>d+=c).on("end",()=>console.log(JSON.parse(d).code))')"

echo "== installing and launching on $simulator_id"
xcrun simctl boot "$simulator_id" >/dev/null 2>&1 || true
xcrun simctl terminate "$simulator_id" "$bundle_id" >/dev/null 2>&1 || true
xcrun simctl uninstall "$simulator_id" "$bundle_id" >/dev/null 2>&1 || true
xcrun simctl install "$simulator_id" "$app_path"
SIMCTL_CHILD_PHONEBROWSER_RELAY_URL="http://127.0.0.1:$port" \
SIMCTL_CHILD_PHONEBROWSER_PAIRING_CODE="$code" \
  xcrun simctl launch "$simulator_id" "$bundle_id" >/dev/null

echo "== running the controlled workflow"
RELAY_URL="http://127.0.0.1:$port" AGENT_TOKEN="$agent_token" node Relay/scripts/e2e.mjs
