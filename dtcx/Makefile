# dtcx — vanilla dtc plus a flag to print phandle references as &label.
#
#   make            fetch, patch, build -> ./dtcx
#   make test       prove it on this repo's board DTBs
#   make clean      drop the build, keep the checkout
#   make distclean  drop everything
#
# Nothing here is installed system-wide; ./dtcx is a standalone binary.

DTC_VERSION ?= v1.8.1
DTC_URL     ?= https://git.kernel.org/pub/scm/utils/dtc/dtc.git

SRC     := src
STAMP   := $(SRC)/.patched
BIN     := dtcx
PATCHES := $(sort $(wildcard patches/*.patch))
BOARDS  := $(wildcard ../firmware/*/board.dtb)

MAKEFLAGS += --no-print-directory

.PHONY: all test clean distclean

all: $(BIN)

$(SRC)/.cloned:
	rm -rf $(SRC)
	git clone --quiet --depth 1 --branch $(DTC_VERSION) $(DTC_URL) $(SRC)
	@touch $@

$(STAMP): $(SRC)/.cloned $(PATCHES)
	@cd $(SRC) && git checkout --quiet . && rm -f .patched
	@for p in $(PATCHES); do \
		echo "  PATCH $$p"; \
		git -C $(SRC) apply ../$$p || exit 1; \
	done
	@touch $@

# dtc's own build warns that make is deprecated in favour of meson; it still
# works and needs no extra tooling, so keep it and drop the noise.
$(BIN): $(STAMP)
	@echo "  BUILD dtc $(DTC_VERSION)"
	@$(MAKE) -C $(SRC) NO_PYTHON=1 NO_YAML=1 dtc 2>&1 | grep -vE 'WARNING: Building|Use .meson|^Makefile:[0-9]+:' || true
	@cp $(SRC)/dtc $@
	@echo "  ->    $(CURDIR)/$@"

# The gate that makes the tool trustworthy: every reference must be resolved,
# and the result must recompile to the byte-identical blob it came from.
test: $(BIN)
	@fail=0; \
	for dtb in $(BOARDS); do \
		name=$$(basename $$(dirname $$dtb)); \
		./$(BIN) -I dtb -O dts -P $$dtb > .test.dts 2>/dev/null; \
		refs=$$(grep -cE '<&[a-z0-9_]+' .test.dts); \
		raw=$$(grep -cE '(clocks|gpios|resets|pinctrl-0) = <0x' .test.dts); \
		./$(BIN) -@ -I dts -O dtb -o .test.dtb .test.dts 2>/dev/null; \
		if cmp -s .test.dtb $$dtb && [ "$$raw" = "0" ]; then \
			printf "  PASS  %-10s %s refs, byte-identical round trip\n" "$$name" "$$refs"; \
		else \
			printf "  FAIL  %-10s %s refs, %s raw left\n" "$$name" "$$refs" "$$raw"; fail=1; \
		fi; \
	done; \
	rm -f .test.dts .test.dtb; \
	exit $$fail

clean:
	@rm -f $(BIN) .test.dts .test.dtb
	@[ -d $(SRC) ] && $(MAKE) -C $(SRC) clean >/dev/null 2>&1 || true

distclean:
	rm -rf $(SRC) $(BIN) .test.dts .test.dtb
