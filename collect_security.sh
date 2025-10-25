#!/usr/bin/env bash
# collect_security.sh — комплексный аудит безопасности Linux-системы
# Re-exec in a sterile env to avoid interactive profile/menu scripts being sourced by child shells.
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

set -euo pipefail

# Use shared audit_common.sh for locale management
source "$(dirname -- "${BASH_SOURCE[0]:-$0}")/audit_common.sh"

# Setup locale using common functions
setup_locale

# Check for root privileges
if [ "$EUID" -ne 0 ]; then
    echo "================================================" >&2
    echo "ВНИМАНИЕ: Скрипт запущен БЕЗ root-прав" >&2
    echo "Недоступны:" >&2
    echo "  - /etc/shadow" >&2
    echo "  - Чтение SSH-ключей других пользователей" >&2
    echo "  - Полный список SUID-файлов" >&2
    echo "  - Анализ auditd логов" >&2
    echo "  - Детальный анализ SELinux" >&2
    echo "Для полного аудита запустите: sudo $0 $*" >&2
    echo "================================================" >&2
    echo ""
fi

# Configuration
SECURITY_CHECK_SUID="${SECURITY_CHECK_SUID:-1}"
SECURITY_CHECK_WORLD_WRITABLE="${SECURITY_CHECK_WORLD_WRITABLE:-1}"
SECURITY_SCAN_HOME_DIRS="${SECURITY_SCAN_HOME_DIRS:-1}"
SECURITY_ANALYZE_AUTH_LOGS="${SECURITY_ANALYZE_AUTH_LOGS:-1}"
SECURITY_AUTH_LOG_DAYS="${SECURITY_AUTH_LOG_DAYS:-30}"
SECURITY_CHECK_LYNIS="${SECURITY_CHECK_LYNIS:-1}"
SECURITY_CHECK_AUDITD="${SECURITY_CHECK_AUDITD:-1}"
SECURITY_CHECK_SELINUX="${SECURITY_CHECK_SELINUX:-1}"

# Output directory
TS="$(date +%Y%m%d_%H%M%S)"
WORKDIR="$(mktemp -d "${HOME:-/root}/security_audit_${TS}.XXXXXX" 2>/dev/null || mktemp -d "/tmp/security_audit_${TS}.XXXXXX")"
mkdir -p "$WORKDIR/rootfs/etc" "$WORKDIR/rootfs/home"

# Helper functions
hdr() { printf '==== %s ====\n' "$1"; }
log() { echo "[$(date +%F\ %T)] $*"; }
log_error() { echo "[$(date +%F\ %T)] ERROR: $*" >&2; }
log_warning() { echo "[$(date +%F\ %T)] WARNING: $*" >&2; }
log_info() { echo "[$(date +%F\ %T)] INFO: $*"; }

# Counters for summary
CRITICAL_COUNT=0
WARNING_COUNT=0
INFO_COUNT=0

# Function to increment counters
inc_critical() { ((CRITICAL_COUNT++)); }
inc_warning() { ((WARNING_COUNT++)); }
inc_info() { ((INFO_COUNT++)); }

# Function to check if command exists
have() { command -v "$1" >/dev/null 2>&1; }

# Function to safely read file with error handling
safe_read() {
    local file="$1"
    local output="$2"
    if [ -r "$file" ]; then
        cat "$file" > "$output" 2>/dev/null || echo "Ошибка чтения $file" > "$output"
    else
        echo "Файл недоступен: $file" > "$output"
    fi
}

# Function to analyze users and authentication
analyze_users_auth() {
    log "Анализ пользователей и аутентификации..."
    
    # Analyze /etc/passwd
    hdr "Анализ /etc/passwd" > "$WORKDIR/01_users_passwd.txt"
    if [ -r "/etc/passwd" ]; then
        echo "Общее количество пользователей: $(wc -l < /etc/passwd)" >> "$WORKDIR/01_users_passwd.txt"
        echo "" >> "$WORKDIR/01_users_passwd.txt"
        
        # Users with UID=0 (except root)
        echo "Пользователи с UID=0 (кроме root):" >> "$WORKDIR/01_users_passwd.txt"
        awk -F: '$3==0 && $1!="root" {print $1 ":" $3 ":" $4 ":" $5 ":" $6 ":" $7}' /etc/passwd >> "$WORKDIR/01_users_passwd.txt" || echo "Не найдено" >> "$WORKDIR/01_users_passwd.txt"
        echo "" >> "$WORKDIR/01_users_passwd.txt"
        
        # Users with non-standard shells
        echo "Пользователи с нестандартными shell:" >> "$WORKDIR/01_users_passwd.txt"
        awk -F: '$7!="/bin/bash" && $7!="/bin/sh" && $7!="/usr/bin/bash" && $7!="/usr/bin/sh" && $7!="/bin/false" && $7!="/usr/sbin/nologin" {print $1 ":" $7}' /etc/passwd >> "$WORKDIR/01_users_passwd.txt" || echo "Не найдено" >> "$WORKDIR/01_users_passwd.txt"
        echo "" >> "$WORKDIR/01_users_passwd.txt"
        
        # Users with home directories
        echo "Пользователи с домашними директориями:" >> "$WORKDIR/01_users_passwd.txt"
        awk -F: '$6!="" && $6!="/" {print $1 ":" $6}' /etc/passwd >> "$WORKDIR/01_users_passwd.txt"
        
        # Copy passwd for analysis
        cp /etc/passwd "$WORKDIR/rootfs/etc/passwd" 2>/dev/null || true
    else
        echo "Файл /etc/passwd недоступен" >> "$WORKDIR/01_users_passwd.txt"
        inc_warning
    fi
    
    # Analyze /etc/shadow (if accessible)
    hdr "Анализ политик паролей" > "$WORKDIR/02_shadow_policies.txt"
    if [ -r "/etc/shadow" ]; then
        echo "Анализ политик паролей из /etc/shadow" >> "$WORKDIR/02_shadow_policies.txt"
        echo "" >> "$WORKDIR/02_shadow_policies.txt"
        
        # Users without password (empty password field)
        echo "Пользователи без пароля (пустое поле пароля):" >> "$WORKDIR/02_shadow_policies.txt"
        awk -F: '$2=="" {print $1}' /etc/shadow >> "$WORKDIR/02_shadow_policies.txt" || echo "Не найдено" >> "$WORKDIR/02_shadow_policies.txt"
        if awk -F: '$2=="" {print $1}' /etc/shadow | grep -q .; then
            inc_critical
        fi
        echo "" >> "$WORKDIR/02_shadow_policies.txt"
        
        # Locked accounts
        echo "Заблокированные учетные записи:" >> "$WORKDIR/02_shadow_policies.txt"
        awk -F: '$2 ~ /^!/ {print $1}' /etc/shadow >> "$WORKDIR/02_shadow_policies.txt" || echo "Не найдено" >> "$WORKDIR/02_shadow_policies.txt"
        echo "" >> "$WORKDIR/02_shadow_policies.txt"
        
        # Password aging analysis
        echo "Анализ старения паролей:" >> "$WORKDIR/02_shadow_policies.txt"
        awk -F: '$2!="" && $2!~/^!/ {print $1 ":" $3 ":" $4 ":" $5 ":" $6 ":" $7}' /etc/shadow | while IFS=: read -r user last_changed min_days max_days warn_days inactive; do
            if [ "$max_days" != "" ] && [ "$max_days" != "99999" ]; then
                echo "Пользователь $user: пароль истекает через $max_days дней" >> "$WORKDIR/02_shadow_policies.txt"
            fi
        done
    else
        echo "Файл /etc/shadow недоступен (требуются root права)" >> "$WORKDIR/02_shadow_policies.txt"
        inc_warning
    fi
    
    # Analyze /etc/group
    hdr "Анализ групп" > "$WORKDIR/03_groups.txt"
    if [ -r "/etc/group" ]; then
        echo "Общее количество групп: $(wc -l < /etc/group)" >> "$WORKDIR/03_groups.txt"
        echo "" >> "$WORKDIR/03_groups.txt"
        
        # Groups with GID=0
        echo "Группы с GID=0:" >> "$WORKDIR/03_groups.txt"
        awk -F: '$3==0 {print $1 ":" $3 ":" $4}' /etc/group >> "$WORKDIR/03_groups.txt" || echo "Не найдено" >> "$WORKDIR/03_groups.txt"
        echo "" >> "$WORKDIR/03_groups.txt"
        
        # Groups with members
        echo "Группы с участниками:" >> "$WORKDIR/03_groups.txt"
        awk -F: '$4!="" {print $1 ":" $4}' /etc/group >> "$WORKDIR/03_groups.txt" || echo "Не найдено" >> "$WORKDIR/03_groups.txt"
        
        # Copy group for analysis
        cp /etc/group "$WORKDIR/rootfs/etc/group" 2>/dev/null || true
    else
        echo "Файл /etc/group недоступен" >> "$WORKDIR/03_groups.txt"
        inc_warning
    fi
}

