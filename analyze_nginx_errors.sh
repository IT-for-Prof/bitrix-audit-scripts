#!/usr/bin/env bash
# shellcheck disable=SC2016

# Re-exec under a sterile environment for automation to avoid sourcing
# user/system profiles (and accidentally running interactive menu.sh).
# If _STERILE is not set and we are in an interactive shell or BASH_ENV is set,
# re-exec using a minimal env and `bash --noprofile --norc` so the script runs
# deterministically in automation systems (cron, systemd, CI).
set -euo pipefail
if [ -z "${_STERILE:-}" ] && { [[ $- == *i* ]] || [ -n "${BASH_ENV:-}" ]; }; then
  # Ensure PS4 has a timestamp so 'bash -x' traces after re-exec include wall-clock time
  export PS4='+[$(date +%FT%T.%3N)] ${BASH_SOURCE[0]}:$LINENO: '
  # Preserve PS4 in the cleared environment so traced re-exec includes timestamps
  exec env -i PS4="$PS4" HOME=/root PATH=/usr/sbin:/usr/bin:/bin TERM=xterm-256color BASH_ENV= _STERILE=1 \
    bash --noprofile --norc "$0" "$@"
fi

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

with_locale(){ LANGUAGE="$SCRIPT_LANGUAGE" LC_TIME="$SCRIPT_LC_TIME" "$@"; }

# Default OUT_DIR (raw per-service data) under $HOME
OUT_DIR="${OUT_DIR:-${HOME}/nginx_audit}"
mkdir -p "$OUT_DIR"

# Central audit dir (use shared helper)
source "$(dirname -- "${BASH_SOURCE[0]:-$0}")/audit_common.sh"

# Quick options: --days N (default 7)
DAYS=7
while [[ ${#} -gt 0 ]]; do
  case "$1" in
    --days)
      shift
      DAYS=${1:-$DAYS}
      shift
      ;;
    --help|-h)
      echo "Usage: $0 [--days N]"
      exit 0
      ;;
    *) break ;; # rest of args not used currently
  esac
done

# Require gawk (we use asort/asorti in percentiles)
if command -v gawk >/dev/null 2>&1; then
  AWK_CMD=gawk
elif command -v awk >/dev/null 2>&1; then
  echo "ERROR: this script requires gawk (GNU awk) for percentiles and sorting. Please install gawk." >&2
  exit 1
else
  echo "ERROR: awk not found" >&2
  exit 1
fi

