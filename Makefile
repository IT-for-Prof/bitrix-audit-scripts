SHELL := /bin/bash
.PHONY: ci shellcheck syntax check-locales check-requirements test-all clean help install-deps install-tools install-optional setup-locales setup-monitoring

# Version information
VERSION := 2.1.0

# Default audit directory
AUDIT_DIR := /root/audit

shellcheck:
	@command -v shellcheck >/dev/null 2>&1 || { echo "shellcheck not installed"; exit 1; }
	find . -type f -name '*.sh' -not -path './.github/*' -print0 | xargs -0 shellcheck

syntax:
	@echo "Checking syntax of all shell scripts..."
	@for script in *.sh; do \
		if [ -f "$$script" ]; then \
			echo "Checking $$script..."; \
			bash -n "$$script" || exit 1; \
		fi; \
	done
	@echo "All scripts passed syntax check"

check-locales:
	@echo "Checking locale availability..."
	@echo "Required locales: en_US.UTF-8, ru_RU.UTF-8"
	@echo ""
	@echo "Available locales:"
	@locale -a | grep -E "(en_US|ru_RU)" || echo "No required locales found"
	@echo ""
	@echo "Current locale settings:"
	@echo "LANG=$$LANG"
	@echo "LC_TIME=$$LC_TIME"
	@echo "LC_NUMERIC=$$LC_NUMERIC"
	@echo ""
	@echo "Testing locale functions..."
	@bash -c 'source audit_common.sh && setup_locale && echo "Locale setup successful"'

check-requirements:
	@echo "Checking system requirements..."
	@if [ -f "./check_requirements.sh" ]; then \
		./check_requirements.sh --verbose; \
	else \
		echo "check_requirements.sh not found, checking manually..."; \
		for cmd in bash awk sed grep sort head tail date systemctl journalctl openssl curl nc xxd atopsar sar sadf mysql redis-cli php composer lsof vmstat iostat smartctl ss ethtool findmnt slabtop numactl chronyc ntpq ntpstat getenforce sestatus aa-status lsblk lvs tar gzip; do \
			if command -v "$$cmd" >/dev/null 2>&1; then \
				echo "✓ $$cmd"; \
			else \
				echo "✗ $$cmd (missing)"; \
			fi; \
		done; \
	fi

test-all:
	@echo "Running comprehensive tests..."
	@echo "Version: $(VERSION)"
	@echo "Audit directory: $(AUDIT_DIR)"
	@echo ""
	@echo "1. Syntax check..."
	@$(MAKE) syntax
	@echo ""
	@echo "2. Shellcheck..."
	@$(MAKE) shellcheck
	@echo ""
	@echo "3. Locale check..."
	@$(MAKE) check-locales
	@echo ""
	@echo "4. Requirements check..."
	@$(MAKE) check-requirements
	@echo ""
	@echo "All tests completed successfully!"

clean:
	@echo "Cleaning up temporary files..."
	@rm -f *.bak
	@rm -f *~
	@rm -f .*.swp
	@rm -f /tmp/audit_*
	@echo "Cleanup completed"

