#!/usr/bin/env bash
# Re-exec in a sterile env to avoid interactive profile/menu scripts being sourced by child shells.
if [ -z "${_STERILE:-}" ] && { [[ $- == *i* ]] || [ -n "${BASH_ENV:-}" ]; }; then
  exec env -i PS4="$PS4" HOME=/root PATH=/usr/sbin:/usr/bin:/bin TERM=xterm-256color BASH_ENV= _STERILE=1 \
    bash --noprofile --norc "$0" "$@"
fi
# sar-analyzer.sh — консольный отчёт по sysstat (sar/sadf), header-aware
# Требования: bash>=4, sar/sadf, gawk, sort, head, tail, grep, env, date
set -Eeuo pipefail

### === ENV defaults ===
START="${START:-08:00:00}"
END="${END:-19:00:00}"
MAX_FILES="${MAX_FILES:-4}"
LOCALE="${LOCALE:-ru_RU.UTF-8}"
TOPN="${TOPN:-20}"
DEBUG="${DEBUG:-0}"
INCLUDE_LO="${INCLUDE_LO:-0}"

# Пороги
CPU_BUSY_PCT="${CPU_BUSY_PCT:-75}"
CPU_IOWAIT_WARN="${CPU_IOWAIT_WARN:-5}"
CPU_STEAL_WARN="${CPU_STEAL_WARN:-1}"
RUNQ_FACTOR="${RUNQ_FACTOR:-1.0}"

DISK_AWAIT_WARN="${DISK_AWAIT_WARN:-20}"
DISK_AWAIT_SPIKE="${DISK_AWAIT_SPIKE:-50}"
DISK_UTIL_WARN="${DISK_UTIL_WARN:-70}"
DISK_UTIL_SPIKE="${DISK_UTIL_SPIKE:-90}"
DISK_AQU_SPIKE="${DISK_AQU_SPIKE:-5}"

IFUTIL_WARN="${IFUTIL_WARN:-70}"
NET_ERR_MIN="${NET_ERR_MIN:-0}"

# Скорости интерфейсов (для вычисления %ifutil при нуле в логах)
IF_SPEED_Mbps="${IF_SPEED_Mbps:-}"  # "eth0=1000,ens18=1000,lo=10000"

# sadf CSV с заголовками
SADF_OPTS=( -d -H )

### === Utils / locale ===
tmpdir="$(mktemp -d -t sar-an-XXXXXX)"
# Cleanup tmpdir on exit unless CLEAN_TMP is set to 0 (useful for debugging)
trap 'if [ "${CLEAN_TMP:-1}" -ne 0 ]; then rm -rf "$tmpdir"; fi' EXIT

log(){ echo "[$(date +%F\ %T)] $*" >&2; }
dbg(){ [ "$DEBUG" = "1" ] && log "DBG: $*"; }

require_cmd(){ local miss=0; for c in "$@"; do command -v "$c" >/dev/null 2>&1 || { echo "Нужна утилита: $c"; miss=1; }; done; [ $miss -eq 0 ] || exit 1; }

# Локали: время — по запросу, числа — в C (точка), чтобы printf не спотыкался
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

with_locale(){ LANGUAGE="$SCRIPT_LANGUAGE" LC_TIME="$SCRIPT_LC_TIME" "$@"; }

require_cmd sar sadf awk sort head tail grep date

OUT_DIR="${OUT_DIR:-${HOME}/sar_audit}"
mkdir -p "$OUT_DIR"

# Central audit dir for archives and helpers
source "$(dirname -- "${BASH_SOURCE[0]:-$0}")/audit_common.sh"

