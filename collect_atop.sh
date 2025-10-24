#!/usr/bin/env bash

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

# Version information
VERSION="2.1.0"

# Basic helpers
say() { printf '%s\n' "$*"; }
run() { echo "+ $*" >&2; "$@"; }
die() { echo "ERROR: $*" >&2; exit 1; }

# Defaults and environment
OUT_DIR="${OUT_DIR:-${HOME}/atop_audit}"
mkdir -p "$OUT_DIR"

# Central audit archive directory (archives are stored here)
# Use shared audit_common helper for AUDIT_DIR
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

# full-day by default
FULL_DAY="${FULL_DAY:-1}"
TOPN="${TOPN:-5}"

# Check requirements using common function
check_requirements "ATOP" with_locale atopsar

declare -a LOGS=()
# Determine LOGPATH from systemd unit or config, with sensible fallbacks.
LOGPATH=""
if command -v systemctl >/dev/null 2>&1 && systemctl cat atop >/dev/null 2>&1; then
  # extract LOGPATH from Environment= lines, e.g. Environment="LOGPATH=/var/log/atop"
  lp=$(systemctl cat atop | grep -o 'LOGPATH=[^\" ]*' | head -n1 | cut -d= -f2- || true)
  [ -n "$lp" ] && LOGPATH="$lp"
fi

if [ -z "$LOGPATH" ] && [ -r /etc/sysconfig/atop ]; then
  lp=$(grep -E '^\s*LOGPATH=' /etc/sysconfig/atop | tail -n1 | cut -d= -f2- | tr -d '"' || true)
  [ -n "$lp" ] && LOGPATH="$lp"
fi

# sensible default
LOGPATH="${LOGPATH:-/var/log/atop}"

if [ -n "${F:-}" ]; then
  if [ -r "$F" ] && [ -f "$F" ]; then
    LOGS+=("$F")
  else
    say "Supplied file '$F' is not readable, skipping"
  fi
else
  # try to find atop files in LOGPATH
  if [ -d "$LOGPATH" ]; then
    say "Searching for atop logs in $LOGPATH"
    for f in "$LOGPATH"/atop_*; do
      [ -f "$f" ] || continue
      LOGS+=("$f")
    done
  else
    say "Log directory '$LOGPATH' not found, falling back to current directory"
    for f in atop_*; do
      [ -f "$f" ] || continue
      LOGS+=("$f")
    done
  fi
fi

missing=0
if [ "${#LOGS[@]}" -gt 0 ]; then
  say "Сбор RAW TOP-${TOPN} из atopsar для каждого файла (по дням)"
  for F in "${LOGS[@]}"; do
    DAY_LABEL="$(basename "$F" | sed -n 's/^atop_//p' || true)"
    [ -n "$DAY_LABEL" ] || DAY_LABEL="$(basename "$F")"
    say "Processing day: $DAY_LABEL (file: $F)"
    if [ "${FULL_DAY}" = "1" ] || [ "${FULL_DAY}" = "true" ]; then
      run with_locale atopsar -O -S -r "$F" | tee "${OUT_DIR}/RAW_TOP5_${DAY_LABEL}_CPU.txt" >/dev/null || true
      run with_locale atopsar -G -S -r "$F" | tee "${OUT_DIR}/RAW_TOP5_${DAY_LABEL}_MEM.txt" >/dev/null || true
      run with_locale atopsar -D -S -r "$F" | tee "${OUT_DIR}/RAW_TOP5_${DAY_LABEL}_DSK.txt" >/dev/null || true
      run with_locale atopsar -N -S -r "$F" | tee "${OUT_DIR}/RAW_TOP5_${DAY_LABEL}_NET.txt" >/dev/null || true
      run with_locale atopsar -A -r "$F" > "${OUT_DIR}/SYSTEM_${DAY_LABEL}_${WIN_LABEL:-ALL}.txt" || true
    else
      run with_locale atopsar -O -S -r "$F" -b "${B:-09:00}" -e "${E:-19:00}" | tee "${OUT_DIR}/RAW_TOP5_${DAY_LABEL}_CPU.txt" >/dev/null || true
      run with_locale atopsar -G -S -r "$F" -b "${B:-09:00}" -e "${E:-19:00}" | tee "${OUT_DIR}/RAW_TOP5_${DAY_LABEL}_MEM.txt" >/dev/null || true
      run with_locale atopsar -D -S -r "$F" -b "${B:-09:00}" -e "${E:-19:00}" | tee "${OUT_DIR}/RAW_TOP5_${DAY_LABEL}_DSK.txt" >/dev/null || true
      run with_locale atopsar -N -S -r "$F" -b "${B:-09:00}" -e "${E:-19:00}" | tee "${OUT_DIR}/RAW_TOP5_${DAY_LABEL}_NET.txt" >/dev/null || true
      run with_locale atopsar -A -r "$F" -b "${B:-09:00}" -e "${E:-19:00}" > "${OUT_DIR}/SYSTEM_${DAY_LABEL}_${WIN_LABEL:-WINDOW}.txt" || true
    fi
  done

  # concatenate per-day RAW files into combined "ALL" files for aggregation
  for m in CPU MEM DSK NET; do
    outall="${OUT_DIR}/RAW_TOP5_ALL_${m}.txt"
    rm -f "$outall" || true
  for f in "$OUT_DIR"/RAW_TOP5_*_"${m}".txt; do
      [ -f "$f" ] || continue
  sed -n '1,99999p' -- "$f" >> "$outall" 2>/dev/null || true
  echo >> "$outall"
    done
  done

  # basic existence check
  for f in CPU MEM DSK NET; do
    if ! [ -s "${OUT_DIR}/RAW_TOP5_ALL_${f}.txt" ]; then
      echo "WARN: combined RAW_TOP5_ALL_${f}.txt empty — no data for metric ${f}" >&2
      missing=1
    fi
  done
