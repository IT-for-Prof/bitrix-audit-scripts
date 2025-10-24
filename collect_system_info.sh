#!/usr/bin/env bash
# Re-exec in a sterile env to avoid interactive profile/menu scripts being sourced by child shells.
# If _STERILE is not set and we are in an interactive shell or BASH_ENV is set, re-exec using a
# minimal env and `bash --noprofile --norc` so the script runs deterministically in automation.
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

set -u
set -o pipefail
umask 022

LOCALE="${LOCALE:-ru_RU.UTF-8}"
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

# ========== EOL DATABASE ==========
# Local EOL database for supported distributions
declare -A EOL_DATABASE
# Ubuntu LTS
EOL_DATABASE["ubuntu-16.04"]="2021-04-30|EOL|Standard support ended"
EOL_DATABASE["ubuntu-18.04"]="2028-04-21|LTS|Long Term Support"
EOL_DATABASE["ubuntu-20.04"]="2030-04-21|LTS|Long Term Support"
EOL_DATABASE["ubuntu-22.04"]="2032-04-21|LTS|Long Term Support"
EOL_DATABASE["ubuntu-24.04"]="2034-04-21|LTS|Long Term Support"
# Debian
EOL_DATABASE["debian-10"]="2024-06-30|EOL|Standard support ended"
EOL_DATABASE["debian-11"]="2026-06-30|Standard|Standard support"
EOL_DATABASE["debian-12"]="2028-06-30|Standard|Standard support"
# CentOS
EOL_DATABASE["centos-7"]="2024-06-30|EOL|Standard support ended"
EOL_DATABASE["centos-8"]="2021-12-31|EOL|Standard support ended"
# RHEL
EOL_DATABASE["rhel-7"]="2024-06-30|Standard|Standard support (Extended until 2028)"
EOL_DATABASE["rhel-8"]="2029-05-31|Standard|Standard support"
EOL_DATABASE["rhel-9"]="2032-05-31|Standard|Standard support"
# AlmaLinux
EOL_DATABASE["almalinux-8"]="2029-03-31|Standard|Standard support"
EOL_DATABASE["almalinux-9"]="2032-05-31|Standard|Standard support"
# Rocky Linux
EOL_DATABASE["rocky-8"]="2029-05-31|Standard|Standard support"
EOL_DATABASE["rocky-9"]="2032-05-31|Standard|Standard support"
# Fedora (6-month lifecycle)
EOL_DATABASE["fedora-37"]="2023-11-14|EOL|Standard support ended"
EOL_DATABASE["fedora-38"]="2024-05-14|EOL|Standard support ended"
EOL_DATABASE["fedora-39"]="2024-11-12|EOL|Standard support ended"
EOL_DATABASE["fedora-40"]="2025-05-13|Standard|Standard support"
EOL_DATABASE["fedora-41"]="2025-11-11|Standard|Standard support"

# ========== OS DETECTION FUNCTIONS ==========

# Detect OS distribution and version
detect_os_distribution() {
    local distro_id=""
    local distro_version=""
    local distro_codename=""
    local distro_name=""
    
    if [ -f /etc/os-release ]; then
        distro_id=$(grep "^ID=" /etc/os-release | cut -d= -f2 | tr -d '"')
        distro_version=$(grep "^VERSION_ID=" /etc/os-release | cut -d= -f2 | tr -d '"')
        distro_codename=$(grep "^VERSION_CODENAME=" /etc/os-release | cut -d= -f2 | tr -d '"')
        distro_name=$(grep "^PRETTY_NAME=" /etc/os-release | cut -d= -f2 | tr -d '"')
    fi
    
    # Normalize distribution names
    case "$distro_id" in
        "almalinux")
            distro_id="almalinux"
            ;;
        "rocky")
            distro_id="rocky"
            ;;
        "centos")
            distro_id="centos"
            ;;
        "rhel")
            distro_id="rhel"
            ;;
        "fedora")
            distro_id="fedora"
            ;;
        "ubuntu")
            distro_id="ubuntu"
            ;;
        "debian")
            distro_id="debian"
            ;;
    esac
    
    # Export for use in other functions
    export OS_DISTRO_ID="$distro_id"
    export OS_DISTRO_VERSION="$distro_version"
    export OS_DISTRO_CODENAME="$distro_codename"
    export OS_DISTRO_NAME="$distro_name"
    
    echo "$distro_id|$distro_version|$distro_codename|$distro_name"
}

# Parse OS version for EOL lookup
parse_os_version() {
    local distro_id="$1"
    local version="$2"
    
    # Extract major version for lookup
    local major_version
    major_version=$(echo "$version" | cut -d. -f1)
    
    # Handle special cases
    case "$distro_id" in
        "ubuntu")
            # Ubuntu versions like 22.04, 20.04
            if [[ "$version" =~ ^[0-9]+\.[0-9]+$ ]]; then
                echo "$distro_id-$version"
            else
                echo "$distro_id-$major_version"
            fi
            ;;
        "debian"|"centos"|"rhel"|"almalinux"|"rocky"|"fedora")
            echo "$distro_id-$major_version"
            ;;
        *)
            echo "$distro_id-$major_version"
            ;;
    esac
}

# Check EOL status via API endoflife.date
check_eol_status_api() {
    local distro_id="$1"
    local version="$2"
    local api_url="https://endoflife.date/api/$distro_id/$version.json"
    
    if ! command -v curl >/dev/null 2>&1 && ! command -v wget >/dev/null 2>&1; then
        return 1
    fi
    
    local response
    if command -v curl >/dev/null 2>&1; then
        response=$(curl -s --connect-timeout 10 --max-time 30 "$api_url" 2>/dev/null)
    elif command -v wget >/dev/null 2>&1; then
        response=$(wget -qO- --timeout=30 "$api_url" 2>/dev/null)
    fi
    
    if [ -n "$response" ] && echo "$response" | grep -q "eol"; then
        echo "$response"
        return 0
    fi
    
    return 1
}

# Check EOL status using local database
check_eol_status_local() {
    local lookup_key="$1"
    
    if [ -n "${EOL_DATABASE[$lookup_key]:-}" ]; then
        echo "${EOL_DATABASE[$lookup_key]}"
        return 0
    fi
    
    return 1
}

# Analyze OS EOL status and provide recommendations
analyze_os_eol() {
    local os_info
    os_info=$(detect_os_distribution)
    
    local distro_id
    local distro_version
    local distro_codename
    local distro_name
    
    IFS='|' read -r distro_id distro_version distro_codename distro_name <<< "$os_info"
    
    if [ -z "$distro_id" ] || [ -z "$distro_version" ]; then
        echo "Не удалось определить дистрибутив операционной системы"
        return 1
    fi
    
    local lookup_key
    lookup_key=$(parse_os_version "$distro_id" "$distro_version")
    
    local eol_data=""
    local eol_source=""
    
    # Try API first
    if check_eol_status_api "$distro_id" "$distro_version"; then
        eol_data=$(check_eol_status_api "$distro_id" "$distro_version")
        eol_source="API endoflife.date"
    # Fallback to local database
    elif check_eol_status_local "$lookup_key"; then
        eol_data=$(check_eol_status_local "$lookup_key")
        eol_source="локальная база данных"
    fi
    
    # Output OS information
    echo "==== Информация об операционной системе ===="
    echo "Дистрибутив: $distro_name"
    echo "Версия: $distro_version"
    if [ -n "$distro_codename" ]; then
        echo "Кодовое имя: $distro_codename"
    fi
    echo "Версия ядра: $(uname -r)"
    echo "Архитектура: $(uname -m)"
    echo ""
    
    echo "==== Статус поддержки (End of Life) ===="
    
    if [ -n "$eol_data" ]; then
        local eol_date=""
        local support_type=""
        local description=""
        
        if [ "$eol_source" = "API endoflife.date" ]; then
            # Parse JSON response (simplified)
            eol_date=$(echo "$eol_data" | grep -o '"eol":"[^"]*"' | cut -d'"' -f4)
            support_type="API"
            description="Данные получены через API"
        else
            # Parse local database format: "date|type|description"
            IFS='|' read -r eol_date support_type description <<< "$eol_data"
        fi
        
        if [ -n "$eol_date" ]; then
            echo "Тип поддержки: $support_type"
            echo "Поддержка до: $eol_date"
            echo "Описание: $description"
            echo ""
            echo "Источник данных: $eol_source (дата проверки: $(date +%Y-%m-%d))"
            echo ""
            
            # Calculate days until EOL
            local current_date
            local eol_timestamp
            local current_timestamp
            local days_until_eol
            
            current_date=$(date +%Y-%m-%d)
            eol_timestamp=$(date -d "$eol_date" +%s 2>/dev/null || echo "0")
            current_timestamp=$(date -d "$current_date" +%s 2>/dev/null || echo "0")
            
            if [ "$eol_timestamp" -gt 0 ] && [ "$current_timestamp" -gt 0 ]; then
                days_until_eol=$(( (eol_timestamp - current_timestamp) / 86400 ))
                
                if [ "$days_until_eol" -lt 0 ]; then
                    echo "[CRIT] Операционная система достигла End of Life! ($((-days_until_eol)) дней назад)"
                    echo ""
                    echo "КРИТИЧЕСКИЕ РЕКОМЕНДАЦИИ:"
                    echo "  • Немедленно обновите операционную систему"
                    echo "  • Рассмотрите миграцию на поддерживаемую версию"
                    echo "  • Усильте мониторинг безопасности"
                    echo "  • Ограничьте сетевой доступ к серверу"
                elif [ "$days_until_eol" -lt 90 ]; then
                    echo "[WARN] Операционная система скоро достигнет End of Life ($days_until_eol дней)"
                    echo ""
                    echo "РЕКОМЕНДАЦИИ:"
                    echo "  • Запланируйте обновление операционной системы"
                    echo "  • Подготовьте план миграции"
                    echo "  • Усильте мониторинг безопасности"
                elif [ "$days_until_eol" -lt 365 ]; then
                    echo "[INFO] Операционная система в активной поддержке ($days_until_eol дней до EOL)"
                    echo ""
                    echo "РЕКОМЕНДАЦИИ:"
                    echo "  • Запланируйте обновление в течение года"
                    echo "  • Следите за обновлениями безопасности"
                else
                    echo "[OK] Операционная система находится в активной поддержке ($days_until_eol дней до EOL)"
                fi
            else
                echo "[INFO] Операционная система находится в активной поддержке"
            fi
        else
            echo "[INFO] Информация о EOL недоступна"
        fi
    else
        echo "[WARN] Не удалось получить информацию о статусе поддержки"
        echo "Дистрибутив: $distro_id $distro_version не найден в базе данных"
        echo ""
        echo "РЕКОМЕНДАЦИИ:"
        echo "  • Проверьте актуальность информации о поддержке дистрибутива"
        echo "  • Рассмотрите обновление до поддерживаемой версии"
    fi
    
    echo ""
}

