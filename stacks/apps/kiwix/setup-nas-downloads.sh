#!/bin/bash
# Kiwix NAS Setup Script
# Configures OpenMediaVault NAS for automated ZIM downloads

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"
ZIM_MANAGER_SCRIPT="$SCRIPT_DIR/zim-manager.sh"

# ==============================================================================
# Color Definitions
# ==============================================================================

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# ==============================================================================
# Logging Functions
# ==============================================================================

log_info() { echo -e "${GREEN}[INFO]${NC} $*"; }
log_warn() { echo -e "${YELLOW}[WARN]${NC} $*"; }
log_error() { echo -e "${RED}[ERROR]${NC} $*"; }

# ==============================================================================
# Helper Functions
# ==============================================================================

prompt() {
    local var_name="$1"
    local prompt_text="$2"
    local default="${3:-}"

    if [ -n "$default" ]; then
        read -p "$prompt_text [$default]: " value
        eval "$var_name=\"${value:-$default}\""
    else
        read -p "$prompt_text: " value
        eval "$var_name=\"$value\""
    fi
}

# ==============================================================================
# Core Setup Functions
# ==============================================================================

load_environment() {
    # Load environment variables and dependencies
    # Sources .env for NAS_SERVER, SSH_KEY_FILE configuration
    # Sources ssh.sh for SSH helper functions
    if [ -f "$PROJECT_ROOT/.env" ]; then
        set -a  # Export all variables
        source "$PROJECT_ROOT/.env"
        set +a
        log_info "Loaded environment from .env"
    fi

    # Source common SSH library
    if [ -f "$PROJECT_ROOT/scripts/common/ssh.sh" ]; then
        source "$PROJECT_ROOT/scripts/common/ssh.sh"
        log_info "Loaded SSH library"
    else
        log_error "Could not find scripts/common/ssh.sh"
        log_error "Please ensure you're running this from the project directory"
        exit 1
    fi
}

get_nas_connection_info() {
    # Gather NAS connection credentials
    # Uses NAS_SERVER and SSH_KEY_FILE from .env if available
    # Otherwise prompts user with sensible defaults
    # Exports NAS_USER_HOST for use by SSH functions
    log_info "Gathering NAS connection information..."

    # Use NAS_SERVER from .env if available, otherwise prompt
    if [ -z "${NAS_SERVER:-}" ]; then
        prompt NAS_SERVER "NAS hostname or IP" "nas.local"
        log_warn "Consider adding NAS_SERVER=$NAS_SERVER to .env file"
    else
        log_info "Using NAS_SERVER from .env: $NAS_SERVER"
    fi

    # Use SSH_KEY_FILE from .env if available, otherwise prompt
    if [ -z "${SSH_KEY_FILE:-}" ]; then
        prompt SSH_KEY_FILE "SSH key path" "$HOME/.ssh/selfhosted_rsa"
        log_warn "Consider adding SSH_KEY_FILE=$SSH_KEY_FILE to .env file"
    else
        log_info "Using SSH_KEY_FILE from .env: $SSH_KEY_FILE"
    fi

    # Prompt for SSH user (typically root for NAS)
    prompt NAS_USER "SSH username for NAS" "root"

    # Build user@host string for SSH commands
    NAS_USER_HOST="$NAS_USER@$NAS_SERVER"
    export NAS_USER_HOST
}

ensure_ssh_connectivity() {
    log_info "Testing SSH connection to $NAS_USER_HOST..."

    if ssh_test_connection "$NAS_USER_HOST"; then
        log_info "SSH connection successful"
        return 0
    fi

    log_warn "Cannot connect with SSH key. Attempting to copy SSH key..."
    log_info "You will be prompted for the NAS password"

    if ssh_copy_key "$NAS_USER_HOST"; then
        log_info "SSH key copied successfully"

        # Test again after copying key
        if ssh_test_connection "$NAS_USER_HOST"; then
            log_info "SSH connection successful"
            return 0
        else
            log_error "SSH connection still failing after copying key"
            log_error "Please check:"
            log_error "  1. NAS is powered on and accessible"
            log_error "  2. SSH is enabled on OpenMediaVault"
            log_error "  3. Firewall allows SSH connections"
            exit 1
        fi
    else
        log_error "Failed to copy SSH key"
        log_error "Please ensure:"
        log_error "  1. Password authentication is enabled on NAS"
        log_error "  2. You have the correct password"
        exit 1
    fi
}

