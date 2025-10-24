#!/usr/bin/env bash
# MySQL 8 audit collector — safe read-only
# By default creates a stable tree: ${HOME}/mysql_audit/
# Archive default: ${HOME}/mysql.tgz (no date suffix)

 # Re-exec under a sterile environment for automation to avoid sourcing
 # user/system profiles (and accidentally running interactive menu.sh).
 # If _STERILE is not set and we are in an interactive shell or BASH_ENV is set,
 # re-exec using a minimal env and `bash --noprofile --norc` so the script runs
 # deterministically in automation systems (cron, systemd, CI).
 set -euo pipefail
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
IFS=$'\n\t'
# Default base and per-service workdir. Avoid referencing ROOT_DIR before it's defined
# to prevent unbound variable errors under 'set -u'. Use a safe default under HOME.
WORKDIR="${WORKDIR:-${HOME}/mysql_audit}"
# Standard OUT_DIR and central audit dir
: "${MYSQL_BIN:=mysql}"
: "${MYSQL_OPTS:=}"
: "${N_TOP:=20}"
# fallback, если вдруг section не определена к этому месту
type section >/dev/null 2>&1 || section(){ echo; echo "==== $* ===="; }

# -------- Settings --------
# Use shared audit_common.sh for locale management
source "$(dirname -- "${BASH_SOURCE[0]:-$0}")/audit_common.sh"

# Setup locale using common functions
setup_locale

# Check for root privileges
if [ "$EUID" -ne 0 ]; then
    echo "================================================" >&2
    echo "ВНИМАНИЕ: Скрипт запущен БЕЗ root-прав" >&2
    echo "Некоторые данные будут недоступны:" >&2
    echo "  - Логи в /var/log/mysql/" >&2
    echo "  - Конфигурации в /etc/mysql/" >&2
    echo "  - Системные команды (smartctl, dmidecode)" >&2
    echo "Для полного аудита запустите: sudo $0 $*" >&2
    echo "================================================" >&2
    echo ""
fi

export TZ=${TZ:-Europe/Nicosia}

BASE=${BASE:-${HOME}}                # каталог запуска; по-умолчанию $HOME
# Ensure ROOT_DIR has a sensible default to avoid unbound variable errors
ROOT_DIR="${ROOT_DIR:-${BASE}/mysql_audit}"
# By default keep a stable per-service directory under $HOME (can be overridden)
WORKDIR="${WORKDIR:-${ROOT_DIR}}"

OUT="${OUT:-${HOME%/}/mysql_audit.txt}"
mkdir -p "$(dirname "$OUT")" || true
# Single archive per service under $HOME (no date suffix by default)
ARCHIVE="${ARCHIVE:-${AUDIT_DIR:-${HOME}/audit}/mysql.tgz}"

TIMEOUT=${TIMEOUT:-90}
HARD_TIMEOUT=${HARD_TIMEOUT:-180}
PT_SAMPLE_LINES=${PT_SAMPLE_LINES:-200}
INNODB_STATUS_LINES=${INNODB_STATUS_LINES:-500}
PROCESSLIST_LINES=${PROCESSLIST_LINES:-200}

# mysql опции (креды подтянутся из my.cnf автоматически)
MYSQL_OPTS=(--batch --raw --silent)
MYSQL_TBL_OPTS=(--batch --raw --table --silent)

# -------- Helpers --------
have(){ command -v "$1" >/dev/null 2>&1; }
divider(){ printf '\n'; }

run() { # печать заголовка + выполнение команды (без bash -c)
  local title="$1"; shift
  printf '==== %s ====\n' "$title" | tee -a "$OUT"
  "$@" | tee -a "$OUT" || true
  divider | tee -a "$OUT" >/dev/null
}

# Standard OUT_DIR and central audit dir
OUT_DIR="${OUT_DIR:-${WORKDIR}}"
mkdir -p "$OUT_DIR"/{conf,logs,sql,tooling} 2>/dev/null || true
run_sh(){ # «как есть», но безопасно: ошибки не валят скрипт
  local title="$1"; shift
  printf '==== %s ====\n' "$title" | tee -a "$OUT"
  "$@" | tee -a "$OUT" || true
  divider | tee -a "$OUT" >/dev/null
}

run_mysql(){ # SQL в табличном виде
  local title="$1"; shift
  local sql="$1"
  printf '==== %s ====\n' "$title" | tee -a "$OUT"
  mysql "${MYSQL_TBL_OPTS[@]}" -e "$sql" </dev/null | tee -a "$OUT" || true
  divider | tee -a "$OUT" >/dev/null
}

run_mysql_raw(){ # SQL без рамок таблицы
  local title="$1"; shift
  local sql="$1"
  printf '==== %s ====\n' "$title" | tee -a "$OUT"
  mysql "${MYSQL_OPTS[@]}" -e "$sql" </dev/null | tee -a "$OUT" || true
  divider | tee -a "$OUT" >/dev/null
}

mkdir -p "${WORKDIR}"/{conf,logs,sql,tooling}

# -------- System info --------
run "hostnamectl" hostnamectl
run "uname -a" uname -a

if have tree; then
  run_sh "tree -A /etc/my.cnf.d/" tree -A /etc/my.cnf.d/
  run_sh "tree /etc/mysql/"       tree /etc/mysql/
else
  run_sh "ls -l /etc/my.cnf.d/ (fallback)" ls -l /etc/my.cnf.d/
  run_sh "ls -lR /etc/mysql/ (fallback)"   ls -lR /etc/mysql/