# ========== VULNERABILITY ANALYSIS FUNCTIONS ==========

# Check vulnerable packages for Debian/Ubuntu
check_vulnerable_packages_apt() {
    local vulnerable_packages=()
    local critical_count=0
    local high_count=0
    local medium_count=0
    local low_count=0
    
    echo "Метод проверки: apt (native)"
    
    # Get upgradable packages
    if command -v apt >/dev/null 2>&1; then
        local upgradable
        upgradable=$(apt list --upgradable 2>/dev/null | grep -v "Listing..." | tail -n +2)
        
        if [ -n "$upgradable" ]; then
            echo "Найдены пакеты с доступными обновлениями:"
            echo "$upgradable" | while IFS= read -r line; do
                if [ -n "$line" ]; then
                    local package_name
                    local current_version
                    local available_version
                    
                    package_name=$(echo "$line" | cut -d'/' -f1)
                    current_version=$(echo "$line" | awk '{print $2}' | cut -d' ' -f1)
                    available_version=$(echo "$line" | awk '{print $3}')
                    
                    # Check if it's a security update (simplified)
                    if echo "$line" | grep -qi "security\|cve"; then
                        echo "  - $package_name ($current_version -> $available_version) [SECURITY]"
                        critical_count=$((critical_count + 1))
                    else
                        echo "  - $package_name ($current_version -> $available_version)"
                        medium_count=$((medium_count + 1))
                    fi
                fi
            done
        else
            echo "Все пакеты актуальны"
        fi
    else
        echo "apt не найден"
        return 1
    fi
    
    # Try debsecan if available
    if command -v debsecan >/dev/null 2>&1; then
        echo ""
        echo "Дополнительная проверка через debsecan:"
        local debsecan_output
        debsecan_output=$(debsecan --format=text 2>/dev/null | head -n 20)
        
        if [ -n "$debsecan_output" ]; then
            echo "$debsecan_output"
        else
            echo "debsecan не обнаружил известных уязвимостей"
        fi
    fi
    
    echo ""
    echo "Статистика:"
    echo "  Critical: $critical_count пакетов"
    echo "  High: $high_count пакетов"
    echo "  Medium: $medium_count пакетов"
    echo "  Low: $low_count пакетов"
}

# Check vulnerable packages for RHEL-family
check_vulnerable_packages_yum() {
    local vulnerable_packages=()
    local critical_count=0
    local high_count=0
    local medium_count=0
    local low_count=0
    
    echo "Метод проверки: dnf/yum (native)"
    
    # Try dnf first, then yum
    local package_manager=""
    if command -v dnf >/dev/null 2>&1; then
        package_manager="dnf"
    elif command -v yum >/dev/null 2>&1; then
        package_manager="yum"
    else
        echo "dnf/yum не найден"
        return 1
    fi
    
    # Check for security updates
    local security_updates
    if [ "$package_manager" = "dnf" ]; then
        security_updates=$(dnf updateinfo list security 2>/dev/null | grep -E "^(Critical|Important|Moderate|Low)" | head -n 20)
    else
        security_updates=$(yum updateinfo list security 2>/dev/null | grep -E "^(Critical|Important|Moderate|Low)" | head -n 20)
    fi
    
    if [ -n "$security_updates" ]; then
        echo "Найдены обновления безопасности:"
        echo "$security_updates" | while IFS= read -r line; do
            if [ -n "$line" ]; then
                local severity
                local package_info
                
                severity=$(echo "$line" | awk '{print $1}')
                package_info=$(echo "$line" | sed 's/^[A-Za-z]* *//')
                
                case "$severity" in
                    "Critical")
                        echo "  - $package_info [CRITICAL]"
                        critical_count=$((critical_count + 1))
                        ;;
                    "Important")
                        echo "  - $package_info [HIGH]"
                        high_count=$((high_count + 1))
                        ;;
                    "Moderate")
                        echo "  - $package_info [MEDIUM]"
                        medium_count=$((medium_count + 1))
                        ;;
                    "Low")
                        echo "  - $package_info [LOW]"
                        low_count=$((low_count + 1))
                        ;;
                esac
            fi
        done
    else
        echo "Обновления безопасности не найдены"
    fi
    
    echo ""
    echo "Статистика:"
    echo "  Critical: $critical_count пакетов"
    echo "  High: $high_count пакетов"
    echo "  Medium: $medium_count пакетов"
    echo "  Low: $low_count пакетов"
}

# Check with external security tools
check_with_external_tools() {
    echo ""
    echo "Проверка внешними инструментами безопасности:"
    
    # Check lynis
    if command -v lynis >/dev/null 2>&1; then
        echo "  lynis: доступен"
        echo "    Рекомендация: запустите 'lynis audit system' для полного анализа"
    else
        echo "  lynis: не установлен"
    fi
    
    # Check debsecan (Debian/Ubuntu)
    if command -v debsecan >/dev/null 2>&1; then
        echo "  debsecan: доступен"
    else
        echo "  debsecan: не установлен"
    fi
    
    # Check yum-plugin-security (RHEL-family)
    if command -v yum >/dev/null 2>&1 && rpm -q yum-plugin-security >/dev/null 2>&1; then
        echo "  yum-plugin-security: установлен"
    else
        echo "  yum-plugin-security: не установлен"
    fi
}

# Analyze package vulnerabilities
analyze_package_vulnerabilities() {
    echo "==== Анализ уязвимостей установленных пакетов ===="
    
    # Detect package manager
    local package_manager=""
    if command -v apt >/dev/null 2>&1; then
        package_manager="apt"
    elif command -v dnf >/dev/null 2>&1; then
        package_manager="dnf"
    elif command -v yum >/dev/null 2>&1; then
        package_manager="yum"
    else
        echo "Не удалось определить менеджер пакетов"
        return 1
    fi
    
    # Run appropriate check
    case "$package_manager" in
        "apt")
            check_vulnerable_packages_apt
            ;;
        "dnf"|"yum")
            check_vulnerable_packages_yum
            ;;
    esac
    
    # Check external tools
    check_with_external_tools
    
    echo ""
    echo "Рекомендации:"
    echo "  • Регулярно обновляйте систему: $package_manager update && $package_manager upgrade"
    echo "  • Установите инструменты безопасности: lynis, debsecan (для Debian/Ubuntu)"
    echo "  • Настройте автоматические обновления безопасности"
    echo "  • Мониторьте CVE базы данных для критичных уязвимостей"
    echo ""
}

