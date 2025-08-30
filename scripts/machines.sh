#!/bin/bash

# Get the actual script directory, handling both direct execution and sourcing
MACHINES_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$MACHINES_SCRIPT_DIR/ssh.sh"


# Parse machine configuration from YAML file
# Args:
#   $1: Key to parse ('manager' or 'workers')
# Returns:
#   Space-separated list of machine keys for the given key
machines_parse() {
    local machines_file="${MACHINES_FILE:-$PROJECT_ROOT/machines.yaml}"
    if [ ! -f "$machines_file" ]; then
        echo "Error: Machines file not found at $machines_file" >&2
        return 1
    fi

    local key=$1
    local yq_query=""

    if [ "$key" = "manager" ]; then
        yq_query='.machines | to_entries[] | select(.value.role == "manager") | .key'
    elif [ "$key" = "workers" ]; then
        yq_query='.machines | to_entries[] | select(.value.role == "worker") | .key'
    elif [ "$key" = "all" ]; then
        yq_query='.machines | keys | .[]'
    else
        echo "Error: Invalid key '$key'. Use 'manager', 'workers', or 'all'" >&2
        return 1
    fi

    # Run yq and capture both stdout and stderr
    local output
    # Check yq exit status
    if ! output=$(yq "$yq_query" "$machines_file" 2>&1); then
        echo "Error: Invalid YAML in $machines_file" >&2
        echo "$output" >&2
        return 1
    fi

    echo "$output" | tr '\n' ' ' | tr -d '"' | sed 's/ $//'
}


# Get SSH user for a given machine key
# Args:
#   $1: Machine key to get SSH user for (e.g., "driver", "node-01")
# Returns:
#   SSH user for the given machine key
machines_get_ssh_user() {
    local machine_key=$1
    local machines_file="${MACHINES_FILE:-$PROJECT_ROOT/machines.yaml}"

    if [ ! -f "$machines_file" ]; then
        echo "Error: Machines file not found at $machines_file" >&2
        return 1
    fi

    local user
    # Use machine key to get ssh_user directly from the new structure
    user=$(yq ".machines[\"$machine_key\"].ssh_user" "$machines_file" 2>/dev/null | tr -d '"')

    # Fallback to .user for backward compatibility
    if [ -z "$user" ] || [ "$user" = "null" ]; then
        user=$(yq ".machines[\"$machine_key\"].user" "$machines_file" 2>/dev/null | tr -d '"')
    fi

    # Handle case where machine key isn't found or user is not set
    if [ -z "$user" ] || [ "$user" = "null" ]; then
        echo "null"
        return 0
    fi

    echo "$user"
}

# Build hostname from machine key and BASE_DOMAIN
# Args:
#   $1: Machine key (e.g., "manager", "node-01")
# Returns:
#   Full hostname (e.g., "manager.diyhub.dev")
machines_build_hostname() {
    local machine_key="$1"

    if [ -z "$machine_key" ]; then
        echo "Error: Machine key parameter is required" >&2
        return 1
    fi

    echo "${machine_key}.${BASE_DOMAIN:-}"
}

# Format machine display string for consistent logging
# Args:
#   $1: Machine key (e.g., "manager", "node-01")
#   $2: Machine IP (e.g., "192.168.1.100")
# Returns:
#   Formatted string: "machine_key (ip_address)"
machines_format_display() {
    local machine_key="$1"
    local machine_ip="$2"
    echo "$machine_key ($machine_ip)"
}

# The current machine's IP address
machines_my_ip() {
    local ip
    ip=$(ip route get 1 | awk '{print $(NF-2);exit}')
    echo "$ip"
}

# Check if SSH is already configured for a host (without timeout)
# Args:
#   $1: Hostname to check
#   $2: SSH user for the host
# Returns:
#   0 if SSH key authentication works, 1 otherwise
machines_is_ssh_configured_no_timeout() {
    local host=$1
    local ssh_user=$2

    # Try to connect with key auth - if it works, SSH is already configured
    if ssh_key_auth "$ssh_user@$host" exit 2>/dev/null; then
        return 0  # SSH is configured
    else
        return 1  # SSH needs setup
    fi
}

