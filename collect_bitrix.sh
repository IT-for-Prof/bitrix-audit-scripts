#!/usr/bin/env bash
# Bitrix24/Bitrix Framework cache and configuration analysis
# Usage: ./collect_bitrix.sh [--cache-only] [--settings-only] [--verbose]

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

##### Anti-interactive / BitrixVA #####
exec </dev/null
PS1=
PROMPT_COMMAND=
TMOUT=0
export PS1 PROMPT_COMMAND TMOUT
BASH_ENV=/dev/null
ENV=/dev/null
export BASH_ENV ENV
BX_NOMENU=1
BITRIX_NO_MENU=1
DISABLE_BITRIX_MENU=1
export BX_NOMENU BITRIX_NO_MENU DISABLE_BITRIX_MENU

##### Locale / PATH / Pagers #####
# Use shared audit_common.sh for locale management
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

# Version information
VERSION="2.1.0"

# Script directory
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Default configuration
CACHE_ONLY=0
SETTINGS_ONLY=0
VERBOSE=0

# Bitrix-specific configuration
BITRIX_CACHE_MAX_AGE_DAYS=${BITRIX_CACHE_MAX_AGE_DAYS:-30}
BITRIX_CACHE_WARNING_SIZE_GB=${BITRIX_CACHE_WARNING_SIZE_GB:-5}
BITRIX_CACHE_CRITICAL_SIZE_GB=${BITRIX_CACHE_CRITICAL_SIZE_GB:-10}
BITRIX_CACHE_DISK_PCT_CRITICAL=${BITRIX_CACHE_DISK_PCT_CRITICAL:-20}

# Parse command line arguments
while [[ $# -gt 0 ]]; do
    case "$1" in
        --cache-only)
            CACHE_ONLY=1
            shift
            ;;
        --settings-only)
            SETTINGS_ONLY=1
            shift
            ;;
        --verbose|-v)
            VERBOSE=1
            shift
            ;;
        --help|-h)
            echo "Usage: $0 [--cache-only] [--settings-only] [--verbose]"
            echo "Analyze Bitrix24/Bitrix Framework cache and configuration"
            echo ""
            echo "Options:"
            echo "  --cache-only     Only analyze cache directories"
            echo "  --settings-only  Only analyze .settings.php files"
            echo "  --verbose        Enable verbose output"
            echo "  --help           Show this help"
            exit 0
            ;;
        *)
            echo "Unknown option: $1" >&2
            exit 1
            ;;
    esac
done

# Output directories
OUT_DIR="${OUT_DIR:-${HOME}/bitrix_audit}"
mkdir -p "$OUT_DIR"

# AUDIT_DIR is prepared by audit_common.sh
BITRIX_OUT_DIR="$AUDIT_DIR/bitrix_audit"
mkdir -p "$BITRIX_OUT_DIR"

# Helper functions
log() {
    echo "[$(date +%F\ %T)] $*"
}

log_verbose() {
    if [ "$VERBOSE" = "1" ]; then
        echo "[$(date +%F\ %T)] VERBOSE: $*"
    fi
}

log_error() {
    echo "[$(date +%F\ %T)] ERROR: $*" >&2
}

hdr(){ printf '==== %s ====\n' "$1"; }

