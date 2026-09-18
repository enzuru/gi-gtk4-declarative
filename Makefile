# gi-gtk4-declarative -- build the library, the examples, and the tests.
#
# Everything here assumes you are inside `nix develop`, which supplies
# GHC with the gi-gtk 4 bindings and the GTK libraries they load.
#
# GHC is called directly rather than through cabal, because the dev
# shell already has every dependency and no package it does not have.

BUILD := .build

LIB      := gi-gtk4-declarative/src
APP      := gi-gtk4-declarative-app-simple/src
TEST     := gi-gtk4-declarative/test
BENCH    := gi-gtk4-declarative/bench
APPTEST  := gi-gtk4-declarative-app-simple/test
ADWAITA  := gi-gtk4-declarative-adwaita/src
ADWTEST  := gi-gtk4-declarative-adwaita/test
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

SOURCES := $(shell find $(LIB) $(APP) $(ADWAITA) -name '*.hs')

# A nested X server, which is all a test needs: the tests drive the
# widgets from code and read them back, so nothing has to be on screen,
# but GTK still refuses to start without a display.
XVFB := xvfb-run -s "-screen 0 1280x1024x24"

# A GtkApplication registers itself on the session bus, and answers
# nothing at all when there is none, so the suite that makes one runs
# under a bus of its own.
DBUS := dbus-run-session --

.PHONY: all build examples check check-lib check-adwaita check-app check-input check-toggle bench coverage docs clean

# One compiler at a time. Each call below loads the whole gi-gtk
# interface, so `make -j` multiplies the memory rather than dividing the
# time.
.NOTPARALLEL:

all: build

# Typecheck the three libraries without producing code, which is the
# fast gate while working.
#
# The model views are named here as well. GHC follows imports, and the
# umbrella module does not re-export them, so they would go unchecked
# until the test binary was built. The libadwaita package is a compiler
# call of its own, because nothing in the other two imports it.
build:
	@mkdir -p $(BUILD)
	ghc -fno-code -i$(LIB) -i$(APP) $(WARNINGS) $(PACKAGES) \
	  -outputdir $(BUILD)/objects \
	  $(LIB)/GI/Gtk/Declarative.hs $(APP)/GI/Gtk/Declarative/App/Simple.hs \
	  $(LIB)/GI/Gtk/Declarative/ModelView/ListView.hs \
	  $(LIB)/GI/Gtk/Declarative/ModelView/ColumnView.hs \
	  $(GHC_RTS)
	ghc -fno-code -i$(LIB) -i$(ADWAITA) $(WARNINGS) $(PACKAGES) \
	  -outputdir $(BUILD)/adwaita-objects \
	  $(ADWAITA)/GI/Gtk/Declarative/Adwaita/Bin.hs \
	  $(ADWAITA)/GI/Gtk/Declarative/Adwaita/HeaderBar.hs \
	  $(ADWAITA)/GI/Gtk/Declarative/Adwaita/References.hs \
	  $(ADWAITA)/GI/Gtk/Declarative/Adwaita/Rows.hs \
	  $(ADWAITA)/GI/Gtk/Declarative/Adwaita/Slots.hs \
	  $(ADWAITA)/GI/Gtk/Declarative/Adwaita/TabView.hs \
	  $(ADWAITA)/GI/Gtk/Declarative/Adwaita/ToggleGroup.hs \
	  $(ADWAITA)/GI/Gtk/Declarative/Adwaita/ToolbarView.hs \
	  $(GHC_RTS)

# The examples are part of the build: they are what says the library is
# usable, and a GTK 4 port that does not compile against them is not done.
examples:
	@mkdir -p $(BUILD)
	ghc -i$(LIB) -i$(APP) -i$(EXAMPLES) $(WARNINGS) $(PACKAGES) -threaded \
	  -outputdir $(BUILD)/example-objects -o $(BUILD)/example \
	  $(EXAMPLES)/Main.hs $(GHC_RTS)

check: check-lib check-adwaita check-app check-input check-toggle

# The library's own suite: patching, custom widgets, every container,
# and the menus.
check-lib: $(BUILD)/tests
	$(XVFB) $(BUILD)/tests