# Check if SSH is already configured for a host
# Args:
#   $1: Hostname to check
#   $2: SSH user for the host
#   $3: Optional "debug" to show SSH command output
# Returns:
#   0 if SSH key authentication works, 1 otherwise
machines_is_ssh_configured() {
    local host=$1
    local ssh_user=$2
    local debug_mode=$3

    # Use the SSH command directly with timeout built into ssh_key_auth function
    # ssh_key_auth already has its own timeout, so we don't need external timeout
    if [ "$debug_mode" = "debug" ]; then
        # Show SSH output for debugging - don't suppress stderr
        if ssh_key_auth "$ssh_user@$host" exit; then
            return 0  # SSH is configured
        else
            return 1  # SSH needs setup
        fi
    else
        # Normal operation - suppress output
        if machines_is_ssh_configured_no_timeout "$host" "$ssh_user"; then
            return 0  # SSH is configured
        else
            return 1  # SSH needs setup
        fi
    fi
}

# Get IP address for a given machine key or hostname, preferring IP field from machines.yaml
# Args:
#   $1: Machine key (e.g. "manager") or hostname (e.g. "manager.diyhub.dev") to resolve
# Returns:
#   IP address of the machine from machines.yaml IP field, or hostname resolution
#   Exits with error if machine cannot be resolved
machines_get_ip() {
    local input="$1"
    local machines_file="${MACHINES_FILE:-$PROJECT_ROOT/machines.yaml}"

    # Validate input
    if [ -z "$input" ]; then
        echo "Error: Machine key or hostname parameter is required" >&2
        return 1
    fi

    if [ ! -f "$machines_file" ]; then
        echo "Error: Machines file not found at $machines_file" >&2
        return 1
    fi

    # Check if input looks like a machine key (no dots) vs hostname (has dots)
    local machine_key
    if [[ "$input" =~ \. ]]; then
        # Input is a hostname, extract machine key from it
                machine_key="${input%%\."${BASE_DOMAIN:-}"*}"
    else
        # Input is already a machine key
        machine_key="$input"
    fi

    # Try to get IP from machines.yaml IP field using machine key
    local ip_field
    if ! ip_field=$(yq ".machines[\"${machine_key}\"].ip" "$machines_file" 2>/dev/null | tr -d '"'); then
        echo "Error: Failed to parse machines.yaml" >&2
        return 1
    fi

    # Use IP field if present and valid
    if [ -n "$ip_field" ] && [ "$ip_field" != "null" ] && [ "$ip_field" != "" ]; then
        echo "$ip_field"
        return 0
    fi

    # Fallback to hostname resolution
    # If input was a machine key, construct the hostname
    local hostname
    if [[ "$input" =~ \. ]]; then
        hostname="$input"
    else
        hostname=$(machines_build_hostname "$machine_key")
    fi

    machines_get_host_ip "$hostname"
}