else
  echo "[WARN] atop log collection skipped." | tee -a "${OUT_DIR}/collection_warn.txt"
fi

# ===== 2) АГРЕГАЦИЯ: почасово и за день, ТОП-20 + CSV =====
say "Агрегация RAW -> почасовые и дневные ТОП-20 (cpu/mem/dsk/net)"
AWK_OUT="${OUT_DIR}/TOP20_ALL_${WIN_LABEL:-ALL}.txt"
HOURLY_CSV_PREFIX="${OUT_DIR}/HOURLY_ALL_${WIN_LABEL:-ALL}"
DAILY_CSV_PREFIX="${OUT_DIR}/DAILY_ALL_${WIN_LABEL:-ALL}"
# Only run aggregation if all combined RAW files are present and non-empty.
if [ -s "${OUT_DIR}/RAW_TOP5_ALL_CPU.txt" ] && [ -s "${OUT_DIR}/RAW_TOP5_ALL_MEM.txt" ] \
  && [ -s "${OUT_DIR}/RAW_TOP5_ALL_DSK.txt" ] && [ -s "${OUT_DIR}/RAW_TOP5_ALL_NET.txt" ]; then

  awk -v day="ALL" -v b="${B:-}" -v e="${E:-}" \
    -v report="$AWK_OUT" \
    -v hpre="$HOURLY_CSV_PREFIX" -v dpre="$DAILY_CSV_PREFIX" '
  function trim(s){sub(/^[ \t]+/,"",s);sub(/[ \t]+$/,"",s);return s}
  function add(metric, hh, cmd, v){ H[metric,hh,cmd]+=v; D[metric,cmd]+=v }

  # строка TOP-N: "HH:MM:SS  pid cmd... val | pid cmd... val | ..."
  function parse_line(metric, line,   hh,rest,n,i,rec,nt,k,pid,cmd,val,a,cols){
    if (line !~ /^[0-9]{2}:[0-9]{2}:[0-9]{2}/) return
    hh=substr(line,1,2); rest=substr(line,10)
    n=split(rest, cols, /\s+\|\s+/)
    for (i=1;i<=n;i++){
      rec=trim(cols[i]); nt=split(rec,a,/[ \t]+/); if (nt<3) continue
      pid=a[1]; val=a[nt]; cmd=""
      for (k=2;k<nt;k++) cmd=(cmd==""?a[k]:cmd" "a[k])
      gsub(/[%]/,"",val); gsub(/[^0-9.]/,"",val); if (val=="") val=0
      add(metric, hh, cmd, val+0)
    }
  }

  FILENAME ~ /RAW_TOP5_.*_CPU\.txt$/ { parse_line("cpu", $0); next }
  FILENAME ~ /RAW_TOP5_.*_MEM\.txt$/ { parse_line("mem", $0); next }
  FILENAME ~ /RAW_TOP5_.*_DSK\.txt$/ { parse_line("dsk", $0); next }
  FILENAME ~ /RAW_TOP5_.*_NET\.txt$/ { parse_line("net", $0); next }

  # сортированная печать map[cmd]=value в файл fn
  function print_top_to(map, N, fn,   arrC,arrV,i,j,n,tc,tv){
    n=0; for (k in map){ n++; arrC[n]=k; arrV[n]=map[k] }
    if (n==0){ print "(no data)" >> fn; print "" >> fn; close(fn); return }
    for (i=1;i<=n;i++) for (j=i+1;j<=n;j++) if (arrV[j]>arrV[i]){ tv=arrV[i]; arrV[i]=arrV[j]; arrV[j]=tv; tc=arrC[i]; arrC[i]=arrC[j]; arrC[j]=tc }
    print "rank,cmd,sum" >> fn
    for (i=1;i<=N && i<=n;i++) printf "%2d,%s,%.2f\n", i, arrC[i], arrV[i] >> fn
    print "" >> fn
    close(fn)
  }

  # выгрузка CSV для часа
  function dump_hour_csv(metric, hh,   map,fn,c,v,i,j,n,tc,tv) {
    split("",map)
    for (k in H){ split(k,p,SUBSEP); if (p[1]==metric && p[2]==hh) map[p[3]]=H[k] }
    fn=(hpre "_" metric "_hour" hh ".csv")
    printf "rank,cmd,sum\n" > fn
    n=0; for (k in map){ n++; c[n]=k; v[n]=map[k] }
    for (i=1;i<=n;i++) for (j=i+1;j<=n;j++) if (v[j]>v[i]){ tv=v[i]; v[i]=v[j]; v[j]=tv; tc=c[i]; c[i]=c[j]; c[j]=tc }
    for (i=1;i<=n && i<=20;i++) printf "%d,%s,%.2f\n", i, c[i], v[i] >> fn
    close(fn)
  }

  # выгрузка CSV для дня
  function dump_day_csv(metric,   map,fn,c,v,i,j,n,tc,tv) {
    split("",map)
    for (k in D){ split(k,p,SUBSEP); if (p[1]==metric) map[p[2]]=D[k] }
    fn=(dpre "_" metric ".csv")
    printf "rank,cmd,sum\n" > fn
    n=0; for (k in map){ n++; c[n]=k; v[n]=map[k] }
    for (i=1;i<=n;i++) for (j=i+1;j<=n;j++) if (v[j]>v[i]){ tv=v[i]; v[i]=v[j]; v[j]=tv; tc=c[i]; c[i]=c[j]; c[j]=tc }
    for (i=1;i<=n && i<=20;i++) printf "%d,%s,%.2f\n", i, c[i], v[i] >> fn
    close(fn)
  }

  END{
    # Заголовок отчёта
    printf("===== TOP-20 BY HOUR (%s %s-%s) =====\n", day, b, e) > report

    for (h=0; h<=23; h++){
      hh=sprintf("%02d",h)

      # CPU
      printf("### Metric: cpu, hour %s\n", hh) >> report
      split("",map); for (k in H){ split(k,p,SUBSEP); if (p[1]=="cpu"&&p[2]==hh) map[p[3]]=H[k] }
      print_top_to(map,20,report)
      dump_hour_csv("cpu",hh)

      # MEM
      printf("### Metric: mem, hour %s\n", hh) >> report
      split("",map); for (k in H){ split(k,p,SUBSEP); if (p[1]=="mem"&&p[2]==hh) map[p[3]]=H[k] }
      print_top_to(map,20,report)
      dump_hour_csv("mem",hh)

      # DSK
      printf("### Metric: dsk, hour %s\n", hh) >> report
      split("",map); for (k in H){ split(k,p,SUBSEP); if (p[1]=="dsk"&&p[2]==hh) map[p[3]]=H[k] }
      print_top_to(map,20,report)
      dump_hour_csv("dsk",hh)

      # NET
      printf("### Metric: net, hour %s\n", hh) >> report
      split("",map); for (k in H){ split(k,p,SUBSEP); if (p[1]=="net"&&p[2]==hh) map[p[3]]=H[k] }
      print_top_to(map,20,report)
      dump_hour_csv("net",hh)
    }

    # Дневные
    printf("===== TOP-20 BY DAY (%s %s-%s) =====\n", day, b, e) >> report

    printf("### Metric: cpu\n") >> report
    split("",map); for (k in D){ split(k,p,SUBSEP); if (p[1]=="cpu") map[p[2]]=D[k] }
    print_top_to(map,20,report); dump_day_csv("cpu")

    printf("### Metric: mem\n") >> report
    split("",map); for (k in D){ split(k,p,SUBSEP); if (p[1]=="mem") map[p[2]]=D[k] }
    print_top_to(map,20,report); dump_day_csv("mem")

    printf("### Metric: dsk\n") >> report
    split("",map); for (k in D){ split(k,p,SUBSEP); if (p[1]=="dsk") map[p[2]]=D[k] }
    print_top_to(map,20,report); dump_day_csv("dsk")

    printf("### Metric: net\n") >> report
    split("",map); for (k in D){ split(k,p,SUBSEP); if (p[1]=="net") map[p[2]]=D[k] }
    print_top_to(map,20,report); dump_day_csv("net")
  }
    ' "${OUT_DIR}/RAW_TOP5_ALL_CPU.txt" "${OUT_DIR}/RAW_TOP5_ALL_MEM.txt" "${OUT_DIR}/RAW_TOP5_ALL_DSK.txt" "${OUT_DIR}/RAW_TOP5_ALL_NET.txt"

