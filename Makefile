SHELL := /bin/bash
.PHONY: ci shellcheck syntax

shellcheck:
	@command -v shellcheck >/dev/null 2>&1 || { echo "shellcheck not installed"; exit 1; }
	find . -type f -name '*.sh' -not -path './.github/*' -print0 | xargs -0 shellcheck

syntax:
	bash -n ./collect_nginx.sh

ci: shellcheck syntax

echo: # helper
	@echo "Available targets: shellcheck, syntax, ci"
