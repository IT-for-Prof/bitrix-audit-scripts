#!/usr/bin/env bash
# Check requirements for Bitrix24 audit scripts
# Usage: ./check_requirements.sh [--module MODULE] [--verbose]

set -euo pipefail

# Version information
VERSION="2.2.0"

# Script directory
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Source common functions
source "$SCRIPT_DIR/audit_common.sh"

# Setup locale using common functions
setup_locale

# Show help
show_help() {
    cat << EOF
Bitrix24 Audit Requirements Checker v$VERSION

Usage: $0 [OPTIONS]

OPTIONS:
    --module MODULE          Check requirements for specific module
    --verbose, -v            Enable verbose output
    --install                Automatically install missing packages
    --non-interactive        Run without user prompts (for --install)
    --help, -h               Show this help

MODULES:
    nginx                    Check nginx requirements
    apache                   Check apache requirements
    mysql                    Check mysql requirements
    php                      Check php requirements
    redis                    Check redis requirements
    system                   Check system requirements
    atop                     Check atop requirements
    sar                      Check sar requirements
    cron                     Check cron requirements
    tuned                    Check tuned-adm requirements
    bitrix                   Check Bitrix-specific requirements
    tools                    Check additional tools (mysqltuner, pt-tools, etc)
    security                 Check security tools (lynis, debsecan, firewall tools)
    all                      Check all requirements (default)

EXAMPLES:
    $0                       # Check all requirements
    $0 --module nginx        # Check only nginx requirements
    $0 --verbose             # Check all requirements with verbose output
    $0 --module tools --verbose # Check additional tools with verbose output
    $0 --install             # Auto-install missing packages
    $0 --install --non-interactive # Auto-install without prompts

EOF
}

# Global arrays for tracking installation results
declare -g -A INSTALLED_PACKAGES=()  # package -> version
declare -g -A INSTALL_STATUS=()       # package -> status (installed/upgraded/skipped/failed)
declare -g INSTALL_COUNTERS=(0 0 0 0) # installed, upgraded, skipped, failed

# Helper function to track package installation
track_package_install() {
    local package="$1"
    local status="$2"
    local version="$3"
    
    INSTALLED_PACKAGES["$package"]="$version"
    INSTALL_STATUS["$package"]="$status"
    
    case "$status" in
        "installed") ((INSTALL_COUNTERS[0]++)) ;;
        "upgraded") ((INSTALL_COUNTERS[1]++)) ;;
        "skipped") ((INSTALL_COUNTERS[2]++)) ;;
        "failed") ((INSTALL_COUNTERS[3]++)) ;;
    esac
}

# Helper function to get package version
get_package_version() {
    local package="$1"
    local pkg_manager="$2"
    
    case "$pkg_manager" in
        "apt-get")
            apt list --installed 2>/dev/null | grep "^$package/" | awk '{print $2}' | head -n1
            ;;
        "yum"|"dnf")
            rpm -q "$package" 2>/dev/null | sed 's/.*-//' | head -n1
            ;;
        *)
            echo "unknown"
            ;;
    esac
}

# Install Percona Toolkit based on distribution
install_percona_toolkit() {
    local distro_id="$1"
    
    log_info "Installing Percona Toolkit..."
    
    case "$distro_id" in
        "ubuntu"|"debian")
            # Check if already installed
            local pt_version_before
            pt_version_before=$(get_package_version "percona-toolkit" "apt-get")
            
            if [ -n "$pt_version_before" ] && [ "$pt_version_before" != "unknown" ]; then
                log_info "Percona Toolkit already installed (version: $pt_version_before)"
                track_package_install "percona-toolkit" "skipped" "$pt_version_before"
            else
                if apt-get install -y percona-toolkit; then
                    local pt_version_after
                    pt_version_after=$(get_package_version "percona-toolkit" "apt-get")
                    log_success "Percona Toolkit installed successfully (version: $pt_version_after)"
                    track_package_install "percona-toolkit" "installed" "$pt_version_after"
                else
                    log_error "Failed to install Percona Toolkit"
                    track_package_install "percona-toolkit" "failed" "unknown"
                fi
            fi
            ;;
        "almalinux"|"rocky"|"centos"|"rhel"|"fedora")
            # Установить репозиторий Percona
            local pkg_manager="dnf"
            if ! command -v dnf >/dev/null 2>&1; then
                pkg_manager="yum"
            fi
            
            # Check if already installed
            local pt_version_before
            pt_version_before=$(get_package_version "percona-toolkit" "$pkg_manager")
            
            if [ -n "$pt_version_before" ] && [ "$pt_version_before" != "unknown" ]; then
                log_info "Percona Toolkit already installed (version: $pt_version_before)"
                track_package_install "percona-toolkit" "skipped" "$pt_version_before"
            else
                log_info "Installing Percona repository..."
                if $pkg_manager install -y https://repo.percona.com/yum/percona-release-latest.noarch.rpm; then
                    log_success "Percona repository installed"
                    
                    log_info "Enabling tools repository..."
                    if percona-release enable tools release; then
                        log_success "Tools repository enabled"
                        
                        log_info "Installing percona-toolkit..."
                        if $pkg_manager install -y percona-toolkit; then
                            local pt_version_after
                            pt_version_after=$(get_package_version "percona-toolkit" "$pkg_manager")
                            log_success "Percona Toolkit installed successfully (version: $pt_version_after)"
                            track_package_install "percona-toolkit" "installed" "$pt_version_after"
                        else
                            log_error "Failed to install percona-toolkit package"
                            track_package_install "percona-toolkit" "failed" "unknown"
                        fi
                    else
                        log_error "Failed to enable tools repository"
                        track_package_install "percona-toolkit" "failed" "unknown"
                    fi
                else
                    log_error "Failed to install Percona repository"
                    track_package_install "percona-toolkit" "failed" "unknown"
                fi
            fi
            ;;
        *)
            log_warning "Unsupported distribution for Percona Toolkit: $distro_id"
            track_package_install "percona-toolkit" "failed" "unsupported"
            return 1
            ;;
    esac
}

# Check for vulnerable packages before installation
check_package_vulnerabilities() {
    log "=== Checking for vulnerable packages ==="
    
    local distro_id=""
    if [ -f /etc/os-release ]; then
        distro_id=$(grep "^ID=" /etc/os-release | cut -d= -f2 | tr -d '"')
    fi
    
    case "$distro_id" in
        "ubuntu"|"debian")
            # Check with apt
            if command -v apt >/dev/null 2>&1; then
                log_info "Checking security updates with apt..."
                local security_updates
                security_updates=$(apt list --upgradable 2>/dev/null | grep -i security | wc -l)
                if [ "$security_updates" -gt 0 ]; then
                    log_warning "Found $security_updates security updates available"
                    apt list --upgradable 2>/dev/null | grep -i security | head -n 10
                else
                    log_success "No security updates found via apt"
                fi
            else
                log_warning "apt command not available for security check"
            fi
            
            # Check with debsecan if available
            if command -v debsecan >/dev/null 2>&1; then
                log_info "Checking CVEs with debsecan..."
                local cve_count
                cve_count=$(debsecan 2>/dev/null | wc -l)
                if [ "$cve_count" -gt 0 ]; then
                    log_warning "Found $cve_count CVEs via debsecan"
                else
                    log_success "No CVEs found via debsecan"
                fi
            else
                log_info "debsecan not available (optional tool)"
            fi
            ;;
            
        "almalinux"|"rocky"|"centos"|"rhel"|"fedora")
            # Determine package manager with fallback
            local pkg_manager="dnf"
            if ! command -v dnf >/dev/null 2>&1; then
                pkg_manager="yum"
            fi
            
            log_info "Checking security updates with $pkg_manager..."
            
            # Check if updateinfo command works
            if ! $pkg_manager updateinfo list 2>/dev/null | head -n1 | grep -q "updateinfo"; then
                log_warning "$pkg_manager updateinfo not available - security check limited"
                log_info "Consider installing yum-plugin-security for detailed security analysis"
                return 0
            fi
            
            # Check security updates
            local security_updates
            security_updates=$($pkg_manager updateinfo list security 2>/dev/null | grep -cE "^(Critical|Important)" || echo "0")
            
            if [ "$security_updates" -gt 0 ]; then
                log_warning "Found $security_updates critical/important security updates"
                $pkg_manager updateinfo list security 2>/dev/null | grep -E "^(Critical|Important)" | head -n 10
            else
                log_success "No critical/important security updates found"
            fi
            
            # Additional check for all security updates
            local all_security_updates
            all_security_updates=$($pkg_manager updateinfo list security 2>/dev/null | grep -c "^[A-Z]" || echo "0")
            if [ "$all_security_updates" -gt 0 ]; then
                log_info "Total security updates available: $all_security_updates"
            fi
            ;;
        *)
            log_warning "Unknown distribution: $distro_id - skipping vulnerability check"
            ;;
    esac
    
    log_info "Vulnerability check completed"
}

