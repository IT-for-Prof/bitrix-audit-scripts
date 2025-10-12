#!/usr/bin/env bash
# Re-exec in a sterile env to avoid interactive profile/menu scripts being sourced by child shells.
# If _STERILE is not set and we are in an interactive shell or BASH_ENV is set, re-exec using a
# minimal env and `bash --noprofile --norc` so the script runs deterministically in automation.
if [ -z "${_STERILE:-}" ] && { [[ $- == *i* ]] || [ -n "${BASH_ENV:-}" ]; }; then
	exec env -i HOME=/root PATH=/usr/sbin:/usr/bin:/bin TERM=xterm-256color BASH_ENV= _STERILE=1 \
		bash --noprofile --norc "$0" "$@"
fi

set -euo pipefail

# collect_apache.sh — офлайн/онлайн аудит Apache+PHP (BitrixVM-friendly)
shopt -s nullglob
export LC_ALL=C

LANG_PREFS=("en_US.UTF-8" "en_US:en")
LC_TIME_RU='ru_RU.UTF-8'

locale_has(){ local want_lc; want_lc=$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]'); if locale -a >/dev/null 2>&1; then locale -a 2>/dev/null | tr '[:upper:]' '[:lower:]' | grep -x -- "${want_lc}" >/dev/null 2>&1; return $?; fi; return 1; }

# Determine per-command LANGUAGE and LC_TIME without exporting system-wide
SCRIPT_LANGUAGE=""
for lg in "${LANG_PREFS[@]}"; do if locale_has "$lg"; then SCRIPT_LANGUAGE="$lg"; break; fi; done
if [ -z "$SCRIPT_LANGUAGE" ]; then SCRIPT_LANGUAGE="en_US:en"; fi
if [ "${LANGUAGE:-}" != "$SCRIPT_LANGUAGE" ]; then
	printf 'NOTICE: LANGUAGE=%s, will use LANGUAGE=%s for commands in this script only\n' "${LANGUAGE:-unset}" "$SCRIPT_LANGUAGE" >&2
fi

SCRIPT_LC_TIME=""
if locale_has "$LC_TIME_RU"; then
	SCRIPT_LC_TIME="$LC_TIME_RU"
else
	if locale_has "en_US.UTF-8"; then SCRIPT_LC_TIME="en_US.UTF-8"
	elif locale_has "en_US:en"; then SCRIPT_LC_TIME="en_US:en"
	else SCRIPT_LC_TIME=C; fi
	# prefer en_US language if we switched LC_TIME away from ru
	if [[ "$SCRIPT_LANGUAGE" != "en_US.UTF-8" ]]; then
		if locale_has "en_US.UTF-8"; then NEW_SCRIPT_LANG="en_US.UTF-8"
		elif locale_has "en_US:en"; then NEW_SCRIPT_LANG="en_US:en"
		else NEW_SCRIPT_LANG="$SCRIPT_LANGUAGE"; fi
		printf 'NOTICE: ru_RU.UTF-8 LC_TIME not available; will use LC_TIME=%s and LANGUAGE=%s for commands in this script only\n' "$SCRIPT_LC_TIME" "$NEW_SCRIPT_LANG" >&2
		SCRIPT_LANGUAGE="$NEW_SCRIPT_LANG"
	else
		printf 'NOTICE: LC_TIME=%s will be used for commands in this script only\n' "$SCRIPT_LC_TIME" >&2
	fi
fi

# with_locale runs a single command with the chosen LANGUAGE and LC_TIME
with_locale(){ LANGUAGE="$SCRIPT_LANGUAGE" LC_TIME="$SCRIPT_LC_TIME" "$@"; }

OUT_BASE="${OUT_BASE:-${HOME}/apache_audit}"
OUT_DIR="${OUT_DIR:-${OUT_BASE}}"
# create expected output subdirs (fix: no stray space before brace)
mkdir -p "$OUT_DIR"/{ctx,conf,mods,vhosts,php,fpm,ssl,logs,sys} 2>/dev/null || true

AUDIT_DIR="${AUDIT_DIR:-${HOME%/}/audit}"

echo "collect_apache: OUT_DIR=$OUT_DIR AUDIT_DIR=$AUDIT_DIR"

# If caller wants an archive, prepare standard archive path and report after collection
# We'll create: $AUDIT_DIR/apache_audit.tgz

# Ensure audit dir exists
mkdir -p "$AUDIT_DIR" 2>/dev/null || true


# Use centralized create_and_verify_archive from audit_common.sh (keeps behavior consistent)
source "$(dirname -- "${BASH_SOURCE[0]:-$0}")/audit_common.sh"


# If script is executed (not sourced), perform default collection and archive
if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
	printf 'collect_apache: starting collection. OUT_DIR=%s AUDIT_DIR=%s\n' "$OUT_DIR" "$AUDIT_DIR"

	# show files that would be archived (exclude access/error logs)
	printf 'Files considered for archiving (excluding access/error):\n'
	find "$OUT_DIR" -type f ! -iname '*access*' ! -iname '*error*' -print | sed 's/^/  /' || true

	# create archive and verify
	create_and_verify_archive "$OUT_DIR"

	printf 'collect_apache: finished\n'
fi