fi

# скопируем конфиги (если есть)
cp -a /etc/my.cnf       "${WORKDIR}/conf/" 2>/dev/null || true
cp -a /etc/my.cnf.d     "${WORKDIR}/conf/" 2>/dev/null || true
cp -a /etc/mysql        "${WORKDIR}/conf/" 2>/dev/null || true
cp -a /etc/mysql/conf.d "${WORKDIR}/conf/" 2>/dev/null || true

# -------- MySQL basics --------
run_mysql "MySQL version" "SELECT @@version AS version, @@version_comment AS version_comment\\G"

# Ключевые переменные (через performance_schema — ORDER BY работает)
run_mysql "GLOBAL VARIABLES (key subset, ordered)" "
SELECT VARIABLE_NAME, VARIABLE_VALUE
FROM performance_schema.global_variables
WHERE VARIABLE_NAME IN (
  'basedir','datadir','tmpdir','log_error','log_error_services',
  'slow_query_log','slow_query_log_file','long_query_time','log_slow_admin_statements','log_queries_not_using_indexes',
  'max_connections','max_connect_errors','thread_cache_size','table_open_cache',
  'innodb_buffer_pool_size','innodb_buffer_pool_instances','innodb_flush_log_at_trx_commit','innodb_log_file_size',
  'innodb_flush_method','innodb_io_capacity','innodb_io_capacity_max','innodb_read_io_threads','innodb_write_io_threads',
  'innodb_file_per_table','performance_schema','sql_mode'
)
ORDER BY VARIABLE_NAME;
"

run_mysql "SHOW VARIABLES LIKE 'innodb%'" "SHOW VARIABLES LIKE 'innodb%';"
run_mysql "SHOW VARIABLES LIKE 'performance_schema%'" "SHOW VARIABLES LIKE 'performance_schema%';"

# Сырые снимки — удобно для пост-анализа
mysql "${MYSQL_OPTS[@]}" -e "SHOW VARIABLES;"     > "${WORKDIR}/sql/variables.tsv"  2>/dev/null || true
mysql "${MYSQL_OPTS[@]}" -e "SHOW GLOBAL STATUS;" > "${WORKDIR}/sql/status.tsv"     2>/dev/null || true

# Статусы/счётчики
run_mysql "Threads / Connections / Uptime" "
SELECT VARIABLE_NAME, VARIABLE_VALUE
FROM performance_schema.global_status
WHERE VARIABLE_NAME IN (
  'Uptime','Threads_connected','Threads_running','Connections','Aborted_connects',
  'Queries','Questions','Com_select','Com_insert','Com_update','Com_delete',
  'Innodb_buffer_pool_reads','Innodb_buffer_pool_read_requests','Innodb_row_lock_time',
  'Innodb_rows_read','Innodb_rows_inserted','Innodb_rows_updated','Innodb_rows_deleted'
)
ORDER BY VARIABLE_NAME;
"

# -------- InnoDB STATUS (жёсткий timeout, без bash -c) --------
printf '==== %s ====\n' "SHOW ENGINE INNODB STATUS (first ${INNODB_STATUS_LINES})" | tee -a "$OUT"
if have timeout; then
  if timeout "${TIMEOUT}s" \
       mysql "${MYSQL_OPTS[@]}" --connect-timeout=5 -e "SHOW ENGINE INNODB STATUS\\G" </dev/null \
       | sed -n "1,${INNODB_STATUS_LINES}p" | tee -a "$OUT"
  then :; else echo "[timeout]" | tee -a "$OUT"; fi
else
  mysql "${MYSQL_OPTS[@]}" -e "SHOW ENGINE INNODB STATUS\\G" </dev/null \
    | sed -n "1,${INNODB_STATUS_LINES}p" | tee -a "$OUT" || true
fi
divider | tee -a "$OUT" >/dev/null

# -------- Deadlocks & Metadata locks --------
# Deadlock information (последние deadlock из INNODB STATUS)
printf '==== %s ====\n' "Recent deadlocks (from INNODB STATUS)" | tee -a "$OUT"
mysql "${MYSQL_OPTS[@]}" -e "SHOW ENGINE INNODB STATUS\\G" </dev/null 2>/dev/null | \
  awk '/LATEST DETECTED DEADLOCK/,/^---/' | sed -n "1,100p" | tee -a "$OUT" || true
divider | tee -a "$OUT" >/dev/null

# Metadata locks (если performance_schema включен)
if "${MYSQL_BIN:-mysql}" "${MYSQL_OPTS[@]:-}" -N -e "SELECT 1 FROM performance_schema.metadata_locks LIMIT 1;" </dev/null >/dev/null 2>&1; then
  run_mysql "Metadata locks (current)" "
  SELECT OBJECT_TYPE, OBJECT_SCHEMA, OBJECT_NAME, LOCK_TYPE, LOCK_DURATION, LOCK_STATUS
  FROM performance_schema.metadata_locks
  WHERE OBJECT_SCHEMA NOT IN ('mysql', 'performance_schema', 'information_schema', 'sys')
  LIMIT 50;
  "
fi

# -------- PROCESSLIST (без подвисаний) --------
printf '==== %s ====\n' "SHOW FULL PROCESSLIST (first ${PROCESSLIST_LINES})" | tee -a "$OUT"
mysql "${MYSQL_OPTS[@]}" --connect-timeout=5 -e "SHOW FULL PROCESSLIST" </dev/null \
  | head -n "${PROCESSLIST_LINES}" | tee -a "$OUT" || true
