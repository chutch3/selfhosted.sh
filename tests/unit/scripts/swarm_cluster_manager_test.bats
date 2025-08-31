#!/usr/bin/env bats

# Tests for Docker Swarm Cluster Management
# Part of Issue #39 - Docker Swarm Cluster Management
# Following TDD workflow: RED phase - write failing tests first

load test_helper

setup() {
    # Set PROJECT_ROOT relative to test location
    local project_root_path
    project_root_path="$(cd "$(dirname "$BATS_TEST_FILENAME")/../../.." && pwd)"
    export PROJECT_ROOT="$project_root_path"

    # Create temporary directories for testing
    local test_dir
    test_dir=$(mktemp -d)
    export TEST_DIR="$test_dir"
    export TEST_CONFIG="$TEST_DIR/homelab.yaml"
    export SWARM_TOKEN_FILE="$TEST_DIR/.swarm_token"
    export HOMELAB_CONFIG="$TEST_CONFIG"

    # Create test configuration
    create_test_swarm_config
}

teardown() {
    # Clean up temporary directories
    rm -rf "$TEST_DIR"
}

# Helper function to create test Swarm configuration with NEW format
create_test_swarm_config() {
    cat > "$TEST_CONFIG" << 'EOF'
version: "2.0"
deployment: docker_swarm

environment:
  BASE_DOMAIN: test.local
  PROJECT_ROOT: /opt/homelab

machines:
  driver:
    ip: 192.168.1.100
    ssh_user: ubuntu
    role: manager
    labels:
      storage: ssd
      gpu: nvidia
  node-01:
    ip: 192.168.1.101
    ssh_user: ubuntu
    role: worker
    labels:
      storage: hdd
  node-02:
    ip: 192.168.1.102
    ssh_user: ubuntu
    role: worker
    labels:
      storage: ssd

services:
  nginx:
    image: nginx:alpine
    ports: [80, 443]
    deploy: all

  web_app:
    image: nginx:alpine
    port: 8080
    deploy: any
    replicas: 3
EOF
}

# Helper function to create invalid configuration
create_invalid_config() {
    cat > "$TEST_CONFIG" << 'EOF'
version: "2.0"
deployment: docker_compose

# Missing machines section for Swarm
services:
  nginx:
    image: nginx:alpine
EOF
}

# Mock docker commands for testing
mock_docker_swarm_init() {
    echo "Swarm initialized: $1"
    return 0
}

mock_docker_swarm_get_worker_token() {
    echo "SWMTKN-1-test-token-12345"
    return 0
}

mock_docker_node_update_label() {
    # Extract the label from the arguments (format: --label-add key=value nodename)
    local label="$2"
    echo "Mock: docker node update --label-add $label $3"
    return 0
}

mock_ssh_docker_command() {
    echo "SSH Docker command: $1 -> $2"
    return 0
}

# Export mock functions
export -f mock_docker_swarm_init
export -f mock_docker_swarm_get_worker_token
export -f mock_docker_node_update_label
export -f mock_ssh_docker_command

# ================================
# RED PHASE - Failing Tests First
# ================================

@test "swarm_cluster_manager.sh script exists and is executable" {
    local script_path="$PROJECT_ROOT/scripts/swarm_cluster_manager.sh"

    # This should FAIL initially (RED phase)
    [ -f "$script_path" ]
    [ -x "$script_path" ]
}

@test "get_manager_machine identifies manager from machines configuration" {
    # Source the script
    source "$PROJECT_ROOT/scripts/swarm_cluster_manager.sh"

    # Create machines.yaml config
    cat > "$TEST_DIR/machines.yaml" << EOF
machines:
  manager:
    ip: 192.168.1.10
    user: admin
    role: manager
  worker-01:
    ip: 192.168.1.11
    user: admin
    role: worker
EOF

    # Valid configuration should return manager
    run get_manager_machine "$TEST_DIR/machines.yaml"
    [ "$status" -eq 0 ]
    [[ "$output" == *"manager"* ]]
}

@test "get_worker_machines lists worker nodes" {
    source "$PROJECT_ROOT/scripts/swarm_cluster_manager.sh"

    # Create machines.yaml with workers
    cat > "$TEST_DIR/machines.yaml" << EOF
machines:
  manager:
    ip: 192.168.1.10
    user: admin
  worker-01:
    ip: 192.168.1.11
    user: admin
  worker-02:
    ip: 192.168.1.12
    user: admin
EOF

    # Should return worker nodes
    run get_worker_machines "$TEST_DIR/machines.yaml"
    [ "$status" -eq 0 ]
    [[ "$output" == *"worker-01"* ]]
    [[ "$output" == *"worker-02"* ]]
    [[ "$output" != *"manager"* ]]
}

@test "get_manager_machine identifies manager from configuration" {
    source "$PROJECT_ROOT/scripts/swarm_cluster_manager.sh"

    run get_manager_machine "$TEST_CONFIG"
    [ "$status" -eq 0 ]
    [ "$output" = "driver" ]
}


