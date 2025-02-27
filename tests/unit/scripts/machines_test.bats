#!/usr/bin/env bats

setup() {
    # Load test helper functions
    load test_helper

    # Create temporary test directory
    TEST_TEMP_DIR="$(temp_make)"
    
    # Set up test environment variables
    export TEST=true
    export PROJECT_ROOT="${TEST_TEMP_DIR}"
    
    # Create test machines.yml file with new format
    cat > "${TEST_TEMP_DIR}/machines.yml" <<EOF
machines:
  - host: manager.example.com
    role: manager
    ssh_user: admin1
  
  - host: worker1.example.com
    role: worker
    ssh_user: admin2
    labels:
      storage: ssd
  
  - host: worker2.example.com
    role: worker
    ssh_user: admin3
    labels:
      storage: hdd
EOF

    # Source the machines script with mocked functions
    source "${BATS_TEST_DIRNAME}/../../../scripts/machines.sh"
    
    # Mock getent to return test IPs
    getent() {
        case "$2" in
            "manager.example.com") echo "10.0.0.1 manager.example.com" ;;
            "worker2.example.com") echo "10.0.0.3 worker2.example.com" ;;
            *) return 1 ;;
        esac
    }

    # Mock ssh-copy-id to always succeed
    ssh-copy-id() {
        return 0
    }
}

teardown() {
    # Clean up test directory
    temp_del "$TEST_TEMP_DIR"
}

@test "machines_parse reads yaml correctly" {
    MACHINES_FILE="${TEST_TEMP_DIR}/machines.yml"

    run machines_parse 'manager'
    echo "output: $output"
    [ "$status" -eq 0 ]
    [ "$output" = "manager.example.com" ]
    
    run machines_parse 'workers'
    echo "output: $output"
    [ "$status" -eq 0 ]
    [[ "$output" =~ "worker1.example.com worker2.example.com" ]]
}

@test "machines_parse handles missing file" {
    MACHINES_FILE="/nonexistent/path/machines.yml"
    run machines_parse 'manager'
    [ "$status" -eq 1 ]
    [[ "$output" =~ "Error" ]]  # Should have error message
}