divider | tee -a "$OUT" >/dev/null

# -------- Размеры таблиц --------
run_mysql "TOP-30 secondary indexes by size (MB)" "
SELECT
  s.database_name AS table_schema,
  s.table_name,
  s.index_name,
  ROUND(s.stat_value*@@innodb_page_size/1024/1024,1) AS MB
FROM mysql.innodb_index_stats s
JOIN information_schema.tables t
  ON t.table_schema=s.database_name AND t.table_name=s.table_name
WHERE s.stat_name='size'
  AND t.table_schema NOT IN ('mysql','performance_schema','information_schema','sys')
  AND t.table_type='BASE TABLE'
ORDER BY MB DESC
LIMIT 30;
"

# -------- Крупные индексы (по innodb_index_stats) --------
run_mysql "TOP-30 secondary indexes by size (MB)" "
SELECT s.database_name AS table_schema, s.table_name, s.index_name,
       ROUND(s.stat_value*@@innodb_page_size/1024/1024) AS MB
FROM mysql.innodb_index_stats s
JOIN information_schema.tables t
  ON t.table_schema=s.database_name AND t.table_name=s.table_name
WHERE s.stat_name='size'
  AND t.table_schema NOT IN ('mysql','performance_schema','information_schema','sys')
ORDER BY MB DESC
LIMIT 30;
"

# -------- Таблицы без PK --------
run_mysql "Tables without PRIMARY KEY" "
SELECT t.table_schema, t.table_name, t.engine
FROM information_schema.tables t
LEFT JOIN information_schema.table_constraints c
  ON c.table_schema=t.table_schema AND c.table_name=t.table_name AND c.constraint_type='PRIMARY KEY'
WHERE t.table_schema NOT IN ('mysql','performance_schema','information_schema','sys')
  AND t.table_type='BASE TABLE'
  AND c.constraint_name IS NULL
ORDER BY t.table_schema, t.table_name;
"

# -------- Активные транзакции / блокировки --------
run_mysql_raw "Active transactions (innodb_trx)" "
SELECT trx_id, trx_mysql_thread_id, trx_started, trx_state, trx_tables_locked,
       trx_rows_locked, trx_rows_modified
FROM information_schema.innodb_trx
ORDER BY trx_started
LIMIT 100;
"

run_mysql_raw "Locks snapshot (performance_schema.data_locks)" "
SELECT ENGINE, OBJECT_SCHEMA, OBJECT_NAME, INDEX_NAME, LOCK_TYPE, LOCK_MODE, LOCK_STATUS, LOCK_DATA
FROM performance_schema.data_locks
LIMIT 200;
"

# -------- sys.schema_unused_indexes (если sys есть) --------
if mysql "${MYSQL_OPTS[@]}" -e "SELECT 1 FROM information_schema.SCHEMATA WHERE SCHEMA_NAME='sys'\\G" | grep -q 1; then
  run_mysql_raw "sys.schema_unused_indexes (if available)" "
SELECT object_schema, object_name, index_name
FROM sys.schema_unused_indexes
ORDER BY object_schema, object_name
LIMIT 200;
"
else
  printf '==== %s ====\n' "sys.schema_unused_indexes (if available)" | tee -a "$OUT"
  echo "sys schema missing - skip." | tee -a "$OUT"
  divider | tee -a "$OUT" >/dev/null
fi

# -------- Long running queries & Table scans --------
# Долгие запросы (активные > 5 секунд)
run_mysql "Long running queries (>5 sec)" "
SELECT
  ID, USER, HOST, DB, COMMAND, TIME, STATE,
  LEFT(INFO, 200) AS QUERY_PREVIEW
FROM information_schema.PROCESSLIST
WHERE COMMAND != 'Sleep'
  AND TIME > 5
ORDER BY TIME DESC
LIMIT 30;
"

# Table scans (full scans without indexes)
run_mysql "Queries with table scans (no index used)" "
SELECT
  DIGEST_TEXT,
  COUNT_STAR AS exec_count,
  SUM_NO_INDEX_USED AS no_index_count,
  SUM_NO_GOOD_INDEX_USED AS no_good_index_count,
  ROUND(SUM_TIMER_WAIT/1000000000000, 2) AS total_time_sec,
  ROUND(AVG_TIMER_WAIT/1000000000000, 3) AS avg_time_sec
FROM performance_schema.events_statements_summary_by_digest
WHERE SUM_NO_INDEX_USED > 0 OR SUM_NO_GOOD_INDEX_USED > 0
ORDER BY SUM_NO_INDEX_USED DESC, SUM_TIMER_WAIT DESC
LIMIT 20;
"

# -------- Логи --------
SLOW="/var/lib/mysql-files/mysql-slow.log"
GEN="/var/lib/mysql-files/mysql.log"

if [ -f "$SLOW" ]; then
  run_sh "[ -f ${SLOW} ] && wc -l" wc -l "$SLOW"
  run_sh "tail -n 60 slowlog"       tail -n 60 "$SLOW"
else
  printf '==== %s ====\n' "tail -n 200 slowlog" | tee -a "$OUT"
  echo "slow log missing" | tee -a "$OUT"
  divider | tee -a "$OUT" >/dev/null
fi