install-tools:
	@echo "Installing additional audit tools..."
	@if [ -f /etc/os-release ]; then \
		DISTRO_ID=$$(grep "^ID=" /etc/os-release | cut -d= -f2 | tr -d '"'); \
		DISTRO_VERSION=$$(grep "^VERSION_ID=" /etc/os-release | cut -d= -f2 | tr -d '"'); \
		echo "Detected distribution: $$DISTRO_ID (version: $$DISTRO_VERSION)"; \
		case "$$DISTRO_ID" in \
			"ubuntu"|"debian") \
				echo "Installing additional tools via apt-get..."; \
				apt-get update && apt-get install -y tuned mysqltuner percona-toolkit gnuplot sysbench wkhtmltopdf; \
				;; \
			"almalinux"|"rocky"|"centos"|"rhel"|"fedora") \
				echo "Installing additional tools via dnf..."; \
				echo "Installing EPEL repository (if not already installed)..."; \
				dnf install -y epel-release || { echo "ERROR: Failed to install EPEL repository"; exit 1; }; \
				echo "Installing Percona repository..."; \
				dnf install -y https://repo.percona.com/yum/percona-release-latest.noarch.rpm || { echo "ERROR: Failed to install Percona repository"; exit 1; }; \
				echo "Installing required tools..."; \
				dnf install -y tuned mysqltuner percona-toolkit gnuplot sysbench || { echo "ERROR: Failed to install required tools"; exit 1; }; \
				echo "Installing optional tools..."; \
				dnf install -y wkhtmltopdf || { echo "WARNING: wkhtmltopdf not available in standard repos"; echo "Try RPMFusion: sudo dnf install -y https://download1.rpmfusion.org/free/el/rpmfusion-free-release-\$$(rpm -E %rhel).noarch.rpm"; echo "Then: sudo dnf install -y wkhtmltopdf"; }; \
				;; \
			*) \
				echo "Unknown distribution: $$DISTRO_ID"; \
				echo "Please install manually: tuned mysqltuner percona-toolkit gnuplot sysbench"; \
				echo "For RHEL-family distributions, try:"; \
				echo "  sudo dnf install -y epel-release"; \
				echo "  sudo dnf install -y https://repo.percona.com/yum/percona-release-latest.noarch.rpm"; \
				echo "  sudo dnf install -y tuned mysqltuner percona-toolkit gnuplot sysbench"; \
				exit 1; \
				;; \
		esac; \
	else \
		echo "Cannot detect distribution - /etc/os-release not found"; \
		echo "Please install manually: tuned mysqltuner percona-toolkit gnuplot sysbench"; \
		exit 1; \
	fi

install-optional:
	@echo "Installing optional packages..."
	@if [ -f /etc/os-release ]; then \
		DISTRO_ID=$$(grep "^ID=" /etc/os-release | cut -d= -f2 | tr -d '"'); \
		DISTRO_VERSION=$$(grep "^VERSION_ID=" /etc/os-release | cut -d= -f2 | tr -d '"'); \
		echo "Detected distribution: $$DISTRO_ID (version: $$DISTRO_VERSION)"; \
		case "$$DISTRO_ID" in \
			"ubuntu"|"debian") \
				echo "Installing optional packages via apt-get..."; \
				apt-get update && apt-get install -y wkhtmltopdf testssl.sh; \
				;; \
			"almalinux"|"rocky"|"centos"|"rhel"|"fedora") \
				echo "Installing optional packages via dnf..."; \
				echo "Installing RPMFusion repository..."; \
				dnf install -y https://download1.rpmfusion.org/free/el/rpmfusion-free-release-$$(rpm -E %rhel).noarch.rpm || { echo "ERROR: Failed to install RPMFusion repository"; exit 1; }; \
				echo "Installing wkhtmltopdf..."; \
				dnf install -y wkhtmltopdf || { echo "WARNING: wkhtmltopdf installation failed"; echo "Try manual installation from: https://wkhtmltopdf.org/downloads.html"; }; \
				echo "Installing testssl.sh manually..."; \
				curl -O https://raw.githubusercontent.com/drwetter/testssl.sh/master/testssl.sh && chmod +x testssl.sh && mv testssl.sh /usr/local/bin/ || { echo "WARNING: testssl.sh installation failed"; }; \
				;; \
			*) \
				echo "Unknown distribution: $$DISTRO_ID"; \
				echo "Please install manually: wkhtmltopdf, testssl.sh"; \
				exit 1; \
				;; \
		esac; \
	else \
		echo "Cannot detect distribution - /etc/os-release not found"; \
		echo "Please install manually: wkhtmltopdf, testssl.sh"; \
		exit 1; \
	fi

