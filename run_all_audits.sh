#!/usr/bin/env bash
# Unified orchestrator for all Bitrix24 audit scripts
# Usage: ./run_all_audits.sh [--all|--nginx|--apache|--mysql|--php|--redis|--system|--atop|--sar|--cron|--analyze-errors|--bitrix] [--parallel|--sequential] [--config FILE]

set -euo pipefail

# Version information
VERSION="2.1.0"

# Script directory
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Source common functions
source "$SCRIPT_DIR/audit_common.sh"

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

# Проверка зависимостей (интерактивно)
if [ -t 0 ] && [ -z "${SKIP_REQ_CHECK:-}" ]; then
  echo "============================================================"
  echo "Bitrix24 Audit Orchestrator v$VERSION"
  echo "============================================================"
  echo ""
  echo "Рекомендуется сначала проверить системные зависимости."
  echo ""
  read -p "Запустить check_requirements.sh перед аудитом? [Y/n]: " answer
  answer=${answer:-Y}
  if [[ "$answer" != "n" && "$answer" != "N" ]]; then
    echo ""
    if [ -f "$SCRIPT_DIR/check_requirements.sh" ]; then
      bash "$SCRIPT_DIR/check_requirements.sh"
      echo ""
      read -p "Продолжить выполнение аудита? [Y/n]: " continue_answer
      continue_answer=${continue_answer:-Y}
      if [[ "$continue_answer" == "n" || "$continue_answer" == "N" ]]; then
        echo "Аудит отменен пользователем."
        exit 0
      fi
    else
      echo "WARN: check_requirements.sh не найден в $SCRIPT_DIR"
    fi
  fi
  echo ""
fi

# Default configuration
ENABLE_NGINX=1
ENABLE_APACHE=1
ENABLE_MYSQL=1
ENABLE_PHP=1
ENABLE_REDIS=1
ENABLE_SYSTEM=1
ENABLE_ATOP=1
ENABLE_SAR=1
ENABLE_CRON=1
ENABLE_ERROR_ANALYSIS=1
ENABLE_BITRIX=1

# Execution mode
PARALLEL_EXECUTION=0
CLEANUP_AFTER_ARCHIVE=1
KEEP_LAST_N_ARCHIVES=5

# Time settings for performance analysis
SAR_FULL_DAY=1
SAR_START_TIME="08:00:00"
SAR_END_TIME="19:00:00"
SAR_DAYS=7

ATOP_FULL_DAY=1
ATOP_START_TIME="09:00"
ATOP_END_TIME="19:00"

ERROR_ANALYSIS_DAYS=7

# Bitrix-specific components
ENABLE_PUSH_SERVER=1
ENABLE_SPHINX=1
ENABLE_MEMCACHED=1
ENABLE_COMPOSITE_CACHE=1

# Logging
LOG_FILE="$AUDIT_DIR/audit_run.log"
SUMMARY_FILE="$AUDIT_DIR/SUMMARY_ALL.md"

# Helper functions
log() {
    echo "[$(date +%F\ %T)] $*" | tee -a "$LOG_FILE"
}

log_error() {
    echo "[$(date +%F\ %T)] ERROR: $*" | tee -a "$LOG_FILE" >&2
}

log_warning() {
    echo "[$(date +%F\ %T)] WARNING: $*" | tee -a "$LOG_FILE" >&2
}

# Load configuration file if specified
load_config() {
    local config_file="$1"
    if [ -f "$config_file" ]; then
        log "Loading configuration from $config_file"
        source "$config_file"
    else
        log_error "Configuration file not found: $config_file"
        exit 1
    fi
}

