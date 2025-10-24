#!/usr/bin/env bash
# shellcheck disable=SC2317,SC1091
# If this file is sourced from an interactive shell (accidentally), don't execute the main body.
# Prevent running interactive user RCs (for example /root/.bash_profile invoking /root/menu.sh)
if [ "${BASH_SOURCE[0]}" != "$0" ]; then
  cat >&2 <<'MSG'
This script is intended to be executed, not sourced.
To run it in a clean, non-interactive environment use for example:

  env -i HOME=/root PATH=/usr/sbin:/usr/bin:/bin BASH_ENV= bash --noprofile --norc -c '/root/Audit-Bitrix24/collect_nginx.sh'

Or, when root privileges are required:

  sudo env -i HOME=/root PATH=/usr/sbin:/usr/bin:/bin BASH_ENV= bash --noprofile --norc -c '/root/Audit-Bitrix24/collect_nginx.sh'

The script will return immediately when sourced to avoid executing user RC files.
MSG
  return 0 2>/dev/null || exit 0
fi
# Re-exec in a sterile env to avoid interactive profile/menu scripts being sourced by child shells.
# If _STERILE is not set and we are in an interactive shell or BASH_ENV is set, re-exec using a
# minimal env and `bash --noprofile --norc` so the script runs deterministically in automation.
if [ -z "${_STERILE:-}" ] && { [[ $- == *i* ]] || [ -n "${BASH_ENV:-}" ]; }; then
  exec env -i HOME=/root PATH=/usr/sbin:/usr/bin:/bin TERM=xterm-256color BASH_ENV= _STERILE=1 \
    bash --noprofile --norc "$0" "$@"
fi

set -Euo pipefail

# --- 0. Локаль/пути
# Use shared audit_common.sh for locale management
source "$(dirname -- "${BASH_SOURCE[0]:-$0}")/audit_common.sh"

# Setup locale using common functions
setup_locale

# Check for root privileges
if [ "$EUID" -ne 0 ]; then
    echo "================================================" >&2
    echo "ВНИМАНИЕ: Скрипт запущен БЕЗ root-прав" >&2
    echo "Некоторые данные будут недоступны:" >&2
    echo "  - Логи в /var/log/nginx/" >&2
    echo "  - Конфигурации в /etc/nginx/" >&2
    echo "  - Системные команды (smartctl, dmidecode)" >&2
    echo "Для полного аудита запустите: sudo $0 $*" >&2
    echo "================================================" >&2
    echo ""
fi

TS="$(date +%Y%m%d_%H%M%S)"
HOST="$(hostname -f 2>/dev/null || hostname)"
# Use static OUT_ROOT under HOME and static OUT_DIR (no timestamp)
OUT_ROOT="${OUT_ROOT:-${HOME}/nginx_audit}"
OUT_DIR="${OUT_DIR:-${OUT_ROOT}}"
DUMP="$OUT_DIR/dump"
mkdir -p "$DUMP"

# CLI: support --vars-file KEY=VALUE pairs via --vars-file and inline --var KEY=VALUE
VARS_FILE=""
SAVE_CERT_CHAIN=0
VARS_EXTRA=()
AUTO_APPLY=1
while [ "$#" -gt 0 ]; do
  case "$1" in
    --vars-file) VARS_FILE="$2"; shift 2 ;;
    --var) VARS_EXTRA+=("$2"); shift 2 ;;
    --save-cert-chain) SAVE_CERT_CHAIN=1; shift ;;
    --auto-apply) AUTO_APPLY=1; shift ;;
    --no-auto-apply) AUTO_APPLY=0; shift ;;
    --) shift; break ;;
    *) break ;;
  esac
done

# Prepare a temporary vars mapping file used by heuristics (format: key|value)
vars_tmp=$(mktemp 2>/dev/null || printf '/tmp/nginx_vars.%s' "$$_")
if [ -n "$VARS_FILE" ] && [ -f "$VARS_FILE" ]; then
  while IFS= read -r l; do
    [ -z "${l// }" ] && continue
    case "$l" in \#*) continue ;; esac
    k=$(printf '%s' "$l" | awk -F= '{print $1}')
    v=$(printf '%s' "$l" | awk -F= '{sub(/^[^=]*=/,""); print}')
    # strip surrounding quotes
    case "$v" in
      '"'*'"') v="${v#\"}"; v="${v%\"}" ;;
      "'"*"'") v="${v#\'}"; v="${v%\'}" ;;
    esac
    printf '%s|%s\n' "$k" "$v" >> "$vars_tmp"
  done < "$VARS_FILE"
fi
for e in "${VARS_EXTRA[@]:-}"; do
  case "$e" in \#*) continue ;; esac
  k=${e%%=*}
  v=${e#*=}
  case "$v" in
    '"'*'"') v="${v#\"}"; v="${v%\"}" ;;
    "'"*"'") v="${v#\'}"; v="${v%\'}" ;;
  esac
  printf '%s|%s\n' "$k" "$v" >> "$vars_tmp"
done

# If auto-apply is enabled, and a previously-generated auto_vars.txt exists in OUT_DIR,
# merge its key=value pairs into vars_tmp for heuristics, but do not overwrite keys
# already provided by the user via --vars-file or --var. This lets the collector
# progressively remember resolved variables across runs while preserving explicit
# overrides from the user.
if [ "${AUTO_APPLY:-0}" -eq 1 ] && [ -f "$OUT_DIR/auto_vars.txt" ]; then
  while IFS= read -r l; do
    [ -z "${l// }" ] && continue
    case "$l" in \#*) continue ;; esac
    k=${l%%=*}
    v=${l#*=}
    # strip surrounding quotes
    case "$v" in
      '"'*'"') v="${v#\"}"; v="${v%\"}" ;;
      "'"*"'" ) v="${v#\'}"; v="${v%\'}" ;;
    esac
    # append only when key not already present in vars_tmp
    if ! awk -F'|' -v key="$k" '$1==key{exit 1}' "$vars_tmp" 2>/dev/null; then
      printf '%s|%s\n' "$k" "$v" >> "$vars_tmp"
    fi
  done < "$OUT_DIR/auto_vars.txt"
  log "[INFO] AUTO_APPLY: merged auto-vars from $OUT_DIR/auto_vars.txt"
fi

# --- 1. Утилиты
NGINX_BIN="$(command -v nginx || command -v /usr/sbin/nginx || true)"
SYSTEMCTL="$(command -v systemctl || true)"
SS="$(command -v ss || true)"
NETSTAT="$(command -v netstat || true)"
LSOF="$(command -v lsof || true)"
OPENSSL="$(command -v openssl || true)"
TREE="$(command -v tree || true)"
JOURNALCTL="$(command -v journalctl || true)"
CURL="$(command -v curl || true)"
GREP="$(command -v grep || true)"
AWK="$(command -v awk || true)"
SED="$(command -v sed || true)"
MD5="$(command -v md5sum || true)"
SHA256="$(command -v sha256sum || true)"
ZCAT="$(command -v zcat || true)"

log(){ printf '%b\n' "$*" | sed 's/\r//'; }
run(){ log ""; log "==== $* ===="; "$@" || true; }

# ==========================
# СБОР ДАННЫХ (коллектор)
# ==========================

# 1) Система/пакеты
{
  log "===== Контекст ОС/пакетов ====="
  uname -a 2>/dev/null || true
  sed -n '1,200p' /etc/os-release 2>/dev/null || true
  log "\n-- Пакеты nginx --"
  (rpm -qa 2>/dev/null | grep -i '^nginx' || true)
  (dpkg -l 2>/dev/null | grep -i ' nginx' || true)
} > "$OUT_DIR/00_system.txt"

# 2) Версия/флаги Nginx
{
  log "===== Nginx: версия/флаги ====="
  if [ -n "$NGINX_BIN" ]; then
    "$NGINX_BIN" -v 2>&1 || true
    "$NGINX_BIN" -V 2>&1 || true
  else
    log "[WARN] nginx не найден в PATH"
  fi
} > "$OUT_DIR/10_version_build.txt"