# Функция для поиска лог-файлов из конфигов
find_log_files_from_configs() {
  local log_files=()
  
  # Nginx logs
  if [ -d /etc/nginx ]; then
    while IFS= read -r logpath; do
      [ -n "$logpath" ] && [ -f "$logpath" ] && log_files+=("$logpath")
    done < <(grep -rh -E '^\s*(access_log|error_log)\s+' /etc/nginx --include='*.conf' 2>/dev/null \
      | sed -E 's/^\s*(access_log|error_log)\s+//I' \
      | awk '{print $1}' \
      | sed -E 's/^"|"$//g; s/;.*$//' \
      | sort -u)
  fi
  
  # Apache logs
  if [ -d /etc/httpd ]; then
    while IFS= read -r logpath; do
      [ -n "$logpath" ] && [ -f "$logpath" ] && log_files+=("$logpath")
    done < <(grep -rh -E '^\s*(CustomLog|ErrorLog)\s+' /etc/httpd --include='*.conf' 2>/dev/null \
      | sed -E 's/^\s*(CustomLog|ErrorLog)\s+//I' \
      | awk '{print $1}' \
      | sed -E 's/^"|"$//g; s/\%\{.*\}//g' \
      | sort -u)
  fi
  
  if [ -d /etc/apache2 ]; then
    while IFS= read -r logpath; do
      [ -n "$logpath" ] && [ -f "$logpath" ] && log_files+=("$logpath")
    done < <(grep -rh -E '^\s*(CustomLog|ErrorLog)\s+' /etc/apache2 --include='*.conf' 2>/dev/null \
      | sed -E 's/^\s*(CustomLog|ErrorLog)\s+//I' \
      | awk '{print $1}' \
      | sed -E 's/^"|"$//g; s/\%\{.*\}//g' \
      | sort -u)
  fi
  
  # PHP error_log
  for phpini in /etc/php.ini /etc/php/*/fpm/php.ini /etc/php/*/cli/php.ini /etc/php*/php.ini; do
    [ -f "$phpini" ] && while IFS= read -r logpath; do
      [ -n "$logpath" ] && [ -f "$logpath" ] && log_files+=("$logpath")
    done < <(grep -E '^\s*error_log\s*=' "$phpini" 2>/dev/null \
      | sed -E 's/^\s*error_log\s*=\s*//' \
      | tr -d '"' \
      | sort -u)
  done
  
  # MySQL logs
  if command -v mysql >/dev/null 2>&1; then
    for logvar in log_error slow_query_log_file general_log_file; do
      logpath=$(mysql -NBe "SELECT @@${logvar};" 2>/dev/null || true)
      [ -n "$logpath" ] && [ -f "$logpath" ] && log_files+=("$logpath")
    done
  fi
  
  # Redis logs
  for redisconf in /etc/redis/redis.conf /etc/redis.conf /etc/redis/*.conf; do
    [ -f "$redisconf" ] && while IFS= read -r logpath; do
      [ -n "$logpath" ] && [ "$logpath" != '""' ] && [ -f "$logpath" ] && log_files+=("$logpath")
    done < <(grep -E '^\s*logfile\s+' "$redisconf" 2>/dev/null \
      | awk '{print $2}' \
      | tr -d '"' \
      | sort -u)
  done
  
  # systemd журналы (файлы, не journald)
  if command -v systemctl >/dev/null 2>&1; then
    while IFS= read -r logpath; do
      [ -n "$logpath" ] && [ -f "$logpath" ] && log_files+=("$logpath")
    done < <(systemctl show '*' --property=StandardOutput --property=StandardError --no-pager 2>/dev/null \
      | grep -E '=file:' \
      | cut -d: -f2- \
      | sort -u)
  fi
  
  # Удаление дубликатов и вывод
  printf '%s\n' "${log_files[@]}" | sort -u
}

: > "$TMP"

# ========== ПОРТЫ И СЕТЕВЫЕ СОЕДИНЕНИЯ ==========

hdr "Открытые порты и сетевые соединения"
if command -v ss >/dev/null; then
  echo "--- Все открытые порты (LISTEN) ---"
  ss -tuln 2>/dev/null | head -n 50
  echo
  echo "--- Активные соединения (ESTABLISHED) ---"
  ss -tun 2>/dev/null | grep ESTAB | head -n 20
  echo
  echo "--- Соединения по состояниям ---"
  ss -tan 2>/dev/null | awk 'NR>1{st[$1]++} END{for(k in st) printf "%-15s %d\n", k, st[k]}' | sort -k2 -nr
else
  echo "ss не найден, используем netstat"
  if command -v netstat >/dev/null; then
    netstat -tuln 2>/dev/null | head -n 50
  else
    echo "netstat также не найден"
  fi
fi

hdr "Сетевые интерфейсы и их статус"
if command -v ip >/dev/null; then
  ip -o link show 2>/dev/null
  echo
  echo "--- Статистика интерфейсов ---"
  ip -s link show 2>/dev/null | head -n 50
else
  echo "ip не найден, используем ifconfig"
  if command -v ifconfig >/dev/null; then
    ifconfig 2>/dev/null | head -n 50
  else
    echo "ifconfig также не найден"
  fi
fi

# ========== ПРОЦЕССЫ И СЕРВИСЫ ==========

hdr "Запущенные сервисы systemd"
if command -v systemctl >/dev/null; then
  echo "--- Активные сервисы ---"
  systemctl list-units --type=service --state=active --no-pager | head -n 30
  echo
  echo "--- Неудачные сервисы ---"
  systemctl list-units --type=service --state=failed --no-pager
  echo
  echo "--- Сервисы с ошибками ---"
  systemctl list-units --type=service --state=error --no-pager
else
  echo "systemctl не найден"
fi

hdr "Топ процессов по использованию ресурсов"
echo "--- По CPU ---"
ps -eo pid,ppid,cmd,%cpu,%mem --sort=-%cpu | head -n 15
echo
echo "--- По памяти ---"
ps -eo pid,ppid,cmd,%cpu,%mem --sort=-%mem | head -n 15
echo
echo "--- Zombie процессы ---"
ps -eo pid,ppid,state,cmd | grep -E '^[[:space:]]*[0-9]+[[:space:]]+[0-9]+[[:space:]]+Z' || echo "Zombie процессов не найдено"

hdr "Процессы не от systemd (возможные проблемы)"
if command -v systemctl >/dev/null; then
  ps -eo pid,ppid,cmd --no-headers | while read -r pid ppid cmd; do
    if [ "$ppid" != "1" ] && [ "$pid" != "1" ]; then
      # Проверяем, является ли родительский процесс systemd
      if ! systemctl is-system-running >/dev/null 2>&1 || [ "$ppid" != "1" ]; then
        echo "PID $pid (PPID $ppid): $cmd"
      fi
    fi
  done | head -n 20
else
  echo "systemctl не найден, пропускаем проверку"
fi

# ========== FIREWALL ANALYSIS FUNCTIONS ==========

# Analyze UFW rules in detail
analyze_ufw_rules() {
    echo "Тип: UFW"
    
    if ! command -v ufw >/dev/null 2>&1; then
        echo "UFW не установлен"
        return 1
    fi
    
    # Check if UFW is active
    local ufw_status
    ufw_status=$(ufw status 2>/dev/null | head -n1)
    
    if echo "$ufw_status" | grep -q "Status: active"; then
        echo "Статус: активен"
        
        # Get default policies
        local default_policies
        default_policies=$(ufw status verbose 2>/dev/null | grep "Default:" | head -n2)
        echo "Политика по умолчанию:"
        echo "$default_policies"
        echo ""
        
        # Get active rules
        echo "Активные правила:"
        local rule_num=1
        ufw status numbered 2>/dev/null | grep -E "^\[[0-9]+\]" | while IFS= read -r line; do
            local rule_text
            rule_text=$(echo "$line" | sed 's/^\[[0-9]*\] *//')
            
            # Analyze rule for Bitrix24 security
            if echo "$rule_text" | grep -q "22/tcp"; then
                echo "  $rule_num. $rule_text [OK] SSH защищен"
            elif echo "$rule_text" | grep -q "80/tcp"; then
                echo "  $rule_num. $rule_text [OK] HTTP открыт"
            elif echo "$rule_text" | grep -q "443/tcp"; then
                echo "  $rule_num. $rule_text [OK] HTTPS открыт"
            elif echo "$rule_text" | grep -q "3306/tcp"; then
                if echo "$rule_text" | grep -q "from anywhere"; then
                    echo "  $rule_num. $rule_text [WARN] MySQL открыт наружу!"
                else
                    echo "  $rule_num. $rule_text [OK] MySQL ограничен"
                fi
            elif echo "$rule_text" | grep -q "6379/tcp"; then
                if echo "$rule_text" | grep -q "from anywhere"; then
                    echo "  $rule_num. $rule_text [CRIT] Redis открыт наружу!"
                else
                    echo "  $rule_num. $rule_text [OK] Redis ограничен"
                fi
            else
                echo "  $rule_num. $rule_text"
            fi
            rule_num=$((rule_num + 1))
        done
    else
        echo "Статус: не активен"
        echo "[WARN] UFW не активен - система не защищена фаерволом"
    fi
}

# Analyze firewalld rules in detail
analyze_firewalld_rules() {
    echo "Тип: firewalld"
    
    if ! command -v firewall-cmd >/dev/null 2>&1; then
        echo "firewalld не установлен"
        return 1
    fi
    
    # Check if firewalld is active
    local firewalld_status
    firewalld_status=$(firewall-cmd --state 2>/dev/null)
    
    if [ "$firewalld_status" = "running" ]; then
        echo "Статус: активен"
        
        # Get default zone
        local default_zone
        default_zone=$(firewall-cmd --get-default-zone 2>/dev/null)
        echo "Зона по умолчанию: $default_zone"
        
        # Get active zones
        echo ""
        echo "Активные зоны:"
        firewall-cmd --get-active-zones 2>/dev/null | while IFS= read -r zone_info; do
            if [[ "$zone_info" =~ ^[a-zA-Z0-9_-]+$ ]]; then
                local zone="$zone_info"
                echo "  Зона: $zone"
                
                # Get services in zone
                local services
                services=$(firewall-cmd --zone="$zone" --list-services 2>/dev/null)
                if [ -n "$services" ]; then
                    echo "    Сервисы: $services"
                fi
                
                # Get ports in zone
                local ports
                ports=$(firewall-cmd --zone="$zone" --list-ports 2>/dev/null)
                if [ -n "$ports" ]; then
                    echo "    Порты: $ports"
                fi
            fi
        done
        
        # Check Bitrix24-specific ports
        echo ""
        echo "Bitrix24-специфичные проверки:"
        
        # Check HTTP/HTTPS
        if firewall-cmd --query-service=http 2>/dev/null; then
            echo "  ✓ HTTP разрешен"
        else
            echo "  ✗ HTTP не разрешен"
        fi
        
        if firewall-cmd --query-service=https 2>/dev/null; then
            echo "  ✓ HTTPS разрешен"
        else
            echo "  ✗ HTTPS не разрешен"
        fi
        
        # Check SSH
        if firewall-cmd --query-service=ssh 2>/dev/null; then
            echo "  ✓ SSH разрешен"
        else
            echo "  ✗ SSH не разрешен"
        fi
        
        # Check MySQL
        if firewall-cmd --query-port=3306/tcp 2>/dev/null; then
            echo "  ⚠ MySQL порт 3306 открыт"
        else
            echo "  ✓ MySQL порт 3306 закрыт"
        fi
        
        # Check Redis
        if firewall-cmd --query-port=6379/tcp 2>/dev/null; then
            echo "  ⚠ Redis порт 6379 открыт"
        else
            echo "  ✓ Redis порт 6379 закрыт"
        fi
        
    else
        echo "Статус: не активен"
        echo "[WARN] firewalld не активен - система не защищена фаерволом"
    fi
}

# Analyze iptables rules in detail
analyze_iptables_rules() {
    echo "Тип: iptables"
    
    if ! command -v iptables >/dev/null 2>&1; then
        echo "iptables не установлен"
        return 1
    fi
    
    # Check if there are any rules
    local rule_count
    rule_count=$(iptables -L -n 2>/dev/null | grep -c "^[A-Z]" || echo "0")
    
    if [ "$rule_count" -gt 0 ]; then
        echo "Статус: правила найдены ($rule_count цепочек)"
        
        # Get INPUT chain rules
        echo ""
        echo "Правила INPUT цепочки:"
        iptables -L INPUT -n --line-numbers 2>/dev/null | while IFS= read -r line; do
            if echo "$line" | grep -q "ACCEPT.*tcp.*dpt:22"; then
                echo "  $line [OK] SSH разрешен"
            elif echo "$line" | grep -q "ACCEPT.*tcp.*dpt:80"; then
                echo "  $line [OK] HTTP разрешен"
            elif echo "$line" | grep -q "ACCEPT.*tcp.*dpt:443"; then
                echo "  $line [OK] HTTPS разрешен"
            elif echo "$line" | grep -q "ACCEPT.*tcp.*dpt:3306"; then
                echo "  $line [WARN] MySQL разрешен"
            elif echo "$line" | grep -q "ACCEPT.*tcp.*dpt:6379"; then
                echo "  $line [CRIT] Redis разрешен"
            else
                echo "  $line"
            fi
        done
        
        # Check default policy
        local default_policy
        default_policy=$(iptables -L INPUT 2>/dev/null | grep "Chain INPUT" | awk '{print $4}' | tr -d ')')
        echo ""
        echo "Политика по умолчанию INPUT: $default_policy"
        
    else
        echo "Статус: правила не найдены"
        echo "[WARN] iptables не настроен - система не защищена фаерволом"
    fi
}

