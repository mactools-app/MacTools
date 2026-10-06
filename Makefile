SHELL := /bin/zsh

# Prefer Xcode's Apple-signed Python for local tooling while allowing explicit overrides.
PYTHON3 ?= $(if $(wildcard /usr/bin/python3),/usr/bin/python3,python3)
export PYTHON3

PROJECT_NAME := MacTools
APP_PRODUCT_NAME ?= MacTools Dev
REMOTE_URL ?= git@github.com:owner/MacTools.git
PLACEHOLDER_REMOTE_URL := git@github.com:owner/MacTools.git
PROJECT_FILE := $(PROJECT_NAME).xcodeproj
WORKSPACE_FILE := $(PROJECT_NAME).xcworkspace
DERIVED_DATA := build/DerivedData
# Keep unsigned XCTest host bundles out of the signed local app build.
TEST_DERIVED_DATA ?= $(DERIVED_DATA)Tests
APP_PATH := $(DERIVED_DATA)/Build/Products/Debug/$(APP_PRODUCT_NAME).app
APP_EXECUTABLE := $(APP_PATH)/Contents/MacOS/$(APP_PRODUCT_NAME)
ALLOW_MULTIPLE_DEBUG_APPS ?= 0
LOCAL_APP_INSTALL_DIR ?= $(HOME)/Applications
INSTALLED_APP_PATH := $(LOCAL_APP_INSTALL_DIR)/$(APP_PRODUCT_NAME).app
INSTALLED_APP_EXECUTABLE := $(INSTALLED_APP_PATH)/Contents/MacOS/$(APP_PRODUCT_NAME)
HOST_ARCH := $(shell uname -m)
BUILD_DESTINATION := platform=macOS,arch=$(HOST_ARCH)
XCODEBUILD ?= $(abspath scripts/xcodebuild-filtered.sh)
LOCAL_PLUGIN_SOURCE_DIR ?= Plugins
PLUGIN_PROJECT_SOURCE_DIR ?= Plugins
GENERATED_PLUGIN_PROJECT_CONFIG := Configs/GeneratedPlugins.yml
LOCAL_PLUGIN_BUILD_DIR ?= build/LocalPlugins
LOCAL_PLUGIN_CATALOG := $(LOCAL_PLUGIN_BUILD_DIR)/catalog.dev.json
DEBUG_BUILD_PRODUCTS_DIR := $(DERIVED_DATA)/Build/Products/Debug
DEBUG_CLI_PATH := $(DEBUG_BUILD_PRODUCTS_DIR)/mactools
DEBUG_PLUGIN_INSTALL_DIR ?= $(HOME)/Library/Application Support/MacTools Dev/Plugins/Installed
LOCAL_ICON_GALLERY_DIR ?= build/LocalIconGallery
LOCAL_ICON_GALLERY_CATALOG := $(LOCAL_ICON_GALLERY_DIR)/catalog.dev.json
PLUGIN_RELEASE_REPO ?= ggbond268/MacTools
PLUGIN_RELEASE_TAG ?= plugins-local
PLUGIN_RELEASE_BUILD_DIR ?= build/PluginRelease/Build
PLUGIN_RELEASE_DIST_DIR ?= build/PluginRelease
PLUGIN_RELEASE_ASSETS_DIR ?= $(PLUGIN_RELEASE_DIST_DIR)/Assets
PLUGIN_RELEASE_CATALOG ?= $(PLUGIN_RELEASE_DIST_DIR)/catalog.json
PLUGIN_KIT_VERSION ?= $(shell $(PYTHON3) -c 'import glob,json; versions={json.load(open(path, encoding="utf-8"))["pluginKitVersion"] for path in glob.glob("Plugins/*/plugin.json")}; print(next(iter(versions)) if len(versions) == 1 else "")')
PLUGIN_RELEASE_SIGNED_CATALOG ?= $(if $(filter 5,$(PLUGIN_KIT_VERSION)),docs/plugins/v5/schema3/catalog.json,$(if $(filter 2,$(PLUGIN_KIT_VERSION)),docs/plugins/catalog.json,docs/plugins/v$(PLUGIN_KIT_VERSION)/catalog.json))
PLUGIN_CATALOG_MINIMUM_HOST_VERSION ?= 1.2.1
PLUGIN_RELEASE_BASE_URL ?= https://github.com/$(PLUGIN_RELEASE_REPO)/releases/download/$(PLUGIN_RELEASE_TAG)
E2E_SCRIPT := scripts/e2e/mactools-e2e.sh
E2E_SESSION ?=
E2E_DURATION ?= 90
E2E_PACK ?=
TEST_FILTER ?=