else
  echo "WARN: combined RAW_TOP5_ALL_*.txt files missing or empty — skipping aggregation step." >&2
  echo "(Run the script with valid atop atopsar logs or set F to point to atop files.)" >&2
  missing=1
fi

# ===== 3) Полная системная сводка (для сверки) =====
# ===== DETAILED SUMMARY: top processes, percentiles, spikes =====
mkdir -p "${OUT_DIR}" || true
SUMMARY_FILE="${AUDIT_DIR}/atop_SUMMARY_DETAILED_${WIN_LABEL:-ALL}.txt"
{
  echo "Detailed atop summary"
  echo "Window: ${B:-} - ${E:-}"
  echo "Generated: $(date -u +%Y-%m-%dT%H:%M:%SZ)"
  echo
  # helper: percentile calculator using awk (simple sort)
  percentile() {
    awk -v p="$1" 'BEGIN{n=0} {a[++n]=$1} END{ if(n==0){print "NA"; exit} for(i=1;i<=n;i++) for(j=i+1;j<=n;j++) if(a[j]<a[i]){t=a[i];a[i]=a[j];a[j]=t} idx=int(n*p+0.5); if(idx<1) idx=1; if(idx>n) idx=n; print a[idx] }'
  }

  # thresholds (tweakable via env)
  CPU_THR=${CPU_THR:-80}
  MEM_THR=${MEM_THR:-80}
  DSK_THR=${DSK_THR:-80}
  NET_THR=${NET_THR:-100000} # units depend on atopsar output

  for metric in cpu mem dsk net; do
    echo "== Metric: ${metric} =="
    daily_csv="${DAILY_CSV_PREFIX}_${metric}.csv"
    echo "Top entries by total (daily aggregation):"
    if [ -f "$daily_csv" ]; then
      sed -n '2,11p' "$daily_csv" || true
    else
      echo "(no daily CSV for ${metric})"
    fi

    # collect hourly top sums
    vals_file="${OUT_DIR}/.vals_${metric}.txt"
    rm -f "$vals_file" || true
    for hf in "${HOURLY_CSV_PREFIX}_${metric}"_hour*.csv; do
      [ -f "$hf" ] || continue
      # take first data line (rank 1) sum value (3rd column)
      topline=$(sed -n '2p' "$hf" 2>/dev/null || true)
      if [ -n "$topline" ]; then
        sumv=$(echo "$topline" | awk -F, '{print $3+0}')
        echo "$sumv" >> "$vals_file"
      fi
    done

    if [ -f "$vals_file" ]; then
  p95=$(percentile 0.95 < "$vals_file")
  p99=$(percentile 0.99 < "$vals_file")
      echo "Top-1 hourly sum percentiles: 95% = $p95, 99% = $p99"

      # spike hours over threshold
      thr=${CPU_THR}
      [ "$metric" = "mem" ] && thr=${MEM_THR}
      [ "$metric" = "dsk" ] && thr=${DSK_THR}
      [ "$metric" = "net" ] && thr=${NET_THR}

      spikes_file="${OUT_DIR}/.spikes_${metric}.txt"
      rm -f "$spikes_file" || true
      for hf in "${HOURLY_CSV_PREFIX}_${metric}"_hour*.csv; do
        [ -f "$hf" ] || continue
        topl=$(sed -n '2p' "$hf" 2>/dev/null || true)
        if [ -n "$topl" ]; then
          sumv=$(echo "$topl" | awk -F, '{print $3+0}')
          if awk -v s="$sumv" -v t="$thr" 'BEGIN{if(s>t) exit 0; exit 1}'; then
            echo "${hf##*/}: $sumv" >> "$spikes_file"
          fi
        fi
      done

      if [ -s "$spikes_file" ]; then
        echo "Hours with top-1 > ${thr}:"
        sed -n '1,200p' "$spikes_file"
      else
        echo "No hourly spikes > ${thr} found for ${metric}."
      fi
      rm -f "$spikes_file"
    else
      echo "(no hourly data to compute percentiles for ${metric})"
    fi

    echo
  done

} > "$SUMMARY_FILE"

