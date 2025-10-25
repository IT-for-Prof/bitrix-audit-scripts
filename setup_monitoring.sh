#!/usr/bin/env bash
# Automatic setup of monitoring tools for Bitrix24 audit
# Usage: ./setup_monitoring.sh [--force] [--non-interactive]

# Use set -e only for critical sections, not globally
# set -euo pipefail

# Version information
VERSION="2.1.0"

# Script directory
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Source common functions
source "$SCRIPT_DIR/audit_common.sh"

# Setup locale using common functions
# setup_locale

# Default settings
FORCE_INSTALL=0
NON_INTERACTIVE=0
VERBOSE=0
DIAGNOSE_ONLY=0
CHECK_ONLY=0
DISABLE_SERVICES=0
UNINSTALL_PACKAGES=0

# Show help
show_help() {
    cat << EOF
Bitrix24 Monitoring Setup v$VERSION

Usage: $0 [OPTIONS]

OPTIONS:
    --force                 Force installation even if tools are already configured
    --non-interactive       Run without user prompts
    --verbose, -v           Enable verbose output
    --diagnose              Run comprehensive diagnostics without making changes
    --check-only            Check current setup status without installation
    --disable               Stop and disable monitoring services (keep packages and configs)
    --uninstall             Completely remove monitoring packages and delete collected data
    --help, -h              Show this help

DESCRIPTION:
    This script automatically installs and configures monitoring tools
    required for Bitrix24 audit scripts:
    
    - sysstat: System activity reporter (sar, iostat, vmstat)
    - atop: Advanced system monitor
    - sysbench: Benchmarking tool
    - psacct/acct: Process accounting
    
    The script will:
    1. Detect the Linux distribution
    2. Install required packages
    3. Configure optimal settings for Bitrix24 monitoring
    4. Enable and start services
    5. Create backup copies of configuration files
    6. Verify the setup

EXAMPLES:
    $0                       # Interactive setup
    $0 --non-interactive     # Automated setup
    $0 --force --verbose     # Force reconfiguration with detailed output
    $0 --diagnose            # Run comprehensive diagnostics
    $0 --check-only          # Check current status only
    $0 --disable             # Stop and disable monitoring services
    $0 --uninstall           # Completely remove monitoring tools

DIAGNOSTIC MODES:
    --diagnose               Generates detailed reports for all services including:
                            - Service status and configuration analysis
                            - Comparison with recommended Bitrix24 settings
                            - Data collection verification
                            - Specific recommendations for optimization
    
    --check-only             Quick status check showing:
                            - Service status with indicators (✓/⚠/✗)
                            - Configuration compliance
                            - Data collection status
                            - Quick recommendations

EOF
}

# Parse command line arguments
while [[ $# -gt 0 ]]; do
    case "$1" in
        --force)
            FORCE_INSTALL=1
            shift
            ;;
        --non-interactive)
            NON_INTERACTIVE=1
            shift
            ;;
        --verbose|-v)
            VERBOSE=1
            shift
            ;;
        --diagnose)
            DIAGNOSE_ONLY=1
            shift
            ;;
        --check-only)
            CHECK_ONLY=1
            shift
            ;;
        --disable)
            DISABLE_SERVICES=1
            shift
            ;;
        --uninstall)
            UNINSTALL_PACKAGES=1
            shift
            ;;
        --help|-h)
            show_help
            exit 0
            ;;
        *)
            echo "Unknown option: $1" >&2
            show_help
            exit 1
            ;;
    esac
done

# Helper functions
log() {
    echo "$*"
}

log_verbose() {
    if [ "$VERBOSE" = "1" ]; then
        echo "VERBOSE: $*"
    fi
}

log_error() {
    echo -e "${RED}✗ $*${NC}" >&2
}

log_warning() {
    echo "WARNING: $*" >&2
}

log_success() {
    echo "✅ $*"
}

log_info() {
    echo "ℹ️  $*"
}

# Detect Linux distribution
detect_distro() {
    local distro_id=""
    local distro_version=""
    local distro_codename=""
    local package_manager=""
    
    if [ -f /etc/os-release ]; then
        distro_id=$(grep "^ID=" /etc/os-release | cut -d= -f2 | tr -d '"')
        distro_version=$(grep "^VERSION_ID=" /etc/os-release | cut -d= -f2 | tr -d '"')
        distro_codename=$(grep "^VERSION_CODENAME=" /etc/os-release | cut -d= -f2 | tr -d '"' || echo "")
    fi
    
    # Determine package manager
    case "$distro_id" in
        "ubuntu"|"debian")
            package_manager="apt"
            ;;
        "almalinux"|"rocky"|"centos"|"rhel"|"fedora")
            # Проверить доступность dnf, иначе использовать yum
            if command -v dnf &> /dev/null; then
                package_manager="dnf"
            elif command -v yum &> /dev/null; then
                package_manager="yum"
            else
                log_error "Neither dnf nor yum found"
                return 1
            fi
            ;;
        *)
            log_error "Unsupported distribution: $distro_id"
            return 1
            ;;
    esac
    
    log_info "Detected distribution: $distro_id $distro_version ($distro_codename)"
    log_info "Package manager: $package_manager"
    
    # Export for use in other functions
    export DISTRO_ID="$distro_id"
    export DISTRO_VERSION="$distro_version"
    export DISTRO_CODENAME="$distro_codename"
    export PACKAGE_MANAGER="$package_manager"
    
    log_verbose "DEBUG: detect_distro completed successfully"
}

# Check internet connectivity
check_internet() {
    log_info "Checking internet connectivity..."
    if ping -c 1 -W 2 8.8.8.8 >/dev/null 2>&1 || \
       ping -c 1 -W 2 1.1.1.1 >/dev/null 2>&1; then
        log_success "Internet connection: OK"
        return 0
    else
        log_warning "No internet connection detected"
        return 1
    fi
}

# Check available disk space
check_disk_space() {
    local required_mb=500
    local available_mb
    available_mb=$(df /var/log | tail -1 | awk '{print int($4/1024)}')
    
    log_info "Checking disk space..."
    if [ "$available_mb" -lt "$required_mb" ]; then
        log_warning "Low disk space: ${available_mb}MB available, ${required_mb}MB recommended"
        return 1
    else
        log_success "Disk space: ${available_mb}MB available"
        return 0
    fi
}

# Create backup of file with timestamp
backup_file() {
    local file="$1"
    local timestamp
    timestamp=$(date +%F_%T)
    
    if [ -f "$file" ]; then
        local backup_file="${file}.bak.${timestamp}"
        cp -a "$file" "$backup_file"
        log_success "Backed up $file to $backup_file"
        return 0
    else
        log_warning "File $file does not exist, skipping backup"
        return 1
    fi
}

# ===== SERVICE DIAGNOSTIC FUNCTIONS =====

# Get comprehensive service status
get_service_status() {
    local service_name="$1"
    local status=""
    local description=""
    
    # Check if unit file exists
    if ! systemctl list-unit-files | grep -q "^${service_name}\.service "; then
        status="not-found"
        description="unit file not found"
    else
        # Get actual status
        status=$(systemctl is-active "$service_name" 2>/dev/null || echo "unknown")
        
        # Special handling for services that might be enabled but not active
        if [ "$status" = "unknown" ]; then
            # Check if service is enabled but not active (common with timers)
            if systemctl is-enabled "$service_name" >/dev/null 2>&1; then
                status="inactive"
                description="enabled but not active (may use timers)"
            fi
        fi
        
        # Special handling for timer-based services
        if [ "$status" = "inactive" ] || [ "$status" = "unknown" ]; then
            # Check if service uses timers (common in modern distributions)
            local timers
            timers=$(get_service_timers "$service_name")
            if [ -n "$timers" ]; then
                local timer_active=false
                for timer in $timers; do
                    if systemctl is-active "$timer" >/dev/null 2>&1; then
                        timer_active=true
                        break
                    fi
                done
                
                if [ "$timer_active" = true ]; then
                    status="active-timer"
                    description="running via systemd timers"
                fi
            fi
        fi
        
        case "$status" in
            "active")
                description="running"
                ;;
            "active-timer")
                description="running via systemd timers"
                ;;
            "inactive")
                description="installed but not started"
                ;;
            "failed")
                description="startup failed"
                ;;
            "unknown")
                description="status unknown"
                ;;
            *)
                description="unexpected status: $status"
                ;;
        esac
    fi
    
    # Check alternative startup methods if systemd service not found or inactive
    if [ "$status" = "not-found" ] || [ "$status" = "inactive" ]; then
        # Check for cron-based startup
        if [ "$service_name" = "sysstat" ]; then
            if crontab -l 2>/dev/null | grep -q "sa1\|sa2" || \
               [ -f /etc/cron.d/sysstat ] || \
               [ -f /etc/cron.hourly/sysstat ]; then
                status="active-cron"
                description="running via cron (legacy mode)"
            fi
        fi
        
        # Check if process is running directly
        if pgrep -x "$service_name" >/dev/null 2>&1; then
            status="active-manual"
            description="running (started manually or via non-systemd)"
        fi
    fi
    
    echo "$status|$description"
}