# Auto-install missing packages
auto_install_packages() {
    local distro_id=""
    local pkg_manager=""
    
    # Определить дистрибутив
    if [ -f /etc/os-release ]; then
        distro_id=$(grep "^ID=" /etc/os-release | cut -d= -f2 | tr -d '"')
    fi
    
    # Определить пакетный менеджер с фолбэком
    case "$distro_id" in
        "ubuntu"|"debian")
            pkg_manager="apt-get"
            ;;
        "almalinux"|"rocky"|"centos"|"rhel"|"fedora")
            if command -v dnf >/dev/null 2>&1; then
                pkg_manager="dnf"
            else
                pkg_manager="yum"
            fi
            ;;
        *)
            log_error "Unsupported distribution: $distro_id"
            return 1
            ;;
    esac
    
    log_info "Detected distribution: $distro_id"
    log_info "Using package manager: $pkg_manager"
    
    # Список пакетов для установки по дистрибутивам
    local packages_debian="jq lynis tuned mysqltuner gnuplot sysbench sysstat atop psmisc curl wget debsecan"
    local packages_rhel="jq lynis tuned mysqltuner gnuplot sysbench sysstat atop psmisc curl wget"
    
    # Проверка уязвимостей перед установкой
    check_package_vulnerabilities
    
    # Установка EPEL для RHEL-family
    if [[ "$distro_id" =~ ^(almalinux|rocky|centos|rhel|fedora)$ ]]; then
        log_info "Installing EPEL repository..."
        
        # Check if EPEL is already installed
        local epel_version_before
        epel_version_before=$(get_package_version "epel-release" "$pkg_manager")
        
        if [ -n "$epel_version_before" ] && [ "$epel_version_before" != "unknown" ]; then
            log_info "EPEL repository already installed (version: $epel_version_before)"
            track_package_install "epel-release" "skipped" "$epel_version_before"
        else
            if $pkg_manager install -y epel-release; then
                local epel_version_after
                epel_version_after=$(get_package_version "epel-release" "$pkg_manager")
                log_success "EPEL repository installed successfully (version: $epel_version_after)"
                track_package_install "epel-release" "installed" "$epel_version_after"
            else
                log_error "Failed to install EPEL repository"
                track_package_install "epel-release" "failed" "unknown"
            fi
        fi
    fi
    
    # Установка основных пакетов
    log_info "Installing main packages..."
    case "$distro_id" in
        "ubuntu"|"debian")
            log_info "Updating package lists..."
            apt-get update
            
            log_info "Installing packages: $packages_debian"
            if apt-get install -y $packages_debian; then
                log_success "Main packages installed successfully"
                # Track each package individually
                for package in $packages_debian; do
                    local version
                    version=$(get_package_version "$package" "$pkg_manager")
                    track_package_install "$package" "installed" "$version"
                done
            else
                log_error "Failed to install some main packages"
                # Track failed packages
                for package in $packages_debian; do
                    track_package_install "$package" "failed" "unknown"
                done
            fi
            ;;
        "almalinux"|"rocky"|"centos"|"rhel"|"fedora")
            log_info "Installing packages: $packages_rhel"
            if $pkg_manager install -y $packages_rhel; then
                log_success "Main packages installed successfully"
                # Track each package individually
                for package in $packages_rhel; do
                    local version
                    version=$(get_package_version "$package" "$pkg_manager")
                    track_package_install "$package" "installed" "$version"
                done
            else
                log_error "Failed to install some main packages"
                # Track failed packages
                for package in $packages_rhel; do
                    track_package_install "$package" "failed" "unknown"
                done
            fi
            ;;
    esac
    
    # Установка Percona Toolkit
    install_percona_toolkit "$distro_id"
    
    # Apply security updates if available
    log_info "Checking and applying security updates..."
    case "$distro_id" in
        "ubuntu"|"debian")
            log_info "Applying security updates with apt..."
            if apt-get upgrade -y --security; then
                log_success "Security updates applied successfully"
                track_package_install "security-updates" "installed" "latest"
            else
                log_warning "Some security updates may have failed"
                track_package_install "security-updates" "failed" "partial"
            fi
            ;;
        "almalinux"|"rocky"|"centos"|"rhel"|"fedora")
            log_info "Applying security updates with $pkg_manager..."
            if $pkg_manager update -y --security; then
                log_success "Security updates applied successfully"
                track_package_install "security-updates" "installed" "latest"
            else
                log_warning "Some security updates may have failed"
                track_package_install "security-updates" "failed" "partial"
            fi
            ;;
    esac
    
    # Install Percona Toolkit manually for RHEL-family
    if [[ "$distro_id" =~ ^(almalinux|rocky|centos|rhel|fedora)$ ]]; then
        local pt_tools=("pt-query-digest" "pt-mysql-summary" "pt-variable-advisor" "pt-duplicate-key-checker" "pt-index-usage")
        local pt_found=0
        for tool in "${pt_tools[@]}"; do
            if command -v "$tool" >/dev/null 2>&1; then
                pt_found=1
                break
            fi
        done
        
        if [ "$pt_found" -eq 0 ]; then
            log_info "Installing Percona Toolkit..."
            # Download and install Percona Toolkit RPM
            local percona_rpm_url="https://repo.percona.com/yum/percona-release-latest.noarch.rpm"
            local percona_toolkit_rpm="percona-toolkit-3.5.5-1.el9.noarch.rpm"
            
            # Install Percona repository
            $pkg_manager install -y "$percona_rpm_url"
            
            # Enable tools repository
            percona-release enable tools release
            
            # Install percona-toolkit
            $pkg_manager install -y percona-toolkit
            
            log_success "Percona Toolkit installed successfully"
        fi
    fi
    
    # Install testssl.sh manually
    if ! command -v testssl.sh >/dev/null 2>&1; then
        log_info "Installing testssl.sh..."
        if curl -o /usr/local/bin/testssl.sh https://raw.githubusercontent.com/drwetter/testssl.sh/master/testssl.sh; then
            if chmod +x /usr/local/bin/testssl.sh; then
                log_success "testssl.sh installed successfully"
                track_package_install "testssl.sh" "installed" "latest"
            else
                log_error "Failed to make testssl.sh executable"
                track_package_install "testssl.sh" "failed" "unknown"
            fi
        else
            log_error "Failed to download testssl.sh"
            track_package_install "testssl.sh" "failed" "unknown"
        fi
    else
        log_info "testssl.sh already installed"
        track_package_install "testssl.sh" "skipped" "existing"
    fi
    
    # Вызвать setup_monitoring.sh для настройки мониторинга
    if [ -f "$SCRIPT_DIR/setup_monitoring.sh" ]; then
        log_info "Running monitoring setup script..."
        if bash "$SCRIPT_DIR/setup_monitoring.sh" --non-interactive; then
            log_success "Monitoring setup completed"
            track_package_install "monitoring-setup" "installed" "configured"
        else
            log_warning "Monitoring setup had issues"
            track_package_install "monitoring-setup" "failed" "partial"
        fi
    fi
    
    # Generate installation summary
    generate_install_summary
    
    log_success "Auto-installation completed successfully"
}

# Generate installation summary report
generate_install_summary() {
    log_info "=== Installation Summary ==="
    
    local total_packages=${#INSTALLED_PACKAGES[@]}
    local installed_count=${INSTALL_COUNTERS[0]}
    local upgraded_count=${INSTALL_COUNTERS[1]}
    local skipped_count=${INSTALL_COUNTERS[2]}
    local failed_count=${INSTALL_COUNTERS[3]}
    
    if [ "$total_packages" -eq 0 ]; then
        log_warning "No packages were tracked during installation"
        return 0
    fi
    
    echo ""
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo "Package              Version       Status"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    
    # Sort packages by name for consistent output
    local sorted_packages=($(printf '%s\n' "${!INSTALLED_PACKAGES[@]}" | sort))
    
    for package in "${sorted_packages[@]}"; do
        local version="${INSTALLED_PACKAGES[$package]}"
        local status="${INSTALL_STATUS[$package]}"
        
        # Format status with appropriate color/symbol
        case "$status" in
            "installed") status_symbol="✅ installed" ;;
            "upgraded") status_symbol="🔄 upgraded" ;;
            "skipped") status_symbol="⏭️  skipped" ;;
            "failed") status_symbol="❌ failed" ;;
            *) status_symbol="❓ $status" ;;
        esac
        
        # Truncate long package names and versions for table formatting
        local package_display="$package"
        local version_display="$version"
        
        if [ ${#package_display} -gt 20 ]; then
            package_display="${package_display:0:17}..."
        fi
        
        if [ ${#version_display} -gt 12 ]; then
            version_display="${version_display:0:9}..."
        fi
        
        printf "%-20s %-12s %s\n" "$package_display" "$version_display" "$status_symbol"
    done
    
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo ""
    echo "Total packages processed: $total_packages"
    echo "Successfully installed: $installed_count"
    echo "Upgraded: $upgraded_count"
    echo "Skipped (already installed): $skipped_count"
    echo "Failed: $failed_count"
    echo ""
    
    # Recommendations based on results
    if [ "$failed_count" -gt 0 ]; then
        log_warning "Some packages failed to install. Check the logs above for details."
        log_info "You may need to install them manually or check repository availability."
    fi
    
    if [ "$installed_count" -gt 0 ] || [ "$upgraded_count" -gt 0 ]; then
        log_success "Installation completed successfully!"
        log_info "You can now run the audit scripts with improved functionality."
    fi
    
    if [ "$skipped_count" -gt 0 ]; then
        log_info "Some packages were already installed and up-to-date."
    fi
    
    echo ""
}

# Default settings
VERBOSE=0
MODULE=""
AUTO_INSTALL=0
NON_INTERACTIVE=0

# Arrays to track missing components
declare -a MISSING_CRITICAL=()
declare -a MISSING_RECOMMENDED=()

# Global variables for distribution detection
DISTRO_ID=""
PKG_MANAGER=""

# Detect distribution and package manager
detect_distro() {
    DISTRO_ID=""
    PKG_MANAGER=""
    
    if [ -f /etc/os-release ]; then
        DISTRO_ID=$(grep "^ID=" /etc/os-release | cut -d= -f2 | tr -d '"')
    fi
    
    case "$DISTRO_ID" in
        "ubuntu"|"debian")
            PKG_MANAGER="apt-get"
            ;;
        "almalinux"|"rocky"|"centos"|"rhel"|"fedora")
            if command -v dnf >/dev/null 2>&1; then
                PKG_MANAGER="dnf"
            else
                PKG_MANAGER="yum"
            fi
            ;;
    esac
}

# Generate install hints based on distribution
get_install_hint() {
    local component_type="$1"
    local component_name="$2"
    
    case "$component_type" in
        "locale-en")
            if [ "$PKG_MANAGER" = "apt-get" ]; then
                echo "apt-get install locales && locale-gen en_US.UTF-8"
            else
                echo "dnf install glibc-langpack-en"
            fi
            ;;
        "locale-ru")
            if [ "$PKG_MANAGER" = "apt-get" ]; then
                echo "apt-get install locales && locale-gen ru_RU.UTF-8"
            else
                echo "dnf install glibc-langpack-ru"
            fi
            ;;
        "php-mysql")
            if [ "$PKG_MANAGER" = "apt-get" ]; then
                echo "apt-get install php-mysql"
            else
                echo "dnf install php-mysqlnd"
            fi
            ;;
        "php-redis")
            echo "$PKG_MANAGER install php-redis"
            ;;
        "php-opcache")
            if [ "$PKG_MANAGER" = "apt-get" ]; then
                echo "apt-get install php-opcache"
            else
                echo "Already included in php package"
            fi
            ;;
        "mysqltuner")
            echo "$PKG_MANAGER install mysqltuner"
            ;;
        "percona-toolkit")
            if [ "$PKG_MANAGER" = "apt-get" ]; then
                echo "apt-get install percona-toolkit"
            else
                echo "Manual install: download RPM from percona.com or setup Percona repo"
            fi
            ;;
        "tuned")
            echo "$PKG_MANAGER install tuned"
            ;;
        "sysbench")
            echo "$PKG_MANAGER install sysbench"
            ;;
        "wkhtmltopdf")
            if [ "$PKG_MANAGER" = "apt-get" ]; then
                echo "apt-get install wkhtmltopdf"
            else
                echo "Manual install from wkhtmltopdf.org"
            fi
            ;;
        "gnuplot")
            echo "$PKG_MANAGER install gnuplot"
            ;;
        "testssl")
            echo "Manual download from GitHub"
            ;;
        "lynis")
            echo "$PKG_MANAGER install lynis"
            ;;
        "debsecan")
            echo "apt-get install debsecan (Debian/Ubuntu only)"
            ;;
        "firewall")
            if [ "$PKG_MANAGER" = "apt-get" ]; then
                echo "apt-get install ufw"
            else
                echo "dnf install firewalld"
            fi
            ;;
        *)
            echo "Manual installation required"
            ;;
    esac
}

