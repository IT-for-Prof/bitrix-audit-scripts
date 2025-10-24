#!/usr/bin/env bash
# collect_cron.sh — найти и вывести все cron-файлы + собрать в архив
# Re-exec in a sterile env to avoid interactive profile/menu scripts being sourced by child shells.
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
# Использование:
#   bash collect_cron.sh            # печать и создание архива в ~/cron_audit/
#   bash collect_cron.sh --no-archive
#   bash collect_cron.sh --no-comments
#   bash collect_cron.sh --no-archive --no-comments

set -euo pipefail

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

# with_locale runs a single command with the chosen LANGUAGE and LC_TIME

NO_ARCHIVE=0
NO_COMMENTS=0

for a in "$@"; do
  case "$a" in
    --no-archive)  NO_ARCHIVE=1 ;;
    --no-comments) NO_COMMENTS=1 ;;
    *) echo "Неизвестный аргумент: $a" >&2; exit 2 ;;
  esac
done

TS="$(date +%Y%m%d_%H%M%S)"
# Use a transient workdir (mktemp) to avoid creating long-lived per-run
# directories under $HOME. The final archive will be moved to $AUDIT_DIR
# by create_and_verify_archive(). Fall back to /tmp if creating under
# $HOME fails.
WORKDIR="$(mktemp -d "${HOME:-/root}/cron_audit_${TS}.XXXXXX" 2>/dev/null || mktemp -d "/tmp/cron_audit_${TS}.XXXXXX")"

mkdir -p "$WORKDIR/rootfs" "$WORKDIR/log"
OUTTXT="$WORKDIR/log/cron_dump_${TS}.txt"

# --- Вспомогательные функции ---
is_text() {
  local f="$1"
  # Считаем текстом mime text/*, application/x-empty и ряд конфигов
  local mt
  mt="$(file -b --mime-type -- "$f" 2>/dev/null || true)"
  [[ "$mt" =~ ^text/ ]] || [[ "$mt" == "application/x-empty" ]] || [[ "$mt" == "application/json" ]] || [[ "$mt" == "application/xml" ]]
}

print_meta() {
  local f="$1"
  if command -v stat >/dev/null 2>&1; then
    stat -c "path=%n size=%s mode=%a owner=%U group=%G mtime=%y" -- "$f" 2>/dev/null || true
  else
    ls -l -- "$f" 2>/dev/null || true
  fi
}

copy_with_parents() {
  # Копируем файл в WORKDIR/rootfs/<исходный_путь>
  local src="$1"
  local dst="$WORKDIR/rootfs$1"
  mkdir -p "$(dirname -- "$dst")"
  # сохраняем права как есть
  cp -a -- "$src" "$dst" 2>/dev/null || cp --preserve=mode,timestamps -- "$src" "$dst" 2>/dev/null || cp -- "$src" "$dst"
}

dump_file() {
  local f="$1"
  {
    printf '====== %s ======\n' "$f"
    print_meta "$f"
    echo "--- CONTENT BEGIN ---"
    if is_text "$f"; then
      if (( NO_COMMENTS )); then
        # Убираем пустые строки и комментарии shell/cron
        sed -n '1,99999p' -- "$f" | awk 'BEGIN{blank=0} {if ($0 ~ /^[[:space:]]*(#|$)/) next; print}'
      else
        sed -n '1,99999p' -- "$f"
      fi
    else
      echo "[binary/non-text, первые 200 строк hexdump для ориентира]"
      hexdump -C -- "$f" | head -n 200
    fi
    echo "--- CONTENT END ---"
    echo
  } | tee -a "$OUTTXT"
}

# --- Сбор целей для поиска ---
declare -a roots=(
  "/etc/crontab"
  "/etc/cron.d"
  "/etc/cron.hourly"
  "/etc/cron.daily"
  "/etc/cron.weekly"
  "/etc/cron.monthly"
  "/etc/cron.allow"
  "/etc/cron.deny"
  "/etc/anacrontab"
  "/etc/anacron"
  "/var/spool/cron"
  "/var/spool/cron/crontabs"
)

# --- Поиск файлов (поверхностно + глубоко) ---
declare -A seen=()
declare -a files=()

add_file() {
  local f="$1"
  # нормализуем путь и исключаем дубликаты
  if [ -f "$f" ] && [ -r "$f" ]; then
    if [[ -z "${seen[$f]:-}" ]]; then
      seen["$f"]=1
      files+=("$f")
    fi
  fi
}

for r in "${roots[@]}"; do
  if [ -f "$r" ]; then
    add_file "$r"
  elif [ -d "$r" ]; then
    # рекурсивно, только обычные файлы
    while IFS= read -r -d '' f; do
      add_file "$f"
    done < <(find "$r" -type f -print0 2>/dev/null)
  fi
done

# На некоторых системах crontab пользователей хранится в альтернативных местах — пробуем угадать
for alt in /usr/spool/cron /var/cron/tabs; do
  if [ -d "$alt" ]; then
    while IFS= read -r -d '' f; do
      add_file "$f"
    done < <(find "$alt" -type f -print0 2>/dev/null)
  fi
done

# --- Вывод и копирование ---
{
  echo "==== CRON AUDIT DUMP ===="
  echo "Timestamp: $TS"
  echo "Host: $(hostname -f 2>/dev/null || hostname)"
  echo "Kernel: $(uname -srmo 2>/dev/null || uname -a)"
  echo "Total files: ${#files[@]}"
  echo
} | tee -a "$OUTTXT"

if [ "${#files[@]}" -eq 0 ]; then
  echo "[WARN] Cron-файлов не найдено в стандартных путях." | tee -a "$OUTTXT"
else
  for f in "${files[@]}"; do
    # Печать
    dump_file "$f"
    # Копия для архива (если включено)
    if (( NO_ARCHIVE == 0 )); then
      copy_with_parents "$f"
    fi
  done
fi

# --- Архивирование (если не отключено) ---
if (( NO_ARCHIVE == 0 )); then
  source "$(dirname -- "${BASH_SOURCE[0]:-$0}")/audit_common.sh"
  SUMMARY_COPY="$AUDIT_DIR/cron_summary.log"
  { echo "# Cron Audit Summary: $(date --iso-8601=seconds)"; echo; sed -n '1,500p' "$OUTTXT" 2>/dev/null || true; } | write_audit_summary "$SUMMARY_COPY"

  # Use centralized archive/verification helper. It excludes access/error logs by policy
  create_and_verify_archive "$WORKDIR" "cron_audit.tgz"
  # Ensure transient WORKDIR is removed unless NO_DELETE=1 was explicitly set.
  # Note: create_and_verify_archive will already remove the source directory
  # when verification succeeds and NO_DELETE!=1; this is an extra safety cleanup
  # to cover cases where the archive helper couldn't remove (permissions, etc.).
  if [ "${NO_DELETE:-0}" -eq 0 ]; then
    if [ -d "$WORKDIR" ]; then
      rm -rf -- "$WORKDIR" >/dev/null 2>&1 || true
    fi
  else
    echo "NOTICE: NO_DELETE=${NO_DELETE} set — preserving workdir: $WORKDIR" >&2
  fi

  echo
  echo "[OK] Логи и копии файлов собраны."
  echo "  Папка:   $WORKDIR"
else
  echo
  echo "[OK] Вывод сформирован без архива. Полный дамп: $OUTTXT"
fi
