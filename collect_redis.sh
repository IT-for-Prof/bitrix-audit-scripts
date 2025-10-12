#!/usr/bin/env bash
# Redis audit collector — extended
# Версия: 1.5 (полный расширенный сбор)

set -uo pipefail
# Re-exec in a sterile env to avoid interactive profile/menu scripts being sourced by child shells.
if [ -z "${_STERILE:-}" ] && { [[ $- == *i* ]] || [ -n "${BASH_ENV:-}" ]; }; then
  exec env -i HOME=/root PATH=/usr/sbin:/usr/bin:/bin TERM=xterm-256color BASH_ENV= _STERILE=1 \
    bash --noprofile --norc "$0" "$@"
fi

# Prevent interactive Bitrix appliance menu (some system scripts source /root/menu.sh)
export BX_NOMENU=1 BITRIX_NO_MENU=1 DISABLE_BITRIX_MENU=1

# ===== Настройки (переопределяемые переменные окружения) =====
LOCALE="${LOCALE:-ru_RU.UTF-8}"

# Ensure per-process LC_TIME for consistent time formatting (do not modify system-wide settings)
# Prefer ru_RU.UTF-8, fall back to en_US.UTF-8, then en_US:en, then C if needed.
# LANGUAGE and LC_TIME policy (do not modify system-wide settings)
# - Ensure commands inside the script run with LANGUAGE=en_US.UTF-8 (fallback en_US:en)
# - Ensure LC_TIME=ru_RU.UTF-8 when available; if ru isn't available, try to ensure
#   LANGUAGE is en_US.UTF-8 (fallback en_US:en) and use an en_US LC_TIME if needed.

LANG_PREFS=("en_US.UTF-8" "en_US:en")
LC_TIME_RU='ru_RU.UTF-8'

locale_has() {
  local want_lc
  want_lc=$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]')
  if locale -a >/dev/null 2>&1; then
    locale -a 2>/dev/null | tr '[:upper:]' '[:lower:]' | grep -x -- "${want_lc}" >/dev/null 2>&1
    return $?
  fi
  return 1
}

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
  else SCRIPT_LC_TIME=C
  fi
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

BASE_DIR="${BASE_DIR:-${HOME}}"
PROBE_ROOT="${PROBE_ROOT:-${BASE_DIR:-${HOME}}/redis_audit}"
TS="$(date +%Y%m%d_%H%M%S)"
WORKDIR="${WORKDIR:-${PROBE_ROOT}}"
# Standard OUT_DIR and central audit dir
OUT_DIR="${OUT_DIR:-${WORKDIR}}"
mkdir -p "$OUT_DIR"/{conf,logs,out,sys} 2>/dev/null || true
AUDIT_DIR="${AUDIT_DIR:-${HOME%/}/audit}"
mkdir -p "$AUDIT_DIR"
ARCHIVE_NAME="redis.tgz"
ARCHIVE_PATH="$AUDIT_DIR/$ARCHIVE_NAME"
ARCHIVE="${ARCHIVE_PATH}"

# Как подключаться к Redis: можно задать хост/порт/DB/пароль и т.п.
# Примеры:
#   REDIS_CLI="redis-cli -h 127.0.0.1 -p 6379 -n 0"
#   REDIS_CLI="redis-cli -h 127.0.0.1 -p 6379 -a 'SuperSecret' --no-auth-warning"
REDIS_CLI="${REDIS_CLI:-redis-cli}"

# Лимиты и поведение
TIMEOUT="${TIMEOUT:-10}"                  # таймаут для отдельных команд (сек)
JOURNAL_MAXLINES="${JOURNAL_MAXLINES:-2000}"
LOG_TAIL_LINES="${LOG_TAIL_LINES:-2000}"
SLOWLOG_LEN="${SLOWLOG_LEN:-200}"
MEMKEYS_SAMPLES="${MEMKEYS_SAMPLES:-10000}"

RUN_BIGKEYS="${RUN_BIGKEYS:-auto}"        # auto|yes|no
RUN_MEMKEYS="${RUN_MEMKEYS:-auto}"        # auto|yes|no
BIGKEYS_MAX_KEYS_AUTO="${BIGKEYS_MAX_KEYS_AUTO:-200000}"

