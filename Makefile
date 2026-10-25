APP      := build/FastText.app
BIN      := $(APP)/Contents/MacOS/FastText
ARCH     ?= $(shell uname -m)
CFLAGS   := -O2 -flto -fobjc-arc -fno-objc-exceptions -arch $(ARCH) -mmacosx-version-min=14.0 -Wall -Wextra
LDFLAGS  := -framework AppKit -Wl,-dead_strip

all: $(BIN)

$(BIN): src/main.m Info.plist resources/AppIcon.icns
	@mkdir -p $(APP)/Contents/MacOS $(APP)/Contents/Resources
	cp resources/AppIcon.icns $(APP)/Contents/Resources/AppIcon.icns
	clang $(CFLAGS) $(LDFLAGS) src/main.m -o $@
	strip -x $@
	cp Info.plist $(APP)/Contents/Info.plist
	codesign --force -s - $(APP)

# Regenerates the committed icon (only needed when tools/makeicon.m changes).
icon:
	@mkdir -p build/tools
	clang -fobjc-arc -framework AppKit tools/makeicon.m -o build/tools/makeicon
	rm -rf build/AppIcon.iconset
	build/tools/makeicon build/AppIcon.iconset
	iconutil -c icns build/AppIcon.iconset -o resources/AppIcon.icns

deploy: all
	scripts/deploy.sh

# Prints exec -> first-window-drawn time in ms (run a few times; first run is cold).
bench:
	@mkdir -p build/bench
	clang $(CFLAGS) -DFT_BENCH $(LDFLAGS) src/main.m -o build/bench/FastTextBench
	@for i in 1 2 3 4 5 6; do build/bench/FastTextBench; done

clean:
	rm -rf build

.PHONY: all icon deploy bench clean