get_storage_configuration() {
    log_info "Configuring storage paths..."

    # Prompt for storage paths
    prompt ZIM_DATA_DIR "ZIM data directory on NAS" "/srv/kiwix_data"
    prompt ZIM_LOG_DIR "Log directory on NAS" "/var/log/kiwix"

    # Prompt for email notifications
    prompt EMAIL_TO "Email address for notifications" "admin@example.com"

    export ZIM_DATA_DIR ZIM_LOG_DIR EMAIL_TO
}

setup_nas_directories() {
    log_info "Creating directories on NAS..."

    # Create ZIM data directory
    if ssh_create_directory "$NAS_USER_HOST" "$ZIM_DATA_DIR" "755"; then
        log_info "Created $ZIM_DATA_DIR"
    else
        log_error "Failed to create $ZIM_DATA_DIR"
        exit 1
    fi

    # Create log directory
    if ssh_create_directory "$NAS_USER_HOST" "$ZIM_LOG_DIR" "755"; then
        log_info "Created $ZIM_LOG_DIR"
    else
        log_error "Failed to create $ZIM_LOG_DIR"
        exit 1
    fi
}

install_zim_manager() {
    log_info "Installing zim-manager.sh on NAS..."

    # Copy script to NAS
    if ! scp -i "$SSH_KEY_FILE" "$ZIM_MANAGER_SCRIPT" "$NAS_USER_HOST:/usr/local/bin/zim-manager.sh" >/dev/null 2>&1; then
        log_error "Failed to copy zim-manager.sh"
        exit 1
    fi

    # Make executable
    if ! ssh_execute "$NAS_USER_HOST" "chmod +x /usr/local/bin/zim-manager.sh"; then
        log_error "Failed to make zim-manager.sh executable"
        exit 1
    fi

    log_info "zim-manager.sh installed successfully"

    # Create configuration file
    log_info "Creating configuration file on NAS..."
    ssh_execute "$NAS_USER_HOST" "cat > /etc/kiwix-config.sh <<EOF
export ZIM_DATA_DIR='$ZIM_DATA_DIR'
export ZIM_LOG_DIR='$ZIM_LOG_DIR'
export EMAIL_TO='$EMAIL_TO'
EOF"

    log_info "Configuration file created at /etc/kiwix-config.sh"
}

setup_update_schedule() {
    log_info "Setting up monthly scheduled task in OpenMediaVault..."

    # Generate UUID for the cron job (using kernel's random UUID generator)
    local cron_uuid=$(ssh_execute "$NAS_USER_HOST" "cat /proc/sys/kernel/random/uuid")

    # Create scheduled task using omv-rpc
    # FINAL FIX: Using the structure captured from the network payload.
    ssh_execute "$NAS_USER_HOST" "omv-rpc -u admin Cron set '{
      \"uuid\": \"fa4b1c66-ef79-11e5-87a0-0002b3a176b4\",
      \"enable\": true,
      \"type\": \"userdefined\",
      \"execution\": \"monthly\",
      \"minute\": [\"0\"],
      \"everynminute\": false,
      \"hour\": [\"2\"],
      \"everynhour\": false,
      \"dayofmonth\": [\"1\"],
      \"everyndayofmonth\": false,
      \"month\": [\"*\"],
      \"dayofweek\": [\"*\"],
      \"username\": \"root\",
      \"command\": \". /etc/kiwix-config.sh && /usr/local/bin/zim-manager.sh check\",
      \"comment\": \"Kiwix ZIM update check - runs monthly\",
      \"sendemail\": false
    }'"

    # Apply the configuration
    ssh_execute "$NAS_USER_HOST" "omv-salt deploy run cron"

    log_info "Scheduled task configured in OMV (1st of month at 2 AM)"
    log_info "View in OMV: System → Scheduled Jobs"
}