# Get associated timers for a service
get_service_timers() {
    local service_name="$1"
    local timers=""
    
    case "$service_name" in
        "sysstat")
            timers="sysstat-collect.timer sysstat-summary.timer"
            ;;
        "atop")
            timers="atop-rotate.timer"
            ;;
    esac
    
    echo "$timers"
}

# Check and enable systemd timers for a service
check_and_enable_timers() {
    local service_name="$1"
    local timers
    timers=$(get_service_timers "$service_name")
    local enabled_count=0
    
    if [ -z "$timers" ]; then
        return 0
    fi
    
    for timer in $timers; do
        if systemctl list-unit-files | grep -q "^${timer} "; then
            log_info "Found timer: $timer"
            
            # Check if enabled
            if ! systemctl is-enabled "$timer" >/dev/null 2>&1; then
                log_info "Enabling timer: $timer"
                if systemctl enable "$timer" >/dev/null 2>&1; then
                    log_success "Timer $timer enabled"
                    enabled_count=$((enabled_count + 1))
                else
                    log_warning "Failed to enable timer: $timer"
                fi
            else
                log_success "Timer $timer already enabled"
            fi
            
            # Check if active
            if ! systemctl is-active "$timer" >/dev/null 2>&1; then
                log_info "Starting timer: $timer"
                if systemctl start "$timer" >/dev/null 2>&1; then
                    log_success "Timer $timer started"
                else
                    log_warning "Failed to start timer: $timer"
                fi
            else
                log_success "Timer $timer is active"
            fi
        fi
    done
    
    return 0
}

# Get service configuration
get_service_config() {
    local service_name="$1"
    local config_file=""
    local config_data=""
    
    case "$service_name" in
        "sysstat")
            # Find sysstat config file
            for path in "/etc/default/sysstat" "/etc/sysconfig/sysstat"; do
                if [ -f "$path" ]; then
                    config_file="$path"
                    break
                fi
            done
            ;;
        "atop")
            # Find atop config file
            for path in "/etc/default/atop" "/etc/sysconfig/atop"; do
                if [ -f "$path" ]; then
                    config_file="$path"
                    break
                fi
            done
            ;;
        "psacct"|"acct")
            # Process accounting config
            config_file="systemd"
            ;;
    esac
    
    if [ -n "$config_file" ] && [ "$config_file" != "systemd" ]; then
        config_data=$(cat "$config_file" 2>/dev/null || echo "")
    fi
    
    echo "$config_file|$config_data"
}

# Get service runtime parameters
get_service_runtime_params() {
    local service_name="$1"
    local pid=""
    local cmdline=""
    local env_vars=""
    
    # Get PID
    pid=$(systemctl show "$service_name" --property=MainPID --value 2>/dev/null || echo "")
    
    if [ -n "$pid" ] && [ "$pid" != "0" ]; then
        # Get command line
        cmdline=$(tr '\0' ' ' < "/proc/$pid/cmdline" 2>/dev/null || echo "")
        
        # Get environment variables
        env_vars=$(systemctl show "$service_name" --property=Environment --value 2>/dev/null || echo "")
    fi
    
    echo "$pid|$cmdline|$env_vars"
}

# Get expected configuration for Bitrix24
get_expected_config() {
    local service_name="$1"
    
    case "$service_name" in
        "sysstat")
            # ENABLED используется только на Debian/Ubuntu
            if [ "$PACKAGE_MANAGER" = "apt" ]; then
                echo "ENABLED=true|HISTORY=7|INTERVAL=30"
            else
                echo "HISTORY=7|INTERVAL=30"
            fi
            ;;
        "atop")
            echo "LOGGING=yes|LOGINTERVAL=30|LOGSAVINGS=7|LOGROTATE=7|PERIOD=7"
            ;;
        "psacct"|"acct")
            echo "ENABLED=true|RUNNING=true"
            ;;
    esac
}

# Compare current config with expected
compare_config_with_expected() {
    local service_name="$1"
    local current_config="$2"
    local expected_config="$3"
    local issues=""
    local warnings=""
    local infos=""
    
    case "$service_name" in
        "sysstat")
            # Check ENABLED (только для Debian/Ubuntu)
            if [ "$PACKAGE_MANAGER" = "apt" ]; then
                if echo "$current_config" | grep -q 'ENABLED="true"'; then
                    issues="${issues}✓ ENABLED=true\n"
                else
                    issues="${issues}✗ ENABLED not set to true\n"
                fi
            fi
            
            # Check HISTORY
            local history
            history=$(echo "$current_config" | grep -o 'HISTORY=[0-9]*' | tail -1 | cut -d= -f2)
            if [ -n "$history" ]; then
                if [ "$history" -ge 7 ]; then
                    issues="${issues}✓ HISTORY=$history (>=7 days)\n"
                elif [ "$history" -ge 3 ]; then
                    warnings="${warnings}⚠ HISTORY=$history (expected: 7, current: $history)\n"
                else
                    issues="${issues}✗ HISTORY=$history (too short, expected: 7)\n"
                fi
            else
                issues="${issues}✗ HISTORY not set\n"
            fi
            
            # Check SADC_OPTIONS
            local sadc_opts
            sadc_opts=$(echo "$current_config" | grep -o 'SADC_OPTIONS=.*' | cut -d'"' -f2)
            if echo "$sadc_opts" | grep -qE "XALL|ALL"; then
                issues="${issues}✓ SADC_OPTIONS: $sadc_opts (collecting all metrics)\n"
            else
                issues="${issues}✗ SADC_OPTIONS: $sadc_opts (should contain XALL or ALL)\n"
            fi
            
            # Check collection interval
            local interval
            interval=$(check_collection_interval "sysstat")
            if [ "$interval" -le 60 ]; then
                issues="${issues}✓ Collection interval: ${interval}s (optimal)\n"
            elif [ "$interval" -le 300 ]; then
                warnings="${warnings}⚠ Collection interval: ${interval}s (recommended: ≤60s)\n"
            else
                issues="${issues}✗ Collection interval: ${interval}s (too long, expected: ≤60s)\n"
            fi
            ;;
            
        "atop")
            # Check LOGGING
            if echo "$current_config" | grep -q 'LOGGING=yes'; then
                issues="${issues}✓ LOGGING=yes\n"
            else
                issues="${issues}✗ LOGGING not enabled\n"
            fi
            
            # Check LOGINTERVAL
            local interval
            interval=$(echo "$current_config" | grep -o 'LOGINTERVAL=[0-9]*' | tail -1 | cut -d= -f2)
            if [ -n "$interval" ]; then
                if [ "$interval" -le 30 ]; then
                    issues="${issues}✓ LOGINTERVAL=$interval (<=30s)\n"
                elif [ "$interval" -le 60 ]; then
                    warnings="${warnings}⚠ LOGINTERVAL=$interval (expected: 30, current: $interval)\n"
                else
                    issues="${issues}✗ LOGINTERVAL=$interval (too long, expected: 30)\n"
                fi
            else
                issues="${issues}✗ LOGINTERVAL not set\n"
            fi
            
            # Check LOGSAVINGS
            local savings
            savings=$(echo "$current_config" | grep -o 'LOGSAVINGS=[0-9]*' | tail -1 | cut -d= -f2)
            if [ -n "$savings" ]; then
                if [ "$savings" -ge 7 ]; then
                    issues="${issues}✓ LOGSAVINGS=$savings (>=7 days)\n"
                elif [ "$savings" -ge 3 ]; then
                    warnings="${warnings}⚠ LOGSAVINGS=$savings (expected: 7, current: $savings)\n"
                else
                    issues="${issues}✗ LOGSAVINGS=$savings (too short, expected: 7)\n"
                fi
            else
                issues="${issues}✗ LOGSAVINGS not set\n"
            fi
            
            # Check LOGOPTS (should be empty or contain useful options)
            local logopts
            logopts=$(echo "$current_config" | grep -o 'LOGOPTS=.*' | cut -d'"' -f2)
            if [ -z "$logopts" ]; then
                issues="${issues}✓ LOGOPTS: (default - all metrics)\n"
            else
                issues="${issues}ℹ LOGOPTS: $logopts\n"
            fi
            ;;
    esac
    
    echo "$issues|$warnings|$infos"
}

