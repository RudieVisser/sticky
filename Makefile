APP_NAME    := Sticky
BUILD_DIR   := build
APP_BUNDLE  := $(BUILD_DIR)/$(APP_NAME).app
CONFIG      := release
BIN         := $(shell swift build -c $(CONFIG) --show-bin-path 2>/dev/null)/$(APP_NAME)

.PHONY: build bundle run clean

build:
	swift build -c $(CONFIG)

bundle: build
	rm -rf $(APP_BUNDLE)
	mkdir -p $(APP_BUNDLE)/Contents/MacOS
	mkdir -p $(APP_BUNDLE)/Contents/Resources
	cp $(BIN) $(APP_BUNDLE)/Contents/MacOS/$(APP_NAME)
	cp Resources/Info.plist $(APP_BUNDLE)/Contents/Info.plist
	codesign --force --deep -s - $(APP_BUNDLE)
	@echo "Done: $(APP_BUNDLE)"

run: bundle
	open $(APP_BUNDLE)

clean:
	rm -rf $(BUILD_DIR) .build