# Check port exposure for security
check_port_exposure() {
    echo ""
    echo "Анализ открытых портов на безопасность:"
    
    if ! command -v ss >/dev/null 2>&1; then
        echo "ss не найден, пропускаем анализ портов"
        return 1
    fi
    
    # Get all listening ports
    local listening_ports
    listening_ports=$(ss -tuln 2>/dev/null | grep LISTEN)
    
    if [ -n "$listening_ports" ]; then
        echo "Открытые порты:"
        echo "$listening_ports" | while IFS= read -r line; do
            local port
            port=$(echo "$line" | awk '{print $5}' | sed 's/.*://')
            
            case "$port" in
                "22")
                    echo "  - $port/tcp (SSH) [OK]"
                    ;;
                "80")
                    echo "  - $port/tcp (HTTP) [OK]"
                    ;;
                "443")
                    echo "  - $port/tcp (HTTPS) [OK]"
                    ;;
                "3306")
                    echo "  - $port/tcp (MySQL) [WARN] Должен быть доступен только локально"
                    ;;
                "6379")
                    echo "  - $port/tcp (Redis) [CRIT] Должен быть доступен только локально"
                    ;;
                "8888")
                    echo "  - $port/tcp (Bitrix Push) [INFO]"
                    ;;
                "8893"|"8894"|"8895")
                    echo "  - $port/tcp (Bitrix Push) [INFO]"
                    ;;
                "9010"|"9011"|"9012"|"9013"|"9014"|"9015")
                    echo "  - $port/tcp (Bitrix Push) [INFO]"
                    ;;
                *)
                    echo "  - $port/tcp [UNKNOWN] Неизвестный сервис"
                    ;;
            esac
        done
    else
        echo "Открытые порты не найдены"
    fi
}

# Generate firewall recommendations
generate_firewall_recommendations() {
    echo ""
    echo "Рекомендации по настройке фаервола:"
    
    # Check if any firewall is active
    local firewall_active=0
    
    if command -v ufw >/dev/null 2>&1 && ufw status 2>/dev/null | grep -q "Status: active"; then
        firewall_active=1
        echo "  [INFO] UFW активен - проверьте правила выше"
    elif command -v firewall-cmd >/dev/null 2>&1 && [ "$(firewall-cmd --state 2>/dev/null)" = "running" ]; then
        firewall_active=1
        echo "  [INFO] firewalld активен - проверьте настройки выше"
    elif command -v iptables >/dev/null 2>&1 && iptables -L -n 2>/dev/null | grep -q "ACCEPT\|DROP\|REJECT"; then
        firewall_active=1
        echo "  [INFO] iptables настроен - проверьте правила выше"
    fi
    
    if [ "$firewall_active" -eq 0 ]; then
        echo "  [CRIT] Фаервол не активен!"
        echo "    • Установите и настройте UFW: sudo ufw enable"
        echo "    • Или firewalld: sudo systemctl enable --now firewalld"
        echo "    • Или настройте iptables правила"
    fi
    
    # Bitrix24-specific recommendations
    echo ""
    echo "Bitrix24-специфичные рекомендации:"
    
    # Check MySQL port
    if ss -tuln 2>/dev/null | grep -q ":3306"; then
        echo "  [WARN] MySQL порт 3306 открыт:"
        echo "    • Ограничьте доступ: sudo ufw allow from 10.0.0.0/8 to any port 3306"
        echo "    • Или закройте: sudo ufw delete allow 3306/tcp"
    fi
    
    # Check Redis port
    if ss -tuln 2>/dev/null | grep -q ":6379"; then
        echo "  [CRIT] Redis порт 6379 открыт:"
        echo "    • Ограничьте доступ: sudo ufw allow from 127.0.0.1 to any port 6379"
        echo "    • Или закройте: sudo ufw delete allow 6379/tcp"
    fi
    
    # Check SSH
    if ss -tuln 2>/dev/null | grep -q ":22"; then
        echo "  [INFO] SSH порт 22 открыт:"
        echo "    • Рассмотрите изменение порта SSH"
        echo "    • Включите rate limiting: sudo ufw limit 22/tcp"
        echo "    • Используйте ключи вместо паролей"
    fi
    
    echo ""
    echo "Общие рекомендации:"
    echo "  • Регулярно проверяйте правила фаервола"
    echo "  • Ведите логи фаервола для мониторинга"
    echo "  • Используйте fail2ban для защиты от брутфорса"
    echo "  • Рассмотрите использование VPN для административного доступа"
}

# ========== FIREWALL И БЕЗОПАСНОСТЬ ==========

hdr "Расширенный анализ безопасности фаервола"
# Проверяем разные типы firewall с детальным анализом
if command -v ufw >/dev/null; then
  analyze_ufw_rules | w
elif command -v firewall-cmd >/dev/null; then
  analyze_firewalld_rules | w
elif command -v iptables >/dev/null; then
  analyze_iptables_rules | w
else
  echo "Фаервол не найден - система не защищена!"
fi

# Анализ открытых портов
check_port_exposure | w

# Генерация рекомендаций
generate_firewall_recommendations | w

hdr "Открытые порты для веб-серверов и баз данных"
if command -v ss >/dev/null; then
  echo "--- Критичные порты ---"
  ss -tuln 2>/dev/null | grep -E ':(80|443|3306|6379|8888|8893|8894|8895|9010|9011|9012|9013|9014|9015)' || echo "Критичные порты не найдены"
  echo
  echo "--- SSH порты ---"
  ss -tuln 2>/dev/null | grep -E ':22' || echo "SSH порт не найден"
else
  echo "ss не найден, пропускаем проверку портов"
fi

# ========== РАСШИРЕННЫЙ АНАЛИЗ SYSCTL ==========

hdr "Полный дамп sysctl параметров (для анализа)"
SYSCTL_DUMP_FILE="${OUT_DIR}/sysctl_full_dump.txt"
sysctl -a 2>/dev/null > "$SYSCTL_DUMP_FILE" || echo "Не удалось создать полный дамп sysctl"
echo "Полный дамп сохранен в: $SYSCTL_DUMP_FILE"

hdr "Критичные sysctl параметры для Bitrix24"
echo "--- Память и VM ---"
sysctl vm.swappiness vm.dirty_ratio vm.dirty_background_ratio vm.overcommit_memory vm.max_map_count 2>/dev/null
echo
echo "--- Сеть ---"
sysctl net.core.somaxconn net.core.netdev_max_backlog net.ipv4.tcp_max_syn_backlog 2>/dev/null
echo
echo "--- Файловая система ---"
sysctl fs.file-max fs.inotify.max_user_watches fs.inotify.max_user_instances 2>/dev/null
echo
echo "--- Процессы ---"
sysctl kernel.pid_max kernel.threads-max kernel.sched_latency_ns 2>/dev/null

hdr "Анализ sysctl на предмет оптимизации"
# Функция для проверки параметров
check_sysctl_param() {
  local param="$1"
  local current="$2"
  local recommended="$3"
  local description="$4"
  
  if [ "$current" -lt "$recommended" ]; then
    echo "[WARN] $param=$current (рекомендуется >= $recommended) - $description"
  elif [ "$current" -gt "$recommended" ]; then
    echo "[INFO] $param=$current (рекомендуется <= $recommended) - $description"
  else
    echo "[OK] $param=$current - $description"
  fi
}

# Проверяем ключевые параметры
SOMAXCONN=$(sysctl -n net.core.somaxconn 2>/dev/null || echo "0")
check_sysctl_param "net.core.somaxconn" "$SOMAXCONN" "1024" "Размер очереди подключений"

FILE_MAX=$(sysctl -n fs.file-max 2>/dev/null || echo "0")
check_sysctl_param "fs.file-max" "$FILE_MAX" "2097152" "Максимальное количество открытых файлов"

SWAPPINESS=$(sysctl -n vm.swappiness 2>/dev/null || echo "60")
check_sysctl_param "vm.swappiness" "$SWAPPINESS" "10" "Склонность к использованию swap"

DIRTY_RATIO=$(sysctl -n vm.dirty_ratio 2>/dev/null || echo "20")
check_sysctl_param "vm.dirty_ratio" "$DIRTY_RATIO" "15" "Процент грязных страниц для записи"

TCP_MAX_SYN_BACKLOG=$(sysctl -n net.ipv4.tcp_max_syn_backlog 2>/dev/null || echo "128")
check_sysctl_param "net.ipv4.tcp_max_syn_backlog" "$TCP_MAX_SYN_BACKLOG" "2048" "Размер очереди SYN запросов"

# ========== БАЗОВОЕ ==========
hdr "uname / дата / аптайм"
uname -a
date
uptime

# ========== АНАЛИЗ ОС И EOL ==========
analyze_os_eol | w

# ========== АНАЛИЗ УЯЗВИМОСТЕЙ ПАКЕТОВ ==========
analyze_package_vulnerabilities | w

hdr "Информация о локали и окружении"
echo "Текущая локаль:"
locale
echo ""
echo "LC_TIME: ${LC_TIME:-not set}"
echo "LANGUAGE: ${LANGUAGE:-not set}"
echo "LC_NUMERIC: ${LC_NUMERIC:-not set}"
echo "SCRIPT_LANGUAGE: ${SCRIPT_LANGUAGE:-not set}"
echo "SCRIPT_LC_TIME: ${SCRIPT_LC_TIME:-not set}"

hdr "Загрузка (loadavg)"
sed -n '1p' -- /proc/loadavg 2>/dev/null

