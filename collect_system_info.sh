#!/usr/bin/env bash
# Re-exec in a sterile env to avoid interactive profile/menu scripts being sourced by child shells.
# If _STERILE is not set and we are in an interactive shell or BASH_ENV is set, re-exec using a
# minimal env and `bash --noprofile --norc` so the script runs deterministically in automation.
if [ -z "${_STERILE:-}" ] && { [[ $- == *i* ]] || [ -n "${BASH_ENV:-}" ]; }; then
  exec env -i HOME=/root PATH=/usr/sbin:/usr/bin:/bin TERM=xterm-256color BASH_ENV= _STERILE=1 \
    bash --noprofile --norc "$0" "$@"
fi

set -u
set -o pipefail
umask 022

LOCALE="${LOCALE:-ru_RU.UTF-8}"
source "$(dirname -- "${BASH_SOURCE[0]:-$0}")/audit_common.sh"

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
    if locale_has "en_US.UTF-8"; then
      SCRIPT_LC_TIME="en_US.UTF-8"
    elif locale_has "en_US:en"; then
      SCRIPT_LC_TIME="en_US:en"
    else
      SCRIPT_LC_TIME=C
    fi
    if [[ "$SCRIPT_LANGUAGE" != "en_US.UTF-8" ]]; then
      if locale_has "en_US.UTF-8"; then
        NEW_SCRIPT_LANG="en_US.UTF-8"
      elif locale_has "en_US:en"; then
        NEW_SCRIPT_LANG="en_US:en"
      else
        NEW_SCRIPT_LANG="$SCRIPT_LANGUAGE"
      fi
      printf 'NOTICE: ru_RU.UTF-8 LC_TIME not available; will use LC_TIME=%s and LANGUAGE=%s for commands in this script only\n' \
        "$SCRIPT_LC_TIME" "$NEW_SCRIPT_LANG" >&2
      SCRIPT_LANGUAGE="$NEW_SCRIPT_LANG"
    else
      printf 'NOTICE: LC_TIME=%s will be used for commands in this script only\n' "$SCRIPT_LC_TIME" >&2
    fi
  fi

with_locale(){ LANGUAGE="$SCRIPT_LANGUAGE" LC_TIME="$SCRIPT_LC_TIME" "$@"; }

OUT="${OUT:-${HOME}/system.info}"
TMP="$(mktemp -p /tmp sysinfo.XXXXXX)" || { printf 'ERROR: mktemp failed\n' >&2; exit 2; }
if [ -z "${TMP:-}" ] || [ ! -e "$TMP" ]; then
  printf 'ERROR: mktemp failed to create temporary file\n' >&2
  exit 2
fi
trap 'rm -f -- "${TMP:-}"' EXIT INT TERM
OUT_DIR="${OUT_DIR:-${HOME}/system_info_audit}"
mkdir -p "$OUT_DIR"

# AUDIT_DIR is prepared by audit_common.sh

hdr(){ printf '==== %s ====\n' "$1"; }
w(){ tee -a "$TMP"; }

: > "$TMP"

# ========== БАЗОВОЕ ==========
{
  hdr "uname / дата / аптайм"
  uname -a
  date
  uptime
} | w

hdr "Загрузка (loadavg)" | w
sed -n '1p' -- /proc/loadavg 2>/dev/null | w

# ========== ЛИМИТЫ ==========
hdr "ulimit -a (лимиты текущего шелла)" | w
ulimit -a 2>/dev/null | w

hdr "/proc/$$/limits (лимиты текущего процесса)" | w
sed -n '1p' -- "/proc/$$/limits" 2>/dev/null | w

