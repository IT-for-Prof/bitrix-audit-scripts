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

# Show help
show_help() {
    cat << EOF
Bitrix24 Monitoring Setup v$VERSION

Usage: $0 [OPTIONS]

OPTIONS:
    --force                 Force installation even if tools are already configured
    --non-interactive       Run without user prompts
    --verbose, -v           Enable verbose output
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

EOF
}

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
            package_manager="dnf"
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

# Install packages based on distribution
install_packages() {
    log_info "Installing monitoring packages..."
    
    case "$PACKAGE_MANAGER" in
        "apt")
            log_info "Updating package lists..."
            apt-get update
            
            log_info "Installing packages: sysstat atop sysbench acct"
            apt-get install -y sysstat atop sysbench acct
            ;;
        "dnf")
            log_info "Installing packages: sysstat atop sysbench psacct"
            dnf install -y sysstat atop sysbench psacct
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
        "dnf")
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
        
        # Enable sysstat
        sed -ri 's/^ENABLED=.*/ENABLED="true"/' "$sysstat_config" || \
        echo 'ENABLED="true"' >> "$sysstat_config"
        
        # Set history to 7 days
        sed -ri 's/^HISTORY=.*/HISTORY=7/' "$sysstat_config" || \
        echo 'HISTORY=7' >> "$sysstat_config"
        
        log_success "sysstat configuration updated"
    else
        log_warning "sysstat config file not found: $sysstat_config"
    fi
    
    # Configure cron for sysstat (or systemd timers on newer systems)
    if [ -n "$cron_file" ] && [ -f "$cron_file" ]; then
        backup_file "$cron_file"
        
        # Update sa1 to run every minute with 30-second intervals
        sed -ri 's#^[^#].*sa1.*#* * * * * root /usr/lib64/sa/sa1 30 2 \&>/dev/null#' "$cron_file" || \
        sed -ri 's#^[^#].*sa1.*#* * * * * root /usr/lib/sa/sa1 30 2 \&>/dev/null#' "$cron_file" || true
        
        # Ensure sa2 exists for daily reports
        if ! grep -q 'sa2' "$cron_file"; then
            echo '53 23 * * * root /usr/lib64/sa/sa2 -A' >> "$cron_file" || \
            echo '53 23 * * * root /usr/lib/sa/sa2 -A' >> "$cron_file"
        fi
        
        log_success "sysstat cron configuration updated"
    elif [ -z "$cron_file" ]; then
        # On newer systems (AlmaLinux 9+), sysstat uses systemd timers
        log_info "sysstat uses systemd timers (modern configuration)"
        
        # Check if timers are active
        if systemctl is-active --quiet sysstat-collect.timer; then
            log_success "sysstat-collect timer is active"
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
        "dnf")
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
    
    # Enable sysstat
    systemctl enable sysstat
    systemctl start sysstat
    log_success "sysstat service enabled and started"
    
    # Enable atop
    systemctl enable atop
    systemctl start atop
    log_success "atop service enabled and started"
    
    # Enable atopacctd if available
    if systemctl list-unit-files | grep -q atopacctd; then
        systemctl enable atopacctd
        systemctl start atopacctd
        log_success "atopacctd service enabled and started"
    else
        log_info "atopacctd service not available"
    fi
    
    # Enable process accounting
    local service_name=""
    case "$PACKAGE_MANAGER" in
        "apt")
            service_name="acct"
            ;;
        "dnf")
            service_name="psacct"
            ;;
    esac
    
    if [ -n "$service_name" ] && systemctl list-unit-files | grep -q "$service_name"; then
        systemctl enable "$service_name"
        systemctl start "$service_name"
        log_success "$service_name service enabled and started"
    else
        log_warning "Process accounting service not available"
    fi
}

# Verify setup
verify_setup() {
    log_info "Verifying setup..."
    
    local all_good=1
    
    # Check sysstat
    if systemctl is-active sysstat >/dev/null 2>&1; then
        log_success "sysstat is running"
    else
        log_error "sysstat is not running"
        all_good=0
    fi
    
    # Check atop
    if systemctl is-active atop >/dev/null 2>&1; then
        log_success "atop is running"
    else
        log_error "atop is not running"
        all_good=0
    fi
    
    # Check if sar data is being collected
    if [ -d /var/log/sa ] && [ "$(ls -A /var/log/sa 2>/dev/null)" ]; then
        log_success "sar data collection is working"
    else
        log_warning "sar data collection may not be working yet (wait a few minutes)"
    fi
    
    # Check if atop data is being collected
    if [ -d /var/log/atop ] && [ "$(ls -A /var/log/atop 2>/dev/null)" ]; then
        log_success "atop data collection is working"
    else
        log_warning "atop data collection may not be working yet (wait a few minutes)"
    fi
    
    # Check commands availability
    local commands=("sar" "atop" "sysbench" "iostat" "vmstat")
    for cmd in "${commands[@]}"; do
        if command -v "$cmd" >/dev/null 2>&1; then
            log_success "$cmd command is available"
        else
            log_error "$cmd command is not available"
            all_good=0
        fi
    done
    
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
    
    # Check if sysstat is configured
    if systemctl is-active sysstat >/dev/null 2>&1; then
        configured=$((configured + 1))
    fi
    
    # Check if atop is configured
    if systemctl is-active atop >/dev/null 2>&1; then
        configured=$((configured + 1))
    fi
    
    # Check if data is being collected
    if [ -d /var/log/sa ] && [ "$(ls -A /var/log/sa 2>/dev/null)" ]; then
        configured=$((configured + 1))
    fi
    
    if [ "$configured" -ge 2 ]; then
        log_warning "Monitoring tools appear to be already configured"
        echo ""
        echo "Detected:"
        echo "  • sysstat service: $(systemctl is-active sysstat 2>/dev/null || echo 'inactive')"
        echo "  • atop service: $(systemctl is-active atop 2>/dev/null || echo 'inactive')"
        echo "  • Data collection: $(if [ -d /var/log/sa ] && [ "$(ls -A /var/log/sa 2>/dev/null)" ]; then echo 'active'; else echo 'inactive'; fi)"
        echo ""
        echo "Use --force to reconfigure anyway"
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
    
    # Check if already configured
    if check_existing_setup; then
        exit 0
    fi
    
    # Confirm setup
    confirm_setup
    
    echo ""
    log_info "Starting monitoring tools setup..."
    echo ""
    
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
        echo ""
    fi
    
    # Show report
    show_report
}

# Run main function
main "$@"