# 3) Проверка и полный конфиг
{
  log "===== nginx -t ====="
  if [ -n "$NGINX_BIN" ]; then
    "$NGINX_BIN" -t 2>&1 || true
  fi

  log "\n===== nginx -T ====="
  if [ -n "$NGINX_BIN" ]; then
    "$NGINX_BIN" -T > "$DUMP/nginx_T.txt" 2>&1 || true
    log "Сохранено: $DUMP/nginx_T.txt"
  fi
  # If nginx -T produced nothing (permissions or not installed), fall back to reading /etc/nginx and expanding includes
  if [ ! -s "$DUMP/nginx_T.txt" ]; then
    log "[INFO] nginx -T empty or unavailable, falling back to reading /etc/nginx and expanding include directives"
    # Build a combined dump by recursively expanding include directives found in files under /etc/nginx
    tmplist=$(mktemp)
    printf '%s\n' "/etc/nginx/nginx.conf" > "$tmplist"
    seen=$(mktemp)
    while IFS= read -r f; do
      [ -f "$f" ] || continue
      # avoid processing same file twice
      grep -Fxq "$f" "$seen" 2>/dev/null || printf '%s\n' "$f" >> "$seen"
      # add file contents to dump with a header
      printf '\n# FILE: %s\n' "$f" >> "$DUMP/nginx_T.txt"
      sed -n '1,4000p' "$f" >> "$DUMP/nginx_T.txt" 2>/dev/null || true
      # find include directives and expand globs
      awk '/^\s*include/ { for(i=2;i<=NF;i++) printf("%s\n", $i) }' "$f" 2>/dev/null | sed 's/;\s*$//' | while IFS= read -r inc; do
        # shell-expand globs relative to /etc/nginx if not absolute
        case "$inc" in
          /*) pattern="$inc" ;;
          *) pattern="/etc/nginx/${inc#./}" ;;
        esac
        for nf in $(ls -d $pattern 2>/dev/null || true); do
          # only queue files
          if [ -f "$nf" ]; then
            # avoid loops
            if ! grep -Fxq "$nf" "$seen" 2>/dev/null; then
              printf '%s\n' "$nf" >> "$tmplist"
            fi
          fi
        done
      done
    done < "$tmplist"
    # process queued files (simple breadth-first)
    while IFS= read -r f; do
      [ -f "$f" ] || continue
      # already appended above in loop, skip
      true
    done < "$tmplist"
    rm -f "$tmplist" "$seen" || true
  fi
} > "$OUT_DIR/20_config_test.txt"

# 4) Дерево /etc/nginx + контрольные суммы
{
  CONF_ROOT="/etc/nginx"
  log "===== /etc/nginx: дерево и контрольные суммы ====="
  if [ -d "$CONF_ROOT" ]; then
    if [ -n "$TREE" ]; then
      LC_ALL="$LOCALE" "$TREE" -L 6 -a -F -h --du -p -u -g "$CONF_ROOT" || true
    else
      find "$CONF_ROOT" -maxdepth 6 -printf '%M %u %g %s %TY-%Tm-%Td %TH:%TM %p\n' 2>/dev/null | sort || true
    fi
    log "\n-- sha256sum *.conf --"
  if [ -n "$SHA256" ]; then
    find "$CONF_ROOT" -type f -name '*.conf' -print0 2>/dev/null | xargs -0 "$SHA256" 2>/dev/null || true
  fi
    log "\n-- md5sum *.conf --"
  if [ -n "$MD5" ]; then
    find "$CONF_ROOT" -type f -name '*.conf' -print0 2>/dev/null | xargs -0 "$MD5" 2>/dev/null || true
  fi
  else
    log "[WARN] /etc/nginx отсутствует"
  fi
} > "$OUT_DIR/30_tree_checksums.txt"

# 5) Ключевые директивы из nginx_T.txt
{
  SRC="$DUMP/nginx_T.txt"
  log "===== Ключевые директивы из nginx_T.txt ====="
  if [ -s "$SRC" ]; then
    log "-- worker_* / rlimit_nofile / events --"
  "$GREP" -nE '^\s*(worker_processes|worker_connections|multi_accept|use\s+|worker_rlimit_nofile)\b' "$SRC" || true

    log "\n-- http: gzip/brotli/timeouts/proxy/fastcgi --"
  "$GREP" -nE '^\s*(gzip|gzip_types|brotli|brotli_types|keepalive_timeout|client_header_timeout|client_body_timeout|client_max_body_size|client_header_buffer_size|large_client_header_buffers|send_timeout|ssl_handshake_timeout|proxy_(connect|send|read)_timeout|resolver_timeout|proxy_buffers|proxy_buffer_size|proxy_busy_buffers_size|proxy_max_temp_file_size|fastcgi_(connect|send|read)_timeout|fastcgi_buffers|uwsgi_.*|scgi_.*)\b' "$SRC" || true

    log "\n-- server: listen/ssl/http2/HSTS --"
  "$GREP" -nE '^\s*(server_name|listen|ssl_protocols|ssl_ciphers|ssl_prefer_server_ciphers|ssl_session_cache|ssl_session_timeout|ssl_stapling|ssl_stapling_verify|add_header\s+Strict-Transport-Security)\b' "$SRC" || true

    log "\n-- upstream: балансировка/keepalive --"
  "$GREP" -nE '^\s*upstream\b|^\s*server\s+[0-9.:]+.*(max_fails|fail_timeout|backup|weight|resolve)|^\s*keepalive\s+[0-9]+' "$SRC" || true

    log "\n-- location / rewrite / try_files --"
  "$GREP" -nE '^\s*(location|rewrite|try_files)\b' "$SRC" || true

    log "\n-- include / map / limit_* / real_ip --"
  "$GREP" -nE '^\s*(include|map|limit_req|limit_req_zone|limit_conn|limit_conn_zone|set_real_ip_from|real_ip_header|real_ip_recursive)\b' "$SRC" || true

    log "\n-- логи (log_format/access_log/error_log) --"
  "$GREP" -nE '^\s*(log_format|access_log|error_log)\b' "$SRC" || true

    log "\n-- Bitrix-специфика --"
  "$GREP" -nE '/bx/|push|rtc|im_subscrider|site_enabled|site_avaliable' "$SRC" || true
  else
    log "[WARN] нет $SRC — пропущен парсинг директив"
  fi
} > "$OUT_DIR/40_key_directives.txt"

# 6) include/битые symlink
{
  log "===== include и symlink ====="
  if [ -d /etc/nginx ]; then
  find /etc/nginx -type l -printf 'SYMLINK %p -> %l\n' 2>/dev/null | while IFS= read -r L; do
  T="$(printf '%s' "$L" | "$AWK" "{print \$NF}")"
  P="$(printf '%s' "$L" | "$AWK" "{print \$2}")"
      [ -e "$T" ] || log "[BROKEN] $P -> $T"
    done
    log "\n-- include пути из nginx_T.txt --"
  if [ -s "$DUMP/nginx_T.txt" ]; then
    "$GREP" -nE '^\s*include\s+' "$DUMP/nginx_T.txt" | \
      "$AWK" "{for(i=2;i<=NF;i++) printf(\"%s%s\", \$i, (i<NF ? \" \" : \"\\n\"))}" | "$SED" 's/;*$//' | sort -u || true
  fi
  fi
} > "$OUT_DIR/45_includes_links.txt"

# 7) Сертификаты в /etc/nginx
{
  log "===== SSL/TLS сертификаты ====="
  find /etc/nginx -type f \( -name '*.pem' -o -name '*.crt' -o -name 'fullchain*.pem' -o -name 'cert*.pem' \) 2>/dev/null | sort -u | while IFS= read -r C; do
    log "-- $C"
    stat -c 'perm=%A owner=%U group=%G size=%s mtime=%y' "$C" 2>/dev/null || true
    if [ -n "$OPENSSL" ]; then
      "$OPENSSL" x509 -in "$C" -noout -subject -issuer -dates 2>/dev/null || true
    "$OPENSSL" x509 -in "$C" -noout -text 2>/dev/null | "$GREP" -oE 'DNS:[^,]+' | sed 's/^DNS://;s/^[[:space:]]*//' | sort -u || true
    fi
  done
} > "$OUT_DIR/50_certs.txt"

# 8) PHP/fastcgi
{
  log "===== PHP/CGI интеграция ====="
  "$GREP" -RIn --include='*.conf' -E 'fastcgi_pass|uwsgi_pass|scgi_pass|include\s+fastcgi_params|php-fpm|php.*sock' /etc/nginx 2>/dev/null || true

  log "\n-- fastcgi_params (файл) --"
  if [ -f /etc/nginx/fastcgi_params ]; then
    sed -n '1,200p' /etc/nginx/fastcgi_params || true
  fi

  log "\n-- php-fpm sockets --"
  find /run -maxdepth 2 -type s -name '*php*sock' 2>/dev/null || true
  ss -xlp 2>/dev/null | "$GREP" -i php || true
} > "$OUT_DIR/55_php_fastcgi.txt"

# 9) Порты/процессы/systemd
{
  log "===== Открытые порты (TCP) ====="
  [ -n "$SS" ] && "$SS" -ltnp 2>/dev/null | "$GREP" -E ':(80|443)\s' -n || "$SS" -ltnp 2>/dev/null || true
  log "\n-- Процессы nginx --"
  ps -eo pid,ppid,cmd | "$GREP" '[n]ginx' || true
  log "\n-- systemd unit nginx --"
  if [ -n "$SYSTEMCTL" ]; then
    "$SYSTEMCTL" status nginx 2>&1 | sed -n '1,140p' || true
  fi
} > "$OUT_DIR/60_ports_systemd.txt"

# 65) Активные проверки HTTP/2 и Content-Encoding для SSL-хостов из конфига
{
  PROBE_OUT="$OUT_DIR/65_http2_gzip_probe.txt"
  : > "$PROBE_OUT"

  if [ -z "$CURL" ]; then
    echo "[WARN] curl не найден — пропущены активные проверки" | tee -a "$PROBE_OUT"
  else
    echo "curl version:" | tee -a "$PROBE_OUT"
    "$CURL" -V 2>&1 | sed 's/^/  /' | tee -a "$PROBE_OUT"
    echo | tee -a "$PROBE_OUT"

    # Извлекаем SSL-виртуалки: server{...} с listen 443/ssl или ssl_certificate; берём server_name
    SSL_HOSTS="$(
      awk '
        BEGIN{in_s=0; ssl=0; names=""}
        /^\s*server\s*\{/ {in_s=1; ssl=0; names=""; next}
        in_s && /^\s*\}/ {
          if(ssl && names!=""){
            gsub(/[ \t]+/," ",names); print names
          }
          in_s=0; ssl=0; names=""; next
        }
        in_s {
          if($0 ~ /^\s*listen[ \t]+/ && $0 ~ /443|ssl/) ssl=1;
          if($0 ~ /^\s*ssl_certificate[ \t]+/) ssl=1;
          if($0 ~ /^\s*server_name[ \t]+/){
            line=$0; sub(/.*server_name[ \t]+/,"",line); sub(/;.*/,"",line);
            names = (names==""?line:names" "line)
          }
        }
      ' "$DUMP/nginx_T.txt" 2>/dev/null | tr ' ' '\n' | sed '/^$/d' | sort -u
    )"

    if [ -z "$SSL_HOSTS" ]; then
      echo "[INFO] В конфиге не найдены SSL-хосты (server_name при listen 443/ssl)" | tee -a "$PROBE_OUT"
    else
      echo "Найдено SSL-хостов: $(printf '%s\n' "$SSL_HOSTS" | wc -l)" | tee -a "$PROBE_OUT"
      printf '%s\n' "$SSL_HOSTS" | sed 's/^/  - /' | tee -a "$PROBE_OUT"
      echo | tee -a "$PROBE_OUT"

            printf '%s\n' "$SSL_HOSTS" | while IFS= read -r h; do
        echo "===== $h =====" | tee -a "$PROBE_OUT"

        # 1) ALPN + фактическая версия протокола
  ALPN="$("$CURL" -sS --http2 -H "Host: $h" -o /dev/null -v "https://$h/" 2>&1 | grep -i 'ALPN, server accepted' | head -n1 || true)"
  PROTO="$("$CURL" -sS --http2 -H "Host: $h" -L -o /dev/null -w 'HTTP/%{http_version}\n' "https://$h/" 2>/dev/null || echo '')"
        [ -n "$ALPN" ] && echo "ALPN: $ALPN" | tee -a "$PROBE_OUT"
        [ -n "$PROTO" ] && echo "PROTO: $PROTO" | tee -a "$PROBE_OUT"

        # Optionally save server certificate chain using openssl when requested
        if [ "$SAVE_CERT_CHAIN" -eq 1 ] && command -v openssl >/dev/null 2>&1; then
          s_out_srv="$(timeout 6 bash -c "echo | openssl s_client -connect ${h}:443 -servername ${h} -showcerts 2>/dev/null" || true)"
          if printf '%s' "$s_out_srv" | $GREP -Fq -- '-----BEGIN CERTIFICATE-----'; then
            # write individual certs to dump with stable names
            srv_prefix="$DUMP/sslserver_$(printf '%s' "$h" | sed -e 's/[^A-Za-z0-9_.-]/_/g')_$(date +%Y%m%d_%H%M%S)_$$"
            printf '%s' "$s_out_srv" | awk -v p="$srv_prefix" 'BEGIN{c=0} /-----BEGIN CERTIFICATE-----/{c++; fname=sprintf("%s_%d.pem",p,c); print > fname; in=1; print > fname; next} in{print > fname} /-----END CERTIFICATE-----/{in=0}' 2>/dev/null || true
            for f in ${srv_prefix}_*.pem; do
              [ -f "$f" ] || continue
              echo "SAVED_CHAIN: $f" | tee -a "$PROBE_OUT"
            done
          fi
        fi

        # 1.1) TLS-версия и шифр + грубая латентность (time_total)
  read -r tls_ver tls_cipher t_total <<EOFINFO
$("$CURL" -sS -H "Host: $h" -o /dev/null -w '%{ssl_version} %{ssl_cipher} %{time_total}\n' "https://$h/" 2>/dev/null)
EOFINFO
        [ -n "$tls_ver" ]    && echo "TLS: $tls_ver  CIPHER: $tls_cipher  t_total≈${t_total}s" | tee -a "$PROBE_OUT"

        # 2) Сжатия: br/gzip/deflate/zstd
        for enc in br gzip deflate zstd; do
          hdr="$("$CURL" -sSL -H "Host: $h" -H "Accept-Encoding: $enc" -D - -o /dev/null "https://$h/" 2>/dev/null | grep -i '^content-encoding:' || true)"
          if [ -n "$hdr" ]; then
            echo "ENC[$enc]: $(echo "$hdr" | tr -d '\r')" | tee -a "$PROBE_OUT"
          else
            echo "ENC[$enc]: (нет — сервер не выдал $enc)" | tee -a "$PROBE_OUT"
          fi
        done

        # 3) Итог по умолчанию (--compressed)
  DEF="$("$CURL" -sSL --compressed -H "Host: $h" -D - -o /dev/null "https://$h/" 2>/dev/null | grep -i '^content-encoding:' | tr -d '\r' || true)"
        [ -n "$DEF" ] && echo "ENC[default]: $DEF" | tee -a "$PROBE_OUT"
        echo | tee -a "$PROBE_OUT"
      done

    fi
  fi

  sed -n '1,200p' "$PROBE_OUT"
} > "$OUT_DIR/65_http2_gzip_probe.txt"

