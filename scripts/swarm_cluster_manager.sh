#!/bin/bash

# Docker Swarm Cluster Management - Minimal Implementation
# Part of Issue #39 - Docker Swarm Cluster Management
# TDD GREEN phase - minimal code to make tests pass

# Function: validate_homelab_config
# Description: Validates homelab.yaml configuration for Swarm deployment
# Arguments: $1 - config file path
# Returns: 0 on success, 1 on failure
validate_homelab_config() {
    local config_file="${1:-homelab.yaml}"

    if [[ ! -f "$config_file" ]]; then
        echo "Configuration file not found: $config_file" >&2
        return 1
    fi

    # Check deployment type
    if grep -q "deployment: docker_swarm" "$config_file"; then
        # Check machines section exists
        if grep -q "^machines:" "$config_file"; then
            return 0
        else
            echo "Configuration must have machines section for Swarm deployment" >&2
            return 1
        fi
    else
        echo "Configuration must have deployment: docker_swarm" >&2
        return 1
    fi
}

# Function: get_manager_machine
# Description: Get the manager machine from configuration
# Arguments: $1 - config file path
# Returns: manager machine name
get_manager_machine() {
    local config_file="${1:-homelab.yaml}"

    # Look for explicitly defined manager role
    local manager
    # Find machine that has "role: manager" by looking at the context around it
    manager=$(awk '
        /^  [a-zA-Z]/ { current_machine = $1; gsub(/:/, "", current_machine) }
        /role: manager/ { print current_machine; exit }
    ' "$config_file")

    # If no explicit manager, use 'driver' as default
    if [[ -z "$manager" ]]; then
        if grep -A 5 "^machines:" "$config_file" | grep -q "^  driver:"; then
            manager="driver"
        else
            # Use first machine as manager
            manager=$(grep -A 20 "^machines:" "$config_file" | grep "^  [a-zA-Z]" | head -1 | cut -d: -f1 | tr -d ' ')
        fi
    fi

    echo "$manager"
}

# Function: get_worker_machines
# Description: Get list of worker machines from configuration
# Arguments: $1 - config file path
# Returns: space-separated list of worker machine names
get_worker_machines() {
    local config_file="${1:-homelab.yaml}"
    local manager
    manager=$(get_manager_machine "$config_file")

    # Get all machines except manager
    local workers
    workers=$(grep -A 20 "^machines:" "$config_file" | grep "^  [a-zA-Z]" | cut -d: -f1 | tr -d ' ' | grep -v "^$manager$" | tr '\n' ' ')

    echo "$workers"
}

# Function: get_machine_host
# Description: Get host IP/hostname for a machine
# Arguments: $1 - machine name, $2 - config file path
# Returns: host address
get_machine_host() {
    local machine="$1"
    local config_file="${2:-homelab.yaml}"

    local host
    host=$(grep -A 5 "^  $machine:" "$config_file" | grep "host:" | head -1 | cut -d: -f2- | tr -d ' "')

    echo "$host"
}

# Function: get_machine_user
# Description: Get SSH user for a machine
# Arguments: $1 - machine name, $2 - config file path
# Returns: SSH username
get_machine_user() {
    local machine="$1"
    local config_file="${2:-homelab.yaml}"

    local user
    user=$(grep -A 5 "^  $machine:" "$config_file" | grep "user:" | head -1 | cut -d: -f2- | tr -d ' "')

    echo "$user"
}

# Function: get_machine_labels
# Description: Get labels for a machine
# Arguments: $1 - machine name, $2 - config file path
# Returns: space-separated list of labels
get_machine_labels() {
    local machine="$1"
    local config_file="${2:-homelab.yaml}"

    # Extract labels from YAML (simplified parsing)
    local labels
    labels=$(awk "
        /^  $machine:/ { in_machine=1; next }
        in_machine && /^  [a-zA-Z]/ { in_machine=0; in_labels=0 }
        in_machine && /^    labels:/ { in_labels=1; next }
        in_machine && in_labels && /^      - / { gsub(/^      - /, \"\"); print }
        in_machine && in_labels && /^    [a-zA-Z]/ && !/^    labels:/ { in_labels=0 }
    " "$config_file" | tr '\n' ' ')

    echo "$labels"
}
