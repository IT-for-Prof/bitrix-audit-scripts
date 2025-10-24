#!/usr/bin/env bash
# Pre-production verification script for Bitrix24 Audit
# Comprehensive check before deployment

set -euo pipefail

# Version information
VERSION="2.1.0"

# Script directory
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Source common functions
source "$SCRIPT_DIR/audit_common.sh"

# Setup locale
setup_locale

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Counters
TOTAL_CHECKS=0
PASSED_CHECKS=0
FAILED_CHECKS=0
WARNING_CHECKS=0

# Logging functions
log_info() {
    echo -e "${BLUE}[INFO]${NC} $1"
}

log_success() {
    echo -e "${GREEN}[PASS]${NC} $1"
    ((PASSED_CHECKS++))
}

log_warning() {
    echo -e "${YELLOW}[WARN]${NC} $1"
    ((WARNING_CHECKS++))
}

log_error() {
    echo -e "${RED}[FAIL]${NC} $1"
    ((FAILED_CHECKS++))
}

log_check() {
    echo -e "${BLUE}[CHECK]${NC} $1"
    ((TOTAL_CHECKS++))
}

# Check syntax of all shell scripts
check_syntax() {
    log_info "=== Проверка синтаксиса скриптов ==="
    
    local scripts=(
        "run_all_audits.sh"
        "check_requirements.sh"
        "analyze_and_recommend.sh"
        "collect_nginx.sh"
        "collect_mysql.sh"
        "collect_php.sh"
        "collect_redis.sh"
        "collect_system_info.sh"
        "collect_atop.sh"
        "collect_sar.sh"
        "collect_cron.sh"
        "collect_bitrix.sh"
        "collect_apache.sh"
        "analyze_nginx_errors.sh"
        "analyze_apache_errors.sh"
        "calculate_optimal_params.sh"
        "generate_report.sh"
        "setup_monitoring.sh"
    )
    
    local syntax_errors=0
    
    for script in "${scripts[@]}"; do
        if [ -f "$SCRIPT_DIR/$script" ]; then
            log_check "Проверка синтаксиса: $script"
            if timeout 10 bash -n "$SCRIPT_DIR/$script" 2>/dev/null; then
                log_success "Синтаксис $script корректен"
            else
                log_error "Ошибка синтаксиса в $script"
                ((syntax_errors++))
            fi
        else
            log_warning "Файл $script не найден"
        fi
    done
    
    if [ $syntax_errors -eq 0 ]; then
        log_success "Все скрипты имеют корректный синтаксис"
    else
        log_error "Найдено $syntax_errors ошибок синтаксиса"
    fi
}

# Check shellcheck warnings
check_shellcheck() {
    log_info "=== Проверка ShellCheck ==="
    
    if ! command -v shellcheck >/dev/null 2>&1; then
        log_warning "ShellCheck не установлен, пропускаем проверку"
        return 0
    fi
    
    local scripts=(
        "run_all_audits.sh"
        "check_requirements.sh"
        "analyze_and_recommend.sh"
        "collect_nginx.sh"
        "collect_mysql.sh"
        "collect_php.sh"
        "collect_redis.sh"
        "collect_system_info.sh"
        "collect_atop.sh"
        "collect_sar.sh"
        "collect_cron.sh"
        "collect_bitrix.sh"
        "collect_apache.sh"
        "analyze_nginx_errors.sh"
        "analyze_apache_errors.sh"
        "calculate_optimal_params.sh"
        "generate_report.sh"
        "setup_monitoring.sh"
    )
    
    local shellcheck_warnings=0
    
    for script in "${scripts[@]}"; do
        if [ -f "$SCRIPT_DIR/$script" ]; then
            log_check "ShellCheck: $script"
            local warnings
            warnings=$(shellcheck "$SCRIPT_DIR/$script" 2>&1 | grep -c "SC[0-9]" || echo "0")
            if [ "$warnings" -eq 0 ]; then
                log_success "ShellCheck: $script без предупреждений"
            else
                log_warning "ShellCheck: $script имеет $warnings предупреждений"
                ((shellcheck_warnings++))
            fi
        fi
    done
    
    if [ $shellcheck_warnings -eq 0 ]; then
        log_success "Все скрипты прошли проверку ShellCheck"
    else
        log_warning "Найдено предупреждений ShellCheck в $shellcheck_warnings скриптах"
    fi
}

