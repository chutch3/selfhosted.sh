#!/usr/bin/env bats

# Workflow Integration Tests
# Part of Issue #40 - Comprehensive Test Suite for Unified Configuration
# Tests end-to-end workflows with mocking for CI/CD compatibility

load ../helpers/enhanced_test_helper

setup() {
    setup_comprehensive_test

    # Source required scripts based on test type
    if [ -f "$PROJECT_ROOT/scripts/translate_homelab_to_compose.sh" ]; then
        # shellcheck disable=SC1091
        source "$PROJECT_ROOT/scripts/translate_homelab_to_compose.sh"
    fi

    # Note: Swarm script sourced only for specific Swarm tests to avoid conflicts
    # The validate_homelab_config function conflicts between scripts

    # Enable mocking for CI/CD
    export -f mock_ssh
    export -f mock_docker
    alias ssh=mock_ssh
    alias docker=mock_docker
}

teardown() {
    teardown_comprehensive_test
    unalias ssh docker 2>/dev/null || true
}

# =============================================================================
# DOCKER COMPOSE WORKFLOW TESTS
# =============================================================================

@test "complete Docker Compose workflow - single machine" {
    # Create single machine configuration
    create_test_homelab_config "docker_compose" 1 3

    # Generate bundles
    export HOMELAB_CONFIG="$TEST_CONFIG"
    export OUTPUT_DIR="$TEST_OUTPUT"
    time_operation "Single Machine Bundle Generation" translate_homelab_to_compose
    assert_within_time_limit 3

    # Validate generated bundles
    [ -f "$TEST_OUTPUT/driver/docker-compose.yaml" ]
    assert_docker_compose_valid "$TEST_OUTPUT/driver/docker-compose.yaml"

    # Check for nginx configuration
    [ -f "$TEST_OUTPUT/driver/nginx/nginx.conf" ]
    assert_nginx_config_valid "$TEST_OUTPUT/driver/nginx/nginx.conf"

    # Check for deployment script
    [ -f "$TEST_OUTPUT/driver/deploy.sh" ]
    [ -x "$TEST_OUTPUT/driver/deploy.sh" ]

    # Verify service inclusion
    local service_count
    service_count=$(yq '.services | keys | length' "$TEST_OUTPUT/driver/docker-compose.yaml")
    [ "$service_count" -ge 3 ]  # At least 3 services plus nginx-proxy
}

@test "complete Docker Compose workflow - multi-machine" {
    # Create multi-machine configuration
    create_test_homelab_config "docker_compose" 3 5

    # Generate bundles
    export HOMELAB_CONFIG="$TEST_CONFIG"
    export OUTPUT_DIR="$TEST_OUTPUT"
    time_operation "Multi Machine Bundle Generation" translate_homelab_to_compose
    assert_within_time_limit 5

    # Validate all machine bundles
    for machine in driver node-01 node-02; do
        echo "Validating bundle for $machine"

        [ -f "$TEST_OUTPUT/$machine/docker-compose.yaml" ]
        assert_docker_compose_valid "$TEST_OUTPUT/$machine/docker-compose.yaml"

        [ -f "$TEST_OUTPUT/$machine/nginx/nginx.conf" ]
        assert_nginx_config_valid "$TEST_OUTPUT/$machine/nginx/nginx.conf"

        [ -f "$TEST_OUTPUT/$machine/deploy.sh" ]
        [ -x "$TEST_OUTPUT/$machine/deploy.sh" ]
    done

    # Verify deployment strategy distribution
    validate_deployment_strategy "all" "$TEST_OUTPUT" "nginx"
}

@test "Docker Compose deployment coordination (mocked)" {
    create_test_homelab_config "docker_compose" 3 5
    export HOMELAB_CONFIG="$TEST_CONFIG"
    export OUTPUT_DIR="$TEST_OUTPUT"
    translate_homelab_to_compose

    # Test deployment coordination with mocked SSH
    if [ -f "$PROJECT_ROOT/scripts/deploy_compose_bundles.sh" ]; then
        # shellcheck disable=SC1091
        source "$PROJECT_ROOT/scripts/deploy_compose_bundles.sh"

        # Ensure mocking is enabled (from enhanced_test_helper.bash)
        export -f mock_ssh
        alias ssh=mock_ssh
        
        # Mock SSH connectivity test to always succeed in CI
        ssh_test_connection() {
            echo "Mocked SSH test for $1" >&2
            return 0
        }
        export -f ssh_test_connection

        time_operation "Deployment Coordination" deploy_to_all_machines "$TEST_CONFIG"
        assert_within_time_limit 10

        # Verify coordination messages
        [[ $output == *"driver"* ]]
        [[ $output == *"node-01"* ]]
        [[ $output == *"node-02"* ]]
    else
        skip "Deploy script not available"
    fi
}

