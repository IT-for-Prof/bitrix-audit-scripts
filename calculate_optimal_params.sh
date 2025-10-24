#!/usr/bin/env bash
# Calculate optimal parameters for Bitrix24 based on available system resources
# Usage: ./calculate_optimal_params.sh [--output-dir DIR] [--config-file FILE]

set -euo pipefail

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

# Script directory
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Source common functions
source "$SCRIPT_DIR/audit_common.sh"

# Setup locale using common functions
setup_locale

# Default configuration
OUTPUT_DIR="${OUTPUT_DIR:-${AUDIT_DIR}/optimal_params}"
CONFIG_DIR="${CONFIG_DIR:-${OUTPUT_DIR}/recommended_configs}"
SUMMARY_FILE="${OUTPUT_DIR}/optimal_params_summary.txt"
JSON_FILE="${OUTPUT_DIR}/optimal_params.json"

# Parse command line arguments
while [[ $# -gt 0 ]]; do
    case "$1" in
        --output-dir)
            shift
            OUTPUT_DIR="$1"
            shift
            ;;
        --config-file)
            shift
            CONFIG_FILE="$1"
            shift
            ;;
        --help|-h)
            echo "Usage: $0 [--output-dir DIR] [--config-file FILE]"
            echo "Calculate optimal parameters for Bitrix24 based on system resources"
            exit 0
            ;;
        *)
            echo "Unknown option: $1" >&2
            exit 1
            ;;
    esac
done

# Create output directories
mkdir -p "$OUTPUT_DIR" "$CONFIG_DIR"

# Helper functions
log() {
    echo "[$(date +%F\ %T)] $*"
}

log_error() {
    echo "[$(date +%F\ %T)] ERROR: $*" >&2
}

log_warning() {
    echo "[$(date +%F\ %T)] WARNING: $*" >&2
}

# Function to get system resources
get_system_resources() {
    log "Определение системных ресурсов..."
    
    # CPU cores
    CPU_CORES=$(nproc 2>/dev/null || echo "1")
    
    # Total RAM in MB
    TOTAL_RAM_MB=$(awk '/MemTotal:/ {print int($2/1024)}' /proc/meminfo 2>/dev/null || echo "1024")
    
    # Available RAM in MB (excluding buffers/cache)
    AVAILABLE_RAM_MB=$(awk '/MemAvailable:/ {print int($2/1024)}' /proc/meminfo 2>/dev/null || echo "$TOTAL_RAM_MB")
    
    # Disk space
    DISK_SPACE_GB=$(df -BG / | awk 'NR==2 {print int(substr($2,1,length($2)-1))}' 2>/dev/null || echo "10")
    
    # Current load average
    LOAD_AVG=$(uptime | awk -F'load average:' '{print $2}' | awk '{print $1}' | sed 's/,//' 2>/dev/null || echo "0.0")
    
    log "Системные ресурсы:"
    log "  CPU cores: $CPU_CORES"
    log "  Total RAM: ${TOTAL_RAM_MB}MB"
    log "  Available RAM: ${AVAILABLE_RAM_MB}MB"
    log "  Disk space: ${DISK_SPACE_GB}GB"
    log "  Load average: $LOAD_AVG"
}