@test "machines_parse handles invalid yaml" {
    # create invalid yaml file
    cat > "${TEST_TEMP_DIR}/machines.yml" <<EOF
machines:
  - host: manager.example.com
    role: manager
    invalid_yaml: [
EOF
    MACHINES_FILE="${TEST_TEMP_DIR}/machines.yml"
    run machines_parse 'manager'
    echo "output: $output"
    echo "status: $status"
    [ "$status" -eq 1 ]
    [[ "$output" =~ "Error" ]]
}

@test "machines_get_host_ip resolves hostname to IP" {
    run machines_get_host_ip "manager.example.com"
    [ "$status" -eq 0 ]
    [ "$output" = "10.0.0.1" ]
}

@test "machines_get_host_ip returns IP if given IP" {
    run machines_get_host_ip "192.168.1.101"
    [ "$status" -eq 0 ]
    [ "$output" = "192.168.1.101" ]
}

@test "machines_get_host_ip handles invalid IP format" {
    run machines_get_host_ip "256.256.256.256"
    [ "$status" -eq 1 ]
    [[ "$output" =~ "Error: Invalid IP address" ]]
}

@test "machines_get_host_ip fails on unresolvable host" {
    run machines_get_host_ip "nonexistent.example.com"
    [ "$status" -eq 1 ]
    [[ "$output" =~ "Error: Could not resolve IP for host" ]]
}

@test "machines_setup_ssh attempts to setup all hosts" {
    # Mock commands
    ssh() {
        echo "SSH: $*" >&2
        return 0
    }
    
    ssh-copy-id() {
        echo "Copying key: $*" >&2
        return 0
    }
    
    timeout() {
        "${@:2}"
    }
    
    export -f ssh ssh-copy-id timeout
    
    run machines_setup_ssh
    echo "output: $output" >&2
    [ "$status" -eq 0 ]
    [[ "$output" =~ "Setting up SSH access for manager.example.com" ]]
}

@test "machines_setup_ssh handles ssh-copy-id failure" {
    ssh() {
        return 0
    }
    
    ssh-copy-id() {
        echo "Failed to copy key" >&2
        return 1
    }
    
    export -f ssh ssh-copy-id
    
    run machines_setup_ssh
    [ "$status" -eq 1 ]
    [[ "$output" =~ "Failed to copy SSH key" ]]
}

@test "machines_test_connection checks all hosts" {
    timeout() {
        "${@:2}"
    }
    
    ssh() {
        echo "Mock SSH called with args: $*" >&2
        return 0
    }
    
    export -f timeout ssh
    
    run machines_test_connection
    echo "output: $output" >&2
    [ "$status" -eq 0 ]
    [[ "$output" =~ "Testing connection to worker1.example.com" ]]
    [[ "$output" =~ "✓ Successfully connected to worker1.example.com" ]]
}

@test "machines_test_connection shows failure for failed connections" {
    timeout() {
        "${@:2}"
    }
    
    ssh() {
        echo "Mock SSH called with args: $*" >&2
        return 1
    }
    
    export -f timeout ssh
    
    run machines_test_connection
    echo "output: $output" >&2
    [ "$status" -eq 1 ]
    [[ "$output" =~ "Testing connection to worker1.example.com" ]]
    [[ "$output" =~ "✗ Failed to connect to worker1.example.com" ]]
}

@test "machines_get_ssh_user gets user for host" {
    MACHINES_FILE="${TEST_TEMP_DIR}/machines.yml"
    
    run machines_get_ssh_user "manager.example.com"
    [ "$status" -eq 0 ]
    [ "$output" = "admin1" ]
    
    run machines_get_ssh_user "worker1.example.com"
    [ "$status" -eq 0 ]
    [ "$output" = "admin2" ]
    
    run machines_get_ssh_user "worker2.example.com"
    [ "$status" -eq 0 ]
    [ "$output" = "admin3" ]
}

@test "machines_get_ssh_user handles missing user" {
    # Create test machines.yml without SSH users
    cat > "${TEST_TEMP_DIR}/machines.yml" <<EOF
machines:
  - host: manager.example.com
    role: manager
  - host: worker1.example.com
    role: worker
EOF

    MACHINES_FILE="${TEST_TEMP_DIR}/machines.yml"
    
    run machines_get_ssh_user "manager.example.com"
    [ "$status" -eq 0 ]
    [ "$output" = "null" ]  # yq returns "null" for missing fields
}

@test "machines_get_ssh_user handles invalid host" {
    MACHINES_FILE="${TEST_TEMP_DIR}/machines.yml"
    
    run machines_get_ssh_user "nonexistent"
    [ "$status" -eq 0 ]
    [ "$output" = "null" ]
}

@test "machines_get_ssh_user handles missing file" {
    MACHINES_FILE="/nonexistent/path/machines.yml"
    
    run machines_get_ssh_user "manager"
    [ "$status" -eq 1 ]
    [[ "$output" =~ "Error" ]]
}

@test "machines_setup_ssh handles permissions" {
    # Mock all commands that interact with the system
    chmod() {
        echo "Setting permissions $1 on $2" >&2
        return 0
    }
    
    ssh() {
        echo "SSH: $*" >&2
        return 0
    }
    
    ssh-copy-id() {
        echo "Copying key: $*" >&2
        return 0
    }
    
    timeout() {
        "${@:2}"
    }
    
    export -f chmod ssh ssh-copy-id timeout
    
    run machines_setup_ssh
    echo "Output: $output" >&2
    [ "$status" -eq 0 ]
    [[ "$output" =~ "Setting up SSH access for manager.example.com" ]]
    [[ "$output" =~ "Successfully set up SSH access for manager.example.com" ]]
}

@test "machines_setup_ssh skips local machine" {
    # Mock hostname to return one of our test hosts
    hostname() {
        echo "manager.example.com"
    }
    
    ssh() {
        echo "SSH: $*" >&2
        return 0
    }
    
    ssh-copy-id() {
        echo "Copying key: $*" >&2
        return 0
    }
    
    timeout() {
        "${@:2}"
    }
    
    export -f hostname ssh ssh-copy-id timeout
    
    run machines_setup_ssh
    echo "Output: $output" >&2
    [ "$status" -eq 0 ]
    [[ "$output" =~ "Skipping SSH setup for local machine: manager.example.com" ]]
    [[ "$output" =~ "Setting up SSH access for worker1.example.com" ]]
}