# Check version consistency
check_versions() {
    log_info "=== Проверка версий ==="
    
    local scripts=(
        "run_all_audits.sh"
        "analyze_and_recommend.sh"
        "analyze_apache_errors.sh"
        "analyze_nginx_errors.sh"
        "calculate_optimal_params.sh"
        "collect_atop.sh"
        "collect_bitrix.sh"
        "collect_php.sh"
        "collect_redis.sh"
        "collect_sar.sh"
        "collect_system_info.sh"
        "generate_report.sh"
        "setup_monitoring.sh"
    )
    
    local version_errors=0
    
    for script in "${scripts[@]}"; do
        if [ -f "$SCRIPT_DIR/$script" ]; then
            log_check "Проверка версии: $script"
            local version
            version=$(grep '^VERSION=' "$SCRIPT_DIR/$script" | head -1 | cut -d'"' -f2 || echo "")
            if [ "$version" = "2.1.0" ]; then
                log_success "Версия $script: $version"
            else
                log_error "Неверная версия $script: $version (ожидается 2.1.0)"
                ((version_errors++))
            fi
        fi
    done
    
    if [ $version_errors -eq 0 ]; then
        log_success "Все версии унифицированы (2.1.0)"
    else
        log_error "Найдено $version_errors несоответствий версий"
    fi
}

# Check root privileges
check_root_privileges() {
    log_info "=== Проверка root-прав ==="
    
    log_check "Проверка EUID"
    if [ "$EUID" -eq 0 ]; then
        log_success "Root-права: есть (полный аудит)"
    else
        log_error "Root-права: НЕТ (ограниченный аудит)"
        log_error "Для production ОБЯЗАТЕЛЬНО нужны root-права!"
        log_error "Запустите: sudo $0"
    fi
}

# Check dependencies
check_dependencies() {
    log_info "=== Проверка зависимостей ==="
    
    local deps=(
        "bash"
        "grep"
        "awk"
        "sed"
        "cut"
        "head"
        "tail"
        "sort"
        "uniq"
        "wc"
        "find"
        "xargs"
        "tar"
        "gzip"
        "curl"
        "wget"
    )
    
    local missing_deps=0
    
    for dep in "${deps[@]}"; do
        log_check "Проверка: $dep"
        if command -v "$dep" >/dev/null 2>&1; then
            log_success "$dep: установлен"
        else
            log_error "$dep: НЕ УСТАНОВЛЕН"
            ((missing_deps++))
        fi
    done
    
    if [ $missing_deps -eq 0 ]; then
        log_success "Все основные зависимости установлены"
    else
        log_error "Отсутствует $missing_deps зависимостей"
    fi
}

# Check locales
check_locales() {
    log_info "=== Проверка локалей ==="
    
    log_check "Проверка en_US.UTF-8"
    if locale -a 2>/dev/null | grep -q "en_US.utf8"; then
        log_success "Локаль en_US.UTF-8: доступна"
    else
        log_warning "Локаль en_US.UTF-8: недоступна"
    fi
    
    log_check "Проверка ru_RU.UTF-8"
    if locale -a 2>/dev/null | grep -q "ru_RU.utf8"; then
        log_success "Локаль ru_RU.UTF-8: доступна"
    else
        log_warning "Локаль ru_RU.UTF-8: недоступна"
    fi
}

# Check execution permissions
check_permissions() {
    log_info "=== Проверка прав на исполнение ==="
    
    local scripts=(
        "run_all_audits.sh"
        "check_requirements.sh"
        "analyze_and_recommend.sh"
        "collect_nginx.sh"
        "collect_mysql.sh"
        "collect_php.sh"
        "collect_redis.sh"
        "collect_system_info.sh"
        "collect_atop.sh"
        "collect_sar.sh"
        "collect_cron.sh"
        "collect_bitrix.sh"
        "collect_apache.sh"
        "analyze_nginx_errors.sh"
        "analyze_apache_errors.sh"
        "calculate_optimal_params.sh"
        "generate_report.sh"
        "setup_monitoring.sh"
    )
    
    local permission_errors=0
    
    for script in "${scripts[@]}"; do
        if [ -f "$SCRIPT_DIR/$script" ]; then
            log_check "Проверка прав: $script"
            if [ -x "$SCRIPT_DIR/$script" ]; then
                log_success "Права на исполнение $script: есть"
            else
                log_error "Права на исполнение $script: НЕТ"
                ((permission_errors++))
            fi
        fi
    done
    
    if [ $permission_errors -eq 0 ]; then
        log_success "Все скрипты имеют права на исполнение"
    else
        log_error "У $permission_errors скриптов нет прав на исполнение"
    fi
}