{
  hdr "/etc/security/limits.conf и limits.d/* (постоянные лимиты PAM)"
  if [ -r /etc/security/limits.conf ]; then
    echo "# /etc/security/limits.conf"
    sed -n '1,200p' /etc/security/limits.conf
  fi
  if [ -d /etc/security/limits.d ]; then
    for f in /etc/security/limits.d/*.conf; do
      [ -e "$f" ] || continue
      ss -lntH 2>/dev/null | awk '{printf "%-22s backlog=%s\n",$4,$2}' | grep -E ':(80|443|8888|6379|3306|22|889[3-5]|901[0-5])' || true
      echo "$f"
      sed -n '1,200p' "$f"
    done
  fi
} | w

{
  hdr "kernel.threads-max / pid_max (лимиты процессов/потоков)"
  sysctl kernel.threads-max 2>/dev/null
  sysctl kernel.pid_max 2>/dev/null
} | w

# ========== CGROUPS / SYSTEMD ==========
hdr "cgroups: текущий процесс" | w
sed -n '1p' -- "/proc/$$/cgroup" 2>/dev/null | w

{
  hdr "systemd-cgls (дерево cgroups)"
  if command -v systemd-cgls >/dev/null; then
    systemd-cgls --no-pager | sed -n '1,200p'
  else
    echo "systemd-cgls не найден"
  fi
} | w

{
  hdr "Ограничения unit-файлов (Memory*, CPU*, IO*)"
  if command -v systemctl >/dev/null; then
    echo "--- UNIT ---"
    systemctl show -p MemoryHigh -p MemoryMax -p TasksMax --no-pager
    for s in atop atopacct auditd chronyd crond dbus-broker getty@tty1 \
             google-guest-agent gssproxy httpd irqbalance mysqld \
             NetworkManager nginx oddjobd polkit push-server redis \
             rpc-gssd; do
      if systemctl is-enabled "$s" &>/dev/null || systemctl is-active "$s" &>/dev/null; then
        echo "--- $s.service ---"
        systemctl show "$s".service -p MemoryHigh -p MemoryMax -p TasksMax --no-pager
      fi
    done
  else
    echo "systemctl не найден"
  fi
} | w

# ========== CGROUP v2: СЧЁТЧИКИ ==========
{
  hdr "cgroup v2 текущие лимиты/использование"
  cg_path="$(awk -F: '/^0:/{print $3}' /proc/self/cgroup 2>/dev/null)"
  b="/sys/fs/cgroup${cg_path}"
  if [ -d "$b" ]; then
    for f in memory.current memory.max memory.high memory.swap.current memory.swap.max \
             cpu.max cpu.weight cpu.stat io.stat pids.current pids.max; do
      if [ -r "$b/$f" ]; then
        printf '%s: ' "$f"
        sed -n '1p' -- "$b/$f" 2>/dev/null | tr -d '\n' || true
        echo
      fi
    done
  else
    echo "cgroup v2 недоступен или путь не найден"
  fi
} | w

# ========== FD ==========
{
  hdr "fs.file-max (глобальный лимит) и file-nr (использование)"
  sysctl fs.file-max 2>/dev/null
  sed -n '1p' -- /proc/sys/fs/file-nr 2>/dev/null | w
} | w

{
  hdr "Топ процессов по числу открытых файлов (если есть lsof)"
  if command -v lsof >/dev/null 2>&1; then
    lsof -nP 2>/dev/null | awk 'NR>1{print $1" "$2}' | sort | uniq -c | sort -nr | head -n 20
  else
    echo "lsof не найден"
  fi
} | w

# ========== ПАМЯТЬ / VM ==========
hdr "/proc/meminfo" | w
sed -n '1,200p' "/proc/meminfo" | w

{
  hdr "vmstat -s (если установлен)"
  if command -v vmstat >/dev/null; then vmstat -s; else echo "vmstat не найден (sysstat)"; fi
} | w

{
  hdr "Настройки VM: swappiness / dirty_* / overcommit / max_map_count / NUMA"
  sysctl vm.swappiness 2>/dev/null
  sysctl vm.dirty_ratio 2>/dev/null
  sysctl vm.dirty_background_ratio 2>/dev/null
  sysctl vm.dirty_bytes 2>/dev/null
  sysctl vm.dirty_background_bytes 2>/dev/null
  sysctl vm.overcommit_memory 2>/dev/null
  sysctl vm.overcommit_ratio 2>/dev/null
  sysctl vm.max_map_count 2>/dev/null
  sysctl kernel.numa_balancing 2>/dev/null
  sysctl vm.zone_reclaim_mode 2>/dev/null
} | w

{
  hdr "HugePages и Transparent HugePages"
  for f in /sys/kernel/mm/transparent_hugepage/defrag \
           /sys/kernel/mm/transparent_hugepage/enabled \
           /sys/kernel/mm/transparent_hugepage/hpage_pmd_size \
           /sys/kernel/mm/transparent_hugepage/shmem_enabled \
           /sys/kernel/mm/transparent_hugepage/use_zero_page; do
  if [ -r "$f" ]; then printf '%s:' "$f"; sed -n '1p' -- "$f" 2>/dev/null | tr -d '\n' || true; echo; fi
  done
  [ -r /proc/sys/vm/nr_hugepages ] && { printf '%s:' "/proc/sys/vm/nr_hugepages"; sed -n '1p' -- /proc/sys/vm/nr_hugepages 2>/dev/null | tr -d '\n' || true; echo; }
  [ -r /proc/sys/vm/nr_overcommit_hugepages ] && { printf '%s:' "/proc/sys/vm/nr_overcommit_hugepages"; sed -n '1p' -- /proc/sys/vm/nr_overcommit_hugepages 2>/dev/null | tr -d '\n' || true; echo; }
} | w

# PSI
{
  hdr "Pressure Stall Information (PSI) cpu/memory/io"
  for f in /proc/pressure/cpu /proc/pressure/memory /proc/pressure/io; do
  if [ -r "$f" ]; then echo "== $f =="; sed -n '1p' -- "$f" 2>/dev/null | tr -d '\n' || true; echo; fi
  done
} | w

# ========== ДИСКИ / IO ==========
{
  hdr "Планировщик IO и параметры очереди (по всем блочным устройствам)"
  for b in /sys/block/*; do
    [ -e "$b/queue/scheduler" ] || continue
    dev=$(basename "$b")
    if [ -r "$b/queue/scheduler" ]; then
      sched="$(< "$b/queue/scheduler")"
    else
      sched=""
    fi
    if [ -r "$b/queue/nr_requests" ]; then
      rq="$(< "$b/queue/nr_requests")"
    else
      rq="?"
    fi
    if [ -r "$b/ro" ]; then
      ro="$(< "$b/ro")"
    else
      ro="?"
    fi
    echo "$dev | scheduler: $sched  | nr_requests: $rq | read-only: $ro"
  done
} | w

{
  hdr "AIO лимиты"
  sysctl fs.aio-max-nr 2>/dev/null
  [ -r /proc/sys/fs/aio-nr ] && { printf 'aio-nr: '; sed -n '1p' -- /proc/sys/fs/aio-nr 2>/dev/null | tr -d '\n' || true; echo; }
} | w

{
  hdr "Статистика IO (iostat -x 1 3, если есть)"
  if command -v iostat >/dev/null; then iostat -x 1 3; else echo "iostat не найден (sysstat)"; fi
} | w

# SMART
{
  hdr "SMART (smartctl -H, если есть)"
  if command -v smartctl >/dev/null; then
    for d in /dev/sd? /dev/vd? /dev/nvme?n?; do
      [ -b "$d" ] || continue
      echo "--- $d ---"
      smartctl -H "$d" 2>/dev/null | sed -n '1,80p' || true
    done
  else
    echo "smartctl не найден"
  fi
} | w

# ========== СЕТЬ ==========
{
  hdr "Очереди и буферы TCP/сокетов"
  sysctl net.core.somaxconn 2>/dev/null
  sysctl net.core.netdev_max_backlog 2>/dev/null
  sysctl net.core.rmem_max 2>/dev/null
  sysctl net.core.wmem_max 2>/dev/null
  sysctl net.ipv4.tcp_rmem 2>/dev/null
  sysctl net.ipv4.tcp_wmem 2>/dev/null
  sysctl net.ipv4.tcp_max_syn_backlog 2>/dev/null
  sysctl net.ipv4.ip_local_port_range 2>/dev/null
  sysctl net.ipv4.tcp_fin_timeout 2>/dev/null
  sysctl net.ipv4.tcp_tw_reuse 2>/dev/null
  sysctl net.ipv4.tcp_syncookies 2>/dev/null
} | w

{
  hdr "TCP стек: congestion_control / default_qdisc / keepalive / fastopen / timestamps / sack / window_scaling / mtu_probing / orphan* / ARP gc"
  sysctl net.ipv4.tcp_congestion_control 2>/dev/null
  sysctl net.core.default_qdisc 2>/dev/null
  sysctl net.ipv4.tcp_keepalive_time 2>/dev/null
  sysctl net.ipv4.tcp_keepalive_intvl 2>/dev/null
  sysctl net.ipv4.tcp_keepalive_probes 2>/dev/null
  sysctl net.ipv4.tcp_fastopen 2>/dev/null
  sysctl net.ipv4.tcp_timestamps 2>/dev/null
  sysctl net.ipv4.tcp_sack 2>/dev/null
  sysctl net.ipv4.tcp_window_scaling 2>/dev/null
  sysctl net.ipv4.tcp_mtu_probing 2>/dev/null
  sysctl net.ipv4.tcp_orphan_retries 2>/dev/null
  sysctl net.ipv4.tcp_max_orphans 2>/dev/null
  sysctl net.ipv4.neigh.default.gc_thresh1 2>/dev/null
  sysctl net.ipv4.neigh.default.gc_thresh2 2>/dev/null
  sysctl net.ipv4.neigh.default.gc_thresh3 2>/dev/null
} | w

# Conntrack
{
  hdr "Conntrack (если доступен)"
  [ -r /proc/sys/net/netfilter/nf_conntrack_max ]   && { printf 'nf_conntrack_max: ';   sed -n '1p' -- /proc/sys/net/netfilter/nf_conntrack_max 2>/dev/null | tr -d '\n' || true; echo; }
  [ -r /proc/sys/net/netfilter/nf_conntrack_count ] && { printf 'nf_conntrack_count: '; sed -n '1p' -- /proc/sys/net/netfilter/nf_conntrack_count 2>/dev/null | tr -d '\n' || true; echo; }
} | w

# Состояния TCP
{
  hdr "Состояния TCP (счётчики по ss)"
  if command -v ss >/dev/null; then
    ss -tan 2>/dev/null | awk 'NR>1{st[$1]++} END{for(k in st) printf "%-15s %d\n", k, st[k]}' | sort
  else
    echo "ss не найден"
  fi
} | w

# LISTEN backlog популярных портов
{
  hdr "Очереди LISTEN (оценка backlog популярных портов)"
  if command -v ss >/dev/null; then
  ss -lntH 2>/dev/null | awk '{printf "%-22s backlog=%s\n",$4,$2}' | grep -E ':(80|443|8888|6379|3306|22|889[3-5]|901[0-5])' || true
  else
    echo "ss не найден"
  fi
} | w

hdr "Сетевые ring-buffers (ethtool -g)" | w
if command -v ethtool >/dev/null; then
  ip -o link | awk -F': ' '{print $2}' | while IFS= read -r IF; do
    echo "--- $IF ---" | w
    ethtool -g "$IF" 2>/dev/null | w
  done
else
  echo "ethtool не найден" | w
fi

hdr "Сокеты в состоянии LISTEN (если есть ss)" | w
if command -v ss >/dev/null; then
  ss -lntp 2>/dev/null | sed -n '1,999p' | w
else
  echo "ss не найден" | w
fi

# softnet
{
  hdr "/proc/net/softnet_stat (ошибки на входе, drops)"
  sed -n '1,200p' /proc/net/softnet_stat 2>/dev/null || echo "нет /proc/net/softnet_stat"
} | w

# /proc/net/snmp и netstat -s
{
  hdr "Сетевые счётчики (/proc/net/snmp, netstat -s)"
  sed -n '1,200p' /proc/net/snmp 2>/dev/null || true
  if command -v netstat >/dev/null; then netstat -s 2>/dev/null | sed -n '1,200p'; fi
} | w

# RPS/XPS (с доп.проверками наличия файлов)
{
  hdr "RPS/XPS настройки по интерфейсам/очередям"
  for IF_PATH in /sys/class/net/*; do
    [ -e "$IF_PATH" ] || continue
    IF="$(basename "$IF_PATH")"
    qbase="/sys/class/net/$IF/queues"
    [ -d "$qbase" ] || continue
    for q in "$qbase"/rx-* "$qbase"/tx-*; do
      [ -d "$q" ] || continue
        for f in rps_cpus rps_flow_cnt xps_cpus; do
        p="$q/$f"
        if [ -e "$p" ] && [ -r "$p" ]; then
          printf '%s: ' "$p"
            sed -n '1,200p' -- "$p" 2>/dev/null || true
        fi
      done
    done
  done
} | w

# ========== CPU ==========
{
  hdr "/proc/cpuinfo (кратко)"
    grep -E -i 'processor|model name|cpu MHz|bogomips' /proc/cpuinfo | sed -n '1,80p'
} | w

{
  hdr "Приоритеты процессов (top 20 по CPU)"
  ps -eo pid,ppid,cmd,pri,ni,rtprio,%cpu --sort=-%cpu | sed -n '1,21p'
} | w

{
  hdr "CPU affinity (топ-10 по CPU)"
  ps -eo pid,%cpu,cmd --sort=-%cpu | awk 'NR>1{print $1}' | head -n 10 | while IFS= read -r P; do
    [ -r "/proc/$P/status" ] || continue
    ALLOWED="$(grep -i '^Cpus_allowed_list:' "/proc/$P/status" 2>/dev/null | awk '{print $2}')"
    echo "pid=$P cpus_allowed_list=${ALLOWED:-?}"
  done
} | w

# governor
{
  hdr "CPU frequency governor"
  for g in /sys/devices/system/cpu/cpu*/cpufreq/scaling_governor; do
  if [ -r "$g" ]; then printf '%s: ' "$g"; sed -n '1p' -- "$g" 2>/dev/null | tr -d '\n' || true; echo; fi
  done
} | w