# Parse command line arguments
while [[ $# -gt 0 ]]; do
    case "$1" in
        --module)
            shift
            MODULE="$1"
            shift
            ;;
        --verbose|-v)
            VERBOSE=1
            shift
            ;;
        --install)
            AUTO_INSTALL=1
            shift
            ;;
        --non-interactive)
            NON_INTERACTIVE=1
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
    echo "ERROR: $*" >&2
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

# Get service ports
get_service_ports() {
    local process_name="$1"
    local ports=""
    
    # Try netstat first, fallback to ss
    if command -v netstat >/dev/null 2>&1; then
        ports=$(netstat -tlnp 2>/dev/null | grep "$process_name" | awk '{print $4}' | sed 's/.*://g' | grep -E '^[0-9]+$' | sort -u | tr '\n' ',' | sed 's/,$//')
    elif command -v ss >/dev/null 2>&1; then
        ports=$(ss -tlnp 2>/dev/null | grep "$process_name" | awk '{print $5}' | sed 's/.*://g' | grep -E '^[0-9]+$' | sort -u | tr '\n' ',' | sed 's/,$//')
    fi
    
    echo "$ports"
}

# Get service sockets
get_service_sockets() {
    local process_name="$1"
    local sockets=""
    
    # Extract Unix sockets using ss
    if command -v ss >/dev/null 2>&1; then
        sockets=$(ss -xlnp 2>/dev/null | grep "$process_name" | awk '{print $5}' | grep '^/' | sort -u | tr '\n' ',' | sed 's/,$//')
    fi
    
    echo "$sockets"
}

# Get MySQL details
get_mysql_details() {
    local details=""
    local ports=""
    local sockets=""
    local version=""
    local datadir=""
    
    # Get TCP ports
    ports=$(get_service_ports "mysqld")
    
    # Get Unix sockets
    sockets=$(get_service_sockets "mysqld")
    
    # Get MySQL version
    if command -v mysql >/dev/null 2>&1; then
        version=$(mysql --version 2>/dev/null | head -n1 | sed 's/.*Ver //' | sed 's/ .*//' || echo "unknown")
    fi
    
    # Get data directory
    if command -v mysqld >/dev/null 2>&1; then
        datadir=$(mysqld --help --verbose 2>/dev/null | grep "^datadir" | awk '{print $2}' | head -n1 || echo "unknown")
    fi
    
    # Build details string
    if [ -n "$ports" ]; then
        details="TCP Ports: $ports"
    fi
    
    if [ -n "$sockets" ]; then
        if [ -n "$details" ]; then
            details="$details, Unix Socket: $sockets"
        else
            details="Unix Socket: $sockets"
        fi
    fi
    
    if [ -n "$version" ] && [ "$version" != "unknown" ]; then
        if [ -n "$details" ]; then
            details="$details, Version: $version"
        else
            details="Version: $version"
        fi
    fi
    
    if [ -n "$datadir" ] && [ "$datadir" != "unknown" ]; then
        if [ -n "$details" ]; then
            details="$details, Data Dir: $datadir"
        else
            details="Data Dir: $datadir"
        fi
    fi
    
    echo "$details"
}

# Get Redis details
get_redis_details() {
    local details=""
    local ports=""
    local sockets=""
    local version=""
    local mode=""
    local memory=""
    local used_memory=""
    local maxmemory_policy=""
    local connected_clients=""
    local persistence_rdb=""
    local persistence_aof=""
    
    # Get TCP ports
    ports=$(get_service_ports "redis-server")
    
    # Get Unix sockets
    sockets=$(get_service_sockets "redis-server")
    
    # Get Redis version
    if command -v redis-server >/dev/null 2>&1; then
        version=$(redis-server --version 2>/dev/null | head -n1 | sed 's/.*v=//' | sed 's/ .*//' || echo "unknown")
    fi
    
    # Get Redis mode and memory info via redis-cli
    if command -v redis-cli >/dev/null 2>&1; then
        # Try to get info from Redis server
        if redis-cli ping >/dev/null 2>&1; then
            mode=$(redis-cli info replication 2>/dev/null | grep "role:" | cut -d: -f2 | tr -d '\r' || echo "unknown")
            memory=$(redis-cli config get maxmemory 2>/dev/null | tail -n1 | sed 's/^0$//' || echo "unknown")
            
            # Get additional memory info
            used_memory=$(redis-cli info memory 2>/dev/null | grep "used_memory:" | cut -d: -f2 | tr -d '\r' || echo "unknown")
            maxmemory_policy=$(redis-cli config get maxmemory-policy 2>/dev/null | tail -n1 || echo "unknown")
            connected_clients=$(redis-cli info clients 2>/dev/null | grep "connected_clients:" | cut -d: -f2 | tr -d '\r' || echo "unknown")
            
            # Get persistence settings
            persistence_rdb=$(redis-cli config get save 2>/dev/null | tail -n1 || echo "unknown")
            persistence_aof=$(redis-cli config get appendonly 2>/dev/null | tail -n1 || echo "unknown")
        fi
    fi
    
    # Build details string
    if [ -n "$ports" ]; then
        details="TCP Port: $ports"
    fi
    
    if [ -n "$sockets" ]; then
        if [ -n "$details" ]; then
            details="$details, Unix Socket: $sockets"
        else
            details="Unix Socket: $sockets"
        fi
    fi
    
    if [ -n "$version" ] && [ "$version" != "unknown" ]; then
        if [ -n "$details" ]; then
            details="$details, Version: $version"
        else
            details="Version: $version"
        fi
    fi
    
    if [ -n "$mode" ] && [ "$mode" != "unknown" ]; then
        if [ -n "$details" ]; then
            details="$details, Mode: $mode"
        else
            details="Mode: $mode"
        fi
    fi
    
    if [ -n "$memory" ] && [ "$memory" != "unknown" ] && [ "$memory" != "" ]; then
        if [ -n "$details" ]; then
            details="$details, Max Memory: $memory"
        else
            details="Max Memory: $memory"
        fi
    fi
    
    if [ -n "$used_memory" ] && [ "$used_memory" != "unknown" ] && [ "$used_memory" != "0" ]; then
        # Convert bytes to MB
        local used_memory_mb=$((used_memory / 1024 / 1024))
        if [ -n "$details" ]; then
            details="$details, Used Memory: ${used_memory_mb}MB"
        else
            details="Used Memory: ${used_memory_mb}MB"
        fi
    fi
    
    if [ -n "$maxmemory_policy" ] && [ "$maxmemory_policy" != "unknown" ]; then
        if [ -n "$details" ]; then
            details="$details, Eviction Policy: $maxmemory_policy"
        else
            details="Eviction Policy: $maxmemory_policy"
        fi
    fi
    
    if [ -n "$connected_clients" ] && [ "$connected_clients" != "unknown" ] && [ "$connected_clients" != "0" ]; then
        if [ -n "$details" ]; then
            details="$details, Connected Clients: $connected_clients"
        else
            details="Connected Clients: $connected_clients"
        fi
    fi
    
    if [ -n "$persistence_rdb" ] && [ "$persistence_rdb" != "unknown" ]; then
        if [ -n "$details" ]; then
            details="$details, RDB Persistence: $persistence_rdb"
        else
            details="RDB Persistence: $persistence_rdb"
        fi
    fi
    
    if [ -n "$persistence_aof" ] && [ "$persistence_aof" != "unknown" ]; then
        if [ -n "$details" ]; then
            details="$details, AOF Persistence: $persistence_aof"
        else
            details="AOF Persistence: $persistence_aof"
        fi
    fi
    
    echo "$details"
}