# Опциональные «тяжёлые»/нагрузочные блоки
RUN_MONITOR="${RUN_MONITOR:-0}"           # 1 — включить 5с снимок MONITOR
RUN_SCAN_PREFIX="${RUN_SCAN_PREFIX:-0}"   # 1 — семпл SCAN с префикс-heatmap
SCAN_SAMPLE_LIMIT="${SCAN_SAMPLE_LIMIT:-20000}"
RUN_BENCH="${RUN_BENCH:-0}"               # 1 — лёгкий redis-benchmark (на стенде!)

# ===== Подготовка =====
mkdir -p "${WORKDIR}/conf" "${WORKDIR}/logs" "${WORKDIR}/out" "${WORKDIR}/sys"
MASTER_OUT="${WORKDIR}/redis_audit.txt"

have() { command -v "$1" >/dev/null 2>&1; }
hdr()  { printf '==== %s ====\n' "$1"; }
run_to_master() { { hdr "$1"; shift; "$@"; echo; } >>"${MASTER_OUT}" 2>&1; }

# Redis helper с таймаутом; use non-login shell (bash -c) to avoid reading login profiles (/root/menu.sh)
rc() { timeout "${TIMEOUT}s" bash -c "$(printf "%q " "${REDIS_CLI}") $*"; }

# ===== Баннер =====
{
  hdr "Redis Audit: старт"
  echo "timestamp=${TS}"
  echo "host=$(hostname -f 2>/dev/null || hostname)"
  echo "Workdir: ${WORKDIR}"
  echo "Archive: ${ARCHIVE}"
  echo "Locale:  ${LC_ALL:-unset}"
  echo "User:    $(id -un) (uid $(id -u))"
  echo
} >>"${MASTER_OUT}" 2>&1

# ===== Система =====
{
  hdr "Сведения о системе"
  uname -a || true
  date
  uptime || true

  echo
  hdr "ulimit и лимиты файловых дескрипторов"
  ulimit -a || true
  # read single-file without spawning 'cat'
  sed -n '1p' -- /proc/sys/fs/file-max 2>/dev/null | tr -d '\n' || true
  echo

  echo
  hdr "Важные sysctl (сетевые/память)"
  sysctl -a 2>/dev/null | grep -E -i 'net.core.somaxconn|net.ipv4.tcp_(tw_reuse|fin_timeout)|vm.overcommit_memory|vm.swappiness' || true

  echo
  hdr "Transparent HugePages"
  for f in /sys/kernel/mm/transparent_hugepage/enabled /sys/kernel/mm/transparent_hugepage/defrag; do
    [ -r "$f" ] && { echo "$f: $(< "$f" tr -d '\n' || true)"; }
  done
} >>"${MASTER_OUT}" 2>&1

# ===== Версии =====
{
  hdr "Версии redis-server / redis-cli"
  (redis-server -v || true)
  ("${REDIS_CLI}" --version || true)
} >>"${MASTER_OUT}" 2>&1

