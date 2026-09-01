PREFIX ?= $(HOME)/.local
BINDIR  = $(PREFIX)/bin
MANDIR  = $(PREFIX)/share/man/man1

.PHONY: install uninstall test lint help

help:
	@echo "make install    install retire and its man page under PREFIX ($(PREFIX))"
	@echo "make uninstall  remove them"
	@echo "make test       run the test suite against a scratch ledger"
	@echo "make lint       byte-compile the script and lint the man page"

install:
	@mkdir -p $(BINDIR) $(MANDIR)
	install -m 755 retire $(BINDIR)/retire
	install -m 644 man/retire.1 $(MANDIR)/retire.1
	@echo "installed $(BINDIR)/retire and $(MANDIR)/retire.1"
	@command -v mandb >/dev/null 2>&1 && mandb -q $(PREFIX)/share/man 2>/dev/null || true
	@echo "run 'retire doctor' to check the setup"

uninstall:
	rm -f $(BINDIR)/retire $(MANDIR)/retire.1
	@echo "removed. Ledger under XDG_DATA_HOME was left alone."

test:
	@sh tests/test_retire.sh

lint:
	@python3 -c "import py_compile,sys; py_compile.compile('retire', doraise=True)" && echo "python OK"
	@if command -v groff >/dev/null 2>&1; then \
	  LC_ALL=C groff -man -Tascii -ww -z man/retire.1 && echo "man OK"; \
	else echo "groff absent, skipping man lint"; fi