if [ -f "$GEN" ]; then
  run_sh "tail -n 200 general" tail -n 200 "$GEN"
else
  printf '==== %s ====\n' "tail -n 200 general" | tee -a "$OUT"
  echo "general log missing" | tee -a "$OUT"
  divider | tee -a "$OUT" >/dev/null
fi

# -------- pt-query-digest (если есть) --------
if have pt-query-digest && [ -f "$SLOW" ]; then
  printf '==== %s ====\n' "pt-query-digest (first ${PT_SAMPLE_LINES}, full saved)" | tee -a "$OUT"
  if have timeout; then
    if timeout "${HARD_TIMEOUT}s" pt-query-digest "$SLOW" > "${WORKDIR}/tooling/pt-query-digest.txt" 2>&1; then
      sed -n "1,${PT_SAMPLE_LINES}p" "${WORKDIR}/tooling/pt-query-digest.txt" | tee -a "$OUT" || true
    else
      echo "[timeout]" | tee -a "$OUT"
    fi
  else
    pt-query-digest "$SLOW" > "${WORKDIR}/tooling/pt-query-digest.txt" 2>&1 || true
    sed -n "1,${PT_SAMPLE_LINES}p" "${WORKDIR}/tooling/pt-query-digest.txt" | tee -a "$OUT" || true
  fi
  divider | tee -a "$OUT" >/dev/null
fi

# -------- mysqltuner (жёсткий лимит, без --no-ask-password) --------
if have mysqltuner; then
  printf '==== %s ====\n' "mysqltuner (fragment, full saved)" | tee -a "$OUT"
  if have timeout; then
    if timeout "${HARD_TIMEOUT}s" mysqltuner --silent --forcemem --forceswap > "${WORKDIR}/tooling/mysqltuner.txt" 2>&1; then
      sed -n "1,120p" "${WORKDIR}/tooling/mysqltuner.txt" | tee -a "$OUT" || true
    else
      echo "[timeout]" | tee -a "$OUT"
    fi
  else
    mysqltuner --silent --forcemem --forceswap > "${WORKDIR}/tooling/mysqltuner.txt" 2>&1 || true
    sed -n "1,120p" "${WORKDIR}/tooling/mysqltuner.txt" | tee -a "$OUT" || true
  fi
  divider | tee -a "$OUT" >/dev/null
fi

# -------- Percona Toolkit: Index & Configuration Analysis --------
# pt-duplicate-key-checker - поиск дублирующихся и избыточных индексов
if have pt-duplicate-key-checker; then
  printf '==== %s ====\n' "pt-duplicate-key-checker (duplicate/redundant indexes)" | tee -a "$OUT"
  if have timeout; then
    if timeout "${HARD_TIMEOUT}s" pt-duplicate-key-checker --host localhost > "${WORKDIR}/tooling/pt-duplicate-key-checker.txt" 2>&1; then
      sed -n "1,300p" "${WORKDIR}/tooling/pt-duplicate-key-checker.txt" | tee -a "$OUT" || true
    else
      echo "[warn] pt-duplicate-key-checker timeout or error" | tee -a "$OUT"
    fi
  else
    pt-duplicate-key-checker --host localhost > "${WORKDIR}/tooling/pt-duplicate-key-checker.txt" 2>&1 || true
    sed -n "1,300p" "${WORKDIR}/tooling/pt-duplicate-key-checker.txt" | tee -a "$OUT" || true
  fi
  divider | tee -a "$OUT" >/dev/null
fi

# pt-variable-advisor - рекомендации по MySQL переменным
if have pt-variable-advisor; then
  printf '==== %s ====\n' "pt-variable-advisor (configuration recommendations)" | tee -a "$OUT"
  pt-variable-advisor --host localhost 2>&1 | sed -n "1,200p" | tee -a "$OUT" || true
  divider | tee -a "$OUT" >/dev/null
fi

# pt-index-usage - статистика использования индексов (из slow log если доступен)
if have pt-index-usage && [ -f "$SLOW" ]; then
  printf '==== %s ====\n' "pt-index-usage (index usage from slow log)" | tee -a "$OUT"
  pt-index-usage "$SLOW" --host localhost 2>&1 | sed -n "1,200p" | tee -a "$OUT" || true
  divider | tee -a "$OUT" >/dev/null
fi

# -------- Percona summaries --------
if have pt-mysql-summary; then
  printf '==== %s ====\n' "pt-mysql-summary (fragment, full saved)" | tee -a "$OUT"
  if have timeout; then
    if timeout "${HARD_TIMEOUT}s" pt-mysql-summary > "${WORKDIR}/tooling/pt-mysql-summary.txt" 2>&1; then
      sed -n "1,200p" "${WORKDIR}/tooling/pt-mysql-summary.txt" | tee -a "$OUT" || true
    else
      echo "[timeout]" | tee -a "$OUT"
    fi
  else
    pt-mysql-summary > "${WORKDIR}/tooling/pt-mysql-summary.txt" 2>&1 || true
    sed -n "1,200p" "${WORKDIR}/tooling/pt-mysql-summary.txt" | tee -a "$OUT" || true
  fi
  divider | tee -a "$OUT" >/dev/null
fi