# interrupts
{
  hdr "/proc/interrupts (top 40 строк)"
  sed -n '1,40p' /proc/interrupts 2>/dev/null
} | w

# Параметры планировщика ядра
{
  hdr "kernel.sched_* (настройки планировщика)"
  sysctl kernel.sched_latency_ns 2>/dev/null
  sysctl kernel.sched_min_granularity_ns 2>/dev/null
  sysctl kernel.sched_wakeup_granularity_ns 2>/dev/null
} | w

# ========== IPC ==========
{
  hdr "Общая память и семафоры (kernel.shm*, kernel.sem)"
  sysctl kernel.shmmax 2>/dev/null
  sysctl kernel.shmall 2>/dev/null
  sysctl kernel.shmmni 2>/dev/null
  sysctl kernel.sem 2>/dev/null
} | w

# ========== INOTIFY ==========
{
  hdr "Inotify лимиты"
  sysctl fs.inotify.max_user_watches 2>/dev/null
  sysctl fs.inotify.max_user_instances 2>/dev/null
  sysctl fs.inotify.max_queued_events 2>/dev/null
} | w

# ========== FS ==========
{
  hdr "Параметры монтирования (mount | findmnt)"
  if command -v findmnt >/dev/null; then
    findmnt -aro TARGET,SOURCE,FSTYPE,OPTIONS
  else
    mount
  fi
} | w