### === IF speeds map ===
# Normalize IF_SPEED_Mbps into a canonical comma-separated list of iface=speed entries.
# We avoid associative arrays to keep compatibility and to prevent 'unbound variable' issues.
IF_SPEED_Mbps_NORM=""
if [[ -n "${IF_SPEED_Mbps:-}" ]]; then
  IFS=',' read -r -a arr <<< "$IF_SPEED_Mbps"
  for kv in "${arr[@]}"; do
    kv_trimmed="$(printf '%s' "$kv" | sed -e 's/^\s*//' -e 's/\s*$//')"
    kv_norm="$(printf '%s' "$kv_trimmed" | sed -e 's/\s*=\s*/=/')"
    [[ "$kv_norm" =~ ^([^=]+)=(.+)$ ]] || continue
    key="${BASH_REMATCH[1]}"
    val="${BASH_REMATCH[2]}"
    IF_SPEED_Mbps_NORM="${IF_SPEED_Mbps_NORM:+${IF_SPEED_Mbps_NORM},}${key}=${val}"
  done
fi
# Per-IF overrides, типа IF_SPEED_Mbps_eth0=1000
while IFS='=' read -r k v; do
  [[ $k == IF_SPEED_Mbps_* ]] || continue
  iface="${k#IF_SPEED_Mbps_}"
  # trim whitespace from value
  v="$(printf '%s' "$v" | sed -e 's/^\s*//' -e 's/\s*$//')"
  IF_SPEED_Mbps_NORM="${IF_SPEED_Mbps_NORM:+${IF_SPEED_Mbps_NORM},}${iface}=${v}"
done < <(env)

# Log the resolved IF speed map for visibility
# Avoid referencing IFSPD directly under 'set -u' if it wasn't declared for some reason.
if [ -n "${IF_SPEED_Mbps_NORM:-}" ]; then
  dbg "IF speeds: $IF_SPEED_Mbps_NORM"
elif [ -n "${IF_SPEED_Mbps:-}" ]; then
  dbg "IF speeds (raw): $IF_SPEED_Mbps"
fi

# get_if_speed <iface>
# Returns numeric speed in Mbps or 0 if unknown. Looks up associative IFSPD when available,
# else parses IF_SPEED_Mbps string and environment overrides.
get_if_speed(){
  local iface="$1" val=""
  # env var override IF_SPEED_Mbps_<iface>
  local varname="IF_SPEED_Mbps_$iface"
  val="${!varname:-}"
  if [ -z "$val" ] && [ -n "${IF_SPEED_Mbps_NORM:-}" ]; then
    val=$(printf '%s' "$IF_SPEED_Mbps_NORM" | tr ',' '\n' | sed -n "s/^ *${iface} *= *\([0-9]\+\) *$/\1/p" | head -n1)
  fi
  if [ -z "$val" ] && [ -n "${IF_SPEED_Mbps:-}" ]; then
    val=$(printf '%s' "$IF_SPEED_Mbps" | tr ',' '\n' | sed -n "s/^ *${iface} *= *\([0-9]\+\) *$/\1/p" | head -n1)
  fi
  printf '%s' "${val:-0}"
}

### === Find saNN files by mtime ===
find_sa_files(){
  find /var/log/sa /var/log/sysstat -maxdepth 1 -type f -name 'sa[0-9]*' -printf '%T@ %p\n' 2>/dev/null \
  | sort -nr | awk '{print $2}' | head -n "$MAX_FILES"
}

### === Header ===
print_report_header(){
  printf "Окно анализа: %s-%s (LC_TIME=%s)\n" "$START" "$END" "$SCRIPT_LC_TIME"
  printf -- "--------------------------------------------------------------------------------\n\n"
}

### === Percentiles ===
percentile(){ # file p
  local file="$1" p="$2" n idx
  n=$(wc -l < "$file" | tr -d ' ')
  [ "$n" -gt 0 ] || { echo "NaN"; return; }
  idx=$(awk -v n="$n" -v p="$p" 'BEGIN{v=p*n; printf("%d", (v==int(v)?v:int(v)+1))}')
  sed -n "${idx}p" "$file"
}