say "Detailed summary written to: $SUMMARY_FILE"

# ===== 3) Полная системная сводка (для сверки) =====
if [ "${#LOGS[@]}" -gt 0 ]; then
  # write per-day system files already created earlier; we still keep a consolidated note
  echo "System dumps available per day in $OUT_DIR (SYSTEM_*.txt)"
else
  echo "NOTE: skipped full atopsar system dump because no log was available" > "${OUT_DIR}/SYSTEM_${DAY_LABEL:-NA}_${WIN_LABEL:-ALL}.txt" || true
fi

# ===== 4) Архив =====
# By default keep a single archive per service under $AUDIT_DIR with no date suffix
FINAL_REPORT="${AUDIT_DIR}/atop_REPORT_${WIN_LABEL:-ALL}.txt"
{
  echo "ATOP AUDIT REPORT"
  echo "Window: ${B:-} - ${E:-}"
  echo "Generated: $(date -u +%Y-%m-%dT%H:%M:%SZ)"
  echo
  if [ -f "${AWK_OUT}" ]; then
    echo "===== TOP-20 AGGREGATED (ALL days) ====="
    sed -n '1,200p' "${AWK_OUT}" || true
    echo
  fi
  if [ -f "$SUMMARY_FILE" ]; then
    echo "===== DETAILED SUMMARY ====="
    sed -n '1,400p' "$SUMMARY_FILE" || true
    echo
  fi
  echo "Artifacts saved to: $OUT_DIR"
} > "$FINAL_REPORT"