# ========== ЛИМИТЫ ==========
hdr "ulimit -a (лимиты текущего шелла)"
ulimit -a 2>/dev/null

hdr "/proc/$$/limits (лимиты текущего процесса)"
sed -n '1p' -- "/proc/$$/limits" 2>/dev/null


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


hdr "kernel.threads-max / pid_max (лимиты процессов/потоков)"
sysctl kernel.threads-max 2>/dev/null
sysctl kernel.pid_max 2>/dev/null

# ========== CGROUPS / SYSTEMD ==========
hdr "cgroups: текущий процесс"
sed -n '1p' -- "/proc/$$/cgroup" 2>/dev/null

hdr "systemd-cgls (дерево cgroups)"
if command -v systemd-cgls >/dev/null; then
  systemd-cgls --no-pager | sed -n '1,200p'
else
  echo "systemd-cgls не найден"
fi

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

# ========== CGROUP v2: СЧЁТЧИКИ ==========

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


# ========== FD ==========

  hdr "fs.file-max (глобальный лимит) и file-nr (использование)"
  sysctl fs.file-max 2>/dev/null
  sed -n '1p' -- /proc/sys/fs/file-nr 2>/dev/null | wc -l



  hdr "Топ процессов по числу открытых файлов (если есть lsof)"
  if command -v lsof >/dev/null 2>&1; then
    timeout 10 lsof -nP 2>/dev/null | awk 'NR>1{print $1" "$2}' | sort | uniq -c | sort -nr | head -n 20 || echo "lsof timeout or error"
  else
    echo "lsof не найден"
  fi


# ========== ПАМЯТЬ / VM ==========
hdr "/proc/meminfo"
sed -n '1,200p' "/proc/meminfo"


  hdr "vmstat -s (если установлен)"
  if command -v vmstat >/dev/null; then vmstat -s; else 
    echo ""
    echo "============================================================"
    echo "РЕКОМЕНДАЦИИ ПО УСТАНОВКЕ ОТСУТСТВУЮЩИХ ПАКЕТОВ"
    echo "============================================================"
    echo ""
    echo "vmstat не найден (sysstat)"; 
  fi



  hdr "Настройки VM: swappiness / dirty_* / overcommit / max_map_count / NUMA"
  sysctl vm.swappiness 2>/dev/null
  sysctl vm.dirty_ratio 2>/dev/null
  sysctl vm.dirty_background_ratio 2>/dev/null
  sysctl vm.dirty_bytes 2>/dev/null
  sysctl vm.dirty_background_bytes 2>/dev/null
  sysctl vm.overcommit_memory 2>/dev/null
  sysctl vm.overcommit_ratio 2>/dev/null
  sysctl vm.max_map_count 2>/dev/null
  sysctl kernel.numa_balancing 2>/dev/null || echo "kernel.numa_balancing: not available" 2>/dev/null
  sysctl vm.zone_reclaim_mode 2>/dev/null


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


# PSI

  hdr "Pressure Stall Information (PSI) cpu/memory/io"
  for f in /proc/pressure/cpu /proc/pressure/memory /proc/pressure/io; do
  if [ -r "$f" ]; then echo "== $f =="; sed -n '1p' -- "$f" 2>/dev/null | tr -d '\n' || true; echo; fi
  done


# ========== ДИСКИ / IO ==========

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



  hdr "AIO лимиты"
  sysctl fs.aio-max-nr 2>/dev/null
  [ -r /proc/sys/fs/aio-nr ] && { printf 'aio-nr: '; sed -n '1p' -- /proc/sys/fs/aio-nr 2>/dev/null | tr -d '\n' || true; echo; }



  hdr "Статистика IO (iostat -x 1 3, если есть)"
  if command -v iostat >/dev/null; then iostat -x 1 3; else echo "iostat не найден (sysstat)"; fi


# SMART

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


# ========== СЕТЬ ==========

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


# Conntrack

  hdr "Conntrack (если доступен)"
  [ -r /proc/sys/net/netfilter/nf_conntrack_max ]   && { printf 'nf_conntrack_max: ';   sed -n '1p' -- /proc/sys/net/netfilter/nf_conntrack_max 2>/dev/null | tr -d '\n' || true; echo; }
  [ -r /proc/sys/net/netfilter/nf_conntrack_count ] && { printf 'nf_conntrack_count: '; sed -n '1p' -- /proc/sys/net/netfilter/nf_conntrack_count 2>/dev/null | tr -d '\n' || true; echo; }


# Состояния TCP

  hdr "Состояния TCP (счётчики по ss)"
  if command -v ss >/dev/null; then
    ss -tan 2>/dev/null | awk 'NR>1{st[$1]++} END{for(k in st) printf "%-15s %d\n", k, st[k]}' | sort
  else
    echo "ss не найден"
  fi


# LISTEN backlog популярных портов

  hdr "Очереди LISTEN (оценка backlog популярных портов)"
  if command -v ss >/dev/null; then
  ss -lntH 2>/dev/null | awk '{printf "%-22s backlog=%s\n",$4,$2}' | grep -E ':(80|443|8888|6379|3306|22|889[3-5]|901[0-5])' || true
  else
    echo "ss не найден"
  fi


hdr "Сетевые ring-buffers (ethtool -g)"
if command -v ethtool >/dev/null; then
  ip -o link | awk -F': ' '{print $2}' | while IFS= read -r IF; do
    echo "--- $IF ---"
        ethtool -g "$IF" 2>/dev/null || echo "ethtool -g $IF: not supported"
  done
else
  echo "ethtool не найден"
fi

hdr "Сокеты в состоянии LISTEN (если есть ss)"
if command -v ss >/dev/null; then
  ss -lntp 2>/dev/null | sed -n '1,999p'
else
  echo "ss не найден"
fi

# softnet

  hdr "/proc/net/softnet_stat (ошибки на входе, drops)"
  sed -n '1,200p' /proc/net/softnet_stat 2>/dev/null || echo "нет /proc/net/softnet_stat"


# /proc/net/snmp и netstat -s

  hdr "Сетевые счётчики (/proc/net/snmp, netstat -s)"
  sed -n '1,200p' /proc/net/snmp 2>/dev/null || true
  if command -v netstat >/dev/null; then netstat -s 2>/dev/null | sed -n '1,200p'; fi


# RPS/XPS (с доп.проверками наличия файлов)

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


# ========== CPU ==========

  hdr "/proc/cpuinfo (кратко)"
    grep -E -i 'processor|model name|cpu MHz|bogomips' /proc/cpuinfo | sed -n '1,80p'



  hdr "Приоритеты процессов (top 20 по CPU)"
  ps -eo pid,ppid,cmd,pri,ni,rtprio,%cpu --sort=-%cpu | sed -n '1,21p'



  hdr "CPU affinity (топ-10 по CPU)"
  ps -eo pid,%cpu,cmd --sort=-%cpu | awk 'NR>1{print $1}' | head -n 10 | while IFS= read -r P; do
    [ -r "/proc/$P/status" ] || continue
    ALLOWED="$(grep -i '^Cpus_allowed_list:' "/proc/$P/status" 2>/dev/null | awk '{print $2}')"
    echo "pid=$P cpus_allowed_list=${ALLOWED:-?}"
  done


# governor

  hdr "CPU frequency governor"
  for g in /sys/devices/system/cpu/cpu*/cpufreq/scaling_governor; do
  if [ -r "$g" ]; then printf '%s: ' "$g"; sed -n '1p' -- "$g" 2>/dev/null | tr -d '\n' || true; echo; fi
  done


# interrupts

  hdr "/proc/interrupts (top 40 строк)"
  sed -n '1,40p' /proc/interrupts 2>/dev/null


# Параметры планировщика ядра

  hdr "kernel.sched_* (настройки планировщика)"
  sysctl kernel.sched_latency_ns 2>/dev/null || echo "kernel.sched_latency_ns: not available" 2>/dev/null
  sysctl kernel.sched_min_granularity_ns 2>/dev/null || echo "kernel.sched_min_granularity_ns: not available" 2>/dev/null
  sysctl kernel.sched_wakeup_granularity_ns 2>/dev/null || echo "kernel.sched_wakeup_granularity_ns: not available" 2>/dev/null


# ========== IPC ==========

  hdr "Общая память и семафоры (kernel.shm*, kernel.sem)"
  sysctl kernel.shmmax 2>/dev/null
  sysctl kernel.shmall 2>/dev/null
  sysctl kernel.shmmni 2>/dev/null
  sysctl kernel.sem 2>/dev/null


# ========== INOTIFY ==========

  hdr "Inotify лимиты"
  sysctl fs.inotify.max_user_watches 2>/dev/null
  sysctl fs.inotify.max_user_instances 2>/dev/null
  sysctl fs.inotify.max_queued_events 2>/dev/null


# ========== FS ==========

  hdr "Параметры монтирования (mount | findmnt)"
  if command -v findmnt >/dev/null; then
    findmnt -aro TARGET,SOURCE,FSTYPE,OPTIONS
  else
    mount
  fi


# ========== ETH TOOLS ==========

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


# ========== SLAB / NUMA ==========

  hdr "slabtop (топ-объекты SLAB), если установлен"
  if command -v slabtop >/dev/null; then slabtop -o 2>/dev/null | sed -n '1,200p' || echo "slabtop: /proc/slabinfo not available (WSL2 issue)"; else echo "slabtop не найден (procps-ng)"; fi



  hdr "numactl/hwloc (NUMA топология), если есть"
  if command -v numactl >/dev/null; then numactl --hardware; else echo "numactl не найден"; fi


# ========== NTP / ЧАСЫ ==========

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


# ========== ENTROPY ==========

  hdr "Доступная энтропия"
  if [ -r /proc/sys/kernel/random/entropy_avail ]; then
    # Read single-file content without spawning an extra process
  sed -n '1p' -- /proc/sys/kernel/random/entropy_avail 2>/dev/null | tr -d '\n' || true
    echo
  else
    echo "нет /proc/sys/kernel/random/entropy_avail"
  fi


