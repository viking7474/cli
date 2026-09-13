.DEFAULT_GOAL := all
SHELL    := /bin/sh
SDK      ?= $(shell xcrun --sdk iphoneos --show-sdk-path)
TARGET   ?= arm64-apple-ios16.0
LEGACY_TARGET ?= arm64-apple-ios13.0
SWIFT    ?= swift
LDID     ?= ldid
INSTALL  ?= /var/jb/usr/bin/icli

BUILD    := .build
BIN      ?= $(BUILD)/icli
LEGACY_BIN ?= $(BUILD)/icli-ios13
ENT      := Resources/icli.entitlements

ifeq ($(DEBUG),1)
CONFIGURATION := debug
else
CONFIGURATION := release
endif

SWIFT_FLAGS := --configuration $(CONFIGURATION) --triple $(TARGET) --sdk $(SDK) \
	--scratch-path $(BUILD)/swiftpm --product icli --force-resolved-versions

.PHONY: all debug legacy-rootful legacy-check legacy-fixtures resolve install clean deb deb-rootless deb-roothide deb-rootful deb-rootful-legacy

all:
	$(SWIFT) build $(SWIFT_FLAGS)
	cp "$$($(SWIFT) build $(SWIFT_FLAGS) --show-bin-path)/icli" $(BIN)
	$(LDID) -S$(ENT) $(BIN)
	python3 scripts/verify-binary.py $(BIN)

debug:
	$(MAKE) DEBUG=1 all

legacy-rootful:
	$(MAKE) TARGET=$(LEGACY_TARGET) BIN=$(LEGACY_BIN) all

legacy-check:
	sh scripts/check-legacy-package.sh

legacy-fixtures:
	ICLI_LAYOUT=rootful ICLI_MIN_IOS=13.0 ./scripts/build-testhost.sh
	ICLI_LAYOUT=rootful ./scripts/build-install-fixtures.sh

resolve:
	$(SWIFT) package --scratch-path $(BUILD)/swiftpm resolve

install: all
	sudo mkdir -p $(dir $(INSTALL))
	sudo cp $(BIN) $(INSTALL)
	sudo $(LDID) -S$(ENT) $(INSTALL)

clean:
	rm -rf $(BUILD) packaging/root

deb: all
	./packaging/build-deb.sh rootless

deb-rootless: deb

deb-roothide: all
	./packaging/build-deb.sh roothide

deb-rootful: all
	./packaging/build-deb.sh rootful

deb-rootful-legacy: legacy-rootful
	ICLI_BINARY=$(LEGACY_BIN) ICLI_MIN_IOS=13.0 ICLI_OUTPUT_SUFFIX=-ios13 ./packaging/build-deb.sh rootful