# Get Memcached details
get_memcached_details() {
    local details=""
    local ports=""
    local version=""
    local memory=""
    local connections=""
    local curr_connections=""
    local total_connections=""
    local evictions=""
    
    # Get TCP ports
    ports=$(get_service_ports "memcached")
    
    # Get Memcached version
    if command -v memcached >/dev/null 2>&1; then
        version=$(memcached -h 2>/dev/null | head -n1 | sed 's/.*memcached //' | sed 's/ .*//' || echo "unknown")
    fi
    
    # Try to get memory and connection info via telnet/nc
    if [ -n "$ports" ]; then
        local port=$(echo "$ports" | cut -d',' -f1)
        local stats_output=""
        
        # Try nc first, then telnet as fallback
        if command -v nc >/dev/null 2>&1; then
            stats_output=$(echo "stats" | nc localhost "$port" 2>/dev/null | head -n30)
        elif command -v telnet >/dev/null 2>&1; then
            stats_output=$(echo -e "stats\nquit" | telnet localhost "$port" 2>/dev/null | head -n30)
        fi
        
        if [ -n "$stats_output" ]; then
            memory=$(echo "$stats_output" | grep "limit_maxbytes" | awk '{print $3}' | head -n1)
            connections=$(echo "$stats_output" | grep "max_connections" | awk '{print $3}' | head -n1)
            curr_connections=$(echo "$stats_output" | grep "curr_connections" | awk '{print $3}' | head -n1)
            total_connections=$(echo "$stats_output" | grep "total_connections" | awk '{print $3}' | head -n1)
            evictions=$(echo "$stats_output" | grep "evictions" | awk '{print $3}' | head -n1)
        fi
    fi
    
    # Build details string
    if [ -n "$ports" ]; then
        details="TCP Port: $ports"
    fi
    
    if [ -n "$version" ] && [ "$version" != "unknown" ]; then
        if [ -n "$details" ]; then
            details="$details, Version: $version"
        else
            details="Version: $version"
        fi
    fi
    
    if [ -n "$memory" ] && [ "$memory" != "0" ]; then
        # Convert bytes to MB
        local memory_mb=$((memory / 1024 / 1024))
        if [ -n "$details" ]; then
            details="$details, Memory: ${memory_mb}MB"
        else
            details="Memory: ${memory_mb}MB"
        fi
    fi
    
    if [ -n "$connections" ] && [ "$connections" != "0" ]; then
        if [ -n "$details" ]; then
            details="$details, Max Connections: $connections"
        else
            details="Max Connections: $connections"
        fi
    fi
    
    if [ -n "$curr_connections" ] && [ "$curr_connections" != "0" ]; then
        if [ -n "$details" ]; then
            details="$details, Current Connections: $curr_connections"
        else
            details="Current Connections: $curr_connections"
        fi
    fi
    
    if [ -n "$total_connections" ] && [ "$total_connections" != "0" ]; then
        if [ -n "$details" ]; then
            details="$details, Total Connections: $total_connections"
        else
            details="Total Connections: $total_connections"
        fi
    fi
    
    if [ -n "$evictions" ] && [ "$evictions" != "0" ]; then
        if [ -n "$details" ]; then
            details="$details, Evictions: $evictions"
        else
            details="Evictions: $evictions"
        fi
    fi
    
    echo "$details"
}

# Get PHP-FPM details
get_php_fpm_details() {
    local details=""
    local ports=""
    local sockets=""
    local version=""
    local pools=""
    
    # Get TCP ports
    ports=$(get_service_ports "php-fpm")
    
    # Get Unix sockets
    sockets=$(get_service_sockets "php-fpm")
    
    # Get PHP version
    if command -v php >/dev/null 2>&1; then
        version=$(php --version 2>/dev/null | head -n1 | sed 's/PHP //' | sed 's/ .*//' || echo "unknown")
    fi
    
    # Get PHP-FPM pools
    if command -v php-fpm >/dev/null 2>&1; then
        # Look for pool configuration files
        local pool_dirs=("/etc/php-fpm.d" "/etc/php/*/fpm/pool.d" "/etc/php/*/php-fpm.d")
        local pool_count=0
        
        for dir in "${pool_dirs[@]}"; do
            if [ -d "$dir" ]; then
                pool_count=$((pool_count + $(find "$dir" -name "*.conf" 2>/dev/null | wc -l)))
            fi
        done
        
        if [ "$pool_count" -gt 0 ]; then
            pools="$pool_count pools"
        fi
    fi
    
    # Build details string
    if [ -n "$ports" ]; then
        details="TCP Port: $ports"
    fi
    
    if [ -n "$sockets" ]; then
        if [ -n "$details" ]; then
            details="$details, Unix Socket: $sockets"
        else
            details="Unix Socket: $sockets"
        fi
    fi
    
    if [ -n "$version" ] && [ "$version" != "unknown" ]; then
        if [ -n "$details" ]; then
            details="$details, Version: $version"
        else
            details="Version: $version"
        fi
    fi
    
    if [ -n "$pools" ]; then
        if [ -n "$details" ]; then
            details="$details, $pools"
        else
            details="$pools"
        fi
    fi
    
    echo "$details"
}

# Get Nginx details
get_nginx_details() {
    local details=""
    local ports=""
    local version=""
    local workers=""
    local config=""
    
    # Get TCP ports
    ports=$(get_service_ports "nginx")
    
    # Get Nginx version
    if command -v nginx >/dev/null 2>&1; then
        version=$(nginx -v 2>&1 | sed 's/nginx version: nginx\///' | sed 's/ .*//' || echo "unknown")
    fi
    
    # Get worker processes count
    if command -v nginx >/dev/null 2>&1; then
        workers=$(nginx -T 2>/dev/null | grep "worker_processes" | head -n1 | awk '{print $2}' | sed 's/;//' || echo "unknown")
    fi
    
    # Get main config file
    if command -v nginx >/dev/null 2>&1; then
        config=$(nginx -T 2>/dev/null | grep "# configuration file" | head -n1 | sed 's/# configuration file //' || echo "unknown")
    fi
    
    # Build details string
    if [ -n "$ports" ]; then
        details="TCP Ports: $ports"
    fi
    
    if [ -n "$version" ] && [ "$version" != "unknown" ]; then
        if [ -n "$details" ]; then
            details="$details, Version: $version"
        else
            details="Version: $version"
        fi
    fi
    
    if [ -n "$workers" ] && [ "$workers" != "unknown" ] && [ "$workers" != "auto" ]; then
        if [ -n "$details" ]; then
            details="$details, Workers: $workers"
        else
            details="Workers: $workers"
        fi
    fi
    
    if [ -n "$config" ] && [ "$config" != "unknown" ]; then
        if [ -n "$details" ]; then
            details="$details, Config: $config"
        else
            details="Config: $config"
        fi
    fi
    
    echo "$details"
}

# Get Apache details
get_apache_details() {
    local details=""
    local ports=""
    local version=""
    local mpm=""
    local config=""
    
    # Get TCP ports
    ports=$(get_service_ports "httpd")
    if [ -z "$ports" ]; then
        ports=$(get_service_ports "apache2")
    fi
    
    # Get Apache version
    if command -v httpd >/dev/null 2>&1; then
        version=$(httpd -v 2>&1 | head -n1 | sed 's/.*Server version: Apache\///' | sed 's/ .*//' || echo "unknown")
    elif command -v apache2 >/dev/null 2>&1; then
        version=$(apache2 -v 2>&1 | head -n1 | sed 's/.*Server version: Apache\///' | sed 's/ .*//' || echo "unknown")
    fi
    
    # Get MPM (Multi-Processing Module)
    if command -v httpd >/dev/null 2>&1; then
        mpm=$(httpd -l 2>/dev/null | grep -E "(prefork|worker|event)" | head -n1 | sed 's/.*\(prefork\|worker\|event\).*/\1/' || echo "unknown")
    elif command -v apache2 >/dev/null 2>&1; then
        mpm=$(apache2 -l 2>/dev/null | grep -E "(prefork|worker|event)" | head -n1 | sed 's/.*\(prefork\|worker\|event\).*/\1/' || echo "unknown")
    fi
    
    # Get main config file
    if command -v httpd >/dev/null 2>&1; then
        config=$(httpd -V 2>/dev/null | grep "SERVER_CONFIG_FILE" | sed 's/.*"\(.*\)".*/\1/' || echo "unknown")
    elif command -v apache2 >/dev/null 2>&1; then
        config=$(apache2 -V 2>/dev/null | grep "SERVER_CONFIG_FILE" | sed 's/.*"\(.*\)".*/\1/' || echo "unknown")
    fi
    
    # Build details string
    if [ -n "$ports" ]; then
        details="TCP Ports: $ports"
    fi
    
    if [ -n "$version" ] && [ "$version" != "unknown" ]; then
        if [ -n "$details" ]; then
            details="$details, Version: $version"
        else
            details="Version: $version"
        fi
    fi
    
    if [ -n "$mpm" ] && [ "$mpm" != "unknown" ]; then
        if [ -n "$details" ]; then
            details="$details, MPM: $mpm"
        else
            details="MPM: $mpm"
        fi
    fi
    
    if [ -n "$config" ] && [ "$config" != "unknown" ]; then
        if [ -n "$details" ]; then
            details="$details, Config: $config"
        else
            details="Config: $config"
        fi
    fi
    
    echo "$details"
}

# Get Push-server details
get_push_server_details() {
    local details=""
    local ports=""
    local version=""
    local config=""
    
    # Get TCP ports
    ports=$(get_service_ports "push-server")
    
    # Get Push-server version (try to get from binary or config)
    if command -v push-server >/dev/null 2>&1; then
        version=$(push-server --version 2>/dev/null | head -n1 | sed 's/.*version //' | sed 's/ .*//' || echo "unknown")
    fi
    
    # Get config file
    local config_paths=("/etc/push-server/push-server.conf" "/etc/push-server.conf" "/opt/push-server/config/push-server.conf")
    for path in "${config_paths[@]}"; do
        if [ -f "$path" ]; then
            config="$path"
            break
        fi
    done
    
    # Build details string
    if [ -n "$ports" ]; then
        details="TCP Ports: $ports"
    fi
    
    if [ -n "$version" ] && [ "$version" != "unknown" ]; then
        if [ -n "$details" ]; then
            details="$details, Version: $version"
        else
            details="Version: $version"
        fi
    fi
    
    if [ -n "$config" ]; then
        if [ -n "$details" ]; then
            details="$details, Config: $config"
        else
            details="Config: $config"
        fi
    fi
    
    echo "$details"
}