### === TOP accumulators ===
TOP_CPU="$tmpdir/top_cpu.all"; TOP_MEM="$tmpdir/top_mem.all"; TOP_DISK="$tmpdir/top_disk.all"
TOP_NETLOAD="$tmpdir/top_netload.all"; TOP_NETERR="$tmpdir/top_neterr.all"
TOP_SOCK="$tmpdir/top_sock.all"; TOP_TCP="$tmpdir/top_tcp.all"; TOP_IP="$tmpdir/top_ip.all"
TOP_ALL="$tmpdir/top_all.all"
: >"$TOP_CPU"; : >"$TOP_MEM"; : >"$TOP_DISK"; : >"$TOP_NETLOAD"; : >"$TOP_NETERR"; : >"$TOP_SOCK"; : >"$TOP_TCP"; : >"$TOP_IP"; : >"$TOP_ALL"

append_top(){ # file score ts desc
  printf "%s;%s;%s\n" "$2" "$3" "$4" >>"$1"
  printf "%s;%s;%s\n" "$2" "$3" "$4" >>"$TOP_ALL"
}

### === has_data ===
has_data(){ # safile, sar-keys
  local f="$1"; shift
  sadf "${SADF_OPTS[@]}" -s "$START" -e "$END" "$f" -- "$@" 2>/dev/null | awk 'NR==2{ok=1} END{exit !ok}'
}

### === Sections ===

print_cpu_section(){
  local f="$1"
  echo "-- CPU"
  if ! has_data "$f" -u; then echo "  (нет данных sar -u в окне)"; return; fi

  local busy_vals="$tmpdir/cpu_busy.$RANDOM" iow_vals="$tmpdir/cpu_iow.$RANDOM"
  : >"$busy_vals"; : >"$iow_vals"

  # pctl + TOP
  sadf "${SADF_OPTS[@]}" -s "$START" -e "$END" "$f" -- -u \
  | awk -F';' -v busy_vals="$busy_vals" -v iow_vals="$iow_vals" \
        -v BUSYW="$CPU_BUSY_PCT" -v IOWW="$CPU_IOWAIT_WARN" -v STW="$CPU_STEAL_WARN" '
      NR==1{ for(i=1;i<=NF;i++) m[$i]=i; next }
      {
        cpu=$(m["CPU"])
        if (cpu!="-1" && cpu!="all") next
        usr=$(m["%user"])+0; sys=$(m["%system"])+0; iow=$(m["%iowait"])+0; stl=$(m["%steal"])+0; idle=$(m["%idle"])+0
        busy=usr+sys
        print busy >> busy_vals
        print iow  >> iow_vals
        ts=$(m["timestamp"])
        sc=(busy>BUSYW?2:0)+(iow>IOWW?2:0)+(stl>STW?3:0)
        if (sc>0) printf "%d;%s;busy=%.1f%% iow=%.1f%%\n", sc, ts, busy, iow
      }' \
  | sort -t';' -k1,1nr -k2,2 >>"$TOP_CPU"

  sort -n "$busy_vals" -o "$busy_vals"; sort -n "$iow_vals" -o "$iow_vals"
  local p95b p99b p95i p99i
  p95b=$(percentile "$busy_vals" 0.95); p99b=$(percentile "$busy_vals" 0.99)
  p95i=$(percentile "$iow_vals"  0.95); p99i=$(percentile "$iow_vals"  0.99)

  # runq/load из -q
  local runq_avg l1 l5 l15
  read -r runq_avg l1 l5 l15 < <(
  sadf "${SADF_OPTS[@]}" -s "$START" -e "$END" "$f" -- -q \
    | awk -F';' '
        NR==1{ for(i=1;i<=NF;i++) m[$i]=i; next }
        { rq+=$(m["runq-sz"])+0; l_1+=$(m["ldavg-1"])+0; l_5+=$(m["ldavg-5"])+0; l_15+=$(m["ldavg-15"])+0; n++ }
        END{ if(n>0) printf "%.2f %.2f %.2f %.2f\n", rq/n, l_1/n, l_5/n, l_15/n; else print "NaN NaN NaN NaN" }'
  )

  # cswch/s из -w
  local cswch_avg
  cswch_avg=$(
    sadf "${SADF_OPTS[@]}" -s "$START" -e "$END" "$f" -- -w \
    | awk -F';' 'NR==1{for(i=1;i<=NF;i++) m[$i]=i; next}{cs+=$(m["cswch/s"])+0; n++} END{printf n? cs/n:0}'
  )

  # avg steal/idle из -u
  local steal_avg idle_avg
  steal_avg=$(sadf "${SADF_OPTS[@]}" -s "$START" -e "$END" "$f" -- -u \
    | awk -F';' 'NR==1{for(i=1;i<=NF;i++) m[$i]=i; next} ($(m["CPU"])=="-1"||$(m["CPU"])=="all"){st+=$(m["%steal"]); n++} END{printf n? st/n:0}')
  idle_avg=$(sadf "${SADF_OPTS[@]}" -s "$START" -e "$END" "$f" -- -u \
    | awk -F';' 'NR==1{for(i=1;i<=NF;i++) m[$i]=i; next} ($(m["CPU"])=="-1"||$(m["CPU"])=="all"){id+=$(m["%idle"]); n++}  END{printf n? id/n:0}')

  printf "  avg busy(usr+sys)=%.1f%%  iowait=%.1f%%  steal=%.1f%%  idle=%.1f%%\n" \
    "$(awk '{s+=$1;n++} END{printf n? s/n:0}' "$busy_vals")" \
    "$(awk '{s+=$1;n++} END{printf n? s/n:0}' "$iow_vals")" \
    "${steal_avg:-0}" "${idle_avg:-0}"
  printf "  avg runq-sz=%s  load(1/5/15)=%s/%s/%s  cswch/s=%.0f\n" \
    "${runq_avg:-NaN}" "${l1:-NaN}" "${l5:-NaN}" "${l15:-NaN}" "${cswch_avg:-0}"
  printf "  p95/p99 busy=%.1f/%.1f%%  p95/p99 iowait=%.1f/%.1f%%\n" \
    "${p95b:-0}" "${p99b:-0}" "${p95i:-0}" "${p99i:-0}"

  awk -v p99i="${p99i:-0}" -v warn_i="$CPU_IOWAIT_WARN" 'BEGIN{ if (p99i>warn_i) printf "  [!] iowait p99=%.1f%% (>%d%%)\n", p99i, warn_i }'

  # Предупреждение по runq относительно vCPU
  local vcpu thr
  vcpu=$(nproc 2>/dev/null || echo 1)
  thr=$(awk -v v="$vcpu" -v f="$RUNQ_FACTOR" 'BEGIN{printf "%.2f", v*f}')
  if awk -v rq="$runq_avg" -v t="$thr" 'BEGIN{exit !(rq>t)}'; then
    echo "  [!] runq-sz avg=${runq_avg} (> ${thr})"
    # добавим в TOP_CPU и общий TOP
    append_top "$TOP_CPU" 2 "$(date +%F' '%T' UTC')" "runq avg=${runq_avg} (> ${thr})"
  fi

  echo
}