# Check if module should be enabled
is_module_enabled() {
    local module="$1"
    case "$module" in
        nginx) [ "${ENABLE_NGINX:-1}" = "1" ] ;;
        apache) [ "${ENABLE_APACHE:-1}" = "1" ] ;;
        mysql) [ "${ENABLE_MYSQL:-1}" = "1" ] ;;
        php) [ "${ENABLE_PHP:-1}" = "1" ] ;;
        redis) [ "${ENABLE_REDIS:-1}" = "1" ] ;;
        system) [ "${ENABLE_SYSTEM:-1}" = "1" ] ;;
        atop) [ "${ENABLE_ATOP:-1}" = "1" ] ;;
        sar) [ "${ENABLE_SAR:-1}" = "1" ] ;;
        cron) [ "${ENABLE_CRON:-1}" = "1" ] ;;
        analyze-errors) [ "${ENABLE_ERROR_ANALYSIS:-1}" = "1" ] ;;
        bitrix) [ "${ENABLE_BITRIX:-1}" = "1" ] ;;
        *) return 1 ;;
    esac
}

# Check if module requirements are met
check_module_requirements() {
    local module="$1"
    case "$module" in
        nginx)
            if ! have nginx; then
                log_warning "nginx not found, skipping nginx audit"
                return 1
            fi
            ;;
        apache)
            if ! have apache2 && ! have httpd; then
                log_warning "apache2/httpd not found, skipping apache audit"
                return 1
            fi
            ;;
        mysql)
            if ! have mysql && ! have mysqladmin; then
                log_warning "mysql/mysqladmin not found, skipping mysql audit"
                return 1
            fi
            ;;
        php)
            if ! have php; then
                log_warning "php not found, skipping php audit"
                return 1
            fi
            ;;
        redis)
            if ! have redis-cli; then
                log_warning "redis-cli not found, skipping redis audit"
                return 1
            fi
            ;;
        atop)
            if ! have atopsar; then
                log_warning "atopsar not found, skipping atop audit"
                return 1
            fi
            ;;
        sar)
            if ! have sar && ! have sadf; then
                log_warning "sar/sadf not found, skipping sar audit"
                return 1
            fi
            ;;
        bitrix)
            if [ ! -d "/home/bitrix" ]; then
                log_warning "/home/bitrix directory not found, skipping bitrix audit"
                return 1
            fi
            ;;
    esac
    return 0
}

# Run a single audit module
run_audit_module() {
    local module="$1"
    local start_time end_time duration
    
    if ! is_module_enabled "$module"; then
        log "Module $module is disabled, skipping"
        return 0
    fi
    
    if ! check_module_requirements "$module"; then
        return 0
    fi
    
    log "Starting $module audit..."
    start_time=$(date +%s)
    
    case "$module" in
        nginx)
            if [ -f "$SCRIPT_DIR/run_nginx_audit.sh" ]; then
                bash "$SCRIPT_DIR/run_nginx_audit.sh" 2>&1 | tee -a "$LOG_FILE"
            else
                bash "$SCRIPT_DIR/collect_nginx.sh" 2>&1 | tee -a "$LOG_FILE"
            fi
            ;;
        apache)
            bash "$SCRIPT_DIR/collect_apache.sh" 2>&1 | tee -a "$LOG_FILE"
            ;;
        mysql)
            bash "$SCRIPT_DIR/collect_mysql.sh" 2>&1 | tee -a "$LOG_FILE"
            ;;
        php)
            bash "$SCRIPT_DIR/collect_php.sh" 2>&1 | tee -a "$LOG_FILE"
            ;;
        redis)
            bash "$SCRIPT_DIR/collect_redis.sh" 2>&1 | tee -a "$LOG_FILE"
            ;;
        system)
            bash "$SCRIPT_DIR/collect_system_info.sh" 2>&1 | tee -a "$LOG_FILE"
            ;;
        atop)
            ATOP_FULL_DAY="$ATOP_FULL_DAY" ATOP_START_TIME="$ATOP_START_TIME" ATOP_END_TIME="$ATOP_END_TIME" \
            bash "$SCRIPT_DIR/collect_atop.sh" 2>&1 | tee -a "$LOG_FILE"
            ;;
        sar)
            SAR_FULL_DAY="$SAR_FULL_DAY" SAR_START_TIME="$SAR_START_TIME" SAR_END_TIME="$SAR_END_TIME" SAR_DAYS="$SAR_DAYS" \
            bash "$SCRIPT_DIR/collect_sar.sh" 2>&1 | tee -a "$LOG_FILE"
            ;;
        cron)
            bash "$SCRIPT_DIR/collect_cron.sh" 2>&1 | tee -a "$LOG_FILE"
            ;;
        analyze-errors)
            ERROR_ANALYSIS_DAYS="$ERROR_ANALYSIS_DAYS" bash "$SCRIPT_DIR/analyze_nginx_errors.sh" 2>&1 | tee -a "$LOG_FILE"
            ERROR_ANALYSIS_DAYS="$ERROR_ANALYSIS_DAYS" bash "$SCRIPT_DIR/analyze_apache_errors.sh" 2>&1 | tee -a "$LOG_FILE"
            ;;
        bitrix)
            bash "$SCRIPT_DIR/collect_bitrix.sh" 2>&1 | tee -a "$LOG_FILE"
            ;;
        *)
            log_error "Unknown module: $module"
            return 1
            ;;
    esac
    
    local exit_code=$?
    end_time=$(date +%s)
    duration=$((end_time - start_time))
    
    if [ $exit_code -eq 0 ]; then
        log "Completed $module audit in ${duration}s"
        echo "✅ $module" >> "$SUMMARY_FILE"
    else
        log_error "Failed $module audit after ${duration}s (exit code: $exit_code)"
        echo "❌ $module (exit code: $exit_code)" >> "$SUMMARY_FILE"
    fi
    
    return $exit_code
}