.PHONY: setup validate-local-debug-config generate-plugin-config generate build build-cli validate-changelog validate-generated-plugin-data validate-localization script-tests test ci sync-debug-plugins build-plugin build-plugins generate-icon-gallery package-plugins-release stop-debug-app install-debug-app run run-open e2e-preflight e2e-prepare e2e-upgrade e2e-reseed e2e-resume e2e-rebuild e2e-audit e2e-scenarios e2e-record e2e-record-pack e2e-verify-code e2e-collect e2e-restore e2e-self-test clean release release-local

setup:
	@if [ ! -f LocalConfig.xcconfig ]; then cp LocalConfig.sample.xcconfig LocalConfig.xcconfig; fi
	@if ! git rev-parse --git-dir >/dev/null 2>&1; then git init; fi
	@git branch -M main
	@if [ "$(REMOTE_URL)" = "$(PLACEHOLDER_REMOTE_URL)" ]; then echo "Skipping origin remote setup. Pass REMOTE_URL=git@github.com:<owner>/MacTools.git to make setup when ready."; \
	else \
		if git remote get-url origin >/dev/null 2>&1; then git remote set-url origin $(REMOTE_URL); else git remote add origin $(REMOTE_URL); fi; \
	fi

validate-local-debug-config:
	@./scripts/validate-local-debug-config.sh LocalConfig.xcconfig

generate-plugin-config:
	@./scripts/plugins/generate-plugin-project-config.rb \
		--source-dir "$(PLUGIN_PROJECT_SOURCE_DIR)" \
		--output "$(GENERATED_PLUGIN_PROJECT_CONFIG)"

generate: generate-plugin-config
	@xcodegen generate

build: validate-local-debug-config generate
	@echo "Building Debug app and plugins..."
	@mkdir -p build
	@touch build/.metadata_never_index
	@$(XCODEBUILD) -project $(PROJECT_FILE) -scheme $(PROJECT_NAME) -configuration Debug -destination "$(BUILD_DESTINATION)" -derivedDataPath $(DERIVED_DATA) build -quiet
	@LSREGISTER=/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister; \
	if [[ -x "$$LSREGISTER" ]]; then \
		"$$LSREGISTER" -u "$(CURDIR)/$(APP_PATH)" >/dev/null 2>&1 || true; \
	fi

build-cli: validate-local-debug-config generate
	@echo "Building standalone Debug CLI..."
	@mkdir -p build
	@touch build/.metadata_never_index
	@$(XCODEBUILD) -project $(PROJECT_FILE) -scheme MacToolsCLI -configuration Debug -destination "$(BUILD_DESTINATION)" -derivedDataPath $(DERIVED_DATA) build -quiet
	@echo "CLI ready: $(abspath $(DEBUG_CLI_PATH))"

validate-changelog:
	@$(PYTHON3) scripts/changelog.py validate

validate-generated-plugin-data:
	@$(PYTHON3) scripts/plugins/generate_website_plugin_data.py --check

validate-localization:
	@$(PYTHON3) scripts/audit-localization.py --require-complete

script-tests: validate-changelog validate-generated-plugin-data validate-localization
	@$(PYTHON3) -m unittest discover -s scripts/tests -p 'test_*.py'