print_mem_section(){
  local f="$1"
  echo "-- Память/своп"
  if ! has_data "$f" -r; then echo "  (нет данных sar -r в окне)"; return; fi

  local memvals="$tmpdir/memused.$RANDOM" kbavals="$tmpdir/kbavail.$RANDOM"
  : >"$memvals"; : >"$kbavals"

  sadf "${SADF_OPTS[@]}" -s "$START" -e "$END" "$f" -- -r \
  | awk -F';' -v M="$memvals" -v K="$kbavals" '
      NR==1{for(i=1;i<=NF;i++) m[$i]=i; next}
      { mu=$(m["%memused"])+0; ka=$(m["kbavail"])+0; print mu>>M; print ka>>K; MU+=mu; KA+=ka; n++ }
      END{ if(n>0) printf "  avg %%memused=%.1f%%  kbavail=%.0f\n", MU/n, KA/n }'

  sort -n "$memvals" -o "$memvals"; sort -n "$kbavals" -o "$kbavals"
  local p95m p99m p5ka p1ka
  p95m=$(percentile "$memvals" 0.95); p99m=$(percentile "$memvals" 0.99)
  p5ka=$(percentile "$kbavals" 0.05); p1ka=$(percentile "$kbavals" 0.01)
  printf "  p95/p99 %%memused=%.1f/%.1f%%  (kbavail p5/p1≈%s/%s)\n" "${p95m:-0}" "${p99m:-0}" "${p5ka:-NaN}" "${p1ka:-NaN}"

  if has_data "$f" -S; then
    local swpavg
    swpavg=$(sadf "${SADF_OPTS[@]}" -s "$START" -e "$END" "$f" -- -S \
      | awk -F';' 'NR==1{for(i=1;i<=NF;i++) m[$i]=i; next}{s+=$(m["%swpused"]); n++} END{printf n? s/n:0}')
    printf "  avg %%swpused=%.1f%%\n" "${swpavg:-0}"
  fi

  if has_data "$f" -B; then
    local press
    press=$(sadf "${SADF_OPTS[@]}" -s "$START" -e "$END" "$f" -- -B \
      | awk -F';' 'NR==1{for(i=1;i<=NF;i++) m[$i]=i; next}{if($(m["pgscan/s"])+0>0 && $(m["pgsteal/s"])+0>0) p=1} END{print p+0}')
    [ "${press:-0}" -eq 1 ] && echo "  [!] Давление на кэш страниц: pgscan>0 и pgsteal>0 в окне"
  fi

  # ТОП по моментам памяти (фильтруем «пустые» записи)
  sadf "${SADF_OPTS[@]}" -s "$START" -e "$END" "$f" -- -r \
  | awk -F';' '
      NR==1{for(i=1;i<=NF;i++) m[$i]=i; next}
      { ts=(("timestamp" in m)? $(m["timestamp"]) : $1);
        mu=$(m["%memused"])+0; ka=$(m["kbavail"])+0;
        if (mu==0 && ka==0) next;
        score=(mu>80?2:0)+(ka<1048576?3:0);
        printf "%d;%s;%%memused=%.1f kbavail=%.0f\n", score, ts, mu, ka }' \
  | sort -t';' -k1,1nr -k2,2 >>"$TOP_MEM"

  echo
}

