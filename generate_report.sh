#!/usr/bin/env bash
# Report generator for Bitrix24 audit results
# Usage: ./generate_report.sh [--input-dir DIR] [--output-dir DIR] [--formats FORMATS]

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
OUTPUT_DIR="${OUTPUT_DIR:-${AUDIT_DIR}/reports}"
FORMATS="${FORMATS:-markdown,json}"
HOST="$(hostname -f 2>/dev/null || hostname)"
TIMESTAMP="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

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
        --formats)
            shift
            FORMATS="$1"
            shift
            ;;
        --help|-h)
            echo "Usage: $0 [--input-dir DIR] [--output-dir DIR] [--formats FORMATS]"
            echo "Generate reports from Bitrix24 audit data"
            echo "Available formats: markdown,json,html,pdf"
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

# Function to collect audit data
collect_audit_data() {
    log "Сбор данных аудита..."
    
    local data=()
    
    # System information
    if [ -f "${INPUT_DIR}/system_info_audit/system.info" ]; then
        data+=("system:${INPUT_DIR}/system_info_audit/system.info")
    fi
    
    # MySQL audit
    if [ -f "${INPUT_DIR}/mysql_audit/mysql_audit.txt" ]; then
        data+=("mysql:${INPUT_DIR}/mysql_audit/mysql_audit.txt")
    fi
    
    # PHP audit
    if [ -f "${INPUT_DIR}/php_audit/report.txt" ]; then
        data+=("php:${INPUT_DIR}/php_audit/report.txt")
    fi
    
    # Nginx audit
    if [ -f "${INPUT_DIR}/nginx_audit/nginx_audit.txt" ]; then
        data+=("nginx:${INPUT_DIR}/nginx_audit/nginx_audit.txt")
    fi
    
    # Redis audit
    if [ -f "${INPUT_DIR}/redis_audit/out/recommendations.txt" ]; then
        data+=("redis:${INPUT_DIR}/redis_audit/out/recommendations.txt")
    fi
    
    # Analysis results
    if [ -f "${INPUT_DIR}/analysis/recommendations.txt" ]; then
        data+=("analysis:${INPUT_DIR}/analysis/recommendations.txt")
    fi
    
    if [ -f "${INPUT_DIR}/analysis/priority_recommendations.txt" ]; then
        data+=("priority:${INPUT_DIR}/analysis/priority_recommendations.txt")
    fi
    
    # Optimal parameters
    if [ -f "${INPUT_DIR}/optimal_params/optimal_params_summary.txt" ]; then
        data+=("optimal:${INPUT_DIR}/optimal_params/optimal_params_summary.txt")
    fi
    
    printf '%s\n' "${data[@]}"
}

# Function to generate executive summary
generate_executive_summary() {
    local output_file="$1"
    
    log "Генерация executive summary..."
    
    cat > "$output_file" << EOF
# Executive Summary - Bitrix24 Audit Report

**Дата:** $(date)
**Сервер:** $HOST
**Версия отчета:** $VERSION

## Краткое резюме

Данный отчет содержит результаты комплексного аудита сервера с установленным Bitrix24. 
Анализ включает проверку системных ресурсов, конфигураций служб, производительности и безопасности.

## Ключевые находки

EOF

    # Count critical issues
    local critical_count=0
    local security_count=0
    local warning_count=0
    
    if [ -f "${INPUT_DIR}/analysis/priority_recommendations.txt" ]; then
        critical_count=$(grep -c "КРИТИЧНО:" "${INPUT_DIR}/analysis/priority_recommendations.txt" 2>/dev/null || echo "0")
        security_count=$(grep -c "БЕЗОПАСНОСТЬ:" "${INPUT_DIR}/analysis/priority_recommendations.txt" 2>/dev/null || echo "0")
        warning_count=$(grep -c "ВНИМАНИЕ:" "${INPUT_DIR}/analysis/priority_recommendations.txt" 2>/dev/null || echo "0")
    fi
    
    cat >> "$output_file" << EOF
- **Критичных проблем:** $critical_count
- **Проблем безопасности:** $security_count  
- **Предупреждений:** $warning_count

## Приоритетные рекомендации

EOF

    # Add top 5 critical recommendations
    if [ -f "${INPUT_DIR}/analysis/priority_recommendations.txt" ]; then
        local critical_recommendations=$(grep "КРИТИЧНО:" "${INPUT_DIR}/analysis/priority_recommendations.txt" | head -5)
        if [ -n "$critical_recommendations" ]; then
            echo "$critical_recommendations" | while IFS= read -r line; do
                echo "- $line" >> "$output_file"
            done
        else
            echo "- Критичных проблем не обнаружено" >> "$output_file"
        fi
    fi
    
    cat >> "$output_file" << EOF

## Следующие шаги

1. **Немедленно** устраните все критические проблемы
2. **В течение недели** решите проблемы безопасности
3. **В течение месяца** оптимизируйте предупреждения
4. **Регулярно** проводите мониторинг производительности

## Контакты

Для получения дополнительной информации или помощи в устранении проблем обратитесь к системному администратору.

---
*Отчет сгенерирован автоматически системой аудита Bitrix24 v$VERSION*
EOF

    log "Executive summary сохранен в $output_file"
}

