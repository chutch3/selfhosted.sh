
SSH_KEY_FILE="${SSH_KEY_FILE:-$HOME/.ssh/selfhosted_rsa}"
SSH_TIMEOUT="${SSH_TIMEOUT:-5}"

export SSH_KEY_FILE
export SSH_TIMEOUT

# SSH wrapper that uses the SSH key file. It's
# a bit more opinionated than the default ssh command.
# Args:
#   $1: SSH user@hostname
#   $2: Command to run
# Returns:
#   None
ssh_key_auth() {
    local key_file="$SSH_KEY_FILE"
    ssh -i "$key_file" \
        -o PasswordAuthentication=no \
        -o PubkeyAuthentication=yes \
        -o IdentitiesOnly=yes \
        "$1" "$2"
}

# SSH wrapper that uses password authentication
# Args:
#   $1: SSH user@hostname
#   $2: Command to run
# Returns:
#   None
ssh_password_auth() {
    ssh -o PasswordAuthentication=yes "$1" "$2"
}

# SSH wrapper that uses ssh-copy-id to copy the SSH key to the remote machine
# Args:
#   $1: SSH user@hostname
#   $2: Command to run
# Returns:
#   None
ssh_copy_id() {
    ssh-copy-id -o PasswordAuthentication=yes "$1"
}

# Export the ssh_wrapper function so it's available to subshells
export -f ssh_key_auth
export -f ssh_password_auth
export -f ssh_copy_id