print_disk_section(){
  local f="$1"
  echo "-- Диски"
  if ! has_data "$f" -d; then echo "  (нет данных sar -d в окне)"; return; fi

  local avg_table="$tmpdir/disk_avg.$RANDOM"
  sadf "${SADF_OPTS[@]}" -s "$START" -e "$END" "$f" -- -d \
  | awk -F';' '
      NR==1{for(i=1;i<=NF;i++) m[$i]=i; next}
      { dev=$(m["DEV"]); await=$(m["await"])+0; util=$(m["%util"])+0; aqu=$(m["aqu-sz"])+0; c[dev]++; A[dev]+=await; U[dev]+=util; Q[dev]+=aqu }
      END{ for (d in A) printf "%-20s avg await=%.1fms  %%util=%.1f  aqu=%.2f\n", d, A[d]/c[d], U[d]/c[d], Q[d]/c[d] }' >"$avg_table"

  echo "  Средние задержки/занятость (топ 5 по await):"
  awk '{ if (match($0,/avg await=([0-9.]+)ms/,m)) print m[1], $0 }' "$avg_table" | sort -nr | head -n 5 | cut -d' ' -f2-

  awk -v aw="$DISK_AWAIT_WARN" -v uw="$DISK_UTIL_WARN" '
    match($0,/avg await=([0-9.]+)ms/,m1) && match($0,/%util=([0-9.]+)/,m2){
      if(m1[1]+0>aw) printf "  [!] %s (>%.0fms)\n", $0, aw;
      if(m2[1]+0>uw) printf "  [!] %s (>%.0f%%)\n", $0, uw;
    }' "$avg_table"

  sadf "${SADF_OPTS[@]}" -s "$START" -e "$END" "$f" -- -d \
  | awk -F';' -v awsp="$DISK_AWAIT_SPIKE" -v us="$DISK_UTIL_SPIKE" -v aq="$DISK_AQU_SPIKE" '
      NR==1{for(i=1;i<=NF;i++) m[$i]=i; next}
      { ts=$(m["timestamp"]); dev=$(m["DEV"]); await=$(m["await"])+0; util=$(m["%util"])+0; aqu=$(m["aqu-sz"])+0; sc=0;
        if (await>=awsp) sc+=3; if (util>=us) sc+=3; if (aqu>=aq) sc+=2;
        if (sc>0) printf "%d;%s;DEV=%s await=%.1fms util=%.0f%% aqu=%.2f\n", sc, ts, dev, await, util, aqu;
      }' \
  | sort -t';' -k1,1nr -k2,2 >>"$TOP_DISK"
  echo
}