# Check service data collection
check_service_data_collection() {
    local service_name="$1"
    local data_dir=""
    local latest_file=""
    local file_age=""
    local file_size=""
    local status=""
    
    case "$service_name" in
        "sysstat")
            data_dir="/var/log/sa"
            ;;
        "atop")
            data_dir="/var/log/atop"
            ;;
        "psacct"|"acct")
            # Check for accounting files
            for path in "/var/log/account/pacct" "/var/account/pacct"; do
                if [ -f "$path" ]; then
                    status="✓ accounting file present: $path"
                    echo "$status"
                    return
                fi
            done
            status="✗ accounting files not found"
            echo "$status"
            return
            ;;
    esac
    
    if [ -d "$data_dir" ]; then
        # Find latest file
        latest_file=$(find "$data_dir" -maxdepth 1 -type f -printf '%T@ %p\n' 2>/dev/null | sort -rn | head -1 | cut -d' ' -f2-)
        
        if [ -n "$latest_file" ]; then
            # Get file age in minutes
            file_age=$(find "$data_dir/$latest_file" -mmin -5 2>/dev/null | wc -l)
            
            # Get file size
            file_size=$(stat -c%s "$data_dir/$latest_file" 2>/dev/null || echo "0")
            
            if [ "$file_age" -gt 0 ]; then
                status="✓ Data files present: $data_dir"
                status="${status}\n✓ Latest file: $latest_file (modified <5 min ago)"
            else
                status="⚠ Data files present: $data_dir"
                status="${status}\n⚠ Latest file: $latest_file (modified >5 min ago)"
            fi
            
            if [ "$file_size" -gt 0 ]; then
                status="${status}\n✓ File size: ${file_size}B (non-empty)"
            else
                status="${status}\n✗ File size: 0B (empty)"
            fi
        else
            status="✗ No data files found in $data_dir"
        fi
    else
        status="✗ Data directory not found: $data_dir"
    fi
    
    echo "$status"
}

# Comprehensive service diagnosis
diagnose_service_comprehensive() {
    local service_name="$1"
    local status_info=""
    local config_info=""
    local runtime_info=""
    local expected_config=""
    local comparison=""
    local data_collection=""
    local issues=""
    local warnings=""
    local infos=""
    
    log_verbose "Diagnosing service: $service_name"
    
    # Get service status
    status_info=$(get_service_status "$service_name")
    local status
    status=$(echo "$status_info" | cut -d'|' -f1)
    local description
    description=$(echo "$status_info" | cut -d'|' -f2)
    
    # Get configuration
    config_info=$(get_service_config "$service_name")
    local config_file
    config_file=$(echo "$config_info" | cut -d'|' -f1)
    local config_data
    config_data=$(echo "$config_info" | cut -d'|' -f2)
    
    # Get runtime parameters
    runtime_info=$(get_service_runtime_params "$service_name")
    local pid
    pid=$(echo "$runtime_info" | cut -d'|' -f1)
    local cmdline
    cmdline=$(echo "$runtime_info" | cut -d'|' -f2)
    local env_vars
    env_vars=$(echo "$runtime_info" | cut -d'|' -f3)
    
    # Get expected configuration
    expected_config=$(get_expected_config "$service_name")
    
    # Compare configurations
    if [ -n "$config_data" ]; then
        comparison=$(compare_config_with_expected "$service_name" "$config_data" "$expected_config")
        issues=$(echo "$comparison" | cut -d'|' -f1)
        warnings=$(echo "$comparison" | cut -d'|' -f2)
        infos=$(echo "$comparison" | cut -d'|' -f3)
    fi
    
    # Check data collection
    data_collection=$(check_service_data_collection "$service_name")
    
    # Check associated timers
    local timers=$(get_service_timers "$service_name")
    local timer_info=""
    if [ -n "$timers" ]; then
        timer_info="Associated Timers:\n"
        for timer in $timers; do
            if systemctl list-unit-files | grep -q "^${timer} "; then
                local timer_status=$(systemctl is-active "$timer" 2>/dev/null || echo "inactive")
                local timer_enabled=$(systemctl is-enabled "$timer" 2>/dev/null || echo "disabled")
                
                if [ "$timer_status" = "active" ] && [ "$timer_enabled" = "enabled" ]; then
                    timer_info="${timer_info}  ✓ $timer: active, enabled\n"
                elif [ "$timer_status" = "active" ]; then
                    timer_info="${timer_info}  ⚠ $timer: active, but not enabled\n"
                else
                    timer_info="${timer_info}  ✗ $timer: $timer_status, $timer_enabled\n"
                fi
            else
                timer_info="${timer_info}  ℹ $timer: not found (optional)\n"
            fi
        done
    fi
    
    # Determine overall status
    local overall_status="OK"
    if [ "$status" = "not-found" ] || [ "$status" = "failed" ]; then
        overall_status="CRITICAL"
    elif [ "$status" = "inactive" ] || [ "$status" = "unknown" ]; then
        overall_status="WARNING"
    elif [ "$status" = "active-timer" ] || [ "$status" = "active-cron" ] || [ "$status" = "active-manual" ]; then
        overall_status="OK"
    fi
    
    # Check for critical issues in comparison
    if echo "$issues" | grep -q "✗"; then
        overall_status="CRITICAL"
    elif echo "$warnings" | grep -q "⚠"; then
        if [ "$overall_status" = "OK" ]; then
            overall_status="WARNING"
        fi
    fi
    
    # Output results
    echo "Service: $service_name"
    echo "Overall Status: $overall_status"
    echo "Service Status: $status ($description)"
    
    # Show how service is started
    case "$status" in
        "active")
            echo "Startup Method: systemd service"
            ;;
        "active-timer")
            echo "Startup Method: systemd timers"
            ;;
        "active-cron")
            echo "Startup Method: cron (legacy)"
            if [ "$service_name" = "sysstat" ]; then
                echo "Cron Jobs:"
                crontab -l 2>/dev/null | grep "sa1\|sa2" | sed 's/^/  /'
                [ -f /etc/cron.d/sysstat ] && echo "  Config: /etc/cron.d/sysstat"
            fi
            ;;
        "active-manual")
            echo "Startup Method: manual or non-systemd"
            echo "Process Info:"
            pgrep -a "$service_name" | sed 's/^/  /'
            ;;
    esac
    
    if [ -n "$pid" ] && [ "$pid" != "0" ]; then
        echo "PID: $pid"
        echo "Command: $cmdline"
    fi
    
    if [ -n "$issues" ]; then
        echo -e "\nConfiguration Check:"
        echo -e "$issues"
    fi
    
    if [ -n "$warnings" ]; then
        echo -e "\nWarnings:"
        echo -e "$warnings"
    fi
    
    if [ -n "$data_collection" ]; then
        echo -e "\nData Collection:"
        echo -e "$data_collection"
    fi
    
    # Data Collection Parameters
    echo ""
    echo "Data Collection Parameters:"
    case "$service_name" in
        "sysstat")
            local interval=$(check_collection_interval "sysstat")
            local sadc_opts=$(grep "^SADC_OPTIONS=" "/etc/sysconfig/sysstat" 2>/dev/null | sed 's/.*"\(.*\)".*/\1/')
            local history=$(grep "^HISTORY=" "/etc/sysconfig/sysstat" 2>/dev/null | cut -d= -f2 | head -1)
            local compression=$(grep "^ZIP=" "/etc/sysconfig/sysstat" 2>/dev/null | sed 's/.*"\(.*\)".*/\1/')
            
            echo "  ℹ Collection interval: ${interval}s"
            echo "  ℹ Metrics collected: ${sadc_opts:-not set}"
            echo "  ℹ Retention period: ${history:-not set} days"
            [ -n "$compression" ] && echo "  ℹ Compression: $compression"
            ;;
        "atop")
            local interval=$(grep "^LOGINTERVAL=" "/etc/sysconfig/atop" 2>/dev/null | cut -d= -f2)
            local retention=$(grep "^LOGSAVINGS=" "/etc/sysconfig/atop" 2>/dev/null | cut -d= -f2)
            
            echo "  ℹ Collection interval: ${interval:-not set}s"
            echo "  ℹ Metrics collected: ALL (CPU, MEM, DSK, NET, PRG)"
            echo "  ℹ Retention period: ${retention:-not set} days"
            ;;
    esac
    
    # Log Rotation Status
    echo ""
    echo "Log Rotation Status:"
    check_log_rotation "$service_name"
    
    # Metrics Verification
    echo ""
    echo "Metrics Verification:"
    verify_metrics_collection "$service_name" | sed 's/^/  /'
    
    if [ -n "$timer_info" ]; then
        echo -e "\n$timer_info"
    fi
    
    echo ""
}

# Generate service report
generate_service_report() {
    local service_name="$1"
    
    echo "================================================"
    echo "SERVICE REPORT: $service_name"
    echo "================================================"
    
    diagnose_service_comprehensive "$service_name"
    
    # Add recommendations
    echo "Recommendations:"
    case "$service_name" in
        "sysstat")
            if [ "$PACKAGE_MANAGER" = "apt" ]; then
                echo "  • Ensure ENABLED=true in config"
            fi
            echo "  • Set HISTORY=7 for better analysis"
            echo "  • Verify cron/systemd timers are active"
            ;;
        "atop")
            echo "  • Enable LOGGING=yes"
            echo "  • Set LOGINTERVAL=30 for optimal monitoring"
            echo "  • Set LOGSAVINGS=7 for sufficient history"
            ;;
        "psacct"|"acct")
            echo "  • Ensure process accounting is enabled"
            echo "  • Check accounting files are being created"
            ;;
    esac
    
    echo "================================================"
    echo ""
}