# Function to analyze sudo configuration
analyze_sudo_config() {
    log "Анализ конфигурации sudo..."
    
    hdr "Конфигурация sudo" > "$WORKDIR/04_sudo_config.txt"
    
    # Check main sudoers file
    if [ -r "/etc/sudoers" ]; then
        echo "Основной файл sudoers:" >> "$WORKDIR/04_sudo_config.txt"
        echo "Права на файл: $(stat -c "%a" /etc/sudoers 2>/dev/null || echo "неизвестно")" >> "$WORKDIR/04_sudo_config.txt"
        
        # Check for dangerous NOPASSWD rules
        echo "" >> "$WORKDIR/04_sudo_config.txt"
        echo "Правила NOPASSWD:" >> "$WORKDIR/04_sudo_config.txt"
        grep -E "NOPASSWD" /etc/sudoers 2>/dev/null >> "$WORKDIR/04_sudo_config.txt" || echo "Не найдено" >> "$WORKDIR/04_sudo_config.txt"
        
        # Check for ALL=(ALL) ALL rules
        echo "" >> "$WORKDIR/04_sudo_config.txt"
        echo "Правила с полными правами ALL=(ALL) ALL:" >> "$WORKDIR/04_sudo_config.txt"
        grep -E "ALL.*=.*ALL.*ALL" /etc/sudoers 2>/dev/null >> "$WORKDIR/04_sudo_config.txt" || echo "Не найдено" >> "$WORKDIR/04_sudo_config.txt"
        
        # Copy sudoers for analysis
        cp /etc/sudoers "$WORKDIR/rootfs/etc/sudoers" 2>/dev/null || true
    else
        echo "Файл /etc/sudoers недоступен" >> "$WORKDIR/04_sudo_config.txt"
        inc_warning
    fi
    
    # Check sudoers.d directory
    if [ -d "/etc/sudoers.d" ]; then
        echo "" >> "$WORKDIR/04_sudo_config.txt"
        echo "Файлы в /etc/sudoers.d:" >> "$WORKDIR/04_sudo_config.txt"
        ls -la /etc/sudoers.d/ >> "$WORKDIR/04_sudo_config.txt" 2>/dev/null || echo "Директория недоступна" >> "$WORKDIR/04_sudo_config.txt"
        
        # Analyze each file in sudoers.d
        for file in /etc/sudoers.d/*; do
            if [ -f "$file" ] && [ -r "$file" ]; then
                echo "" >> "$WORKDIR/04_sudo_config.txt"
                echo "=== $(basename "$file") ===" >> "$WORKDIR/04_sudo_config.txt"
                cat "$file" >> "$WORKDIR/04_sudo_config.txt" 2>/dev/null || echo "Ошибка чтения $file" >> "$WORKDIR/04_sudo_config.txt"
            fi
        done
        
        # Copy sudoers.d for analysis
        cp -r /etc/sudoers.d "$WORKDIR/rootfs/etc/" 2>/dev/null || true
    fi
    
    # Check file permissions
    local sudoers_perms
    sudoers_perms=$(stat -c "%a" /etc/sudoers 2>/dev/null || echo "unknown")
    if [ "$sudoers_perms" != "440" ] && [ "$sudoers_perms" != "0440" ]; then
        echo "" >> "$WORKDIR/04_sudo_config.txt"
        echo "[WARNING] Небезопасные права на /etc/sudoers: $sudoers_perms (должны быть 440)" >> "$WORKDIR/04_sudo_config.txt"
        inc_warning
    fi
}

# Function to analyze SSH configuration
analyze_ssh_config() {
    log "Анализ конфигурации SSH..."
    
    hdr "Конфигурация SSH" > "$WORKDIR/05_ssh_config.txt"
    
    # Check SSH daemon configuration
    if [ -r "/etc/ssh/sshd_config" ]; then
        echo "Конфигурация SSH daemon:" >> "$WORKDIR/05_ssh_config.txt"
        echo "" >> "$WORKDIR/05_ssh_config.txt"
        
        # Critical SSH settings
        local ssh_settings=("Port" "PermitRootLogin" "PasswordAuthentication" "PubkeyAuthentication" "Protocol" "X11Forwarding" "AllowUsers" "DenyUsers")
        
        for setting in "${ssh_settings[@]}"; do
            local value
            value=$(grep -E "^$setting" /etc/ssh/sshd_config 2>/dev/null | head -1 || echo "не настроено")
            echo "$setting: $value" >> "$WORKDIR/05_ssh_config.txt"
        done
        
        # Check for dangerous settings
        echo "" >> "$WORKDIR/05_ssh_config.txt"
        echo "Анализ безопасности:" >> "$WORKDIR/05_ssh_config.txt"
        
        # PermitRootLogin check
        if grep -q "PermitRootLogin yes" /etc/ssh/sshd_config 2>/dev/null; then
            echo "[CRITICAL] Root login разрешен!" >> "$WORKDIR/05_ssh_config.txt"
            inc_critical
        elif grep -q "PermitRootLogin no" /etc/ssh/sshd_config 2>/dev/null; then
            echo "[OK] Root login запрещен" >> "$WORKDIR/05_ssh_config.txt"
        else
            echo "[WARNING] PermitRootLogin не настроен явно" >> "$WORKDIR/05_ssh_config.txt"
            inc_warning
        fi
        
        # Password authentication check
        if grep -q "PasswordAuthentication no" /etc/ssh/sshd_config 2>/dev/null; then
            echo "[OK] Аутентификация по паролю отключена" >> "$WORKDIR/05_ssh_config.txt"
        else
            echo "[WARNING] Аутентификация по паролю включена" >> "$WORKDIR/05_ssh_config.txt"
            inc_warning
        fi
        
        # Protocol check
        if grep -q "Protocol 1" /etc/ssh/sshd_config 2>/dev/null; then
            echo "[CRITICAL] Используется устаревший SSH Protocol 1!" >> "$WORKDIR/05_ssh_config.txt"
            inc_critical
        fi
        
        # Copy sshd_config for analysis
        cp /etc/ssh/sshd_config "$WORKDIR/rootfs/etc/ssh/" 2>/dev/null || true
    else
        echo "Файл /etc/ssh/sshd_config недоступен" >> "$WORKDIR/05_ssh_config.txt"
        inc_warning
    fi
    
    # Analyze SSH keys if home directory scanning is enabled
    if [ "$SECURITY_SCAN_HOME_DIRS" = "1" ]; then
        analyze_ssh_keys
    fi
}

# Function to analyze SSH keys
analyze_ssh_keys() {
    log "Анализ SSH-ключей пользователей..."
    
    hdr "SSH-ключи пользователей" > "$WORKDIR/06_ssh_keys.txt"
    
    # Get list of users with home directories
    local users
    users=$(awk -F: '$6!="" && $6!="/" && $7!="/bin/false" && $7!="/usr/sbin/nologin" {print $1 ":" $6}' /etc/passwd 2>/dev/null || true)
    
    if [ -n "$users" ]; then
        echo "$users" | while IFS=: read -r user home_dir; do
            if [ -d "$home_dir/.ssh" ]; then
                echo "" >> "$WORKDIR/06_ssh_keys.txt"
                echo "=== Пользователь: $user ===" >> "$WORKDIR/06_ssh_keys.txt"
                echo "Домашняя директория: $home_dir" >> "$WORKDIR/06_ssh_keys.txt"
                
                # Check .ssh directory permissions
                local ssh_dir_perms
                ssh_dir_perms=$(stat -c "%a" "$home_dir/.ssh" 2>/dev/null || echo "недоступно")
                echo "Права на .ssh: $ssh_dir_perms" >> "$WORKDIR/06_ssh_keys.txt"
                
                if [ "$ssh_dir_perms" != "700" ] && [ "$ssh_dir_perms" != "0700" ]; then
                    echo "[WARNING] Небезопасные права на .ssh директорию: $ssh_dir_perms (должны быть 700)" >> "$WORKDIR/06_ssh_keys.txt"
                    inc_warning
                fi
                
                # Check authorized_keys
                if [ -f "$home_dir/.ssh/authorized_keys" ]; then
                    local auth_keys_perms
                    auth_keys_perms=$(stat -c "%a" "$home_dir/.ssh/authorized_keys" 2>/dev/null || echo "недоступно")
                    echo "Права на authorized_keys: $auth_keys_perms" >> "$WORKDIR/06_ssh_keys.txt"
                    
                    if [ "$auth_keys_perms" != "600" ] && [ "$auth_keys_perms" != "0600" ]; then
                        echo "[WARNING] Небезопасные права на authorized_keys: $auth_keys_perms (должны быть 600)" >> "$WORKDIR/06_ssh_keys.txt"
                        inc_warning
                    fi
                    
                    # Analyze key types
                    echo "Типы ключей:" >> "$WORKDIR/06_ssh_keys.txt"
                    grep -E "^(ssh-rsa|ssh-dss|ssh-ed25519|ecdsa-sha2)" "$home_dir/.ssh/authorized_keys" 2>/dev/null | while read -r line; do
                        local key_type
                        key_type=$(echo "$line" | awk '{print $1}')
                        echo "  $key_type" >> "$WORKDIR/06_ssh_keys.txt"
                        
                        # Check for weak RSA keys
                        if [[ "$key_type" == "ssh-rsa" ]]; then
                            local key_size
                            key_size=$(echo "$line" | awk '{print $2}' | base64 -d 2>/dev/null | wc -c 2>/dev/null || echo "0")
                            if [ "$key_size" -lt 256 ]; then
                                echo "    [WARNING] Слабый RSA ключ (< 2048 бит)" >> "$WORKDIR/06_ssh_keys.txt"
                                inc_warning
                            fi
                        fi
                        
                        # Check for deprecated DSA keys
                        if [[ "$key_type" == "ssh-dss" ]]; then
                            echo "    [WARNING] Устаревший DSA ключ" >> "$WORKDIR/06_ssh_keys.txt"
                            inc_warning
                        fi
                    done
                    
                    # Copy authorized_keys for analysis
                    mkdir -p "$WORKDIR/rootfs/home/$user/.ssh" 2>/dev/null || true
                    cp "$home_dir/.ssh/authorized_keys" "$WORKDIR/rootfs/home/$user/.ssh/" 2>/dev/null || true
                fi
                
                # Check for private keys
                for key_file in "$home_dir/.ssh/id_"*; do
                    if [ -f "$key_file" ]; then
                        local key_perms
                        key_perms=$(stat -c "%a" "$key_file" 2>/dev/null || echo "недоступно")
                        echo "Приватный ключ $(basename "$key_file"): права $key_perms" >> "$WORKDIR/06_ssh_keys.txt"
                        
                        if [ "$key_perms" != "600" ] && [ "$key_perms" != "0600" ]; then
                            echo "[WARNING] Небезопасные права на приватный ключ: $key_perms (должны быть 600)" >> "$WORKDIR/06_ssh_keys.txt"
                            inc_warning
                        fi
                    fi
                done
            fi
        done
    else
        echo "Сканирование домашних директорий отключено" >> "$WORKDIR/06_ssh_keys.txt"
    fi
}

# Function to analyze SUID/SGID files
analyze_suid_sgid() {
    if [ "$SECURITY_CHECK_SUID" != "1" ]; then
        return
    fi
    
    log "Анализ SUID/SGID файлов..."
    
    hdr "SUID/SGID файлы" > "$WORKDIR/07_suid_sgid_files.txt"
    
    # Find SUID files
    echo "SUID файлы:" >> "$WORKDIR/07_suid_sgid_files.txt"
    find / -type f -perm -4000 2>/dev/null | head -50 >> "$WORKDIR/07_suid_sgid_files.txt" || echo "Не найдено или нет доступа" >> "$WORKDIR/07_suid_sgid_files.txt"
    
    echo "" >> "$WORKDIR/07_suid_sgid_files.txt"
    echo "SGID файлы:" >> "$WORKDIR/07_suid_sgid_files.txt"
    find / -type f -perm -2000 2>/dev/null | head -50 >> "$WORKDIR/07_suid_sgid_files.txt" || echo "Не найдено или нет доступа" >> "$WORKDIR/07_suid_sgid_files.txt"
    
    # Count SUID/SGID files
    local suid_count sgid_count
    suid_count=$(find / -type f -perm -4000 2>/dev/null | wc -l || echo "0")
    sgid_count=$(find / -type f -perm -2000 2>/dev/null | wc -l || echo "0")
    
    echo "" >> "$WORKDIR/07_suid_sgid_files.txt"
    echo "Общее количество SUID файлов: $suid_count" >> "$WORKDIR/07_suid_sgid_files.txt"
    echo "Общее количество SGID файлов: $sgid_count" >> "$WORKDIR/07_suid_sgid_files.txt"
    
    # Check for suspicious SUID files
    echo "" >> "$WORKDIR/07_suid_sgid_files.txt"
    echo "Подозрительные SUID файлы (не в стандартных местах):" >> "$WORKDIR/07_suid_sgid_files.txt"
    find / -type f -perm -4000 2>/dev/null | grep -v -E "^(/usr|/bin|/sbin|/lib)" >> "$WORKDIR/07_suid_sgid_files.txt" || echo "Не найдено" >> "$WORKDIR/07_suid_sgid_files.txt"
    
    if [ "$suid_count" -gt 50 ]; then
        inc_warning
    fi
}

# Function to analyze file permissions
analyze_file_permissions() {
    log "Анализ прав доступа к критичным файлам..."
    
    hdr "Права доступа к критичным файлам" > "$WORKDIR/08_file_permissions.txt"
    
    # Critical files and their expected permissions
    local critical_files=(
        "/etc/passwd:644"
        "/etc/shadow:640"
        "/etc/group:644"
        "/etc/gshadow:640"
        "/etc/sudoers:440"
        "/etc/ssh/sshd_config:644"
    )
    
    for file_perm in "${critical_files[@]}"; do
        local file perm
        file=$(echo "$file_perm" | cut -d: -f1)
        perm=$(echo "$file_perm" | cut -d: -f2)
        
        if [ -e "$file" ]; then
            local current_perm
            current_perm=$(stat -c "%a" "$file" 2>/dev/null || echo "недоступно")
            echo "$file: текущие права $current_perm, ожидаемые $perm" >> "$WORKDIR/08_file_permissions.txt"
            
            if [ "$current_perm" != "$perm" ] && [ "$current_perm" != "0$perm" ]; then
                echo "  [WARNING] Неправильные права доступа!" >> "$WORKDIR/08_file_permissions.txt"
                inc_warning
            fi
        else
            echo "$file: файл не найден" >> "$WORKDIR/08_file_permissions.txt"
        fi
    done
}

# Function to analyze world-writable files
analyze_world_writable() {
    if [ "$SECURITY_CHECK_WORLD_WRITABLE" != "1" ]; then
        return
    fi
    
    log "Анализ world-writable файлов..."
    
    hdr "World-writable файлы и директории" > "$WORKDIR/09_world_writable.txt"
    
    # Find world-writable files (excluding /tmp, /var/tmp, /dev/shm)
    echo "World-writable файлы (исключая /tmp, /var/tmp, /dev/shm):" >> "$WORKDIR/09_world_writable.txt"
    find / -type f -perm -002 2>/dev/null | grep -v -E "^(/tmp|/var/tmp|/dev/shm)" | head -50 >> "$WORKDIR/09_world_writable.txt" || echo "Не найдено" >> "$WORKDIR/09_world_writable.txt"
    
    echo "" >> "$WORKDIR/09_world_writable.txt"
    echo "World-writable директории (исключая /tmp, /var/tmp, /dev/shm):" >> "$WORKDIR/09_world_writable.txt"
    find / -type d -perm -002 2>/dev/null | grep -v -E "^(/tmp|/var/tmp|/dev/shm)" | head -50 >> "$WORKDIR/09_world_writable.txt" || echo "Не найдено" >> "$WORKDIR/09_world_writable.txt"
    
    # Count world-writable files
    local world_writable_count
    world_writable_count=$(find / -type f -perm -002 2>/dev/null | grep -v -E "^(/tmp|/var/tmp|/dev/shm)" | wc -l || echo "0")
    
    echo "" >> "$WORKDIR/09_world_writable.txt"
    echo "Общее количество world-writable файлов (исключая временные): $world_writable_count" >> "$WORKDIR/09_world_writable.txt"
    
    if [ "$world_writable_count" -gt 10 ]; then
        inc_warning
    fi
}

# Function to analyze orphaned files
analyze_orphaned_files() {
    log "Анализ файлов без владельца..."
    
    hdr "Файлы без владельца (nouser/nogroup)" > "$WORKDIR/10_orphaned_files.txt"
    
    # Find files with no user
    echo "Файлы без пользователя (nouser):" >> "$WORKDIR/10_orphaned_files.txt"
    find / -nouser 2>/dev/null | head -50 >> "$WORKDIR/10_orphaned_files.txt" || echo "Не найдено" >> "$WORKDIR/10_orphaned_files.txt"
    
    echo "" >> "$WORKDIR/10_orphaned_files.txt"
    echo "Файлы без группы (nogroup):" >> "$WORKDIR/10_orphaned_files.txt"
    find / -nogroup 2>/dev/null | head -50 >> "$WORKDIR/10_orphaned_files.txt" || echo "Не найдено" >> "$WORKDIR/10_orphaned_files.txt"
    
    # Count orphaned files
    local nouser_count nogroup_count
    nouser_count=$(find / -nouser 2>/dev/null | wc -l || echo "0")
    nogroup_count=$(find / -nogroup 2>/dev/null | wc -l || echo "0")
    
    echo "" >> "$WORKDIR/10_orphaned_files.txt"
    echo "Общее количество файлов без пользователя: $nouser_count" >> "$WORKDIR/10_orphaned_files.txt"
    echo "Общее количество файлов без группы: $nogroup_count" >> "$WORKDIR/10_orphaned_files.txt"
    
    if [ "$nouser_count" -gt 0 ] || [ "$nogroup_count" -gt 0 ]; then
        inc_warning
    fi
}

# Function to analyze firewall status (reference to system_info)
analyze_firewall_status() {
    log "Анализ статуса firewall..."
    
    hdr "Статус firewall" > "$WORKDIR/11_firewall_status.txt"
    
    echo "Детальный анализ firewall доступен в collect_system_info.sh" >> "$WORKDIR/11_firewall_status.txt"
    echo "Файл: ~/audit/system_info_audit/sysctl_full_dump.txt" >> "$WORKDIR/11_firewall_status.txt"
    echo "" >> "$WORKDIR/11_firewall_status.txt"
    
    # Quick firewall check
    local firewall_active=0
    
    if have ufw && ufw status 2>/dev/null | grep -q "Status: active"; then
        echo "UFW: активен" >> "$WORKDIR/11_firewall_status.txt"
        firewall_active=1
    elif have firewall-cmd && [ "$(firewall-cmd --state 2>/dev/null)" = "running" ]; then
        echo "firewalld: активен" >> "$WORKDIR/11_firewall_status.txt"
        firewall_active=1
    elif have iptables && iptables -L -n 2>/dev/null | grep -q "ACCEPT\|DROP\|REJECT"; then
        echo "iptables: настроен" >> "$WORKDIR/11_firewall_status.txt"
        firewall_active=1
    else
        echo "Firewall: не активен" >> "$WORKDIR/11_firewall_status.txt"
        inc_critical
    fi
    
    # SSH port analysis
    analyze_ssh_port_firewall
}

# Function to analyze SSH port and firewall rules
analyze_ssh_port_firewall() {
    log "Анализ SSH порта и firewall правил..."
    
    hdr "SSH порт и firewall защита" >> "$WORKDIR/11_firewall_status.txt"
    
    # Detect SSH port
    local ssh_port="22"
    if [ -r "/etc/ssh/sshd_config" ]; then
        local config_port
        config_port=$(grep -E "^Port" /etc/ssh/sshd_config 2>/dev/null | awk '{print $2}' | head -1)
        if [ -n "$config_port" ]; then
            ssh_port="$config_port"
        fi
    fi
    
    echo "SSH порт: $ssh_port" >> "$WORKDIR/11_firewall_status.txt"
    
    # Check if SSH port is open
    if ss -tln 2>/dev/null | grep -q ":$ssh_port "; then
        echo "SSH порт $ssh_port: открыт" >> "$WORKDIR/11_firewall_status.txt"
        
        # Check if SSH is listening on all interfaces
        if ss -tln 2>/dev/null | grep -q "0.0.0.0:$ssh_port "; then
            echo "SSH слушает на всех интерфейсах (0.0.0.0)" >> "$WORKDIR/11_firewall_status.txt"
            inc_warning
        else
            echo "SSH ограничен по интерфейсам" >> "$WORKDIR/11_firewall_status.txt"
        fi
        
        # Check fail2ban status
        if have fail2ban-client; then
            echo "" >> "$WORKDIR/11_firewall_status.txt"
            echo "Fail2ban статус:" >> "$WORKDIR/11_firewall_status.txt"
            fail2ban-client status sshd 2>/dev/null >> "$WORKDIR/11_firewall_status.txt" || echo "Fail2ban не настроен для SSH" >> "$WORKDIR/11_firewall_status.txt"
        fi
    else
        echo "SSH порт $ssh_port: не открыт" >> "$WORKDIR/11_firewall_status.txt"
        inc_warning
    fi
}

# Function to analyze SELinux/AppArmor
analyze_selinux_apparmor() {
    if [ "$SECURITY_CHECK_SELINUX" != "1" ]; then
        return
    fi
    
    log "Анализ SELinux/AppArmor..."
    
    hdr "SELinux/AppArmor анализ" > "$WORKDIR/13_selinux_apparmor.txt"
    
    # SELinux analysis
    if have getenforce; then
        local selinux_status
        selinux_status=$(getenforce 2>/dev/null || echo "недоступно")
        echo "SELinux статус: $selinux_status" >> "$WORKDIR/13_selinux_apparmor.txt"
        
        if [ "$selinux_status" = "Disabled" ]; then
            echo "[WARNING] SELinux отключен" >> "$WORKDIR/13_selinux_apparmor.txt"
            inc_warning
        elif [ "$selinux_status" = "Permissive" ]; then
            echo "[WARNING] SELinux в режиме Permissive" >> "$WORKDIR/13_selinux_apparmor.txt"
            inc_warning
        else
            echo "[OK] SELinux активен в режиме Enforcing" >> "$WORKDIR/13_selinux_apparmor.txt"
        fi
        
        # SELinux policy
        if have sestatus; then
            echo "" >> "$WORKDIR/13_selinux_apparmor.txt"
            echo "SELinux детальная информация:" >> "$WORKDIR/13_selinux_apparmor.txt"
            sestatus >> "$WORKDIR/13_selinux_apparmor.txt" 2>/dev/null || echo "sestatus недоступен" >> "$WORKDIR/13_selinux_apparmor.txt"
        fi
        
        # SELinux violations (last 24 hours)
        if have ausearch; then
            echo "" >> "$WORKDIR/13_selinux_apparmor.txt"
            echo "SELinux нарушения за последние 24 часа:" >> "$WORKDIR/13_selinux_apparmor.txt"
            ausearch -m AVC -ts yesterday 2>/dev/null | wc -l >> "$WORKDIR/13_selinux_apparmor.txt" || echo "0" >> "$WORKDIR/13_selinux_apparmor.txt"
        fi
    else
        echo "SELinux не установлен" >> "$WORKDIR/13_selinux_apparmor.txt"
    fi
    
    # AppArmor analysis
    if have aa-status; then
        echo "" >> "$WORKDIR/13_selinux_apparmor.txt"
        echo "AppArmor статус:" >> "$WORKDIR/13_selinux_apparmor.txt"
        aa-status >> "$WORKDIR/13_selinux_apparmor.txt" 2>/dev/null || echo "AppArmor недоступен" >> "$WORKDIR/13_selinux_apparmor.txt"
    elif [ -d "/sys/kernel/security/apparmor" ]; then
        echo "" >> "$WORKDIR/13_selinux_apparmor.txt"
        echo "AppArmor модуль загружен, но aa-status недоступен" >> "$WORKDIR/13_selinux_apparmor.txt"
    else
        echo "" >> "$WORKDIR/13_selinux_apparmor.txt"
        echo "AppArmor не установлен" >> "$WORKDIR/13_selinux_apparmor.txt"
    fi
}

# Function to analyze authentication logs
analyze_auth_logs() {
    if [ "$SECURITY_ANALYZE_AUTH_LOGS" != "1" ]; then
        return
    fi
    
    log "Анализ логов аутентификации..."
    
    hdr "Логи аутентификации" > "$WORKDIR/14_auth_logs.txt"
    
    # Find auth log files
    local auth_logs=()
    if [ -r "/var/log/auth.log" ]; then
        auth_logs+=("/var/log/auth.log")
    fi
    if [ -r "/var/log/secure" ]; then
        auth_logs+=("/var/log/secure")
    fi
    
    if [ ${#auth_logs[@]} -gt 0 ]; then
        for log_file in "${auth_logs[@]}"; do
            echo "Анализ файла: $log_file" >> "$WORKDIR/14_auth_logs.txt"
            echo "" >> "$WORKDIR/14_auth_logs.txt"
            
            # Failed login attempts
            echo "Неудачные попытки входа за последние $SECURITY_AUTH_LOG_DAYS дней:" >> "$WORKDIR/14_auth_logs.txt"
            grep -i "failed\|invalid\|authentication failure" "$log_file" 2>/dev/null | tail -20 >> "$WORKDIR/14_auth_logs.txt" || echo "Не найдено" >> "$WORKDIR/14_auth_logs.txt"
            
            echo "" >> "$WORKDIR/14_auth_logs.txt"
            echo "Попытки sudo за последние $SECURITY_AUTH_LOG_DAYS дней:" >> "$WORKDIR/14_auth_logs.txt"
            grep -i "sudo" "$log_file" 2>/dev/null | tail -10 >> "$WORKDIR/14_auth_logs.txt" || echo "Не найдено" >> "$WORKDIR/14_auth_logs.txt"
            
            echo "" >> "$WORKDIR/14_auth_logs.txt"
            echo "SSH подключения за последние $SECURITY_AUTH_LOG_DAYS дней:" >> "$WORKDIR/14_auth_logs.txt"
            grep -i "sshd" "$log_file" 2>/dev/null | tail -10 >> "$WORKDIR/14_auth_logs.txt" || echo "Не найдено" >> "$WORKDIR/14_auth_logs.txt"
        done
    else
        echo "Логи аутентификации недоступны" >> "$WORKDIR/14_auth_logs.txt"
        inc_warning
    fi
}

# Function to analyze login history
analyze_login_history() {
    log "Анализ истории входов..."
    
    hdr "История входов" > "$WORKDIR/15_login_history.txt"
    
    # Last successful logins
    if have last; then
        echo "Последние успешные входы:" >> "$WORKDIR/15_login_history.txt"
        last -n 20 >> "$WORKDIR/15_login_history.txt" 2>/dev/null || echo "last недоступен" >> "$WORKDIR/15_login_history.txt"
    fi
    
    echo "" >> "$WORKDIR/15_login_history.txt"
    
    # Failed login attempts
    if have lastb; then
        echo "Неудачные попытки входа:" >> "$WORKDIR/15_login_history.txt"
        lastb -n 20 >> "$WORKDIR/15_login_history.txt" 2>/dev/null || echo "lastb недоступен" >> "$WORKDIR/15_login_history.txt"
    fi
    
    echo "" >> "$WORKDIR/15_login_history.txt"
    
    # Current logged in users
    if have who; then
        echo "Текущие пользователи:" >> "$WORKDIR/15_login_history.txt"
        who >> "$WORKDIR/15_login_history.txt" 2>/dev/null || echo "who недоступен" >> "$WORKDIR/15_login_history.txt"
    fi
    
    echo "" >> "$WORKDIR/15_login_history.txt"
    
    # Wtmp analysis
    if [ -r "/var/log/wtmp" ]; then
        echo "Анализ /var/log/wtmp:" >> "$WORKDIR/15_login_history.txt"
        echo "Размер файла: $(stat -c "%s" /var/log/wtmp) байт" >> "$WORKDIR/15_login_history.txt"
    fi
}

# Function to analyze security packages
analyze_security_packages() {
    log "Анализ установленных пакетов безопасности..."
    
    hdr "Установленные пакеты безопасности" > "$WORKDIR/16_security_packages.txt"
    
    # Security packages to check
    local security_packages=("fail2ban" "aide" "rkhunter" "chkrootkit" "tripwire" "clamav" "lynis")
    
    for package in "${security_packages[@]}"; do
        if have "$package"; then
            echo "[OK] $package: установлен" >> "$WORKDIR/16_security_packages.txt"
            
            # Get package version
            if have dpkg; then
                local version
                version=$(dpkg -l "$package" 2>/dev/null | grep "^ii" | awk '{print $3}' || echo "неизвестно")
                echo "  Версия: $version" >> "$WORKDIR/16_security_packages.txt"
            elif have rpm; then
                local version
                version=$(rpm -q "$package" 2>/dev/null || echo "неизвестно")
                echo "  Версия: $version" >> "$WORKDIR/16_security_packages.txt"
            fi
            
            # Check service status for some packages
            case "$package" in
                "fail2ban")
                    if have systemctl; then
                        local status
                        status=$(systemctl is-active fail2ban 2>/dev/null || echo "неактивен")
                        echo "  Статус службы: $status" >> "$WORKDIR/16_security_packages.txt"
                    fi
                    ;;
                "clamav")
                    if have systemctl; then
                        local status
                        status=$(systemctl is-active clamav-daemon 2>/dev/null || echo "неактивен")
                        echo "  Статус службы: $status" >> "$WORKDIR/16_security_packages.txt"
                    fi
                    ;;
            esac
        else
            echo "[INFO] $package: не установлен" >> "$WORKDIR/16_security_packages.txt"
        fi
    done
    
    # Check for security updates (reference to check_requirements.sh)
    echo "" >> "$WORKDIR/16_security_packages.txt"
    echo "Информация об обновлениях безопасности доступна в check_requirements.sh" >> "$WORKDIR/16_security_packages.txt"
}

# Function to run Lynis audit
run_lynis_audit() {
    if [ "$SECURITY_CHECK_LYNIS" != "1" ] || ! have lynis; then
        return
    fi
    
    log "Запуск Lynis аудита..."
    
    hdr "Lynis аудит безопасности" > "$WORKDIR/lynis_audit.txt"
    
    # Run Lynis in quiet mode
    lynis audit system --quiet --no-colors 2>/dev/null >> "$WORKDIR/lynis_audit.txt" || echo "Lynis завершился с ошибкой" >> "$WORKDIR/lynis_audit.txt"
    
    # Extract hardening index
    local hardening_index
    hardening_index=$(grep "Hardening index" "$WORKDIR/lynis_audit.txt" 2>/dev/null | tail -1 || echo "не найден")
    echo "" >> "$WORKDIR/lynis_audit.txt"
    echo "Hardening Index: $hardening_index" >> "$WORKDIR/lynis_audit.txt"
    
    # Extract warnings
    echo "" >> "$WORKDIR/lynis_audit.txt"
    echo "Предупреждения Lynis:" >> "$WORKDIR/lynis_audit.txt"
    grep -i "warning\|suggestion" "$WORKDIR/lynis_audit.txt" 2>/dev/null | head -10 >> "$WORKDIR/lynis_audit.txt" || echo "Предупреждения не найдены" >> "$WORKDIR/lynis_audit.txt"
}

# Function to analyze auditd
analyze_auditd() {
    if [ "$SECURITY_CHECK_AUDITD" != "1" ]; then
        return
    fi
    
    log "Анализ auditd..."
    
    hdr "Auditd анализ" > "$WORKDIR/auditd_analysis.txt"
    
    # Check auditd service status
    if have systemctl; then
        local auditd_status
        auditd_status=$(systemctl is-active auditd 2>/dev/null || echo "неактивен")
        echo "Auditd статус службы: $auditd_status" >> "$WORKDIR/auditd_analysis.txt"
        
        if [ "$auditd_status" != "active" ]; then
            echo "[WARNING] Auditd не активен" >> "$WORKDIR/auditd_analysis.txt"
            inc_warning
        fi
    fi
    
    # Check audit rules
    if have auditctl; then
        echo "" >> "$WORKDIR/auditd_analysis.txt"
        echo "Правила аудита:" >> "$WORKDIR/auditd_analysis.txt"
        auditctl -l >> "$WORKDIR/auditd_analysis.txt" 2>/dev/null || echo "Правила недоступны" >> "$WORKDIR/auditd_analysis.txt"
    fi
    
    # Check audit log size
    if [ -r "/var/log/audit/audit.log" ]; then
        local log_size
        log_size=$(stat -c "%s" /var/log/audit/audit.log 2>/dev/null || echo "0")
        echo "" >> "$WORKDIR/auditd_analysis.txt"
        echo "Размер лога аудита: $log_size байт" >> "$WORKDIR/auditd_analysis.txt"
        
        if [ "$log_size" -gt 104857600 ]; then  # 100MB
            echo "[WARNING] Лог аудита очень большой (>100MB)" >> "$WORKDIR/auditd_analysis.txt"
            inc_warning
        fi
    fi
    
    # Recent audit events
    if have ausearch; then
        echo "" >> "$WORKDIR/auditd_analysis.txt"
        echo "Последние события аудита:" >> "$WORKDIR/auditd_analysis.txt"
        ausearch -m ALL -ts today 2>/dev/null | head -10 >> "$WORKDIR/auditd_analysis.txt" || echo "События не найдены" >> "$WORKDIR/auditd_analysis.txt"
    fi
}

# Function to analyze kernel security parameters
analyze_kernel_security() {
    log "Анализ параметров безопасности ядра..."
    
    hdr "Параметры безопасности ядра" > "$WORKDIR/kernel_security.txt"
    
    # Security-related sysctl parameters
    local security_params=(
        "kernel.dmesg_restrict:1"
        "kernel.kptr_restrict:2"
        "kernel.yama.ptrace_scope:1"
        "kernel.unprivileged_bpf_disabled:1"
        "kernel.unprivileged_userns_clone:0"
        "net.ipv4.conf.all.rp_filter:1"
        "net.ipv4.conf.all.accept_source_route:0"
        "net.ipv4.icmp_echo_ignore_broadcasts:1"
        "net.ipv4.tcp_syncookies:1"
        "fs.suid_dumpable:0"
    )
    
    for param_value in "${security_params[@]}"; do
        local param expected
        param=$(echo "$param_value" | cut -d: -f1)
        expected=$(echo "$param_value" | cut -d: -f2)
        
        local current
        current=$(sysctl -n "$param" 2>/dev/null || echo "недоступен")
        
        echo "$param: текущее=$current, ожидаемое=$expected" >> "$WORKDIR/kernel_security.txt"
        
        if [ "$current" != "$expected" ] && [ "$current" != "недоступен" ]; then
            echo "  [WARNING] Небезопасное значение!" >> "$WORKDIR/kernel_security.txt"
            inc_warning
        fi
    done
    
    # Kernel modules analysis
    echo "" >> "$WORKDIR/kernel_security.txt"
    echo "Загруженные модули ядра:" >> "$WORKDIR/kernel_security.txt"
    lsmod | head -20 >> "$WORKDIR/kernel_security.txt" 2>/dev/null || echo "lsmod недоступен" >> "$WORKDIR/kernel_security.txt"
    
    # Check for suspicious modules
    echo "" >> "$WORKDIR/kernel_security.txt"
    echo "Подозрительные модули (не в стандартных местах):" >> "$WORKDIR/kernel_security.txt"
    lsmod | awk '{print $1}' | grep -v -E "^(Module|ext4|xfs|nfs|ipv6|tcp|udp)" >> "$WORKDIR/kernel_security.txt" || echo "Не найдено" >> "$WORKDIR/kernel_security.txt"
}

# Function to analyze journald
analyze_journald() {
    log "Анализ journald и системных событий..."
    
    hdr "Journald и системное логирование" > "$WORKDIR/19_journald_analysis.txt"
    
    # Journald configuration
    if [ -r "/etc/systemd/journald.conf" ]; then
        echo "Конфигурация journald:" >> "$WORKDIR/19_journald_analysis.txt"
        grep -v "^#" /etc/systemd/journald.conf | grep -v "^$" >> "$WORKDIR/19_journald_analysis.txt" 2>/dev/null || echo "Конфигурация по умолчанию" >> "$WORKDIR/19_journald_analysis.txt"
        echo "" >> "$WORKDIR/19_journald_analysis.txt"
    fi
    
    # Check persistent storage
    if [ -d "/var/log/journal" ]; then
        echo "Persistent storage: включен" >> "$WORKDIR/19_journald_analysis.txt"
        local journal_size
        journal_size=$(du -sh /var/log/journal 2>/dev/null | cut -f1 || echo "неизвестно")
        echo "Размер журналов: $journal_size" >> "$WORKDIR/19_journald_analysis.txt"
    else
        echo "Persistent storage: отключен (volatile)" >> "$WORKDIR/19_journald_analysis.txt"
        inc_warning
    fi
    
    echo "" >> "$WORKDIR/19_journald_analysis.txt"
    
    # Critical events in last 24 hours
    if have journalctl; then
        echo "Критичные события за последние 24 часа:" >> "$WORKDIR/19_journald_analysis.txt"
        echo "" >> "$WORKDIR/19_journald_analysis.txt"
        
        # Authentication errors
        echo "=== Ошибки аутентификации ===" >> "$WORKDIR/19_journald_analysis.txt"
        journalctl --since "24 hours ago" -p err -t sshd -t su -t sudo 2>/dev/null | tail -10 >> "$WORKDIR/19_journald_analysis.txt" || echo "Не найдено" >> "$WORKDIR/19_journald_analysis.txt"
        echo "" >> "$WORKDIR/19_journald_analysis.txt"
        
        # Kernel panics/oops
        echo "=== Kernel panics/oops ===" >> "$WORKDIR/19_journald_analysis.txt"
        journalctl --since "24 hours ago" -k -p emerg,alert,crit 2>/dev/null | tail -10 >> "$WORKDIR/19_journald_analysis.txt" || echo "Не найдено" >> "$WORKDIR/19_journald_analysis.txt"
        echo "" >> "$WORKDIR/19_journald_analysis.txt"
        
        # OOM killer events
        echo "=== OOM killer события ===" >> "$WORKDIR/19_journald_analysis.txt"
        journalctl --since "24 hours ago" | grep -i "out of memory\|oom" 2>/dev/null | tail -10 >> "$WORKDIR/19_journald_analysis.txt" || echo "Не найдено" >> "$WORKDIR/19_journald_analysis.txt"
        echo "" >> "$WORKDIR/19_journald_analysis.txt"
        
        # Segmentation faults
        echo "=== Segmentation faults ===" >> "$WORKDIR/19_journald_analysis.txt"
        journalctl --since "24 hours ago" | grep -i "segfault\|segmentation fault" 2>/dev/null | tail -10 >> "$WORKDIR/19_journald_analysis.txt" || echo "Не найдено" >> "$WORKDIR/19_journald_analysis.txt"
        echo "" >> "$WORKDIR/19_journald_analysis.txt"
    fi
    
    # Failed systemd units
    if have systemctl; then
        echo "=== Failed systemd units ===" >> "$WORKDIR/19_journald_analysis.txt"
        systemctl --failed --no-pager >> "$WORKDIR/19_journald_analysis.txt" 2>/dev/null || echo "Нет failed units" >> "$WORKDIR/19_journald_analysis.txt"
        echo "" >> "$WORKDIR/19_journald_analysis.txt"
    fi
    
    # Check rsyslog/syslog-ng
    echo "=== Syslog конфигурация ===" >> "$WORKDIR/19_journald_analysis.txt"
    if have rsyslogd && [ -r "/etc/rsyslog.conf" ]; then
        echo "rsyslog: установлен" >> "$WORKDIR/19_journald_analysis.txt"
    elif have syslog-ng && [ -r "/etc/syslog-ng/syslog-ng.conf" ]; then
        echo "syslog-ng: установлен" >> "$WORKDIR/19_journald_analysis.txt"
    else
        echo "Дополнительный syslog: не найден" >> "$WORKDIR/19_journald_analysis.txt"
    fi
}

# Function to analyze PAM configuration
analyze_pam_config() {
    log "Анализ конфигурации PAM..."
    
    hdr "PAM конфигурация" > "$WORKDIR/20_pam_config.txt"
    
    if [ -d "/etc/pam.d" ]; then
        echo "Анализ PAM модулей:" >> "$WORKDIR/20_pam_config.txt"
        echo "" >> "$WORKDIR/20_pam_config.txt"
        
        # Check password quality
        echo "=== Политики паролей (pam_pwquality/pam_cracklib) ===" >> "$WORKDIR/20_pam_config.txt"
        if [ -r "/etc/security/pwquality.conf" ]; then
            grep -v "^#" /etc/security/pwquality.conf | grep -v "^$" >> "$WORKDIR/20_pam_config.txt" 2>/dev/null || echo "Конфигурация по умолчанию" >> "$WORKDIR/20_pam_config.txt"
        else
            echo "pwquality.conf не найден" >> "$WORKDIR/20_pam_config.txt"
        fi
        echo "" >> "$WORKDIR/20_pam_config.txt"
        
        # Check faillock/tally2
        echo "=== Блокировка аккаунтов (pam_faillock/pam_tally2) ===" >> "$WORKDIR/20_pam_config.txt"
        if grep -r "pam_faillock" /etc/pam.d/ 2>/dev/null | head -5 >> "$WORKDIR/20_pam_config.txt"; then
            echo "pam_faillock: настроен" >> "$WORKDIR/20_pam_config.txt"
        elif grep -r "pam_tally2" /etc/pam.d/ 2>/dev/null | head -5 >> "$WORKDIR/20_pam_config.txt"; then
            echo "pam_tally2: настроен" >> "$WORKDIR/20_pam_config.txt"
        else
            echo "Блокировка аккаунтов: не настроена" >> "$WORKDIR/20_pam_config.txt"
            inc_warning
        fi
        echo "" >> "$WORKDIR/20_pam_config.txt"
        
        # Check limits
        echo "=== Ограничения ресурсов (pam_limits) ===" >> "$WORKDIR/20_pam_config.txt"
        if [ -r "/etc/security/limits.conf" ]; then
            grep -v "^#" /etc/security/limits.conf | grep -v "^$" | head -10 >> "$WORKDIR/20_pam_config.txt" 2>/dev/null || echo "Конфигурация по умолчанию" >> "$WORKDIR/20_pam_config.txt"
        else
            echo "limits.conf не найден" >> "$WORKDIR/20_pam_config.txt"
        fi
    else
        echo "Директория /etc/pam.d недоступна" >> "$WORKDIR/20_pam_config.txt"
        inc_warning
    fi
}

# Function to analyze login.defs
analyze_login_defs() {
    log "Анализ login.defs..."
    
    hdr "Login.defs конфигурация" > "$WORKDIR/21_login_defs.txt"
    
    if [ -r "/etc/login.defs" ]; then
        echo "Критичные параметры из /etc/login.defs:" >> "$WORKDIR/21_login_defs.txt"
        echo "" >> "$WORKDIR/21_login_defs.txt"
        
        # Password aging
        echo "=== Параметры старения паролей ===" >> "$WORKDIR/21_login_defs.txt"
        grep -E "^PASS_MAX_DAYS|^PASS_MIN_DAYS|^PASS_WARN_AGE" /etc/login.defs >> "$WORKDIR/21_login_defs.txt" 2>/dev/null || echo "Не настроено" >> "$WORKDIR/21_login_defs.txt"
        echo "" >> "$WORKDIR/21_login_defs.txt"
        
        # UID/GID ranges
        echo "=== Диапазоны UID/GID ===" >> "$WORKDIR/21_login_defs.txt"
        grep -E "^UID_MIN|^UID_MAX|^GID_MIN|^GID_MAX" /etc/login.defs >> "$WORKDIR/21_login_defs.txt" 2>/dev/null || echo "Не настроено" >> "$WORKDIR/21_login_defs.txt"
        echo "" >> "$WORKDIR/21_login_defs.txt"
        
        # Umask
        echo "=== Umask ===" >> "$WORKDIR/21_login_defs.txt"
        grep -E "^UMASK|^USERGROUPS_ENAB" /etc/login.defs >> "$WORKDIR/21_login_defs.txt" 2>/dev/null || echo "Не настроено" >> "$WORKDIR/21_login_defs.txt"
        echo "" >> "$WORKDIR/21_login_defs.txt"
        
        # Encryption method
        echo "=== Метод шифрования ===" >> "$WORKDIR/21_login_defs.txt"
        grep -E "^ENCRYPT_METHOD" /etc/login.defs >> "$WORKDIR/21_login_defs.txt" 2>/dev/null || echo "Не настроено" >> "$WORKDIR/21_login_defs.txt"
        
        # Copy login.defs
        cp /etc/login.defs "$WORKDIR/rootfs/etc/" 2>/dev/null || true
    else
        echo "Файл /etc/login.defs недоступен" >> "$WORKDIR/21_login_defs.txt"
        inc_warning
    fi
}

# Function to check additional security items
analyze_additional_security() {
    log "Дополнительные проверки безопасности..."
    
    hdr "Дополнительные проверки безопасности" > "$WORKDIR/22_additional_checks.txt"
    
    # Temporary directories mount options
    echo "=== Опции монтирования временных директорий ===" >> "$WORKDIR/22_additional_checks.txt"
    for dir in "/tmp" "/var/tmp" "/dev/shm"; do
        if mount | grep -q " $dir "; then
            local mount_opts
            mount_opts=$(mount | grep " $dir " | sed 's/.*(\(.*\))/\1/')
            echo "$dir: $mount_opts" >> "$WORKDIR/22_additional_checks.txt"
            
            # Check for security options
            if echo "$mount_opts" | grep -q "noexec"; then
                echo "  ✓ noexec установлен" >> "$WORKDIR/22_additional_checks.txt"
            else
                echo "  [WARNING] noexec не установлен" >> "$WORKDIR/22_additional_checks.txt"
                inc_warning
            fi
            
            if echo "$mount_opts" | grep -q "nosuid"; then
                echo "  ✓ nosuid установлен" >> "$WORKDIR/22_additional_checks.txt"
            else
                echo "  [WARNING] nosuid не установлен" >> "$WORKDIR/22_additional_checks.txt"
                inc_warning
            fi
        else
            echo "$dir: не смонтирован отдельно" >> "$WORKDIR/22_additional_checks.txt"
        fi
    done
    echo "" >> "$WORKDIR/22_additional_checks.txt"
    
    # Compilers on production
    echo "=== Компиляторы и dev-tools ===" >> "$WORKDIR/22_additional_checks.txt"
    local compilers=("gcc" "g++" "make" "cc" "clang")
    local found_compilers=()
    for compiler in "${compilers[@]}"; do
        if have "$compiler"; then
            found_compilers+=("$compiler")
        fi
    done
    
    if [ ${#found_compilers[@]} -gt 0 ]; then
        echo "Найдены компиляторы: ${found_compilers[*]}" >> "$WORKDIR/22_additional_checks.txt"
        echo "[WARNING] Рекомендуется удалить компиляторы на production-серверах" >> "$WORKDIR/22_additional_checks.txt"
        inc_warning
    else
        echo "Компиляторы не найдены" >> "$WORKDIR/22_additional_checks.txt"
    fi
    echo "" >> "$WORKDIR/22_additional_checks.txt"
    
    # Suspicious processes
    echo "=== Подозрительные процессы ===" >> "$WORKDIR/22_additional_checks.txt"
    if have ps; then
        # Root processes with network connections
        echo "Root процессы с сетевыми соединениями:" >> "$WORKDIR/22_additional_checks.txt"
        ps aux | awk '$1=="root"' | head -20 >> "$WORKDIR/22_additional_checks.txt" 2>/dev/null || echo "Не найдено" >> "$WORKDIR/22_additional_checks.txt"
        echo "" >> "$WORKDIR/22_additional_checks.txt"
        
        # Processes without executable (deleted)
        echo "Процессы без исполняемого файла (deleted):" >> "$WORKDIR/22_additional_checks.txt"
        ls -l /proc/*/exe 2>/dev/null | grep deleted | head -10 >> "$WORKDIR/22_additional_checks.txt" || echo "Не найдено" >> "$WORKDIR/22_additional_checks.txt"
    fi
    echo "" >> "$WORKDIR/22_additional_checks.txt"
    
    # Immutable files
    echo "=== Immutable файлы ===" >> "$WORKDIR/22_additional_checks.txt"
    if have lsattr; then
        echo "Критичные файлы с атрибутом immutable:" >> "$WORKDIR/22_additional_checks.txt"
        for file in "/etc/passwd" "/etc/shadow" "/etc/group" "/etc/sudoers"; do
            if [ -e "$file" ]; then
                local attrs
                attrs=$(lsattr "$file" 2>/dev/null | awk '{print $1}')
                echo "$file: $attrs" >> "$WORKDIR/22_additional_checks.txt"
            fi
        done
    else
        echo "lsattr недоступен" >> "$WORKDIR/22_additional_checks.txt"
    fi
    echo "" >> "$WORKDIR/22_additional_checks.txt"
    
    # Capabilities
    echo "=== Linux Capabilities ===" >> "$WORKDIR/22_additional_checks.txt"
    if have getcap; then
        echo "Файлы с capabilities:" >> "$WORKDIR/22_additional_checks.txt"
        getcap -r / 2>/dev/null | head -20 >> "$WORKDIR/22_additional_checks.txt" || echo "Не найдено" >> "$WORKDIR/22_additional_checks.txt"
        
        # Check for dangerous capabilities
        echo "" >> "$WORKDIR/22_additional_checks.txt"
        echo "Опасные capabilities (CAP_SYS_ADMIN, CAP_NET_RAW):" >> "$WORKDIR/22_additional_checks.txt"
        getcap -r / 2>/dev/null | grep -E "cap_sys_admin|cap_net_raw" >> "$WORKDIR/22_additional_checks.txt" || echo "Не найдено" >> "$WORKDIR/22_additional_checks.txt"
    else
        echo "getcap недоступен" >> "$WORKDIR/22_additional_checks.txt"
    fi
}

