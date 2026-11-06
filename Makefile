# SPDX-License-Identifier: GPL-3.0-only
# Apricot SSTV for macOS (arm64) -- build the decoder + the test-signal tools.
#
#   make            build/apricot-sstv
#   make tools      build/sstv_tx (makes test WAVs from a PPM)
#   make test       build everything and run the decode self-test
#   make install    copy the binary to $(PREFIX)/bin (PREFIX=/usr/local)
#
# The decoder core (src/sstv_dsp.c) is the iPod nano's, unmodified.
CC         ?= clang
CFLAGS     ?= -std=c11 -O2 -g -Wall -Wextra -Wno-unused-parameter -D_DEFAULT_SOURCE
OBJCFLAGS  ?= -fobjc-arc -O2 -g -Wall -Wextra -Wno-unused-parameter
LDFLAGS    ?=
FW = -framework Foundation -framework AppKit -framework AVFoundation -framework AudioToolbox \
     -framework AudioUnit -framework CoreAudio -framework CoreFoundation -framework CoreGraphics \
     -framework ImageIO

BUILD := build
BIN   := $(BUILD)/apricot-sstv

CORE_OBJS := $(BUILD)/sstv_dsp.o $(BUILD)/image_out.o $(BUILD)/audio_in.o
OBJS      := $(CORE_OBJS) $(BUILD)/main.o
HDRS      := $(wildcard src/*.h)

all: $(BIN) tools app

$(BUILD):
	@mkdir -p $(BUILD)

$(BUILD)/%.o: src/%.c $(HDRS) | $(BUILD)
	$(CC) $(CFLAGS) -c -o $@ $<

$(BUILD)/main.o: src/main.m $(HDRS) | $(BUILD)
	$(CC) $(OBJCFLAGS) -c -o $@ $<

$(BIN): $(OBJS)
	$(CC) $(CFLAGS) $(LDFLAGS) -o $@ $(OBJS) $(FW) -lm

# A minimal .app: its own TCC identity, so the microphone prompt names the app
# (and survives rebuilds). Double-click it to go straight to live decoding.
APP := build/Apricot SSTV.app
app: $(APP)
$(APP): $(BIN) Info.plist
	@mkdir -p "$(APP)/Contents/MacOS"
	cp $(BIN) "$(APP)/Contents/MacOS/apricot-sstv"
	cp Info.plist "$(APP)/Contents/Info.plist"
	codesign --force --sign - "$(APP)" 2>/dev/null || true
	@echo "built: $(APP)"

# ---- test-signal tools (from the upstream repo's host/ directory) ----
TX_DEPS := tools/util.h tools/enc.h
tools: $(BUILD)/sstv_tx

$(BUILD)/sstv_tx: tools/sstv_tx.c tools/enc.c tools/util.c $(TX_DEPS) | $(BUILD)
	$(CC) $(CFLAGS) -o $@ tools/sstv_tx.c tools/enc.c tools/util.c -lm

test: $(BIN) tools
	./test/run_tests.sh

install: $(BIN)
	install -d $(PREFIX)/bin
	install -m 755 $(BIN) $(PREFIX)/bin/apricot-sstv

clean:
	rm -rf $(BUILD) test/out

PREFIX ?= /usr/local
.PHONY: all tools app test install clean