@test "get_machine_host extracts host IP from configuration" {
    source "$PROJECT_ROOT/scripts/swarm_cluster_manager.sh"

    run get_machine_host "driver" "$TEST_CONFIG"
    [ "$status" -eq 0 ]
    [ "$output" = "192.168.1.100" ]

    run get_machine_host "node-01" "$TEST_CONFIG"
    [ "$status" -eq 0 ]
    [ "$output" = "192.168.1.101" ]
}

@test "get_machine_user extracts SSH user from configuration" {
    source "$PROJECT_ROOT/scripts/swarm_cluster_manager.sh"

    run get_machine_user "driver" "$TEST_CONFIG"
    [ "$status" -eq 0 ]
    [ "$output" = "ubuntu" ]
}

@test "get_machine_labels extracts labels from configuration" {
    source "$PROJECT_ROOT/scripts/swarm_cluster_manager.sh"

    run get_machine_labels "driver" "$TEST_CONFIG"
    [ "$status" -eq 0 ]
    [[ "$output" == *"storage=ssd"* ]]
    [[ "$output" == *"gpu=nvidia"* ]]
}

@test "initialize_swarm_cluster fails with invalid configuration" {
    source "$PROJECT_ROOT/scripts/swarm_cluster_manager.sh"

    create_invalid_config
    run initialize_swarm_cluster "$TEST_CONFIG"
    [ "$status" -eq 1 ]
}

@test "initialize_swarm_cluster initializes manager node" {
    # Mock docker functions
    # shellcheck disable=SC2317
    docker_swarm_init() { mock_docker_swarm_init "$@"; }
    # shellcheck disable=SC2317
    docker_swarm_get_worker_token() { mock_docker_swarm_get_worker_token "$@"; }
    # shellcheck disable=SC2317
    ssh_docker_command() { mock_ssh_docker_command "$@"; }
    # shellcheck disable=SC2317
    docker_node_update_label() { mock_docker_node_update_label "$@"; }
    # shellcheck disable=SC2317
    machines_my_ip() { echo "127.0.0.1"; }

    export -f docker_swarm_init
    export -f docker_swarm_get_worker_token
    export -f ssh_docker_command
    export -f docker_node_update_label
    export -f machines_my_ip

    source "$PROJECT_ROOT/scripts/swarm_cluster_manager.sh"

    # Re-define the mocks after sourcing to override any imported functions
    machines_my_ip() { echo "127.0.0.1"; }
    docker_swarm_init() { mock_docker_swarm_init "$@"; }
    docker_swarm_get_worker_token() { mock_docker_swarm_get_worker_token "$@"; }
    ssh_docker_command() { mock_ssh_docker_command "$@"; }
    docker_node_update_label() { mock_docker_node_update_label "$@"; }
    export -f machines_my_ip docker_swarm_init docker_swarm_get_worker_token ssh_docker_command docker_node_update_label

    # Create machines.yaml config for local testing
    cat > "$TEST_DIR/machines.yaml" << 'EOF'
machines:
  manager:
    ip: 127.0.0.1
    ssh_user: testuser
    role: manager
EOF

    run initialize_swarm_cluster "$TEST_DIR/machines.yaml"
    [ "$status" -eq 0 ]
    [[ "$output" == *"Swarm manager initialized successfully"* ]]

    # Check token file was created
    [ -f "$SWARM_TOKEN_FILE" ]
    [ "$(cat "$SWARM_TOKEN_FILE")" = "SWMTKN-1-test-token-12345" ]
}

@test "join_worker_nodes joins workers to cluster" {
    # Mock functions
    # shellcheck disable=SC2317
    ssh_docker_command() { mock_ssh_docker_command "$@"; }
    export -f ssh_docker_command

    source "$PROJECT_ROOT/scripts/swarm_cluster_manager.sh"

    # Re-define mocks after sourcing to override imports
    ssh_docker_command() { mock_ssh_docker_command "$@"; }
    export -f ssh_docker_command

    run join_worker_nodes "$TEST_CONFIG" "SWMTKN-1-test-token" "192.168.1.100"
    [ "$status" -eq 0 ]
    [[ "$output" == *"node-01"* ]]
    [[ "$output" == *"node-02"* ]]
}

@test "label_swarm_nodes applies machine labels" {
    # Mock functions
    # shellcheck disable=SC2317
    docker_node_update_label() { mock_docker_node_update_label "$@"; }
    # shellcheck disable=SC2317
    docker_node_ls() { echo "driver"; }  # Mock node exists
    export -f docker_node_update_label
    export -f docker_node_ls

    source "$PROJECT_ROOT/scripts/swarm_cluster_manager.sh"

    # Re-define mocks after sourcing to override imports
    docker_node_update_label() { mock_docker_node_update_label "$@"; }
    docker_node_ls() { echo "driver"; }
    export -f docker_node_update_label docker_node_ls

    run label_swarm_nodes "$TEST_CONFIG"
    [ "$status" -eq 0 ]
    [[ "$output" == *"machine.id=driver"* ]]        # NEW: Expect machine ID label
    [[ "$output" == *"machine.role=manager"* ]]     # KEEP: Existing role label
    [[ "$output" == *"storage=ssd"* ]]              # KEEP: Custom labels
    [[ "$output" == *"gpu=nvidia"* ]]               # KEEP: Custom labels
}