# Function to calculate MySQL parameters
calculate_mysql_params() {
    log "Расчет параметров MySQL..."
    
    # InnoDB Buffer Pool Size (70-80% of available RAM)
    INNODB_BUFFER_POOL_SIZE=$((AVAILABLE_RAM_MB * 75 / 100))
    
    # Max connections (based on RAM and CPU)
    MAX_CONNECTIONS=$((CPU_CORES * 50))
    if [ "$MAX_CONNECTIONS" -lt 100 ]; then
        MAX_CONNECTIONS=100
    elif [ "$MAX_CONNECTIONS" -gt 1000 ]; then
        MAX_CONNECTIONS=1000
    fi
    
    # Thread cache size
    THREAD_CACHE_SIZE=$((MAX_CONNECTIONS / 4))
    if [ "$THREAD_CACHE_SIZE" -lt 8 ]; then
        THREAD_CACHE_SIZE=8
    fi
    
    # Table open cache
    TABLE_OPEN_CACHE=$((MAX_CONNECTIONS * 2))
    if [ "$TABLE_OPEN_CACHE" -lt 400 ]; then
        TABLE_OPEN_CACHE=400
    fi
    
    # Query cache size (if enabled)
    QUERY_CACHE_SIZE=$((AVAILABLE_RAM_MB / 20))
    if [ "$QUERY_CACHE_SIZE" -lt 16 ]; then
        QUERY_CACHE_SIZE=16
    elif [ "$QUERY_CACHE_SIZE" -gt 256 ]; then
        QUERY_CACHE_SIZE=256
    fi
    
    # InnoDB log file size
    INNODB_LOG_FILE_SIZE=$((INNODB_BUFFER_POOL_SIZE / 4))
    if [ "$INNODB_LOG_FILE_SIZE" -lt 64 ]; then
        INNODB_LOG_FILE_SIZE=64
    elif [ "$INNODB_LOG_FILE_SIZE" -gt 2048 ]; then
        INNODB_LOG_FILE_SIZE=2048
    fi
    
    # InnoDB log buffer size
    INNODB_LOG_BUFFER_SIZE=$((INNODB_BUFFER_POOL_SIZE / 100))
    if [ "$INNODB_LOG_BUFFER_SIZE" -lt 8 ]; then
        INNODB_LOG_BUFFER_SIZE=8
    elif [ "$INNODB_LOG_BUFFER_SIZE" -gt 64 ]; then
        INNODB_LOG_BUFFER_SIZE=64
    fi
    
    cat > "$CONFIG_DIR/mysql_optimal.cnf" << EOF
# MySQL оптимальная конфигурация для Bitrix24
# Рассчитано для системы: ${CPU_CORES} CPU, ${TOTAL_RAM_MB}MB RAM

[mysqld]
# Основные параметры
max_connections = $MAX_CONNECTIONS
thread_cache_size = $THREAD_CACHE_SIZE
table_open_cache = $TABLE_OPEN_CACHE

# InnoDB параметры
innodb_buffer_pool_size = ${INNODB_BUFFER_POOL_SIZE}M
innodb_log_file_size = ${INNODB_LOG_FILE_SIZE}M
innodb_log_buffer_size = ${INNODB_LOG_BUFFER_SIZE}M
innodb_flush_log_at_trx_commit = 2
innodb_file_per_table = 1
innodb_flush_method = O_DIRECT

# Query cache (если используется)
query_cache_type = 1
query_cache_size = ${QUERY_CACHE_SIZE}M
query_cache_limit = 2M

# Дополнительные параметры
tmp_table_size = 64M
max_heap_table_size = 64M
sort_buffer_size = 2M
read_buffer_size = 2M
read_rnd_buffer_size = 8M
join_buffer_size = 2M

# Логирование
slow_query_log = 1
slow_query_log_file = /var/log/mysql/slow.log
long_query_time = 2
log_queries_not_using_indexes = 1

# Безопасность
bind-address = 127.0.0.1
EOF

    log "MySQL параметры рассчитаны и сохранены в $CONFIG_DIR/mysql_optimal.cnf"
}