# ========== ETH TOOLS ==========
{
  hdr "ethtool -к (offloads) / -c (coalesce)"
  if command -v ethtool >/dev/null; then
    ip -o link | awk -F': ' '{print $2}' | while IFS= read -r IF; do
      echo "--- $IF (offload) ---"
      ethtool -k "$IF" 2>/dev/null | sed -n '1,200p' || true
      echo "--- $IF (coalesce) ---"
      ethtool -c "$IF" 2>/dev/null | sed -n '1,200p' || true
    done
  else
    echo "ethtool не найден"
  fi
} | w

# ========== SLAB / NUMA ==========
{
  hdr "slabtop (топ-объекты SLAB), если установлен"
  if command -v slabtop >/dev/null; then slabtop -o | sed -n '1,200p'; else echo "slabtop не найден (procps-ng)"; fi
} | w

{
  hdr "numactl/hwloc (NUMA топология), если есть"
  if command -v numactl >/dev/null; then numactl --hardware; else echo "numactl не найден"; fi
} | w

# ========== NTP / ЧАСЫ ==========
{
  hdr "Синхронизация времени (chrony/ntpstat)"
  if command -v chronyc >/dev/null; then
    chronyc tracking 2>/dev/null || true
    chronyc sources -v 2>/dev/null | sed -n '1,120p'
  elif command -v ntpq >/dev/null; then
    ntpq -pn 2>/dev/null || true
  elif command -v ntpstat >/dev/null; then
    ntpstat 2>/dev/null || true
  else
    echo "chronyc/ntpq/ntpstat не найдены"
  fi
} | w

