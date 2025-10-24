#!/usr/bin/env bash
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

##### Anti-interactive / BitrixVA #####
exec </dev/null
PS1=
PROMPT_COMMAND=
TMOUT=0
export PS1 PROMPT_COMMAND TMOUT
BASH_ENV=/dev/null
ENV=/dev/null
export BASH_ENV ENV
BX_NOMENU=1
BITRIX_NO_MENU=1
DISABLE_BITRIX_MENU=1
export BX_NOMENU BITRIX_NO_MENU DISABLE_BITRIX_MENU

##### Locale / PATH / Pagers #####
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

# with_locale will run commands with the chosen per-command LANGUAGE and LC_TIME
SYSTEMD_PAGER=
SYSTEMD_COLORS=0
export SYSTEMD_PAGER SYSTEMD_COLORS
export PATH=/usr/sbin:/usr/bin:/sbin:/bin

##### Tunables #####
INCLUDE_PHPINFO="${INCLUDE_PHPINFO:-1}"            # 1/0
PHPINFO_MODE="${PHPINFO_MODE:-full}"               # full|safe
CONF_COPY_MODE="${CONF_COPY_MODE:-loaded}"         # loaded|scan|all

##### Helpers (minimal needed by AUTO SUMMARY)
# Minimal header helper (AUTO SUMMARY runs early and needs this)
hdr(){ printf '\n==== %s ===='"\n" "" "$1"; }

# Ensure probe/report/summary variables exist before AUTO SUMMARY
PROBE_DIR="${PROBE_DIR:-${HOME}/php_audit}"
REPORT="${REPORT:-${PROBE_DIR}/report.txt}"
SUMMARY="${SUMMARY:-${PROBE_DIR}/summary.txt}"
mkdir -p "$PROBE_DIR" "$PROBE_DIR/cmd" "$PROBE_DIR/files" "$PROBE_DIR/conf.d" "$PROBE_DIR/php-fpm" 2>/dev/null || true
mkdir -p "$PROBE_DIR/logs" 2>/dev/null || true
# Timestamp for summaries
TS="${TS:-$(date -u +%Y-%m-%dT%H:%M:%SZ)}"

# Timeouts and log limits (defaults)
TIMEOUT_DEFAULT="5s"
TIMEOUT_LONG="20s"
LOG_TAIL_LINES="200"
LOG_MAX_BYTES=$(( 64*1024 ))
LOG_TOTAL_MAX_BYTES=$(( 512*1024 ))
LOG_COMPRESS_THRESHOLD=$(( 32*1024 ))

# Log inclusion toggles
INCLUDE_PHP_LOGS="${INCLUDE_PHP_LOGS:-1}"
INCLUDE_NGINX_LOGS="${INCLUDE_NGINX_LOGS:-1}"
INCLUDE_HTTPD_LOGS="${INCLUDE_HTTPD_LOGS:-1}"