# Function to calculate PHP-FPM parameters
calculate_php_params() {
    log "Расчет параметров PHP-FPM..."
    
    # Estimate average PHP process memory usage (MB)
    AVG_PHP_MEMORY=64
    
    # Calculate max children based on available RAM
    MAX_CHILDREN=$((AVAILABLE_RAM_MB / AVG_PHP_MEMORY))
    if [ "$MAX_CHILDREN" -lt 5 ]; then
        MAX_CHILDREN=5
    elif [ "$MAX_CHILDREN" -gt 200 ]; then
        MAX_CHILDREN=200
    fi
    
    # Start servers (10% of max children)
    START_SERVERS=$((MAX_CHILDREN / 10))
    if [ "$START_SERVERS" -lt 2 ]; then
        START_SERVERS=2
    fi
    
    # Min spare servers (5% of max children)
    MIN_SPARE_SERVERS=$((MAX_CHILDREN / 20))
    if [ "$MIN_SPARE_SERVERS" -lt 1 ]; then
        MIN_SPARE_SERVERS=1
    fi
    
    # Max spare servers (20% of max children)
    MAX_SPARE_SERVERS=$((MAX_CHILDREN / 5))
    if [ "$MAX_SPARE_SERVERS" -lt 2 ]; then
        MAX_SPARE_SERVERS=2
    fi
    
    # Memory limit for PHP processes
    MEMORY_LIMIT=$((AVG_PHP_MEMORY + 32))M
    
    # Max execution time
    MAX_EXECUTION_TIME=300
    
    # Max input time
    MAX_INPUT_TIME=60
    
    cat > "$CONFIG_DIR/php-fpm_optimal.conf" << EOF
; PHP-FPM оптимальная конфигурация для Bitrix24
; Рассчитано для системы: ${CPU_CORES} CPU, ${TOTAL_RAM_MB}MB RAM

[www]
user = www-data
group = www-data

listen = /run/php/php8.1-fpm.sock
listen.owner = www-data
listen.group = www-data
listen.mode = 0660

pm = dynamic
pm.max_children = $MAX_CHILDREN
pm.start_servers = $START_SERVERS
pm.min_spare_servers = $MIN_SPARE_SERVERS
pm.max_spare_servers = $MAX_SPARE_SERVERS
pm.max_requests = 1000

; Таймауты
request_terminate_timeout = 300s
request_slowlog_timeout = 10s

; Логирование
slowlog = /var/log/php8.1-fpm-slow.log
catch_workers_output = yes
EOF

    cat > "$CONFIG_DIR/php_optimal.ini" << EOF
; PHP оптимальная конфигурация для Bitrix24
; Рассчитано для системы: ${CPU_CORES} CPU, ${TOTAL_RAM_MB}MB RAM

; Память и выполнение
memory_limit = $MEMORY_LIMIT
max_execution_time = $MAX_EXECUTION_TIME
max_input_time = $MAX_INPUT_TIME
max_input_vars = 3000

; Загрузка файлов
upload_max_filesize = 100M
post_max_size = 100M
max_file_uploads = 20

; Сессии
session.gc_maxlifetime = 3600
session.cookie_lifetime = 0

; OPcache
opcache.enable = 1
opcache.memory_consumption = 128
opcache.interned_strings_buffer = 8
opcache.max_accelerated_files = 4000
opcache.revalidate_freq = 2
opcache.fast_shutdown = 1

; Безопасность
expose_php = Off
allow_url_fopen = Off
allow_url_include = Off
display_errors = Off
log_errors = On
EOF

    log "PHP-FPM параметры рассчитаны и сохранены в $CONFIG_DIR/php-fpm_optimal.conf"
    log "PHP параметры рассчитаны и сохранены в $CONFIG_DIR/php_optimal.ini"
}