say "Упаковка архива"
source "$(dirname -- "${BASH_SOURCE[0]:-$0}")/audit_common.sh"
ATOP_SUMMARY_COPY="$AUDIT_DIR/atop_summary.log"
if [ -f "$SUMMARY_FILE" ]; then sed -n '1,500p' "$SUMMARY_FILE"; else echo "(no detailed summary)"; fi | write_audit_summary "$ATOP_SUMMARY_COPY"

# Use centralized archive helper to create a single archive under $AUDIT_DIR
ARCHIVE_NAME="atop.tgz"
create_and_verify_archive "$OUT_DIR" "$ARCHIVE_NAME"

# ===== 5) Итоги =====
say "Готово"
# human-friendly listing without parsing ls output
find "$OUT_DIR" -maxdepth 1 -type f -printf "%M %s %p\n" | sed -n '1,200p' || true
if [ "${missing:-0}" -eq 1 ]; then
  echo "NOTE: часть RAW-файлов пустые — в выбранном окне метрика не собиралась/нет активности." >&2
fi

# --- Краткий итог в консоль (чтобы не открывать файлы вручную) ---
echo
echo "==== QUICK SUMMARY ===="
echo "Report: $FINAL_REPORT"
echo "Summary: $SUMMARY_FILE"
if [ -f "$SUMMARY_FILE" ]; then
  echo
  echo "-- Top of detailed summary --"
  sed -n '1,120p' "$SUMMARY_FILE"
  echo
  # show spike counts per metric (count lines with HOURLY_ entries)
  echo "-- Spike counts by metric (hours where top-1 exceeded threshold) --"
  for m in cpu mem dsk net; do
    cnt=$(grep -c "HOURLY_ALL_.*_${m}_hour" "$SUMMARY_FILE" 2>/dev/null || true)
    # if grep didn't find HOURLY entries, try count of 'Hours with' lines
    if [ "$cnt" -eq 0 ]; then
      cnt=$(grep -A3 "== Metric: ${m} ==" "$SUMMARY_FILE" 2>/dev/null | grep -c "HOURLY_ALL_" || true)
    fi
    echo "$m: $cnt"
  done