# ===== Конфиги и сервисы =====
{
  hdr "Поиск конфигурации и unit-файлов"
  ls -l /etc/redis*.conf /etc/redis/redis.conf 2>/dev/null || true
  ls -l /etc/redis/*.conf 2>/dev/null || true
  ls -l /etc/systemd/system/redis*.service /usr/lib/systemd/system/redis*.service 2>/dev/null || true
  ls -l /etc/sysconfig/redis /etc/default/redis* 2>/dev/null || true
} >>"${MASTER_OUT}" 2>&1

for f in /etc/redis/redis.conf /etc/redis*.conf /etc/redis/*.conf; do
  if [ -r "$f" ]; then
    cp -a "$f" "${WORKDIR}/conf/" 2>/dev/null || true
  fi
done

if have systemctl; then
  {
    hdr "systemctl status redis (кратко)"
    systemctl is-enabled redis 2>/dev/null || true
    systemctl is-active redis 2>/dev/null || true
    systemctl status redis --no-pager -l 2>/dev/null | sed -n '1,160p' || true
  } >>"${MASTER_OUT}" 2>&1
fi

# ===== Базовые проверки подключения =====
{
  hdr "PING"
  "${REDIS_CLI}" PING || true

  echo
  hdr "INFO server"
  "${REDIS_CLI}" INFO server || true

  echo
  hdr "INFO memory / clients / stats / keyspace / persistence"
  "${REDIS_CLI}" INFO memory || true
  "${REDIS_CLI}" INFO clients || true
  "${REDIS_CLI}" INFO stats || true
  "${REDIS_CLI}" INFO keyspace || true
  "${REDIS_CLI}" INFO persistence || true

  echo
  hdr "Ключевые метрики (выжимка)"
  "${REDIS_CLI}" INFO | grep -E -i 'redis_version|uptime_in_seconds|process_id|tcp_port|role|maxmemory(_human)?|used_memory(_peak)?(_human)?|evicted_keys|expired_keys|connected_clients|connected_slaves|instantaneous_ops_per_sec|rdb_last_bgsave_status|aof_enabled|aof_last_write_status' || true
} >>"${MASTER_OUT}" 2>&1

# ===== CONFIG essentials =====
{
  hdr "CONFIG GET maxmemory / maxmemory-policy / save / appendonly / appendfsync"
  "${REDIS_CLI}" CONFIG GET maxmemory || true
  "${REDIS_CLI}" CONFIG GET maxmemory-policy || true
  "${REDIS_CLI}" CONFIG GET save || true
  "${REDIS_CLI}" CONFIG GET appendonly || true
  "${REDIS_CLI}" CONFIG GET appendfsync || true
} >>"${MASTER_OUT}" 2>&1

# ===== COMMANDSTATS / HitRatio =====
{
  hdr "COMMAND STATS (топ по вызовам/времени)"
  "${REDIS_CLI}" INFO commandstats 2>/dev/null || true
  "${REDIS_CLI}" INFO commandstats 2>/dev/null | awk -F[:,=] '
    /^cmdstat_/{
      cmd=$1; sub(/^cmdstat_/,"",cmd)
      for(i=2;i<=NF;i+=2){ m[$i]=$(i+1) }
      printf "%-20s calls=%-12s usec=%-12s usec_per_call=%s\n", cmd, m["calls"], m["usec"], m["usec_per_call"]
      delete m
    }' | sort -k2,2nr | head -n 20 || true

  echo
  hdr "KEYSPACE HITS/MISSES & HITRATIO"
  "${REDIS_CLI}" INFO stats | grep -E -i 'keyspace_hits|keyspace_misses|expired_keys|evicted_keys' || true
  hits="$("${REDIS_CLI}" INFO stats | awk -F: '/^keyspace_hits:/{print $2}')"
  miss="$("${REDIS_CLI}" INFO stats | awk -F: '/^keyspace_misses:/{print $2}')"
  if [ -n "$hits" ] && [ -n "$miss" ]; then
    total=$((hits+miss))
    if [ "$total" -gt 0 ]; then
      echo "hit_ratio=$(( 100*hits/total ))%"
    fi
  fi
} >>"${MASTER_OUT}" 2>&1

# ===== MODULES / ACL =====
{
  hdr "MODULE LIST"
  "${REDIS_CLI}" MODULE LIST 2>/dev/null || true

  echo
  hdr "ACL LIST / ACL LOG(30)"
  "${REDIS_CLI}" ACL LIST 2>/dev/null || true
  "${REDIS_CLI}" ACL LOG 30 2>/dev/null || true
} >>"${MASTER_OUT}" 2>&1

# ===== PUB/SUB / STREAMS quick-check =====
{
  hdr "PUBSUB CHANNELS / NUMPAT / NUMSUB(top20)"
  "${REDIS_CLI}" PUBSUB CHANNELS 2>/dev/null || true
  "${REDIS_CLI}" PUBSUB NUMPAT 2>/dev/null || true
  read -r -d '' _chans < <("${REDIS_CLI}" PUBSUB CHANNELS 2>/dev/null | head -n20 | tr '\n' ' ' && printf '\0')
  # convert to array for safe word-splitting
  IFS=' ' read -r -a chans_arr <<< "${_chans:-}"
  if [ "${#chans_arr[@]}" -gt 0 ]; then
    "${REDIS_CLI}" PUBSUB NUMSUB "${chans_arr[@]}" 2>/dev/null || true
  fi

  echo
  hdr "STREAMS quick-check (до 50 ключей)"
  cnt=0
  # one-pass scan (не перегружаем)
  "${REDIS_CLI}" --scan --count 200 2>/dev/null | while IFS= read -r k; do
    t="$("${REDIS_CLI}" TYPE "$k" 2>/dev/null || true)"
    if [ "$t" = "stream" ]; then
      xlen="$("${REDIS_CLI}" XLEN "$k" 2>/dev/null || true)"
      printf "%s XLEN=%s\n" "$k" "$xlen"
      cnt=$((cnt+1))
      [ "${cnt}" -ge 50 ] && break
    fi
  done
} >>"${MASTER_OUT}" 2>&1

# ===== Память: фрагментация/дефраг =====
{
  hdr "MEMORY FRAGMENTATION & ACTIVE DEFRAG"
  "${REDIS_CLI}" INFO memory | grep -E -i 'mem_fragmentation_ratio|active_defrag_running|allocator_frag_ratio|allocator_rss_ratio|lazyfree_pending_objects' || true
} >>"${MASTER_OUT}" 2>&1

# ===== LATENCY / SLOWLOG =====
{
  hdr "LATENCY DOCTOR"
  "${REDIS_CLI}" LATENCY DOCTOR || true

  echo
  hdr "LATENCY LATEST"
  "${REDIS_CLI}" LATENCY LATEST || true

  echo
  hdr "SLOWLOG LEN / SLOWLOG GET ${SLOWLOG_LEN}"
  "${REDIS_CLI}" SLOWLOG LEN || true
  "${REDIS_CLI}" SLOWLOG GET "${SLOWLOG_LEN}" || true
} >>"${MASTER_OUT}" 2>&1

# ===== Keyspace =====
KEYSPACE_TXT="$("${REDIS_CLI}" INFO keyspace 2>/dev/null || true)"
printf '%s\n' "${KEYSPACE_TXT}" > "${WORKDIR}/out/keyspace.info.txt"
TOTAL_KEYS="$(printf '%s\n' "${KEYSPACE_TXT}" | awk -F'[=,]' '/^db[0-9]+:keys=/{sum+=$2} END{print (sum+0)}')"

{
  hdr "Суммарное число ключей"
  echo "TOTAL_KEYS=${TOTAL_KEYS}"
} >>"${MASTER_OUT}" 2>&1

decide_probe() {
  local mode="$1" total="$2" max_auto="$3"
  case "$mode" in
    yes) echo yes ;;
    no)  echo no ;;
    auto)
      if [ "${total:-0}" -le "${max_auto:-200000}" ]; then echo yes; else echo no; fi
      ;;
    *) echo no ;;
  esac
}

if have "${REDIS_CLI% *}"; then
  if [ "$(decide_probe "${RUN_BIGKEYS}" "${TOTAL_KEYS}" "${BIGKEYS_MAX_KEYS_AUTO}")" = "yes" ]; then
    {
      hdr "--bigkeys (может занять время)"
      "${REDIS_CLI}" --bigkeys || true
    } >>"${MASTER_OUT}" 2>&1
  else
    {
      hdr "--bigkeys (пропущено)"
      echo "Пропущено (RUN_BIGKEYS=${RUN_BIGKEYS}, TOTAL_KEYS=${TOTAL_KEYS}, порог=${BIGKEYS_MAX_KEYS_AUTO})"
    } >>"${MASTER_OUT}" 2>&1
  fi

  if ${REDIS_CLI} --help 2>&1 | grep -q -- '--memkeys'; then
    if [ "$(decide_probe "${RUN_MEMKEYS}" "${TOTAL_KEYS}" "${BIGKEYS_MAX_KEYS_AUTO}")" = "yes" ]; then
        {
        hdr "--memkeys (samples=${MEMKEYS_SAMPLES})"
        "${REDIS_CLI}" --memkeys --memkeys-samples "${MEMKEYS_SAMPLES}" || true
      } >>"${MASTER_OUT}" 2>&1
    else
      {
        hdr "--memkeys (пропущено)"
        echo "Пропущено (RUN_MEMKEYS=${RUN_MEMKEYS}, TOTAL_KEYS=${TOTAL_KEYS})"
      } >>"${MASTER_OUT}" 2>&1
    fi
  fi
fi

# ===== Репликация / кластер / sentinel =====
{
  hdr "REPLICATION DETAILS (lag/backlog)"
  "${REDIS_CLI}" INFO replication | grep -E -i 'role|master_link_status|master_last_io_seconds_ago|slave_repl_offset|master_replid|repl_backlog_active|repl_backlog_size|repl_backlog_histlen' || true

  echo
  hdr "ROLE / REPLICATION"
  "${REDIS_CLI}" ROLE 2>/dev/null || true
  "${REDIS_CLI}" INFO replication 2>/dev/null || true

  echo
  hdr "CLUSTER HEALTH"
  "${REDIS_CLI}" CLUSTER INFO 2>/dev/null || true
  # Выведем проблемные узлы (не connected)
  "${REDIS_CLI}" CLUSTER NODES 2>/dev/null | grep -E -v ' connected$' || true
  "${REDIS_CLI}" CLUSTER SLOTS 2>/dev/null | head -n 120 || true

  echo
  hdr "SENTINEL masters"
  "${REDIS_CLI}" SENTINEL masters 2>/dev/null || true
} >>"${MASTER_OUT}" 2>&1

# ===== Персистентность: файлы и детали =====
RDB_PATH="$(rc 'CONFIG GET dir' 2>/dev/null | awk 'NR==2{print $1}')"
RDB_NAME="$(rc 'CONFIG GET dbfilename' 2>/dev/null | awk 'NR==2{print $1}')"
AOF_ENABLED="$(rc 'CONFIG GET appendonly' 2>/dev/null | awk 'NR==2{print $1}')"
AOF_NAME="$(rc 'CONFIG GET appendfilename' 2>/dev/null | awk 'NR==2{print $1}')"

{
  hdr "PERSISTENCE DETAILS"
  "${REDIS_CLI}" INFO persistence | grep -E -i 'rdb_(last_.*|changes_since_last_save|bgsave_in_progress)|aof_(enabled|rewrite_in_progress|last_bgrewrite_status|current_rewrite_time_sec|buffer_length|pending_bio_fsync|delayed_fsync)' || true

  echo
  hdr "RDB/AOF файлы"
  if [ -n "${RDB_PATH}" ] && [ -n "${RDB_NAME}" ]; then
    ls -lh -- "${RDB_PATH}/${RDB_NAME}" 2>/dev/null || true
  fi
  if [ "${AOF_ENABLED}" = "yes" ] && [ -n "${RDB_PATH}" ] && [ -n "${AOF_NAME}" ]; then
    ls -lh -- "${RDB_PATH}/${AOF_NAME}" 2>/dev/null || true
  fi
} >>"${MASTER_OUT}" 2>&1

# ===== Ключевые CONFIG влияющие на задержки/IO =====
{
  hdr "CONFIG: производительность и отказоустойчивость"
  "${REDIS_CLI}" CONFIG GET hz tcp-keepalive tcp-backlog client-output-buffer-limit \
    stop-writes-on-bgsave-error rdbcompression rdbchecksum \
    appendonly appendfsync aof-use-rdb-preamble \
    maxmemory maxmemory-policy maxmemory-samples \
    lazyfree-lazy-eviction lazyfree-lazy-expire lazyfree-lazy-server-del \
    replica-serve-stale-data replica-read-only \
    activedefrag yes 2>/dev/null || true
} >>"${MASTER_OUT}" 2>&1

# ===== Логи =====
if have journalctl; then
  {
    hdr "journalctl -u redis (последние ${JOURNAL_MAXLINES})"
    journalctl -u redis --no-pager -n "${JOURNAL_MAXLINES}" || true
  } >>"${MASTER_OUT}" 2>&1
fi

{
  hdr "Хвост логов /var/log/redis* (последние ${LOG_TAIL_LINES})"
  for f in /var/log/redis*.log /var/log/redis/*log; do
    [ -f "$f" ] && { echo "--- $f"; tail -n "${LOG_TAIL_LINES}" "$f"; echo; }
  done
} >>"${MASTER_OUT}" 2>&1

# Поиск «опасных» сообщений
{
  hdr "Redis logs: OOM/latency/aof/rdb warnings"
  for f in /var/log/redis*.log /var/log/redis/*log; do
    [ -f "$f" ] || continue
    echo "--- $f"
  grep -E -i 'OOM|LATENCY.*spike|cluster fail|aof.*error|rdb.*error|loading.*stalled|Rejected.*clients|BUSY.*SCRIPT' "$f" || true
  done
} >>"${MASTER_OUT}" 2>&1

# ===== Опциональные блоки (нагрузочные/внимание) =====
if [ "${RUN_MONITOR}" = "1" ]; then
  {
    hdr "MONITOR (≈5s snapshot)"
    # Ограничим вывод, чтобы не раздуть файл
  timeout 5s "${REDIS_CLI}" MONITOR 2>/dev/null | head -n 1000 || true
  } >>"${MASTER_OUT}" 2>&1
fi

if [ "${RUN_SCAN_PREFIX}" = "1" ]; then
  {
    hdr "SCAN sampling (prefix heatmap)"
    limit="${SCAN_SAMPLE_LIMIT}"
    # Сэмплируем до limit ключей, считаем топ префиксов (до ':' или '|')
  "${REDIS_CLI}" --scan --count 1000 2>/dev/null | \
    awk -v LIM="$limit" '
      function prefix(k){
        split(k,a,/[:|]/); return a[1]
      }
      { p=prefix($0); S[p]++; if(++n>=LIM) exit }
      END{ for(k in S) printf "%-30s %10d\n", k, S[k] }' | \
    sort -k2,2nr | head -n 50 || true
  } >>"${MASTER_OUT}" 2>&1
fi

if [ "${RUN_BENCH}" = "1" ] && have redis-benchmark; then
  {
    hdr "redis-benchmark (light)"
    redis-benchmark -q -n 5000 -c 50 -P 16 ping set get incr lpush rpop sadd hset spop zadd zrem 2>/dev/null || true
  } >>"${MASTER_OUT}" 2>&1
fi

# ===== Окружение: FS/NUMA/affinity =====
{
  hdr "FS for RDB/AOF (df/mount/lsblk)"
  dir="$RDB_PATH"
  if [ -z "$dir" ]; then
  dir="$("${REDIS_CLI}" CONFIG GET dir 2>/dev/null | awk 'NR==2{print $1}')"
  fi
  if [ -n "$dir" ]; then
    df -Th -- "$dir" 2>/dev/null || true
    findmnt -T "$dir" 2>/dev/null || true
  fi
  lsblk -o NAME,KNAME,FSTYPE,MOUNTPOINT,TYPE,ROTA,SIZE,SCHED 2>/dev/null || true

  echo
  hdr "NUMA / CPU affinity"
  if command -v numactl >/dev/null 2>&1; then
    numactl --hardware 2>/dev/null || true
  fi
  p="$(${REDIS_CLI} INFO server 2>/dev/null | awk -F: '/^process_id:/{print $2}')"
  if [ -n "$p" ]; then
    taskset -pc "$p" 2>/dev/null || true
  fi
} >>"${MASTER_OUT}" 2>&1

# ===== Рекомендации (на основе метрик) =====
INFO_ALL="$(${REDIS_CLI} INFO 2>/dev/null || true)"
USED_MEM="$(printf '%s\n' "$INFO_ALL" | awk -F: '/^used_memory:/{print $2+0}')"
MAXMEM="$(printf '%s\n' "$INFO_ALL" | awk -F: '/^maxmemory:/{print $2+0}')"
EVICTED="$(printf '%s\n' "$INFO_ALL" | awk -F: '/^evicted_keys:/{print $2+0}')"
AOF_EN="$(printf '%s\n' "$INFO_ALL" | awk -F: '/^aof_enabled:/{print $2+0}')"
RDB_BGSAVE="$(printf '%s\n' "$INFO_ALL" | awk -F: '/^rdb_last_bgsave_status:/{gsub(/\r/,"",$2);print $2}')"
AOF_LAST_STATUS="$(printf '%s\n' "$INFO_ALL" | awk -F: '/^aof_last_write_status:/{gsub(/\r/,"",$2);print $2}')"
POLICY="$(${REDIS_CLI} CONFIG GET maxmemory-policy 2>/dev/null | awk 'NR==2{print $1}')"

RECO="${WORKDIR}/out/recommendations.txt"
{
  hdr "Рекомендации (черновик)"
  if [ "${MAXMEM:-0}" -eq 0 ]; then
    echo "- Не задан maxmemory: задайте предел (обычно 50–70% RAM под Redis) + корректную политику (allkeys-lru/lfu или volatile-*)."
  else
    if [ "${USED_MEM:-0}" -gt 0 ] && [ $(( USED_MEM * 100 / MAXMEM )) -ge 85 ]; then
      echo "- used_memory >=85% от maxmemory: риск вытеснений/OOM. Увеличьте maxmemory или оптимизируйте структуры/TTL/шардирование."
    fi
  fi
  if [ -n "${POLICY}" ]; then
    echo "- Текущая maxmemory-policy: ${POLICY}. Сверьте с паттерном (кэш vs долговечные данные)."
  fi
  if [ "${EVICTED:-0}" -gt 0 ]; then
    echo "- Evicted keys > 0: нехватает памяти/неверная политика. Проверьте ключи без TTL, bigkeys/memkeys, добавьте TTL/перешардируйте."
  fi
  if [ "${AOF_EN:-0}" -eq 1 ]; then
    echo "- AOF включён: поставьте appendfsync=everysec (обычно оптимум), следите за BGREWRITEAOF и размером файла."
    [ "${AOF_LAST_STATUS:-ok}" != "ok" ] && echo "- AOF last_write_status != ok: проверьте диски/FS/IO."
  else
    echo "- AOF отключён: пересмотрите RPO. Если потеря до 1с недопустима — включите AOF everysec или чаще RDB."
  fi
  [ "${RDB_BGSAVE:-ok}" != "ok" ] && echo "- RDB последний статус не 'ok': проверьте права/свободное место/IO."
  echo "- Отключите THP, поставьте vm.overcommit_memory=1; проверьте net.core.somaxconn и tcp-backlog."
  echo "- При высоких задержках изучите LATENCY/SLOWLOG, разбивайте большие команды/батчи."
  echo "- Используйте --bigkeys/--memkeys для находки «тяжёлых» ключей, добавляйте TTL где возможно."
} > "${RECO}"

# ===== Сводка путей =====
{
  hdr "Сводка путей"
  echo "MASTER_OUT: ${MASTER_OUT}"
  echo "RECOMMENDATIONS: ${RECO}"
  echo "CONF: ${WORKDIR}/conf"
  echo "LOGS: ${WORKDIR}/logs"
  echo "OUT: ${WORKDIR}/out"
} >>"${MASTER_OUT}" 2>&1

# ===== Упаковка =====
source "$(dirname -- "${BASH_SOURCE[0]:-$0}")/audit_common.sh"

# Create short summary file in AUDIT_DIR
SUMMARY_COPY="$AUDIT_DIR/redis_summary.log"
sed -n '1,300p' "${MASTER_OUT}" 2>/dev/null | write_audit_summary "$SUMMARY_COPY"

# Use centralized archive helper; it will exclude access/error logs and verify counts
create_and_verify_archive "${WORKDIR}" "redis.tgz"

{
  hdr "Готово"
  echo "OK: результаты в ${WORKDIR}"
  echo "Архив: ${AUDIT_DIR}/redis.tgz"

} >>"${MASTER_OUT}" 2>&1