# Discover access/error logs under /var/log/nginx (rotated and compressed too)
LOG_GLOBS=(/var/log/nginx/*access* /var/log/nginx/*error* /var/log/nginx/*.log*)
LOGS=()
for g in "${LOG_GLOBS[@]}"; do
  for f in $g; do
    [[ -e "$f" ]] || continue
    # include readable files; zcat -f will handle compressed/plain
    LOGS+=("$f")
  done
done
if [[ ${#LOGS[@]} -eq 0 ]]; then
  echo "No nginx access/error logs found under /var/log/nginx" >&2
  exit 1
fi

# Date range (inclusive). END = today, START = today - (DAYS-1)
END_YMD=$(date +%Y%m%d)
START_YMD="$(date -d "${DAYS} days ago" +%Y%m%d 2>/dev/null || date -v -"${DAYS}"d +%Y%m%d 2>/dev/null || date +%Y%m%d)"

# Prepare a temp dir and a single filtered log (one-pass input) to speed up processing
TMPDIR=$(mktemp -d /tmp/nginx_analyze.XXXXXX)
FILTERED="$TMPDIR/filtered.log"
trap 'rm -rf "$TMPDIR"' EXIT

# Build filtered log: include only lines whose timestamp falls into START..END
zcat -f "${LOGS[@]:-}" 2>/dev/null | "$AWK_CMD" -v START_YMD="$START_YMD" -v END_YMD="$END_YMD" '
function monthnum(m){ m=tolower(m); return (m=="jan"?1: m=="feb"?2: m=="mar"?3: m=="apr"?4: m=="may"?5: m=="jun"?6: m=="jul"?7: m=="aug"?8: m=="sep"?9: m=="oct"?10: m=="nov"?11: m=="dec"?12:0) }
{
  if (match($0, /\[([0-9]{2})\/([A-Za-z]+)\/([0-9]{4}):[0-9]{2}:[0-9]{2}:[0-9]{2}/, a)) {
    day=a[1]; mon=a[2]; yr=a[3]; ymd = sprintf("%04d%02d%02d", yr, monthnum(mon), day);
    if (ymd >= START_YMD && ymd <= END_YMD) print
  }
}' > "$FILTERED"

if [[ ! -s "$FILTERED" ]]; then
  echo "No log lines found in the requested ${DAYS}-day window (${START_YMD}..${END_YMD})." >&2
  # let script continue but most outputs will be empty; or exit — choose to continue
fi

SRC=("$FILTERED")

# ====================== ВСПОМОГАТЕЛЬНЫЕ ЗАМЕТКИ ======================
# $time_local у вас вида: [DD/Mon/YYYY:HH:MM:SS +ZZZZ - $upstream_response_time]
# Ниже мы достаем содержимое [...] в A[1], далее split(A[1], P, " - "),
# где P[1] — time_local, P[2] — сырой upstream_response_time (URT).
# Функция max_urt() парсит одиночное значение / список и берёт максимум.

# ====================== ОСНОВНЫЕ ТЕСТЫ (ERRORS) ======================
printf 'TRACE-BLOCK-START: errors_summary %s\n' "$(date +%s.%3N)"
echo -e "==== Errors summary (HTTP 4xx/5xx, top 30) ===="
awk '
  match($0, /\] ([0-9]{3}) "/, m) && m[1] ~ /^[45]/ { print m[1] }
' "${SRC[@]}" 2>/dev/null | sort | uniq -c | sort -nr | head -30  || true

printf 'TRACE-BLOCK-END: errors_summary %s\n' "$(date +%s.%3N)"
printf 'TRACE-BLOCK-START: top_error_urls %s\n' "$(date +%s.%3N)"
echo -e "\n==== Top error URLs (no query, 4xx/5xx, top 50) ===="
awk '
  match($0, /\] ([0-9]{3}) "/, s) && s[1] ~ /^[45]/ &&
  match($0, /"[^"]* (\/[^ "]+) HTTP/, r) { u=r[1]; sub(/\?.*$/, "", u); print u }
' "${SRC[@]}" 2>/dev/null | sort | uniq -c | sort -nr | head -50 || true

printf 'TRACE-BLOCK-END: top_error_urls %s\n' "$(date +%s.%3N)"
printf 'TRACE-BLOCK-START: error_pairs %s\n' "$(date +%s.%3N)"
echo -e "\n==== Error pairs (code -> URL, top 50) ===="
awk '
  match($0, /\] ([0-9]{3}) "/, s) && s[1] ~ /^[45]/ &&
  match($0, /"[^"]* (\/[^ "]+) HTTP/, r) {
    u=r[1]; sub(/\?.*$/, "", u); printf "%s %s\n", s[1], u
  }
' "${SRC[@]}" 2>/dev/null | sort | uniq -c | sort -nr | head -50 || true

printf 'TRACE-BLOCK_END: error_pairs %s\n' "$(date +%s.%3N)"
printf 'TRACE-BLOCK-START: top_referers %s\n' "$(date +%s.%3N)"
echo -e "\n==== Top Referers on errors (top 30) ===="
awk '
  match($0, /\] ([0-9]{3}) "/, s) && s[1] ~ /^[45]/ {
    n=split($0, q, "\""); ref=q[4]; if(ref==""||ref=="-") ref="(direct)"; print ref
  }
' "${SRC[@]}" 2>/dev/null | sort | uniq -c | sort -nr | head -30 || true

printf 'TRACE-BLOCK-END: top_referers %s\n' "$(date +%s.%3N)"
printf 'TRACE-BLOCK-START: top_useragents %s\n' "$(date +%s.%3N)"
echo -e "\n==== Top User-Agents on errors (top 30) ===="
awk '
  match($0, /\] ([0-9]{3}) "/, s) && s[1] ~ /^[45]/ {
    n=split($0, q, "\""); ua=q[6]; if(ua=="") ua="-"; print ua
  }
' "${SRC[@]}" 2>/dev/null | sort | uniq -c | sort -nr | head -30 || true

printf 'TRACE-BLOCK-END: top_useragents %s\n' "$(date +%s.%3N)"
printf 'TRACE-BLOCK-START: top_client_ips %s\n' "$(date +%s.%3N)"
echo -e "\n==== Top client IPs on errors (top 30) ===="
awk '
  match($0, /^\S+/, ip) && match($0, /\] ([0-9]{3}) "/, s) && s[1] ~ /^[45]/ { print ip[0] }
' "${SRC[@]}" 2>/dev/null | sort | uniq -c | sort -nr | head -30 || true

printf 'TRACE-BLOCK-END: top_client_ips %s\n' "$(date +%s.%3N)"
printf 'TRACE-BLOCK-START: errors_by_hour %s\n' "$(date +%s.%3N)"
echo -e "\n==== Errors by hour (all days combined, top 24) ===="
awk '
  match($0, /\[([^:]+):([0-9]{2}):[0-9]{2}:[0-9]{2} /, t) &&
  match($0, /\] ([0-9]{3}) "/, s) && s[1] ~ /^[45]/ { print t[2]":00" }
' "${SRC[@]}" 2>/dev/null | sort | uniq -c | sort -nr | head -24 || true

# ====================== ВРЕМЯ/URT (ГЛОБАЛЬНО) ======================
printf 'TRACE-BLOCK-END: errors_by_hour %s\n' "$(date +%s.%3N)"
printf 'TRACE-BLOCK-START: urt_token_shapes %s\n' "$(date +%s.%3N)"
echo -e "\n==== URT token shapes ===="
awk '
{
  if (!match($0, /\[([^\]]+)\]/, A)) next
  split(A[1], P, " - ")   # P[1]=time_local, P[2]=upstream_response_time(raw)
  t=P[2]; gsub(/^ +| +$/, "", t)
  if (t=="" || t=="-") print "(dash)"
  else if (t ~ /^[0-9.]+$/) print "(single)"
  else print "(list) " t
}' "${SRC[@]}" 2>/dev/null | sort | uniq -c | sort -nr | head -20 || true
printf 'TRACE-BLOCK-END: urt_token_shapes %s\n' "$(date +%s.%3N)"
printf 'TRACE-BLOCK-START: urt_percentiles %s\n' "$(date +%s.%3N)"

echo -e "\n==== URT percentiles (p50/p95/p99) ===="
awk '
function max_urt(raw,  t,n,a,i,m,v){
  t=raw; gsub(/^ +| +$/, "", t)
  if (t=="" || t=="-") return -1
  n=split(t, a, /[ ,;:]+/); m=-1
  for (i=1;i<=n;i++) if (a[i] ~ /^[0-9]*\.?[0-9]+$/) { v=a[i]+0; if (v>m) m=v }
  return m
}
{
  if (!match($0, /\[([^\]]+)\]/, A)) next
  split(A[1], P, " - "); v=max_urt(P[2]); if (v>=0) vals[++c]=v
}
END{
  if (c==0) { print "no data"; exit }
  asort(vals)
  p50 = vals[int(0.50*c) ? int(0.50*c) : 1]
  p95 = vals[int(0.95*c) ? int(0.95*c) : c]
  p99 = vals[int(0.99*c) ? int(0.99*c) : c]
  printf "p50=%.3fs  p95=%.3fs  p99=%.3fs  (n=%d)\n", p50, p95, p99, c
}' "${SRC[@]}" 2>/dev/null
printf 'TRACE-BLOCK-END: urt_percentiles %s\n' "$(date +%s.%3N)"

printf 'TRACE-BLOCK-START: urt_buckets %s\n' "$(date +%s.%3N)"

echo -e "\n==== URT buckets (fixed parser) ===="
awk '
function max_urt(raw,  t,n,a,i,m,v){
  t=raw; gsub(/^ +| +$/, "", t)
  if (t=="" || t=="-") return -1
  n=split(t, a, /[ ,;:]+/); m=-1
  for (i=1;i<=n;i++) if (a[i] ~ /^[0-9]*\.?[0-9]+$/) { v=a[i]+0; if (v>m) m=v }
  return m
}
{
  if (!match($0, /\[([^\]]+)\]/, A)) next
  split(A[1], P, " - "); v = max_urt(P[2]); if (v<0) next
  b = (v>=5 ? ">=5s" : v>=3 ? "3–5s" : v>=1 ? "1–3s" : v>=0.5 ? "0.5–1s" : "<0.5s")
  print b
}' "${SRC[@]}" 2>/dev/null | sort | uniq -c | sort -nr

# ====================== МЕДЛЕННЫЕ URL (оптимизировано, единый проход) ======================
printf 'TRACE-BLOCK-START: slow_urls_aggregate %s\n' "$(date +%s.%3N)"
gawk '
function max_urt(raw, t,n,a,i,m,v){ t=raw; gsub(/^ +| +$/, "", t); if(t==""||t=="-") return -1; n=split(t,a,/[ ,;:]+/); m=-1; for(i=1;i<=n;i++) if(a[i] ~ /^[0-9]*\.?[0-9]+$/){ v=a[i]+0; if(v>m)m=v } return m }
{
  if (!match($0, /\[([^\]]+)\]/, B)) next
  split(B[1], P, " - "); v=max_urt(P[2]); if (v<0) next
  if (!match($0, /"[^"]* (\/[^ "]+) HTTP/, R)) next
  u=R[1]; sub(/\?.*$/,"",u)
  sum[u]+=v; cnt[u]++; if(v>mx[u]) mx[u]=v
}
END{
  # compute averages and sort by average desc using asorti on avg values
  for (u in cnt) avg[u]=sum[u]/cnt[u]
  n = asorti(avg, sorted, "@val_num_desc")

  printf "\n==== Slow URLs (avg/max/req) top 20 ===\n"
  for (i=1;i<=20 && i<=n;i++){
    u = sorted[i]
    printf "%.3fs avg | %.3fs max | %6d req | %s\n", avg[u], mx[u], cnt[u], u
  }

  printf "\n==== Slow URLs (avg>=1s OR max>=3s) top 100 ===\n"
  p=0
  for (i=1;i<=n && p<100;i++){
    u = sorted[i]
    if (avg[u] >= 1 || mx[u] >= 3){
      printf "%.3fs avg | %.3fs max | %6d req | %s\n", avg[u], mx[u], cnt[u], u
      p++
    }
  }
}
' "${SRC[@]}" 2>/dev/null || true
printf 'TRACE-BLOCK-END: slow_urls_aggregate %s\n' "$(date +%s.%3N)"

echo -e "\n==== Slow & errors (code -> URL, avg/max URT) top 50 ===="
"$AWK_CMD" '
function max_urt(raw, t,n,a,i,m,v){ t=raw; gsub(/^ +| +$/, "", t); if(t==""||t=="-")return -1; n=split(t,a,/[ ,;:]+/); m=-1; for(i=1;i<=n;i++) if(a[i] ~ /^[0-9]*\.?[0-9]+$/){ v=a[i]+0; if(v>m)m=v } return m }
{
  if (!match($0, /\[([^\]]+)\]/, B)) next
  split(B[1], P, " - "); v=max_urt(P[2]); if (v<0) next
  if (!match($0, /\] ([0-9]{3}) "/, S)) next
  code=S[1]; if (code !~ /^[45]/) next
  if (!match($0, /"[^\"]* (\/[^ \"]+) HTTP/, R)) next
  u=R[1]; sub(/\?.*$/,"",u)
  k=code" "u; sum[k]+=v; cnt[k]++; if(v>mx[k]) mx[k]=v
}
END{
  for (k in cnt) avg[k]=sum[k]/cnt[k]
  # sort keys by avg desc using gawk asorti and print top 50
  n = asorti(avg, sorted, "@val_num_desc")
  for (i=1;i<=50 && i<=n;i++){
    k = sorted[i]
    printf "%.3fs avg | %.3fs max | %6d req | %s\n", avg[k], mx[k], cnt[k], k
  }
}' "${SRC[@]}" 2>/dev/null || true

# ====================== КРИТИЧНЫЕ КОДЫ С ДАТАМИ ======================
echo -e "\n==== 5xx by URL (first/last + avg/max URT) ===="
awk '
function max_urt(raw, t,n,a,i,m,v){ t=raw; gsub(/^ +| +$/, "", t); if(t==""||t=="-")return -1; n=split(t,a,/[ ,;:]+/); m=-1; for(i=1;i<=n;i++) if(a[i] ~ /^[0-9]*\.?[0-9]+$/){ v=a[i]+0; if(v>m)m=v } return m }
function upd(k,dt){ if(!(k in f)||dt<f[k])f[k]=dt; if(!(k in l)||dt>l[k])l[k]=dt }
{
  if (!match($0, /\[([^\]]+)\]/, T)) next
  split(T[1], P, " - "); dt=P[1]; v=max_urt(P[2]); if (v<0) next
  if (!match($0, /\] ([0-9]{3}) "/, S)) next
  code=S[1]; if (code !~ /^5/) next
  if (!match($0, /"[^"]* (\/[^ "]+) HTTP/, R)) next
  u=R[1]; sub(/\?.*$/,"",u); k=code" "u
  c[k]++; s[k]+=v; if(v>m[k]) m[k]=v; upd(k,dt)
}
END{ for (k in c) printf "%s | %6d | %.3fs avg | %.3fs max | first=%s | last=%s\n", k, c[k], s[k]/c[k], m[k], f[k], l[k] }' "${SRC[@]}" | sort -t'|' -k2,2nr | head -50 || true

echo -e "\n==== 499 by URL (first/last + avg/max URT) ===="
awk '
function max_urt(raw, t,n,a,i,m,v){ t=raw; gsub(/^ +| +$/, "", t); if(t==""||t=="-")return -1; n=split(t,a,/[ ,;:]+/); m=-1; for(i=1;i<=n;i++) if(a[i] ~ /^[0-9]*\.?[0-9]+$/){ v=a[i]+0; if(v>m)m=v } return m }
function upd(k,dt){ if(!(k in f)||dt<f[k])f[k]=dt; if(!(k in l)||dt>l[k])l[k]=dt }
{
  if (!match($0, /\[([^\]]+)\]/, T)) next
  split(T[1], P, " - "); dt=P[1]; v=max_urt(P[2]); if (v<0) next
  if (!match($0, /\] (499) "/, S)) next
  if (!match($0, /"[^"]* (\/[^ "]+) HTTP/, R)) next
  u=R[1]; sub(/\?.*$/,"",u); k="499 "u
  c[k]++; s[k]+=v; if(v>m[k]) m[k]=v; upd(k,dt)
}
END{ for (k in c) printf "%s | %6d | %.3fs avg | %.3fs max | first=%s | last=%s\n", k, c[k], s[k]/c[k], m[k], f[k], l[k] }' "${SRC[@]}" | sort -t'|' -k2,2nr | head -15 || true

echo -e "\n==== 401 by URL (first/last) ===="
awk '
function upd(k,dt){ if(!(k in f)||dt<f[k])f[k]=dt; if(!(k in l)||dt>l[k])l[k]=dt }
{
  if (!match($0, /\[([^\]]+)\]/, T)) next
  split(T[1], P, " - "); dt=P[1]
  if (!match($0, /\] (401) "/, S)) next
  if (!match($0, /"[^"]* (\/[^ "]+) HTTP/, R)) next
  u=R[1]; sub(/\?.*$/,"",u); k="401 "u; c[k]++; upd(k,dt)
}
END{ for (k in c) printf "%s | %6d | first=%s | last=%s\n", k, c[k], f[k], l[k] }' "${SRC[@]}" | sort -t'|' -k2,2nr | head -50 || true

# ====================== ОДИНОЧНЫЕ САМЫЕ МЕДЛЕННЫЕ ======================
echo -e "\n==== Top single slow requests (URT desc, top 30) ===="
awk '
function max_urt(raw, t,n,a,i,m,v){ t=raw; gsub(/^ +| +$/, "", t); if(t==""||t=="-")return -1; n=split(t,a,/[ ,;:]+/); m=-1; for(i=1;i<=n;i++) if(a[i] ~ /^[0-9]*\.?[0-9]+$/){ v=a[i]+0; if(v>m)m=v } return m }
{
  if (!match($0, /\[([^\]]+)\]/, A)) next
  split(A[1], P, " - "); ts=P[1]; v = max_urt(P[2]); if (v<0) next
  if (!match($0, /\] ([0-9]{3}) "/, S)) next
  code=S[1]
  if (!match($0, /"[^"]* (\/[^ "]+) HTTP/, R)) next
  url=R[1]; sub(/\?.*$/, "", url)
  if (!match($0, /^\S+/, IP)) IP[0]="-"
  n=split($0, Q, "\""); ref=Q[4]; if(ref==""||ref=="-") ref="(direct)"; ua=Q[6]; if(ua=="") ua="-"
  printf "%.3f %s %s %s | ref=%s | ua=%s | ip=%s\n", v, ts, code, url, ref, ua, IP[0]
}' "${SRC[@]}" | sort -nr | head -30 || true

# ====================== ВРЕМЯ С ПРИВЯЗКОЙ К ДАТЕ ======================
echo -e "\n==== Hourly URT avg (all days combined) ===="
awk '
function max_urt(raw, t,n,a,i,m,v){ t=raw; gsub(/^ +| +$/, "", t); if(t==""||t=="-")return -1; n=split(t,a,/[ ,;:]+/); m=-1; for(i=1;i<=n;i++) if(a[i] ~ /^[0-9]*\.?[0-9]+$/){ v=a[i]+0; if(v>m)m=v } return m }
{
  if (!match($0, /\[([^\]]+)\]/, A)) next
  split(A[1], P, " - "); v = max_urt(P[2]); if (v<0) next
  if (match(P[1], /:([0-9]{2}):[0-9]{2}:[0-9]{2} /, H)) {
    h=H[1]; key=sprintf("%02d:00", h); S[key]+=v; C[key]++
  }
}
END{ for (k in C) printf "%s avg=%.3fs n=%d\n", k, S[k]/C[k], C[k] }' "${SRC[@]}" | sort

echo -e "\n==== Hourly URT avg by date ===="
awk '
function max_urt(raw, t,n,a,i,m,v){ t=raw; gsub(/^ +| +$/, "", t); if(t==""||t=="-")return -1; n=split(t,a,/[ ,;:]+/); m=-1; for(i=1;i<=n;i++) if(a[i] ~ /^[0-9]*\.?[0-9]+$/){ v=a[i]+0; if(v>m)m=v } return m }
{
  if (!match($0, /\[([^\]]+)\]/, A)) next
  split(A[1], P, " - ")        # P[1] = "DD/Mon/YYYY:HH:MM:SS +ZZZZ"
  v = max_urt(P[2]); if (v<0) next
  if (match(P[1], /^([^:]+):([0-9]{2}):[0-9]{2}:[0-9]{2} /, H)) {
    d=H[1]; h=H[2]; key=d" "h":00"; S[key]+=v; C[key]++
  }
}
END{ for (k in C) printf "%s avg=%.3fs n=%d\n", k, S[k]/C[k], C[k] }' "${SRC[@]}" | sort

echo -e "\n==== Errors by hour by date (4xx/5xx) ===="
awk '
{
  if (!match($0, /\[([^\]]+)\]/, A)) next
  tl=A[1]
  if (!match($0, /\] ([0-9]{3}) "/, S)) next
  code=S[1]
  if (code !~ /^[45]/) next
  if (match(tl, /^([^:]+):([0-9]{2}):[0-9]{2}:[0-9]{2} /, H)) {
    d=H[1]; h=H[2]; key=d" "h":00"; cnt[key]++
  }
}
END{ for (k in cnt) printf "%6d %s\n", cnt[k], k }' "${SRC[@]}" | sort -k2,2 -k1,1nr

# ====================== МИКС СТАТУСОВ ПО URL ======================
echo -e "\n==== Status mix by URL (top 80) ===="
awk '
{
  if (!match($0, /\] ([0-9]{3}) "/, S)) next
  code=S[1]
  if (!match($0, /"[^"]* (\/[^ "]+) HTTP/, R)) next
  u=R[1]; sub(/\?.*$/,"",u)
  k=u" "code; c[k]++
}
END{
  for (k in c) {
    split(k, a, " ")
    st=a[length(a)]
    $0=k; sub(" [^ ]+$",""); url=$0
    printf "%6d %s %s\n", c[k], url, st
  }
}' "${SRC[@]}" | sort -nr | head -80  || true

###############################################################################
# 5xx: Агрегат по URL (count + first/last по времени) за вчера+сегодня
# Требует: переменная SRC уже собрана выше (вчерашний + текущий логи).
# Пример: SRC="/var/log/nginx/access.log-$(date +%Y%m%d) /var/log/nginx/access.log"

echo -e "==== 5xx — by URL (count + first/last timestamps) ===="
echo "Агрегирует все ответы 5xx по каждому URL (без query), показывает счётчик и первый/последний штамп времени."
awk '
{
  # time_local и (опционально) URT лежат в квадратных скобках: [time_local - upstream_response_time]
  if (!match($0, /\[([^\]]+)\]/, A)) next
  split(A[1], P, " - ")         # P[1] = time_local "DD/Mon/YYYY:HH:MM:SS +ZZZZ"
  dt=P[1]

  # HTTP-статус
  if (!match($0, /\] ([0-9]{3}) "/, S)) next
  code=S[1]
  if (code !~ /^5/) next

  # URL без query
  if (!match($0, /"[^"]* (\/[^ "]+) HTTP/, R)) next
  u=R[1]; sub(/\?.*$/, "", u)

  # Агрегация
  c[u]++
  if (!(u in f) || dt < f[u]) f[u]=dt
  if (!(u in l) || dt > l[u]) l[u]=dt
}
END{
  for (u in c) printf "%6d %s | first=%s | last=%s\n", c[u], u, f[u], l[u]
}' "${SRC[@]}" 2>/dev/null | sort -t'|' -k1,1nr

###############################################################################
# 5xx: Полная лента событий (точное время, код, URL, IP, Referer, UA)
# Опционально: ограничить количество строк через FIVE_XX_LIMIT (например, FIVE_XX_LIMIT=1000)

LIMIT="${FIVE_XX_LIMIT:-}"

echo -e "\n==== 5xx — full event stream (timestamp, code, URL, IP, Referer, UA) ===="
echo "Полный список всех ответов 5xx в хронологическом порядке (вчера→сегодня)."

awk '
{
  # Время
  if (!match($0, /\[([^\]]+)\]/, A)) next
  split(A[1], P, " - ")
  ts=P[1]

  # Код ответа
  if (!match($0, /\] ([0-9]{3}) "/, S)) next
  code=S[1]
  if (code !~ /^5/) next

  # URL без query
  if (!match($0, /"[^"]* (\/[^ "]+) HTTP/, R)) next
  url=R[1]; sub(/\?.*$/, "", url)

  # IP (первое поле в логе)
  if (!match($0, /^\S+/, IP)) IP[0]="-"

  # Referer и UA — через разбиение по кавычкам
  n=split($0, Q, "\"")
  ref=Q[4]; if(ref=="" || ref=="-") ref="(direct)"
  ua =Q[6]; if(ua=="") ua="-"

  printf "%s %s %s | ip=%s | ref=%s | ua=%s\n", ts, code, url, IP[0], ref, ua
}
' "${SRC[@]}" 2>/dev/null | if [[ -n "$LIMIT" ]]; then head -n "$LIMIT"; else cat; fi

ANALYZE_SUMMARY="$AUDIT_DIR/nginx_analyze_summary.log"
{
  echo "# Nginx Analyze Summary: $(date --iso-8601=seconds)"
  echo
  echo "==== Errors summary (top) ===="
  awk 'match($0, /\] ([0-9]{3}) "/, m) && m[1] ~ /^[45]/ { print m[1] }' "$FILTERED" 2>/dev/null | sort | uniq -c | sort -nr | head -n 20 || true
  echo
  echo "==== Top error URLs (top 20) ===="
  awk 'match($0, /\] ([0-9]{3}) "/, s) && s[1] ~ /^[45]/ && match($0, /"[^\"]* (\/[^ \"]+) HTTP/, r) { u=r[1]; sub(/\?.*$/, "", u); print u }' "$FILTERED" 2>/dev/null | sort | uniq -c | sort -nr | head -n 20 || true
} | write_audit_summary "$ANALYZE_SUMMARY"

###############################################################################
# 5xx — Агрегат по URL с разбивкой по кодам + first/last
FIVE_XX_SORT="${FIVE_XX_SORT:-count}"   # count|last|first
FIVE_XX_CODES="${FIVE_XX_CODES:-}"      # напр.: "500 502 503 504" (если пусто — любые 5xx)

echo -e "==== 5xx — by URL (count + per-code + first/last) ===="
echo "Агрегирует все 5xx по URL (без query). Показывает total, разрез по кодам, первый и последний штамп времени."
awk -v codes="$FIVE_XX_CODES" '
BEGIN{
  split(codes, ALLOW); allow_any = (codes=="")
}
{
  # time
  if (!match($0, /\[([^\]]+)\]/, A)) next
  split(A[1], P, " - "); dt=P[1]

  # status
  if (!match($0, /\] ([0-9]{3}) "/, S)) next
  code=S[1]
  if (code !~ /^5/) next
  if (!allow_any) { ok=0; for (i in ALLOW) if (code==ALLOW[i]) { ok=1; break } if(!ok) next }

  # URL (no query)
  if (!match($0, /"[^"]* (\/[^ "]+) HTTP/, R)) next
  u=R[1]; sub(/\?.*$/, "", u)

  T[u]++               # total per URL
  C[u,code]++          # per code per URL
  if (!(u in F) || dt < F[u]) F[u]=dt
  if (!(u in L) || dt > L[u]) L[u]=dt

  # копим набор кодов, чтобы вывести в порядке возрастания
  K[code]=1
}
END{
  # Сформируем вывод: total | url | codes... | first= | last=
  for (u in T) {
    line = sprintf("%6d %s |", T[u], u)
    # по кодам
    for (k in K) keys[++nk]=k
  }
  # отсортируем список кодов как числа
  asort(keys)
  # теперь снова печать (после сортировки keys)
  for (u in T) {
    printf "%6d %s |", T[u], u
    for (i=1;i<=nk;i++) {
      k = keys[i]
      if ((u SUBSEP k) in C) printf " %s=%d", k, C[u,k]
    }
    printf " | first=%s | last=%s\n", F[u], L[u]
  }
}' "${SRC[@]}" 2>/dev/null | {
  case "$FIVE_XX_SORT" in
    last)  sort -t'|' -k3,3 ;;          # сортировка по last (лексикографически по дате)
    first) sort -t'|' -k2,2 ;;          # по first
    *)     sort -nr ;;                  # по total (count)
  esac
}

###############################################################################
# 5xx — Полная лента событий (timestamp, code, URL, IP, Referer, UA)
LIMIT="${FIVE_XX_LIMIT:-}"

echo -e "\n==== 5xx — full event stream (timestamp, code, URL, IP, Referer, UA) ===="
echo "Полный список 5xx в хронологическом порядке (вчера→сегодня). Для ограничения объёма задайте FIVE_XX_LIMIT."
awk '
{
  # time
  if (!match($0, /\[([^\]]+)\]/, A)) next
  split(A[1], P, " - "); ts=P[1]

  # status
  if (!match($0, /\] ([0-9]{3}) "/, S)) next
  code=S[1]
  if (code !~ /^5/) next

  # URL (no query)
  if (!match($0, /"[^"]* (\/[^ "]+) HTTP/, R)) next
  url=R[1]; sub(/\?.*$/, "", url)

  # IP
  if (!match($0, /^\S+/, IP)) IP[0]="-"

  # Referer / UA
  n=split($0, Q, "\"")
  ref=Q[4]; if(ref==""||ref=="-") ref="(direct)"
  ua =Q[6]; if(ua=="") ua="-"

  # Вывод в виде: YYYY/Mon/DD:HH:MM:SS +ZZZZ CODE URL | ip=... | ref=... | ua=...
  printf "%s %s %s | ip=%s | ref=%s | ua=%s\n", ts, code, url, IP[0], ref, ua
}
' "${SRC[@]}" 2>/dev/null | if [[ -n "$LIMIT" ]]; then head -n "$LIMIT"; else cat; fi
