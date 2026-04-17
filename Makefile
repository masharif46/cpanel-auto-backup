# Makefile — developer conveniences for cpanel-auto-backup.
# Production install: see scripts/install.sh.

SCRIPTS := backup-cpanel.sh $(wildcard lib/*.sh) $(wildcard scripts/*.sh)
SHELLCHECK ?= shellcheck
SHELLCHECK_OPTS ?= -S warning -x

.PHONY: help lint syntax dry-run install uninstall clean

help:
	@echo "Developer targets:"
	@echo "  lint        Run ShellCheck at 'warning' severity on every .sh"
	@echo "  syntax      bash -n every script (catches syntax errors, no runtime)"
	@echo "  dry-run     Run the tool with --dry-run --verbose (requires root)"
	@echo "  install     Run scripts/install.sh (requires root)"
	@echo "  uninstall   Remove installed paths (requires root; see docs/INSTALL.md)"
	@echo "  clean       Remove local cruft (logs, .release-notes)"

lint:
	$(SHELLCHECK) $(SHELLCHECK_OPTS) $(SCRIPTS)

syntax:
	@set -e; for f in $(SCRIPTS); do bash -n "$$f" || exit 1; done
	@echo "Syntax OK: $(words $(SCRIPTS)) file(s)"

dry-run:
	sudo ./backup-cpanel.sh --dry-run --verbose

install:
	sudo ./scripts/install.sh

uninstall:
	sudo rm -f /etc/cron.d/cpanel-auto-backup
	sudo rm -rf /opt/cpanel-auto-backup
	sudo rm -f  /usr/local/sbin/cpanel-auto-backup
	sudo rm -rf /var/log/cpanel-auto-backup
	@echo ""
	@echo "Config at /etc/cpanel-auto-backup/ and backups at \$$BACKUP_ROOT NOT removed."
	@echo "Delete those by hand when you're sure."

clean:
	rm -f  *.log
	rm -f  .release-notes-*.md
	rm -rf tmp/ scratch/ test-output/