verify_email_system() {
    log_info "Testing email notifications..."

    if ssh_command_exists "$NAS_USER_HOST" "mail"; then
        ssh_execute "$NAS_USER_HOST" "echo 'Test email from Kiwix setup' | mail -s 'Kiwix Setup Test' '$EMAIL_TO' 2>&1" || \
            log_warn "Email test failed - check mail configuration on NAS"
    else
        log_warn "Mail command not found on NAS - email notifications will not work"
        log_warn "Install mailutils on NAS: apt-get install mailutils"
    fi
}

offer_initial_download() {
    echo
    read -p "Run initial download of starter pack now? (y/N): " run_init

    if [[ "$run_init" =~ ^[Yy]$ ]]; then
        log_info "Starting initial download (this will take a while for 100GB+ of data)..."
        log_warn "Downloads will run in background on NAS. Check logs at: $ZIM_LOG_DIR"

        # Use nohup to run in background, redirect output to log file
        ssh_execute "$NAS_USER_HOST" ". /etc/kiwix-config.sh && nohup /usr/local/bin/zim-manager.sh init > $ZIM_LOG_DIR/init.log 2>&1 &"

        log_info "Initial download started in background"
        log_info "Monitor progress: ssh $NAS_USER@$NAS_SERVER 'tail -f $ZIM_LOG_DIR/init.log'"
    else
        log_info "Skipping initial download"
        log_info "To download manually later, run on NAS:"
        log_info "  ssh $NAS_USER@$NAS_SERVER"
        log_info "  . /etc/kiwix-config.sh && /usr/local/bin/zim-manager.sh init"
    fi
}

# ==============================================================================
# Main Function
# ==============================================================================

main() {
    echo "========================================="
    echo "  Kiwix NAS Setup"
    echo "========================================="
    echo

    load_environment
    get_nas_connection_info
    ensure_ssh_connectivity
    get_storage_configuration
    setup_nas_directories
    install_zim_manager
    setup_update_schedule
    verify_email_system
    offer_initial_download

    # Setup complete
    echo
    echo "========================================="
    echo "  Setup Complete!"
    echo "========================================="
    echo
    echo "Next steps:"
    echo "  1. Wait for initial downloads to complete (if started)"
    echo "  2. Create SMB share in OpenMediaVault:"
    echo "     - Storage → Shared Folders → Add shared folder for: $ZIM_DATA_DIR"
    echo "     - Services → SMB/CIFS → Shares → Add share named: kiwix_data"
    echo "  3. Deploy Kiwix service: ./selfhosted.sh deploy --skip-infra --only-apps kiwix"
    echo "  4. Access at: https://kiwix.\${BASE_DOMAIN}/"
    echo
    echo "Manual operations:"
    echo "  - Check logs: ssh $NAS_USER@$NAS_SERVER 'ls -l $ZIM_LOG_DIR'"
    echo "  - Run update check: ssh $NAS_USER@$NAS_SERVER 'zim-manager.sh check'"
    echo "  - Download specific ZIM: ssh $NAS_USER@$NAS_SERVER 'zim-manager.sh download <url>'"
    echo
    echo "Configuration stored in .env:"
    echo "  NAS_SERVER=$NAS_SERVER"
    echo "  SSH_KEY_FILE=$SSH_KEY_FILE"
    echo

    exit 0
}

# ==============================================================================
# Script Execution
# ==============================================================================

# Only run main if not being sourced
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi
