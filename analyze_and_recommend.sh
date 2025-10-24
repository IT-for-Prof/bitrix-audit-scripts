#!/usr/bin/env bash
# Centralized analyzer and recommendation generator for Bitrix24 audit
# Usage: ./analyze_and_recommend.sh [--input-dir DIR] [--output-dir DIR]

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
INPUT_DIR="${INPUT_DIR:-${AUDIT_DIR}}"
OUTPUT_DIR="${OUTPUT_DIR:-${AUDIT_DIR}/analysis}"
RECOMMENDATIONS_FILE="${OUTPUT_DIR}/recommendations.txt"
PRIORITY_FILE="${OUTPUT_DIR}/priority_recommendations.txt"
ISSUES_FILE="${OUTPUT_DIR}/issues_found.txt"
JSON_FILE="${OUTPUT_DIR}/analysis.json"

# Parse command line arguments
while [[ $# -gt 0 ]]; do
    case "$1" in
        --input-dir)
            shift
            INPUT_DIR="$1"
            shift
            ;;
        --output-dir)
            shift
            OUTPUT_DIR="$1"
            shift
            ;;
        --help|-h)
            echo "Usage: $0 [--input-dir DIR] [--output-dir DIR]"
            echo "Analyze collected audit data and generate prioritized recommendations"
            exit 0
            ;;
        *)
            echo "Unknown option: $1" >&2
            exit 1
            ;;
    esac
done

# Create output directory
mkdir -p "$OUTPUT_DIR"

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

# Function to analyze system resources
analyze_system_resources() {
    log "Анализ системных ресурсов..."
    
    local issues=()
    local recommendations=()
    
    # Check if system_info file exists
    if [ -f "${INPUT_DIR}/system_info_audit/system.info" ]; then
        local sysinfo_file="${INPUT_DIR}/system_info_audit/system.info"
        
        # Analyze memory usage
        local mem_total
        mem_total=$(grep "MemTotal:" "$sysinfo_file" | awk '{print int($2/1024)}' 2>/dev/null || echo "0")
        local mem_available
        mem_available=$(grep "MemAvailable:" "$sysinfo_file" | awk '{print int($2/1024)}' 2>/dev/null || echo "0")
        
        if [ "$mem_total" -gt 0 ] && [ "$mem_available" -gt 0 ]; then
            local mem_usage_pct=$((100 - (mem_available * 100 / mem_total)))
            
            if [ "$mem_usage_pct" -gt 90 ]; then
                issues+=("КРИТИЧНО: Использование памяти ${mem_usage_pct}%")
                recommendations+=("КРИТИЧНО: Увеличьте RAM или оптимизируйте использование памяти")
            elif [ "$mem_usage_pct" -gt 80 ]; then
                issues+=("ВНИМАНИЕ: Высокое использование памяти ${mem_usage_pct}%")
                recommendations+=("Рекомендуется: Мониторинг памяти, возможна оптимизация")
            fi
        fi
        
        # Analyze load average
        local load_avg
        load_avg=$(grep "load average:" "$sysinfo_file" | awk '{print $NF}' | sed 's/,//' 2>/dev/null || echo "0")
        local cpu_cores
        cpu_cores=$(nproc 2>/dev/null || echo "1")
        
        if [ "$load_avg" != "0" ] && [ "$cpu_cores" -gt 0 ]; then
            local load_ratio
            load_ratio=$(echo "scale=2; $load_avg / $cpu_cores" | bc -l 2>/dev/null || echo "0")
            
            if (( $(echo "$load_ratio > 2.0" | bc -l) )); then
                issues+=("КРИТИЧНО: Высокая загрузка системы (load ratio: $load_ratio)")
                recommendations+=("КРИТИЧНО: Проверьте процессы с высокой нагрузкой, возможна нехватка CPU")
            elif (( $(echo "$load_ratio > 1.0" | bc -l) )); then
                issues+=("ВНИМАНИЕ: Повышенная загрузка системы (load ratio: $load_ratio)")
                recommendations+=("Рекомендуется: Мониторинг загрузки CPU")
            fi
        fi
        
        # Analyze disk space
        local disk_usage
        disk_usage=$(df / | awk 'NR==2 {print int($5)}' 2>/dev/null || echo "0")
        if [ "$disk_usage" -gt 90 ]; then
            issues+=("КРИТИЧНО: Диск заполнен на ${disk_usage}%")
            recommendations+=("КРИТИЧНО: Освободите место на диске или увеличьте размер")
        elif [ "$disk_usage" -gt 80 ]; then
            issues+=("ВНИМАНИЕ: Диск заполнен на ${disk_usage}%")
            recommendations+=("Рекомендуется: Мониторинг использования диска")
        fi
        
        # Analyze PSI (Pressure Stall Information)
        if grep -q "PSI" "$sysinfo_file"; then
            local psi_cpu
            psi_cpu=$(grep "PSI.*cpu" "$sysinfo_file" | grep -o "avg10=[0-9.]*" | cut -d= -f2 2>/dev/null || echo "0")
            local psi_memory
            psi_memory=$(grep "PSI.*memory" "$sysinfo_file" | grep -o "avg10=[0-9.]*" | cut -d= -f2 2>/dev/null || echo "0")
            
            if (( $(echo "$psi_cpu > 1.0" | bc -l) )); then
                issues+=("ВНИМАНИЕ: Высокое давление CPU (PSI: $psi_cpu)")
                recommendations+=("Рекомендуется: Оптимизация процессов с высокой нагрузкой на CPU")
            fi
            
            if (( $(echo "$psi_memory > 1.0" | bc -l) )); then
                issues+=("ВНИМАНИЕ: Высокое давление памяти (PSI: $psi_memory)")
                recommendations+=("Рекомендуется: Увеличение RAM или оптимизация использования памяти")
            fi
        fi
    else
        log_warning "Файл system.info не найден, пропускаем анализ системных ресурсов"
    fi
    
    # Save results
    printf '%s\n' "${issues[@]}" > "${OUTPUT_DIR}/system_issues.txt"
    printf '%s\n' "${recommendations[@]}" > "${OUTPUT_DIR}/system_recommendations.txt"
    
    log "Найдено проблем с системными ресурсами: ${#issues[@]}"
    log "Сгенерировано рекомендаций по системным ресурсам: ${#recommendations[@]}"
}