if have pt-summary; then
  printf '==== %s ====\n' "pt-summary (fragment, full saved)" | tee -a "$OUT"
  if have timeout; then
    if timeout "${HARD_TIMEOUT}s" pt-summary > "${WORKDIR}/tooling/pt-summary.txt" 2>&1; then
      sed -n "1,200p" "${WORKDIR}/tooling/pt-summary.txt" | tee -a "$OUT" || true
    else
      echo "[timeout]" | tee -a "$OUT"
    fi
  else
    pt-summary > "${WORKDIR}/tooling/pt-summary.txt" 2>&1 || true
    sed -n "1,200p" "${WORKDIR}/tooling/pt-summary.txt" | tee -a "$OUT" || true
  fi
  divider | tee -a "$OUT" >/dev/null
fi

# -------- Примерная оценка hit-ratio буфера --------
run_mysql "InnoDB buffer pool hit ratio (approx)" "
SELECT 1 - (VARIABLE_VALUE_READS / NULLIF(VARIABLE_VALUE_REQ,0)) AS approx_hit_ratio
FROM (
  SELECT
    (SELECT VARIABLE_VALUE FROM performance_schema.global_status WHERE VARIABLE_NAME='Innodb_buffer_pool_reads')            AS VARIABLE_VALUE_READS,
    (SELECT VARIABLE_VALUE FROM performance_schema.global_status WHERE VARIABLE_NAME='Innodb_buffer_pool_read_requests')   AS VARIABLE_VALUE_REQ
) t;
"
# =====================[ ДОПОЛНИТЕЛЬНЫЕ МОДУЛИ ДЛЯ ДИАГНОСТИКИ ]=====================
: "${N_TOP:=20}"
# 1) Temp tables: доля дисковых
run_mysql "Temp tables on disk ratio" "
SELECT
  s1.VARIABLE_VALUE AS Created_tmp_tables,
  s2.VARIABLE_VALUE AS Created_tmp_disk_tables,
  ROUND(100*s2.VARIABLE_VALUE/NULLIF(s1.VARIABLE_VALUE,0),1) AS disk_ratio_pct
FROM performance_schema.global_status s1
JOIN performance_schema.global_status s2
  ON s1.VARIABLE_NAME='Created_tmp_tables' AND s2.VARIABLE_NAME='Created_tmp_disk_tables';
"

# 2) InnoDB Buffer Pool / Hit Ratio (быстрый чек)
run_mysql "InnoDB Buffer Pool — hit ratio" "
SELECT
  (SELECT VARIABLE_VALUE FROM performance_schema.global_status WHERE VARIABLE_NAME='Innodb_buffer_pool_read_requests') AS read_req,
  (SELECT VARIABLE_VALUE FROM performance_schema.global_status WHERE VARIABLE_NAME='Innodb_buffer_pool_reads')         AS reads_miss,
  ROUND(100*(1 - ( (SELECT VARIABLE_VALUE FROM performance_schema.global_status WHERE VARIABLE_NAME='Innodb_buffer_pool_reads')
                /NULLIF((SELECT VARIABLE_VALUE FROM performance_schema.global_status WHERE VARIABLE_NAME='Innodb_buffer_pool_read_requests'),0) )),3) AS hit_ratio_pct;
"

# 3) InnoDB REDO / LSN / Checkpoint age (если INNODB_METRICS включены)
run_mysql "InnoDB REDO / LSN / Checkpoint age" "
SELECT
  MAX(CASE WHEN NAME='log_lsn_current'    THEN COUNT END) AS lsn_curr,
  MAX(CASE WHEN NAME='log_lsn_checkpoint' THEN COUNT END) AS lsn_ckp,
  MAX(CASE WHEN NAME='log_lsn_current'    THEN COUNT END) - MAX(CASE WHEN NAME='log_lsn_checkpoint' THEN COUNT END) AS checkpoint_age
FROM information_schema.INNODB_METRICS
WHERE NAME IN ('log_lsn_current','log_lsn_checkpoint');
"

# 4) Top waits (Performance Schema waits)
run_mysql "Top waits by total time" "
SELECT EVENT_NAME, COUNT_STAR AS cnt,
       ROUND(SUM_TIMER_WAIT/1e12,3) AS total_s,
       ROUND(AVG_TIMER_WAIT/1e9,3)  AS avg_ms
FROM performance_schema.events_waits_summary_global_by_event_name
WHERE SUM_TIMER_WAIT>0
ORDER BY SUM_TIMER_WAIT DESC
LIMIT ${N_TOP};
"

# 5) Долгие транзакции
run_mysql "Long transactions (information_schema.innodb_trx)" "
SELECT trx_id, trx_state, trx_started,
       TIMESTAMPDIFF(SECOND,trx_started,NOW()) AS age_s,
       trx_requested_lock_id, trx_mysql_thread_id
FROM information_schema.innodb_trx
ORDER BY age_s DESC
LIMIT ${N_TOP};
"

# 6) Ожидания блокировок (sys.innodb_lock_waits)
run_mysql "InnoDB lock waits (sys.innodb_lock_waits)" "
SELECT * FROM sys.innodb_lock_waits
LIMIT ${N_TOP};
"

# 7) Агрегация PROCESSLIST по state + sample
run_mysql "Processlist aggregation by State/Query sample" "
SELECT IFNULL(State,'(NULL)') AS state,
       LEFT(IFNULL(Info,''),80) AS sample,
       COUNT(*) AS cnt,
       MAX(TIME) AS max_time_s
FROM information_schema.PROCESSLIST
GROUP BY state, sample
ORDER BY cnt DESC, max_time_s DESC
LIMIT ${N_TOP};
"