# Function to calculate Nginx parameters
calculate_nginx_params() {
    log "Расчет параметров Nginx..."
    
    # Worker processes = CPU cores
    WORKER_PROCESSES=$CPU_CORES
    
    # Worker connections (based on available RAM and CPU)
    WORKER_CONNECTIONS=$((AVAILABLE_RAM_MB / CPU_CORES / 2))
    if [ "$WORKER_CONNECTIONS" -lt 512 ]; then
        WORKER_CONNECTIONS=512
    elif [ "$WORKER_CONNECTIONS" -gt 2048 ]; then
        WORKER_CONNECTIONS=2048
    fi
    
    # Keepalive timeout
    KEEPALIVE_TIMEOUT=65
    
    # Client max body size
    CLIENT_MAX_BODY_SIZE=100M
    
    # Buffer sizes
    CLIENT_BODY_BUFFER_SIZE=128k
    CLIENT_HEADER_BUFFER_SIZE=1k
    LARGE_CLIENT_HEADER_BUFFERS=4 16k
    
    cat > "$CONFIG_DIR/nginx_optimal.conf" << EOF
# Nginx оптимальная конфигурация для Bitrix24
# Рассчитано для системы: ${CPU_CORES} CPU, ${TOTAL_RAM_MB}MB RAM

user www-data;
worker_processes $WORKER_PROCESSES;
pid /run/nginx.pid;

events {
    worker_connections $WORKER_CONNECTIONS;
    use epoll;
    multi_accept on;
}

http {
    # Основные настройки
    sendfile on;
    tcp_nopush on;
    tcp_nodelay on;
    keepalive_timeout $KEEPALIVE_TIMEOUT;
    types_hash_max_size 2048;
    
    # Размеры буферов
    client_body_buffer_size $CLIENT_BODY_BUFFER_SIZE;
    client_header_buffer_size $CLIENT_HEADER_BUFFER_SIZE;
    large_client_header_buffers $LARGE_CLIENT_HEADER_BUFFERS;
    client_max_body_size $CLIENT_MAX_BODY_SIZE;
    
    # Gzip сжатие
    gzip on;
    gzip_vary on;
    gzip_proxied any;
    gzip_comp_level 6;
    gzip_types
        text/plain
        text/css
        text/xml
        text/javascript
        application/json
        application/javascript
        application/xml+rss
        application/atom+xml
        image/svg+xml;
    
    # Логирование
    access_log /var/log/nginx/access.log;
    error_log /var/log/nginx/error.log;
    
    # Безопасность
    server_tokens off;
    add_header X-Frame-Options DENY;
    add_header X-Content-Type-Options nosniff;
    add_header X-XSS-Protection "1; mode=block";
    
    # Включение конфигураций сайтов
    include /etc/nginx/conf.d/*.conf;
    include /etc/nginx/sites-enabled/*;
}
EOF

    log "Nginx параметры рассчитаны и сохранены в $CONFIG_DIR/nginx_optimal.conf"
}

# Function to calculate Redis parameters
calculate_redis_params() {
    log "Расчет параметров Redis..."
    
    # Max memory (20% of available RAM)
    MAX_MEMORY=$((AVAILABLE_RAM_MB * 20 / 100))
    if [ "$MAX_MEMORY" -lt 64 ]; then
        MAX_MEMORY=64
    elif [ "$MAX_MEMORY" -gt 2048 ]; then
        MAX_MEMORY=2048
    fi
    
    # Max memory policy
    MAX_MEMORY_POLICY="allkeys-lru"
    
    # Save intervals
    SAVE_900_1="900 1"
    SAVE_300_10="300 10"
    SAVE_60_10000="60 10000"
    
    cat > "$CONFIG_DIR/redis_optimal.conf" << EOF
# Redis оптимальная конфигурация для Bitrix24
# Рассчитано для системы: ${CPU_CORES} CPU, ${TOTAL_RAM_MB}MB RAM

# Основные настройки
bind 127.0.0.1
port 6379
timeout 0
tcp-keepalive 300

# Память
maxmemory ${MAX_MEMORY}mb
maxmemory-policy $MAX_MEMORY_POLICY

# Персистентность
save $SAVE_900_1
save $SAVE_300_10
save $SAVE_60_10000
stop-writes-on-bgsave-error yes
rdbcompression yes
rdbchecksum yes
dbfilename dump.rdb
dir /var/lib/redis

# Логирование
loglevel notice
logfile /var/log/redis/redis-server.log

# Безопасность
requirepass your_strong_password_here

# Производительность
tcp-backlog 511
databases 16
EOF

    log "Redis параметры рассчитаны и сохранены в $CONFIG_DIR/redis_optimal.conf"
}

# Function to calculate sysctl parameters
calculate_sysctl_params() {
    log "Расчет параметров sysctl..."
    
    # Calculate optimal values based on system resources
    SOMAXCONN=$((CPU_CORES * 256))
    if [ "$SOMAXCONN" -lt 1024 ]; then
        SOMAXCONN=1024
    elif [ "$SOMAXCONN" -gt 65535 ]; then
        SOMAXCONN=65535
    fi
    
    FILE_MAX=$((TOTAL_RAM_MB * 1024))
    if [ "$FILE_MAX" -lt 2097152 ]; then
        FILE_MAX=2097152
    fi
    
    # Swappiness (lower for servers)
    SWAPPINESS=10
    
    # Dirty ratio (lower for better responsiveness)
    DIRTY_RATIO=15
    DIRTY_BACKGROUND_RATIO=5
    
    # TCP parameters
    TCP_MAX_SYN_BACKLOG=$((CPU_CORES * 512))
    if [ "$TCP_MAX_SYN_BACKLOG" -lt 2048 ]; then
        TCP_MAX_SYN_BACKLOG=2048
    fi
    
    cat > "$CONFIG_DIR/sysctl_optimal.conf" << EOF
# Sysctl оптимальная конфигурация для Bitrix24
# Рассчитано для системы: ${CPU_CORES} CPU, ${TOTAL_RAM_MB}MB RAM

# Сеть
net.core.somaxconn = $SOMAXCONN
net.core.netdev_max_backlog = 5000
net.ipv4.tcp_max_syn_backlog = $TCP_MAX_SYN_BACKLOG
net.ipv4.tcp_fin_timeout = 30
net.ipv4.tcp_tw_reuse = 1
net.ipv4.tcp_syncookies = 1
net.ipv4.ip_local_port_range = 1024 65535

# Память
vm.swappiness = $SWAPPINESS
vm.dirty_ratio = $DIRTY_RATIO
vm.dirty_background_ratio = $DIRTY_BACKGROUND_RATIO
vm.overcommit_memory = 1
vm.max_map_count = 262144

# Файловая система
fs.file-max = $FILE_MAX
fs.inotify.max_user_watches = 524288
fs.inotify.max_user_instances = 256

# Процессы
kernel.pid_max = 4194304
kernel.threads-max = 2097152

# Планировщик
kernel.sched_latency_ns = 6000000
kernel.sched_min_granularity_ns = 750000
kernel.sched_wakeup_granularity_ns = 1000000
EOF

    log "Sysctl параметры рассчитаны и сохранены в $CONFIG_DIR/sysctl_optimal.conf"
}

# Function to generate summary
generate_summary() {
    log "Генерация сводки оптимальных параметров..."
    
    cat > "$SUMMARY_FILE" << EOF
# Оптимальные параметры для Bitrix24
**Сгенерировано:** $(date)
**Система:** ${CPU_CORES} CPU cores, ${TOTAL_RAM_MB}MB RAM, ${DISK_SPACE_GB}GB disk

## Системные ресурсы
- CPU cores: $CPU_CORES
- Total RAM: ${TOTAL_RAM_MB}MB
- Available RAM: ${AVAILABLE_RAM_MB}MB
- Disk space: ${DISK_SPACE_GB}GB
- Load average: $LOAD_AVG

## MySQL параметры
- innodb_buffer_pool_size: ${INNODB_BUFFER_POOL_SIZE}M
- max_connections: $MAX_CONNECTIONS
- thread_cache_size: $THREAD_CACHE_SIZE
- table_open_cache: $TABLE_OPEN_CACHE
- query_cache_size: ${QUERY_CACHE_SIZE}M

## PHP-FPM параметры
- pm.max_children: $MAX_CHILDREN
- pm.start_servers: $START_SERVERS
- pm.min_spare_servers: $MIN_SPARE_SERVERS
- pm.max_spare_servers: $MAX_SPARE_SERVERS
- memory_limit: $MEMORY_LIMIT

## Nginx параметры
- worker_processes: $WORKER_PROCESSES
- worker_connections: $WORKER_CONNECTIONS
- keepalive_timeout: ${KEEPALIVE_TIMEOUT}s
- client_max_body_size: $CLIENT_MAX_BODY_SIZE

## Redis параметры
- maxmemory: ${MAX_MEMORY}mb
- maxmemory-policy: $MAX_MEMORY_POLICY

## Sysctl параметры
- net.core.somaxconn: $SOMAXCONN
- fs.file-max: $FILE_MAX
- vm.swappiness: $SWAPPINESS
- vm.dirty_ratio: $DIRTY_RATIO
- net.ipv4.tcp_max_syn_backlog: $TCP_MAX_SYN_BACKLOG

## Рекомендации по применению
1. Создайте резервные копии текущих конфигураций
2. Применяйте изменения поэтапно, тестируя каждый компонент
3. Мониторьте производительность после изменений
4. Настройте мониторинг для отслеживания использования ресурсов

## Файлы конфигураций
- MySQL: $CONFIG_DIR/mysql_optimal.cnf
- PHP-FPM: $CONFIG_DIR/php-fpm_optimal.conf
- PHP: $CONFIG_DIR/php_optimal.ini
- Nginx: $CONFIG_DIR/nginx_optimal.conf
- Redis: $CONFIG_DIR/redis_optimal.conf
- Sysctl: $CONFIG_DIR/sysctl_optimal.conf
EOF

    log "Сводка сохранена в $SUMMARY_FILE"
}

# Function to generate JSON output
generate_json() {
    log "Генерация JSON отчета..."
    
    cat > "$JSON_FILE" << EOF
{
  "generated_at": "$(date -u +%Y-%m-%dT%H:%M:%SZ)",
  "system_resources": {
    "cpu_cores": $CPU_CORES,
    "total_ram_mb": $TOTAL_RAM_MB,
    "available_ram_mb": $AVAILABLE_RAM_MB,
    "disk_space_gb": $DISK_SPACE_GB,
    "load_average": "$LOAD_AVG"
  },
  "mysql_parameters": {
    "innodb_buffer_pool_size_mb": $INNODB_BUFFER_POOL_SIZE,
    "max_connections": $MAX_CONNECTIONS,
    "thread_cache_size": $THREAD_CACHE_SIZE,
    "table_open_cache": $TABLE_OPEN_CACHE,
    "query_cache_size_mb": $QUERY_CACHE_SIZE,
    "innodb_log_file_size_mb": $INNODB_LOG_FILE_SIZE,
    "innodb_log_buffer_size_mb": $INNODB_LOG_BUFFER_SIZE
  },
  "php_parameters": {
    "max_children": $MAX_CHILDREN,
    "start_servers": $START_SERVERS,
    "min_spare_servers": $MIN_SPARE_SERVERS,
    "max_spare_servers": $MAX_SPARE_SERVERS,
    "memory_limit": "$MEMORY_LIMIT",
    "max_execution_time": $MAX_EXECUTION_TIME,
    "max_input_time": $MAX_INPUT_TIME
  },
  "nginx_parameters": {
    "worker_processes": $WORKER_PROCESSES,
    "worker_connections": $WORKER_CONNECTIONS,
    "keepalive_timeout": $KEEPALIVE_TIMEOUT,
    "client_max_body_size": "$CLIENT_MAX_BODY_SIZE"
  },
  "redis_parameters": {
    "maxmemory_mb": $MAX_MEMORY,
    "maxmemory_policy": "$MAX_MEMORY_POLICY"
  },
  "sysctl_parameters": {
    "net_core_somaxconn": $SOMAXCONN,
    "fs_file_max": $FILE_MAX,
    "vm_swappiness": $SWAPPINESS,
    "vm_dirty_ratio": $DIRTY_RATIO,
    "vm_dirty_background_ratio": $DIRTY_BACKGROUND_RATIO,
    "net_ipv4_tcp_max_syn_backlog": $TCP_MAX_SYN_BACKLOG
  },
  "config_files": {
    "mysql": "$CONFIG_DIR/mysql_optimal.cnf",
    "php_fpm": "$CONFIG_DIR/php-fpm_optimal.conf",
    "php": "$CONFIG_DIR/php_optimal.ini",
    "nginx": "$CONFIG_DIR/nginx_optimal.conf",
    "redis": "$CONFIG_DIR/redis_optimal.conf",
    "sysctl": "$CONFIG_DIR/sysctl_optimal.conf"
  }
}
EOF

    log "JSON отчет сохранен в $JSON_FILE"
}

# Main execution
main() {
    log "Запуск расчета оптимальных параметров для Bitrix24 v$VERSION"
    
    # Get system resources
    get_system_resources
    
    # Calculate parameters for each component
    calculate_mysql_params
    calculate_php_params
    calculate_nginx_params
    calculate_redis_params
    calculate_sysctl_params
    
    # Generate outputs
    generate_summary
    generate_json
    
    log "Расчет оптимальных параметров завершен"
    log "Результаты сохранены в: $OUTPUT_DIR"
    log "Конфигурации сохранены в: $CONFIG_DIR"
    
    # Create archive
    if [ -d "$OUTPUT_DIR" ]; then
        create_and_verify_archive "$OUTPUT_DIR" "optimal_params.tgz"
    fi
}

# Run main function
main "$@"