# Install packages based on distribution
install_packages() {
    if ! check_internet; then
        log_error "Internet connection required for package installation"
        return 1
    fi
    
    log_info "Installing monitoring packages..."
    
    case "$PACKAGE_MANAGER" in
        "apt")
            log_info "Updating package lists..."
            apt-get update
            
            log_info "Installing packages: sysstat atop sysbench acct"
            apt-get install -y sysstat atop sysbench acct
            ;;
        "dnf"|"yum")
            log_info "Installing packages: sysstat atop sysbench psacct"
            $PACKAGE_MANAGER install -y sysstat atop sysbench psacct
            ;;
        *)
            log_error "Unknown package manager: $PACKAGE_MANAGER"
            return 1
            ;;
    esac
    
    log_success "Packages installed successfully"
}

# Configure sysstat
configure_sysstat() {
    log_info "Configuring sysstat..."
    
    local sysstat_config=""
    local cron_file=""
    
    # Find sysstat configuration file
    case "$PACKAGE_MANAGER" in
        "apt")
            sysstat_config="/etc/default/sysstat"
            cron_file="/etc/cron.d/sysstat"
            ;;
        "dnf"|"yum")
            sysstat_config="/etc/sysconfig/sysstat"
            # Check if this is a newer system (RHEL 8+, AlmaLinux 8+, CentOS 8+) that uses systemd timers
            if [ -f /etc/os-release ]; then
                local major_version=$(grep "^VERSION_ID=" /etc/os-release | cut -d= -f2 | tr -d '"' | cut -d. -f1)
                if [ "$major_version" -ge 8 ] 2>/dev/null; then
                    # Newer systems use systemd timers
                    cron_file=""
                else
                    # Older systems (RHEL 7, CentOS 7) use cron
                    cron_file="/etc/cron.d/sysstat"
                fi
            else
                # Fallback: assume older system with cron
                cron_file="/etc/cron.d/sysstat"
            fi
            ;;
    esac
    
    if [ -f "$sysstat_config" ]; then
        backup_file "$sysstat_config"
        
        # Enable sysstat (только для Debian/Ubuntu)
        if [ "$PACKAGE_MANAGER" = "apt" ]; then
            sed -ri 's/^ENABLED=.*/ENABLED="true"/' "$sysstat_config" || \
            echo 'ENABLED="true"' >> "$sysstat_config"
        fi
        
        # Set history to 7 days
        sed -ri 's/^HISTORY=.*/HISTORY=7/' "$sysstat_config" || \
        echo 'HISTORY=7' >> "$sysstat_config"
        
        # Set SADC_OPTIONS to collect all metrics
        sed -ri 's/^SADC_OPTIONS=.*/SADC_OPTIONS="-S XALL"/' "$sysstat_config" || \
        echo 'SADC_OPTIONS="-S XALL"' >> "$sysstat_config"
        
        log_success "sysstat configuration updated"
    else
        log_warning "sysstat config file not found: $sysstat_config"
    fi
    
    # Configure cron for sysstat (or systemd timers on newer systems)
    if [ -n "$cron_file" ] && [ -f "$cron_file" ]; then
        backup_file "$cron_file"
        
        # Update sa1 to run every minute with 30-second intervals and XALL
        sed -ri 's#^[^#].*sa1.*#* * * * * root /usr/lib64/sa/sa1 -S XALL 30 2 \&>/dev/null#' "$cron_file" || \
        sed -ri 's#^[^#].*sa1.*#* * * * * root /usr/lib/sa/sa1 -S XALL 30 2 \&>/dev/null#' "$cron_file" || true
        
        # Ensure sa2 exists for daily reports
        if ! grep -q 'sa2' "$cron_file"; then
            echo '53 23 * * * root /usr/lib64/sa/sa2 -A' >> "$cron_file" || \
            echo '53 23 * * * root /usr/lib/sa/sa2 -A' >> "$cron_file"
        fi
        
        log_success "sysstat cron configuration updated"
    elif [ -z "$cron_file" ]; then
        # On newer systems (AlmaLinux 9+), sysstat uses systemd timers
        log_info "sysstat uses systemd timers (modern configuration)"
        
        # Configure 30-second collection interval for systemd timers
        log_info "Configuring 30-second collection interval..."
        
        # Create override directory for timer
        mkdir -p /etc/systemd/system/sysstat-collect.timer.d/
        
        # Create timer override for 30-second interval
        cat > /etc/systemd/system/sysstat-collect.timer.d/override.conf << 'EOF'
[Timer]
# Disable default 10-minute interval
OnCalendar=
# Set 30-second interval
OnCalendar=*:*:0/30
EOF
        
        # Create override directory for service
        mkdir -p /etc/systemd/system/sysstat-collect.service.d/
        
        # Create service override to use XALL
        cat > /etc/systemd/system/sysstat-collect.service.d/override.conf << 'EOF'
[Service]
# Use XALL for collecting all metrics
ExecStart=
ExecStart=/usr/lib64/sa/sadc -S XALL 1 1 -
EOF
        
        # Reload systemd and restart timer
        systemctl daemon-reload
        systemctl restart sysstat-collect.timer
        
        # Check if timers are active
        if systemctl is-active --quiet sysstat-collect.timer; then
            log_success "sysstat-collect timer is active (30-second interval)"
        else
            log_warning "sysstat-collect timer is not active"
        fi
        
        if systemctl is-active --quiet sysstat-summary.timer; then
            log_success "sysstat-summary timer is active"
        else
            log_warning "sysstat-summary timer is not active"
        fi
    else
        log_warning "sysstat cron file not found: $cron_file"
    fi
}

# Check collection interval for monitoring services
check_collection_interval() {
    local service_name="$1"
    local interval=0
    
    case "$service_name" in
        "sysstat")
            # For systemd timers
            if systemctl list-unit-files | grep -q "sysstat-collect.timer"; then
                # Check OnCalendar in timer (check both original and override)
                local timer_interval=$(systemctl cat sysstat-collect.timer 2>/dev/null | grep "OnCalendar=" | tail -1)
                if echo "$timer_interval" | grep -q "0/30"; then
                    interval=30
                elif echo "$timer_interval" | grep -q "0/10"; then
                    interval=600  # 10 minutes
                else
                    interval=600  # Default if not found
                fi
            # For cron
            elif [ -f /etc/cron.d/sysstat ]; then
                # Check interval in cron (sa1 30 2 = 30 seconds, 2 times)
                if grep -q "sa1.*30.*2" /etc/cron.d/sysstat; then
                    interval=30
                elif grep -q "sa1" /etc/cron.d/sysstat; then
                    interval=600  # Default 10 minutes
                fi
            else
                interval=600  # Default if no timer/cron found
            fi
            ;;
        "atop")
            # From config
            interval=$(grep "^LOGINTERVAL=" /etc/sysconfig/atop /etc/default/atop 2>/dev/null | cut -d= -f2 | head -1)
            ;;
    esac
    
    echo "$interval"
}

# Check rotation mechanism for monitoring services
check_rotation_mechanism() {
    local service_name="$1"
    
    case "$service_name" in
        "sysstat")
            # Проверить cron
            if [ -f /etc/cron.d/sysstat ] && grep -q "sa2" /etc/cron.d/sysstat; then
                echo "  ✓ Cron job: /etc/cron.d/sysstat (sa2)"
            fi
            # Проверить systemd timer
            if systemctl list-unit-files 2>/dev/null | grep -q "sysstat-summary.timer"; then
                echo "  ✓ Systemd timer: sysstat-summary.timer"
            fi
            ;;
        "atop")
            # Проверить systemd timer
            if systemctl list-unit-files 2>/dev/null | grep -q "atop-rotate.timer"; then
                echo "  ✓ Systemd timer: atop-rotate.timer"
            fi
            # Проверить cron
            if [ -f /etc/cron.daily/atop ]; then
                echo "  ✓ Cron job: /etc/cron.daily/atop"
            fi
            ;;
        "psacct")
            if [ -f /etc/logrotate.d/psacct ]; then
                echo "  ✓ Logrotate config: /etc/logrotate.d/psacct"
            fi
            ;;
    esac
}

# Check rotation status for monitoring services
check_rotation_status() {
    local service_name="$1"
    
    case "$service_name" in
        "sysstat")
            # Проверить systemd timer
            if systemctl list-unit-files 2>/dev/null | grep -q "sysstat-summary.timer"; then
                if systemctl is-enabled sysstat-summary.timer >/dev/null 2>&1; then
                    echo "  ✓ sysstat-summary.timer: enabled"
                else
                    echo "  ✗ sysstat-summary.timer: disabled"
                fi
                if systemctl is-active sysstat-summary.timer >/dev/null 2>&1; then
                    echo "  ✓ sysstat-summary.timer: active"
                else
                    echo "  ✗ sysstat-summary.timer: inactive"
                fi
            fi
            # Проверить cron daemon
            if systemctl is-active crond >/dev/null 2>&1 || systemctl is-active cron >/dev/null 2>&1; then
                echo "  ✓ Cron daemon: running"
            fi
            ;;
        "atop")
            if systemctl list-unit-files 2>/dev/null | grep -q "atop-rotate.timer"; then
                if systemctl is-enabled atop-rotate.timer >/dev/null 2>&1; then
                    echo "  ✓ atop-rotate.timer: enabled"
                else
                    echo "  ✗ atop-rotate.timer: disabled"
                fi
                if systemctl is-active atop-rotate.timer >/dev/null 2>&1; then
                    echo "  ✓ atop-rotate.timer: active"
                else
                    echo "  ✗ atop-rotate.timer: inactive"
                fi
            fi
            ;;
        "psacct")
            if [ -f /etc/cron.daily/logrotate ]; then
                echo "  ✓ Logrotate cron job exists"
            fi
            if systemctl is-active crond >/dev/null 2>&1 || systemctl is-active cron >/dev/null 2>&1; then
                echo "  ✓ Cron daemon: running"
            fi
            ;;
    esac
}