# 8) Top digests по ERRORS/WARNINGS
run_mysql "TOP-${N_TOP} digests by ERRORS/WARNINGS" "
SELECT LEFT(DIGEST_TEXT,200) AS sample,
       SUM_ERRORS AS sum_errors,
       SUM_WARNINGS AS sum_warnings,
       COUNT_STAR AS calls
FROM performance_schema.events_statements_summary_by_digest
WHERE (SUM_ERRORS>0 OR SUM_WARNINGS>0)
ORDER BY SUM_ERRORS DESC, SUM_WARNINGS DESC
LIMIT ${N_TOP};
"

# 9) IO по файлам (redo/ibd/tmp) — если доступна sys.x$io_global_by_file_by_bytes
run_mysql "IO by files (sys.x\$io_global_by_file_by_bytes)" "
SELECT
  file,
  IFNULL(count_read,0) AS count_read,
  IFNULL(count_write,0) AS count_write,
  IFNULL(total,0) AS total
FROM sys.x\$io_global_by_file_by_bytes
ORDER BY total DESC
LIMIT ${N_TOP};
"

# 10) Крупнейшие таблицы
run_mysql "Largest tables by size (top ${N_TOP})" "
SELECT TABLE_SCHEMA, TABLE_NAME, ENGINE,
       ROUND(DATA_LENGTH/1024/1024,1)  AS data_mb,
       ROUND(INDEX_LENGTH/1024/1024,1) AS idx_mb,
       ROUND((DATA_LENGTH+INDEX_LENGTH)/1024/1024,1) AS total_mb,
       ROUND(DATA_FREE/1024/1024,1)    AS data_free_mb
FROM information_schema.TABLES
WHERE TABLE_TYPE='BASE TABLE'
ORDER BY (DATA_LENGTH+INDEX_LENGTH) DESC
LIMIT ${N_TOP};
"

# 11) Фрагментация (кандидаты по DATA_FREE)
run_mysql "Fragmentation candidates (DATA_FREE > 256MB)" "
SELECT TABLE_SCHEMA, TABLE_NAME, ENGINE,
       ROUND((DATA_LENGTH+INDEX_LENGTH)/1024/1024,1) AS total_mb,
       ROUND(DATA_FREE/1024/1024,1) AS data_free_mb
FROM information_schema.TABLES
WHERE DATA_FREE>256*1024*1024
ORDER BY DATA_FREE DESC
LIMIT ${N_TOP};
"

# 12) Не-InnoDB таблицы
run_mysql "Non-InnoDB tables (top ${N_TOP})" "
SELECT TABLE_SCHEMA, TABLE_NAME, ENGINE
FROM information_schema.TABLES
WHERE ENGINE IS NOT NULL AND ENGINE!='InnoDB'
ORDER BY TABLE_SCHEMA, TABLE_NAME
LIMIT ${N_TOP};
"

# 13) Эффективность table cache
run_mysql "Table cache efficiency" "
SELECT
  (SELECT VARIABLE_VALUE FROM performance_schema.global_status WHERE VARIABLE_NAME='Opened_tables')            AS Opened_tables,
  (SELECT VARIABLE_VALUE FROM performance_schema.global_status WHERE VARIABLE_NAME='Table_open_cache_hits')   AS Table_open_cache_hits,
  (SELECT VARIABLE_VALUE FROM performance_schema.global_status WHERE VARIABLE_NAME='Table_open_cache_misses') AS Table_open_cache_misses;
"

# 14) Настройки slow log / логирования
run_mysql "Slow log / logging variables" "
SELECT
  @@slow_query_log              AS slow_query_log,
  @@long_query_time             AS long_query_time,
  @@log_output                  AS log_output,
  @@log_error_verbosity         AS log_error_verbosity,
  @@log_slow_admin_statements   AS log_slow_admin_statements,
  @@log_slow_replica_statements AS log_slow_replica_statements;
"

# 15) SQL modes / timeouts
run_mysql "SQL modes / Timeouts / Network" "
SELECT
  @@sql_mode                       AS sql_mode,
  @@transaction_isolation          AS tx_isolation,
  @@innodb_flush_log_at_trx_commit AS innodb_flush_log_at_trx_commit,
  @@sync_binlog                    AS sync_binlog,
  @@wait_timeout                   AS wait_timeout,
  @@interactive_timeout            AS interactive_timeout,
  @@connect_timeout                AS connect_timeout,
  @@net_read_timeout               AS net_read_timeout,
  @@net_write_timeout              AS net_write_timeout,
  @@lock_wait_timeout              AS lock_wait_timeout,
  @@innodb_lock_wait_timeout       AS innodb_lock_wait_timeout;
"

# 15b) Query execution limits (MySQL 5.7.8+) and replication timeout
run_mysql "Query execution limits & Replication timeout" "
SELECT
  @@max_execution_time             AS max_execution_time_global,
  @@SESSION.max_execution_time     AS max_execution_time_session,
  @@slave_net_timeout              AS slave_net_timeout;
"

# 16) Репликация (если есть права/настроена)

# SHOW REPLICA STATUS — только если команда реально работает
if "${MYSQL_BIN:-mysql}" "${MYSQL_OPTS[@]:-}" -e "SHOW REPLICA STATUS\G" </dev/null >/dev/null 2>&1; then
  run_mysql_raw "SHOW REPLICA STATUS" "SHOW REPLICA STATUS\\G"