# Function to analyze open ports (brief summary)
analyze_open_ports_summary() {
    log "Анализ открытых портов..."
    
    hdr "Открытые порты (краткая сводка)" > "$WORKDIR/12_open_ports.txt"
    
    echo "Детальный анализ портов доступен в collect_system_info.sh" >> "$WORKDIR/12_open_ports.txt"
    echo "" >> "$WORKDIR/12_open_ports.txt"
    
    # Quick summary of listening ports
    if have ss; then
        echo "Слушающие порты:" >> "$WORKDIR/12_open_ports.txt"
        ss -tlnp 2>/dev/null | grep LISTEN | head -20 >> "$WORKDIR/12_open_ports.txt" || echo "Не найдено" >> "$WORKDIR/12_open_ports.txt"
    elif have netstat; then
        echo "Слушающие порты:" >> "$WORKDIR/12_open_ports.txt"
        netstat -tlnp 2>/dev/null | grep LISTEN | head -20 >> "$WORKDIR/12_open_ports.txt" || echo "Не найдено" >> "$WORKDIR/12_open_ports.txt"
    else
        echo "ss/netstat недоступны" >> "$WORKDIR/12_open_ports.txt"
    fi
}

# Function to check package vulnerabilities (CVE)
analyze_package_vulnerabilities() {
    log "Анализ уязвимостей пакетов (CVE)..."
    
    hdr "Уязвимости пакетов (CVE)" > "$WORKDIR/23_package_vulnerabilities.txt"
    
    # Debian/Ubuntu: debsecan
    if have debsecan; then
        echo "=== Debsecan анализ ===" >> "$WORKDIR/23_package_vulnerabilities.txt"
        debsecan --suite $(lsb_release -cs) 2>/dev/null | head -20 >> "$WORKDIR/23_package_vulnerabilities.txt" || echo "Ошибка запуска debsecan" >> "$WORKDIR/23_package_vulnerabilities.txt"
        echo "" >> "$WORKDIR/23_package_vulnerabilities.txt"
        
        # Count vulnerabilities by severity
        local cve_count
        cve_count=$(debsecan --suite $(lsb_release -cs) 2>/dev/null | wc -l || echo "0")
        echo "Всего уязвимостей: $cve_count" >> "$WORKDIR/23_package_vulnerabilities.txt"
        
        if [ "$cve_count" -gt 0 ]; then
            inc_warning
        fi
    elif have apt; then
        echo "debsecan не установлен (рекомендуется установить)" >> "$WORKDIR/23_package_vulnerabilities.txt"
        echo "Установка: apt-get install debsecan" >> "$WORKDIR/23_package_vulnerabilities.txt"
        echo "" >> "$WORKDIR/23_package_vulnerabilities.txt"
    fi
    
    # RHEL/CentOS: yum/dnf updateinfo
    if have dnf; then
        echo "=== DNF updateinfo CVEs ===" >> "$WORKDIR/23_package_vulnerabilities.txt"
        dnf updateinfo list cves 2>/dev/null | head -20 >> "$WORKDIR/23_package_vulnerabilities.txt" || echo "Нет CVE информации" >> "$WORKDIR/23_package_vulnerabilities.txt"
        echo "" >> "$WORKDIR/23_package_vulnerabilities.txt"
        
        # Count CVEs
        local cve_count
        cve_count=$(dnf updateinfo list cves 2>/dev/null | wc -l || echo "0")
        echo "Всего CVE: $cve_count" >> "$WORKDIR/23_package_vulnerabilities.txt"
        
        if [ "$cve_count" -gt 0 ]; then
            inc_warning
        fi
    elif have yum; then
        echo "=== YUM updateinfo CVEs ===" >> "$WORKDIR/23_package_vulnerabilities.txt"
        yum updateinfo list cves 2>/dev/null | head -20 >> "$WORKDIR/23_package_vulnerabilities.txt" || echo "Нет CVE информации" >> "$WORKDIR/23_package_vulnerabilities.txt"
        echo "" >> "$WORKDIR/23_package_vulnerabilities.txt"
        
        # Count CVEs
        local cve_count
        cve_count=$(yum updateinfo list cves 2>/dev/null | wc -l || echo "0")
        echo "Всего CVE: $cve_count" >> "$WORKDIR/23_package_vulnerabilities.txt"
        
        if [ "$cve_count" -gt 0 ]; then
            inc_warning
        fi
    fi
    
    # Reference to check_requirements.sh
    echo "" >> "$WORKDIR/23_package_vulnerabilities.txt"
    echo "Информация об обновлениях безопасности доступна в check_requirements.sh" >> "$WORKDIR/23_package_vulnerabilities.txt"
}

