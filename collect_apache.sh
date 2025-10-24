#!/usr/bin/env bash
# Re-exec in a sterile env to avoid interactive profile/menu scripts being sourced by child shells.
# If _STERILE is not set and we are in an interactive shell or BASH_ENV is set, re-exec using a
# minimal env and `bash --noprofile --norc` so the script runs deterministically in automation.
if [ -z "${_STERILE:-}" ] && { [[ $- == *i* ]] || [ -n "${BASH_ENV:-}" ]; }; then
  # Determine best available locale for sterile environment
  _detect_locale() {
    if locale -a 2>/dev/null | grep -qi '^en_US\.UTF-8$'; then
      echo "en_US.UTF-8"
    elif locale -a 2>/dev/null | grep -qi '^en_US\.utf8$'; then
      echo "en_US.utf8"
    elif locale -a 2>/dev/null | grep -qi '^ru_RU\.UTF-8$'; then
      echo "ru_RU.UTF-8"
    elif locale -a 2>/dev/null | grep -qi '^ru_RU\.utf8$'; then
      echo "ru_RU.utf8"
      echo "ru_RU.UTF-8"
    elif locale -a 2>/dev/null | grep -qi '^C\.UTF-8$'; then
      echo "C.UTF-8"
    elif locale -a 2>/dev/null | grep -qi '^C\.utf8$'; then
      echo "C.utf8"
    elif locale -a 2>/dev/null | grep -qi '^POSIX$'; then
      echo "POSIX"
    else
      echo "C"
    fi
  }
  
  _LOCALE="$(_detect_locale)"
  exec env -i HOME=/root PATH=/usr/sbin:/usr/bin:/bin TERM=xterm-256color \
    LANG="$_LOCALE" LANGUAGE="$_LOCALE" \
    BASH_ENV= _STERILE=1 \
    bash --noprofile --norc "$0" "$@"
fi

set -euo pipefail

# collect_apache.sh — офлайн/онлайн аудит Apache+PHP (BitrixVM-friendly)
shopt -s nullglob
export LC_ALL=C

# Use shared audit_common.sh for locale management
source "$(dirname -- "${BASH_SOURCE[0]:-$0}")/audit_common.sh"

# Setup locale using common functions
setup_locale

# Check for root privileges
if [ "$EUID" -ne 0 ]; then
    echo "================================================" >&2
    echo "ВНИМАНИЕ: Скрипт запущен БЕЗ root-прав" >&2
    echo "Некоторые данные будут недоступны:" >&2
    echo "  - Логи в /var/log/" >&2
    echo "  - Конфигурации в /etc/" >&2
    echo "  - Системные команды (smartctl, dmidecode)" >&2
    echo "Для полного аудита запустите: sudo $0 $*" >&2
    echo "================================================" >&2
    echo ""
fi

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