# Check documentation
check_documentation() {
    log_info "=== Проверка документации ==="
    
    local docs=(
        "README.md"
        "REQUIREMENTS.md"
        "CHANGELOG.md"
        "docs/locales-and-dates.md"
        "audit.conf.example"
        "Makefile"
    )
    
    local missing_docs=0
    
    for doc in "${docs[@]}"; do
        log_check "Проверка: $doc"
        if [ -f "$SCRIPT_DIR/$doc" ]; then
            log_success "$doc: существует"
        else
            log_error "$doc: НЕ НАЙДЕН"
            ((missing_docs++))
        fi
    done
    
    if [ $missing_docs -eq 0 ]; then
        log_success "Вся документация присутствует"
    else
        log_error "Отсутствует $missing_docs документов"
    fi
}

# Test dry-run
test_dry_run() {
    log_info "=== Тестовый dry-run ==="
    
    log_check "Тест check_requirements.sh"
    if [ -x "$SCRIPT_DIR/check_requirements.sh" ]; then
        if timeout 30 "$SCRIPT_DIR/check_requirements.sh" --help >/dev/null 2>&1; then
            log_success "check_requirements.sh: работает"
        else
            log_error "check_requirements.sh: ошибка выполнения"
        fi
    else
        log_error "check_requirements.sh: нет прав на исполнение"
    fi
    
    log_check "Тест run_all_audits.sh --help"
    if [ -x "$SCRIPT_DIR/run_all_audits.sh" ]; then
        if timeout 30 "$SCRIPT_DIR/run_all_audits.sh" --help >/dev/null 2>&1; then
            log_success "run_all_audits.sh: работает"
        else
            log_error "run_all_audits.sh: ошибка выполнения"
        fi
    else
        log_error "run_all_audits.sh: нет прав на исполнение"
    fi
}

# Generate final report
generate_report() {
    log_info "=== Финальный отчет готовности ==="
    
    echo
    echo "============================================================"
    echo "ОТЧЕТ ГОТОВНОСТИ К ПРОДАКШЕНУ"
    echo "============================================================"
    echo "Всего проверок: $TOTAL_CHECKS"
    echo "Успешно: $PASSED_CHECKS"
    echo "Предупреждения: $WARNING_CHECKS"
    echo "Ошибки: $FAILED_CHECKS"
    echo
    
    if [ $FAILED_CHECKS -eq 0 ]; then
        if [ $WARNING_CHECKS -eq 0 ]; then
            echo -e "${GREEN}✅ ПРОЕКТ ГОТОВ К ПРОДАКШЕНУ!${NC}"
            echo "Все проверки пройдены успешно."
        else
            echo -e "${YELLOW}⚠️  ПРОЕКТ ГОТОВ С ПРЕДУПРЕЖДЕНИЯМИ${NC}"
            echo "Основные проверки пройдены, но есть предупреждения."
        fi
    else
        echo -e "${RED}❌ ПРОЕКТ НЕ ГОТОВ К ПРОДАКШЕНУ${NC}"
        echo "Найдены критические ошибки, требующие исправления."
    fi
    
    echo
    echo "============================================================"
    
    # Return appropriate exit code
    if [ $FAILED_CHECKS -eq 0 ]; then
        return 0
    else
        return 1
    fi
}

# Main execution
main() {
    echo "============================================================"
    echo "Bitrix24 Audit - Pre-Production Check v$VERSION"
    echo "============================================================"
    echo
    
    # Run all checks
    check_syntax
    echo
    
    check_shellcheck
    echo
    
    check_versions
    echo
    
    check_root_privileges
    echo
    
    check_dependencies
    echo
    
    check_locales
    echo
    
    check_permissions
    echo
    
    check_documentation
    echo
    
    test_dry_run
    echo
    
    generate_report
}

# Run main function
main "$@"
