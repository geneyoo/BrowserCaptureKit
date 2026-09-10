#!/bin/bash
set -euo pipefail

exec ./scripts/hosted-test.sh \
  PhoneBrowser/PhoneBrowser.xcodeproj \
  PhoneBrowser \
  PhoneBrowser/Tests \
  phone-browser-hosted \
  "${1:-simulator}"
