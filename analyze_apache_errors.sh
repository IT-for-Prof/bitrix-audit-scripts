#!/usr/bin/env bash
set -euo pipefail

# Version information
VERSION="2.1.0"

# Guard: detect accidental execution of editor-created temporary files ("Run Selection").
# If the file being executed doesn't contain expected markers from the full script,
# print a helpful message and exit. This prevents confusing errors like "OUT: command not found".
SELF_FILE="${BASH_SOURCE[0]:-$0}"
if [ -f "$SELF_FILE" ]; then
  # Look for a couple of distinctive strings that exist in the full script.
  if ! grep -qE 'Re-exec under a sterile environment|LC_TIME_WANTED|OUT_DIR=' "$SELF_FILE" 2>/dev/null; then
    cat >&2 <<'ERR'
ERROR: It appears you are running a temporary/selection file created by an editor (for example, VSCode "Run Selection").
This script should be run as the full file, not a small temporary fragment.

To run the full script, execute something like:
  bash "<path-to-script>" --days 1
Or run this file directly (replace <path-to-script> with the actual path shown below):

  "${SELF_FILE}"

If you intended to run a fragment, open the real file and run the whole script instead.
ERR
    exit 2
  fi
fi

# Re-exec under a sterile environment for automation to avoid sourcing
# user/system profiles (and accidentally running interactive menu.sh).
# If _STERILE is not set and we are in an interactive shell or BASH_ENV is set,
# re-exec using a minimal env and `bash --noprofile --norc` so the script runs
# deterministically in automation systems (cron, systemd, CI).
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

# Default period: last N days including today
DAYS=7

# Output directory: default to per-service folder under HOME unless OUT_DIR is set
OUT_DIR="${OUT_DIR:-${HOME}/apache_audit}"
mkdir -p "$OUT_DIR"
# Central audit dir for short summaries (do not move raw per-service OUT_DIR)
# Central audit dir + helpers
source "$(dirname -- "${BASH_SOURCE[0]:-$0}")/audit_common.sh"

# Setup locale using common functions
setup_locale

# Allow --days N and optional file globs as args
while [[ $# -gt 0 ]]; do
  case "$1" in
    --days|-d)
      shift; DAYS=${1:-$DAYS}; shift;;
    --help|-h)
      echo "Usage: $0 [--days N] [log-glob ...]"; exit 0;;
    *)
      # remaining args are treated as log globs
      break;;
  esac
done