# ========== ПЕРСИСТЕНТНЫЕ sysctl / GRUB / ENV ==========

  hdr "Персистентные sysctl (/etc/sysctl.conf, sysctl.d)"
  [ -r /etc/sysctl.conf ] && sed -n '1,200p' /etc/sysctl.conf
  if [ -d /etc/sysctl.d ]; then
    for f in /etc/sysctl.d/*.conf; do
      [ -r "$f" ] || continue
      echo "$f"
      sed -n '1,200p' "$f"
    done
  fi



  hdr "GRUB_CMDLINE_LINUX (ядро)"
  if [ -r /etc/default/grub ]; then
    grep -E -i '^GRUB_CMDLINE_LINUX' /etc/default/grub || true
  fi
  if [ -r /boot/grub2/grub.cfg ]; then
    sed -n '1,120p' /boot/grub2/grub.cfg 2>/dev/null | grep -E -i 'linux|kernel' || true
  elif compgen -G "/boot/efi/EFI/*/grub.cfg" >/dev/null; then
    sed -n '1,120p' /boot/efi/EFI/*/grub.cfg 2>/dev/null | grep -E -i 'linux|kernel' || true
  fi



  hdr "Environment (LIMITS/ULIMIT, если прокинуты через сервисы)"
  if command -v systemctl >/dev/null; then
    systemctl show --property=Environment --type=service --no-pager
  else
    echo "systemctl не найден"
  fi


# ========== DMSG / RATE LIMIT ==========

  hdr "Последние сообщения ядра (dmesg tail -200)"
  dmesg 2>/dev/null | tail -n 200



  hdr "dmesg ratelimit"
  sysctl kernel.printk_ratelimit 2>/dev/null
  sysctl kernel.printk_ratelimit_burst 2>/dev/null


# ========== SELINUX / APPARMOR ==========

  hdr "SELinux/AppArmor статус"
  if command -v getenforce >/dev/null; then
    echo "SELinux: $(getenforce)"
  elif [ -r /etc/selinux/config ]; then
    grep -E '^SELINUX=' /etc/selinux/config || true
  fi
  [ -r /sys/module/apparmor/parameters/enabled ] && { printf 'AppArmor: '; sed -n '1p' -- /sys/module/apparmor/parameters/enabled 2>/dev/null | tr -d '\n' || true; echo; }


# ========== ТОП-10 RSS - /proc/<pid>/limits ==========

  hdr "/proc/<pid>/limits для топ-10 по RSS"
  ps -eo pid,rss,cmd --sort=-rss | head -n 11 | tail -n +2 | while IFS= read -r P RSS CMD; do
    echo "--- pid=$P rss=${RSS} kB cmd=${CMD:0:80} ---"
    sed -n '1,200p' "/proc/$P/limits" 2>/dev/null || true
  done


# ========== DIAG menu.sh (read-only) ==========

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


# ========== АВТО-SUMMARY ==========

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

  # Проверка открытых портов
  if command -v ss >/dev/null; then
    CRITICAL_PORTS=$(ss -tuln 2>/dev/null | grep -E ':(80|443|3306|6379|8888)' | wc -l)
    if [ "${CRITICAL_PORTS:-0}" -gt 0 ]; then
      ok "Критичные порты открыты: $CRITICAL_PORTS"
    else
      warn "Критичные порты не найдены"
    fi
  fi

  # Проверка zombie процессов
  ZOMBIES=$(ps -eo state | grep -c Z || echo "0")
  if [ "${ZOMBIES:-0}" -gt 0 ]; then
    warn "Zombie процессов: $ZOMBIES"
  else
    ok "Zombie процессов: 0"
  fi

  # Проверка неудачных сервисов
  if command -v systemctl >/dev/null; then
    FAILED_SERVICES=$(systemctl list-units --type=service --state=failed --no-pager | grep -c failed || echo "0")
    if [ "${FAILED_SERVICES:-0}" -gt 0 ]; then
      warn "Неудачных сервисов: $FAILED_SERVICES"
    else
      ok "Неудачных сервисов: 0"
    fi
  fi

  # Проверка EOL операционной системы
  OS_EOL_STATUS="неизвестно"
  if [ -n "${OS_DISTRO_ID:-}" ] && [ -n "${OS_DISTRO_VERSION:-}" ]; then
    local lookup_key
    lookup_key=$(parse_os_version "$OS_DISTRO_ID" "$OS_DISTRO_VERSION")
    
    if check_eol_status_local "$lookup_key"; then
      local eol_data
      eol_data=$(check_eol_status_local "$lookup_key")
      local eol_date
      local support_type
      local description
      
      IFS='|' read -r eol_date support_type description <<< "$eol_data"
      
      if [ -n "$eol_date" ]; then
        local current_date
        local eol_timestamp
        local current_timestamp
        local days_until_eol
        
        current_date=$(date +%Y-%m-%d)
        eol_timestamp=$(date -d "$eol_date" +%s 2>/dev/null || echo "0")
        current_timestamp=$(date -d "$current_date" +%s 2>/dev/null || echo "0")
        
        if [ "$eol_timestamp" -gt 0 ] && [ "$current_timestamp" -gt 0 ]; then
          days_until_eol=$(( (eol_timestamp - current_timestamp) / 86400 ))
          
          if [ "$days_until_eol" -lt 0 ]; then
            crit "ОС достигла EOL ($((-days_until_eol)) дней назад)"
          elif [ "$days_until_eol" -lt 90 ]; then
            warn "ОС скоро достигнет EOL ($days_until_eol дней)"
          else
            ok "ОС в поддержке ($days_until_eol дней до EOL)"
          fi
        else
          ok "ОС в поддержке"
        fi
      else
        warn "EOL информация недоступна"
      fi
    else
      warn "ОС не найдена в базе EOL"
    fi
  else
    warn "Не удалось определить ОС"
  fi

  # Проверка уязвимостей пакетов
  VULNERABILITY_STATUS="неизвестно"
  if command -v apt >/dev/null 2>&1; then
    local upgradable_count
    upgradable_count=$(apt list --upgradable 2>/dev/null | grep -c "/" || echo "0")
    if [ "$upgradable_count" -gt 0 ]; then
      warn "Доступно обновлений: $upgradable_count"
    else
      ok "Все пакеты актуальны"
    fi
  elif command -v dnf >/dev/null 2>&1; then
    local security_updates
    security_updates=$(dnf updateinfo list security 2>/dev/null | grep -c "Critical\|Important" || echo "0")
    if [ "$security_updates" -gt 0 ]; then
      warn "Критичных обновлений безопасности: $security_updates"
    else
      ok "Критичных обновлений безопасности: 0"
    fi
  elif command -v yum >/dev/null 2>&1; then
    local security_updates
    security_updates=$(yum updateinfo list security 2>/dev/null | grep -c "Critical\|Important" || echo "0")
    if [ "$security_updates" -gt 0 ]; then
      warn "Критичных обновлений безопасности: $security_updates"
    else
      ok "Критичных обновлений безопасности: 0"
    fi
  fi

  # Проверка firewall
  FIREWALL_STATUS="неизвестно"
  if command -v ufw >/dev/null && ufw status | grep -q "Status: active"; then
    FIREWALL_STATUS="UFW активен"
  elif command -v firewall-cmd >/dev/null && firewall-cmd --state 2>/dev/null | grep -q "running"; then
    FIREWALL_STATUS="Firewalld активен"
  elif command -v iptables >/dev/null && iptables -L | grep -q "Chain INPUT"; then
    FIREWALL_STATUS="iptables активен"
  else
    FIREWALL_STATUS="не настроен"
  fi
  echo "[INFO] Firewall: $FIREWALL_STATUS"

  # Проверка открытых незащищенных портов
  if command -v ss >/dev/null; then
    local mysql_open=0
    local redis_open=0
    local unknown_ports=0
    
    # Check MySQL port
    if ss -tuln 2>/dev/null | grep -q ":3306"; then
      mysql_open=1
    fi
    
    # Check Redis port
    if ss -tuln 2>/dev/null | grep -q ":6379"; then
      redis_open=1
    fi
    
    # Check for unknown ports (not in our known list)
    local known_ports="22 80 443 3306 6379 8888 8893 8894 8895 9010 9011 9012 9013 9014 9015"
    local all_ports
    all_ports=$(ss -tuln 2>/dev/null | awk '{print $5}' | sed 's/.*://' | sort -u)
    
    for port in $all_ports; do
      if ! echo "$known_ports" | grep -q "\b$port\b"; then
        unknown_ports=$((unknown_ports + 1))
      fi
    done
    
    if [ "$redis_open" -eq 1 ]; then
      crit "Redis порт 6379 открыт наружу"
    elif [ "$mysql_open" -eq 1 ]; then
      warn "MySQL порт 3306 открыт наружу"
    else
      ok "Критичные порты БД защищены"
    fi
    
    if [ "$unknown_ports" -gt 0 ]; then
      warn "Неизвестных портов: $unknown_ports"
    else
      ok "Неизвестных портов: 0"
    fi
  fi

  # Проверка больших лог-файлов (исключая atop и sysstat)
  if [ -d /var/log ]; then
    BIG_LOGS=$(find /var/log -type f -size +100M \
      -not -path "/var/log/atop/*" \
      -not -path "/var/log/sa/*" \
      -not -path "/var/log/sysstat/*" \
      2>/dev/null | wc -l)
    if [ "${BIG_LOGS:-0}" -gt 0 ]; then
      warn "Больших лог-файлов (>100MB, исключая atop/sysstat): $BIG_LOGS"
    else
      ok "Больших лог-файлов (>100MB, исключая atop/sysstat): 0"
    fi
  fi

  # Проверка использования диска
  DISK_USAGE=$(df / 2>/dev/null | awk 'NR==2 {print $5}' | tr -d '%' || echo "0")
  if [ "${DISK_USAGE:-0}" -ge 90 ]; then
    crit "Использование диска /: ${DISK_USAGE}%"
  elif [ "${DISK_USAGE:-0}" -ge 80 ]; then
    warn "Использование диска /: ${DISK_USAGE}%"
  else
    ok "Использование диска /: ${DISK_USAGE}%"
  fi

  # Проверка исполняемых файлов в подозрительных местах
  SUSPICIOUS_EXECUTABLES=0
  for dir in /root /home /var/www /tmp /dev/shm; do
    if [ -d "$dir" ]; then
      count=$(find "$dir" -xdev -type f -executable 2>/dev/null | grep -v -E "^/(var/lib|var/cache|var/log|proc|sys|dev)" | wc -l)
      SUSPICIOUS_EXECUTABLES=$((SUSPICIOUS_EXECUTABLES + count))
    fi
  done
  
  if [ "${SUSPICIOUS_EXECUTABLES:-0}" -gt 0 ]; then
    warn "Исполняемых файлов в подозрительных местах: $SUSPICIOUS_EXECUTABLES"
  else
    ok "Исполняемых файлов в подозрительных местах: 0"
  fi

  # Проверка лог-файлов без logrotate
  CONFIG_LOGS_NO_ROTATE=0
  CONFIG_LOGS=$(find_log_files_from_configs | grep -v "^/var/log/" || true)
  if [ -n "$CONFIG_LOGS" ]; then
    while IFS= read -r logfile; do
      if [ -f "$logfile" ]; then
        if ! grep -R --line-number -F "$logfile" /etc/logrotate.d /etc/logrotate.conf >/dev/null 2>&1; then
          CONFIG_LOGS_NO_ROTATE=$((CONFIG_LOGS_NO_ROTATE + 1))
        fi
      fi
    done <<< "$CONFIG_LOGS"
  fi
  
  if [ "${CONFIG_LOGS_NO_ROTATE:-0}" -gt 0 ]; then
    warn "Лог-файлов без logrotate: $CONFIG_LOGS_NO_ROTATE"
  else
    ok "Лог-файлов без logrotate: 0"
  fi

  # Проверка синхронизации времени
  TIME_SYNC_STATUS="unknown"
  if command -v chronyc >/dev/null 2>&1; then
    if chronyc tracking 2>/dev/null | grep -q "Reference ID"; then
      SYNC_SOURCE=$(chronyc tracking 2>/dev/null | grep "Reference ID" | awk '{print $4}')
      if [ "$SYNC_SOURCE" != "()" ] && [ -n "$SYNC_SOURCE" ]; then
        TIME_SYNC_STATUS="synced"
        ok "Синхронизация времени: активна (chrony, источник: $SYNC_SOURCE)"
      else
        TIME_SYNC_STATUS="not_synced"
        warn "Синхронизация времени: не синхронизировано (chrony не подключен к источнику)"
      fi
    else
      TIME_SYNC_STATUS="chrony_error"
      warn "Синхронизация времени: ошибка запроса chrony"
    fi
  elif command -v ntpstat >/dev/null 2>&1; then
    if ntpstat >/dev/null 2>&1; then
      TIME_SYNC_STATUS="synced"
      ok "Синхронизация времени: активна (ntp)"
    else
      TIME_SYNC_STATUS="not_synced"
      warn "Синхронизация времени: не синхронизировано (ntp)"
    fi
  elif command -v timedatectl >/dev/null 2>&1; then
    if timedatectl status 2>/dev/null | grep -q "System clock synchronized: yes"; then
      TIME_SYNC_STATUS="synced"
      ok "Синхронизация времени: активна (systemd-timesyncd)"
    else
      TIME_SYNC_STATUS="not_synced"
      warn "Синхронизация времени: не синхронизировано"
    fi
  else
    TIME_SYNC_STATUS="no_tool"
    warn "Синхронизация времени: невозможно проверить (нет chrony/ntp/timedatectl)"
  fi

  # Проверка использования swap
  if [ -r /proc/meminfo ]; then
    SWAP_TOTAL=$(grep "^SwapTotal:" /proc/meminfo | awk '{print $2}')
    SWAP_FREE=$(grep "^SwapFree:" /proc/meminfo | awk '{print $2}')
    if [ "${SWAP_TOTAL:-0}" -gt 0 ]; then
      SWAP_USED=$((SWAP_TOTAL - SWAP_FREE))
      SWAP_PCT=$((100 * SWAP_USED / SWAP_TOTAL))
      if [ "$SWAP_PCT" -ge 80 ]; then
        crit "Использование swap: ${SWAP_PCT}% (${SWAP_USED}KB/${SWAP_TOTAL}KB)"
      elif [ "$SWAP_PCT" -ge 50 ]; then
        warn "Использование swap: ${SWAP_PCT}% (${SWAP_USED}KB/${SWAP_TOTAL}KB)"
      else
        ok "Использование swap: ${SWAP_PCT}% (${SWAP_USED}KB/${SWAP_TOTAL}KB)"
      fi
    else
      ok "Swap не используется"
    fi
  fi

  # Проверка использования RAM
  if [ -r /proc/meminfo ]; then
    MEM_TOTAL=$(grep "^MemTotal:" /proc/meminfo | awk '{print $2}')
    MEM_AVAILABLE=$(grep "^MemAvailable:" /proc/meminfo | awk '{print $2}')
    if [ -z "$MEM_AVAILABLE" ]; then
      MEM_FREE=$(grep "^MemFree:" /proc/meminfo | awk '{print $2}')
      MEM_BUFFERS=$(grep "^Buffers:" /proc/meminfo | awk '{print $2}')
      MEM_CACHED=$(grep "^Cached:" /proc/meminfo | awk '{print $2}')
      MEM_AVAILABLE=$((MEM_FREE + MEM_BUFFERS + MEM_CACHED))
    fi
    MEM_USED=$((MEM_TOTAL - MEM_AVAILABLE))
    MEM_PCT=$((100 * MEM_USED / MEM_TOTAL))
    if [ "$MEM_PCT" -ge 95 ]; then
      crit "Использование RAM: ${MEM_PCT}% (${MEM_USED}KB/${MEM_TOTAL}KB)"
    elif [ "$MEM_PCT" -ge 90 ]; then
      warn "Использование RAM: ${MEM_PCT}% (${MEM_USED}KB/${MEM_TOTAL}KB)"
    else
      ok "Использование RAM: ${MEM_PCT}% (${MEM_USED}KB/${MEM_TOTAL}KB)"
    fi
  fi

  # Проверка использования /home/bitrix (если отдельный раздел)
  if [ -d /home/bitrix ]; then
    BITRIX_USAGE=$(df /home/bitrix 2>/dev/null | awk 'NR==2 {print $5}' | tr -d '%' || echo "0")
    if [ "${BITRIX_USAGE:-0}" -ge 90 ]; then
      crit "Использование /home/bitrix: ${BITRIX_USAGE}%"
    elif [ "${BITRIX_USAGE:-0}" -ge 80 ]; then
      warn "Использование /home/bitrix: ${BITRIX_USAGE}%"
    else
      ok "Использование /home/bitrix: ${BITRIX_USAGE}%"
    fi
  fi

  # Проверка статуса ключевых сервисов Bitrix24
  BITRIX_SERVICES=("nginx" "mysqld" "php-fpm" "redis")
  FAILED_BITRIX_SERVICES=0
  for service in "${BITRIX_SERVICES[@]}"; do
    if command -v systemctl >/dev/null 2>&1; then
      if systemctl is-active "$service" >/dev/null 2>&1; then
        ok "Сервис $service: активен"
      else
        warn "Сервис $service: НЕ АКТИВЕН"
        FAILED_BITRIX_SERVICES=$((FAILED_BITRIX_SERVICES + 1))
      fi
    fi
  done
  
  if [ "$FAILED_BITRIX_SERVICES" -gt 0 ]; then
    crit "Критичных сервисов Bitrix24 неактивно: $FAILED_BITRIX_SERVICES"
  fi

  # Проверка inode usage
  INODE_USAGE=$(df -i / 2>/dev/null | awk 'NR==2 {print $5}' | tr -d '%' || echo "0")
  if [ "${INODE_USAGE:-0}" -ge 90 ]; then
    crit "Использование inode: ${INODE_USAGE}%"
  elif [ "${INODE_USAGE:-0}" -ge 80 ]; then
    warn "Использование inode: ${INODE_USAGE}%"
  else
    ok "Использование inode: ${INODE_USAGE}%"
  fi

  # Проверка load average относительно количества CPU
  CPU_COUNT=$(nproc 2>/dev/null || echo "1")
  LOAD_1MIN=$(uptime | awk -F'load average:' '{print $2}' | awk -F',' '{print $1}' | tr -d ' ' || echo "0")
  LOAD_THRESHOLD_WARN=$((CPU_COUNT * 150 / 100))
  LOAD_THRESHOLD_CRIT=$((CPU_COUNT * 200 / 100))
  
  if [ "$(echo "$LOAD_1MIN > $LOAD_THRESHOLD_CRIT" | bc -l 2>/dev/null || echo "0")" = "1" ]; then
    crit "Load average: $LOAD_1MIN (CPU: $CPU_COUNT, критично)"
  elif [ "$(echo "$LOAD_1MIN > $LOAD_THRESHOLD_WARN" | bc -l 2>/dev/null || echo "0")" = "1" ]; then
    warn "Load average: $LOAD_1MIN (CPU: $CPU_COUNT, высоко)"
  else
    ok "Load average: $LOAD_1MIN (CPU: $CPU_COUNT)"
  fi

  # Проверка SUID/SGID файлов в подозрительных местах
  SUID_SUSPICIOUS=0
  for dir in /home /tmp /var/www; do
    if [ -d "$dir" ]; then
      count=$(find "$dir" -xdev -type f \( -perm -4000 -o -perm -2000 \) 2>/dev/null | wc -l)
      SUID_SUSPICIOUS=$((SUID_SUSPICIOUS + count))
    fi
  done
  
  if [ "${SUID_SUSPICIOUS:-0}" -gt 0 ]; then
    warn "SUID/SGID файлов в подозрительных местах: $SUID_SUSPICIOUS"
  else
    ok "SUID/SGID файлов в подозрительных местах: 0"
  fi

  # Проверка world-writable файлов в /home, /var/www
  WORLD_WRITABLE=0
  for dir in /home /var/www; do
    if [ -d "$dir" ]; then
      count=$(find "$dir" -xdev -type f -perm -002 2>/dev/null | wc -l)
      WORLD_WRITABLE=$((WORLD_WRITABLE + count))
    fi
  done
  
  if [ "${WORLD_WRITABLE:-0}" -gt 10 ]; then
    warn "World-writable файлов в /home,/var/www: $WORLD_WRITABLE"
  else
    ok "World-writable файлов в /home,/var/www: $WORLD_WRITABLE"
  fi

  # Проверка ESTABLISHED connections
  if command -v ss >/dev/null 2>&1; then
    ESTABLISHED_COUNT=$(ss -tan 2>/dev/null | grep -c ESTAB || echo "0")
    if [ "${ESTABLISHED_COUNT:-0}" -gt 5000 ]; then
      warn "ESTABLISHED соединений: $ESTABLISHED_COUNT (много)"
    else
      ok "ESTABLISHED соединений: $ESTABLISHED_COUNT"
    fi
  fi

  # Проверка CPU steal time (для виртуализации)
  if [ -r /proc/stat ]; then
    CPU_STEAL=$(grep "^cpu " /proc/stat | awk '{print $9}')
    CPU_TOTAL=$(grep "^cpu " /proc/stat | awk '{sum=0; for(i=2;i<=NF;i++) sum+=$i; print sum}')
    if [ "${CPU_TOTAL:-0}" -gt 0 ]; then
      STEAL_PCT=$((100 * CPU_STEAL / CPU_TOTAL))
      if [ "$STEAL_PCT" -ge 10 ]; then
        crit "CPU steal time: ${STEAL_PCT}% (критично для VPS)"
      elif [ "$STEAL_PCT" -ge 5 ]; then
        warn "CPU steal time: ${STEAL_PCT}% (высоко для VPS)"
      else
        ok "CPU steal time: ${STEAL_PCT}%"
      fi
    fi
  fi

  # Проверка OOM killer activity
  OOM_KILLS=$(dmesg 2>/dev/null | grep -c "Out of memory\|oom-killer" || echo "0")
  if [ "${OOM_KILLS:-0}" -gt 0 ]; then
    warn "OOM killer активность: $OOM_KILLS событий"
  else
    ok "OOM killer активность: 0 событий"
  fi

  # Проверка файлов без владельца
  NOUSER_FILES=$(find / -xdev -nouser 2>/dev/null | wc -l)
  NOGROUP_FILES=$(find / -xdev -nogroup 2>/dev/null | wc -l)
  ORPHAN_FILES=$((NOUSER_FILES + NOGROUP_FILES))
  
  if [ "${ORPHAN_FILES:-0}" -gt 0 ]; then
    warn "Файлов без владельца/группы: $ORPHAN_FILES"
  else
    ok "Файлов без владельца/группы: 0"
  fi


# ========== АНАЛИЗ ФАЙЛОВОЙ СИСТЕМЫ ==========

hdr "Топ-10 файлов по размеру (вся система, исключая /home/bitrix)"
echo "Поиск больших файлов в системе (это может занять время)..."
if command -v find >/dev/null; then
  find / -xdev -type f \
    -not -path "/home/bitrix/*" \
    -not -path "/proc/*" \
    -not -path "/sys/*" \
    -not -path "/dev/*" \
    -not -path "/run/*" \
    -not -path "/tmp/*" \
    -printf "%s %p\n" 2>/dev/null \
    | sort -rn | head -n 10 \
    | awk '{printf "%12.2f MB  %s\n", $1/1024/1024, $2}' || echo "Ошибка поиска файлов"
else
  echo "find не найден"
fi

hdr "Топ-10 файлов по размеру в /home/bitrix"
if [ -d /home/bitrix ]; then
  find /home/bitrix -xdev -type f -printf "%s %p\n" 2>/dev/null \
    | sort -rn | head -n 10 \
    | awk '{printf "%12.2f MB  %s\n", $1/1024/1024, $2}' || echo "Ошибка поиска файлов в /home/bitrix"
else
  echo "/home/bitrix не найден"
fi

hdr "Топ-10 файлов по размеру (общий по всей системе)"
find / -xdev -type f \
  -not -path "/proc/*" \
  -not -path "/sys/*" \
  -not -path "/dev/*" \
  -not -path "/run/*" \
  -not -path "/tmp/*" \
  -printf "%s %p\n" 2>/dev/null \
  | sort -rn | head -n 10 \
  | awk '{printf "%12.2f MB  %s\n", $1/1024/1024, $2}' || echo "Ошибка поиска файлов"

hdr "Большие лог-файлы в /var/log (>100MB, возможно не ротируются)"
if [ -d /var/log ]; then
  echo "Файлы размером более 100MB (исключая atop и sysstat):"
  find /var/log -type f -size +100M \
    -not -path "/var/log/atop/*" \
    -not -path "/var/log/sa/*" \
    -not -path "/var/log/sysstat/*" \
    -printf "%s %p\n" 2>/dev/null \
    | sort -rn \
    | awk '{printf "%12.2f MB  %s\n", $1/1024/1024, $2}' || echo "Больших лог-файлов не найдено"
  
  echo ""
  echo "Статистика: количество файлов по размеру в /var/log (исключая atop/sysstat):"
  echo -n "  10-50 MB: "
  find /var/log -type f -size +10M -size -50M \
    -not -path "/var/log/atop/*" \
    -not -path "/var/log/sa/*" \
    -not -path "/var/log/sysstat/*" \
    2>/dev/null | wc -l
  echo -n "  50-100 MB: "
  find /var/log -type f -size +50M -size -100M \
    -not -path "/var/log/atop/*" \
    -not -path "/var/log/sa/*" \
    -not -path "/var/log/sysstat/*" \
    2>/dev/null | wc -l
  echo -n "  100-500 MB: "
  find /var/log -type f -size +100M -size -500M \
    -not -path "/var/log/atop/*" \
    -not -path "/var/log/sa/*" \
    -not -path "/var/log/sysstat/*" \
    2>/dev/null | wc -l
  echo -n "  >500 MB: "
  find /var/log -type f -size +500M \
    -not -path "/var/log/atop/*" \
    -not -path "/var/log/sa/*" \
    -not -path "/var/log/sysstat/*" \
    2>/dev/null | wc -l
else
  echo "/var/log не найден"
fi

hdr "Лог-файлы из конфигов (вне /var/log)"
echo "Поиск лог-файлов из конфигураций сервисов..."
CONFIG_LOGS=$(find_log_files_from_configs | grep -v "^/var/log/" || true)
if [ -n "$CONFIG_LOGS" ]; then
  echo "Найденные лог-файлы вне /var/log:"
  while IFS= read -r logfile; do
    if [ -f "$logfile" ]; then
      size=$(stat -c '%s' "$logfile" 2>/dev/null || echo "0")
      perms=$(stat -c '%A %U:%G' "$logfile" 2>/dev/null || echo "N/A")
      printf "%12.2f MB  %-20s  %s\n" "$(($size/1024/1024))" "$perms" "$logfile"
      
      # Проверка logrotate
      if grep -R --line-number -F "$logfile" /etc/logrotate.d /etc/logrotate.conf >/dev/null 2>&1; then
        echo "    ✓ logrotate настроен"
      else
        echo "    ⚠ logrotate НЕ настроен"
      fi
    fi
  done <<< "$CONFIG_LOGS"
else
  echo "Лог-файлы вне /var/log не найдены"
fi

hdr "Анализ безопасности - исполняемые файлы в подозрительных местах"
echo "Поиск исполняемых файлов в потенциально опасных каталогах..."
SUSPICIOUS_DIRS=("/root" "/home" "/var/www" "/tmp" "/dev/shm")
EXCLUDE_DIRS=("/var/lib" "/var/cache" "/var/log" "/proc" "/sys" "/dev")

for dir in "${SUSPICIOUS_DIRS[@]}"; do
  if [ -d "$dir" ]; then
    echo "--- Проверка $dir ---"
    find "$dir" -xdev -type f -executable 2>/dev/null | while IFS= read -r file; do
      # Пропускаем системные каталоги
      skip=false
      for exclude in "${EXCLUDE_DIRS[@]}"; do
        if [[ "$file" == "$exclude"* ]]; then
          skip=true
          break
        fi
      done
      [ "$skip" = true ] && continue
      
      # Получаем информацию о файле
      size=$(stat -c '%s' "$file" 2>/dev/null || echo "0")
      perms=$(stat -c '%A %U:%G' "$file" 2>/dev/null || echo "N/A")
      mtime=$(stat -c '%Y' "$file" 2>/dev/null || echo "0")
      mtime_str=$(date -d "@$mtime" "+%Y-%m-%d %H:%M" 2>/dev/null || echo "N/A")
      
      # Пытаемся получить birth time (если поддерживается)
      birth_time=$(stat -c '%W' "$file" 2>/dev/null || echo "0")
      if [ "$birth_time" != "0" ] && [ "$birth_time" != "-" ]; then
        birth_str=$(date -d "@$birth_time" "+%Y-%m-%d %H:%M" 2>/dev/null || echo "N/A")
      else
        birth_str="N/A"
      fi
      
      # Тип файла
      file_type=$(file -b "$file" 2>/dev/null || echo "N/A")
      
      printf "%.2f MB\t%s\t%s\t%s\t%s\n" "$(($size/1024/1024))" "$perms" "$birth_str" "$mtime_str" "$file"
      echo "  Тип: $file_type"
      
      # Для подозрительных файлов вычисляем хеш
      if [ "$size" -gt 1048576 ] || [[ "$file_type" == *"executable"* ]]; then
        if command -v md5sum >/dev/null 2>&1; then
          md5_hash=$(md5sum "$file" 2>/dev/null | cut -d' ' -f1 || echo "N/A")
          echo "  MD5: $md5_hash"
        fi
        if command -v sha256sum >/dev/null 2>&1; then
          sha256_hash=$(sha256sum "$file" 2>/dev/null | cut -d' ' -f1 || echo "N/A")
          echo "  SHA256: $sha256_hash"
        fi
      fi
      echo ""
    done | head -n 50  # Ограничиваем вывод для производительности
  fi
done

hdr "Анализ использования дисков (df -h)"
df -h 2>/dev/null || echo "df не найден"


# ========== ФУТЕР ==========
hdr "Сбор завершен"

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