# Function to analyze Bitrix cache directories
analyze_bitrix_cache() {
    log "Анализ директорий кеша Битрикс..."
    
    local cache_analysis_file="$BITRIX_OUT_DIR/cache_analysis.txt"
    local recommendations_file="$BITRIX_OUT_DIR/cache_recommendations.txt"
    
    # Initialize output files
    : > "$cache_analysis_file"
    : > "$recommendations_file"
    
    # Bitrix paths to analyze
    local bitrix_paths=(
        "/home/bitrix/www"
        "/home/bitrix/ext_www"/*
    )
    
    local total_cache_size=0
    local total_files=0
    local total_old_files=0
    local sites_found=0
    
    echo "# Анализ кеша Битрикс - $(date)" >> "$cache_analysis_file"
    echo "" >> "$cache_analysis_file"
    
    for bitrix_path in "${bitrix_paths[@]}"; do
        [ -d "$bitrix_path" ] || continue
        
        # Determine site name
        local site_name=$(basename "$bitrix_path")
        if [ "$site_name" = "www" ]; then
            site_name="main"
        fi
        
        log_verbose "Анализ сайта: $site_name ($bitrix_path)"
        
        echo "=== Сайт: $site_name ===" >> "$cache_analysis_file"
        echo "Путь: $bitrix_path" >> "$cache_analysis_file"
        echo "" >> "$cache_analysis_file"
        
        sites_found=$((sites_found + 1))
        
        # Cache directories to analyze
        local cache_dirs=(
            "$bitrix_path/bitrix/cache"
            "$bitrix_path/bitrix/managed_cache"
            "$bitrix_path/bitrix/stack_cache"
            "$bitrix_path/upload"
        )
        
        local site_cache_size=0
        local site_files=0
        local site_old_files=0
        
        for cache_dir in "${cache_dirs[@]}"; do
            if [ -d "$cache_dir" ]; then
                log_verbose "Анализ директории: $cache_dir"
                
                # Get directory size
                local dir_size_bytes=$(du -sb "$cache_dir" 2>/dev/null | awk '{print $1}' || echo "0")
                local dir_size_mb=$((dir_size_bytes / 1024 / 1024))
                local dir_size_gb=$((dir_size_bytes / 1024 / 1024 / 1024))
                
                # Count files
                local file_count=$(find "$cache_dir" -type f 2>/dev/null | wc -l || echo "0")
                
                # Count old files (older than BITRIX_CACHE_MAX_AGE_DAYS)
                local old_files=$(find "$cache_dir" -type f -mtime +$BITRIX_CACHE_MAX_AGE_DAYS 2>/dev/null | wc -l || echo "0")
                
                # Get file type distribution
                local php_files=$(find "$cache_dir" -name "*.php" -type f 2>/dev/null | wc -l || echo "0")
                local html_files=$(find "$cache_dir" -name "*.html" -type f 2>/dev/null | wc -l || echo "0")
                local txt_files=$(find "$cache_dir" -name "*.txt" -type f 2>/dev/null | wc -l || echo "0")
                local other_files=$((file_count - php_files - html_files - txt_files))
                
                # Get top 10 largest files
                local largest_files=$(find "$cache_dir" -type f -printf '%s %p\n' 2>/dev/null | sort -nr | head -10 || echo "")
                
                # Write analysis results
                echo "Директория: $(basename "$cache_dir")" >> "$cache_analysis_file"
                echo "  Размер: ${dir_size_mb} MB (${dir_size_gb} GB)" >> "$cache_analysis_file"
                echo "  Файлов: $file_count" >> "$cache_analysis_file"
                echo "  Старых файлов (>${BITRIX_CACHE_MAX_AGE_DAYS} дней): $old_files" >> "$cache_analysis_file"
                echo "  Типы файлов:" >> "$cache_analysis_file"
                echo "    PHP: $php_files" >> "$cache_analysis_file"
                echo "    HTML: $html_files" >> "$cache_analysis_file"
                echo "    TXT: $txt_files" >> "$cache_analysis_file"
                echo "    Другие: $other_files" >> "$cache_analysis_file"
                
                if [ -n "$largest_files" ]; then
                    echo "  Топ-10 больших файлов:" >> "$cache_analysis_file"
                    echo "$largest_files" | while read -r size path; do
                        local size_mb=$((size / 1024 / 1024))
                        echo "    ${size_mb} MB: $path" >> "$cache_analysis_file"
                    done
                fi
                echo "" >> "$cache_analysis_file"
                
                # Accumulate totals
                site_cache_size=$((site_cache_size + dir_size_bytes))
                site_files=$((site_files + file_count))
                site_old_files=$((site_old_files + old_files))
                
                # Generate recommendations for this directory
                if [ "$dir_size_gb" -gt "$BITRIX_CACHE_CRITICAL_SIZE_GB" ]; then
                    echo "[КРИТИЧНО] Директория $(basename "$cache_dir") сайта $site_name занимает ${dir_size_gb} GB" >> "$recommendations_file"
                elif [ "$dir_size_gb" -gt "$BITRIX_CACHE_WARNING_SIZE_GB" ]; then
                    echo "[ВНИМАНИЕ] Директория $(basename "$cache_dir") сайта $site_name занимает ${dir_size_gb} GB" >> "$recommendations_file"
                fi
                
                if [ "$old_files" -gt 1000 ]; then
                    echo "[ВНИМАНИЕ] В директории $(basename "$cache_dir") сайта $site_name найдено $old_files старых файлов" >> "$recommendations_file"
                elif [ "$old_files" -gt 100 ]; then
                    echo "[РЕКОМЕНДАЦИЯ] В директории $(basename "$cache_dir") сайта $site_name найдено $old_files старых файлов" >> "$recommendations_file"
                fi
            else
                echo "Директория: $(basename "$cache_dir") - НЕ НАЙДЕНА" >> "$cache_analysis_file"
                echo "" >> "$cache_analysis_file"
            fi
        done
        
        # Site totals
        local site_size_mb=$((site_cache_size / 1024 / 1024))
        local site_size_gb=$((site_cache_size / 1024 / 1024 / 1024))
        
        echo "ИТОГО для сайта $site_name:" >> "$cache_analysis_file"
        echo "  Общий размер кеша: ${site_size_mb} MB (${site_size_gb} GB)" >> "$cache_analysis_file"
        echo "  Общее количество файлов: $site_files" >> "$cache_analysis_file"
        echo "  Старых файлов: $site_old_files" >> "$cache_analysis_file"
        echo "" >> "$cache_analysis_file"
        
        # Accumulate global totals
        total_cache_size=$((total_cache_size + site_cache_size))
        total_files=$((total_files + site_files))
        total_old_files=$((total_old_files + site_old_files))
    done
    
    # Global summary
    local total_size_mb=$((total_cache_size / 1024 / 1024))
    local total_size_gb=$((total_cache_size / 1024 / 1024 / 1024))
    
    echo "=== ОБЩАЯ СТАТИСТИКА ===" >> "$cache_analysis_file"
    echo "Найдено сайтов: $sites_found" >> "$cache_analysis_file"
    echo "Общий размер кеша: ${total_size_mb} MB (${total_size_gb} GB)" >> "$cache_analysis_file"
    echo "Общее количество файлов: $total_files" >> "$cache_analysis_file"
    echo "Старых файлов: $total_old_files" >> "$cache_analysis_file"
    
    # Calculate disk usage percentage
    local disk_total=$(df /home/bitrix 2>/dev/null | awk 'NR==2 {print $2}' || echo "0")
    local disk_used=$(df /home/bitrix 2>/dev/null | awk 'NR==2 {print $3}' || echo "0")
    local disk_pct=0
    if [ "$disk_total" -gt 0 ]; then
        disk_pct=$((100 * disk_used / disk_total))
    fi
    
    echo "Использование диска /home/bitrix: ${disk_pct}%" >> "$cache_analysis_file"
    
    # Global recommendations
    echo "" >> "$recommendations_file"
    echo "=== ОБЩИЕ РЕКОМЕНДАЦИИ ===" >> "$recommendations_file"
    
    if [ "$total_size_gb" -gt "$BITRIX_CACHE_CRITICAL_SIZE_GB" ]; then
        echo "[КРИТИЧНО] Общий размер кеша ${total_size_gb} GB превышает критический порог" >> "$recommendations_file"
    elif [ "$total_size_gb" -gt "$BITRIX_CACHE_WARNING_SIZE_GB" ]; then
        echo "[ВНИМАНИЕ] Общий размер кеша ${total_size_gb} GB превышает предупреждающий порог" >> "$recommendations_file"
    fi
    
    if [ "$disk_pct" -gt "$BITRIX_CACHE_DISK_PCT_CRITICAL" ]; then
        echo "[КРИТИЧНО] Использование диска ${disk_pct}% критично" >> "$recommendations_file"
    fi
    
    if [ "$total_old_files" -gt 10000 ]; then
        echo "[КРИТИЧНО] Найдено $total_old_files старых файлов кеша" >> "$recommendations_file"
    elif [ "$total_old_files" -gt 1000 ]; then
        echo "[ВНИМАНИЕ] Найдено $total_old_files старых файлов кеша" >> "$recommendations_file"
    fi
    
    echo "[РЕКОМЕНДАЦИЯ] Настройте автоматическую очистку кеша через cron" >> "$recommendations_file"
    echo "[РЕКОМЕНДАЦИЯ] Рассмотрите использование Memcached/Redis для кеширования" >> "$recommendations_file"
    
    log "Анализ кеша завершен. Найдено сайтов: $sites_found, общий размер: ${total_size_gb} GB"
}

# Function to analyze Bitrix settings files
analyze_bitrix_settings() {
    log "Анализ файлов настроек Битрикс..."
    
    local settings_analysis_file="$BITRIX_OUT_DIR/settings_analysis.txt"
    local settings_recommendations_file="$BITRIX_OUT_DIR/settings_recommendations.txt"
    
    # Initialize output files
    : > "$settings_analysis_file"
    : > "$settings_recommendations_file"
    
    echo "# Анализ настроек Битрикс - $(date)" >> "$settings_analysis_file"
    echo "" >> "$settings_analysis_file"
    
    # Candidate paths: per-installation files
    local bitrix_candidates=(
        "/home/bitrix/www/bitrix/.settings.php"
        "/home/bitrix/ext_www"/*/bitrix/.settings.php
    )
    
    local found=0
    for p in "${bitrix_candidates[@]}"; do
        for f in $p; do
            [ -f "$f" ] || continue
            found=$((found + 1))
            
            # Derive site name (best-effort)
            local parent1=$(dirname -- "$f")         # .../bitrix
            local parent2=$(dirname -- "$parent1")   # .../www or .../ext_www/<site>
            local site=$(basename -- "$parent2")
            # Normalize common www path to "www" (keeps unique)
            [ -z "$site" ] && site="site${found}"
            
            local dst_base="$BITRIX_OUT_DIR/${site}"
            mkdir -p "$BITRIX_OUT_DIR" 2>/dev/null || true
            cp -a "$f" "$dst_base.settings.php" 2>/dev/null || true
            
            # File metadata
            local perm_owner=$(stat -c '%A %a %U:%G' "$f" 2>/dev/null || echo "N/A")
            local fsize=$(stat -c '%s' "$f" 2>/dev/null || echo 0)
            
            log_verbose "Анализ настроек сайта: $site ($f)"
            
            echo "=== Сайт: $site ===" >> "$settings_analysis_file"
            echo "Файл настроек: $f" >> "$settings_analysis_file"
            echo "Размер: $fsize байт" >> "$settings_analysis_file"
            echo "Права/владелец: $perm_owner" >> "$settings_analysis_file"
            echo "" >> "$settings_analysis_file"
            
            # Extract exception_handling block values using PHP
            local eh_out="$dst_base.exception_handling.txt"
            local eh_json="$dst_base.exception_handling.json"
            
            # PHP snippet: include settings, find exception_handling and print specific keys
            local tmp_eh="$eh_out.tmp"
            with_locale php - "$f" <<'PHP' 2>/dev/null >"$tmp_eh" || true
<?php
$f = isset($argv[1]) ? $argv[1] : "";
$s = @include $f;
if (!is_array($s) && is_object($s)) $s = (array)$s;
$e = null;
if (is_array($s) && isset($s["exception_handling"])) {
  $eh = $s["exception_handling"];
  if (is_array($eh) && isset($eh["value"])) $e = $eh["value"]; else $e = $eh;
}
if (!$e) { exit(0); }
$out = [];
$out["debug"] = array_key_exists("debug", $e) ? var_export($e["debug"], true) : null;
$out["handled_errors_types"] = array_key_exists("handled_errors_types", $e) ? var_export($e["handled_errors_types"], true) : null;
$out["exception_errors_types"] = array_key_exists("exception_errors_types", $e) ? var_export($e["exception_errors_types"], true) : null;
$out["ignore_silence"] = array_key_exists("ignore_silence", $e) ? var_export($e["ignore_silence"], true) : null;
$out["assertion_throws_exception"] = array_key_exists("assertion_throws_exception", $e) ? var_export($e["assertion_throws_exception"], true) : null;
$out["assertion_error_type"] = array_key_exists("assertion_error_type", $e) ? var_export($e["assertion_error_type"], true) : null;
$logfile = null; $logsize = null;
if (isset($e["log"]["settings"])) {
  $ls = $e["log"]["settings"];
  if (is_array($ls) && isset($ls["file"])) $logfile = $ls["file"];
  if (is_array($ls) && isset($ls["log_size"])) $logsize = $ls["log_size"];
}
$out["log_file"] = $logfile;
$out["log_size"] = $logsize;
foreach ($out as $k => $v) {
  if (is_null($v)) echo "$k=<missing>\n";
  else echo "$k=" . trim($v, "'\"\n ") . "\n";
}
echo "--JSON-BEGIN--\n";
echo json_encode($e, JSON_UNESCAPED_SLASHES | JSON_UNESCAPED_UNICODE) . "\n";
PHP
            
            # Split temp into kv and json parts
            awk 'BEGIN{json=0} /^--JSON-BEGIN--/{json=1; next} { if(!json) print > "'"$eh_out"'"; else print > "'"$eh_json"'" }' "$tmp_eh" || true
            rm -f "$tmp_eh" 2>/dev/null || true
            
            # If EH_OUT missing or empty, create a marker
            if [ ! -s "$eh_out" ]; then echo "exception_handling=absent" > "$eh_out"; fi
            
            # Inspect exception log path if provided
            local eh_log_path=$(grep -m1 '^log_file=' "$eh_out" 2>/dev/null | sed 's/^log_file=//' || true)
            eh_log_path=${eh_log_path:-}
            
            # Settings file perms check
            local ss_mode=$(stat -c '%a' "$f" 2>/dev/null || echo "0")
            local ss_human=$(stat -c '%A %a %U:%G' "$f" 2>/dev/null || echo "N/A")
            local ss_warn="OK"
            local last_digit=${ss_mode: -1}
            if [ "$last_digit" != "0" ]; then ss_warn="WARN: world perms"; fi
            
            # Write analysis results
            echo "Настройки exception_handling:" >> "$settings_analysis_file"
            sed -n '1,20p' "$eh_out" | sed 's/^/  /' 2>/dev/null >> "$settings_analysis_file" || true
            echo "Путь к логу исключений: ${eh_log_path:-<не настроен>}" >> "$settings_analysis_file"
            
            # Check exception log file
            if [ -n "$eh_log_path" ]; then
                if [ -f "$eh_log_path" ]; then
                    local lf_info=$(stat -c '%A %a %U:%G %s' "$eh_log_path" 2>/dev/null || echo "N/A")
                    echo "Лог исключений найден: да" >> "$settings_analysis_file"
                    echo "Информация о логе: $lf_info" >> "$settings_analysis_file"
                    
                    # Capture bounded tail of exception log
                    tail -n 200 "$eh_log_path" > "$BITRIX_OUT_DIR/${site}.exceptions.log.tail.txt" 2>/dev/null || true
                    if [ -f "$BITRIX_OUT_DIR/${site}.exceptions.log.tail.txt" ]; then
                        local b=$(wc -c < "$BITRIX_OUT_DIR/${site}.exceptions.log.tail.txt" 2>/dev/null || echo 0)
                        if [ "$b" -gt 1048576 ]; then gzip -9f "$BITRIX_OUT_DIR/${site}.exceptions.log.tail.txt"; fi
                    fi
                else
                    echo "Лог исключений найден: нет" >> "$settings_analysis_file"
                fi
            fi
            
            echo "" >> "$settings_analysis_file"
            
            # Generate recommendations
            if [ "$ss_warn" != "OK" ]; then
                echo "[БЕЗОПАСНОСТЬ] Файл настроек сайта $site имеет небезопасные права доступа" >> "$settings_recommendations_file"
            fi
            
            if [ -z "$eh_log_path" ]; then
                echo "[РЕКОМЕНДАЦИЯ] Настройте логирование исключений для сайта $site" >> "$settings_recommendations_file"
            fi
            
            local debug_mode=$(grep -m1 '^debug=' "$eh_out" 2>/dev/null | sed 's/^debug=//' || echo "")
            if [ "$debug_mode" = "true" ]; then
                echo "[ВНИМАНИЕ] Режим отладки включен для сайта $site" >> "$settings_recommendations_file"
            fi
        done
    done
    
    if [ $found -eq 0 ]; then
        echo "Файлы настроек Битрикс не найдены" >> "$settings_analysis_file"
        echo "[ИНФОРМАЦИЯ] Файлы настроек Битрикс не найдены в стандартных местах" >> "$settings_recommendations_file"
    else
        log "Анализ настроек завершен. Найдено сайтов: $found"
    fi
}

