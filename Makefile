SHELL := /bin/bash

.PHONY: build test verify

build:
	@./scripts/xcodebuild.sh build-for-testing

test:
	@./scripts/xcodebuild.sh test

verify: build test