# Get Sphinx/Manticore details
get_sphinx_details() {
    local details=""
    local ports=""
    local version=""
    local indexes=""
    local config=""
    local service_name=""
    
    # Determine service name (sphinx or manticore)
    if systemctl is-active sphinx >/dev/null 2>&1; then
        service_name="sphinx"
    elif systemctl is-active manticore >/dev/null 2>&1; then
        service_name="manticore"
    fi
    
    # Get TCP ports
    ports=$(get_service_ports "searchd")
    
    # Get version
    if command -v searchd >/dev/null 2>&1; then
        version=$(searchd --help 2>/dev/null | head -n1 | sed 's/.*Sphinx //' | sed 's/ .*//' || echo "unknown")
    fi
    
    # Get indexes count
    if command -v indexer >/dev/null 2>&1; then
        indexes=$(indexer --list 2>/dev/null | wc -l || echo "unknown")
        if [ "$indexes" != "unknown" ] && [ "$indexes" -gt 0 ]; then
            indexes="$indexes indexes"
        else
            indexes=""
        fi
    fi
    
    # Get config file
    local config_paths=("/etc/sphinx/sphinx.conf" "/etc/sphinx.conf" "/etc/manticoresearch/manticore.conf" "/etc/manticore.conf")
    for path in "${config_paths[@]}"; do
        if [ -f "$path" ]; then
            config="$path"
            break
        fi
    done
    
    # Build details string
    if [ -n "$service_name" ]; then
        details="Service: $service_name"
    fi
    
    if [ -n "$ports" ]; then
        if [ -n "$details" ]; then
            details="$details, TCP Ports: $ports"
        else
            details="TCP Ports: $ports"
        fi
    fi
    
    if [ -n "$version" ] && [ "$version" != "unknown" ]; then
        if [ -n "$details" ]; then
            details="$details, Version: $version"
        else
            details="Version: $version"
        fi
    fi
    
    if [ -n "$indexes" ]; then
        if [ -n "$details" ]; then
            details="$details, $indexes"
        else
            details="$indexes"
        fi
    fi
    
    if [ -n "$config" ]; then
        if [ -n "$details" ]; then
            details="$details, Config: $config"
        else
            details="Config: $config"
        fi
    fi
    
    echo "$details"
}

# Display components grouped by category
display_components_by_category() {
    local components=("$@")
    local current_category=""
    
    # Sort by category
    for item in "${components[@]}"; do
        local category=$(echo "$item" | cut -d'|' -f1)
        local component=$(echo "$item" | cut -d'|' -f2)
        local hint=$(echo "$item" | cut -d'|' -f3)
        
        if [ "$category" != "$current_category" ]; then
            echo ""
            log "[$category]"
            current_category="$category"
        fi
        
        echo "  • $component"
        if [ -n "$hint" ]; then
            echo "    → $hint"
        fi
    done
    echo ""
}

# Display missing components summary
display_missing_components() {
    local critical_count=${#MISSING_CRITICAL[@]}
    local recommended_count=${#MISSING_RECOMMENDED[@]}
    local total=$((critical_count + recommended_count))
    
    if [ "$total" -eq 0 ]; then
        return 0
    fi
    
    echo ""
    log "=== Missing Components Summary ==="
    log "Total: $total issues found (Critical: $critical_count, Recommended: $recommended_count)"
    echo ""
    
    # Display critical components table
    if [ "$critical_count" -gt 0 ]; then
        echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
        log "❌ CRITICAL COMPONENTS (must be installed)"
        echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
        display_components_by_category "${MISSING_CRITICAL[@]}"
    fi
    
    # Display recommended components table
    if [ "$recommended_count" -gt 0 ]; then
        echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
        log "⚠️  RECOMMENDED COMPONENTS (optional but recommended)"
        echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
        display_components_by_category "${MISSING_RECOMMENDED[@]}"
    fi
}

# Check if command exists
check_command() {
    local cmd="$1"
    local description="${2:-$cmd}"
    
    if have "$cmd"; then
        log "✅ $description: found"
        if [ "$VERBOSE" = "1" ]; then
            local version
            version=$("$cmd" --version 2>/dev/null | head -n1 || echo "version unknown")
            log_verbose "  Version: $version"
        fi
        return 0
    else
        log "❌ $description: not found"
        return 1
    fi
}

# Check locale availability
check_locale() {
    local locale="$1"
    local description="${2:-$locale}"
    
    if locale_has "$locale"; then
        log "✅ Locale $description: available"
        return 0
    else
        log "❌ Locale $description: not available"
        return 1
    fi
}

# Check system requirements
check_system_requirements() {
    log "=== System Requirements ==="
    local missing=0
    
    # Check bash version
    local bash_version
    bash_version=$(bash --version | head -n1 | grep -o '[0-9]\+\.[0-9]\+' | head -n1)
    if [ "$(echo "$bash_version" | cut -d. -f1)" -ge 4 ]; then
        log "✅ Bash version: $bash_version (>= 4.0 required)"
    else
        log "❌ Bash version: $bash_version (< 4.0 required)"
        missing=1
    fi
    
    # Check core utilities
    local core_utils=("cat" "date" "find" "grep" "sed" "awk" "sort" "head" "tail" "wc" "tr" "cut" "mktemp" "mkdir" "hostname")
    for util in "${core_utils[@]}"; do
        if ! check_command "$util" "Core utility: $util"; then
            missing=1
        fi
    done
    
    # Check archive utilities
    if ! check_command "tar" "Archive utility: tar"; then
        missing=1
    fi
    if ! check_command "gzip" "Compression utility: gzip"; then
        missing=1
    fi
    
    # Check process utilities
    if ! check_command "ps" "Process utility: ps"; then
        missing=1
    fi
    
    # Check network utilities
    local net_utils=("ss" "netstat" "ip" "curl" "wget")
    for util in "${net_utils[@]}"; do
        if ! check_command "$util" "Network utility: $util"; then
            log_warning "$util not found - some network checks may be limited"
        fi
    done
    
    return $missing
}

# Check locale requirements
check_locale_requirements() {
    log "=== Locale Requirements ==="
    local missing=0
    
    # Show current locale settings
    local language="${LANGUAGE:-not set}"
    local lc_time="${LC_TIME:-not set}"
    local lc_all="${LC_ALL:-not set}"
    log "Current locale settings: LANGUAGE=$language, LC_TIME=$lc_time, LC_ALL=$lc_all"
    
    # Check critical locales - check for any en_US variant
    local en_us_found=0
    local en_us_variants=("en_US.UTF-8" "en_US.utf8" "en_US")
    
    for variant in "${en_us_variants[@]}"; do
        if locale_has "$variant"; then
            log "✅ Locale $variant: available"
            en_us_found=1
            break
        fi
    done
    
    if [ "$en_us_found" -eq 0 ]; then
        log_warning "No en_US locale variant found - date parsing may be unpredictable"
        MISSING_RECOMMENDED+=("Locales|en_US.UTF-8|$(get_install_hint 'locale-en' 'en_US.UTF-8')")
    fi
    
    if ! check_locale "ru_RU.UTF-8" "ru_RU.UTF-8 (recommended for Russian dates)"; then
        log_warning "ru_RU.UTF-8 not available - Russian dates may not display correctly"
        MISSING_RECOMMENDED+=("Locales|ru_RU.UTF-8|$(get_install_hint 'locale-ru' 'ru_RU.UTF-8')")
    fi
    
    # Test date parsing
    log "Testing date parsing with current locales..."
    local test_date="2024-01-15 14:30:00"
    if with_locale date -d "$test_date" +%Y-%m-%d >/dev/null 2>&1; then
        log "✅ Date parsing test: passed"
    else
        log "❌ Date parsing test: failed"
        missing=1
    fi
    
    return $missing
}

# Check MySQL requirements
check_mysql_requirements() {
    log "=== MySQL Requirements ==="
    local missing=0
    
    # Check MySQL client
    if ! check_command "mysql" "MySQL client"; then
        missing=1
    fi
    
    # Check MySQL server status
    local mysql_running=0
    local ports=""
    
    if systemctl is-active mysql >/dev/null 2>&1; then
        mysql_running=1
        ports=$(get_service_ports "mysqld")
    elif systemctl is-active mysqld >/dev/null 2>&1; then
        mysql_running=1
        ports=$(get_service_ports "mysqld")
    fi
    
    if [ "$mysql_running" -eq 1 ]; then
        local mysql_details
        mysql_details=$(get_mysql_details)
        if [ -n "$mysql_details" ]; then
            log "✅ MySQL server: running ($mysql_details)"
        else
            log "✅ MySQL server: running"
        fi
    else
        log "❌ MySQL server: not running"
        missing=1
    fi
    
    return $missing
}

# Check PHP requirements
check_php_requirements() {
    log "=== PHP Requirements ==="
    local missing=0
    
    # Check PHP CLI
    if ! check_command "php" "PHP CLI"; then
        missing=1
    fi
    
    # Check PHP-FPM
    if ! check_command "php-fpm" "PHP-FPM"; then
        log_warning "PHP-FPM not found - some PHP checks may be limited"
    else
        # Check if PHP-FPM is running and get details
        local php_fpm_running=0
        if systemctl is-active php-fpm >/dev/null 2>&1; then
            php_fpm_running=1
        fi
        
        if [ "$php_fpm_running" -eq 1 ]; then
            local php_fpm_details
            php_fpm_details=$(get_php_fpm_details)
            if [ -n "$php_fpm_details" ]; then
                log "✅ PHP-FPM: running ($php_fpm_details)"
            else
                log "✅ PHP-FPM: running"
            fi
        else
            log_warning "PHP-FPM: not running"
        fi
    fi
    
    # Check PHP extensions - special handling for mysqli/pdo_mysql
    local mysqli_found=0
    local pdo_mysql_found=0
    
    # Check mysqli
    if php -m | grep -q "^mysqli$"; then
        log "✅ PHP extension: mysqli"
        mysqli_found=1
    else
        log "❌ PHP extension: mysqli (not loaded)"
    fi
    
    # Check pdo_mysql
    if php -m | grep -q "^pdo_mysql$"; then
        log "✅ PHP extension: pdo_mysql"
        pdo_mysql_found=1
    else
        log "❌ PHP extension: pdo_mysql (not loaded)"
    fi
    
    # Check if at least one MySQL extension is available
    if [ "$mysqli_found" -eq 0 ] && [ "$pdo_mysql_found" -eq 0 ]; then
        log "❌ No MySQL PHP extensions found - at least one is required"
        missing=1
        MISSING_CRITICAL+=("PHP Extensions|mysqli or pdo_mysql|$(get_install_hint 'php-mysql' 'mysqli or pdo_mysql')")
    elif [ "$mysqli_found" -eq 1 ] && [ "$pdo_mysql_found" -eq 0 ]; then
        log_warning "Only mysqli found - consider adding pdo_mysql for better compatibility"
        MISSING_RECOMMENDED+=("PHP Extensions|pdo_mysql|$(get_install_hint 'php-mysql' 'pdo_mysql')")
    elif [ "$mysqli_found" -eq 0 ] && [ "$pdo_mysql_found" -eq 1 ]; then
        log_warning "Only pdo_mysql found - consider adding mysqli for better compatibility"
        MISSING_RECOMMENDED+=("PHP Extensions|mysqli|$(get_install_hint 'php-mysql' 'mysqli')")
    fi
    
    # Check other extensions
    local other_extensions=("redis" "opcache" "json")
    for ext in "${other_extensions[@]}"; do
        if php -m | grep -q "^$ext$"; then
            log "✅ PHP extension: $ext"
        else
            log "❌ PHP extension: $ext (not loaded)"
            case "$ext" in
                "redis")
                    MISSING_RECOMMENDED+=("PHP Extensions|$ext|$(get_install_hint 'php-redis' '$ext')")
                    ;;
                "opcache")
                    MISSING_RECOMMENDED+=("PHP Extensions|$ext|$(get_install_hint 'php-opcache' '$ext')")
                    ;;
                "json")
                    missing=1
                    MISSING_CRITICAL+=("PHP Extensions|$ext|$(get_install_hint 'php-mysql' '$ext')")
                    ;;
            esac
        fi
    done
    
    # Additional PHP extension checks for cache services
    check_php_memcache_extensions
    check_php_redis_extension
    
    # Analyze PHP cache settings
    analyze_php_cache_settings
    
    return $missing
}