# If user provided globs, use them; otherwise try to parse /etc/httpd configs
USER_GLOBS=("$@")
FILES=()
shopt -s nullglob
if [[ ${#USER_GLOBS[@]} -gt 0 ]]; then
    for g in "${USER_GLOBS[@]}"; do
      # allow glob expansion from user input (nullglob is set earlier)
      for f in $g; do FILES+=("$f"); done
    done
else
  # Try to find log file paths in /etc/httpd/*.conf and subdirs
  if [[ -d /etc/httpd ]]; then
    # Extract paths from CustomLog and ErrorLog directives
    mapfile -t cfgpaths < <(grep -R --include='*.conf' -h -E '^[[:space:]]*(CustomLog|ErrorLog)\b' /etc/httpd 2>/dev/null \
      | sed -E 's/^[[:space:]]*(CustomLog|ErrorLog)[[:space:]]+//I' \
      | awk '{print $1}' \
      | sed -E 's/^"|"$//g' \
      | sed -E 's/\%\{.*\}//g' \
      | sort -u)
    for p in "${cfgpaths[@]}"; do
      # If path is absolute, expand; otherwise try relative to /var/log/httpd
      if [[ "$p" = /* ]]; then
        for f in "$p"*; do
          [[ -e "$f" ]] && FILES+=("$f")
        done
      else
        for f in /var/log/httpd/"$p"*; do
          [[ -e "$f" ]] && FILES+=("$f")
        done
      fi
    done
  fi
fi

# Fallback to common globs if nothing found
if [[ ${#FILES[@]} -eq 0 ]]; then
  for f in /var/log/httpd/*access* /var/log/httpd/*error*; do
    [[ -e "$f" ]] && FILES+=("$f")
  done
fi

if [[ ${#FILES[@]} -eq 0 ]]; then
  echo "Нет читаемых логов Apache в /etc/httpd или по шаблонам /var/log/httpd/*access*" >&2
  exit 1
fi

# Optionally keep temp dir for debugging
KEEP_TEMP=0
for a in "$@"; do
  if [[ "$a" == "--keep-temp" ]]; then KEEP_TEMP=1; fi
done

# Prefer gawk if available, else fall back to awk
if command -v gawk >/dev/null 2>&1; then
  AWK_CMD="gawk"
elif command -v awk >/dev/null 2>&1; then
  AWK_CMD="awk"
else
  echo "ERROR: awk not found" >&2; exit 1
fi

# Build date window: from START to END (inclusive), format YYYYMMDD
END_DATE=$(date +%Y%m%d)
START_DATE=$(date -d "-$((DAYS-1)) days" +%Y%m%d)

# Create a filtered temporary file with only lines within the date window
TMPDIR=$(mktemp -d /tmp/apache_analyze.XXXXXX)
cleanup(){
  if [[ "$KEEP_TEMP" -eq 1 ]]; then
    echo "Keeping temp dir: $TMPDIR" >&2
  else
    rm -rf "$TMPDIR"
  fi
}
trap cleanup EXIT

# Single-pass: filter by date window once and tee the filtered stream to multiple workers
# Workers write temporary per-run files inside $TMPDIR; everything is removed on exit.
# filter AWK program (provided via here-doc when invoked) - keeps dates within window

# temp files for each report
ERR_CODES="$TMPDIR/err_codes"
TOP_URLS="$TMPDIR/top_urls"
TOP_UA="$TMPDIR/top_ua"
TOP_IP="$TMPDIR/top_ip"
PERDAY_RAW="$TMPDIR/perday_raw"

# Stream-filter once to a raw filtered log (original lines), then derive per-day TSV and top lists
FILTERED_RAW="$TMPDIR/filtered.log"
PERDAY_TSV="$TMPDIR/perday.tsv"

${AWK_CMD} -v start="$START_DATE" -v end="$END_DATE" -f <(cat <<'AWK'
function monthnum(m) {
    if (m=="Jan") return "01"; if (m=="Feb") return "02"; if (m=="Mar") return "03";
    if (m=="Apr") return "04"; if (m=="May") return "05"; if (m=="Jun") return "06";
    if (m=="Jul") return "07"; if (m=="Aug") return "08"; if (m=="Sep") return "09";
    if (m=="Oct") return "10"; if (m=="Nov") return "11"; if (m=="Dec") return "12";
    return "00";
}
{
  if (!match($0, /\[([0-9]{2})\/([A-Za-z]{3})\/([0-9]{4})/, t)) {
    print $0; next
  }
  d = t[3] monthnum(t[2]) t[1];
  if (d >= start && d <= end) print $0;
}
AWK
) <(zcat -f "${FILES[@]}" 2>/dev/null) >"$FILTERED_RAW"

# Build PERDAY_TSV with fields: day(YYYY-MM-DD) \t status \t url \t ua \t hour
${AWK_CMD} -f - "$FILTERED_RAW" >"$PERDAY_TSV" <<'AWK'
function monthnum(m) {
  if (m=="Jan") return "01"; if (m=="Feb") return "02"; if (m=="Mar") return "03";
  if (m=="Apr") return "04"; if (m=="May") return "05"; if (m=="Jun") return "06";
  if (m=="Jul") return "07"; if (m=="Aug") return "08"; if (m=="Sep") return "09";
  if (m=="Oct") return "10"; if (m=="Nov") return "11"; if (m=="Dec") return "12";
  return "00";
}
{
  day=""; hour="";
  if(match($0,/\[([0-9]{2})\/([A-Za-z]{3})\/([0-9]{4}):([0-9]{2}):[0-9]{2}:[0-9]{2}/,t)){
    dd=t[1]; mon=t[2]; yyyy=t[3]; hh=t[4]; day = yyyy "-" monthnum(mon) "-" dd; hour=hh
  }
  n=split($0,q,"\""); if(n<3) next; status=""; if(match(q[3],/^ ([0-9]{3}) /,m)) status=m[1]; else next;
  if(!(status~/^[45]/)) next;
  url=""; if(match(q[2],/^[A-Z]+ ([^ ]+)( HTTP\/[^ ]+)?$/,r)){ url=r[1]; sub(/\?.*$/,"",url) }
  ua=""; if(n>=6) ua=q[6]; if(ua=="") ua="-";
  if(day=="") day="(unknown)";
  print day "\t" status "\t" url "\t" ua "\t" hour
}
AWK

# Top files derived from the filtered raw log
$AWK_CMD -f - "$FILTERED_RAW" >"$ERR_CODES" <<'AWK'
{ n=split($0,q,"\""); if(n>=3 && match(q[3],/^ ([0-9]{3}) /,m) && m[1]~/^[45]/) print m[1] }
AWK

$AWK_CMD -f - "$FILTERED_RAW" >"$TOP_URLS" <<'AWK'
{ n=split($0,q,"\""); if(n>=3 && match(q[3],/^ ([0-9]{3}) /,m) && m[1]~/^[45]/ && match(q[2],/^[A-Z]+ ([^ ]+)( HTTP\/[^ ]+)?$/,r)){ u=r[1]; sub(/\?.*$/,"",u); print u }}
AWK

$AWK_CMD -f - "$FILTERED_RAW" >"$TOP_UA" <<'AWK'
{ n=split($0,q,"\""); if(n>=6 && match(q[3],/^ ([0-9]{3}) /,m) && m[1]~/^[45]/){ ua=q[6]; if(ua=="") ua="-"; print ua }}
AWK

$AWK_CMD -f - "$FILTERED_RAW" >"$TOP_IP" <<'AWK'
{ n=split($0,q,"\""); if(n>=3 && match(q[3],/^ ([0-9]{3}) /,m) && m[1]~/^[45]/){ if (match($0,/^[^ ]+/,I)) print I[0] }}
AWK

# Use FILTERED_RAW as the SRC for the rest of the script and PERDAY_TSV for per-day breakdown
PERDAY_RAW="$PERDAY_TSV"

# Single-pass per-day aggregation into small summary files (codes, urls, uas, hours)
PERDAY_CODES="$TMPDIR/perday_codes.tsv"
PERDAY_URLS="$TMPDIR/perday_urls.tsv"
PERDAY_UAS="$TMPDIR/perday_uas.tsv"
PERDAY_HOURS="$TMPDIR/perday_hours.tsv"

${AWK_CMD} -F"\t" -v codes="$PERDAY_CODES" -v urls="$PERDAY_URLS" -v uas="$PERDAY_UAS" -v hrs="$PERDAY_HOURS" -f - "$PERDAY_TSV" <<'AWK'
{
  day=$1; code=$2; url=$3; ua=$4; hour=$5;
  if(code!="") c[day SUBSEP code]++;
  if(url!="") u[day SUBSEP url]++;
  if(ua!="") a[day SUBSEP ua]++;
  if(hour!="") h[day SUBSEP hour]++;
}
END{
  for(k in c){ split(k,x,SUBSEP); printf "%s\t%s\t%d\n", x[1], x[2], c[k] > codes }
  for(k in u){ split(k,x,SUBSEP); printf "%s\t%s\t%d\n", x[1], x[2], u[k] > urls }
  for(k in a){ split(k,x,SUBSEP); gsub(/"/ , "\"\"", x[2]); printf "%s\t%s\t%d\n", x[1], x[2], a[k] > uas }
  for(k in h){ split(k,x,SUBSEP); printf "%s\t%s:00\t%d\n", x[1], x[2], h[k] > hrs }
}
AWK

# Sort per-day summary files by day then count desc for fast per-day lookup
PERDAY_CODES_SORT="$TMPDIR/perday_codes.sorted"
PERDAY_URLS_SORT="$TMPDIR/perday_urls.sorted"
PERDAY_UAS_SORT="$TMPDIR/perday_uas.sorted"
PERDAY_HOURS_SORT="$TMPDIR/perday_hours.sorted"

sort -t$'\t' -k1,1 -k3,3nr "$PERDAY_CODES" > "$PERDAY_CODES_SORT" 2>/dev/null || true
sort -t$'\t' -k1,1 -k3,3nr "$PERDAY_URLS" > "$PERDAY_URLS_SORT" 2>/dev/null || true
sort -t$'\t' -k1,1 -k3,3nr "$PERDAY_UAS" > "$PERDAY_UAS_SORT" 2>/dev/null || true
sort -t$'\t' -k1,1 -k3,3nr "$PERDAY_HOURS" > "$PERDAY_HOURS_SORT" 2>/dev/null || true

# Now produce human-readable per-day breakdown using the PERDAY_RAW file
echo -e "\n==== Per-day breakdown (last ${DAYS} days: ${START_DATE}..${END_DATE}) ===="
START_ISO=$(date -d "-$((DAYS-1)) days" '+%Y-%m-%d')
for i in $(seq 0 $((DAYS-1))); do
  DAY_ISO=$(date -d "$START_ISO +${i} days" '+%Y-%m-%d')
  echo -e "\n---- ${DAY_ISO} ----"

  echo "  Errors summary (HTTP 4xx/5xx):"
  $AWK_CMD -F"\t" -v day="$DAY_ISO" -f <(cat <<'AWK'
$1==day { print $2","$3 }
AWK
) "$PERDAY_CODES_SORT" | $AWK_CMD -F"," -f <(cat <<'AWK'
{print $2 " " $1}
AWK
) - | head -30 || true

  echo "  Top error URLs (no query):"
  $AWK_CMD -F"\t" -v day="$DAY_ISO" -f <(cat <<'AWK'
$1==day { print $2 }
AWK
) "$PERDAY_URLS_SORT" | head -20 || true

  echo "  Top User-Agents on errors:"
  $AWK_CMD -F"\t" -v day="$DAY_ISO" -f <(cat <<'AWK'
$1==day { print $2 }
AWK
) "$PERDAY_UAS_SORT" | head -20 || true

  echo "  Errors by hour:"
  $AWK_CMD -F"\t" -v day="$DAY_ISO" -f <(cat <<'AWK'
$1==day { print $2 }
AWK
) "$PERDAY_HOURS_SORT" | head -24 || true
done

# Use PERDAY_RAW and the other temp files as SRC-equivalents for the rest of the report
# Generate CSV aggregation (compact): only top N per category
CSV_OUT="$OUT_DIR/analyze_apache_agg.csv"
URL_TOP=50; UA_TOP=30; IP_TOP=30; DAY_URL_TOP=20
echo "metric,submetric,count,date,code" > "$CSV_OUT"


{
  # overall error codes
  sort "$ERR_CODES" | uniq -c | sort -rn | $AWK_CMD -f <(cat <<'AWK'
{printf "status_code,%s,%d,,\n", $2, $1}
AWK
) -

  # top URLs overall
  sort "$TOP_URLS" | uniq -c | sort -rn | head -n "$URL_TOP" | $AWK_CMD -f <(cat <<'AWK'
{cnt=$1; $1=""; sub(/^ /,""); printf "url,%s,%d,,\n", $0, cnt }
AWK
) -

  # top UAs (escape double-quotes, quote the UA field)
  sort "$TOP_UA" | uniq -c | sort -rn | head -n "$UA_TOP" | \
    $AWK_CMD -v q='"' -f <(cat <<'AWK'
{ cnt=$1; $1=""; sub(/^ /,""); ua=$0; gsub(q, q q, ua); printf "ua,\"%s\",%d,,\n", ua, cnt }
AWK
) -

  # top IPs
  sort "$TOP_IP" | uniq -c | sort -rn | head -n "$IP_TOP" | $AWK_CMD -f <(cat <<'AWK'
{printf "ip,%s,%d,,\n", $2, $1 }
AWK
) -

  # per-day top URLs (limited): produce lines day,url,count
  $AWK_CMD -F"\t" -f <(cat <<'AWK'
{ if($3!="") c[$1","$3]++ }
END { for(k in c) { split(k,a,","); print a[1]","a[2]","c[k] } }
AWK
) "$PERDAY_RAW" | \
    sort -t, -k3,3nr | head -n "$DAY_URL_TOP"
} >> "$CSV_OUT"

echo "CSV aggregation written to $CSV_OUT"

# For remaining sections, revert to on-the-fly processing from PERDAY_RAW and TOP_* files as needed

# Prepare SRC-like input (filtered combined logs are not stored persistently)
SRC=("$PERDAY_RAW")


echo "==== Errors summary (HTTP 4xx/5xx, top 30) ===="
awk -f <(cat <<'AWK'
{
  n=split($0,q,"\"");
  if (n<3) next;
  if (match(q[3], /^ ([0-9]{3}) /, m)) {
    code=m[1];
    if (code ~ /^[45]/) print code;
  }
}
AWK
) "${SRC[@]}" 2>/dev/null | sort | uniq -c | sort -nr | head -30 || true

echo -e "\n==== Top error URLs (no query, 4xx/5xx, top 50) ===="
awk -f <(cat <<'AWK'
{
  n=split($0,q,"\"");
  if (n<3) next;
  if (!match(q[3], /^ ([0-9]{3}) /, m)) next;
  code=m[1]; if (code !~ /^[45]/) next;
  if (match(q[2], /^[A-Z]+ ([^ ]+)( HTTP\/[0-9.]+)?$/, r)) {
    u=r[1]; sub(/\?.*$/, "", u); print u;
  }
}
AWK
) "${SRC[@]}" 2>/dev/null | sort | uniq -c | sort -nr | head -50 || true

echo -e "\n==== Top 20 error URLs (4xx/5xx total with breakdown) ===="
awk -f <(cat <<'AWK'
{
  # Разбор Apache combined
  n=split($0,q,"\"");
  if (n<3) next;

  # Код ответа
  if (!match(q[3], /^ ([0-9]{3}) /, m)) next;
  code=m[1]; if (code !~ /^[45]/) next;

  # URL без query
  if (!match(q[2], /^[A-Z]+ ([^ ]+)( HTTP\/[0-9.]+)?$/, r)) next;
  u=r[1]; sub(/\?.*$/,"",u);

  T[u]++; C[u,code]++;
}
END{
  # Печать: общее кол-во | URL | разбивка вида " 401=nn 404=mm 500=kk ..."
  for (u in T) {
    b="";
    for (k in C) {
      split(k,a,SUBSEP);
      if (a[1]==u) b=b " " a[2] "=" C[k];
    }
    printf "%6d %s |%s\n", T[u], u, b;
  }
}
AWK
) "${SRC[@]}" 2>/dev/null | sort -nr | head -20 || true

echo -e "\n==== Top-20 URLs per error code (4xx/5xx) ===="
awk -f <(cat <<'AWK'
{
  # Apache combined → делим по кавычкам
  n=split($0,q,"\"");
  if (n<3) next;

  # Код ответа
  if (!match(q[3], /^ ([0-9]{3}) /, m)) next;
  code=m[1];
  if (code !~ /^[45]/) next;

  # URL без query
  if (!match(q[2], /^[A-Z]+ ([^ ]+)( HTTP\/[0-9.]+)?$/, r)) next;
  u=r[1]; sub(/\?.*$/,"",u);

  # Выводим "code url" — дальше сгруппируем и отсортируем
  printf "%s %s\n", code, u;
}
AWK
) "${SRC[@]}" 2>/dev/null | sort \
| uniq -c \
| sort -k2,2 -k1,1nr \
| awk '
  BEGIN { curr=""; shown=0 }
  {
    cnt=$1; code=$2; url=$3;
    if (code!=curr) {
      if (curr!="") print "";            # пустая строка между кодами
      curr=code; shown=0;
    }
    if (shown<20) {
      printf "%6d %s\n", cnt, url;
      shown++;
    }
  }
' || true

echo -e "\n==== Error pairs (code -> URL, top 50) ===="
awk -f <(cat <<'AWK'
{
  n=split($0,q,"\"");
  if (n<3) next;
  if (!match(q[3], /^ ([0-9]{3}) /, m)) next;
  code=m[1]; if (code !~ /^[45]/) next;
  if (match(q[2], /^[A-Z]+ ([^ ]+)( HTTP\/[0-9.]+)?$/, r)) {
    u=r[1]; sub(/\?.*$/, "", u); printf "%s %s\n", code, u;
  }
}
AWK
) "${SRC[@]}" 2>/dev/null | sort | uniq -c | sort -nr | head -50 || true

echo -e "\n==== Top Referers on errors (top 30) ===="
$AWK_CMD -f <(cat <<'AWK'
{
  n=split($0,q,"\"");
  if (n<6) next;
  if (!match(q[3], /^ ([0-9]{3}) /, m)) next;
  code=m[1]; if (code !~ /^[45]/) next;
  ref=q[4]; if(ref==""||ref=="-") ref="(direct)"; print ref;
}
AWK
) "${SRC[@]}" 2>/dev/null | sort | uniq -c | sort -nr | head -30 || true

echo -e "\n==== Top User-Agents on errors (top 30) ===="
$AWK_CMD -f <(cat <<'AWK'
{
  n=split($0,q,"\"");
  if (n<6) next;
  if (!match(q[3], /^ ([0-9]{3}) /, m)) next;
  code=m[1]; if (code !~ /^[45]/) next;
  ua=q[6]; if(ua=="") ua="-"; print ua;
}
AWK
) "${SRC[@]}" | sort | uniq -c | sort -nr | head -30 || true

echo -e "\n==== Top client IPs on errors (top 30) ===="
$AWK_CMD -f <(cat <<'AWK'
{
  n=split($0,q,"\"");
  if (n<3) next;
  if (!match(q[3], /^ ([0-9]{3}) /, m)) next;
  code=m[1]; if (code !~ /^[45]/) next;
  if (match($0, /^[^ ]+/, ip)) print ip[0];
}
AWK
) "${SRC[@]}" | sort | uniq -c | sort -nr | head -30 || true

echo -e "\n==== Errors by hour (all days combined, top 24) ===="
$AWK_CMD -f <(cat <<'AWK'
{
  if (!(match($0, /\[([^:]+):([0-9]{2}):[0-9]{2}:[0-9]{2} /, t))) next;  # t[2]=HH
  n=split($0,q,"\"");
  if (n<3) next;
  if (!match(q[3], /^ ([0-9]{3}) /, m)) next;
  code=m[1]; if (code !~ /^[45]/) next;
  print t[2]":00";
}
AWK
) "${SRC[@]}" 2>/dev/null | sort | uniq -c | sort -nr | head -24 || true

echo -e "\n==== 401 by URL (first/last) ===="
$AWK_CMD -f <(cat <<'AWK'
function upd(k,dt){ if(!(k in f)||dt<f[k])f[k]=dt; if(!(k in l)||dt>l[k])l[k]=dt }
{
  if (!match($0, /\[([^\]]+)\]/, T)) next;  # T[1]=DD/Mon/YYYY:HH:MM:SS +ZZZZ
  dt=T[1];
  n=split($0,q,"\"");
  if (n<3) next;
  if (!match(q[3], /^ (401) /, m)) next;
  if (!match(q[2], /^[A-Z]+ ([^ ]+)( HTTP\/[0-9.]+)?$/, r)) next;
  u=r[1]; sub(/\?.*$/,"",u); k="401 "u; c[k]++; upd(k,dt);
}
END{
  for (k in c) printf "%s | %6d | first=%s | last=%s\n", k, c[k], f[k], l[k]
}
AWK
) "${SRC[@]}" 2>/dev/null | sort -t'|' -k2,2nr | head -50 || true

echo -e "\n==== Status mix by URL (top 80) ===="
$AWK_CMD -f <(cat <<'AWK'
{
  n=split($0,q,"\"");
  if (n<3) next;
  if (!match(q[3], /^ ([0-9]{3}) /, m)) next;
  code=m[1];
  if (!match(q[2], /^[A-Z]+ ([^ ]+)( HTTP\/[0-9.]+)?$/, r)) next;
  u=r[1]; sub(/\?.*$/,"",u);
  k=u " "code; c[k]++;
}
END{
  for (k in c) {
    split(k,a," ");
    st=a[length(a)];
    $0=k; sub(" [^ ]+$",""); url=$0;
    printf "%6d %s %s\n", c[k], url, st;
  }
}
AWK
) "${SRC[@]}" 2>/dev/null | sort -nr | head -80 || true

echo -e "\n==== 5xx by URL (count + first/last) ===="
$AWK_CMD -f <(cat <<'AWK'
function upd(k,dt){ if(!(k in f)||dt<f[k])f[k]=dt; if(!(k in l)||dt>l[k])l[k]=dt }
{
  # Вытаскиваем timestamp из [DD/Mon/YYYY:HH:MM:SS +ZZZZ]
  if (!match($0, /\[([^\]]+)\]/, T)) next; dt=T[1];

  # Разбор по кавычкам (Apache combined)
  n=split($0,q,"\"");
  if (n<3) next;

  # Код ответа
  if (!match(q[3], /^ ([0-9]{3}) /, m)) next;
  code=m[1]; if (code !~ /^5/) next;

  # URL без query
  if (!match(q[2], /^[A-Z]+ ([^ ]+)( HTTP\/[0-9.]+)?$/, r)) next;
  u=r[1]; sub(/\?.*$/, "", u);

  k=code" "u; c[k]++; upd(k,dt);
}
END{
  for (k in c) printf "%s | %6d | first=%s | last=%s\n", k, c[k], f[k], l[k]
}
AWK
) "${SRC[@]}" 2>/dev/null | sort -t'|' -k2,2nr -k1,1 | head -50 || true

echo -e "\n==== 5xx events (timestamp | code | url | ip | ref | ua) ===="
$AWK_CMD -f <(cat <<'AWK'
{
  # timestamp
  if (!match($0, /\[([^\]]+)\]/, T)) next; ts=T[1];

  # split by quotes
  n=split($0,q,"\"");
  if (n<6) next;

  # status
  if (!match(q[3], /^ ([0-9]{3}) /, m)) next;
  code=m[1]; if (code !~ /^5/) next;

  # url
  if (!match(q[2], /^[A-Z]+ ([^ ]+)( HTTP\/[0-9.]+)?$/, r)) next;
  url=r[1]; sub(/\?.*$/, "", url);

  # ip, referer, ua
  ip="-" ; if (match($0, /^[^ ]+/, I)) ip=I[0];
  ref=q[4]; if (ref==""||ref=="-") ref="(direct)";
  ua=q[6]; if (ua=="") ua="-";

  printf "%s | %s | %s | ip=%s | ref=%s | ua=%s\n", ts, code, url, ip, ref, ua;
}
AWK
) "${SRC[@]}" 2>/dev/null | sort | head -200 || true


# Write a short summary copy into the central AUDIT_DIR for quick inspection
# Include top error codes and top URLs (the temp files exist until script exit)
SUMMARY_COPY="$AUDIT_DIR/apache_analyze_summary.log"
{
  echo "Apache analyze summary - $(date -u +%Y-%m-%dT%H:%M:%SZ)"
  echo "CSV aggregation: $CSV_OUT"
  echo
  echo "Top error codes (count code):"
  if [[ -f "$ERR_CODES" ]]; then
    sort "$ERR_CODES" | uniq -c | sort -nr | head -n 30
  else
    echo "(no ERR_CODES file)"
  fi
  echo
  echo "Top error URLs (count url):"
  if [[ -f "$TOP_URLS" ]]; then
    sort "$TOP_URLS" | uniq -c | sort -nr | head -n 50
  else
    echo "(no TOP_URLS file)"
  fi
  echo
  echo "Per-day top URLs (sample):"
  if [[ -f "$PERDAY_URLS_SORT" ]]; then
    awk -F"\t" '{print $1 "\t" $2 "\t" $3}' "$PERDAY_URLS_SORT" | head -n 60
  else
    echo "(no per-day urls)"
  fi
} > "$SUMMARY_COPY"
printf 'NOTICE: wrote short summary to %s\n' "$SUMMARY_COPY" >&2