print_net_section(){
  local f="$1"
  echo "-- Сеть"
  if ! has_data "$f" -n DEV; then echo "  (нет данных sar -n DEV в окне)"; return; fi

  local iflist="$tmpdir/ifaces.$RANDOM"; : >"$iflist"
  sadf "${SADF_OPTS[@]}" -s "$START" -e "$END" "$f" -- -n DEV \
  | awk -F';' -v inc_lo="$INCLUDE_LO" '
      NR==1{for(i=1;i<=NF;i++) m[$i]=i; next}
      {
        ts=$(m["timestamp"]); ifc=$(m["IFACE"])
        if (ts !~ /^[0-9]{4}-[0-9]{2}-[0-9]{2} /) next
        if (inc_lo==0 && ifc=="lo") next
        if (ifc ~ /[[:space:]]/ || ifc=="IFACE" || ifc ~ /^LINUX-RESTART/) next
        if(!seen[ifc]++) print ifc
      }' >"$iflist"

  echo "  Средние по интерфейсам:"
  while read -r iface; do
    local rxfile="$tmpdir/${iface}.rx" txfile="$tmpdir/${iface}.tx" utilfile="$tmpdir/${iface}.util"
    : >"$rxfile"; : >"$txfile"; : >"$utilfile"

  sadf "${SADF_OPTS[@]}" -s "$START" -e "$END" "$f" -- -n DEV \
    | awk -F';' -v ifc="$iface" -v RX="$rxfile" -v TX="$txfile" -v UT="$utilfile" '
        NR==1{for(i=1;i<=NF;i++) m[$i]=i; next}
        $(m["IFACE"])==ifc { print $(m["rxkB/s"])>>RX; print $(m["txkB/s"])>>TX; print $(m["%ifutil"])>>UT }'

    sort -n "$rxfile" -o "$rxfile"; sort -n "$txfile" -o "$txfile"; sort -n "$utilfile" -o "$utilfile"

    local rxavg txavg ifutil_avg speed util_known
    rxavg=$(awk '{s+=$1;n++} END{printf n? s/n:0}' "$rxfile")
    txavg=$(awk '{s+=$1;n++} END{printf n? s/n:0}' "$txfile")
    util_known=$(awk '{if($1>0) k=1} END{print k+0}' "$utilfile")
  speed="$(get_if_speed "$iface")"
    if [ "$util_known" -eq 1 ]; then
      ifutil_avg=$(awk '{s+=$1;n++} END{printf n? s/n:0}' "$utilfile")
    elif [ "${speed:-0}" != "0" ]; then
      # оценка средней %ifutil по сумме rx+tx
      ifutil_avg=$(awk -v sp="$speed" 'NR==FNR{a[NR]=$1; next}{s+=(a[FNR]+$1)} END{printf s? 100*(s*1024*8/sp/1e6)/NR:0}' "$rxfile" "$txfile")
    else
      echo "  [!] Интерфейс $iface: %ifutil=0.00 — неизвестна скорость линка. Укажи IF_SPEED_Mbps_$iface=... или IF_SPEED_Mbps=\"iface=...,...\""
      ifutil_avg=0
    fi
    printf "   - %-12s rx=%.1fkB/s  tx=%.1fkB/s  %%ifutil≈%.1f\n" "$iface" "$rxavg" "$txavg" "$ifutil_avg"

    local sumfile="$tmpdir/${iface}.sum" p95 p99
    awk 'NR==FNR{a[NR]=$1; next}{print a[FNR]+$1}' "$rxfile" "$txfile" | sort -n >"$sumfile"
    p95=$(percentile "$sumfile" 0.95); p99=$(percentile "$sumfile" 0.99)
    printf "     p95/p99 load(rx+tx)=%.1f/%.1f kB/s\n" "${p95:-0}" "${p99:-0}"

    # ТОП по нагрузке (баллы только если скорость известна и %ifutil>=порога)
  sadf "${SADF_OPTS[@]}" -s "$START" -e "$END" "$f" -- -n DEV \
    | awk -F';' -v ifc="$iface" -v sp="${speed:-0}" -v warn="$IFUTIL_WARN" '
        NR==1{for(i=1;i<=NF;i++) m[$i]=i; next}
        $(m["IFACE"])!=ifc{next}
        { ts=$(m["timestamp"]); sum=$(m["rxkB/s"])+$(m["txkB/s"]); ifutil=$(m["%ifutil"])+0;
          if (ifutil==0 && sp>0) ifutil=100.0*(sum*1024*8)/(sp*1e6);
          score=(sp>0 && ifutil>=warn?2:0);
          printf "%d;%s;IF=%s load=%.1fkB/s ifutil=%.1f%%\n", score, ts, ifc, sum, ifutil }' \
    | sort -t';' -k1,1nr -k2,2 >>"$TOP_NETLOAD"

  done < "$iflist"

  if has_data "$f" -n EDEV; then
    sadf "${SADF_OPTS[@]}" -s "$START" -e "$END" "$f" -- -n EDEV \
    | awk -F';' -v min="$NET_ERR_MIN" -v inc_lo="$INCLUDE_LO" '
        NR==1{for(i=1;i<=NF;i++) m[$i]=i; next}
        { iface=$(m["IFACE"]); if(inc_lo==0 && iface=="lo") next
          rxerr=$(m["rxerr/s"])+0; txerr=$(m["txerr/s"])+0; rxdr=$(m["rxdrop/s"])+0; txdr=$(m["txdrop/s"])+0; ts=$(m["timestamp"])
          if (rxerr>min || txerr>min || rxdr>min || txdr>min) {
            score=(rxerr>0||txerr>0?3:0)+(rxdr>0||txdr>0?2:0)
            printf "%d;%s;IF=%s rxerr=%.1f txerr=%.1f rxdrop=%.1f txdrop=%.1f\n", score, ts, iface, rxerr, txerr, rxdr, txdr
          } }' \
    | sort -t';' -k1,1nr -k2,2 >>"$TOP_NETERR"
  fi
  echo
}

