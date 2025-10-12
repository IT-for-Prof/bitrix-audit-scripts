#!/usr/bin/env bash
# Minimal shared helpers for the audit scripts.
set -euo pipefail

# Central audit dir for short summaries and archives. Scripts may override OUT_DIR/AUDIT_DIR.
AUDIT_DIR="${AUDIT_DIR:-${HOME}/audit}"
mkdir -p "$AUDIT_DIR"

# Host/time helpers
HOST="$(hostname -f 2>/dev/null || hostname)"
TS="$(date --iso-8601=seconds 2>/dev/null || date -u +%Y-%m-%dT%H:%M:%SZ)"

# Prevent Bitrix appliance interactive menu from launching when child shells source
# system/profile files that call /root/menu.sh. Export these environment variables so
# all collectors (which source this file) inherit them.
BX_NOMENU=1 BITRIX_NO_MENU=1 DISABLE_BITRIX_MENU=1
export BX_NOMENU BITRIX_NO_MENU DISABLE_BITRIX_MENU

# Prevent child bash instances from sourcing user/system profile files via BASH_ENV/ENV
# and disable prompts/timeouts so the scripts are non-interactive by default.
export BASH_ENV=/dev/null ENV=/dev/null
exec </dev/null || true
PS1='' PROMPT_COMMAND='' TMOUT=0
export PS1 PROMPT_COMMAND TMOUT

# write_audit_summary: take stdin, write to target file and print a NOTICE to stderr
write_audit_summary(){
  local out="$1"
  if [[ -z "$out" ]]; then return 1; fi
  # ensure parent dir exists
  mkdir -p "$(dirname -- "$out")"
  cat - > "$out" 2>/dev/null || return 1
  printf 'NOTICE: wrote short summary to %s\n' "$out" >&2
}

# pipe_save_full <file>: save stdin fully to file (create parent dir)
pipe_save_full(){
  local out="$1"
  if [[ -z "$out" ]]; then return 1; fi
  mkdir -p "$(dirname -- "$out")" 2>/dev/null || true
  cat - > "$out" 2>/dev/null || true
  return 0
}

# pipe_save_slim <file>: shorthand to save stdin (could add truncation later)
pipe_save_slim(){
  pipe_save_full "$1"
}

# run_to <seconds> <cmd...>: run a command with timeout if available
run_to(){
  local to="$1"; shift
  if command -v timeout >/dev/null 2>&1; then
    timeout "$to" "$@"
  else
    "$@"
  fi
}

# create_and_verify_archive <workdir> <archive_name>
# Creates archive under $AUDIT_DIR/<archive_name> (no date suffix), excluding access/error logs.
# Verifies the number of files in the archive matches the source (excluding access/error). If they
# match and are non-zero, removes the source directory. Prints ARCHIVE: path (size=..., files=...)
create_and_verify_archive(){
  local workdir="$1" archive_name="${2:-archive.tgz}" archive_path tmp archive_count archive_size src_count
  if [[ -z "$workdir" ]]; then return 2; fi
  archive_path="$AUDIT_DIR/$archive_name"
  if [ ! -d "$workdir" ]; then
    printf 'NOTICE: workdir %s does not exist, skipping archive\n' "$workdir" >&2
    return 0
  fi
  src_count=$(find "$workdir" -type f ! -iname '*access*' ! -iname '*error*' 2>/dev/null | wc -l | tr -d ' ' || true)
  if [ "${src_count:-0}" -eq 0 ]; then
    printf 'NOTICE: no files under %s; skipping archive creation\n' "$workdir" >&2
    return 0
  fi
  mkdir -p "$(dirname -- "$archive_path")" || true
  tmp=$(mktemp -p "$(dirname -- "$archive_path")" "${archive_name}.tmp.XXXXXXXX") || tmp="${archive_path}.tmp"
  # create archive excluding common access/error logs
  if tar --exclude='*access*' --exclude='*error*' -C "$workdir" -czf "$tmp" . 2>/dev/null; then
    mv -f "$tmp" "$archive_path" 2>/dev/null || true
  else
    printf 'ERROR: failed to create archive from %s\n' "$workdir" >&2
    rm -f "$tmp" || true
    return 2
  fi
  archive_count=$(tar -tf "$archive_path" 2>/dev/null | sed '/\/$/d' | wc -l | tr -d ' ' || true)
  archive_size=$(du -h "$archive_path" 2>/dev/null | cut -f1 || true)
  printf 'ARCHIVE: %s (size=%s, files=%s)\n' "$archive_path" "${archive_size:-unknown}" "${archive_count:-0}"
  printf 'SRC COUNT (excluding access/error): %s files under %s\n' "$src_count" "$workdir"
  if [ "$archive_count" -gt 0 ] && [ "$archive_count" -eq "$src_count" ]; then
    if [ "${NO_DELETE:-0}" = "1" ]; then
      printf 'NOTICE: NO_DELETE=1 set — archive file count matches source (%s) but skipping removal of %s\n' "$archive_count" "$workdir"
    else
      printf 'NOTICE: archive file count matches source file count — removing source dir %s\n' "$workdir"
      rm -rf "$workdir" || printf 'WARN: failed to remove %s\n' "$workdir" >&2
    fi
  else
    printf 'WARN: archive and source counts differ (archive=%s src=%s) — keeping source dir %s for inspection\n' "$archive_count" "$src_count" "$workdir" >&2
  fi
  return 0
}

# Export commonly used vars for scripts that source this file
export AUDIT_DIR HOST TS