else
  echo; echo "==== SHOW REPLICA STATUS ====" | tee -a "$LOG"
  echo "[info] replication is not configured or insufficient privileges" | tee -a "$LOG"
fi

# Replication applier by worker — только если таблица доступна и не пустая
if "${MYSQL_BIN:-mysql}" "${MYSQL_OPTS[@]:-}" -N -e "SELECT 1 FROM performance_schema.replication_applier_status_by_worker LIMIT 1;" </dev/null >/dev/null 2>&1; then
  run_mysql "Replication applier by worker" "
SELECT * FROM performance_schema.replication_applier_status_by_worker
ORDER BY CHANNEL_NAME, WORKER_ID
LIMIT ${N_TOP:-20};
"
else
  echo; echo "==== Replication applier by worker ====" | tee -a "$LOG"
  echo "[info] no replication workers (standalone/master) or insufficient privileges" | tee -a "$LOG"
fi

# 17) Binlog / GTID

# Binary logs — печатаем только при включённом @@log_bin
if "${MYSQL_BIN:-mysql}" "${MYSQL_OPTS[@]:-}" -N -e "SELECT @@log_bin;" </dev/null 2>/dev/null | grep -qE '^[1-9]'; then
  run_mysql "Binary logs (SHOW BINARY LOGS)" "SHOW BINARY LOGS;"
else
  echo; echo "==== Binary logs (SHOW BINARY LOGS) ====" | tee -a "${LOG:-/dev/null}"
  echo "[info] binary logging is OFF (@@log_bin=0)" | tee -a "${LOG:-/dev/null}"
fi

# GTID/формат — всегда безопасно (read-only)
run_mysql "Binlog/GTID settings" "
SELECT
  @@log_bin          AS log_bin,
  @@binlog_format    AS binlog_format,
  @@binlog_row_image AS binlog_row_image,
  @@gtid_mode        AS gtid_mode,
  @@enforce_gtid_consistency AS enforce_gtid_consistency;
"

# 18) Performance Schema consumers — включено ли нужное
run_mysql "Performance Schema consumers (enabled)" "
SELECT NAME, ENABLED
FROM performance_schema.setup_consumers
ORDER BY NAME;
"


# ================================================================================

# -------- ДОПОЛНИТЕЛЬНЫЕ ИНСТРУМЕНТЫ MYSQL --------

# MySQLTuner
if have mysqltuner; then
  run_sh "MySQLTuner анализ" mysqltuner --silent
  # Сохраняем вывод mysqltuner в отдельный файл для анализа
  mysqltuner --silent > "${OUT_DIR}/tooling/mysqltuner.txt" 2>&1 || true
  echo "MySQLTuner отчет сохранен в: ${OUT_DIR}/tooling/mysqltuner.txt" | tee -a "$OUT"
else
  echo "==== MySQLTuner анализ ====" | tee -a "$OUT"
  echo "[INFO] MySQLTuner не установлен - рекомендуется для анализа конфигурации MySQL" | tee -a "$OUT"
  echo "Установка: apt-get install mysqltuner (Debian/Ubuntu) или скачать с https://github.com/major/MySQLTuner-perl" | tee -a "$OUT"
fi

# Percona Toolkit - pt-query-digest
if have pt-query-digest; then
  echo "==== pt-query-digest анализ ====" | tee -a "$OUT"
  
  # Ищем slow query log
  SLOW_LOG=""
  if mysql "${MYSQL_OPTS[@]}" -e "SELECT @@slow_query_log_file;" 2>/dev/null | grep -v "@@slow_query_log_file" | grep -v "^$" | head -1 | read -r log_file; then
    if [ -r "$log_file" ]; then
      SLOW_LOG="$log_file"
    fi
  fi
  
  # Также проверяем стандартные пути
  for log_path in /var/log/mysql/slow.log /var/log/mysql/mysql-slow.log /var/log/mysqld.log; do
    if [ -r "$log_path" ]; then
      SLOW_LOG="$log_path"
      break
    fi
  done
  
  if [ -n "$SLOW_LOG" ]; then
    echo "Анализ slow query log: $SLOW_LOG" | tee -a "$OUT"
    pt-query-digest "$SLOW_LOG" > "${OUT_DIR}/tooling/pt_query_digest.txt" 2>&1 || true
    echo "pt-query-digest отчет сохранен в: ${OUT_DIR}/tooling/pt_query_digest.txt" | tee -a "$OUT"
    
    # Показываем топ-5 медленных запросов
    echo "Топ-5 медленных запросов:" | tee -a "$OUT"
    head -50 "${OUT_DIR}/tooling/pt_query_digest.txt" | tee -a "$OUT"
  else
    echo "[INFO] Slow query log не найден или недоступен для чтения" | tee -a "$OUT"
    echo "Рекомендуется включить slow_query_log для анализа производительности" | tee -a "$OUT"
  fi
else
  echo "==== pt-query-digest анализ ====" | tee -a "$OUT"
  echo "[INFO] pt-query-digest не установлен - рекомендуется для анализа медленных запросов" | tee -a "$OUT"
  echo "Установка: apt-get install percona-toolkit (Debian/Ubuntu)" | tee -a "$OUT"
fi