$(BUILD)/tests: $(SOURCES) $(wildcard $(TEST)/*.hs) $(wildcard $(TEST)/GI/Gtk/Declarative/*.hs)
	@mkdir -p $(BUILD)
	ghc -i$(LIB) -i$(TEST) $(WARNINGS) $(PACKAGES) -threaded \
	  -outputdir $(BUILD)/test-objects -o $@ $(TEST)/Main.hs $(GHC_RTS)

# The libadwaita widgets, which are a package of their own because the
# core depends on GTK and on nothing else.
check-adwaita: $(BUILD)/adwaita-tests
	$(XVFB) $(BUILD)/adwaita-tests

$(BUILD)/adwaita-tests: $(SOURCES) $(wildcard $(ADWTEST)/*.hs) $(wildcard $(ADWTEST)/GI/Gtk/Declarative/Adwaita/*.hs)
	@mkdir -p $(BUILD)
	ghc -i$(LIB) -i$(ADWAITA) -i$(ADWTEST) $(WARNINGS) $(PACKAGES) -threaded \
	  -outputdir $(BUILD)/adwaita-test-objects -o $@ $(ADWTEST)/Main.hs $(GHC_RTS)

# The application loop: inputs, exits, and exceptions.
check-app: $(BUILD)/app-tests
	GTK_A11Y=none $(XVFB) $(DBUS) $(BUILD)/app-tests

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

# What the test suites reach, measured with GHC's own coverage.
#
# Three programs, so three reports: hpc adds up the runs of one program
# and not the runs of three, because each call to GHC writes its own
# module hashes. The library's own suite is the number that says most;
# the other two say what their packages reach.
#
# The .tix file lands in the working directory of the program that
# wrote it, which is why the runs happen inside the coverage directory.
#
# Not part of `make check`: it builds everything a second time.
COVERAGE := $(BUILD)/coverage

# The test modules, which are not what is being measured.
NOT_MEASURED := $(shell find $(TEST) $(ADWTEST) $(APPTEST) -name '*.hs' \
  | sed -e 's|.*/test/||' -e 's|/|.|g' -e 's|\.hs$$||' -e 's|^|--exclude=|')

coverage:
	@mkdir -p $(COVERAGE)
	# A .tix file from an earlier run belongs to the programs of that
	# run, and hpc says so rather than adding the two up.
	@rm -f $(COVERAGE)/*.tix
	ghc -fhpc -hpcdir $(COVERAGE)/lib-mix -i$(LIB) -i$(TEST) \
	  $(WARNINGS) $(PACKAGES) -threaded \
	  -outputdir $(COVERAGE)/lib-objects -o $(COVERAGE)/lib-tests \
	  $(TEST)/Main.hs $(GHC_RTS)
	ghc -fhpc -hpcdir $(COVERAGE)/adwaita-mix -i$(LIB) -i$(ADWAITA) -i$(ADWTEST) \
	  $(WARNINGS) $(PACKAGES) -threaded \
	  -outputdir $(COVERAGE)/adwaita-objects -o $(COVERAGE)/adwaita-tests \
	  $(ADWTEST)/Main.hs $(GHC_RTS)
	ghc -fhpc -hpcdir $(COVERAGE)/app-mix -i$(LIB) -i$(APP) -i$(APPTEST) \
	  $(WARNINGS) $(PACKAGES) -threaded \
	  -outputdir $(COVERAGE)/app-objects -o $(COVERAGE)/app-tests \
	  $(APPTEST)/Main.hs $(GHC_RTS)
	cd $(COVERAGE) && $(XVFB) ./lib-tests > lib-run.log 2>&1
	cd $(COVERAGE) && $(XVFB) ./adwaita-tests > adwaita-run.log 2>&1
	cd $(COVERAGE) && GTK_A11Y=none $(XVFB) $(DBUS) ./app-tests > app-run.log 2>&1
	@echo
	@echo "== gi-gtk4-declarative, from its own suite"
	@hpc report $(COVERAGE)/lib-tests.tix --hpcdir=$(COVERAGE)/lib-mix \
	  --srcdir=. --exclude=Main $(NOT_MEASURED)
	@echo
	@echo "== gi-gtk4-declarative-adwaita, from its own suite"
	@hpc report $(COVERAGE)/adwaita-tests.tix --hpcdir=$(COVERAGE)/adwaita-mix \
	  --srcdir=. --per-module --exclude=Main $(NOT_MEASURED) \
	  | grep -A1 'module GI.Gtk.Declarative.Adwaita' | grep -v '^--$$' \
	  | paste - - | sed 's/-----//g'
	@echo
	@echo "== GI.Gtk.Declarative.App.Simple, from its own suite"
	@hpc report $(COVERAGE)/app-tests.tix --hpcdir=$(COVERAGE)/app-mix \
	  --srcdir=. --per-module --exclude=Main $(NOT_MEASURED) \
	  | grep -A1 'module GI.Gtk.Declarative.App.Simple' | grep -v '^--$$' \
	  | paste - - | sed 's/-----//g'
	@echo
	@echo "Per module, for the library itself:"
	@hpc report $(COVERAGE)/lib-tests.tix --hpcdir=$(COVERAGE)/lib-mix \
	  --srcdir=. --per-module --exclude=Main $(NOT_MEASURED) \
	  | grep -B1 'expressions used' | grep -v '^--$$' | paste - - \
	  | sed 's/-----//g' | sort -t'(' -k2 -n

# A click on a toggle group, driven with real X11 input.
#
# The reason that widget is in this library is a claim about GTK: a
# click cannot turn the chosen toggle off. Nothing can synthesise a
# click, so this clicks one for real and reads the group back.
check-toggle: $(BUILD)/toggle-app
	$(XVFB) tests/gui-toggle.sh $(BUILD)/toggle-app

$(BUILD)/toggle-app: $(SOURCES) $(ADWTEST)/ToggleApp.hs
	@mkdir -p $(BUILD)
	ghc -i$(LIB) -i$(ADWAITA) -i$(ADWTEST) $(WARNINGS) $(PACKAGES) -threaded \
	  -main-is ToggleApp.main \
	  -outputdir $(BUILD)/toggle-app-objects -o $@ $(ADWTEST)/ToggleApp.hs \
	  $(GHC_RTS)

# How long patching takes. Not part of `make check`: it measures rather
# than checks, and it takes minutes rather than seconds.
bench: $(BUILD)/bench
	GDK_BACKEND=x11 GSK_RENDERER=cairo $(XVFB) $(BUILD)/bench

$(BUILD)/bench: $(SOURCES) $(BENCH)/Benchmark.hs
	@mkdir -p $(BUILD)
	ghc -i$(LIB) -i$(BENCH) $(WARNINGS) $(PACKAGES) -threaded \
	  -outputdir $(BUILD)/bench-objects -o $@ $(BENCH)/Benchmark.hs $(GHC_RTS)

# The documentation site. This one needs the docs shell, which has
# MkDocs in it rather than GHC: `nix develop .#docs`.
docs:
	cd docs && mkdocs build

clean:
	rm -rf $(BUILD)