# Get IP address for a given hostname
# Args:
#   $1: Hostname or IP address to resolve
# Returns:
#   IP address of the host
# Exits with error if hostname cannot be resolved
machines_get_host_ip() {
    local host=$1

    # Check if host is already an IP address
    if [[ $host =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
        # Validate IP address format
        local IFS='.'
        read -ra octets <<< "$host"
        for octet in "${octets[@]}"; do
            if [ "$octet" -gt 255 ] || [ "$octet" -lt 0 ]; then
                echo "Error: Invalid IP address format: $host" >&2
                return 1
            fi
        done
        echo "$host"
        return
    fi

    # Otherwise resolve hostname to IP
    local ip
    ip=$(getent hosts "$host" | awk '{ print $1 }')

    if [ -z "$ip" ]; then
        echo "Error: Could not resolve IP for host: $host" >&2
        return 1
    fi

    echo "$ip"
}

# Set up SSH access to all machines
# Generates SSH key if needed and copies to all hosts
# No args
# Returns:
#   None
machines_setup_ssh() {
    local key_file="$SSH_KEY_FILE"
    local current_machine_ip
    current_machine_ip=$(machines_my_ip)

    # Generate SSH key if it doesn't exist
    if [ ! -f "$key_file" ]; then
        echo "Generating new SSH key at $key_file..."
        if ! ssh-keygen -t rsa -b 4096 -f "$key_file" -N ""; then
            echo "Failed to generate SSH key" >&2
            return 1
        fi
    fi

    # Fix local key file permissions
    chmod 600 "$key_file"
    chmod 644 "${key_file}.pub"

    # Get all machine keys
    local machine_keys
    machine_keys="$(machines_parse all)"

    for machine_key in $machine_keys; do
        # IP-first approach: Use direct IP connections to avoid DNS dependency
        local machine_ip
        machine_ip=$(machines_get_ip "$machine_key")
        local display_name
        display_name=$(machines_format_display "$machine_key" "$machine_ip")

        # Skip if this is the local machine
        if [[ "$machine_ip" == "$current_machine_ip" || "$machine_ip" == "localhost" || "$machine_ip" == "127.0.0.1" ]]; then
            echo "Skipping SSH setup for local machine: $display_name"
            continue
        fi

        local ssh_user
        ssh_user=$(machines_get_ssh_user "$machine_key")
        if [ "$ssh_user" = "null" ]; then
            ssh_user=${USER}
            echo "No SSH user specified for $machine_key, using current user: $ssh_user"
        fi

        # Check if SSH key authentication is already working for this IP
        if machines_is_ssh_configured "$machine_ip" "$ssh_user" "debug"; then
            echo "Skipping SSH setup for already configured machine: $display_name"
            continue
        fi

        echo "Setting up SSH access for $display_name (user: $ssh_user)..."

        # Create .ssh directory with correct permissions on remote host
        if ! ssh_password_auth "$ssh_user@$machine_ip" \
            "mkdir -p ~/.ssh && chmod 700 ~/.ssh"; then
            echo "Failed to create/fix permissions on .ssh directory for $display_name" >&2
            return 1
        fi

        # Copy SSH key and set permissions
        if ! ssh_copy_id "$ssh_user@$machine_ip"; then
            echo "Failed to copy SSH key to $display_name" >&2
            return 1
        fi

        # Verify and fix permissions on authorized_keys
        if ! ssh_key_auth "$ssh_user@$machine_ip" \
            "chmod 600 ~/.ssh/authorized_keys"; then
            echo "Failed to fix permissions on authorized_keys for $display_name" >&2
            return 1
        fi

        # Test the connection
        if ! ssh_key_auth "$ssh_user@$machine_ip" exit; then
            echo "Failed to verify SSH key access to $display_name" >&2
            return 1
        fi

        echo "✓ Successfully set up SSH access for $display_name"
    done

    echo "SSH setup completed successfully for all hosts"
}


# TODO: This does not work when trying to connect to another machine
# Test SSH connectivity to all machines
# No args
# Returns:
#   None, but prints connection status for each machine
machines_test_connection() {
    local machine_keys
    machine_keys="$(machines_parse workers)"
    local timeout=$SSH_TIMEOUT
    for machine_key in $machine_keys; do
        local machine_ip
        machine_ip=$(machines_get_ip "$machine_key")
        local display_name
        display_name=$(machines_format_display "$machine_key" "$machine_ip")
        local ssh_user
        ssh_user="$(machines_get_ssh_user "$machine_key")"

        echo "Testing connection to $display_name..."
        if timeout "$timeout" bash -c "ssh_key_auth \"$ssh_user@$machine_ip\" exit"; then
            echo "✓ Successfully connected to $display_name"
        else
            local status=$?
            if [ $status -eq 124 ]; then
                echo "Connection timed out for $display_name" >&2
                return 1
            fi
            echo "✗ Failed to connect to $display_name"
            return 1
        fi
    done
}


machines_check_cifs_utils() {
    local current_machine_ip
    current_machine_ip=$(machines_my_ip)
    local machine_keys

    machine_keys="$(machines_parse all)"
    echo "Checking cifs-utils on all machines..."
    for machine_key in $machine_keys; do
        local machine_ip
        machine_ip=$(machines_get_ip "$machine_key")
        local display_name
        display_name=$(machines_format_display "$machine_key" "$machine_ip")

        echo "Checking cifs-utils on $display_name..."

        # Skip if this is the local machine
        if [ "$machine_ip" == "$current_machine_ip" ]; then
            echo "Running command locally on $machine_key..."
            if ! which mount.cifs >/dev/null 2>&1; then
                echo "cifs-utils not installed on $machine_key"
                echo "Installing cifs-utils on $machine_key..."
                sudo apt-get update && sudo apt-get install -y cifs-utils
                echo "cifs-utils is installed on $machine_key"
            fi
            continue
        fi

        echo "Running command on remote machine: $display_name..."
        local ssh_user
        ssh_user="$(machines_get_ssh_user "$machine_key")"
        if ! ssh_key_auth "$ssh_user@$machine_ip" "which mount.cifs >/dev/null 2>&1"; then
            echo "Installing cifs-utils on $display_name..."
            ssh_key_auth "$ssh_user@$machine_ip" "sudo apt-get update && sudo apt-get install -y cifs-utils"
        fi
        echo "cifs-utils is installed on $display_name"
    done
    echo "cifs-utils is installed on all machines"
    return 0
}