else
  echo "(no detailed summary found)"
fi

# list very small files (<1K) to help spot empty artifacts
echo
echo "-- Small files in $OUT_DIR (size < 1K) --"
find "$OUT_DIR" -maxdepth 1 -type f -size -1k -printf "%f (%s bytes)\n" | sed -n '1,200p' || true

echo "==== END SUMMARY ===="

# ===== 3) Полная системная сводка (для сверки) =====
# ===== DETAILED SUMMARY: top processes, percentiles, spikes =====
SUMMARY_FILE="${AUDIT_DIR}/atop_SUMMARY_DETAILED_${WIN_LABEL:-ALL}.txt"
{
  echo "Detailed atop summary"
  echo "Window: ${B:-} - ${E:-}"
  echo "Generated: $(date -u +%Y-%m-%dT%H:%M:%SZ)"
  echo
  # helper: percentile calculator using awk (simple sort)
  percentile() {
    awk -v p="$1" 'BEGIN{n=0} {a[++n]=$1} END{ if(n==0){print "NA"; exit} for(i=1;i<=n;i++) for(j=i+1;j<=n;j++) if(a[j]<a[i]){t=a[i];a[i]=a[j];a[j]=t} idx=int(n*p+0.5); if(idx<1) idx=1; if(idx>n) idx=n; print a[idx] }'
  }

  # thresholds (tweakable via env)
  CPU_THR=${CPU_THR:-80}
  MEM_THR=${MEM_THR:-80}
  DSK_THR=${DSK_THR:-80}
  NET_THR=${NET_THR:-100000} # units depend on atopsar output

  for metric in cpu mem dsk net; do
    echo "== Metric: ${metric} =="
    daily_csv="${DAILY_CSV_PREFIX}_${metric}.csv"
    echo "Top entries by total (daily aggregation):"
    if [ -f "$daily_csv" ]; then
      sed -n '2,11p' "$daily_csv" || true
    else
      echo "(no daily CSV for ${metric})"
    fi

    # collect hourly top sums
    vals_file="${OUT_DIR}/.vals_${metric}.txt"
    rm -f "$vals_file" || true
  for hf in "${HOURLY_CSV_PREFIX}_${metric}"_hour*.csv; do
      [ -f "$hf" ] || continue
      # take first data line (rank 1) sum value (3rd column)
      topline=$(sed -n '2p' "$hf" 2>/dev/null || true)
      if [ -n "$topline" ]; then
        sumv=$(echo "$topline" | awk -F, '{print $3+0}')
        echo "$sumv" >> "$vals_file"
      fi
    done

    if [ -f "$vals_file" ]; then
  p95=$(percentile 0.95 < "$vals_file")
  p99=$(percentile 0.99 < "$vals_file")
      echo "Top-1 hourly sum percentiles: 95% = $p95, 99% = $p99"

      # spike hours over threshold
      thr=${CPU_THR}
      [ "$metric" = "mem" ] && thr=${MEM_THR}
      [ "$metric" = "dsk" ] && thr=${DSK_THR}
      [ "$metric" = "net" ] && thr=${NET_THR}

      spikes_file="${OUT_DIR}/.spikes_${metric}.txt"
      rm -f "$spikes_file" || true
  for hf in "${HOURLY_CSV_PREFIX}_${metric}"_hour*.csv; do
        [ -f "$hf" ] || continue
        topl=$(sed -n '2p' "$hf" 2>/dev/null || true)
        if [ -n "$topl" ]; then
          sumv=$(echo "$topl" | awk -F, '{print $3+0}')
          if awk -v s="$sumv" -v t="$thr" 'BEGIN{if(s>t) exit 0; exit 1}'; then
            echo "${hf##*/}: $sumv" >> "$spikes_file"
          fi
        fi
      done

      if [ -s "$spikes_file" ]; then
        echo "Hours with top-1 > ${thr}:"
        sed -n '1,200p' "$spikes_file"
      else
        echo "No hourly spikes > ${thr} found for ${metric}."
      fi
      rm -f "$spikes_file"
    else
      echo "(no hourly data to compute percentiles for ${metric})"
    fi

    echo
  done

} > "$SUMMARY_FILE"