install-deps:
	@echo "Installing dependencies..."
	@if [ -f /etc/os-release ]; then \
		DISTRO_ID=$$(grep "^ID=" /etc/os-release | cut -d= -f2 | tr -d '"'); \
		DISTRO_VERSION=$$(grep "^VERSION_ID=" /etc/os-release | cut -d= -f2 | tr -d '"'); \
		echo "Detected distribution: $$DISTRO_ID (version: $$DISTRO_VERSION)"; \
		case "$$DISTRO_ID" in \
			"ubuntu"|"debian") \
				echo "Installing packages via apt-get..."; \
				apt-get update && apt-get install -y shellcheck sysstat atop; \
				;; \
			"almalinux"|"rocky"|"centos"|"rhel"|"fedora") \
				echo "Installing packages via dnf..."; \
				echo "Installing EPEL repository..."; \
				dnf install -y epel-release || { echo "ERROR: Failed to install EPEL repository"; exit 1; }; \
				echo "Installing base packages..."; \
				dnf install -y shellcheck sysstat atop || { echo "ERROR: Failed to install base packages"; exit 1; }; \
				;; \
			*) \
				echo "Unknown distribution: $$DISTRO_ID"; \
				echo "Please install manually: shellcheck, sysstat, atop"; \
				exit 1; \
				;; \
		esac; \
	else \
		echo "Cannot detect distribution - /etc/os-release not found"; \
		echo "Please install manually: shellcheck, sysstat, atop"; \
		exit 1; \
	fi

setup-locales:
	@echo "Setting up locales..."
	@if command -v locale-gen >/dev/null 2>&1; then \
		echo "Generating locales..."; \
		locale-gen en_US.UTF-8; \
		locale-gen ru_RU.UTF-8; \
		echo "Locales generated successfully"; \
	else \
		echo "locale-gen not found. Please install locales package and run:"; \
		echo "  sudo locale-gen en_US.UTF-8"; \
		echo "  sudo locale-gen ru_RU.UTF-8"; \
	fi

setup-monitoring:
	@echo "Setting up monitoring tools..."
	@if [ -f "./setup_monitoring.sh" ]; then \
		bash ./setup_monitoring.sh; \
	else \
		echo "ERROR: setup_monitoring.sh not found"; \
		exit 1; \
	fi

ci: shellcheck syntax

production-check:
	@echo "Running pre-production verification..."
	@if [ -f "./pre_production_check.sh" ]; then \
		./pre_production_check.sh; \
	else \
		echo "Error: pre_production_check.sh not found"; \
		exit 1; \
	fi

help:
	@echo "Bitrix24 Audit Scripts - Makefile"
	@echo "Version: $(VERSION)"
	@echo ""
	@echo "Available targets:"
	@echo "  shellcheck      - Run shellcheck on all shell scripts"
	@echo "  syntax         - Check syntax of all shell scripts"
	@echo "  check-locales   - Check locale availability and settings"
	@echo "  check-requirements - Check system requirements and dependencies"
	@echo "  test-all        - Run all tests (syntax, shellcheck, locales, requirements)"
	@echo "  clean           - Clean up temporary files"
	@echo "  install-deps    - Install required dependencies (shellcheck, sysstat, atop)"
	@echo "  install-tools   - Install additional audit tools (tuned, mysqltuner, percona-toolkit, etc.)"
	@echo "  install-optional - Install optional packages (wkhtmltopdf, testssl.sh)"
	@echo "  setup-locales   - Set up required locales"
	@echo "  setup-monitoring - Set up monitoring tools (sysstat, atop, sysbench, psacct)"
	@echo "  production-check - Run comprehensive pre-production verification"
	@echo "  ci              - Run CI checks (shellcheck + syntax)"
	@echo "  help            - Show this help message"
	@echo ""
	@echo "Examples:"
	@echo "  make test-all           # Run all tests"
	@echo "  make check-locales      # Check locale setup"
	@echo "  make install-deps       # Install dependencies"
	@echo "  make install-tools      # Install additional audit tools"
	@echo "  make install-optional    # Install optional packages"
	@echo "  make setup-locales      # Set up locales"
	@echo "  make setup-monitoring   # Set up monitoring tools"
