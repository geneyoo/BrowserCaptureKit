#!/bin/bash
set -euo pipefail

exec ./scripts/hosted-test.sh \
  Conformance/BrowserCaptureKitConformance.xcodeproj \
  BrowserCaptureKitConformance \
  Conformance/Tests \
  conformance-hosted \
  "${1:-simulator}"