# 10) Анализ логов (error/access)
{
  log "===== Логи Nginx ====="
  SRC="$DUMP/nginx_T.txt"
  ERR_FILES="$([ -s "$SRC" ] && "$GREP" -E '^\s*error_log\s+' "$SRC" | "$AWK" "{for(i=2;i<=NF;i++)print \$i}" | "$SED" 's/;.*$//' | tr -d ' ' | sort -u)"
  [ -n "${ERR_FILES:-}" ] || ERR_FILES="/var/log/nginx/error.log"

    printf '%s\n' "$ERR_FILES" | while IFS= read -r f; do
    [ -r "$f" ] || continue
    log "-- error: $f"
  tail -n 1000 "$f" | "$GREP" -Ei 'crit|alert|emerg|error|segfault|worker process|failed|timeout' || true
  done

  log "\n===== Access логи: 4xx/5xx (топ 20) ====="
  ACC_FILES="$([ -s "$SRC" ] && "$GREP" -E '^\s*access_log\s+' "$SRC" | "$AWK" "{print \$2}" | "$SED" 's/;.*$//' | sort -u)"
  [ -n "${ACC_FILES:-}" ] || ACC_FILES="/var/log/nginx/access.log"

  printf '%s\n' "$ACC_FILES" | while IFS= read -r a; do
    [ -r "$a" ] || continue
    log "-- access: $a"
    tail -n 100000 "$a" | "${AWK}" "{ c=0; for(i=1;i<=NF;i++){ if(\$i ~ /^[0-9]{3}$/){ c=\$i; break; } } if(c>=400) print c; }" \
      | "${AWK}" "{cnt[\$1]++} END{for(k in cnt) printf(\"%s %d\\n\", k, cnt[k])}" | sort -nrk2 | head -n20

    log "\n-- Топ URL с 5xx --"
    tail -n 100000 "$a" | "${AWK}" "{ \
      c=0; url=\"\"; \
      for(i=1;i<=NF;i++){ if(\$i ~ /^[0-9]{3}$/) c=\$i } \
      if(match(\$0, /\"[^\"]+\"/)){ rq=substr(\$0,RSTART,RLENGTH); if(match(rq, /\"[^ ]+ ([^ ]+)/, m)) url=m[1] } \
      if(c ~ /^5/ && url!=\"\") print url \
    }" | sort | uniq -c | sort -nr | head -n 20
  done
} > "$OUT_DIR/70_logs_analysis.txt"

# 11) Security / Firewall
{
  log "===== SELinux / AppArmor / Firewall ====="
  getenforce 2>/dev/null || true
  sestatus 2>/dev/null || true
  aa-status 2>/dev/null || true
  log "\n-- nft/iptables (первые 200 строк) --"
  nft list ruleset 2>/dev/null | sed -n '1,200p' || true
  iptables -S 2>/dev/null | sed -n '1,200p' || true
} > "$OUT_DIR/80_security.txt"

# 12) Журнал systemd за 48h
{
  log "===== Журнал systemd nginx (48h) ====="
  if [ -n "$JOURNALCTL" ]; then
    "$JOURNALCTL" -u nginx --since '48 hours ago' -n 2000 2>/dev/null | sed -n '1,2000p' || true
  fi
} > "$OUT_DIR/90_journal.txt"

# ==========================
# ПОСТ-ОБРАБОТКА (сводки)
# ==========================

SRC="$DUMP/nginx_T.txt"
[ -s "$SRC" ] && ACC_LIST="$({ "${GREP}" -E '^\s*access_log\s+' "$SRC" 2>/dev/null || true; } | "${AWK}" "{print \$2}" | "${SED}" 's/;.*$//' | sort -u)" || ACC_LIST=""
[ -n "${ACC_LIST:-}" ] || ACC_LIST="/var/log/nginx/access.log"
[ -s "$SRC" ] && ERR_LIST="$({ "${GREP}" -E '^\s*error_log\s+' "$SRC" 2>/dev/null || true; } | "${AWK}" "{for(i=2;i<=NF;i++)print \$i}" | "${SED}" 's/;.*$//' | tr -d ' ' | sort -u)" || ERR_LIST=""
[ -n "${ERR_LIST:-}" ] || ERR_LIST="/var/log/nginx/error.log"

OUT_SUMMARY="$OUT_DIR/SUMMARY.md"
OUT_VHOSTS="$OUT_DIR/vhosts.csv"
OUT_TIMINGS="$OUT_DIR/timings_p95.txt"
OUT_ISSUES="$OUT_DIR/issues.txt"
OUT_UP_HEALTH="$OUT_DIR/upstreams_health.txt"
OUT_CERTS="$OUT_DIR/certs_expiry.txt"

OUT_NGINX_STATUS="$OUT_DIR/nginx_status.txt"
OUT_SYS_LIMITS="$OUT_DIR/sys_limits.txt"
OUT_FDCOUNTS="$OUT_DIR/fd_counts.txt"

# Simple upstream reachability check (non-invasive)
check_upstreams() {
  local src="$DUMP/nginx_T.txt"
  local out="$OUT_UP_HEALTH"
  : > "$out"
  echo "Using dump: $src" >> "$out"

  if [ ! -s "$src" ]; then
    echo '[WARN] no nginx dump, skipping upstream checks' >> "$out"
    return 0
  fi

  # helpers
  resolve_var() {
    local varname="$1"
    # simple 'set' assignments: set $name value;
    awk -v v="$varname" ' { if(match($0, "^\s*set[ \t]+\\$"v"[ \t]+") ){ line=$0; sub(/^\s*set[ \t]+\\$"v"[ \t]+/,"",line); sub(/;.*/,"",line); gsub(/^\s+|\s+$/,"",line); print line; exit } }' "$src" 2>/dev/null || true
  }

  # check_target: test a single host:port/proto and append results to $out
  check_target() {
    local canddesc="$1"; shift
    local host="$1"; shift
    local port="$1"; shift
    local proto="$1"; shift
    local stype="${1:-}"
  { printf 'TARGET: %s -> %s:%s (proto=%s)\n' "$canddesc" "$host" "$port" "$proto"; } >> "$out"

    target_ip="$host"
    if ! printf '%s' "$host" | grep -Eq '^[0-9:\.]+'; then
      ip_res=$(getent ahostsv4 "$host" 2>/dev/null | awk '{print $1; exit}') || true
      if [ -n "$ip_res" ]; then target_ip="$ip_res"; fi
    fi

    if timeout 3 bash -c "</dev/tcp/$target_ip/$port" >/dev/null 2>&1; then
      echo "  STATUS: UP (tcp connect) -> $target_ip:$port" >> "$out"

      # TLS probe: run when we have https/grpcs explicitly or when the port responds to TLS handshake
      if command -v openssl >/dev/null 2>&1; then
        probe_tls=0
        case "$proto" in
          https|grpcs) probe_tls=1 ;;
          *)
            # quick TLS detection: try s_client with SNI (if host looks like a name) then without SNI
            quick=""
            if ! printf '%s' "$host" | grep -Eq '^[0-9:\.]+'; then
              quick=$(timeout 3 bash -c "echo | openssl s_client -connect ${target_ip}:${port} -servername ${host} 2>/dev/null" || true)
            fi
            if [ -z "$quick" ]; then
              quick=$(timeout 3 bash -c "echo | openssl s_client -connect ${target_ip}:${port} 2>/dev/null" || true)
            fi
            if printf '%s' "$quick" | $GREP -Fq -- '-----BEGIN CERTIFICATE-----'; then
              probe_tls=1
            fi
            ;;
        esac

        if [ "$probe_tls" -eq 1 ]; then
          # try to find common CA bundle paths
          CAFILE=""
          for c in /etc/ssl/certs/ca-certificates.crt /etc/ssl/certs/ca-bundle.crt /etc/pki/tls/certs/ca-bundle.crt /etc/ssl/cert.pem; do
            [ -f "$c" ] && { CAFILE="$c"; break; }
          done

          # ALPN: prefer default server advertisement (no explicit -alpn), then fall back to explicit probes
          alpn_out=$(timeout 5 bash -c "echo | openssl s_client -connect ${target_ip}:${port} -servername ${host} 2>/dev/null" || true)
          if printf '%s' "$alpn_out" | grep -qi 'ALPN protocol'; then
            alpn_line=$(printf '%s' "$alpn_out" | grep -i 'ALPN protocol' | tail -n1)
            echo "  ALPN: $(printf '%s' "$alpn_line" | sed 's/^/ /')" >> "$out"
          else
            for alpn_proto in h2 http/1.1; do
              alpn_out=$(timeout 5 bash -c "echo | openssl s_client -connect ${target_ip}:${port} -servername ${host} -alpn ${alpn_proto} 2>/dev/null" || true)
              if printf '%s' "$alpn_out" | grep -qi 'ALPN protocol'; then
                alpn_line=$(printf '%s' "$alpn_out" | grep -i 'ALPN protocol' | tail -n1)
                echo "  ALPN: ${alpn_proto} -> $(printf '%s' "$alpn_line" | sed 's/^/ /')" >> "$out"
                break
              fi
            done
          fi

          # Check OCSP stapling status via s_client -status (if supported by server)
          ocsp_out=$(timeout 6 bash -c "echo | openssl s_client -connect ${target_ip}:${port} -servername ${host} -status 2>/dev/null" || true)
          if printf '%s' "$ocsp_out" | grep -qi 'OCSP response:'; then
            ocsp_line=$(printf '%s' "$ocsp_out" | sed -n '/OCSP response:/,/-----BEGIN/s/\r//p' | sed -n '1,6p' || true)
            echo "  OCSP: present" >> "$out"
            printf '%s
