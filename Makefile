SHELL := /bin/bash

.PHONY: generate build test conformance conformance-device phone-browser phone-browser-device phone-browser-e2e phone-browser-e2e-device relay-test verify

generate:
	@xcodegen generate --spec Conformance/project.yml
	@xcodegen generate --spec PhoneBrowser/project.yml

build:
	@./scripts/xcodebuild.sh build-for-testing

test:
	@./scripts/xcodebuild.sh test

conformance:
	@./scripts/conformance.sh simulator

conformance-device:
	@./scripts/conformance.sh device

phone-browser:
	@./scripts/phone-browser.sh simulator

phone-browser-device:
	@./scripts/phone-browser.sh device

relay-test:
	@cd Relay && npm ci --no-audit --no-fund && npm test

# Signed simulator build + relay + counter workflow; not part of `verify`
# because it installs a signed app and binds a local port.
phone-browser-e2e:
	@./scripts/phone-browser-e2e.sh simulator

phone-browser-e2e-device:
	@./scripts/phone-browser-e2e.sh device

verify: build test conformance phone-browser relay-test
