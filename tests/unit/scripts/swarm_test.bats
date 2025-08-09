#!/usr/bin/env bats

setup() {
    # Load test helper functions
    load test_helper

    # Create temporary test directory
    TEST_TEMP_DIR="$(temp_make)"

    # Set up test environment variables
    export TEST=true
    export PROJECT_ROOT="${TEST_TEMP_DIR}"
    export BASE_DOMAIN="test.example.com"

    # Create test certificate files structure
    mkdir -p "${TEST_TEMP_DIR}/certs/${BASE_DOMAIN}_ecc"
    mkdir -p "${TEST_TEMP_DIR}/certs"

    # Create mock certificate files
    echo "mock-fullchain-content" > "${TEST_TEMP_DIR}/certs/${BASE_DOMAIN}_ecc/fullchain.cer"
    echo "mock-key-content" > "${TEST_TEMP_DIR}/certs/${BASE_DOMAIN}_ecc/${BASE_DOMAIN}.key"
    echo "mock-ca-content" > "${TEST_TEMP_DIR}/certs/${BASE_DOMAIN}_ecc/ca.cer"
    echo "mock-dhparam-content" > "${TEST_TEMP_DIR}/certs/dhparam.pem"

    # Mock the load_env function
    load_env() {
        export BASE_DOMAIN="test.example.com"
    }

    # Source the swarm script with mocked wrapper functions
    source "${BATS_TEST_DIRNAME}/../../../scripts/wrappers/docker_wrapper.sh"
    source "${BATS_TEST_DIRNAME}/../../../scripts/wrappers/ssh_wrapper.sh"
    source "${BATS_TEST_DIRNAME}/../../../scripts/wrappers/file_wrapper.sh"
    source "${BATS_TEST_DIRNAME}/../../../scripts/deployments/swarm.sh"

    # Track docker commands called
    export DOCKER_COMMANDS_FILE="${TEST_TEMP_DIR}/docker_commands.log"
    # Clear any previous commands
    true > "$DOCKER_COMMANDS_FILE"

    # Mock docker wrapper functions
    docker_secret_create() {
        echo "docker secret create $1 $2" >> "$DOCKER_COMMANDS_FILE"
        echo "Creating secret: $1 from file: $2" >&2
        return 0
    }

    export -f load_env docker_secret_create
}

teardown() {
    # Clean up test directory
    temp_del "$TEST_TEMP_DIR"
}

@test "swarm_create_ssl_secrets_should_create_docker_secrets_from_cert_files" {
    # Clear previous commands
    true > "$DOCKER_COMMANDS_FILE"

    # Change to test directory for relative file operations
    cd "$TEST_TEMP_DIR"

    run swarm_create_ssl_secrets

    echo "Status: $status" >&2
    echo "Output: $output" >&2

    [ "$status" -eq 0 ]
    [[ "$output" == *"Creating swarm secrets for test.example.com"* ]]

    # Read the commands that were executed
    local commands_called
    if [ -f "$DOCKER_COMMANDS_FILE" ]; then
        commands_called=$(cat "$DOCKER_COMMANDS_FILE")
        echo "Commands called: $commands_called" >&2
    else
        echo "No commands file found at $DOCKER_COMMANDS_FILE" >&2
        return 1
    fi

    # Verify all four secrets were created with correct files
    [[ "$commands_called" == *"docker secret create ssl_full.pem ${TEST_TEMP_DIR}/certs/test.example.com_ecc/fullchain.cer"* ]]
    [[ "$commands_called" == *"docker secret create ssl_key.pem ${TEST_TEMP_DIR}/certs/test.example.com_ecc/test.example.com.key"* ]]
    [[ "$commands_called" == *"docker secret create ssl_ca.pem ${TEST_TEMP_DIR}/certs/test.example.com_ecc/ca.cer"* ]]
    [[ "$commands_called" == *"docker secret create ssl_dhparam.pem ${TEST_TEMP_DIR}/certs/dhparam.pem"* ]]
}