@test "monitor_swarm_cluster shows cluster status" {
    # Mock functions
    docker_node_list() {
        if [[ "$1" == "table"* ]]; then
            echo -e "HOSTNAME\tSTATUS\tAVAILABILITY\tMANAGER STATUS"
            echo -e "driver\tReady\tActive\tLeader"
            echo -e "node-01\tReady\tActive\t"
        else
            echo -e "driver\nnode-01"
        fi
    }

    docker_node_inspect() {
        echo "ready"
    }

    docker_service_list() {
        echo -e "ID\tNAME\tMODE\tREPLICAS"
        echo -e "abc123\tnginx\tglobal\t2/2"
    }

    export -f docker_node_list
    export -f docker_node_inspect
    export -f docker_service_list

    source "$PROJECT_ROOT/scripts/swarm_cluster_manager.sh"

    # Re-define mocks after sourcing to override imports
    docker_node_list() {
        if [[ "$1" == "table"* ]]; then
            echo -e "HOSTNAME\tSTATUS\tAVAILABILITY\tMANAGER STATUS"
            echo -e "driver\tReady\tActive\tLeader"
            echo -e "node-01\tReady\tActive\t"
        else
            echo -e "driver\nnode-01"
        fi
    }
    docker_node_inspect() { echo "ready"; }
    docker_service_list() {
        echo -e "ID\tNAME\tMODE\tREPLICAS"
        echo -e "abc123\tnginx\tglobal\t2/2"
    }
    export -f docker_node_list docker_node_inspect docker_service_list

    run monitor_swarm_cluster
    [ "$status" -eq 0 ]
    [[ "$output" == *"Swarm Node Status"* ]]
    [[ "$output" == *"All nodes are healthy"* ]]
    [[ "$output" == *"Swarm Services"* ]]
}

@test "script shows usage when called with --help" {
    run "$PROJECT_ROOT/scripts/swarm_cluster_manager.sh" --help
    [ "$status" -eq 0 ]
    [[ "$output" == *"Usage:"* ]]
    [[ "$output" == *"init-cluster"* ]]
    [[ "$output" == *"join-workers"* ]]
    [[ "$output" == *"monitor-cluster"* ]]
}

@test "script fails with unknown command" {
    run "$PROJECT_ROOT/scripts/swarm_cluster_manager.sh" invalid-command
    [ "$status" -eq 1 ]
    [[ "$output" == *"Unknown command"* ]]
}

@test "init-cluster command works end-to-end" {
    skip "End-to-end test requires real SSH environment or integration test setup"

    # Note: This test executes the script as a subprocess, so mocked functions
    # defined in the test environment don't carry over. This test should be
    # moved to an integration test suite or the script should be modified to
    # support test mode detection.

    # Mock all docker functions
    docker_swarm_init() { mock_docker_swarm_init "$@"; }
    docker_swarm_get_worker_token() { mock_docker_swarm_get_worker_token "$@"; }
    ssh_docker_command() { mock_ssh_docker_command "$@"; }
    docker_node_update_label() { mock_docker_node_update_label "$@"; }

    export -f docker_swarm_init
    export -f docker_swarm_get_worker_token
    export -f ssh_docker_command
    export -f docker_node_update_label

    # Create localhost config
    cat > "$TEST_CONFIG" << 'EOF'
version: "2.0"
deployment: docker_swarm

machines:
  driver:
    ip: 127.0.0.1
    ssh_user: testuser
    role: manager
EOF

    # Override mocks after loading
    machines_my_ip() { echo "127.0.0.1"; }
    export -f machines_my_ip

    run "$PROJECT_ROOT/scripts/swarm_cluster_manager.sh" init-cluster -c "$TEST_CONFIG"
    [ "$status" -eq 0 ]
    [[ "$output" == *"Swarm cluster initialization complete"* ]]
}

# ================================
# Integration Tests (More Complex)
# ================================


@test "swarm_cluster_manager uses machines_get_ip for IP-first resolution" {
    # Verify that swarm_cluster_manager.sh contains the IP-first function call
    run grep "machines_get_ip" "$PROJECT_ROOT/scripts/swarm_cluster_manager.sh"
    [ "$status" -eq 0 ]
    [[ "$output" == *"machines_get_ip"* ]]

    # Verify it's NOT using the old function
    run grep "machines_get_host_ip" "$PROJECT_ROOT/scripts/swarm_cluster_manager.sh"
    [ "$status" -eq 1 ]  # Should not find it
}

@test "get_machine_host should work with new machines.yaml format" {
    source "$PROJECT_ROOT/scripts/swarm_cluster_manager.sh"

    # This should FAIL initially - testing with new format
    run get_machine_host "driver" "$TEST_CONFIG"
    [ "$status" -eq 0 ]
    [ "$output" = "192.168.1.100" ]

    run get_machine_host "node-01" "$TEST_CONFIG"
    [ "$status" -eq 0 ]
    [ "$output" = "192.168.1.101" ]
}