say "Detailed summary written to: $SUMMARY_FILE"

# ===== 3) Полная системная сводка (для сверки) =====
if [ "${#LOGS[@]}" -gt 0 ]; then
  # write per-day system files already created earlier; we still keep a consolidated note
  echo "System dumps available per day in $OUT_DIR (SYSTEM_*.txt)"
else
  echo "NOTE: skipped full atopsar system dump because no log was available" > "${OUT_DIR}/SYSTEM_${DAY_LABEL:-NA}_${WIN_LABEL:-ALL}.txt" || true
fi

# ===== 4) Архив =====
# By default keep a single archive per service under $HOME with no date suffix
ARCHIVE="${ARCHIVE:-${AUDIT_DIR:-${HOME}/audit}/atop.tgz}"
# Create a final human-readable report that includes TOP20 and the detailed summary
FINAL_REPORT="${AUDIT_DIR}/atop_REPORT_${WIN_LABEL:-ALL}.txt"
{
  echo "ATOP AUDIT REPORT"
  echo "Window: ${B:-} - ${E:-}"
  echo "Generated: $(date -u +%Y-%m-%dT%H:%M:%SZ)"
  echo
  if [ -f "${AWK_OUT}" ]; then
    echo "===== TOP-20 AGGREGATED (ALL days) ====="
    sed -n '1,200p' "${AWK_OUT}" || true
    echo
  fi
  if [ -f "$SUMMARY_FILE" ]; then
    echo "===== DETAILED SUMMARY ====="
    sed -n '1,400p' "$SUMMARY_FILE" || true
    echo
  fi
  echo "Artifacts saved to: $OUT_DIR"
} > "$FINAL_REPORT"

say "Упаковка архива"
# Use centralized archive helper from audit_common.sh
source "$(dirname -- "${BASH_SOURCE[0]:-$0}")/audit_common.sh"
ATOP_SUMMARY_COPY="$AUDIT_DIR/atop_summary.log"
if [ -f "$SUMMARY_FILE" ]; then sed -n '1,500p' "$SUMMARY_FILE"; else echo "(no detailed summary)"; fi | write_audit_summary "$ATOP_SUMMARY_COPY"

# ===== 5) Итоги (до архивирования) =====
say "Готово"
# human-friendly listing without parsing ls output
find "$OUT_DIR" -maxdepth 1 -type f -printf "%M %s %p\n" | sed -n '1,200p' || true
if [ "${missing:-0}" -eq 1 ]; then
  echo "NOTE: часть RAW-файлов пустые — в выбранном окне метрика не собиралась/нет активности." >&2
fi

# --- Краткий итог в консоль (чтобы не открывать файлы вручную) ---
echo
echo "==== QUICK SUMMARY ===="
echo "Report: $FINAL_REPORT"
echo "Summary: $SUMMARY_FILE"
if [ -f "$SUMMARY_FILE" ]; then
  echo
  echo "-- Top of detailed summary --"
  sed -n '1,120p' "$SUMMARY_FILE"
  echo
  # show spike counts per metric (count lines with HOURLY_ entries)
  echo "-- Spike counts by metric (hours where top-1 exceeded threshold) --"
  for m in cpu mem dsk net; do
    cnt=$(grep -c "HOURLY_ALL_.*_${m}_hour" "$SUMMARY_FILE" 2>/dev/null || true)
    # if grep didn't find HOURLY entries, try count of 'Hours with' lines
    if [ "$cnt" -eq 0 ]; then
      cnt=$(grep -A3 "== Metric: ${m} ==" "$SUMMARY_FILE" 2>/dev/null | grep -c "HOURLY_ALL_" || true)
    fi
    echo "$m: $cnt"
  done
else
  echo "(no detailed summary found)"
fi

# list very small files (<1K) to help spot empty artifacts
echo
echo "-- Small files in $OUT_DIR (size < 1K) --"
find "$OUT_DIR" -maxdepth 1 -type f -size -1k -printf "%f (%s bytes)\n" | sed -n '1,200p' || true

echo "==== END SUMMARY ===="

# ===== 6) Архивирование (после всех операций чтения) =====
create_and_verify_archive "$OUT_DIR" "atop.tgz"