# Check PHP memcache/memcached extensions
check_php_memcache_extensions() {
    log "=== PHP Memcache Extensions ==="
    local missing=0
    
    # Check if memcached service is running
    local memcached_running=0
    if systemctl is-active memcached >/dev/null 2>&1; then
        memcached_running=1
        log "✅ Memcached service: running"
    else
        log "ℹ️ Memcached service: not running - skipping PHP extension checks"
        return 0
    fi
    
    # Check PHP extensions
    local memcache_found=0
    local memcached_found=0
    
    # Check memcache extension
    if php -m | grep -q "^memcache$"; then
        log "✅ PHP extension: memcache"
        memcache_found=1
    else
        log "❌ PHP extension: memcache (not loaded)"
    fi
    
    # Check memcached extension
    if php -m | grep -q "^memcached$"; then
        log "✅ PHP extension: memcached"
        memcached_found=1
    else
        log "❌ PHP extension: memcached (not loaded)"
    fi
    
    # Check for conflicts and recommendations
    if [ "$memcache_found" -eq 1 ] && [ "$memcached_found" -eq 1 ]; then
        log_warning "Both memcache and memcached extensions loaded - potential conflict"
        MISSING_RECOMMENDED+=("PHP Extensions|memcache/memcached conflict|Consider using only one memcache extension")
    elif [ "$memcache_found" -eq 0 ] && [ "$memcached_found" -eq 0 ]; then
        log_warning "No memcache PHP extensions found - memcached service is running"
        MISSING_RECOMMENDED+=("PHP Extensions|memcache or memcached|$(get_install_hint 'php-memcache' 'memcache or memcached')")
    elif [ "$memcache_found" -eq 1 ] && [ "$memcached_found" -eq 0 ]; then
        log "ℹ️ Using memcache extension (older, consider upgrading to memcached)"
        MISSING_RECOMMENDED+=("PHP Extensions|memcached|$(get_install_hint 'php-memcached' 'memcached')")
    elif [ "$memcache_found" -eq 0 ] && [ "$memcached_found" -eq 1 ]; then
        log "✅ Using memcached extension (recommended)"
    fi
    
    return $missing
}

# Check PHP redis extension
check_php_redis_extension() {
    log "=== PHP Redis Extension ==="
    local missing=0
    
    # Check if redis service is running
    local redis_running=0
    if systemctl is-active redis >/dev/null 2>&1 || systemctl is-active redis-server >/dev/null 2>&1; then
        redis_running=1
        log "✅ Redis service: running"
    else
        log "ℹ️ Redis service: not running - skipping PHP extension check"
        return 0
    fi
    
    # Check redis extension
    if php -m | grep -q "^redis$"; then
        log "✅ PHP extension: redis"
    else
        log "❌ PHP extension: redis (not loaded)"
        MISSING_RECOMMENDED+=("PHP Extensions|redis|$(get_install_hint 'php-redis' 'redis')")
    fi
    
    return $missing
}

# Analyze PHP cache settings
analyze_php_cache_settings() {
    log "=== PHP Cache Settings Analysis ==="
    
    # Get session save handler
    local session_handler
    session_handler=$(php -r "echo ini_get('session.save_handler');" 2>/dev/null || echo "unknown")
    log "Session save handler: $session_handler"
    
    # Get session save path
    local session_path
    session_path=$(php -r "echo ini_get('session.save_path');" 2>/dev/null || echo "unknown")
    log "Session save path: $session_path"
    
    # Check if session handler matches running services
    case "$session_handler" in
        "memcache"|"memcached")
            if ! systemctl is-active memcached >/dev/null 2>&1; then
                log_warning "Session handler set to $session_handler but memcached service is not running"
                MISSING_RECOMMENDED+=("PHP Settings|session.save_handler|Memcached service not running but handler is $session_handler")
            else
                log "✅ Session handler $session_handler matches running memcached service"
            fi
            ;;
        "redis")
            if ! systemctl is-active redis >/dev/null 2>&1 && ! systemctl is-active redis-server >/dev/null 2>&1; then
                log_warning "Session handler set to redis but redis service is not running"
                MISSING_RECOMMENDED+=("PHP Settings|session.save_handler|Redis service not running but handler is redis")
            else
                log "✅ Session handler redis matches running redis service"
            fi
            ;;
        "files")
            log "ℹ️ Using file-based session storage"
            ;;
        *)
            log "ℹ️ Session handler: $session_handler"
            ;;
    esac
    
    # Check memcache-specific settings
    if [ "$session_handler" = "memcache" ] || [ "$session_handler" = "memcached" ]; then
        local hash_strategy
        hash_strategy=$(php -r "echo ini_get('memcache.hash_strategy');" 2>/dev/null || echo "not set")
        log "Memcache hash strategy: $hash_strategy"
        
        local session_redundancy
        session_redundancy=$(php -r "echo ini_get('memcache.session_redundancy');" 2>/dev/null || echo "not set")
        log "Memcache session redundancy: $session_redundancy"
    fi
    
    # Check redis-specific settings
    if [ "$session_handler" = "redis" ]; then
        local redis_locking
        redis_locking=$(php -r "echo ini_get('redis.session.locking_enabled');" 2>/dev/null || echo "not set")
        log "Redis session locking: $redis_locking"
        
        local redis_lock_expire
        redis_lock_expire=$(php -r "echo ini_get('redis.session.lock_expire');" 2>/dev/null || echo "not set")
        log "Redis session lock expire: $redis_lock_expire"
    fi
}

# Check Nginx requirements
check_nginx_requirements() {
    log "=== Nginx Requirements ==="
    local missing=0
    
    # Check Nginx
    if ! check_command "nginx" "Nginx web server"; then
        missing=1
    fi
    
    # Check Nginx status
    local nginx_running=0
    local ports=""
    
    if systemctl is-active nginx >/dev/null 2>&1; then
        nginx_running=1
        ports=$(get_service_ports "nginx")
    fi
    
    if [ "$nginx_running" -eq 1 ]; then
        local nginx_details
        nginx_details=$(get_nginx_details)
        if [ -n "$nginx_details" ]; then
            log "✅ Nginx service: running ($nginx_details)"
        else
            log "✅ Nginx service: running"
        fi
    else
        log "❌ Nginx service: not running"
        missing=1
    fi
    
    return $missing
}

# Check Apache requirements
check_apache_requirements() {
    log "=== Apache Requirements ==="
    local missing=0
    
    # Check Apache
    local apache_found=0
    local apache_type=""
    
    if have "apache2"; then
        apache_found=1
        apache_type="apache2"
    elif have "httpd"; then
        apache_found=1
        apache_type="httpd"
    fi
    
    if [ "$apache_found" -eq 1 ]; then
        log "✅ Apache web server: found ($apache_type)"
    else
        log "❌ Apache web server: not found"
        missing=1
    fi
    
    # Check Apache status
    local apache_running=0
    local ports=""
    
    if systemctl is-active apache2 >/dev/null 2>&1; then
        apache_running=1
        ports=$(get_service_ports "apache2")
    elif systemctl is-active httpd >/dev/null 2>&1; then
        apache_running=1
        ports=$(get_service_ports "httpd")
    fi
    
    if [ "$apache_running" -eq 1 ]; then
        local apache_details
        apache_details=$(get_apache_details)
        if [ -n "$apache_details" ]; then
            log "✅ Apache service: running ($apache_details)"
        else
            log "✅ Apache service: running"
        fi
    else
        log "❌ Apache service: not running"
        missing=1
    fi
    
    return $missing
}

# Check Redis requirements
check_redis_requirements() {
    log "=== Redis Requirements ==="
    local missing=0
    
    # Check Redis CLI
    if ! check_command "redis-cli" "Redis CLI"; then
        missing=1
    fi
    
    # Check Redis server
    if ! check_command "redis-server" "Redis server"; then
        missing=1
    fi
    
    # Check Redis status
    local redis_running=0
    local ports=""
    
    if systemctl is-active redis >/dev/null 2>&1; then
        redis_running=1
        ports=$(get_service_ports "redis-server")
    elif systemctl is-active redis-server >/dev/null 2>&1; then
        redis_running=1
        ports=$(get_service_ports "redis-server")
    fi
    
    if [ "$redis_running" -eq 1 ]; then
        local redis_details
        redis_details=$(get_redis_details)
        if [ -n "$redis_details" ]; then
            log "✅ Redis service: running ($redis_details)"
        else
            log "✅ Redis service: running"
        fi
    else
        log "❌ Redis service: not running"
        missing=1
    fi
    
    return $missing
}

# Check performance monitoring requirements
check_performance_requirements() {
    log "=== Performance Monitoring Requirements ==="
    local missing=0
    
    # Check atop
    if ! check_command "atop" "atop (system monitoring)"; then
        log_warning "atop not found - system monitoring will be limited"
    fi
    
    # Check sar (sysstat)
    if ! check_command "sar" "sar (sysstat)"; then
        log_warning "sar not found - historical performance data will be limited"
    fi
    
    # Check iostat
    if ! check_command "iostat" "iostat (sysstat)"; then
        log_warning "iostat not found - disk I/O monitoring will be limited"
    fi
    
    return $missing
}