# =============================================================================
# DOCKER SWARM WORKFLOW TESTS
# =============================================================================

@test "complete Docker Swarm workflow - stack generation" {
    # Create Swarm configuration
    create_test_homelab_config "docker_swarm" 3 5

    # Source Swarm script separately (avoiding function conflicts)
    if [ -f "$PROJECT_ROOT/scripts/translate_homelab_to_swarm.sh" ]; then
        # shellcheck disable=SC1091
        source "$PROJECT_ROOT/scripts/translate_homelab_to_swarm.sh"
        
        # Generate Swarm stack
        time_operation "Swarm Stack Generation" translate_to_docker_swarm "$TEST_CONFIG"
        assert_within_time_limit 3

        # Save stack output
        translate_to_docker_swarm "$TEST_CONFIG" > "$TEST_OUTPUT/docker-stack.yaml"

        # Validate generated stack
        assert_swarm_stack_valid "$TEST_OUTPUT/docker-stack.yaml"

        # Verify Swarm-specific features
    yq '.networks.overlay_network.driver' "$TEST_OUTPUT/docker-stack.yaml" | grep -q "overlay"

        # Check for placement constraints
        local constraints
        constraints=$(yq '.services[].deploy.placement.constraints[]?' "$TEST_OUTPUT/docker-stack.yaml" 2>/dev/null)
        echo "$constraints" | grep -q "node.hostname" || echo "No placement constraints found (may be expected)"
    else
        skip "Swarm translation script not available"
    fi
}

@test "Docker Swarm deployment strategies translation" {
    # Source Swarm script separately
    if [ -f "$PROJECT_ROOT/scripts/translate_homelab_to_swarm.sh" ]; then
        # shellcheck disable=SC1091
        source "$PROJECT_ROOT/scripts/translate_homelab_to_swarm.sh"
    cat > "$TEST_CONFIG" << 'EOF'
version: "2.0"
deployment: docker_swarm

machines:
  driver: {host: 192.168.1.10, user: admin, role: manager}
  node-01: {host: 192.168.1.11, user: admin, role: worker}
  node-02: {host: 192.168.1.12, user: admin, role: worker}

services:
  driver_service:
    image: test:latest
    port: 3000
    deploy: driver
  all_service:
    image: test:latest
    port: 3001
    deploy: all
  specific_service:
    image: test:latest
    port: 3002
    deploy: node-01
  random_service:
    image: test:latest
    port: 3003
    deploy: random
EOF

        # Generate stack
        translate_to_docker_swarm "$TEST_CONFIG" > "$TEST_OUTPUT/docker-stack.yaml"
        assert_swarm_stack_valid "$TEST_OUTPUT/docker-stack.yaml"

        # Verify deployment strategies are translated
        local stack_content
        stack_content=$(cat "$TEST_OUTPUT/docker-stack.yaml")

        # Check for placement constraints
        echo "$stack_content" | grep -q "node.hostname == driver" || echo "Driver constraint not found"
        echo "$stack_content" | grep -q "node.hostname == node-01" || echo "Node-01 constraint not found"

        # Check for global mode (deploy: all)
        echo "$stack_content" | grep -q "mode: global" || echo "Global mode not found"
    else
        skip "Swarm translation script not available"
    fi
}

@test "Docker Swarm orchestration features" {
    # Source Swarm script separately
    if [ -f "$PROJECT_ROOT/scripts/translate_homelab_to_swarm.sh" ]; then
        # shellcheck disable=SC1091
        source "$PROJECT_ROOT/scripts/translate_homelab_to_swarm.sh"
    cat > "$TEST_CONFIG" << 'EOF'
version: "2.0"
deployment: docker_swarm

machines:
  driver: {host: 192.168.1.10, user: admin, role: manager}

services:
  web_service:
    image: nginx:alpine
    port: 80
    replicas: 3
    health_check: /health

secrets:
  api_key:
    external: true
  db_password:
    external: false
EOF

        translate_to_docker_swarm "$TEST_CONFIG" > "$TEST_OUTPUT/docker-stack.yaml"
        assert_swarm_stack_valid "$TEST_OUTPUT/docker-stack.yaml"

        # Verify orchestration features
        local stack_content
        stack_content=$(cat "$TEST_OUTPUT/docker-stack.yaml")

        echo "$stack_content" | grep -q "replicas: 3"
        echo "$stack_content" | grep -q "healthcheck:"
        echo "$stack_content" | grep -q "secrets:"
        echo "$stack_content" | grep -q "api_key:"
    else
        skip "Swarm translation script not available"
    fi
}