# Function to analyze MySQL configuration
analyze_mysql_config() {
    log "Анализ конфигурации MySQL..."
    
    local issues=()
    local recommendations=()
    
    # Check if MySQL audit files exist
    if [ -f "${INPUT_DIR}/mysql_audit/mysql_audit.txt" ]; then
        local mysql_file="${INPUT_DIR}/mysql_audit/mysql_audit.txt"
        
        # Check InnoDB buffer pool size
        local innodb_buffer_pool
        innodb_buffer_pool=$(grep "innodb_buffer_pool_size" "$mysql_file" | awk '{print $2}' 2>/dev/null || echo "")
        if [ -n "$innodb_buffer_pool" ]; then
            local buffer_pool_mb
            buffer_pool_mb=${innodb_buffer_pool//[^0-9]/}
            local total_ram_mb
            total_ram_mb=$(grep "MemTotal:" "${INPUT_DIR}/system_info_audit/system.info" | awk '{print int($2/1024)}' 2>/dev/null || echo "1024")
            
            if [ "$buffer_pool_mb" -gt 0 ] && [ "$total_ram_mb" -gt 0 ]; then
                local buffer_pool_pct=$((buffer_pool_mb * 100 / total_ram_mb))
                
                if [ "$buffer_pool_pct" -lt 50 ]; then
                    issues+=("ВНИМАНИЕ: InnoDB buffer pool слишком мал (${buffer_pool_pct}% от RAM)")
                    recommendations+=("Рекомендуется: Увеличьте innodb_buffer_pool_size до 70-80% от RAM")
                elif [ "$buffer_pool_pct" -gt 90 ]; then
                    issues+=("ВНИМАНИЕ: InnoDB buffer pool слишком велик (${buffer_pool_pct}% от RAM)")
                    recommendations+=("Рекомендуется: Уменьшите innodb_buffer_pool_size до 70-80% от RAM")
                fi
            fi
        fi
        
        # Check max_connections
        local max_connections
        max_connections=$(grep "max_connections" "$mysql_file" | awk '{print $2}' 2>/dev/null || echo "")
        if [ -n "$max_connections" ] && [ "$max_connections" -lt 100 ]; then
            issues+=("ВНИМАНИЕ: max_connections слишком мал ($max_connections)")
            recommendations+=("Рекомендуется: Увеличьте max_connections до 200-500")
        fi
        
        # Check slow query log
        local slow_query_log
        slow_query_log=$(grep "slow_query_log" "$mysql_file" | awk '{print $2}' 2>/dev/null || echo "")
        if [ "$slow_query_log" = "OFF" ]; then
            issues+=("ИНФОРМАЦИЯ: Slow query log отключен")
            recommendations+=("Рекомендуется: Включите slow_query_log для мониторинга производительности")
        fi
        
        # Check for mysqltuner recommendations
        if [ -f "${INPUT_DIR}/mysql_audit/mysqltuner.txt" ]; then
            local tuner_file="${INPUT_DIR}/mysql_audit/mysqltuner.txt"
            
            # Extract recommendations from mysqltuner
            if grep -q "Recommendations:" "$tuner_file"; then
                local tuner_recommendations
                tuner_recommendations=$(sed -n '/Recommendations:/,$p' "$tuner_file" | grep -E "^\s*\*" | head -10)
                if [ -n "$tuner_recommendations" ]; then
                    while IFS= read -r line; do
                        recommendations+=("MySQL Tuner: $line")
                    done <<< "$tuner_recommendations"
                fi
            fi
        fi
    else
        log_warning "Файл mysql_audit.txt не найден, пропускаем анализ MySQL"
    fi
    
    # Save results
    printf '%s\n' "${issues[@]}" > "${OUTPUT_DIR}/mysql_issues.txt"
    printf '%s\n' "${recommendations[@]}" > "${OUTPUT_DIR}/mysql_recommendations.txt"
    
    log "Найдено проблем с MySQL: ${#issues[@]}"
    log "Сгенерировано рекомендаций по MySQL: ${#recommendations[@]}"
}

# Function to analyze PHP configuration
analyze_php_config() {
    log "Анализ конфигурации PHP..."
    
    local issues=()
    local recommendations=()
    
    # Check if PHP audit files exist
    if [ -f "${INPUT_DIR}/php_audit/report.txt" ]; then
        local php_file="${INPUT_DIR}/php_audit/report.txt"
        
        # Check memory_limit
        local memory_limit
        memory_limit=$(grep "memory_limit=" "$php_file" | cut -d= -f2 2>/dev/null || echo "")
        if [ -n "$memory_limit" ]; then
            local memory_mb
            memory_mb=${memory_limit//[^0-9]/}
            
            if [ "$memory_mb" -lt 128 ]; then
                issues+=("ВНИМАНИЕ: memory_limit слишком мал (${memory_limit})")
                recommendations+=("Рекомендуется: Увеличьте memory_limit до 256M или больше")
            elif [ "$memory_mb" -gt 1024 ]; then
                issues+=("ВНИМАНИЕ: memory_limit слишком велик (${memory_limit})")
                recommendations+=("Рекомендуется: Уменьшите memory_limit до 512M для экономии памяти")
            fi
        fi
        
        # Check max_execution_time
        local max_exec_time
        max_exec_time=$(grep "max_execution_time=" "$php_file" | cut -d= -f2 2>/dev/null || echo "")
        if [ -n "$max_exec_time" ] && [ "$max_exec_time" -lt 300 ]; then
            issues+=("ВНИМАНИЕ: max_execution_time слишком мал (${max_exec_time}s)")
            recommendations+=("Рекомендуется: Увеличьте max_execution_time до 300s или больше")
        fi
        
        # Check OPcache
        local opcache_enabled
        opcache_enabled=$(grep "opcache.enable" "$php_file" | cut -d= -f2 2>/dev/null || echo "")
        if [ "$opcache_enabled" = "0" ]; then
            issues+=("КРИТИЧНО: OPcache отключен")
            recommendations+=("КРИТИЧНО: Включите OPcache для улучшения производительности")
        fi
        
        # Check security settings
        local allow_url_fopen
        allow_url_fopen=$(grep "allow_url_fopen=" "$php_file" | cut -d= -f2 2>/dev/null || echo "")
        if [ "$allow_url_fopen" = "1" ]; then
            issues+=("БЕЗОПАСНОСТЬ: allow_url_fopen включен")
            recommendations+=("БЕЗОПАСНОСТЬ: Отключите allow_url_fopen для повышения безопасности")
        fi
        
        local display_errors
        display_errors=$(grep "display_errors=" "$php_file" | cut -d= -f2 2>/dev/null || echo "")
        if [ "$display_errors" = "1" ]; then
            issues+=("БЕЗОПАСНОСТЬ: display_errors включен")
            recommendations+=("БЕЗОПАСНОСТЬ: Отключите display_errors в продакшене")
        fi
    else
        log_warning "Файл php_audit/report.txt не найден, пропускаем анализ PHP"
    fi
    
    # Save results
    printf '%s\n' "${issues[@]}" > "${OUTPUT_DIR}/php_issues.txt"
    printf '%s\n' "${recommendations[@]}" > "${OUTPUT_DIR}/php_recommendations.txt"
    
    log "Найдено проблем с PHP: ${#issues[@]}"
    log "Сгенерировано рекомендаций по PHP: ${#recommendations[@]}"
}

# Function to analyze Nginx configuration
analyze_nginx_config() {
    log "Анализ конфигурации Nginx..."
    
    local issues=()
    local recommendations=()
    
    # Check if Nginx audit files exist
    if [ -f "${INPUT_DIR}/nginx_audit/nginx_audit.txt" ]; then
        local nginx_file="${INPUT_DIR}/nginx_audit/nginx_audit.txt"
        
        # Check worker_processes
        local worker_processes
        worker_processes=$(grep "worker_processes" "$nginx_file" | awk '{print $2}' | head -1 2>/dev/null || echo "")
        local cpu_cores
        cpu_cores=$(nproc 2>/dev/null || echo "1")
        
        if [ -n "$worker_processes" ] && [ "$worker_processes" != "auto" ]; then
            if [ "$worker_processes" -lt "$cpu_cores" ]; then
                issues+=("ВНИМАНИЕ: worker_processes ($worker_processes) меньше количества CPU cores ($cpu_cores)")
                recommendations+=("Рекомендуется: Установите worker_processes = $cpu_cores")
            fi
        fi
        
        # Check worker_connections
        local worker_connections
        worker_connections=$(grep "worker_connections" "$nginx_file" | awk '{print $2}' | head -1 2>/dev/null || echo "")
        if [ -n "$worker_connections" ] && [ "$worker_connections" -lt 1024 ]; then
            issues+=("ВНИМАНИЕ: worker_connections слишком мал ($worker_connections)")
            recommendations+=("Рекомендуется: Увеличьте worker_connections до 2048 или больше")
        fi
        
        # Check gzip compression
        local gzip_enabled
        gzip_enabled=$(grep -c "gzip on" "$nginx_file" 2>/dev/null || echo "0")
        if [ "$gzip_enabled" -eq 0 ]; then
            issues+=("ИНФОРМАЦИЯ: Gzip сжатие отключено")
            recommendations+=("Рекомендуется: Включите gzip сжатие для экономии трафика")
        fi
        
        # Check SSL configuration
        local ssl_protocols
        ssl_protocols=$(grep "ssl_protocols" "$nginx_file" | head -1 2>/dev/null || echo "")
        if [ -n "$ssl_protocols" ] && echo "$ssl_protocols" | grep -q "SSLv2\|SSLv3"; then
            issues+=("БЕЗОПАСНОСТЬ: Используются устаревшие SSL протоколы")
            recommendations+=("БЕЗОПАСНОСТЬ: Отключите SSLv2 и SSLv3, используйте только TLS 1.2+")
        fi
    else
        log_warning "Файл nginx_audit.txt не найден, пропускаем анализ Nginx"
    fi
    
    # Save results
    printf '%s\n' "${issues[@]}" > "${OUTPUT_DIR}/nginx_issues.txt"
    printf '%s\n' "${recommendations[@]}" > "${OUTPUT_DIR}/nginx_recommendations.txt"
    
    log "Найдено проблем с Nginx: ${#issues[@]}"
    log "Сгенерировано рекомендаций по Nginx: ${#recommendations[@]}"
}

# Function to analyze Redis configuration
analyze_redis_config() {
    log "Анализ конфигурации Redis..."
    
    local issues=()
    local recommendations=()
    
    # Check if Redis audit files exist
    if [ -f "${INPUT_DIR}/redis_audit/out/recommendations.txt" ]; then
        local redis_file="${INPUT_DIR}/redis_audit/out/recommendations.txt"
        
        # Read existing recommendations
        while IFS= read -r line; do
            if [ -n "$line" ]; then
                recommendations+=("Redis: $line")
            fi
        done < "$redis_file"
    else
        log_warning "Файл redis_audit/out/recommendations.txt не найден, пропускаем анализ Redis"
    fi
    
    # Save results
    printf '%s\n' "${issues[@]}" > "${OUTPUT_DIR}/redis_issues.txt"
    printf '%s\n' "${recommendations[@]}" > "${OUTPUT_DIR}/redis_recommendations.txt"
    
    log "Найдено проблем с Redis: ${#issues[@]}"
    log "Сгенерировано рекомендаций по Redis: ${#recommendations[@]}"
}

# Function to analyze sysctl parameters
analyze_sysctl_config() {
    log "Анализ параметров sysctl..."
    
    local issues=()
    local recommendations=()
    
    # Check if sysctl dump exists
    if [ -f "${INPUT_DIR}/system_info_audit/sysctl_full_dump.txt" ]; then
        local sysctl_file="${INPUT_DIR}/system_info_audit/sysctl_full_dump.txt"
        
        # Check vm.swappiness
        local swappiness
        swappiness=$(grep "vm.swappiness" "$sysctl_file" | awk '{print $3}' 2>/dev/null || echo "")
        if [ -n "$swappiness" ] && [ "$swappiness" -gt 10 ]; then
            issues+=("ВНИМАНИЕ: vm.swappiness слишком высокий ($swappiness)")
            recommendations+=("Рекомендуется: Установите vm.swappiness = 10 для серверов")
        fi
        
        # Check net.core.somaxconn
        local somaxconn
        somaxconn=$(grep "net.core.somaxconn" "$sysctl_file" | awk '{print $3}' 2>/dev/null || echo "")
        if [ -n "$somaxconn" ] && [ "$somaxconn" -lt 1024 ]; then
            issues+=("ВНИМАНИЕ: net.core.somaxconn слишком мал ($somaxconn)")
            recommendations+=("Рекомендуется: Увеличьте net.core.somaxconn до 1024 или больше")
        fi
        
        # Check fs.file-max
        local file_max
        file_max=$(grep "fs.file-max" "$sysctl_file" | awk '{print $3}' 2>/dev/null || echo "")
        if [ -n "$file_max" ] && [ "$file_max" -lt 2097152 ]; then
            issues+=("ВНИМАНИЕ: fs.file-max слишком мал ($file_max)")
            recommendations+=("Рекомендуется: Увеличьте fs.file-max до 2097152 или больше")
        fi
        
        # Check vm.dirty_ratio
        local dirty_ratio
        dirty_ratio=$(grep "vm.dirty_ratio" "$sysctl_file" | awk '{print $3}' 2>/dev/null || echo "")
        if [ -n "$dirty_ratio" ] && [ "$dirty_ratio" -gt 20 ]; then
            issues+=("ВНИМАНИЕ: vm.dirty_ratio слишком высокий ($dirty_ratio)")
            recommendations+=("Рекомендуется: Установите vm.dirty_ratio = 15 для лучшей отзывчивости")
        fi
    else
        log_warning "Файл sysctl_full_dump.txt не найден, пропускаем анализ sysctl"
    fi
    
    # Save results
    printf '%s\n' "${issues[@]}" > "${OUTPUT_DIR}/sysctl_issues.txt"
    printf '%s\n' "${recommendations[@]}" > "${OUTPUT_DIR}/sysctl_recommendations.txt"
    
    log "Найдено проблем с sysctl: ${#issues[@]}"
    log "Сгенерировано рекомендаций по sysctl: ${#recommendations[@]}"
}

# Function to analyze Bitrix cache and settings
analyze_bitrix_cache() {
    log "Анализ кеша и настроек Битрикс..."
    
    local issues=()
    local recommendations=()
    
    # Check if Bitrix audit files exist
    if [ -f "${INPUT_DIR}/bitrix_audit/cache_analysis.txt" ]; then
        local cache_file="${INPUT_DIR}/bitrix_audit/cache_analysis.txt"
        
        # Extract cache size information
        local total_size_gb
        total_size_gb=$(grep "Общий размер кеша:" "$cache_file" | grep -o '[0-9]* GB' | sed 's/ GB//' 2>/dev/null || echo "0")
        local total_old_files
        total_old_files=$(grep "Старых файлов:" "$cache_file" | tail -1 | grep -o '[0-9]*' 2>/dev/null || echo "0")
        local disk_pct
        disk_pct=$(grep "Использование диска" "$cache_file" | grep -o '[0-9]*%' | sed 's/%//' 2>/dev/null || echo "0")
        
        # Analyze cache size
        if [ "$total_size_gb" -gt 10 ]; then
            issues+=("КРИТИЧНО: Общий размер кеша Битрикс ${total_size_gb} GB превышает критический порог")
            recommendations+=("КРИТИЧНО: Немедленно очистите кеш Битрикс или увеличьте дисковое пространство")
        elif [ "$total_size_gb" -gt 5 ]; then
            issues+=("ВНИМАНИЕ: Общий размер кеша Битрикс ${total_size_gb} GB превышает предупреждающий порог")
            recommendations+=("Рекомендуется: Настройте автоматическую очистку кеша Битрикс")
        fi
        
        # Analyze old files
        if [ "$total_old_files" -gt 10000 ]; then
            issues+=("КРИТИЧНО: Найдено $total_old_files старых файлов кеша")
            recommendations+=("КРИТИЧНО: Очистите старые файлы кеша старше 30 дней")
        elif [ "$total_old_files" -gt 1000 ]; then
            issues+=("ВНИМАНИЕ: Найдено $total_old_files старых файлов кеша")
            recommendations+=("Рекомендуется: Очистите старые файлы кеша")
        fi
        
        # Analyze disk usage
        if [ "$disk_pct" -gt 20 ]; then
            issues+=("КРИТИЧНО: Использование диска /home/bitrix ${disk_pct}% критично")
            recommendations+=("КРИТИЧНО: Освободите место на диске или увеличьте размер раздела")
        fi
        
        # General recommendations
        recommendations+=("Рекомендуется: Настройте автоматическую очистку кеша через cron")
        recommendations+=("Рекомендуется: Рассмотрите использование Memcached/Redis для кеширования")
        recommendations+=("Рекомендуется: Настройте мониторинг размера кеша")
    else
        log_warning "Файл cache_analysis.txt не найден, пропускаем анализ кеша Битрикс"
    fi
    
    # Check Bitrix settings recommendations
    if [ -f "${INPUT_DIR}/bitrix_audit/settings_recommendations.txt" ]; then
        local settings_file="${INPUT_DIR}/bitrix_audit/settings_recommendations.txt"
        
        # Read existing recommendations
        while IFS= read -r line; do
            if [ -n "$line" ]; then
                recommendations+=("Настройки Битрикс: $line")
            fi
        done < "$settings_file"
    else
        log_warning "Файл settings_recommendations.txt не найден, пропускаем анализ настроек Битрикс"
    fi
    
    # Save results
    printf '%s\n' "${issues[@]}" > "${OUTPUT_DIR}/bitrix_issues.txt"
    printf '%s\n' "${recommendations[@]}" > "${OUTPUT_DIR}/bitrix_recommendations.txt"
    
    log "Найдено проблем с Битрикс: ${#issues[@]}"
    log "Сгенерировано рекомендаций по Битрикс: ${#recommendations[@]}"
}

# Function to generate priority recommendations
generate_priority_recommendations() {
    log "Генерация приоритизированных рекомендаций..."
    
    cat > "$PRIORITY_FILE" << EOF
# Приоритизированные рекомендации для Bitrix24
**Сгенерировано:** $(date)
**Источник:** Анализ данных аудита

## КРИТИЧНЫЕ проблемы (требуют немедленного внимания)
EOF

    # Collect critical issues
    local critical_issues=()
    
    for file in "${OUTPUT_DIR}"/*_issues.txt; do
        if [ -f "$file" ]; then
            while IFS= read -r line; do
                if [[ "$line" == "КРИТИЧНО:"* ]]; then
                    critical_issues+=("$line")
                fi
            done < "$file"
        fi
    done
    
    if [ ${#critical_issues[@]} -gt 0 ]; then
        printf '%s\n' "${critical_issues[@]}" >> "$PRIORITY_FILE"
    else
        echo "Критичных проблем не найдено" >> "$PRIORITY_FILE"
    fi
    
    cat >> "$PRIORITY_FILE" << EOF

## Проблемы БЕЗОПАСНОСТИ (высокий приоритет)
EOF

    # Collect security issues
    local security_issues=()
    
    for file in "${OUTPUT_DIR}"/*_issues.txt; do
        if [ -f "$file" ]; then
            while IFS= read -r line; do
                if [[ "$line" == "БЕЗОПАСНОСТЬ:"* ]]; then
                    security_issues+=("$line")
                fi
            done < "$file"
        fi
    done
    
    if [ ${#security_issues[@]} -gt 0 ]; then
        printf '%s\n' "${security_issues[@]}" >> "$PRIORITY_FILE"
    else
        echo "Проблем безопасности не найдено" >> "$PRIORITY_FILE"
    fi
    
    cat >> "$PRIORITY_FILE" << EOF

## ВНИМАНИЕ (средний приоритет)
EOF

    # Collect warning issues
    local warning_issues=()
    
    for file in "${OUTPUT_DIR}"/*_issues.txt; do
        if [ -f "$file" ]; then
            while IFS= read -r line; do
                if [[ "$line" == "ВНИМАНИЕ:"* ]]; then
                    warning_issues+=("$line")
                fi
            done < "$file"
        fi
    done
    
    if [ ${#warning_issues[@]} -gt 0 ]; then
        printf '%s\n' "${warning_issues[@]}" >> "$PRIORITY_FILE"
    else
        echo "Предупреждений не найдено" >> "$PRIORITY_FILE"
    fi
    
    cat >> "$PRIORITY_FILE" << EOF

## ИНФОРМАЦИЯ (низкий приоритет)
EOF

    # Collect info issues
    local info_issues=()
    
    for file in "${OUTPUT_DIR}"/*_issues.txt; do
        if [ -f "$file" ]; then
            while IFS= read -r line; do
                if [[ "$line" == "ИНФОРМАЦИЯ:"* ]]; then
                    info_issues+=("$line")
                fi
            done < "$file"
        fi
    done
    
    if [ ${#info_issues[@]} -gt 0 ]; then
        printf '%s\n' "${info_issues[@]}" >> "$PRIORITY_FILE"
    else
        echo "Информационных сообщений не найдено" >> "$PRIORITY_FILE"
    fi
    
    log "Приоритизированные рекомендации сохранены в $PRIORITY_FILE"
}

# Function to generate comprehensive recommendations
generate_comprehensive_recommendations() {
    log "Генерация комплексных рекомендаций..."
    
    cat > "$RECOMMENDATIONS_FILE" << EOF
# Комплексные рекомендации для оптимизации Bitrix24
**Сгенерировано:** $(date)
**Источник:** Анализ данных аудита

## Системные ресурсы
EOF

    if [ -f "${OUTPUT_DIR}/system_recommendations.txt" ]; then
        cat "${OUTPUT_DIR}/system_recommendations.txt" >> "$RECOMMENDATIONS_FILE"
    fi
    
    cat >> "$RECOMMENDATIONS_FILE" << EOF

## MySQL
EOF

    if [ -f "${OUTPUT_DIR}/mysql_recommendations.txt" ]; then
        cat "${OUTPUT_DIR}/mysql_recommendations.txt" >> "$RECOMMENDATIONS_FILE"
    fi
    
    cat >> "$RECOMMENDATIONS_FILE" << EOF

## PHP
EOF

    if [ -f "${OUTPUT_DIR}/php_recommendations.txt" ]; then
        cat "${OUTPUT_DIR}/php_recommendations.txt" >> "$RECOMMENDATIONS_FILE"
    fi
    
    cat >> "$RECOMMENDATIONS_FILE" << EOF

## Nginx
EOF

    if [ -f "${OUTPUT_DIR}/nginx_recommendations.txt" ]; then
        cat "${OUTPUT_DIR}/nginx_recommendations.txt" >> "$RECOMMENDATIONS_FILE"
    fi
    
    cat >> "$RECOMMENDATIONS_FILE" << EOF

## Redis
EOF

    if [ -f "${OUTPUT_DIR}/redis_recommendations.txt" ]; then
        cat "${OUTPUT_DIR}/redis_recommendations.txt" >> "$RECOMMENDATIONS_FILE"
    fi
    
    cat >> "$RECOMMENDATIONS_FILE" << EOF

## Sysctl
EOF

    if [ -f "${OUTPUT_DIR}/sysctl_recommendations.txt" ]; then
        cat "${OUTPUT_DIR}/sysctl_recommendations.txt" >> "$RECOMMENDATIONS_FILE"
    fi
    
    cat >> "$RECOMMENDATIONS_FILE" << EOF

## Битрикс
EOF

    if [ -f "${OUTPUT_DIR}/bitrix_recommendations.txt" ]; then
        cat "${OUTPUT_DIR}/bitrix_recommendations.txt" >> "$RECOMMENDATIONS_FILE"
    fi
    
    log "Комплексные рекомендации сохранены в $RECOMMENDATIONS_FILE"
}

# Function to generate JSON output
generate_json_output() {
    log "Генерация JSON отчета..."
    
    cat > "$JSON_FILE" << EOF
{
  "generated_at": "$(date -u +%Y-%m-%dT%H:%M:%SZ)",
  "analysis_summary": {
    "total_issues": $(find "${OUTPUT_DIR}" -name "*_issues.txt" -exec wc -l {} + | tail -1 | awk '{print $1}' || echo "0"),
    "total_recommendations": $(find "${OUTPUT_DIR}" -name "*_recommendations.txt" -exec wc -l {} + | tail -1 | awk '{print $1}' || echo "0")
  },
  "components_analyzed": [
EOF

    local components=()
    for file in "${OUTPUT_DIR}"/*_issues.txt; do
        if [ -f "$file" ]; then
            local component
            component=$(basename "$file" _issues.txt)
            components+=("\"$component\"")
        fi
    done
    
    if [ ${#components[@]} -gt 0 ]; then
        printf '%s' "${components[@]}" | sed 's/ /, /g' >> "$JSON_FILE"
    fi
    
    cat >> "$JSON_FILE" << EOF
  ],
  "files": {
    "recommendations": "$RECOMMENDATIONS_FILE",
    "priority_recommendations": "$PRIORITY_FILE",
    "issues": "$ISSUES_FILE"
  }
}
EOF

    log "JSON отчет сохранен в $JSON_FILE"
}

# Main execution
main() {
    log "Запуск анализа и генерации рекомендаций для Bitrix24 v$VERSION"
    
    # Analyze each component
    analyze_system_resources
    analyze_mysql_config
    analyze_php_config
    analyze_nginx_config
    analyze_redis_config
    analyze_sysctl_config
    analyze_bitrix_cache
    
    # Generate outputs
    generate_priority_recommendations
    generate_comprehensive_recommendations
    generate_json_output
    
    log "Анализ и генерация рекомендаций завершены"
    log "Результаты сохранены в: $OUTPUT_DIR"
    
    # Create archive
    if [ -d "$OUTPUT_DIR" ]; then
        create_and_verify_archive "$OUTPUT_DIR" "analysis.tgz"
    fi
}

# Run main function
main "$@"