# Check security tools (optional)
check_security_tools() {
    log "=== Security Tools Requirements (Optional) ==="
    local missing=0
    
    # Detect distribution type
    local distro_id=""
    if [ -f /etc/os-release ]; then
        distro_id=$(grep "^ID=" /etc/os-release | cut -d= -f2 | tr -d '"')
    fi
    
    # Check lynis (common for all)
    log "--- Security Analysis Tools ---"
    if ! check_command "lynis" "Lynis (comprehensive security audit tool)"; then
        log_warning "lynis not found - advanced security analysis will be limited"
        log "  Install: apt-get install lynis (Debian/Ubuntu) or dnf install lynis (RHEL-family)"
        MISSING_RECOMMENDED+=("Security Tools|Lynis|$(get_install_hint 'lynis' 'Lynis')")
        echo ""
        missing=1
    fi
    
    # Check debsecan (Debian/Ubuntu only)
    case "$distro_id" in
        "ubuntu"|"debian")
            if ! check_command "debsecan" "Debsecan (Debian security scanner)"; then
                log_warning "debsecan not found - CVE scanning will be limited"
                log "  Install: apt-get install debsecan"
                MISSING_RECOMMENDED+=("Security Tools|Debsecan|$(get_install_hint 'debsecan' 'Debsecan')")
                echo ""
                missing=1
            fi
            ;;
    esac
    
    # Check yum-plugin-security (RHEL-family only)
    case "$distro_id" in
        "almalinux"|"rocky"|"centos"|"rhel"|"fedora")
            # Для dnf встроенная поддержка
            if command -v dnf >/dev/null 2>&1; then
                log "✅ dnf has built-in security updates support"
            elif command -v yum >/dev/null 2>&1; then
                # Для старых систем с yum проверяем плагин
                if rpm -q yum-plugin-security >/dev/null 2>&1; then
                    log "✅ yum-plugin-security: installed"
                else
                    # Проверяем, работает ли updateinfo без плагина
                    if yum updateinfo list 2>/dev/null | grep -q "updateinfo"; then
                        log "✅ yum updateinfo: working"
                    else
                        log_warning "yum-plugin-security not found - security updates analysis will be limited"
                        log "  Install: yum install yum-plugin-security"
                        echo ""
                        missing=1
                    fi
                fi
            fi
            ;;
    esac
    
    # Check curl/wget for API access (common for all)
    log "--- API Access Tools ---"
    if ! check_command "curl" "curl (HTTP client for API requests)"; then
        if ! check_command "wget" "wget (HTTP client for API requests)"; then
            log_warning "curl/wget not found - endoflife.date API access will be unavailable"
            log "  Install: apt-get install curl (Debian/Ubuntu) or dnf install curl (RHEL-family)"
            echo ""
            missing=1
        fi
    fi
    
    # Check jq (optional, common for all)
    if ! check_command "jq" "jq (JSON parser, optional)"; then
        log_warning "jq not found - JSON parsing will use basic methods"
        log "  Install: apt-get install jq (Debian/Ubuntu) or dnf install jq (RHEL-family)"
        echo ""
    fi
    
    # Check firewall tools (common for all)
    log "--- Firewall Tools ---"
    local firewall_found=0
    if check_command "ufw" "UFW (Uncomplicated Firewall)"; then
        firewall_found=1
    fi
    
    if check_command "firewall-cmd" "firewalld (Firewall daemon)"; then
        firewall_found=1
    fi
    
    if check_command "iptables" "iptables (Packet filter)"; then
        firewall_found=1
    fi
    
    if [ "$firewall_found" -eq 0 ]; then
        log_warning "No firewall tools found - firewall analysis will be limited"
        log "  Install: apt-get install ufw (Debian/Ubuntu) or dnf install firewalld (RHEL-family)"
        MISSING_RECOMMENDED+=("Security Tools|Firewall Tools|$(get_install_hint 'firewall' 'Firewall Tools')")
        echo ""
        missing=1
    fi
    
    echo ""  # Разрыв перед итоговым сообщением
    
    if [ "$missing" -eq 0 ]; then
        log "✅ All security tools are available"
        return 0
    else
        log_warning "Some security tools are missing (optional but recommended)"
        return 1
    fi
}

# Check additional tools requirements
check_additional_tools() {
    log "=== Additional Tools Requirements ==="
    local missing=0
    
    # MySQL tools
    log "--- MySQL Tools ---"
    if ! check_command "mysqltuner" "MySQLTuner (MySQL configuration analyzer)"; then
        log_warning "mysqltuner not found - MySQL configuration analysis will be limited"
        log "  Install: apt-get install mysqltuner (Debian/Ubuntu)"
        log "  Or download: https://github.com/major/MySQLTuner-perl"
        MISSING_RECOMMENDED+=("MySQL Tools|MySQLTuner|$(get_install_hint 'mysqltuner' 'MySQLTuner')")
        echo ""
    fi
    
    # Percona Toolkit
    local pt_tools=("pt-query-digest" "pt-mysql-summary" "pt-variable-advisor" "pt-duplicate-key-checker" "pt-index-usage")
    local pt_found=0
    for tool in "${pt_tools[@]}"; do
        if have "$tool"; then
            pt_found=1
            log "✅ Percona Toolkit: $tool"
        fi
    done
    
    if [ "$pt_found" -eq 0 ]; then
        log_warning "Percona Toolkit not found - advanced MySQL analysis will be limited"
        log "  Install: apt-get install percona-toolkit (Debian/Ubuntu)"
        log "  Or: yum install percona-toolkit (CentOS/RHEL)"
        MISSING_CRITICAL+=("MySQL Tools|Percona Toolkit|$(get_install_hint 'percona-toolkit' 'Percona Toolkit')")
        echo ""
    fi
    
    # Tuned
    log "--- System Tuning ---"
    if ! check_command "tuned-adm" "tuned-adm (system tuning)"; then
        log_warning "tuned-adm not found - system tuning analysis will be limited"
        log "  Install: apt-get install tuned (Debian/Ubuntu)"
        log "  Or: yum install tuned (CentOS/RHEL)"
        MISSING_RECOMMENDED+=("System Tools|tuned-adm|$(get_install_hint 'tuned' 'tuned-adm')")
        echo ""
    fi
    
    # Sysbench
    if ! check_command "sysbench" "sysbench (benchmarking)"; then
        log_warning "sysbench not found - benchmarking will be limited"
        log "  Install: apt-get install sysbench (Debian/Ubuntu)"
        log "  Or: yum install sysbench (CentOS/RHEL)"
        MISSING_RECOMMENDED+=("System Tools|sysbench|$(get_install_hint 'sysbench' 'sysbench')")
        echo ""
    fi
    
    # SSL tools
    log "--- SSL/Security Tools ---"
    if ! check_command "openssl" "OpenSSL (SSL analysis)"; then
        log_warning "openssl not found - SSL analysis will be limited"
    fi
    
    if ! check_command "testssl.sh" "testssl.sh (SSL testing)"; then
        log_warning "testssl.sh not found - SSL testing will be limited"
        MISSING_CRITICAL+=("Report Tools|testssl.sh|$(get_install_hint 'testssl' 'testssl.sh')")
        echo ""
    fi
    
    # HTML/PDF generation tools
    log "--- Report Generation Tools ---"
    if ! check_command "wkhtmltopdf" "wkhtmltopdf (PDF generation)"; then
        log_warning "wkhtmltopdf not found - PDF report generation will be limited"
        log "  Install: apt-get install wkhtmltopdf (Debian/Ubuntu)"
        MISSING_RECOMMENDED+=("Report Tools|wkhtmltopdf|$(get_install_hint 'wkhtmltopdf' 'wkhtmltopdf')")
        echo ""
    fi
    
    if ! check_command "gnuplot" "gnuplot (graphics generation)"; then
        log_warning "gnuplot not found - graphics generation will be limited"
        log "  Install: apt-get install gnuplot (Debian/Ubuntu)"
        MISSING_RECOMMENDED+=("Report Tools|gnuplot|$(get_install_hint 'gnuplot' 'gnuplot')")
        echo ""
    fi
    
    return $missing
}

# Check Bitrix-specific requirements
check_bitrix_requirements() {
    log "=== Bitrix-Specific Requirements ==="
    local missing=0
    
    # Check Bitrix directories
    local bitrix_dirs=("/var/www/bitrix" "/home/bitrix/www" "/opt/bitrix")
    local bitrix_found=0
    
    for dir in "${bitrix_dirs[@]}"; do
        if [ -d "$dir" ]; then
            log "✅ Bitrix directory: $dir"
            bitrix_found=1
        fi
    done
    
    if [ "$bitrix_found" -eq 0 ]; then
        log_warning "Bitrix directory not found in standard locations"
        log "  Expected locations: ${bitrix_dirs[*]}"
    fi
    
    # Check push-server
    local push_running=0
    local push_ports=""
    
    if systemctl is-active push-server >/dev/null 2>&1; then
        push_running=1
        push_ports=$(get_service_ports "push-server")
    fi
    
    if [ "$push_running" -eq 1 ]; then
        local push_details
        push_details=$(get_push_server_details)
        if [ -n "$push_details" ]; then
            log "✅ Push-server: running ($push_details)"
        else
            log "✅ Push-server: running"
        fi
    else
        log_warning "Push-server: not running or not found"
    fi
    
    # Check Sphinx/Manticore
    local search_running=0
    local search_ports=""
    
    if systemctl is-active sphinx >/dev/null 2>&1; then
        search_running=1
        search_ports=$(get_service_ports "searchd")
    elif systemctl is-active manticore >/dev/null 2>&1; then
        search_running=1
        search_ports=$(get_service_ports "searchd")
    fi
    
    if [ "$search_running" -eq 1 ]; then
        local search_details
        search_details=$(get_sphinx_details)
        if [ -n "$search_details" ]; then
            log "✅ Sphinx/Manticore: running ($search_details)"
        else
            log "✅ Sphinx/Manticore: running"
        fi
    else
        log_warning "Sphinx/Manticore: not running or not found"
    fi
    
    # Check Memcached
    local memcached_running=0
    local memcached_ports=""
    
    if systemctl is-active memcached >/dev/null 2>&1; then
        memcached_running=1
        memcached_ports=$(get_service_ports "memcached")
    fi
    
    if [ "$memcached_running" -eq 1 ]; then
        local memcached_details
        memcached_details=$(get_memcached_details)
        if [ -n "$memcached_details" ]; then
            log "✅ Memcached: running ($memcached_details)"
        else
            log "✅ Memcached: running"
        fi
    else
        log_warning "Memcached: not running or not found"
    fi
    
    return $missing
}

