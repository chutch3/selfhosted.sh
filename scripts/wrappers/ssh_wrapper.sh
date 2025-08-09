#!/bin/bash

# SSH wrapper interface to enable testing by abstracting SSH operations
# This extends the existing ssh.sh functionality with additional operations needed for swarm

# Source the base SSH functionality
source scripts/ssh.sh

# Execute command on remote host using SSH key authentication
# Args:
#   $1: user@hostname
#   $2: command to execute
# Returns:
#   SSH command exit code
ssh_execute() {
    local user_host="$1"
    local command="$2"
    ssh_key_auth "$user_host" "$command"
}

# Execute command on remote host with password authentication
# Args:
#   $1: user@hostname
#   $2: command to execute
# Returns:
#   SSH command exit code
ssh_execute_password() {
    local user_host="$1"
    local command="$2"
    ssh_password_auth "$user_host" "$command"
}

# Test SSH connectivity to a host
# Args:
#   $1: user@hostname
# Returns:
#   0 if connection successful, 1 otherwise
ssh_test_connection() {
    local user_host="$1"
    ssh_key_auth "$user_host" "exit" 2>/dev/null
}

# Copy SSH key to remote host
# Args:
#   $1: user@hostname
# Returns:
#   ssh-copy-id exit code
ssh_copy_key() {
    local user_host="$1"
    ssh_copy_id "$user_host"
}

# Execute docker command on remote host
# Args:
#   $1: user@hostname
#   $2: docker command (e.g., "docker swarm join --token TOKEN ADDR")
# Returns:
#   SSH command exit code
ssh_docker_command() {
    local user_host="$1"
    local docker_cmd="$2"
    ssh_execute "$user_host" "$docker_cmd"
}

# Get hostname from remote host
# Args:
#   $1: user@hostname
# Returns:
#   remote hostname to stdout
ssh_get_hostname() {
    local user_host="$1"
    ssh_execute "$user_host" "hostname"
}

# Check if docker is running on remote host
# Args:
#   $1: user@hostname
# Returns:
#   0 if docker is running, 1 otherwise
ssh_check_docker() {
    local user_host="$1"
    ssh_execute "$user_host" "docker info" >/dev/null 2>&1
}

# Create directory on remote host
# Args:
#   $1: user@hostname
#   $2: directory path
#   $3: permissions (optional, e.g., 700)
# Returns:
#   SSH command exit code
ssh_create_directory() {
    local user_host="$1"
    local dir_path="$2"
    local permissions="${3:-755}"
    ssh_execute "$user_host" "mkdir -p '$dir_path' && chmod '$permissions' '$dir_path'"
}

# Check if command exists on remote host
# Args:
#   $1: user@hostname
#   $2: command name
# Returns:
#   0 if command exists, 1 otherwise
ssh_command_exists() {
    local user_host="$1"
    local command="$2"
    ssh_execute "$user_host" "command -v '$command'" >/dev/null 2>&1
}

# Export all functions for use in other scripts
export -f ssh_execute
export -f ssh_execute_password
export -f ssh_test_connection
export -f ssh_copy_key
export -f ssh_docker_command
export -f ssh_get_hostname
export -f ssh_check_docker
export -f ssh_create_directory
export -f ssh_command_exists
