# SPDX-License-Identifier: GPL-3.0-only
# SSTV Tool for macOS (arm64) -- receiver + transmitter, plus the test-signal
# tools.
#
#   make            build/sstv-tool + build/SSTV Tool.app
#   make test       decode self-test (14 modes, impaired signals, continuous rx)
#   make test-pause pause / cancel on a real-time replay (~90 s)
#   make install    copy the binary to $(PREFIX)/bin (PREFIX=/usr/local)
#
# The decoder core (src/sstv_dsp.c) is the iPod nano's, unmodified; the encoder
# is the host encoder from the same upstream repo (tools/enc.c).
CC         ?= clang
CFLAGS     ?= -std=c11 -O2 -g -Wall -Wextra -Wno-unused-parameter -D_DEFAULT_SOURCE
OBJCFLAGS  ?= -fobjc-arc -O2 -g -Wall -Wextra -Wno-unused-parameter
LDFLAGS    ?=
FW = -framework Foundation -framework AppKit -framework AVFoundation -framework AudioToolbox \
     -framework AudioUnit -framework CoreAudio -framework CoreFoundation -framework CoreGraphics \
     -framework CoreText -framework ImageIO

BUILD := build
BIN   := $(BUILD)/sstv-tool
INC   := -Isrc -Itools

CORE_OBJS := $(BUILD)/sstv_dsp.o $(BUILD)/image_out.o $(BUILD)/audio_in.o
ENC_OBJS  := $(BUILD)/encode.o $(BUILD)/enc.o $(BUILD)/util.o
OBJS      := $(CORE_OBJS) $(ENC_OBJS) $(BUILD)/main.o
HDRS      := $(wildcard src/*.h) $(wildcard tools/*.h)

all: $(BIN) tools app

$(BUILD):
	@mkdir -p $(BUILD)

$(BUILD)/%.o: src/%.c $(HDRS) | $(BUILD)
	$(CC) $(CFLAGS) $(INC) -c -o $@ $<

$(BUILD)/%.o: src/%.m $(HDRS) | $(BUILD)
	$(CC) $(OBJCFLAGS) $(INC) -c -o $@ $<

$(BUILD)/enc.o: tools/enc.c tools/enc.h | $(BUILD)
	$(CC) $(CFLAGS) -Itools -c -o $@ $<

$(BUILD)/util.o: tools/util.c tools/util.h | $(BUILD)
	$(CC) $(CFLAGS) -Itools -c -o $@ $<

$(BIN): $(OBJS)
	$(CC) $(CFLAGS) $(LDFLAGS) -o $@ $(OBJS) $(FW) -lm

# ---- test-signal tool: PPM in, WAV out (used by the self-tests) ----
tools: $(BUILD)/sstv_tx
$(BUILD)/sstv_tx: tools/sstv_tx.c tools/enc.c tools/util.c $(HDRS) | $(BUILD)
	$(CC) $(CFLAGS) -Itools -o $@ tools/sstv_tx.c tools/enc.c tools/util.c -lm

# ---- the .app: its own TCC identity, so the microphone prompt names the app ----
ICON     := assets/AppIcon.icns
ICON_SRC := assets/AppIcon-1024.png
APP      := build/SSTV Tool.app

$(BUILD)/makeicon: tools/makeicon.c | $(BUILD)
	$(CC) $(CFLAGS) -o $@ $< -framework CoreGraphics -framework ImageIO -framework CoreFoundation

# regenerate the icon art from a picture: make icon SRC=some.png
icon: $(BUILD)/makeicon
	$(BUILD)/makeicon $(or $(SRC),test/out/Robot36-1.png) $(ICON_SRC) 1024 22
	$(MAKE) $(ICON)

$(ICON): $(ICON_SRC)
	rm -rf $(BUILD)/AppIcon.iconset && mkdir -p $(BUILD)/AppIcon.iconset
	@for s in 16 32 128 256 512; do \
	  sips -z $$s $$s $(ICON_SRC) --out $(BUILD)/AppIcon.iconset/icon_$${s}x$${s}.png >/dev/null; \
	  d=$$((s * 2)); \
	  sips -z $$d $$d $(ICON_SRC) --out $(BUILD)/AppIcon.iconset/icon_$${s}x$${s}@2x.png >/dev/null; \
	done
	iconutil -c icns $(BUILD)/AppIcon.iconset -o $@

app: $(APP)
$(APP): $(BIN) Info.plist $(ICON)
	@mkdir -p "$(APP)/Contents/MacOS" "$(APP)/Contents/Resources"
	cp $(BIN) "$(APP)/Contents/MacOS/sstv-tool"
	cp Info.plist "$(APP)/Contents/Info.plist"
	cp $(ICON) "$(APP)/Contents/Resources/AppIcon.icns"
	codesign --force --sign - "$(APP)" 2>/dev/null || true
	@echo "built: $(APP)"

test: $(BIN) tools
	./test/run_tests.sh

# pause / cancel on a real-time replay (~90 s, wall-clock on purpose)
test-pause: $(BIN)
	./test/pause_test.sh

install: $(BIN)
	install -d $(PREFIX)/bin
	install -m 755 $(BIN) $(PREFIX)/bin/sstv-tool

clean:
	rm -rf $(BUILD) test/out

PREFIX ?= /usr/local
.PHONY: all tools app icon test test-pause install clean