# Check cron requirements
check_permissions_requirements() {
    log "=== Проверка прав доступа ==="
    
    if [ "$EUID" -eq 0 ]; then
        log "✅ Root-права: есть (полный аудит)"
    else
        log "⚠️  Root-права: НЕТ (ограниченный аудит)"
        log "Недоступно: /var/log/, /etc/, smartctl, dmidecode"
        log "Рекомендация: sudo ./run_all_audits.sh --all"
    fi
}

check_cron_requirements() {
    log "=== Cron Requirements ==="
    local missing=0
    
    # Check cron service
    if systemctl is-active cron >/dev/null 2>&1 || systemctl is-active crond >/dev/null 2>&1; then
        log "✅ Cron service: running"
    else
        log "❌ Cron service: not running"
        missing=1
    fi
    
    # Check cron directories
    local cron_dirs=("/etc/cron.d" "/etc/cron.daily" "/etc/cron.hourly" "/etc/cron.weekly" "/etc/cron.monthly")
    for dir in "${cron_dirs[@]}"; do
        if [ -d "$dir" ]; then
            log "✅ Cron directory: $dir"
        else
            log_warning "Cron directory not found: $dir"
        fi
    done
    
    return $missing
}

# Generate installation recommendations
generate_installation_recommendations() {
    log "=== Installation Recommendations ==="
    
    # Detect distribution and version
    local distro="unknown"
    local version="unknown"
    local package_manager=""
    
    if [ -f /etc/os-release ]; then
        distro=$(grep "^ID=" /etc/os-release | cut -d= -f2 | tr -d '"')
        version=$(grep "^VERSION_ID=" /etc/os-release | cut -d= -f2 | tr -d '"')
    fi
    
    log "Detected distribution: $distro (version: $version)"
    echo
    
    echo ""
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    log "🚀 AUTOMATIC INSTALLATION AVAILABLE"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo ""
    echo "Instead of manual installation, you can run:"
    echo ""
    echo "  sudo ./check_requirements.sh --install"
    echo ""
    echo "This will automatically:"
    echo "  • Install all missing packages"
    echo "  • Configure monitoring tools (sysstat, atop)"
    echo "  • Apply security updates"
    echo "  • Verify installation"
    echo ""
    echo "For non-interactive installation:"
    echo "  sudo ./check_requirements.sh --install --non-interactive"
    echo ""
    echo "For monitoring tools only:"
    echo "  sudo ./setup_monitoring.sh --non-interactive"
    echo ""
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    log "📋 MANUAL INSTALLATION COMMANDS (if preferred)"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo ""
    
    case "$distro" in
        "ubuntu"|"debian")
            log "Debian/Ubuntu installation commands:"
            echo "  sudo apt-get update"
            echo "  sudo apt-get install mysqltuner percona-toolkit tuned sysbench"
            echo "  sudo apt-get install wkhtmltopdf gnuplot"
            echo "  sudo apt-get install testssl.sh"
            ;;
        "almalinux"|"rocky"|"centos"|"rhel"|"fedora")
            log "RHEL-family (AlmaLinux/Rocky/CentOS/RHEL/Fedora) installation commands:"
            echo "  # Install EPEL repository (contains mysqltuner, sysbench)"
            echo "  sudo dnf install -y epel-release"
            echo ""
            echo "  # Install Percona repository (for percona-toolkit)"
            echo "  sudo dnf install -y https://repo.percona.com/yum/percona-release-latest.noarch.rpm"
            echo ""
            echo "  # Install required packages"
            echo "  sudo dnf install -y tuned mysqltuner percona-toolkit gnuplot sysbench"
            echo ""
            echo "  # Optional packages (may not be available in all repositories):"
            echo "  # wkhtmltopdf - try RPMFusion or manual installation:"
            echo "  #   sudo dnf install -y https://download1.rpmfusion.org/free/el/rpmfusion-free-release-\$(rpm -E %rhel).noarch.rpm"
            echo "  #   sudo dnf install -y wkhtmltopdf"
            echo "  #   OR download from: https://wkhtmltopdf.org/downloads.html"
            echo ""
            echo "  # For testssl.sh (manual installation):"
            echo "  curl -O https://raw.githubusercontent.com/drwetter/testssl.sh/master/testssl.sh"
            echo "  chmod +x testssl.sh"
            echo "  sudo mv testssl.sh /usr/local/bin/"
            ;;
        *)
            log "Unknown distribution - manual installation required"
            echo "  MySQLTuner: https://github.com/major/MySQLTuner-perl"
            echo "  Percona Toolkit: https://www.percona.com/downloads/percona-toolkit/"
            echo "  testssl.sh: https://github.com/drwetter/testssl.sh"
            echo ""
            echo "  For RHEL-family distributions, try:"
            echo "  sudo dnf install -y epel-release"
            echo "  sudo dnf install -y https://repo.percona.com/yum/percona-release-latest.noarch.rpm"
            echo "  sudo dnf install -y tuned mysqltuner percona-toolkit gnuplot sysbench"
            ;;
    esac
}

# Main execution
main() {
    # Detect distribution and package manager
    detect_distro
    
    log "Bitrix24 Audit Requirements Checker v$VERSION"
    log "Checking requirements for: ${MODULE:-all}"
    echo
    
    local total_missing=0
    
    # Check system requirements
    if [ -z "$MODULE" ] || [ "$MODULE" = "all" ] || [ "$MODULE" = "system" ]; then
        if ! check_system_requirements; then
            total_missing=1
        fi
        echo
    fi
    
    # Check locale requirements
    if [ -z "$MODULE" ] || [ "$MODULE" = "all" ] || [ "$MODULE" = "system" ]; then
        if ! check_locale_requirements; then
            total_missing=1
        fi
        echo
    fi
    
    # Check MySQL requirements
    if [ -z "$MODULE" ] || [ "$MODULE" = "all" ] || [ "$MODULE" = "mysql" ]; then
        if ! check_mysql_requirements; then
            total_missing=1
        fi
        echo
    fi
    
    # Check PHP requirements
    if [ -z "$MODULE" ] || [ "$MODULE" = "all" ] || [ "$MODULE" = "php" ]; then
        if ! check_php_requirements; then
            total_missing=1
        fi
        echo
    fi
    
    # Check Nginx requirements
    if [ -z "$MODULE" ] || [ "$MODULE" = "all" ] || [ "$MODULE" = "nginx" ]; then
        if ! check_nginx_requirements; then
            total_missing=1
        fi
        echo
    fi
    
    # Check Apache requirements
    if [ -z "$MODULE" ] || [ "$MODULE" = "all" ] || [ "$MODULE" = "apache" ]; then
        if ! check_apache_requirements; then
            total_missing=1
        fi
        echo
    fi
    
    # Check Redis requirements
    if [ -z "$MODULE" ] || [ "$MODULE" = "all" ] || [ "$MODULE" = "redis" ]; then
        if ! check_redis_requirements; then
            total_missing=1
        fi
        echo
    fi
    
    # Check performance monitoring requirements
    if [ -z "$MODULE" ] || [ "$MODULE" = "all" ] || [ "$MODULE" = "atop" ] || [ "$MODULE" = "sar" ]; then
        if ! check_performance_requirements; then
            total_missing=1
        fi
        echo
    fi
    
    # Check additional tools
    if [ -z "$MODULE" ] || [ "$MODULE" = "all" ] || [ "$MODULE" = "tools" ]; then
        if ! check_additional_tools; then
            total_missing=1
        fi
        echo
    fi
    
    # Check security tools (optional)
    if [ -z "$MODULE" ] || [ "$MODULE" = "all" ] || [ "$MODULE" = "security" ]; then
        if ! check_security_tools; then
            total_missing=1
        fi
        echo
    fi
    
    # Check Bitrix-specific requirements
    if [ -z "$MODULE" ] || [ "$MODULE" = "all" ] || [ "$MODULE" = "bitrix" ]; then
        if ! check_bitrix_requirements; then
            total_missing=1
        fi
        echo
    fi
    
    # Check permissions requirements
    if [ -z "$MODULE" ] || [ "$MODULE" = "all" ] || [ "$MODULE" = "permissions" ]; then
        check_permissions_requirements
        echo
    fi
    
    # Check cron requirements
    if [ -z "$MODULE" ] || [ "$MODULE" = "all" ] || [ "$MODULE" = "cron" ]; then
        if ! check_cron_requirements; then
            total_missing=1
        fi
        echo
    fi
    
    # Auto-install if requested
    if [ "$AUTO_INSTALL" -eq 1 ]; then
        if [ "$EUID" -ne 0 ]; then
            log_error "Auto-install requires root privileges. Run with sudo."
            exit 1
        fi
        
        echo ""
        log "=== Auto-Install Mode ==="
        display_missing_components
        echo ""
        
        if [ "$NON_INTERACTIVE" -eq 0 ]; then
            read -p "Install missing packages automatically? [Y/n]: " answer
            answer=${answer:-Y}
            if [[ "$answer" == "n" || "$answer" == "N" ]]; then
                log "Installation cancelled"
                exit 0
            fi
        fi
        
        auto_install_packages
        
        echo ""
        log "=== Installation completed. Re-checking requirements ==="
        exec "$0" --module all
    fi
    
    # Generate installation recommendations
    if [ "$total_missing" -gt 0 ] || [ "$VERBOSE" = "1" ]; then
        generate_installation_recommendations
        echo
    fi
    
    # Final summary
    if [ "$total_missing" -eq 0 ]; then
        log "✅ All requirements satisfied!"
        exit 0
    else
        log "❌ Some requirements are missing. See details below."
        echo ""
        display_missing_components
        echo ""
        log "💡 Quick fix: Run automatic installation:"
        log "   sudo ./check_requirements.sh --install"
        exit 1
    fi
}

# Run main function
main "$@"