# ========== ENTROPY ==========
{
  hdr "Доступная энтропия"
  if [ -r /proc/sys/kernel/random/entropy_avail ]; then
    # Read single-file content without spawning an extra process
  sed -n '1p' -- /proc/sys/kernel/random/entropy_avail 2>/dev/null | tr -d '\n' || true
    echo
  else
    echo "нет /proc/sys/kernel/random/entropy_avail"
  fi
} | w

# ========== ПЕРСИСТЕНТНЫЕ sysctl / GRUB / ENV ==========
{
  hdr "Персистентные sysctl (/etc/sysctl.conf, sysctl.d)"
  [ -r /etc/sysctl.conf ] && sed -n '1,200p' /etc/sysctl.conf
  if [ -d /etc/sysctl.d ]; then
    for f in /etc/sysctl.d/*.conf; do
      [ -r "$f" ] || continue
      echo "$f"
      sed -n '1,200p' "$f"
    done
  fi
} | w

{
  hdr "GRUB_CMDLINE_LINUX (ядро)"
  if [ -r /etc/default/grub ]; then
    grep -E -i '^GRUB_CMDLINE_LINUX' /etc/default/grub || true
  fi
  if [ -r /boot/grub2/grub.cfg ]; then
    sed -n '1,120p' /boot/grub2/grub.cfg 2>/dev/null | grep -E -i 'linux|kernel' || true
  elif compgen -G "/boot/efi/EFI/*/grub.cfg" >/dev/null; then
    sed -n '1,120p' /boot/efi/EFI/*/grub.cfg 2>/dev/null | grep -E -i 'linux|kernel' || true
  fi
} | w

{
  hdr "Environment (LIMITS/ULIMIT, если прокинуты через сервисы)"
  if command -v systemctl >/dev/null; then
    systemctl show --property=Environment --type=service --no-pager
  else
    echo "systemctl не найден"
  fi
} | w

# ========== DMSG / RATE LIMIT ==========
{
  hdr "Последние сообщения ядра (dmesg tail -200)"
  dmesg 2>/dev/null | tail -n 200
} | w

{
  hdr "dmesg ratelimit"
  sysctl kernel.printk_ratelimit 2>/dev/null
  sysctl kernel.printk_ratelimit_burst 2>/dev/null
} | w

# ========== SELINUX / APPARMOR ==========
{
  hdr "SELinux/AppArmor статус"
  if command -v getenforce >/dev/null; then
    echo "SELinux: $(getenforce)"
  elif [ -r /etc/selinux/config ]; then
    grep -E '^SELINUX=' /etc/selinux/config || true
  fi
  [ -r /sys/module/apparmor/parameters/enabled ] && { printf 'AppArmor: '; sed -n '1p' -- /sys/module/apparmor/parameters/enabled 2>/dev/null | tr -d '\n' || true; echo; }
} | w

# ========== ТОП-10 RSS - /proc/<pid>/limits ==========
{
  hdr "/proc/<pid>/limits для топ-10 по RSS"
  ps -eo pid,rss,cmd --sort=-rss | head -n 11 | tail -n +2 | while IFS= read -r P RSS CMD; do
    echo "--- pid=$P rss=${RSS} kB cmd=${CMD:0:80} ---"
    sed -n '1,200p' "/proc/$P/limits" 2>/dev/null || true
  done
} | w

# ========== DIAG menu.sh (read-only) ==========
{
  hdr "DIAG: источники автозапуска /root/menu.sh"
  echo "-- Проверка .bashrc/.bash_profile/.profile у root --"
  for f in /root/.bashrc /root/.bash_profile /root/.profile /root/.bash_login /root/.bash_logout; do
  [ -r "$f" ] && { echo ">>> $f"; grep -E -n 'menu\.sh|PROMPT_COMMAND|BASH_ENV|source|\. ' "$f" || true; }
  done
  echo
  echo "-- /etc/profile, /etc/bashrc, /etc/profile.d/*.sh --"
  for f in /etc/profile /etc/bashrc; do
  [ -r "$f" ] && { echo ">>> $f"; grep -E -n 'menu\.sh|PROMPT_COMMAND|BASH_ENV' "$f" || true; }
  done
  if [ -d /etc/profile.d ]; then
    for f in /etc/profile.d/*.sh; do
      [ -r "$f" ] || continue
          if grep -E -q 'menu\.sh|PROMPT_COMMAND|BASH_ENV' "$f"; then
  echo ">>> $f"; grep -E -n 'menu\.sh|PROMPT_COMMAND|BASH_ENV' "$f" || true
      fi
    done
  fi
  echo
  echo "-- SSH hooks / ForceCommand --"
  [ -r /etc/ssh/sshrc ]        && { echo ">>> /etc/ssh/sshrc";        grep -E -n 'menu\.sh' /etc/ssh/sshrc || true; }
  [ -r /root/.ssh/rc ]         && { echo ">>> /root/.ssh/rc";         grep -E -n 'menu\.sh' /root/.ssh/rc || true; }
  [ -r /etc/ssh/sshd_config ]  && { echo ">>> /etc/ssh/sshd_config";  grep -E -n 'ForceCommand|PermitUserEnvironment' /etc/ssh/sshd_config || true; }
  echo
  echo "-- MOTD / update-motd --"
  [ -r /etc/motd ] && { echo ">>> /etc/motd"; grep -E -n 'menu\.sh' /etc/motd || true; }
  for d in /etc/update-motd.d /etc/motd.d; do
    [ -d "$d" ] || continue
    for f in "$d"/*; do
      [ -r "$f" ] || continue
          if grep -E -q 'menu\.sh' "$f"; then echo ">>> $f"; grep -E -n 'menu\.sh' "$f" || true; fi
    done
  done
} | w

# ========== АВТО-SUMMARY ==========
{
  hdr "AUTO-SUMMARY (ключевые индикаторы)"
  ok(){ printf "[OK] %s\n" "$1"; }
  warn(){ printf "[WARN] %s\n" "$1"; }
  crit(){ printf "[CRIT] %s\n" "$1"; }

  # PSI avg10
  for sec in cpu memory io; do
    f="/proc/pressure/$sec"
    if [ -r "$f" ]; then
      v="$(awk '/^some /{for(i=1;i<=NF;i++) if($i~ /^avg10=/){split($i,a,"="); print a[2]}}' "$f")"
      if [ -n "$v" ]; then
        awk -v v="$v" -v s="$sec" 'BEGIN{
          if (v+0 >= 1.0) printf("[WARN] PSI %s some.avg10=%.2f (возможна задержка планировщика)\n", s, v);
          else printf("[OK] PSI %s some.avg10=%.2f\n", s, v);
        }'
      fi
    fi
  done

  # entropy
  if [ -r /proc/sys/kernel/random/entropy_avail ]; then
    E="$(sed -n '1p' /proc/sys/kernel/random/entropy_avail 2>/dev/null || echo)"
    if [ "${E:-0}" -lt 1000 ]; then warn "Низкая энтропия: $E"; else ok "Энтропия: $E"; fi
  fi

  # conntrack
  if [ -r /proc/sys/net/netfilter/nf_conntrack_max ] && [ -r /proc/sys/net/netfilter/nf_conntrack_count ]; then
  MX="$(sed -n '1p' /proc/sys/net/netfilter/nf_conntrack_max 2>/dev/null || echo)"
  CT="$(sed -n '1p' /proc/sys/net/netfilter/nf_conntrack_count 2>/dev/null || echo)"
    if [ "${MX:-0}" -gt 0 ]; then
      PCT=$(( 100 * CT / MX ))
      if [ "$PCT" -ge 80 ]; then warn "Conntrack заполнен: ${CT}/${MX} (${PCT}%)"; else ok "Conntrack: ${CT}/${MX} (${PCT}%)"; fi
    fi
  fi

  # softnet drops
  if [ -r /proc/net/softnet_stat ]; then
    DROPS="$(awk '{d=strtonum("0x"$3); if(d>0) c++} END{print c+0}' /proc/net/softnet_stat)"
    if [ "${DROPS:-0}" -gt 0 ]; then warn "softnet drops на $DROPS CPU"; else ok "softnet drops: 0"; fi
  fi

  # vm.swappiness
  SW="$(sysctl -n vm.swappiness 2>/dev/null || echo)"
  [ -n "$SW" ] && ok "vm.swappiness=$SW"

  # THP
  if [ -r /sys/kernel/mm/transparent_hugepage/enabled ]; then
  THP="$(sed -n '1p' /sys/kernel/mm/transparent_hugepage/enabled 2>/dev/null || echo)"
    echo "[OK] THP enabled: $THP"
  fi

  # tcp backlogs
  SOMAX="$(sysctl -n net.core.somaxconn 2>/dev/null || echo)"
  [ -n "$SOMAX" ] && ok "net.core.somaxconn=$SOMAX"

  # fd usage
    if [ -r /proc/sys/fs/file-nr ]; then
      read -r USED _ MAXF < /proc/sys/fs/file-nr
    if [ "${MAXF:-0}" -gt 0 ]; then
      PCT=$(( 100 * USED / MAXF ))
      if [ "$PCT" -ge 80 ]; then warn "FD занято: ${USED}/${MAXF} (${PCT}%)"; else ok "FD занято: ${USED}/${MAXF} (${PCT}%)"; fi
    fi
  fi
} | w

# ========== ФУТЕР ==========
hdr "Сбор завершен" | w

install -d -- "$(dirname -- "$OUT")"
mv -f -- "$TMP" "$OUT"
chmod 0644 -- "$OUT"

# Ensure the OUT_DIR contains the main output so it can be archived as a unit
mkdir -p "${OUT_DIR}"
cp -a -- "$OUT" "${OUT_DIR}/" 2>/dev/null || true

# Use common audit helper and write short summary (audit_common.sh already sourced at top)
SYS_SUMMARY_COPY="$AUDIT_DIR/system_info_summary.log"
sed -n '1,500p' "$OUT" 2>/dev/null | write_audit_summary "$SYS_SUMMARY_COPY"

echo "Saved to: $OUT"

# Also create an archive of the OUT_DIR (system_info files) into AUDIT_DIR
if [ -d "${OUT_DIR}" ]; then
  create_and_verify_archive "${OUT_DIR}" "system_info.tgz"
fi