test: generate
	@$(XCODEBUILD) \
		-project $(PROJECT_FILE) \
		-scheme $(PROJECT_NAME) \
		-configuration Debug \
		-destination "$(BUILD_DESTINATION)" \
		-derivedDataPath $(TEST_DERIVED_DATA) \
		CODE_SIGNING_ALLOWED=NO \
		CODE_SIGNING_REQUIRED=NO \
		CODE_SIGN_IDENTITY= \
		-parallel-testing-enabled NO \
		-test-timeouts-enabled YES \
		-default-test-execution-time-allowance 120 \
		-maximum-test-execution-time-allowance 120 \
		$(foreach selector,$(TEST_FILTER),-only-testing:MacToolsTests/$(selector)) \
		test \
		-quiet

ci: override TEST_FILTER :=
ci: script-tests test
	@./scripts/plugins/verify-plugin-kit-v7-binary-compatibility.sh "$(abspath $(TEST_DERIVED_DATA)/Build/Products/Debug)"

sync-debug-plugins: build
	@if [ -n "$(PLUGIN)" ]; then \
		PLUGIN_ARGS=(--plugin "$(PLUGIN)"); \
	else \
		PLUGIN_ARGS=(); \
	fi; \
	./scripts/plugins/sync-debug-plugins.sh \
		--source-dir "$(LOCAL_PLUGIN_SOURCE_DIR)" \
		--products-dir "$(DEBUG_BUILD_PRODUCTS_DIR)" \
		--output-dir "$(LOCAL_PLUGIN_BUILD_DIR)" \
		--install-dir "$(DEBUG_PLUGIN_INSTALL_DIR)" \
		$${PLUGIN_ARGS[@]}

build-plugin: generate
	@if [ -n "$(PLUGIN)" ]; then \
		PLUGIN_ARGS=(--plugin "$(PLUGIN)"); \
	else \
		PLUGIN_ARGS=(); \
	fi; \
	./scripts/plugins/build-local-plugins.sh \
		--source-dir "$(LOCAL_PLUGIN_SOURCE_DIR)" \
		--output-dir "$(LOCAL_PLUGIN_BUILD_DIR)" \
		--destination "$(BUILD_DESTINATION)" \
		--xcodebuild "$(XCODEBUILD)" \
		$${PLUGIN_ARGS[@]}

build-plugins: build-plugin

generate-icon-gallery:
	@$(PYTHON3) ./scripts/icons/generate-local-icon-gallery.py \
		--output-dir "$(LOCAL_ICON_GALLERY_DIR)"

package-plugins-release: generate
	@case " 1 2 3 4 " in \
		*" $(PLUGIN_KIT_VERSION) "*) \
			echo "PluginKit versions below 5 use immutable legacy catalogs and cannot be released by the schema-3 tooling." >&2; \
			exit 1; \
			;; \
	esac
	@./scripts/plugins/build-plugin-release-assets.sh \
		--source-dir "$(LOCAL_PLUGIN_SOURCE_DIR)" \
		--build-dir "$(PLUGIN_RELEASE_BUILD_DIR)" \
		--dist-dir "$(PLUGIN_RELEASE_DIST_DIR)" \
		--assets-dir "$(PLUGIN_RELEASE_ASSETS_DIR)" \
		--base-url "$(PLUGIN_RELEASE_BASE_URL)" \
		--catalog-output "$(PLUGIN_RELEASE_CATALOG)" \
		--signed-catalog-output "$(PLUGIN_RELEASE_SIGNED_CATALOG)" \
		--minimum-host-version "$(PLUGIN_CATALOG_MINIMUM_HOST_VERSION)" \
		--sign-identity "$(PLUGIN_CODE_SIGN_IDENTITY)" \
		--destination "$(BUILD_DESTINATION)" \
		--xcodebuild "$(XCODEBUILD)" \
		--release-notes-url "https://github.com/$(PLUGIN_RELEASE_REPO)/releases/tag/$(PLUGIN_RELEASE_TAG)"

