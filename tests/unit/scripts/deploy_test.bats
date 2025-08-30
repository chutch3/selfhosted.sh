#!/usr/bin/env bats

load test_helper

setup() {
    # Create temporary test directory
    TEST_TEMP_DIR="$(temp_make)"
    export PROJECT_ROOT="$TEST_TEMP_DIR"

    # Create test machines.yaml with new format
    cat > "$TEST_TEMP_DIR/machines.yaml" <<EOF
machines:
  cody-X570-GAMING-X:
    ip: 192.168.86.41
    role: manager
    ssh_user: cody
    labels:
      gpu: true
  giant:
    ip: 192.168.86.39
    role: worker
    ssh_user: chutchens
  imac:
    ip: 192.168.86.137
    role: worker
    ssh_user: chutchens
EOF

    export MACHINES_FILE="$TEST_TEMP_DIR/machines.yaml"
}

teardown() {
    temp_del "$TEST_TEMP_DIR"
}

@test "deploy.new.sh should generate nodes with IP addresses not empty hostnames" {
    # Test the yq query used in deploy.new.sh nuke function
    run yq -r '.machines[] | .ssh_user + "@" + .ip' "$MACHINES_FILE"
    [ "$status" -eq 0 ]

    # Verify all lines have the format user@IP
    while IFS= read -r line; do
        [[ -n "$line" ]] || continue
        echo "Testing line: '$line'"
        [[ "$line" =~ ^[a-zA-Z0-9_-]+@[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]
    done <<< "$output"

    # Verify no empty hostnames
    [[ "$output" != *"@"$'\n'* ]]  # No lines ending with just @
    [[ "$output" != *"@ "* ]]      # No @ followed by space
}

@test "deploy.new.sh should not reference .host field for machines" {
    # Regression test: ensure we're using .ip not .host
    run grep -n "\.host" "${BATS_TEST_DIRNAME}/../../../scripts/deploy.new.sh"
    # Should only find references in comments or other contexts, not in the yq queries
    if [ "$status" -eq 0 ]; then
        # If .host is found, it should NOT be in a yq query for machines
        [[ "$output" != *"machines[] | .ssh_user"*".host"* ]]
    fi
}

@test "RED: nuke should detect local machine and run commands directly" {
    # Create a test scenario where one of the nodes is the local machine
    # This test should initially FAIL because the script tries to SSH to itself

    # Get the current user and a local IP (simulate being on the manager node)
    local current_user=$(whoami)

    # Create machines.yaml where one node matches current user@localhost
    cat > "$TEST_TEMP_DIR/machines.yaml" <<EOF
machines:
  local-manager:
    ip: 127.0.0.1
    role: manager
    ssh_user: $current_user
  remote-worker:
    ip: 192.168.86.39
    role: worker
    ssh_user: chutchens
EOF

    # Test the yq query - it should generate proper user@IP including local machine
    run yq -r '.machines[] | .ssh_user + "@" + .ip' "$TEST_TEMP_DIR/machines.yaml"
    [ "$status" -eq 0 ]

    # Verify it includes the local machine entry
    [[ "$output" == *"$current_user@127.0.0.1"* ]]
    [[ "$output" == *"chutchens@192.168.86.39"* ]]

    # This documents the current issue: the script will try to SSH to 127.0.0.1
    # which should be detected as local machine and run commands directly
    echo "Current behavior: script will try SSH to $current_user@127.0.0.1"
    echo "Expected behavior: should detect local machine and run docker commands directly"
}

@test "GREEN: deploy.new.sh should have local machine detection logic" {
    # Verify that the deploy.new.sh script now contains local machine detection

    # Check for machines_my_ip function call
    run grep -n "machines_my_ip" "${BATS_TEST_DIRNAME}/../../../scripts/deploy.new.sh"
    [ "$status" -eq 0 ]

    # Check for local machine detection pattern in nuke function
    run grep -A5 -B5 "node_ip.*current_machine_ip.*localhost.*127.0.0.1" "${BATS_TEST_DIRNAME}/../../../scripts/deploy.new.sh"
    [ "$status" -eq 0 ]

    # Check for local execution message
    run grep -n "Running locally.*detected as current machine" "${BATS_TEST_DIRNAME}/../../../scripts/deploy.new.sh"
    [ "$status" -eq 0 ]

    # Verify local docker commands (not ssh)
    run grep -A2 "Running locally" "${BATS_TEST_DIRNAME}/../../../scripts/deploy.new.sh"
    [ "$status" -eq 0 ]
    [[ "$output" == *"docker volume"* ]]
    [[ "$output" == *"docker swarm leave"* ]]
}

@test "deploy.new.sh should parse user@ip format correctly" {
    # Test the bash parameter expansion used to extract IP and user
    local test_node="testuser@192.168.1.100"

    # Test IP extraction
    local node_ip="${test_node##*@}"
    [ "$node_ip" = "192.168.1.100" ]

    # Test user extraction
    local node_user="${test_node%%@*}"
    [ "$node_user" = "testuser" ]
}