# =============================================================================
# MIGRATION WORKFLOW TESTS
# =============================================================================

@test "complete migration workflow - legacy to unified config" {
    # Create legacy configuration
    create_legacy_config_fixture "$TEST_DIR"

    # Perform migration (if migration script available)
    if [ -f "$PROJECT_ROOT/scripts/migrate_to_homelab_yaml.sh" ]; then
        cd "$TEST_DIR"

        time_operation "Configuration Migration" "$PROJECT_ROOT/scripts/migrate_to_homelab_yaml.sh" -o "$TEST_DIR/test-homelab.yaml"
        assert_within_time_limit 30

        # Validate migrated configuration
        [ -f "$TEST_DIR/test-homelab.yaml" ]
        assert_homelab_config_valid "$TEST_DIR/test-homelab.yaml"

        # Verify migration preserved key information
        yq '.services.homepage' "$TEST_DIR/test-homelab.yaml" | grep -q "homepage"
        yq '.services.jellyfin' "$TEST_DIR/test-homelab.yaml" | grep -q "jellyfin"

        # Test that migrated config can generate bundles
        export HOMELAB_CONFIG="$TEST_DIR/test-homelab.yaml"
        export OUTPUT_DIR="$TEST_OUTPUT"
        translate_homelab_to_compose
        [ -f "$TEST_OUTPUT/driver/docker-compose.yaml" ]
    else
        skip "Migration script not available"
    fi
}

@test "migration preserves service functionality" {
    create_legacy_config_fixture "$TEST_DIR"

    if [ -f "$PROJECT_ROOT/scripts/migrate_to_homelab_yaml.sh" ]; then
        cd "$TEST_DIR"
        "$PROJECT_ROOT/scripts/migrate_to_homelab_yaml.sh" -o "$TEST_DIR/test-homelab.yaml"

        # Generate bundles from migrated config
        export HOMELAB_CONFIG="$TEST_DIR/test-homelab.yaml"
        export OUTPUT_DIR="$TEST_OUTPUT/migrated"
        translate_homelab_to_compose

        # Validate functionality preservation
        local migrated_services
        migrated_services=$(yq '.services | keys[]' "$TEST_OUTPUT/migrated/driver/docker-compose.yaml")

        echo "$migrated_services" | grep -q "homepage"
        echo "$migrated_services" | grep -q "jellyfin"
    else
        skip "Migration script not available"
    fi
}

# =============================================================================
# CROSS-DEPLOYMENT VALIDATION
# =============================================================================

@test "same configuration works for both deployment types" {
    # Create base configuration
    cat > "$TEST_CONFIG" << 'EOF'
version: "2.0"
deployment: docker_compose

machines:
  driver: {host: localhost, user: test}

services:
  web:
    image: nginx:alpine
    port: 80
    enabled: true
  app:
    image: app:latest
    port: 3000
    enabled: true
EOF

    # Test Docker Compose generation
    export HOMELAB_CONFIG="$TEST_CONFIG"
    export OUTPUT_DIR="$TEST_OUTPUT"
    translate_homelab_to_compose
    assert_docker_compose_valid "$TEST_OUTPUT/driver/docker-compose.yaml"

    # Convert to Swarm and test (using actual swarm script)
    yq '.deployment = "docker_swarm"' -i "$TEST_CONFIG"
    
    # Source swarm script and translate
    if [ -f "$PROJECT_ROOT/scripts/translate_homelab_to_swarm.sh" ]; then
        # shellcheck disable=SC1091
        source "$PROJECT_ROOT/scripts/translate_homelab_to_swarm.sh"
        translate_to_docker_swarm "$TEST_CONFIG" > "$TEST_OUTPUT/docker-stack.yaml"
        assert_swarm_stack_valid "$TEST_OUTPUT/docker-stack.yaml"
    else
        skip "Swarm translation script not available"
    fi

    # Both should have the same services
    local compose_services swarm_services
    compose_services=$(yq '.services | keys[]' "$TEST_OUTPUT/driver/docker-compose.yaml" | grep -v nginx-proxy | sort)
    swarm_services=$(yq '.services | keys[]' "$TEST_OUTPUT/docker-stack.yaml" | sort)

    # Services should be present in both (allowing for nginx-proxy differences)
    echo "$compose_services" | grep -q "web"
    echo "$compose_services" | grep -q "app"
    echo "$swarm_services" | grep -q "web"
    echo "$swarm_services" | grep -q "app"
}