# Percona Toolkit - pt-mysql-summary
if have pt-mysql-summary; then
  run_sh "pt-mysql-summary анализ" pt-mysql-summary
  # Сохраняем вывод pt-mysql-summary в отдельный файл
  pt-mysql-summary > "${OUT_DIR}/tooling/pt_mysql_summary.txt" 2>&1 || true
  echo "pt-mysql-summary отчет сохранен в: ${OUT_DIR}/tooling/pt_mysql_summary.txt" | tee -a "$OUT"
else
  echo "==== pt-mysql-summary анализ ====" | tee -a "$OUT"
  echo "[INFO] pt-mysql-summary не установлен - рекомендуется для комплексного анализа MySQL" | tee -a "$OUT"
  echo "Установка: apt-get install percona-toolkit (Debian/Ubuntu)" | tee -a "$OUT"
fi

# Percona Toolkit - pt-variable-advisor
if have pt-variable-advisor; then
  run_sh "pt-variable-advisor анализ" pt-variable-advisor
  # Сохраняем вывод pt-variable-advisor в отдельный файл
  pt-variable-advisor > "${OUT_DIR}/tooling/pt_variable_advisor.txt" 2>&1 || true
  echo "pt-variable-advisor отчет сохранен в: ${OUT_DIR}/tooling/pt_variable_advisor.txt" | tee -a "$OUT"
else
  echo "==== pt-variable-advisor анализ ====" | tee -a "$OUT"
  echo "[INFO] pt-variable-advisor не установлен - рекомендуется для проверки переменных MySQL" | tee -a "$OUT"
  echo "Установка: apt-get install percona-toolkit (Debian/Ubuntu)" | tee -a "$OUT"
fi

# Percona Toolkit - pt-duplicate-key-checker
if have pt-duplicate-key-checker; then
  run_sh "pt-duplicate-key-checker анализ" pt-duplicate-key-checker
  # Сохраняем вывод pt-duplicate-key-checker в отдельный файл
  pt-duplicate-key-checker > "${OUT_DIR}/tooling/pt_duplicate_key_checker.txt" 2>&1 || true
  echo "pt-duplicate-key-checker отчет сохранен в: ${OUT_DIR}/tooling/pt_duplicate_key_checker.txt" | tee -a "$OUT"
else
  echo "==== pt-duplicate-key-checker анализ ====" | tee -a "$OUT"
  echo "[INFO] pt-duplicate-key-checker не установлен - рекомендуется для поиска дублирующихся индексов" | tee -a "$OUT"
  echo "Установка: apt-get install percona-toolkit (Debian/Ubuntu)" | tee -a "$OUT"
fi

# Percona Toolkit - pt-index-usage
if have pt-index-usage; then
  echo "==== pt-index-usage анализ ====" | tee -a "$OUT"
  echo "[INFO] pt-index-usage требует времени для анализа - запускаем в фоне" | tee -a "$OUT"
  # pt-index-usage может работать долго, поэтому запускаем с таймаутом
  timeout 300 pt-index-usage > "${OUT_DIR}/tooling/pt_index_usage.txt" 2>&1 || true
  if [ -s "${OUT_DIR}/tooling/pt_index_usage.txt" ]; then
    echo "pt-index-usage отчет сохранен в: ${OUT_DIR}/tooling/pt_index_usage.txt" | tee -a "$OUT"
    echo "Топ-10 неиспользуемых индексов:" | tee -a "$OUT"
    head -20 "${OUT_DIR}/tooling/pt_index_usage.txt" | tee -a "$OUT"
  else
    echo "[INFO] pt-index-usage не смог завершиться за 5 минут или не нашел данных" | tee -a "$OUT"
  fi
else
  echo "==== pt-index-usage анализ ====" | tee -a "$OUT"
  echo "[INFO] pt-index-usage не установлен - рекомендуется для анализа использования индексов" | tee -a "$OUT"
  echo "Установка: apt-get install percona-toolkit (Debian/Ubuntu)" | tee -a "$OUT"
fi

# Сводка по дополнительным инструментам
echo "==== Сводка дополнительных инструментов ====" | tee -a "$OUT"
echo "Установленные инструменты:" | tee -a "$OUT"
for tool in mysqltuner pt-query-digest pt-mysql-summary pt-variable-advisor pt-duplicate-key-checker pt-index-usage; do
  if have "$tool"; then
    echo "  ✓ $tool" | tee -a "$OUT"
  else
    echo "  ✗ $tool (рекомендуется установить)" | tee -a "$OUT"
  fi
done

echo "" | tee -a "$OUT"
echo "Рекомендации по установке дополнительных инструментов:" | tee -a "$OUT"
echo "  Debian/Ubuntu: apt-get install mysqltuner percona-toolkit" | tee -a "$OUT"
echo "  CentOS/RHEL: yum install mysqltuner percona-toolkit" | tee -a "$OUT"
echo "  Или скачать MySQLTuner с: https://github.com/major/MySQLTuner-perl" | tee -a "$OUT"

# ================================================================================
printf '==== %s ====' "Pack results" | tee -a "$OUT"
echo "" | tee -a "$OUT"
echo "Workdir: ${WORKDIR}" | tee -a "$OUT"

# Use centralized helper to create archive under $AUDIT_DIR and verify counts.
create_and_verify_archive "$WORKDIR" "mysql.tgz"

divider | tee -a "$OUT" >/dev/null

MYSQL_SUMMARY_COPY="$AUDIT_DIR/mysql_summary.log"
sed -n '1,300p' "$OUT" 2>/dev/null | write_audit_summary "$MYSQL_SUMMARY_COPY"

echo "Done."
