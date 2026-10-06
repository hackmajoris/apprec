APP := AppRec
DERIVED := build
PRODUCTS := $(DERIVED)/Build/Products
XCODEBUILD := xcodebuild -quiet -project $(APP).xcodeproj -scheme $(APP) -derivedDataPath $(DERIVED) -destination 'platform=macOS,arch=$(shell uname -m)'

.PHONY: help build project release run install dist clean site
.DEFAULT_GOAL := help

SITE_PORT := 8000

help: ## List available commands
	@awk 'BEGIN {FS = ":.*## "} /^[a-z]+:.*## / {printf "  \033[1m%-9s\033[0m %s\n", $$1, $$2}' $(MAKEFILE_LIST)

build: project ## Build a debug version
	$(XCODEBUILD) -configuration Debug build

project: ## Generate the Xcode project from project.yml
	xcodegen generate --quiet

release: project ## Build a release version
	$(XCODEBUILD) -configuration Release build

run: build ## Build and launch the debug app
	-pkill -x $(APP) && sleep 1
	open $(PRODUCTS)/Debug/$(APP).app

install: release ## Build a release and install it to /Applications
	-pkill -x $(APP) && sleep 1
	rm -rf /Applications/$(APP).app
	cp -R $(PRODUCTS)/Release/$(APP).app /Applications/
	open /Applications/$(APP).app

dist: release ## Zip the release app to build/AppRec.zip for a GitHub release
	rm -f $(DERIVED)/$(APP).zip
	ditto -c -k --keepParent $(PRODUCTS)/Release/$(APP).app $(DERIVED)/$(APP).zip
	@shasum -a 256 $(DERIVED)/$(APP).zip

clean: ## Remove build output
	rm -rf $(DERIVED)

site: ## Serve the website from docs/ at http://localhost:8000
	@echo "Serving docs/ at http://localhost:$(SITE_PORT) (Ctrl-C to stop)"
	@(sleep 1 && open http://localhost:$(SITE_PORT)) &
	python3 -m http.server $(SITE_PORT) --bind 127.0.0.1 --directory docs