print_sock_tcp_ip_section_collect_tops(){
  local f="$1"
  if has_data "$f" -n SOCK; then
  sadf "${SADF_OPTS[@]}" -s "$START" -e "$END" "$f" -- -n SOCK \
    | awk -F';' 'NR==1{for(i=1;i<=NF;i++) m[$i]=i; next}
        { ts=$(m["timestamp"]); tots=$(m["totsck"])+0; tcps=$(m["tcpsck"])+0; udps=$(m["udpsck"])+0; tw=$(m["tcp-tw"])+0;
          score=(tw>0?1:0)
          printf "%d;%s;SOCK tots=%d tcp=%d udp=%d tw=%d\n", score, ts, tots, tcps, udps, tw }' \
    | sort -t';' -k1,1nr -k2,2 >>"$TOP_SOCK"
  fi
  if has_data "$f" -n TCP; then
  sadf "${SADF_OPTS[@]}" -s "$START" -e "$END" "$f" -- -n TCP \
    | awk -F';' 'NR==1{for(i=1;i<=NF;i++) m[$i]=i; next}
        { ts=$(m["timestamp"]); act=$(m["active/s"])+0; pas=$(m["passive/s"])+0; ret=$(m["retrans/s"])+0; est=$(m["estab"])+0; inerr=$(m["inerr"])+0;
          score=(ret>0?4:0)+(inerr>0?4:0)+((act>0||pas>0)?1:0)
          printf "%d;%s;TCP active/s=%.1f passive/s=%.1f retrans/s=%.1f estab=%d inerr=%.1f\n", score, ts, act, pas, ret, est, inerr }' \
    | sort -t';' -k1,1nr -k2,2 >>"$TOP_TCP"
  fi
  if has_data "$f" -n IP; then
  sadf "${SADF_OPTS[@]}" -s "$START" -e "$END" "$f" -- -n IP \
    | awk -F';' 'NR==1{for(i=1;i<=NF;i++) m[$i]=i; next}
        { ts=$(m["timestamp"]); irec=$(m["irec/s"])+0; idel=$(m["idel/s"])+0; irej=$(m["irej/s"])+0;
          score=(irej>0?3:0)+((irec>1000 && idel>0)?1:0)
          printf "%d;%s;IP irec/s=%.1f idel/s=%.1f irej/s=%.1f\n", score, ts, irec, idel, irej }' \
    | sort -t';' -k1,1nr -k2,2 >>"$TOP_IP"
  fi
}

