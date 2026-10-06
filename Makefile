APP := AppRec
DERIVED := build
PRODUCTS := $(DERIVED)/Build/Products
XCODEBUILD := xcodebuild -quiet -project $(APP).xcodeproj -scheme $(APP) -derivedDataPath $(DERIVED) -destination 'platform=macOS,arch=$(shell uname -m)'

.PHONY: build project release run install clean

build: project
	$(XCODEBUILD) -configuration Debug build

project:
	xcodegen generate --quiet

release: project
	$(XCODEBUILD) -configuration Release build

run: build
	-pkill -x $(APP) && sleep 1
	open $(PRODUCTS)/Debug/$(APP).app

install: release
	-pkill -x $(APP) && sleep 1
	rm -rf /Applications/$(APP).app
	cp -R $(PRODUCTS)/Release/$(APP).app /Applications/
	open /Applications/$(APP).app

clean:
	rm -rf $(DERIVED)