' "$ocsp_line" | sed 's/^/    /' >> "$out"
          else
            echo "  OCSP: not stapled" >> "$out"
          fi

          # capture full s_client output (including chain) and verification status
          s_out=$(timeout 6 bash -c "echo | openssl s_client -connect ${target_ip}:${port} -servername ${host} -showcerts 2>/dev/null" || true)
          if [ -n "$s_out" ]; then
            verify_line=$(printf '%s' "$s_out" | grep -i 'verify return code' | tail -n1 || true)
            if [ -n "$verify_line" ]; then
              echo "  TLS_VERIFY: $(printf '%s' "$verify_line" | sed 's/^/ /')" >> "$out"
            fi

            # extract individual certs from the chain and summarize subject/issuer/dates, and attempt openssl verify using system bundle
            cert_idx=0
            # create temp certs in /tmp or save to DUMP when requested
            tmp_prefix="/tmp/sslchain_$$_"
            printf '%s' "$s_out" | awk -v p="$tmp_prefix" 'BEGIN{c=0} /-----BEGIN CERTIFICATE-----/{c++; fname=sprintf("%s%d.pem",p,c); print > fname; in=1; print > fname; next} in{print > fname} /-----END CERTIFICATE-----/{in=0}' 2>/dev/null || true
            for f in ${tmp_prefix}*.pem; do
              [ -f "$f" ] || continue
              cert_idx=$((cert_idx+1))
              subj=$($OPENSSL x509 -in "$f" -noout -subject 2>/dev/null || true)
              iss=$($OPENSSL x509 -in "$f" -noout -issuer 2>/dev/null || true)
              dates=$($OPENSSL x509 -in "$f" -noout -dates 2>/dev/null || true)
              {
                printf '  CERT[%d]: %s\n' "$cert_idx" "${subj:-unk}"
                printf '    ISSUER: %s\n' "${iss:-unk}"
                printf '    %s\n' "${dates:-}" | sed 's/^/    /'
                if [ -n "$CAFILE" ]; then
                  verify_res=$($OPENSSL verify -CAfile "$CAFILE" "$f" 2>/dev/null || true)
                  printf '    VERIFY: %s\n' "${verify_res:-(no verify output)}"
                fi
              } >> "$out"
              # save chain if requested
              if [ "$SAVE_CERT_CHAIN" -eq 1 ]; then
                safe_host=$(printf '%s' "$host" | sed -e 's/[^A-Za-z0-9_.-]/_/g')
                ts="$(date +%Y%m%d_%H%M%S)"
                dst="$DUMP/sslchain_${safe_host}_${port}_${ts}_$$_${cert_idx}.pem"
                cp -f "$f" "$dst" 2>/dev/null || true
                echo "    SAVED_CHAIN: $dst" >> "$out"
              fi
              # remove temp file
              rm -f "$f"
            done
            if [ "$cert_idx" -eq 0 ]; then
              echo "  TLS_VERIFY: (no certs presented)" >> "$out"
              echo "  STATUS_NOTE: tls-no-cert" >> "$out"
            fi
          fi
        fi
      fi

      if command -v curl >/dev/null 2>&1; then
        if [ "$proto" = "https" ]; then
          hdrs=$(curl -sS -k -I --max-time 4 "${proto}://$host/" 2>/dev/null | grep -Ei 'HTTP/|^Server:|^Content-Encoding:' | tr -d '\r' | sed -n '1,6p' || true)
        else
          hdrs=$(curl -sS -I --max-time 4 -H "Host: $host" "${proto}://$host/" 2>/dev/null | grep -Ei 'HTTP/|^Server:|^Content-Encoding:' | tr -d '\r' | sed -n '1,6p' || true)
        fi
        [ -n "$hdrs" ] && printf '%s\n' "$hdrs" | sed 's/^/  /' >> "$out"
      else
        if command -v nc >/dev/null 2>&1; then
          resp=$(printf 'HEAD / HTTP/1.0\r\nHost: %s\r\n\r\n' "$host" | timeout 3 nc -w 2 "$target_ip" "$port" 2>/dev/null | grep -Ei 'HTTP/|^Server:' | sed -n '1,2p' || true)
          [ -n "$resp" ] && printf '%s\n' "$resp" | sed 's/^/  /' >> "$out"
        fi
      fi
      # --- type-specific active probes (memcached/grpc) ---
      # memcached: send 'version' command (text) and fallback to binary NOOP probe
      if printf '%s' "$stype" | grep -qi '^memcached'; then
        if command -v nc >/dev/null 2>&1; then
          mc_resp=$( (printf 'version\r\n'; sleep 0.15; printf '\r\n') | timeout 4 nc -w 3 "$target_ip" "$port" 2>/dev/null || true)
          if [ -n "$mc_resp" ]; then
            printf '  MEMCACHED-TXT: %s\n' "$(printf '%s' "$mc_resp" | tr -d '\r' | sed -n '1,4p' | tr '\n' ' ' )" >> "$out"
          else
            # try memcached binary protocol: request magic(0x80), opcode NOOP(0x0a), rest zeros (24-byte header)
            if command -v xxd >/dev/null 2>&1; then
              bin_req=$(printf '\x80\x0a\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00')
              bin_resp=$(printf '%s' "$bin_req" | timeout 4 nc -w 3 "$target_ip" "$port" 2>/dev/null || true)
              if [ -n "$bin_resp" ]; then
                # show first 32 bytes as hex
                hexs=$(printf '%s' "$bin_resp" | xxd -p | sed -n '1p' || true)
                printf '  MEMCACHED-BIN: %s\n' "${hexs:-(no-hex)}" >> "$out"
              fi
            fi
          fi
        fi
      fi

      # grpc: attempt HTTP/2 prior-knowledge probe for plaintext gRPC (if curl supports it)
      if printf '%s' "$stype" | grep -qi '^grpc'; then
        if command -v curl >/dev/null 2>&1; then
          if curl --help 2>&1 | grep -q -- '--http2-prior-knowledge'; then
            gresp=$(curl -sS --http2-prior-knowledge -I --max-time 4 "http://$host:$port/" 2>/dev/null || true)
            if [ -n "$gresp" ]; then
              printf '  GRPC_HTTP2_PRIOR: %s\n' "$(printf '%s' "$gresp" | sed -n '1p' | tr -d '\r')" >> "$out"
            fi
          fi
        fi
      fi
      # additional grpc heuristics: ALPN=h2 probe and HTTP/2 client preface
      if printf '%s' "$stype" | grep -qi '^grpc'; then
        if command -v openssl >/dev/null 2>&1; then
          alpn_h2=$(timeout 4 bash -c "echo | openssl s_client -connect ${target_ip}:${port} -servername ${host} -alpn h2 2>/dev/null" || true)
          if printf '%s' "$alpn_h2" | grep -qi 'ALPN protocol'; then
            echo "  ALPN: h2 (grpc candidate)" >> "$out"
          fi
        fi
        # try raw HTTP/2 client preface (PRI * HTTP/2.0) via nc if available
        if command -v nc >/dev/null 2>&1; then
          preface_resp=$(printf 'PRI * HTTP/2.0\r\n\r\nSM\r\n\r\n' | timeout 3 nc -w 2 "$target_ip" "$port" 2>/dev/null || true)
          if [ -n "$preface_resp" ]; then
            printf '  GRPC_PREFACE_RESP: %s\n' "$(printf '%s' "$preface_resp" | tr -d '\r' | sed -n '1,3p' | tr '\n' ' ' )" >> "$out"
          fi
        fi
      fi

      # correlate with listening sockets and processes (local ports) using available tools
      listen_info=""
      if [ -n "$SS" ]; then
        listen_info=$($SS -ltnp 2>/dev/null | $GREP -E ":${port}\b" || true)
      elif [ -n "$NETSTAT" ]; then
        listen_info=$($NETSTAT -ltnp 2>/dev/null | $GREP -E ":${port}\b" || true)
      elif [ -n "$LSOF" ]; then
        listen_info=$($LSOF -nP -iTCP -sTCP:LISTEN 2>/dev/null | $GREP -E ":${port}\b" || true)
      fi
      if [ -n "$listen_info" ]; then
        echo "  LISTENERS:" >> "$out"
        printf '%s\n' "$listen_info" | sed 's/^/    /' >> "$out"
        # try to detect known backend processes for type hints
        if printf '%s' "$listen_info" | $GREP -qi nginx; then
          echo "    LISTENER_OWNER: nginx" >> "$out"
        else
          if [ -n "$stype" ]; then
            case "$stype" in
              fastcgi)
                if printf '%s' "$listen_info" | $GREP -qi php; then echo "    LIKELY_BACKEND: php-fpm" >> "$out"; fi
                ;;
              uwsgi)
                if printf '%s' "$listen_info" | $GREP -qi uwsgi; then echo "    LIKELY_BACKEND: uwsgi" >> "$out"; fi
                ;;
              scgi)
                if printf '%s' "$listen_info" | $GREP -qi python; then echo "    LIKELY_BACKEND: scgi/python" >> "$out"; fi
                ;;
              *) ;;
            esac
          fi
        fi
      fi
    else
      echo "  STATUS: DOWN (tcp connect failed to $target_ip:$port) reason=connect-failed" >> "$out"
    fi

    echo >> "$out"
  }
  # sanitized copy without full-line comments to avoid picking commented-out directives
  sanitized_tmp=$(mktemp 2>/dev/null || printf '/tmp/nginx_sanitized.%s' "$$_")
  grep -v -E '^[[:space:]]*#' "$src" > "$sanitized_tmp" 2>/dev/null || true

  candidates=$( (
    # proxy_pass targets (right-hand token)
    grep -Eo 'proxy_pass[[:space:]]+[^;]+' "$sanitized_tmp" 2>/dev/null | sed -E 's/^proxy_pass[[:space:]]+/proxy|/' || true
  # fastcgi/uwsgi/scgi/memcached/grpc pass (preserve directive name then strip _pass)
  grep -Eo '(fastcgi_pass|uwsgi_pass|scgi_pass|memcached_pass|grpc_pass)[[:space:]]+[^;]+' "$sanitized_tmp" 2>/dev/null | sed -E 's/^[[:space:]]*(fastcgi_pass|uwsgi_pass|scgi_pass|memcached_pass|grpc_pass)[[:space:]]+(.+)$/\1|\2/; s/_pass$//' || true
    # explicit URLs
    grep -Eo 'https?://[A-Za-z0-9._:%@\-\[\]]+(:[0-9]+)?' "$sanitized_tmp" 2>/dev/null | sed -E 's#^(https?://)#url|#' || true
    # unix sockets
    grep -Eo 'unix:[^; )]+' "$sanitized_tmp" 2>/dev/null | sed -E 's/^/unix|/' || true
    # upstream server lines
    awk '/^\s*upstream[[:space:]]+/ { in=1; next } in && /^\s*\}/ { in=0 } in && /^\s*server[[:space:]]+/ { line=$0; sub(/.*server[[:space:]]+/,"",line); sub(/;.*/,"",line); print "upstream_server|" line }' "$sanitized_tmp" 2>/dev/null || true
  ) | sed 's/[ \t]\+/ /g' | sed 's/^[ \t]*//;s/[ \t]*$//' | sort -u )

  # Parse 'map' blocks to help resolve variables mapped from keys (map $key $var { ... })
  maps_tmp=$(mktemp 2>/dev/null || printf '/tmp/nginx_maps.%s' "$$_")
  setvars_tmp=$(mktemp 2>/dev/null || printf '/tmp/nginx_setvars.%s' "$$_")
  upstreams_tmp=$(mktemp 2>/dev/null || printf '/tmp/nginx_upstreams.%s' "$$_")
  # ensure tmp files removed on exit (include sanitized_tmp)
  trap 'rm -f "$maps_tmp" "$setvars_tmp" "$upstreams_tmp" "$vars_tmp" "$sanitized_tmp"' RETURN

  # Note: we will substitute variables on a per-candidate basis below (safer for concatenated expressions)

  # parse map blocks: produce lines like: var|key|value  and var|__default__|value
  awk '
    BEGIN{inmap=0}
    /^\s*map[[:space:]]+\$[A-Za-z0-9_]+[[:space:]]+\$[A-Za-z0-9_]+[[:space:]]*\{/ {
      keyvar=$2; valvar=$3; sub(/\$/,"",keyvar); sub(/\$/,"",valvar); inmap=1; next
    }
    inmap && /^\s*\}/ { inmap=0; next }
    inmap {
      line=$0; sub(/;.*/,"",line); gsub(/^[ \t]+|[ \t]+$/,"",line); if(line=="") next
      if(line ~ /^default[ \t]+/) {
        sub(/^default[ \t]+/,"",line); gsub(/^[ \t\"]+|[ \t\"]+$/,"",line); print valvar "|__default__|" line; next
      }
      n=split(line, arr, /[ \t]+/); key=arr[1]; val=arr[n]; gsub(/^[ \t\"]+|[ \t\"]+$/,"",key); gsub(/^[ \t\"]+|[ \t\"]+$/,"",val);
      print valvar "|" key "|" val
    }
  ' "$src" > "$maps_tmp" 2>/dev/null || true

  # parse upstream blocks: lines like upstream_name|server_entry
  awk '
    BEGIN{inup=0; up=""}
    /^\s*upstream[[:space:]]+[A-Za-z0-9_]+[[:space:]]*\{/ { up=$2; inup=1; next }
    inup && /^\s*\}/ { inup=0; up=""; next }
    inup && /^\s*server[[:space:]]+/ {
      line=$0; sub(/.*server[[:space:]]+/,"",line); sub(/;.*/,"",line); gsub(/^[ \t]+|[ \t]+$/,"",line);
      if(up!="") print up "|" line
    }
  ' "$src" > "$upstreams_tmp" 2>/dev/null || true

  # Extract simple 'set $var value;' assignments to help resolution
  # Use a safe shell loop to avoid tricky quoting inside sed/awk
  grep -E "^\s*set[[:space:]]+\$[A-Za-z0-9_]+" "$src" 2>/dev/null | while IFS= read -r line; do
    # remove trailing semicolon and surrounding whitespace
    l=$(printf '%s' "$line" | sed -E 's/[[:space:]]*;[[:space:]]*$//')
  var=$(printf '%s' "$l" | sed -E "s/^\\s*set[[:space:]]+\\\$([[:alnum:]_]+).*$/\1/")
  val=$(printf '%s' "$l" | sed -E "s/^\\s*set[[:space:]]+\\\$[[:alnum:]_]+[[:space:]]+(.*)$/\1/")
    # strip wrapping quotes
    # strip wrapping quotes (double or single) safely
    case "$val" in
      '"'*'"') val="${val#\"}"; val="${val%\"}" ;;
      "'"*"'") val="${val#\'}"; val="${val%\'}" ;;
    esac
    if [ -n "$var" ]; then printf '%s|%s\n' "$var" "$val" >> "$setvars_tmp"; fi
  done || true

  # copy parsed setvars into vars_tmp (so user-supplied vars and parsed setvars are in one place)
  if [ -s "$setvars_tmp" ]; then
    while IFS='|' read -r kk vv; do
      # avoid duplicates
      if ! awk -F'|' -v k="$kk" '$1==k{exit 1}' "$vars_tmp" 2>/dev/null; then
        printf '%s|%s\n' "$kk" "$vv" >> "$vars_tmp"
      fi
    done < "$setvars_tmp" || true
  fi

  # write auto vars-file for user visibility and reuse
  if [ -s "$vars_tmp" ]; then
    auto_vars_file="$OUT_DIR/auto_vars.txt"
    mkdir -p "$(dirname -- "$auto_vars_file")" 2>/dev/null || true
    awk -F'|' 'NF>=2 && $1!~"^$" { gsub(/^[ \t]+|[ \t]+$/,"",$1); gsub(/^[ \t]+|[ \t]+$/,"",$2); print $1"="$2 }' "$vars_tmp" > "$auto_vars_file" 2>/dev/null || true
    echo "[INFO] wrote auto vars file: $auto_vars_file" >> "$out"
  fi

  # robust resolver: repeatedly substitute $vars using --vars-file, set assignments, map blocks or upstream names
  full_resolve() {
    local cand="$1"
    local iter=0
    # loop to allow nested substitutions (max depth 6)
    while printf '%s' "$cand" | grep -q '\$' && [ "$iter" -lt 6 ]; do
      iter=$((iter+1))
      for v in $(printf '%s' "$cand" | grep -oE '\$[A-Za-z0-9_]+' | tr -d '$' | sort -u); do
        resolved=""
        # 1) vars file overrides
        if [ -s "$vars_tmp" ]; then
          resolved=$(awk -F'|' -v var="$v" '$1==var{print $2; exit}' "$vars_tmp" 2>/dev/null || true)
        fi
        # 2) setvars parsed from config
        if [ -z "$resolved" ] && [ -s "$setvars_tmp" ]; then
          resolved=$(awk -F'|' -v var="$v" '$1==var{print $2; exit}' "$setvars_tmp" 2>/dev/null || true)
        fi
        # 3) try map explicit match then default
        if [ -z "$resolved" ] && [ -s "$maps_tmp" ]; then
          mapmatch=$(awk -F'|' -v var="$v" -v cand="$cand" '$1==var && $2!="__default__" { if(index(cand,$2)) {print $3; exit} }' "$maps_tmp" 2>/dev/null || true)
          if [ -n "$mapmatch" ]; then
            resolved="$mapmatch"
          else
            mapdef=$(awk -F'|' -v var="$v" '$1==var && $2=="__default__"{print $3; exit}' "$maps_tmp" 2>/dev/null || true)
            [ -n "$mapdef" ] && resolved="$mapdef"
          fi
        fi
        # 4) if var name equals an upstream block name, use first server host
        if [ -z "$resolved" ] && [ -s "$upstreams_tmp" ]; then
          srv=$(awk -F'|' -v var="$v" '$1==var{print $2; exit}' "$upstreams_tmp" 2>/dev/null || true)
          if [ -n "$srv" ]; then
            if printf '%s' "$srv" | grep -q '^unix:'; then
              resolved=$(printf '%s' "$srv" | sed -E 's/^unix:(.*)$/\1/')
            else
              resolved=$(printf '%s' "$srv" | sed -E 's/^\[([^\]]+)\].*$/\1/; s/:.*$//')
            fi
          fi
        fi
        # strip surrounding quotes, trailing semicolons and surrounding whitespace
        if [ -n "$resolved" ]; then
          # remove surrounding double or single quotes
          resolved=${resolved#\"}
          resolved=${resolved%\"}
          resolved=${resolved#\'}
          resolved=${resolved%\'}
          # remove trailing semicolons and trim
          resolved=${resolved%;}
          # trim leading/trailing whitespace using parameter expansion
          resolved="$(printf '%s' "$resolved" | awk '{gsub(/^ +| +$/,"",$0); print $0}')"
          # perform safe bash string substitution (replace literal $var occurrences)
          cand=${cand//\$$v/$resolved}
        fi
      done
    done
    printf '%s' "$cand"
  }

  # conservative positional heuristic: try to resolve $1 as http/https; for $2..$N try to split first upstream server host
  try_positionals() {
    local cand="$1"
    # quick try for $1
    if printf '%s' "$cand" | grep -q '\$1'; then
      for sc in http https; do
        trial=${cand//\$1/$sc}
        # if trial contains no other $vars, return it
        if ! printf '%s' "$trial" | grep -q '\$[0-9]'; then
          printf '%s' "$trial"
          return 0
        fi
      done
    fi
    # try to split first upstream server into labels and map to $2..$N
    if [ -s "$upstreams_tmp" ]; then
      firstsrv=$(awk -F'|' 'NR==1{print $2}' "$upstreams_tmp" 2>/dev/null || true)
      # strip possible port or unix:
      firstsrv=${firstsrv#unix:}
      firsthost=${firstsrv%%:*}
      if [ -n "$firsthost" ] && printf '%s' "$firsthost" | grep -qE '\.'; then
        IFS='.' read -r -a parts <<< "$firsthost"
        local outcand="$cand"
        # assign $2.. by parts[0].. etc
        for idx in "${!parts[@]}"; do
          varn=$((idx+2))
          outcand=${outcand//\$${varn}/${parts[idx]}}
        done
        # if some $1 remains, default to http
        outcand=${outcand//\$1/http}
        printf '%s' "$outcand"
        return 0
      fi
    fi
    # fallback: return original
    printf '%s' "$cand"
  }

  printf '%s\n' "$candidates" | sed '/^\s*$/d' | while IFS= read -r raw; do
    [ -z "$raw" ] && continue
    heuristic_notes=""
    if printf '%s' "$raw" | grep -q '|'; then
      stype=${raw%%|*}
      cand=${raw#*|}
    else
      stype=generic
      cand=$raw
    fi
    # try to fully resolve any $vars in candidate using layered heuristics
    cand=$(full_resolve "$cand")

    # Aggressive positional heuristics (enabled by default): if positional
    # variables like $1/$2 remain unresolved, attempt a conservative guess
    # via try_positionals() and re-run the resolver. This increases the
    # chance to expand templated proxy_pass targets (CDNs, S3, etc.).
    if printf '%s' "$cand" | grep -q '\$[0-9]'; then
      cand_try=$(try_positionals "$cand")
      if [ "$cand_try" != "$cand" ]; then
        heuristic_notes="${heuristic_notes} positional_guess"
        cand=$(full_resolve "$cand_try")
      fi
    fi

  # normalize unix socket
    if printf '%s' "$cand" | grep -q '^unix:'; then
      sock=${cand#unix:}
      echo "TARGET: unix:$sock" >> "$out"
      if [ -S "$sock" ] || [ -e "$sock" ]; then
        echo "  STATUS: UP (socket exists)" >> "$out"
        if [ -n "${CURL:-}" ] && command -v curl >/dev/null 2>&1; then
          hdrs=$(curl -sS --unix-socket "$sock" -I --max-time 3 http://localhost/ 2>/dev/null | grep -Ei 'HTTP/|^Server:|^Content-Encoding:' | tr -d '\r' | sed -n '1,5p' || true)
          [ -n "$hdrs" ] && printf '%s\n' "$hdrs" | sed 's/^/  /' >> "$out"
        fi
      else
        echo "  STATUS: DOWN (socket missing)" >> "$out"
      fi
      echo >> "$out"
      continue
    fi

    # ensure we have a scheme; build a working URL for host extraction
    proto=
    # accept https/http and grpc/grpcs explicit schemes; also honor stype hints (grpc/memcached)
    if printf '%s' "$cand" | grep -qE '^(https?|grpcs?)://'; then
      proto=$(printf '%s' "$cand" | sed -n 's#^\(https\?\|grpcs\?\)://.*#\1#p')
      url="$cand"
    else
      # use stype heuristics when no explicit scheme is present
      case "$stype" in
        grpc* ) proto=grpc; url="grpc://$cand" ;; 
        memcached* ) proto=memcached; url="memcached://$cand" ;; 
        *) proto=http; url="http://$cand" ;;
      esac
    fi

    # extract hostport and remove any trailing path and any leftover $variables
    hostport=${url#*://}
    hostport=${hostport%%/*}
    hostport=${hostport#*@}
    # drop anything starting with a $ (e.g. $request_uri) that may remain in hostport
    hostport_clean=${hostport%%\$*}
    # IPv6 like [::1]:port
    if printf '%s' "$hostport_clean" | grep -q '\['; then
      host=$(printf '%s' "$hostport_clean" | sed -E 's/^\[([^\]]+)\].*$/\1/')
      port=$(printf '%s' "$hostport_clean" | awk -F']:' '{ if(NF>1) print $2; else print "" }')
    elif printf '%s' "$hostport_clean" | grep -q ':'; then
      host=${hostport_clean%%:*}
      port=${hostport_clean##*:}
      port=${port%%/*}
    else
      host=$hostport_clean
      port=
    fi
    if [ -z "$port" ]; then
      if [ "$proto" = "https" ]; then port=443; else port=80; fi
    fi

    # Aggressive heuristics: handle concatenations like $proxyserver$request_uri or $var$request_uri/
    # 1) If host contains a literal '$request_uri' or '$uri', try removing that suffix and re-evaluate
  if printf '%s' "$host" | grep -q "\$request_uri\|\$uri"; then
      host_trimmed=$(printf '%s' "$host" | sed -E "s/\$(request_uri|uri).*//")
      # try setvars/maps/upstreams for host_trimmed
      if [ -n "$host_trimmed" ]; then
        # try setvars
        hv=$(awk -F'|' -v var="$host_trimmed" '$1==var{print $2; exit}' "$setvars_tmp" 2>/dev/null || true)
        if [ -n "$hv" ]; then host="$hv"; fi
        # try maps
        if [ -z "$hv" ] && [ -s "$maps_tmp" ]; then
          mvv=$(awk -F'|' -v var="$host_trimmed" '$1==var && $2!="__default__"{print $3; exit} $1==var && $2=="__default__"{d=$3} END{ if(!d && !"" ){}; if(d) print d }' "$maps_tmp" 2>/dev/null || true)
          if [ -n "$mvv" ]; then host="$mvv"; fi
        fi
        # try upstreams
        if [ -z "$hv" ] && [ -s "$upstreams_tmp" ]; then
          upsrv=$(awk -F'|' -v var="$host_trimmed" '$1==var{print $2; exit}' "$upstreams_tmp" 2>/dev/null || true)
          if [ -n "$upsrv" ]; then host=$(printf '%s' "$upsrv" | sed -E 's/^unix:(.*)$/\1/; s/:.*$//'); fi
        fi
      fi
    fi

    # 2) If host ends with a trailing slash, strip it
    host=$(printf '%s' "$host" | sed -E 's:/*$::')

    # If host still contains variables or looks empty, mark as templated and skip active probes
    if [ -z "$host" ] || printf '%s' "$host" | grep -q '\$'; then
      {
        printf 'TARGET: %s:%s -> %s:%s (proto=%s)\n' "$stype" "$cand" "${host:-<empty>}" "$port" "$proto"
        printf '  STATUS: SKIPPED (templated or unresolved) -> %s:%s reason=templated\n' "${host:-<empty>}" "$port"
        printf '\n'
      } >> "$out"
      continue
    fi

    # If the host part is actually an upstream name, expand to servers from upstreams_tmp
    if [ -n "$upstreams_tmp" ] && [ -s "$upstreams_tmp" ]; then
      upname="$host"
      # exact match upstream name
      if awk -F'|' -v u="$upname" ' $1==u {print; exit}' "$upstreams_tmp" >/dev/null 2>&1; then
        echo "TARGET: upstream:$upname (expanded servers)" >> "$out"
        awk -F'|' -v u="$upname" '$1==u { print $2 }' "$upstreams_tmp" | while IFS= read -r srv; do
          [ -z "$srv" ] && continue
          # server may be unix:..., or host:port, or host
          if printf '%s' "$srv" | grep -q '^unix:'; then
            sock=${srv#unix:}
            echo "  server: unix:$sock" >> "$out"
            if [ -S "$sock" ] || [ -e "$sock" ]; then
              echo "    STATUS: UP (socket exists)" >> "$out"
            else
              echo "    STATUS: DOWN (socket missing)" >> "$out"
            fi
            continue
          fi
          # extract host/port from srv
          s_host="$srv"
          s_port=
          if printf '%s' "$s_host" | grep -q '\\['; then
            s_host=$(printf '%s' "$s_host" | sed -E 's/^\[([^\]]+)\].*$/\1/')
            s_port=$(printf '%s' "$srv" | awk -F: '{ if(NF>1) print $2; else print "" }')
          elif printf '%s' "$s_host" | grep -q ':'; then
            s_port=$(printf '%s' "$s_host" | awk -F: '{print $2}')
            s_host=$(printf '%s' "$s_host" | awk -F: '{print $1}')
          fi
          [ -z "$s_port" ] && s_port=$port
          check_target "upstream:$upname server:$srv" "$s_host" "$s_port" "$proto" upstream
        done
        # done expanding this upstream; skip the default single-host check
        continue
      fi
    fi

    # Delegate final check to check_target to get unified cert-chain/listener logic
    check_target "${stype}:${cand}" "$host" "$port" "$proto" "$stype"
  done
}


# A) Виртуальные хосты CSV
{
  echo "server_idx,listen,server_name,http2,access_log,error_log,root_or_tryfiles,client_header_timeout,client_body_timeout,send_timeout,ssl_handshake_timeout,proxy_connect_timeout,proxy_send_timeout,proxy_read_timeout,fastcgi_connect_timeout,fastcgi_send_timeout,fastcgi_read_timeout"
  awk '
    BEGIN{in_server=0; idx=0; listen=""; name=""; http2="no"; alog=""; elog=""; rootline="";
          cht=""; cbt=""; snt=""; sslht=""; pconn=""; psend=""; pread=""; fconn=""; fsend=""; fread=""}
    function flush(){
      if(in_server){
        if(alog=="") alog="-";
        if(elog=="") elog="-";
        if(rootline=="") rootline="-";
        gsub(/[[:space:]]+/, "", listen);
        gsub(/[[:space:]]+/, "", name);
        printf("%d,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s\n", idx, listen, name, http2, alog, elog, rootline, cht, cbt, snt, sslht, pconn, psend, pread, fconn, fsend, fread);
      }
      listen=""; name=""; http2="no"; alog=""; elog=""; rootline="";
      cht=""; cbt=""; snt=""; sslht=""; pconn=""; psend=""; pread=""; fconn=""; fsend=""; fread=""
    }
    /^\s*server\s*\{/ {in_server=1; idx++; next}
    in_server && /^\s*\}/ { flush(); in_server=0; next}
    {
      if(in_server){
        if($0 ~ /^\s*listen\s+/){
          L=$0; sub(/.*listen[ \t]+/,"",L); sub(/;.*/,"",L);
          if(L ~ /http2/) http2="yes";
          gsub(/[ \t]+/,"",L);
          listen = (listen==""?L:listen"|"L)
        }
        if($0 ~ /^\s*server_name\s+/){
          N=$0; sub(/.*server_name[ \t]+/,"",N); sub(/;.*/,"",N);
          gsub(/[ \t]+/," ",N);
          name = (name==""?N:name"|"N)
        }
        if($0 ~ /^\s*access_log\s+/){
          A=$0; sub(/.*access_log[ \t]+/,"",A); sub(/;.*/,"",A);
          alog = (alog==""?A:alog"|"A)
        }
        if($0 ~ /^\s*error_log\s+/){
          E=$0; sub(/.*error_log[ \t]+/,"",E); sub(/;.*/,"",E);
          elog = (elog==""?E:elog"|"E)
        }
        if($0 ~ /^\s*root\s+/ || $0 ~ /^\s*try_files\s+/){
          R=$0; gsub(/^[ \t]+|[ \t]+$/,"",R);
          rootline = (rootline==""?R:rootline"||"R)
        }
        # capture timeouts if present (last occurrence wins)
        if($0 ~ /^\s*client_header_timeout\s+/){ T=$0; sub(/.*client_header_timeout[ \t]+/,"",T); sub(/;.*/,"",T); gsub(/[ \t]+/,"",T); cht=T }
        if($0 ~ /^\s*client_body_timeout\s+/){ T=$0; sub(/.*client_body_timeout[ \t]+/,"",T); sub(/;.*/,"",T); gsub(/[ \t]+/,"",T); cbt=T }
        if($0 ~ /^\s*send_timeout\s+/){ T=$0; sub(/.*send_timeout[ \t]+/,"",T); sub(/;.*/,"",T); gsub(/[ \t]+/,"",T); snt=T }
        if($0 ~ /^\s*ssl_handshake_timeout\s+/){ T=$0; sub(/.*ssl_handshake_timeout[ \t]+/,"",T); sub(/;.*/,"",T); gsub(/[ \t]+/,"",T); sslht=T }
        if($0 ~ /^\s*proxy_connect_timeout\s+/){ T=$0; sub(/.*proxy_connect_timeout[ \t]+/,"",T); sub(/;.*/,"",T); gsub(/[ \t]+/,"",T); pconn=T }
        if($0 ~ /^\s*proxy_send_timeout\s+/){ T=$0; sub(/.*proxy_send_timeout[ \t]+/,"",T); sub(/;.*/,"",T); gsub(/[ \t]+/,"",T); psend=T }
        if($0 ~ /^\s*proxy_read_timeout\s+/){ T=$0; sub(/.*proxy_read_timeout[ \t]+/,"",T); sub(/;.*/,"",T); gsub(/[ \t]+/,"",T); pread=T }
        if($0 ~ /^\s*fastcgi_connect_timeout\s+/){ T=$0; sub(/.*fastcgi_connect_timeout[ \t]+/,"",T); sub(/;.*/,"",T); gsub(/[ \t]+/,"",T); fconn=T }
        if($0 ~ /^\s*fastcgi_send_timeout\s+/){ T=$0; sub(/.*fastcgi_send_timeout[ \t]+/,"",T); sub(/;.*/,"",T); gsub(/[ \t]+/,"",T); fsend=T }
        if($0 ~ /^\s*fastcgi_read_timeout\s+/){ T=$0; sub(/.*fastcgi_read_timeout[ \t]+/,"",T); sub(/;.*/,"",T); gsub(/[ \t]+/,"",T); fread=T }
      }
    }
  ' "$SRC" 2>/dev/null
} > "$OUT_VHOSTS"

# B) p95 по access-логам (эвристика) + ротация (.1..5 и .gz)
{
  echo "== Timings p95 (эвристика с ротацией) =="
  printf '%s\n' "$ACC_LIST" | while IFS= read -r a; do
    files=""
    for sfx in "" .1 .2 .3 .4 .5 .1.gz .2.gz .3.gz .4.gz .5.gz; do
      f="${a}${sfx}"; [ -e "$f" ] && files="${files}"$'\n'"$f"
    done
    [ -z "$files" ] && continue
    files_cnt=$(printf '%s\n' "$files" | sed '/^$/d' | wc -l)
    echo "-- $a (включая ротацию)"
    {
    printf '%s\n' "$files" | while IFS= read -r f; do
        [ -z "$f" ] && continue
        case "$f" in
          *.gz)
            if [ -n "$ZCAT" ]; then
              "$ZCAT" -- "$f" 2>/dev/null || true
            fi
            ;;
          *)    sed -n '1,200p' "$f" 2>/dev/null ;;
        esac
      done
    } | tail -n 400000 | \
      awk -v files_cnt="$files_cnt" '
        {
          for(i=1;i<=NF;i++){
            if($i ~ /^[0-9]+(\.[0-9]+)?(\/[0-9\.\-]+)?$/){
              gsub(/-.*/, "", $i);
              n=split($i, arr, "/");
              for(j=1;j<=n;j++){
                v=arr[j];
                if(v ~ /^[0-9]+(\.[0-9]+)?$/ && v+0 < 60) print v+0;
              }
            }
          }
        }
      ' 2>/dev/null | sort -n | awk -v fc="$files_cnt" '
        {a[NR]=$1}
        END{
          if(NR){
            i=int(0.95*NR); if(i<1)i=1;
            printf("files=%d  lines=%d  p95≈%.3fs\n", fc, NR, a[i]);
          } else {
            print "нет данных"
          }
        }'
  done
} > "$OUT_TIMINGS"

# C) Потенциальные проблемы
{
  echo "== Потенциальные проблемы =="
  echo "-- Низкие таймауты (proxy_/fastcgi_)"
  grep -En '^\s*(proxy|fastcgi)_(connect|send|read)_timeout\s+([1-5]s|[1-2]m)\s*;?' "$SRC" 2>/dev/null || echo "не найдено"

  echo
  echo "-- gzip/brotli"
  if grep -Eq '^\s*gzip\s+on' "$SRC" 2>/dev/null || grep -Eq '^\s*brotli\s+on' "$SRC" 2>/dev/null; then
    echo "включены"
  else
    echo "вероятно выключены"
  fi

  echo
  echo "-- client_max_body_size"
  grep -En '^\s*client_max_body_size\s+' "$SRC" 2>/dev/null || echo "директива не найдена (дефолт может ограничивать загрузки)"

  echo
  echo "-- HTTP/2 (по конфигу)"
  if grep -Eq '^\s*listen\s+.*http2' "$SRC" 2>/dev/null || grep -Eq '^\s*http2\s+on;?' "$SRC" 2>/dev/null; then
    echo "обнаружен в конфигурации"
  else
    echo "не обнаружен в конфигурации"
  fi

  echo
  echo "-- HSTS"
  grep -En 'add_header\s+Strict-Transport-Security' "$SRC" 2>/dev/null || echo "HSTS не найден"

  echo
  echo "-- real_ip_*"
  if grep -Eq 'set_real_ip_from|real_ip_header|real_ip_recursive' "$SRC" 2>/dev/null; then
    echo "real_ip: присутствует"
  else
    echo "real_ip: отсутствует (за балансером client_ip может быть неверен)"
  fi

  echo
  echo "-- Access: 5xx/499 (последние ~100к)"
  printf '%s\n' "$ACC_LIST" | while IFS= read -r a; do
    [ -r "$a" ] || continue
    echo "Лог: $a"
    tail -n 100000 "$a" | awk '{ c=0; for(i=1;i<=NF;i++){ if($i ~ /^[0-9]{3}$/){ c=$i; break; } } if(c>=500 || c==499) print c; }' \
      | awk '{cnt[$1]++} END{for(k in cnt) printf("%s %d\n", k, cnt[k])}' | sort -nrk2 | head -n 10
    echo
  done

  echo "-- error_log (последние 1000 строк)"
  printf '%s\n' "$ERR_LIST" | while IFS= read -r e; do
    [ -r "$e" ] || continue
    echo "Файл: $e"
    tail -n 1000 "$e" | grep -Ei 'crit|alert|emerg|error|segfault|worker process|failed|timeout' | tail -n 20 || echo "(нет критичных записей в хвосте)"
    echo
  done
} > "$OUT_ISSUES"

# D) Upstream health — use enhanced check_upstreams() implementation
# The function writes a more detailed report to $OUT_UP_HEALTH
check_upstreams || true

# E) Сертификаты: дни до истечения (+ маркеры <30д)
{
  echo "== SSL сертификаты (дни до истечения) =="
  if [ -n "$OPENSSL" ]; then
  find /etc/nginx -type f \( -name '*.pem' -o -name '*.crt' \) 2>/dev/null | sort -u | while IFS= read -r C; do
      end="$($OPENSSL x509 -in "$C" -noout -enddate 2>/dev/null | sed 's/notAfter=//')"
      [ -z "$end" ] && continue
      end_ts="$(date -d "$end" +%s 2>/dev/null || echo "")"
      now_ts="$(date +%s)"
      if [ -n "$end_ts" ]; then
        days=$(( (end_ts - now_ts) / 86400 ))
        flag=""
        if [ "$days" -lt 0 ]; then flag=" [EXPIRED]"; fi
        if [ "$days" -ge 0 ] && [ "$days" -lt 30 ]; then flag=" [SOON<30d]"; fi
        printf "%-60s  %s  (≈%+d days)%s\n" "$C" "$end" "$days" "$flag"
      else
        printf "%-60s  %s\n" "$C" "$end"
      fi
    done
  else
    echo "(openssl недоступен)"
  fi
} > "$OUT_CERTS" || true

# G) Nginx-specific runtime checks: stub_status, sysctl/ulimit, fd counts
{
  echo "===== Nginx runtime: stub_status / basic metrics ====="
  # try common stub_status locations: /nginx_status, /status
  if [ -n "$CURL" ]; then
    for p in "http://127.0.0.1/nginx_status" "http://127.0.0.1/status" "http://localhost/nginx_status"; do
      echo "-- probe: $p";
      $CURL -sS --max-time 3 "$p" 2>/dev/null || echo "(no response)";
    done
  else
    echo "(curl missing, skipped stub_status probes)"
  fi

  echo "\n===== System limits / sysctl ====="
  echo "ulimit -n: $(ulimit -n 2>/dev/null || echo n/a)"
  echo "net.core.somaxconn: $(sysctl -n net.core.somaxconn 2>/dev/null || echo n/a)"
  echo "fs.file-max: $(sysctl -n fs.file-max 2>/dev/null || echo n/a)"

  echo "\n===== FD counts for nginx workers (sample) ====="
  # find master and some worker pids
  nginx_pids=$(ps -eo pid,cmd | $GREP '[n]ginx' | awk '{print $1}' || true)
  if [ -n "$nginx_pids" ]; then
    for pid in $nginx_pids; do
      echo "PID: $pid"; ls -1 /proc/$pid/fd 2>/dev/null | wc -l 2>/dev/null || echo "(no fd info)";
    done
  else
    echo "(nginx processes not found)"
  fi

  echo "\n===== access_log format check (request_time/upstream_response_time) ====="
  if [ -s "$SRC" ]; then
    if $GREP -qE '\$request_time|\$upstream_response_time' "$SRC" 2>/dev/null; then
      echo "access_log contains request_time/upstream_response_time";
    else
      echo "access_log DOES NOT contain request_time/upstream_response_time — recommend enabling for accurate p95";
    fi
  else
    echo "(no nginx -T dump to inspect)"
  fi
} > "$OUT_NGINX_STATUS"

# H) System limits and FD summary
{
  echo "ulimit -n (current shell): $(ulimit -n 2>/dev/null || echo n/a)"
  sysctl net.core.somaxconn 2>/dev/null || true
  ss -s 2>/dev/null || netstat -s 2>/dev/null || true
} > "$OUT_SYS_LIMITS" || true

# I) FD counts per nginx worker (detailed)
{
  if [ -n "$nginx_pids" ]; then
    for pid in $nginx_pids; do
      echo "PID:$pid"; ls -l /proc/$pid/fd 2>/dev/null || echo "(no /proc/$pid/fd)";
    done
  else
    echo "(no nginx pids)"
  fi
} > "$OUT_FDCOUNTS" || true

# F) SUMMARY.md (короткий отчёт)
{
  echo "# Nginx — сводка аудита"
  echo
  echo "- Хост: \`$HOST\`"
  echo "- Каталог: \`$OUT_DIR\`"
  echo
  echo "## Ключевые параметры"
  cmbs="$(grep -E '^\s*client_max_body_size\s+' "$SRC" 2>/dev/null | awk '{print $2}' | tr -d ';' | tail -n1 || true)"
  [ -n "${cmbs:-}" ] && echo "- client_max_body_size: **$cmbs**"
  gz="$(grep -E '^\s*gzip\s+' "$SRC" 2>/dev/null | awk '{print $2}' | tr -d ';' | tail -n1 || true)"
  br="$(grep -E '^\s*brotli\s+' "$SRC" 2>/dev/null | awk '{print $2}' | tr -d ';' | tail -n1 || true)"
  [ -n "${gz:-}" ] && echo "- gzip: **$gz**"
  [ -n "${br:-}" ] && echo "- brotli: **$br**"
  kat="$(grep -E '^\s*keepalive_timeout\s+' "$SRC" 2>/dev/null | awk '{print $2}' | tr -d ';' | tail -n1 || true)"
  [ -n "${kat:-}" ] && echo "- keepalive_timeout: **$kat**"
  cht="$(grep -E '^\s*client_header_timeout\s+' "$SRC" 2>/dev/null | awk '{print $2}' | tr -d ';' | tail -n1 || true)"
  [ -n "${cht:-}" ] && echo "- client_header_timeout: **$cht**"
  cbt="$(grep -E '^\s*client_body_timeout\s+' "$SRC" 2>/dev/null | awk '{print $2}' | tr -d ';' | tail -n1 || true)"
  [ -n "${cbt:-}" ] && echo "- client_body_timeout: **$cbt**"
  snt="$(grep -E '^\s*send_timeout\s+' "$SRC" 2>/dev/null | awk '{print $2}' | tr -d ';' | tail -n1 || true)"
  [ -n "${snt:-}" ] && echo "- send_timeout: **$snt**"
  sslht="$(grep -E '^\s*ssl_handshake_timeout\s+' "$SRC" 2>/dev/null | awk '{print $2}' | tr -d ';' | tail -n1 || true)"
  [ -n "${sslht:-}" ] && echo "- ssl_handshake_timeout: **$sslht**"
  # proxy timeouts
  pconn="$(grep -E '^\s*proxy_connect_timeout\s+' "$SRC" 2>/dev/null | awk '{print $2}' | tr -d ';' | tail -n1 || true)"
  [ -n "${pconn:-}" ] && echo "- proxy_connect_timeout: **$pconn**"
  psend="$(grep -E '^\s*proxy_send_timeout\s+' "$SRC" 2>/dev/null | awk '{print $2}' | tr -d ';' | tail -n1 || true)"
  [ -n "${psend:-}" ] && echo "- proxy_send_timeout: **$psend**"
  pread="$(grep -E '^\s*proxy_read_timeout\s+' "$SRC" 2>/dev/null | awk '{print $2}' | tr -d ';' | tail -n1 || true)"
  [ -n "${pread:-}" ] && echo "- proxy_read_timeout: **$pread**"
  rtime="$(grep -E '^\s*resolver_timeout\s+' "$SRC" 2>/dev/null | awk '{print $2}' | tr -d ';' | tail -n1 || true)"
  [ -n "${rtime:-}" ] && echo "- resolver_timeout: **$rtime**"
  # fastcgi timeouts
  fconn="$(grep -E '^\s*fastcgi_connect_timeout\s+' "$SRC" 2>/dev/null | awk '{print $2}' | tr -d ';' | tail -n1 || true)"
  [ -n "${fconn:-}" ] && echo "- fastcgi_connect_timeout: **$fconn**"
  fsend="$(grep -E '^\s*fastcgi_send_timeout\s+' "$SRC" 2>/dev/null | awk '{print $2}' | tr -d ';' | tail -n1 || true)"
  [ -n "${fsend:-}" ] && echo "- fastcgi_send_timeout: **$fsend**"
  fread="$(grep -E '^\s*fastcgi_read_timeout\s+' "$SRC" 2>/dev/null | awk '{print $2}' | tr -d ';' | tail -n1 || true)"
  [ -n "${fread:-}" ] && echo "- fastcgi_read_timeout: **$fread**"
  wp="$(grep -E '^\s*worker_processes\s+' "$SRC" 2>/dev/null | awk '{print $2}' | tr -d ';' | tail -n1 || true)"
  wc="$(grep -E '^\s*worker_connections\s+' "$SRC" 2>/dev/null | awk '{print $2}' | tr -d ';' | tail -n1 || true)"
  [ -n "${wp:-}" ] && echo "- worker_processes: **$wp**"
  [ -n "${wc:-}" ] && echo "- worker_connections: **$wc**"
  if grep -Eq '^\s*listen\s+.*http2' "$SRC" 2>/dev/null || grep -Eq '^\s*http2\s+on;?' "$SRC" 2>/dev/null; then
    echo "- HTTP/2: **включён**"
  else
    echo "- HTTP/2: **нет**"
  fi
  grep -Eq 'add_header\s+Strict-Transport-Security' "$SRC" 2>/dev/null && echo "- HSTS: **настроен**" || echo "- HSTS: **нет**"

  echo
  echo "## Виртуальные хосты"
  echo "- CSV: \`$(basename "$OUT_VHOSTS")\` (открыть в Excel)"
  echo
  echo "## Производительность (эвристика p95)"
  if [ -s "$OUT_TIMINGS" ]; then
    echo '```'
    sed -n '1,80p' "$OUT_TIMINGS"
    echo '```'
  else
    echo "- Недостаточно данных для p95 (нет \$request_time/\$upstream_response_time в log_format?)."
  fi

  echo
  echo "## Upstream health (TCP, 1s)"
  if [ -s "$OUT_UP_HEALTH" ]; then
    echo '```'
    sed -n '1,200p' "$OUT_UP_HEALTH"
    echo '```'
  else
    echo "- Upstream’ы не обнаружены."
  fi

  echo
  echo "## HTTP/2 и сжатие (активные проверки)"
  if [ -s "$OUT_DIR/65_http2_gzip_probe.txt" ]; then
    echo '```'
    sed -n '1,200p' "$OUT_DIR/65_http2_gzip_probe.txt"
    echo '```'
  else
    echo "- Пропущено (нет curl или SSL-хостов в конфиге)."
  fi

  echo
  echo "## Сертификаты (дни до истечения)"
  if [ -s "$OUT_CERTS" ]; then
    echo '```'
    sed -n '1,120p' "$OUT_CERTS"
    echo '```'
  else
    echo "- Не найдено сертификатов в /etc/nginx."
  fi

  echo
  echo "## Проблемы/риски"
  if [ -s "$OUT_ISSUES" ]; then
    echo '```'
    sed -n '1,200p' "$OUT_ISSUES"
    echo '```'
  else
    echo "- Не обнаружено критичных сигналов по текущей эвристике."
  fi

  echo
  echo "## Рекомендации (кратко)"
  echo "- Проверить real_ip_* за балансером (X-Forwarded-For / PROXY protocol)."
  echo "- Включить/проверить gzip/brotli, набор типов."
  echo "- Привести client_max_body_size на уровнях http/server/location."
  echo "- Настроить proxy_/fastcgi_*_timeout под характер бэкенда (PHP/Bitrix, push/rtc)."
  echo "- Обогатить access_log: \$request_time, \$upstream_response_time, \$status, \$body_bytes_sent, \$http_referer, \$http_user_agent."
  echo "- Контроль сроков сертификатов, OCSP stapling."
} > "$OUT_SUMMARY"

# ==========================
# SECURITY AUDIT
# ==========================
if [ "${ENABLE_SECURITY_CHECKS:-1}" = "1" ]; then
  log "===== Security Audit ====="
  
  # SSL/TLS Security Analysis
  log "===== SSL/TLS Security Analysis ====="
  
  # Check SSL protocols
  if grep -q "ssl_protocols" "$DUMP/nginx_T.txt" 2>/dev/null; then
    echo "[SECURITY] SSL протоколы:" | tee -a "$OUT_ISSUES"
    grep "ssl_protocols" "$DUMP/nginx_T.txt" | tee -a "$OUT_ISSUES"
    
    # Check for insecure protocols
    if grep -q "SSLv2\|SSLv3" "$DUMP/nginx_T.txt"; then
      echo "[SECURITY] ВНИМАНИЕ: Обнаружены устаревшие SSL протоколы (SSLv2/SSLv3)" | tee -a "$OUT_ISSUES"
    fi
  else
    echo "[SECURITY] INFO: ssl_protocols не настроен" | tee -a "$OUT_ISSUES"
  fi
  
  # Check SSL ciphers
  if grep -q "ssl_ciphers" "$DUMP/nginx_T.txt" 2>/dev/null; then
    echo "[SECURITY] SSL шифры:" | tee -a "$OUT_ISSUES"
    grep "ssl_ciphers" "$DUMP/nginx_T.txt" | tee -a "$OUT_ISSUES"
  fi
  
  # Check for security headers
  log "===== Security Headers Analysis ====="
  
  # Check if security headers are configured
  SECURITY_HEADERS=("add_header X-Frame-Options" "add_header X-Content-Type-Options" "add_header X-XSS-Protection" "add_header Strict-Transport-Security")
  
  for header in "${SECURITY_HEADERS[@]}"; do
    if grep -q "$header" "$DUMP/nginx_T.txt" 2>/dev/null; then
      echo "[SECURITY] OK: Настроен $header" | tee -a "$OUT_ISSUES"
    else
      echo "[SECURITY] ВНИМАНИЕ: Не настроен $header" | tee -a "$OUT_ISSUES"
    fi
  done
  
  # Check server_tokens
  if grep -q "server_tokens off" "$DUMP/nginx_T.txt" 2>/dev/null; then
    echo "[SECURITY] OK: server_tokens отключен" | tee -a "$OUT_ISSUES"
  else
    echo "[SECURITY] ВНИМАНИЕ: server_tokens включен (раскрывает версию nginx)" | tee -a "$OUT_ISSUES"
  fi
  
  # Check for sensitive information exposure
  log "===== Sensitive Information Check ====="
  
  # Check for debug information
  if grep -q "debug_connection\|debug_points" "$DUMP/nginx_T.txt" 2>/dev/null; then
    echo "[SECURITY] ВНИМАНИЕ: Обнаружены debug настройки" | tee -a "$OUT_ISSUES"
    grep "debug_connection\|debug_points" "$DUMP/nginx_T.txt" | tee -a "$OUT_ISSUES"
  fi
  
  # Check for error pages that might expose information
  if grep -q "error_page.*50[0-9]" "$DUMP/nginx_T.txt" 2>/dev/null; then
    echo "[SECURITY] INFO: Настроены кастомные error pages" | tee -a "$OUT_ISSUES"
  fi
  
  # Check file permissions
  log "===== File Permissions Check ====="
  
  # Check nginx config file permissions
  if [ -r "/etc/nginx/nginx.conf" ]; then
    NGINX_CONF_PERMS=$(stat -c "%a" "/etc/nginx/nginx.conf" 2>/dev/null || echo "unknown")
    if [ "$NGINX_CONF_PERMS" != "644" ] && [ "$NGINX_CONF_PERMS" != "640" ]; then
      echo "[SECURITY] ВНИМАНИЕ: Небезопасные права на nginx.conf: $NGINX_CONF_PERMS" | tee -a "$OUT_ISSUES"
    else
      echo "[SECURITY] OK: Безопасные права на nginx.conf: $NGINX_CONF_PERMS" | tee -a "$OUT_ISSUES"
    fi
  fi
  
  # Check for world-readable sensitive files
  find /etc/nginx -type f -perm -o+r 2>/dev/null | while read -r file; do
    if [ -f "$file" ]; then
      echo "[SECURITY] ВНИМАНИЕ: Файл доступен для чтения всем: $file" | tee -a "$OUT_ISSUES"
    fi
  done
  
  # Check for open ports
  log "===== Open Ports Security Check ====="
  
  # Check if nginx is listening on all interfaces
  if ss -tlnp | grep -q ":80.*nginx\|:443.*nginx"; then
    echo "[SECURITY] INFO: Nginx слушает на портах 80/443" | tee -a "$OUT_ISSUES"
    
    # Check if listening on all interfaces (0.0.0.0)
    if ss -tlnp | grep -q "0.0.0.0:80\|0.0.0.0:443"; then
      echo "[SECURITY] ВНИМАНИЕ: Nginx слушает на всех интерфейсах (0.0.0.0)" | tee -a "$OUT_ISSUES"
    fi
  fi
  
  # Check for unnecessary open ports
  OPEN_PORTS=$(ss -tlnp | grep -E ":(80|443|8080|8443)" | wc -l)
  if [ "$OPEN_PORTS" -gt 2 ]; then
    echo "[SECURITY] ВНИМАНИЕ: Открыто много веб-портов: $OPEN_PORTS" | tee -a "$OUT_ISSUES"
  fi
  
  # Check for SSL certificate issues
  log "===== SSL Certificate Security Check ====="
  
  if [ -s "$OUT_CERTS" ]; then
    # Check for expired certificates
    if grep -q "expired\|EXPIRED" "$OUT_CERTS"; then
      echo "[SECURITY] КРИТИЧНО: Обнаружены истекшие сертификаты" | tee -a "$OUT_ISSUES"
    fi
    
    # Check for self-signed certificates
    if grep -q "self-signed\|SELF_SIGNED" "$OUT_CERTS"; then
      echo "[SECURITY] ВНИМАНИЕ: Обнаружены самоподписанные сертификаты" | tee -a "$OUT_ISSUES"
    fi
    
    # Check for weak key sizes
    if grep -q "1024\|512" "$OUT_CERTS"; then
      echo "[SECURITY] ВНИМАНИЕ: Обнаружены слабые ключи (< 2048 бит)" | tee -a "$OUT_ISSUES"
    fi
  fi
  
  # Generate security summary
  echo "" | tee -a "$OUT_ISSUES"
  echo "===== Security Summary =====" | tee -a "$OUT_ISSUES"
  
  CRITICAL_COUNT=$(grep -c "КРИТИЧНО:" "$OUT_ISSUES" 2>/dev/null || echo "0")
  WARNING_COUNT=$(grep -c "ВНИМАНИЕ:" "$OUT_ISSUES" 2>/dev/null || echo "0")
  OK_COUNT=$(grep -c "OK:" "$OUT_ISSUES" 2>/dev/null || echo "0")
  
  echo "[SECURITY] Критичных проблем: $CRITICAL_COUNT" | tee -a "$OUT_ISSUES"
  echo "[SECURITY] Предупреждений: $WARNING_COUNT" | tee -a "$OUT_ISSUES"
  echo "[SECURITY] OK проверок: $OK_COUNT" | tee -a "$OUT_ISSUES"
  
  if [ "$CRITICAL_COUNT" -gt 0 ]; then
    echo "[SECURITY] РЕКОМЕНДАЦИЯ: Немедленно устраните критические проблемы безопасности" | tee -a "$OUT_ISSUES"
  fi
  
  if [ "$WARNING_COUNT" -gt 0 ]; then
    echo "[SECURITY] РЕКОМЕНДАЦИЯ: Рассмотрите устранение предупреждений безопасности" | tee -a "$OUT_ISSUES"
  fi
  
  log "Security audit завершен"
else
  log "===== Security Audit ====="
  log "Security проверки отключены (ENABLE_SECURITY_CHECKS=0)"
fi

# ==========================
{
  echo "# Nginx audit ($HOST @ $TS)"
  echo
  echo "Отчётные файлы:"
  find "$OUT_DIR" -maxdepth 1 -type f -printf '%f\n' 2>/dev/null | sed 's/^/- /'
  echo
  echo "Дампы:"
  find "$DUMP" -maxdepth 1 -type f -printf '%f\n' 2>/dev/null | sed 's/^/- /'
} > "$OUT_DIR/README.txt"

# Ensure central audit dir + helpers
source "$(dirname -- "${BASH_SOURCE[0]:-$0}")/audit_common.sh"

# Copy short summary into central audit dir for quick access
SUMMARY_COPY="$AUDIT_DIR/nginx_summary.log"
if [ -f "$OUT_SUMMARY" ]; then sed -n '1,800p' "$OUT_SUMMARY"; else echo "(no summary)"; fi | write_audit_summary "$SUMMARY_COPY"

# Create archive under AUDIT_DIR using shared helper (excludes access/error logs)
create_and_verify_archive "$OUT_DIR" "nginx.tgz"

echo
echo "[OK] Готово."
echo "Каталог: $OUT_DIR"
