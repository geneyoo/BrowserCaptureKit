SHELL := /bin/bash

.PHONY: generate build test conformance conformance-device verify

generate:
	@xcodegen generate --spec Conformance/project.yml

build:
	@./scripts/xcodebuild.sh build-for-testing

test:
	@./scripts/xcodebuild.sh test

conformance:
	@./scripts/conformance.sh simulator

conformance-device:
	@./scripts/conformance.sh device

verify: build test conformance