# Main execution
main() {
    log "Запуск анализа Битрикс v$VERSION"
    
    if [ "$SETTINGS_ONLY" = "1" ]; then
        analyze_bitrix_settings
    elif [ "$CACHE_ONLY" = "1" ]; then
        analyze_bitrix_cache
    else
        analyze_bitrix_settings
        analyze_bitrix_cache
    fi
    
    # Create summary file
    local summary_file="$BITRIX_OUT_DIR/summary.txt"
    : > "$summary_file"
    
    echo "# Сводка анализа Битрикс - $(date)" >> "$summary_file"
    echo "" >> "$summary_file"
    
    if [ -f "$BITRIX_OUT_DIR/settings_analysis.txt" ]; then
        echo "=== Анализ настроек ===" >> "$summary_file"
        head -50 "$BITRIX_OUT_DIR/settings_analysis.txt" >> "$summary_file"
        echo "" >> "$summary_file"
    fi
    
    if [ -f "$BITRIX_OUT_DIR/cache_analysis.txt" ]; then
        echo "=== Анализ кеша ===" >> "$summary_file"
        head -50 "$BITRIX_OUT_DIR/cache_analysis.txt" >> "$summary_file"
        echo "" >> "$summary_file"
    fi
    
    # Create archive
    if [ -d "$BITRIX_OUT_DIR" ]; then
        create_and_verify_archive "$BITRIX_OUT_DIR" "bitrix_audit.tgz"
    fi
    
    log "Анализ Битрикс завершен. Результаты сохранены в: $BITRIX_OUT_DIR"
}

# Run main function
main "$@"