# The default development flow is singleton across installed, worktree,
# sanitizer, and other DerivedData copies. Use ALLOW_MULTIPLE_DEBUG_APPS=1
# only when a deliberately isolated bundle needs to coexist.
stop-debug-app:
	@if [[ "$(ALLOW_MULTIPLE_DEBUG_APPS)" == "1" ]]; then exit 0; fi
	@PIDS=($$(/usr/bin/pgrep -f -x \
		".*/$(APP_PRODUCT_NAME)[.]app/Contents/MacOS/$(APP_PRODUCT_NAME)( .*)?" \
		2>/dev/null || true)); \
	if (( $${#PIDS[@]} == 0 )); then \
		exit 0; \
	fi; \
	echo "Stopping existing $(APP_PRODUCT_NAME) instance(s)..."; \
	/bin/kill -TERM $${PIDS[@]} >/dev/null 2>&1 || true; \
	for attempt in {1..50}; do \
		REMAINING=(); \
		for PID in $${PIDS[@]}; do \
			/bin/kill -0 "$$PID" >/dev/null 2>&1 && REMAINING+=("$$PID"); \
		done; \
		if (( $${#REMAINING[@]} == 0 )); then \
			exit 0; \
		fi; \
		/bin/sleep 0.1; \
	done; \
	echo "$(APP_PRODUCT_NAME) is still running; not launching another instance." >&2; \
	exit 1

install-debug-app: sync-debug-plugins generate-icon-gallery
	@EXPECTED_BUNDLE_IDENTIFIER="$$(./scripts/validate-local-debug-config.sh LocalConfig.xcconfig --print-bundle-identifier)"; \
	./scripts/install-debug-app.sh \
		"$(CURDIR)/$(APP_PATH)" \
		"$(INSTALLED_APP_PATH)" \
		"$$EXPECTED_BUNDLE_IDENTIFIER"

run: stop-debug-app install-debug-app
	@CATALOG_URL="$(MACTOOLS_PLUGIN_CATALOG_URL)"; \
	ICON_CATALOG_URL="$(MACTOOLS_ICON_CATALOG_URL)"; \
	if [ -z "$$CATALOG_URL" ] && [ -f "$(LOCAL_PLUGIN_CATALOG)" ]; then \
		CATALOG_URL="file://$(abspath $(LOCAL_PLUGIN_CATALOG))"; \
	fi; \
	if [ -z "$$ICON_CATALOG_URL" ] && [ -f "$(LOCAL_ICON_GALLERY_CATALOG)" ]; then \
		ICON_CATALOG_URL="file://$(abspath $(LOCAL_ICON_GALLERY_CATALOG))"; \
	fi; \
	if [ -n "$$CATALOG_URL" ]; then \
		echo "Using plugin catalog: $$CATALOG_URL"; \
	fi; \
	if [ -n "$$ICON_CATALOG_URL" ]; then \
		echo "Using icon catalog: $$ICON_CATALOG_URL"; \
	fi; \
	RUN_ENV=(); \
	if [[ "$(ALLOW_MULTIPLE_DEBUG_APPS)" == "1" ]]; then \
		RUN_ENV+=("MACTOOLS_ALLOW_MULTIPLE_DEBUG_INSTANCES=1"); \
	fi; \
	if [ -n "$$CATALOG_URL" ]; then \
		RUN_ENV+=("MACTOOLS_PLUGIN_CATALOG_URL=$$CATALOG_URL"); \
	fi; \
	if [ -n "$$ICON_CATALOG_URL" ]; then \
		RUN_ENV+=("MACTOOLS_ICON_CATALOG_URL=$$ICON_CATALOG_URL"); \
	fi; \
	stop_app() { \
		PIDS=($$(/usr/bin/pgrep -f -x "$(INSTALLED_APP_EXECUTABLE)" 2>/dev/null || true)); \
		if (( $${#PIDS[@]} > 0 )); then \
			echo "Stopping $(APP_PRODUCT_NAME)..."; \
			/bin/kill -TERM $${PIDS[@]} >/dev/null 2>&1 || true; \
		fi; \
	}; \
	trap 'stop_app; exit 130' INT TERM; \
	if [ -z "$$CATALOG_URL" ] && [ -z "$$ICON_CATALOG_URL" ]; then \
		echo "No local plugin catalog found. Run 'make build-plugin' or set MACTOOLS_PLUGIN_CATALOG_URL."; \
	fi; \
	OPEN_ENV=(); \
	for ENVIRONMENT_VARIABLE in "$${RUN_ENV[@]}"; do \
		OPEN_ENV+=(--env "$$ENVIRONMENT_VARIABLE"); \
	done; \
	open -n "$${OPEN_ENV[@]}" -W "$(INSTALLED_APP_PATH)"

run-open: stop-debug-app install-debug-app
	@open -n -W "$(INSTALLED_APP_PATH)"

e2e-preflight:
	@$(E2E_SCRIPT) preflight

e2e-prepare:
	@$(E2E_SCRIPT) prepare

e2e-upgrade:
	@test -n "$(E2E_SESSION)" || (echo "Pass E2E_SESSION=/absolute/path/to/session"; exit 1)
	@$(E2E_SCRIPT) upgrade "$(E2E_SESSION)"

e2e-reseed:
	@test -n "$(E2E_SESSION)" || (echo "Pass E2E_SESSION=/absolute/path/to/session"; exit 1)
	@$(E2E_SCRIPT) reseed "$(E2E_SESSION)"

e2e-resume:
	@test -n "$(E2E_SESSION)" || (echo "Pass E2E_SESSION=/absolute/path/to/session"; exit 1)
	@$(E2E_SCRIPT) resume "$(E2E_SESSION)"

e2e-rebuild:
	@test -n "$(E2E_SESSION)" || (echo "Pass E2E_SESSION=/absolute/path/to/session"; exit 1)
	@$(E2E_SCRIPT) rebuild "$(E2E_SESSION)"

e2e-audit:
	@test -n "$(E2E_SESSION)" || (echo "Pass E2E_SESSION=/absolute/path/to/session"; exit 1)
	@$(E2E_SCRIPT) audit "$(E2E_SESSION)"

e2e-scenarios:
	@$(E2E_SCRIPT) scenarios "$(E2E_PACK)"

e2e-record:
	@test -n "$(E2E_SESSION)" || (echo "Pass E2E_SESSION=/absolute/path/to/session"; exit 1)
	@$(E2E_SCRIPT) record "$(E2E_SESSION)" "$(E2E_DURATION)"

e2e-record-pack:
	@test -n "$(E2E_SESSION)" || (echo "Pass E2E_SESSION=/absolute/path/to/session"; exit 1)
	@test -n "$(E2E_PACK)" || (echo "Pass E2E_PACK=<scenario-pack-id>"; exit 1)
	@$(E2E_SCRIPT) record-pack "$(E2E_SESSION)" "$(E2E_PACK)" "$(E2E_DURATION)"

e2e-verify-code:
	@test -n "$(E2E_SESSION)" || (echo "Pass E2E_SESSION=/absolute/path/to/session"; exit 1)
	@$(E2E_SCRIPT) verify-code "$(E2E_SESSION)"

e2e-collect:
	@test -n "$(E2E_SESSION)" || (echo "Pass E2E_SESSION=/absolute/path/to/session"; exit 1)
	@$(E2E_SCRIPT) collect "$(E2E_SESSION)"

e2e-restore:
	@test -n "$(E2E_SESSION)" || (echo "Pass E2E_SESSION=/absolute/path/to/session"; exit 1)
	@$(E2E_SCRIPT) restore "$(E2E_SESSION)"

e2e-self-test:
	@$(E2E_SCRIPT) self-test

clean:
	@rm -rf build $(PROJECT_FILE) $(WORKSPACE_FILE) "$(GENERATED_PLUGIN_PROJECT_CONFIG)"

release:
	@./scripts/release.py $(ARGS)

release-local:
	@./scripts/release-local.sh $(ARGS)
