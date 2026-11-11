# Shared script contract and runner. The grammar and case format are in
# include/songyan_script.h; the execution API is in include/songyan_script_run.h.
#
# Build output goes to the repository's git-ignored .local/ directory. There is no clean target:
# OUT may be overridden, so deleting whatever it points at would be too broad a sweep.
#
# The engine sources are fetched from the pin in Tools/BuildRimeIOS/QUICKJS-VERSIONS.env (tag plus
# archive sha256) into .local/, the same way the Rime sources are fetched, so no third-party source
# is committed. The script environment is embedded from src/bootstrap.js.

DIR := $(dir $(abspath $(lastword $(MAKEFILE_LIST))))
ROOT := $(abspath $(DIR)../..)
OUT ?= $(ROOT)/.local/script-cli
BIN := $(OUT)/songyan-script
FAULTS := $(OUT)/contract-faults
SOURCES := $(DIR)src/contract.c $(DIR)src/main.c $(DIR)src/run.c $(DIR)src/fetch.c \
	$(DIR)src/run_cli.c
HEADERS := $(DIR)include/songyan_script.h $(DIR)include/songyan_script_run.h \
	$(DIR)src/internal.h
CFLAGS ?= -std=c11 -Wall -Wextra -Werror -O2
QJS_CFLAGS ?= -std=gnu11 -O2 -D_GNU_SOURCE
CC ?= cc

QUICKJS_PIN := $(ROOT)/Tools/BuildRimeIOS/QUICKJS-VERSIONS.env
QJS_PATH := $(OUT)/quickjs-source.path
QJS_OBJECTS := $(OUT)/quickjs/quickjs.o $(OUT)/quickjs/libregexp.o \
	$(OUT)/quickjs/libunicode.o $(OUT)/quickjs/dtoa.o
BOOTSTRAP := $(OUT)/songyan_script_bootstrap.inc

.PHONY: all test contract execution run

all: $(BIN)

$(QJS_PATH): $(QUICKJS_PIN) $(DIR)scripts/fetch-quickjs.sh
	@mkdir -p $(OUT)
	$(DIR)scripts/fetch-quickjs.sh > $(QJS_PATH).tmp
	mv $(QJS_PATH).tmp $(QJS_PATH)

$(OUT)/quickjs/%.o: $(QJS_PATH)
	@mkdir -p $(OUT)/quickjs
	@engine="$$(cat $(QJS_PATH))"; $(CC) $(QJS_CFLAGS) -I"$$engine" -c "$$engine/$*.c" -o $@

$(BOOTSTRAP): $(DIR)src/bootstrap.js $(DIR)scripts/embed-text.py
	@mkdir -p $(OUT)
	python3 $(DIR)scripts/embed-text.py $(DIR)src/bootstrap.js $@ songyan_script_bootstrap

$(BIN): $(SOURCES) $(HEADERS) $(QJS_OBJECTS) $(BOOTSTRAP)
	@mkdir -p $(OUT)
	$(CC) $(CFLAGS) -I$(DIR)include -I$(OUT) -I"$$(cat $(QJS_PATH))" \
		$(SOURCES) $(QJS_OBJECTS) -lm -o $(BIN)

# Test-only build: the same parser compiled with allocation failure injection and live counting.
$(FAULTS): $(DIR)src/contract.c $(DIR)tests/faults.c $(DIR)include/songyan_script.h
	@mkdir -p $(OUT)
	$(CC) $(CFLAGS) -DSONGYAN_SCRIPT_TESTING -I$(DIR)include \
		$(DIR)src/contract.c $(DIR)tests/faults.c -o $(FAULTS)

test: $(BIN) $(FAULTS)
	$(DIR)tests/run.sh $(BIN) $(FAULTS)
	$(DIR)tests/run-execution.sh $(BIN)

contract: $(BIN) $(FAULTS)
	$(DIR)tests/run.sh $(BIN) $(FAULTS)

execution: $(BIN)
	$(DIR)tests/run-execution.sh $(BIN)

# Runs one script with no host network and no fixture, for manual experiments.
run: $(BIN)
	$(BIN) run --script $(or $(SCRIPT),$(DIR)examples/minimal.js) \
		--text "$(or $(TEXT),一段测试文字)" --capabilities text \
		--source-bytes 1048576 --heap-bytes 8388608 --duration-ms 4000 \
		--request-count 4 --response-bytes 1048576 --input-text-bytes 20000