# Check rotation settings for monitoring services
check_rotation_settings() {
    local service_name="$1"
    local retention_days="$2"
    
    case "$service_name" in
        "sysstat")
            echo "  ℹ Retention period: $retention_days days (HISTORY)"
            ;;
        "atop")
            echo "  ℹ Retention period: $retention_days days (LOGSAVINGS)"
            ;;
        "psacct")
            if [ -f /etc/logrotate.d/psacct ]; then
                local rotate=$(grep "^[[:space:]]*rotate" /etc/logrotate.d/psacct | awk '{print $2}')
                [ -n "$rotate" ] && echo "  ℹ Keeps $rotate old files (logrotate)"
            else
                echo "  ℹ No automatic rotation configured"
            fi
            ;;
    esac
}

# Check rotation results for monitoring services
check_rotation_results() {
    local log_dir="$1"
    local file_pattern="$2"
    local retention_days="$3"
    
    if [ ! -d "$log_dir" ]; then
        echo "  ✗ Log directory not found: $log_dir"
        return 1
    fi
    
    # Count files
    local file_count=$(find "$log_dir" -name "$file_pattern" -type f 2>/dev/null | wc -l)
    echo "  ℹ Total log files: $file_count"
    
    # Check old files
    if [ "$retention_days" -gt 0 ]; then
        local old_files=$(find "$log_dir" -name "$file_pattern" -type f -mtime +$retention_days 2>/dev/null | wc -l)
        if [ "$old_files" -eq 0 ]; then
            echo "  ✓ No files older than $retention_days days"
        else
            echo "  ⚠ Found $old_files file(s) older than $retention_days days"
        fi
    fi
    
    # Oldest file
    local oldest_file=$(find "$log_dir" -name "$file_pattern" -type f -printf '%T+ %p\n' 2>/dev/null | sort | head -1 | awk '{print $2}')
    if [ -n "$oldest_file" ]; then
        local oldest_days=$(( ($(date +%s) - $(stat -c %Y "$oldest_file" 2>/dev/null || echo 0)) / 86400 ))
        echo "  ℹ Oldest file: $(basename "$oldest_file") ($oldest_days days old)"
    fi
    
    # Total size
    local total_size=$(du -sh "$log_dir" 2>/dev/null | awk '{print $1}')
    echo "  ℹ Total size: $total_size"
}

# Check log rotation status for monitoring services
check_log_rotation() {
    local service_name="$1"
    local log_dir=""
    local retention_days=0
    local file_pattern=""
    
    case "$service_name" in
        "sysstat")
            log_dir="/var/log/sa"
            retention_days=$(grep "^HISTORY=" /etc/sysconfig/sysstat /etc/default/sysstat 2>/dev/null | head -1 | cut -d= -f2 || true)
            [ -z "$retention_days" ] && retention_days=7
            file_pattern="sa[0-9][0-9]"
            ;;
        "atop")
            log_dir="/var/log/atop"
            retention_days=$(grep "^LOGSAVINGS=" /etc/sysconfig/atop /etc/default/atop 2>/dev/null | head -1 | cut -d= -f2 || true)
            [ -z "$retention_days" ] && retention_days=7
            file_pattern="atop_[0-9]*"
            ;;
        "psacct")
            log_dir="/var/account"
            file_pattern="pacct*"
            retention_days=0  # psacct не имеет встроенной ротации
            ;;
    esac
    
    # 1. Проверка наличия механизма ротации
    echo "Rotation Mechanism:"
    check_rotation_mechanism "$service_name"
    
    # 2. Проверка активности механизма
    echo ""
    echo "Rotation Status:"
    check_rotation_status "$service_name"
    
    # 3. Проверка настроек
    echo ""
    echo "Rotation Settings:"
    check_rotation_settings "$service_name" "$retention_days"
    
    # 4. Проверка результата работы
    echo ""
    echo "Rotation Results:"
    check_rotation_results "$log_dir" "$file_pattern" "$retention_days"
}

# Verify metrics collection for monitoring services
verify_metrics_collection() {
    local service_name="$1"
    
    case "$service_name" in
        "sysstat")
            # Check latest sa file
            local latest_sa
            latest_sa=$(find /var/log/sa -name "sa[0-9][0-9]" -type f -printf '%T@ %p\n' 2>/dev/null | sort -rn | head -1 | cut -d' ' -f2-)
            if [ -n "$latest_sa" ]; then
                # Check for various metrics
                local has_cpu=$(sar -u -f "$latest_sa" 2>/dev/null | grep -c "Average")
                local has_mem=$(sar -r -f "$latest_sa" 2>/dev/null | grep -c "Average")
                local has_disk=$(sar -d -f "$latest_sa" 2>/dev/null | grep -c "Average")
                local has_net=$(sar -n DEV -f "$latest_sa" 2>/dev/null | grep -c "Average")
                
                echo "Metrics verification:"
                [ "$has_cpu" -gt 0 ] && echo "  ✓ CPU metrics: present" || echo "  ✗ CPU metrics: missing"
                [ "$has_mem" -gt 0 ] && echo "  ✓ Memory metrics: present" || echo "  ✗ Memory metrics: missing"
                [ "$has_disk" -gt 0 ] && echo "  ✓ Disk metrics: present" || echo "  ✗ Disk metrics: missing"
                [ "$has_net" -gt 0 ] && echo "  ✓ Network metrics: present" || echo "  ✗ Network metrics: missing"
            fi
            ;;
        "atop")
            # Check latest atop file
            local latest_atop
            latest_atop=$(find /var/log/atop -name "atop_*" -type f -printf '%T@ %p\n' 2>/dev/null | sort -rn | head -1 | cut -d' ' -f2-)
            if [ -n "$latest_atop" ]; then
                local has_sections=$(atop -r "$latest_atop" -P CPU,MEM,DSK,NET 2>/dev/null | grep -c "^CPU\|^MEM\|^DSK\|^NET")
                
                if [ "$has_sections" -gt 0 ]; then
                    echo "  ✓ All metric sections present (CPU, MEM, DSK, NET)"
                else
                    echo "  ✗ Some metric sections missing"
                fi
            fi
            ;;
    esac
}

# Configure atop
configure_atop() {
    log_info "Configuring atop..."
    
    local atop_config=""
    
    # Find atop configuration file
    for config_path in /etc/sysconfig/atop /etc/default/atop; do
        if [ -f "$config_path" ]; then
            atop_config="$config_path"
            break
        fi
    done
    
    if [ -n "$atop_config" ]; then
        backup_file "$atop_config"
        
        # Enable logging
        grep -q '^LOGGING=' "$atop_config" && \
        sed -ri 's/^LOGGING=.*/LOGGING=yes/' "$atop_config" || \
        echo 'LOGGING=yes' >> "$atop_config"
        
        # Set log interval to 30 seconds
        grep -q '^LOGINTERVAL=' "$atop_config" && \
        sed -ri 's/^LOGINTERVAL=.*/LOGINTERVAL=30/' "$atop_config" || \
        echo 'LOGINTERVAL=30' >> "$atop_config"
        
        # Set log retention to 7 days
        grep -q '^LOGSAVINGS=' "$atop_config" && \
        sed -ri 's/^LOGSAVINGS=.*/LOGSAVINGS=7/' "$atop_config" || \
        echo 'LOGSAVINGS=7' >> "$atop_config"
        
        grep -q '^LOGROTATE=' "$atop_config" && \
        sed -ri 's/^LOGROTATE=.*/LOGROTATE=7/' "$atop_config" || \
        echo 'LOGROTATE=7' >> "$atop_config"
        
        grep -q '^PERIOD=' "$atop_config" && \
        sed -ri 's/^PERIOD=.*/PERIOD=7/' "$atop_config" || \
        echo 'PERIOD=7' >> "$atop_config"
        
        log_success "atop configuration updated"
    else
        log_warning "atop config file not found in standard locations"
    fi
}

# Configure process accounting
configure_psacct() {
    log_info "Configuring process accounting..."
    
    # Determine service name based on package manager
    local service_name=""
    case "$PACKAGE_MANAGER" in
        "apt")
            service_name="acct"
            ;;
        "dnf"|"yum")
            service_name="psacct"
            ;;
    esac
    
    if [ -n "$service_name" ]; then
        log_success "Process accounting service: $service_name"
    else
        log_warning "Could not determine process accounting service name"
    fi
}