@test "swarm_initialize_manager_should_init_swarm_with_manager_ip" {
    # Clear previous commands
    true > "$DOCKER_COMMANDS_FILE"

    # Change to test directory for relative file operations
    cd "$TEST_TEMP_DIR"

    # Create test machines.yml file
    cat > "machines.yml" <<EOF
machines:
  - host: manager.test.com
    role: manager
    ssh_user: testuser
EOF

    # Mock machines functions
    machines_parse() {
        local key=$1
        if [ "$key" = "manager" ]; then
            echo "manager.test.com"
        fi
    }

    machines_get_host_ip() {
        local host=$1
        if [ "$host" = "manager.test.com" ]; then
            echo "192.168.1.100"
        fi
    }

    # Mock docker wrapper functions
    docker_swarm_init() {
        echo "docker swarm init --advertise-addr $1" >> "$DOCKER_COMMANDS_FILE"
        echo "Swarm initialized successfully" >&2
        return 0
    }

    docker_swarm_get_worker_token() {
        echo "docker swarm join-token -q worker" >> "$DOCKER_COMMANDS_FILE"
        echo "SWMTKN-1-test-token-12345"
        return 0
    }

    export -f machines_parse machines_get_host_ip docker_swarm_init docker_swarm_get_worker_token

    run swarm_initialize_manager

    echo "Status: $status" >&2
    echo "Output: $output" >&2

    [ "$status" -eq 0 ]
    [[ "$output" == *"Initializing swarm on manager node"* ]]
    [[ "$output" == *"Resolved manager IP: 192.168.1.100"* ]]

    # Read the commands that were executed
    local commands_called
    if [ -f "$DOCKER_COMMANDS_FILE" ]; then
        commands_called=$(cat "$DOCKER_COMMANDS_FILE")
        echo "Commands called: $commands_called" >&2
    fi

    # Verify swarm was initialized with correct IP
    [[ "$commands_called" == *"docker swarm init --advertise-addr 192.168.1.100"* ]]
    [[ "$commands_called" == *"docker swarm join-token -q worker"* ]]

    # Verify token was saved to file
    [ -f ".swarm_token" ]
    local token_content
    token_content=$(cat ".swarm_token")
    [ "$token_content" = "SWMTKN-1-test-token-12345" ]
}

@test "swarm_add_worker_node_should_join_node_to_swarm" {
    # Clear previous commands
    true > "$DOCKER_COMMANDS_FILE"

    # Change to test directory for relative file operations
    cd "$TEST_TEMP_DIR"

    # Create test machines.yml file
    cat > "machines.yml" <<EOF
machines:
  - host: manager.test.com
    role: manager
    ssh_user: manager_user
  - host: worker1.test.com
    role: worker
    ssh_user: worker_user
EOF

    # Create test token file
    echo "SWMTKN-1-test-worker-token-67890" > ".swarm_token"

    # Track SSH commands called
    export SSH_COMMANDS_FILE="${TEST_TEMP_DIR}/ssh_commands.log"
    true > "$SSH_COMMANDS_FILE"

    # Mock machines functions
    machines_parse() {
        local key=$1
        if [ "$key" = "manager" ]; then
            echo "manager.test.com"
        fi
    }

    machines_get_host_ip() {
        local host=$1
        case "$host" in
            "manager.test.com") echo "192.168.1.100" ;;
            "worker1.test.com") echo "192.168.1.101" ;;
        esac
    }

    machines_get_ssh_user() {
        local host=$1
        case "$host" in
            "manager.test.com") echo "manager_user" ;;
            "worker1.test.com") echo "worker_user" ;;
        esac
    }

    # Mock file wrapper functions
    file_read() {
        local file_path="$1"
        if [ "$file_path" = ".swarm_token" ]; then
            echo "SWMTKN-1-test-worker-token-67890"
        fi
    }

    # Mock SSH wrapper functions
    ssh_docker_command() {
        echo "ssh_docker_command $1 $2" >> "$SSH_COMMANDS_FILE"
        echo "SSH Docker command executed on $1: $2" >&2
        return 0
    }

    export -f machines_parse machines_get_host_ip machines_get_ssh_user file_read ssh_docker_command

    run swarm_add_worker_node "worker1.test.com"

    echo "Status: $status" >&2
    echo "Output: $output" >&2

    [ "$status" -eq 0 ]
    [[ "$output" == *"Joining node worker1.test.com to swarm"* ]]

    # Read the SSH commands that were executed
    local ssh_commands_called
    if [ -f "$SSH_COMMANDS_FILE" ]; then
        ssh_commands_called=$(cat "$SSH_COMMANDS_FILE")
        echo "SSH commands called: $ssh_commands_called" >&2
    fi

    # Verify the worker node was joined with correct token and manager IP
    [[ "$ssh_commands_called" == *"ssh_docker_command worker_user@worker1.test.com docker swarm join --token SWMTKN-1-test-worker-token-67890 192.168.1.100:2377"* ]]
}