# Function to generate technical report
generate_technical_report() {
    local output_file="$1"
    
    log "Генерация технического отчета..."
    
    cat > "$output_file" << EOF
# Технический отчет - Bitrix24 Audit

**Дата:** $(date)
**Сервер:** $HOST
**Версия отчета:** $VERSION

## Содержание

1. [Системные ресурсы](#системные-ресурсы)
2. [Конфигурация MySQL](#конфигурация-mysql)
3. [Конфигурация PHP](#конфигурация-php)
4. [Конфигурация Nginx](#конфигурация-nginx)
5. [Конфигурация Redis](#конфигурация-redis)
6. [Параметры ядра](#параметры-ядра)
7. [Рекомендации](#рекомендации)
8. [Оптимальные параметры](#оптимальные-параметры)

## Системные ресурсы

EOF

    # Add system information
    if [ -f "${INPUT_DIR}/system_info_audit/system.info" ]; then
        echo "### Основная информация" >> "$output_file"
        echo '```' >> "$output_file"
        head -20 "${INPUT_DIR}/system_info_audit/system.info" >> "$output_file"
        echo '```' >> "$output_file"
        echo "" >> "$output_file"
        
        echo "### Использование памяти" >> "$output_file"
        echo '```' >> "$output_file"
        grep -A 10 "MemTotal:" "${INPUT_DIR}/system_info_audit/system.info" >> "$output_file" 2>/dev/null || echo "Информация о памяти недоступна" >> "$output_file"
        echo '```' >> "$output_file"
        echo "" >> "$output_file"
        
        echo "### Загрузка системы" >> "$output_file"
        echo '```' >> "$output_file"
        grep "load average:" "${INPUT_DIR}/system_info_audit/system.info" >> "$output_file" 2>/dev/null || echo "Информация о загрузке недоступна" >> "$output_file"
        echo '```' >> "$output_file"
        echo "" >> "$output_file"
    fi
    
    # Add MySQL information
    if [ -f "${INPUT_DIR}/mysql_audit/mysql_audit.txt" ]; then
        cat >> "$output_file" << EOF
## Конфигурация MySQL

EOF
        echo "### Версия и основные параметры" >> "$output_file"
        echo '```' >> "$output_file"
        head -30 "${INPUT_DIR}/mysql_audit/mysql_audit.txt" >> "$output_file"
        echo '```' >> "$output_file"
        echo "" >> "$output_file"
    fi
    
    # Add PHP information
    if [ -f "${INPUT_DIR}/php_audit/report.txt" ]; then
        cat >> "$output_file" << EOF
## Конфигурация PHP

EOF
        echo "### Основные параметры PHP" >> "$output_file"
        echo '```' >> "$output_file"
        head -20 "${INPUT_DIR}/php_audit/report.txt" >> "$output_file"
        echo '```' >> "$output_file"
        echo "" >> "$output_file"
    fi
    
    # Add Nginx information
    if [ -f "${INPUT_DIR}/nginx_audit/nginx_audit.txt" ]; then
        cat >> "$output_file" << EOF
## Конфигурация Nginx

EOF
        echo "### Основные параметры Nginx" >> "$output_file"
        echo '```' >> "$output_file"
        head -20 "${INPUT_DIR}/nginx_audit/nginx_audit.txt" >> "$output_file"
        echo '```' >> "$output_file"
        echo "" >> "$output_file"
    fi
    
    # Add Redis information
    if [ -f "${INPUT_DIR}/redis_audit/out/recommendations.txt" ]; then
        cat >> "$output_file" << EOF
## Конфигурация Redis

EOF
        echo "### Рекомендации Redis" >> "$output_file"
        echo '```' >> "$output_file"
        cat "${INPUT_DIR}/redis_audit/out/recommendations.txt" >> "$output_file"
        echo '```' >> "$output_file"
        echo "" >> "$output_file"
    fi
    
    # Add recommendations
    if [ -f "${INPUT_DIR}/analysis/recommendations.txt" ]; then
        cat >> "$output_file" << EOF
## Рекомендации

EOF
        echo '```' >> "$output_file"
        cat "${INPUT_DIR}/analysis/recommendations.txt" >> "$output_file"
        echo '```' >> "$output_file"
        echo "" >> "$output_file"
    fi
    
    # Add optimal parameters
    if [ -f "${INPUT_DIR}/optimal_params/optimal_params_summary.txt" ]; then
        cat >> "$output_file" << EOF
## Оптимальные параметры

EOF
        echo '```' >> "$output_file"
        cat "${INPUT_DIR}/optimal_params/optimal_params_summary.txt" >> "$output_file"
        echo '```' >> "$output_file"
        echo "" >> "$output_file"
    fi
    
    log "Технический отчет сохранен в $output_file"
}

# Function to generate JSON report
generate_json_report() {
    local output_file="$1"
    
    log "Генерация JSON отчета..."
    
    cat > "$output_file" << EOF
{
  "report_metadata": {
    "generated_at": "$TIMESTAMP",
    "host": "$HOST",
    "version": "$VERSION",
    "report_type": "bitrix24_audit"
  },
  "summary": {
EOF

    # Count issues
    local critical_count=0
    local security_count=0
    local warning_count=0
    
    if [ -f "${INPUT_DIR}/analysis/priority_recommendations.txt" ]; then
        critical_count=$(grep -c "КРИТИЧНО:" "${INPUT_DIR}/analysis/priority_recommendations.txt" 2>/dev/null || echo "0")
        security_count=$(grep -c "БЕЗОПАСНОСТЬ:" "${INPUT_DIR}/analysis/priority_recommendations.txt" 2>/dev/null || echo "0")
        warning_count=$(grep -c "ВНИМАНИЕ:" "${INPUT_DIR}/analysis/priority_recommendations.txt" 2>/dev/null || echo "0")
    fi
    
    cat >> "$output_file" << EOF
    "critical_issues": $critical_count,
    "security_issues": $security_count,
    "warnings": $warning_count
  },
  "components": {
EOF

    # Add component data
    local components=()
    
    if [ -f "${INPUT_DIR}/system_info_audit/system.info" ]; then
        components+=('    "system": "available"')
    fi
    
    if [ -f "${INPUT_DIR}/mysql_audit/mysql_audit.txt" ]; then
        components+=('    "mysql": "available"')
    fi
    
    if [ -f "${INPUT_DIR}/php_audit/report.txt" ]; then
        components+=('    "php": "available"')
    fi
    
    if [ -f "${INPUT_DIR}/nginx_audit/nginx_audit.txt" ]; then
        components+=('    "nginx": "available"')
    fi
    
    if [ -f "${INPUT_DIR}/redis_audit/out/recommendations.txt" ]; then
        components+=('    "redis": "available"')
    fi
    
    if [ ${#components[@]} -gt 0 ]; then
        printf '%s,\n' "${components[@]}" | sed '$s/,$//' >> "$output_file"
    fi
    
    cat >> "$output_file" << EOF
  },
  "recommendations": {
EOF

    # Add recommendations
    if [ -f "${INPUT_DIR}/analysis/priority_recommendations.txt" ]; then
        echo '    "priority": [' >> "$output_file"
        local recommendations=$(grep -E "(КРИТИЧНО|БЕЗОПАСНОСТЬ|ВНИМАНИЕ):" "${INPUT_DIR}/analysis/priority_recommendations.txt" | head -10)
        if [ -n "$recommendations" ]; then
            echo "$recommendations" | while IFS= read -r line; do
                echo "      \"$line\"," >> "$output_file"
            done | sed '$s/,$//'
        fi
        echo '    ]' >> "$output_file"
    else
        echo '    "priority": []' >> "$output_file"
    fi
    
    cat >> "$output_file" << EOF
  },
  "files": {
EOF

    # Add file references
    local files=()
    
    if [ -f "${INPUT_DIR}/analysis/recommendations.txt" ]; then
        files+=("    \"recommendations\": \"${INPUT_DIR}/analysis/recommendations.txt\"")
    fi
    
    if [ -f "${INPUT_DIR}/analysis/priority_recommendations.txt" ]; then
        files+=("    \"priority_recommendations\": \"${INPUT_DIR}/analysis/priority_recommendations.txt\"")
    fi
    
    if [ -f "${INPUT_DIR}/optimal_params/optimal_params_summary.txt" ]; then
        files+=("    \"optimal_parameters\": \"${INPUT_DIR}/optimal_params/optimal_params_summary.txt\"")
    fi
    
    if [ ${#files[@]} -gt 0 ]; then
        printf '%s,\n' "${files[@]}" | sed '$s/,$//' >> "$output_file"
    fi
    
    cat >> "$output_file" << EOF
  }
}
EOF

    log "JSON отчет сохранен в $output_file"
}

# Function to generate HTML report
generate_html_report() {
    local output_file="$1"
    
    log "Генерация HTML отчета..."
    
    cat > "$output_file" << EOF
<!DOCTYPE html>
<html lang="ru">
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <title>Bitrix24 Audit Report - $HOST</title>
    <style>
        body {
            font-family: -apple-system, BlinkMacSystemFont, 'Segoe UI', Roboto, sans-serif;
            line-height: 1.6;
            color: #333;
            max-width: 1200px;
            margin: 0 auto;
            padding: 20px;
            background-color: #f5f5f5;
        }
        .container {
            background: white;
            padding: 30px;
            border-radius: 8px;
            box-shadow: 0 2px 10px rgba(0,0,0,0.1);
        }
        h1 {
            color: #2c3e50;
            border-bottom: 3px solid #3498db;
            padding-bottom: 10px;
        }
        h2 {
            color: #34495e;
            margin-top: 30px;
        }
        h3 {
            color: #7f8c8d;
        }
        .summary {
            background: #ecf0f1;
            padding: 20px;
            border-radius: 5px;
            margin: 20px 0;
        }
        .critical {
            color: #e74c3c;
            font-weight: bold;
        }
        .security {
            color: #f39c12;
            font-weight: bold;
        }
        .warning {
            color: #f1c40f;
            font-weight: bold;
        }
        .info {
            color: #3498db;
        }
        pre {
            background: #2c3e50;
            color: #ecf0f1;
            padding: 15px;
            border-radius: 5px;
            overflow-x: auto;
        }
        .nav {
            background: #34495e;
            padding: 15px;
            border-radius: 5px;
            margin-bottom: 20px;
        }
        .nav a {
            color: white;
            text-decoration: none;
            margin-right: 20px;
            padding: 5px 10px;
            border-radius: 3px;
        }
        .nav a:hover {
            background: #3498db;
        }
        .footer {
            margin-top: 40px;
            padding-top: 20px;
            border-top: 1px solid #bdc3c7;
            color: #7f8c8d;
            text-align: center;
        }
    </style>
</head>
<body>
    <div class="container">
        <h1>Bitrix24 Audit Report</h1>
        
        <div class="nav">
            <a href="#summary">Сводка</a>
            <a href="#system">Система</a>
            <a href="#mysql">MySQL</a>
            <a href="#php">PHP</a>
            <a href="#nginx">Nginx</a>
            <a href="#redis">Redis</a>
            <a href="#recommendations">Рекомендации</a>
        </div>
        
        <div class="summary">
            <h2 id="summary">Краткая сводка</h2>
            <p><strong>Дата:</strong> $(date)</p>
            <p><strong>Сервер:</strong> $HOST</p>
            <p><strong>Версия отчета:</strong> $VERSION</p>
EOF

    # Add summary statistics
    local critical_count=0
    local security_count=0
    local warning_count=0
    
    if [ -f "${INPUT_DIR}/analysis/priority_recommendations.txt" ]; then
        critical_count=$(grep -c "КРИТИЧНО:" "${INPUT_DIR}/analysis/priority_recommendations.txt" 2>/dev/null || echo "0")
        security_count=$(grep -c "БЕЗОПАСНОСТЬ:" "${INPUT_DIR}/analysis/priority_recommendations.txt" 2>/dev/null || echo "0")
        warning_count=$(grep -c "ВНИМАНИЕ:" "${INPUT_DIR}/analysis/priority_recommendations.txt" 2>/dev/null || echo "0")
    fi
    
    cat >> "$output_file" << EOF
            <p><span class="critical">Критичных проблем:</span> $critical_count</p>
            <p><span class="security">Проблем безопасности:</span> $security_count</p>
            <p><span class="warning">Предупреждений:</span> $warning_count</p>
        </div>
EOF

    # Add system information
    if [ -f "${INPUT_DIR}/system_info_audit/system.info" ]; then
        cat >> "$output_file" << EOF
        
        <h2 id="system">Системная информация</h2>
        <h3>Основная информация</h3>
        <pre>
EOF
        head -10 "${INPUT_DIR}/system_info_audit/system.info" >> "$output_file"
        cat >> "$output_file" << EOF
        </pre>
EOF
    fi
    
    # Add MySQL information
    if [ -f "${INPUT_DIR}/mysql_audit/mysql_audit.txt" ]; then
        cat >> "$output_file" << EOF
        
        <h2 id="mysql">MySQL</h2>
        <h3>Основные параметры</h3>
        <pre>
EOF
        head -15 "${INPUT_DIR}/mysql_audit/mysql_audit.txt" >> "$output_file"
        cat >> "$output_file" << EOF
        </pre>
EOF
    fi
    
    # Add PHP information
    if [ -f "${INPUT_DIR}/php_audit/report.txt" ]; then
        cat >> "$output_file" << EOF
        
        <h2 id="php">PHP</h2>
        <h3>Основные параметры</h3>
        <pre>
EOF
        head -15 "${INPUT_DIR}/php_audit/report.txt" >> "$output_file"
        cat >> "$output_file" << EOF
        </pre>
EOF
    fi
    
    # Add Nginx information
    if [ -f "${INPUT_DIR}/nginx_audit/nginx_audit.txt" ]; then
        cat >> "$output_file" << EOF
        
        <h2 id="nginx">Nginx</h2>
        <h3>Основные параметры</h3>
        <pre>
EOF
        head -15 "${INPUT_DIR}/nginx_audit/nginx_audit.txt" >> "$output_file"
        cat >> "$output_file" << EOF
        </pre>
EOF
    fi
    
    # Add Redis information
    if [ -f "${INPUT_DIR}/redis_audit/out/recommendations.txt" ]; then
        cat >> "$output_file" << EOF
        
        <h2 id="redis">Redis</h2>
        <h3>Рекомендации</h3>
        <pre>
EOF
        cat "${INPUT_DIR}/redis_audit/out/recommendations.txt" >> "$output_file"
        cat >> "$output_file" << EOF
        </pre>
EOF
    fi
    
    # Add recommendations
    if [ -f "${INPUT_DIR}/analysis/priority_recommendations.txt" ]; then
        cat >> "$output_file" << EOF
        
        <h2 id="recommendations">Приоритетные рекомендации</h2>
        <h3>Критичные проблемы</h3>
        <ul>
EOF
        grep "КРИТИЧНО:" "${INPUT_DIR}/analysis/priority_recommendations.txt" | head -5 | while IFS= read -r line; do
            echo "            <li class=\"critical\">$line</li>" >> "$output_file"
        done
        cat >> "$output_file" << EOF
        </ul>
        
        <h3>Проблемы безопасности</h3>
        <ul>
EOF
        grep "БЕЗОПАСНОСТЬ:" "${INPUT_DIR}/analysis/priority_recommendations.txt" | head -5 | while IFS= read -r line; do
            echo "            <li class=\"security\">$line</li>" >> "$output_file"
        done
        cat >> "$output_file" << EOF
        </ul>
        
        <h3>Предупреждения</h3>
        <ul>
EOF
        grep "ВНИМАНИЕ:" "${INPUT_DIR}/analysis/priority_recommendations.txt" | head -5 | while IFS= read -r line; do
            echo "            <li class=\"warning\">$line</li>" >> "$output_file"
        done
        cat >> "$output_file" << EOF
        </ul>
EOF
    fi
    
    cat >> "$output_file" << EOF
        
        <div class="footer">
            <p>Отчет сгенерирован автоматически системой аудита Bitrix24 v$VERSION</p>
            <p>Дата генерации: $(date)</p>
        </div>
    </div>
</body>
</html>
EOF

    log "HTML отчет сохранен в $output_file"
}

# Function to generate PDF report (if wkhtmltopdf is available)
generate_pdf_report() {
    local html_file="$1"
    local output_file="$2"
    
    if command -v wkhtmltopdf >/dev/null 2>&1; then
        log "Генерация PDF отчета..."
        wkhtmltopdf --page-size A4 --margin-top 0.75in --margin-right 0.75in --margin-bottom 0.75in --margin-left 0.75in "$html_file" "$output_file" 2>/dev/null
        if [ $? -eq 0 ]; then
            log "PDF отчет сохранен в $output_file"
        else
            log_warning "Не удалось сгенерировать PDF отчет"
        fi
    else
        log_warning "wkhtmltopdf не установлен, PDF отчет не сгенерирован"
        log "Для генерации PDF установите: apt-get install wkhtmltopdf"
    fi
}

# Main execution
main() {
    log "Запуск генерации отчетов для Bitrix24 v$VERSION"
    
    # Check if input directory exists
    if [ ! -d "$INPUT_DIR" ]; then
        log_error "Входная директория не найдена: $INPUT_DIR"
        exit 1
    fi
    
    # Generate reports based on requested formats
    IFS=',' read -ra FORMAT_ARRAY <<< "$FORMATS"
    
    for format in "${FORMAT_ARRAY[@]}"; do
        format=$(echo "$format" | tr -d ' ')
        
        case "$format" in
            "markdown")
                log "Генерация Markdown отчетов..."
                generate_executive_summary "${OUTPUT_DIR}/executive_summary.md"
                generate_technical_report "${OUTPUT_DIR}/technical_report.md"
                ;;
            "json")
                log "Генерация JSON отчета..."
                generate_json_report "${OUTPUT_DIR}/audit_report.json"
                ;;
            "html")
                log "Генерация HTML отчета..."
                generate_html_report "${OUTPUT_DIR}/audit_report.html"
                ;;
            "pdf")
                log "Генерация PDF отчета..."
                if [ -f "${OUTPUT_DIR}/audit_report.html" ]; then
                    generate_pdf_report "${OUTPUT_DIR}/audit_report.html" "${OUTPUT_DIR}/audit_report.pdf"
                else
                    log_warning "HTML файл не найден, сначала генерируем HTML..."
                    generate_html_report "${OUTPUT_DIR}/audit_report.html"
                    generate_pdf_report "${OUTPUT_DIR}/audit_report.html" "${OUTPUT_DIR}/audit_report.pdf"
                fi
                ;;
            *)
                log_warning "Неизвестный формат: $format"
                ;;
        esac
    done
    
    log "Генерация отчетов завершена"
    log "Отчеты сохранены в: $OUTPUT_DIR"
    
    # List generated files
    log "Сгенерированные файлы:"
    ls -la "$OUTPUT_DIR"/*.md "$OUTPUT_DIR"/*.json "$OUTPUT_DIR"/*.html "$OUTPUT_DIR"/*.pdf 2>/dev/null || true
    
    # Create archive
    if [ -d "$OUTPUT_DIR" ]; then
        create_and_verify_archive "$OUTPUT_DIR" "reports.tgz"
    fi
}

# Run main function
main "$@"