# Run all enabled modules
run_all_modules() {
    local modules=("nginx" "apache" "mysql" "php" "redis" "system" "atop" "sar" "cron" "analyze-errors" "bitrix")
    local failed_modules=()
    local total_start_time total_end_time total_duration
    
    log "Starting comprehensive Bitrix24 audit..."
    total_start_time=$(date +%s)
    
    # Initialize summary file
    cat > "$SUMMARY_FILE" << SUMMARY_EOF
# Bitrix24 Audit Summary
**Generated:** $(date)
**Host:** $HOST
**Version:** $VERSION

## Module Status

SUMMARY_EOF
    
    log "Running modules in sequential mode"
    for module in "${modules[@]}"; do
        if ! run_audit_module "$module"; then
            failed_modules+=("$module")
        fi
    done
    
    total_end_time=$(date +%s)
    total_duration=$((total_end_time - total_start_time))
    
    # Finalize summary
    cat >> "$SUMMARY_FILE" << SUMMARY_EOF

## Summary
- **Total execution time:** ${total_duration}s
- **Failed modules:** ${#failed_modules[@]}
- **Log file:** $LOG_FILE

SUMMARY_EOF
    
    if [ ${#failed_modules[@]} -gt 0 ]; then
        echo "**Failed modules:** ${failed_modules[*]}" >> "$SUMMARY_FILE"
        log_error "Some modules failed: ${failed_modules[*]}"
    else
        echo "**All modules completed successfully**" >> "$SUMMARY_FILE"
        log "All modules completed successfully"
    fi
    
    log "Audit completed. Summary: $SUMMARY_FILE"
    return ${#failed_modules[@]}
}

# Main execution
main() {
    log "Starting Bitrix24 Audit Orchestrator v$VERSION"
    log "Host: $HOST"
    log "Audit directory: $AUDIT_DIR"
    
    # Create audit directory
    mkdir -p "$AUDIT_DIR"
    
    # Run audit
    if ! run_all_modules; then
        log_error "Audit completed with errors"
        exit 1
    else
        log "Audit completed successfully"
        exit 0
    fi
}

# Run main function
main "$@"