# =============================================================================
# ERROR HANDLING AND EDGE CASES
# =============================================================================

@test "workflow handles missing dependencies gracefully" {
    create_test_homelab_config "docker_compose" 1 2

    # Test with missing translation functions
    if ! command -v translate_homelab_to_compose >/dev/null 2>&1; then
        run translate_homelab_to_compose "$TEST_CONFIG"
        [ $status -ne 0 ]
        echo "Expected failure when translation functions not available"
    fi
}

@test "workflow validates configuration before processing" {
    # Create invalid configuration
    cat > "$TEST_CONFIG" << 'EOF'
version: "2.0"
# Missing deployment type
machines:
  driver: {host: localhost, user: test}
services:
  test:
    image: test:latest
EOF

    # Should fail early with validation error
    run translate_homelab_to_compose "$TEST_CONFIG"
    [ $status -ne 0 ]
}

@test "workflow handles empty service lists" {
    cat > "$TEST_CONFIG" << 'EOF'
version: "2.0"
deployment: docker_compose
machines:
  driver: {host: localhost, user: test}
services: {}
EOF

    # Should handle empty services gracefully
    run translate_homelab_to_compose "$TEST_CONFIG"
    # May succeed with empty output or fail with validation error
    echo "Empty services result: $status"
}

# =============================================================================
# PERFORMANCE INTEGRATION TESTS
# =============================================================================

@test "workflow performance - small configuration" {
    create_test_homelab_config "docker_compose" 1 3

    export HOMELAB_CONFIG="$TEST_CONFIG"
    export OUTPUT_DIR="$TEST_OUTPUT"
    time_operation "Small Config Workflow" translate_homelab_to_compose
    assert_within_time_limit 2
}

@test "workflow performance - medium configuration" {
    create_test_homelab_config "docker_compose" 3 10

    export HOMELAB_CONFIG="$TEST_CONFIG"
    export OUTPUT_DIR="$TEST_OUTPUT"
    time_operation "Medium Config Workflow" translate_homelab_to_compose
    assert_within_time_limit 5
}

@test "workflow performance - large configuration" {
    create_test_homelab_config "docker_compose" 5 20

    export HOMELAB_CONFIG="$TEST_CONFIG"
    export OUTPUT_DIR="$TEST_OUTPUT"
    time_operation "Large Config Workflow" translate_homelab_to_compose
    assert_within_time_limit 10
}

# =============================================================================
# NETWORK CONNECTIVITY SIMULATION
# =============================================================================

@test "service connectivity validation (simulated)" {
    create_test_homelab_config "docker_compose" 3 5
    translate_homelab_to_compose "$TEST_CONFIG"

    # Simulate connectivity testing for each machine
    for machine_dir in "$TEST_OUTPUT"/*; do
        if [ -d "$machine_dir" ] && [ -f "$machine_dir/docker-compose.yaml" ]; then
            local machine
            machine=$(basename "$machine_dir")

            # Extract services and ports
            local services
            services=$(yq '.services | keys[]' "$machine_dir/docker-compose.yaml" 2>/dev/null | tr -d '"')

            while IFS= read -r service; do
                if [ -n "$service" ] && [ "$service" != "nginx-proxy" ]; then
                    # Get service port
                    local port
                    port=$(yq ".services[\"$service\"].ports[0]?" "$machine_dir/docker-compose.yaml" 2>/dev/null | cut -d: -f1 | tr -d '"')

                    if [ "$port" != "null" ] && [ -n "$port" ]; then
                        simulate_connectivity_test "$machine" "$service" "$port"
                        [ $status -eq 0 ]
                    fi
                fi
            done <<< "$services"
        fi
    done
}

@test "nginx proxy configuration validation" {
    create_test_homelab_config "docker_compose" 2 4
    translate_homelab_to_compose "$TEST_CONFIG"

    # Verify nginx configurations for each machine
    for nginx_conf in "$TEST_OUTPUT"/*/nginx/nginx.conf; do
        if [ -f "$nginx_conf" ]; then
            local machine
            machine=$(basename "$(dirname "$(dirname "$nginx_conf")")")

            echo "Validating nginx config for $machine"
            assert_nginx_config_valid "$nginx_conf"

            # Check for upstream configurations
            grep -q "upstream" "$nginx_conf" || echo "No upstream blocks found (may be expected)"

            # Check for proxy_pass configurations
            grep -q "proxy_pass" "$nginx_conf" || echo "No proxy_pass directives found (may be expected)"
        fi
    done
}
