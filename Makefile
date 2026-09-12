# gi-gtk-declarative -- build the library, the examples, and the tests.
#
# Everything here assumes you are inside `nix develop`, which supplies
# GHC with the gi-gtk 4 bindings and the GTK libraries they load.
#
# GHC is called directly rather than through cabal, because the dev
# shell already has every dependency and no package it does not have.

BUILD := .build

LIB      := gi-gtk-declarative/src
APP      := gi-gtk-declarative-app-simple/src
TEST     := gi-gtk-declarative/test
APPTEST  := gi-gtk-declarative-app-simple/test
EXAMPLES := examples

# The cabal files say Haskell2010, so the direct GHC calls say it too,
# rather than building against the newer default and finding out later.
WARNINGS := -Wall -XHaskell2010

# Two packages in the dev shell hold a module called GI.Gtk: gi-gtk,
# which is the one the cabal files name, and gi-gtk4, a copy of it under
# another name that comes along as a dependency. Hiding the copy is what
# makes an import of GI.Gtk unambiguous when GHC is called directly.
# Cabal does not need this, because it names every package it passes.
PACKAGES := -hide-package gi-gtk4 -hide-package gi-gdk4

# Settings for GHC's own runtime, applied to every compiler call below.
#
# -M caps the heap. A compile that runs away then dies with a heap
# overflow message, instead of growing until the kernel kills something
# on the machine to make room. The heaviest target here peaks at about
# 360 MiB, so 4 GiB is a ceiling no honest build reaches.
#
# -A64m gives the collector a larger nursery, which cuts its work on a
# build of this size.
#
# Pass the same settings to a compiler this file does not call, such as
# cabal's, with GHCRTS=-M4g in the environment.
GHC_RTS := +RTS -M4g -A64m -RTS

SOURCES := $(shell find $(LIB) $(APP) -name '*.hs')

# A nested X server, which is all a test needs: the tests drive the
# widgets from code and read them back, so nothing has to be on screen,
# but GTK still refuses to start without a display.
XVFB := xvfb-run -s "-screen 0 1280x1024x24"

.PHONY: all build examples check check-lib check-app check-input clean

# One compiler at a time. Each call below loads the whole gi-gtk
# interface, so `make -j` multiplies the memory rather than dividing the
# time.
.NOTPARALLEL:

all: build

# Typecheck the library and app-simple without producing code, which is
# the fast gate while working.
build:
	@mkdir -p $(BUILD)
	ghc -fno-code -i$(LIB) -i$(APP) $(WARNINGS) $(PACKAGES) \
	  -outputdir $(BUILD)/objects \
	  $(LIB)/GI/Gtk/Declarative.hs $(APP)/GI/Gtk/Declarative/App/Simple.hs \
	  $(GHC_RTS)

# The examples are part of the build: they are what says the library is
# usable, and a GTK 4 port that does not compile against them is not done.
examples:
	@mkdir -p $(BUILD)
	ghc -i$(LIB) -i$(APP) -i$(EXAMPLES) $(WARNINGS) $(PACKAGES) -threaded \
	  -outputdir $(BUILD)/example-objects -o $(BUILD)/example \
	  $(EXAMPLES)/Main.hs $(GHC_RTS)

check: check-lib check-app check-input

# The library's own suite: patching, custom widgets, every container,
# and the menus.
check-lib: $(BUILD)/tests
	$(XVFB) $(BUILD)/tests

$(BUILD)/tests: $(SOURCES) $(wildcard $(TEST)/*.hs) $(wildcard $(TEST)/GI/Gtk/Declarative/*.hs)
	@mkdir -p $(BUILD)
	ghc -i$(LIB) -i$(TEST) $(WARNINGS) $(PACKAGES) -threaded \
	  -outputdir $(BUILD)/test-objects -o $@ $(TEST)/Main.hs $(GHC_RTS)

# The application loop: inputs, exits, and exceptions.
check-app: $(BUILD)/app-tests
	$(XVFB) $(BUILD)/app-tests

$(BUILD)/app-tests: $(SOURCES) $(wildcard $(APPTEST)/*.hs)
	@mkdir -p $(BUILD)
	ghc -i$(LIB) -i$(APP) -i$(APPTEST) $(WARNINGS) $(PACKAGES) -threaded \
	  -outputdir $(BUILD)/app-test-objects -o $@ $(APPTEST)/Main.hs $(GHC_RTS)

# Keys and clicks, driven with real X11 input.
#
# GTK 4 reports these through event controllers, and nothing can make
# one happen from code, so this test presses a key and clicks a button
# for real and reads back what the application received.
check-input: $(BUILD)/input-test
	$(XVFB) tests/gui-input.sh $(BUILD)/input-test

$(BUILD)/input-test: $(SOURCES) $(TEST)/InputApp.hs
	@mkdir -p $(BUILD)
	ghc -i$(LIB) -i$(APP) -i$(TEST) $(WARNINGS) $(PACKAGES) -threaded -main-is InputApp.main \
	  -outputdir $(BUILD)/input-test-objects -o $@ $(TEST)/InputApp.hs $(GHC_RTS)

clean:
	rm -rf $(BUILD)