# Enable and start services
enable_services() {
    log_info "Enabling and starting services..."
    
    local services=("sysstat" "atop")
    local optional_services=()
    local process_accounting_service=""
    local failed_services=0
    
    # Variables for statistics collection
    local services_started=0
    local services_restarted=0
    local services_failed=0
    local warnings=()
    local errors=()
    
    # Determine process accounting service name
    case "$PACKAGE_MANAGER" in
        "apt")
            process_accounting_service="acct"
            ;;
        "dnf"|"yum")
            process_accounting_service="psacct"
            ;;
    esac
    
    echo ""
    echo "================================================"
    echo "SERVICE ENABLEMENT AND STARTUP"
    echo "================================================"
    
    # Enable and start main services
    for service in "${services[@]}"; do
        echo ""
        log_info "Processing $service service..."
        
        # Check if unit file exists
        if ! systemctl list-unit-files | grep -q "^${service}.service"; then
            log_error "$service unit file not found"
            log_warning "This usually means the package is not installed properly"
            log_info "Try reinstalling: $PACKAGE_MANAGER install $service"
            failed_services=$((failed_services + 1))
            continue
        fi
        
        # Check if service uses timers instead of traditional service
        local timers=$(get_service_timers "$service")
        local timer_based=false
        if [ -n "$timers" ]; then
            for timer in $timers; do
                if systemctl list-unit-files | grep -q "^${timer} "; then
                    timer_based=true
                    break
                fi
            done
        fi
        
        # Enable service
        log_info "Enabling $service service..."
        if systemctl enable "$service" >/dev/null 2>&1; then
            log_success "$service service enabled"
        else
            log_error "Failed to enable $service service"
            failed_services=$((failed_services + 1))
            continue
        fi
        
        # Start/Restart service
        if [ "$FORCE_INSTALL" -eq 1 ]; then
            # При --force всегда перезапускаем для применения новых настроек
            if systemctl is-active "$service" >/dev/null 2>&1; then
                log_info "Restarting $service service to apply new configuration..."
                if systemctl restart "$service" >/dev/null 2>&1; then
                    log_success "$service service restarted"
                    services_restarted=$((services_restarted + 1))
                    
                    # Проверить состояние после перезапуска
                    sleep 2
                    if systemctl is-active "$service" >/dev/null 2>&1; then
                        log_success "$service service is running after restart"
                        check_and_enable_timers "$service"
                    else
                        log_error "$service service failed to start after restart"
                        log_info "Check logs: journalctl -u $service"
                        errors+=("$service failed to start after restart")
                        services_failed=$((services_failed + 1))
                    fi
                else
                    log_error "Failed to restart $service service"
                    log_info "Check logs: journalctl -u $service"
                    errors+=("Failed to restart $service")
                    services_failed=$((services_failed + 1))
                    continue
                fi
            else
                # Служба не запущена, просто запускаем
                log_info "Starting $service service..."
                if systemctl start "$service" >/dev/null 2>&1; then
                    log_success "$service service started"
                    services_started=$((services_started + 1))
                    
                    # Проверить состояние после запуска
                    sleep 2
                    if systemctl is-active "$service" >/dev/null 2>&1; then
                        log_success "$service service is running"
                        check_and_enable_timers "$service"
                    else
                        log_warning "$service service started but not running"
                        log_info "Check logs: journalctl -u $service"
                        warnings+=("$service started but not running")
                        services_failed=$((services_failed + 1))
                    fi
                else
                    log_error "Failed to start $service service"
                    log_info "Check logs: journalctl -u $service"
                    errors+=("Failed to start $service")
                    services_failed=$((services_failed + 1))
                    continue
                fi
            fi
        else
            # Без --force просто запускаем если не запущена
            log_info "Starting $service service..."
            if systemctl start "$service" >/dev/null 2>&1; then
                log_success "$service service started"
                services_started=$((services_started + 1))
                
                # Проверить состояние
                sleep 2
                if systemctl is-active "$service" >/dev/null 2>&1; then
                    log_success "$service service is running"
                    check_and_enable_timers "$service"
                else
                    log_warning "$service service started but not running"
                    log_info "Check logs: journalctl -u $service"
                    warnings+=("$service started but not running")
                    services_failed=$((services_failed + 1))
                fi
            else
                log_error "Failed to start $service service"
                log_info "Check logs: journalctl -u $service"
                errors+=("Failed to start $service")
                services_failed=$((services_failed + 1))
                continue
            fi
        fi
    done
    
    # Handle optional services
    echo ""
    log_info "Processing optional services..."
    
    # Process accounting
    if [ -n "$process_accounting_service" ]; then
        log_info "Processing $process_accounting_service service..."
        if systemctl list-unit-files | grep -q "^${process_accounting_service}.service"; then
            if systemctl enable "$process_accounting_service" >/dev/null 2>&1; then
                log_success "$process_accounting_service service enabled"
                if systemctl start "$process_accounting_service" >/dev/null 2>&1; then
                    log_success "$process_accounting_service service started"
                else
                    log_warning "$process_accounting_service service failed to start"
                fi
            else
                log_warning "Failed to enable $process_accounting_service service"
            fi
        else
            log_warning "$process_accounting_service service not available"
        fi
    fi
    
    # Summary
    echo ""
    echo "================================================"
    echo "OPERATION SUMMARY"
    echo "================================================"
    echo "Operation: Monitoring Setup"
    echo "Date: $(date '+%Y-%m-%d %H:%M:%S')"
    echo "Distribution: $DISTRO_ID $DISTRO_VERSION"
    echo ""
    echo "Actions performed:"
    [ "$services_started" -gt 0 ] && echo "  ✓ Started $services_started service(s)"
    [ "$services_restarted" -gt 0 ] && echo "  ✓ Restarted $services_restarted service(s)"
    echo ""
    
    if [ ${#warnings[@]} -gt 0 ]; then
        echo "Warnings (${#warnings[@]}):"
        for warning in "${warnings[@]}"; do
            echo "  ⚠ $warning"
        done
        echo ""
    fi
    
    if [ ${#errors[@]} -gt 0 ]; then
        echo "Errors (${#errors[@]}):"
        for error in "${errors[@]}"; do
            echo "  ✗ $error"
        done
        echo ""
    fi
    
    if [ "$services_failed" -eq 0 ]; then
        echo "Status: ✅ Success"
    elif [ "$services_failed" -lt 2 ]; then
        echo "Status: ⚠ Completed with warnings"
    else
        echo "Status: ✗ Failed"
    fi
    echo "================================================"
    
    return $failed_services
}

# Disable monitoring services
disable_services() {
    log_info "Disabling monitoring services..."
    
    local services=("sysstat" "atop" "psacct" "acct")
    local timers=("sysstat-collect.timer" "sysstat-summary.timer" "atop-rotate.timer")
    local services_stopped=0
    local services_disabled=0
    local timers_stopped=0
    local warnings=()
    
    echo ""
    echo "================================================"
    echo "SERVICE DISABLING"
    echo "================================================"
    
    # Остановить и отключить службы
    for service in "${services[@]}"; do
        if systemctl list-unit-files | grep -q "^${service}.service"; then
            echo ""
            log_info "Processing $service service..."
            
            # Остановить службу
            if systemctl is-active "$service" >/dev/null 2>&1; then
                log_info "Stopping $service service..."
                if systemctl stop "$service" >/dev/null 2>&1; then
                    log_success "$service service stopped"
                    services_stopped=$((services_stopped + 1))
                else
                    log_warning "Failed to stop $service service"
                    warnings+=("Failed to stop $service")
                fi
            else
                log_info "$service service is not running"
            fi
            
            # Отключить автозапуск
            if systemctl is-enabled "$service" >/dev/null 2>&1; then
                log_info "Disabling $service service..."
                if systemctl disable "$service" >/dev/null 2>&1; then
                    log_success "$service service disabled"
                    services_disabled=$((services_disabled + 1))
                else
                    log_warning "Failed to disable $service service"
                    warnings+=("Failed to disable $service")
                fi
            else
                log_info "$service service is not enabled"
            fi
        fi
    done
    
    # Остановить и отключить таймеры
    echo ""
    log_info "Processing timers..."
    for timer in "${timers[@]}"; do
        if systemctl list-unit-files | grep -q "^${timer}"; then
            if systemctl is-active "$timer" >/dev/null 2>&1; then
                systemctl stop "$timer" >/dev/null 2>&1
                log_success "$timer stopped"
                timers_stopped=$((timers_stopped + 1))
            fi
            if systemctl is-enabled "$timer" >/dev/null 2>&1; then
                systemctl disable "$timer" >/dev/null 2>&1
                log_success "$timer disabled"
            fi
        fi
    done
    
    # Summary
    echo ""
    echo "================================================"
    echo "OPERATION SUMMARY"
    echo "================================================"
    echo "Operation: Disable Monitoring Services"
    echo "Date: $(date '+%Y-%m-%d %H:%M:%S')"
    echo ""
    echo "Actions performed:"
    [ "$services_stopped" -gt 0 ] && echo "  ✓ Stopped $services_stopped service(s)"
    [ "$services_disabled" -gt 0 ] && echo "  ✓ Disabled $services_disabled service(s)"
    [ "$timers_stopped" -gt 0 ] && echo "  ✓ Stopped $timers_stopped timer(s)"
    echo "  ✓ Packages preserved"
    echo "  ✓ Configuration files preserved"
    echo "  ✓ Collected data preserved"
    echo ""
    
    if [ ${#warnings[@]} -gt 0 ]; then
        echo "Warnings (${#warnings[@]}):"
        for warning in "${warnings[@]}"; do
            echo "  ⚠ $warning"
        done
        echo ""
    fi
    
    echo "Status: ✅ Success"
    echo "================================================"
}

# Uninstall monitoring tools
uninstall_monitoring() {
    log_info "Uninstalling monitoring tools..."
    
    # Сначала отключить все службы
    disable_services
    
    echo ""
    echo "================================================"
    echo "PACKAGE REMOVAL"
    echo "================================================"
    
    local packages=("sysstat" "atop" "sysbench" "psacct")
    local packages_removed=0
    local data_dirs_removed=0
    local total_size_freed=0
    local warnings=()
    
    # Удалить пакеты
    log_info "Removing packages..."
    case "$PACKAGE_MANAGER" in
        "apt")
            apt-get remove -y "${packages[@]}" 2>&1 | grep -v "^Reading\|^Building"
            apt-get autoremove -y 2>&1 | grep -v "^Reading\|^Building"
            ;;
        "dnf"|"yum")
            $PACKAGE_MANAGER remove -y "${packages[@]}"
            ;;
    esac
    
    log_success "Packages removed"
    packages_removed=${#packages[@]}
    
    # Удалить собранные данные
    echo ""
    log_info "Removing collected data..."
    
    local data_dirs=(
        "/var/log/sa"
        "/var/log/atop"
        "/var/account"
    )
    
    for dir in "${data_dirs[@]}"; do
        if [ -d "$dir" ]; then
            local dir_size=$(du -sb "$dir" 2>/dev/null | awk '{print $1}')
            total_size_freed=$((total_size_freed + dir_size))
            rm -rf "$dir"
            log_success "Removed $dir"
            data_dirs_removed=$((data_dirs_removed + 1))
        fi
    done
    
    local size_mb=$((total_size_freed / 1024 / 1024))
    log_info "Freed ${size_mb}MB of disk space"
    
    # Удалить systemd overrides
    echo ""
    log_info "Removing systemd overrides..."
    local override_dirs=(
        "/etc/systemd/system/sysstat-collect.timer.d"
        "/etc/systemd/system/sysstat-collect.service.d"
    )
    
    for dir in "${override_dirs[@]}"; do
        if [ -d "$dir" ]; then
            rm -rf "$dir"
            log_success "Removed $dir"
        fi
    done
    
    systemctl daemon-reload
    
    # Summary
    echo ""
    echo "================================================"
    echo "OPERATION SUMMARY"
    echo "================================================"
    echo "Operation: Uninstall Monitoring Tools"
    echo "Date: $(date '+%Y-%m-%d %H:%M:%S')"
    echo ""
    echo "Actions performed:"
    echo "  ✓ Stopped and disabled all services"
    [ "$packages_removed" -gt 0 ] && echo "  ✓ Removed $packages_removed package(s)"
    [ "$data_dirs_removed" -gt 0 ] && echo "  ✓ Removed $data_dirs_removed data directory(ies)"
    [ "$total_size_freed" -gt 0 ] && echo "  ✓ Freed ${size_mb}MB of disk space"
    echo "  ✓ Configuration backups preserved"
    echo ""
    
    if [ ${#warnings[@]} -gt 0 ]; then
        echo "Warnings (${#warnings[@]}):"
        for warning in "${warnings[@]}"; do
            echo "  ⚠ $warning"
        done
        echo ""
    fi
    
    echo "Status: ✅ Success"
    echo "================================================"
}

# Verify setup
verify_setup() {
    log_info "Verifying setup..."
    
    local all_good=0
    local services=("sysstat" "atop")
    local critical_issues=0
    local warnings=0
    
    echo ""
    echo "================================================"
    echo "COMPREHENSIVE SERVICE VERIFICATION"
    echo "================================================"
    
    # Check each service comprehensively
    for service in "${services[@]}"; do
        echo ""
        log_info "Checking $service service..."
        
        # Get service status
        local service_status=$(get_service_status "$service")
        local status=$(echo "$service_status" | cut -d'|' -f1)
        local description=$(echo "$service_status" | cut -d'|' -f2)
        
        case "$status" in
            "active")
                log_success "$service is running ($description)"
                
                # Check configuration
                local config_info=$(get_service_config "$service")
                local config_file=$(echo "$config_info" | cut -d'|' -f1)
                local config_data=$(echo "$config_info" | cut -d'|' -f2)
                
                if [ -n "$config_data" ]; then
                    local expected_config=$(get_expected_config "$service")
                    local comparison=$(compare_config_with_expected "$service" "$config_data" "$expected_config")
                    local issues=$(echo "$comparison" | cut -d'|' -f1)
                    local warnings_text=$(echo "$comparison" | cut -d'|' -f2)
                    
                    if echo "$issues" | grep -q "✗"; then
                        log_error "$service configuration issues detected:"
                        echo -e "$issues"
                        critical_issues=$((critical_issues + 1))
                        all_good=1
                    elif echo "$warnings_text" | grep -q "⚠"; then
                        log_warning "$service configuration warnings:"
                        echo -e "$warnings_text"
                        warnings=$((warnings + 1))
                    else
                        log_success "$service configuration is optimal"
                    fi
                fi
                
                # Check data collection
                local data_status=$(check_service_data_collection "$service")
                if echo "$data_status" | grep -q "✓"; then
                    log_success "$service data collection is working"
                elif echo "$data_status" | grep -q "⚠"; then
                    log_warning "$service data collection issues:"
                    echo -e "$data_status"
                    warnings=$((warnings + 1))
                else
                    log_error "$service data collection problems:"
                    echo -e "$data_status"
                    critical_issues=$((critical_issues + 1))
                    all_good=1
                fi
                ;;
            "inactive")
                log_warning "$service is installed but not started ($description)"
                warnings=$((warnings + 1))
                all_good=1
                ;;
            "failed")
                log_error "$service failed to start ($description)"
                critical_issues=$((critical_issues + 1))
                all_good=1
                ;;
            "unknown")
                log_error "$service status unknown ($description)"
                critical_issues=$((critical_issues + 1))
                all_good=1
                ;;
            "not-found")
                log_error "$service not found ($description)"
                critical_issues=$((critical_issues + 1))
                all_good=1
                ;;
        esac
    done
    
    # Check commands availability
    echo ""
    log_info "Checking command availability..."
    local commands=("sar" "atop" "sysbench" "iostat" "vmstat")
    local missing_commands=0
    
    for cmd in "${commands[@]}"; do
        if command -v "$cmd" >/dev/null 2>&1; then
            log_success "$cmd command is available"
        else
            log_error "$cmd command is not available"
            missing_commands=$((missing_commands + 1))
            all_good=1
        fi
    done
    
    # Summary
    echo ""
    echo "================================================"
    echo "VERIFICATION SUMMARY"
    echo "================================================"
    
    if [ "$critical_issues" -eq 0 ] && [ "$missing_commands" -eq 0 ]; then
        if [ "$warnings" -eq 0 ]; then
            log_success "All services are running correctly with optimal configuration"
        else
            log_warning "All services are running but $warnings configuration warnings detected"
            echo ""
            echo "Recommendations:"
            echo "  • Review configuration warnings above"
            echo "  • Consider adjusting settings for optimal Bitrix24 monitoring"
            echo "  • Run with --diagnose for detailed analysis"
        fi
    else
        log_error "Setup verification failed"
        echo ""
        echo "Issues found:"
        echo "  • Critical issues: $critical_issues"
        echo "  • Configuration warnings: $warnings"
        echo "  • Missing commands: $missing_commands"
        echo ""
        echo "Troubleshooting:"
        echo "  • Check service status: systemctl status sysstat atop"
        echo "  • Check logs: journalctl -u sysstat -u atop"
        echo "  • Restart services: systemctl restart sysstat atop"
        echo "  • Run diagnostics: $0 --diagnose"
        echo ""
    fi
    
    echo "================================================"
    
    return $all_good
}

# Show final report
show_report() {
    log_info "Setup completed!"
    echo ""
    echo "============================================================"
    echo "MONITORING SETUP REPORT"
    echo "============================================================"
    echo ""
    echo "Distribution: $DISTRO_ID $DISTRO_VERSION"
    echo "Package Manager: $PACKAGE_MANAGER"
    echo "Setup Date: $(date)"
    echo ""
    echo "Installed Tools:"
    echo "  ✓ sysstat (sar, iostat, vmstat) - System activity reporter"
    echo "  ✓ atop - Advanced system monitor"
    echo "  ✓ sysbench - Benchmarking tool"
    echo "  ✓ psacct/acct - Process accounting"
    echo ""
    echo "Configuration:"
    echo "  ✓ sysstat: 30-second intervals, 7-day retention"
    echo "  ✓ atop: 30-second intervals, 7-day retention"
    echo "  ✓ Services: All enabled and started"
    echo ""
    echo "Data Collection:"
    echo "  • sysstat data: /var/log/sa/"
    echo "  • atop data: /var/log/atop/"
    echo "  • Process accounting: /var/log/pacct"
    echo ""
    echo "Next Steps:"
    echo "  1. Wait 5-10 minutes for initial data collection"
    echo "  2. Run audit scripts: ./run_all_audits.sh --all"
    echo "  3. Check data with: sar -f /var/log/sa/sa$(date +%d)"
    echo "  4. Monitor with: atop -r /var/log/atop/atop_$(date +%Y%m%d)"
    echo ""
    echo "============================================================"
}

# Interactive confirmation
confirm_setup() {
    if [ "$NON_INTERACTIVE" = "1" ]; then
        return 0
    fi
    
    echo ""
    echo "This will install and configure monitoring tools for Bitrix24 audit:"
    echo "  • sysstat (sar, iostat, vmstat)"
    echo "  • atop (advanced system monitor)"
    echo "  • sysbench (benchmarking)"
    echo "  • psacct/acct (process accounting)"
    echo ""
    echo "Configuration changes:"
    echo "  • sysstat: 30-second intervals, 7-day retention"
    echo "  • atop: 30-second intervals, 7-day retention"
    echo "  • Services will be enabled and started"
    echo "  • Backup copies of config files will be created"
    echo ""
    
    read -p "Continue with setup? [Y/n]: " answer
    answer=${answer:-Y}
    
    if [[ "$answer" != "n" && "$answer" != "N" ]]; then
        return 0
    else
        echo "Setup cancelled by user"
        exit 0
    fi
}

# Check if already configured
check_existing_setup() {
    if [ "$FORCE_INSTALL" = "1" ]; then
        return 1
    fi
    
    local configured=0
    local services=("sysstat" "atop")
    local service_status=""
    local status=""
    local description=""
    local data_collection_status=""
    
    # Check each service
    for service in "${services[@]}"; do
        service_status=$(get_service_status "$service")
        status=$(echo "$service_status" | cut -d'|' -f1)
        description=$(echo "$service_status" | cut -d'|' -f2)
        
        if [ "$status" = "active" ]; then
            configured=$((configured + 1))
        fi
    done
    
    # Check data collection
    local data_collecting=0
    if [ -d /var/log/sa ] && [ "$(ls -A /var/log/sa 2>/dev/null)" ]; then
        data_collecting=1
    fi
    
    if [ "$configured" -ge 1 ] || [ "$data_collecting" -eq 1 ]; then
        log_warning "Monitoring tools appear to be already configured"
        echo ""
        echo "Detected:"
        
        # Show status for each service with indicators
        for service in "${services[@]}"; do
            service_status=$(get_service_status "$service")
            status=$(echo "$service_status" | cut -d'|' -f1)
            description=$(echo "$service_status" | cut -d'|' -f2)
            
            case "$status" in
                "active")
                    echo "  • $service service: ✓ active ($description)"
                    ;;
                "inactive")
                    echo "  • $service service: ⚠ inactive ($description)"
                    ;;
                "failed")
                    echo "  • $service service: ✗ failed ($description)"
                    ;;
                "unknown")
                    echo "  • $service service: ✗ unknown ($description)"
                    ;;
                "not-found")
                    echo "  • $service service: ✗ not found ($description)"
                    ;;
                *)
                    echo "  • $service service: ? $status ($description)"
                    ;;
            esac
        done
        
        # Check data collection status
        local sysstat_data=""
        local atop_data=""
        
        if [ -d /var/log/sa ] && [ "$(ls -A /var/log/sa 2>/dev/null)" ]; then
            sysstat_data="✓ sysstat collecting"
        else
            sysstat_data="✗ sysstat not collecting"
        fi
        
        if [ -d /var/log/atop ] && [ "$(ls -A /var/log/atop 2>/dev/null)" ]; then
            atop_data="✓ atop collecting"
        else
            atop_data="✗ atop not collecting"
        fi
        
        echo "  • Data collection: $sysstat_data, $atop_data"
        echo ""
        echo "Use --force to reconfigure anyway"
        echo "Use --diagnose to see detailed service reports"
        return 0
    fi
    
    return 1
}