### === TOP print ===
print_top_block(){ # title file
  local title="$1" file="$2"
  echo "$title (ТОП-$TOPN)"
  if [ ! -s "$file" ]; then echo "  (пусто)"; echo; return; fi
  sort -t';' -k1,1nr -k2,2 "$file" | head -n "$TOPN" | awk -F';' '{printf "  %s  %s\n", $2, $3}'
  echo
}

### === Main ===
print_report_header
mapfile -t sa_files < <(find_sa_files || true)
if [ "${#sa_files[@]}" -eq 0 ]; then echo "Нет файлов sa[NN]."; exit 0; fi
[ "$DEBUG" = "1" ] && { echo "Файлы к анализу (последние по mtime):"; printf " - %s\n" "${sa_files[@]}"; echo; }

for f in "${sa_files[@]}"; do
  printf "=== Файл: %s ===\n" "$f"
  print_cpu_section  "$f"
  print_mem_section  "$f"
  print_disk_section "$f"
  print_net_section  "$f"
  print_sock_tcp_ip_section_collect_tops "$f"
  printf -- "--------------------------------------------------------------------------------\n\n"
done

print_top_block "CPU"                 "$TOP_CPU"
print_top_block "Память/Swap"         "$TOP_MEM"
print_top_block "Диски — моменты"     "$TOP_DISK"
print_top_block "Сеть — нагрузка"     "$TOP_NETLOAD"
print_top_block "Сеть — ошибки/дропы" "$TOP_NETERR"
print_top_block "SOCK"                "$TOP_SOCK"
print_top_block "TCP"                 "$TOP_TCP"
print_top_block "IP"                  "$TOP_IP"

echo "Сводный ТОП-$TOPN по всем подсистемам"
if [ -s "$TOP_ALL" ]; then
  sort -t';' -k1,1nr -k2,2 "$TOP_ALL" | head -n "$TOPN" | awk -F';' '{printf "  %s  %s\n", $2, $3}'
else
  echo "  (пусто)"
fi
echo

# Справочно
if command -v lsblk >/dev/null 2>&1; then
  echo "Карта блочных устройств/томов (lsblk):"; lsblk -o NAME,KNAME,TYPE,SIZE,FSTYPE,MOUNTPOINTS; echo
fi
if command -v lvs >/dev/null 2>&1; then
  echo "LVM logical volumes (lvs):"; lvs; echo
fi
echo "Готово."

# Write short summary and archive collected tmp files into central AUDIT_DIR
SAR_SUMMARY="$AUDIT_DIR/sar_summary.log"
# Use TOP_ALL accumulator as a short summary (if present)
if [ -f "$TOP_ALL" ]; then
  sed -n '1,400p' "$TOP_ALL" 2>/dev/null | write_audit_summary "$SAR_SUMMARY"
else
  { echo "# sar summary: $(date --iso-8601=seconds)"; echo; } | write_audit_summary "$SAR_SUMMARY"
fi

# Archive the tmpdir (contains TOP_* and intermediate files); helper will exclude access/error and verify counts
create_and_verify_archive "$tmpdir" "sar.tgz"
