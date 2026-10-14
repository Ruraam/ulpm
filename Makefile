# ULPM - developer & packaging tasks
SHELL      := /bin/bash
PREFIX     ?= /usr/local
DESTDIR    ?=
SCRIPTS    := bin/ulpm install.sh $(wildcard lib/*.sh)

.PHONY: all help check lint syntax whitespace test install uninstall

all: help

help:
	@echo "make check      Run syntax + whitespace guard + shellcheck"
	@echo "make test       Run the bats suites (tests/*.bats), if bats is installed"
	@echo "make install    Install to \$$(PREFIX) (default /usr/local); honours DESTDIR"
	@echo "make uninstall  Remove what 'make install' installed"

check: syntax whitespace lint

syntax:
	@for f in $(SCRIPTS); do bash -n "$$f" || exit 1; done; echo "bash -n: OK"

# Catches copy/paste damage such as 'if[[', 'for_x in' or "printf'%s" (missing spaces)
whitespace:
	@! grep -nE "(^|[[:space:];])(if|elif|while|until)(\[\[|\(|!)|printf'|null[0-9]>|^[[:space:]]*for_[a-z_]+ in " $(SCRIPTS) \
	  && echo "whitespace guard: OK" || { echo "whitespace guard: FAILED (see lines above)"; exit 1; }

lint:
	@command -v shellcheck >/dev/null || { echo "shellcheck not installed, skipping"; exit 0; }
	@shellcheck -x $(SCRIPTS) && echo "shellcheck: OK"

test:
	@command -v bats >/dev/null || { echo "bats not installed"; exit 1; }
	@bats tests/

# ULPM resolves lib/ relative to the real path of bin/ulpm, so keep both under one root
install:
	install -d "$(DESTDIR)$(PREFIX)/share/ulpm/bin" "$(DESTDIR)$(PREFIX)/share/ulpm/lib" "$(DESTDIR)$(PREFIX)/bin"
	install -m 0755 bin/ulpm "$(DESTDIR)$(PREFIX)/share/ulpm/bin/ulpm"
	install -m 0644 lib/*.sh "$(DESTDIR)$(PREFIX)/share/ulpm/lib/"
	ln -sf ../share/ulpm/bin/ulpm "$(DESTDIR)$(PREFIX)/bin/ulpm"
	@if [ -f man/ulpm.1 ]; then install -D -m 0644 man/ulpm.1 "$(DESTDIR)$(PREFIX)/share/man/man1/ulpm.1"; fi

uninstall:
	rm -f "$(DESTDIR)$(PREFIX)/bin/ulpm" "$(DESTDIR)$(PREFIX)/share/man/man1/ulpm.1"
	rm -rf "$(DESTDIR)$(PREFIX)/share/ulpm"