# Function to generate security issues summary
generate_security_issues() {
    log "Генерация сводки проблем безопасности..."
    
    hdr "Обнаруженные проблемы безопасности" > "$WORKDIR/17_security_issues.txt"
    
    echo "Критичные проблемы: $CRITICAL_COUNT" >> "$WORKDIR/17_security_issues.txt"
    echo "Предупреждения: $WARNING_COUNT" >> "$WORKDIR/17_security_issues.txt"
    echo "Информационные: $INFO_COUNT" >> "$WORKDIR/17_security_issues.txt"
    echo "" >> "$WORKDIR/17_security_issues.txt"
    
    # Collect all issues from different files
    echo "Детальные проблемы:" >> "$WORKDIR/17_security_issues.txt"
    echo "" >> "$WORKDIR/17_security_issues.txt"
    
    for file in "$WORKDIR"/*.txt; do
        if [ -f "$file" ] && [ "$(basename "$file")" != "17_security_issues.txt" ]; then
            local filename
            filename=$(basename "$file")
            echo "=== $filename ===" >> "$WORKDIR/17_security_issues.txt"
            grep -E "\[(CRITICAL|WARNING|OK|INFO)\]" "$file" >> "$WORKDIR/17_security_issues.txt" 2>/dev/null || echo "Проблемы не найдены" >> "$WORKDIR/17_security_issues.txt"
            echo "" >> "$WORKDIR/17_security_issues.txt"
        fi
    done
}

# Function to generate security recommendations
generate_security_recommendations() {
    log "Генерация рекомендаций по безопасности..."
    
    hdr "Рекомендации по безопасности" > "$WORKDIR/18_security_recommendations.txt"
    
    echo "Приоритетные рекомендации:" >> "$WORKDIR/18_security_recommendations.txt"
    echo "" >> "$WORKDIR/18_security_recommendations.txt"
    
    # Critical recommendations
    if [ "$CRITICAL_COUNT" -gt 0 ]; then
        echo "[КРИТИЧНО] Немедленно устраните критические проблемы:" >> "$WORKDIR/18_security_recommendations.txt"
        echo "1. Отключите root login через SSH" >> "$WORKDIR/18_security_recommendations.txt"
        echo "2. Установите пароли для всех пользователей" >> "$WORKDIR/18_security_recommendations.txt"
        echo "3. Включите firewall" >> "$WORKDIR/18_security_recommendations.txt"
        echo "4. Исправьте права доступа к критичным файлам" >> "$WORKDIR/18_security_recommendations.txt"
        echo "" >> "$WORKDIR/18_security_recommendations.txt"
    fi
    
    # Warning recommendations
    if [ "$WARNING_COUNT" -gt 0 ]; then
        echo "[ВНИМАНИЕ] Рассмотрите устранение предупреждений:" >> "$WORKDIR/18_security_recommendations.txt"
        echo "1. Отключите аутентификацию по паролю SSH" >> "$WORKDIR/18_security_recommendations.txt"
        echo "2. Включите SELinux/AppArmor" >> "$WORKDIR/18_security_recommendations.txt"
        echo "3. Удалите ненужные SUID/SGID файлы" >> "$WORKDIR/18_security_recommendations.txt"
        echo "4. Настройте auditd" >> "$WORKDIR/18_security_recommendations.txt"
        echo "5. Обновите слабые SSH ключи" >> "$WORKDIR/18_security_recommendations.txt"
        echo "" >> "$WORKDIR/18_security_recommendations.txt"
    fi
    
    # General recommendations
    echo "[ОБЩИЕ] Рекомендации по улучшению безопасности:" >> "$WORKDIR/18_security_recommendations.txt"
    echo "1. Регулярно обновляйте систему" >> "$WORKDIR/18_security_recommendations.txt"
    echo "2. Используйте fail2ban для защиты SSH" >> "$WORKDIR/18_security_recommendations.txt"
    echo "3. Настройте мониторинг логов" >> "$WORKDIR/18_security_recommendations.txt"
    echo "4. Проводите регулярные аудиты безопасности" >> "$WORKDIR/18_security_recommendations.txt"
    echo "5. Используйте сильные пароли и SSH ключи" >> "$WORKDIR/18_security_recommendations.txt"
    echo "6. Ограничьте сетевой доступ к сервисам" >> "$WORKDIR/18_security_recommendations.txt"
}

# Function to generate summary
generate_summary() {
    log "Генерация сводки аудита безопасности..."
    
    cat > "$WORKDIR/SUMMARY_security.txt" << EOF
===== Security Audit Summary =====
Host: $HOST
Date: $(date)
Version: 1.0.0

CRITICAL ISSUES: $CRITICAL_COUNT
WARNINGS: $WARNING_COUNT
INFO: $INFO_COUNT

Файлы отчета:
$(ls -1 "$WORKDIR"/*.txt | sed 's|.*/||' | sed 's/^/- /')

Архив: $WORKDIR.tgz
EOF
    
    # Add critical issues to summary
    if [ "$CRITICAL_COUNT" -gt 0 ]; then
        echo "" >> "$WORKDIR/SUMMARY_security.txt"
        echo "КРИТИЧНЫЕ ПРОБЛЕМЫ:" >> "$WORKDIR/SUMMARY_security.txt"
        grep -h "\[CRITICAL\]" "$WORKDIR"/*.txt 2>/dev/null | head -5 >> "$WORKDIR/SUMMARY_security.txt" || echo "Детали в файлах отчета" >> "$WORKDIR/SUMMARY_security.txt"
    fi
    
    # Add warnings to summary
    if [ "$WARNING_COUNT" -gt 0 ]; then
        echo "" >> "$WORKDIR/SUMMARY_security.txt"
        echo "ПРЕДУПРЕЖДЕНИЯ:" >> "$WORKDIR/SUMMARY_security.txt"
        grep -h "\[WARNING\]" "$WORKDIR"/*.txt 2>/dev/null | head -5 >> "$WORKDIR/SUMMARY_security.txt" || echo "Детали в файлах отчета" >> "$WORKDIR/SUMMARY_security.txt"
    fi
}

# Main execution
main() {
    log "Запуск аудита безопасности системы..."
    log "Рабочая директория: $WORKDIR"
    
    # Create output directory
    mkdir -p "$WORKDIR"
    
    # Run all analysis functions
    analyze_users_auth
    analyze_sudo_config
    analyze_ssh_config
    analyze_suid_sgid
    analyze_file_permissions
    analyze_world_writable
    analyze_orphaned_files
    analyze_firewall_status
    analyze_open_ports_summary
    analyze_selinux_apparmor
    analyze_auth_logs
    analyze_login_history
    analyze_security_packages
    analyze_package_vulnerabilities
    run_lynis_audit
    analyze_auditd
    analyze_journald
    analyze_pam_config
    analyze_login_defs
    analyze_kernel_security
    analyze_additional_security
    
    # Generate reports
    generate_security_issues
    generate_security_recommendations
    generate_summary
    
    log "Аудит безопасности завершен"
    log "Критичных проблем: $CRITICAL_COUNT"
    log "Предупреждений: $WARNING_COUNT"
    log "Информационных: $INFO_COUNT"
    
    # Copy summary to central audit directory
    SUMMARY_COPY="$AUDIT_DIR/security_summary.log"
    if [ -f "$WORKDIR/SUMMARY_security.txt" ]; then
        cat "$WORKDIR/SUMMARY_security.txt" | write_audit_summary "$SUMMARY_COPY"
    fi
    
    # Create archive
    create_and_verify_archive "$WORKDIR" "security_audit.tgz"
    
    echo ""
    echo "[OK] Аудит безопасности завершен."
    echo "Директория: $WORKDIR"
    echo "Архив: $AUDIT_DIR/security_audit.tgz"
    echo "Сводка: $SUMMARY_COPY"
}

# Run main function
main "$@"