##### AUTO SUMMARY #####
hdr "AUTO SUMMARY (рекомендации и статус)"
{
  echo "# PHP Audit Summary ($TS)"
  echo
  # Basic key/value facts
  php -r 'echo "PHP_VERSION=".PHP_VERSION."\n";' 2>/dev/null || echo "PHP_VERSION=<php-missing>"
  php -r 'echo "PHP_SAPI=".PHP_SAPI."\n";' 2>/dev/null || echo "PHP_SAPI=<php-missing>"
  php -r 'echo "PHP_INI=".(php_ini_loaded_file()?:"<none>")."\n";' 2>/dev/null || echo "PHP_INI=<php-missing>"
  php -r 'echo "memory_limit=".ini_get("memory_limit")."\n";' 2>/dev/null || echo "memory_limit=<n/a>"
  php -r 'echo "upload_max_filesize=".ini_get("upload_max_filesize")."\n";' 2>/dev/null || echo "upload_max_filesize=<n/a>"
  # Write KV output to a temp file then move into place to avoid races/zero-length files
  TMP_SUMMARY_KV="$PROBE_DIR/summary_kv.txt.tmp"
  with_locale php <<'PHP' > "$TMP_SUMMARY_KV" 2>/dev/null || true
<?php
$out = [];
$out[] = "PHP_VERSION=".PHP_VERSION;
$out[] = "PHP_SAPI=".PHP_SAPI;
$out[] = "PHP_INI=".(php_ini_loaded_file()?:"<none>");
$out[] = "memory_limit=".ini_get("memory_limit");
$out[] = "upload_max_filesize=".ini_get("upload_max_filesize");
$out[] = "post_max_size=".ini_get("post_max_size");
$out[] = "max_execution_time=".ini_get("max_execution_time");
$out[] = "max_input_time=".ini_get("max_input_time");
$out[] = "default_socket_timeout=".ini_get("default_socket_timeout");
$out[] = "mysqlnd.net_read_timeout=".ini_get("mysqlnd.net_read_timeout");
$out[] = "disable_functions=".ini_get("disable_functions");
$out[] = "loaded_extensions_count=".count(get_loaded_extensions());

// opcache quick
if(function_exists('opcache_get_status')){
  $s=@opcache_get_status(false);
  if($s && is_array($s)){
    $mu=$s['memory_usage']??[]; $free=$mu['free_memory']??null; $used=$mu['used_memory']??null; $total=($free!==null&&$used!==null)?$free+$used:null;
    $freePct = ($total && $free!==null) ? sprintf('%.1f',$free*100/$total) : 'n/a';
    $out[] = 'opcache_free_memory_pct='.$freePct;
    $out[] = 'opcache_cache_full='.(isset($s['cache_full'])?($s['cache_full']? 'true':'false'):'n/a');
  }
}

// APCu quick
if(function_exists('apcu_cache_info')){
  $ci=@apcu_cache_info(false);
  if(is_array($ci)){
    $out[] = 'apcu_num_entries='.(isset($ci['num_entries'])?$ci['num_entries']:'n/a');
    $out[] = 'apcu_mem_size='.(isset($ci['mem_size'])?$ci['mem_size']:'n/a');
  }
}

// mysqli/PDO constants
$out[] = 'MYSQLI_OPT_CONNECT_TIMEOUT='.(defined('MYSQLI_OPT_CONNECT_TIMEOUT')?MYSQLI_OPT_CONNECT_TIMEOUT:'<undef>');
$out[] = 'MYSQLI_OPT_READ_TIMEOUT='.(defined('MYSQLI_OPT_READ_TIMEOUT')?MYSQLI_OPT_READ_TIMEOUT:'<undef>');
$out[] = 'PDO_ATTR_TIMEOUT='.(defined('PDO::ATTR_TIMEOUT')?constant('PDO::ATTR_TIMEOUT'):'<undef>');

// more runtime / ini details
$out[] = 'error_log=' . (ini_get('error_log')?:'<none>');
$out[] = 'log_errors=' . ini_get('log_errors');
$out[] = 'display_errors=' . ini_get('display_errors');
$out[] = 'session_save_path=' . (ini_get('session.save_path')?:'<none>');
$out[] = 'upload_tmp_dir=' . (ini_get('upload_tmp_dir')?:'<none>');
$out[] = 'allow_url_fopen=' . ini_get('allow_url_fopen');
$out[] = 'allow_url_include=' . ini_get('allow_url_include');
$out[] = 'open_basedir=' . (ini_get('open_basedir')?:'<none>');
$out[] = 'realpath_cache_size=' . ini_get('realpath_cache_size');
$out[] = 'realpath_cache_ttl=' . ini_get('realpath_cache_ttl');

// opcache config keys
$out[] = 'opcache.memory_consumption=' . ini_get('opcache.memory_consumption');
$out[] = 'opcache.max_accelerated_files=' . ini_get('opcache.max_accelerated_files');
$out[] = 'opcache.file_cache=' . (ini_get('opcache.file_cache')?:'<none>');

// PDO drivers
try {
  $pdodr = is_callable(['PDO','getAvailableDrivers']) ? PDO::getAvailableDrivers() : [];
  $out[] = 'pdo_drivers=' . implode(',', $pdodr);
} catch (Exception $e) { $out[] = 'pdo_drivers='; }

// xdebug mode if present
if (extension_loaded('xdebug')) {
  $out[] = 'xdebug_mode=' . (ini_get('xdebug.mode')?:'<set>');
} else { $out[] = 'xdebug_mode=<absent>'; }

// opcache runtime stats (if available)
if (function_exists('opcache_get_status')) {
  $s = @opcache_get_status(false);
  if ($s && is_array($s)) {
    $stat = $s['opcache_statistics'] ?? [];
    $mu = $s['memory_usage'] ?? [];
    $used = isset($mu['used_memory']) ? $mu['used_memory'] : null;
    $free = isset($mu['free_memory']) ? $mu['free_memory'] : null;
    $total = ($used !== null && $free !== null) ? $used + $free : null;
    $hits = isset($stat['num_hits']) ? $stat['num_hits'] : null;
    $misses = isset($stat['num_misses']) ? $stat['num_misses'] : null;
    $hitRate = ($hits !== null && $misses !== null && ($hits+$misses)>0) ? sprintf('%.2f', $hits*100/($hits+$misses)) : 'n/a';
    $out[] = 'opcache_used_bytes=' . ($used!==null ? $used : 'n/a');
    $out[] = 'opcache_free_bytes=' . ($free!==null ? $free : 'n/a');
    $out[] = 'opcache_total_bytes=' . ($total!==null ? $total : 'n/a');
    $out[] = 'opcache_restart_count=' . ($s['restart_count'] ?? 'n/a');
    $out[] = 'opcache_hits=' . ($hits!==null ? $hits : 'n/a');
    $out[] = 'opcache_misses=' . ($misses!==null ? $misses : 'n/a');
    $out[] = 'opcache_hit_rate=' . $hitRate;
  }
}

foreach($out as $l) echo $l."\n";
PHP
  # Move temp into final location if non-empty, else remove temp
  if [ -s "$TMP_SUMMARY_KV" ]; then mv -f "$TMP_SUMMARY_KV" "$PROBE_DIR/summary_kv.txt"; else rm -f "$TMP_SUMMARY_KV" 2>/dev/null || true; fi

# Additional KV probes: security INI, opcache script counts, xdebug extras, session handler
# and more filesystem/service checks (composer, errorlog stats, php-fpm pools, selinux/time, ulimits)
with_locale php <<'PHP' >> "$PROBE_DIR/summary_kv.txt" 2>/dev/null || true
<?php
$out=[];
$out[]='display_errors='.ini_get('display_errors');
$out[]='expose_php='.ini_get('expose_php');
$out[]='session_cookie_secure='.ini_get('session.cookie_secure');
$out[]='session_cookie_httponly='.ini_get('session.cookie_httponly');
$out[]='session_save_handler='.ini_get('session.save_handler');
$out[]='session_use_strict_mode='.ini_get('session.use_strict_mode');
$out[]='allow_url_fopen='.ini_get('allow_url_fopen');
$out[]='open_basedir='.(ini_get('open_basedir')?:'<none>');

// opcache additional counters
if(function_exists('opcache_get_status')){
  $s=@opcache_get_status(false);
  if($s && is_array($s)){
    $out[]='opcache_num_cached_scripts='.(isset($s['num_cached_scripts'])?$s['num_cached_scripts']:'n/a');
    $out[]='opcache_num_cached_keys='.(isset($s['opcache_statistics']['num_cached_keys'])?$s['opcache_statistics']['num_cached_keys']:'n/a');
  }
}

// xdebug profiling/tracing flags
if(extension_loaded('xdebug')){
  $out[]='xdebug.profiler_enable='.ini_get('xdebug.profiler_enable');
  $out[]='xdebug.start_with_request='.ini_get('xdebug.start_with_request');
}

foreach($out as $l) echo $l."\n";
PHP

# Error log extra stats and logrotate hint
errlog=$(grep -m1 '^error_log=' "$PROBE_DIR/summary_kv.txt" 2>/dev/null | sed 's/^error_log=//' || true)
if [ -n "$errlog" ] && [ "$errlog" != "<none>" ]; then
  if [ -f "$errlog" ]; then
    stat -c 'error_log_size=%s' "$errlog" >> "$PROBE_DIR/summary_kv.txt" 2>/dev/null || true
    stat -c 'error_log_mtime=%Y' "$errlog" >> "$PROBE_DIR/summary_kv.txt" 2>/dev/null || true
  fi
  # quick logrotate detection by exact path or basename
  if grep -R --line-number -F "$errlog" /etc/logrotate.d /etc/logrotate.conf >/dev/null 2>&1; then
    echo "error_log_rotated=1" >> "$PROBE_DIR/summary_kv.txt"
  else
    bname=$(basename "$errlog")
    if grep -R --line-number -F "$bname" /etc/logrotate.d /etc/logrotate.conf >/dev/null 2>&1; then
      echo "error_log_rotated=1" >> "$PROBE_DIR/summary_kv.txt"
    else
      echo "error_log_rotated=0" >> "$PROBE_DIR/summary_kv.txt"
    fi
  fi
fi

# Composer projects / lock detection
composer_projects_count=$(find /home/*/www /var/www /srv/www -maxdepth 3 -type f -name composer.json 2>/dev/null | wc -l || echo 0)
echo "composer_projects_count=${composer_projects_count:-0}" >> "$PROBE_DIR/summary_kv.txt"
composer_lock_found=$(find /home/*/www /var/www /srv/www -maxdepth 3 -type f -name composer.lock 2>/dev/null | wc -l || true)
if [ "${composer_lock_found:-0}" -gt 0 ]; then echo "composer_lock_present=1" >> "$PROBE_DIR/summary_kv.txt"; fi

# Extension versions (parsed from saved php --ri probes)
ext_diag_dir="${EXT_DIAG_DIR:-$PROBE_DIR/cmd/ext_diag}"
for m in opcache apcu redis xdebug; do
  f="$ext_diag_dir/php_ri_${m}.txt"
  if [ -f "$f" ]; then
    ver=$(awk -F: '/[Vv]ersion/ {print $2; exit}' "$f" 2>/dev/null | sed 's/^[[:space:]]*//;s/[[:space:]]*$//') || true
    if [ -n "$ver" ]; then echo "ext_${m}_version=${ver}" >> "$PROBE_DIR/summary_kv.txt"; fi
  fi
done

# Session dir checks: look for php files inside session.save_path
sspath=$(grep -m1 '^session_save_path=' "$PROBE_DIR/summary_kv.txt" 2>/dev/null | sed 's/^session_save_path=//' || true)
if [ -n "$sspath" ] && [ "$sspath" != "<none>" ] && [ -d "$sspath" ]; then
  cnt=$(find "$sspath" -maxdepth 2 -type f -name '*.php' 2>/dev/null | wc -l || echo 0)
  echo "session_save_path_contains_php_files=${cnt:-0}" >> "$PROBE_DIR/summary_kv.txt"
fi

# PHP-FPM pools: read common pool config dirs and report pm/listen/slowlog
while IFS= read -r pc; do
  [ -f "$pc" ] || continue
  pool=$(basename "$pc" .conf)
  pm=$(grep -E '^[[:space:]]*pm\s*=' "$pc" 2>/dev/null | head -n1 | sed -E 's/.*=\s*//; s/\s*$//') || true
  maxc=$(grep -E '^[[:space:]]*(pm\.max_children|pm.max_children)\s*=' "$pc" 2>/dev/null | head -n1 | sed -E 's/.*=\s*//; s/\s*$//') || true
  listen=$(grep -E '^[[:space:]]*listen\s*=' "$pc" 2>/dev/null | head -n1 | sed -E 's/.*=\s*//; s/\s*$//') || true
  slowlog=$(grep -E '^[[:space:]]*slowlog\s*=' "$pc" 2>/dev/null | head -n1 | sed -E 's/.*=\s*//; s/\s*$//') || true
  if [ -n "$pool" ]; then
    [ -n "$pm" ] && echo "phpfpm_pool_${pool}_pm=${pm}" >> "$PROBE_DIR/summary_kv.txt"
    [ -n "$maxc" ] && echo "phpfpm_pool_${pool}_pm_max_children=${maxc}" >> "$PROBE_DIR/summary_kv.txt"
    if [ -n "$listen" ]; then
      echo "phpfpm_pool_${pool}_listen=${listen}" >> "$PROBE_DIR/summary_kv.txt"
      # if listen is unix socket, stat it
      if [[ "$listen" == /* ]] && [ -e "$listen" ]; then
        stat -c "phpfpm_pool_${pool}_listen_perms=%A %a %U:%G" "$listen" >> "$PROBE_DIR/summary_kv.txt" 2>/dev/null || true
      fi
    fi
    [ -n "$slowlog" ] && echo "phpfpm_pool_${pool}_slowlog=${slowlog}" >> "$PROBE_DIR/summary_kv.txt"
  fi
done < <(
  find /etc/php-fpm.d -maxdepth 1 -type f -name '*.conf' 2>/dev/null || true
  find /etc/php -type f -path '*/fpm/pool.d/*.conf' 2>/dev/null || true
  find /etc/php-fpm.conf.d -maxdepth 1 -type f -name '*.conf' 2>/dev/null || true
)

# SELinux / AppArmor quick checks
if command -v getenforce >/dev/null 2>&1; then
  se=$(getenforce 2>/dev/null || true)
  echo "selinux_enforced=${se:-unknown}" >> "$PROBE_DIR/summary_kv.txt"
elif command -v sestatus >/dev/null 2>&1; then
  se=$(sestatus 2>/dev/null | awk -F': ' '/SELinux status/ {print $2; exit}' ) || true
  echo "selinux_enforced=${se:-unknown}" >> "$PROBE_DIR/summary_kv.txt"
fi
if command -v aa-status >/dev/null 2>&1; then
  aa=$(aa-status 2>/dev/null | head -n1 || true)
  echo "apparmor_status=$(printf '%s' "${aa// /_}")" >> "$PROBE_DIR/summary_kv.txt"
fi

# Time sync / timezone
system_time_utc=$(date -u +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || true)
echo "system_time_utc=${system_time_utc}" >> "$PROBE_DIR/summary_kv.txt"
time_sync_ok=0
for s in systemd-timesyncd ntp chronyd ntpd; do
  if systemctl is-active "$s" >/dev/null 2>&1; then time_sync_ok=1; break; fi
done
echo "time_sync_ok=${time_sync_ok}" >> "$PROBE_DIR/summary_kv.txt"

# php-fpm process ulimits (try first running pid)
pfpid=$(pgrep -o php-fpm || true)
if [ -n "$pfpid" ] && [ -r "/proc/$pfpid/limits" ]; then
  nofile=$(awk -F: '/Max open files/ {gsub(/^[ \t]+|[ \t]+$/,"",$2); print $2}' "/proc/$pfpid/limits" 2>/dev/null || true)
  nproc=$(awk -F: '/Max processes/ {gsub(/^[ \t]+|[ \t]+$/,"",$2); print $2}' "/proc/$pfpid/limits" 2>/dev/null || true)
  [ -n "$nofile" ] && echo "phpfpm_proc_nofile=${nofile}" >> "$PROBE_DIR/summary_kv.txt"
  [ -n "$nproc" ] && echo "phpfpm_proc_nproc=${nproc}" >> "$PROBE_DIR/summary_kv.txt"
fi

# Bitrix webroot quick checks: world-writable files count and settings file hashes
bw=$(find /home/*/www /var/www /srv/www -type f -perm /022 -printf '.' 2>/dev/null | wc -c || echo 0)
echo "web_world_writable_files_count=${bw}" >> "$PROBE_DIR/summary_kv.txt"
if [ -n "${PHP_INI_PATH:-}" ] && [ -f "${PHP_INI_PATH}" ]; then
  sha=$(sha256sum "${PHP_INI_PATH}" 2>/dev/null | awk '{print $1}' || true)
  [ -n "$sha" ] && echo "sha256_php_ini=${sha}" >> "$PROBE_DIR/summary_kv.txt"
fi
BITRIX_OUT_DIR="${BITRIX_OUT_DIR:-$PROBE_DIR/bitrix}"
if [ -d "$BITRIX_OUT_DIR" ]; then
  for s in "$BITRIX_OUT_DIR"/*settings.php; do
    [ -f "$s" ] || continue
    site=$(basename "$s" | sed -e 's/\.settings.php$//')
    sha=$(sha256sum "$s" 2>/dev/null | awk '{print $1}' || true)
    [ -n "$sha" ] && echo "sha256_bitrix_${site}_settings=${sha}" >> "$PROBE_DIR/summary_kv.txt"
  done
fi

# (cleanup will be performed later after all KV writes)


## Collect php-fpm pool timeout settings into compact form (if any)
grep -Hn --include='*.conf' -E 'request_terminate_timeout|request_slowlog_timeout' /etc/php* /etc/opt/remi 2>/dev/null \
  | sed -E 's/^([^:]+):([0-9]+):?[[:space:]]*(.*)$/phpfpm_\1_\2=\3/; s#/#_##g' >> "$PROBE_DIR/summary_kv.txt" 2>/dev/null || true

# Post-process some paths/keys produced by PHP heredoc: check existence/perms and capture tails
errlog=$(grep -m1 '^error_log=' "$PROBE_DIR/summary_kv.txt" 2>/dev/null | sed 's/^error_log=//') || true
if [ -n "$errlog" ] && [ "$errlog" != "<none>" ] && [ -f "$errlog" ]; then
  echo "error_log_present=1" >> "$PROBE_DIR/summary_kv.txt" || true
  stat -c 'error_log_perms=%A %a %U:%G' "$errlog" >> "$PROBE_DIR/summary_kv.txt" 2>/dev/null || true
  tail -n 200 "$errlog" > "$PROBE_DIR/logs/exception_error_log.tail.txt" 2>/dev/null || true
  b=$(wc -c < "$PROBE_DIR/logs/exception_error_log.tail.txt" 2>/dev/null || echo 0)
  if [ "$b" -gt "$LOG_COMPRESS_THRESHOLD" ]; then gzip -9f "$PROBE_DIR/logs/exception_error_log.tail.txt"; fi
else
  echo "error_log_present=0" >> "$PROBE_DIR/summary_kv.txt" || true
fi

# session.save_path
sspath=$(grep -m1 '^session_save_path=' "$PROBE_DIR/summary_kv.txt" 2>/dev/null | sed 's/^session_save_path=//') || true
if [ -n "$sspath" ] && [ "$sspath" != "<none>" ] && [ -d "$sspath" ]; then
  echo "session_save_path_present=1" >> "$PROBE_DIR/summary_kv.txt"
  stat -c 'session_save_path_perms=%A %a %U:%G' "$sspath" >> "$PROBE_DIR/summary_kv.txt" 2>/dev/null || true
else
  echo "session_save_path_present=0" >> "$PROBE_DIR/summary_kv.txt"
fi

# upload_tmp_dir
updir=$(grep -m1 '^upload_tmp_dir=' "$PROBE_DIR/summary_kv.txt" 2>/dev/null | sed 's/^upload_tmp_dir=//') || true
if [ -n "$updir" ] && [ "$updir" != "<none>" ] && [ -d "$updir" ]; then
  echo "upload_tmp_dir_present=1" >> "$PROBE_DIR/summary_kv.txt"
  stat -c 'upload_tmp_dir_perms=%A %a %U:%G' "$updir" >> "$PROBE_DIR/summary_kv.txt" 2>/dev/null || true
else
  echo "upload_tmp_dir_present=0" >> "$PROBE_DIR/summary_kv.txt"
fi

# composer presence (quick scan in common locations)
if command -v composer >/dev/null 2>&1; then
  echo "composer_bin=$(command -v composer)" >> "$PROBE_DIR/summary_kv.txt"
fi
for d in /home/*/www /var/www /srv/www; do
  if [ -d "$d" ] && ls "$d"/*/composer.json >/dev/null 2>&1; then
    echo "composer_projects_found=1" >> "$PROBE_DIR/summary_kv.txt"; break
  fi
done

# Expand php-fpm pool parsing: find pm settings and append to summary_kv
grep -Hn --include='*.conf' -E 'pm\.|pm\s*=|pm\.max_children|pm.max_children|pm.start_servers|pm.max_requests|request_terminate_timeout|request_slowlog_timeout' /etc/php* /etc/opt/remi 2>/dev/null \
  | sed -E 's#^([^:]+):([0-9]+):?[[:space:]]*(.*)$#phpfpm_\1_\2=\3#; s#/#_##g' >> "$PROBE_DIR/summary_kv.txt" 2>/dev/null || true

  php -r 'echo "post_max_size=".ini_get("post_max_size")."\n";' 2>/dev/null || echo "post_max_size=<n/a>"
  php -r 'echo "max_execution_time=".ini_get("max_execution_time")."\n";' 2>/dev/null || echo "max_execution_time=<n/a>"
  php -r 'echo "opcache.enable=".ini_get("opcache.enable")."\n";' 2>/dev/null || echo "opcache.enable=<n/a>"

  echo
  # Short opcache health (if available)
  # shellcheck disable=SC2016
  php -d opcache.enable_cli=1 -r 'if(function_exists("opcache_get_status")){$s=@opcache_get_status(false); if($s && is_array($s)){ $mu=$s["memory_usage"]??[]; $free=$mu["free_memory"]??null; $used=$mu["used_memory"]??null; $total=($free!==null&&$used!==null)?$free+$used:null; $freePct = ($total && $free!==null) ? sprintf("%.1f", $free*100/$total) : "n/a"; echo "opcache_free_memory_pct={$freePct}\n"; echo "opcache_cache_full=".($s["cache_full"]?"true":"false")."\n"; } else { echo "opcache_unavailable=1\n"; }}' 2>/dev/null || true

  echo
  # Loaded extensions (comma-separated, truncated)
  php -r 'echo "loaded_extensions=".implode(",",array_slice(get_loaded_extensions(),0,60))."\n";' 2>/dev/null || echo "loaded_extensions=<n/a>"

  echo
  # Core / important INI values
  php -r 'echo "max_execution_time=".ini_get("max_execution_time")."\n";' 2>/dev/null || echo "max_execution_time=<n/a>"
  php -r 'echo "max_input_time=".ini_get("max_input_time")."\n";' 2>/dev/null || echo "max_input_time=<n/a>"
  php -r 'echo "default_socket_timeout=".ini_get("default_socket_timeout")."\n";' 2>/dev/null || echo "default_socket_timeout=<n/a>"
  php -r 'echo "mysqlnd.net_read_timeout=".ini_get("mysqlnd.net_read_timeout")."\n";' 2>/dev/null || echo "mysqlnd.net_read_timeout=<n/a>"

  # disable_functions
  php -r 'echo "disable_functions=".ini_get("disable_functions")."\n";' 2>/dev/null || echo "disable_functions=<n/a>"

  # mysqli / PDO timeout-related constants (if available)
  php -r 'echo "MYSQLI_OPT_CONNECT_TIMEOUT=".(defined("MYSQLI_OPT_CONNECT_TIMEOUT")?MYSQLI_OPT_CONNECT_TIMEOUT:"<undef>")."\n";' 2>/dev/null || true
  php -r 'echo "MYSQLI_OPT_READ_TIMEOUT=".(defined("MYSQLI_OPT_READ_TIMEOUT")?MYSQLI_OPT_READ_TIMEOUT:"<undef>")."\n";' 2>/dev/null || true
  php -r 'echo "PDO_ATTR_TIMEOUT=".(defined("PDO::ATTR_TIMEOUT")?constant("PDO::ATTR_TIMEOUT"):"<undef>")."\n";' 2>/dev/null || true

  echo
  # Paths to important probe artifacts
  echo "probe_dir=$PROBE_DIR"
  echo "report=$REPORT"
  echo "summary=$SUMMARY"
  echo
  # PHP-FPM pool timeouts (request_terminate_timeout / request_slowlog_timeout)
  echo "php_fpm_pool_timeouts:";
  if grep -Hn --include='*.conf' -E 'request_terminate_timeout|request_slowlog_timeout' /etc/php* /etc/opt/remi 2>/dev/null | sed 's/^/  /'; then :; else echo "  (none found)"; fi
} > "$SUMMARY" || true

##### Version / modules #####
hdr "php -v"
with_locale php -v | pipe_save_full "$PROBE_DIR/cmd/php_v.txt" >/dev/null || true

hdr "php -m (модули, отсортировано)"
{ with_locale php -m || true; } | with_locale sort | pipe_save_slim "$PROBE_DIR/cmd/php_m.txt" >/dev/null

##### phpinfo (optional) #####
PHPINFO_FULL="$PROBE_DIR/cmd/php_i.full.txt"
PHPINFO_SAFE="$PROBE_DIR/cmd/php_i.safe.txt"
# Place phpinfo under the per-user probe dir so all artifacts live under $HOME/php_audit
PHPINFO_ROOT="$PROBE_DIR/files/phpinfo.txt"

if [ "$INCLUDE_PHPINFO" = "1" ]; then
  hdr "php -i (mode=$PHPINFO_MODE, timeout ${TIMEOUT_LONG})"
  if [ "$PHPINFO_MODE" = "safe" ]; then
    run_to "$TIMEOUT_DEFAULT" php -n -i | pipe_save_slim "$PHPINFO_SAFE" >/dev/null || true
    if [ -s "$PHPINFO_SAFE" ]; then
      mkdir -p "$(dirname -- "$PHPINFO_ROOT")" 2>/dev/null || true
      cp -a "$PHPINFO_SAFE" "$PHPINFO_ROOT" || true
    fi
  else
    set +e
    if run_to "$TIMEOUT_LONG" php -i | pipe_save_slim "$PHPINFO_FULL" >/dev/null; then
      mkdir -p "$(dirname -- "$PHPINFO_ROOT")" 2>/dev/null || true
      cp -a "$PHPINFO_FULL" "$PHPINFO_ROOT" || true
      echo "[OK] php -i (full)" | tee -a "$REPORT"
    else
      echo "[WARN] full mode timeout → safe" | tee -a "$REPORT"
      run_to "$TIMEOUT_DEFAULT" php -n -i | pipe_save_slim "$PHPINFO_SAFE" >/dev/null || true
      if [ -s "$PHPINFO_SAFE" ]; then
        mkdir -p "$(dirname -- "$PHPINFO_ROOT")" 2>/dev/null || true
        cp -a "$PHPINFO_SAFE" "$PHPINFO_ROOT" || true
      fi
    fi
    set -e
  fi
else
  hdr "php -i — отключено (INCLUDE_PHPINFO=0)"
fi

##### Key INI (для summary) #####
hdr "Ключевые ini-параметры (php -r ...)"
with_locale php <<'PHP' | pipe_save_full "$PROBE_DIR/cmd/php_ini_keys.txt" >/dev/null || true
<?php
$k=[
 "opcache.enable","opcache.enable_cli","opcache.memory_consumption",
 "opcache.max_accelerated_files","opcache.validate_timestamps","opcache.revalidate_freq",
 "realpath_cache_size","realpath_cache_ttl","max_execution_time","memory_limit",
 "post_max_size","upload_max_filesize","date.timezone","error_reporting","display_errors"
];
foreach($k as $p){ printf("%s=%s\n",$p,ini_get($p)); }
PHP

##### OPcache health (CLI one-shot) #####
hdr "OPcache статус (CLI проба с -d opcache.enable_cli=1)"
# shellcheck disable=SC2016
with_locale php -d opcache.enable_cli=1 -r '
if(function_exists("opcache_get_status")){
  $s=@opcache_get_status(false);
  echo $s?json_encode($s,JSON_PRETTY_PRINT|JSON_UNESCAPED_SLASHES):"empty";
}else{ echo "opcache_get_status() недоступна"; }
' | pipe_save_full "$PROBE_DIR/cmd/opcache_status.json" >/dev/null || true

##### Configs copy modes #####
hdr "Конфигурация: php.ini и *.ini/*.conf (mode=$CONF_COPY_MODE)"
PHP_INI_PATH="$(php -r 'echo php_ini_loaded_file() ?: "";' 2>/dev/null || true)"
 if [ -z "$PHP_INI_PATH" ]; then
   PHP_INI_PATH="$(php --ini 2>/dev/null | awk -F': ' '/Loaded Configuration File/ {print $2}')"
 fi
 
 true
INI_SCAN_DIR="$(php --ini 2>/dev/null | awk -F': ' '/Scan for additional .ini files in:/ {print $2}')" || true

echo "Loaded php.ini: ${PHP_INI_PATH:-<none>}" | tee -a "$REPORT"
echo "Scan dir:       ${INI_SCAN_DIR:-<none>}" | tee -a "$REPORT"

case "$CONF_COPY_MODE" in
  loaded)
    [ -n "${PHP_INI_PATH:-}" ] && [ -f "$PHP_INI_PATH" ] && cp -a "$PHP_INI_PATH" "$PROBE_DIR/php.ini"
    if [ -n "${INI_SCAN_DIR:-}" ] && [ -d "$INI_SCAN_DIR" ]; then
      find "$INI_SCAN_DIR" -maxdepth 1 -type f -name '*.ini' -print0 2>/dev/null \
        | xargs -0 -I{} cp -a "{}" "$PROBE_DIR/conf.d/" || true
    fi
    ;;
  scan)
    {
      echo "== Scan dir listing =="
      [ -d "$INI_SCAN_DIR" ] && ls -1 "$INI_SCAN_DIR"/*.ini 2>/dev/null || echo "(нет ini в scan dir)"
    } | pipe_save_full "$PROBE_DIR/conf.d/scan_listing.txt" >/dev/null
    [ -n "${PHP_INI_PATH:-}" ] && [ -f "$PHP_INI_PATH" ] && cp -a "$PHP_INI_PATH" "$PROBE_DIR/php.ini"
    ;;
  all)
    [ -n "${PHP_INI_PATH:-}" ] && [ -f "$PHP_INI_PATH" ] && cp -a "$PHP_INI_PATH" "$PROBE_DIR/php.ini"
    if [ -n "${INI_SCAN_DIR:-}" ] && [ -d "$INI_SCAN_DIR" ]; then
      find "$INI_SCAN_DIR" -maxdepth 1 -type f -name '*.ini' -print0 2>/dev/null \
        | xargs -0 -I{} cp -a "{}" "$PROBE_DIR/conf.d/" || true
    fi
    find /etc -maxdepth 2 -type f \( -path "/etc/php*" -o -path "/etc/opt/remi/php*" \) \
      \( -name "*.ini" -o -name "*.conf" \) -print0 2>/dev/null \
      | while IFS= read -r -d '' src; do
          dst="$PROBE_DIR/files/${src//\//_}"
          cp -a "$src" "$dst" 2>/dev/null || true
        done
    ;;
esac

##### PHP-FPM basic + overrides #####
FPM_BIN="$(command -v php-fpm 2>/dev/null || command -v php-fpm8.3 2>/dev/null || command -v php-fpm8.2 2>/dev/null || true)"
if [ -n "$FPM_BIN" ]; then
  hdr "PHP-FPM: тест конфига/статус"
  {
  echo "bin: $FPM_BIN"
  "${FPM_BIN}" -v 2>&1 | head -n1 || true
  "${FPM_BIN}" -tt 2>&1 || true
    echo; echo "systemctl status (кандидаты):"
    for s in php-fpm php8.3-fpm php8.2-fpm; do
      systemctl --no-pager status "$s" 2>&1 | sed "s/^/[$s] /" || true
    done
    echo; echo "Сокеты/PID:"; ls -l /run/php-fpm* 2>/dev/null || true; pgrep -a php-fpm 2>/dev/null || true
  } | pipe_save_slim "$PROBE_DIR/php-fpm/summary.txt" >/dev/null

  hdr "DIAG: PHP-FPM — php_admin_value/php_value из пулов"
  FPM_OVR_DIR="$PROBE_DIR/php-fpm/overrides"; mkdir -p "$FPM_OVR_DIR"
  for d in /etc/php-fpm.d /etc/php/*/fpm/pool.d /etc/php-fpm.conf.d /etc/opt/remi/php*/php-fpm.d; do
    [ -d "$d" ] || continue
    grep -RInh --binary-files=without-match -E '^\s*(php_admin_value|php_value)\s*=' "$d" 2>/dev/null \
      | pipe_save_full "$FPM_OVR_DIR/values.txt" >/dev/null || true
  done
fi

##### Web stacks linkage (без логов; *.conf only) #####
hdr "Связки: nginx/httpd → fastcgi/php"
if [ -d /etc/nginx ]; then
  {
    echo "== nginx.conf (шапка) =="; head -n 120 /etc/nginx/nginx.conf 2>/dev/null || true
    echo; echo "== fastcgi в nginx =="; grep -RIn --binary-files=without-match -E 'fastcgi_pass|php(-fpm)?\.sock|php-fpm' /etc/nginx 2>/dev/null || true
  } | pipe_save_slim "$PROBE_DIR/nginx/nginx_php.txt" >/dev/null
fi
if [ -d /etc/httpd ] || [ -d /etc/apache2 ]; then
  {
    echo "== php* конфиги apache ==";
    grep -RIn --include='*.conf' --binary-files=without-match \
      -E 'php|fcgi|proxy:unix:/.*php-fpm|SetHandler .*fcgi' \
      /etc/httpd /etc/apache2 2>/dev/null || true
    echo; echo "== httpd -S (виртуальные хосты) =="; (httpd -S 2>/dev/null || apachectl -S 2>/dev/null || true)
  } | pipe_save_slim "$PROBE_DIR/httpd/apache_php.txt" >/dev/null
fi

##### Logs (tight, compressed, global cap) #####
hdr "Хвосты логов PHP/PHP-FPM (по $LOG_TAIL_LINES строк; ≤ ${LOG_MAX_BYTES}B/файл; общ.≤ ${LOG_TOTAL_MAX_BYTES}B)"
LOG_TOTAL_BYTES=0
log_may_continue(){ [ "$LOG_TOTAL_BYTES" -lt "$LOG_TOTAL_MAX_BYTES" ]; }
collect_log_tail(){
  local src="$1" name out tmp bytes
  [ -f "$src" ] || return 0
  log_may_continue || { echo "[SKIP] Глобальный лимит логов достигнут (${LOG_TOTAL_BYTES}/${LOG_TOTAL_MAX_BYTES})" | tee -a "$REPORT"; return 0; }
  name="${src//\//_}"; out="$PROBE_DIR/logs/${name}.tail.txt"; tmp="$out.tmp"
  with_locale tail -n "$LOG_TAIL_LINES" -- "$src" > "$tmp" 2>/dev/null || true
  bytes=$(wc -c < "$tmp" 2>/dev/null || echo 0)
  if [ "$bytes" -gt "$LOG_MAX_BYTES" ]; then
    with_locale tail -c "$LOG_MAX_BYTES" "$tmp" > "$out"
    echo "--- truncated to ${LOG_MAX_BYTES} bytes" >> "$out"
    rm -f "$tmp"
  else
    mv -f "$tmp" "$out"
  fi
  bytes=$(wc -c < "$out" 2>/dev/null || echo 0)
  if [ "$bytes" -gt "$LOG_COMPRESS_THRESHOLD" ]; then gzip -9f "$out"; out="${out}.gz"; bytes=$(wc -c < "$out" 2>/dev/null || echo 0); fi
  LOG_TOTAL_BYTES=$(( LOG_TOTAL_BYTES + bytes ))
  echo "--- $src → $(basename "$out") (bytes=${bytes}, total=${LOG_TOTAL_BYTES}/${LOG_TOTAL_MAX_BYTES})" | tee -a "$REPORT"
}
if [ "$INCLUDE_PHP_LOGS" = "1" ]; then
  for f in /var/log/php-fpm/error.log /var/log/php-fpm/www-error.log /var/log/php/php-fpm.log \
           /var/log/php/errors.log /var/log/php/error.log /var/log/php/exceptions.log; do
    collect_log_tail "$f"; log_may_continue || break
  done
else
  echo "(Отключено INCLUDE_PHP_LOGS=0)" | tee -a "$REPORT"
fi
if [ "$INCLUDE_NGINX_LOGS" = "1" ] && log_may_continue; then
  hdr "Хвосты логов nginx"; for f in /var/log/nginx/error.log /var/log/nginx/access.log; do collect_log_tail "$f"; log_may_continue || break; done
fi
if [ "$INCLUDE_HTTPD_LOGS" = "1" ] && log_may_continue; then
  hdr "Хвосты логов Apache"; for f in /var/log/httpd/error_log /var/log/httpd/access_log /var/log/apache2/error.log /var/log/apache2/access.log; do collect_log_tail "$f"; log_may_continue || break; done
fi

##### DIAG: Extensions (ini vs loaded vs FS) #####
hdr "DIAG: PHP extensions — ini vs реально загружено (CLI)"
EXT_DIAG_DIR="$PROBE_DIR/cmd/ext_diag"; mkdir -p "$EXT_DIAG_DIR"

with_locale php <<'PHP' | pipe_save_full "$EXT_DIAG_DIR/extension_dir.txt" >/dev/null || true
<?php
printf("extension_dir=%s\n", ini_get("extension_dir"));
PHP
EXT_DIR="$(awk -F= '/^extension_dir=/{print $2}' "$EXT_DIAG_DIR/extension_dir.txt" 2>/dev/null || true)"
if [ -n "$EXT_DIR" ] && [ -d "$EXT_DIR" ]; then
  ls -1 "$EXT_DIR"/*.so 2>/dev/null || true
fi \
  | sed 's#.*/##; s#\.so$##' | sort -u \
  | pipe_save_full "$EXT_DIAG_DIR/present_in_fs.txt" >/dev/null

with_locale php <<'PHP' | pipe_save_full "$EXT_DIAG_DIR/loaded_cli.txt" >/dev/null || true
<?php
$ext=get_loaded_extensions(true);
sort($ext,SORT_FLAG_CASE|SORT_STRING);
foreach($ext as $e){ echo strtolower($e),"\n"; }
PHP

: > "$EXT_DIAG_DIR/expected_from_ini.txt"
if [ -n "${INI_SCAN_DIR:-}" ] && [ -d "$INI_SCAN_DIR" ]; then
  grep -RInh --binary-files=without-match -E '^\s*(zend_)?extension\s*=' "$INI_SCAN_DIR" 2>/dev/null \
    | sed -E 's/^\s*(zend_)?extension\s*=\s*//; s#^.*/##; s#\.so$##; s/^php_//' \
    | awk '{print tolower($0)}' | sort -u >> "$EXT_DIAG_DIR/expected_from_ini.txt" || true
fi

# --------------------------------------------------
# Bitrix: exception_handling block analysis
# NOTE: Bitrix-specific analysis has been moved to collect_bitrix.sh
# This includes .settings.php analysis, exception_handling extraction,
# cache analysis, and multi-site configuration support.
# --------------------------------------------------
hdr "Bitrix: exception_handling (moved to collect_bitrix.sh)"
echo "Bitrix-specific analysis has been moved to collect_bitrix.sh"
echo "Run './collect_bitrix.sh' for comprehensive Bitrix analysis including:"
echo "  - .settings.php files analysis"
echo "  - exception_handling configuration"
echo "  - cache directories analysis"
echo "  - multi-site configuration support"
echo "  - cache cleanup recommendations"


comm -23 "$EXT_DIAG_DIR/expected_from_ini.txt" "$EXT_DIAG_DIR/loaded_cli.txt" \
  | pipe_save_full "$EXT_DIAG_DIR/in_ini_but_not_loaded.txt" >/dev/null || true
comm -13 "$EXT_DIAG_DIR/expected_from_ini.txt" "$EXT_DIAG_DIR/loaded_cli.txt" \
  | pipe_save_full "$EXT_DIAG_DIR/loaded_but_not_in_ini.txt" >/dev/null || true

if [ -s "$EXT_DIAG_DIR/in_ini_but_not_loaded.txt" ]; then
  while IFS= read -r e; do
    if grep -qx "$e" "$EXT_DIAG_DIR/present_in_fs.txt" 2>/dev/null; then s="present_in_fs"; else s="MISSING_in_fs"; fi
    printf "%s\t%s\n" "$e" "$s"
  done | pipe_save_full "$EXT_DIAG_DIR/in_ini_not_loaded_fs_check.txt" >/dev/null
fi

for mod in opcache apcu redis xdebug; do
  hdr "php --ri $mod"
  with_locale php --ri "$mod" 2>&1 | pipe_save_full "$EXT_DIAG_DIR/php_ri_${mod}.txt" >/dev/null || true
done

if [ -f /etc/php.d/15-xdebug.ini ] && [ ! -s /etc/php.d/15-xdebug.ini ]; then
  echo "[NOTE] /etc/php.d/15-xdebug.ini is EMPTY (does not enable xdebug)" | tee -a "$REPORT"
fi

##### AUTO SUMMARY #####
hdr "AUTO SUMMARY (рекомендации и статус)"
{
  echo "# PHP Audit Summary ($TS)"
  echo
with_locale php <<'PHP' 2>/dev/null || true
<?php
echo "PHP_VERSION: ", PHP_VERSION, "\n";
echo "PHP_SAPI: ", PHP_SAPI, "\n";
$ini = php_ini_loaded_file(); echo "PHP_INI: ", ($ini?: "<none>"), "\n";
PHP
  echo

  with_locale php <<'PHP' 2>/dev/null || true
  <?php
function toBytes($v){
      if($v==="") return null;
      $v=trim($v); $m=["g"=>1<<30,"m"=>1<<20,"k"=>1<<10];
      $s=strtolower($v); if(is_numeric($s)) return (int)$s;
      $u=substr($s,-1); $n=substr($s,0,-1);
      return (isset($m[$u]) && is_numeric($n)) ? (int)$n*$m[$u] : null;
    }
    function evalBool($name,$val,$want){ $ok = ($val==$want)? "OK":"WARN"; printf("%-28s = %-12s [%s want %s]\n",$name,$val===""?"<empty>":$val,$ok,$want); }
    function evalNumRange($name,$val,$min,$hint){
      if($name==="max_execution_time" && $val==="0"){ printf("%-28s = %-12s [CHECK unlimited; set per-FPM≈120]\n",$name,$val); return; }
      $ok = (is_numeric($val) && $val+0 >= $min) ? "OK":"WARN";
      printf("%-28s = %-12s [%s >= %s%s]\n",$name,$val===""?"<empty>":$val,$ok,$min,$hint);
    }
    function evalBytesMin($name,$val,$minB,$hint){
      $b=toBytes($val); $ok = ($b!==null && $b >= $minB) ? "OK":"WARN";
      printf("%-28s = %-12s [%s >= %s%s]\n",$name,$val===""?"<empty>":$val,$ok,$minB,$hint);
    }

    $kv = ["opcache.enable","opcache.enable_cli","opcache.memory_consumption","opcache.max_accelerated_files","opcache.validate_timestamps","opcache.revalidate_freq","realpath_cache_size","realpath_cache_ttl","max_execution_time","memory_limit","post_max_size","upload_max_filesize","date.timezone"];
    $ini=[]; foreach($kv as $k){ $ini[$k]=ini_get($k); }

    echo "## INI checks\n";
    evalBool("opcache.enable", $ini["opcache.enable"], "1");

    $mb = is_numeric($ini["opcache.memory_consumption"]) ? (int)$ini["opcache.memory_consumption"] : null; // МБ
    $ok = ($mb!==null && $mb >= 256) ? "OK":"WARN";
    printf("%-28s = %-12s [%s >= %s MB; крупные порталы 512–768 MB]\n","opcache.memory_consumption",$ini["opcache.memory_consumption"]===""?"<empty>":$ini["opcache.memory_consumption"],$ok,256);

    evalNumRange("opcache.max_accelerated_files",$ini["opcache.max_accelerated_files"], 100000, " (рекомендуем 100k–200k)");
    $ok = ($ini["opcache.validate_timestamps"]==="0") ? "OK":"CHECK";
    printf("%-28s = %-12s [%s prod=0; dev=1]\n","opcache.validate_timestamps", $ini["opcache.validate_timestamps"]===""?"<empty>":$ini["opcache.validate_timestamps"], $ok);
    if($ini["opcache.validate_timestamps"]==="1"){
      evalNumRange("opcache.revalidate_freq",$ini["opcache.revalidate_freq"], 0, " (обычно 1–2 для dev)");
    }

    evalBytesMin("realpath_cache_size",$ini["realpath_cache_size"], 4096*1024, " (>=4096k)");
    evalNumRange("realpath_cache_ttl",$ini["realpath_cache_ttl"], 300, " (300–600)");

    evalBytesMin("memory_limit",$ini["memory_limit"], 512*1024*1024, " (512M–1024M для Битрикс)");
    evalNumRange("max_execution_time",$ini["max_execution_time"], 90, " (90–120)");

    $post=toBytes($ini["post_max_size"]); $upl=toBytes($ini["upload_max_filesize"]);
    $coh = ($post!==null && $upl!==null && $post >= $upl) ? "OK":"WARN";
    printf("%-28s = %-12s [INFO]\n","post_max_size",$ini["post_max_size"]);
    printf("%-28s = %-12s [INFO]\n","upload_max_filesize",$ini["upload_max_filesize"]);
    printf("%-28s   %-12s [%s upload<=post]\n","size coherence","",$coh);
    $tzok = ($ini["date.timezone"]!=="") ? "OK":"WARN";
    printf("%-28s = %-12s [%s set timezone]\n","date.timezone",$ini["date.timezone"]===""?"<empty>":$ini["date.timezone"],$tzok);
PHP

  echo
  # shellcheck disable=SC2016
  with_locale php -d opcache.enable_cli=1 -r '
    if(function_exists("opcache_get_status")){
      $s=@opcache_get_status(false);
      if($s && is_array($s)){
        $mu=$s["memory_usage"]??[];
        $free=$mu["free_memory"]??null; $used=$mu["used_memory"]??null;
        $total=($free!==null&&$used!==null)?$free+$used:null;
        $freePct = ($total && $free!==null) ? sprintf("%.1f", $free*100/$total) : "n/a";
        $cache_full = isset($s["cache_full"]) ? ($s["cache_full"]?"true":"false") : "n/a";
        $rst = $s["restart_count"] ?? "n/a";
        $okFree = (is_numeric($freePct) && $freePct+0 >= 5) ? "OK":"WARN";
        $okFull = ($cache_full==="false") ? "OK":"WARN";
        echo "## OPcache health (CLI sample)\n";
        printf("free_memory_pct        = %s%%  [%s >=5%%]\n",$freePct,$okFree);
        printf("cache_full             = %s    [%s false]\n",$cache_full,$okFull);
        printf("restart_count          = %s    [INFO ideally low]\n",$rst);
      } else {
        echo "## OPcache health: unavailable\n";
      }
    } else {
      echo "## OPcache health: function not available\n";
    }
  ' 2>/dev/null || true

  echo
  echo "## Extensions reality check (CLI)"
  echo "- loaded_cli:       $PROBE_DIR/cmd/ext_diag/loaded_cli.txt"
  echo "- expected_from_ini:$PROBE_DIR/cmd/ext_diag/expected_from_ini.txt"
  echo "- in_ini_not_loaded:$PROBE_DIR/cmd/ext_diag/in_ini_but_not_loaded.txt"
  echo "- loaded_not_in_ini:$PROBE_DIR/cmd/ext_diag/loaded_but_not_in_ini.txt"
  [ -f /etc/php.d/15-xdebug.ini ] && [ ! -s /etc/php.d/15-xdebug.ini ] && echo "NOTE: /etc/php.d/15-xdebug.ini is EMPTY → xdebug не активируется этим файлом"

  echo
  echo "## php --ri quick probes"
  for m in opcache apcu redis xdebug; do
    printf "%-8s: %s\n" "$m" "$PROBE_DIR/cmd/ext_diag/php_ri_${m}.txt"
  done < "$EXT_DIAG_DIR/in_ini_but_not_loaded.txt"

  echo
  echo "## FPM overrides (если есть)"
  echo "$PROBE_DIR/php-fpm/overrides/values.txt"

} | tee "$SUMMARY"

source "$(dirname -- "${BASH_SOURCE[0]:-$0}")/audit_common.sh"
SUMMARY_COPY="$AUDIT_DIR/php_summary.log"

# Build human-readable summary from compact KV (if present)
HUMAN_SUMMARY="$PROBE_DIR/php_summary_human.txt"
rm -f "$HUMAN_SUMMARY" 2>/dev/null || true
# Final cleanup/dedupe for summary_kv: keep first occurrence of each key and drop stray lines
if [ -f "$PROBE_DIR/summary_kv.txt" ]; then
  awk -F'=' 'NF>=2{key=$1; if(!seen[key]++){print}}' "$PROBE_DIR/summary_kv.txt" > "$PROBE_DIR/summary_kv.txt.clean" || true
  mv -f "$PROBE_DIR/summary_kv.txt.clean" "$PROBE_DIR/summary_kv.txt" 2>/dev/null || true
fi
kv_get(){
  # Primary: summary_kv.txt produced by PHP heredoc
  local v
  v=$(grep -m1 "^$1=" "$PROBE_DIR/summary_kv.txt" 2>/dev/null | sed 's/^[^=]*=//' || true)
  if [ -n "$v" ]; then printf '%s' "$v"; return 0; fi
  # Fallback: parse human-readable summary (AUTO SUMMARY) for lines like 'key: value' or 'KEY: value'
  # Try patterns: 'KEY: value' (case-insensitive), then 'key ... = value' lines from INI checks
  v=$(sed -n '1,200p' "$PROBE_DIR/summary.txt" 2>/dev/null | sed -n "s/^[[:space:]]*${1}[:][[:space:]]*\(.*\)/\1/pI" | head -n1 || true)
  if [ -z "$v" ]; then
    v=$(sed -n '1,240p' "$PROBE_DIR/summary.txt" 2>/dev/null | sed -n "s/^[[:space:]]*${1}[[:space:]]*=\([[:print:]]*\)/\1/pI" | head -n1 || true)
  fi
  # strip trailing ' [..]' annotations
  v=$(printf '%s' "$v" | sed -E 's/\s*\[[^\]]+\]\s*$//')
  printf '%s' "${v:-}";
}
pv(){ printf "%s: %s\n" "$1" "${2:-<missing>}" >> "$HUMAN_SUMMARY"; }

echo "PHP Audit Summary — $TS" > "$HUMAN_SUMMARY"
echo "Host: $HOST" >> "$HUMAN_SUMMARY"
echo >> "$HUMAN_SUMMARY"

pv "PHP version" "$(kv_get PHP_VERSION)"
pv "SAPI" "$(kv_get PHP_SAPI)"
pv "Loaded php.ini" "$(kv_get PHP_INI)"
echo >> "$HUMAN_SUMMARY"

pv "memory_limit" "$(kv_get memory_limit)"
pv "upload_max_filesize" "$(kv_get upload_max_filesize)"
pv "post_max_size" "$(kv_get post_max_size)"

ME=$(kv_get max_execution_time)
if [ "$ME" = "0" ]; then
  pv "max_execution_time" "$ME (unlimited)"
else
  pv "max_execution_time" "$ME"
fi
pv "max_input_time" "$(kv_get max_input_time)"
pv "default_socket_timeout" "$(kv_get default_socket_timeout)"
pv "mysqlnd.net_read_timeout" "$(kv_get mysqlnd.net_read_timeout)"

DF=$(kv_get disable_functions)
pv "disable_functions" "${DF:-(none)}"

# Evaluate key settings and append simple OK/WARN guidance
eval_note(){ echo "  - $1: $2" >> "$HUMAN_SUMMARY"; }
is_int(){ printf '%s' "$1" | grep -Eq '^[0-9]+$'; }

echo >> "$HUMAN_SUMMARY"
echo "Quick checks:" >> "$HUMAN_SUMMARY"

# max_execution_time checks
if [ "$ME" = "0" ]; then
  eval_note "max_execution_time" "WARN: unlimited (0) — can allow runaway scripts"
elif is_int "$ME"; then
  if [ "$ME" -lt 90 ]; then
    eval_note "max_execution_time" "WARN: $ME sec (recommended >=90 for long jobs)"
  else
    eval_note "max_execution_time" "OK: $ME sec"
  fi
else
  eval_note "max_execution_time" "INFO: $ME"
fi

# max_input_time check (simple)
MI=$(kv_get max_input_time)
if is_int "$MI"; then
  if [ "$MI" -lt 60 ]; then
    eval_note "max_input_time" "WARN: $MI sec (may be too low for large uploads)"
  else
    eval_note "max_input_time" "OK: $MI sec"
  fi
else
  eval_note "max_input_time" "INFO: $MI"
fi

# default_socket_timeout and mysqlnd.net_read_timeout
DST=$(kv_get default_socket_timeout)
if is_int "$DST"; then
  if [ "$DST" -lt 15 ]; then
    eval_note "default_socket_timeout" "WARN: $DST sec (short timeout may affect slow network ops)"
  else
    eval_note "default_socket_timeout" "OK: $DST sec"
  fi
else
  eval_note "default_socket_timeout" "INFO: $DST"
fi

MNR=$(kv_get mysqlnd.net_read_timeout)
if is_int "$MNR"; then
  if [ "$MNR" -lt 30 ]; then
    eval_note "mysqlnd.net_read_timeout" "WARN: $MNR sec (may be too low for some queries)"
  else
    eval_note "mysqlnd.net_read_timeout" "OK: $MNR sec"
  fi
else
  eval_note "mysqlnd.net_read_timeout" "INFO: $MNR"
fi

# disable_functions check for common dangerous entries
if [ -n "$DF" ] && [ "$DF" != "(none)" ]; then
  dangerous=$(printf '%s' "$DF" | tr ',' '\n' | grep -E -x '^(exec|shell_exec|system|passthru|proc_open|popen|pcntl_exec)$' || true)
  if [ -n "$dangerous" ]; then
    eval_note "disable_functions" "OK: contains dangerous funcs disabled -> $dangerous"
  else
    eval_note "disable_functions" "INFO: functions disabled list exists"
  fi
else
  eval_note "disable_functions" "WARN: none — consider disabling exec/shell_exec/system to harden PHP"
fi

# opcache free memory
OP_FREE=$(kv_get opcache_free_memory_pct)
if printf '%s' "$OP_FREE" | grep -Eq '^[0-9]+(\.[0-9]+)?$'; then
  # compare with 5.0 threshold using awk
  if awk "BEGIN{print ($OP_FREE+0) < 5 ? 1:0}" | grep -q 1; then
    eval_note "opcache_free_memory_pct" "WARN: $OP_FREE% (<5% means cache nearly full)"
  else
    eval_note "opcache_free_memory_pct" "OK: $OP_FREE%"
  fi
else
  eval_note "opcache_free_memory_pct" "INFO: $OP_FREE"
fi

pv "Loaded extensions (count)" "$(kv_get loaded_extensions_count)"

# Additional threshold checks: display_errors, expose_php, allow_url_fopen, xdebug, opcache hit rate/cache_full
DE=$(kv_get display_errors)
if [ -n "$DE" ] && [ "$DE" != "0" ]; then eval_note "display_errors" "WARN: enabled (should be 0 in prod)"; else eval_note "display_errors" "OK: disabled"; fi
EX=$(kv_get expose_php)
if [ -n "$EX" ] && [ "$EX" != "0" ]; then eval_note "expose_php" "WARN: enabled (exposes PHP version)"; else eval_note "expose_php" "OK: disabled"; fi
AUF=$(kv_get allow_url_fopen)
if [ "$AUF" = "1" ]; then eval_note "allow_url_fopen" "WARN: enabled (security risk)"; else eval_note "allow_url_fopen" "OK: disabled"; fi
XDBG=$(kv_get xdebug_mode)
if [ -n "$XDBG" ] && [ "$XDBG" != "<absent>" ] && [ "$XDBG" != "off" ]; then eval_note "xdebug_mode" "WARN: xdebug enabled ($XDBG) — may impact performance"; else eval_note "xdebug_mode" "OK: absent/off"; fi

# opcache hit rate
OH=$(kv_get opcache_hit_rate)
if printf '%s' "$OH" | grep -Eq '^[0-9]+(\.[0-9]+)?$'; then
  if awk "BEGIN{print ($OH+0) < 85 ? 1:0}" | grep -q 1; then eval_note "opcache_hit_rate" "WARN: $OH% (<85%)"; else eval_note "opcache_hit_rate" "OK: $OH%"; fi
else
  eval_note "opcache_hit_rate" "INFO: $OH"
fi
OCF=$(kv_get opcache_cache_full)
if [ "${OCF,,}" = "true" ]; then eval_note "opcache_cache_full" "WARN: cache_full=true"; fi

# composer hint
CP=$(kv_get composer_projects_count)
if [ -n "$CP" ] && [ "$CP" -gt 0 ] 2>/dev/null; then eval_note "composer_projects" "INFO: $CP projects with composer.json found"; fi

# web world-writable files
WWW=$(kv_get web_world_writable_files_count)
if [ -n "$WWW" ] && [ "$WWW" -gt 0 ] 2>/dev/null; then eval_note "web_world_writable_files_count" "WARN: $WWW files are world-writable — check webroots"; else eval_note "web_world_writable_files_count" "OK: none"; fi

# error_log rotation check
ELR=$(kv_get error_log_rotated)
if [ "$ELR" = "0" ]; then eval_note "error_log_rotated" "WARN: no logrotate entry found for error_log"; else eval_note "error_log_rotated" "OK: error_log rotation configured"; fi

# session/upload dir perms check (warn if others/world perms non-zero)
SSP=$(kv_get session_save_path_perms)
if [ -n "$SSP" ]; then
  SSP_MODE=$(printf '%s' "$SSP" | awk '{print $2}' 2>/dev/null || true)
  lastd=${SSP_MODE: -1}
  if [ -n "$lastd" ] && [ "$lastd" != "0" ]; then eval_note "session_save_path_perms" "WARN: last octal digit $lastd -> world/other perms set"; else eval_note "session_save_path_perms" "OK: restrictive"; fi
fi
UPP=$(kv_get upload_tmp_dir_perms)
if [ -n "$UPP" ]; then
  UPP_MODE=$(printf '%s' "$UPP" | awk '{print $2}' 2>/dev/null || true)
  lastd=${UPP_MODE: -1}
  if [ -n "$lastd" ] && [ "$lastd" != "0" ]; then eval_note "upload_tmp_dir_perms" "WARN: last octal digit $lastd -> world/other perms set"; else eval_note "upload_tmp_dir_perms" "OK: restrictive"; fi
fi

# PHP-FPM pool checks: warn if pm_max_children unusually high (>500)
if grep -q '^phpfpm_pool_' "$PROBE_DIR/summary_kv.txt" 2>/dev/null; then
  while IFS='=' read -r key val; do
    case "$key" in
      phpfpm_pool_*_pm_max_children)
        if printf '%s' "$val" | grep -Eq '^[0-9]+$'; then
          if [ "$val" -gt 500 ]; then eval_note "$key" "WARN: $val (high)"; else eval_note "$key" "OK: $val"; fi
        fi
        ;;
    esac
  done < <(grep '^phpfpm_pool_.*_pm_max_children=' "$PROBE_DIR/summary_kv.txt" || true)
fi

OP_FREE=$(kv_get opcache_free_memory_pct)
OP_FULL=$(kv_get opcache_cache_full)
if [ -n "$OP_FREE" ]; then pv "opcache_free_memory_pct" "$OP_FREE"; fi
pv "opcache_cache_full" "${OP_FULL:-n/a}"

AP_ENT=$(kv_get apcu_num_entries)
AP_MEM=$(kv_get apcu_mem_size)
if [ -n "$AP_ENT" ] || [ -n "$AP_MEM" ]; then
  pv "apcu_num_entries" "${AP_ENT:-n/a}"
  pv "apcu_mem_size" "${AP_MEM:-n/a}"
fi

pv "MYSQLI_OPT_CONNECT_TIMEOUT" "$(kv_get MYSQLI_OPT_CONNECT_TIMEOUT)"
pv "MYSQLI_OPT_READ_TIMEOUT" "$(kv_get MYSQLI_OPT_READ_TIMEOUT)"
pv "PDO::ATTR_TIMEOUT" "$(kv_get PDO_ATTR_TIMEOUT)"

# shellcheck disable=SC2129
{
  echo
  echo "PHP-FPM pool timeouts (from configs):"
  grep -Hn --include='*.conf' -E 'request_terminate_timeout|request_slowlog_timeout' /etc/php* /etc/opt/remi 2>/dev/null | sed 's/^/  /' || echo "  (none found)"

  echo
  echo "Probe artifacts (paths):"
  echo "  probe_dir: $PROBE_DIR"
  echo "  report: $REPORT"
  echo "  summary (raw): $SUMMARY"
} >> "$HUMAN_SUMMARY"

echo >> "$HUMAN_SUMMARY"
echo "Artifacts summary:" >> "$HUMAN_SUMMARY"
echo "  Total files under probe_dir: $(find "$PROBE_DIR" -type f 2>/dev/null | wc -l)" >> "$HUMAN_SUMMARY"
echo "  Top largest files (top 5):" >> "$HUMAN_SUMMARY"
find "$PROBE_DIR" -type f -printf '%s	%p
' 2>/dev/null | sort -nr | head -n 5 | awk '{printf "    %9.1f KB  %s\n", $1/1024, $2}' >> "$HUMAN_SUMMARY" || true

# Write human summary to audit dir
write_audit_summary "$SUMMARY_COPY" < "$HUMAN_SUMMARY"

##### Security Audit #####
if [ "${ENABLE_SECURITY_CHECKS:-1}" = "1" ]; then
  hdr "Security Audit"
  
  # Create security report file
  SECURITY_REPORT="${PROBE_DIR}/security_report.txt"
  echo "# PHP Security Audit Report" > "$SECURITY_REPORT"
  echo "Generated: $(date)" >> "$SECURITY_REPORT"
  echo "" >> "$SECURITY_REPORT"
  
  # Check dangerous PHP settings
  hdr "Dangerous PHP Settings Check"
  
  DANGEROUS_SETTINGS=(
    "allow_url_fopen=On"
    "allow_url_include=On"
    "display_errors=On"
    "log_errors=Off"
    "expose_php=On"
    "enable_dl=On"
    "file_uploads=On"
    "register_globals=On"
    "magic_quotes_gpc=On"
  )
  
  for setting in "${DANGEROUS_SETTINGS[@]}"; do
    setting_name=$(echo "$setting" | cut -d= -f1)
    setting_value=$(echo "$setting" | cut -d= -f2)
    
    if php -r "echo ini_get('$setting_name');" 2>/dev/null | grep -q "$setting_value"; then
      echo "[SECURITY] ВНИМАНИЕ: $setting_name = $setting_value (небезопасно)" | tee -a "$SECURITY_REPORT"
    else
      echo "[SECURITY] OK: $setting_name настроен безопасно" | tee -a "$SECURITY_REPORT"
    fi
  done
  
  # Check memory and execution limits
  hdr "Memory and Execution Limits Check"
  
  MEMORY_LIMIT=$(php -r "echo ini_get('memory_limit');" 2>/dev/null || echo "unknown")
  MAX_EXECUTION_TIME=$(php -r "echo ini_get('max_execution_time');" 2>/dev/null || echo "unknown")
  MAX_INPUT_TIME=$(php -r "echo ini_get('max_input_time');" 2>/dev/null || echo "unknown")
  
  echo "[SECURITY] memory_limit: $MEMORY_LIMIT" | tee -a "$SECURITY_REPORT"
  echo "[SECURITY] max_execution_time: $MAX_EXECUTION_TIME" | tee -a "$SECURITY_REPORT"
  echo "[SECURITY] max_input_time: $MAX_INPUT_TIME" | tee -a "$SECURITY_REPORT"
  
  # Check for reasonable limits
  if [[ "$MEMORY_LIMIT" =~ ^[0-9]+$ ]] && [ "$MEMORY_LIMIT" -lt 128 ]; then
    echo "[SECURITY] ВНИМАНИЕ: memory_limit слишком мал ($MEMORY_LIMIT MB)" | tee -a "$SECURITY_REPORT"
  fi
  
  if [[ "$MAX_EXECUTION_TIME" =~ ^[0-9]+$ ]] && [ "$MAX_EXECUTION_TIME" -lt 30 ]; then
    echo "[SECURITY] ВНИМАНИЕ: max_execution_time слишком мал ($MAX_EXECUTION_TIME s)" | tee -a "$SECURITY_REPORT"
  fi
  
  # Check file upload settings
  hdr "File Upload Security Check"
  
  UPLOAD_MAX_FILESIZE=$(php -r "echo ini_get('upload_max_filesize');" 2>/dev/null || echo "unknown")
  POST_MAX_SIZE=$(php -r "echo ini_get('post_max_size');" 2>/dev/null || echo "unknown")
  MAX_FILE_UPLOADS=$(php -r "echo ini_get('max_file_uploads');" 2>/dev/null || echo "unknown")
  
  echo "[SECURITY] upload_max_filesize: $UPLOAD_MAX_FILESIZE" | tee -a "$SECURITY_REPORT"
  echo "[SECURITY] post_max_size: $POST_MAX_SIZE" | tee -a "$SECURITY_REPORT"
  echo "[SECURITY] max_file_uploads: $MAX_FILE_UPLOADS" | tee -a "$SECURITY_REPORT"
  
  # Check for excessive upload limits
  if [[ "$UPLOAD_MAX_FILESIZE" =~ ^[0-9]+M$ ]] && [ "${UPLOAD_MAX_FILESIZE%M}" -gt 100 ]; then
    echo "[SECURITY] ВНИМАНИЕ: upload_max_filesize слишком велик ($UPLOAD_MAX_FILESIZE)" | tee -a "$SECURITY_REPORT"
  fi
  
  # Check session security
  hdr "Session Security Check"
  
  SESSION_COOKIE_SECURE=$(php -r "echo ini_get('session.cookie_secure');" 2>/dev/null || echo "unknown")
  SESSION_COOKIE_HTTPONLY=$(php -r "echo ini_get('session.cookie_httponly');" 2>/dev/null || echo "unknown")
  SESSION_USE_STRICT_MODE=$(php -r "echo ini_get('session.use_strict_mode');" 2>/dev/null || echo "unknown")
  
  echo "[SECURITY] session.cookie_secure: $SESSION_COOKIE_SECURE" | tee -a "$SECURITY_REPORT"
  echo "[SECURITY] session.cookie_httponly: $SESSION_COOKIE_HTTPONLY" | tee -a "$SECURITY_REPORT"
  echo "[SECURITY] session.use_strict_mode: $SESSION_USE_STRICT_MODE" | tee -a "$SECURITY_REPORT"
  
  if [ "$SESSION_COOKIE_SECURE" != "1" ]; then
    echo "[SECURITY] ВНИМАНИЕ: session.cookie_secure отключен (небезопасно для HTTPS)" | tee -a "$SECURITY_REPORT"
  fi
  
  if [ "$SESSION_COOKIE_HTTPONLY" != "1" ]; then
    echo "[SECURITY] ВНИМАНИЕ: session.cookie_httponly отключен (уязвимость XSS)" | tee -a "$SECURITY_REPORT"
  fi
  
  if [ "$SESSION_USE_STRICT_MODE" != "1" ]; then
    echo "[SECURITY] ВНИМАНИЕ: session.use_strict_mode отключен (уязвимость session fixation)" | tee -a "$SECURITY_REPORT"
  fi
  
  # Check for dangerous functions
  hdr "Dangerous Functions Check"
  
  DISABLED_FUNCTIONS=$(php -r "echo ini_get('disable_functions');" 2>/dev/null || echo "")
  
  if [ -n "$DISABLED_FUNCTIONS" ]; then
    echo "[SECURITY] OK: Отключенные функции: $DISABLED_FUNCTIONS" | tee -a "$SECURITY_REPORT"
  else
    echo "[SECURITY] ВНИМАНИЕ: disable_functions не настроен" | tee -a "$SECURITY_REPORT"
  fi
  
  # Check for dangerous extensions
  hdr "Dangerous Extensions Check"
  
  DANGEROUS_EXTENSIONS=("exec" "shell_exec" "system" "passthru" "proc_open" "popen")
  
  for ext in "${DANGEROUS_EXTENSIONS[@]}"; do
    if php -m | grep -q "^$ext$"; then
      echo "[SECURITY] ВНИМАНИЕ: Загружено расширение $ext (потенциально опасно)" | tee -a "$SECURITY_REPORT"
    fi
  done
  
  # Check PHP version for known vulnerabilities
  hdr "PHP Version Security Check"
  
  PHP_VERSION=$(php -r "echo PHP_VERSION;" 2>/dev/null || echo "unknown")
  echo "[SECURITY] PHP Version: $PHP_VERSION" | tee -a "$SECURITY_REPORT"
  
  # Check for very old PHP versions
  if [[ "$PHP_VERSION" =~ ^[0-9]+\.[0-9]+ ]]; then
    MAJOR_MINOR=$(echo "$PHP_VERSION" | cut -d. -f1-2)
    if (( $(echo "$MAJOR_MINOR < 7.4" | bc -l) )); then
      echo "[SECURITY] КРИТИЧНО: PHP $PHP_VERSION не поддерживается (уязвимости безопасности)" | tee -a "$SECURITY_REPORT"
    elif (( $(echo "$MAJOR_MINOR < 8.0" | bc -l) )); then
      echo "[SECURITY] ВНИМАНИЕ: PHP $PHP_VERSION устарел (рекомендуется обновление)" | tee -a "$SECURITY_REPORT"
    fi
  fi
  
  # Check OPcache security
  hdr "OPcache Security Check"
  
  OPCACHE_ENABLED=$(php -r "echo ini_get('opcache.enable');" 2>/dev/null || echo "unknown")
  OPCACHE_VALIDATE_TIMESTAMPS=$(php -r "echo ini_get('opcache.validate_timestamps');" 2>/dev/null || echo "unknown")
  
  echo "[SECURITY] opcache.enable: $OPCACHE_ENABLED" | tee -a "$SECURITY_REPORT"
  echo "[SECURITY] opcache.validate_timestamps: $OPCACHE_VALIDATE_TIMESTAMPS" | tee -a "$SECURITY_REPORT"
  
  if [ "$OPCACHE_ENABLED" != "1" ]; then
    echo "[SECURITY] ВНИМАНИЕ: OPcache отключен (снижение производительности)" | tee -a "$SECURITY_REPORT"
  fi
  
  # Check file permissions
  hdr "File Permissions Check"
  
  # Check PHP configuration files
  for conf_file in /etc/php/*/fpm/php.ini /etc/php/*/cli/php.ini; do
    if [ -f "$conf_file" ]; then
      PERMS=$(stat -c "%a" "$conf_file" 2>/dev/null || echo "unknown")
      if [ "$PERMS" != "644" ] && [ "$PERMS" != "640" ]; then
        echo "[SECURITY] ВНИМАНИЕ: Небезопасные права на $conf_file: $PERMS" | tee -a "$SECURITY_REPORT"
      else
        echo "[SECURITY] OK: Безопасные права на $conf_file: $PERMS" | tee -a "$SECURITY_REPORT"
      fi
    fi
  done
  
  # Generate security summary
  echo "" | tee -a "$SECURITY_REPORT"
  echo "===== Security Summary =====" | tee -a "$SECURITY_REPORT"
  
  CRITICAL_COUNT=$(grep -c "КРИТИЧНО:" "$SECURITY_REPORT" 2>/dev/null || echo "0")
  WARNING_COUNT=$(grep -c "ВНИМАНИЕ:" "$SECURITY_REPORT" 2>/dev/null || echo "0")
  OK_COUNT=$(grep -c "OK:" "$SECURITY_REPORT" 2>/dev/null || echo "0")
  
  echo "[SECURITY] Критичных проблем: $CRITICAL_COUNT" | tee -a "$SECURITY_REPORT"
  echo "[SECURITY] Предупреждений: $WARNING_COUNT" | tee -a "$SECURITY_REPORT"
  echo "[SECURITY] OK проверок: $OK_COUNT" | tee -a "$SECURITY_REPORT"
  
  if [ "$CRITICAL_COUNT" -gt 0 ]; then
    echo "[SECURITY] РЕКОМЕНДАЦИЯ: Немедленно устраните критические проблемы безопасности" | tee -a "$SECURITY_REPORT"
  fi
  
  if [ "$WARNING_COUNT" -gt 0 ]; then
    echo "[SECURITY] РЕКОМЕНДАЦИЯ: Рассмотрите устранение предупреждений безопасности" | tee -a "$SECURITY_REPORT"
  fi
  
  # Add security report to main report
  echo "" | tee -a "$REPORT"
  echo "===== Security Audit Results =====" | tee -a "$REPORT"
  cat "$SECURITY_REPORT" | tee -a "$REPORT"
  
  hdr "Security audit завершен"
else
  hdr "Security Audit"
  echo "Security проверки отключены (ENABLE_SECURITY_CHECKS=0)" | tee -a "$REPORT"
fi

##### Final stats (упаковку делает trap EXIT) #####
ARCHIVE="${ARCHIVE:-${AUDIT_DIR}/php.tgz}"
hdr "Итог: состав артефактов"
{
  echo "Всего файлов: $(find "$PROBE_DIR" -type f | wc -l)"
  echo "Размер каталога: $(du -sh "$PROBE_DIR" | awk '{print $1}')"
  echo
  echo "Top-10 largest files:"
  find "$PROBE_DIR" -type f -printf '%s\t%p\n' | sort -nr | head -n 10 | awk '{printf "%9.1f KB  %s\n",$1/1024,$2}'
  echo
  echo "Archive target: $ARCHIVE"
} | tee -a "$REPORT"

# На этом месте скрипт заканчивается, а упаковку гарантированно выполнит trap EXIT → pack_archive

# pack_archive: create archive from PROBE_DIR into AUDIT_DIR/php.tgz and set ARCHIVE
pack_archive(){
  ARCHIVE_NAME="php.tgz"
  # create archive and print summary
  create_and_verify_archive "$PROBE_DIR" "$ARCHIVE_NAME" || true
  ARCHIVE="$AUDIT_DIR/$ARCHIVE_NAME"
}
trap pack_archive EXIT