# Main execution
main() {
    log "Bitrix24 Monitoring Setup v$VERSION"
    echo ""
    
    # Detect distribution
    detect_distro
    
    # Handle diagnostic modes
    if [ "$DIAGNOSE_ONLY" = "1" ]; then
        echo "================================================"
        echo "COMPREHENSIVE SERVICE DIAGNOSTICS"
        echo "================================================"
        echo ""
        
        local services=("sysstat" "atop")
        local process_accounting_service=""
        
        # Determine process accounting service name
        case "$PACKAGE_MANAGER" in
            "apt")
                process_accounting_service="acct"
                ;;
            "dnf"|"yum")
                process_accounting_service="psacct"
                ;;
        esac
        
        if [ -n "$process_accounting_service" ]; then
            services+=("$process_accounting_service")
        fi
        
        for service in "${services[@]}"; do
            generate_service_report "$service"
        done
        
        echo "================================================"
        echo "DIAGNOSTICS COMPLETE"
        echo "================================================"
        echo ""
        echo "Next steps:"
        echo "  • Review recommendations above"
        echo "  • Run setup with --force to apply fixes"
        echo "  • Use --check-only for quick status updates"
        echo ""
        exit 0
    fi
    
    # Handle disable mode
    if [ "$DISABLE_SERVICES" -eq 1 ]; then
        echo ""
        log_warning "This will stop and disable all monitoring services"
        log_info "Packages and configuration files will be preserved"
        echo ""
        
        if [ "$NON_INTERACTIVE" -eq 0 ]; then
            read -p "Continue with disabling? [y/N]: " confirm
            if [[ ! "$confirm" =~ ^[Yy]$ ]]; then
                log_info "Operation cancelled"
                exit 0
            fi
        fi
        
        disable_services
        exit 0
    fi
    
    # Handle uninstall mode
    if [ "$UNINSTALL_PACKAGES" -eq 1 ]; then
        echo ""
        log_warning "This will completely remove monitoring tools and delete all collected data"
        log_error "This action cannot be undone!"
        echo ""
        
        if [ "$NON_INTERACTIVE" -eq 0 ]; then
            read -p "Are you sure you want to uninstall? [y/N]: " confirm
            if [[ ! "$confirm" =~ ^[Yy]$ ]]; then
                log_info "Operation cancelled"
                exit 0
            fi
        fi
        
        uninstall_monitoring
        exit 0
    fi
    
    if [ "$CHECK_ONLY" = "1" ]; then
        echo "================================================"
        echo "QUICK STATUS CHECK"
        echo "================================================"
        echo ""
        
        # Use check_existing_setup but force it to run
        local original_force="$FORCE_INSTALL"
        FORCE_INSTALL=0
        
        if check_existing_setup; then
            echo ""
            echo "================================================"
            echo "STATUS CHECK COMPLETE"
            echo "================================================"
            echo ""
            echo "Recommendations:"
            echo "  • Use --diagnose for detailed analysis"
            echo "  • Use --force to reconfigure if needed"
        else
            echo ""
            echo "================================================"
            echo "STATUS CHECK COMPLETE"
            echo "================================================"
            echo ""
            echo "No monitoring tools detected."
            echo "Run without --check-only to install and configure."
        fi
        
        FORCE_INSTALL="$original_force"
        exit 0
    fi
    
    # Check if already configured
    if check_existing_setup; then
        exit 0
    fi
    
    # Confirm setup
    confirm_setup
    
    echo ""
    log_info "Starting monitoring tools setup..."
    echo ""
    
    # Check prerequisites
    if ! check_disk_space; then
        log_warning "Continuing despite low disk space..."
    fi
    
    # Install packages
    install_packages
    echo ""
    
    # Configure tools
    configure_sysstat
    configure_atop
    configure_psacct
    echo ""
    
    # Enable services
    enable_services
    echo ""
    
    # Verify setup
    if verify_setup; then
        log_success "All services are running correctly"
    else
        log_error "Some services failed to start properly"
        echo ""
        log_info "Troubleshooting:"
        echo "  • Check service status: systemctl status sysstat atop"
        echo "  • Check logs: journalctl -u sysstat -u atop"
        echo "  • Restart services: systemctl restart sysstat atop"
        echo "  • Run diagnostics: $0 --diagnose"
        echo ""
    fi
    
    # Show report
    show_report
}

# Run main function
main "$@"
