#!/bin/bash
# Simulator end-to-end gate: relay + signed PhoneBrowser build + controlled
# counter workflow driven through the agent API.
#
# Usage: scripts/phone-browser-e2e.sh [simulator|device]
# Env:   BCK_DESTINATION / BCK_CONFORMANCE_DESTINATION (xcodebuild destination),
#        PORT (relay port, default 8787), BCK_RELAY_HOST (address the phone uses
#        to reach this Mac in device mode; defaults to the en0 address),
#        BCK_DEVELOPMENT_TEAM (device signing team).
set -euo pipefail

mode="${1:-simulator}"
if [[ "$mode" != "simulator" && "$mode" != "device" ]]; then
  echo "Usage: $0 [simulator|device]" >&2
  exit 64
fi

port="${PORT:-8787}"
agent_token="e2e-$(uuidgen | tr -d '-')"
work_dir="$(mktemp -d)"
bundle_id="com.geneyoo.phonebrowser"
relay_pid=""
if [[ "$mode" == "simulator" ]]; then
  destination="${BCK_DESTINATION:-$(./scripts/ios-destination.sh simulator)}"
  simulator_id="${destination##*id=}"
  app_path=".build/phone-browser-e2e/Build/Products/Debug-iphonesimulator/PhoneBrowser.app"
  relay_host=127.0.0.1
  relay_bind=127.0.0.1
else
  destination="${BCK_CONFORMANCE_DESTINATION:-$(./scripts/ios-destination.sh device)}"
  device_udid="${destination##*id=}"
  app_path=".build/phone-browser-e2e-device/Build/Products/Debug-iphoneos/PhoneBrowser.app"
  relay_host="${BCK_RELAY_HOST:-$(ipconfig getifaddr en0)}"
  relay_bind=0.0.0.0
  # devicectl addresses devices by CoreDevice identifier, not UDID.
  core_device_id="$(xcrun devicectl list devices --json-output "$work_dir/devices.json" >/dev/null 2>&1; \
    node -e 'const d=JSON.parse(require("fs").readFileSync(process.argv[1]));const m=d.result.devices.find(x=>x.hardwareProperties.udid===process.argv[2]);if(!m){process.exit(1)}console.log(m.identifier)' "$work_dir/devices.json" "$device_udid")"
fi

cleanup() {
  local status=$?
  if [[ $status -ne 0 && -f "$work_dir/relay.log" ]]; then
    echo "== relay log" >&2
    tail -20 "$work_dir/relay.log" >&2
    echo "== devices" >&2
    curl -s -H "Authorization: Bearer $agent_token" "http://127.0.0.1:$port/v1/devices" >&2 || true
    echo >&2
  fi
  if [[ "$mode" == "simulator" ]]; then
    xcrun simctl terminate "$simulator_id" "$bundle_id" >/dev/null 2>&1 || true
  fi
  if [[ -n "$relay_pid" ]]; then
    kill "$relay_pid" >/dev/null 2>&1 || true
  fi
  rm -rf "$work_dir"
}
trap cleanup EXIT

echo "== building signed PhoneBrowser (Keychain needs entitlements)"
build_arguments=(
  -project PhoneBrowser/PhoneBrowser.xcodeproj
  -scheme PhoneBrowser
  -configuration Debug
  -destination "$destination"
  -derivedDataPath "$(dirname "$(dirname "$(dirname "$(dirname "$app_path")")")")"
  build -quiet
)
if [[ "$mode" == "device" ]]; then
  build_arguments+=(-allowProvisioningUpdates 'CODE_SIGN_IDENTITY=Apple Development' "DEVELOPMENT_TEAM=${BCK_DEVELOPMENT_TEAM:-H32EKFDL92}")
fi
xcodebuild "${build_arguments[@]}"

echo "== starting relay on $relay_bind:$port (phone will use http://$relay_host:$port)"
(cd Relay && npm ci --no-audit --no-fund --silent)
AGENT_TOKEN="$agent_token" PORT="$port" HOST="$relay_bind" DATA_DIR="$work_dir/relay" \
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

if [[ "$mode" == "simulator" ]]; then
  echo "== installing and launching on $simulator_id"
  xcrun simctl boot "$simulator_id" >/dev/null 2>&1 || true
  xcrun simctl terminate "$simulator_id" "$bundle_id" >/dev/null 2>&1 || true
  xcrun simctl uninstall "$simulator_id" "$bundle_id" >/dev/null 2>&1 || true
  xcrun simctl install "$simulator_id" "$app_path"
  SIMCTL_CHILD_PHONEBROWSER_RELAY_URL="http://127.0.0.1:$port" \
  SIMCTL_CHILD_PHONEBROWSER_PAIRING_CODE="$code" \
    xcrun simctl launch "$simulator_id" "$bundle_id" >/dev/null
  ready_timeout_ms=60000
else
  echo "== installing and launching on iPhone $device_udid (unlock it; allow local network access when asked)"
  xcrun devicectl device install app --device "$core_device_id" "$app_path" >/dev/null
  xcrun devicectl device process launch --device "$core_device_id" --terminate-existing \
    -e "{\"PHONEBROWSER_RELAY_URL\":\"http://$relay_host:$port\",\"PHONEBROWSER_PAIRING_CODE\":\"$code\"}" \
    "$bundle_id" >/dev/null
  ready_timeout_ms=240000
fi

echo "== running the controlled workflow"
RELAY_URL="http://127.0.0.1:$port" FIXTURE_URL="http://$relay_host:$port/fixtures/counter" \
AGENT_TOKEN="$agent_token" READY_TIMEOUT_MS="$ready_timeout_ms" node Relay/scripts/e2e.mjs
